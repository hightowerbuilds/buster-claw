defmodule BusterClaw.Automation.DeliveryDestination do
  use Ecto.Schema

  import Ecto.Changeset

  @types ~w(slack discord telegram email)

  schema "delivery_destinations" do
    field :name, :string
    field :type, :string
    field :url, :string
    field :token, BusterClaw.Encrypted
    field :chat_id, :string
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(destination, attrs) do
    destination
    |> cast(attrs, [:name, :type, :url, :token, :chat_id, :enabled])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @types)
    |> unique_constraint(:name)
  end
end
