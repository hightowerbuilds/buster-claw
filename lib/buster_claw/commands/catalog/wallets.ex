defmodule BusterClaw.Commands.Catalog.Wallets do
  @moduledoc "Catalog entries: wallets (financial management: ledger + budgets)."

  alias BusterClaw.Commands.Catalog.Helpers

  @doc "Wallets catalog entries."
  def entries,
    do: [
      # Wallets (financial management: ledger + budgets)
      Helpers.list_entry("wallet_list", "List wallets."),
      Helpers.get_entry("wallet_get", "Fetch a wallet by ID."),
      %{
        name: "wallet_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a wallet (business or personal).",
        args: %{
          "name" => %{type: :string, required: true},
          "type" => %{type: :string, required: false, enum: ["business", "personal"]},
          "template" => %{type: :string, required: false, enum: ["none", "busterclaw"]},
          "currency" => %{type: :string, required: false, default: "USD"}
        }
      },
      %{
        name: "wallet_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a wallet.",
        args: %{
          "id" => %{type: :integer, required: true},
          "name" => %{type: :string, required: false},
          "type" => %{type: :string, required: false, enum: ["business", "personal"]},
          "template" => %{type: :string, required: false, enum: ["none", "busterclaw"]},
          "currency" => %{type: :string, required: false},
          "archived" => %{type: :boolean, required: false}
        }
      },
      Helpers.delete_entry("wallet_delete", "Delete a wallet and its transactions."),
      %{
        name: "wallet_list_transactions",
        type: :read,
        tier: :safe,
        description: "List a wallet's ledger transactions.",
        args: %{"wallet_id" => %{type: :integer, required: true}}
      },
      %{
        name: "wallet_add_transaction",
        type: :mutate,
        tier: :restricted,
        description: "Add an income or expense transaction to a wallet's ledger.",
        args: %{
          "wallet_id" => %{type: :integer, required: true},
          "kind" => %{type: :string, required: true, enum: ["income", "expense"]},
          "amount_cents" => %{type: :integer, required: true},
          "category" => %{type: :string, required: false},
          "description" => %{type: :string, required: false},
          "occurred_on" => %{type: :string, required: false},
          "source" => %{type: :string, required: false}
        }
      },
      %{
        name: "wallet_set_budget",
        type: :mutate,
        tier: :restricted,
        description: "Set (or update) a wallet's monthly budget targets.",
        args: %{
          "wallet_id" => %{type: :integer, required: true},
          "month" => %{type: :string, required: true},
          "income_target_cents" => %{type: :integer, required: false},
          "expense_target_cents" => %{type: :integer, required: false},
          "savings_target_cents" => %{type: :integer, required: false}
        }
      },
      %{
        name: "wallet_budget_summary",
        type: :read,
        tier: :safe,
        description: "Budget actuals vs. targets for a wallet/month.",
        args: %{
          "wallet_id" => %{type: :integer, required: true},
          "month" => %{type: :string, required: true}
        }
      },
      %{
        name: "wallet_feed_list",
        type: :read,
        tier: :safe,
        description: "List a wallet's external polling feeds.",
        args: %{"wallet_id" => %{type: :integer, required: true}}
      },
      %{
        name: "wallet_feed_create",
        type: :mutate,
        tier: :restricted,
        description: "Add a polling feed (market/url/integration/gmail) to a wallet.",
        args: %{
          "wallet_id" => %{type: :integer, required: true},
          "kind" => %{
            type: :string,
            required: true,
            enum: ["market", "url", "integration", "gmail"]
          },
          "config" => %{type: :map, required: false},
          "polling_interval_minutes" => %{type: :integer, required: false, default: 60},
          "enabled" => %{type: :boolean, required: false, default: true}
        }
      },
      %{
        name: "wallet_feed_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a wallet feed.",
        args: %{
          "id" => %{type: :integer, required: true},
          "config" => %{type: :map, required: false},
          "polling_interval_minutes" => %{type: :integer, required: false},
          "enabled" => %{type: :boolean, required: false}
        }
      },
      Helpers.delete_entry("wallet_feed_delete", "Delete a wallet feed."),
      Helpers.id_trigger_entry("wallet_poll", "Poll a wallet's external feeds now.", :restricted)
    ]
end
