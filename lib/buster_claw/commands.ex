defmodule BusterClaw.Commands do
  @moduledoc """
  Canonical command surface for Buster Claw.

  Every external surface (HTTP API, MCP server, CLI escript) dispatches through
  this module. See
  `docs/COMMAND_SURFACE.md` for a command-surface overview.

  ## Contract

  - All commands accept a single map argument (string keys preferred for wire
    parity; atom keys are normalized).
  - All commands return `{:ok, value}` or `{:error, reason_or_changeset}`.
  - Bang getters raise; their `Commands.*` wrappers translate to
    `{:error, :not_found}`.

  ## Dispatch

  - `list_commands/0` returns the catalog (used by MCP `tools/list` and CLI `--help`).
  - `call/2` dispatches by string command name (used by HTTP and MCP frontends).
  - Direct calls (`Commands.document_list(%{})`) work for internal callers.
  """

  alias BusterClaw.{
    Browser,
    Calendar,
    Dispatch,
    Finance,
    Google,
    Integrations,
    Jobs,
    Library,
    Orchestration,
    Search,
    TerminalWorkspace
  }

  alias BusterClaw.Runtime.Status

  # -----------------------------------------------------------------------
  # Catalog
  #
  # The catalog is pure/constant, so it is built exactly once (lazily, on first
  # use) and cached in :persistent_term — along with a name-index map and the
  # safe-tier subset. `by_name/0` gives O(1) lookups for `has_command?/1`,
  # `command_tier/1`, and `command_type/1` instead of re-scanning a freshly
  # rebuilt list on every call. (Local functions can't be invoked from a module
  # attribute during compilation, so this is memoized at runtime rather than
  # baked in at compile time.)
  # -----------------------------------------------------------------------

  @id_required %{"id" => %{type: :integer, required: true}}

  defp list_entry(name, desc),
    do: %{name: name, type: :read, tier: :safe, description: desc, args: %{}}

  defp get_entry(name, desc),
    do: %{name: name, type: :read, tier: :safe, description: desc, args: @id_required}

  # Deletes are irreversible, so they are `gated`: an autonomous run working
  # untrusted-origin content (`:agent_untrusted`) cannot fire them — they surface
  # for human approval instead. See `command_gated?/1` and `authorize/2`.
  defp delete_entry(name, desc),
    do: %{
      name: name,
      type: :mutate,
      tier: :restricted,
      gated: true,
      description: desc,
      args: @id_required
    }

  defp id_trigger_entry(name, desc, tier),
    do: %{name: name, type: :trigger, tier: tier, description: desc, args: @id_required}

  defp build_catalog,
    do: [
      # Documents
      list_entry("document_list", "List all indexed documents."),
      get_entry("document_get", "Fetch a document by ID."),
      get_entry("document_read", "Read the raw markdown contents of a document."),
      %{
        name: "document_save",
        type: :mutate,
        tier: :restricted,
        description: "Write a new raw document to the library and index it.",
        args: %{
          "name" => %{type: :string, required: true},
          "body" => %{type: :string, required: true},
          "source_url" => %{type: :string, required: false},
          "date" => %{type: :string, required: false, description: "ISO 8601 date"},
          "tags" => %{type: :map, required: false}
        }
      },
      delete_entry("document_delete", "Delete a document's file and mark it deleted."),

      # Events
      list_entry("event_list", "List all calendar events."),
      get_entry("event_get", "Fetch an event by ID."),
      %{
        name: "event_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a calendar event.",
        args: %{
          "event_id" => %{type: :string, required: true},
          "date" => %{type: :string, required: true, description: "ISO 8601 date"},
          "title" => %{type: :string, required: true},
          "notes" => %{type: :string, required: false}
        }
      },
      %{
        name: "event_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a calendar event.",
        args: %{
          "id" => %{type: :integer, required: true},
          "event_id" => %{type: :string, required: false},
          "date" => %{type: :string, required: false},
          "title" => %{type: :string, required: false},
          "notes" => %{type: :string, required: false}
        }
      },
      delete_entry("event_delete", "Delete a calendar event."),

      # Integrations
      list_entry("integration_list", "List service integrations."),
      get_entry("integration_get", "Fetch an integration by ID."),
      %{
        name: "integration_create",
        type: :mutate,
        tier: :restricted,
        description: "Create an integration.",
        args: %{
          "name" => %{type: :string, required: true},
          "service_type" => %{type: :string, required: true},
          "base_url" => %{type: :string, required: false},
          "token" => %{type: :string, required: false},
          "webhook_secret" => %{type: :string, required: false},
          "config" => %{type: :map, required: false},
          "enabled" => %{type: :boolean, required: false, default: true},
          "polling_interval_minutes" => %{type: :integer, required: false, default: 60}
        }
      },
      %{
        name: "integration_update",
        type: :mutate,
        tier: :restricted,
        description: "Update an integration.",
        args: %{
          "id" => %{type: :integer, required: true},
          "name" => %{type: :string, required: false},
          "service_type" => %{type: :string, required: false},
          "base_url" => %{type: :string, required: false},
          "token" => %{type: :string, required: false},
          "webhook_secret" => %{type: :string, required: false},
          "config" => %{type: :map, required: false},
          "enabled" => %{type: :boolean, required: false},
          "polling_interval_minutes" => %{type: :integer, required: false}
        }
      },
      delete_entry("integration_delete", "Delete an integration."),
      id_trigger_entry("integration_poll", "Poll a single integration.", :safe),
      list_entry("integration_poll_all", "Poll every enabled integration.")
      |> Map.put(:type, :trigger),
      %{
        name: "integration_run_list",
        type: :read,
        tier: :safe,
        description: "List integration run history.",
        args: %{
          "integration_id" => %{type: :integer, required: false}
        }
      },

      # Google Workspace accounts
      list_entry("google_account_list", "List configured Google Workspace accounts."),
      get_entry("google_account_get", "Fetch a Google Workspace account summary."),
      %{
        name: "google_account_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Google Workspace account credential shell.",
        args: %{
          "email" => %{type: :string, required: true},
          "client_id" => %{type: :string, required: true},
          "client_secret" => %{type: :string, required: false},
          "refresh_token" => %{type: :string, required: false},
          "access_token" => %{type: :string, required: false},
          "access_token_expires_at" => %{type: :string, required: false},
          "scopes" => %{type: :string, required: false},
          "default_query" => %{type: :string, required: false},
          "enabled" => %{type: :boolean, required: false, default: true}
        }
      },
      %{
        name: "google_account_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a Google Workspace account credential shell.",
        args: %{
          "id" => %{type: :integer, required: true},
          "email" => %{type: :string, required: false},
          "client_id" => %{type: :string, required: false},
          "client_secret" => %{type: :string, required: false},
          "refresh_token" => %{type: :string, required: false},
          "access_token" => %{type: :string, required: false},
          "access_token_expires_at" => %{type: :string, required: false},
          "scopes" => %{type: :string, required: false},
          "default_query" => %{type: :string, required: false},
          "enabled" => %{type: :boolean, required: false}
        }
      },
      delete_entry("google_account_delete", "Delete a Google Workspace account."),
      %{
        name: "gmail_label_list",
        type: :read,
        tier: :safe,
        description: "List Gmail labels for a connected Google Workspace account.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false}
        }
      },
      %{
        name: "gmail_search",
        type: :read,
        tier: :safe,
        description: "Search Gmail messages for a connected Google Workspace account.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "query" => %{type: :string, required: false},
          "limit" => %{type: :integer, required: false, default: 10},
          "incremental" => %{type: :boolean, required: false, default: false},
          "start_history_id" => %{type: :string, required: false}
        }
      },
      %{
        name: "gmail_read",
        type: :read,
        tier: :safe,
        description: "Read one Gmail message by message ID.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "message_id" => %{type: :string, required: true}
        }
      },
      %{
        name: "gmail_sync",
        type: :trigger,
        tier: :safe,
        description: "Sync Gmail search results or history deltas into Library raw documents.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "query" => %{type: :string, required: false},
          "limit" => %{type: :integer, required: false, default: 10},
          "incremental" => %{type: :boolean, required: false, default: false},
          "start_history_id" => %{type: :string, required: false}
        }
      },
      %{
        name: "gmail_draft_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Gmail draft for a connected Google Workspace account.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "to" => %{type: :string, required: false},
          "recipient" => %{type: :string, required: false, description: "Alias for to."},
          "cc" => %{type: :string, required: false},
          "bcc" => %{type: :string, required: false},
          "subject" => %{type: :string, required: true},
          "body" => %{type: :string, required: true}
        }
      },
      %{
        name: "gmail_send",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Send a Gmail message from a connected Google Workspace account.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "to" => %{type: :string, required: false},
          "recipient" => %{type: :string, required: false, description: "Alias for to."},
          "cc" => %{type: :string, required: false},
          "bcc" => %{type: :string, required: false},
          "subject" => %{type: :string, required: true},
          "body" => %{type: :string, required: true},
          "confirm_send" => %{type: :boolean, required: true, default: false}
        }
      },
      %{
        name: "google_calendar_sync",
        type: :trigger,
        tier: :safe,
        description: "One-way sync Google Calendar events into the app calendar.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "calendar_id" => %{type: :string, required: false, default: "primary"},
          "days_ahead" => %{type: :integer, required: false, default: 90},
          "force_full" => %{type: :boolean, required: false, default: false}
        }
      },

      # Search
      %{
        name: "web_search",
        type: :trigger,
        tier: :safe,
        description: "DuckDuckGo web search.",
        args: %{
          "query" => %{type: :string, required: true},
          "limit" => %{type: :integer, required: false, default: 10}
        }
      },

      # Browser
      %{
        name: "browser_fetch",
        type: :trigger,
        tier: :safe,
        description: "Fetch a URL and convert to markdown.",
        args: %{"url" => %{type: :string, required: true}}
      },

      # Finance (read-only research; every result carries source + as-of)
      %{
        name: "finance_filings",
        type: :read,
        tier: :safe,
        description: "Recent SEC EDGAR filings for a ticker (10-K/10-Q/8-K …), newest first.",
        args: %{"symbol" => %{type: :string, required: true}}
      },
      %{
        name: "finance_fundamentals",
        type: :read,
        tier: :safe,
        description: "Latest SEC XBRL fundamentals for a ticker (revenue, net income, assets …).",
        args: %{"symbol" => %{type: :string, required: true}}
      },
      %{
        name: "finance_quote",
        type: :read,
        tier: :safe,
        description: "Latest quote for a ticker (Finnhub; needs FINNHUB_API_KEY). Carries as-of.",
        args: %{"symbol" => %{type: :string, required: true}}
      },
      %{
        name: "finance_news",
        type: :read,
        tier: :safe,
        description: "Recent company news for a ticker (Finnhub; needs FINNHUB_API_KEY).",
        args: %{"symbol" => %{type: :string, required: true}}
      },

      # Runtime
      list_entry("runtime_status", "Snapshot of process and system state."),
      %{
        name: "activity_report",
        type: :read,
        tier: :safe,
        description:
          "Summary of work Buster Claw handled over a recent window: requests done/blocked/failed, currently open, and unattended runs.",
        args: %{"days" => %{type: :integer, required: false, default: 7}}
      },

      # Visible terminal workspace
      %{
        name: "terminal_tab_open",
        type: :trigger,
        tier: :safe,
        description: "Open a new visible in-app terminal tab for a role.",
        args: %{
          "role_key" => %{type: :string, required: true},
          "label" => %{type: :string, required: false},
          "agent_name" => %{type: :string, required: false},
          "purpose" => %{type: :string, required: false},
          "session_key" => %{type: :string, required: false},
          "startup_profile" => %{type: :string, required: false, enum: ["mailman"]},
          "activate" => %{type: :boolean, required: false, default: true}
        }
      },

      # Orchestration shift — agent-drivable so the on-shift model can start/stop it.
      list_entry("shift_status", "Whether an orchestration shift is active, plus counts."),
      %{
        name: "shift_start",
        type: :trigger,
        tier: :safe,
        description:
          "Start an orchestration shift (runs until stopped) with job/agent assignment metadata. Set `unattended` to let the Dispatcher work the queue with headless agent runs (no human in the terminal).",
        args: %{
          "job" => %{type: :string, required: false, default: "lookout"},
          "agent_name" => %{type: :string, required: false},
          "shell" => %{type: :string, required: false},
          "unattended" => %{
            type: :boolean,
            required: false,
            default: false,
            description: "Let the Dispatcher drive headless agent runs against the queue."
          }
        }
      },
      %{
        name: "shift_stop",
        type: :trigger,
        tier: :safe,
        description: "Stop the active orchestration shift.",
        args: %{"reason" => %{type: :string, required: false}}
      },
      %{
        name: "shift_assignment_start",
        type: :trigger,
        tier: :safe,
        description: "Start a specialist role/session inside the active shift.",
        args: %{
          "role_key" => %{type: :string, required: true},
          "agent_name" => %{type: :string, required: false},
          "shell" => %{type: :string, required: false},
          "purpose" => %{type: :string, required: false},
          "dedupe_key" => %{type: :string, required: false},
          "notes" => %{type: :string, required: false}
        }
      },
      %{
        name: "shift_assignment_status",
        type: :read,
        tier: :safe,
        description: "List active specialist role sessions inside the active shift.",
        args: %{}
      },
      %{
        name: "shift_assignment_stop",
        type: :trigger,
        tier: :safe,
        description: "Stop or block an active specialist role/session.",
        args: %{
          "id" => %{type: :integer, required: false},
          "role_key" => %{type: :string, required: false},
          "dedupe_key" => %{type: :string, required: false},
          "status" => %{type: :string, required: false, default: "stopped"},
          "notes" => %{type: :string, required: false}
        }
      },

      # Job descriptions (the role roster).
      list_entry("job_list", "List the defined jobs (role roster)."),
      %{
        name: "job_show",
        type: :read,
        tier: :safe,
        description: "Read one job description by key.",
        args: %{"key" => %{type: :string, required: true}}
      },

      # Dispatch queue (pull model) — the terminal agent's worklist + write-back.
      %{
        name: "dispatch_list",
        type: :read,
        tier: :safe,
        description: "List open Dispatch items (or by status), optionally for one job.",
        args: %{
          "status" => %{type: :string, required: false},
          "job" => %{type: :string, required: false},
          "limit" => %{type: :integer, required: false}
        }
      },
      get_entry("dispatch_show", "Fetch a Dispatch item by ID."),
      %{
        name: "dispatch_claim",
        type: :mutate,
        tier: :safe,
        description: "Claim the next open Dispatch item (optionally scoped to one job).",
        args: %{
          "job" => %{type: :string, required: false},
          "source" => %{type: :string, required: false},
          "claimed_by" => %{type: :string, required: false}
        }
      },
      %{
        name: "dispatch_done",
        type: :mutate,
        tier: :safe,
        description: "Mark a Dispatch item done.",
        args: %{
          "id" => %{type: :integer, required: true},
          "note" => %{type: :string, required: false}
        }
      },
      %{
        name: "dispatch_block",
        type: :mutate,
        tier: :safe,
        description: "Mark a Dispatch item blocked.",
        args: %{
          "id" => %{type: :integer, required: true},
          "note" => %{type: :string, required: false}
        }
      },
      %{
        name: "dispatch_reply",
        type: :mutate,
        tier: :restricted,
        description:
          "Send a threaded Gmail reply to a Dispatch item's sender and mark the item done.",
        args: %{
          "id" => %{type: :integer, required: true},
          "body" => %{type: :string, required: true},
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false}
        }
      }
    ]

  # The catalog is constant, but local functions can't be called from a module
  # attribute during compilation, so build it once at runtime and cache it —
  # plus the derived name-index and safe subset — in :persistent_term for O(1)
  # reuse instead of rebuilding/rescanning a fresh list on every call.
  defp catalog do
    case :persistent_term.get({__MODULE__, :catalog}, nil) do
      nil ->
        built = build_catalog()
        :persistent_term.put({__MODULE__, :catalog}, built)
        :persistent_term.put({__MODULE__, :by_name}, Map.new(built, &{&1.name, &1}))

        :persistent_term.put(
          {__MODULE__, :safe_commands},
          Enum.filter(built, &(&1.tier == :safe))
        )

        built

      built ->
        built
    end
  end

  defp by_name do
    catalog()
    :persistent_term.get({__MODULE__, :by_name})
  end

  defp safe_catalog do
    catalog()
    :persistent_term.get({__MODULE__, :safe_commands})
  end

  # -----------------------------------------------------------------------
  # Dispatch
  # -----------------------------------------------------------------------

  @doc """
  Dispatch a command by string name with the given args. Returns
  `{:error, :unknown_command}` if the name is not in the catalog.

  Accepts an optional `:caller` (`:trusted | :agent_untrusted | :agent | :mcp`,
  default `:trusted`):

  - `:trusted` — internal callers and the user's own CLI/`/api/run`; runs anything.
  - `:agent_untrusted` — an autonomous run working untrusted-origin content; runs
    anything EXCEPT the `gated` (outbound/irreversible) set, which is refused.
  - `:agent` / `:mcp` — may only run `:safe`-tier commands.

  A refused command returns `{:error, :requires_confirmation}`, is recorded via
  `Sentinel.Pending`, and is NOT executed.
  """
  def call(name, args \\ %{}, opts \\ []) when is_binary(name) do
    caller = Keyword.get(opts, :caller, :trusted)

    result =
      case authorize(name, caller) do
        :ok ->
          dispatch(name, args)

        {:error, :requires_confirmation} = refusal ->
          BusterClaw.Sentinel.Pending.record(name, args, caller)
          refusal
      end

    audit(name, args, caller, result)
    result
  end

  # Feed the Sentinel audit/notify spine. Refused restricted calls are critical
  # security blocks; otherwise only consequential (mutating/triggering) commands
  # are recorded — pure reads are skipped to keep the audit log signal-rich.
  defp audit(name, args, caller, {:error, :requires_confirmation}) do
    record(
      :security_block,
      ~s(Refused restricted command "#{name}" for #{caller} caller),
      %{command: name, args: args, caller: caller, tier: command_tier(name)}
    )

    :ok
  end

  defp audit(name, args, caller, result) do
    if command_type(name) in [:mutate, :trigger] do
      outcome = if match?({:ok, _}, result), do: "ok", else: "error"

      record(
        :command_invoke,
        "#{name} (#{outcome})",
        %{command: name, args: args, caller: caller, tier: command_tier(name), outcome: outcome}
      )
    end

    :ok
  end

  # Sentinel persistence + broadcast is on the hot command path. In tests it must
  # run inline so it shares the request's Ecto sandbox connection (tests read the
  # audit rows back synchronously). In dev/prod it is offloaded to a Task so the
  # caller doesn't block on a DB insert + PubSub broadcast.
  defp record(category, message, meta) do
    if inline_audit?() do
      BusterClaw.Sentinel.observe(category, message, meta)
    else
      # Fire-and-forget: observe/4 is best-effort and rescues its own failures, so
      # an unsupervised task is acceptable here and keeps it off the caller's path.
      Task.start(fn -> BusterClaw.Sentinel.observe(category, message, meta) end)
    end

    :ok
  end

  # Audit must run inline under the test Ecto sandbox so it shares the request's
  # checked-out connection. We detect that without a Mix-env runtime call: when the
  # Repo is configured with the SQL.Sandbox pool (test only), run inline. An
  # explicit `:sentinel_inline_audit` config value overrides the detection.
  defp inline_audit? do
    case Application.get_env(:buster_claw, :sentinel_inline_audit) do
      nil -> BusterClaw.Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox
      flag -> flag
    end
  end

  @doc "Return the command catalog as a list of maps."
  def list_commands, do: catalog()

  @doc "Return only the `:safe`-tier commands (the ones untrusted callers may run)."
  def safe_commands, do: safe_catalog()

  @doc """
  The tier (`:safe | :restricted`) of a command by name, or `nil` when the name
  is not in the catalog.
  """
  def command_tier(name) do
    case Map.get(by_name(), name) do
      %{tier: tier} -> tier
      nil -> nil
    end
  end

  @doc """
  The type (`:read | :mutate | :trigger`) of a command by name, or `nil` when
  the name is not in the catalog.
  """
  def command_type(name) do
    case Map.get(by_name(), name) do
      %{type: type} -> type
      nil -> nil
    end
  end

  @doc """
  Whether a command is `gated` — an outbound or irreversible action (`gmail_send`
  and the `*_delete` commands). An autonomous run working *untrusted-origin*
  content (`caller: :agent_untrusted`) may not fire these; they are refused and
  surfaced for human approval. Trusted callers are unaffected.
  """
  def command_gated?(name), do: match?(%{gated: true}, Map.get(by_name(), name))

  defp dispatch(name, args) do
    if has_command?(name) do
      apply(__MODULE__, String.to_existing_atom(name), [normalize_args(args)])
    else
      {:error, :unknown_command}
    end
  end

  # An autonomous run working untrusted-origin content is trusted enough to do a
  # lot without asking (drafts, saves, calendar edits, the dispatch verbs) — it is
  # only stopped from the `gated` set (outbound/irreversible), which surfaces for
  # human approval. This is the one guardrail kept for the "agent does a lot
  # without asking" model: untrusted input must not autonomously send or delete.
  defp authorize(name, :agent_untrusted) do
    if command_gated?(name), do: {:error, :requires_confirmation}, else: :ok
  end

  # Untrusted callers (chat agent / MCP) may only run safe-tier commands.
  # Unknown names fall through to `dispatch/2`, which returns
  # `{:error, :unknown_command}` — we don't leak "restricted" for those.
  defp authorize(name, caller) when caller in [:agent, :mcp] do
    case command_tier(name) do
      :restricted -> {:error, :requires_confirmation}
      _ -> :ok
    end
  end

  defp authorize(_name, _caller), do: :ok

  defp has_command?(name), do: Map.has_key?(by_name(), name)

  defp normalize_args(args) when is_map(args) do
    Map.new(args, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_args(_), do: %{}

  # -----------------------------------------------------------------------
  # CRUD: list/get/create/update/delete for every resource whose context
  # module exposes the canonical 5-function shape. Each tuple expands to
  # five command functions named `<prefix>_list`, `<prefix>_get`,
  # `<prefix>_create`, `<prefix>_update`, `<prefix>_delete`, all of which
  # honor the `{:ok, _} | {:error, reason}` contract used by `call/2`.
  # -----------------------------------------------------------------------

  for {prefix, context, ctx_singular, ctx_plural} <- [
        {:event, Calendar, :event, :events},
        {:integration, Integrations, :integration, :integrations}
      ] do
    list_fn = :"list_#{ctx_plural}"
    get_fn = :"get_#{ctx_singular}!"
    create_fn = :"create_#{ctx_singular}"
    update_fn = :"update_#{ctx_singular}"
    delete_fn = :"delete_#{ctx_singular}"

    def unquote(:"#{prefix}_list")(_args \\ %{}),
      do: {:ok, apply(unquote(context), unquote(list_fn), [])}

    def unquote(:"#{prefix}_get")(%{"id" => id}),
      do: safe_get(unquote(context), unquote(get_fn), id)

    def unquote(:"#{prefix}_create")(args),
      do: apply(unquote(context), unquote(create_fn), [args])

    def unquote(:"#{prefix}_update")(%{"id" => id} = args) do
      with_resource(unquote(context), unquote(get_fn), id, fn record ->
        apply(unquote(context), unquote(update_fn), [record, Map.delete(args, "id")])
      end)
    end

    def unquote(:"#{prefix}_delete")(%{"id" => id}) do
      with_resource(unquote(context), unquote(get_fn), id, fn record ->
        apply(unquote(context), unquote(delete_fn), [record])
      end)
    end
  end

  # -----------------------------------------------------------------------
  # Documents (asymmetric: read/save/delete wrap raw files)
  # -----------------------------------------------------------------------

  def document_list(_args \\ %{}), do: {:ok, Library.list_documents()}

  def document_get(%{"id" => id}), do: safe_get(Library, :get_document!, id)

  def document_read(%{"id" => id}) do
    with_resource(Library, :get_document!, id, &Library.read_raw_document/1)
  end

  def document_save(args), do: Library.save_raw_document(args)

  def document_delete(%{"id" => id}) do
    with_resource(Library, :get_document!, id, &Library.delete_raw_document/1)
  end

  # -----------------------------------------------------------------------
  # Integrations (extras)
  # -----------------------------------------------------------------------

  def integration_poll(%{"id" => id}) do
    case Integrations.poll_integration(id, []) do
      {:ok, run} -> {:ok, run}
      {:error, _} = err -> err
    end
  end

  def integration_poll_all(_args \\ %{}), do: {:ok, Integrations.poll_all([])}

  def integration_run_list(args) do
    case Map.get(args, "integration_id") do
      nil ->
        {:ok, Integrations.list_runs()}

      id ->
        with_resource(Integrations, :get_integration!, id, fn integration ->
          {:ok, Integrations.list_runs_for_integration(integration)}
        end)
    end
  end

  # -----------------------------------------------------------------------
  # Google Workspace accounts
  # -----------------------------------------------------------------------

  def google_account_list(_args \\ %{}), do: {:ok, Google.list_account_summaries()}

  def google_account_get(%{"id" => id}) do
    with_resource(Google, :get_account!, id, fn account ->
      {:ok, Google.account_summary(account)}
    end)
  end

  def google_account_create(args) do
    case Google.create_account(args) do
      {:ok, account} -> {:ok, Google.account_summary(account)}
      other -> other
    end
  end

  def google_account_update(%{"id" => id} = args) do
    with_resource(Google, :get_account!, id, fn account ->
      case Google.update_account(account, Map.delete(args, "id")) do
        {:ok, account} -> {:ok, Google.account_summary(account)}
        other -> other
      end
    end)
  end

  def google_account_delete(%{"id" => id}) do
    with_resource(Google, :get_account!, id, fn account ->
      case Google.delete_account(account) do
        {:ok, account} -> {:ok, Google.account_summary(account)}
        other -> other
      end
    end)
  end

  def gmail_label_list(args \\ %{}) do
    with_google_account(args, fn account ->
      BusterClaw.Google.Gmail.labels(account)
    end)
  end

  def gmail_search(args) do
    with_google_account(args, fn account ->
      query = Map.get(args, "query") || account.default_query || "newer_than:7d"
      limit = Map.get(args, "limit", 10)
      BusterClaw.Google.Gmail.search(account, query, limit: limit)
    end)
  end

  def gmail_read(args) do
    message_id = Map.get(args, "message_id") || Map.get(args, "id")

    if message_id in [nil, ""] do
      {:error, :missing_message_id}
    else
      with_google_account(args, fn account ->
        BusterClaw.Google.Gmail.read(account, message_id)
      end)
    end
  end

  def gmail_sync(args) do
    with_google_account(args, fn account ->
      query = Map.get(args, "query") || account.default_query || "newer_than:7d"
      limit = Map.get(args, "limit", 10)

      BusterClaw.Google.GmailSync.sync(account,
        query: query,
        limit: limit,
        incremental: truthy?(Map.get(args, "incremental", false)),
        start_history_id: Map.get(args, "start_history_id")
      )
    end)
  end

  def gmail_draft_create(args) do
    with_google_account(args, fn account ->
      BusterClaw.Google.Gmail.create_draft(account, args)
    end)
  end

  def gmail_send(args) do
    if send_confirmed?(args) do
      with_google_account(args, fn account ->
        BusterClaw.Google.Gmail.send_message(account, args)
      end)
    else
      {:error, :missing_send_confirmation}
    end
  end

  def google_calendar_sync(args) do
    with_google_account(args, fn account ->
      BusterClaw.Google.CalendarSync.sync(account,
        calendar_id: Map.get(args, "calendar_id", "primary"),
        days_ahead: Map.get(args, "days_ahead", 90),
        force_full?: truthy?(Map.get(args, "force_full", false))
      )
    end)
  end

  # -----------------------------------------------------------------------
  # Search
  # -----------------------------------------------------------------------

  def web_search(%{"query" => query} = args) do
    limit = Map.get(args, "limit", 10)
    Search.search(query, limit: limit)
  end

  # -----------------------------------------------------------------------
  # Browser
  # -----------------------------------------------------------------------

  def browser_fetch(%{"url" => url}), do: Browser.fetch(url, [])

  # -----------------------------------------------------------------------
  # Finance (read-only research)
  # -----------------------------------------------------------------------

  def finance_filings(%{"symbol" => symbol}) when is_binary(symbol) and symbol != "",
    do: Finance.filings(symbol)

  def finance_filings(_args), do: {:error, :missing_symbol}

  def finance_fundamentals(%{"symbol" => symbol}) when is_binary(symbol) and symbol != "",
    do: Finance.fundamentals(symbol)

  def finance_fundamentals(_args), do: {:error, :missing_symbol}

  def finance_quote(%{"symbol" => symbol}) when is_binary(symbol) and symbol != "",
    do: Finance.quote(symbol)

  def finance_quote(_args), do: {:error, :missing_symbol}

  def finance_news(%{"symbol" => symbol}) when is_binary(symbol) and symbol != "",
    do: Finance.news(symbol)

  def finance_news(_args), do: {:error, :missing_symbol}

  # -----------------------------------------------------------------------
  # Runtime
  # -----------------------------------------------------------------------

  def runtime_status(_args \\ %{}), do: {:ok, Status.snapshot()}

  def activity_report(args \\ %{}) do
    days =
      case Map.get(args, "days") do
        n when is_integer(n) and n > 0 -> n
        _ -> 7
      end

    {:ok, BusterClaw.ActivityReport.summary(days: days)}
  end

  # -----------------------------------------------------------------------
  # Visible terminal workspace
  # -----------------------------------------------------------------------

  def terminal_tab_open(args \\ %{}), do: TerminalWorkspace.open(args)

  # --- Orchestration shift (agent-drivable: the on-shift Claude starts/stops it) ---

  def shift_status(_args \\ %{}) do
    case Orchestration.active_shift() do
      nil ->
        {:ok, %{active: false}}

      shift ->
        {:ok,
         %{
           active: true,
           shift_id: shift.id,
           job_key: shift.job_key,
           job_name: shift.job_name,
           job_description: shift.job_description,
           agent_name: shift.agent_name,
           shell: shift.shell,
           unattended: shift.unattended,
           started_at: shift.started_at,
           dispatched: shift.dispatched_count,
           done: shift.done_count,
           failed: shift.failed_count
         }}
    end
  end

  def shift_start(args \\ %{}) do
    Orchestration.clear_kill_switch()

    case Orchestration.start_shift(args) do
      {:ok, shift} ->
        {:ok,
         %{
           shift_id: shift.id,
           status: shift.status,
           job_key: shift.job_key,
           job_name: shift.job_name,
           agent_name: shift.agent_name,
           shell: shift.shell,
           unattended: shift.unattended,
           started_at: shift.started_at
         }}

      {:error, _changeset} = error ->
        error
    end
  end

  def shift_stop(args \\ %{}) do
    reason = Map.get(args, "reason", "stopped by agent")

    case Orchestration.stop_shift(reason) do
      {:ok, shift} -> {:ok, %{shift_id: shift.id, status: shift.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def shift_assignment_start(args \\ %{}) do
    case Orchestration.start_shift_assignment(args) do
      {:ok, assignment} ->
        {:ok, assignment}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def shift_assignment_status(args \\ %{}), do: Orchestration.shift_assignment_status(args)

  def shift_assignment_stop(args \\ %{}) do
    case Orchestration.stop_shift_assignment(args) do
      {:ok, assignment} -> {:ok, assignment}
      {:error, reason} -> {:error, reason}
    end
  end

  # -----------------------------------------------------------------------
  # Dispatch queue (pull model)
  # -----------------------------------------------------------------------

  def dispatch_list(args \\ %{}) do
    items =
      case blank_to_nil(Map.get(args, "status")) do
        nil -> Dispatch.list_open()
        status -> Dispatch.list_items(status: status, limit: Map.get(args, "limit"))
      end

    {:ok, filter_by_job(items, blank_to_nil(Map.get(args, "job")))}
  end

  def dispatch_show(%{"id" => id}), do: safe_get(Dispatch, :get_item!, id)

  def dispatch_claim(args \\ %{}) do
    claimed_by =
      blank_to_nil(Map.get(args, "claimed_by")) || blank_to_nil(Map.get(args, "job")) || "agent"

    opts =
      [source: blank_to_nil(Map.get(args, "source")), role: blank_to_nil(Map.get(args, "job"))]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Dispatch.claim_next(claimed_by, opts) do
      {:ok, item} -> {:ok, item}
      {:error, :empty} -> {:ok, %{"empty" => true}}
      {:error, reason} -> {:error, reason}
    end
  end

  def dispatch_done(%{"id" => id} = args), do: finish_dispatch(id, "done", args)
  def dispatch_block(%{"id" => id} = args), do: finish_dispatch(id, "blocked", args)

  @doc """
  Send a threaded Gmail reply to a Dispatch item's sender and mark the item done.
  Restricted-tier: the act of calling it is the send authorization (no separate
  `confirm_send`). The reply threads via the stored RFC Message-ID + thread id and
  is sent from the account that received the original mail.
  """
  def dispatch_reply(%{"id" => id} = args) do
    with_resource(Dispatch, :get_item!, id, fn item ->
      cond do
        is_nil(blank_to_nil(Map.get(args, "body"))) -> {:error, :missing_body}
        is_nil(blank_to_nil(item.sender)) -> {:error, :no_reply_recipient}
        true -> send_dispatch_reply(item, blank_to_nil(Map.get(args, "body")), args)
      end
    end)
  end

  defp send_dispatch_reply(item, body, args) do
    selector =
      args
      |> Map.take(["account_id", "email"])
      |> put_new_string("email", blank_to_nil(item.source_account))

    with_google_account(selector, fn account ->
      case BusterClaw.Google.Gmail.send_message(account, reply_message_attrs(item, body)) do
        {:ok, sent} ->
          # The mail is already sent. If finishing the Dispatch item fails we must
          # NOT crash and report the whole reply as failed — surface the partial
          # success instead so the caller knows the send went through.
          thread_id = Map.get(sent, :thread_id) || item.gmail_thread_id

          BusterClaw.Sentinel.observe(
            :outbound_send,
            "Auto-replied to Dispatch item ##{item.id}",
            %{
              dispatch_item_id: item.id,
              to: item.sender,
              gmail_thread_id: item.gmail_thread_id
            }
          )

          case Dispatch.finish(item, "done", reply_finish_attrs(body)) do
            {:ok, finished} ->
              {:ok,
               %{
                 dispatch_item_id: finished.id,
                 status: finished.status,
                 to: item.sender,
                 subject: reply_subject(item.subject),
                 thread_id: thread_id
               }}

            {:error, reason} ->
              # Sent, but the item could not be marked done. Report partial success
              # rather than raising a MatchError.
              {:ok,
               %{
                 dispatch_item_id: item.id,
                 status: item.status,
                 sent: true,
                 finish_error: reason,
                 to: item.sender,
                 subject: reply_subject(item.subject),
                 thread_id: thread_id
               }}
          end

        error ->
          error
      end
    end)
  end

  defp reply_message_attrs(item, body) do
    %{
      "to" => item.sender,
      "subject" => reply_subject(item.subject),
      "body" => body,
      "in_reply_to" => item.gmail_rfc_message_id,
      "references" => item.gmail_rfc_message_id,
      "thread_id" => item.gmail_thread_id
    }
  end

  defp reply_subject(subject) do
    case blank_to_nil(subject) do
      nil -> "Re:"
      trimmed -> if Regex.match?(~r/^re:/i, trimmed), do: trimmed, else: "Re: " <> trimmed
    end
  end

  defp reply_finish_attrs(body) do
    %{outcome: "replied", notes: "Auto-replied: " <> String.slice(to_string(body), 0, 280)}
  end

  defp put_new_string(map, _key, nil), do: map

  defp put_new_string(map, key, value) do
    if Map.get(map, key) in [nil, ""], do: Map.put(map, key, value), else: map
  end

  # -----------------------------------------------------------------------
  # Job descriptions (the role roster)
  # -----------------------------------------------------------------------

  def job_list(_args \\ %{}), do: {:ok, Jobs.list()}

  def job_show(%{"key" => key}) do
    case Jobs.get(key) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end

  defp finish_dispatch(id, status, args) do
    with_resource(Dispatch, :get_item!, id, fn item ->
      attrs =
        case blank_to_nil(Map.get(args, "note")) do
          nil -> %{}
          note -> %{notes: note, outcome: note}
        end

      Dispatch.finish(item, status, attrs)
    end)
  end

  # -----------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp filter_by_job(items, nil), do: items
  defp filter_by_job(items, job), do: Enum.filter(items, &(&1.recommended_role_key == job))

  defp safe_get(module, fun, id) do
    {:ok, apply(module, fun, [id])}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp with_resource(module, getter, id, fun) do
    case safe_get(module, getter, id) do
      {:ok, resource} -> fun.(resource)
      error -> error
    end
  end

  defp with_google_account(args, fun) do
    cond do
      account_id = Map.get(args, "account_id") ->
        with_resource(Google, :get_account!, account_id, fun)

      email = Map.get(args, "email") ->
        case Google.get_account_by_email(email) do
          nil -> {:error, :not_found}
          account -> fun.(account)
        end

      account = Google.default_account() ->
        fun.(account)

      true ->
        {:error, :no_google_account}
    end
  end

  defp send_confirmed?(args) do
    Map.get(args, "confirm_send") in [true, "true", "send", "SEND"]
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, "yes", "YES", "on", "ON"]
end
