defmodule BusterClaw.Commands.CatalogInvariantsTest do
  # The entire trust model keys off the tier/gated metadata in the catalog: a
  # one-character mistake marking an outbound command :safe means every
  # MCP-token agent can fire it. These tests make that mistake impossible to
  # land silently — loosening a tier shows up as a loud, named test diff.
  use ExUnit.Case, async: true

  alias BusterClaw.Commands.Catalog

  @entries Catalog.entries()

  # Commands whose names *sound* mutating but are deliberately :safe and
  # ungated. Adding a name here is a reviewed, deliberate act in a diff — never
  # an accident. Keep each entry justified.
  @mutating_name_exceptions %{
                              # (none yet)
                            }

  # Name fragments that imply an outbound, destructive, or state-changing
  # action. Any command matching one must be :restricted or gated, unless it
  # carries a justified exception above.
  @mutating_name_pattern ~r/(send|delete|create|update|save|write|reply|move|archive|trash|remove|approve|dismiss|^set_|_set$)/

  describe "structural invariants" do
    test "names are unique" do
      names = Enum.map(@entries, & &1.name)
      dupes = names -- Enum.uniq(names)
      assert dupes == [], "duplicate command names: #{inspect(dupes)}"
    end

    test "names are policy-glob friendly (lowercase snake_case)" do
      bad = Enum.reject(@entries, &Regex.match?(~r/\A[a-z0-9_]+\z/, &1.name))
      assert bad == [], "bad command names: #{inspect(Enum.map(bad, & &1.name))}"
    end

    test "every entry carries a valid tier, type, and description" do
      for entry <- @entries do
        assert entry.tier in [:safe, :restricted],
               "#{entry.name}: bad tier #{inspect(entry.tier)}"

        assert entry.type in [:read, :mutate, :trigger],
               "#{entry.name}: bad type #{inspect(entry.type)}"

        assert is_binary(entry.description) and entry.description != "",
               "#{entry.name}: missing description"

        assert is_map(entry.args), "#{entry.name}: args must be a map"

        gated = Map.get(entry, :gated, false)
        assert is_boolean(gated), "#{entry.name}: gated must be boolean"
      end
    end

    test "gated implies restricted" do
      bad =
        @entries
        |> Enum.filter(&Map.get(&1, :gated, false))
        |> Enum.reject(&(&1.tier == :restricted))

      assert bad == [],
             "gated commands must be :restricted (gated is a gate on TOP of the tier, " <>
               "not a substitute): #{inspect(Enum.map(bad, & &1.name))}"
    end
  end

  describe "semantic invariants" do
    test "mutating-sounding commands are restricted or gated" do
      offenders =
        @entries
        |> Enum.filter(fn entry ->
          Regex.match?(@mutating_name_pattern, entry.name) and
            entry.tier == :safe and
            not Map.get(entry, :gated, false) and
            not Map.has_key?(@mutating_name_exceptions, entry.name)
        end)
        |> Enum.map(& &1.name)

      assert offenders == [],
             """
             These commands sound outbound/destructive but are :safe and ungated:
             #{inspect(offenders)}
             Either fix the tier, or add a justified entry to @mutating_name_exceptions.
             """
    end

    test "exception allowlist contains no stale names" do
      known = MapSet.new(@entries, & &1.name)
      stale = Enum.reject(Map.keys(@mutating_name_exceptions), &MapSet.member?(known, &1))
      assert stale == [], "exceptions for commands that no longer exist: #{inspect(stale)}"
    end
  end

  describe "safe-tier snapshot" do
    # The exact set of commands an :mcp / :agent caller may run. Any change to
    # this list is a change to the trust boundary — the diff below should be
    # reviewed with exactly that in mind. Regenerate with:
    #
    #   MIX_ENV=test mix run --no-start -e 'BusterClaw.Commands.Catalog.entries() |> Enum.filter(&(&1.tier == :safe)) |> Enum.map(& &1.name) |> Enum.sort() |> Enum.each(&IO.puts("        \"#{&1}\","))'
    @safe_tier ~w(
      activity_report
      bookmark_export
      bookmark_list
      browser_fetch
      contacts_get
      contacts_list
      contacts_search
      dispatch_block
      dispatch_claim
      dispatch_done
      dispatch_list
      dispatch_show
      docs_get
      document_get
      document_list
      document_read
      drive_download
      drive_export
      drive_get
      drive_list
      event_get
      event_list
      finance_filings
      finance_fundamentals
      finance_news
      finance_quote
      gmail_label_list
      gmail_read
      gmail_search
      gmail_sync
      google_account_get
      google_account_list
      google_calendar_sync
      history_recent
      history_search
      integration_get
      integration_list
      integration_poll
      integration_poll_all
      integration_run_list
      job_list
      job_show
      memory_search
      runtime_status
      sheets_get
      sheets_get_values
      shift_assignment_start
      shift_assignment_status
      shift_assignment_stop
      shift_start
      shift_status
      shift_stop
      skill_suggestions
      slides_get
      tasks_get
      tasks_list
      terminal_command_list
      terminal_tab_open
      wallet_budget_summary
      wallet_feed_list
      wallet_get
      wallet_list
      wallet_list_transactions
      web_search
    )

    test "the safe tier is exactly the reviewed snapshot" do
      actual =
        @entries
        |> Enum.filter(&(&1.tier == :safe))
        |> Enum.map(& &1.name)
        |> Enum.sort()

      newly_safe = actual -- @safe_tier
      no_longer_safe = @safe_tier -- actual

      assert newly_safe == [],
             """
             Commands newly promoted to the :safe tier (runnable by any MCP/agent token):
             #{inspect(newly_safe)}
             If intentional, review each for outbound/irreversible effects, then add it
             to the snapshot in this test.
             """

      assert no_longer_safe == [],
             """
             Commands removed from the :safe tier (or renamed/deleted):
             #{inspect(no_longer_safe)}
             If intentional, remove them from the snapshot in this test.
             """
    end
  end
end
