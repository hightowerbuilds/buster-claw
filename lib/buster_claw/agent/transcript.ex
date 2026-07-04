defmodule BusterClaw.Agent.Transcript do
  @moduledoc """
  Persistence for the headless-Claude chat transcript.

  `record/4` is best-effort — a write failure is logged and swallowed so it can
  never break the chat run that produced the message (same posture as
  `BusterClaw.Sentinel.observe/4`). `recent/2` returns a conversation's messages
  oldest-first, ready to seed a freshly mounted LiveView.
  """

  import Ecto.Query

  require Logger

  alias BusterClaw.Repo
  alias BusterClaw.Agent.Message

  @doc """
  Persist one transcript message. `opts` may carry `:session_id`, `:cost_usd`,
  and `:num_turns`. Returns `{:ok, message}` or `{:error, reason}`; callers
  generally ignore the result.
  """
  def record(conv_id, role, content, opts \\ []) do
    attrs = %{
      conv_id: conv_id,
      role: to_string(role),
      content: content,
      session_id: opts[:session_id],
      cost_usd: opts[:cost_usd],
      num_turns: opts[:num_turns]
    }

    %Message{} |> Message.changeset(attrs) |> Repo.insert()
  rescue
    error ->
      Logger.warning("Transcript.record failed: #{Exception.message(error)}")
      {:error, error}
  end

  @doc "A conversation's most recent messages, oldest-first. `:limit` defaults to 100."
  def recent(conv_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Message
    |> where([m], m.conv_id == ^conv_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc "Delete a conversation's entire transcript. Returns the number of rows removed."
  def clear(conv_id) do
    {count, _} =
      Message
      |> where([m], m.conv_id == ^conv_id)
      |> Repo.delete_all()

    count
  end
end
