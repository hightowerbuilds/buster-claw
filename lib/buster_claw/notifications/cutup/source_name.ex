defmodule BusterClaw.Notifications.Cutup.SourceName do
  @moduledoc """
  The one gate that decides whether a string may be used as a source basename —
  shared by every store in the cut-up pipeline that keys files on one.

  A `source` is a **basename inside the Studio's sources directory**, never a
  path (`t:BusterClaw.Notifications.Cutup.Types.index/0` states that as a
  contract). `Cutup.Index` and `Cutup.Features` both turn a source name into a
  filename in a directory they own, so both have to refuse a name that could
  name a file somewhere else. They each carried their own copy of this check.

  ## Why the copies had to go

  The copies were **verbatim identical** — checked line for line before they were
  merged, so nothing was chosen and nothing was lost. That is the good case, and
  it is also the fragile one: both moduledocs claimed to use "the same gate
  `Cutup.Index` uses", and that claim was true only by coincidence of editing.
  The failure mode is silent by construction — a fix or a tightening applied to
  one copy leaves the *other* store's gate weaker with no test failing anywhere,
  because each store's traversal test only ever exercised its own copy. One
  function makes the claim true by construction instead.

  ## What it refuses, and why the two errors are different

  - `:invalid_source` — the name is not a plain basename. Empty, `.`, `..`, or
    containing `/`, `\\`, `..` or a null byte, or anything `Path.basename/1`
    would shorten. This is the traversal answer.
  - `:unsafe_source` — a legal basename that `BusterClaw.AudioName.safe_name/1`
    would **rewrite**. Refused rather than silently renamed: a store that
    sanitized on the way in would write its file under a name the caller never
    asked for and could not then load by.

  Two atoms rather than one because the fixes differ — "that is a path, pass a
  basename" and "that name has characters the studio will not store" — and both
  are already in `Index`'s and `Features`' published error types.

  The `safe_name/1` comparison is **case-insensitive**, because that sanitizer
  downcases the extension it re-attaches. Without the fold, a genuine
  `VOICE.WAV` is refused for a difference that is not a safety difference.

  ## Totality

  Nothing here raises, on anything, including a non-binary. Both callers promise
  a named result from every public function; a gate that raised would be the one
  hole in that.
  """

  alias BusterClaw.AudioName

  @typedoc "A source basename inside the studio's sources directory."
  @type t :: String.t()

  @typedoc "Why a name was refused. Returned, never raised."
  @type error :: :invalid_source | :unsafe_source

  @doc """
  The gate. `{:ok, name}` for a name a store may key a file on, and one of the
  two errors above otherwise.

  The returned name is the input unchanged — this validates, it never repairs.
  """
  @spec safe(term()) :: {:ok, t()} | {:error, error()}
  def safe(source) when is_binary(source) do
    cond do
      source in ["", ".", ".."] -> {:error, :invalid_source}
      String.contains?(source, ["/", "\\", "..", <<0>>]) -> {:error, :invalid_source}
      Path.basename(source) != source -> {:error, :invalid_source}
      not fixpoint?(source) -> {:error, :unsafe_source}
      true -> {:ok, source}
    end
  end

  def safe(_source), do: {:error, :invalid_source}

  @doc "Whether a term passes the gate. `safe/1` when the reason does not matter."
  @spec safe?(term()) :: boolean()
  def safe?(source), do: match?({:ok, _name}, safe(source))

  @doc """
  The source basenames a store's directory holds: every entry ending in `ext`,
  with the suffix removed, **run back through the gate**, sorted case-insensitively.

  The gate is applied on the way *out* as well as on the way in because the
  directory is on disk and a name can arrive there without passing through this
  module — a copy, a hand-edit, a restore from a backup taken before the gate
  existed. Listing a name no entry point would then accept is a listing that
  lies.

  Never raises. An absent or unreadable directory lists as `[]`: both callers
  document that answer, and neither has an error channel here.
  """
  @spec list_in(String.t(), String.t()) :: [t()]
  def list_in(dir, ext) when is_binary(dir) and is_binary(ext) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ext))
        |> Enum.map(&String.replace_suffix(&1, ext, ""))
        |> Enum.filter(&safe?/1)
        |> Enum.sort_by(&String.downcase/1)

      {:error, _reason} ->
        []
    end
  end

  # Case-insensitive because `safe_name/1` downcases the extension it re-attaches,
  # so a genuine `VOICE.WAV` would otherwise be refused for a difference that is
  # not a safety difference.
  defp fixpoint?(source) do
    String.downcase(AudioName.safe_name(source)) == String.downcase(source)
  end
end
