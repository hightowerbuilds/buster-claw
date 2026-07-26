defmodule BusterClaw.Commands.AgentRuns do
  @moduledoc """
  Agent Mode run commands — the surface that makes the browse tab's mode
  switch real. `agent_run_start` launches a **headful, supervised** run: the
  user's installed Chromium with the persistent agent profile ("be the real
  user"), a scope frozen from the given intent + domains, and — for commerce
  runs — the payment handoff instead of the payment dead end. The run
  registers in the RunRegistry and broadcasts on the all-runs topic, which is
  exactly what the browse tab renders.

  Delegated to from `BusterClaw.Commands`.
  """

  alias BusterClaw.BrowserControl
  alias BusterClaw.BrowserControl.{AgentMode, RunSupervisor, Scope, Session, SessionSupervisor}
  alias BusterClaw.BrowserControl.AgentMode.Trajectory
  alias BusterClaw.BrowserControl.Commerce.Cart

  @doc """
  Start a supervised Agent Mode run. Args: `intent` (the task, verbatim —
  frozen into the scope), `domains` (the allowlist; every navigation outside
  it halts), `commerce` (optional boolean: payment pages hand off to the human
  instead of halting).
  """
  def agent_run_start(%{"intent" => intent, "domains" => domains} = args)
      when is_binary(intent) and intent != "" and is_list(domains) and domains != [] do
    scope = Scope.new(intent, domains)
    on_payment = if Map.get(args, "commerce") == true, do: :handoff, else: :halt

    run_opts = [scope: scope, on_payment: on_payment]

    # Test seam (like the session starter): a scripted CDP surface for the run.
    run_opts =
      case Application.get_env(:buster_claw, :agent_run_session_mod) do
        nil -> run_opts
        mod -> Keyword.put(run_opts, :session_mod, mod)
      end

    with {:ok, session} <- start_session(),
         {:ok, run} <-
           RunSupervisor.start_run([{:session, session} | run_opts]),
         {:ok, :agent_working} <- AgentMode.start_run(run) do
      # Lease the session to the run so the idle reaper leaves it alone.
      if is_pid(session), do: Session.lease(session, run)

      {:ok,
       %{
         run_id: scope.id,
         mode: :agent_working,
         commerce: on_payment == :handoff,
         intent: intent,
         domains: scope.allowed_domains
       }}
    end
  end

  def agent_run_start(_args), do: {:error, :missing_intent_or_domains}

  @act_actions %{
    "click" => :click,
    "fill" => :fill,
    "extract" => :extract,
    "read" => :read,
    "find_elements" => :find_elements,
    "wait" => :wait
  }

  @doc """
  Navigate a run under its frozen scope. A gate firing is a *result*, not an
  error: off-scope comes back `result: "halted"`, and a payment page on a
  commerce run comes back `result: "handoff"` with the frozen cart — the human
  pays from there.
  """
  def agent_run_navigate(%{"id" => id, "url" => url})
      when is_binary(id) and is_binary(url) and url != "" do
    with {:ok, run} <- lookup(id) do
      case AgentMode.navigate(run, url) do
        {:ok, origin} ->
          {:ok, %{result: "ok", navigated: url, origin: origin}}

        {:handoff, :payment, meta} ->
          {:ok, %{result: "handoff", url: meta[:url], cart: meta[:cart], mode: :awaiting_human}}

        {:halt, reason, meta} ->
          {:ok, %{result: "halted", reason: reason, url: meta[:url], mode: safe_mode(run)}}

        {:error, _reason} = error ->
          error

        other ->
          {:error, {:navigate_failed, other}}
      end
    end
  end

  def agent_run_navigate(_args), do: {:error, :missing_id_or_url}

  @doc """
  Perform one page action in a run: `#{Enum.map_join(Map.keys(@act_actions), " | ", & &1)}`.
  Targeting/args pass through (`selector`/`text`/`index`, `value` for fill —
  `$secret.<name>` resolves in the executor and never enters the record —
  `until`/`timeout_ms` for wait). Content-returning actions come back
  egress-prepared, never as raw page text.
  """
  def agent_run_act(%{"id" => id, "action" => action} = args) when is_binary(id) do
    case Map.fetch(@act_actions, action) do
      {:ok, act} ->
        with {:ok, run} <- lookup(id) do
          case AgentMode.act(run, act, Map.drop(args, ["id", "action"])) do
            {:ok, result} -> {:ok, %{action: action, result: result}}
            {:error, _reason} = error -> error
          end
        end

      :error ->
        {:error, {:unknown_action, action}}
    end
  end

  def agent_run_act(_args), do: {:error, :missing_id_or_action}

  @doc """
  Attach/replace the run's cart (Phase 5): `items` are
  `{"name", "unit_cents", "qty" (default 1)}`. Frozen at the payment handoff —
  what the human is shown is exactly what the ledger may bill.
  """
  def agent_run_cart(%{"id" => id, "items" => items}) when is_binary(id) and is_list(items) do
    with {:ok, run} <- lookup(id),
         {:ok, cart} <- build_cart(items) do
      AgentMode.put_cart(run, cart)
    end
  end

  def agent_run_cart(_args), do: {:error, :missing_id_or_items}

  @doc """
  A run's live status by `id` — mode, step/egress summary, and the cart
  summary when one is attached. Without `id`: all registered runs.
  """
  def agent_run_status(args \\ %{}) do
    case Map.get(args, "id") do
      nil ->
        {:ok, %{runs: Enum.map(AgentMode.list_runs(), &Map.take(&1, [:run_id, :mode]))}}

      id when is_binary(id) ->
        with {:ok, run} <- lookup(id) do
          cart = AgentMode.cart(run)

          {:ok,
           %{
             run_id: id,
             mode: AgentMode.mode(run),
             summary: AgentMode.summary(run),
             steps: run |> AgentMode.trajectory() |> Trajectory.steps() |> length(),
             cart: cart && Cart.summary(cart)
           }}
        end

      _other ->
        {:error, :bad_id}
    end
  end

  @doc """
  Stop a run — halts before its next action — and stop its browser session
  with it. The run process stays registered for trajectory inspection; only
  the engine goes away.
  """
  def agent_run_stop(%{"id" => id}) when is_binary(id) and id != "" do
    with {:ok, run} <- lookup(id) do
      result = AgentMode.stop_run(run)
      stop_session(AgentMode.session(run))

      case result do
        {:ok, mode} -> {:ok, %{run_id: id, mode: mode}}
        {:error, :invalid_transition} -> {:ok, %{run_id: id, mode: AgentMode.mode(run)}}
        other -> other
      end
    end
  end

  def agent_run_stop(_args), do: {:error, :missing_id}

  # ── internals ───────────────────────────────────────────────────────────────

  defp lookup(id) do
    case AgentMode.whereis(id) do
      nil -> {:error, :run_not_found}
      pid -> {:ok, pid}
    end
  end

  defp safe_mode(run) do
    AgentMode.mode(run)
  catch
    :exit, _ -> :gone
  end

  defp build_cart(items) do
    items
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, Cart.new()}, fn
      {%{"name" => name, "unit_cents" => cents} = item, index}, {:ok, cart}
      when is_binary(name) and is_integer(cents) ->
        qty = Map.get(item, "qty", 1)

        with true <- is_integer(qty),
             {:ok, cart} <-
               Cart.add_item(cart, name, cents, qty) do
          {:cont, {:ok, cart}}
        else
          _invalid -> {:halt, {:error, {:invalid_item, index}}}
        end

      {_bad_item, index}, _acc ->
        {:halt, {:error, {:invalid_item, index}}}
    end)
  end

  # Seam: tests must never launch a real Chromium.
  defp start_session do
    case Application.get_env(:buster_claw, :agent_run_session_starter, :default) do
      :default -> start_headful_session()
      fun when is_function(fun, 0) -> fun.()
    end
  end

  defp start_headful_session do
    with {:ok, browser_path} <- BrowserControl.detect(),
         {:ok, session} <-
           SessionSupervisor.start_session(
             browser_path: browser_path,
             profile_dir: BrowserControl.profile_dir(),
             headless: false,
             id: "agent-run"
           ) do
      # Headful, but not in the user's face: the mirror shows the page inside the
      # app, so the real window is pushed aside rather than left on top of
      # everything. It still exists — checkout popups and native dialogs need a
      # real window — and the rail's "Real window" control brings it back.
      BrowserControl.stash_window(session)
      {:ok, session}
    end
  end

  defp stop_session(session) when is_pid(session) do
    Session.stop(session)
  catch
    :exit, _ -> :ok
  end

  defp stop_session(_session), do: :ok
end
