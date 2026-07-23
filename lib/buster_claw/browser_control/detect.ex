defmodule BusterClaw.BrowserControl.Detect do
  @moduledoc """
  Find the Chromium-family engine binary for BrowserControl.

  Decision (BROWSER_ENGINE_ROADMAP, 07-22): we drive the user's installed
  Chromium-family browser — never a bundled build. Detection order is
  Chrome → Brave → Edge → Chromium; all speak the same CDP surface. An operator
  can pin an exact binary with config `:browser_control_binary`, which wins over
  detection when it points at something executable.

  Absence is loud by contract: callers surface "no engine" to the user; nothing
  in this app silently degrades to a weaker path when no browser is found.
  """

  # Standard install locations, in preference order. `~` entries cover
  # user-local installs (no-admin machines put apps in ~/Applications).
  @mac_candidates [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "~/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "~/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "~/Applications/Chromium.app/Contents/MacOS/Chromium"
  ]

  @doc "The default candidate paths for this platform, in preference order."
  def candidates, do: Enum.map(@mac_candidates, &Path.expand/1)

  @doc """
  The engine binary to use: the configured override when set and runnable,
  else the first runnable candidate. `{:ok, path}` or `{:error, :no_browser}`.
  """
  def find(paths \\ candidates()) do
    override = Application.get_env(:buster_claw, :browser_control_binary)

    (List.wrap(override) ++ paths)
    |> Enum.find(&runnable?/1)
    |> case do
      nil -> {:error, :no_browser}
      path -> {:ok, path}
    end
  end

  defp runnable?(path) when is_binary(path) do
    case File.stat(path) do
      # Owner-execute bit set on a regular file; the engine is spawned by us,
      # under our uid, so the owner bit is the one that matters.
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o100) != 0
      _ -> false
    end
  end

  defp runnable?(_), do: false
end
