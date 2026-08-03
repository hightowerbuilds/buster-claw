defmodule BusterClawWeb.TradingTabStrip do
  @moduledoc """
  The Trading page's tab strip — one typed conversation per tab.

  The strip doubles as the dock target: a floating chat window dragged onto it
  becomes a sub-tab again, which is why it carries `data-tab-dropzone` and the
  `bc-dropzone-active` class the ChatWindow hook toggles.

  Presentation only — `TradingLive` owns the tab list, the active id, and every
  event this emits.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Trading

  attr :tabs, :list, required: true
  attr :active, :string, required: true
  attr :menu_open, :boolean, required: true
  attr :open_chats, :list, required: true

  def trading_tabs(assigns) do
    ~H"""
    <%!-- The strip doubles as the dock target: drag a floating chat onto it and
          it becomes a sub-tab. `bc-dropzone-active` is toggled by the ChatWindow
          hook while a window is over it. --%>
    <div
      id="trading-tab-strip"
      data-tab-dropzone
      class="relative flex items-center gap-1 rounded-sm border-2 border-transparent px-1 py-0.5 transition"
      role="tablist"
      aria-label="Trading tabs"
    >
      <div
        :for={tab <- @tabs}
        id={"trading-tab-#{tab.id}"}
        role="tab"
        aria-selected={to_string(tab.id == @active)}
        phx-click="trading_select_tab"
        phx-value-id={tab.id}
        class={[
          "group flex shrink-0 cursor-pointer items-center gap-1.5 rounded-t-sm border-2 px-2.5 py-1.5 font-mono text-xs transition",
          if(tab.id == @active,
            do: "border-base-content/30 bg-base-200 text-base-content",
            else: "border-base-content/15 bg-base-200/40 text-base-content/55 hover:text-base-content"
          )
        ]}
      >
        <%!-- The kind is written, not merely coloured: which surface a tab can
              reach is the single most important thing about it. --%>
        <span class={[
          "shrink-0 border px-1 text-[0.55rem] font-black uppercase tracking-wider",
          if(tab.kind == "research",
            do: "border-info/50 text-info",
            else: "border-success/50 text-success"
          )
        ]}>
          {Trading.kind_badge(tab.kind)}
        </span>
        <span
          :if={tab.docked}
          title="This chat is docked into the tab"
          class="shrink-0 font-mono text-[0.6rem] text-base-content/40"
        >
          ⊞
        </span>
        <span
          :if={tab.running}
          class="size-2 shrink-0 animate-pulse rounded-full bg-primary"
          title="Working"
        >
        </span>
        <span
          :if={tab.unread and tab.id != @active}
          class="size-2 shrink-0 rounded-full bg-warning"
          title="New messages"
        >
        </span>
        <span class="max-w-[10rem] truncate font-medium">{tab.title}</span>
        <%!-- Opening a chat is separate from selecting a tab, because the two are
              now separate things: the tab decides the panel, the window decides
              which conversation you are talking to. --%>
        <span
          phx-click="trading_toggle_chat"
          phx-value-id={tab.id}
          title={if tab.id in @open_chats, do: "Close this chat window", else: "Open this chat"}
          class={[
            "grid size-4 shrink-0 place-items-center rounded-sm transition hover:bg-base-content/15",
            if(tab.id in @open_chats,
              do: "text-primary",
              else: "text-base-content/40 hover:text-base-content"
            )
          ]}
        >
          <.icon name="hero-chat-bubble-left" class="size-3.5" />
        </span>
        <span
          phx-click="trading_close_tab"
          phx-value-id={tab.id}
          title="Close tab"
          class="ml-0.5 grid size-4 shrink-0 place-items-center rounded-sm text-base-content/40 hover:bg-base-content/15 hover:text-primary"
        >
          ×
        </span>
      </div>

      <button
        id="trading-new-tab"
        type="button"
        phx-click="trading_new_tab_menu"
        title="New tab"
        aria-label="New tab"
        aria-expanded={to_string(@menu_open)}
        class="grid size-7 shrink-0 place-items-center rounded-sm border-2 border-base-content/20 font-mono text-base-content/70 transition hover:border-primary hover:text-primary"
      >
        +
      </button>

      <div
        :if={@menu_open}
        id="trading-new-tab-menu"
        class="absolute left-0 top-full z-20 mt-1 w-56 border-2 border-base-content/25 bg-base-100 font-mono text-xs shadow-[3px_3px_0_0_oklch(var(--bc)/0.15)]"
      >
        <%!-- Chat leads: it is the neutral one, and it can be pointed at either
              of the others afterwards. --%>
        <button
          type="button"
          phx-click="trading_new_tab"
          phx-value-kind="chat"
          class="block w-full px-3 py-2 text-left transition hover:bg-base-content/10"
        >
          <span class="font-black uppercase tracking-wide">Chat</span>
          <span class="block text-[0.68rem] text-base-content/60">
            Opens as a sub-tab · float it from its title bar
          </span>
        </button>
        <button
          type="button"
          phx-click="trading_new_tab"
          phx-value-kind="robinhood"
          class="block w-full border-t-2 border-base-content/15 px-3 py-2 text-left transition hover:bg-base-content/10"
        >
          <span class="font-black uppercase tracking-wide text-success">Robinhood</span>
          <span class="block text-[0.68rem] text-base-content/60">
            Your accounts, positions and orders
          </span>
        </button>
        <button
          type="button"
          phx-click="trading_new_tab"
          phx-value-kind="research"
          class="block w-full border-t-2 border-base-content/15 px-3 py-2 text-left transition hover:bg-base-content/10"
        >
          <span class="font-black uppercase tracking-wide text-info">Research</span>
          <span class="block text-[0.68rem] text-base-content/60">
            Public quotes and filings — no account access
          </span>
        </button>
      </div>
    </div>
    """
  end
end
