defmodule BusterClawWeb.WatchlistSidebar do
  @moduledoc """
  The Trading tab's left rail: the operator's watchlists, and what the cache
  actually holds for each symbol.

  ## Why the depth is on every row

  The question this whole surface exists to answer is *why is this chart so
  short?* — the one the Chart Build agent had to guess at on 08-04 because
  nothing recorded it. So each symbol carries its own answer beside it:

    * **year** — a usable year of bars; advanced charts are honest for it
    * **N bars** — short, and short because it is new
    * **failed** — a backfill was tried and did not work, with the date

  Showing "6 bars" without saying which of those it is was the original bug.

  ## The bumper

  Copied from the Workspace tab (`workspace_live.ex`), which is the app's
  cheapest collapse: a `w-2.5` sibling button, a chevron that flips, and a
  boolean in the LiveView. No JS hook and no custom CSS — unlike `CornerWidget`,
  which is a hook and an animation for a job this does not have.

  Collapsed is the default here, where the Workspace defaults open: this tab
  already carries a tab strip, a data panel and floating chat windows.
  """
  use BusterClawWeb, :html

  attr :open, :boolean, required: true
  attr :lists, :map, required: true, doc: "name => [symbol]"
  attr :depths, :map, required: true, doc: "symbol => :deep | {:short, n} | {:failed, on}"
  attr :selected, :string, default: nil

  slot :panel,
    doc: """
    Ticker-shaped content the rail carries above the lists — the Chart Build
    lookup, for instance. Passed in rather than imported: only `TradingLive`
    knows which tab kind is showing, and this component stays a rail.
    """

  def watchlist_sidebar(assigns) do
    ~H"""
    <div class="flex min-h-0 shrink-0">
      <section
        :if={@open}
        class={[
          "ic-panel flex min-h-0 flex-col overflow-hidden p-3",
          if(@panel != [], do: "w-[21rem]", else: "w-[17rem]")
        ]}
      >
        <%!-- The panel and the lists scroll independently inside one
              fixed-height column. That, not the bumper, is the layout problem
              here. --%>
        <div :if={@panel != []} class="shrink-0 space-y-2 pb-3">
          {render_slot(@panel)}
        </div>
        <div class="flex shrink-0 items-baseline justify-between gap-2 pb-2">
          <p class="ic-eyebrow">Watchlists</p>
          <span class="font-mono text-[0.6rem] text-base-content/50">
            {map_size(@lists)} list{if map_size(@lists) == 1, do: "", else: "s"}
          </span>
        </div>

        <form phx-submit="watchlist_create" class="flex shrink-0 gap-1 pb-3">
          <input
            type="text"
            name="name"
            value=""
            autocomplete="off"
            placeholder="New list"
            class="input input-sm min-w-0 flex-1 font-mono text-xs"
          />
          <button type="submit" class="border-2 border-base-content/25 px-2 font-mono text-xs">
            +
          </button>
        </form>

        <p
          :if={@lists == %{}}
          class="border-l-2 border-base-content/20 pl-2 text-xs leading-5 text-base-content/60"
        >
          No lists yet. A watchlist records which symbols you want history for — it
          does not fetch anything on its own.
        </p>

        <div class="min-h-0 flex-1 space-y-4 overflow-y-auto">
          <div :for={{name, symbols} <- Enum.sort(@lists)} class="space-y-1">
            <div class="flex items-baseline justify-between gap-2">
              <p class="truncate font-mono text-xs font-bold uppercase tracking-wide">{name}</p>
              <button
                type="button"
                phx-click="watchlist_delete"
                phx-value-name={name}
                title={"Delete #{name}"}
                aria-label={"Delete list #{name}"}
                class="shrink-0 font-mono text-xs text-base-content/40 hover:text-primary"
              >
                ×
              </button>
            </div>

            <p :if={symbols == []} class="font-mono text-[0.68rem] text-base-content/45">
              empty
            </p>

            <div
              :for={symbol <- symbols}
              class="flex items-center justify-between gap-2 border-l-2 border-base-content/15 pl-2"
            >
              <span class="font-mono text-xs">{symbol}</span>
              <span class="flex shrink-0 items-center gap-1.5">
                <span class={["font-mono text-[0.6rem]", depth_class(@depths[symbol])]}>
                  {depth_label(@depths[symbol])}
                </span>
                <button
                  type="button"
                  phx-click="watchlist_remove"
                  phx-value-name={name}
                  phx-value-symbol={symbol}
                  aria-label={"Remove #{symbol} from #{name}"}
                  class="font-mono text-xs text-base-content/40 hover:text-primary"
                >
                  −
                </button>
              </span>
            </div>

            <form phx-submit="watchlist_add" class="flex gap-1 pt-0.5">
              <input type="hidden" name="name" value={name} />
              <input
                type="text"
                name="symbol"
                value=""
                autocomplete="off"
                placeholder="add ticker"
                class="input input-xs min-w-0 flex-1 font-mono text-[0.68rem] uppercase"
              />
            </form>
          </div>
        </div>

        <p class="shrink-0 border-t-2 border-base-content/15 pt-2 text-[0.6rem] leading-4 text-base-content/50">
          Adding a symbol records intent, not a fetch. A full year of history costs
          one agent run (~$0.57) and arrives on the daily tick, one symbol per day.
        </p>
      </section>

      <%!-- The Workspace tab's bumper, verbatim in shape: a thin sibling button
            and a chevron that flips. No hook, no animation, no CSS of its own. --%>
      <button
        type="button"
        phx-click="watchlist_toggle"
        title={if @open, do: "Collapse watchlists", else: "Expand watchlists"}
        aria-label={if @open, do: "Collapse watchlists", else: "Expand watchlists"}
        aria-expanded={@open}
        class="group flex w-2.5 shrink-0 items-center justify-center border-y-2 border-r-2 border-base-content/15 bg-primary/15 transition hover:bg-primary/30"
      >
        <.icon
          name={if @open, do: "hero-chevron-left", else: "hero-chevron-right"}
          class="size-3 text-primary"
        />
      </button>
    </div>
    """
  end

  # `nil` means the symbol is in a list but has no bars at all yet — distinct
  # from a failure, and the commonest state right after adding one.
  defp depth_label(:deep), do: "year"
  defp depth_label({:short, n}), do: "#{n} bars"
  defp depth_label({:failed, _on}), do: "failed"
  defp depth_label(_none), do: "queued"

  defp depth_class(:deep), do: "text-success"
  defp depth_class({:failed, _on}), do: "text-error"
  defp depth_class({:short, _n}), do: "text-base-content/55"
  defp depth_class(_none), do: "text-base-content/40"
end
