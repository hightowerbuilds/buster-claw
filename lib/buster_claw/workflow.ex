defmodule BusterClaw.Workflow do
  @moduledoc "Durable workflow state for jobs, attempts, hook runs, and audit events."

  alias BusterClaw.Repo
  alias BusterClaw.Workflow.{DeliveryAttempt, HookRun, RuntimeEvent}

  for {schema, plural, singular} <- [
        {DeliveryAttempt, :delivery_attempts, :delivery_attempt},
        {HookRun, :hook_runs, :hook_run},
        {RuntimeEvent, :runtime_events, :runtime_event}
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
