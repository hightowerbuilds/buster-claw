defmodule BusterClawWeb.TradingOrderComponents do
  @moduledoc "Structured, transcript-independent equity order workflow UI."
  use BusterClawWeb, :html

  alias BusterClaw.TradingOrders.OrderIntent

  attr :ready, :boolean, required: true
  attr :submission_ready, :boolean, required: true
  attr :account_label, :string, default: nil
  attr :order_form, :any, required: true
  attr :confirmation_form, :any, required: true
  attr :workflow, :any, required: true
  attr :broker_connection, :any, default: nil
  attr :broker_account, :any, default: nil
  attr :broker_auth_url, :string, default: nil
  attr :broker_note, :string, default: nil

  def order_lane(assigns) do
    ~H"""
    <section
      id="trading-order-lane"
      class="border-2 border-base-content/20 bg-base-100 font-mono shadow-[3px_3px_0_0_oklch(var(--bc)/0.12)]"
    >
      <header class="flex items-start justify-between gap-3 border-b-2 border-base-content/20 p-3">
        <div>
          <p class="text-[0.65rem] font-bold uppercase tracking-[0.22em] text-base-content/50">
            Application-controlled
          </p>
          <h2 class="text-sm font-black uppercase tracking-wide">Deterministic order lane</h2>
        </div>
        <span class={[
          "border-2 px-2 py-1 text-[0.62rem] font-black uppercase tracking-widest",
          if(@ready,
            do: "border-warning/60 bg-warning/10 text-warning",
            else: "border-base-content/20 text-base-content/50"
          )
        ]}>
          <%= cond do %>
            <% @submission_ready -> %>
              Execution ready
            <% @ready -> %>
              Review ready
            <% true -> %>
              Sealed
          <% end %>
        </span>
      </header>

      <div :if={!@ready} id="trading-order-sealed" class="space-y-2 p-3 text-xs">
        <p class="font-bold">Writes remain sealed.</p>
        <p class="leading-relaxed text-base-content/65">
          This lane will open only when a structured Robinhood broker adapter and opaque
          Agentic account identity are configured. Portfolio snapshot data and free-form
          assistant text are never accepted as execution inputs.
        </p>
        <div class="mt-3 border-t-2 border-base-content/15 pt-3">
          <div class="flex items-center justify-between gap-3">
            <div>
              <p class="text-[0.62rem] font-bold uppercase tracking-widest text-base-content/45">
                Direct Robinhood MCP
              </p>
              <p id="trading-broker-status" class="mt-1 font-bold">
                {broker_status(@broker_connection, @broker_account)}
              </p>
            </div>
            <span class={[
              "size-2.5 shrink-0 rounded-full",
              broker_status_dot(@broker_connection, @broker_account)
            ]}>
            </span>
          </div>
          <p :if={@broker_note} id="trading-broker-note" class="mt-2 text-base-content/60">
            {@broker_note}
          </p>
          <div class="mt-3 grid grid-cols-2 gap-2">
            <button
              id="trading-broker-connect-button"
              type="button"
              phx-click="trading_broker_connect"
              class="border-2 border-primary bg-primary/10 px-3 py-2 font-black uppercase tracking-wide text-primary transition hover:bg-primary hover:text-primary-content"
            >
              {if(@broker_connection, do: "Reconnect", else: "Connect")}
            </button>
            <button
              id="trading-broker-check-button"
              type="button"
              phx-click="trading_broker_check"
              class="border-2 border-base-content/20 px-3 py-2 font-bold uppercase tracking-wide transition hover:border-base-content/50"
            >
              Check
            </button>
          </div>
          <a
            :if={@broker_auth_url}
            id="trading-broker-auth-link"
            href={@broker_auth_url}
            target="_blank"
            rel="noreferrer"
            class="mt-2 block break-all text-[0.65rem] text-primary underline"
          >
            Open Robinhood authorization manually
          </a>
        </div>
      </div>

      <div :if={@ready} class="p-3">
        <div class="mb-3 flex items-center justify-between gap-2 text-[0.68rem]">
          <span class="uppercase tracking-wide text-base-content/50">Account</span>
          <span id="trading-order-account" class="font-bold">{@account_label}</span>
        </div>

        <div
          :if={match?({:error, _reason}, @workflow)}
          id="trading-order-error"
          class="mb-3 border-2 border-error/40 bg-error/5 p-2 text-xs text-error"
        >
          {workflow_error(@workflow)}
        </div>

        <div
          :if={match?({:result, _intent}, @workflow)}
          id="trading-order-result"
          class="mb-3 border-2 border-success/40 bg-success/5 p-3 text-xs"
        >
          <p class="font-black uppercase tracking-wide">Submission recorded</p>
          <p class="mt-1 text-base-content/70">{result_copy(@workflow)}</p>
        </div>

        <.form
          :if={!match?({:preview, _preview}, @workflow)}
          for={@order_form}
          id="trading-order-form"
          phx-submit="trading_order_preview"
          class="space-y-2"
        >
          <div class="grid grid-cols-2 gap-2">
            <.input
              field={@order_form[:side]}
              type="select"
              label="Side"
              options={[Buy: "buy", Sell: "sell"]}
              required
            />
            <.input
              field={@order_form[:symbol]}
              type="text"
              label="Symbol"
              placeholder="AAPL"
              maxlength="10"
              required
            />
          </div>
          <div class="grid grid-cols-2 gap-2">
            <.input
              field={@order_form[:amount_type]}
              type="select"
              label="Amount type"
              options={[Shares: "quantity", Dollars: "notional"]}
              required
            />
            <.input
              field={@order_form[:amount]}
              type="text"
              label="Amount"
              placeholder="1"
              required
            />
          </div>
          <div class="grid grid-cols-2 gap-2">
            <.input
              field={@order_form[:order_type]}
              type="select"
              label="Order type"
              options={[Limit: "limit", Market: "market"]}
              required
            />
            <.input
              field={@order_form[:limit_price]}
              type="text"
              label="Limit price"
              placeholder="Required for limit"
            />
          </div>
          <.input
            field={@order_form[:time_in_force]}
            type="select"
            label="Time in force"
            options={[Day: "day", "Good 'til canceled": "gtc"]}
            required
          />
          <button
            id="trading-order-review-button"
            type="submit"
            class="w-full border-2 border-warning bg-warning/10 px-3 py-2 text-xs font-black uppercase tracking-widest text-warning transition hover:bg-warning hover:text-warning-content active:translate-y-px"
          >
            Review exact order
          </button>
        </.form>

        <.preview
          :if={match?({:preview, _preview}, @workflow)}
          workflow={@workflow}
          confirmation_form={@confirmation_form}
          submission_ready={@submission_ready}
        />
      </div>
    </section>
    """
  end

  attr :workflow, :any, required: true
  attr :confirmation_form, :any, required: true
  attr :submission_ready, :boolean, required: true

  defp preview(assigns) do
    {:preview, %{intent: intent, confirmation_phrase: phrase}} = assigns.workflow

    assigns =
      assigns
      |> assign(:intent, intent)
      |> assign(:phrase, phrase)
      |> assign(:warnings, broker_warnings(intent))
      |> assign(:market_data_disclosure, market_data_disclosure(intent))

    ~H"""
    <div id="trading-order-preview" class="space-y-3">
      <div class="border-2 border-warning/50 bg-warning/5 p-3">
        <div class="flex items-start justify-between gap-3">
          <div>
            <p class="text-[0.62rem] font-bold uppercase tracking-widest text-base-content/50">
              Exact broker-reviewed payload
            </p>
            <p class="mt-1 text-lg font-black">
              {String.upcase(@intent.side)} {amount(@intent)} {@intent.symbol}
            </p>
          </div>
          <span class="border border-base-content/20 px-2 py-1 text-[0.62rem] uppercase">
            {@intent.order_type} · {@intent.time_in_force}
          </span>
        </div>
        <dl class="mt-3 grid grid-cols-2 gap-x-3 gap-y-2 text-xs">
          <div>
            <dt class="text-base-content/50">Current quote</dt>
            <dd class="font-bold">{money(@intent.quote_cents)}</dd>
          </div>
          <div>
            <dt class="text-base-content/50">Estimated notional</dt>
            <dd class="font-bold">{money(@intent.estimated_notional_cents)}</dd>
          </div>
          <div>
            <dt class="text-base-content/50">Buying power</dt>
            <dd class="font-bold">{money(@intent.buying_power_cents)}</dd>
          </div>
          <div>
            <dt class="text-base-content/50">Concentration after</dt>
            <dd class="font-bold">{percent(@intent.concentration_bps)}</dd>
          </div>
        </dl>
        <p class="mt-3 break-all text-[0.62rem] text-base-content/45">
          Preview fingerprint: {@intent.preview_digest}
        </p>
        <p
          :if={@market_data_disclosure}
          id="trading-order-market-data-disclosure"
          class="mt-3 border-t border-base-content/15 pt-2 text-xs leading-relaxed text-base-content/70"
        >
          {@market_data_disclosure}
        </p>
        <div :if={@warnings != []} class="mt-3 border-t border-warning/30 pt-2">
          <p class="text-[0.62rem] font-black uppercase tracking-widest text-warning">
            Broker warnings
          </p>
          <ul id="trading-order-warnings" class="mt-1 list-disc space-y-1 pl-4 text-xs">
            <li :for={warning <- @warnings}>{warning}</li>
          </ul>
        </div>
      </div>

      <div
        :if={@submission_ready}
        class="border-l-4 border-error bg-error/5 p-3 text-xs"
      >
        <p class="font-bold">Type this exact phrase to submit:</p>
        <code id="trading-order-confirmation-phrase" class="mt-2 block select-all break-all">
          {@phrase}
        </code>
      </div>

      <.form
        :if={@submission_ready}
        for={@confirmation_form}
        id="trading-order-confirmation-form"
        phx-submit="trading_order_confirm"
      >
        <.input
          field={@confirmation_form[:phrase]}
          type="text"
          label="Exact confirmation"
          autocomplete="off"
          required
        />
        <div class="grid grid-cols-2 gap-2">
          <button
            id="trading-order-cancel-button"
            type="button"
            phx-click="trading_order_cancel"
            class="border-2 border-base-content/20 px-3 py-2 text-xs font-bold uppercase tracking-wide transition hover:border-base-content/50"
          >
            Cancel
          </button>
          <button
            id="trading-order-submit-button"
            type="submit"
            class="border-2 border-error bg-error/10 px-3 py-2 text-xs font-black uppercase tracking-wide text-error transition hover:bg-error hover:text-error-content"
          >
            Submit order
          </button>
        </div>
      </.form>

      <div
        :if={!@submission_ready}
        id="trading-order-review-only"
        class="border-l-4 border-success bg-success/5 p-3 text-xs"
      >
        <p class="font-black uppercase tracking-wide">Review complete — submission sealed</p>
        <p class="mt-1 leading-relaxed text-base-content/65">
          This is live broker data, but Buster Claw cannot place, amend, or cancel the order.
        </p>
        <button
          id="trading-order-cancel-button"
          type="button"
          phx-click="trading_order_cancel"
          class="mt-3 w-full border-2 border-base-content/20 px-3 py-2 font-bold uppercase tracking-wide transition hover:border-base-content/50"
        >
          Close review
        </button>
      </div>
    </div>
    """
  end

  defp amount(%OrderIntent{quantity_micros: micros}) when is_integer(micros) do
    whole = div(micros, 1_000_000)
    decimal = micros |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    trimmed = String.trim_trailing(decimal, "0")
    if trimmed == "", do: "#{whole} shares", else: "#{whole}.#{trimmed} shares"
  end

  defp amount(%OrderIntent{notional_cents: cents}), do: money(cents)

  defp money(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    remainder = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "$#{dollars}.#{remainder}"
  end

  defp money(_cents), do: "Unavailable"

  defp percent(bps) when is_integer(bps), do: "#{Float.round(bps / 100, 2)}%"
  defp percent(_bps), do: "Unavailable"

  defp broker_warnings(%OrderIntent{broker_preview: %{"warnings" => warnings}})
       when is_list(warnings),
       do: Enum.filter(warnings, &is_binary/1)

  defp broker_warnings(_intent), do: []

  defp market_data_disclosure(%OrderIntent{
         broker_preview: %{"market_data_disclosure" => disclosure}
       })
       when is_binary(disclosure) and disclosure != "",
       do: disclosure

  defp market_data_disclosure(_intent), do: nil

  defp workflow_error({:error, reason}),
    do: "Order lane refused the request: #{humanize_reason(reason)}."

  defp workflow_error(_workflow), do: nil

  defp result_copy({:result, intent}) do
    "Local state: #{intent.status}. Broker status: #{intent.broker_status || "unavailable"}. " <>
      "Client order ID: #{intent.client_order_id}."
  end

  defp result_copy(_workflow), do: nil

  defp humanize_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp humanize_reason(%Ecto.Changeset{}), do: "invalid structured order"
  defp humanize_reason(reason), do: inspect(reason, limit: 8)

  defp broker_status(nil, _account), do: "Not connected"

  defp broker_status(%{status: "connected"}, %{label: label}),
    do: "Connected · #{label}"

  defp broker_status(%{status: "connected"}, nil),
    do: "Connected · no Agentic account"

  defp broker_status(%{status: "authorizing"}, _account), do: "Authorization pending"
  defp broker_status(%{status: "reconnect_required"}, _account), do: "Reconnect required"
  defp broker_status(%{status: "error"}, _account), do: "Connection check failed"
  defp broker_status(_connection, _account), do: "Not connected"

  defp broker_status_dot(%{status: "connected"}, %{can_trade: true}), do: "bg-success"
  defp broker_status_dot(%{status: "authorizing"}, _account), do: "bg-warning animate-pulse"
  defp broker_status_dot(_connection, _account), do: "bg-base-content/25"
end
