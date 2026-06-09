defmodule BusterClaw.Automation.Webhook do
  use Ecto.Schema

  import Ecto.Changeset

  @actions ~w(command)

  schema "webhooks" do
    field :name, :string
    field :secret, BusterClaw.Encrypted
    field :action, :string
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:name, :secret, :action, :enabled])
    |> validate_required([:name, :action])
    |> validate_inclusion(:action, @actions)
    |> unique_constraint(:name)
  end
end
