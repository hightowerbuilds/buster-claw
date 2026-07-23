defmodule BusterClaw.BrowserControl.Launch do
  @moduledoc """
  Pure argv builder for the BrowserControl engine process.

  Transport is `--remote-debugging-pipe`, never `--remote-debugging-port`: a
  loopback debug port is reachable by any local process, and what sits behind it
  is a browser holding logged-in sessions. The pipe protocol uses fds 3 (CDP in)
  and 4 (CDP out), which an Erlang port cannot hand over directly — so the
  engine is spawned through `/bin/sh` with fd redirections and an `exec`:

      exec "$0" "$@" 3<&0 4>&1 1>/dev/null 2>&1

  Left to right: fd3 becomes the port's stdin (our commands reach the engine),
  fd4 duplicates the *original* stdout (engine responses reach the port), and
  only then are the engine's own stdout/stderr logs silenced so they can never
  corrupt the CDP stream. `exec` means sh replaces itself — the port's OS pid IS
  the engine's pid, so exit_status and the kill backstop act on the real process.

  `--enable-automation` is deliberately absent (roadmap: it flags the session
  for zero benefit). The hygiene flags keep the engine from phoning home —
  that flag list is part of the privacy claim, so additions belong here with a
  reason, not inline at call sites.
  """

  @shim ~S(exec "$0" "$@" 3<&0 4>&1 1>/dev/null 2>&1)

  # No background networking, no sync, no component updates, no default-browser
  # nag, no crash uploader, metrics local-only, no promo/first-run chrome.
  @hygiene_flags [
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-networking",
    "--disable-sync",
    "--disable-component-update",
    "--disable-default-apps",
    "--disable-breakpad",
    "--metrics-recording-only",
    "--password-store=basic"
  ]

  @doc "The sh script the engine is exec'd through (exposed for tests)."
  def shim, do: @shim

  @doc "The always-on hygiene flag set (exposed for tests and the roadmap's audit)."
  def hygiene_flags, do: @hygiene_flags

  @doc """
  Full `Port.open/2` argument list for `/bin/sh`: `["-c", shim, browser | flags]`.

  Options:
    * `:profile_dir` (required) — dedicated `--user-data-dir`; never a real
      browser profile in place.
    * `:headless` (default `true`) — headless engine for pool/probe work;
      `false` is the visible Agent Mode surface.
    * `:window_size` (default `{1280, 900}`)
  """
  def argv(browser_path, opts) do
    profile = Keyword.fetch!(opts, :profile_dir)
    headless? = Keyword.get(opts, :headless, true)
    {w, h} = Keyword.get(opts, :window_size, {1280, 900})

    flags =
      ["--remote-debugging-pipe", "--user-data-dir=#{profile}"] ++
        @hygiene_flags ++
        if(headless?, do: ["--headless=new", "--mute-audio"], else: []) ++
        ["--window-size=#{w},#{h}", "about:blank"]

    ["-c", @shim, browser_path | flags]
  end
end
