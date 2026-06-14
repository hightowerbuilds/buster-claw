defmodule BusterClaw.Setup do
  @moduledoc """
  Derived first-run setup progress. Completion is computed from real state
  (settings, files on disk, detected CLIs, and connected accounts), not a single
  flag, so the home CTA can reflect partial progress ("2 of 4 complete") and
  disappear only once every tracked step is genuinely done.

  The four derived steps, in order:

    1. `:workspace` — the workspace folder has been confirmed.
    2. `:tools` — the `buster-claw` launcher exists on disk AND an agent CLI
       (`claude` or `codex`) is detected on `PATH`.
    3. `:google` — at least one Google Workspace account is connected.
    4. `:live` — the user has gone live (a `went_live_at` timestamp is set).
  """

  alias BusterClaw.Google
  alias BusterClaw.Settings
  alias BusterClaw.WorkspaceCLI

  @profile_name_key "profile_name"
  @profile_org_key "profile_org"
  @workspace_confirmed_key "workspace_confirmed"
  @went_live_key "went_live_at"

  @doc "Ordered tracked steps with `:complete` resolved from current state."
  def steps do
    [
      %{key: :workspace, label: "Workspace folder", complete: workspace_complete?()},
      %{key: :tools, label: "Tools ready", complete: tools_complete?()},
      %{key: :google, label: "Google Workspace", complete: google_complete?()},
      %{key: :live, label: "Go live", complete: live_complete?()}
    ]
  end

  @doc "Summary: `%{steps, completed, total, complete?}`."
  def status do
    steps = steps()
    completed = Enum.count(steps, & &1.complete)
    total = length(steps)

    %{steps: steps, completed: completed, total: total, complete?: completed == total}
  end

  @doc """
  Whether a name or org profile has been saved. No longer a tracked step, but
  still used by the Settings page, so kept public.
  """
  def profile_complete?,
    do: present?(Settings.get(@profile_name_key)) or present?(Settings.get(@profile_org_key))

  def workspace_complete?, do: Settings.get(@workspace_confirmed_key) == "true"

  @doc "True once the launcher is installed and an agent CLI is on `PATH`."
  def tools_complete? do
    File.exists?(WorkspaceCLI.launcher_path()) and agent_cli_available?()
  end

  def google_complete?, do: Google.list_account_summaries() != []

  @doc "True once the user has gone live (`went_live_at` is set)."
  def live_complete?, do: present?(Settings.get(@went_live_key))

  # --- Profile + workspace persistence -----------------------------------

  def profile_name, do: Settings.get(@profile_name_key, "")
  def profile_org, do: Settings.get(@profile_org_key, "")

  def put_profile(name, org) do
    Settings.put(@profile_name_key, String.trim(to_string(name)))
    Settings.put(@profile_org_key, String.trim(to_string(org)))
    :ok
  end

  def confirm_workspace, do: Settings.put(@workspace_confirmed_key, "true")

  @doc "Record that the user has gone live (timestamped, idempotent overwrite)."
  def mark_went_live,
    do: Settings.put(@went_live_key, DateTime.utc_now() |> DateTime.to_iso8601())

  @doc """
  Whether an agent CLI (`claude` or `codex`) is available.

  PATH lookup first; falls back to the native installer's well-known location
  (`~/.local/bin/claude`) since the BEAM's PATH may not include it until the
  shell is restarted after a fresh install.
  """
  def agent_cli_available? do
    System.find_executable("claude") != nil or
      System.find_executable("codex") != nil or
      File.exists?(Path.expand("~/.local/bin/claude"))
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
