defmodule BusterClaw.BrowserControl.Commerce do
  @moduledoc """
  Commerce — cart in, human pays (BROWSER_ENGINE_ROADMAP Phase 5).

  The honest model, stated plainly: the agent searches, compares, and builds a
  `Cart` in Agent Mode, in view; at the payment step it **hands off** to the
  human, who pays in the same headful surface where checkout popups actually
  work; and only after the human confirms does a `Wallets` transaction land, so
  agent-assisted spending shows up where the user's money already lives. This is
  **not** autonomous purchasing — no payment credential ever passes through the
  agent, which is what removes the entire payment-credential threat surface.

  The boundaries are reused, not reinvented: the "trusted merchants" allowlist is
  a Phase 3 `Scope`, and the payment hard-stop is that scope's payment gate — a
  commerce run just asks Agent Mode to turn that stop into a handoff
  (`on_payment: :handoff`) instead of a dead end.

  This module is the thin composition: start a scoped commerce run, and — once
  the human has paid — turn the frozen cart into a ledger entry. The agent
  attaches the cart to the run as it shops (`AgentMode.put_cart/2`); the payment
  handoff freezes it and shows it to the human, and `confirm_purchase/3` bills
  **that** cart — the ledger can never disagree with what the human saw.
  """

  alias BusterClaw.BrowserControl.{AgentMode, Scope}
  alias BusterClaw.BrowserControl.Commerce.Cart
  alias BusterClaw.Wallets

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
  Close the loop after the human has paid: write a `Wallets` transaction for the
  **run's** cart — the one frozen and shown at the handoff — and mark the run
  `done`. There is no cart argument on purpose: the ledger can only ever bill
  what the human saw.

  Refuses unless the run is in `awaiting_human` (i.e. a handoff actually
  happened) and the run's cart exists and is non-empty — a ledger entry must
  correspond to a real human-confirmed purchase, never a speculative one.
  `attrs` may carry `:occurred_on`, `:category` (default `"shopping"`), and
  `:confirmation` (an order id / URL recorded in metadata).

  Returns `{:ok, transaction}` or `{:error, reason}`.
  """
  def confirm_purchase(run, %Wallets.Wallet{} = wallet, attrs \\ %{}) do
    attrs = Map.new(attrs)
    cart = AgentMode.cart(run)

    cond do
      is_nil(cart) or Cart.empty?(cart) ->
        {:error, :empty_cart}

      AgentMode.mode(run) != :awaiting_human ->
        {:error, {:not_awaiting_human, AgentMode.mode(run)}}

      true ->
        summary = Cart.summary(cart)

        tx_attrs =
          %{
            kind: "expense",
            amount_cents: summary.total_cents,
            category: Map.get(attrs, :category, "shopping"),
            description: "Agent purchase: #{summary.lines}",
            occurred_on: Map.get(attrs, :occurred_on),
            source: "browser_agent",
            metadata: %{
              "run_id" => AgentMode.run_id(run),
              "cart" => cart_metadata(cart),
              "confirmation" => Map.get(attrs, :confirmation),
              # Roadmap: "capture the confirmation page". Best-effort — a failed
              # capture degrades to a receipt-less entry, never a lost entry.
              "confirmation_capture" => capture_confirmation(run)
            }
          }
          # Drop occurred_on when nil so Wallets' put_new default (today) applies
          # rather than a nil failing validate_required.
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        with {:ok, tx} <- Wallets.add_transaction(wallet, tx_attrs) do
          AgentMode.complete(run)
          {:ok, tx}
        end
    end
  end

  # The run's capture can fail for engine reasons (dead session, stub without a
  # CDP surface); the exit-trap keeps a post-payment engine death from also
  # losing the ledger entry.
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
