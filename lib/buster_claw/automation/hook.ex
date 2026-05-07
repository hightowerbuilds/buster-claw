defmodule BusterClaw.Automation.Hook do
  use Ecto.Schema

  import Ecto.Changeset

  @events ~w(pre_ingest post_ingest pre_analysis post_analysis pre_report post_report on_error)
  @types ~w(shell webhook)

  schema "hooks" do
    field :name, :string
    field :event, :string
    field :type, :string
    field :target, :string
    field :async, :boolean, default: true
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(hook, attrs) do
    hook
    |> cast(attrs, [:name, :event, :type, :target, :async, :enabled])
    |> validate_required([:name, :event, :type, :target])
    |> validate_inclusion(:event, @events)
    |> validate_inclusion(:type, @types)
    |> unique_constraint([:name, :event])
  end
end
