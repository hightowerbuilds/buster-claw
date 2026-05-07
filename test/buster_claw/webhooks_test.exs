defmodule BusterClaw.WebhooksTest do
  use BusterClaw.DataCase

  alias BusterClaw.{Webhooks, Workflow}

  test "authenticates configured webhook secret and records audit event" do
    assert {:ok, _webhook} =
             Webhooks.create_webhook(%{
               name: "ingest-now",
               action: "ingest",
               secret: "secret"
             })

    assert {:error, :unauthorized} = Webhooks.trigger("ingest-now", [], "{}")

    assert {:ok, %{action: "ingest"}} =
             Webhooks.trigger("ingest-now", [{"x-buster-claw-secret", "secret"}], "{}")

    assert Workflow.list_runtime_events() |> Enum.any?(&String.starts_with?(&1.kind, "webhook."))
  end
end
