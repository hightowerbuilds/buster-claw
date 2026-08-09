defmodule BusterClaw.Clinch do
  @moduledoc """
  The Clinch — one door for every credential the app holds.

  A clinch is how you hold something so close nothing can swing at it. Worth
  being precise about what that can and cannot mean here, because overselling it
  is how a security boundary becomes decoration:

  **This is a chokepoint, not a sandbox.** In-VM isolation is a fiction — a
  GenServer holding plaintext does not stop anything else in the same BEAM from
  reaching `Repo` or the vaults directly. What one door buys is that audit,
  policy and redaction are *unavoidable* rather than *remembered*, and that
  Phase 4's re-key is one file's problem instead of every caller's.

  The walls that do hold are elsewhere, and each faces a different adversary:

  | Adversary | Wall |
  |---|---|
  | The agent — prompt-injectable, in-VM, with real command authority | **No command ever returns a value.** A model emits `$secret.<name>`; the executor resolves it at the moment of the fill. `Egress.SecretRef` has always done this correctly. |
  | The remote operator — holds an SSH key, may be a stolen laptop | Management is *unreachable*, not merely denied: Phase 2 puts it behind Tauri IPC, which a tunneled browser has no way to invoke and no token to fake. |
  | Someone with the disk — a backup, a stolen Mac, a copied `.db` | AES-256-GCM at rest via `Clinch.Vault`, keyed from `secret_key_base`, which lives in the Keychain and never on disk. |

  ## Two verbs, and the boundary between them

  Everything here is one of two things, and the split is the design:

  - **use** — `resolve/2`, `resolver/2`. Returns plaintext to an in-VM caller at
    the point of use. Audited. **Never reachable from a command, a controller, or
    a LiveView**, which is why there is no `browser_secret_get` and must never be
    one.
  - **manage** — `put/3`, `delete/1`, `list/0`, `known?/1`. Never returns a
    value, not even one just written. Phase 2 moves the write path behind the
    desktop shell so a remote session cannot reach it.

  A remote session may *use* credentials — agent runs, integration polls and
  Twilio sends should all keep working when you are away from the Mac — and may
  never *manage* them. A stolen key then buys a working Buster Claw, not the
  operator's Twilio account.

  ## What is behind the door today

  `:sign_in` is fully managed here. `:oauth` and `:service_key` are **listed
  read-only** from the stores that already own them (`google_accounts`,
  `integrations`) — the roadmap's call was that the chokepoint is the point, not
  the table, and moving Google's account structure into a generic credential
  table would be a lot of churn for no security gain. Phase 3 gives
  `:service_key` a writable home when the env-var credentials move in.

  One honest gap, deferred to Phase 3 with a reason: `Integrations` and
  `Google.Account` do not call `resolve/2` per field. Their secrets are typed
  `BusterClaw.Encrypted`, so decryption happens transparently at *Ecto load* —
  there is no resolve moment to hook until those rows move, and forcing one would
  mean un-typing the columns and rewriting every caller for no security gain
  today. Their crypto still passes through `Clinch.Vault`, which is the property
  the chokepoint test actually enforces.

  ## The audit

  `resolve/2` emits a `credential_use` Sentinel event carrying the kind, the
  name and the caller — **never the value**. This is observability the app has
  never had: until now nothing recorded that a credential was used at all.

  Deliberately not emitted from `Clinch.Vault`: that runs on every row load, and
  fifty rows would mean fifty audit writes. See that module.
  """

  import Ecto.Query

  alias BusterClaw.Clinch.Secret
  alias BusterClaw.Clinch.Types
  alias BusterClaw.Repo
  alias BusterClaw.Sentinel

  @type ref :: Types.ref()

  # ---- use -------------------------------------------------------------

  @doc """
  Resolve a credential to its plaintext. **The only read path there is.**

  Returns `:error` for absent, empty, unwritable-kind and undecryptable alike —
  a rotated key makes a secret *unknown*, which fails the resolve rather than
  typing garbage into a form.

  `opts` accepts `:caller` for the audit row. Pass the real caller where one is
  known; it is the difference between "a credential was used" and "who used it".
  """
  @spec resolve(ref(), keyword()) :: Types.resolution()
  def resolve(ref, opts \\ [])

  def resolve({:sign_in, name}, opts) when is_binary(name) do
    case Repo.get_by(Secret, name: normalize(name)) do
      %Secret{value: value} when is_binary(value) and value != "" ->
        audit_use(:sign_in, name, opts)
        {:ok, value}

      _absent_or_undecryptable ->
        :error
    end
  end

  def resolve(_ref, _opts), do: :error

  @doc """
  A resolver function for a kind: `fn name -> {:ok, value} | :error end`.

  Reads on demand rather than closing over a snapshot, so a credential removed
  mid-run stops resolving and nothing holds plaintext in process state for the
  life of a run. This is what `AgentMode` is handed at `agent_run_start`.
  """
  @spec resolver(Types.kind(), keyword()) :: (String.t() -> Types.resolution())
  def resolver(kind \\ :sign_in, opts \\ []) do
    fn name -> resolve({kind, name}, opts) end
  end

  # ---- manage ----------------------------------------------------------

  @doc """
  Store or replace a credential. Returns the ref and note — **never the value**,
  not even the one just written.
  """
  @spec put(ref(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :unmanaged_kind | :missing_name_or_value | map()}
  def put(ref, value, opts \\ [])

  def put({:sign_in, name}, value, opts)
      when is_binary(name) and is_binary(value) and value != "" do
    attrs = %{name: normalize(name), value: value, note: presence(opts[:note])}

    %Secret{}
    |> Secret.changeset(attrs)
    |> Repo.insert(on_conflict: {:replace, [:value, :note, :updated_at]}, conflict_target: :name)
    |> case do
      {:ok, secret} -> {:ok, shape(secret)}
      {:error, changeset} -> {:error, errors(changeset)}
    end
  end

  def put({kind, _name}, _value, _opts) when kind not in [:sign_in],
    do: {:error, :unmanaged_kind}

  def put(_ref, _value, _opts), do: {:error, :missing_name_or_value}

  @doc "Forget a credential. `{:error, :not_found}` rather than a silent success."
  @spec delete(ref()) :: {:ok, map()} | {:error, :not_found | :unmanaged_kind}
  def delete({:sign_in, name}) when is_binary(name) do
    case Repo.get_by(Secret, name: normalize(name)) do
      nil -> {:error, :not_found}
      %Secret{} = secret -> with {:ok, _} <- Repo.delete(secret), do: {:ok, shape(secret)}
    end
  end

  def delete({kind, _name}) when kind not in [:sign_in], do: {:error, :unmanaged_kind}
  def delete(_ref), do: {:error, :not_found}

  @doc """
  Every credential the app holds, as `t:BusterClaw.Clinch.Types.entry/0` —
  **names and metadata only, across every kind**.

  This is the model's whole view of the store and the Phase 3 screen's data
  source: enough to know what may be referenced, nothing that could be
  exfiltrated. There is no `:value` key and there must never be one.
  """
  @spec list() :: [Types.entry()]
  def list do
    Enum.flat_map(Types.kinds(), &list/1)
  end

  @doc "The entries of one kind. Unwritable kinds list what their own store holds."
  @spec list(Types.kind()) :: [Types.entry()]
  def list(:sign_in) do
    Secret
    |> select([s], %{name: s.name, note: s.note, updated_at: s.updated_at})
    |> order_by([s], asc: s.name)
    |> Repo.all()
    |> Enum.map(&Map.merge(&1, %{kind: :sign_in, managed?: true}))
  end

  def list(:oauth) do
    "google_accounts"
    |> select([a], %{name: a.email, updated_at: a.updated_at})
    |> order_by([a], asc: a.email)
    |> Repo.all()
    |> Enum.map(&Map.merge(&1, %{kind: :oauth, note: "Google account", managed?: false}))
  end

  def list(:service_key) do
    "integrations"
    |> where([i], not is_nil(i.token))
    |> select([i], %{name: i.name, note: i.service_type, updated_at: i.updated_at})
    |> order_by([i], asc: i.name)
    |> Repo.all()
    |> Enum.map(&Map.merge(&1, %{kind: :service_key, managed?: false}))
  end

  # The Keychain holds the loopback tokens and paired device keys do not exist
  # yet (Phase 6). Neither is readable from here, and listing a name the operator
  # cannot act on would be a promise the screen does not keep.
  def list(kind) when kind in [:loopback_token, :device_key], do: []

  @doc "True if the ref is stored. Used to explain an unknown reference."
  @spec known?(ref()) :: boolean()
  def known?(ref), do: match?({:ok, _}, resolve(ref, audit: false))

  # ---- internals -------------------------------------------------------

  # The kind and the name, never the value — and `Sentinel`'s own key-name
  # redaction is a second layer under that, not the thing being relied on.
  #
  # `audit: false` exists for `known?/1` alone: an existence check is not a use,
  # and recording one would make the feed claim a credential was consumed when
  # nothing read it.
  defp audit_use(kind, name, opts) do
    if Keyword.get(opts, :audit, true) do
      Sentinel.observe(
        :credential_use,
        "#{kind} credential \"#{normalize(name)}\" resolved",
        %{kind: kind, name: normalize(name)},
        caller: opts[:caller]
      )
    end

    :ok
  end

  defp shape(%Secret{} = secret), do: %{kind: :sign_in, name: secret.name, note: secret.note}

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
