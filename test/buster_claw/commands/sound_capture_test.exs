defmodule BusterClaw.Commands.SoundCaptureTest do
  # The capture verbs' end-to-end wiring: catalogued, dispatchable, and — the part
  # that matters — carrying the trust metadata their capability deserves.
  #
  # WHAT THIS FILE DELIBERATELY DOES NOT DO: call `sound_input_level_set` or
  # `sound_record` for real. One would change the volume of the operator's
  # microphone as a side effect of running the suite; the other would open it. The
  # domain modules (`Capture`, `Capture.Level`, `Capture.Devices`) each take an
  # injected runner and test their own shell-out paths against it. What is left for
  # here is the layer above: argument coercion, the validation that happens BEFORE
  # anything is spawned, and the policy shape.
  use ExUnit.Case, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Commands.Catalog
  alias BusterClaw.Notifications.Cutup.Index
  alias BusterClaw.PolicyEngine

  @verbs ~w(sound_gaps sound_devices sound_input_level sound_input_level_set sound_record)

  defp entry(name), do: Enum.find(Catalog.entries(), &(&1.name == name))

  describe "the five verbs are wired" do
    test "each one is catalogued and reachable as a function" do
      for name <- @verbs do
        assert entry(name), "#{name} is missing from the catalog"

        # `to_existing_atom` is the right call here and not merely the linted one:
        # the atom exists precisely because a `defdelegate` created it, so a typo'd
        # verb raises rather than quietly asking whether a function nobody defined
        # is exported.
        assert function_exported?(Commands, String.to_existing_atom(name), 1),
               "#{name} is catalogued but has no arity-1 function on Commands"
      end
    end

    test "each declares every argument it reads" do
      # A verb that reads an argument it never declared is unusable by a model:
      # the catalog IS the documentation the agent gets.
      assert entry("sound_gaps").args |> Map.keys() |> Enum.sort() == ["limit", "target"]
      assert entry("sound_devices").args == %{}
      assert entry("sound_input_level").args == %{}
      assert entry("sound_input_level_set").args |> Map.keys() == ["volume"]

      assert entry("sound_record").args |> Map.keys() |> Enum.sort() == [
               "device",
               "name",
               "seconds"
             ]
    end
  end

  describe "trust metadata" do
    test "the three reads are safe, and the two writes are restricted" do
      for name <- ~w(sound_gaps sound_devices sound_input_level) do
        assert entry(name).type == :read
        assert entry(name).tier == :safe
        refute Map.get(entry(name), :gated, false), "#{name} is a read and should not be gated"
      end

      for name <- ~w(sound_input_level_set sound_record) do
        assert entry(name).type == :mutate
        assert entry(name).tier == :restricted
      end
    end

    # The load-bearing assertion in this file.
    #
    # `catalog_invariants_test.exs` already forces `sound_input_level_set` to be
    # restricted-or-gated, because its `@mutating_name_pattern` matches `_set$`.
    # **Nothing in that pattern matches "record"** — so `sound_record`'s gating is
    # a deliberate decision that no existing invariant would have caught, and this
    # is the test that stops it being quietly loosened.
    test "sound_record is gated, because :restricted alone does not stop an untrusted caller" do
      assert entry("sound_record").gated == true

      # The reason, asserted against the real policy rather than described in a
      # comment: `:restricted` earns a confirmation from :agent and :mcp, but an
      # :agent_untrusted caller is stopped ONLY by `gated`.
      assert {:confirm, _meta} =
               PolicyEngine.check(%{
                 name: "sound_record",
                 caller: :agent_untrusted,
                 tier: :restricted,
                 gated: true
               })

      # And the counterfactual: had it been restricted-but-ungated, an autonomous
      # run acting on content it did not choose could have opened the microphone
      # with no confirmation at all. This is what the line above buys.
      assert :allow =
               PolicyEngine.check(%{
                 name: "sound_record",
                 caller: :agent_untrusted,
                 tier: :restricted,
                 gated: false
               })
    end

    test "setting the input level is not gated — it is reversible and records nothing" do
      refute Map.get(entry("sound_input_level_set"), :gated, false)

      # Still confirmed for :agent/:mcp by virtue of being :restricted.
      for caller <- [:agent, :mcp] do
        assert {:confirm, _meta} =
                 PolicyEngine.check(%{
                   name: "sound_input_level_set",
                   caller: caller,
                   tier: :restricted
                 })
      end
    end
  end

  describe "validation happens before anything is spawned" do
    test "sound_input_level_set with no volume is refused without shelling out" do
      assert {:error, :volume_required} = Commands.sound_input_level_set(%{})
    end

    test "sound_record with no duration is refused without opening the microphone" do
      assert {:error, :duration_required} = Commands.sound_record(%{})
    end

    test "sound_record refuses a duration past the ceiling" do
      assert {:error, :duration_too_long} = Commands.sound_record(%{"seconds" => 100_000})
    end
  end

  describe "sound_gaps over a real index on disk" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "sound-capture-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      previous = Application.get_env(:buster_claw, :workspace_root)
      Application.put_env(:buster_claw, :workspace_root, root)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:buster_claw, :workspace_root, previous),
          else: Application.delete_env(:buster_claw, :workspace_root)

        File.rm_rf!(root)
      end)

      :ok
    end

    defp index!(source, words) do
      spans = Enum.map(words, fn {w, at} -> %{word: w, start_ms: at, end_ms: at + 100} end)
      {:ok, index} = Index.build(source, spans, origin: :aligned)
      :ok = Index.save(index)
    end

    test "an empty corpus reports zeros rather than an error" do
      assert {:ok, report} = Commands.sound_gaps()
      assert report.indexed_sources == 0
      assert report.distinct_words == 0
      assert report.single_take == []
    end

    test "single_take separates the quotations from the cut-ups" do
      index!("a.wav", [{"boat", 0}, {"boat", 500}, {"fog", 1000}])

      assert {:ok, report} = Commands.sound_gaps()
      assert report.distinct_words == 2
      assert report.total_takes == 3
      assert report.cuttable == 1
      assert report.single_take == ["fog"]
    end

    test "target reports the words a sentence could not be built from" do
      index!("a.wav", [{"the", 0}, {"boat", 500}])

      assert {:ok, report} = Commands.sound_gaps(%{"target" => "the boat sank"})
      assert report.missing == ["sank"]
    end

    test "limit arrives as a string from the CLI and still caps the list" do
      index!("a.wav", [{"boat", 0}, {"boat", 500}, {"fog", 1000}, {"tide", 1500}])

      # The coercion path: every CLI and JSON argument is a string.
      assert {:ok, report} = Commands.sound_gaps(%{"limit" => "2"})
      assert length(report.by_take_count) == 2

      # An unparseable value falls through to the domain module's own default
      # rather than inventing a second vocabulary of argument errors here.
      assert {:ok, unlimited} = Commands.sound_gaps(%{"limit" => "not-a-number"})
      assert length(unlimited.by_take_count) == 3
    end
  end
end
