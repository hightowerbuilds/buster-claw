defmodule BusterClaw.BrowserControl.Secrets do
  @moduledoc """
  The store behind `$secret.<name>` — the half of the secret-reference design
  that was never built (BROWSER_CLOSEOUT Part II, item 3).

  `Egress.SecretRef` has always been pure, correct and tested: the model emits a
  reference, the executor swaps in the value at the moment of the `fill`, and
  the trajectory records the reference token rather than its expansion. But
  `AgentMode` defaulted `:secret_resolver` to `fn _ -> :error end` and
  `agent_run_start` never passed one, so **every reference failed** and no
  unattended run could touch a site requiring sign-in.

  ## Where the values live

  In the database, in a column typed `BusterClaw.Encrypted` — AES-256-GCM
  through `BusterClaw.Vault`, keyed from `secret_key_base`, which the Tauri
  shell stores in the **macOS Keychain** and injects at boot. So values are
  Keychain-protected transitively, through the one key the app already has,
  rather than through a second Keychain integration with its own Rust commands
  and ACL registration to keep in lockstep.

  `Encrypted` also fails closed: a blob framed as our ciphertext that will not
  decrypt (key rotation, tampering) loads as `nil` rather than handing back raw
  bytes as if they were the secret. A rotated key therefore makes a secret
  *unknown*, which fails the resolve — it never types garbage into a form.

  ## What can read a value

  Nothing outside `resolver/0`, which is handed to a run at start and consulted
  only inside the executor. **There is deliberately no command that returns a
  secret's value, and there must never be one** — the entire point of the
  reference design is that a model can drive a form it is constitutionally
  incapable of reading. `names/0` lists names so the model knows what it may
  reference; that is the whole of its visibility.
  """

  import Ecto.Query

  alias BusterClaw.BrowserControl.Secret
  alias BusterClaw.Repo

  @doc """
  A resolver for `AgentMode`: `fn name -> {:ok, value} | :error end`.

  Reads on demand rather than closing over a snapshot of values, so a secret
  removed mid-run stops resolving, and nothing holds plaintext in process state
  for the life of a run.
  """
  def resolver do
    fn name ->
      case fetch(name) do
        {:ok, value} -> {:ok, value}
        :error -> :error
      end
    end
  end

  @doc "Resolve one name to its plaintext. The only read path there is."
  def fetch(name) when is_binary(name) do
    case Repo.get_by(Secret, name: normalize(name)) do
      %Secret{value: value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  def fetch(_name), do: :error

  @doc "Store or replace a secret. Returns the name and note, never the value."
  def put(name, value, note \\ nil)

  def put(name, value, note) when is_binary(name) and is_binary(value) and value != "" do
    attrs = %{name: normalize(name), value: value, note: presence(note)}

    %Secret{}
    |> Secret.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:value, :note, :updated_at]},
      conflict_target: :name
    )
    |> case do
      {:ok, secret} -> {:ok, shape(secret)}
      {:error, changeset} -> {:error, errors(changeset)}
    end
  end

  def put(_name, _value, _note), do: {:error, :missing_name_or_value}

  @doc "Forget a secret. `{:error, :not_found}` rather than a silent success."
  def delete(name) when is_binary(name) do
    case Repo.get_by(Secret, name: normalize(name)) do
      nil -> {:error, :not_found}
      %Secret{} = secret -> with {:ok, _} <- Repo.delete(secret), do: {:ok, shape(secret)}
    end
  end

  def delete(_name), do: {:error, :not_found}

  @doc """
  Every stored name, with its note and timestamps — and **no values**. This is
  the model's whole view of the store: enough to know what it may reference,
  nothing it could exfiltrate.
  """
  def names do
    Secret
    |> select([s], %{name: s.name, note: s.note, updated_at: s.updated_at})
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  @doc "True if the name is stored. Used to explain an unknown reference."
  def known?(name) when is_binary(name), do: fetch(name) != :error
  def known?(_name), do: false

  defp shape(%Secret{} = secret), do: %{name: secret.name, note: secret.note}

  defp normalize(name), do: name |> to_string() |> String.trim() |> String.downcase()

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
