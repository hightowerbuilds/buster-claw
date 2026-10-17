defmodule BusterClawWeb.Appearance.TerminalPalette do
  @moduledoc """
  The Terminal theme panel on Settings → Appearance: the preset picker (with the
  agent's slot badged), and the operator's own theme — the spectrum slider that
  generates a whole palette from one hue, and the 21-swatch editor.

  Extracted from `AppearanceLive.render/1` on 10-16 (CODE_QUALITY_SWEEP Phase 7).
  Every event here (`generate_custom_theme`, `edit_custom_theme`,
  `close_custom_theme`, `save_custom_theme`, `delete_custom_theme`) still lands
  in `AppearanceLive`, which owns the draft and the `TerminalTheme` writes.
  """
  use BusterClawWeb, :html

  alias BusterClaw.TerminalTheme

  attr :terminal_themes, :list, required: true
  attr :agent_theme, :any, required: true, doc: "the agent's painted theme, or nil"
  attr :custom_theme, :any, required: true, doc: "the operator's saved theme, or nil"
  attr :custom_draft, :any, required: true, doc: "the palette being edited, or nil"
  attr :custom_name, :string, required: true
  attr :custom_hue, :integer, required: true
  attr :custom_error, :any, required: true

  def terminal_theme_panel(assigns) do
    ~H"""
    <section class="ic-panel space-y-4 p-6">
      <h2 class="ic-eyebrow">Terminal theme</h2>
      <p class="max-w-2xl text-sm leading-7 text-base-content/70">
        Color scheme for the in-app terminal — background, text, cursor, and ANSI colors.
        Applies to open terminals immediately.
      </p>
      <div
        id="terminal-theme-picker"
        phx-hook="TermThemePicker"
        class="grid gap-3 sm:grid-cols-2"
      >
        <button
          :for={t <- @terminal_themes}
          type="button"
          phx-click={JS.dispatch("bc:set-term-theme")}
          data-term-theme={t.key}
          title={t.label}
          class="group flex items-center gap-3 rounded-lg border-2 border-base-content/20 p-2.5 text-left transition hover:border-primary focus:outline-none"
        >
          <span
            class="flex size-11 shrink-0 flex-col items-start justify-center gap-1 rounded-md px-2 font-mono"
            style={"background:#{t.swatch.bg}"}
          >
            <span class="text-xs font-bold leading-none" style={"color:#{t.swatch.fg}"}>
              $ ls
            </span>
            <span class="h-1.5 w-5 rounded-full" style={"background:#{t.swatch.accent}"}></span>
          </span>
          <span class="min-w-0">
            <span class="block text-sm font-semibold">{t.label}</span>
            <span class="block font-mono text-xs text-base-content/55">{t.key}</span>
          </span>
          <%!-- The one thing that tells the operator this row is not theirs.
                Marked rather than moved: the agent's theme is selectable
                exactly like any other, and the badge is the whole
                difference. --%>
          <span
            :if={agent_slot?(t, @agent_theme)}
            class="ml-auto shrink-0 rounded border-2 border-primary/60 px-1.5 py-0.5 font-mono text-[0.6rem] font-bold uppercase tracking-wide text-primary"
          >
            Agent
          </span>
        </button>
      </div>

      <%!-- Only when there is one. An explanation of a row that isn't there
            is a promise about a feature the operator hasn't met. --%>
      <p :if={@agent_theme} class="text-xs leading-6 text-base-content/60">
        <span class="font-semibold">{@agent_theme.label}</span>
        is the agent's own slot — it painted that, it is the only theme it can write,
        and its own reset clears it. Select it, keep it, or ignore it; your colours
        below are untouched either way.
      </p>

      <%!-- The custom slot. Creating one means COPYING a preset, which is the
            design rather than a convenience: a copy is always a complete
            22-colour palette, so a custom theme can never be the half-applied
            thing where the background is yours and `ls` is xterm's. It also
            makes the common case one edit.

            Industrial is not offered as a starting point because it has no
            fixed colours to copy — it is resolved from the app's tokens so it
            can follow the light/dark switch. --%>
      <div class="space-y-3 border-t-2 border-base-content/15 pt-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="ic-eyebrow">Your own</h3>
          <div :if={@custom_theme} class="flex gap-2">
            <button
              type="button"
              phx-click="edit_custom_theme"
              class="rounded border-2 border-base-content/25 px-2.5 py-1 font-mono text-[0.62rem] uppercase tracking-wide transition hover:border-primary hover:text-primary"
            >
              Edit colours
            </button>
            <button
              type="button"
              phx-click="delete_custom_theme"
              class="rounded border-2 border-error/50 px-2.5 py-1 font-mono text-[0.62rem] uppercase tracking-wide text-error transition hover:bg-error/10"
            >
              Delete
            </button>
          </div>
        </div>

        <%!-- The spectrum. One number produces all 21 colours, which is what
              keeps a custom theme from ever being half-applied — and it makes
              the first move a drag rather than a form. The hue tints the
              surfaces fully; the program colours are pulled only slightly
              toward it, so red stays red at every position. --%>
        <form phx-change="generate_custom_theme" class="space-y-1.5">
          <div class="flex items-baseline justify-between gap-2">
            <label for="custom-theme-hue" class="ic-eyebrow">Spectrum</label>
            <span class="font-mono text-[0.62rem] uppercase tracking-wide text-base-content/50">
              {@custom_hue}°
            </span>
          </div>
          <input
            id="custom-theme-hue"
            type="range"
            name="hue"
            min={Enum.min(TerminalTheme.hue_range())}
            max={Enum.max(TerminalTheme.hue_range())}
            value={@custom_hue}
            data-hue-slider
            class="ic-hue-slider"
          />
          <p class="text-xs leading-5 text-base-content/60">
            <span :if={is_nil(@custom_theme)}>
              Drag to build a theme — every colour is generated, so program output
              stays themed.
            </span>
            <span :if={@custom_theme}>
              Moving this rebuilds every colour. Edit the swatches below to change
              one at a time.
            </span>
          </p>
        </form>

        <%!-- One form for the whole palette: every input is named for its
              field, so the params are the palette and there is no per-field
              event to keep in step with the field list. Saved on every change
              — the terminal restyles while the picker is still open. --%>
        <%!-- `phx-submit` mirrors `phx-change` and is not decorative: the
              Name field is a text input, so Enter would submit this form
              NATIVELY, reload /appearance, and take the half-built palette
              with it. Same defect found in Studio -> Voice in the 08-15
              packaged build (DMG-review-8-15, finding 3). --%>
        <form
          :if={@custom_draft}
          id="custom-theme-editor"
          phx-change="save_custom_theme"
          phx-submit="save_custom_theme"
          class="space-y-4"
        >
          <div class="space-y-1">
            <label for="custom-theme-name" class="ic-eyebrow block">Name</label>
            <input
              id="custom-theme-name"
              type="text"
              name="name"
              value={@custom_name}
              maxlength="40"
              class="w-full rounded border-2 border-base-content/25 bg-base-100 px-3 py-1.5 text-sm font-semibold focus:border-primary focus:outline-none"
            />
          </div>

          <p :if={@custom_error} role="alert" class="text-sm font-semibold text-error">
            {@custom_error}
          </p>

          <%!-- Three groups rather than 21 swatches in one grid, because they
                answer different questions: what the terminal IS, what programs
                draw with, and what they use for emphasis. Every colour is
                visible — the previous version hid sixteen of them behind a
                collapsed section, which is most of the palette. --%>
          <div
            :for={{title, blurb, fields} <- TerminalTheme.field_groups()}
            data-color-group={title}
            class="space-y-2"
          >
            <div>
              <h4 class="ic-eyebrow">{title}</h4>
              <p class="text-xs leading-5 text-base-content/55">{blurb}</p>
            </div>
            <div class="grid gap-2 sm:grid-cols-2">
              <.color_row
                :for={{field, label} <- fields}
                field={field}
                label={label}
                value={@custom_draft[field]}
              />
            </div>
          </div>

          <div class="flex items-center justify-between gap-3">
            <p class="text-xs leading-5 text-base-content/55">
              Saved as you go, and applied to every open terminal. A custom theme keeps
              its colours when you switch the app between light and dark — only Industrial
              follows that.
            </p>
            <button
              type="button"
              phx-click="close_custom_theme"
              class="shrink-0 rounded border-2 border-base-content/25 px-3 py-1.5 text-sm font-semibold transition hover:border-primary hover:text-primary"
            >
              Done
            </button>
          </div>
        </form>
      </div>
    </section>
    """
  end

  # One palette field: a native colour swatch, its label, and the hex it resolves
  # to.
  #
  # The swatch is the only input — the hex is shown, not typed. A second text input
  # sharing the field's `name` would put two values on the wire for one field, and
  # "pick a colour" is what was asked for; a hex field is a power-user affordance
  # that can be added later without changing the store.
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  defp color_row(assigns) do
    ~H"""
    <label class="flex items-center gap-2 rounded border-2 border-base-content/20 px-2 py-1.5">
      <input
        type="color"
        name={@field}
        value={@value}
        data-color-field={@field}
        aria-label={@label}
        class="size-7 shrink-0 cursor-pointer rounded-sm border-0 bg-transparent p-0"
      />
      <span class="min-w-0 flex-1 truncate text-sm">{@label}</span>
      <span class="shrink-0 font-mono text-[0.62rem] uppercase text-base-content/55">
        {@value}
      </span>
    </label>
    """
  end

  # Whether this picker row is the agent's slot rather than a preset or the
  # operator's own. `nil` means the agent has never painted, so no row is.
  defp agent_slot?(_theme, nil), do: false
  defp agent_slot?(theme, agent), do: theme.key == agent.key
end
