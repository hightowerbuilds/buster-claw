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
    Delivery,
    Google,
    Hooks,
    Integrations,
    Library,
    MCP,
    Memory,
    Orchestration,
    Scheduler,
    Search,
    TerminalWorkspace,
    Webhooks
  }

  alias BusterClaw.Runtime.Status

  # -----------------------------------------------------------------------
  # Dispatch
  # -----------------------------------------------------------------------

  @doc """
  Dispatch a command by string name with the given args. Returns
  `{:error, :unknown_command}` if the name is not in the catalog.

  Accepts an optional `:caller` (`:trusted | :agent | :mcp`, default
  `:trusted`). Untrusted callers (`:agent`, `:mcp`) may only run `:safe`-tier
  commands; a `:restricted` command is refused with
  `{:error, :requires_confirmation}`, recorded via `Sentinel.Pending`, and is
  NOT executed. Internal callers and the user's own `/api/run` default to
  `:trusted` and are unaffected.
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
    BusterClaw.Sentinel.observe(
      :security_block,
      ~s(Refused restricted command "#{name}" for #{caller} caller),
      %{command: name, args: args, caller: caller, tier: command_tier(name)}
    )

    :ok
  end

  defp audit(name, args, caller, result) do
    if command_type(name) in [:mutate, :trigger] do
      outcome = if match?({:ok, _}, result), do: "ok", else: "error"

      BusterClaw.Sentinel.observe(
        :command_invoke,
        "#{name} (#{outcome})",
        %{command: name, args: args, caller: caller, tier: command_tier(name), outcome: outcome}
      )
    end

    :ok
  end

  @doc "Return the command catalog as a list of maps."
  def list_commands, do: commands_catalog()

  @doc "Return only the `:safe`-tier commands (the ones untrusted callers may run)."
  def safe_commands, do: Enum.filter(commands_catalog(), &(&1.tier == :safe))

  @doc """
  The tier (`:safe | :restricted`) of a command by name, or `nil` when the name
  is not in the catalog.
  """
  def command_tier(name) do
    case Enum.find(commands_catalog(), &(&1.name == name)) do
      %{tier: tier} -> tier
      nil -> nil
    end
  end

  @doc """
  The type (`:read | :mutate | :trigger`) of a command by name, or `nil` when
  the name is not in the catalog.
  """
  def command_type(name) do
    case Enum.find(commands_catalog(), &(&1.name == name)) do
      %{type: type} -> type
      nil -> nil
    end
  end

  defp dispatch(name, args) do
    if has_command?(name) do
      apply(__MODULE__, String.to_existing_atom(name), [normalize_args(args)])
    else
      {:error, :unknown_command}
    end
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

  defp has_command?(name), do: Enum.any?(commands_catalog(), &(&1.name == name))

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
        {:mcp_server, MCP, :server, :servers},
        {:webhook, Webhooks, :webhook, :webhooks},
        {:delivery_destination, Delivery, :destination, :destinations},
        {:scheduler_job, Scheduler, :job, :jobs},
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
  # MCP servers (extras)
  # -----------------------------------------------------------------------

  def mcp_server_connect(%{"id" => id}) do
    with_resource(MCP, :get_server!, id, fn server ->
      case MCP.connect_server(server) do
        {:ok, _pid} -> {:ok, MCP.get_server!(server.id)}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def mcp_server_tools(%{"id" => id}) do
    with_resource(MCP, :get_server!, id, &MCP.discover_tools/1)
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
  # Memory (asymmetric: remember/forget naming, create stamps timestamp)
  # -----------------------------------------------------------------------

  def memory_list(_args \\ %{}), do: {:ok, Memory.list_memories()}

  def memory_remember(%{"text" => _} = args) do
    attrs = Map.put_new_lazy(args, "created_at", &now_utc/0)
    Memory.create_memory(attrs)
  end

  def memory_forget(%{"id" => id}) do
    with_resource(Memory, :get_memory!, id, &Memory.delete_memory/1)
  end

  # -----------------------------------------------------------------------
  # Webhooks (extras)
  # -----------------------------------------------------------------------

  def webhook_trigger(%{"name" => name} = args) do
    headers = Map.get(args, "headers", %{}) |> Enum.into([])
    body = Map.get(args, "body", "")
    Webhooks.trigger(name, headers, body)
  end

  # -----------------------------------------------------------------------
  # Hooks (asymmetric: list/get via Hooks; mutate via BusterClaw.Automation)
  # -----------------------------------------------------------------------

  def hook_list(_args \\ %{}), do: {:ok, Hooks.list_hooks()}

  def hook_get(%{"id" => id}), do: safe_get(Hooks, :get_hook!, id)

  def hook_create(args), do: BusterClaw.Automation.create_hook(args)

  def hook_update(%{"id" => id} = args) do
    with_resource(Hooks, :get_hook!, id, fn hook ->
      BusterClaw.Automation.update_hook(hook, Map.delete(args, "id"))
    end)
  end

  def hook_delete(%{"id" => id}) do
    with_resource(Hooks, :get_hook!, id, &BusterClaw.Automation.delete_hook/1)
  end

  def hook_test(%{"id" => id} = args) do
    payload = Map.get(args, "payload", %{})

    with_resource(Hooks, :get_hook!, id, fn hook ->
      Hooks.test_hook(hook, payload: payload)
    end)
  end

  # -----------------------------------------------------------------------
  # Delivery destinations (extras)
  # -----------------------------------------------------------------------

  def delivery_destination_test(%{"id" => id} = args) do
    payload = Map.get(args, "payload", %{})

    with_resource(Delivery, :get_destination!, id, fn destination ->
      Delivery.test_destination(destination, payload: payload)
    end)
  end

  # -----------------------------------------------------------------------
  # Delivery (broadcast)
  # -----------------------------------------------------------------------

  def delivery_dispatch_all(%{"payload" => payload}) do
    {:ok, Delivery.dispatch_all(payload, [])}
  end

  # -----------------------------------------------------------------------
  # Scheduler jobs (extras)
  # -----------------------------------------------------------------------

  def scheduler_job_run_now(%{"id" => id}) do
    case Scheduler.run_now(id) do
      {:ok, summary} -> {:ok, summary}
      {:error, :not_found} -> {:error, :not_found}
      other -> other
    end
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
  # Runtime
  # -----------------------------------------------------------------------

  def runtime_status(_args \\ %{}), do: {:ok, Status.snapshot()}

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
           duration_hours: shift.duration_hours,
           started_at: shift.started_at,
           ends_at: shift.ends_at,
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
           duration_hours: shift.duration_hours,
           ends_at: shift.ends_at
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
  # Helpers
  # -----------------------------------------------------------------------

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

  defp now_utc, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # -----------------------------------------------------------------------
  # Catalog
  # -----------------------------------------------------------------------

  @id_required %{"id" => %{type: :integer, required: true}}

  defp list_entry(name, desc),
    do: %{name: name, type: :read, tier: :safe, description: desc, args: %{}}

  defp get_entry(name, desc),
    do: %{name: name, type: :read, tier: :safe, description: desc, args: @id_required}

  defp delete_entry(name, desc),
    do: %{name: name, type: :mutate, tier: :restricted, description: desc, args: @id_required}

  defp id_trigger_entry(name, desc, tier),
    do: %{name: name, type: :trigger, tier: tier, description: desc, args: @id_required}

  defp id_payload_trigger_entry(name, desc, tier) do
    %{
      name: name,
      type: :trigger,
      tier: tier,
      description: desc,
      args: Map.put(@id_required, "payload", %{type: :map, required: false})
    }
  end

  defp commands_catalog,
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

      # Memory
      list_entry("memory_list", "List all persistent memory entries."),
      %{
        name: "memory_remember",
        type: :mutate,
        tier: :restricted,
        description: "Save a new memory.",
        args: %{"text" => %{type: :string, required: true}}
      },
      delete_entry("memory_forget", "Delete a memory by ID."),

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

      # MCP servers
      list_entry("mcp_server_list", "List configured MCP servers."),
      get_entry("mcp_server_get", "Fetch an MCP server by ID."),
      %{
        name: "mcp_server_create",
        type: :mutate,
        tier: :restricted,
        description: "Configure a new MCP server.",
        args: %{
          "name" => %{type: :string, required: true},
          "command" => %{type: :string, required: true},
          "args" => %{type: :map, required: false},
          "env" => %{type: :map, required: false},
          "enabled" => %{type: :boolean, required: false, default: true}
        }
      },
      %{
        name: "mcp_server_update",
        type: :mutate,
        tier: :restricted,
        description: "Update an MCP server config.",
        args: %{
          "id" => %{type: :integer, required: true},
          "name" => %{type: :string, required: false},
          "command" => %{type: :string, required: false},
          "args" => %{type: :map, required: false},
          "env" => %{type: :map, required: false},
          "enabled" => %{type: :boolean, required: false}
        }
      },
      delete_entry("mcp_server_delete", "Delete an MCP server config."),
      id_trigger_entry(
        "mcp_server_connect",
        "Launch a configured MCP stdio server.",
        :restricted
      ),
      id_trigger_entry(
        "mcp_server_tools",
        "Launch and discover tools from an MCP stdio server.",
        :safe
      ),

      # Webhooks
      list_entry("webhook_list", "List all webhooks."),
      get_entry("webhook_get", "Fetch a webhook by ID."),
      %{
        name: "webhook_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a webhook.",
        args: %{
          "name" => %{type: :string, required: true},
          "action" => %{
            type: :string,
            required: true,
            enum: ["command"]
          },
          "secret" => %{type: :string, required: false},
          "enabled" => %{type: :boolean, required: false, default: true}
        }
      },
      %{
        name: "webhook_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a webhook.",
        args: %{
          "id" => %{type: :integer, required: true},
          "name" => %{type: :string, required: false},
          "action" => %{type: :string, required: false, enum: ["command"]},
          "secret" => %{type: :string, required: false},
          "enabled" => %{type: :boolean, required: false}
        }
      },
      delete_entry("webhook_delete", "Delete a webhook."),
      %{
        name: "webhook_trigger",
        type: :trigger,
        tier: :restricted,
        description: "Trigger a webhook by name.",
        args: %{
          "name" => %{type: :string, required: true},
          "headers" => %{type: :map, required: false},
          "body" => %{type: :string, required: false}
        }
      },

      # Hooks
      list_entry("hook_list", "List all hooks."),
      get_entry("hook_get", "Fetch a hook by ID."),
      %{
        name: "hook_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a hook.",
        args: %{
          "name" => %{type: :string, required: true},
          "event" => %{type: :string, required: true},
          "type" => %{type: :string, required: true, enum: ["shell", "webhook"]},
          "target" => %{type: :string, required: true},
          "async" => %{type: :boolean, required: false, default: true},
          "enabled" => %{type: :boolean, required: false, default: true}
        }
      },
      %{
        name: "hook_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a hook.",
        args: %{
          "id" => %{type: :integer, required: true},
          "name" => %{type: :string, required: false},
          "event" => %{type: :string, required: false},
          "type" => %{type: :string, required: false},
          "target" => %{type: :string, required: false},
          "async" => %{type: :boolean, required: false},
          "enabled" => %{type: :boolean, required: false}
        }
      },
      delete_entry("hook_delete", "Delete a hook."),
      # Restricted: hook_test runs the hook's stored target, which for "shell"
      # hooks is an arbitrary command. Must not be reachable by the chat agent.
      id_payload_trigger_entry("hook_test", "Test-run a single hook.", :restricted),

      # Delivery destinations
      list_entry("delivery_destination_list", "List delivery destinations."),
      get_entry("delivery_destination_get", "Fetch a delivery destination by ID."),
      %{
        name: "delivery_destination_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a delivery destination.",
        args: %{
          "name" => %{type: :string, required: true},
          "type" => %{
            type: :string,
            required: true,
            enum: ["slack", "discord", "telegram", "webhook"]
          },
          "url" => %{type: :string, required: false},
          "token" => %{type: :string, required: false},
          "chat_id" => %{type: :string, required: false},
          "enabled" => %{type: :boolean, required: false, default: true}
        }
      },
      %{
        name: "delivery_destination_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a delivery destination.",
        args: %{
          "id" => %{type: :integer, required: true},
          "name" => %{type: :string, required: false},
          "type" => %{type: :string, required: false},
          "url" => %{type: :string, required: false},
          "token" => %{type: :string, required: false},
          "chat_id" => %{type: :string, required: false},
          "enabled" => %{type: :boolean, required: false}
        }
      },
      delete_entry("delivery_destination_delete", "Delete a delivery destination."),
      id_payload_trigger_entry(
        "delivery_destination_test",
        "Send a test payload to a destination.",
        :safe
      ),

      # Delivery
      %{
        name: "delivery_dispatch_all",
        type: :trigger,
        tier: :restricted,
        description: "Send a payload to every enabled destination.",
        args: %{
          "payload" => %{type: :map, required: true}
        }
      },

      # Scheduler
      list_entry("scheduler_job_list", "List scheduler jobs."),
      get_entry("scheduler_job_get", "Fetch a scheduler job by ID."),
      %{
        name: "scheduler_job_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a scheduler job.",
        args: %{
          "job_id" => %{type: :string, required: true},
          "type" => %{type: :string, required: true, enum: ["integrations_poll"]},
          "cron" => %{type: :string, required: true},
          "enabled" => %{type: :boolean, required: false, default: true}
        }
      },
      %{
        name: "scheduler_job_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a scheduler job.",
        args: %{
          "id" => %{type: :integer, required: true},
          "job_id" => %{type: :string, required: false},
          "type" => %{type: :string, required: false, enum: ["integrations_poll"]},
          "cron" => %{type: :string, required: false},
          "enabled" => %{type: :boolean, required: false}
        }
      },
      delete_entry("scheduler_job_delete", "Delete a scheduler job."),
      id_trigger_entry("scheduler_job_run_now", "Run a scheduler job immediately.", :restricted),

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

      # Runtime
      list_entry("runtime_status", "Snapshot of process and system state."),

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
          "Start an unattended orchestration shift with job/agent assignment metadata.",
        args: %{
          "job" => %{type: :string, required: false, default: "lookout"},
          "agent_name" => %{type: :string, required: false},
          "shell" => %{type: :string, required: false},
          "hours" => %{type: :integer, required: false, default: 12}
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
      }
    ]
end
