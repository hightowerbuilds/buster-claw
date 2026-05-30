defmodule BusterClaw.AgentMode do
  @moduledoc """
  Process-backed flag that tracks whether the user has handed control to an
  external terminal agent (Claude Code, Codex, etc. via the MCP server).

  When agent mode is on:
  - `BusterClaw.Commands.call/2` broadcasts each invocation on the activity
    topic so the GUI can show live progress.
  - The GUI may disable a few user-driven controls so the human and the agent
    don't fight over the same state (currently TBD; see the AgentLive page).

  Subscribes/broadcasts:
  - `"agent_mode"` — `:on` | `:off` events when the flag flips.
  - `"agent_activity"` — `{:command, name, args, result}` events while on.
  """

  use Agent

  @mode_topic "agent_mode"
  @activity_topic "agent_activity"

  def start_link(_opts) do
    Agent.start_link(fn -> default_mode() end, name: __MODULE__)
  end

  # Agent mode is on by default so the agent surface is live as soon as the app
  # opens. Override with `config :buster_claw, :agent_mode_default, false`.
  defp default_mode, do: Application.get_env(:buster_claw, :agent_mode_default, true)

  @doc "Returns `true` if agent mode is currently on. Safe before supervision starts."
  def on? do
    ensure_started()
    Agent.get(__MODULE__, & &1)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc "Switch agent mode on or off and broadcast the change."
  def set(value) when is_boolean(value) do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> value end)
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @mode_topic, {:agent_mode, value})
    value
  end

  @doc "Flip the current value."
  def toggle do
    ensure_started()
    new_value = Agent.get_and_update(__MODULE__, fn current -> {!current, !current} end)
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @mode_topic, {:agent_mode, new_value})
    new_value
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case Agent.start(fn -> default_mode() end, name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  @doc "Topic for mode-change broadcasts."
  def mode_topic, do: @mode_topic

  @doc "Topic for command activity broadcasts."
  def activity_topic, do: @activity_topic

  @doc "Subscribe to mode-change events."
  def subscribe_mode, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @mode_topic)

  @doc "Subscribe to command-activity events."
  def subscribe_activity, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @activity_topic)

  @doc """
  Record a command invocation. No-op when agent mode is off; broadcasts the
  `{:activity, %{name, args, result, at}}` event otherwise.
  """
  def record_activity(name, args, result) do
    if on?() do
      payload = %{
        name: name,
        args: args,
        result: classify_result(result),
        at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      Phoenix.PubSub.broadcast(BusterClaw.PubSub, @activity_topic, {:activity, payload})
    end

    :ok
  end

  defp classify_result({:ok, _}), do: :ok
  defp classify_result({:error, _}), do: :error
  defp classify_result(_), do: :unknown
end
