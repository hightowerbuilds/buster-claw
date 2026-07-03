defmodule BusterClaw.TerminalWorkspace do
  @moduledoc """
  In-memory bridge for opening visible terminal tabs from the command surface.

  The CLI/API/MCP side cannot and should not spawn an OS terminal. Instead it
  queues a terminal-tab request and broadcasts it to connected top-level
  LiveViews. The browser-side tab strip then creates a Buster Claw tab pointing
  at `/terminal?session=...&label=...`, which opens the shell inside the app.
  """

  use GenServer

  @topic "terminal_workspace"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "PubSub topic for terminal workspace requests."
  def topic, do: @topic

  @doc "Subscribe the current process to terminal workspace requests."
  def subscribe do
    Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)
  end

  @doc """
  Queue and broadcast a request to open an in-app terminal tab for a role.

  Required args:
  - `role_key` or `role`

  Optional args:
  - `label`
  - `agent_name`
  - `purpose`
  - `session_key` or `session`
  - `startup_profile`
  - `startup_submit` (defaults true; set false to pre-fill the startup command
    without pressing enter, so the user runs it themselves)
  - `activate` (defaults true)
  """
  def open(args) when is_map(args) do
    call({:open, args})
  end

  @doc """
  Open a terminal tab for a role with its startup command PRE-FILLED but NOT
  run, so the user presses enter to start it.

  Convenience wrapper over `open/1` that forces `startup_submit: false`. The
  onboarding flow uses this to drop the user into a terminal with
  `./buster-claw on-duty` typed and waiting.

  ## Examples

      # On-duty loop, pre-typed, un-submitted:
      BusterClaw.TerminalWorkspace.request_open(%{"role" => "mailman"})

  """
  def request_open(args) when is_map(args) do
    args
    |> normalize_args()
    |> Map.put("startup_submit", false)
    |> open()
  end

  @doc """
  Open the Mailman terminal tab with `./buster-claw on-duty` pre-filled but
  NOT executed. Shorthand the onboarding LiveView can call with no arguments.
  """
  def request_open_mailman do
    request_open(%{"role" => "mailman", "label" => "Mailman"})
  end

  @doc "Return and clear any terminal requests that were queued before a UI connected."
  def drain_pending do
    case call(:drain_pending) do
      {:error, :terminal_workspace_unavailable} -> []
      pending -> pending
    end
  end

  @doc "Acknowledge that a request was delivered to a top-level LiveView."
  def ack(id) when is_binary(id) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:ack, id})
    end

    :ok
  end

  @impl true
  def init(_opts), do: {:ok, []}

  @impl true
  def handle_call({:open, args}, _from, pending) do
    case build_request(args) do
      {:ok, request} ->
        Phoenix.PubSub.broadcast(
          BusterClaw.PubSub,
          @topic,
          {:terminal_workspace, {:open, request}}
        )

        {:reply, {:ok, request}, pending ++ [request]}

      {:error, reason} ->
        {:reply, {:error, reason}, pending}
    end
  end

  def handle_call(:drain_pending, _from, pending), do: {:reply, pending, []}

  @impl true
  def handle_cast({:ack, id}, pending) do
    {:noreply, Enum.reject(pending, &(&1.id == id))}
  end

  defp call(message) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :terminal_workspace_unavailable}
      _pid -> GenServer.call(__MODULE__, message)
    end
  end

  defp build_request(args) do
    args = normalize_args(args)
    role_key = args |> first_present(["role_key", "role"]) |> sanitize_role_key()

    if is_nil(role_key) do
      {:error, :missing_role_key}
    else
      label =
        args
        |> first_present(["label", "agent_name"])
        |> Kernel.||(label_from_role(role_key))

      session_key =
        args
        |> first_present(["session_key", "session"])
        |> sanitize_session_key()
        |> Kernel.||(generated_session_key(role_key))

      startup_profile =
        args
        |> first_present(["startup_profile", "profile"])
        |> sanitize_startup_profile()
        |> Kernel.||(default_startup_profile(role_key))

      startup_submit = truthy?(Map.get(args, "startup_submit", true))

      request = %{
        id: request_id(),
        role_key: role_key,
        agent_name: first_present(args, ["agent_name"]),
        label: label,
        purpose: first_present(args, ["purpose"]),
        session_key: session_key,
        startup_profile: startup_profile,
        startup_submit: startup_submit,
        path: terminal_path(session_key, label, startup_profile, startup_submit),
        activate: truthy?(Map.get(args, "activate", true))
      }

      {:ok, request}
    end
  end

  defp normalize_args(args) do
    Map.new(args, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp first_present(args, keys) do
    keys
    |> Enum.find_value(fn key -> present(Map.get(args, key)) end)
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp sanitize_role_key(nil), do: nil

  defp sanitize_role_key(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> nil
      role_key -> role_key
    end
  end

  defp sanitize_session_key(nil), do: nil

  defp sanitize_session_key(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._:-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 96)
    |> case do
      "" -> nil
      session_key -> session_key
    end
  end

  # Accept any profile that resolves to a command in the TerminalCommands
  # catalog (mailman, agent-setup, …); reject anything else. The catalog is the
  # whitelist, so this never admits arbitrary shell.
  defp sanitize_startup_profile(value) when is_binary(value) do
    if BusterClaw.TerminalCommands.startup_command(value), do: value, else: nil
  end

  defp sanitize_startup_profile(_value), do: nil

  defp default_startup_profile(role_key),
    do: BusterClaw.TerminalCommands.startup_profile_for_role(role_key)

  defp generated_session_key(role_key) do
    stamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%d%H%M%S")

    "role-#{role_key}-#{stamp}-#{System.unique_integer([:positive])}"
  end

  defp request_id, do: "term-req-#{System.unique_integer([:positive])}"

  defp label_from_role(role_key) do
    role_key
    |> String.split(~r/[-_]+/, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
    |> case do
      "" -> "Terminal"
      label -> label
    end
  end

  defp terminal_path(session_key, label, startup_profile, startup_submit) do
    query =
      [{"session", session_key}, {"label", label}]
      |> maybe_append_query("startup_profile", startup_profile)
      # Only emit the flag when we want prefill-without-run; omitting it keeps
      # the default (run) and avoids churn in existing callers/tests.
      |> maybe_append_query("startup_submit", if(startup_submit, do: nil, else: "false"))

    "/terminal?" <> URI.encode_query(query)
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, "yes", "YES", "on", "ON"]

  defp maybe_append_query(query, _key, nil), do: query
  defp maybe_append_query(query, key, value), do: query ++ [{key, value}]
end
