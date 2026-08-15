defmodule BusterClaw.Telephony.Twilio do
  @moduledoc """
  Twilio REST client for voicemail billing and outbound SMS
  (`VOICEMAIL_COST_ROADMAP.md`). Twilio never sends price in a webhook; it lives
  on the REST resources and populates **asynchronously** (null right after the
  call, settled a bit later), so cost is a retryable back-fill, not a
  capture-at-drain value.

  `cost_for/2` prices two things, from the single SID each row already carries.

  A **voicemail**, from its **RecordingSid** (`twilio_sid` on every drained row):

  - the **recording** — `Recordings/{RecordingSid}` (also yields the parent
    `call_sid`, so nothing extra needs storing),
  - the inbound **call leg** — `Calls/{CallSid}`,
  - the **transcription(s)** — `Recordings/{RecordingSid}/Transcriptions` (a list;
    prices summed).

  An **outbound bridged call**, from its parent **CallSid** — and this one is two
  billed legs, because `<Dial>` creates a *second* call resource with its own
  price (`Calls?ParentCallSid=`). The parent alone is roughly half the bill and
  reads as a settled number, which is the worst of both.

  Prices are micro-USD integers (`$0.25 = 250_000`) to avoid float drift. A
  component whose price hasn't settled is `:pending`; `final?` is true only when
  every component has settled, which is the signal to stop back-filling a row.
  For a call it additionally requires a **terminal status** — `price` and `status`
  are separate fields, and a priced in-flight call must not finalize at whatever
  it has cost so far.

  Creds come from app env `:twilio`, set in `config/runtime.exs`. Outbound SMS
  additionally requires a Messaging Service SID and the explicit SMS kill
  switch. `req_options` (Req.Test plugs) inject in tests.

  `send_sms/3` checks those three SMS preconditions itself, through the private
  `sms_ready` below, which names *which* one is missing. There is deliberately no
  public boolean twin of it — a `sms_configured?` was deleted 08-09 as dead. If a
  UI ever needs the boolean, it is `sms_ready() == :ok`; do not re-add a second
  copy of the conditions, which would drift out of step with the tagged errors.
  """

  alias BusterClaw.Clinch.AppKeys

  @api "https://api.twilio.com"

  @doc "True when both the Twilio Account SID and Auth Token are configured."
  def configured? do
    present?(account_sid()) and present?(auth_token())
  end

  @doc "Create one outbound SMS through the configured Twilio Messaging Service."
  def send_sms(to, body, opts \\ []) do
    with :ok <- sms_ready(),
         :ok <- validate_recipient(to),
         {:ok, body} <- validate_body(body) do
      path = "/2010-04-01/Accounts/#{account_sid()}/Messages.json"

      request(opts)
      |> Req.merge(
        url: path,
        form: [
          {"To", to},
          {"Body", body},
          {"MessagingServiceSid", messaging_service_sid()}
        ]
      )
      |> Req.post()
      |> normalize_sms_response()
    end
  end

  @doc """
  Place a bridged outbound call: ring the operator's phone, then dial `to` and
  join the two legs.

  `OUTBOUND_VOICE_ROADMAP` picked this shape over a softphone because no audio
  passes through this machine — the operator talks on their own phone and the app
  is a dialler. It also means outbound calling does not queue behind the
  `getUserMedia`-in-WKWebView question that is blocking Studio → Voice.

  ## Inline TwiML, and why there is no relay endpoint

  The roadmap's Phase 2 was a new Supabase function serving `<Dial>` TwiML, with
  a signature check, a `PUBLIC_URL_BASE`, and an opaque id so the endpoint could
  not be made to dial an arbitrary number. **None of that is built, because none
  of it is needed.** Twilio's Calls API takes a `Twiml` parameter carrying the
  document inline, so the instruction travels with the request that creates the
  call.

  That deletes the phase and the risk together: **there is no public endpoint to
  abuse**, and the number dialled cannot arrive from a callback because nothing
  calls back. It is composed here, from a value this function validated.

  Both legs present the app's own number: `From` is what the operator sees
  ringing, `callerId` is what the far end sees. A callback therefore reaches the
  answering machine rather than the operator — a property, not an oversight, and
  the one Phase 0 exists to have chosen deliberately.

  Returns `{:ok, %{call_sid, status, to}}`. Every precondition is named by
  `voice_ready/0` rather than collapsed into a boolean, for the reason
  `sms_ready/0` records: a second copy of the conditions drifts out of step with
  the tagged errors.
  """
  def place_call(to, opts \\ []) do
    with :ok <- voice_ready(),
         :ok <- validate_recipient(to),
         :ok <- refuse_self_dial(to) do
      path = "/2010-04-01/Accounts/#{account_sid()}/Calls.json"

      request(opts)
      |> Req.merge(
        url: path,
        form: [
          # Leg 1 rings the operator. Nothing dials `to` until they answer, so a
          # failure here is a call that never happened to anyone else.
          {"To", operator_number()},
          {"From", phone_number()},
          {"Twiml", bridge_twiml(to)}
        ]
      )
      |> Req.post()
      |> normalize_call_response(to)
    end
  end

  # Deliberately minimal. Anything richer — recording, AMD, whisper — is a
  # decision this roadmap listed as out of scope, and a TwiML document is the
  # wrong place to acquire features quietly.
  #
  # `to` is E.164-validated before it reaches here and contains only `+` and
  # digits, so escaping is belt-and-braces rather than load-bearing. It is here
  # anyway: the day this takes a name or a SIP URI, the escaping must already
  # exist rather than be remembered.
  defp bridge_twiml(to) do
    ~s(<Response><Dial callerId="#{xml_escape(phone_number())}">#{xml_escape(to)}</Dial></Response>)
  end

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # Dialling our own number bridges the app to its own answering machine: it
  # bills two legs, records a voicemail from the operator to themselves, and
  # looks exactly like a bug from the outside.
  defp refuse_self_dial(to) do
    cond do
      to == phone_number() -> {:error, :cannot_dial_own_number}
      to == operator_number() -> {:error, :cannot_dial_yourself}
      true -> :ok
    end
  end

  @doc """
  `:ok` when a call could be placed right now, or the tagged reason it could not.

  Public because the Phone tab's Call button needs the reason, not a boolean —
  the whole point of the disabled state is to say *which* precondition is
  missing. It is the same function `place_call/2` guards with rather than a
  second copy: this module's moduledoc records what happens when a public
  predicate is written beside the tagged errors, and a UI reading a different
  copy is exactly how a button ends up enabled for a call that cannot be placed.

  It answers only "would the preconditions pass" — not whether *this* recipient
  is dialable. Self-dial, opt-out and the daily cap are per-recipient and stay
  where they can see one.
  """
  def voice_ready do
    cond do
      not voice_enabled?() -> {:error, :voice_disabled}
      not configured?() -> {:error, :not_configured}
      not present?(phone_number()) -> {:error, :missing_phone_number}
      not present?(operator_number()) -> {:error, :missing_operator_number}
      true -> :ok
    end
  end

  @doc """
  The number the far end sees, for a UI that must state it before the first ring.

  `nil` when unset, which is one of the reasons `voice_ready/0` refuses.
  """
  def caller_id, do: phone_number()

  # `from` is reported rather than inferred later. `Telephony.our_number/0`
  # derives the app's number from inbound history, which is empty on a machine
  # that has placed a call but never received one — and this function knows the
  # answer for certain, because it just used it.
  defp normalize_call_response({:ok, %{status: status, body: body}}, to)
       when status in 200..299 do
    {:ok, %{call_sid: body["sid"], status: body["status"], to: to, from: phone_number()}}
  end

  defp normalize_call_response({:ok, %{status: status, body: body}}, _to),
    do: {:error, {:twilio_status, status, body}}

  defp normalize_call_response({:error, reason}, _to),
    do: {:error, {:twilio_request_failed, reason}}

  @doc """
  Total cost of one priced thing, from the SIDs a row already carries.

  Two shapes, because the two things bill differently:

    * `%{recording_sid: _}` — a **voicemail**: the recording, its parent call leg,
      and its transcription(s). Breakdown `%{call, recording, transcription}`.
    * `%{call_sid: _}` — an **outbound bridged call**: `<Dial>` creates a second,
      child call that Twilio prices as its own resource, so the parent alone
      under-reports by roughly half. Breakdown `%{your_leg, their_leg}` — leg one
      is the ring to the operator's own phone, leg two is the far end.

  Returns `{:ok, %{total_micros, currency, final?, breakdown}}` (each breakdown
  part an integer micros or `:pending`) or `{:error, reason}`. `total_micros` sums
  only the settled parts, so a non-`final?` result is a provisional floor, not the
  finished number.
  """
  def cost_for(sids, opts \\ [])

  def cost_for(%{recording_sid: rec_sid}, opts) when is_binary(rec_sid) do
    with {:ok, rec} <- resource(["Recordings", rec_sid <> ".json"], opts),
         {:ok, call} <- call_resource(rec["call_sid"], opts),
         {:ok, trans} <- resource(["Recordings", rec_sid, "Transcriptions.json"], opts) do
      call_p = price_micros(call["price"])
      rec_p = price_micros(rec["price"])

      trans_prices = (trans["transcriptions"] || []) |> Enum.map(&price_micros(&1["price"]))
      # An empty list is `:pending` too — the transcription callback may not have
      # landed yet, so the row isn't final and mustn't stop back-filling.
      trans_p = sum_component(trans_prices)

      # Finalize on the recording + transcription — the reliably-priced parts.
      # The inbound call leg is often `null` forever (trial-credit calls, and some
      # inbound plans don't per-call price), which would otherwise pin a row
      # "pending" and re-hit Twilio every tick. Include the call cost when it
      # prices; don't block on it.
      final? = rec_p != :pending and trans_p != :pending
      total = [call_p, rec_p, trans_p] |> Enum.map(&settled_value/1) |> Enum.sum()

      {:ok,
       %{
         total_micros: total,
         currency: call["price_unit"] || rec["price_unit"],
         final?: final?,
         breakdown: %{call: call_p, recording: rec_p, transcription: trans_p}
       }}
    end
  end

  # Two legs, and only one of them is the call we created. Summing the parent
  # alone is worse than not pricing at all — it looks like a settled number.
  def cost_for(%{call_sid: call_sid}, opts) when is_binary(call_sid) do
    with {:ok, parent} <- resource(["Calls", call_sid <> ".json"], opts),
         {:ok, children} <- child_calls(call_sid, opts) do
      your_leg = price_micros(parent["price"])
      their_leg = their_leg_price(children, parent["status"])

      # A call prices only after it ends, so an in-flight call is pending no
      # matter what the legs currently say — a `completed` parent whose child is
      # still `in-progress` would otherwise finalize at half the real cost.
      final? =
        terminal_status?(parent["status"]) and your_leg != :pending and their_leg != :pending

      {:ok,
       %{
         total_micros: [your_leg, their_leg] |> Enum.map(&settled_value/1) |> Enum.sum(),
         currency: parent["price_unit"] || currency_of(children),
         final?: final?,
         breakdown: %{your_leg: your_leg, their_leg: their_leg}
       }}
    end
  end

  def cost_for(_sids, _opts), do: {:error, :missing_sids}

  # The one place this differs from the voicemail path, and the reason it cannot
  # reuse `sum_component/1`: there an empty list means "the transcription callback
  # has not landed yet" and is `:pending`, but here it can mean the second leg
  # **never existed**. If the operator did not pick up, `<Dial>` never ran and one
  # leg is the whole bill. Treating that as pending would retry the row forever.
  defp their_leg_price([], status) do
    if terminal_status?(status), do: 0, else: :pending
  end

  defp their_leg_price(children, _status) do
    children
    |> Enum.map(&price_micros(&1["price"]))
    |> sum_component()
  end

  # Twilio's own list of states a call can no longer leave. `queued`, `ringing`
  # and `in-progress` are the ones that are not here, which is the point.
  defp terminal_status?(status),
    do: status in ~w(completed busy no-answer failed canceled)

  defp currency_of(children), do: Enum.find_value(children, & &1["price_unit"])

  # Child legs, via ParentCallSid. Twilio returns `calls: []` rather than a 404
  # for a parent with no children, but a parent that has been deleted 404s — and
  # that is not a reason to fail the whole price, since the row may still hold a
  # settled parent price.
  defp child_calls(parent_sid, opts) do
    case resource(["Calls.json"], opts, ParentCallSid: parent_sid) do
      {:ok, body} -> {:ok, body["calls"] || []}
      {:error, :not_found} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  # The call leg, via the CallSid the Recording resource reports. A recording
  # with no parent call (shouldn't happen for a voicemail) has no call cost.
  defp call_resource(call_sid, opts) when is_binary(call_sid),
    do: resource(["Calls", call_sid <> ".json"], opts)

  defp call_resource(_nil, _opts), do: {:ok, %{}}

  # A single price value → the resource JSON. 404 is surfaced so a row pointing at
  # a deleted resource can stop being retried by the caller.
  defp resource(segments, opts, params \\ []) do
    path = Enum.join(["/2010-04-01/Accounts", account_sid() | segments], "/")

    request(opts)
    |> Req.merge(url: path, params: params)
    |> Req.get()
    |> case do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:twilio_status, status, body}}
      {:error, reason} -> {:error, {:twilio_request_failed, reason}}
    end
  end

  defp normalize_sms_response({:ok, %{status: status, body: body}})
       when status in 200..299 and is_map(body) do
    case body["sid"] do
      sid when is_binary(sid) and sid != "" ->
        {:ok,
         %{
           sid: sid,
           status: body["status"],
           to: body["to"],
           from: body["from"],
           messaging_service_sid: body["messaging_service_sid"] || messaging_service_sid()
         }}

      _ ->
        {:error, :malformed_twilio_response}
    end
  end

  defp normalize_sms_response({:ok, %{status: status, body: body}}),
    do: {:error, {:twilio_status, status, body}}

  defp normalize_sms_response({:error, reason}),
    do: {:error, {:twilio_request_failed, reason}}

  defp sms_ready do
    cond do
      not sms_enabled?() -> {:error, :sms_disabled}
      not configured?() -> {:error, :not_configured}
      not present?(messaging_service_sid()) -> {:error, :missing_messaging_service}
      true -> :ok
    end
  end

  defp validate_recipient(to) when is_binary(to) do
    if Regex.match?(~r/^\+[1-9]\d{7,14}$/, to), do: :ok, else: {:error, :invalid_recipient}
  end

  defp validate_recipient(_to), do: {:error, :invalid_recipient}

  defp validate_body(body) when is_binary(body) do
    cond do
      String.trim(body) == "" -> {:error, :empty_body}
      String.length(body) > 1600 -> {:error, :body_too_long}
      true -> {:ok, body}
    end
  end

  defp validate_body(_body), do: {:error, :invalid_body}

  # Twilio price is a negative USD string ("-0.00850") once settled, or null while
  # billing is still being computed. → integer micro-USD (absolute), or :pending.
  @doc false
  def price_micros(nil), do: :pending
  def price_micros(""), do: :pending

  def price_micros(price) when is_binary(price) do
    case Float.parse(price) do
      {value, _rest} -> round(abs(value) * 1_000_000)
      :error -> :pending
    end
  end

  def price_micros(price) when is_number(price), do: round(abs(price) * 1_000_000)
  def price_micros(_other), do: :pending

  # Sum a component that may itself be several prices (transcriptions). :pending if
  # any part is unsettled OR there are no parts yet (a recording awaiting its
  # transcription callback).
  defp sum_component([]), do: :pending

  defp sum_component(prices) do
    if Enum.any?(prices, &(&1 == :pending)),
      do: :pending,
      else: Enum.sum(prices)
  end

  defp settled_value(:pending), do: 0
  defp settled_value(micros) when is_integer(micros), do: micros

  defp request(opts) do
    Req.new(
      base_url: @api,
      auth: {:basic, "#{account_sid()}:#{auth_token()}"},
      retry: false,
      receive_timeout: 30_000
    )
    |> Req.merge(Keyword.get(opts, :req_options, []))
  end

  # Live through the Clinch, env as fallback. `sms_enabled` deliberately does NOT
  # move: a kill switch you can flip from a settings screen is not the same
  # safeguard as one that needs a deliberate act outside the running app.
  defp account_sid, do: AppKeys.get("twilio_account_sid")
  defp auth_token, do: AppKeys.get("twilio_auth_token")
  defp messaging_service_sid, do: AppKeys.get("twilio_messaging_service_sid")
  defp sms_enabled?, do: get_in(config(), [:sms_enabled]) == true

  # A SECOND switch, not a reuse of the first. A text and a phone call are
  # different capabilities with different costs and different consequences, and
  # the operator may well want one without the other — outbound SMS waits on A2P
  # registration, outbound voice does not.
  defp voice_enabled?, do: get_in(config(), [:voice_enabled]) == true
  defp phone_number, do: AppKeys.get("twilio_phone_number")
  defp operator_number, do: AppKeys.get("operator_phone_number")
  defp config, do: Application.get_env(:buster_claw, :twilio, %{})

  defp present?(value), do: is_binary(value) and value != ""
end
