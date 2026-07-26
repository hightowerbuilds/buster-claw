defmodule BusterClaw.BrowserControl do
  @moduledoc """
  BrowserControl — the in-house browser engine facade (BROWSER_ENGINE_ROADMAP).

  Drives the user's installed Chromium-family browser over our own CDP client
  (`BusterClaw.BrowserControl.CDP`) through a pipe — no debug socket, no
  third-party automation framework, session data never leaves the machine.

  This is the Phase 0/1 slice: detection, launch, protocol, and `probe/1` — the
  end-to-end proof (launch → version → target → attach → navigate → load event →
  read back → clean exit) that must pass from the packaged app before anything
  is built on top. The session pool (Phase 2) and Agent Mode (Phase 4) sit on
  this surface; nothing above it may talk to the engine another way.
  """

  alias BusterClaw.BrowserControl.{CDP, Detect, Page, Scope, Session}
  alias BusterClaw.Library.Artifact
  alias BusterClaw.Sentinel

  @probe_page "data:text/html,<title>bc-probe</title>ok"
  @load_timeout_ms 10_000

  @doc "The engine binary in use: `{:ok, path}` or `{:error, :no_browser}`."
  defdelegate detect, to: Detect, as: :find

  @doc """
  Navigate a leased session, but **only after the frozen `Scope` authorizes it**
  (BROWSER_ENGINE_ROADMAP Phase 3) — and only if it authorizes where the browser
  actually *landed* (Finding 6, 07-25).

  The gate fires twice, on purpose:

    1. **Before** the request. An out-of-scope, payment, or malformed URL never
       reaches the engine.
    2. **After** the load event, against the URL the browser really ended on. A
       302 is a URL the agent never asked for and the scope never saw; without
       this check a redirect walks a run onto a payment page or an off-scope
       host with the mode still `agent_working`, which is the only state that
       permits acting. Same failure as the 07-25 payment-regex gap, reached by a
       different road — that was a bad pattern, this was a missing check.

  The returned origin always describes the **landed** URL, which is what makes
  `AgentMode`'s `current_host` — and therefore `Egress`'s per-host redaction
  level — track reality. Before this, a cross-host redirect left content being
  prepared at the *previous* host's level, so a domain set to `:structure_only`
  could be read at `:full` simply by being redirected to. A redirect adds
  `:redirected_from` to the origin (or the halt meta) so the trajectory and the
  security feed can tell a redirect apart from a direct navigation — a
  distinction that matters when diagnosing injection.

  **Fails closed.** If the landed URL cannot be read, the result is
  `{:halt, :unverified_location, meta}`: not knowing where the browser is, is
  not a reason to let the agent act there.

  **Known limit.** The check runs once, at the load event. A JS redirect fired
  afterwards (`setTimeout`, meta-refresh) is not caught. Catching those needs
  CDP frame-navigation events rather than a point-in-time read; the mode machine
  still bounds the damage, since acting is serialized through `AgentMode`.

  Returns `{:ok, origin}` or `{:halt, reason, meta}`. This is the primitive
  Phase 4's action loop drives; a bare `Session.navigate/2` bypasses the gate and
  is for scope-free internal use only — the probe, and `Browser`'s fetch render,
  which is URL-guarded at its own entry.

  `opts[:session_mod]` (default `Session`) makes the whole composition testable
  without a browser.
  """
  def navigate(session, %Scope{} = scope, url, opts \\ []) do
    case Scope.guard(scope, {:navigate, url}) do
      {:ok, _requested_origin} ->
        session_mod = Keyword.get(opts, :session_mod, Session)

        case session_mod.navigate(session, url) do
          :ok -> verify_landing(session, scope, url, opts)
          other -> other
        end

      {:halt, _reason, _meta} = halt ->
        halt
    end
  end

  # Re-run the gate on the URL the browser actually ended on. Guarding the
  # landed URL unconditionally (rather than only when it differs) keeps one
  # decision path: when nothing redirected, it is the same pure verdict on the
  # same input, and `Scope.guard` only records to Sentinel on a halt.
  defp verify_landing(session, scope, requested, opts) do
    case landed_url(session, opts) do
      {:ok, landed} ->
        case Scope.guard(scope, {:navigate, landed}) do
          {:ok, origin} -> {:ok, mark_redirect(origin, requested, landed)}
          {:halt, reason, meta} -> {:halt, reason, mark_redirect(meta, requested, landed)}
        end

      :error ->
        meta = %{url: requested, scope_id: scope.id, intent: scope.intent}

        Sentinel.observe(
          :security_block,
          "browser landing unverifiable after navigate: #{requested}",
          Map.put(meta, :trust, "policy")
        )

        {:halt, :unverified_location, meta}
    end
  end

  defp landed_url(session, opts) do
    case Page.current(session, opts) do
      {:ok, %{"url" => url}} when is_binary(url) and url != "" -> {:ok, url}
      _ -> :error
    end
  end

  defp mark_redirect(meta, same, same), do: meta
  defp mark_redirect(meta, requested, _landed), do: Map.put(meta, :redirected_from, requested)

  @doc """
  Push the engine's window off-screen so it stops competing with our own for the
  user's attention. The mirror (Phase 7) shows the page inside the app, so the
  real window only needs to exist — it does not need to be looked at.

  **Why not minimize.** Measured 07-25: a minimized window stops compositing on
  macOS, so `Page.screencastFrame` dries up after one frame and the mirror
  freezes. Off-screen keeps rendering. That rules out the tidier-looking option.

  **Honest limit.** macOS clamps window positions to keep a window reachable, so
  a requested `left: -32000` lands around `-1240` for a 1280-wide window — a
  ~40px sliver stays visible at the screen edge. Out of the way, not invisible.
  Fully hiding it is not available without giving up the live view.

  Best-effort: a failure here is cosmetic and must never fail a run.
  """
  def stash_window(session, opts \\ []) do
    with_window(session, opts, fn wid, mod ->
      mod.command(session, "Browser.setWindowBounds", %{
        "windowId" => wid,
        "bounds" => %{"left" => -32_000, "top" => 0}
      })
    end)
  end

  @doc """
  Bring the engine's window back on-screen and focus it — the counterpart to
  `stash_window/2`, and what the "Real window" control needs.

  `Page.bringToFront` alone is not enough once the window has been stashed: it
  would focus a window that is still off-screen. Position is restored first.
  """
  def reveal_window(session, opts \\ []) do
    with_window(session, opts, fn wid, mod ->
      mod.command(session, "Browser.setWindowBounds", %{
        "windowId" => wid,
        "bounds" => %{"left" => 60, "top" => 60, "windowState" => "normal"}
      })

      mod.command(session, "Page.bringToFront", %{})
    end)
  end

  defp with_window(session, opts, fun) do
    mod = Keyword.get(opts, :session_mod, Session)

    case mod.command(session, "Browser.getWindowForTarget", %{}) do
      {:ok, %{"windowId" => wid}} -> fun.(wid, mod)
      other -> other
    end
  catch
    :exit, _ -> {:error, :session_gone}
  end

  @doc "Whether Agent Mode has an engine at all. Absence is surfaced, never papered over."
  def available?, do: match?({:ok, _}, detect())

  @doc "The dedicated persistent profile for Agent Mode (never the user's real one)."
  def profile_dir, do: Artifact.workspace_path(["browser-control", "profile"])

  @doc """
  Prove the whole engine path end to end, headless, against a throwaway profile:

  launch → `Browser.getVersion` → `Target.createTarget` → attach (flat) →
  `Page.navigate` → `Page.loadEventFired` → `Runtime.evaluate` the title →
  `Browser.close` → confirm the OS process actually exited.

  Returns `{:ok, report}` with the engine path, product string, OS pid, the
  title read back, and the exit status — or `{:error, step, reason}` naming the
  first step that failed. This is the packaged-app smoke check for Phase 0.
  """
  def probe(opts \\ []) do
    with {:ok, browser} <- detect_step(opts) do
      profile =
        Path.join(System.tmp_dir!(), "bc_probe_#{System.unique_integer([:positive])}")

      try do
        run_probe(browser, profile, opts)
      after
        File.rm_rf(profile)
      end
    end
  end

  defp detect_step(opts) do
    case Keyword.fetch(opts, :browser_path) do
      {:ok, path} -> {:ok, path}
      :error -> with {:error, r} <- detect(), do: {:error, :detect, r}
    end
  end

  defp run_probe(browser, profile, opts) do
    case launch(browser, profile, opts) do
      {:ok, pid} ->
        # A failed step must not leave an engine behind: the success path stops
        # it in close_and_confirm; every other path stops it here.
        try do
          probe_steps(browser, pid)
        after
          if Process.alive?(pid), do: CDP.stop(pid)
        end

      {:error, :launch, reason} ->
        {:error, :launch, reason}
    end
  end

  # Per-step CDP deadline; tests shrink it to fail a mute engine fast.
  defp timeout_ms,
    do: Application.get_env(:buster_claw, :browser_control_probe_timeout_ms, 15_000)

  defp probe_steps(browser, pid) do
    with {:subscribe, :ok} <- {:subscribe, CDP.subscribe(pid)},
         os_pid = CDP.os_pid(pid),
         {:version, {:ok, %{"product" => product}}} <-
           {:version, CDP.command(pid, "Browser.getVersion", %{}, timeout: timeout_ms())},
         {:target, {:ok, %{"targetId" => target_id}}} <-
           {:target,
            CDP.command(pid, "Target.createTarget", %{"url" => "about:blank"},
              timeout: timeout_ms()
            )},
         {:attach, {:ok, %{"sessionId" => session}}} <-
           {:attach,
            CDP.command(
              pid,
              "Target.attachToTarget",
              %{"targetId" => target_id, "flatten" => true},
              timeout: timeout_ms()
            )},
         {:page, {:ok, _}} <-
           {:page,
            CDP.command(pid, "Page.enable", %{}, session_id: session, timeout: timeout_ms())},
         {:navigate, {:ok, _}} <-
           {:navigate,
            CDP.command(pid, "Page.navigate", %{"url" => @probe_page},
              session_id: session,
              timeout: timeout_ms()
            )},
         {:load, :ok} <- {:load, await_load(session)},
         {:title, {:ok, title}} <- {:title, read_title(pid, session)},
         {:exit, {:ok, status}} <- {:exit, close_and_confirm(pid)} do
      {:ok,
       %{
         browser: browser,
         product: product,
         os_pid: os_pid,
         title: title,
         exit_status: status
       }}
    else
      {:error, :launch, reason} -> {:error, :launch, reason}
      {step, {:error, reason}} -> {:error, step, reason}
    end
  end

  defp launch(browser, profile, opts) do
    File.mkdir_p!(profile)

    case CDP.start_link(
           browser_path: browser,
           profile_dir: profile,
           headless: Keyword.get(opts, :headless, true)
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, :launch, reason}
    end
  end

  defp await_load(session) do
    receive do
      {:browser_control_event, "Page.loadEventFired", _params, ^session} -> :ok
    after
      @load_timeout_ms -> {:error, :load_event_timeout}
    end
  end

  defp read_title(pid, session) do
    case CDP.command(pid, "Runtime.evaluate", %{"expression" => "document.title"},
           session_id: session,
           timeout: timeout_ms()
         ) do
      {:ok, %{"result" => %{"value" => title}}} -> {:ok, title}
      {:ok, other} -> {:error, {:unexpected_evaluate, other}}
      error -> error
    end
  end

  # The probe's "no orphan" claim is this: the engine's real exit status arrives
  # (we are subscribed), not merely a closed pipe.
  defp close_and_confirm(pid) do
    :ok = CDP.stop(pid)

    receive do
      {:browser_control_exit, status} -> {:ok, status}
    after
      # stop/2 already escalated to KILL if needed; a missing notification here
      # means the server died before broadcasting, which still killed the engine.
      1_000 -> {:ok, :killed}
    end
  end
end
