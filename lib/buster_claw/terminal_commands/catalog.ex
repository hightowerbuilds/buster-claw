defmodule BusterClaw.TerminalCommands.Catalog do
  @moduledoc """
  The persisted user-catalog document: a single versioned JSON value stored in
  `BusterClaw.Settings` under `"terminal_commands.catalog"`. Diff-only — it
  holds user overrides/additions for non-protected roles; unedited built-ins
  and the protected roles are never written here (`TerminalCommands.load/1`
  re-injects them from the shipped catalog).

  This is an embedded-only Ecto schema used purely to validate the document
  before it is serialized to JSON. No table, no migration.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.TerminalCommands.Catalog.Role
  alias BusterClaw.TerminalCommands.Command

  @version 1
  @max_roles 32

  @primary_key false
  embedded_schema do
    field :version, :integer, default: @version
    embeds_many :roles, Role, on_replace: :delete
  end

  @doc "The current document schema version."
  def version, do: @version

  @doc """
  Upgrade an older persisted document to the current shape. Version #{@version}
  is current, so this is a shape-preserving no-op; future versions add clauses
  here. Anything unrecognizable degrades to `nil` (built-ins only).
  """
  def migrate(nil), do: nil
  def migrate(%{} = doc), do: Map.put_new(doc, "version", @version)
  def migrate(_other), do: nil

  def changeset(catalog \\ %__MODULE__{}, attrs) do
    catalog
    |> cast(attrs, [:version])
    |> validate_inclusion(:version, [@version])
    |> cast_embed(:roles)
    |> validate_role_count()
    |> validate_unique_role_keys()
  end

  @doc """
  Validate a decoded (string-keyed) document. Returns `{:ok, normalized_map}`
  ready for `Jason.encode!/1`, or `{:error, changeset}`.
  """
  def validate(attrs) when is_map(attrs) do
    case apply_action(changeset(%__MODULE__{}, attrs), :insert) do
      {:ok, catalog} -> {:ok, to_map(catalog)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Serialize a validated document struct to a string-keyed map for JSON."
  def to_map(%__MODULE__{} = catalog) do
    %{
      "version" => catalog.version,
      "roles" => Enum.map(catalog.roles, &role_to_map/1)
    }
  end

  defp role_to_map(%Role{} = role) do
    %{"key" => role.key}
    |> put_present("default_key", role.default_key)
    |> Map.put("commands", Enum.map(role.commands, &command_to_map/1))
  end

  # `builtin` and the embed id are runtime-only — deliberately not persisted,
  # so they can't be forged through a hand-edited document.
  defp command_to_map(%Command{} = command) do
    %{"key" => command.key, "command" => command.command, "kind" => command.kind}
    |> put_present("label", command.label)
    |> put_present("description", command.description)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp validate_role_count(changeset) do
    if length(get_field(changeset, :roles) || []) > @max_roles do
      add_error(changeset, :roles, "cannot exceed #{@max_roles} roles")
    else
      changeset
    end
  end

  defp validate_unique_role_keys(changeset) do
    keys =
      changeset
      |> get_field(:roles)
      |> Kernel.||([])
      |> Enum.map(& &1.key)
      |> Enum.reject(&is_nil/1)

    if length(keys) == length(Enum.uniq(keys)) do
      changeset
    else
      add_error(changeset, :roles, "role keys must be unique")
    end
  end
end
