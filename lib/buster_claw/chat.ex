defmodule BusterClaw.Chat do
  @moduledoc "Public API for local supervised chat sessions."

  alias BusterClaw.Chat.Session

  @default_session "default"

  def default_session, do: @default_session
  def topic(session_id \\ @default_session), do: Session.topic(session_id)

  def ensure_session(session_id \\ @default_session) do
    case Registry.lookup(BusterClaw.Chat.Registry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(BusterClaw.Chat.SessionSupervisor, {Session, session_id})
    end
  end

  def messages(session_id \\ @default_session) do
    {:ok, _pid} = ensure_session(session_id)
    Session.messages(session_id)
  end

  def send_message(session_id \\ @default_session, prompt) do
    {:ok, _pid} = ensure_session(session_id)
    Session.send_message(session_id, prompt)
  end

  def clear(session_id \\ @default_session) do
    {:ok, _pid} = ensure_session(session_id)
    Session.clear(session_id)
  end
end
