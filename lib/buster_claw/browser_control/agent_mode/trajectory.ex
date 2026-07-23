defmodule BusterClaw.BrowserControl.AgentMode.Trajectory do
  @moduledoc """
  The recorded run (BROWSER_ENGINE_ROADMAP Phase 4) — every route change and
  action as it happened, replayable for scrub-back and inspectable for the "what
  the model saw" view.

  Pure and append-only. A `Step` is formed through `step/2`, which is the single
  place **redaction at capture** happens: a fill's value is masked here, at the
  moment the step is created, so a secret value can never enter the record in the
  first place. That is deliberate — a redaction applied when the rail *renders* is
  one bug away from not running; a value that was never stored cannot leak no
  matter what renders it.

  Each step carries its motivating `origin` (from the frozen `Scope`), so a step
  the trajectory can't tie to the task's intent is exactly what an injected
  action looks like when you scrub back through it.
  """

  alias BusterClaw.BrowserControl.AgentMode.Trajectory
  alias BusterClaw.BrowserControl.Egress.{Redactor, SecretRef}

  defmodule Step do
    @moduledoc false
    defstruct [:seq, :type, :summary, :origin, :outcome, :egress, :at, :thumbnail]

    @type t :: %__MODULE__{
            seq: non_neg_integer(),
            type: atom(),
            summary: String.t(),
            origin: map() | nil,
            outcome: atom(),
            egress: map() | nil,
            at: integer() | nil,
            thumbnail: String.t() | nil
          }
  end

  defstruct steps: [], next_seq: 0

  @type t :: %__MODULE__{steps: [Step.t()], next_seq: non_neg_integer()}

  @doc "A fresh, empty trajectory."
  def new, do: %Trajectory{}

  @doc """
  Append a step, redacting at capture. `attrs`:

    * `:type` — `:navigate | :click | :fill | :extract | :halt | :handoff | …`
    * `:summary` — human/model-facing description; **masked here** for secret
      references and secret-shaped runs before it is stored.
    * `:origin` — the Scope origin that motivated the action (or nil).
    * `:outcome` — `:ok | :halted | :error | …`.
    * `:egress` — the `Egress.Report` for a content-reading step (or nil).
    * `:at` — caller-supplied timestamp (ms); no wall-clock is read here.
    * `:thumbnail` — opaque ref to a capture already redacted at the pixel layer.
  """
  def step(%Trajectory{} = t, attrs) do
    step = %Step{
      seq: t.next_seq,
      type: Map.fetch!(attrs, :type),
      summary: redact_summary(Map.get(attrs, :summary, "")),
      origin: Map.get(attrs, :origin),
      outcome: Map.get(attrs, :outcome, :ok),
      egress: Map.get(attrs, :egress),
      at: Map.get(attrs, :at),
      thumbnail: Map.get(attrs, :thumbnail)
    }

    %{t | steps: [step | t.steps], next_seq: t.next_seq + 1}
  end

  @doc "Steps in the order they happened (oldest first) — the scrub-back timeline."
  def steps(%Trajectory{steps: steps}), do: Enum.reverse(steps)

  @doc "The most recent step, or nil."
  def last(%Trajectory{steps: [s | _]}), do: s
  def last(%Trajectory{steps: []}), do: nil

  @doc """
  Run summary: step count, the egress roll-up (bytes sent, fields redacted,
  secrets resolved — the *\"17 steps, 41KB, 6 redacted\"* line), and per-outcome
  counts. Built from stored steps, so it can never disagree with the timeline.
  """
  def summary(%Trajectory{} = t) do
    steps = steps(t)
    reports = steps |> Enum.map(& &1.egress) |> Enum.reject(&is_nil/1)

    %{
      steps: length(steps),
      egress: BusterClaw.BrowserControl.Egress.summarize(reports),
      outcomes: Enum.frequencies_by(steps, & &1.outcome)
    }
  end

  # The single redaction-at-capture point: secret references become ⟨secret:…⟩
  # and secret-shaped runs become typed placeholders, before storage.
  defp redact_summary(summary) when is_binary(summary) do
    {redacted, _counts} = summary |> SecretRef.mask() |> Redactor.redact()
    redacted
  end

  defp redact_summary(other), do: other
end
