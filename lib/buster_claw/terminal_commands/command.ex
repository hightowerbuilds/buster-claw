defmodule BusterClaw.TerminalCommands.Command do
  @moduledoc """
  Embedded schema for one terminal-catalog command, shared by the persisted
  user-catalog document (`Catalog.Role`) and the Settings editor (`RoleEdit`).

  `kind` picks the editing rules: `"shell"` commands must stay single-line
  (they are typed into a PTY), `"prompt"` entries may be multiline. `builtin`
  is derived from the shipped catalog at load time — it is never cast from
  user input and never persisted.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @kinds ~w(shell prompt)
  @key_format ~r/^[a-z0-9][a-z0-9-]*$/

  @primary_key {:id, :binary_id, autogenerate: true}
  embedded_schema do
    field :key, :string
    field :label, :string
    field :description, :string
    field :command, :string
    field :kind, :string, default: "shell"
    field :builtin, :boolean, default: false
  end

  @doc "The allowed `kind` values."
  def kinds, do: @kinds

  @doc "The slug format command and role keys must match."
  def key_format, do: @key_format

  @doc """
  Validate one command.

  Options:

    * `:require_key` (default `true`) — the editor accepts new rows whose key
      is minted server-side at save time, so it passes `false`.
    * `:enforce_kind` (default `true`) — the persisted document omits `kind`
      on built-in overrides (the built-in kind is authoritative), so the
      catalog changeset passes `false` and re-checks at the role level against
      the shipped kind instead.
  """
  def changeset(command, attrs, opts \\ []) do
    command
    |> cast(attrs, [:key, :label, :description, :command, :kind])
    |> update_change(:label, &blank_to_nil/1)
    |> update_change(:description, &blank_to_nil/1)
    |> update_change(:command, &trim_to_nil/1)
    |> maybe_require_key(Keyword.get(opts, :require_key, true))
    |> validate_format(:key, @key_format, message: "must be a lowercase slug")
    |> validate_length(:key, max: 64)
    |> validate_required([:command])
    |> validate_length(:label, max: 120)
    |> validate_length(:description, max: 1000)
    |> validate_length(:command, max: 8000)
    |> validate_inclusion(:kind, @kinds)
    |> maybe_enforce_kind(Keyword.get(opts, :enforce_kind, true))
  end

  @doc """
  The single-line rule for shell commands, applied to a command changeset.
  Prompts may span lines; shell text is typed straight into the PTY, where a
  newline executes, so embedded newlines would smuggle extra commands.
  """
  def validate_single_line_shell(changeset, kind) do
    command = get_field(changeset, :command)

    if kind == "shell" and is_binary(command) and String.match?(command, ~r/[\r\n]/) do
      add_error(changeset, :command, "shell commands must be a single line")
    else
      changeset
    end
  end

  defp maybe_require_key(changeset, true), do: validate_required(changeset, [:key])
  defp maybe_require_key(changeset, false), do: changeset

  defp maybe_enforce_kind(changeset, true),
    do: validate_single_line_shell(changeset, get_field(changeset, :kind))

  defp maybe_enforce_kind(changeset, false), do: changeset

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp trim_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_to_nil(_value), do: nil
end
