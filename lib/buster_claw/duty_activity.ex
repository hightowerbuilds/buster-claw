defmodule BusterClaw.DutyActivity do
  @moduledoc "Read-only activity from the existing records, scoped to the current shift."
  import Ecto.Query

  alias BusterClaw.Dispatch.Item
  alias BusterClaw.Repo
  alias BusterClaw.Sentinel.Event

  @limit 100

  def list(shift) do
    audit =
      Event
      |> since(shift.started_at, :inserted_at)
      |> Repo.all()
      |> Enum.map(&entry("audit", &1.id, &1.inserted_at, &1.category, &1.message))

    work =
      Item
      |> since(shift.started_at, :updated_at)
      |> Repo.all()
      |> Enum.map(
        &entry(
          "work",
          &1.id,
          &1.updated_at,
          "#{&1.source} · #{&1.status}",
          &1.subject || &1.request_summary || "Queued request"
        )
      )

    (audit ++ work)
    |> Enum.sort_by(&{DateTime.to_unix(&1.at), &1.id}, :desc)
    |> Enum.take(@limit)
  end

  defp since(query, started_at, timestamp) do
    query
    |> where([row], field(row, ^timestamp) >= ^started_at)
    |> order_by([row], desc: field(row, ^timestamp), desc: row.id)
    |> limit(@limit)
  end

  defp entry(source, id, at, label, message) do
    %{id: "#{source}-#{id}", at: at, label: label, message: message}
  end
end
