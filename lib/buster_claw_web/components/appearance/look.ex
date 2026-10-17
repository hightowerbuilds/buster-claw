defmodule BusterClawWeb.Appearance.Look do
  @moduledoc """
  The two look-and-feel panels on Settings → Appearance: the app theme buttons
  (System / Light / Dark, applied client-side through `phx:set-theme`) and the
  chat's look — which `BusterClaw.ChatSkin` it wears and how large
  `BusterClaw.ChatTextSize` makes its text, with the live transcript preview.

  Extracted from `AppearanceLive.render/1` on 10-16 (CODE_QUALITY_SWEEP Phase 7).
  The two chat forms' events (`set_chat_skin`, `set_chat_text_size`) still land
  in `AppearanceLive`.
  """
  use BusterClawWeb, :html

  alias BusterClaw.ChatTextSize

  @doc "System / Light / Dark. No assigns: the choice lives in the browser."
  def theme_panel(assigns) do
    ~H"""
    <section class="ic-panel space-y-2 p-4">
      <div class="flex items-baseline justify-between gap-2">
        <h2 class="ic-eyebrow">Theme</h2>
        <p class="text-[0.6875rem] text-base-content/55">
          <span class="font-semibold">System</span> follows your OS.
        </p>
      </div>
      <div class="flex flex-wrap gap-2">
        <button
          type="button"
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="system"
          class={theme_btn()}
        >
          <.icon name="hero-computer-desktop" class="size-4" /> System
        </button>
        <button
          type="button"
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="light"
          class={theme_btn()}
        >
          <.icon name="hero-sun" class="size-4" /> Light
        </button>
        <button
          type="button"
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="dark"
          class={theme_btn()}
        >
          <.icon name="hero-moon" class="size-4" /> Dark
        </button>
      </div>
    </section>
    """
  end

  @doc "The chat skin and text size dropdowns, and the transcript they preview on."
  attr :chat_skins, :list, required: true
  attr :chat_skin, :string, required: true
  attr :chat_text_sizes, :list, required: true
  attr :chat_text_size, :string, required: true

  def chat_look_panel(assigns) do
    ~H"""
    <%!-- Compact by design: this lives in a third of the page under the two
          surface panels (one screen, 10-17). The two dropdowns share a row,
          the copy is one line, and the preview takes the width it is given —
          a transcript is narrow anyway, so a narrow column shows it honestly. --%>
    <section class="ic-panel space-y-2 p-4" aria-labelledby="chat-skin-heading">
      <div class="flex items-baseline justify-between gap-2">
        <h2 id="chat-skin-heading" class="ic-eyebrow">Chat theme</h2>
        <p class="text-[0.6875rem] text-base-content/55">Applies the moment you pick it.</p>
      </div>

      <div class="grid gap-2 sm:grid-cols-2">
        <form phx-change="set_chat_skin" class="space-y-1">
          <label for="chat-skin-select" class="ic-eyebrow block">Theme</label>
          <select
            id="chat-skin-select"
            name="skin"
            class="w-full rounded border-2 border-base-content/25 bg-base-100 px-2 py-1 text-xs font-semibold focus:border-primary focus:outline-none"
          >
            <option
              :for={skin <- @chat_skins}
              value={skin.key}
              selected={skin.key == @chat_skin}
            >
              {skin.label}
            </option>
          </select>
        </form>

        <%!-- A separate axis, on purpose: bigger text should not cost you the
              look you picked. The two multiply — every skin's font sizes are
              written as a multiple of this one number. --%>
        <form phx-change="set_chat_text_size" class="space-y-1">
          <label for="chat-text-size-select" class="ic-eyebrow block">Text size</label>
          <select
            id="chat-text-size-select"
            name="size"
            class="w-full rounded border-2 border-base-content/25 bg-base-100 px-2 py-1 text-xs font-semibold focus:border-primary focus:outline-none"
          >
            <option
              :for={size <- @chat_text_sizes}
              value={size.key}
              selected={size.key == @chat_text_size}
            >
              {size.label} · {ChatTextSize.percent(size.key)}%
            </option>
          </select>
        </form>
      </div>

      <p
        :for={skin <- @chat_skins}
        :if={skin.key == @chat_skin}
        data-chat-skin-blurb
        class="line-clamp-1 text-[0.6875rem] leading-4 text-base-content/60"
      >
        {skin.blurb} Text size scales what you read, not the buttons.
      </p>

      <%!-- Clipped with a fade rather than scrolled: the first exchange is
            enough to show the skin and the size, and the whole transcript is
            what put this page past one screen. --%>
      <div class="max-h-24 overflow-hidden rounded border-2 border-base-content/20 bg-base-100 [mask-image:linear-gradient(to_bottom,black_70%,transparent)]">
        <BusterClawWeb.ChatPanel.transcript_preview
          skin={@chat_skin}
          text_size={@chat_text_size}
        />
      </div>
      <%!-- Said rather than implied. The composer's form carries live hooks
            and a `chat_send` submit that would crash this page, so the
            preview is the transcript; and the skins' translucency and
            shadow rules describe a panel over the homepage's shader, which
            a settings page does not have. Both are real gaps, and a
            preview that quietly omitted them would be the kind of promise
            this app keeps getting wrong. --%>
      <p class="text-[0.6875rem] leading-4 text-base-content/50">
        The transcript only — the message box and the panel's own edges are shown on
        the homepage.
      </p>
    </section>
    """
  end

  defp theme_btn,
    do:
      "inline-flex items-center gap-1.5 rounded border-2 border-base-content/30 px-3 py-1.5 text-xs font-semibold transition hover:border-primary hover:text-primary"
end
