defmodule BusterClaw.BrowserControl.Egress.Policy do
  @moduledoc """
  Per-domain egress level (BROWSER_ENGINE_ROADMAP Phase 3.5, part 4).

  Not one blanket consent — three levels, resolved per host:

    * `:full` — redacted free text plus structure may go to the model.
    * `:structure_only` — only the interactive skeleton and headings leave;
      free text is dropped. The default for sensitive categories.
    * `:never` — nothing leaves; the model reasons blind on this host.

  Resolution order (most-specific wins, safest ties):

    1. **Operator override** for the host or a parent domain — the same
       most-specific-pattern-wins shape as `policy.md`, so this is an added
       dimension of one permission model, not a second one. (Wiring the literal
       `policy.md` grammar is a follow-up; the resolver contract is fixed here.)
    2. **Sensitive category** (banking / health / government) → `:structure_only`
       by default, without the user having to opt in.
    3. Otherwise → `:full`.

  Redaction (`Redactor`) still runs at every level including `:full` — the level
  decides *how much shape* leaves, redaction decides *what within it is a secret*.
  """

  @levels [:full, :structure_only, :never]

  # Host fragments that are sensitive by default. Conservative and coarse on
  # purpose: a false "sensitive" only drops free text (safe), a missed one leaks
  # it. Matched as a whole label or dotted suffix, never a bare substring.
  @sensitive_fragments ~w(
    bank chase wellsfargo citi capitalone americanexpress amex
    fidelity vanguard schwab etrade coinbase
    irs.gov ssa.gov gov.uk
    healthcare.gov mychart epic.com kaiserpermanente cigna aetna unitedhealthcare
  )

  @doc "The three valid levels, most-open first."
  def levels, do: @levels

  @doc """
  Resolve the egress level for `host`. `opts[:overrides]` is a list of
  `{pattern, level}` (host or parent domain → level); the most specific match
  wins, ties break toward the stricter level.
  """
  def level_for(host, opts \\ []) when is_binary(host) do
    h = normalize(host)
    overrides = Keyword.get(opts, :overrides, [])

    case best_override(h, overrides) do
      {:ok, level} -> level
      :none -> if sensitive?(h), do: :structure_only, else: :full
    end
  end

  @doc "True if the host is in a sensitive-by-default category."
  def sensitive?(host) when is_binary(host) do
    h = normalize(host)
    Enum.any?(@sensitive_fragments, &fragment_match?(h, &1))
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp best_override(host, overrides) do
    overrides
    |> Enum.filter(fn {pattern, level} ->
      level in @levels and host_matches?(host, normalize(pattern))
    end)
    |> Enum.sort_by(fn {pattern, level} ->
      # Longer pattern = more specific (wins); stricter level breaks ties.
      {-String.length(normalize(pattern)), strictness(level)}
    end)
    |> case do
      [{_pattern, level} | _] -> {:ok, level}
      [] -> :none
    end
  end

  # Higher = stricter (sorts first on a length tie so the safe choice wins).
  defp strictness(:never), do: 0
  defp strictness(:structure_only), do: 1
  defp strictness(:full), do: 2

  defp host_matches?(host, pattern),
    do: host == pattern or String.ends_with?(host, "." <> pattern)

  # A fragment matches if it IS a dotted domain (irs.gov) matched as host/suffix,
  # or a bare word that a domain LABEL starts with (bank → bank.x, bankofamerica;
  # citi → citi.com, citibank). Prefix, not substring, so "amex" doesn't fire on
  # "teamexcellence". Over-flagging (e.g. cities.com via "citi") is the safe
  # direction — it only drops free text — so the prefix rule stays coarse.
  defp fragment_match?(host, frag) do
    if String.contains?(frag, ".") do
      host_matches?(host, frag)
    else
      host |> String.split(".") |> Enum.any?(&String.starts_with?(&1, frag))
    end
  end

  defp normalize(v) do
    v
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.trim_leading(".")
    |> String.trim_trailing(".")
  end
end
