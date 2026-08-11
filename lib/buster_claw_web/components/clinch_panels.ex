defmodule BusterClawWeb.ClinchPanels do
  @moduledoc """
  The two credential panels of the Configuration tab — the Clinch itself, and the
  master recovery key.

  Stateless. They render into `SettingsLive`, but neither is a LiveView form and
  that is the whole point of the design rather than a styling choice.

  ## Why these carry no `phx-` attributes

  A credential typed into a LiveView form travels as a `phx-change` payload,
  lands in the socket's assigns and appears in the rendered diff. That is how
  integration tokens still round-trip to the browser in cleartext today (Clinch
  finding #5), and it is a leak that no amount of `type="password"` prevents.

  So the inputs here are plain DOM. The `ClinchManager` hook reads them, hands
  the value to the desktop shell over Tauri IPC, and clears the field. The server
  learns that a credential changed — never what it is. The only message that
  crosses the channel is `clinch:changed`, which carries nothing.

  The recovery key goes further: it is not rendered at all. `RecoveryKey` reads it
  from the macOS Keychain through the shell and writes it into a node it owns, so
  the value that decrypts every other credential is never a server assign. It used
  to be one on every visit to Settings, revealed or not.

  ## What a remote browser sees

  Both panels degrade honestly. With no `window.__TAURI__` — which is every plain
  browser, including one reached over an SSH tunnel — the hooks hide the controls
  and unhide a notice saying where the work has to happen. No dead button that
  fails on click.
  """

  use BusterClawWeb, :html

  # Mirrors `SettingsLive`'s private helper of the same name so these panels stay
  # visually identical to the sections around them. Duplicated rather than made
  # public there because a two-call-site class string is not worth a module
  # boundary — but if a third panel needs it, promote it instead of copying again.
  defp button_outline,
    do:
      "rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"

  attr :entries, :list, required: true
  attr :unreadable, :map, required: true

  @doc "Every credential the app holds — names and metadata, never values."
  def clinch_panel(assigns) do
    ~H"""
    <section class="ic-panel space-y-4 p-6" id="clinch" phx-hook="ClinchManager">
      <h2 class="ic-eyebrow">The Clinch</h2>
      <p class="text-sm text-base-content/70">
        Every credential Buster Claw holds. Values are encrypted at rest and are
        never shown here — not even the one you just typed.
      </p>

      <p
        data-clinch-unavailable
        hidden
        class="rounded border border-warning/40 bg-warning/10 p-3 text-sm"
      >
        Credentials can only be changed on the Mac running Buster Claw. This page
        is reachable, but adding or removing a credential is not.
      </p>

      <%!-- Invariant 5: a rotated key must never silently unconfigure anything.
            `Encrypted` fails closed and loads an unreadable value as nil, so
            without this the screen below looks IDENTICAL whether nothing is
            stored or everything is stored and unopenable. One is fine; the other
            is an emergency. --%>
      <div
        :if={@unreadable.count > 0}
        class="rounded border-2 border-error/50 bg-error/10 p-3 text-sm"
        role="alert"
      >
        <p class="font-semibold">
          {@unreadable.count} stored credential{if @unreadable.count == 1, do: "", else: "s"} cannot be read with the current master key.
        </p>
        <p class="mt-1 text-xs leading-5">
          Affected: {Enum.join(@unreadable.stores, ", ")}. The values are still on
          disk and still encrypted — they were written under a different key. This
          is what a changed master key looks like, and it is recoverable: restore
          the previous key and the credentials come back. Entering new values here
          will also work, and leaves the old rows unreadable but harmless.
        </p>
      </div>

      <%!-- No phx-change and no phx-submit: the value goes from this input
            straight to the desktop shell, never over the LiveView channel. --%>
      <form data-clinch-form class="space-y-3">
        <div class="grid gap-3 sm:grid-cols-2">
          <label class="text-sm">
            <span class="label mb-1">Kind</span>
            <select data-clinch-kind class="w-full input" aria-label="Credential kind">
              <option value="sign_in">Sign-in ($secret)</option>
            </select>
          </label>
          <label class="text-sm">
            <span class="label mb-1">Name</span>
            <input data-clinch-name type="text" class="w-full input" autocomplete="off" />
          </label>
        </div>
        <label class="block text-sm">
          <span class="label mb-1">Value</span>
          <input
            data-clinch-value
            type="password"
            class="w-full input"
            autocomplete="off"
            spellcheck="false"
          />
        </label>
        <label class="block text-sm">
          <span class="label mb-1">Note (never put the secret here)</span>
          <input data-clinch-note type="text" class="w-full input" autocomplete="off" />
        </label>
        <button type="submit" class={button_outline()}>Store credential</button>
        <p data-clinch-status class="text-xs text-base-content/60" aria-live="polite"></p>
      </form>

      <ul :if={@entries != []} class="divide-y divide-base-300 text-sm">
        <li :for={entry <- @entries} class="flex items-center justify-between py-2">
          <span class="font-mono text-xs">{entry.name}</span>
          <span class="text-xs text-base-content/60">
            {entry.kind}{if not entry.managed?, do: " · read-only"}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  attr :app_keys, :list, required: true

  @doc """
  The app's own service credentials — Twilio, the Supabase relay, Finnhub.

  Registry-driven rather than a free-text form, because unlike a `$secret` these
  have **known names**: the app looks up `twilio_auth_token` by that exact string,
  so letting an operator invent the name would produce a credential that stores
  fine and is never read. One row per `Clinch.AppKeys` entry, and adding a
  credential is a row in that registry rather than markup here.

  **Where each value comes from is the column that matters.** A packaged `.app`
  inherits launchd's environment, not a shell's, so a key that works in your
  terminal can be invisible to the shipped app — and "Environment" against a row
  that a packaged build cannot see is the difference between a mystery and a
  diagnosis.
  """
  def app_keys_panel(assigns) do
    ~H"""
    <section class="ic-panel space-y-4 p-6" id="clinch-app-keys" phx-hook="ClinchAppKeys">
      <h2 class="ic-eyebrow">Service credentials</h2>
      <p class="text-sm text-base-content/70">
        Keys Buster Claw uses on your behalf. Stored encrypted, read at the moment
        of use, and never shown here. Storing one takes effect immediately — no
        restart — and clearing one stops it being used on the next call.
      </p>

      <p
        data-clinch-unavailable
        hidden
        class="rounded border border-warning/40 bg-warning/10 p-3 text-sm"
      >
        Credentials can only be changed on the Mac running Buster Claw. This page
        is reachable, but adding or removing a credential is not.
      </p>

      <div :for={{group, keys} <- @app_keys} class="space-y-3">
        <h3 class="font-mono text-xs uppercase tracking-wide text-base-content/50">{group}</h3>

        <div
          :for={key <- keys}
          class="rounded border-2 border-base-content/15 p-3"
          data-app-key={key.name}
        >
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <span class="text-sm font-semibold">{key.label}</span>
            <span class={[
              "rounded px-2 py-0.5 font-mono text-[0.65rem] uppercase tracking-wide",
              key.source == :clinch && "bg-success/15 text-success",
              key.source == :env && "bg-warning/15 text-warning",
              key.source == :unset && "bg-base-300 text-base-content/60"
            ]}>
              {source_label(key.source)}
            </span>
          </div>

          <p class="mt-1 text-xs leading-5 text-base-content/60">{key.note}</p>

          <p :if={key.source == :env} class="mt-1 text-xs leading-5 text-warning/90">
            Coming from <code class="font-mono">{key.env}</code>. A packaged app cannot
            see variables set in your shell — store it here to make it work outside a
            dev terminal.
          </p>

          <%!-- Plain DOM, no phx-: the value goes to the shell, never over the
                LiveView channel. Same rule as the panel above. --%>
          <div class="mt-2 flex flex-wrap items-center gap-2">
            <input
              data-app-key-value
              type="password"
              class="input min-w-0 flex-1 text-sm"
              autocomplete="off"
              spellcheck="false"
              placeholder={if key.source == :clinch, do: "Replace value", else: "Paste value"}
              aria-label={"New value for #{key.label}"}
            />
            <button type="button" data-app-key-store class={button_outline()}>Store</button>
            <button
              :if={key.source == :clinch}
              type="button"
              data-app-key-clear
              class={button_outline()}
            >
              Clear
            </button>
          </div>

          <p data-app-key-status class="mt-1 text-xs text-base-content/60" aria-live="polite"></p>
        </div>
      </div>
    </section>
    """
  end

  defp source_label(:clinch), do: "Stored"
  defp source_label(:env), do: "Environment"
  defp source_label(:unset), do: "Not set"

  attr :restore_path, :string, required: true

  @doc "The master key — read from the Keychain by the shell, never by the server."
  def recovery_panel(assigns) do
    ~H"""
    <section class="ic-panel space-y-4 p-6" id="recovery-key" phx-hook="RecoveryKey">
      <h2 class="ic-eyebrow">Recovery key</h2>
      <p class="text-sm text-base-content/70">
        This key encrypts every credential Buster Claw stores — Google tokens,
        integration secrets. It lives in your system keychain. Back it up to move
        Buster Claw to another machine; anyone with it can decrypt your data, so
        keep it somewhere safe.
      </p>

      <p
        data-recovery-unavailable
        hidden
        class="rounded border border-warning/40 bg-warning/10 p-3 text-sm"
      >
        The recovery key can only be shown on the Mac running Buster Claw. It is
        read from the system keychain by the desktop app and never reaches this
        page over the network.
      </p>

      <button type="button" data-recovery-toggle class={button_outline()}>Reveal key</button>

      <%!-- Written by the hook, from the Keychain, via the desktop shell. Never
            a server assign. --%>
      <div data-recovery-panel hidden class="space-y-3">
        <input
          data-recovery-value
          type="text"
          readonly
          aria-label="Recovery key"
          class="input w-full font-mono text-xs"
        />
        <p class="text-xs text-base-content/60">
          To restore on a new machine: save this value, then before first launch
          create a file named <code class="font-mono">RESTORE_SECRET_KEY</code>
          containing it at <code class="break-all font-mono">{@restore_path}</code>.
        </p>
      </div>
    </section>
    """
  end
end
