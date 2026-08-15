defmodule BusterClawWeb.Phone.CallAction do
  @moduledoc """
  The Call button, its confirmation, and the vocabulary of reasons it says no.

  Its own module rather than more of `Playback`, because it is a different
  responsibility: the dialpad edits a string and searches contacts, and this
  decides whether a phone rings. It also owns the only copy of the refusal
  wording, which is the part most likely to be duplicated badly — a second
  translation of `{:call_daily_cap_reached, n}` written somewhere else would drift
  the moment a tag changed.

  ## The disclosure line is still here, and it still discloses

  `LAUNCH_ROADMAP` G-37 closed by *labelling in place*: the keypad had to say on
  screen that it only searched contacts. That sentence became half-false on 08-15
  when `phone_call` shipped, so it narrowed rather than disappeared. The keypad
  still searches contacts, and when calling is switched off the line now says
  **why and names the fix** rather than reporting the feature unbuilt. A control
  that reads as finished and is not remains the thing this app may not ship; the
  fix for a disabled button was never to hide the reason in a `title`.

  ## Two clicks, on purpose

  A call is irreversible in the way a text is: it cannot be unsent and it stays
  in the other person's log. The confirmation names all three facts an operator
  needs before the first ring — who is being dialled, what number they will see,
  and that their own phone rings first — because the last one is genuinely
  surprising and looks like a bug when it is not explained.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Phone.Shared

  attr :target, :any, required: true
  attr :dialed_number, :string, required: true
  attr :selected_contact, :any, default: nil
  attr :voice_ready, :any, required: true
  attr :caller_id, :string, default: nil
  attr :pending_call, :any, default: nil
  attr :call_error, :string, default: nil
  attr :call_notice, :string, default: nil

  @doc "The keypad's disclosure line, the Call button, and the confirm step."
  def call_action(assigns) do
    ~H"""
    <div id="phone-call-action" class="mt-2">
      <p
        id="phone-keypad-purpose"
        class="px-2 font-mono text-[10px] uppercase tracking-wide text-base-content/40"
      >
        Searches your contacts · {purpose_suffix(@voice_ready)}
      </p>

      <%!-- Enabled only when the preconditions pass AND there is something to
            dial. A disabled button with the reason beside it is the pattern; a
            button that looks live and errors on click is the thing G-37 named. --%>
      <button
        :if={@dialed_number != "" and is_nil(@pending_call)}
        id="phone-dial-call"
        type="button"
        disabled={@voice_ready != :ok}
        aria-disabled={to_string(@voice_ready != :ok)}
        phx-click={@voice_ready == :ok && "call_prompt"}
        phx-target={@target}
        phx-value-number={call_target(@dialed_number, @selected_contact)}
        class={[
          "mt-2 flex h-9 w-full items-center justify-center gap-2 border-2 font-mono text-[11px] font-bold uppercase tracking-wide transition",
          if(@voice_ready == :ok,
            do:
              "border-accent bg-accent/15 text-base-content hover:bg-accent/30 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
            else: "cursor-not-allowed border-base-content/15 bg-base-100/30 text-base-content/40"
          )
        ]}
      >
        <.icon name="hero-phone" class="size-3.5" /> Call {format_dialed(@dialed_number)}
      </button>

      <div
        :if={@pending_call}
        id="phone-call-confirm"
        class="ic-glass mt-2 space-y-2 border-2 border-accent px-3 py-2"
      >
        <p class="font-mono text-xs font-bold text-base-content">
          Call {format_phone(@pending_call)}?
        </p>
        <p class="text-[11px] leading-relaxed text-base-content/70">
          <span class="font-semibold text-base-content">Your own phone rings first.</span>
          Answer it and Buster dials them, then joins the two of you. They see
          <span class="font-mono">{format_phone(@caller_id)}</span>
          — not your mobile — so a call back reaches the answering machine.
        </p>
        <div class="grid grid-cols-2 gap-2">
          <button
            id="phone-call-cancel"
            type="button"
            phx-click="call_cancel"
            phx-target={@target}
            class="flex h-8 items-center justify-center border-2 border-base-content/25 font-mono text-[11px] font-bold uppercase text-base-content/70 transition hover:bg-base-content/10"
          >
            Cancel
          </button>
          <button
            id="phone-call-confirm-place"
            type="button"
            phx-click="call_confirm"
            phx-target={@target}
            phx-disable-with="Calling…"
            class="flex h-8 items-center justify-center gap-2 border-2 border-accent bg-accent/20 font-mono text-[11px] font-bold uppercase text-base-content transition hover:bg-accent/35"
          >
            <.icon name="hero-phone" class="size-3.5" /> Place call
          </button>
        </div>
      </div>

      <p
        :if={@call_error}
        id="phone-call-error"
        class="mt-2 border-l-2 border-error px-2 py-1 font-mono text-[10px] uppercase tracking-wide text-error"
      >
        {@call_error}
      </p>

      <p
        :if={@call_notice}
        id="phone-call-notice"
        class="mt-2 border-l-2 border-accent px-2 py-1 font-mono text-[10px] uppercase tracking-wide text-base-content/70"
      >
        {@call_notice}
      </p>
    </div>
    """
  end

  # A selected contact's stored number beats the digits on the display: the
  # display is national-formatted (`select_contact_number/2` strips the country
  # code), and the stored value is the E.164 one the contact was created with.
  defp call_target(_dialed_number, %{phone: phone}) when is_binary(phone) and phone != "",
    do: phone

  defp call_target(dialed_number, _contact), do: dialed_number

  defp purpose_suffix(:ok), do: "Call rings your phone first"
  defp purpose_suffix({:error, reason}), do: purpose_suffix(reason)

  defp purpose_suffix(:voice_disabled), do: "calling off · set BUSTER_CLAW_VOICE_ENABLED=true"
  defp purpose_suffix(:not_configured), do: "calling off · set TWILIO_ACCOUNT_SID + auth token"
  defp purpose_suffix(:missing_phone_number), do: "calling off · set TWILIO_PHONE_NUMBER"
  defp purpose_suffix(:missing_operator_number), do: "calling off · set OPERATOR_PHONE_NUMBER"
  defp purpose_suffix(_other), do: "calling off"

  @doc """
  One tagged refusal as a sentence the operator can act on.

  Public so the component that handles the click can call it; kept here so the
  wording lives beside the button that shows it. Every branch names what to do
  next, because a phone that says only "refused" is a phone you cannot fix.
  """
  def error_message(:recipient_opted_out),
    do: "That number replied STOP to a text. Buster won't call it either."

  def error_message({:call_daily_cap_reached, cap}),
    do: "Daily limit reached for that number (#{cap} calls). It resets at 00:00 UTC."

  def error_message(:cannot_dial_own_number),
    do: "That is this app's own number — the call would reach its answering machine."

  def error_message(:cannot_dial_yourself),
    do: "That is the phone this call would ring first. It cannot also be the far end."

  def error_message(:invalid_recipient), do: "That is not a number Buster can dial."
  def error_message(:voice_disabled), do: purpose_suffix(:voice_disabled)
  def error_message(:not_configured), do: purpose_suffix(:not_configured)
  def error_message(:missing_phone_number), do: purpose_suffix(:missing_phone_number)
  def error_message(:missing_operator_number), do: purpose_suffix(:missing_operator_number)

  def error_message({:twilio_status, status, _body}),
    do: "Twilio refused the call (HTTP #{status}). Check the number and the account."

  def error_message({:twilio_request_failed, _reason}),
    do: "Could not reach Twilio. Check the network and try again."

  # The one refusal that is not a refusal: somebody's phone is ringing.
  def error_message({:call_placed_but_not_persisted, _reason}),
    do: "The call was placed, but it could not be filed locally. Check the security feed."

  def error_message(other), do: "Call refused: #{inspect(other)}"
end
