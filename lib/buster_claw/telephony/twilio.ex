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
  """

  @api "https://api.twilio.com"

  @doc "True when both the Twilio Account SID and Auth Token are configured."
  def configured? do
    present?(account_sid()) and present?(auth_token())
  end

  @doc "True only when credentials, Messaging Service, and the SMS kill switch are set."
  def sms_configured? do
    configured?() and present?(messaging_service_sid()) and sms_enabled?()
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

  defp account_sid, do: get_in(config(), [:account_sid])
  defp auth_token, do: get_in(config(), [:auth_token])
  def messaging_service_sid, do: get_in(config(), [:messaging_service_sid])
  defp sms_enabled?, do: get_in(config(), [:sms_enabled]) == true
  defp config, do: Application.get_env(:buster_claw, :twilio, %{})

  defp present?(value), do: is_binary(value) and value != ""
end
