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

  describe "catalog access" do
    # Whether the catalog is memoized differs by environment (dev rebuilds so
    # newly-added commands appear without a restart; prod caches). Both paths
    # must answer identically and repeatably — a caching bug here would show up
    # as commands intermittently not existing.
    test "repeated reads are stable and agree with the raw entries" do
      first = BusterClaw.Commands.list_commands()
      second = BusterClaw.Commands.list_commands()

      assert first == second
      assert Enum.map(first, & &1.name) == Enum.map(Catalog.entries(), & &1.name)
    end

    test "every catalogued command has an implementation behind it" do
      # Checked by reflection, never by calling them: dispatching every real
      # commands to find out would send mail, hit APIs, and mutate the workspace.
      missing =
        Catalog.entries()
        |> Enum.map(& &1.name)
        |> Enum.reject(fn name ->
          function_exported?(BusterClaw.Commands, String.to_existing_atom(name), 1)
        end)

      assert missing == [],
             "catalogued but unimplemented (dispatch would answer unknown_command): #{inspect(missing)}"
    end
  end

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
    #
    # Review notes for entries whose safety is not self-evident:
    #
    #   browser_secret_list (added 08-03) — returns secret NAMES and notes,
    #   never a value, and there is deliberately no command that returns one.
    #   The model needs the names to write `$secret.<name>` in a fill at all, so
    #   this is the minimum visibility the reference design requires. Read-only;
    #   nothing outbound, nothing irreversible.
    #
    #   sound_list / sound_routes / sound_sources / sound_probe (added 08-08,
    #   STUDIO_ROADMAP Part I Phase 0) — the read half of the Studio surface.
    #   They list the sound library's two layers, the event routing table, and
    #   the studio's imported clips, and read one named file's header/samples to
    #   report format, duration and peak. Names are basenames allowlisted
    #   against a directory listing, so nothing outside `sounds/` is reachable.
    #   Nothing here writes a file, changes a route, or plays anything.
    #
    #   sound_probe's reach WIDENED 08-08 (Part I Phase 1) and stays :safe: it
    #   now also takes an `event_id` (a phone event whose recording_path the app
    #   stored itself) or a path **relative to the Library root**, so a voicemail
    #   can be inspected before it is imported. That is the only path-shaped
    #   input in the safe tier, and it is why `Commands.Sound.under_library/1`
    #   refuses absolute paths, `~`, `..` and null bytes before touching the
    #   filesystem and then re-checks the expanded path against the root. It
    #   returns format/duration/peak — never file contents, and never a path
    #   outside that root. `decode: true` additionally runs the file through the
    #   system decoder to measure its level; that is a subprocess over a file
    #   already inside the Library root, and it writes nothing.
    #
    #   sound_transcript_search / sound_transcript_words / sound_corpus /
    #   sound_index_list / sound_index_words / sound_index_search (added 08-08,
    #   STUDIO_ROADMAP Part III) — the cut-up read surface. The transcript three
    #   read the `transcript` column of telephony events the operator already
    #   received and report where the audio lives (a Library-relative path, never
    #   an absolute one, and never file contents). The index three read JSON word
    #   indexes under `sounds/studio/index/`, gated to basenames by the same
    #   allowlist. Nothing outbound, nothing written; the writing cut-up verbs
    #   (sound_index_import, sound_index_delete, sound_assemble) are :restricted
    #   and deliberately absent from this list.
    #
    #   pocket_list / pocket_describe / pocket_read (added 08-08, POCKETS_ROADMAP
    #   Phase 4) — the whole Pocket surface, and it is read-only by
    #   construction. They list the operator's own media folders, report one
    #   folder's manifest and file listing, and return the text of one file.
    #   `pocket_read`'s entire reach is `Pockets.resolve/2`: a BARE filename,
    #   canonicalized back against the Pocket's own directory and `lstat`ed, so
    #   a separator, a `..` or a planted symlink is refused rather than
    #   followed. Binary files return no bytes at all. Nothing here writes, and
    #   — the point of the roadmap's D4 — there is deliberately no verb at any
    #   tier that records, changes or removes a MOUNT; that is an operator act
    #   in the UI, and `commands/pocket_test.exs` fails if one ever appears.
    #
    #   terminal_theme_list (added 08-09, TERMINAL_PAINT_ROADMAP Phase 3) — the
    #   read half of the terminal-colour surface, and the only one of its four
    #   verbs that is safe. It reports the theme keys, labels and swatches that
    #   already ship in the page's own `<meta>` payload, plus whether each of the
    #   two dynamic slots holds a saved palette. No colour it returns is a
    #   secret, nothing is written, and nothing is applied — the three verbs that
    #   CHANGE what the operator sees (terminal_theme_select / _paint / _reset)
    #   are :restricted and deliberately absent from this list.
    #
    #   background_list (added 08-15, DMG review B1) — the read half of the
    #   background surface. It reports the option keys and labels the operator's
    #   own Settings → Appearance page already renders, which mode each of the
    #   two surfaces resolves to, and the served `/appearance/image/<slot>` URLs
    #   the webview already fetches. Nothing is written and nothing is applied;
    #   `background_set`, which changes what the operator is looking at, is
    #   :restricted and deliberately absent from this list.
    @safe_tier ~w(
      activity_report
      agent_run_status
      background_list
      bookmark_export
      bookmark_list
      browser_check_list
      browser_fetch
      browser_secret_list
      browser_wait
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
      finance_sources
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
      journal_read
      memory_search
      notify_get
      notify_list
      phone_get
      phone_list
      phone_stats
      pocket_describe
      pocket_list
      pocket_read
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
      sound_corpus
      sound_devices
      sound_gaps
      sound_index_list
      sound_index_search
      sound_index_words
      sound_input_level
      sound_list
      sound_probe
      sound_routes
      sound_sources
      sound_transcript_search
      sound_transcript_words
      tasks_get
      tasks_list
      terminal_command_list
      terminal_tab_open
      terminal_theme_list
      voice_bank_list
      web_search
    )

    # `finance_sources` reviewed and added 08-03: a pure read of a static,
    # code-shipped catalogue of public API metadata. No outbound call, no user
    # data, no secret, nothing irreversible — it answers "where could financial
    # data come from", which is the same answer for every caller.
    #
    # `sound_gaps`, `sound_devices` and `sound_input_level` reviewed and added
    # 08-09 with the capture surface (STUDIO_ROADMAP Part V). Each is a read in
    # the strict sense — none opens the microphone, and that is the line worth
    # stating, because all three sit next to a verb that does:
    #   * `sound_gaps` reads the word indexes already on disk and counts them.
    #   * `sound_devices` ASKS WHAT EXISTS via `system_profiler`. Enumerating
    #     inputs is not capturing from one; it needs no TCC consent and returns
    #     the same answer whether or not consent was ever granted.
    #   * `sound_input_level` reads the OS input volume. It is the get half of a
    #     pair whose set half is deliberately `:restricted` — reading a mixer
    #     level reveals nothing about the room.
    # `sound_record` and `sound_input_level_set` are NOT here, by design: the
    # first is `:restricted` AND `gated` (see `sound_capture_test.exs` for why
    # `:restricted` alone would not have been enough), the second `:restricted`.
    # `voice_bank_list` reviewed and added 08-16 with the contribution surface
    # (STUDIO_ROADMAP Part V). It reads the roster — bank names and labels — plus
    # which one is active. The question worth asking, since a bank label is often
    # a PERSON'S NAME: does naming the voices in the corpus leak more than the
    # tier already allows? No. `sound_gaps` and `sound_index_list` are both
    # already `:safe` and return the actual WORDS spoken in those recordings, so
    # a caller that can read the vocabulary can already read far more than the
    # label above it. Its three write siblings — `voice_bank_create`,
    # `voice_bank_select`, `voice_bank_delete` — are all `:restricted`, and
    # `delete` is `gated` on top.
    #
    # (Note lives out here because ~w() has no comment syntax; putting it inside
    # the sigil turns every word into a command name, which this very test
    # caught.)

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
