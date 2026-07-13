defmodule BusterClaw.Integrations.Integration do
  @moduledoc """
  A configured GitHub / Sentry / Umami integration. `token` and `webhook_secret`
  are encrypted at rest (`BusterClaw.Encrypted`).

  Note `polling_interval_minutes`: it is persisted and validated, but **inert** —
  no scheduler reads it, because there is no integration poller. Polls happen only
  when a human clicks Poll or an agent runs `integration_poll`. See
  `BusterClaw.Integrations`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @service_types ~w(sentry github umami)
  @statuses ~w(never_run ok error disabled)

  schema "integrations" do
    field :name, :string
    field :service_type, :string
    field :base_url, :string
    field :token, BusterClaw.Encrypted
    field :webhook_secret, BusterClaw.Encrypted
    field :config, :map, default: %{}
    field :config_text, :string, virtual: true
    field :enabled, :boolean, default: true
    field :polling_interval_minutes, :integer, default: 60
    field :last_run_at, :utc_datetime
    field :last_status, :string, default: "never_run"
    field :last_error, :string

    timestamps(type: :utc_datetime)
  end

  def service_types, do: @service_types
  def statuses, do: @statuses

  def changeset(integration, attrs) do
    integration
    |> cast(attrs, [
      :name,
      :service_type,
      :base_url,
      :token,
      :webhook_secret,
      :config,
      :config_text,
      :enabled,
      :polling_interval_minutes,
      :last_run_at,
      :last_status,
      :last_error
    ])
    |> parse_config_text()
    |> apply_default_base_url()
    |> validate_required([
      :name,
      :service_type,
      :enabled,
      :polling_interval_minutes,
      :last_status
    ])
    |> validate_inclusion(:service_type, @service_types)
    |> validate_inclusion(:last_status, @statuses)
    |> validate_number(:polling_interval_minutes, greater_than: 0)
    |> unique_constraint(:name)
  end

  defp parse_config_text(changeset) do
    case get_change(changeset, :config_text) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :config, %{})

      value ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) ->
            put_change(changeset, :config, decoded)

          {:ok, _decoded} ->
            add_error(changeset, :config_text, "must decode to a JSON object")

          {:error, _reason} ->
            add_error(changeset, :config_text, "must be valid JSON")
        end
    end
  end

  defp apply_default_base_url(changeset) do
    case {get_field(changeset, :service_type), get_field(changeset, :base_url)} do
      {"sentry", value} when value in [nil, ""] ->
        put_change(changeset, :base_url, "https://sentry.io/api/0")

      {"github", value} when value in [nil, ""] ->
        put_change(changeset, :base_url, "https://api.github.com")

      _ ->
        changeset
    end
  end
end
