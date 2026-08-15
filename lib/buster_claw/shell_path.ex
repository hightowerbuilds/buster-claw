defmodule BusterClaw.ShellPath do
  @moduledoc """
  Executable lookup against the **user's login-shell `PATH`**, not this
  process's.

  ## The bug this exists to close

  A double-clicked `.app` inherits launchd's environment, and launchd's `PATH`
  is roughly `/usr/bin:/bin:/usr/sbin:/sbin`. Every way a developer tool is
  actually installed puts it somewhere else — `~/.local/bin`, `~/.bun/bin`,
  `/usr/local/bin`, `/opt/homebrew/bin`, a version manager's shims. So
  `System.find_executable/1`, which searches *this process's* `PATH`, answers
  "not installed" in the packaged app for tools that are plainly installed.

  Measured on the 08-15 signed build: `claude`, `codex` and `opencode` were all
  present and all three read as missing, so Settings offered no harness and no
  app-wide model could be set (`DMG-review-8-15`, findings 1 and 2).

  **The app was already doing the right thing one layer over.** `AgentRunner`
  spawns through a *login* shell (`-lc`) precisely so a packaged or daemon run
  reaches the user's `PATH` and the agent's persisted auth. Detection asked the
  process instead, so the app could run a harness it reported as absent. This
  module makes the two agree by giving detection the same environment.

  ## How, and why it is one spawn

  The login shell is asked for its `PATH` **once** and the answer is cached;
  lookups afterwards are pure list-walking. Asking the shell per binary
  (`command -v claude`) would also work and costs a spawn each — measured ~25 ms
  — but three spawns to answer one question is a worse trade than one spawn and
  a cached string.

  Running a login shell executes the user's profile. That is not a new exposure:
  `AgentRunner` already does it on every agent spawn. It is new *timing*, which
  is why the call is lazy — nothing runs a shell until something asks whether a
  harness exists.

  ## What it will not do

  **It never raises and never blocks for long.** A profile that hangs, prompts,
  or does not exist yields `nil` and the caller falls back to
  `System.find_executable/1`, which is exactly today's behaviour. The failure
  mode of this module is *the bug it fixes*, not a worse one.

  **It does not widen a guess-list.** The alternative considered was hardcoding
  the handful of common install directories; that is a list which rots silently
  the first time someone uses a version manager we did not think of. Asking the
  shell is the answer that stays correct.

  ## Why the shell is asked interactively (`-lic`, not `-lc`)

  `-lc` was the obvious flag — it is what `AgentRunner` spawns with — and it is
  **not sufficient**, which was measured rather than reasoned about. A zsh login
  shell sources `.zshenv`, `.zprofile` and `.zlogin`; it does **not** source
  `.zshrc`, because that file is for *interactive* shells. On the machine the DMG
  bug was found on, `.zshrc` is the only file that touches `PATH` at all.

  Replaying launchd's environment exactly
  (`env -i HOME=... PATH=/usr/bin:/bin:/usr/sbin:/sbin`):

      zsh -lc   claude -> /usr/local/bin/claude    codex -> NOT FOUND
      zsh -lic  claude -> ~/.local/bin/claude      codex -> ~/.bun/bin/codex

  So `-lc` would have closed finding 1 and left **finding 2 open for codex**, and
  it would have resolved a *different* `claude` than the one a terminal runs. The
  interactive flag is what every GUI editor with this same problem settled on.

  The hazards `-i` adds are the ones already handled: an interactive profile
  prints more (the fence below), warns about a missing tty on stderr
  (`stderr_to_stdout: false`), and can be slow or hang (the 3s cap). `-lc` is
  kept as a second attempt for a machine where interactive genuinely cannot run.

  ## Why the value is fenced in markers

  A login shell runs the user's profile, and profiles *print*. Measured with a
  real `/bin/zsh -lc` and a two-line `.zprofile`, stdout came back as

      profile banner line\\n/usr/local/bin:/usr/bin:...

  — the banner and the `PATH` welded together with no separator that survives a
  trim. Split on `:` and the first entry becomes the garbage directory
  `"profile banner line\\n/usr/local/bin"`, so the *first* real `PATH` entry is
  silently lost; a banner containing a colon (`nvm: using node v20`) corrupts
  more than one. `.zlogout` can print *after* the value for the same reason.

  So the shell is asked to fence the value between markers and only what is
  between them is read. `stderr_to_stdout: false` handles the other half:
  anything the profile writes to stderr never enters the string at all.
  """
  require Logger

  @cache_key {__MODULE__, :path}

  # Long enough for a real profile (measured ~25 ms on the dev machine), short
  # enough that a hung one is a hiccup and not a freeze.
  @timeout_ms 3_000

  # How long a *failed* read stays cached. Long enough that a settings page
  # cannot spawn shells in a loop, short enough that a transient failure heals
  # itself without anyone knowing `refresh/0` exists.
  @retry_after_ms 60_000

  # In order, most-complete first. See the moduledoc: `-lc` alone does NOT source
  # `.zshrc`, which is where most people actually put their `PATH`. The second is
  # a fallback for a machine where an interactive shell cannot run at all, and
  # costs a second spawn only when the first has already failed.
  @flags ["-lic", "-lc"]

  # Fence posts. Deliberately not a shell metacharacter and not something a
  # directory name could plausibly contain.
  @marker_begin "@@BUSTER_CLAW_PATH@@"
  @marker_end "@@BUSTER_CLAW_END@@"
  @command "printf '#{@marker_begin}%s#{@marker_end}' \"$PATH\""
  @fence ~r/#{@marker_begin}(.*?)#{@marker_end}/s

  @doc """
  The user's login-shell `PATH`, or `nil` when it cannot be determined.

  Cached after the first successful call. Set `:login_shell_path` in the app env
  to pin it — the test seam, and the escape hatch for a machine whose profile
  cannot be run.
  """
  @spec path() :: String.t() | nil
  def path do
    case Application.get_env(:buster_claw, :login_shell_path, :unset) do
      :unset -> cached_path()
      value when is_binary(value) -> value
      # `nil` pins "no login PATH" — the seam that proves the fallback. Anything
      # else is a misconfiguration, and this module promises not to raise.
      _ -> nil
    end
  end

  @doc """
  Absolute path to `name` on the login-shell `PATH`, else on this process's,
  else `nil`.

  The process `PATH` is checked second rather than not at all: in dev and in
  tests it already carries everything, and a machine where the shell cannot be
  read must not get *worse* answers than it does today.
  """
  @spec find_executable(String.t()) :: String.t() | nil
  def find_executable(name) when is_binary(name) do
    # A name with a separator in it is a path, not a `PATH` lookup, and joining
    # it onto every directory would produce nonsense (`/usr/bin/usr/bin/env`).
    # `System.find_executable/1` already resolves those correctly.
    if String.contains?(name, "/") do
      System.find_executable(name)
    else
      search(name, path()) || System.find_executable(name)
    end
  end

  def find_executable(_name), do: nil

  @doc "Drop the cached `PATH`. For tests, and for a settings-page re-check."
  def refresh do
    # `erase/1` answers `false` for an absent key rather than raising, so there
    # is nothing here to rescue.
    :persistent_term.erase(@cache_key)
    :ok
  end

  # ---------------------------------------------------------------------------

  defp cached_path do
    case :persistent_term.get(@cache_key, :miss) do
      {:ok, value} ->
        value

      # A failure is cached too — re-spawning a login shell on every keystroke of
      # a settings page is the cost this cache exists to avoid — but only for a
      # window, not forever. A *permanent* negative cache turns one slow boot
      # into "no harness installed" for the life of the process, which is the
      # bug this module exists to fix wearing a different hat, and nothing in the
      # UI calls `refresh/0` to undo it.
      {:error, at} ->
        if now_ms() - at >= @retry_after_ms, do: attempt(), else: nil

      :miss ->
        attempt()
    end
  end

  defp attempt do
    case read_login_path() do
      nil ->
        :persistent_term.put(@cache_key, {:error, now_ms()})
        nil

      value ->
        :persistent_term.put(@cache_key, {:ok, value})
        value
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp read_login_path do
    with shell when is_binary(shell) <- login_shell(),
         true <- File.exists?(shell) do
      Enum.find_value(@flags, &read_with_flag(shell, &1))
    else
      _ -> nil
    end
  end

  defp read_with_flag(shell, flag) do
    with {:ok, out} <- run(shell, flag),
         value when is_binary(value) <- fenced_value(out, flag),
         path when path != "" <- String.trim(value) do
      path
    else
      _ -> nil
    end
  end

  # `SHELL` is what launchd hands a GUI app on macOS, but it is not guaranteed
  # anywhere. `/bin/sh` is, and it still sources the system login files, so the
  # fallback can only do better than not asking — and if it answers with
  # launchd's own `PATH`, `find_executable/1` falls through to exactly today's
  # behaviour.
  defp login_shell, do: System.get_env("SHELL") || "/bin/sh"

  # Only what is between the fence posts. Everything a profile printed before
  # the command ran — or a `.zlogout` printed after — is outside them.
  defp fenced_value(out, flag) do
    case Regex.run(@fence, out) do
      [_, value] ->
        value

      _ ->
        Logger.warning("ShellPath: #{flag} output carried no PATH marker")
        nil
    end
  end

  defp run(shell, flag) do
    task =
      Task.async(fn ->
        # The rescue has to be INSIDE the task. `Task.async` links, so an
        # exception here (a `$SHELL` that exists but is not executable raises
        # `:eacces`) would otherwise take down whatever asked — a LiveView, or
        # the settings page — and a `rescue` in the caller cannot see across a
        # process boundary.
        try do
          System.cmd(shell, [flag, @command], stderr_to_stdout: false)
        rescue
          error -> {:raised, Exception.message(error)}
        catch
          kind, reason -> {:raised, "#{inspect(kind)} #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} when is_binary(out) ->
        {:ok, out}

      {:ok, {out, status}} when is_binary(out) ->
        Logger.warning("ShellPath: #{shell} #{flag} exited #{status}")
        :error

      {:ok, {:raised, message}} ->
        Logger.warning("ShellPath: could not run #{shell}: #{message}")
        :error

      _ ->
        Logger.warning("ShellPath: #{shell} #{flag} did not answer in #{@timeout_ms}ms")
        :error
    end
  end

  defp search(_name, nil), do: nil

  # `System.find_executable/1` cannot be pointed at another PATH, so the walk is
  # here. Same rule it applies: first directory containing a regular file with
  # an execute bit wins.
  defp search(name, path) do
    path
    |> String.split(":", trim: true)
    |> Enum.find_value(fn dir ->
      candidate = Path.join(dir, name)
      if executable_file?(candidate), do: candidate
    end)
  end

  defp executable_file?(candidate) do
    case File.stat(candidate) do
      # `type: :regular` follows symlinks, which matters: every version manager
      # installs a symlink, and `~/.local/bin/claude` is one on the dev machine.
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end
end
