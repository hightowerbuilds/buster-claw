defmodule BusterClaw.Commands.Journal do
  @moduledoc "Journal commands (the Notes record). Delegated to from `BusterClaw.Commands`."

  alias BusterClaw.Journal

  def journal_append(%{"text" => text}), do: Journal.append(text, :agent)
  def journal_append(_args), do: {:error, :missing_text}

  @doc """
  Read a day's Notes record. Defaults to today; a day with no document yet reads as
  an empty body (so the agent's first look on a fresh day isn't an error).
  """
  def journal_read(args \\ %{}) do
    name = Map.get(args, "date") || Journal.today_name()

    case {Journal.get(name), Date.from_iso8601(name)} do
      {nil, {:ok, date}} -> {:ok, %{name: Date.to_iso8601(date), body: ""}}
      {nil, _} -> {:error, :invalid_date}
      {day, _} -> {:ok, %{name: day.name, body: day.body}}
    end
  end
end
