defmodule BusterClawWeb.Status.ChatSystemPromptTest do
  # The home chat's system-prompt addendum. Until 09-13 it was the drawing and
  # voice-clip guides alone, and nothing asserted on it — so the assistant in the
  # app's front door had never been told which app it was in, and no test could
  # have said so. THREE_DOORS Phase 1.
  use ExUnit.Case, async: true

  alias BusterClaw.Introduction
  alias BusterClaw.SvgViewer
  alias BusterClaw.Voice.Clips
  alias BusterClawWeb.Status.Chat

  test "opens with the pointer, then keeps both channel guides" do
    prompt = Chat.system_prompt()

    assert String.starts_with?(prompt, Introduction.pointer())
    assert prompt =~ SvgViewer.guide()
    assert prompt =~ Clips.guide()
  end

  test "stays small, because the shipped transports re-send it every turn" do
    # ~17k tokens of introduction was the tempting fix and the wrong one. The
    # cap is generous; it exists so the number is a decision, not an accident.
    assert length(String.split(Chat.system_prompt())) < 450
  end

  test "does not inline the full introduction" do
    refute Chat.system_prompt() =~ "Operating Guide"
    refute Chat.system_prompt() =~ "Safe (agent-callable)"
  end
end
