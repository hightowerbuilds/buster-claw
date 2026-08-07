defmodule BusterClaw.Agent.AttentionContract do
  @moduledoc """
  What we tell a model about live operator messages.

  Steering has two halves and they fail differently. The **transport** makes the
  message arrive; this makes the model *receptive to it*. Without the contract a
  model receives a mid-turn correction with no framing at all and has to guess
  whether it supersedes the original instruction, whether to redo work it has
  already done, or whether to stop and ask. Buster Claw watched all three
  backends do exactly that during acceptance — they coped, but they were
  guessing.

  Neither half is sufficient alone: the contract makes a model willing to be
  redirected, and nothing in it can deliver a message that the transport did not.

  ## Only where a message can actually arrive mid-turn

  `apply?/1` gates this on the transport advertising `:steer`. Telling a model on
  a one-shot backend that "the operator may send messages while you are working"
  would be false — there, a message submitted during a run becomes the *next
  turn*, arriving as ordinary conversation with nothing to reconcile. Instructing
  it to watch for something that cannot happen is the prompt-side version of the
  placebo button the composer refuses to render.

  ## What the measurements say about the wording

  From the Phase 0 probes and the three acceptance runs:

  * A steered message is acted on at the **next tool boundary** — so "reconcile
    it at the next safe boundary" describes what actually happens rather than
    asking for something the harness cannot do.
  * Injecting *before* a tool call did **not** stop that call from starting: the
    model had already committed. So "do not repeat an external side effect that
    already completed" is aimed at a real hazard, not a hypothetical one.
  * Nothing here can reach a model mid-inference, and the contract deliberately
    never implies it can.

  The final line matters as much as the rest. An earlier draft of this feature
  considered having the model poll a Buster Claw inbox; that was rejected
  because it spends tokens, adds latency, and can still be forgotten. A model
  that *waits* for a possible follow-up would reintroduce the same cost through
  the prompt instead of the tool surface.
  """

  @contract """
  The operator may send additional user messages while you are working. Treat a \
  new live message as the latest statement of intent. Reconcile it at the next \
  safe boundary before beginning another substantial or irreversible step. \
  Briefly acknowledge a material redirection. Do not repeat an external side \
  effect that already completed, and ask when the new instruction conflicts with \
  a completed action. Keep working normally when no message is present; never \
  wait or poll for a possible follow-up.\
  """

  @separator "\n\n---\n\n"

  @doc "The contract text on its own."
  @spec text() :: String.t()
  def text, do: @contract

  @doc """
  True when `capabilities` describes a transport that can deliver into a running
  turn — the only situation in which the contract is true.
  """
  @spec apply?(map()) :: boolean()
  def apply?(%{modes: modes}), do: :steer in modes
  def apply?(_capabilities), do: false

  @doc """
  A conversation's own guide with the contract appended, for a steerable
  transport.

  `guide` is the per-conversation system-prompt addendum (the homepage chat's
  SVG vocabulary, Trading's profile) and may be `nil`. Returns `nil` only when
  there is nothing at all to say, so a caller can omit the field entirely rather
  than sending an empty string.
  """
  @spec compose(String.t() | nil, boolean()) :: String.t() | nil
  def compose(guide, steerable?)

  def compose(nil, true), do: @contract
  def compose("", true), do: @contract
  def compose(guide, true), do: guide <> @separator <> @contract

  # Not steerable: the conversation's own guide, unchanged. The contract would
  # be describing a mechanism this transport does not have.
  def compose(nil, false), do: nil
  def compose("", false), do: nil
  def compose(guide, false), do: guide
end
