defmodule BusterClaw.BrowserControl.Commerce do
  @moduledoc """
  Commerce — cart in, human pays (BROWSER_ENGINE_ROADMAP Phase 5).

  The honest model, stated plainly: the agent searches, compares, and builds a
  `Cart` in Agent Mode, in view; at the payment step it **hands off** to the
  human, who pays in the same headful surface where checkout popups actually
  work; and only after the human confirms does the run complete and capture the
  confirmation page. This is **not** autonomous purchasing — no payment
  credential ever passes through the agent, which removes the entire
  payment-credential threat surface.

  The boundaries are reused, not reinvented: the "trusted merchants" allowlist is
  a Phase 3 `Scope`, and the payment hard-stop is that scope's payment gate — a
  commerce run just asks Agent Mode to turn that stop into a handoff
  (`on_payment: :handoff`) instead of a dead end.

  This module is the thin composition: start a scoped commerce run and, once
  the human has paid, capture the confirmation and finish the run. The agent
  attaches the cart to the run as it shops (`AgentMode.put_cart/2`); the payment
  handoff freezes it and shows it to the human, and `confirm_purchase/2`
  confirms **that** cart.
  """

  alias BusterClaw.BrowserControl.{AgentMode, Scope}
  alias BusterClaw.BrowserControl.Commerce.Cart

  @doc """
  Freeze a commerce scope from a task intent and a **merchant allowlist**. Same
  `Scope` as everywhere else — the merchant list *is* the allowed-domains list,
  so an off-merchant navigation halts and the payment page hands off.
  """
  def scope(intent, merchants, opts \\ []) when is_list(merchants) do
    Scope.new(intent, merchants, opts)
  end

  @doc """
  Start a commerce Agent Mode run: a scoped run with `on_payment: :handoff`.
  Accepts the same options as `AgentMode.start_link/1` (a leased `:session` is
  required); `:on_payment` is forced to `:handoff` so a payment page suspends
  into `awaiting_human` rather than halting.
  """
  def start_run(opts) do
    AgentMode.start_link(Keyword.put(opts, :on_payment, :handoff))
  end

  @doc """
  Close the loop after the human has paid: capture the confirmation page for the
  **run's** frozen cart and mark the run `done`.

  Refuses unless the run is in `awaiting_human` (i.e. a handoff actually
  happened) and the run's cart exists and is non-empty. `attrs` may carry
  `:confirmation` (an order id or URL included in the returned receipt).

  Returns `{:ok, receipt}` or `{:error, reason}`. The receipt is returned to the
  caller and is not persisted as a financial ledger.
  """
  def confirm_purchase(run, attrs \\ %{}) do
    attrs = Map.new(attrs)
    cart = AgentMode.cart(run)

    cond do
      is_nil(cart) or Cart.empty?(cart) ->
        {:error, :empty_cart}

      AgentMode.mode(run) != :awaiting_human ->
        {:error, {:not_awaiting_human, AgentMode.mode(run)}}

      true ->
        receipt = %{
          run_id: AgentMode.run_id(run),
          cart: cart_metadata(cart),
          confirmation: Map.get(attrs, :confirmation),
          confirmation_capture: capture_confirmation(run)
        }

        AgentMode.complete(run)
        {:ok, receipt}
    end
  end

  # The run's capture can fail for engine reasons (dead session, stub without a
  # CDP surface); the exit-trap keeps a post-payment engine death from also
  # losing the handoff confirmation.
  defp capture_confirmation(run) do
    case AgentMode.capture_confirmation(run) do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp cart_metadata(%Cart{} = cart) do
    %{
      "currency" => cart.currency,
      "total_cents" => Cart.total_cents(cart),
      "items" =>
        Enum.map(cart.items, fn %{name: n, qty: q, unit_cents: u} ->
          %{"name" => n, "qty" => q, "unit_cents" => u}
        end)
    }
  end
end
