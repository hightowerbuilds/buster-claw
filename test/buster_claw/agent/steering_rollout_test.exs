defmodule BusterClaw.Agent.SteeringRolloutTest do
  @moduledoc """
  Live steering must not reach a shipped build by accident.

  LAUNCH_ROADMAP G-41. The roadmap's standing preference is a **CI assertion
  over a checklist line**, because a checklist can be skipped and this one would
  be skipped on exactly the release where it mattered — the flag is invisible in
  the UI until a run is in flight, so an accidental rollout would not be obvious
  from clicking around.

  What is actually at stake: with the flag on, a chat conversation holds a
  long-lived `claude` process, a `codex app-server` connection, or an
  `opencode serve` subprocess. That is a real change in what a packaged app does
  on a user's machine, and it should be a decision rather than a leftover.
  """
  use ExUnit.Case, async: true

  @flag :chat_live_steering_enabled

  describe "the flag is off wherever it is not deliberately on" do
    test "it is off in the test environment" do
      # Also the reason every steering test drives transports explicitly rather
      # than through the flag: the suite proves behaviour on both paths, and
      # would keep passing if this were flipped, which is why the assertion has
      # to be made directly.
      refute Application.get_env(:buster_claw, @flag, false)
    end

    test "no config file outside dev turns it on" do
      offenders =
        "config/*.exs"
        |> Path.wildcard()
        |> Enum.reject(&(Path.basename(&1) == "dev.exs"))
        |> Enum.filter(fn path ->
          File.read!(path) =~ ~r/#{@flag}\s*,\s*true|#{@flag}:\s*true/
        end)

      assert offenders == [],
             """
             #{@flag} is enabled outside config/dev.exs: #{inspect(offenders)}

             Turning it on ships long-lived agent processes to users. If that is
             the intent, say so in LAUNCH_ROADMAP G-41 and update this test
             deliberately — do not just delete it.
             """
    end

    test "dev really does turn it on, so the dev default cannot rot silently" do
      # The inverse guard. If someone removes the dev flag, steering quietly
      # stops working locally and the next person debugs a feature that was
      # simply switched off.
      assert File.read!("config/dev.exs") =~ "#{@flag}, true"
    end
  end
end
