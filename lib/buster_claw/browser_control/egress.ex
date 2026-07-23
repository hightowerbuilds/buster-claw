defmodule BusterClaw.BrowserControl.Egress do
  @moduledoc """
  Model egress — the composition (BROWSER_ENGINE_ROADMAP Phase 3.5).

  The qualifier this whole phase answers: the browsing *session* never leaves the
  machine, but page content the agent reasons over goes to Claude or Codex. We
  don't make a privacy promise — we send less, make secrets structurally
  unsendable, and produce a **falsifiable receipt** of exactly what left.

  `prepare/3` takes a `Snapshot` (the structured page capture Phase 4's extractor
  will fill) plus the host, resolves the egress `Policy` level, redacts at
  capture with the `Redactor`, and returns `{payload, %Report{}}`:

    * `:full` — title + interactive elements + redacted free text.
    * `:structure_only` — title + elements only; free text dropped. Structure is
      most of what a step needs (what's here, what's the heading, did my last
      action work), so this is cheap *and* usually enough.
    * `:never` — nothing but a policy marker; the model reasons blind here.

  The `Report` is the receipt part 5 renders and part-of-what earns consent:
  bytes in vs out, redaction counts by type, the level applied, and how many
  secret references were resolved locally (values that, by construction, never
  entered the payload).

  Redaction runs at every level — the level governs *how much shape* leaves,
  redaction governs *what within it is a secret*. Both happen here, at capture,
  before anything reaches a prompt buffer.
  """

  alias BusterClaw.BrowserControl.Egress.{Policy, Redactor, SecretRef}

  defmodule Snapshot do
    @moduledoc """
    The structured page capture Phase 4's extractor produces. Structure-first by
    design (part 3): interactive elements + headings, not raw DOM.
    """
    defstruct title: "", headings: [], elements: [], text: ""

    @type element :: %{optional(:role) => String.t(), optional(:label) => String.t()}
    @type t :: %__MODULE__{
            title: String.t(),
            headings: [String.t()],
            elements: [element()],
            text: String.t()
          }
  end

  defmodule Report do
    @moduledoc "The falsifiable receipt of one capture's egress."
    defstruct host: nil,
              level: :full,
              bytes_in: 0,
              bytes_out: 0,
              redactions: %{card: 0, ssn: 0, iban: 0, token: 0},
              secrets_resolved: 0

    @type t :: %__MODULE__{}
  end

  @doc """
  Prepare a snapshot for egress to the model.

  Options: `:overrides` (passed to `Policy.level_for/2`), `:secrets_resolved`
  (count of `$secret` refs the executor resolved locally this step, for the
  receipt).

  Returns `{payload, %Report{}}`. The payload is a plain map safe to serialize
  into the model prompt; the report is the receipt.
  """
  def prepare(host, %Snapshot{} = snap, opts \\ []) when is_binary(host) do
    level = Policy.level_for(host, opts)
    bytes_in = measure(snap)

    {payload, redactions} = build(level, snap)

    report = %Report{
      host: host,
      level: level,
      bytes_in: bytes_in,
      bytes_out: measure(payload),
      redactions: redactions,
      secrets_resolved: Keyword.get(opts, :secrets_resolved, 0)
    }

    {payload, report}
  end

  @doc """
  Fold one step's egress into a running run-level summary — the
  *"17 steps, 41KB sent, 6 fields redacted, 3 secrets resolved"* line.
  """
  def summarize(reports) when is_list(reports) do
    Enum.reduce(reports, blank_summary(), fn %Report{} = r, acc ->
      %{
        acc
        | steps: acc.steps + 1,
          bytes_out: acc.bytes_out + r.bytes_out,
          redactions: merge_counts(acc.redactions, r.redactions),
          secrets_resolved: acc.secrets_resolved + r.secrets_resolved,
          levels: Map.update(acc.levels, r.level, 1, &(&1 + 1))
      }
    end)
  end

  @doc "The secret-reference helpers, re-exported so callers reach them via Egress."
  defdelegate resolve_secrets(text, resolver), to: SecretRef, as: :resolve
  defdelegate mask_secrets(text), to: SecretRef, as: :mask

  # ── internals ─────────────────────────────────────────────────────────────

  defp build(:never, _snap) do
    {%{withheld: true, reason: "egress policy: never"}, Redactor.zero_counts()}
  end

  defp build(:structure_only, snap) do
    # Structure + headings survive; element labels are still redacted (a label
    # can carry a value); free text is dropped entirely.
    {title, tc} = Redactor.redact(snap.title)
    {headings, hc} = redact_list(snap.headings)
    {elements, ec} = redact_elements(snap.elements)

    payload = %{title: title, headings: headings, elements: elements}
    {payload, sum_counts([tc, hc, ec])}
  end

  defp build(:full, snap) do
    {title, tc} = Redactor.redact(snap.title)
    {headings, hc} = redact_list(snap.headings)
    {elements, ec} = redact_elements(snap.elements)
    {text, xc} = Redactor.redact(snap.text)

    payload = %{title: title, headings: headings, elements: elements, text: text}
    {payload, sum_counts([tc, hc, ec, xc])}
  end

  defp redact_list(list) do
    Enum.map_reduce(list, Redactor.zero_counts(), fn item, acc ->
      {red, counts} = Redactor.redact(item)
      {red, sum_counts([acc, counts])}
    end)
  end

  defp redact_elements(elements) do
    Enum.map_reduce(elements, Redactor.zero_counts(), fn el, acc ->
      {label, counts} = Redactor.redact(Map.get(el, :label, "") || "")
      {Map.put(el, :label, label), sum_counts([acc, counts])}
    end)
  end

  defp sum_counts(list_of_counts) do
    Enum.reduce(list_of_counts, Redactor.zero_counts(), &merge_counts/2)
  end

  defp merge_counts(a, b), do: Map.merge(a, b, fn _k, x, y -> x + y end)

  # The honest metric is "bytes that would actually leave" — the JSON the model
  # receives, not an internal encoding. Structs are normalized to plain maps
  # first; encoding can't fail on these shapes, but fall back defensively.
  defp measure(%Snapshot{} = snap), do: measure(Map.from_struct(snap))

  defp measure(term) do
    case Jason.encode(term) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> term |> :erlang.term_to_binary() |> byte_size()
    end
  end

  defp blank_summary do
    %{
      steps: 0,
      bytes_out: 0,
      redactions: Redactor.zero_counts(),
      secrets_resolved: 0,
      levels: %{}
    }
  end
end
