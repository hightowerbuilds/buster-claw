defmodule BusterClawWeb.GwsPanels do
  @moduledoc """
  The Google Workspace console of the Configuration tab (`SettingsLive`): a tab
  rail, and the pane the active tab dispatches to.

  Stateless — every `phx-submit`/`phx-click` bubbles to the parent LiveView,
  which owns all account/Gmail/Calendar state and event handling.

  ## What lives where

  This module is the **rail and the dispatch**. The panes are `import`ed, so a
  dispatch line still reads `<.search_pane …>` as it did when all five lived
  inside one three-hundred-line function.

  | Module | Holds |
  |---|---|
  | `Gws.Registry` | the `{key, label, icon}` tab list — **add a tab here** |
  | `Gws.Accounts` | the connected-accounts list |
  | `Gws.Mail` | search, labels, sync-to-Library |
  | `Gws.CalendarSync` | Google Calendar sync |
  | `Gws.Shared` | the `tool_pane` shell and the account formatters |

  Splitting the panes made each one declare the assigns it actually reads, and
  they turn out to barely overlap: every pane needs `accounts` (for the account
  picker) and then only its own form and result.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Gws.Accounts
  import BusterClawWeb.Gws.CalendarSync
  import BusterClawWeb.Gws.Mail

  alias BusterClawWeb.Gws.Registry

  @doc "The console's tab keys, in display order (for the parent's tab guard)."
  defdelegate console_tab_keys, to: Registry

  attr :active_tab, :atom, required: true
  attr :accounts, :list, required: true
  attr :gmail_label_form, :any, required: true
  attr :gmail_search_form, :any, required: true
  attr :gmail_sync_form, :any, required: true
  attr :gmail_labels, :list, required: true
  attr :gmail_search, :any, default: nil
  attr :gmail_search_account_id, :any, default: nil
  attr :gmail_sync, :any, default: nil
  attr :gmail_message, :any, default: nil
  attr :calendar_sync_form, :any, required: true
  attr :calendar_sync, :any, default: nil

  @doc """
  The Google Workspace console: a tab rail on the left, one pane on the right.

  The parent owns `active_tab` and validates it against `console_tab_keys/0`.
  """
  def workspace_console(assigns) do
    assigns = assign(assigns, :tabs, Registry.console_tabs())

    ~H"""
    <div id="gws-console" class="grid gap-4 lg:grid-cols-[13rem_minmax(0,1fr)]">
      <nav
        id="gws-console-tabs"
        aria-label="Google Workspace tools"
        class="flex gap-1 overflow-x-auto rounded-lg border border-base-300 bg-base-100 p-1 lg:flex-col lg:overflow-visible"
      >
        <button
          :for={{key, label, icon} <- @tabs}
          type="button"
          id={"gws-tab-#{key}"}
          phx-click="gws_tab"
          phx-value-tab={key}
          aria-current={@active_tab == key && "page"}
          class={[
            "flex items-center gap-2 whitespace-nowrap rounded px-3 py-2 text-left text-sm font-semibold transition",
            if(@active_tab == key,
              do: "bg-base-content text-base-100",
              else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
            )
          ]}
        >
          <.icon name={icon} class="size-4 shrink-0" />
          <span>{label}</span>
        </button>
      </nav>

      <div id="gws-console-main" class="min-w-0">
        <.accounts_panel :if={@active_tab == :accounts} accounts={@accounts} />

        <.search_pane
          :if={@active_tab == :search}
          accounts={@accounts}
          gmail_search_form={@gmail_search_form}
          gmail_search={@gmail_search}
          gmail_search_account_id={@gmail_search_account_id}
          gmail_message={@gmail_message}
        />

        <.labels_pane
          :if={@active_tab == :labels}
          accounts={@accounts}
          gmail_label_form={@gmail_label_form}
          gmail_labels={@gmail_labels}
        />

        <.sync_mail_pane
          :if={@active_tab == :sync_mail}
          accounts={@accounts}
          gmail_sync_form={@gmail_sync_form}
          gmail_sync={@gmail_sync}
        />

        <.calendar_pane
          :if={@active_tab == :calendar}
          accounts={@accounts}
          calendar_sync_form={@calendar_sync_form}
          calendar_sync={@calendar_sync}
        />
      </div>
    </div>
    """
  end
end
