defmodule BusterClaw.Automation do
  @moduledoc "Automation configuration for MCP, webhooks, hooks, delivery, and scheduler jobs."

  alias BusterClaw.Automation.{DeliveryDestination, Hook, MCPServer, SchedulerJob, Webhook}
  alias BusterClaw.Repo

  for {schema, plural, singular} <- [
        {MCPServer, :mcp_servers, :mcp_server},
        {Webhook, :webhooks, :webhook},
        {Hook, :hooks, :hook},
        {DeliveryDestination, :delivery_destinations, :delivery_destination},
        {SchedulerJob, :scheduler_jobs, :scheduler_job}
      ] do
    def unquote(:"list_#{plural}")(), do: Repo.all(unquote(schema))
    def unquote(:"get_#{singular}!")(id), do: Repo.get!(unquote(schema), id)

    def unquote(:"create_#{singular}")(attrs),
      do: unquote(schema).changeset(struct(unquote(schema)), attrs) |> Repo.insert()

    def unquote(:"update_#{singular}")(record, attrs),
      do: unquote(schema).changeset(record, attrs) |> Repo.update()

    def unquote(:"delete_#{singular}")(record), do: Repo.delete(record)
  end
end
