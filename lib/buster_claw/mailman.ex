defmodule BusterClaw.Mailman do
  @moduledoc """
  The in-app mail poller — THREE_DOORS Phase 2.

  `./buster-claw on-duty` is a shift start followed by a loop in the **escript
  process** that POSTs `gmail_sync` every sixty seconds (`cli.ex`). That loop was
  the only mail poller Buster Claw had, so a shift started from the app would
  have been a shift that never received a request. This ticker is the same loop
  inside the BEAM, gated the same way the Dispatcher is: it does nothing unless
  an **unattended shift is active and the kill switch is clear**.

  Shaped like `BusterClaw.Telephony.Drain`: a supervised ticker that decides for
  itself whether there is work, so it costs one cheap check per tick when idle
  and needs no restart when a shift starts. Off in tests (`:mailman_enabled`),
  which drive `tick/1` directly.

  ## Two pollers

  While the CLI's `on-duty` keeps its own loop, an operator using both has two
  syncs a minute. That is a wasted API call, not a duplicate item: `gmail_sync`
  enqueues through `Dispatch.enqueue_gmail/3`, which keys every item on the
  Gmail message id, so the second sync of the same message is a no-op on the
  queue. Folding the CLI loop into this one is a CLI change and a later map.
  """
  use GenServer

  require Logger

  alias BusterClaw.{Commands, Duty, Google, Journal, Orchestration}

  @default_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Force an immediate poll (tests / manual nudge)."
  def tick_now(server \\ __MODULE__), do: send(server, :tick)

  @impl true
  def init(opts) do
    state = %{
      interval_ms:
        Keyword.get(opts, :interval_ms, configured(:mailman_tick_ms, @default_interval_ms)),
      # Injectable for tests: `sync.(account_summary) :: {:ok, term} | {:error, term}`.
      sync: Keyword.get(opts, :sync, &default_sync/1),
      # The shift id the last journal line was written for, so "polling started"
      # is said once per shift rather than once per minute.
      announced_shift: nil
    }

    if Keyword.get(opts, :autostart, true), do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = safe_tick(state)
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def tick(state) do
    case Orchestration.active_shift() do
      %{unattended: true, id: shift_id} = _shift ->
        if Orchestration.kill_switch_engaged?() do
          state
        else
          state |> announce(shift_id) |> sync_accounts()
        end

      _attended_or_none ->
        %{state | announced_shift: nil}
    end
  end

  defp sync_accounts(state) do
    Google.list_account_summaries()
    |> Enum.filter(&Duty.account_ready?/1)
    |> Enum.each(fn account ->
      case state.sync.(account) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.warning("Mailman: sync failed for #{account.email}: #{inspect(reason)}")
      end
    end)

    state
  end

  defp announce(%{announced_shift: shift_id} = state, shift_id), do: state

  defp announce(state, shift_id) do
    _ =
      Journal.append(
        "Mailman: watching Gmail for trusted-sender requests (shift #{shift_id}).",
        :operator
      )

    %{state | announced_shift: shift_id}
  end

  # The same command the CLI loop runs, through the same front door, so the
  # Security feed records it the same way.
  defp default_sync(account) do
    Commands.call("gmail_sync", %{"account_id" => account.id}, caller: :trusted)
  end

  defp safe_tick(state) do
    tick(state)
  rescue
    error ->
      Logger.warning("Mailman tick failed: #{Exception.message(error)}")
      state
  catch
    kind, reason ->
      Logger.warning("Mailman tick failed: #{inspect({kind, reason})}")
      state
  end

  defp configured(key, default), do: Application.get_env(:buster_claw, key, default)
end
