defmodule BusterClaw.Sketch.Authorship do
  @moduledoc """
  `D6` — who may change what, and it is decided by **who made the mark**, not by
  the caller's tier.

  > The model gets full power over its own work and none over yours.

  The obvious design is a tier: let the model create but not delete. It is wrong,
  and it is wrong in a way this repo has already worked out twice. **Terminal
  paint** (`TERMINAL_PAINT` D3) lets the model repaint the terminal, but every
  write lands in the agent's *own* theme slot — the operator's saved palette
  survives whatever the model does. **Voice banks** (`STUDIO` V.0) never merge, so
  one contributor's takes can never be spliced into another's.

  Applied here it produces something a tier could not:

  * The model iterates freely — draw, look, redraw, delete its own false starts —
    with no confirmation friction. That is what makes it useful at all.
  * The operator's strokes cannot be silently removed by a model that decided
    they were a mistake. **That is the [Cleo failure mode](https://arxiv.org/html/2603.02050)
    — an agent reverting a user's edit because it conflicts with its own plan —
    refused structurally rather than prompted against.**

  ## Gated, not refused

  Touching an operator-authored element returns `{:error, :requires_confirmation}`
  and is recorded on the Sentinel feed, exactly as a gated command is. It is not
  a hard block, because *"move my box to make room"* is a reasonable thing to ask
  for and an unreasonable thing to do unasked. The operator can say yes; the
  model cannot say it for them.

  ## The operator is not subject to this

  A `:trusted` caller is the operator's own hand — their CLI, their UI. They own
  every mark on the sketch, including the model's. Only the agent tiers are
  bounded here.
  """

  alias BusterClaw.Sketch.Document

  # The callers that ARE the operator. Everything else is an agent of some kind
  # and gets D6's boundary. `:terminal` is the operator's own shell, which the
  # PolicyEngine already treats as trusted-equivalent for the same reason.
  @operator_callers [:trusted, :terminal]

  @doc """
  May `caller` modify the element `id` on `doc`?

  * `:ok` — go ahead.
  * `{:error, :not_found}` — no such element. Refused **by name** rather than
    silently skipped (`D5`): Phase 3 hands these ids to a model, and "the delete
    did nothing" is the failure that cannot be diagnosed from outside.
  * `{:error, :requires_confirmation}` — the element is the operator's.
  """
  @spec check(Document.t(), String.t(), atom()) ::
          :ok | {:error, :not_found} | {:error, :requires_confirmation}
  def check(%Document{} = doc, id, caller) do
    case Document.find(doc, id) do
      nil -> {:error, :not_found}
      element -> check_element(element, caller)
    end
  end

  @doc "May `caller` modify this element?"
  def check_element(element, caller) do
    cond do
      caller in @operator_callers -> :ok
      element.author == :model -> :ok
      true -> {:error, :requires_confirmation}
    end
  end

  @doc """
  The author an element created by `caller` should carry.

  Not a detail. An element that arrived unattributed — or attributed to the
  operator — would be one the model may never touch again; one wrongly attributed
  to the model is one it may delete without asking. The stamp is the boundary.
  """
  @spec author_for(atom()) :: :operator | :model
  def author_for(caller) when caller in @operator_callers, do: :operator
  def author_for(_caller), do: :model

  @doc "Whether `caller` is the operator rather than an agent."
  def operator?(caller), do: caller in @operator_callers
end
