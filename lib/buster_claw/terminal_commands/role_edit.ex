defmodule BusterClaw.TerminalCommands.RoleEdit do
  @moduledoc """
  Editor-facing schema for one non-protected role: the full merged command
  list (built-ins + user rows) exactly as Settings → cmd-list shows it.

  The changeset guards the editing invariants — built-in commands cannot be
  removed, keys stay unique, the chosen default resolves — and supports the
  standard `sort_param`/`drop_param` dynamic-row form pattern. The persisted
  document is the *diff* computed from an applied edit by
  `TerminalCommands.save_role_edit/2`, which re-validates the whole document
  through `Catalog` before writing.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.TerminalCommands
  alias BusterClaw.TerminalCommands.Command

  @max_commands 64

  @primary_key false
  embedded_schema do
    field :key, :string
    field :default_key, :string
    embeds_many :commands, Command, on_replace: :delete
  end

  @doc """
  Cast editor params. The role `key` is intentionally not cast — role identity
  comes from the server-held base struct, never from the form.
  """
  def changeset(%__MODULE__{} = edit, attrs) do
    edit
    |> cast(attrs, [:default_key])
    |> update_change(:default_key, &blank_to_nil/1)
    |> cast_embed(:commands,
      with: &Command.changeset(&1, &2, require_key: false),
      sort_param: :commands_sort,
      drop_param: :commands_drop
    )
    |> validate_command_count()
    |> validate_builtin_commands_present()
    |> validate_unique_command_keys()
    |> validate_default_key()
  end

  defp validate_command_count(changeset) do
    if length(get_field(changeset, :commands) || []) > @max_commands do
      add_error(changeset, :commands, "cannot exceed #{@max_commands} commands per role")
    else
      changeset
    end
  end

  # Built-in rows are editable but never deletable — dropping one (or forging
  # its hidden key field) surfaces here as a missing built-in key.
  defp validate_builtin_commands_present(changeset) do
    builtin_keys =
      case TerminalCommands.builtin_role(changeset.data.key) do
        nil -> []
        %{commands: commands} -> Enum.map(commands, & &1.key)
      end

    present =
      changeset
      |> get_field(:commands)
      |> Kernel.||([])
      |> Enum.map(& &1.key)

    case builtin_keys -- present do
      [] ->
        changeset

      missing ->
        add_error(
          changeset,
          :commands,
          "built-in commands cannot be deleted: #{Enum.join(missing, ", ")}"
        )
    end
  end

  defp validate_unique_command_keys(changeset) do
    keys =
      changeset
      |> get_field(:commands)
      |> Kernel.||([])
      |> Enum.map(& &1.key)
      |> Enum.reject(&is_nil/1)

    if length(keys) == length(Enum.uniq(keys)) do
      changeset
    else
      add_error(changeset, :commands, "command keys must be unique within a role")
    end
  end

  defp validate_default_key(changeset) do
    default_key = get_field(changeset, :default_key)

    keys =
      changeset
      |> get_field(:commands)
      |> Kernel.||([])
      |> Enum.map(& &1.key)

    if is_nil(default_key) or default_key in keys do
      changeset
    else
      add_error(changeset, :default_key, "must be one of this role's commands")
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
