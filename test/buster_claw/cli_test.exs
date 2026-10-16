defmodule BusterClaw.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias BusterClaw.CLI

  test "request timeout uses seconds from the CLI option" do
    assert CLI.request_timeout_ms(timeout: 120) == 120_000
    assert CLI.request_timeout_ms(timeout: 0) == 1_000
  end

  test "request timeout falls back to the caller default" do
    assert CLI.request_timeout_ms([], 300_000) == 300_000
  end

  test "help documents the timeout option" do
    output = capture_io(fn -> CLI.main(["help"]) end)

    assert output =~ "--timeout <seconds>"
    assert output =~ "Gmail sync default 300"
    assert output =~ "--verbose"
    assert output =~ "on-duty"
  end

  # Regression, 2026-08-02. The refused-connection clause matched
  # `{:failed_connect, _}` — httpc's shape, left behind when this client moved
  # to Req. So the CLI's most common failure by far, "the app isn't running",
  # rendered as `request failed: %Req.TransportError{reason: :econnrefused}`
  # instead of the one line that says what to do. The shape below was verified
  # against a real refused connection, not assumed.
  describe "connection_message/1" do
    test "a refused connection says what to do about it" do
      message = CLI.connection_message(%Req.TransportError{reason: :econnrefused})

      assert message =~ "could not connect to Buster Claw"
      assert message =~ "mix phx.server"
    end

    test "a timeout points at --timeout rather than at the server" do
      message = CLI.connection_message(%Req.TransportError{reason: :timeout})

      assert message =~ "timed out"
      assert message =~ "--timeout <seconds>"
    end

    test "anything else falls back without pretending to diagnose it" do
      assert CLI.connection_message(:boom) == "request failed: :boom"
    end
  end

  # Regression, 2026-08-02. `System.trap_signal(:sigint, ...)` raised on every
  # `on-duty` and the rescue swallowed it. The banner's own wording is tested
  # with the formatter (`cli/format_test.exs`); this is the half that keeps the
  # help text and the banner from drifting apart.
  describe "the on-duty banner and the help text agree about standing down" do
    test "help says the same thing, so the two cannot drift apart" do
      output = capture_io(fn -> CLI.main(["help"]) end)

      assert output =~ "Ctrl-C does not"
      refute output =~ "until Ctrl-C"
    end
  end
end
