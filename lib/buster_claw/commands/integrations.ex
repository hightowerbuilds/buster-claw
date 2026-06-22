defmodule BusterClaw.Commands.Integrations do
  @moduledoc "Integration commands beyond the generated CRUD: polling and run history. Delegated to from `BusterClaw.Commands`."

  import BusterClaw.Commands.Helpers

  alias BusterClaw.Integrations

  def integration_poll(%{"id" => id}) do
    case Integrations.poll_integration(id, []) do
      {:ok, run} -> {:ok, run}
      {:error, _} = err -> err
    end
  end

  def integration_poll_all(_args \\ %{}), do: {:ok, Integrations.poll_all([])}

  def integration_run_list(args) do
    case Map.get(args, "integration_id") do
      nil ->
        {:ok, Integrations.list_runs()}

      id ->
        with_resource(Integrations, :get_integration!, id, fn integration ->
          {:ok, Integrations.list_runs_for_integration(integration)}
        end)
    end
  end
end
