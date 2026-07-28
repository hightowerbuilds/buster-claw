defmodule BusterClaw.Commands.PortfolioTest do
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Commands
  alias BusterClaw.Portfolio

  defp d(iso), do: Date.from_iso8601!(iso)

  defp record(day, key, value) do
    {:ok, _} =
      Portfolio.record(%{"accounts" => [%{"last4" => key, "label" => "Acct", "value" => value}]},
        day: d(day)
      )

    :ok
  end

  describe "portfolio_history" do
    setup do
      record("2026-07-27", "6587", 100.0)
      record("2026-07-28", "6587", 110.0)
      :ok
    end

    test "returns dollars, never the ledger's cents" do
      assert {:ok, %{points: [first, second]}} = Commands.call("portfolio_history")

      # 11000 cents would be a units error waiting to happen.
      assert second.cumulative == 10.0
      assert second.change == 10.0
      assert second.value == 110.0
      # The first point has nothing to measure against and says so with nil.
      assert first.change == nil
      assert first.cumulative == 0.0
    end

    test "every point names its measure" do
      Portfolio.store_backfill("6587", [
        %{bucket_on: d("2026-06-28"), realized: 50.0, trades: 2}
      ])

      assert {:ok, %{points: points}} = Commands.call("portfolio_history")
      measures = points |> Enum.map(& &1.measure) |> Enum.uniq()

      assert "realized" in measures
      assert "recorded" in measures
    end

    test "scopes to one account when asked" do
      record("2026-07-28", "8262", 900.0)

      assert {:ok, %{points: combined}} = Commands.call("portfolio_history")
      assert {:ok, %{points: scoped}} = Commands.call("portfolio_history", %{"account" => "6587"})

      # Both series have two days: the 27th is complete for the accounts that
      # existed *then*, so opening a second account on the 28th does not
      # retroactively void it.
      assert length(combined) == 2
      assert length(scoped) == 2

      # The values are what distinguish them.
      assert List.last(combined).value == 1_010.0
      assert List.last(scoped).value == 110.0

      # And the combined change is the $10 really earned, not the $910 that
      # would include the second account's opening balance.
      assert List.last(combined).change == 10.0
    end

    test "windows by range" do
      record("2026-01-01", "6587", 50.0)

      assert {:ok, %{points: all}} = Commands.call("portfolio_history", %{"range" => "ALL"})
      assert {:ok, %{points: month}} = Commands.call("portfolio_history", %{"range" => "1M"})

      assert length(all) == 3
      assert length(month) == 2
    end

    test "carries coverage so an understated total is never silent" do
      Portfolio.store_backfill("6587", [
        %{bucket_on: d("2026-06-28"), realized: 50.0, trades: 2}
      ])

      record("2026-07-28", "8262", 900.0)

      assert {:ok, %{coverage: coverage}} = Commands.call("portfolio_history")
      assert coverage.missing == ["8262"]
    end

    test "an empty ledger answers with no points rather than an error" do
      Repo.delete_all(Portfolio.Snapshot)
      assert {:ok, %{points: []}} = Commands.call("portfolio_history")
    end

    test "it is safe-tier — an untrusted caller may read it" do
      assert {:ok, _} = Commands.call("portfolio_history", %{}, caller: :mcp)
    end

    test "a transfer is disclosed on the point that carries it" do
      {:ok, _} =
        Portfolio.put_flow(%{
          account_key: "6587",
          occurred_on: d("2026-07-28"),
          amount_cents: 50_000,
          kind: "deposit",
          source: "manual"
        })

      assert {:ok, %{points: [_, second]}} =
               Commands.call("portfolio_history", %{"account" => "6587"})

      assert second.transfer == 500.0
    end
  end

  describe "portfolio_flow_add" do
    test "takes the sign from the kind, never from the caller's amount" do
      assert {:ok, %{amount: -250.0}} =
               Commands.call("portfolio_flow_add", %{
                 "account" => "6587",
                 "day" => "2026-07-28",
                 "kind" => "withdrawal",
                 # A positive magnitude for a withdrawal must still store
                 # negative — otherwise it would ADD to the gain it removes.
                 "amount" => "250"
               })

      assert {:ok, %{flows: [flow]}} =
               Commands.call("portfolio_flow_list", %{"account" => "6587"})

      assert flow.amount == -250.0
      assert flow.kind == "withdrawal"
      assert flow.source == "agent"
    end

    test "accepts a numeric amount as well as a string" do
      assert {:ok, %{amount: 500.0}} =
               Commands.call("portfolio_flow_add", %{
                 "account" => "6587",
                 "day" => "2026-07-28",
                 "kind" => "deposit",
                 "amount" => 500
               })
    end

    test "not_a_transfer needs no amount and stores zero" do
      assert {:ok, %{amount: 0.0}} =
               Commands.call("portfolio_flow_add", %{
                 "account" => "6587",
                 "day" => "2026-07-28",
                 "kind" => "not_a_transfer"
               })
    end

    test "rejects a bad day, a bad kind, and a missing amount" do
      base = %{"account" => "6587", "day" => "2026-07-28", "kind" => "deposit"}

      assert {:error, :bad_day} =
               Commands.call("portfolio_flow_add", %{base | "day" => "not-a-date"})

      assert {:error, :bad_kind} =
               Commands.call("portfolio_flow_add", %{base | "kind" => "vibes"})

      assert {:error, :bad_amount} = Commands.call("portfolio_flow_add", base)

      assert {:error, :bad_amount} =
               Commands.call("portfolio_flow_add", Map.put(base, "amount", "-5"))
    end

    test "re-answering a day corrects it rather than stacking a second flow" do
      for amount <- ["500", "300"] do
        {:ok, _} =
          Commands.call("portfolio_flow_add", %{
            "account" => "6587",
            "day" => "2026-07-28",
            "kind" => "deposit",
            "amount" => amount
          })
      end

      assert {:ok, %{flows: [only]}} =
               Commands.call("portfolio_flow_list", %{"account" => "6587"})

      assert only.amount == 300.0
    end

    test "it is restricted — an untrusted caller cannot rewrite the gain math" do
      args = %{
        "account" => "6587",
        "day" => "2026-07-28",
        "kind" => "deposit",
        "amount" => "500"
      }

      assert {:error, :requires_confirmation} =
               Commands.call("portfolio_flow_add", args, caller: :mcp)

      assert {:ok, %{flows: []}} = Commands.call("portfolio_flow_list", %{"account" => "6587"})
    end
  end

  test "portfolio_flow_list needs an account" do
    assert {:error, :missing_account} = Commands.call("portfolio_flow_list", %{})
  end

  test "all three commands are in the catalog with the right tiers" do
    catalog = Commands.list_commands()
    by_name = Map.new(catalog, &{&1.name, &1})

    assert by_name["portfolio_history"].tier == :safe
    assert by_name["portfolio_flow_list"].tier == :safe
    assert by_name["portfolio_flow_add"].tier == :restricted
  end
end
