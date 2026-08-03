defmodule BusterClawWeb.TradingOrderCard do
  @moduledoc """
  The order confirmation card — the only path from the Trading tab to the broker.

  Everything rendered here comes from the parsed `BusterClaw.TradingOrder`
  struct, never from the model's prose, so what the operator reads is exactly
  what gets placed. A misread "sell 100" cannot become an order without SELL 100
  appearing here first.

  The outcome copy distinguishes three endings on purpose: accepted, refused by
  the broker, and *unknown* — a run that timed out may or may not have reached
  Robinhood, and saying "failed" there would be a claim we cannot support.
  """
  use BusterClawWeb, :html

  # The confirm card: the app's rendering of what it parsed, and the button that
  # sends it. Everything shown here comes from the `TradingOrder` struct, not from
  # the model's prose — so what the operator reads is exactly what gets placed.
  attr :pending, :any, required: true
  attr :conv, :string, required: true

  def order_confirm(assigns) do
    ~H"""
    <div id={"trading-order-confirm-#{@conv}"} class="space-y-2 p-4 font-mono text-xs">
      <%= case @pending do %>
        <% {:proposed, order} -> %>
          <p class="text-[0.62rem] font-bold uppercase tracking-[0.2em] text-base-content/50">
            Confirm to send
          </p>
          <p id={"trading-order-summary-#{@conv}"} class="text-sm font-black tracking-wide">
            {BusterClaw.TradingOrder.summary(order)}
          </p>
          <p class="text-base-content/60">
            This is what Buster Claw will send. Nothing has reached the broker yet.
          </p>
          <div class="flex gap-2 pt-1">
            <button
              id={"trading-order-confirm-button-#{@conv}"}
              type="button"
              phx-click="trading_order_confirm"
              phx-value-conv={@conv}
              class="border-2 border-error bg-error/10 px-3 py-2 font-black uppercase tracking-wide text-error transition hover:bg-error hover:text-error-content"
            >
              Place this order
            </button>
            <button
              type="button"
              phx-click="trading_order_dismiss"
              phx-value-conv={@conv}
              phx-value-conv={@conv}
              class="border-2 border-base-content/25 px-3 py-2 font-bold uppercase tracking-wide transition hover:border-base-content/50"
            >
              Discard
            </button>
          </div>
        <% {:submitting, order} -> %>
          <p class="text-[0.62rem] font-bold uppercase tracking-[0.2em] text-base-content/50">
            Sending
          </p>
          <p class="text-sm font-black tracking-wide">
            {BusterClaw.TradingOrder.summary(order)}
          </p>
          <p id={"trading-order-submitting-#{@conv}"} class="text-base-content/60">
            Placing the order… don't close this tab.
          </p>
        <% {:settled, order, result} -> %>
          <p class={[
            "text-[0.62rem] font-bold uppercase tracking-[0.2em]",
            order_result_class(result)
          ]}>
            {order_result_heading(result)}
          </p>
          <p class="text-sm font-black tracking-wide">
            {BusterClaw.TradingOrder.summary(order)}
          </p>
          <%!-- No retry button, on purpose. A submission that did not return a
                verdict may already be live at the broker; the only safe next
                step is for a human to go look. --%>
          <p id={"trading-order-result-#{@conv}"} class={["text-xs", order_result_class(result)]}>
            {order_result_detail(result)}
          </p>
          <button
            type="button"
            phx-click="trading_order_dismiss"
            class="border-2 border-base-content/25 px-3 py-1.5 font-bold uppercase tracking-wide transition hover:border-base-content/50"
          >
            Dismiss
          </button>
      <% end %>
    </div>
    """
  end

  defp order_result_heading({:ok, _id}), do: "Sent"
  defp order_result_heading({:error, {:refused, _reason}}), do: "Refused by the broker"
  defp order_result_heading({:error, :not_sent}), do: "Not sent"
  defp order_result_heading({:error, _reason}), do: "Status unknown"

  defp order_result_class({:ok, _id}), do: "text-success"
  defp order_result_class({:error, {:refused, _reason}}), do: "text-warning"
  defp order_result_class({:error, :not_sent}), do: "text-warning"
  defp order_result_class({:error, _reason}), do: "text-error"

  defp order_result_detail({:ok, id}), do: "Broker order id #{id}."
  defp order_result_detail({:error, {:refused, reason}}), do: reason

  # `:not_sent` is a verified negative — the run made no place call at all — so
  # unlike the unknown below it is safe to say plainly that nothing happened.
  defp order_result_detail({:error, :not_sent}),
    do:
      "The order never reached Robinhood — the broker tools were not available to " <>
        "the run. Nothing was placed. Check `claude mcp login robinhood` and try again."

  defp order_result_detail({:error, _reason}),
    do:
      "The submission did not come back with a verdict, so this order may or may not " <>
        "have reached Robinhood. Check your order history there before sending it again."
end
