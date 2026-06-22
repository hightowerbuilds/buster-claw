defmodule BusterClaw.Commands.Jobs do
  @moduledoc "Job-roster (role descriptions) commands. Delegated to from `BusterClaw.Commands`."

  alias BusterClaw.Jobs

  def job_list(_args \\ %{}), do: {:ok, Jobs.list()}

  def job_show(%{"key" => key}) do
    case Jobs.get(key) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end
end
