defmodule BusterClaw.Agent.Deliveries do
  @moduledoc """
  Reads and writes for the delivery ledger and the per-backend thread bindings.

  Every function here is **best-effort**. `BusterClaw.Agent.Chat` runs with no
  DB in its own test suite and must keep working when the ledger is unavailable
  — losing durability is bad, but losing the ability to chat because a write
  failed would be worse. Writes therefore return the row or `nil` and never
  raise.
  """

  import Ecto.Query

  alias BusterClaw.Agent.Delivery
  alias BusterClaw.Agent.ThreadBinding
  alias BusterClaw.Repo

  require Logger

  @doc """
  Record a newly submitted message and hand back its row.

  `position` orders it within the conversation's pending queue; pass `:front`
  for a race-demoted message, which must run ahead of anything already waiting.
  """
  def record(conv_id, content, requested_mode, opts \\ []) do
    position =
      case Keyword.get(opts, :position, :back) do
        :front -> front_position(conv_id)
        :back -> next_position(conv_id)
        n when is_integer(n) -> n
      end

    %{
      conv_id: conv_id,
      content: content,
      requested_mode: to_string(requested_mode),
      position: position,
      backend: opts[:backend] && to_string(opts[:backend])
    }
    |> Delivery.new()
    |> Repo.insert()
    |> case do
      {:ok, delivery} -> delivery
      {:error, reason} -> warn("record", reason)
    end
  rescue
    error -> warn("record", error)
  end

  @doc "Advance a delivery. A nil delivery is a no-op, so callers need no guard."
  def transition(nil, _attrs), do: nil

  def transition(%Delivery{} = delivery, attrs) do
    attrs = stamp(attrs)

    delivery
    |> Delivery.transition(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} -> updated
      {:error, reason} -> warn("transition", reason)
    end
  rescue
    error -> warn("transition", error)
  end

  # `accepted_at` and `failed_at` are derived from the status rather than asked
  # of every caller, so they cannot disagree with it.
  defp stamp(%{status: status} = attrs) when status in ["delivered", "queued"],
    do: Map.put_new(attrs, :accepted_at, DateTime.utc_now())

  defp stamp(%{status: "failed"} = attrs), do: Map.put_new(attrs, :failed_at, DateTime.utc_now())
  defp stamp(attrs), do: attrs

  @doc """
  Move a delivery ahead of everything still waiting.

  The completion race demotes a steer to the queue, and it belongs at the FRONT
  — the operator aimed it at work happening a moment ago, so making it wait
  behind messages they wrote earlier would invert their intent. Doing it here
  rather than only in the in-memory queue is what makes that ordering survive a
  restart.
  """
  def move_to_front(nil), do: nil

  def move_to_front(%Delivery{} = delivery),
    do: transition(delivery, %{position: front_position(delivery.conv_id)})

  @doc """
  A conversation's unfinished deliveries, in queue order.

  This is what boot recovery reads: rows that never reached a terminal state
  because the process, the LiveView, or the machine went away mid-flight.
  """
  def unfinished(conv_id) do
    Repo.all(
      from d in Delivery,
        where: d.conv_id == ^conv_id and d.status not in ^Delivery.terminal_statuses(),
        order_by: [asc: d.position, asc: d.inserted_at]
    )
  rescue
    error -> warn("unfinished", error) || []
  end

  @doc """
  Reconcile a conversation's unfinished rows at boot, returning the ones that
  are safe to run.

  The split is the important part:

  * `pending` and `queued` — never handed to a backend, so they are safe to
    run. Returned, in queue order.
  * `sending` — it left this machine and we have no proof of what happened to
    it. Marked `uncertain` and **not** returned. Resending would risk applying
    an instruction twice, and the operator can retype a message they can see was
    never answered; they cannot un-run a duplicated one.
  """
  def recover(conv_id) do
    {resumable, uncertain} =
      conv_id
      |> unfinished()
      |> Enum.split_with(&(&1.status in ["pending", "queued"]))

    # Mapped, not `each`: the caller is handed the rows in their NEW state, so
    # it cannot accidentally report a stale `sending`.
    uncertain =
      Enum.map(uncertain, fn delivery ->
        transition(delivery, %{
          status: "uncertain",
          error: "interrupted before the backend confirmed anything"
        }) || delivery
      end)

    if uncertain != [] do
      Logger.warning(
        "Chat #{conv_id}: #{length(uncertain)} delivery(s) were in flight at shutdown and will NOT be resent"
      )
    end

    %{resumable: resumable, uncertain: uncertain}
  end

  @doc "Deliveries for a conversation, newest first — for a UI or an audit."
  def list(conv_id, limit \\ 50) do
    Repo.all(
      from d in Delivery,
        where: d.conv_id == ^conv_id,
        order_by: [desc: d.inserted_at],
        limit: ^limit
    )
  rescue
    error -> warn("list", error) || []
  end

  # --- thread bindings -----------------------------------------------------

  @doc """
  Remember which thread/session `backend` is using for `conv_id`.

  Upserted on the compound key so switching harness never overwrites the id
  needed to switch back.
  """
  def put_thread(conv_id, backend, thread_id)
      when is_binary(conv_id) and is_binary(thread_id) and not is_nil(backend) do
    %ThreadBinding{}
    |> ThreadBinding.changeset(%{
      conv_id: conv_id,
      backend: to_string(backend),
      thread_id: thread_id
    })
    |> Repo.insert(
      on_conflict: [set: [thread_id: thread_id, updated_at: DateTime.utc_now()]],
      conflict_target: [:conv_id, :backend]
    )
    |> case do
      {:ok, binding} -> binding
      {:error, reason} -> warn("put_thread", reason)
    end
  rescue
    error -> warn("put_thread", error)
  end

  def put_thread(_conv_id, _backend, _thread_id), do: nil

  @doc "The thread/session `backend` last used for `conv_id`, or nil."
  def thread_for(conv_id, backend) when is_binary(conv_id) and not is_nil(backend) do
    Repo.one(
      from t in ThreadBinding,
        where: t.conv_id == ^conv_id and t.backend == ^to_string(backend),
        select: t.thread_id
    )
  rescue
    error -> warn("thread_for", error)
  end

  def thread_for(_conv_id, _backend), do: nil

  @doc "Forget every backend's thread for a conversation — what `Chat.reset/1` means."
  def clear_threads(conv_id) when is_binary(conv_id) do
    Repo.delete_all(from t in ThreadBinding, where: t.conv_id == ^conv_id)
    :ok
  rescue
    error -> warn("clear_threads", error) || :ok
  end

  # --- helpers -------------------------------------------------------------

  defp next_position(conv_id) do
    (Repo.one(from d in Delivery, where: d.conv_id == ^conv_id, select: max(d.position)) || 0) + 1
  rescue
    _error -> 1
  end

  # Ahead of everything currently waiting, without renumbering them.
  defp front_position(conv_id) do
    pending =
      Repo.one(
        from d in Delivery,
          where: d.conv_id == ^conv_id and d.status not in ^Delivery.terminal_statuses(),
          select: min(d.position)
      )

    (pending || 1) - 1
  rescue
    _error -> 0
  end

  # The ledger is a durability feature, not a dependency. A conversation that
  # cannot write to it still runs — it just cannot survive a crash, which is the
  # situation everything was in before this table existed.
  defp warn(op, reason) do
    Logger.warning("Deliveries.#{op} failed: #{inspect(reason)}")
    nil
  end
end
