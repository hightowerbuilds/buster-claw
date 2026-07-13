defmodule BusterClaw.TrustedNumbers do
  @moduledoc """
  Trusted-caller policy: decides whether an inbound phone event may drive
  follow-through work — i.e. be enqueued on the Dispatch queue. Untrusted callers
  are still recorded and playable in the Message Machine; they just don't land on
  the agent's plate.

  This is the phone-side twin of `BusterClaw.TrustedSenders`, and it exists for
  the same reason: an answering machine records *strangers by design*. Robocalls
  are the common case, not the exception. Auto-actioning a stranger's voicemail
  would hand an unauthenticated caller a foothold on the agent's work queue — and
  because the Dispatcher's provenance gate is **per-run, not per-item**, a single
  untrusted item sitting in the open pool downgrades the token for every trusted
  item worked alongside it. So: strangers are archived, never queued.

  The policy lives at `<workspace>/memory/trusted-phone-numbers.md`. It is freeform
  markdown; the parser pulls out any entry that normalizes to a phone number:

    - E.164 — `+18446878016`
    - US 10-digit, in any common shape — `(844) 687-8016`, `844-687-8016`
    - US 11-digit with country code — `1 844 687 8016`

  A missing or empty file means **no** caller is trusted (safe default) — so a
  fresh install records voicemail but never queues it until you say who counts.

  ## Normalization

  Everything is stored and compared as E.164 (`+18446878016`). A bare 10-digit
  number is assumed to be US and gets `+1`; a leading `+` is always honoured as-is,
  so non-US numbers work if written in full E.164. There is no area-code or
  prefix wildcard — trusting "all of +1555…" is exactly the hole robocallers walk
  through, and an exact-match list is the whole point of this module.
  """
  alias BusterClaw.Library.Artifact

  @policy_file "trusted-phone-numbers.md"

  # A phone-shaped token: an optional +, then digits with the usual separators.
  # Deliberately loose — `normalize/1` is the real gate and rejects anything that
  # doesn't land on a plausible E.164 digit count, so a date like 2026-07-12
  # (8 digits, no leading +) is scanned but never accepted.
  @token ~r/\+?\d[\d\s().\-]{5,20}\d/

  @doc "The matched E.164 number for `from`, or nil when the caller is untrusted."
  def match(from) do
    case normalize(from) do
      {:ok, number} -> if number in cached_policy(), do: number, else: nil
      :error -> nil
    end
  end

  @doc "Whether `from` may drive follow-through work."
  def trusted?(from), do: match(from) != nil

  @doc """
  Normalize a raw phone string to E.164.

  Returns `{:ok, "+1..."}` or `:error`. A leading `+` is honoured as written
  (8–15 digits, per E.164). Without a `+`, only a US 10-digit number or an
  11-digit number beginning with `1` is accepted — anything else is ambiguous
  and refused rather than guessed at.
  """
  def normalize(raw) do
    str = to_string(raw) |> String.trim()
    plus? = String.starts_with?(str, "+")
    digits = String.replace(str, ~r/\D/, "")
    len = String.length(digits)

    cond do
      plus? and len in 8..15 -> {:ok, "+" <> digits}
      not plus? and len == 10 -> {:ok, "+1" <> digits}
      not plus? and len == 11 and String.starts_with?(digits, "1") -> {:ok, "+" <> digits}
      true -> :error
    end
  end

  @doc "The configured trusted numbers in E.164, sorted."
  def list_entries do
    read_policy_contents() |> scan_numbers() |> Enum.sort()
  end

  @doc """
  Add a trusted number. Accepts any form `normalize/1` understands. Idempotent.
  Returns `{:ok, e164}` or `{:error, :invalid_entry}`.
  """
  def add_entry(raw) do
    case normalize(raw) do
      {:ok, number} ->
        contents = read_or_seed()

        if number in scan_numbers(contents) do
          {:ok, number}
        else
          with :ok <-
                 File.write(
                   policy_path(),
                   ensure_trailing_newline(contents) <> "- #{number}\n"
                 ) do
            refresh_cache()
            {:ok, number}
          end
        end

      :error ->
        {:error, :invalid_entry}
    end
  end

  @doc """
  Remove a trusted number (any form that normalizes to the same E.164).
  Returns `:ok` (a no-op if it was not present) or `{:error, :invalid_entry}`.
  """
  def remove_entry(raw) do
    case normalize(raw) do
      {:ok, number} ->
        updated =
          read_or_seed()
          |> String.split("\n")
          |> Enum.reject(&(number in scan_numbers(&1)))
          |> Enum.join("\n")

        result = File.write(policy_path(), updated)
        if result == :ok, do: refresh_cache()
        result

      :error ->
        {:error, :invalid_entry}
    end
  end

  defp read_policy_contents do
    case File.read(policy_path()) do
      {:ok, contents} -> contents
      _ -> ""
    end
  end

  defp read_or_seed do
    case File.read(policy_path()) do
      {:ok, contents} ->
        contents

      _ ->
        File.mkdir_p!(Path.dirname(policy_path()))
        header = seed_contents()
        File.write!(policy_path(), header)
        header
    end
  end

  @doc """
  The starter policy file contents (also used by `BusterClaw.Jobs` to seed).

  Deliberately contains **no example number**. The scanner reads the whole file —
  it does not strip code fences or comments — so any phone-shaped example would
  seed itself as a live trusted caller and quietly contradict the safe default.
  The placeholder below has one digit and cannot normalize.
  """
  def seed_contents do
    """
    # Trusted phone numbers

    Callers listed here may drive follow-through work: their voicemail becomes a
    Dispatch item the on-duty agent picks up. Anyone not listed is still recorded
    and playable in the Message Machine — they just never reach the agent's queue.

    An empty list means nobody is trusted. That is the safe default; add yourself
    first. Write one number per line as a list item, in any common form — E.164
    (+1XXXXXXXXXX), US 10-digit, or 11-digit with country code. All normalize to
    E.164 before matching.

    Add real numbers as list items below this line.
    """
  end

  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(contents) do
    if String.ends_with?(contents, "\n"), do: contents, else: contents <> "\n"
  end

  defp scan_numbers(contents) do
    @token
    |> Regex.scan(contents)
    |> Enum.flat_map(fn [token | _] ->
      case normalize(token) do
        {:ok, number} -> [number]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  # Parsed policy cached in :persistent_term so the inbound path skips a disk read
  # + regex scan per event. Keyed by resolved path so switching workspaces serves
  # the right policy. All writes go through add_entry/remove_entry, which refresh.
  defp cache_key, do: {__MODULE__, :policy, policy_path()}

  defp cached_policy do
    key = cache_key()

    case :persistent_term.get(key, :miss) do
      :miss ->
        policy = load_policy()
        :persistent_term.put(key, policy)
        policy

      policy ->
        policy
    end
  end

  defp refresh_cache do
    :persistent_term.put(cache_key(), load_policy())
    :ok
  end

  defp load_policy, do: read_policy_contents() |> scan_numbers()

  defp policy_path do
    Artifact.workspace_path(["memory", @policy_file])
  end
end
