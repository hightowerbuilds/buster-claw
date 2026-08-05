defmodule BusterClaw.WatchlistTest do
  # async: false — writes the shared `watchlists` Settings row.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Watchlist

  describe "the empty state" do
    test "is empty, not an error — a fresh install has no lists" do
      assert Watchlist.all() == %{}
      assert Watchlist.names() == []
      assert Watchlist.symbols() == []
      assert Watchlist.list("nope") == []
      refute Watchlist.watched?("NVDA")
    end
  end

  describe "creating lists" do
    test "creates, and names come back sorted" do
      {:ok, _} = Watchlist.create("Semis")
      {:ok, _} = Watchlist.create("Benchmarks")

      assert Watchlist.names() == ["Benchmarks", "Semis"]
      assert Watchlist.list("Semis") == []
    end

    test "trims the name, so a stray space is not a second list" do
      {:ok, _} = Watchlist.create("  Semis  ")
      assert Watchlist.names() == ["Semis"]
    end

    test "refuses blank, over-long, and duplicate names" do
      assert {:error, :blank_name} = Watchlist.create("   ")
      assert {:error, :name_too_long} = Watchlist.create(String.duplicate("x", 41))

      {:ok, _} = Watchlist.create("Semis")
      assert {:error, {:exists, "Semis"}} = Watchlist.create("Semis")
    end
  end

  describe "adding symbols" do
    setup do
      {:ok, _} = Watchlist.create("Semis")
      :ok
    end

    test "normalizes case and whitespace, so nvda and NVDA are one entry" do
      {:ok, _} = Watchlist.add("Semis", " nvda ")
      {:ok, _} = Watchlist.add("Semis", "NVDA")

      assert Watchlist.list("Semis") == ["NVDA"]
      assert Watchlist.watched?("nvda")
    end

    test "keeps insertion order, because the operator chose it" do
      {:ok, _} = Watchlist.add("Semis", "NVDA")
      {:ok, _} = Watchlist.add("Semis", "AMD")
      {:ok, _} = Watchlist.add("Semis", "AVGO")

      assert Watchlist.list("Semis") == ["NVDA", "AMD", "AVGO"]
    end

    # Class shares and some ETFs really are spelled this way.
    test "accepts dotted and hyphenated tickers" do
      {:ok, _} = Watchlist.add("Semis", "BRK.B")
      {:ok, _} = Watchlist.add("Semis", "RDS-A")

      assert "BRK.B" in Watchlist.list("Semis")
      assert "RDS-A" in Watchlist.list("Semis")
    end

    test "refuses things that are not tickers" do
      assert {:error, {:bad_symbol, _}} = Watchlist.add("Semis", "")
      assert {:error, {:bad_symbol, _}} = Watchlist.add("Semis", "not a ticker")
      assert {:error, {:bad_symbol, _}} = Watchlist.add("Semis", "9NVDA")
      assert {:error, {:bad_symbol, _}} = Watchlist.add("Semis", "TOOLONGSYMBOL")
    end

    test "refuses a list that does not exist rather than creating one" do
      assert {:error, {:no_such_list, "Ghost"}} = Watchlist.add("Ghost", "NVDA")
      assert Watchlist.names() == ["Semis"]
    end
  end

  describe "symbols/0 — what a fetch would actually want" do
    test "is the deduplicated union across lists" do
      {:ok, _} = Watchlist.create("Semis")
      {:ok, _} = Watchlist.create("Mega")
      {:ok, _} = Watchlist.add("Semis", "NVDA")
      {:ok, _} = Watchlist.add("Mega", "NVDA")
      {:ok, _} = Watchlist.add("Mega", "GOOGL")

      # NVDA is watched twice and fetched once.
      assert Watchlist.symbols() == ["GOOGL", "NVDA"]
    end
  end

  describe "removing" do
    setup do
      {:ok, _} = Watchlist.create("Semis")
      {:ok, _} = Watchlist.add("Semis", "NVDA")
      {:ok, _} = Watchlist.add("Semis", "AMD")
      :ok
    end

    test "removes one symbol and leaves the rest" do
      {:ok, _} = Watchlist.remove("Semis", "nvda")
      assert Watchlist.list("Semis") == ["AMD"]
    end

    test "removing something absent is not an error" do
      assert {:ok, _} = Watchlist.remove("Semis", "TSLA")
      assert Watchlist.list("Semis") == ["NVDA", "AMD"]
    end

    test "deleting a list stops the watching, and nothing else" do
      {:ok, _} = Watchlist.delete("Semis")

      assert Watchlist.names() == []
      refute Watchlist.watched?("NVDA")
      assert {:error, {:no_such_list, "Semis"}} = Watchlist.delete("Semis")
    end
  end

  describe "durability" do
    test "a corrupt row reads as empty rather than crashing every caller" do
      BusterClaw.Settings.put("watchlists", "not json")

      assert Watchlist.all() == %{}
      assert Watchlist.symbols() == []
    end

    test "junk inside a valid row is filtered, not trusted" do
      BusterClaw.Settings.put(
        "watchlists",
        Jason.encode!(%{"Semis" => ["NVDA", 5, nil], "Bad" => "not a list"})
      )

      assert Watchlist.list("Semis") == ["NVDA"]
      assert Watchlist.names() == ["Semis"]
    end
  end
end
