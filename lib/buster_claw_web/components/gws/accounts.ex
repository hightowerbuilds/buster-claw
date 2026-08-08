defmodule BusterClawWeb.Gws.Accounts do
  @moduledoc """
  The connected-accounts list: status, token expiry, scopes and self-test
  results for each Google account.
  """
  use BusterClawWeb, :html

  import BusterClawWeb.Gws.Shared

  attr :accounts, :list, required: true

  def accounts_panel(assigns) do
    ~H"""
    <section id="gws-accounts" class="rounded-lg border border-base-300 bg-base-100">
      <div class="flex items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">{length(@accounts)} accounts</h2>
      </div>

      <div class="divide-y divide-base-300">
        <div
          :for={account <- @accounts}
          id={"gws-account-#{account.id}"}
          class="grid gap-4 px-4 py-4 lg:grid-cols-[minmax(0,1fr)_auto]"
        >
          <div class="min-w-0">
            <div class="flex min-w-0 flex-wrap items-center gap-2">
              <h3 class="truncate text-sm font-semibold">{account.email}</h3>
              <span class={account_enabled_class(account.enabled)}>
                {if account.enabled, do: "enabled", else: "disabled"}
              </span>
              <span class={account_token_class(account.has_refresh_token)}>
                {if account.has_refresh_token, do: "authorized", else: "needs auth"}
              </span>
              <span
                :if={missing_scopes?(account)}
                class="rounded-sm border border-warning/50 bg-warning/15 px-2 py-0.5 text-xs font-semibold text-warning"
              >
                Reconnect required — new permissions available
              </span>
              <span
                :if={account.reconnect_needed}
                class="rounded-sm border border-warning/50 bg-warning/15 px-2 py-0.5 text-xs font-semibold text-warning"
              >
                Reconnect needed — Google session expired
              </span>
            </div>

            <dl class="mt-3 grid gap-2 text-xs text-base-content/60 sm:grid-cols-2">
              <div>
                <dt class="font-semibold uppercase tracking-wide">Client ID</dt>
                <dd class="truncate font-mono">{account.client_id}</dd>
              </div>
              <div>
                <dt class="font-semibold uppercase tracking-wide">Scopes</dt>
                <dd class="truncate font-mono">{account.scopes || "default"}</dd>
              </div>
              <div>
                <dt class="font-semibold uppercase tracking-wide">Default Query</dt>
                <dd class="truncate font-mono">{account.default_query || "newer_than:7d"}</dd>
              </div>
              <div>
                <dt class="font-semibold uppercase tracking-wide">Access Token</dt>
                <dd>{token_expiry_label(account.access_token_expires_at)}</dd>
              </div>
              <div class="sm:col-span-2">
                <dt class="font-semibold uppercase tracking-wide">Health</dt>
                <dd>{self_test_label(account.self_test)}</dd>
              </div>
            </dl>
          </div>

          <div class="flex flex-wrap items-start gap-2 lg:justify-end">
            <button
              class="rounded border border-base-300 px-3 py-2 text-sm"
              phx-click="reconnect"
              phx-value-id={account.id}
            >
              Reconnect
            </button>
            <button
              class="rounded border border-base-300 px-3 py-2 text-sm"
              phx-click="self_test"
              phx-value-id={account.id}
            >
              Self-test
            </button>
            <button
              class="rounded border border-base-300 px-3 py-2 text-sm"
              phx-click="toggle"
              phx-value-id={account.id}
            >
              {if account.enabled, do: "Disable", else: "Enable"}
            </button>
            <button
              class="rounded border border-error/40 px-3 py-2 text-sm text-error"
              phx-click="delete_account"
              phx-value-id={account.id}
            >
              Delete
            </button>
          </div>
        </div>

        <div
          :if={@accounts == []}
          id="gws-empty"
          class="px-4 py-10 text-center text-sm text-base-content/60"
        >
          No Google Workspace accounts connected yet.
        </div>
      </div>
    </section>
    """
  end
end
