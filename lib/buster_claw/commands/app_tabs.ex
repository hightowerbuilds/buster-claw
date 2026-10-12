defmodule BusterClaw.Commands.AppTabs do
  @moduledoc "Chat-callable app layout operations; website tabs use browser_* instead."
  alias BusterClaw.AppTabs

  def app_tabs_list(_args), do: AppTabs.request(:list)

  def app_tabs_join(%{"tab" => tab} = args) when is_binary(tab) and tab != "" do
    case Map.get(args, "with", "current") do
      other when is_binary(other) and other != "" ->
        AppTabs.request(:join, %{"tab" => tab, "with" => other})

      _ ->
        {:error, :invalid_tab}
    end
  end

  def app_tabs_join(_args), do: {:error, :missing_tab}

  def app_tabs_separate(args) do
    case Map.get(args, "tab", "current") do
      tab when is_binary(tab) and tab != "" -> AppTabs.request(:separate, %{"tab" => tab})
      _ -> {:error, :invalid_tab}
    end
  end
end
