defmodule BusterClaw.SentinelCategoryTest do
  @moduledoc """
  Every category the app emits must be one `Sentinel.Event` accepts.

  ## Why this needed a test

  `Sentinel.observe/4` is **best-effort by design**: the audit write must never
  raise on the hot path of a recorded action, so a failed insert is logged and
  swallowed. That is right, and it has a sharp edge — a category outside
  `Event.categories/0` produces an invalid changeset, the event is dropped, and
  **the caller is told nothing**.

  This was not hypothetical. Adding `:credential_revoked` and
  `:credential_missing` on 08-10 wired them through `classify/2`, called them from
  `Clinch`, and shipped them into a void: the full suite passed, the new tests
  passed, and the only evidence was a `Logger.warning` in the middle of otherwise
  green output. A security feature that silently does nothing is worse than one
  that is missing, because the roadmap says it is there.

  ## Why source text rather than runtime

  The property is "which categories does this codebase *emit*", which no runtime
  can enumerate — a category in a branch nobody took in a test run is exactly the
  one that will be dropped in production. Same reasoning as
  `Clinch.ChokepointTest` and `acl_lockstep.rs`: read the source, fail in the
  second it breaks.
  """
  use ExUnit.Case, async: true

  alias BusterClaw.Sentinel.Event

  # `Sentinel.observe(:category, ...)` and `Sentinel.observe(\n  :category, ...`.
  @call_re ~r/Sentinel\.observe\(\s*:([a-z_]+)/

  defp emitted_categories do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      @call_re
      |> Regex.scan(File.read!(file), capture: :all_but_first)
      |> Enum.map(fn [category] -> {file, category} end)
    end)
  end

  test "every emitted category is one Event accepts" do
    emitted = emitted_categories()

    # A stripper or regex that matched nothing would make the assertion below
    # vacuously true — the failure mode this repo keeps finding.
    refute Enum.empty?(emitted),
           "found no Sentinel.observe/4 call sites at all — the scan is broken, " <>
             "and a broken scan reads exactly like a clean codebase"

    allowed = MapSet.new(Event.categories())

    unknown =
      emitted
      |> Enum.reject(fn {_file, category} -> MapSet.member?(allowed, category) end)
      |> Enum.uniq()

    assert unknown == [],
           """
           Sentinel category emitted but not accepted by Event.categories/0:

           #{Enum.map_join(unknown, "\n", fn {file, category} -> "  #{file} — :#{category}" end)}

           These events are DROPPED. `observe/4` is best-effort, so the write fails,
           a warning is logged, and the caller is told nothing — the feature looks
           implemented and records nothing. Add the category to
           `BusterClaw.Sentinel.Event`.
           """
  end

  test "the whitelist is real — an unknown category does not persist" do
    # The positive control for the test above: if Event accepted anything, the
    # scan would be guarding a rule that does not exist.
    changeset =
      Event.changeset(%Event{}, %{
        category: "definitely_not_a_category",
        severity: "info",
        message: "x"
      })

    refute changeset.valid?
  end

  test "every category the app accepts can actually be classified" do
    # The other direction: a category in the whitelist that `classify/2` has no
    # clause for still works (there is a catch-all), but this asserts the
    # catch-all is doing the job rather than raising.
    for category <- Event.categories() do
      # `to_atom`, and it must stay `to_atom`. Swapping in `to_existing_atom`
      # for the credo warning makes this test RAISE rather than assert: at
      # least one whitelisted category has no atom anywhere in the compiled
      # tree, which is exactly the case the catch-all exists for and exactly
      # what this test is here to cover. Measured 08-14 — the swap was tried
      # and turned this green test red. Runtime atom creation is bounded here
      # by `Event.categories()`, a compile-time whitelist.
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      severity = BusterClaw.Sentinel.classify(String.to_atom(category), %{})

      assert severity in [:info, :notice, :warning, :critical],
             "#{category} classified as #{inspect(severity)}, which is not a severity"
    end
  end
end
