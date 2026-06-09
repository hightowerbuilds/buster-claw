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
    assert output =~ "mailman default 300"
    assert output =~ "--verbose"
  end

  test "formats Mailman poll results for terminal reading" do
    output =
      CLI.format_mailman_result(%{
        "account" => %{"email" => "person@example.com"},
        "documents" => [
          %{
            "name" => "Important update",
            "date" => "2026-06-09",
            "artifact_path" => "raw/2026-06-09/gmail-1.md"
          }
        ],
        "errors" => [],
        "last_synced_at" => "2026-06-09T00:42:01Z",
        "query" => "newer_than:7d",
        "requested" => 1,
        "result_size_estimate" => 201,
        "synced" => 1
      })

    assert output =~ "Synced 1 Gmail message (requested 1) for person@example.com."
    assert output =~ "Query: newer_than:7d"
    assert output =~ "Mailbox matches: 201"
    assert output =~ "Documents:"
    assert output =~ "  - Important update (2026-06-09)"
    assert output =~ "    raw/2026-06-09/gmail-1.md"
    refute output =~ "{"
    refute output =~ "\"documents\""
  end

  test "formats empty Mailman poll results compactly" do
    output =
      CLI.format_mailman_result(%{
        "account" => %{"email" => "person@example.com"},
        "documents" => [],
        "errors" => [],
        "query" => "newer_than:7d",
        "synced" => 0
      })

    assert output =~ "No new Gmail messages synced for person@example.com."
    assert output =~ "Documents: none"
  end
end
