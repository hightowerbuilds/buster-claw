defmodule BusterClawWeb.FrontDoorTest do
  @moduledoc """
  `VI-a`: the four front-door surfaces must say one sentence.

  The failure this guards is not hypothetical and not small. Before 08-16 the
  README pitched a runtime, the website pitched the same runtime, the setup
  wizard pitched an email assistant, and the home screen's chat pitched a
  headless Claude — and a user could not answer "what is Buster Claw?" after a
  full session, because the answer changed with the screen. The 08-16 novice
  review walked into it from outside, a week after the map recorded it.

  ## What this can and cannot reach

  Three of the four surfaces are in this repo and are asserted below. **The
  fourth — busterclaw.lol — is in another repository and no test here can render
  it.** That is stated rather than quietly omitted, because the same blind spot
  has already cost this project something real: for two weeks in August the
  public repo and the public site stated *opposite legal terms*, and nothing in
  this tree could have caught it. This file narrows that gap from four surfaces
  to one; it does not close it.

  ## Why it reads source rather than rendering

  The README is not rendered by anything, and the two Elixir surfaces carry the
  sentence as a compile-time default rather than something a mount produces. A
  render test would pass while the README drifted, which is the case that
  actually happened.
  """
  use ExUnit.Case, async: true

  # The sentence. Kept here as a literal rather than read from one of the
  # surfaces on purpose: if it were read from the README, a README rewrite would
  # silently redefine what the other two must match, and the test would go
  # vacuously green while the app said something new.
  @sentence "An assistant on your Mac that uses your tools, keeps working, and shows you what it did"

  # Each surface, and the file that owns its copy. `SetupLive`'s headline wraps
  # across source lines in HEEx, so its check normalizes whitespace first.
  @surfaces [
    {"README", "README.md"},
    {"the setup wizard", "lib/buster_claw_web/live/setup_live.ex"},
    {"the home chat", "lib/buster_claw_web/components/chat_panel.ex"}
  ]

  defp squish(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  describe "the one sentence" do
    for {name, path} <- @surfaces do
      test "#{name} says it" do
        source = unquote(path) |> File.read!() |> squish()

        assert source =~ squish(@sentence),
               """
               #{unquote(name)} (#{unquote(path)}) no longer carries the front-door sentence:

                   #{@sentence}

               This is `VI-a` in daily-growth/roadmaps/distribution/FRONT_DOOR_ROADMAP.md.
               Four surfaces must agree; changing one alone produces a fifth pitch
               rather than a fix. If the sentence is being changed deliberately,
               change it in all of them — including busterclaw.lol, which lives in
               another repository and which this test cannot see.
               """
      end
    end
  end

  describe "retired pitches stay retired" do
    # A deprecated-name guard, the idiom the 08-09 doc-drift comb added after
    # finding that a deleted feature's prose reliably outlives it. Asserting the
    # new sentence is present does not stop the old one sitting beside it, and
    # two pitches on one page is the exact defect `VI-a` describes.
    @retired [
      {"the runtime pitch", "desktop runtime that gives an AI agent hands"},
      {"the email-first pitch", "Your assistant, reachable by email"},
      {"the queue-jargon opener", "check your mail, work the queue"}
    ]

    for {name, phrase} <- @retired do
      test "#{name} is gone from every surface" do
        offenders =
          for {surface, path} <- @surfaces,
              File.read!(path) =~ unquote(phrase),
              do: "#{surface} (#{path})"

        assert offenders == [],
               """
               #{unquote(name)} is back, in: #{Enum.join(offenders, ", ")}

                   "#{unquote(phrase)}"

               It was retired on 08-16 when the front door was set to the
               assistant-first sentence. A surface carrying both says two things.
               """
      end
    end
  end

  # `VI-i`: the home chat's empty state named Claude while the harness is
  # `ModelPolicy.backend_for(:chat)`, which returns codex or opencode just as
  # readily. That sentence was false for any operator who had switched, and
  # nothing tested it — the review found it by reading.
  test "the home chat does not name one harness as though it were the only one" do
    empty_state =
      "lib/buster_claw_web/components/chat_panel.ex"
      |> File.read!()
      |> String.split("attr :empty_message")
      |> Enum.at(1)
      |> String.slice(0, 600)

    refute empty_state =~ "Claude",
           """
           The chat's empty state names Claude again.

           The harness comes from `ModelPolicy.backend_for(:chat)` and may be
           codex or opencode. Naming one makes the front door false for anyone
           who switched — `VI-i` in FRONT_DOOR_ROADMAP.md. If a harness must be
           named here, read it from ModelPolicy rather than hardcoding it.
           """
  end
end
