defmodule BusterClaw.BrowserControl.Secrets do
  @moduledoc """
  The `$secret.<name>` store, as Agent Mode sees it — a thin adapter over
  `BusterClaw.Clinch`'s `:sign_in` kind.

  It used to own the storage. Clinch Phase 1 moved that behind one door so every
  credential in the app shares an audit trail, a re-key path and a single place
  where the vaults are touched. Nothing about the browser's contract changed:
  `resolver/0` still returns the same `fn name -> {:ok, value} | :error end` that
  `agent_run_start` hands the executor, and `names/0` still lists names without
  values.

  This module survives rather than being deleted at every call site because the
  browser's vocabulary is `$secret.<name>` — a bare name, no kind — and
  translating that into a Clinch ref is exactly what an adapter is for.

  ## The rule that has not changed

  **Nothing outside `resolver/0` can read a value, and there is deliberately no
  command that returns one.** That is the whole point of the reference design: a
  model can drive a form it is constitutionally incapable of reading. `names/0`
  lists names so the model knows what it may reference; that is the whole of its
  visibility.
  """

  alias BusterClaw.Clinch

  @kind :sign_in

  @doc """
  A resolver for `AgentMode`: `fn name -> {:ok, value} | :error end`.

  Reads on demand rather than closing over a snapshot of values, so a secret
  removed mid-run stops resolving, and nothing holds plaintext in process state
  for the life of a run.
  """
  def resolver(opts \\ []), do: Clinch.resolver(@kind, opts)

  @doc "Resolve one name to its plaintext. The only read path there is."
  def fetch(name, opts \\ [])
  def fetch(name, opts) when is_binary(name), do: Clinch.resolve({@kind, name}, opts)
  def fetch(_name, _opts), do: :error

  @doc "Store or replace a secret. Returns the name and note, never the value."
  def put(name, value, note \\ nil)

  def put(name, value, note) when is_binary(name) and is_binary(value) and value != "" do
    case Clinch.put({@kind, name}, value, note: note) do
      {:ok, entry} -> {:ok, Map.take(entry, [:name, :note])}
      {:error, reason} -> {:error, reason}
    end
  end

  def put(_name, _value, _note), do: {:error, :missing_name_or_value}

  @doc "Forget a secret. `{:error, :not_found}` rather than a silent success."
  def delete(name) when is_binary(name) do
    case Clinch.delete({@kind, name}) do
      {:ok, entry} -> {:ok, Map.take(entry, [:name, :note])}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete(_name), do: {:error, :not_found}

  @doc """
  Every stored name, with its note and timestamps — and **no values**. This is
  the model's whole view of the store: enough to know what it may reference,
  nothing it could exfiltrate.
  """
  def names do
    @kind
    |> Clinch.list()
    |> Enum.map(&Map.take(&1, [:name, :note, :updated_at]))
  end

  @doc "True if the name is stored. Used to explain an unknown reference."
  def known?(name) when is_binary(name), do: Clinch.known?({@kind, name})
  def known?(_name), do: false
end
