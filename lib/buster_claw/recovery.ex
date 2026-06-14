defmodule BusterClaw.Recovery do
  @moduledoc """
  Read-side helpers for the master recovery key — the Phoenix `secret_key_base`,
  from which every at-rest encryption key is derived (see `BusterClaw.Vault`).

  The Tauri shell owns this key: it stores it in the macOS Keychain and injects
  it at boot. The app only ever *reads* it, to show the user a value they can
  back up, and describes where to drop a saved key to restore on another machine.
  On first launch the shell adopts a `RESTORE_SECRET_KEY` file from the data dir
  if present (see `desktop/tauri/src/main.rs`).
  """

  @doc "The current master key — the value a user should back up. `nil` if unset."
  def recovery_key do
    :buster_claw
    |> Application.get_env(BusterClawWeb.Endpoint, [])
    |> Keyword.get(:secret_key_base)
  end

  @doc """
  Per-machine app data directory the Tauri shell uses for app-internal state.
  Mirrors the shell's `dirs::data_dir()/BusterClaw` and the resolution in
  `config/runtime.exs`.
  """
  def data_dir do
    case :os.type() do
      {:unix, :darwin} ->
        Path.expand("~/Library/Application Support/BusterClaw")

      {:unix, _} ->
        Path.join(
          System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"),
          "BusterClaw"
        )

      _ ->
        Path.expand("~/.buster_claw")
    end
  end

  @doc "Where to drop a saved key on a fresh machine to restore secret access."
  def restore_file_path, do: Path.join(data_dir(), "RESTORE_SECRET_KEY")
end
