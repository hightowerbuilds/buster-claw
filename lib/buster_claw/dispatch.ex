defmodule BusterClaw.Dispatch do
  @moduledoc """
  Durable Dispatch queue for trusted inbound requests.

  Mailman writes queue items here. Dispatcher claims queued items, starts the
  right specialist role/session, and links the item to the resulting agent task.
  """

  import Ecto.Query

  alias BusterClaw.Dispatch.Item
  alias BusterClaw.Repo

  @topic "dispatch"
  @default_limit 50
  @attr_keys ~w(
    source
    source_account
    sender
    trusted_sender
    trusted
    gmail_message_id
    gmail_thread_id
    gmail_rfc_message_id
    subject
    request_summary
    request_body_excerpt
    recommended_agent
    recommended_role_key
    risk
    status
    strategy
    shift_id
    shift_assignment_id
    dedupe_key
    claimed_by
    claimed_at
    started_at
    finished_at
    heartbeat_at
    outcome
    notes
    metadata
  )a
  @attr_key_lookup Map.new(@attr_keys, &{Atom.to_string(&1), &1})

  def topic, do: @topic
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  def list_items(opts \\ []) do
    limit = positive_integer(opt(opts, :limit), @default_limit)

    Item
    |> maybe_where_status(present(opt(opts, :status)))
    |> maybe_where_source(present(opt(opts, :source)))
    |> maybe_where_strategy(present(opt(opts, :strategy)))
    |> order_by([item], desc: item.inserted_at, desc: item.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_queued(opts \\ []) do
    opts
    |> put_opt(:status, "queued")
    |> list_items()
  end

  @open_statuses ~w(queued claimed running)
  @in_flight_statuses ~w(claimed running)

  @doc "All currently-open items (queued/claimed/running), oldest first."
  def list_open do
    Item
    |> where([item], item.status in @open_statuses)
    |> order_by([item], asc: item.inserted_at, asc: item.id)
    |> Repo.all()
  end

  @doc """
  True if ANY open item (queued/claimed/running) is not explicitly trusted.

  A cheap EXISTS probe for the Dispatcher's fail-closed provenance gate: it must
  weigh the WHOLE open pool, never a bounded newest-first sample, or an older
  untrusted item beyond the sample window would be invisible and a run could get
  the trusted token while an untrusted item is queued. A `nil` `trusted` counts
  as untrusted (fail closed).
  """
  def any_untrusted_open? do
    from(item in Item,
      where: item.status in @open_statuses,
      where: is_nil(item.trusted) or item.trusted == false
    )
    |> Repo.exists?()
  end

  @doc """
  Return orphaned in-flight items (`claimed`/`running`) to the `queued` pool and
  clear their claim fields. Called on boot so a hard restart that left no session
  owning an item doesn't strand it. Returns the count reset.
  """
  def reclaim_orphans do
    {count, _} =
      from(item in Item, where: item.status in @in_flight_statuses)
      |> Repo.update_all(
        set: [
          status: "queued",
          claimed_by: nil,
          claimed_at: nil,
          started_at: nil,
          heartbeat_at: nil,
          updated_at: timestamp()
        ]
      )

    count
  end

  def get_item!(id), do: Repo.get!(Item, id)
  def get_item(id), do: Repo.get(Item, id)

  def enqueue(attrs) do
    attrs =
      attrs
      |> normalize_attrs()
      |> put_new(:status, "queued")
      |> put_generated_dedupe_key()

    %Item{}
    |> Item.changeset(attrs)
    |> Repo.insert()
    |> tap_broadcast(:dispatch_item_queued)
  end

  def enqueue_gmail(account, message, attrs \\ %{}) do
    attrs =
      attrs
      |> normalize_attrs()
      |> Map.merge(%{
        source: "gmail",
        source_account: value(account, :email),
        sender: value(message, :from),
        gmail_message_id: value(message, :id),
        gmail_thread_id: value(message, :thread_id),
        gmail_rfc_message_id: value(message, :message_id_header),
        subject: value(message, :subject),
        request_body_excerpt: excerpt(value(message, :body_text) || value(message, :snippet))
      })
      |> put_new(:dedupe_key, gmail_dedupe_key(value(message, :id)))

    enqueue(attrs)
  end

  @doc """
  Enqueue a voicemail as follow-through work.

  Only ever called for a **trusted caller** (see `BusterClaw.TrustedNumbers`) —
  a stranger's voicemail is recorded and playable but never reaches the queue.
  The dedupe key is the Twilio SID, which is the voicemail's natural identity, so
  a re-drained row (crash between the local insert and the remote ack) collapses
  onto the existing item instead of queueing the same message twice.
  """
  def enqueue_voicemail(event, attrs \\ %{}) do
    from = value(event, :from_number)

    attrs =
      attrs
      |> normalize_attrs()
      |> Map.merge(%{
        source: "voicemail",
        sender: from,
        subject: "Voicemail from #{from || "unknown"}",
        request_body_excerpt: excerpt(value(event, :transcript))
      })
      |> put_new(:dedupe_key, voicemail_dedupe_key(value(event, :twilio_sid)))

    enqueue(attrs)
  end

  @doc "Enqueue a trusted inbound SMS as follow-through work."
  def enqueue_sms(event, attrs \\ %{}) do
    from = value(event, :from_number)

    attrs =
      attrs
      |> normalize_attrs()
      |> Map.merge(%{
        source: "sms",
        sender: from,
        subject: "Text from #{from || "unknown"}",
        request_body_excerpt: excerpt(value(event, :body))
      })
      |> put_new(:dedupe_key, sms_dedupe_key(value(event, :twilio_sid)))

    enqueue(attrs)
  end

  def update_item(%Item{} = item, attrs) do
    item
    |> Item.changeset(normalize_attrs(attrs))
    |> Repo.update()
    |> tap_broadcast(:dispatch_item_updated)
  end

  def claim_next(claimed_by, opts \\ []) do
    now = timestamp()

    query =
      Item
      |> where([item], item.status == "queued")
      # Swarm-strategy items are owned by the coordinator path — the generic
      # agent-pulls-queue claim only ever takes "single" items.
      |> where([item], item.strategy == "single")
      |> maybe_where_source(present(opt(opts, :source)))
      |> maybe_where_role(present(opt(opts, :role)))
      |> order_by([item], asc: item.inserted_at, asc: item.id)
      |> limit(1)

    case Repo.one(query) do
      nil ->
        {:error, :empty}

      %Item{id: id} ->
        {count, _} =
          from(item in Item, where: item.id == ^id and item.status == "queued")
          |> Repo.update_all(
            set: [
              status: "claimed",
              claimed_by: present(claimed_by) || "dispatcher",
              claimed_at: now,
              updated_at: now
            ]
          )

        case count do
          1 ->
            item = get_item!(id)
            broadcast(:dispatch_item_claimed, item)
            {:ok, item}

          _ ->
            {:error, :not_claimable}
        end
    end
  end

  def mark_running(%Item{} = item, attrs \\ %{}) do
    now = timestamp()

    item
    |> update_item(
      attrs
      |> normalize_attrs()
      |> Map.merge(%{status: "running", started_at: now, heartbeat_at: now})
    )
    |> tap_event(:dispatch_item_running)
  end

  def heartbeat(%Item{} = item), do: update_item(item, %{heartbeat_at: timestamp()})

  @doc """
  Set a queued item's execution strategy (`"single"` | `"swarm"`). Only a still-
  queued item may be re-targeted; once claimed/running the path is locked in.
  """
  def set_strategy(%Item{status: "queued"} = item, strategy)
      when strategy in ["single", "swarm"],
      do: update_item(item, %{strategy: strategy})

  def set_strategy(%Item{}, strategy) when strategy in ["single", "swarm"],
    do: {:error, :not_queued}

  def set_strategy(%Item{}, _strategy), do: {:error, :bad_strategy}

  def finish(item, status, attrs \\ [])

  def finish(%Item{} = item, status, attrs) when status in ["done", "failed", "blocked"] do
    item
    |> update_item(
      attrs
      |> normalize_attrs()
      |> Map.merge(%{status: status, finished_at: timestamp()})
    )
    |> tap_event(:dispatch_item_finished)
  end

  def finish(%Item{} = _item, _status, _attrs), do: {:error, :bad_status}

  defp maybe_where_status(query, nil), do: query
  defp maybe_where_status(query, status), do: where(query, [item], item.status == ^status)

  defp maybe_where_source(query, nil), do: query
  defp maybe_where_source(query, source), do: where(query, [item], item.source == ^source)

  defp maybe_where_strategy(query, nil), do: query
  defp maybe_where_strategy(query, strategy), do: where(query, [item], item.strategy == ^strategy)

  defp maybe_where_role(query, nil), do: query

  defp maybe_where_role(query, role),
    do: where(query, [item], item.recommended_role_key == ^role)

  defp put_generated_dedupe_key(attrs) do
    cond do
      present(Map.get(attrs, :dedupe_key)) ->
        attrs

      Map.get(attrs, :source) == "gmail" and present(Map.get(attrs, :gmail_message_id)) ->
        Map.put(attrs, :dedupe_key, gmail_dedupe_key(Map.get(attrs, :gmail_message_id)))

      true ->
        # Non-Gmail sources (e.g. a manually-enqueued item) have no natural dedupe
        # identity, so mint a unique key — each such enqueue is a distinct item.
        Map.put(attrs, :dedupe_key, generated_dedupe_key(Map.get(attrs, :source)))
    end
  end

  defp generated_dedupe_key(source) do
    prefix = present(source) || "item"
    "#{prefix}:#{System.unique_integer([:positive])}:#{System.os_time(:millisecond)}"
  end

  defp gmail_dedupe_key(nil), do: nil
  defp gmail_dedupe_key(message_id), do: "gmail:#{message_id}"

  defp voicemail_dedupe_key(nil), do: nil
  defp voicemail_dedupe_key(twilio_sid), do: "voicemail:#{twilio_sid}"

  defp sms_dedupe_key(nil), do: nil
  defp sms_dedupe_key(twilio_sid), do: "sms:#{twilio_sid}"

  defp normalize_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        if key in @attr_keys, do: Map.put(acc, key, value), else: acc

      {key, value}, acc when is_binary(key) ->
        case Map.fetch(@attr_key_lookup, key) do
          {:ok, atom_key} -> Map.put(acc, atom_key, value)
          :error -> acc
        end

      _entry, acc ->
        acc
    end)
  end

  defp normalize_attrs(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalize_attrs()
  defp normalize_attrs(_attrs), do: %{}

  defp opt(opts, key) when is_list(opts), do: opts |> Map.new() |> opt(key)

  defp opt(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp opt(_opts, _key), do: nil

  defp put_opt(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)
  defp put_opt(opts, key, value) when is_map(opts), do: Map.put(opts, key, value)
  defp put_opt(_opts, key, value), do: %{key => value}

  defp put_new(attrs, key, value) do
    if present(Map.get(attrs, key)), do: attrs, else: Map.put(attrs, key, value)
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(value), do: value

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp value(nil, _key), do: nil

  defp value(struct, key) when is_struct(struct), do: Map.get(struct, key)

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_other, _key), do: nil

  defp excerpt(nil), do: nil

  defp excerpt(text) do
    text
    |> to_string()
    |> String.trim()
    |> String.slice(0, 2000)
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp tap_broadcast({:ok, item} = result, event) do
    broadcast(event, item)
    result
  end

  defp tap_broadcast(other, _event), do: other

  defp tap_event({:ok, item} = result, event) do
    broadcast(event, item)
    result
  end

  defp tap_event(other, _event), do: other

  defp broadcast(event, item) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:dispatch, event, item})
    :ok
  end
end
