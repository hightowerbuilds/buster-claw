defmodule BusterClaw.AutomationTest do
  use BusterClaw.DataCase

  alias BusterClaw.Automation

  test "manages automation configuration tables" do
    assert {:ok, mcp} =
             Automation.create_mcp_server(%{
               name: "filesystem",
               command: "npx",
               args: %{"items" => ["-y", "@modelcontextprotocol/server-filesystem"]},
               env: %{"HOME" => "/tmp"}
             })

    assert {:ok, webhook} =
             Automation.create_webhook(%{
               name: "daily",
               action: "full",
               secret: "secret"
             })

    assert {:ok, hook} =
             Automation.create_hook(%{
               name: "notify",
               event: "post_report",
               type: "webhook",
               target: "https://example.com/hook"
             })

    assert {:ok, destination} =
             Automation.create_delivery_destination(%{
               name: "slack",
               type: "slack",
               url: "https://hooks.slack.com/services/test"
             })

    assert {:ok, job} =
             Automation.create_scheduler_job(%{
               job_id: "morning",
               type: "ingest",
               cron: "0 8 * * *"
             })

    assert [^mcp] = Automation.list_mcp_servers()
    assert [^webhook] = Automation.list_webhooks()
    assert [^hook] = Automation.list_hooks()
    assert [^destination] = Automation.list_delivery_destinations()
    assert [^job] = Automation.list_scheduler_jobs()

    assert {:ok, hook} = Automation.update_hook(hook, %{enabled: false})
    refute hook.enabled

    assert {:ok, _} = Automation.delete_scheduler_job(job)
    assert [] = Automation.list_scheduler_jobs()
  end

  test "enforces uniqueness and action/type validations" do
    assert {:error, changeset} = Automation.create_webhook(%{name: "bad", action: "bad"})
    assert %{action: [_]} = errors_on(changeset)

    assert {:ok, _} =
             Automation.create_hook(%{
               name: "same",
               event: "post_ingest",
               type: "shell",
               target: "echo ok"
             })

    assert {:error, changeset} =
             Automation.create_hook(%{
               name: "same",
               event: "post_ingest",
               type: "shell",
               target: "echo ok"
             })

    assert %{name: [_]} = errors_on(changeset)
  end
end
