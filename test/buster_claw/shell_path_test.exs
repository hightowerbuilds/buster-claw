defmodule BusterClaw.ShellPathTest do
  @moduledoc """
  The regression suite for the 08-15 DMG's findings 1 and 2: a double-clicked
  `.app` inherits launchd's `PATH`, so `System.find_executable/1` reported
  claude, codex and opencode as missing on a machine carrying all three.

  **`async: false` is load-bearing, twice over.** These tests write the
  `:login_shell_path` app env and the `SHELL` OS env, both of which are global,
  and `ShellPath`'s cache lives in `:persistent_term`, which is global to the
  node. ExUnit runs every async module before any sync one and runs sync modules
  one at a time, so this file can own those three globals as long as it hands
  them back in `on_exit`.
  """
  use ExUnit.Case, async: false

  alias BusterClaw.ShellPath

  # `ShellPath`'s cache key. Reaching for a private detail is deliberate and is
  # the only way to assert `refresh/0` did anything: its whole contract is "the
  # next read is not the cached one".
  @cache_key {BusterClaw.ShellPath, :path}

  setup do
    # Whatever ran before this file may have left a real login PATH cached.
    ShellPath.refresh()
    original_shell = System.get_env("SHELL")

    on_exit(fn ->
      Application.delete_env(:buster_claw, :login_shell_path)
      if original_shell, do: System.put_env("SHELL", original_shell)
      ShellPath.refresh()
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp tmp_dir(context_name) do
    dir =
      Path.join([
        System.tmp_dir!(),
        "shell_path_test",
        "#{context_name}-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # A name nothing on any real PATH could answer to, so "found" can only mean
  # "found in the directory this test made".
  defp unique_name, do: "bc-shellpath-fixture-#{System.unique_integer([:positive])}"

  defp write_executable(dir, name, body \\ "#!/bin/sh\nexit 0\n") do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  defp pin_login_path(value), do: Application.put_env(:buster_claw, :login_shell_path, value)

  # ---------------------------------------------------------------------------

  describe "find_executable/1 against an injected login PATH" do
    # THE test. Everything else in this file is a guard around this one sentence:
    # a binary that exists only where a login shell would look is found anyway.
    test "finds a binary that is on the login PATH and NOT on the process PATH" do
      dir = tmp_dir("login-only")
      name = unique_name()
      expected = write_executable(dir, name)

      # The premise. If this ever stops holding, the test below proves nothing.
      refute System.find_executable(name),
             "fixture leaked onto the process PATH; the test would pass vacuously"

      pin_login_path(dir)

      assert ShellPath.find_executable(name) == expected
    end

    test "a file of the right name without an execute bit is not returned" do
      dir = tmp_dir("not-executable")
      name = unique_name()
      File.write!(Path.join(dir, name), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(dir, name), 0o644)

      pin_login_path(dir)

      refute ShellPath.find_executable(name)
    end

    # Every version manager installs a shim as a symlink, and `~/.local/bin/claude`
    # is one on the machine the DMG bug was measured on. A lookup that skipped
    # symlinks would report exactly the same "not installed" this module exists to
    # stop reporting.
    test "a symlink to a real executable is returned" do
      real_dir = tmp_dir("symlink-target")
      link_dir = tmp_dir("symlink-shim")
      name = unique_name()

      target = write_executable(real_dir, name <> "-real")
      link = Path.join(link_dir, name)
      :ok = File.ln_s!(target, link)

      pin_login_path(link_dir)

      assert ShellPath.find_executable(name) == link
    end

    test "a symlink pointing at nothing is not returned" do
      link_dir = tmp_dir("broken-symlink")
      name = unique_name()
      :ok = File.ln_s!(Path.join(link_dir, "does-not-exist"), Path.join(link_dir, name))

      pin_login_path(link_dir)

      refute ShellPath.find_executable(name)
    end

    test "the first directory on the login PATH wins, as it does for a shell" do
      first = tmp_dir("first")
      second = tmp_dir("second")
      name = unique_name()

      expected = write_executable(first, name)
      write_executable(second, name)

      pin_login_path(Enum.join([first, second], ":"))

      assert ShellPath.find_executable(name) == expected
    end

    test "garbage and empty entries on the login PATH are stepped over, not fatal" do
      dir = tmp_dir("garbage-entries")
      name = unique_name()
      expected = write_executable(dir, name)

      pin_login_path("::/no/such/place:" <> dir <> ":")

      assert ShellPath.find_executable(name) == expected
    end
  end

  describe "falling back to the process PATH" do
    # The promise that makes this safe to land: a machine where the login shell
    # cannot be read must not get *worse* answers than it does today.
    test "with the login PATH pinned to nil, a process-PATH binary is still found" do
      pin_login_path(nil)

      assert ShellPath.path() == nil
      assert found = ShellPath.find_executable("sh")
      assert File.exists?(found)
      assert found == System.find_executable("sh")
    end

    test "a login PATH that lacks the binary still falls through to the process PATH" do
      pin_login_path(tmp_dir("empty-login-path"))

      assert ShellPath.find_executable("sh") == System.find_executable("sh")
    end

    test "a name nothing has is nil, not a crash" do
      pin_login_path(tmp_dir("nothing-here"))

      refute ShellPath.find_executable(unique_name())
    end

    test "a non-binary name is nil rather than a FunctionClauseError" do
      refute ShellPath.find_executable(nil)
      refute ShellPath.find_executable(:sh)
    end

    # `Path.join("/usr/bin", "/usr/bin/env")` is `/usr/bin/usr/bin/env`, so a name
    # that is already a path has to skip the walk entirely.
    test "a name containing a separator is resolved as a path, not joined onto every dir" do
      dir = tmp_dir("separator")
      name = unique_name()
      expected = write_executable(dir, name)

      pin_login_path(dir)

      assert ShellPath.find_executable(expected) == expected
    end
  end

  describe "the app-env seam" do
    test "a pinned string is used verbatim and no shell is run" do
      dir = tmp_dir("verbatim")
      pin_login_path(dir)

      assert ShellPath.path() == dir
      # The seam short-circuits before the cache, so nothing was stored.
      assert :persistent_term.get(@cache_key, :miss) == :miss
    end

    test "a misconfigured seam value is nil, not a CaseClauseError" do
      pin_login_path(:not_a_path)
      assert ShellPath.path() == nil

      pin_login_path(12_345)
      assert ShellPath.path() == nil
    end
  end

  describe "caching and refresh/0" do
    test "a read is cached, and refresh/0 drops it" do
      Application.delete_env(:buster_claw, :login_shell_path)
      ShellPath.refresh()

      # One real login shell, which is what the packaged app does at detection
      # time. Whatever it answers, the answer must then be sticky.
      first = ShellPath.path()
      assert :persistent_term.get(@cache_key, :miss) != :miss

      # Poke a value nothing could have produced. If it comes back, the second
      # read genuinely did not run a shell.
      :persistent_term.put(@cache_key, {:ok, "/sentinel/only/a/test/would/write"})
      assert ShellPath.path() == "/sentinel/only/a/test/would/write"

      assert ShellPath.refresh() == :ok
      assert :persistent_term.get(@cache_key, :miss) == :miss
      assert ShellPath.path() == first
    end

    test "refresh/0 on a cold cache is :ok, not an ArgumentError" do
      :persistent_term.erase(@cache_key)
      assert ShellPath.refresh() == :ok
      assert ShellPath.refresh() == :ok
    end
  end

  describe "a shell that cannot be run" do
    # `read_login_path/0` is only reached with the seam unset, so each of these
    # clears it and then breaks SHELL in a different way. None may raise, and —
    # the sharper half — none may take down the *calling* process. `Task.async`
    # links, so an exception raised inside the spawned task would otherwise kill
    # whichever LiveView asked whether a harness was installed.
    setup do
      Application.delete_env(:buster_claw, :login_shell_path)
      :ok
    end

    test "a SHELL that does not exist yields nil and leaves the caller alive" do
      System.put_env("SHELL", "/no/such/shell-#{System.unique_integer([:positive])}")
      ShellPath.refresh()

      assert ShellPath.path() == nil
      assert Process.alive?(self())
      assert ShellPath.find_executable("sh") == System.find_executable("sh")
    end

    test "a SHELL that exists but is not executable yields nil, not an EXIT" do
      dir = tmp_dir("not-a-shell")
      fake = Path.join(dir, "shell")
      File.write!(fake, "this is not a program\n")
      File.chmod!(fake, 0o644)

      System.put_env("SHELL", fake)
      ShellPath.refresh()

      assert ShellPath.path() == nil
      assert Process.alive?(self())
    end

    test "a SHELL that is a directory yields nil" do
      System.put_env("SHELL", tmp_dir("shell-is-a-dir"))
      ShellPath.refresh()

      assert ShellPath.path() == nil
    end

    test "a shell that exits non-zero without printing a PATH yields nil" do
      dir = tmp_dir("angry-shell")
      shell = write_executable(dir, "shell", "#!/bin/sh\nexit 3\n")

      System.put_env("SHELL", shell)
      ShellPath.refresh()

      assert ShellPath.path() == nil
    end

    test "a shell that exits 0 but prints nothing yields nil rather than an empty PATH" do
      dir = tmp_dir("silent-shell")
      shell = write_executable(dir, "shell", "#!/bin/sh\nexit 0\n")

      System.put_env("SHELL", shell)
      ShellPath.refresh()

      assert ShellPath.path() == nil
    end

    # A failure that is cached FOREVER turns one slow boot into "no harness
    # installed" for the life of the process — the DMG bug wearing a different
    # hat — so the negative entry has to be a timestamp the module can age out.
    test "a failure is cached, but as an expiring entry rather than a flat nil" do
      System.put_env("SHELL", "/no/such/shell-#{System.unique_integer([:positive])}")
      ShellPath.refresh()

      assert ShellPath.path() == nil
      assert {:error, at} = :persistent_term.get(@cache_key, :miss)
      assert is_integer(at)
    end
  end

  describe "which shell flag is used" do
    setup do
      Application.delete_env(:buster_claw, :login_shell_path)
      :ok
    end

    # The measurement that forced this, replayed as a test. `zsh -lc` does not
    # source `.zshrc`, and `.zshrc` is where most people's PATH actually lives —
    # so a login-but-not-interactive read found claude at a DIFFERENT install and
    # did not find codex at all. This fake shell stands in for that: it only adds
    # the interesting directory when it is asked interactively.
    test "the interactive login flag is preferred, because -lc alone misses .zshrc" do
      dir = tmp_dir("interactive-preferred")

      shell =
        write_executable(dir, "shell", """
        #!/bin/sh
        # $1 is the flag. Only an interactive login shell reads .zshrc.
        case "$1" in
          *i*) PATH="/from/zshrc:/from/zprofile" ;;
          *)   PATH="/from/zprofile" ;;
        esac
        export PATH
        /bin/sh -c "$2"
        """)

      System.put_env("SHELL", shell)
      ShellPath.refresh()

      assert ShellPath.path() == "/from/zshrc:/from/zprofile"
    end

    test "a shell that cannot run interactively still answers via the login flag" do
      dir = tmp_dir("no-interactive")

      shell =
        write_executable(dir, "shell", """
        #!/bin/sh
        case "$1" in
          *i*) echo "cannot set terminal process group" >&2; exit 1 ;;
        esac
        PATH="/from/zprofile" /bin/sh -c "$2"
        """)

      System.put_env("SHELL", shell)
      ShellPath.refresh()

      assert ShellPath.path() == "/from/zprofile"
    end

    test "an interactive shell that hangs is capped and the login flag still answers" do
      dir = tmp_dir("interactive-hangs")

      shell =
        write_executable(dir, "shell", """
        #!/bin/sh
        case "$1" in
          *i*) sleep 60 ;;
        esac
        PATH="/from/zprofile" /bin/sh -c "$2"
        """)

      System.put_env("SHELL", shell)
      ShellPath.refresh()

      assert ShellPath.path() == "/from/zprofile"
    end
  end

  describe "a profile that prints on login" do
    setup do
      Application.delete_env(:buster_claw, :login_shell_path)
      :ok
    end

    # Measured, not imagined: `/bin/zsh -lc 'printf %s "$PATH"'` with a two-line
    # `.zprofile` returns `"profile banner line\n/usr/local/bin:..."` on stdout.
    # `String.trim/1` cannot separate those — split on `:` and the first PATH
    # entry becomes the garbage directory `"profile banner line\n/usr/local/bin"`,
    # so the first real entry is silently lost. Hence the fence posts.
    test "a banner printed before the value does not contaminate the PATH" do
      dir = tmp_dir("noisy-profile")

      shell =
        write_executable(dir, "shell", """
        #!/bin/sh
        echo "Welcome to your shell!"
        echo "nvm: using node v20.0.0"
        PATH="/injected/one:/injected/two" /bin/sh -c "$2"
        """)

      System.put_env("SHELL", shell)
      ShellPath.refresh()

      assert ShellPath.path() == "/injected/one:/injected/two"
    end

    test "a .zlogout-style banner printed after the value is discarded too" do
      dir = tmp_dir("trailing-noise")

      shell =
        write_executable(dir, "shell", """
        #!/bin/sh
        PATH="/injected/one" /bin/sh -c "$2"
        echo "goodbye, and thanks"
        """)

      System.put_env("SHELL", shell)
      ShellPath.refresh()

      assert ShellPath.path() == "/injected/one"
    end

    # The nastiest shape, because a banner with a colon in it does not just
    # corrupt one entry — it invents a whole extra directory.
    test "a banner containing a colon is still excluded, end to end" do
      dir = tmp_dir("colon-banner")
      bin = tmp_dir("colon-banner-bin")
      name = unique_name()
      expected = write_executable(bin, name)

      shell =
        write_executable(dir, "shell", """
        #!/bin/sh
        echo "warning: /opt/rvm/bin is not writable"
        PATH="#{bin}" /bin/sh -c "$2"
        """)

      System.put_env("SHELL", shell)
      ShellPath.refresh()

      assert ShellPath.path() == bin
      assert ShellPath.find_executable(name) == expected
    end

    # Break the guard and watch it fail: with the fence removed, this is exactly
    # what a trim-only implementation would have returned.
    test "the raw shell output really is contaminated, so the fence is doing work" do
      dir = tmp_dir("proof")

      shell =
        write_executable(dir, "shell", """
        #!/bin/sh
        echo "Welcome to your shell!"
        PATH="/injected/one" /bin/sh -c "$2"
        """)

      {raw, 0} = System.cmd(shell, ["-lc", "printf %s \"$PATH\""], stderr_to_stdout: false)

      assert String.trim(raw) == "Welcome to your shell!\n/injected/one"
      assert String.split(String.trim(raw), ":", trim: true) == [raw |> String.trim()]
    end

    # Profiles that write to stderr are the common case (rbenv, direnv, brew
    # doctor nags). `stderr_to_stdout: false` is what keeps them out.
    test "a profile that writes to stderr does not contaminate the PATH" do
      dir = tmp_dir("stderr-profile")

      shell =
        write_executable(dir, "shell", """
        #!/bin/sh
        echo "direnv: loading .envrc" >&2
        PATH="/injected/one" /bin/sh -c "$2"
        """)

      System.put_env("SHELL", shell)
      ShellPath.refresh()

      assert ShellPath.path() == "/injected/one"
    end

    # A profile that prints and then never returns must be a hiccup, not a hang.
    @tag timeout: 30_000
    test "a shell that never answers is abandoned and yields nil" do
      dir = tmp_dir("hanging-shell")
      shell = write_executable(dir, "shell", "#!/bin/sh\nsleep 60\n")

      System.put_env("SHELL", shell)
      ShellPath.refresh()

      {elapsed_us, result} = :timer.tc(fn -> ShellPath.path() end)

      assert result == nil
      assert Process.alive?(self())
      assert elapsed_us < 10_000_000, "the 3s cap did not hold: #{div(elapsed_us, 1000)}ms"
    end
  end
end
