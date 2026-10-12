defmodule BusterClaw.Commands.Catalog.AppTabs do
  @moduledoc false

  def entries do
    [
      %{
        name: "app_tabs_list",
        type: :read,
        tier: :safe,
        args: %{},
        description:
          "List open Buster Claw app tabs, the current tab, and joined panes. Requires an open app window. These are app tabs, not website tabs."
      },
      %{
        name: "app_tabs_join",
        type: :trigger,
        tier: :safe,
        description:
          "Join two app tabs side by side. For 'join the browser with this chat', use tab: browser (with defaults to current). Reuses an already open tab and its browser session; opens a supported view if absent. Use exact paths from app_tabs_list when several tabs match. Already joined pairs are unchanged.",
        args: %{
          "tab" => %{
            type: :string,
            required: true,
            description:
              "Tab path or unique label; browser, chat, home, and terminal are accepted."
          },
          "with" => %{
            type: :string,
            required: false,
            default: "current",
            description: "Other tab to join, defaulting to the current app tab."
          }
        }
      },
      %{
        name: "app_tabs_separate",
        type: :trigger,
        tier: :safe,
        description:
          "Separate a joined app tab into its original two tabs, keeping both open and preserving browser sessions. Defaults to the current joined tab; keeps the chat visible when present.",
        args: %{
          "tab" => %{
            type: :string,
            required: false,
            default: "current",
            description: "Joined tab path from app_tabs_list, or current."
          }
        }
      }
    ]
  end
end
