defmodule BusterClaw.Clinch.Types do
  @moduledoc """
  The Clinch's vocabulary: what a credential *is*, how it is referred to, and
  what a listing entry looks like. **No logic** — every function here returns a
  literal.

  This module exists before the context does, on purpose. It is the same lesson
  Scene3D taught: pin the boundary as a real module first, so that everything
  built against it agrees on the shape without having to agree on an
  implementation. `Clinch`, its storage, the Phase 2 Tauri gate and the Phase 3
  screen all speak this and nothing else.

  ## The reference grammar

  A credential is addressed by a `{kind, name}` tuple, never by a bare string.
  The kind is not decoration — it decides *where the value lives* and *who may
  manage it*, and it is what lets one door serve stores that will never share a
  table (see `Clinch`).

  ## The kinds

  | Kind | What it is | Backing store today |
  |---|---|---|
  | `:sign_in` | a value an Agent Mode run types into a form as `$secret.<name>` | `browser_secrets`, managed by `Clinch` |
  | `:service_key` | an API key for a third-party service (Twilio, Supabase, Finnhub) | **nowhere** — env vars until Phase 3; integration rows are listed read-only |
  | `:oauth` | a Google account's client secret / refresh / access tokens | `google_accounts`, listed read-only |
  | `:loopback_token` | the api/mcp/agent token family | the macOS Keychain, via the shell |
  | `:device_key` | a paired remote device's public SSH key | **nowhere** — Phase 6 |

  Three of those have no writable home yet. They are named here anyway because
  the enum is the contract: a kind that appears later should not change the
  shape of everything written against it in the meantime.
  """

  @kinds ~w(service_key app_key oauth sign_in loopback_token device_key)a

  # Byte-identical to the grammar `BrowserControl.Secret` has always enforced,
  # and to what `Egress.SecretRef` will actually match. A name outside it could
  # be stored and then never resolvable, which is a trap rather than a feature.
  #
  # Listing-only kinds are NOT subject to it — a `:oauth` name is an email
  # address, which contains `@` and would fail. Only the kinds `Clinch` can
  # write are validated, which today means `:sign_in`.
  @name_format ~r/\A[a-z0-9_.-]+\z/
  @max_name_length 100
  @max_note_length 200

  @typedoc "What a credential is, which decides where it lives and who may manage it."
  @type kind :: :service_key | :app_key | :oauth | :sign_in | :loopback_token | :device_key

  @typedoc "A credential's name within its kind. Unique per kind, never globally."
  @type name :: String.t()

  @typedoc "How a credential is addressed. Never a bare string."
  @type ref :: {kind(), name()}

  @typedoc """
  One row of `Clinch.list/0` — everything the UI and the model are allowed to
  know. There is deliberately no `:value` key, and there must never be one.

  `managed?` is false for a kind whose values live in a store `Clinch` can read
  but not write yet; the Phase 3 screen renders those as present-but-elsewhere
  rather than pretending they can be edited.
  """
  @type entry :: %{
          kind: kind(),
          name: name(),
          note: String.t() | nil,
          updated_at: DateTime.t() | nil,
          managed?: boolean()
        }

  @typedoc "What a use-verb returns. `:error` covers absent, empty, and undecryptable alike."
  @type resolution :: {:ok, String.t()} | :error

  @doc "Every credential kind, in declaration order."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The kinds `Clinch` can write. Everything else is listed read-only.

  `:app_key` joined `:sign_in` in Phase 3, when Twilio, the Supabase service role
  and Finnhub moved out of `runtime.exs` into the Clinch's own encrypted store.

  ## Why `:app_key` is not just `:service_key`

  Both are "a key for an external service", and the first attempt did put them in
  one kind. That was wrong, and `Clinch`'s own test said so: it forced
  `list/1` to restate `managed?` as a per-entry literal, which is exactly the
  coincidence-not-derivation bug that test exists to prevent.

  The distinction is the one this module already draws — a kind decides **where it
  lives and who may manage it**. An `:app_key` lives in the Clinch and the Clinch
  can rotate it. A `:service_key` is a row in `integrations`, owned and managed by
  the Integrations screen; deleting it from here would leave the integration
  behind with no token. Different store, different manager, different kind.
  """
  @spec managed_kinds() :: [kind()]
  def managed_kinds, do: [:sign_in, :app_key]

  @doc "The name grammar enforced on writable kinds."
  @spec name_format() :: Regex.t()
  def name_format, do: @name_format

  @doc "Maximum stored name length."
  @spec max_name_length() :: pos_integer()
  def max_name_length, do: @max_name_length

  @doc "Maximum stored note length."
  @spec max_note_length() :: pos_integer()
  def max_note_length, do: @max_note_length
end
