defmodule BusterClaw.TccUsageLockstepTest do
  @moduledoc """
  What the frontend captures and what `Info.plist` declares must agree.

  Under the hardened runtime a TCC usage string is not documentation. An app that
  calls `getUserMedia` with no `NSMicrophoneUsageDescription` is **terminated** by
  the OS — not shown a generic prompt — so the omission does not look like a
  missing string, it looks like the webview being unable to capture at all.

  That is not hypothetical. From 08-16 to 09-02-26 this plist listed the
  microphone under "deliberately absent" on the grounds that *"there is no
  getUserMedia anywhere in assets/js"*, while `voice_recorder.js` had been calling
  it twice since the day it shipped. The first person to press record would have
  banked the wrong conclusion about the webview.

  Nothing else can catch this. `check_docs_drift.sh` reads
  `README.md docs/*.md user-guide/*.md` and never opens a plist; the bun suite
  never reads XML; and no test had ever opened `Info.plist` before this one. It is
  the same "one fact in two places" guard the repo already puts on `phx-hook`
  names, the Notes command table and the Tauri ACL.

  Both directions are asserted on purpose. Capture without a string is a crash;
  a string without capture is a permission the app advertises and never exercises,
  which the plist's own header calls a small breach of the trust story.
  """
  use ExUnit.Case, async: true

  @plist "desktop/tauri/Info.plist"
  @js "assets/js"

  @mic "NSMicrophoneUsageDescription"

  test "if anything calls getUserMedia, the microphone usage string is declared" do
    callers = capture_callers()
    declared? = declares?(@mic)

    case {callers, declared?} do
      {[], false} ->
        :ok

      {[_ | _], true} ->
        :ok

      {[_ | _] = files, false} ->
        flunk("""
        #{@plist} does not declare #{@mic}, but these files call getUserMedia:

          #{Enum.join(files, "\n  ")}

        Under the hardened runtime that is a TERMINATION, not a prompt. The app
        will die the first time someone presses record, and it will look like the
        webview cannot capture rather than like a missing plist key.
        """)

      {[], true} ->
        flunk("""
        #{@plist} declares #{@mic}, but nothing under #{@js} calls getUserMedia.

        A usage string for a permission the app never exercises is a permission
        advertised to the OS and to the user for no reason — the plist's own
        header calls that a small breach of the trust story. Remove the key, or
        remove this test if capture is about to return.
        """)
    end
  end

  test "the plist parses, because a broken one fails at bundle time and not before" do
    assert {_, 0} = System.cmd("plutil", ["-lint", @plist], stderr_to_stdout: true)
  end

  defp capture_callers do
    Path.wildcard(Path.join(@js, "**/*.js"))
    |> Enum.filter(fn path ->
      path
      |> File.read!()
      |> strip_js_comments()
      |> String.contains?("getUserMedia")
    end)
    |> Enum.sort()
  end

  # A `<key>` inside an XML comment is prose, not a declaration — and the comments
  # in this plist discuss these keys by name at length, so matching the raw file
  # would report a key that had been deleted.
  defp declares?(key) do
    @plist
    |> File.read!()
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.contains?("<key>#{key}</key>")
  end

  # Same reason on the JS side: `voice_recorder.js` names the API in a comment
  # explaining what it probes for, which is not a call.
  defp strip_js_comments(source) do
    source
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> String.replace(~r{^\s*//.*$}m, "")
  end
end
