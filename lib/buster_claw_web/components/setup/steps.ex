defmodule BusterClawWeb.Setup.Steps do
  @moduledoc """
  The first-run wizard's five screens, one function component each, plus the
  dots, the Back/Next row, the tool-status row and the three button classes
  they share.

  Extracted from `SetupLive.render/1` on 10-16 (CODE_QUALITY_SWEEP Phase 7).
  Every event (`next`, `back`, `goto`, `confirm_workspace`, `install_claude`,
  `recheck_tools`, `validate_google`, `connect_google`,
  `bundled_connect_google`, `open_google_sign_in`, `go_live`) still lands in
  `SetupLive`, which owns the step and every assign passed in here. A step
  takes exactly the assigns it reads, so the `attr` list is the honest record
  of what each screen depends on.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Google.OAuth, as: GoogleOAuthCore
  alias BusterClawWeb.GoogleOAuth

  @doc "The explainer landing. Not a dot."
  def welcome_step(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="ic-panel space-y-4 p-6">
        <h1 class="font-display text-3xl font-black uppercase tracking-tight">
          An assistant on your Mac that uses your tools, keeps working, and shows you what it did
        </h1>
        <p class="text-sm leading-7 text-base-content/80">
          Ask it in Chat, or email it and it answers. While a shift is open your trusted
          contacts can give it work too, and it gets on with it: reading mail, browsing the
          web, handling tasks, and replying for you.
        </p>
        <ul class="space-y-2 text-sm leading-7 text-base-content/80">
          <li>
            <span class="font-semibold">It uses your tools</span>
            — Gmail, Calendar, the web, your files.
          </li>
          <li>
            <span class="font-semibold">It keeps working</span>
            — go on duty and it works a durable queue while you're away.
          </li>
          <li>
            <span class="font-semibold">It shows you what it did</span>
            — every change lands on an audit feed you can read.
            <span class="font-semibold">Go on duty</span>
            and <span class="font-semibold">Stand down</span>
            are both one button in the dock at
            the bottom of the screen.
          </li>
        </ul>
        <%!-- "Everything runs on your machine" was the old line here and it was
        too easy to read as "my data never leaves this computer". The app and
        its records are local; prompts and the content they touch go to the AI
        service you choose, and connected actions reach Google and the rest.
        `VI-h`. --%>
        <p class="text-sm leading-7 text-base-content/60">
          Buster Claw keeps its files and records on your Mac. When you ask it to work, what it
          needs goes to the AI service you choose and to any account you connect. Four quick
          steps and you're live.
        </p>
      </div>
      <div class="flex justify-end">
        <button type="button" phx-click="next" class={button_primary()}>Get started</button>
      </div>
    </div>
    """
  end

  @doc "Step 1 · the folder the assistant works in."
  attr :workspace_root, :string, required: true
  attr :workspace_note, :any, required: true

  def workspace_step(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="ic-panel space-y-4 p-6">
        <h2 class="font-display text-xl font-black uppercase tracking-tight">Pick your folder</h2>
        <p class="text-sm leading-7 text-base-content/80">
          This is where your assistant keeps its files. You can move it later.
        </p>

        <div>
          <p class="ic-eyebrow">Folder</p>
          <p class="mt-1 break-words font-mono text-sm">{@workspace_root}</p>
        </div>

        <p
          :if={@workspace_note}
          class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
        >
          {@workspace_note}
        </p>

        <div class="flex flex-wrap items-center gap-3">
          <button type="button" phx-click="confirm_workspace" class={button_outline()}>
            Use this folder
          </button>
          <.link navigate={~p"/workspace"} class="text-sm text-primary underline">
            Change…
          </.link>
        </div>
      </div>
      <.step_nav />
    </div>
    """
  end

  @doc "Step 2 · the launcher and Claude Code."
  attr :launcher_ready, :boolean, required: true
  attr :claude_ready, :boolean, required: true
  attr :claude_install_command, :string, required: true
  attr :tools_note, :any, required: true

  def tools_step(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="ic-panel space-y-5 p-6">
        <h2 class="font-display text-xl font-black uppercase tracking-tight">
          Get the tools ready
        </h2>
        <p class="text-sm leading-7 text-base-content/80">
          Your assistant runs as Claude Code. We'll set it up — no terminal knowledge needed.
        </p>

        <.tool_row ready={@launcher_ready} label="Buster Claw" detail="ready to go" />

        <div class="space-y-3">
          <.tool_row
            ready={@claude_ready}
            label="Claude Code"
            detail={if @claude_ready, do: "installed", else: "not installed yet"}
          />

          <div :if={not @claude_ready} class="space-y-3 pl-7">
            <p class="text-sm leading-6 text-base-content/70">
              Install it once. We'll open a terminal with the command ready — press enter to run
              it, then come back and Re-check.
            </p>
            <pre class="overflow-x-auto rounded-sm border-2 border-base-content/20 bg-base-200 px-3 py-2 font-mono text-xs">{@claude_install_command}</pre>
            <div class="flex flex-wrap gap-3">
              <button type="button" phx-click="install_claude" class={button_primary()}>
                Install Claude Code
              </button>
              <button type="button" phx-click="recheck_tools" class={button_outline()}>
                Re-check
              </button>
            </div>
          </div>
        </div>

        <p
          :if={@tools_note}
          class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
        >
          {@tools_note}
        </p>
      </div>
      <.step_nav />
    </div>
    """
  end

  @doc "Step 3 · Google Workspace: one-click bundled connect, or your own OAuth app."
  attr :bundled_available, :boolean, required: true
  attr :google_form, :any, required: true
  attr :google_default_query, :string, required: true
  attr :google_auth_url, :any, required: true
  attr :google_note, :any, required: true
  attr :google_accounts, :list, required: true

  def google_step(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="ic-panel space-y-4 p-6">
        <h2 class="font-display text-xl font-black uppercase tracking-tight">
          Connect your Google Workspace
        </h2>
        <p class="text-sm leading-7 text-base-content/80">
          Buster Claw manages your Google Workspace on your behalf — Gmail, Calendar, Drive,
          Docs, Sheets, Slides, Contacts and Tasks. The consent screen will list each of these
          permissions, so approve them all to give your agent full access. {GoogleOAuth.reconnect_sentence()} Once it's done, emails from you are trusted
          automatically — and every action taken with this access lands in the Sentinel audit
          feed (Settings → Security), so you can always see exactly what your agent did.
        </p>

        <p
          :if={@bundled_available and GoogleOAuth.beta_testing?()}
          class="max-w-2xl rounded-sm border-2 border-base-content/15 bg-base-200/60 px-3 py-2 text-xs leading-5 text-base-content/70"
        >
          <%!-- The reconnect cadence deliberately is NOT repeated here: it belongs to
          `GoogleOAuth.reconnect_sentence/0` and is stated once, above. This note carries
          the other half of the unverified-app limit: the approved-tester list, and the
          one symptom that means you are not on it.

          Naming the symptom is the whole point. While the OAuth app is in Testing,
          an address that is not on the list never reaches our callback at all —
          Google stops the flow on its own "Access blocked" page. So the app cannot
          detect this, cannot report it, and cannot recover from it: the wizard just
          sits on step 3 looking broken. The only defence available to us is telling
          the user in advance what that screen means. --%>
          <span class="font-semibold">Beta note:</span>
          Google limits this app to an approved-tester list right now.
          <a href={GoogleOAuth.beta_request_mailto()} class="underline hover:text-base-content">
            Request access
          </a>
          with the Gmail address you'll connect, and you'll get a confirmation within a day.
          <span class="font-semibold">
            If Google shows an "Access blocked" screen saying this app "has not completed
            the Google verification process", that address isn't on the list yet —
            it isn't a fault in Buster Claw, and nothing here can fix it.
          </span>
          Request access, then come back to this step.
        </p>

        <%!-- One-click connect via the bundled OAuth client: nothing to
        type — the address is learned from the connection itself. --%>
        <div :if={@bundled_available} class="space-y-2">
          <button
            type="button"
            id="setup-bundled-connect"
            phx-click="bundled_connect_google"
            class={button_primary()}
          >
            Connect Google
          </button>
          <p class="text-sm text-base-content/60">
            One click — pick your account in the browser and approve.
          </p>
        </div>

        <details
          id="setup-google-advanced"
          open={!@bundled_available}
          class={@bundled_available && "border-t-2 border-base-content/15 pt-4"}
        >
          <summary class="cursor-pointer text-sm font-semibold text-base-content/70">
            Advanced: use your own OAuth app
          </summary>
          <.form
            for={@google_form}
            id="setup-google-form"
            phx-change="validate_google"
            phx-submit="connect_google"
            class="mt-3 space-y-3"
          >
            <.input
              field={@google_form[:email]}
              type="email"
              label="Google email"
              autocomplete="off"
            />
            <.input field={@google_form[:client_id]} label="OAuth client ID" autocomplete="off" />
            <.input
              field={@google_form[:client_secret]}
              type="password"
              label="OAuth client secret"
              autocomplete="off"
            />
            <input
              type="hidden"
              name="google_account[scopes]"
              value={GoogleOAuthCore.default_scope_string()}
            />
            <input
              type="hidden"
              name="google_account[default_query]"
              value={@google_default_query}
            />
            <button type="submit" class={button_outline()}>Save Google account</button>
          </.form>
        </details>

        <div :if={@google_auth_url} class="space-y-2 border-t-2 border-base-content/15 pt-4">
          <button type="button" phx-click="open_google_sign_in" class={button_primary()}>
            Open Google sign-in
          </button>
          <p class="break-words font-mono text-xs text-base-content/60">{@google_auth_url}</p>
        </div>

        <p
          :if={@google_note}
          class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
        >
          {@google_note}
        </p>

        <p :if={@google_accounts != []} class="text-sm text-base-content/70">
          Connected: {Enum.map_join(@google_accounts, ", ", & &1.email)}
        </p>
      </div>
      <.step_nav />
    </div>
    """
  end

  @doc "Step 4 · the checklist and the button that opens the terminal."
  attr :status, :map, required: true

  def live_step(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="ic-panel space-y-4 p-6">
        <h2 class="font-display text-xl font-black uppercase tracking-tight">Start working</h2>
        <p class="text-sm leading-7 text-base-content/80">
          You're ready. Open the terminal and press enter — your assistant starts watching your
          inbox. Email yourself a task to try it.
        </p>

        <ul class="space-y-2 text-sm">
          <li :for={s <- @status.steps} class="flex items-center gap-2">
            <.icon
              name={if s.complete, do: "hero-check-circle-solid", else: "hero-minus-circle"}
              class={[
                "size-5 shrink-0",
                if(s.complete, do: "text-success", else: "text-base-content/40")
              ]}
            />
            <span class={if s.complete, do: "", else: "text-base-content/60"}>{s.label}</span>
          </li>
        </ul>

        <div class="flex flex-wrap gap-3 pt-1">
          <button type="button" phx-click="go_live" class={button_primary()}>
            Open terminal &amp; go live
          </button>
        </div>
      </div>
      <div class="flex justify-start">
        <button type="button" phx-click="back" class={button_ghost()}>Back</button>
      </div>
    </div>
    """
  end

  # --- Dots / nav / row components ----------------------------------------

  attr :steps, :list, required: true
  attr :current, :atom, required: true

  def step_dots(assigns) do
    ~H"""
    <ol class="flex items-start justify-between gap-2">
      <li :for={s <- @steps} class="flex flex-1 flex-col items-center gap-2 text-center">
        <button
          type="button"
          phx-click="goto"
          phx-value-step={s.key}
          class={[
            "flex size-7 items-center justify-center rounded-full border-2 transition",
            dot_classes(s, @current)
          ]}
        >
          <.icon :if={s.complete} name="hero-check-mini" class="size-4" />
        </button>
        <span class={[
          "font-mono text-[0.65rem] uppercase tracking-wide",
          if(s.key == @current, do: "text-primary", else: "text-base-content/55")
        ]}>
          {s.label}
        </span>
      </li>
    </ol>
    """
  end

  # Filled = complete; ringed = current; muted = not yet.
  defp dot_classes(%{complete: true}, _current),
    do: "border-success bg-success text-success-content"

  defp dot_classes(%{key: key}, current) when key == current,
    do: "border-primary bg-primary/15 text-primary"

  defp dot_classes(_step, _current), do: "border-base-content/25 text-base-content/40"

  def step_nav(assigns) do
    ~H"""
    <div class="flex justify-between">
      <button type="button" phx-click="back" class={button_ghost()}>Back</button>
      <button type="button" phx-click="next" class={button_primary()}>Next →</button>
    </div>
    """
  end

  attr :ready, :boolean, required: true
  attr :label, :string, required: true
  attr :detail, :string, required: true

  def tool_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <.icon
        name={if @ready, do: "hero-check-circle-solid", else: "hero-arrow-down-circle"}
        class={["size-5 shrink-0", if(@ready, do: "text-success", else: "text-base-content/40")]}
      />
      <span class="text-sm font-semibold">{@label}</span>
      <span class="text-sm text-base-content/60">— {@detail}</span>
    </div>
    """
  end

  def button_primary,
    do:
      "rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"

  def button_outline,
    do:
      "rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"

  def button_ghost,
    do:
      "rounded px-4 py-2 text-sm font-semibold text-base-content/70 transition hover:bg-base-200"
end
