defmodule BusterClawWeb.Phone.CallFlow do
  @moduledoc """
  The two-step outbound call, as socket transitions.

  Extracted from `BusterClawWeb.PhoneComponent` rather than living beside its log
  and contact handling, because it shares nothing with them: it never touches the
  event list, the filter, the selected thread or the contact form. What it knows
  is a number, whether the preconditions pass, and whether the operator has said
  yes twice.

  The component keeps the `handle_event/3` clauses — those cannot be imported,
  and a socket-facing module pretending to be a LiveComponent would be worse than
  three lines of dispatch.

  ## Where the authority lives

  Nowhere here. `Telephony.place_call/2` re-checks every precondition this module
  checked, plus the per-recipient cap and the opt-out list it cannot see from a
  socket. That is the point: the button is a convenience, and a caller who skips
  it — an agent running `phone_call`, or anything that can speak to this
  component over its socket — meets the same refusals. This module exists to make
  the *reason* visible before the click, not to be the thing that decides.
  """

  import Phoenix.Component, only: [assign: 2]

  alias BusterClaw.Telephony
  alias BusterClaw.Telephony.Twilio
  alias BusterClaw.TrustedNumbers
  alias BusterClawWeb.Phone.CallAction

  @doc """
  The initial (and re-read) state of the switch and the number the far end sees.

  Read from `Twilio.voice_ready/0` rather than recomputed: the button's disabled
  state and `place_call/2`'s refusal have to be the same conditions, or the tab
  offers a call the module will not place.
  """
  def load_readiness(socket) do
    assign(socket, voice_ready: Twilio.voice_ready(), caller_id: Twilio.caller_id())
  end

  @doc "Blank slate — no pending call, no leftover verdict from the last one."
  def reset(socket) do
    assign(socket, pending_call: nil, call_error: nil, call_notice: nil)
  end

  @doc """
  Step one. This rings nobody.

  It normalizes the number, **re-reads the preconditions** — credentials can move
  in the Clinch while this tab sits open, and the switch state rendered at mount
  may be minutes old — and shows what is about to happen.
  """
  def prompt(socket, number) do
    socket = load_readiness(socket)

    case {socket.assigns.voice_ready, TrustedNumbers.normalize(number)} do
      {:ok, {:ok, recipient}} ->
        assign(socket, pending_call: recipient, call_error: nil, call_notice: nil)

      {:ok, :error} ->
        refused(socket, :invalid_recipient)

      {{:error, reason}, _} ->
        refused(socket, reason)
    end
  end

  @doc "Step one, undone."
  def cancel(socket), do: assign(socket, pending_call: nil, call_error: nil)

  @doc """
  Step two: somebody's phone rings.

  Returns `{:placed, socket}` so the caller can reload its event list — the
  outbound row exists the moment this succeeds — or `{:refused, socket}` when
  nothing happened. A bare socket would make those two indistinguishable, and
  they are the most important distinction in this module.
  """
  def confirm(socket) do
    case socket.assigns.pending_call do
      nil ->
        {:refused, socket}

      recipient ->
        case Telephony.place_call(recipient) do
          {:ok, _result} ->
            {:placed,
             assign(socket,
               pending_call: nil,
               call_error: nil,
               call_notice: "Calling #{recipient} — your phone should ring."
             )}

          {:error, reason} ->
            {:refused, socket |> assign(pending_call: nil) |> refused(reason)}
        end
    end
  end

  defp refused(socket, reason) do
    assign(socket, call_error: CallAction.error_message(reason), call_notice: nil)
  end
end
