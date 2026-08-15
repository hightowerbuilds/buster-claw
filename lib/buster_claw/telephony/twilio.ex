defmodule BusterClaw.Telephony.Twilio do
  @moduledoc """
  Twilio REST client for voicemail billing and outbound SMS
  (`VOICEMAIL_COST_ROADMAP.md`). Twilio never sends price in a webhook; it lives
  on the REST resources and populates **asynchronously** (null right after the
  call, settled a bit later), so cost is a retryable back-fill, not a
  capture-at-drain value.

  `cost_for/2` sums the three components of a voicemail's cost from just its
  **RecordingSid** (which every drained voicemail already has as `twilio_sid`):

  - the **recording** — `Recordings/{RecordingSid}` (also yields the parent
    `call_sid`, so nothing extra needs storing),
  - the inbound **call leg** — `Calls/{CallSid}`,
  - the **transcription(s)** — `Recordings/{RecordingSid}/Transcriptions` (a list;
    prices summed).

  Prices are micro-USD integers (`$0.25 = 250_000`) to avoid float drift. A
  component whose price hasn't settled is `:pending`; `final?` is true only when
  every component has settled, which is the signal to stop back-filling a row.

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

  defp voice_ready do
    cond do
      not voice_enabled?() -> {:error, :voice_disabled}
      not configured?() -> {:error, :not_configured}
      not present?(phone_number()) -> {:error, :missing_phone_number}
      not present?(operator_number()) -> {:error, :missing_operator_number}
      true -> :ok
    end
  end

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
  Total voicemail cost from its RecordingSid (a map with `:recording_sid`).

  Returns `{:ok, %{total_micros, currency, final?, breakdown}}` where `breakdown`
  is `%{call, recording, transcription}` (each an integer micros or `:pending`),
  or `{:error, reason}`. `total_micros` sums only the settled components, so a
  non-`final?` result is a provisional floor, not the finished number.
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

  def cost_for(_sids, _opts), do: {:error, :missing_sids}

  # The call leg, via the CallSid the Recording resource reports. A recording
  # with no parent call (shouldn't happen for a voicemail) has no call cost.
  defp call_resource(call_sid, opts) when is_binary(call_sid),
    do: resource(["Calls", call_sid <> ".json"], opts)

  defp call_resource(_nil, _opts), do: {:ok, %{}}

  # A single price value → the resource JSON. 404 is surfaced so a row pointing at
  # a deleted resource can stop being retried by the caller.
  defp resource(segments, opts) do
    path = Enum.join(["/2010-04-01/Accounts", account_sid() | segments], "/")

    request(opts)
    |> Req.merge(url: path)
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
