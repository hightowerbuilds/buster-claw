defmodule BusterClaw.BrowserHistory.Entry do
  @moduledoc """
  One recorded browser navigation — an `(url, title, visited_at)` row. Every
  visit is its own row (no dedupe, no cap), so revisit frequency is preserved and
  can be counted/searched. The native chrome toolbar posts one of these per
  navigation; workspace files opened via the address bar are recorded too.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "browser_history_entries" do
    field :url, :string
    field :title, :string
    field :visited_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:url, :title, :visited_at])
    |> validate_required([:url, :title, :visited_at])
  end
end
