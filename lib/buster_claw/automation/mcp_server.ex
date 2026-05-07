defmodule BusterClaw.Automation.MCPServer do
  use Ecto.Schema

  import Ecto.Changeset

  schema "mcp_servers" do
    field :name, :string
    field :command, :string
    field :args, :map, default: %{}
    field :env, :map, default: %{}
    field :enabled, :boolean, default: true
    field :last_status, :string
    field :last_error, :string
    field :last_connected_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(server, attrs) do
    server
    |> cast(attrs, [
      :name,
      :command,
      :args,
      :env,
      :enabled,
      :last_status,
      :last_error,
      :last_connected_at
    ])
    |> validate_required([:name, :command])
    |> unique_constraint(:name)
  end
end
