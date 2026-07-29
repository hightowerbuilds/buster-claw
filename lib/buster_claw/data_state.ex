defmodule BusterClaw.DataState do
  @moduledoc """
  Explicit availability state for data shown in the application.

  Financial UI must distinguish a fresh value, an old value, an in-flight
  request, a failed or never-attempted request, and a successful empty result.
  The payload and its governing timestamp travel with that state so templates
  cannot accidentally render an unqualified number or definitive empty copy.
  """

  @statuses [:loading, :fresh, :stale, :unavailable, :confirmed_empty]

  @enforce_keys [:status]
  defstruct [:status, :data, :as_of, :reason, :source]

  @type status :: :loading | :fresh | :stale | :unavailable | :confirmed_empty

  @type t :: %__MODULE__{
          status: status(),
          data: term(),
          as_of: Date.t() | DateTime.t() | nil,
          reason: term(),
          source: atom() | nil
        }

  def loading(data \\ nil, opts \\ []), do: build(:loading, data, opts)
  def fresh(data, opts \\ []), do: build(:fresh, data, opts)
  def stale(data, opts \\ []), do: build(:stale, data, opts)

  def unavailable(reason \\ nil, opts \\ []),
    do: build(:unavailable, Keyword.get(opts, :data), opts, reason)

  def confirmed_empty(opts \\ []), do: build(:confirmed_empty, [], opts)

  @doc "Build fresh/stale state from a cache age decision."
  def cached(data, stale?, opts \\ []) when is_boolean(stale?) do
    if stale?, do: stale(data, opts), else: fresh(data, opts)
  end

  defp build(status, data, opts, reason \\ nil) when status in @statuses do
    %__MODULE__{
      status: status,
      data: data,
      as_of: Keyword.get(opts, :as_of),
      reason: Keyword.get(opts, :reason, reason),
      source: Keyword.get(opts, :source)
    }
  end
end
