defmodule BusterClaw.PortfolioCostsTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Portfolio

  defp row(symbol, quantity, basis, lots \\ 1),
    do: %{symbol: symbol, quantity: quantity, lots: lots, cost_basis: basis}

  describe "store_costs/2" do
    test "stores cents and replaces wholesale — sold positions vanish" do
      assert 2 =
               Portfolio.store_costs("6587", [row("GOOGL", 0.25, 69.99), row("OKYO", 1.0, 1.51)])

      # OKYO was sold; the refetch must not resurrect it.
      assert 1 = Portfolio.store_costs("6587", [row("GOOGL", 0.25, 71.0)])

      assert [only] = Portfolio.all_costs()
      assert only.symbol == "GOOGL"
      assert only.cost_basis_cents == 7_100
    end

    test "a nil basis stores as nil, and an invalid row costs only itself" do
      assert 1 = Portfolio.store_costs("8262", [row("QXO", 10.0, nil, 0)])
      assert [qxo] = Portfolio.all_costs()
      assert qxo.cost_basis_cents == nil
      assert qxo.lots == 0
    end

    test "one account's rows never disturb another's" do
      Portfolio.store_costs("6587", [row("GOOGL", 0.25, 69.99)])
      Portfolio.store_costs("8262", [row("GOOGL", 0.2014, 70.0)])

      assert length(Portfolio.all_costs()) == 2

      Portfolio.store_costs("6587", [])
      assert [survivor] = Portfolio.all_costs()
      assert survivor.account_key == "8262"
    end
  end

  describe "position_rows/1" do
    test "aggregates per symbol across accounts, tagged by account" do
      Portfolio.store_costs("6587", [row("GOOGL", 0.25, 81.79)])
      Portfolio.store_costs("8262", [row("GOOGL", 0.2014, 70.0), row("QXO", 10.0, 142.0)])

      assert [googl, qxo] = Portfolio.position_rows([])
      assert googl.symbol == "GOOGL"
      assert_in_delta googl.quantity, 0.4514, 0.0001
      assert googl.cost_basis_cents == 15_179
      assert googl.accounts == ["6587", "8262"]
      assert qxo.accounts == ["8262"]
    end

    test "ANY nil contribution makes the aggregate basis nil — partial is not whole" do
      Portfolio.store_costs("6587", [row("GOOGL", 0.25, 81.79)])
      Portfolio.store_costs("8262", [row("GOOGL", 0.2014, nil)])

      assert [googl] = Portfolio.position_rows([])
      # Claiming $81.79 as the full basis would overstate the gain by the
      # missing account's entire purchase.
      assert googl.cost_basis_cents == nil
    end

    test "excluded accounts leave the rows, exactly as they leave the totals" do
      Portfolio.store_costs("6587", [row("GOOGL", 0.25, 81.79)])
      Portfolio.store_costs("8735", [row("GME", 5.0, 100.0)])

      {:ok, _} = Portfolio.exclude_account("8735")

      rows = Portfolio.position_rows()
      assert Enum.map(rows, & &1.symbol) == ["GOOGL"]
    end
  end

  describe "accounts_missing_costs/1" do
    test "names candidates without rows, skipping the excluded" do
      Portfolio.store_costs("6587", [row("GOOGL", 0.25, 81.79)])
      {:ok, _} = Portfolio.exclude_account("8735")

      assert Portfolio.accounts_missing_costs(["6587", "8262", "8735"]) == ["8262"]
    end
  end
end
