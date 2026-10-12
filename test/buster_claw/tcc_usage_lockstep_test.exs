defmodule BusterClaw.TccUsageLockstepTest do
  @moduledoc """
  Retained capture paths and the desktop microphone usage string must agree.

  The reference recorder is gone, but `sound_record` still invokes ffmpeg's
  microphone capture. TCC may attribute that request up the process chain to
  the desktop app. The embedded browser can also host pages requesting media.
  A scan limited to our JavaScript would miss these paths.

  This guards declarations, not consent or successful capture on a real Mac.
  """
  use ExUnit.Case, async: true

  @plist "desktop/tauri/Info.plist"
  @js "assets/js"

  @mic "NSMicrophoneUsageDescription"

  test "retained audio capture has a microphone usage string" do
    callers = capture_callers()
    declared? = declares?(@mic)

    case {callers, declared?} do
      {[], false} ->
        :ok

      {[_ | _], true} ->
        :ok

      {[_ | _] = files, false} ->
        flunk("""
        #{@plist} does not declare #{@mic}, but these capture paths remain:

          #{Enum.join(files, "\n  ")}

        Under the hardened runtime that is a TERMINATION, not a prompt. The app
        will die the first time someone presses record, and it will look like the
        webview cannot capture rather than like a missing plist key.
        """)

      {[], true} ->
        flunk("""
        #{@plist} declares #{@mic}, but no application capture path remains.

        A usage string for a permission the app never exercises is a permission
        advertised to the OS and to the user for no reason — the plist's own
        header calls that a small breach of the trust story. Audit browser media access before removing the key.
        """)
    end
  end

  # `plutil` is macOS-only. The plist it lints is macOS-only too, so there is
  # nothing for a Linux runner to check here.
  @tag :macos
  test "the plist parses, because a broken one fails at bundle time and not before" do
    assert {_, 0} = System.cmd("plutil", ["-lint", @plist], stderr_to_stdout: true)
  end

  defp capture_callers do
    javascript =
      Path.wildcard(Path.join(@js, "**/*.js"))
      |> Enum.reject(&String.ends_with?(&1, ".test.js"))
      |> Enum.filter(fn path ->
        path |> File.read!() |> strip_js_comments() |> String.contains?("getUserMedia")
      end)

    native =
      BusterClaw.Commands.Catalog.entries()
      |> Enum.filter(&(&1.name == "sound_record"))
      |> Enum.map(& &1.name)

    Enum.sort(javascript ++ native)
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

  # Mentioning the capture API in a comment does not establish a caller.
  defp strip_js_comments(source) do
    source
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> String.replace(~r{^\s*//.*$}m, "")
  end
end
