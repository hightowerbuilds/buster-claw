defmodule BusterClawWeb.WalletsLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.LocalTime
  alias BusterClaw.Wallets
  alias BusterClaw.Wallets.Wallet

  @type_options [{"Business", "business"}, {"Personal", "personal"}]
  @template_options [{"None", "none"}, {"BusterClaw", "busterclaw"}]
  @model_providers [{"Anthropic", "anthropic"}, {"OpenAI", "openai"}, {"OpenCode", "opencode"}]
  @kind_options [{"Expense", "expense"}, {"Income", "income"}]
  @feed_kind_options [
    {"Market price (ticker)", "market"},
    {"Website (URL)", "url"},
    {"Integration", "integration"},
    {"Gmail receipts", "gmail"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Wallets.subscribe()
      # Phone spend feeds the BusterClaw template panel, so keep it live.
      BusterClaw.Telephony.subscribe()
    end

    month = month_key(LocalTime.today())

    {:ok,
     socket
     |> assign(:page_title, "Wallets")
     |> assign(:type_options, @type_options)
     |> assign(:template_options, @template_options)
     |> assign(:kind_options, @kind_options)
     |> assign(:feed_kind_options, @feed_kind_options)
     |> assign(:current_month, month)
     |> assign(:selected, nil)
     |> assign(:transactions, [])
     |> assign(:feeds, [])
     |> assign(:budget_summary, nil)
     |> assign(:busterclaw, nil)
     |> assign(:model_cost_form, nil)
     |> assign(:result, nil)
     |> assign(:txn_form, new_txn_form())
     |> assign(:feed_form, new_feed_form())
     |> assign(:budget_form, new_budget_form(month))
     |> assign_wallet_form(Wallets.change_wallet(%Wallet{type: "business"}))
     |> load_wallets()}
  end

  # --- real-time -------------------------------------------------------------

  @impl true
  def handle_info({:wallet_changed, _event, _wallet}, socket) do
    {:noreply, socket |> load_wallets() |> refresh_selected()}
  end

  def handle_info({:wallet_transaction, _action, txn}, socket) do
    socket = load_wallets(socket)

    if selected?(socket, txn.wallet_id) do
      {:noreply, refresh_selected(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:wallet_budget_changed, budget}, socket) do
    if selected?(socket, budget.wallet_id) do
      {:noreply, refresh_selected(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:wallet_feed_changed, _event, feed}, socket) do
    if selected?(socket, feed.wallet_id) do
      {:noreply, assign(socket, :feeds, Wallets.list_feeds(socket.assigns.selected))}
    else
      {:noreply, socket}
    end
  end

  # Live phone spend for the BusterClaw panel — only recompute when the open
  # wallet actually uses the template.
  def handle_info({:telephony_event, _event}, socket) do
    {:noreply, refresh_busterclaw(socket)}
  end

  # Cost back-fills land as one batched message per drain pass, not per row.
  def handle_info(:telephony_costs_updated, socket) do
    {:noreply, refresh_busterclaw(socket)}
  end

  # Ignore any unexpected message shape on the subscribed topic rather than
  # crashing the LiveView with a FunctionClauseError.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_busterclaw(socket) do
    case socket.assigns.selected do
      %Wallet{template: "busterclaw"} = wallet ->
        assign(socket, :busterclaw, Wallets.busterclaw_summary(wallet))

      _ ->
        socket
    end
  end

  # --- wallet CRUD -----------------------------------------------------------

  @impl true
  def handle_event("validate_wallet", %{"wallet" => params}, socket) do
    changeset =
      %Wallet{} |> Wallets.change_wallet(params) |> Map.put(:action, :validate)

    {:noreply, assign_wallet_form(socket, changeset)}
  end

  def handle_event("create_wallet", %{"wallet" => params}, socket) do
    case Wallets.create_wallet(params) do
      {:ok, wallet} ->
        {:noreply,
         socket
         |> assign(:result, "Wallet \"#{wallet.name}\" created.")
         |> assign_wallet_form(Wallets.change_wallet(%Wallet{type: "business"}))
         |> load_wallets()
         |> select_wallet(wallet)}

      {:error, changeset} ->
        {:noreply, assign_wallet_form(socket, changeset)}
    end
  end

  def handle_event("open", %{"id" => id}, socket) do
    case safe_get_wallet(id) do
      nil -> {:noreply, socket}
      wallet -> {:noreply, select_wallet(socket, wallet)}
    end
  end

  def handle_event("close", _params, socket) do
    {:noreply,
     assign(socket,
       selected: nil,
       transactions: [],
       feeds: [],
       budget_summary: nil,
       busterclaw: nil,
       model_cost_form: nil
     )}
  end

  def handle_event("delete_wallet", %{"id" => id}, socket) do
    case safe_get_wallet(id) do
      nil ->
        {:noreply, socket}

      wallet ->
        {:ok, _} = Wallets.delete_wallet(wallet)

        socket =
          if selected?(socket, wallet.id),
            do:
              assign(socket,
                selected: nil,
                transactions: [],
                feeds: [],
                budget_summary: nil,
                busterclaw: nil,
                model_cost_form: nil
              ),
            else: socket

        {:noreply, socket |> assign(:result, "Wallet deleted.") |> load_wallets()}
    end
  end

  # --- transactions ----------------------------------------------------------

  def handle_event("add_transaction", %{"transaction" => params}, socket) do
    wallet = socket.assigns.selected

    case wallet && build_transaction_attrs(params) do
      nil ->
        {:noreply, socket}

      {:error, message} ->
        {:noreply,
         assign(
           socket,
           :txn_form,
           to_form(params, as: :transaction, errors: [amount: {message, []}])
         )}

      {:ok, attrs} ->
        case Wallets.add_transaction(wallet, attrs) do
          {:ok, _txn} ->
            {:noreply, assign(socket, :txn_form, new_txn_form())}

          {:error, _changeset} ->
            {:noreply,
             assign(
               socket,
               :txn_form,
               to_form(params, as: :transaction, errors: [amount: {"is invalid", []}])
             )}
        end
    end
  end

  def handle_event("delete_transaction", %{"id" => id}, socket) do
    txn = Enum.find(socket.assigns.transactions, &(to_string(&1.id) == id))
    if txn, do: Wallets.delete_transaction(txn)
    {:noreply, socket}
  end

  # --- feeds (polling sources) -----------------------------------------------

  def handle_event("add_feed", %{"feed" => params}, socket) do
    wallet = socket.assigns.selected

    case wallet && Wallets.create_feed(wallet, build_feed_attrs(params)) do
      {:ok, _feed} ->
        {:noreply,
         socket
         |> assign(:feed_form, new_feed_form())
         |> assign(:feeds, Wallets.list_feeds(wallet))
         |> assign(:result, "Feed added.")}

      {:error, _changeset} ->
        {:noreply, assign(socket, :result, "Could not add feed — check the target value.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_feed", %{"id" => id}, socket) do
    feed = Enum.find(socket.assigns.feeds, &(to_string(&1.id) == id))
    if feed, do: Wallets.delete_feed(feed)
    {:noreply, socket}
  end

  def handle_event("poll_feeds", _params, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, socket}

      wallet ->
        results = Wallets.poll_wallet_feeds(wallet)
        {:noreply, assign(socket, :result, "Polled #{length(results)} feed(s).")}
    end
  end

  # --- budgets (personal) ----------------------------------------------------

  def handle_event("set_budget", %{"budget" => params}, socket) do
    wallet = socket.assigns.selected

    if wallet do
      attrs = build_budget_attrs(params, socket.assigns.current_month)

      case Wallets.upsert_budget(wallet, attrs) do
        {:ok, _budget} ->
          {:noreply, assign(socket, :result, "Budget saved.")}

        {:error, _changeset} ->
          {:noreply, assign(socket, :result, "Could not save budget.")}
      end
    else
      {:noreply, socket}
    end
  end

  # --- BusterClaw template (model costs) -------------------------------------

  def handle_event("save_model_costs", %{"model_costs" => params}, socket) do
    case socket.assigns.selected do
      %Wallet{} = wallet ->
        costs =
          for {_label, provider} <- @model_providers, reduce: %{} do
            acc ->
              case to_cents_or_zero(Map.get(params, provider)) do
                cents when cents > 0 -> Map.put(acc, provider, cents)
                _ -> acc
              end
          end

        case Wallets.set_model_costs(wallet, costs) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:selected, updated)
             |> assign(:busterclaw, Wallets.busterclaw_summary(updated))
             |> assign(:model_cost_form, new_model_cost_form(updated.model_costs))
             |> assign(:result, "Model costs saved.")}

          {:error, _changeset} ->
            {:noreply, assign(socket, :result, "Could not save model costs.")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # --- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <header class="flex items-end justify-between">
          <div>
            <h1 class="text-2xl font-semibold">Wallets</h1>
            <p class="text-sm text-base-content/60">
              Financial management — business ledgers and personal budgets.
            </p>
          </div>
        </header>

        <p
          :if={@result}
          id="wallets-result"
          class="rounded border border-base-300 bg-base-100 px-4 py-3 text-sm"
        >
          {@result}
        </p>

        <div class="grid gap-6 lg:grid-cols-[360px_minmax(0,1fr)]">
          <div class="space-y-6">
            <.form
              for={@wallet_form}
              id="wallet-form"
              phx-change="validate_wallet"
              phx-submit="create_wallet"
              class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-5"
            >
              <h2 class="text-lg font-semibold">New Wallet</h2>
              <.input field={@wallet_form[:name]} label="Name" />
              <.input field={@wallet_form[:type]} label="Type" type="select" options={@type_options} />
              <.input
                field={@wallet_form[:template]}
                label="Template"
                type="select"
                options={@template_options}
              />
              <.input field={@wallet_form[:currency]} label="Currency" />
              <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85">
                Create Wallet
              </button>
            </.form>

            <section class="rounded-lg border border-base-300 bg-base-100">
              <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
                {@wallets_count} wallets
              </div>
              <div class="divide-y divide-base-300">
                <button
                  :for={wallet <- @wallets}
                  id={"wallet-#{wallet.id}"}
                  type="button"
                  phx-click="open"
                  phx-value-id={wallet.id}
                  class={[
                    "flex w-full items-center justify-between gap-3 px-4 py-3 text-left transition hover:bg-base-200",
                    @selected && @selected.id == wallet.id && "bg-base-200"
                  ]}
                >
                  <div class="min-w-0">
                    <div class="truncate text-sm font-semibold">{wallet.name}</div>
                    <div class="text-xs text-base-content/60">{wallet.type}</div>
                  </div>
                  <div class={["font-mono text-sm", balance_class(wallet.balance_cents)]}>
                    {format_money(wallet.balance_cents, wallet.currency)}
                  </div>
                </button>
                <div :if={@wallets == []} class="px-4 py-10 text-center text-sm text-base-content/60">
                  No wallets yet. Create one to start.
                </div>
              </div>
            </section>
          </div>

          <div :if={@selected} class="space-y-6">
            {render_detail(assigns)}
          </div>
          <div
            :if={!@selected}
            class="flex items-center justify-center rounded-lg border border-dashed border-base-300 p-16 text-sm text-base-content/60"
          >
            Select a wallet to view its ledger.
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp render_detail(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 p-5">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h2 class="text-xl font-semibold">{@selected.name}</h2>
          <p class="text-xs text-base-content/60">{@selected.type} · {@selected.currency}</p>
        </div>
        <div class="text-right">
          <div class="text-xs text-base-content/60">Balance</div>
          <div class={["font-mono text-2xl font-semibold", balance_class(@selected.balance_cents)]}>
            {format_money(@selected.balance_cents, @selected.currency)}
          </div>
        </div>
      </div>
      <div class="mt-4 flex gap-2">
        <button
          type="button"
          phx-click="close"
          class="rounded border border-base-300 px-3 py-1.5 text-sm"
        >
          Close
        </button>
        <button
          type="button"
          phx-click="delete_wallet"
          phx-value-id={@selected.id}
          data-claw-confirm="Delete this wallet and all its transactions?"
          class="rounded border border-error/40 px-3 py-1.5 text-sm text-error"
        >
          Delete Wallet
        </button>
      </div>
    </section>

    {if @selected.template == "busterclaw" and @busterclaw, do: render_busterclaw(assigns)}

    <section
      :if={@selected.type == "personal"}
      class="rounded-lg border border-base-300 bg-base-100 p-5"
    >
      <h3 class="text-lg font-semibold">Budget · {@current_month}</h3>
      <div class="mt-4 grid gap-4 sm:grid-cols-3">
        {render_budget_row(%{
          label: "Income",
          actual: @budget_summary.income_actual_cents,
          target: @budget_summary.income_target_cents,
          currency: @selected.currency
        })}
        {render_budget_row(%{
          label: "Expense",
          actual: @budget_summary.expense_actual_cents,
          target: @budget_summary.expense_target_cents,
          currency: @selected.currency
        })}
        {render_budget_row(%{
          label: "Savings",
          actual: @budget_summary.savings_actual_cents,
          target: @budget_summary.savings_target_cents,
          currency: @selected.currency
        })}
      </div>

      <.form
        for={@budget_form}
        id="budget-form"
        phx-submit="set_budget"
        class="mt-5 grid gap-3 sm:grid-cols-4"
      >
        <.input field={@budget_form[:income_target]} label="Income target" />
        <.input field={@budget_form[:expense_target]} label="Expense target" />
        <.input field={@budget_form[:savings_target]} label="Savings target" />
        <div class="flex items-end">
          <button class="w-full rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85">
            Save Budget
          </button>
        </div>
      </.form>
    </section>

    <section class="rounded-lg border border-base-300 bg-base-100 p-5">
      <h3 class="text-lg font-semibold">Add transaction</h3>
      <.form
        for={@txn_form}
        id="transaction-form"
        phx-submit="add_transaction"
        class="mt-4 grid gap-3 sm:grid-cols-5"
      >
        <.input field={@txn_form[:kind]} label="Kind" type="select" options={@kind_options} />
        <.input field={@txn_form[:amount]} label={"Amount (#{@selected.currency})"} />
        <.input field={@txn_form[:category]} label="Category" />
        <.input field={@txn_form[:description]} label="Description" />
        <div class="flex items-end">
          <button class="w-full rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85">
            Add
          </button>
        </div>
      </.form>
    </section>

    <section class="rounded-lg border border-base-300 bg-base-100">
      <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">Ledger</div>
      <div class="divide-y divide-base-300">
        <div
          :for={txn <- @transactions}
          id={"transaction-#{txn.id}"}
          class="flex items-center justify-between gap-4 px-4 py-3"
        >
          <div class="min-w-0">
            <div class="truncate text-sm font-medium">
              {txn.description || txn.category || "(no description)"}
            </div>
            <div class="text-xs text-base-content/60">
              {txn.occurred_on} · {txn.category || "uncategorized"} · {txn.source}
            </div>
          </div>
          <div class="flex items-center gap-3">
            <div class={["font-mono text-sm", txn_amount_class(txn.kind)]}>
              {signed_money(txn, @selected.currency)}
            </div>
            <button
              type="button"
              phx-click="delete_transaction"
              phx-value-id={txn.id}
              data-claw-confirm="Delete this transaction?"
              class="rounded border border-error/40 px-2 py-1 text-xs text-error"
            >
              ✕
            </button>
          </div>
        </div>
        <div :if={@transactions == []} class="px-4 py-10 text-center text-sm text-base-content/60">
          No transactions yet.
        </div>
      </div>
    </section>

    <section class="rounded-lg border border-base-300 bg-base-100 p-5">
      <div class="flex items-center justify-between">
        <h3 class="text-lg font-semibold">Polling feeds</h3>
        <button
          type="button"
          phx-click="poll_feeds"
          class="rounded border border-base-300 px-3 py-1.5 text-sm"
        >
          Poll now
        </button>
      </div>

      <.form
        for={@feed_form}
        id="feed-form"
        phx-submit="add_feed"
        class="mt-4 grid gap-3 sm:grid-cols-4"
      >
        <.input field={@feed_form[:kind]} label="Source" type="select" options={@feed_kind_options} />
        <.input field={@feed_form[:target]} label="Target (ticker / URL / integration id)" />
        <.input
          field={@feed_form[:polling_interval_minutes]}
          label="Every (min)"
          type="number"
          min="1"
        />
        <div class="flex items-end">
          <button class="w-full rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85">
            Add Feed
          </button>
        </div>
      </.form>

      <div class="mt-4 divide-y divide-base-300 rounded border border-base-300">
        <div
          :for={feed <- @feeds}
          id={"feed-#{feed.id}"}
          class="flex items-center justify-between gap-4 px-4 py-3"
        >
          <div class="min-w-0">
            <div class="text-sm font-medium">{feed.kind} · {feed_target(feed)}</div>
            <div class="text-xs text-base-content/60">
              every {feed.polling_interval_minutes}m · {feed.last_status}{if feed.last_value,
                do: " · #{feed.last_value}"}
            </div>
            <p :if={feed.last_error} class="mt-1 line-clamp-2 text-xs text-error">
              {feed.last_error}
            </p>
          </div>
          <button
            type="button"
            phx-click="delete_feed"
            phx-value-id={feed.id}
            data-claw-confirm="Delete this feed?"
            class="rounded border border-error/40 px-2 py-1 text-xs text-error"
          >
            ✕
          </button>
        </div>
        <div :if={@feeds == []} class="px-4 py-8 text-center text-sm text-base-content/60">
          No feeds yet. Add a market, website, integration, or Gmail source.
        </div>
      </div>
    </section>
    """
  end

  defp render_budget_row(assigns) do
    ~H"""
    <div class="rounded border border-base-300 p-3">
      <div class="text-xs uppercase tracking-wide text-base-content/60">{@label}</div>
      <div class="mt-1 font-mono text-lg">{format_money(@actual, @currency)}</div>
      <div class="text-xs text-base-content/60">
        target: {if @target, do: format_money(@target, @currency), else: "—"}
      </div>
    </div>
    """
  end

  defp render_busterclaw(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100 p-5">
      <h3 class="text-lg font-semibold">BusterClaw running costs</h3>
      <div class="mt-4 grid gap-4 sm:grid-cols-2">
        <div class="rounded border border-base-300 p-3">
          <div class="text-xs uppercase tracking-wide text-base-content/60">BusterPhone</div>
          <div class="mt-1 font-mono text-sm">{@busterclaw.phone_number || "no calls yet"}</div>
          <div class="mt-2 text-xs text-base-content/60">Running phone total</div>
          <div class="font-mono text-lg">
            {format_money(@busterclaw.phone_spent_cents, @selected.currency)}{if @busterclaw.phone_pending?,
              do: "+"}
          </div>
          <div class="text-xs text-base-content/60">{@busterclaw.voicemails} voicemails</div>
        </div>
        <div class="rounded border border-base-300 p-3">
          <div class="text-xs uppercase tracking-wide text-base-content/60">
            Model subscriptions / mo
          </div>
          <div class="mt-1 font-mono text-lg">
            {format_money(@busterclaw.model_total_cents, @selected.currency)}
          </div>
          <ul class="mt-2 space-y-1 text-xs text-base-content/60">
            <li
              :for={{label, provider} <- model_providers()}
              :if={Map.get(@busterclaw.model_costs_cents, provider, 0) > 0}
            >
              {label}: {format_money(
                Map.get(@busterclaw.model_costs_cents, provider, 0),
                @selected.currency
              )}
            </li>
          </ul>
        </div>
      </div>

      <.form
        for={@model_cost_form}
        id="model-costs-form"
        phx-submit="save_model_costs"
        class="mt-5 grid gap-3 sm:grid-cols-4"
      >
        <.input
          :for={{label, provider} <- model_providers()}
          field={@model_cost_form[provider]}
          label={"#{label} ($/mo)"}
        />
        <div class="flex items-end">
          <button class="w-full rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100 transition hover:opacity-85">
            Save Costs
          </button>
        </div>
      </.form>
    </section>
    """
  end

  # --- helpers ---------------------------------------------------------------

  defp model_providers, do: @model_providers

  defp select_wallet(socket, %Wallet{} = wallet) do
    socket
    |> assign(:selected, wallet)
    |> assign(:transactions, Wallets.list_transactions(wallet))
    |> assign(:feeds, Wallets.list_feeds(wallet))
    |> assign(:budget_summary, Wallets.budget_summary(wallet, socket.assigns.current_month))
    |> assign_busterclaw(wallet)
  end

  defp assign_busterclaw(socket, %Wallet{template: "busterclaw"} = wallet) do
    socket
    |> assign(:busterclaw, Wallets.busterclaw_summary(wallet))
    |> assign(:model_cost_form, new_model_cost_form(wallet.model_costs))
  end

  defp assign_busterclaw(socket, %Wallet{}),
    do: assign(socket, busterclaw: nil, model_cost_form: nil)

  defp refresh_selected(%{assigns: %{selected: nil}} = socket), do: socket

  defp refresh_selected(%{assigns: %{selected: selected}} = socket) do
    case Wallets.get_wallet(selected.id) do
      nil ->
        assign(socket,
          selected: nil,
          transactions: [],
          feeds: [],
          budget_summary: nil,
          busterclaw: nil,
          model_cost_form: nil
        )

      wallet ->
        select_wallet(socket, wallet)
    end
  end

  defp selected?(%{assigns: %{selected: %Wallet{id: id}}}, wallet_id), do: id == wallet_id
  defp selected?(_socket, _wallet_id), do: false

  # Look up a wallet from a `phx-value-id`, tolerating a missing or malformed id
  # (returns nil) so a crafted value can't crash the LiveView.
  defp safe_get_wallet(id) do
    Wallets.get_wallet(id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp load_wallets(socket) do
    wallets = Wallets.list_wallets()

    socket
    |> assign(:wallets, wallets)
    |> assign(:wallets_count, length(wallets))
  end

  defp assign_wallet_form(socket, changeset), do: assign(socket, :wallet_form, to_form(changeset))

  defp new_txn_form,
    do:
      to_form(%{"kind" => "expense", "amount" => "", "category" => "", "description" => ""},
        as: :transaction
      )

  defp new_budget_form(_month),
    do:
      to_form(%{"income_target" => "", "expense_target" => "", "savings_target" => ""},
        as: :budget
      )

  defp new_feed_form,
    do:
      to_form(%{"kind" => "market", "target" => "", "polling_interval_minutes" => "60"},
        as: :feed
      )

  defp new_model_cost_form(costs) do
    costs = costs || %{}

    @model_providers
    |> Map.new(fn {_label, provider} ->
      {provider, cents_to_dollar_input(Map.get(costs, provider))}
    end)
    |> to_form(as: :model_costs)
  end

  defp cents_to_dollar_input(cents) when is_integer(cents) and cents > 0,
    do: :erlang.float_to_binary(cents / 100, decimals: 2)

  defp cents_to_dollar_input(value) when is_binary(value) do
    case Integer.parse(value) do
      {cents, _rest} when cents > 0 -> cents_to_dollar_input(cents)
      _ -> ""
    end
  end

  defp cents_to_dollar_input(_cents), do: ""

  defp build_feed_attrs(params) do
    kind = Map.get(params, "kind", "market")
    target = params |> Map.get("target", "") |> to_string() |> String.trim()

    config =
      case kind do
        "market" -> %{"symbol" => target}
        "url" -> %{"url" => target}
        "integration" -> %{"integration_id" => target}
        _ -> %{}
      end

    %{
      "kind" => kind,
      "config" => config,
      "polling_interval_minutes" => parse_interval(Map.get(params, "polling_interval_minutes"))
    }
  end

  defp parse_interval(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} when n > 0 -> n
      _ -> 60
    end
  end

  defp parse_interval(_value), do: 60

  defp feed_target(%{kind: "market", config: %{"symbol" => s}}), do: s
  defp feed_target(%{kind: "url", config: %{"url" => u}}), do: u

  defp feed_target(%{kind: "integration", config: %{"integration_id" => id}}),
    do: "integration ##{id}"

  defp feed_target(%{kind: "gmail"}), do: "inbound receipts"
  defp feed_target(_feed), do: "—"

  defp build_transaction_attrs(params) do
    case dollars_to_cents(Map.get(params, "amount")) do
      {:ok, cents} ->
        {:ok,
         %{
           "kind" => Map.get(params, "kind", "expense"),
           "amount_cents" => cents,
           "category" => blank_to_nil(Map.get(params, "category")),
           "description" => blank_to_nil(Map.get(params, "description")),
           "source" => "manual"
         }}

      :error ->
        {:error, "enter a positive amount"}
    end
  end

  defp build_budget_attrs(params, month) do
    %{
      "month" => month,
      "income_target_cents" => to_cents_or_zero(Map.get(params, "income_target")),
      "expense_target_cents" => to_cents_or_zero(Map.get(params, "expense_target")),
      "savings_target_cents" => to_cents_or_zero(Map.get(params, "savings_target"))
    }
  end

  # Parse a dollar string ("12", "12.50") to positive integer cents.
  defp dollars_to_cents(value) when is_binary(value) do
    case value |> String.trim() |> Float.parse() do
      {dollars, _rest} when dollars > 0 -> {:ok, round(dollars * 100)}
      _ -> :error
    end
  end

  defp dollars_to_cents(_value), do: :error

  defp to_cents_or_zero(value) when is_binary(value) do
    case value |> String.trim() |> Float.parse() do
      {dollars, _rest} when dollars >= 0 -> round(dollars * 100)
      _ -> 0
    end
  end

  defp to_cents_or_zero(_value), do: 0

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp month_key(%Date{year: year, month: month}),
    do: "#{year}-#{String.pad_leading(Integer.to_string(month), 2, "0")}"

  defp format_money(cents, currency) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs_cents = abs(cents)
    dollars = div(abs_cents, 100)
    rem_cents = rem(abs_cents, 100)

    "#{sign}#{symbol(currency)}#{delimit(dollars)}.#{String.pad_leading(Integer.to_string(rem_cents), 2, "0")}"
  end

  defp format_money(_cents, _currency), do: "—"

  defp signed_money(%{kind: "expense"} = txn, currency),
    do: "-" <> format_money(txn.amount_cents, currency)

  defp signed_money(txn, currency), do: "+" <> format_money(txn.amount_cents, currency)

  defp symbol("USD"), do: "$"
  defp symbol("EUR"), do: "€"
  defp symbol("GBP"), do: "£"
  defp symbol(other), do: "#{other} "

  # Group integer dollars with thousands separators.
  defp delimit(int) do
    int
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp balance_class(cents) when is_integer(cents) and cents < 0, do: "text-error"
  defp balance_class(_cents), do: "text-base-content"

  defp txn_amount_class("expense"), do: "text-error"
  defp txn_amount_class(_kind), do: "text-success"
end
