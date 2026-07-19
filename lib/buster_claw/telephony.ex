defmodule BusterClaw.Telephony do
  @moduledoc """
  BusterPhone's local ledger: voicemails, SMS threads, and calls mirrored into
  SQLite. The Message Machine panel (`PhoneLive`) reads everything through this
  context.

  Inbound voicemail and SMS arrive through signed Supabase Edge Functions and
  the durable relay drain. Outbound SMS uses Twilio's Messages API, but remains
  disabled until the operator explicitly enables the kill switch after the
  Messaging Service and A2P registration are ready.
  """

  import Ecto.Query

  alias BusterClaw.Repo

  alias BusterClaw.Telephony.Event
  alias BusterClaw.Telephony.Twilio
  alias BusterClaw.TrustedNumbers

  @topic "telephony"

  def subscribe do
    Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)
  end

  @doc """
  Persist one phone event and broadcast it. Inbound events are observed by
  Sentinel as `:untrusted_ingest` — a stranger's voice or text is untrusted
  input, same posture as email bodies. Pass `observe: false` to skip (seeds,
  backfills of already-observed events).
  """
  def record_event(attrs, opts \\ []) do
    result =
      %Event{}
      |> Event.changeset(attrs)
      |> Repo.insert()

    with {:ok, event} <- result do
      if event.direction == "inbound" and Keyword.get(opts, :observe, true) do
        BusterClaw.Sentinel.observe(
          :untrusted_ingest,
          "#{String.capitalize(event.kind)} from #{event.from_number}",
          %{kind: event.kind, from: event.from_number, twilio_sid: event.twilio_sid}
        )
      end

      broadcast({:telephony_event, event})
      {:ok, event}
    end
  end

  @doc "Send and persist one SMS, subject to the configured recipient/day cap."
  def send_sms(to, body, opts \\ []) do
    with {:ok, recipient} <- normalize_recipient(to),
         {:ok, body} <- validate_sms_body(body) do
      :global.trans({__MODULE__, {:sms_send, recipient}}, fn ->
        deliver_sms(recipient, body, opts)
      end)
    end
  end

  @doc "Count locally-persisted outbound SMS to one recipient since 00:00 UTC."
  def sent_today_to(recipient) do
    start_of_day = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

    Event
    |> where(
      [event],
      event.kind == "sms" and event.direction == "outbound" and
        event.to_number == ^recipient and event.occurred_at >= ^start_of_day
    )
    |> Repo.aggregate(:count)
  end

  @doc "Whether the latest inbound SMS consent event for a number is an opt-out."
  def sms_opted_out?(recipient) do
    Event
    |> where(
      [event],
      event.kind == "sms" and event.direction == "inbound" and
        event.from_number == ^recipient
    )
    |> order_by([event], desc: event.occurred_at, desc: event.id)
    |> Repo.all()
    |> Enum.reduce_while(false, fn event, _state ->
      case sms_consent_event(event) do
        :opt_out -> {:halt, true}
        :opt_in -> {:halt, false}
        :none -> {:cont, false}
      end
    end)
  end

  defp deliver_sms(recipient, body, opts) do
    cap = sms_daily_cap(opts)

    cond do
      sms_opted_out?(recipient) ->
        {:error, :recipient_opted_out}

      sent_today_to(recipient) >= cap ->
        {:error, {:sms_daily_cap_reached, cap}}

      true ->
        with {:ok, receipt} <- Twilio.send_sms(recipient, body, opts) do
          persist_outbound_sms(recipient, body, receipt)
        end
    end
  end

  defp sms_consent_event(%Event{metadata: metadata, body: body}) do
    type = metadata && (metadata["opt_out_type"] || metadata[:opt_out_type])
    keyword = type || body

    case keyword |> to_string() |> String.trim() |> String.upcase() do
      value when value in ~w(STOP STOPALL UNSUBSCRIBE CANCEL END QUIT) -> :opt_out
      value when value in ~w(START UNSTOP) -> :opt_in
      _ -> :none
    end
  end

  defp persist_outbound_sms(recipient, body, receipt) do
    attrs = %{
      direction: "outbound",
      kind: "sms",
      from_number: receipt.from || our_number() || receipt.messaging_service_sid,
      to_number: recipient,
      body: body,
      twilio_sid: receipt.sid,
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second),
      metadata: %{
        "twilio_status" => receipt.status,
        "messaging_service_sid" => receipt.messaging_service_sid
      }
    }

    case record_event(attrs, observe: false) do
      {:ok, event} ->
        observe_sms_send(recipient, receipt, true)

        {:ok,
         %{
           id: event.id,
           sent: true,
           persisted: true,
           to: recipient,
           twilio_sid: receipt.sid,
           status: receipt.status
         }}

      {:error, changeset} ->
        # Twilio has already accepted the message. Report partial success so a
        # caller does not blindly retry and create a duplicate delivery.
        observe_sms_send(recipient, receipt, false)

        {:ok,
         %{
           sent: true,
           persisted: false,
           to: recipient,
           twilio_sid: receipt.sid,
           status: receipt.status,
           persistence_error: inspect(changeset.errors)
         }}
    end
  end

  defp observe_sms_send(recipient, receipt, persisted?) do
    BusterClaw.Sentinel.observe(
      :outbound_send,
      "SMS sent to #{recipient}",
      %{
        kind: "sms",
        to: recipient,
        twilio_sid: receipt.sid,
        status: receipt.status,
        persisted: persisted?
      }
    )
  end

  defp normalize_recipient(raw) do
    case TrustedNumbers.normalize(raw) do
      {:ok, recipient} -> {:ok, recipient}
      :error -> {:error, :invalid_recipient}
    end
  end

  defp validate_sms_body(body) when is_binary(body) do
    cond do
      String.trim(body) == "" -> {:error, :empty_body}
      String.length(body) > 1600 -> {:error, :body_too_long}
      true -> {:ok, body}
    end
  end

  defp validate_sms_body(_body), do: {:error, :invalid_body}

  defp sms_daily_cap(opts) do
    case Keyword.get(
           opts,
           :daily_cap,
           Application.get_env(:buster_claw, :sms_daily_recipient_cap, 20)
         ) do
      cap when is_integer(cap) and cap > 0 -> cap
      _ -> 20
    end
  end

  # --- cost back-fill (VOICEMAIL_COST_ROADMAP.md) ---
  # Twilio prices lag, so cost is a retryable pass: fetch what's settled now, keep
  # the row unfinalized (cost_synced_at nil) until every component prices, and
  # re-run. Only voicemails carrying a CallSid can be priced.

  @doc """
  Voicemails not yet finally priced (`cost_synced_at` nil), oldest first — the
  back-fill work list. Every drained voicemail has a `twilio_sid` (RecordingSid),
  which is all `refresh_cost/2` needs.
  """
  def unpriced_voicemails(limit \\ 25) do
    from(e in Event,
      where: e.kind == "voicemail" and is_nil(e.cost_synced_at),
      order_by: [asc: e.occurred_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Fetch and store one event's Twilio cost. Sets `cost_micros` to the settled
  total (provisional until final) and `cost_synced_at` only once every component
  has priced, so an unfinal row keeps getting retried. `{:ok, event}` |
  `{:error, :no_sids | reason}`.
  """
  def refresh_cost(%Event{} = event, opts \\ []) do
    case fetch_cost(event, opts) do
      {:ok, cost} -> apply_cost(event, cost)
      {:error, _} = error -> error
    end
  end

  # Pure Twilio fetch — no DB writes, safe to run inside a task.
  defp fetch_cost(%Event{} = event, opts) do
    with %{} = sids <- cost_sids(event),
         {:ok, cost} <- Twilio.cost_for(sids, opts) do
      {:ok, cost}
    else
      :no_sids -> {:error, :no_sids}
      {:error, _} = error -> error
    end
  end

  @doc """
  Back-fill every unpriced voicemail (no-op when Twilio isn't configured). Cheap:
  touches only rows still missing a final price. Called from the drain tick.

  Broadcasts a single `:telephony_costs_updated` after the batch rather than one
  event per priced row — a full drain tick can price 25 rows, and 25 broadcasts
  meant 25 full reloads in every subscribed LiveView.

  The Twilio fetches run concurrently with a hard timeout (the drain is a single
  GenServer — 25 sequential calls against a slow API used to stall the whole
  tick); the row updates stay on this process (SQLite is single-writer).
  """
  @cost_concurrency 4
  @cost_timeout_ms 15_000

  def refresh_unpriced_costs(opts \\ []) do
    if Twilio.configured?() do
      events = unpriced_voicemails()

      priced =
        events
        |> Task.async_stream(&fetch_cost(&1, opts),
          max_concurrency: @cost_concurrency,
          timeout: @cost_timeout_ms,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Enum.zip(events)
        |> Enum.count(fn
          {{:ok, {:ok, cost}}, event} -> match?({:ok, _}, apply_cost(event, cost))
          _ -> false
        end)

      if priced > 0, do: broadcast(:telephony_costs_updated)
    end

    :ok
  end

  defp cost_sids(%Event{twilio_sid: rec}) when is_binary(rec), do: %{recording_sid: rec}
  defp cost_sids(_event), do: :no_sids

  defp apply_cost(event, cost) do
    synced_at = if cost.final?, do: DateTime.utc_now() |> DateTime.truncate(:second)

    breakdown =
      Map.new(cost.breakdown, fn {part, micros} ->
        {to_string(part), if(micros == :pending, do: nil, else: micros)}
      end)

    metadata = Map.put(event.metadata || %{}, "cost_breakdown", breakdown)

    event
    |> Event.changeset(%{
      cost_micros: cost.total_micros,
      cost_currency: cost.currency,
      cost_synced_at: synced_at,
      metadata: metadata
    })
    |> Repo.update()
  end

  def get_event!(id), do: Repo.get!(Event, id) |> Repo.preload(:document)

  @doc "Fetch one event, or nil. The command surface uses this — a bad id is a
  `not_found` result, not a crash."
  def get_event(id) do
    case Repo.get(Event, id) do
      nil -> nil
      event -> Repo.preload(event, :document)
    end
  end

  def list_events(opts \\ []) do
    Event
    |> scope_kind(opts[:kind])
    |> scope_unheard(opts[:unheard_only])
    |> order_by([e], desc: e.occurred_at, desc: e.id)
    |> maybe_limit(opts[:limit])
    |> Repo.all()
  end

  defp scope_kind(query, nil), do: query
  defp scope_kind(query, kind), do: where(query, [e], e.kind == ^kind)

  # "Unheard" is a voicemail concept — the blinking light. A call or a text has
  # nothing to hear, so restricting to unheard also restricts to voicemail.
  defp scope_unheard(query, true),
    do: where(query, [e], e.kind == "voicemail" and is_nil(e.heard_at))

  defp scope_unheard(query, _), do: query

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, n), do: limit(query, ^n)

  @doc """
  The BusterPhone number — the number inbound callers dialed, read from the most
  recent inbound event's `to_number`. It is not configured anywhere; it's learned
  from traffic, so this is `nil` until the first call/voicemail lands.
  """
  def our_number do
    Event
    |> where([e], e.direction == "inbound" and not is_nil(e.to_number))
    |> order_by([e], desc: e.occurred_at, desc: e.id)
    |> limit(1)
    |> select([e], e.to_number)
    |> Repo.one()
  end

  @doc "Voicemails with no `heard_at` — the blinking light."
  def unheard_count do
    Event
    |> where([e], e.kind == "voicemail" and is_nil(e.heard_at))
    |> Repo.aggregate(:count)
  end

  def stats do
    counts =
      Event
      |> group_by([e], e.kind)
      |> select([e], {e.kind, count(e.id)})
      |> Repo.all()
      |> Map.new()

    # Voicemail spend: the total (provisional + final) in micro-USD, and how many
    # voicemails are still awaiting a final price.
    {spent, pending} =
      Event
      |> where([e], e.kind == "voicemail")
      |> select(
        [e],
        {coalesce(sum(e.cost_micros), 0),
         fragment("SUM(CASE WHEN ? IS NULL THEN 1 ELSE 0 END)", e.cost_synced_at)}
      )
      |> Repo.one() || {0, 0}

    %{
      voicemails: Map.get(counts, "voicemail", 0),
      unheard: unheard_count(),
      texts: Map.get(counts, "sms", 0),
      calls: Map.get(counts, "call", 0),
      spent_micros: spent || 0,
      pending_cost: pending || 0
    }
  end

  @doc """
  SMS grouped by the external number, newest thread first. Message volume is
  personal-phone scale, so grouping happens in Elixir rather than SQL.
  """
  def sms_threads do
    list_events(kind: "sms")
    |> Enum.group_by(&counterparty/1)
    |> Enum.map(fn {number, events} ->
      latest = Enum.max_by(events, & &1.occurred_at, DateTime)

      %{
        number: number,
        latest: latest,
        count: length(events)
      }
    end)
    |> Enum.sort_by(& &1.latest.occurred_at, {:desc, DateTime})
  end

  @doc "All SMS with one number, oldest first (thread reading order)."
  def thread_messages(number) do
    Event
    |> where([e], e.kind == "sms")
    |> where([e], e.from_number == ^number or e.to_number == ^number)
    |> order_by([e], asc: e.occurred_at, asc: e.id)
    |> Repo.all()
  end

  @doc "The non-Buster side of an event: sender when inbound, recipient when outbound."
  def counterparty(%Event{direction: "inbound"} = event), do: event.from_number
  def counterparty(%Event{} = event), do: event.to_number

  def mark_heard(%Event{heard_at: nil} = event) do
    result =
      event
      |> Event.changeset(%{heard_at: DateTime.utc_now(:second)})
      |> Repo.update()

    with {:ok, updated} <- result do
      broadcast({:telephony_event, updated})
      {:ok, updated}
    end
  end

  def mark_heard(%Event{} = event), do: {:ok, event}

  ## Contacts live in `BusterClaw.Contacts`.
  #
  # They used to live here, phone-only, alongside a `trusted` column that nothing
  # read. A contact spans both channels now — the person who emails you is the
  # person who calls you — so the list is not telephony's to own, and trust is
  # derived from the markdown policy files rather than stored. `Contacts.by_phone/0`
  # is what the Message Machine log names its rows from.

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, message)
  end
end
