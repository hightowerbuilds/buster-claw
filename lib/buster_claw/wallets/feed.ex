defmodule BusterClaw.Wallets.Feed do
  use Ecto.Schema

  import Ecto.Changeset

  alias BusterClaw.Wallets.Wallet

  # market   — poll a ticker's live price (Finance/Finnhub)
  # url      — poll a website and detect content change (SSRF-guarded fetch)
  # integration — mirror a configured integration's latest run
  # gmail    — react to inbound Gmail receipts (event-driven, not timer-polled)
  @kinds ~w(market url integration gmail)
  @statuses ~w(never_run ok error)

  # kinds worked by the periodic poller (gmail is event-driven instead)
  @polled_kinds ~w(market url integration)

  schema "wallet_feeds" do
    field :kind, :string
    field :enabled, :boolean, default: true
    field :polling_interval_minutes, :integer, default: 60
    field :config, :map, default: %{}
    field :config_text, :string, virtual: true
    field :last_run_at, :utc_datetime
    field :last_status, :string, default: "never_run"
    field :last_error, :string
    field :last_value, :string
    field :last_content_hash, :string

    belongs_to :wallet, Wallet

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def polled_kinds, do: @polled_kinds
  def statuses, do: @statuses

  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :wallet_id,
      :kind,
      :enabled,
      :polling_interval_minutes,
      :config,
      :config_text,
      :last_run_at,
      :last_status,
      :last_error,
      :last_value,
      :last_content_hash
    ])
    |> parse_config_text()
    |> validate_required([:wallet_id, :kind, :enabled, :polling_interval_minutes, :last_status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:last_status, @statuses)
    |> validate_number(:polling_interval_minutes, greater_than: 0)
    |> validate_config()
    |> assoc_constraint(:wallet)
  end

  defp parse_config_text(changeset) do
    case get_change(changeset, :config_text) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :config, %{})

      value ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> put_change(changeset, :config, decoded)
          {:ok, _} -> add_error(changeset, :config_text, "must decode to a JSON object")
          {:error, _} -> add_error(changeset, :config_text, "must be valid JSON")
        end
    end
  end

  # Each kind needs its own config key (gmail needs none).
  defp validate_config(changeset) do
    kind = get_field(changeset, :kind)
    config = get_field(changeset, :config) || %{}

    case kind do
      "market" -> require_config_key(changeset, config, "symbol")
      "url" -> require_config_key(changeset, config, "url")
      "integration" -> require_config_key(changeset, config, "integration_id")
      _ -> changeset
    end
  end

  defp require_config_key(changeset, config, key) do
    case Map.get(config, key) do
      value when value in [nil, ""] ->
        add_error(changeset, :config, "must include #{inspect(key)} for this feed kind")

      _ ->
        changeset
    end
  end
end
