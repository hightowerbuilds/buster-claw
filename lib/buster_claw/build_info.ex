defmodule BusterClaw.BuildInfo do
  @moduledoc """
  What this build *is* — the version it was cut from, and the CPU architecture it
  is actually executing on.

  `UPDATE_ROADMAP` Phase 0 (`G-42`). Until 08-16 the app displayed its own version
  **nowhere**: the only reference in the codebase sends it to Codex
  (`Agent.CodexAppServer`), not to a human. That is fine for an app you re-download
  and fatal for one with an update button, because "Restart and update" beside an
  unknown current version tells the operator nothing about what they are leaving.

  ## One source of truth, and this is not a second one

  `version/0` reads `Application.spec(:buster_claw, :vsn)`, which OTP fills from
  `mix.exs`, which reads the repo-root `VERSION` file — the same file
  `scripts/sync_version.sh` propagates into `tauri.conf.json` and the Rust crate.
  **There is nothing here to keep in sync and no second place to edit.**

  That is load-bearing rather than tidy. The updater compares the running version
  against the feed's, so a build that disagrees with its own `VERSION` is either
  an update loop or a permanent "up to date" on a stale install — and both are
  silent (`UPDATE_ROADMAP` D4).

  ## Why architecture is shown beside it

  Buster Claw ships **two single-arch builds and never a universal binary**: a
  lipo'd ERTS cannot allocate JIT memory on the Intel slice (`APPLE_ROADMAP`
  III.G). So "which build am I running" is a real question with a wrong answer,
  and a support conversation that cannot establish it starts twice.

  `architecture/0` is also what Phase 1 needs to pick a row out of a
  per-architecture `latest.json` — the feed must never hand an Intel bundle to an
  arm64 install, which is the failure mode a universal build would not have had.

  ## Both values are read from the running system, not from a compile-time flag

  `:erlang.system_info(:system_architecture)` reports the ERTS that is executing.
  A build mislabelled by a script still reports itself honestly here, which is the
  property worth having in the one place an operator looks when something is wrong.
  """

  @unknown "unknown"

  @doc """
  The running version, e.g. `"0.1.0"` — or `"unknown"` if the application spec
  cannot be read (it cannot, before the app is loaded).
  """
  @spec version() :: String.t()
  def version do
    case Application.spec(:buster_claw, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      _ -> @unknown
    end
  end

  @doc """
  The bare CPU architecture token — `"aarch64"`, `"x86_64"`, …

  This is the machine-readable half: Phase 1's per-architecture feed keys off it.
  For anything an operator reads, use `architecture_label/0`.
  """
  @spec architecture() :: String.t()
  def architecture do
    :system_architecture
    |> :erlang.system_info()
    |> to_string()
    |> String.split("-", parts: 2)
    |> List.first()
    |> presence()
  end

  @doc """
  The architecture as a person would say it — `"Apple Silicon (aarch64)"`,
  `"Intel (x86_64)"`, or the raw token when it is neither.

  Both halves are shown deliberately. The friendly name is what an operator
  recognises; the token is what they would be asked to read back, and what names
  the artifact they should have downloaded.
  """
  @spec architecture_label() :: String.t()
  def architecture_label do
    case architecture() do
      "aarch64" -> "Apple Silicon (aarch64)"
      "arm64" -> "Apple Silicon (arm64)"
      "x86_64" -> "Intel (x86_64)"
      other -> other
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @unknown
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: @unknown
end
