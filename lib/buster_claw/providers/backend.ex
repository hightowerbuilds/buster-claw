defmodule BusterClaw.Providers.Backend do
  @moduledoc "Provider behavior for model chat backends."

  alias BusterClaw.Providers.Provider, as: ProviderConfig

  @type message :: %{role: String.t(), content: String.t()}
  @type on_chunk :: (String.t() -> any())

  @callback chat(ProviderConfig.t(), [message()], on_chunk()) :: :ok | {:error, term()}
  @callback test_connection(ProviderConfig.t()) :: {:ok, String.t()} | {:error, term()}
end
