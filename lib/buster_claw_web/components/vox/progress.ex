defmodule BusterClawWeb.Vox.Progress do
  @moduledoc """
  The "this is being made right now" chip, for the three places on Vox2B where
  the operator waits on the speech engine: a typed clip, the phone greeting, and
  the whole chime set.

  ## Why a timer and not a spinner

  The operator asked for "a little spinner of some kind", and a bare spinner is
  the wrong instrument for this particular wait. `Voice.Renderer` broadcasts
  exactly one message per job — `{:voice_render, key, result}`, at the end — so
  there is no percentage to show and never will be without the engine reporting
  one. And these waits are long: VoxCPM's measured real-time factor on the
  operator's CPU means a short line is *minutes*. A spinner that has been turning
  for four minutes says exactly what it said at four seconds.

  So the chip is a pulse **and** a running clock. The pulse answers "is it alive",
  the clock answers "how long has this been going", and the second question is
  the one you actually have at minute three.

  ## Why it reuses the chat's hook

  `ThinkingTimer` (`assets/js/hooks/chat.js`) already ticks a label client-side
  without a server round-trip per second. Copying it here would have meant two
  timers drifting apart the first time either was touched, which is the argument
  `voice_recorder.js` already settled for the recorder: parameterise the hook,
  do not fork it. It takes `data-label-running` and `data-elapsed-ms` for us and
  keeps its own defaults for the chat.

  ## `since`, and the bug it exists to prevent

  `since` is a `System.monotonic_time(:millisecond)` reading from when the work
  *started*, and the elapsed figure is computed here, on the server, at render
  time. The hook adds its own client-side delta on top of that.

  That indirection is load-bearing on the homepage. The Vox2B tab is rendered
  behind `:if={@home_tab == "vox"}`, so switching to Chat and back **destroys and
  remounts this element**. A purely client-side timer would restart from zero and
  report "0.2s" into a four-minute render — worse than no number, because it
  reads as authoritative.
  """
  use BusterClawWeb, :html

  @doc """
  A pulsing chip with a live elapsed clock.

  `since` is the monotonic millisecond reading from when the work started; the
  offset handed to the hook is computed from it at render time.
  """
  attr :id, :string, required: true
  attr :since, :integer, required: true
  attr :label, :string, default: "Making"
  attr :class, :any, default: nil

  def chip(assigns) do
    assigns =
      assign(assigns, :elapsed_ms, max(0, System.monotonic_time(:millisecond) - assigns.since))

    ~H"""
    <span
      id={@id}
      phx-hook="ThinkingTimer"
      data-state="running"
      data-label-running={@label}
      data-elapsed-ms={@elapsed_ms}
      class={[
        "inline-flex shrink-0 items-center gap-1.5 font-mono text-[0.6875rem] uppercase tracking-wide text-primary",
        @class
      ]}
    >
      <span class="size-1.5 shrink-0 animate-pulse rounded-full bg-primary" aria-hidden="true"></span>
      <%!-- The hook replaces this text on its first tick. It is not a
            placeholder: a render that lands between mount and the first
            interval, or a browser with JS disabled, still says what is
            happening rather than showing a bare dot. --%>
      <span data-thinking-label>{@label}…</span>
    </span>
    """
  end
end
