defmodule BusterClawWeb.Status.ChatSystemPromptTest do
  # The home chat's system-prompt addendum identifies the app and describes
  # capabilities that need guidance beyond the generated command catalog.
  use ExUnit.Case, async: true

  alias BusterClaw.Introduction
  alias BusterClaw.SvgViewer
  alias BusterClawWeb.Status.Chat

  test "opens with the pointer and keeps drawing and app-tab guidance" do
    prompt = Chat.system_prompt()

    assert String.starts_with?(prompt, Introduction.pointer())
    assert prompt =~ SvgViewer.guide()
    assert prompt =~ "app_tabs_join"
    assert prompt =~ "app_tabs_separate"
  end

  test "does not advertise removed voice generation" do
    prompt = Chat.system_prompt()

    for removed <- ~w(VoxCPM Vox2B voice_clip_ voice_message_) do
      refute prompt =~ removed
    end
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
