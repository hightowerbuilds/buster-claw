defmodule BusterClaw.TerminalCommands.Catalog.Role do
  @moduledoc """
  One role entry in the persisted user catalog. Diff-only: it carries the
  user's command overrides and additions plus an optional `default_key`
  choice — never unedited built-in rows, and never a protected role.
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

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:key, :default_key])
    |> cast_embed(:commands, with: &Command.changeset(&1, &2, enforce_kind: false))
    |> validate_required([:key])
    |> validate_format(:key, Command.key_format(), message: "must be a lowercase slug")
    |> validate_length(:key, max: 64)
    |> validate_format(:default_key, Command.key_format(), message: "must be a lowercase slug")
    |> validate_not_protected()
    |> validate_command_count()
    |> validate_unique_command_keys()
    |> validate_effective_kinds()
    |> validate_default_key_resolves()
    |> validate_user_role_has_commands()
  end

  # The whole point of the protection model: the persisted document can never
  # carry an entry for the shift safety surface, even via direct writes.
  defp validate_not_protected(changeset) do
    key = get_field(changeset, :key)

    if is_binary(key) and TerminalCommands.protected?(key) do
      add_error(changeset, :key, "is protected and cannot be customized")
    else
      changeset
    end
  end

  defp validate_command_count(changeset) do
    if length(get_field(changeset, :commands) || []) > @max_commands do
      add_error(changeset, :commands, "cannot exceed #{@max_commands} commands per role")
    else
      changeset
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

  # Overrides of built-in commands omit `kind` (the shipped kind is
  # authoritative), so the single-line-shell rule is enforced here against the
  # built-in kind — a forged `kind: "prompt"` on a shell override can't smuggle
  # a multiline command past validation.
  defp validate_effective_kinds(changeset) do
    builtin_kinds = builtin_kinds(get_field(changeset, :key))

    offenders =
      changeset
      |> get_field(:commands)
      |> Kernel.||([])
      |> Enum.filter(fn command ->
        kind = Map.get(builtin_kinds, command.key, command.kind)

        kind == "shell" and is_binary(command.command) and
          String.match?(command.command, ~r/[\r\n]/)
      end)
      |> Enum.map(& &1.key)

    if offenders == [] do
      changeset
    else
      add_error(
        changeset,
        :commands,
        "shell commands must be a single line: #{Enum.join(offenders, ", ")}"
      )
    end
  end

  defp validate_default_key_resolves(changeset) do
    default_key = get_field(changeset, :default_key)

    if is_nil(default_key) do
      changeset
    else
      builtin_keys = Map.keys(builtin_kinds(get_field(changeset, :key)))

      doc_keys =
        changeset
        |> get_field(:commands)
        |> Kernel.||([])
        |> Enum.map(& &1.key)

      if default_key in builtin_keys or default_key in doc_keys do
        changeset
      else
        add_error(changeset, :default_key, "must reference a command in this role")
      end
    end
  end

  # A role the shipped catalog doesn't know about only exists through its own
  # commands — an empty one would render as a ghost group.
  defp validate_user_role_has_commands(changeset) do
    key = get_field(changeset, :key)

    if is_binary(key) and is_nil(TerminalCommands.builtin_role(key)) and
         get_field(changeset, :commands) in [nil, []] do
      add_error(changeset, :commands, "a custom role needs at least one command")
    else
      changeset
    end
  end

  defp builtin_kinds(key) when is_binary(key) do
    case TerminalCommands.builtin_role(key) do
      nil ->
        %{}

      %{commands: commands} ->
        Map.new(commands, &{&1.key, Atom.to_string(Map.get(&1, :kind, :shell))})
    end
  end

  defp builtin_kinds(_key), do: %{}
end
