defmodule BusterClaw.Telephony do
  @moduledoc """
  BusterPhone's local ledger: voicemails, SMS threads, and calls mirrored into
  SQLite. The Message Machine panel (`PhoneLive`) reads everything through this
  context.

  ## What is actually wired

  **Inbound voicemail only.** Events arrive one way — Twilio → the Supabase edge
  function → the relay table → `Telephony.Drain` → `record_event/2`. That path is
  complete.

  **There is no outbound path.** No Twilio REST client exists anywhere in the
  app, and nothing calls `record_event/2` with `direction: "outbound"`. The
  schema permits `outbound`, and `sms_threads/0` will render an outbound row if
  one ever appears, but no code produces one. Inbound SMS is likewise unbuilt:
  the `sms` kind is accepted end-to-end, but only the `voice` edge function
  exists, so nothing writes an SMS row either (A2P 10DLC registration is the
  gate — see `daily-growth/roadmaps/BUSTERPHONE_ROADMAP.md`).

  Treat the outbound/SMS surfaces here as schema-ready, not working.
  """

  import Ecto.Query

  alias BusterClaw.Repo

  alias BusterClaw.Telephony.Event

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

    %{
      voicemails: Map.get(counts, "voicemail", 0),
      unheard: unheard_count(),
      texts: Map.get(counts, "sms", 0),
      calls: Map.get(counts, "call", 0)
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
