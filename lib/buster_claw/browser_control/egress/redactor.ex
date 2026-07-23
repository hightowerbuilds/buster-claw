defmodule BusterClaw.BrowserControl.Egress.Redactor do
  @moduledoc """
  Typed redaction for model egress (BROWSER_ENGINE_ROADMAP Phase 3.5, part 2).

  Replaces secret-shaped runs with **typed** placeholders — `⟨redacted:card⟩`,
  not a collapsed `[redacted]` — so page structure survives and the model still
  knows a card field is present without seeing its value. Returns counts per
  type so the run's accounting (part 5) can say *"6 fields redacted"* truthfully.

  Deliberately parallel to, not shared with, `Sentinel`'s masker: that one serves
  the audit log (untyped, never-raise, hot path); this one serves the model
  payload (typed, countable). Same Luhn idea, different consumer — merging them
  would couple two contracts that should move independently.

  Applied **at capture**, before text ever reaches a prompt buffer — a redaction
  pass on the way out is one bug away from not running.
  """

  # 13–19 digit runs, optionally space/dash grouped — filtered to Luhn-valid.
  @card_re ~r/\b\d(?:[ -]?\d){12,18}\b/
  # US SSN, dashed or spaced (bare 9-digit is too false-positive-prone to claim).
  @ssn_re ~r/\b\d{3}[ -]\d{2}[ -]\d{4}\b/
  # IBAN: 2-letter country + 2 check digits + 11–30 alnum.
  @iban_re ~r/\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b/
  # Credential-prefixed tokens (Bearer/sk-/ghp_/AWS/JWT…). Prefix-anchored → ~0 FP.
  @token_re ~r/(?:Bearer\s+|Basic\s+|sk-|pk-|ghp_|gho_|ghs_|ghu_|ghr_|github_pat_|xox[baprs]-|AKIA|eyJ)[A-Za-z0-9._\/+=-]{8,}/

  @placeholders %{
    card: "⟨redacted:card⟩",
    ssn: "⟨redacted:ssn⟩",
    iban: "⟨redacted:iban⟩",
    token: "⟨redacted:token⟩"
  }

  @doc "The placeholder string for a redaction type (exposed for tests/UI)."
  def placeholder(type), do: Map.fetch!(@placeholders, type)

  @doc "The zero count map (all types at 0)."
  def zero_counts, do: %{card: 0, ssn: 0, iban: 0, token: 0}

  @doc """
  Redact `text`, returning `{redacted, counts}` where `counts` is a map of
  `type => n`. Order matters: tokens and IBANs first (they can contain digit
  runs a card scan would otherwise claim), then SSN, then cards.
  """
  def redact(text) when is_binary(text) do
    {text, zero_counts()}
    |> sweep(:token, @token_re, fn _ -> true end)
    |> sweep(:iban, @iban_re, fn _ -> true end)
    |> sweep(:ssn, @ssn_re, fn _ -> true end)
    |> sweep(:card, @card_re, &luhn_valid?/1)
  end

  def redact(other), do: {other, zero_counts()}

  # Replace each match that passes `keep?/1` with its typed placeholder, counting.
  defp sweep({text, counts}, type, re, keep?) do
    ph = @placeholders[type]

    {new_text, n} =
      Regex.scan(re, text)
      |> Enum.reduce({text, 0}, fn [match | _], {acc, hits} ->
        if keep?.(match) do
          {String.replace(acc, match, ph, global: false), hits + 1}
        else
          {acc, hits}
        end
      end)

    {new_text, Map.update!(counts, type, &(&1 + n))}
  end

  defp luhn_valid?(match) do
    digits = String.replace(match, ~r/[ -]/, "")
    len = String.length(digits)

    if len < 13 or len > 19 do
      false
    else
      digits
      |> String.to_charlist()
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {char, idx}, acc ->
        d = char - ?0
        d = if rem(idx, 2) == 1, do: d * 2, else: d
        acc + if(d > 9, do: d - 9, else: d)
      end)
      |> rem(10)
      |> Kernel.==(0)
    end
  end
end
