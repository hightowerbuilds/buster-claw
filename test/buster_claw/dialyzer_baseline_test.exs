defmodule BusterClaw.DialyzerBaselineTest do
  @moduledoc """
  Guards the `unmatched_return` gate in `.dialyzer_ignore.exs`.

  ## What this is protecting against

  That file used to hand-list 76 files whose `unmatched_return` findings were
  accepted, and **the list rotted the moment anyone added a file**. By 08-13 the
  gate was red with 67 findings, 51 of them in files written after the baseline.
  It was not catching defects; it was catching new files, and it had been red
  long enough that nobody read it.

  It is a rule now: `unmatched_return` is accepted everywhere except a short list
  of paths where a silently discarded return could lose a security record or
  persisted data.

  ## Why the rule needs its own test

  A prefix-match rule has a failure mode the old list did not: **it fails
  silently in the safe-looking direction.** Rename `clinch.ex`, or mistype a
  prefix, and the rule matches nothing — the file is quietly accepted, the gate
  goes green, and it looks like it worked. That is the same rot as before, just
  harder to see.

  So this asserts the *outcome* rather than re-listing the prefixes: the files
  that must be gated are named here, and the gated set is derived from the ignore
  file's own output. One source of truth, stated as a requirement.
  """
  use ExUnit.Case, async: true

  # Named by what they protect, not by prefix. If one of these is renamed, this
  # test fails and the rename has to deal with the gate — which is the whole
  # point, because the alternative is it silently stops being gated.
  @must_be_gated %{
    "lib/buster_claw/clinch.ex" =>
      "credentials — the audit trail is the only record a credential was used or revoked",
    "lib/buster_claw/sentinel.ex" =>
      "the audit layer itself; if it drops a return nothing else will notice",
    "lib/buster_claw/vault.ex" => "encryption at rest",
    "lib/buster_claw/notes.ex" => "the operator's vault — atomic writes, conflict detection",
    "lib/buster_claw/policy_engine.ex" => "the tier system",
    "lib/buster_claw/api_token.ex" => "the token the tiers are read from"
  }

  setup_all do
    {entries, _bindings} = Code.eval_file(".dialyzer_ignore.exs")

    accepted =
      for {file, :unmatched_return} <- entries, into: MapSet.new(), do: file

    %{entries: entries, accepted: accepted, all: Path.wildcard("lib/**/*.ex")}
  end

  describe "the gate covers what it claims to" do
    test "every security- and durability-critical file is gated", %{accepted: accepted} do
      for {file, why} <- @must_be_gated do
        assert File.exists?(file),
               """
               #{file} does not exist, so the prefix that gates it matches nothing.

               A renamed gated file silently stops being gated and the build stays
               green — the exact failure this whole restructure was fixing. Update
               the `gated` list in .dialyzer_ignore.exs and this map together.
               """

        refute MapSet.member?(accepted, file),
               """
               #{file} is on the accepted list for :unmatched_return.

               It is gated because: #{why}.

               A discarded return here is invisible by construction. This has
               already cost us once — two Clinch revocation categories recorded
               nothing while the suite stayed green, because Sentinel.observe/4 is
               best-effort and its result was dropped.
               """
      end
    end

    test "at least one telephony file is gated", %{accepted: accepted} do
      telephony = Path.wildcard("lib/buster_claw/telephony/**/*.ex")

      assert telephony != [], "lib/buster_claw/telephony/ has no modules — the prefix is stale"

      refute Enum.any?(telephony, &MapSet.member?(accepted, &1)),
             "a telephony module is accepting unmatched returns. That path is " <>
               "persist-then-ack: a dropped return is a message acknowledged and lost."
    end
  end

  describe "the rule is not vacuous" do
    # The rule is a rejection over a wildcard. Both ends can fail silently: match
    # everything (nothing gated) or match nothing (everything gated, gate red
    # forever). Neither shows up as an error, so both are asserted.
    test "the accepted list is smaller than the tree, so something is actually gated", %{
      accepted: accepted,
      all: all
    } do
      assert MapSet.size(accepted) > 0,
             "no file accepts :unmatched_return — the wildcard matched nothing, and " <>
               "the gate is about to fail on every best-effort broadcast in the app"

      assert MapSet.size(accepted) < length(all),
             "every one of the #{length(all)} files under lib/ is accepted, so the " <>
               "gated list gates nothing. A mistyped prefix looks exactly like this " <>
               "and leaves the build green."
    end

    test "the accepted list contains only files that exist", %{accepted: accepted} do
      missing = Enum.reject(accepted, &File.exists?/1)

      assert missing == [],
             "the accepted list names files that are gone: #{inspect(Enum.take(missing, 5))}. " <>
               "It is computed from a wildcard, so this means it was hand-edited."
    end
  end
end
