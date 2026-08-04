defmodule BusterClaw.Finance.SourcesTest do
  use ExUnit.Case, async: false

  alias BusterClaw.ChartBuilder.DataReq
  alias BusterClaw.Finance.Sources

  setup do
    prev = Application.get_env(:buster_claw, :workspace_root)
    root = Path.join(System.tmp_dir!(), "bc-sources-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sources"))
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp write_override(root, name, contents),
    do: File.write!(Path.join([root, "sources", name]), contents)

  describe "the shipped catalogue" do
    test "every :verified entry carries the date it was verified" do
      # A :verified status with no date is a claim nobody can check. The whole
      # point of the field is that "verified a long time ago" stays visible.
      for source <- Sources.verified() do
        assert %Date{} = source.verified_on, "#{source.key} is :verified with no verified_on"
      end
    end

    test "keys are unique and every entry has a status the registry defines" do
      all = Sources.all()
      keys = Enum.map(all, & &1.key)
      assert length(keys) == length(Enum.uniq(keys))

      for source <- all do
        assert source.status in [:verified, :candidate, :blocked, :unsanctioned, :dead]
      end
    end

    test "FRED is :blocked — a decision, not a to-do" do
      # Recorded so nobody 'unblocks' it by writing an adapter. The barrier is
      # its terms (ML use and caching), not that nobody has called it.
      fred = Sources.get("fred")
      assert fred.status == :blocked
      assert fred.terms =~ "machine learning"
      assert fred.terms =~ "caching"
      assert fred.note =~ "REDISTRIBUTOR"
    end

    test "the sources that would be lost to a rediscovery are recorded as decisions" do
      assert Sources.get("yahoo_unofficial").status == :unsanctioned
      assert Sources.get("nasdaq_datalink").status == :dead
      # The reason has to travel with the entry, or the next person just finds
      # the endpoint again and wires it up.
      assert Sources.get("yahoo_unofficial").note =~ "DECISION"
    end

    test "the traps that would produce a wrong-looking-right chart are written down" do
      assert Sources.get("bls").note =~ "M13"
      assert Sources.get("bea").note =~ "HTTP 200 ON FAILURE"
      assert Sources.get("worldbank").note =~ "do not coerce to 0"
    end
  end

  describe "workspace overrides" do
    test "an override corrects a shipped field without replacing the entry", %{root: root} do
      write_override(root, "bls.md", """
      ---
      rate_limit: 500/day — key registered 2026-08-04
      ---

      Registered a key, so the keyless ceiling no longer applies.
      """)

      bls = Sources.get("bls")
      assert bls.rate_limit =~ "key registered"
      assert bls.note =~ "Registered a key"
      # Untouched fields survive: an override is a patch, not a replacement.
      assert bls.name == "U.S. Bureau of Labor Statistics"
      assert bls.status == :verified
    end

    test "an operator can mark a source dead — the case the code cannot ship fast enough for",
         %{root: root} do
      write_override(root, "frankfurter.md", """
      ---
      status: dead
      ---

      Started returning 522s constantly on 2026-08-10.
      """)

      assert Sources.get("frankfurter").status == :dead
      refute Enum.any?(Sources.verified(), &(&1.key == "frankfurter"))
    end

    test "a new key adds a source, and it lands as :candidate", %{root: root} do
      # Conservative by construction: writing a file must not be able to mint
      # something the fetch path would treat as trustworthy.
      write_override(root, "mysource.md", """
      ---
      name: Some Local Feed
      base_url: https://example.test
      ---

      Notes.
      """)

      added = Sources.get("mysource")
      assert added.name == "Some Local Feed"
      assert added.status == :candidate
      assert added.auth == :unknown
    end

    test "an override cannot promote itself to a status the registry does not define",
         %{root: root} do
      write_override(root, "bea.md", "---\nstatus: totally-fine\n---\n")
      assert Sources.get("bea").status == :candidate
    end

    test "a malformed override is skipped, not fatal", %{root: root} do
      write_override(root, "broken.md", "no frontmatter, just words")
      assert is_list(Sources.all())
      assert Sources.get("bls").status == :verified
    end

    test "no overrides directory at all is fine" do
      Application.put_env(
        :buster_claw,
        :workspace_root,
        "/nonexistent-#{System.unique_integer()}"
      )

      assert Sources.get("bls").status == :verified
    end
  end

  describe "listing is not permission" do
    test "only :verified sources WITH an adapter are fetchable" do
      # The registry describes 16 sources; exactly one can be fetched. A source
      # becomes fetchable by someone writing an adapter, never by being described
      # — which is what stops a :blocked or :unsanctioned entry being reachable
      # because it happens to be listed.
      fetchable = DataReq.source_keys()
      assert fetchable == ["bls", "market"]

      for key <- ["fred", "yahoo_unofficial", "nasdaq_datalink", "bea", "coingecko"] do
        refute key in fetchable, "#{key} must not be fetchable"
      end
    end

    test "a source with an adapter but no :verified status is not fetchable", %{root: root} do
      write_override(root, "bls.md", "---\nstatus: candidate\n---\n")
      # The adapter still exists; the status is what withdraws it.
      refute "bls" in DataReq.source_keys()
    end
  end
end
