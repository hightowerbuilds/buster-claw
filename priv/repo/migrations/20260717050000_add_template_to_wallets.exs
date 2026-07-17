defmodule BusterClaw.Repo.Migrations.AddTemplateToWallets do
  use Ecto.Migration

  # A wallet template pre-shapes what a wallet surfaces. "none" is an ordinary
  # ledger wallet; "busterclaw" adds a running-cost panel (BusterPhone spend +
  # the monthly model/subscription bill). `model_costs` is a JSON map of
  # provider => monthly cost in integer cents, e.g. %{"anthropic" => 2000}.
  def change do
    alter table(:wallets) do
      add :template, :string, null: false, default: "none"
      add :model_costs, :map, null: false, default: %{}
    end
  end
end
