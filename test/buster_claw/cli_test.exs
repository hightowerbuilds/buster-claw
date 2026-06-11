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

  test "format_dispatch_list renders a compact list and handles empty" do
    assert CLI.format_dispatch_list([]) =~ "No open Dispatch items."

    out =
      CLI.format_dispatch_list([
        %{
          "id" => 1,
          "status" => "queued",
          "subject" => "Reset password",
          "sender" => "alice@example.com",
          "recommended_role_key" => "mail-triage"
        }
      ])

    assert out =~ "1 Dispatch item:"
    assert out =~ "#1 [queued] Reset password"
    assert out =~ "alice@example.com"
    assert out =~ "mail-triage"
  end

  test "format_dispatch_claim shows the claimed item or empty" do
    assert CLI.format_dispatch_claim(%{"empty" => true}) =~ "Queue empty"

    out = CLI.format_dispatch_claim(%{"id" => 5, "status" => "claimed", "subject" => "Invoice"})
    assert out =~ "Claimed:"
    assert out =~ "#5 [claimed] Invoice"
  end

  test "format_dispatch_finish confirms the new status" do
    assert CLI.format_dispatch_finish(%{"id" => 9, "status" => "done"}) == "Marked #9 done."
  end

  test "format_job_list renders the roster and handles empty" do
    assert CLI.format_job_list([]) =~ "No jobs defined"

    out =
      CLI.format_job_list([
        %{"key" => "mail-triage", "name" => "Mail Triage", "summary" => "Triage email."}
      ])

    assert out =~ "1 job:"
    assert out =~ "mail-triage — Mail Triage"
    assert out =~ "Triage email."
  end

  test "format_job renders header, summary, and body" do
    out =
      CLI.format_job(%{
        "key" => "mail-triage",
        "name" => "Mail Triage",
        "summary" => "Triage email.",
        "body" => "# Mail Triage\n\nDo the thing."
      })

    assert out =~ "Mail Triage (mail-triage)"
    assert out =~ "Do the thing."
  end
end
