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
  alias BusterClaw.Telephony.Contact
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

  def list_events(opts \\ []) do
    Event
    |> scope_kind(opts[:kind])
    |> order_by([e], desc: e.occurred_at, desc: e.id)
    |> maybe_limit(opts[:limit])
    |> Repo.all()
  end

  defp scope_kind(query, nil), do: query
  defp scope_kind(query, kind), do: where(query, [e], e.kind == ^kind)

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

  ## Contacts — names + shaderfaces for numbers; also the future SMS trust gate.

  def list_contacts do
    Contact
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  def get_contact!(id), do: Repo.get!(Contact, id)

  def create_contact(attrs) do
    %Contact{}
    |> Contact.changeset(attrs)
    |> Repo.insert()
    |> tap_broadcast_contacts()
  end

  def update_contact(%Contact{} = contact, attrs) do
    contact
    |> Contact.changeset(attrs)
    |> Repo.update()
    |> tap_broadcast_contacts()
  end

  def delete_contact(%Contact{} = contact) do
    contact
    |> Repo.delete()
    |> tap_broadcast_contacts()
  end

  @doc "Name lookup map for the log: %{\"+1503...\" => %Contact{}}."
  def contacts_by_number do
    Map.new(list_contacts(), &{&1.number, &1})
  end

  defp tap_broadcast_contacts({:ok, _} = result) do
    broadcast(:telephony_contacts_changed)
    result
  end

  defp tap_broadcast_contacts(result), do: result

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, message)
  end
end
