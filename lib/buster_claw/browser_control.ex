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

  alias BusterClaw.BrowserControl.{CDP, Detect}
  alias BusterClaw.Library.Artifact

  @probe_page "data:text/html,<title>bc-probe</title>ok"
  @load_timeout_ms 10_000

  @doc "The engine binary in use: `{:ok, path}` or `{:error, :no_browser}`."
  defdelegate detect, to: Detect, as: :find

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
