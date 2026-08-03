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

  # The operator's per-host levels live in `Settings` under this key as a JSON
  # object, `{"host": "level"}`. Settings rather than a workspace file on
  # purpose: a seeded file could never be improved on an install that already
  # had one (see LAUNCH_ROADMAP V.8), and this list is one we expect to grow.
  @overrides_key "browser_egress_overrides"

  # Shipped defaults. These stay in CODE so a new entry reaches every install on
  # upgrade; the operator's own entries are layered on top and win. The 07-25
  # field test measured 89.8 KB leaving the machine over 41 steps, all at
  # `:full` with zero redactions — correct per the documented default, and it
  # meant complete Amazon pages, order history included, went to the model.
  @default_overrides [{"amazon.com", :structure_only}]

  @doc """
  The shipped defaults alone — no database read. `AgentMode` falls back to these
  when a caller supplies nothing, so a run never depends on the repo to boot.
  """
  def default_overrides, do: @default_overrides

  @doc """
  Per-host levels: the shipped defaults with the operator's entries layered over
  them. Reads `Settings`, so callers are the command surface, not `AgentMode`.
  """
  def overrides do
    stored = stored_overrides()
    # Host strings come from the operator, so they stay strings — interning them
    # as atoms to use map merging would be an unbounded atom table.
    claimed = MapSet.new(stored, fn {host, _level} -> normalize(host) end)

    Enum.reject(@default_overrides, fn {host, _level} -> normalize(host) in claimed end) ++
      stored
  end

  @doc "The operator's stored entries alone, as `[{host, level}]`."
  def stored_overrides do
    with raw when is_binary(raw) <- BusterClaw.Settings.get(@overrides_key),
         {:ok, %{} = decoded} <- Jason.decode(raw) do
      for {host, level} <- decoded,
          parsed = parse_level(level),
          parsed != nil,
          do: {host, parsed}
    else
      _ -> []
    end
  end

  @doc """
  Set one host's level, or remove it with `nil`. Returns the stored entries.
  Refuses an unknown level rather than silently recording a typo as no rule.
  """
  def put_override(host, level) when is_binary(host) and host != "" do
    with {:ok, level} <- validate_level(level) do
      entries =
        stored_overrides()
        |> Map.new()
        |> then(fn m ->
          if level, do: Map.put(m, normalize(host), level), else: Map.delete(m, normalize(host))
        end)

      BusterClaw.Settings.put(
        @overrides_key,
        Jason.encode!(Map.new(entries, fn {h, l} -> {h, Atom.to_string(l)} end))
      )

      {:ok, Enum.sort(entries)}
    end
  end

  defp validate_level(nil), do: {:ok, nil}
  defp validate_level(level) when level in @levels, do: {:ok, level}

  defp validate_level(level) when is_binary(level) do
    case parse_level(level) do
      nil -> {:error, {:bad_level, level}}
      parsed -> {:ok, parsed}
    end
  end

  defp validate_level(level), do: {:error, {:bad_level, level}}

  defp parse_level(level) when level in @levels, do: level

  defp parse_level(level) when is_binary(level) do
    Enum.find(@levels, &(Atom.to_string(&1) == level))
  end

  defp parse_level(_level), do: nil

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
