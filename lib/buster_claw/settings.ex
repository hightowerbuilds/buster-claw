defmodule BusterClaw.Settings do
  @moduledoc """
  Phoenix-owned key/value store for global app preferences that do not need to
  exist before boot (onboarding state, theme, future global prefs).

  The workspace folder location is intentionally NOT stored here — it must be
  known by the Tauri shell before Phoenix boots, so it lives in a Tauri-owned
  `workspace.json` and reaches Phoenix via the `BUSTER_CLAW_WORKSPACE_ROOT` env
  var (see `BusterClaw.Library.Artifact.workspace_root/0`).
  """

  alias BusterClaw.Repo
  alias BusterClaw.Settings.Setting

  @onboarding_key "onboarding_completed_at"

  @doc "Fetch a raw string setting by key, returning `default` when unset."
  def get(key, default \\ nil) when is_binary(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> default
      %Setting{value: nil} -> default
      %Setting{value: value} -> value
    end
  end

  @doc "Upsert a setting. `value` is stored as a string (nil clears it)."
  def put(key, value) when is_binary(key) do
    attrs = %{key: key, value: stringify(value)}

    case Repo.get_by(Setting, key: key) do
      nil -> %Setting{}
      %Setting{} = existing -> existing
    end
    |> Setting.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Return all settings as a plain `%{key => value}` map."
  def get_all do
    Setting
    |> Repo.all()
    |> Map.new(fn %Setting{key: key, value: value} -> {key, value} end)
  end

  @doc "Delete a setting by key. Returns `:ok` regardless of prior existence."
  def delete(key) when is_binary(key) do
    case Repo.get_by(Setting, key: key) do
      nil ->
        :ok

      %Setting{} = setting ->
        case Repo.delete(setting) do
          {:ok, _} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  # --- Onboarding helpers -------------------------------------------------

  @doc "Whether the first-run setup wizard has been completed."
  def onboarding_completed?, do: get(@onboarding_key) not in [nil, ""]

  @doc "Timestamp the onboarding wizard completion (idempotent-ish: overwrites)."
  def mark_onboarding_complete do
    put(@onboarding_key, DateTime.utc_now() |> DateTime.to_iso8601())
  end

  @doc "Clear the onboarding flag so the wizard runs again."
  def reset_onboarding, do: delete(@onboarding_key)

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
