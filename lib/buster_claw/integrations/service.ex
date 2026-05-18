defmodule BusterClaw.Integrations.Service do
  @moduledoc "Behaviour for operational data integrations."

  alias BusterClaw.Integrations.Integration

  @type snapshot_item :: %{
          required(:date) => Date.t(),
          required(:filename) => String.t(),
          required(:source_url) => String.t(),
          required(:name) => String.t(),
          required(:tags) => [String.t()],
          required(:content) => String.t(),
          required(:fetched_at) => DateTime.t()
        }

  @callback fetch(Integration.t(), keyword()) :: {:ok, [snapshot_item()]} | {:error, term()}
  @callback verify_webhook(Integration.t(), [{String.t(), String.t()}], binary()) ::
              :ok | {:error, term()}
  @callback normalize_webhook(Integration.t(), binary()) ::
              {:ok, [snapshot_item()]} | {:error, term()}
end
