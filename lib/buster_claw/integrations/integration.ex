defmodule BusterClaw.Integrations.Integration do
  @moduledoc """
  A configured service integration — GitHub is the only kind today. `token` and
  `webhook_secret` are encrypted at rest (`BusterClaw.Encrypted`).

  There is deliberately no polling-interval field: polling is on demand only (a
  human clicks Poll, or an agent runs `integration_poll`), so a stored interval
  was a setting that knowingly did nothing. It was removed 08-02 — see
  `BusterClaw.Integrations`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # Ecto does not generate this, and `Integrations.Service`'s three callbacks
  # have referenced `Integration.t()` since they were written — so until
  # 2026-08-02 those specs checked nothing at all, which Dialyzer reported as
  # `unknown_type` in a job configured not to block.
  @type t :: %__MODULE__{}

  # `sentry` and `umami` were both removed 08-14 (ideated, never essential).
  # A stored row with either service_type now fails this whitelist on its next
  # validated write and polls as {:unsupported_integration, type} — deliberately
  # visible rather than silently dropped, since nothing in the app ever seeded
  # one. This stays a list rather than becoming `== "github"`: it is the shape
  # that makes the next adapter one line.
  @service_types ~w(github)
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
    field :last_run_at, :utc_datetime
    field :last_status, :string, default: "never_run"
    field :last_error, :string

    timestamps(type: :utc_datetime)
  end

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
      :last_status
    ])
    |> validate_inclusion(:service_type, @service_types)
    |> validate_inclusion(:last_status, @statuses)
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
      {"github", value} when value in [nil, ""] ->
        put_change(changeset, :base_url, "https://api.github.com")

      _ ->
        changeset
    end
  end
end
