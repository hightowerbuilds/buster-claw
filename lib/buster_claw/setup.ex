defmodule BusterClaw.Setup do
  @moduledoc """
  Derived first-run setup progress. Completion is computed from real state
  (settings + connected accounts), not a single flag, so the home CTA can
  reflect partial progress ("2 of 3 complete") and disappear only once every
  tracked step is genuinely done.
  """

  alias BusterClaw.Google
  alias BusterClaw.Settings

  @profile_name_key "profile_name"
  @profile_org_key "profile_org"
  @workspace_confirmed_key "workspace_confirmed"

  @doc "Ordered tracked steps with `:complete` resolved from current state."
  def steps do
    [
      %{key: :profile, label: "Your name or org", complete: profile_complete?()},
      %{key: :workspace, label: "Workspace folder", complete: workspace_complete?()},
      %{key: :google, label: "Google Workspace", complete: google_complete?()}
    ]
  end

  @doc "Summary: `%{steps, completed, total, complete?}`."
  def status do
    steps = steps()
    completed = Enum.count(steps, & &1.complete)
    total = length(steps)

    %{steps: steps, completed: completed, total: total, complete?: completed == total}
  end

  def profile_complete?,
    do: present?(Settings.get(@profile_name_key)) or present?(Settings.get(@profile_org_key))

  def workspace_complete?, do: Settings.get(@workspace_confirmed_key) == "true"
  def google_complete?, do: Google.list_account_summaries() != []

  # --- Profile + workspace persistence -----------------------------------

  def profile_name, do: Settings.get(@profile_name_key, "")
  def profile_org, do: Settings.get(@profile_org_key, "")

  def put_profile(name, org) do
    Settings.put(@profile_name_key, String.trim(to_string(name)))
    Settings.put(@profile_org_key, String.trim(to_string(org)))
    :ok
  end

  def confirm_workspace, do: Settings.put(@workspace_confirmed_key, "true")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
