defmodule BusterClaw.Commands do
  @moduledoc """
  Canonical command surface for Buster Claw.

  Every external surface (HTTP API, MCP server, CLI escript) and the internal
  chat agent dispatches through this module. See
  `docs/rewrite/COMMAND_SURFACE.md` for the full catalog with arg schemas,
  return shapes, and agent allowlist tiers.

  ## Contract

  - All commands accept a single map argument (string keys preferred for wire
    parity; atom keys are normalized).
  - All commands return `{:ok, value}` or `{:error, reason_or_changeset}`.
  - Bang getters raise; their `Commands.*` wrappers translate to
    `{:error, :not_found}`.

  ## Dispatch

  - `list_commands/0` returns the catalog (used by MCP `tools/list` and CLI `--help`).
  - `call/2` dispatches by string command name (used by HTTP and MCP frontends).
  - Direct calls (`Commands.source_list(%{})`) work for internal callers.
  """

  alias BusterClaw.{
    Analysis,
    Browser,
    Calendar,
    Chat,
    Delivery,
    Hooks,
    Ingest,
    Integrations,
    Library,
    MCP,
    Memory,
    Providers,
    Scheduler,
    Search,
    Sources,
    Webhooks
  }

  alias BusterClaw.Runtime.Status

  # -----------------------------------------------------------------------
  # Dispatch
  # -----------------------------------------------------------------------

  @doc """
  Dispatch a command by string name with the given args. Returns
  `{:error, :unknown_command}` if the name is not in the catalog.
  """
  def call(name, args \\ %{}) when is_binary(name) do
    result =
      if has_command?(name) do
        apply(__MODULE__, String.to_existing_atom(name), [normalize_args(args)])
      else
        {:error, :unknown_command}
      end

    BusterClaw.AgentMode.record_activity(name, args, result)
    result
  end

  @doc "Return the command catalog as a list of maps."
  def list_commands, do: commands_catalog()

  defp has_command?(name), do: Enum.any?(commands_catalog(), &(&1.name == name))

  defp normalize_args(args) when is_map(args) do
    Map.new(args, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_args(_), do: %{}

  # -----------------------------------------------------------------------
  # Sources
  # -----------------------------------------------------------------------

  def source_list(_args \\ %{}), do: {:ok, Sources.list_sources()}

  def source_get(%{"id" => id}), do: safe_get(Sources, :get_source!, id)

  def source_create(args), do: Sources.create_source(args)

  def source_update(%{"id" => id} = args) do
    with_resource(Sources, :get_source!, id, fn source ->
      Sources.update_source(source, Map.delete(args, "id"))
    end)
  end

  def source_delete(%{"id" => id}) do
    with_resource(Sources, :get_source!, id, &Sources.delete_source/1)
  end

  def source_ingest(%{"id" => id}) do
    with_resource(Sources, :get_source!, id, fn source ->
      case Ingest.ingest_source(source) do
        {:ok, count, items} -> {:ok, %{count: count, items: items}}
        other -> other
      end
    end)
  end

  # -----------------------------------------------------------------------
  # Providers
  # -----------------------------------------------------------------------

  def provider_list(_args \\ %{}), do: {:ok, Providers.list_providers()}

  def provider_get(%{"id" => id}), do: safe_get(Providers, :get_provider!, id)

  def provider_active(_args \\ %{}), do: {:ok, Providers.active_provider()}

  def provider_create(args), do: Providers.create_provider(args)

  def provider_update(%{"id" => id} = args) do
    with_resource(Providers, :get_provider!, id, fn provider ->
      Providers.update_provider(provider, Map.delete(args, "id"))
    end)
  end

  def provider_delete(%{"id" => id}) do
    with_resource(Providers, :get_provider!, id, &Providers.delete_provider/1)
  end

  def provider_set_active(%{"id" => id}) do
    with_resource(Providers, :get_provider!, id, &Providers.set_active_provider/1)
  end

  def provider_test(%{"id" => id}) do
    with_resource(Providers, :get_provider!, id, &Providers.test_provider/1)
  end

  # -----------------------------------------------------------------------
  # Documents
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
  # Reports
  # -----------------------------------------------------------------------

  def report_list(_args \\ %{}), do: {:ok, Library.list_reports()}

  def report_get(%{"id" => id}), do: safe_get(Library, :get_report!, id)

  # -----------------------------------------------------------------------
  # Analysis
  # -----------------------------------------------------------------------

  def analysis_job_list(_args \\ %{}), do: {:ok, Analysis.list_jobs()}

  def analysis_queue(%{"document_id" => doc_id} = args) do
    extra = Map.drop(args, ["document_id"])

    with_resource(Library, :get_document!, doc_id, fn document ->
      Analysis.queue_document(document, extra)
    end)
  end

  def analysis_run_pending(args) do
    max = Map.get(args, "max", 1)
    {:ok, Analysis.run_pending(max: max)}
  end

  def analysis_run_job(%{"id" => id}) do
    case Analysis.run_job(id, []) do
      {:ok, job} -> {:ok, job}
      {:error, :not_found} -> {:error, :not_found}
      other -> other
    end
  end

  # -----------------------------------------------------------------------
  # Memory
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
  # Calendar events
  # -----------------------------------------------------------------------

  def event_list(_args \\ %{}), do: {:ok, Calendar.list_events()}

  def event_get(%{"id" => id}), do: safe_get(Calendar, :get_event!, id)

  def event_create(args), do: Calendar.create_event(args)

  def event_update(%{"id" => id} = args) do
    with_resource(Calendar, :get_event!, id, fn event ->
      Calendar.update_event(event, Map.delete(args, "id"))
    end)
  end

  def event_delete(%{"id" => id}) do
    with_resource(Calendar, :get_event!, id, &Calendar.delete_event/1)
  end

  # -----------------------------------------------------------------------
  # MCP servers
  # -----------------------------------------------------------------------

  def mcp_server_list(_args \\ %{}), do: {:ok, MCP.list_servers()}

  def mcp_server_get(%{"id" => id}), do: safe_get(MCP, :get_server!, id)

  def mcp_server_create(args), do: MCP.create_server(args)

  def mcp_server_update(%{"id" => id} = args) do
    with_resource(MCP, :get_server!, id, fn server ->
      MCP.update_server(server, Map.delete(args, "id"))
    end)
  end

  def mcp_server_delete(%{"id" => id}) do
    with_resource(MCP, :get_server!, id, &MCP.delete_server/1)
  end

  # -----------------------------------------------------------------------
  # Webhooks
  # -----------------------------------------------------------------------

  def webhook_list(_args \\ %{}), do: {:ok, Webhooks.list_webhooks()}

  def webhook_get(%{"id" => id}), do: safe_get(Webhooks, :get_webhook!, id)

  def webhook_create(args), do: Webhooks.create_webhook(args)

  def webhook_update(%{"id" => id} = args) do
    with_resource(Webhooks, :get_webhook!, id, fn webhook ->
      Webhooks.update_webhook(webhook, Map.delete(args, "id"))
    end)
  end

  def webhook_delete(%{"id" => id}) do
    with_resource(Webhooks, :get_webhook!, id, &Webhooks.delete_webhook/1)
  end

  def webhook_trigger(%{"name" => name} = args) do
    headers = Map.get(args, "headers", %{}) |> Enum.into([])
    body = Map.get(args, "body", "")
    Webhooks.trigger(name, headers, body)
  end

  # -----------------------------------------------------------------------
  # Hooks
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

  def hook_event_execute(%{"event" => event} = args) do
    payload = Map.get(args, "payload", %{})
    {:ok, Hooks.execute_event(event, payload, [])}
  end

  # -----------------------------------------------------------------------
  # Delivery destinations
  # -----------------------------------------------------------------------

  def delivery_destination_list(_args \\ %{}), do: {:ok, Delivery.list_destinations()}

  def delivery_destination_get(%{"id" => id}), do: safe_get(Delivery, :get_destination!, id)

  def delivery_destination_create(args), do: Delivery.create_destination(args)

  def delivery_destination_update(%{"id" => id} = args) do
    with_resource(Delivery, :get_destination!, id, fn destination ->
      Delivery.update_destination(destination, Map.delete(args, "id"))
    end)
  end

  def delivery_destination_delete(%{"id" => id}) do
    with_resource(Delivery, :get_destination!, id, &Delivery.delete_destination/1)
  end

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
  # Scheduler jobs
  # -----------------------------------------------------------------------

  def scheduler_job_list(_args \\ %{}), do: {:ok, Scheduler.list_jobs()}

  def scheduler_job_get(%{"id" => id}), do: safe_get(Scheduler, :get_job!, id)

  def scheduler_job_create(args), do: Scheduler.create_job(args)

  def scheduler_job_update(%{"id" => id} = args) do
    with_resource(Scheduler, :get_job!, id, fn job ->
      Scheduler.update_job(job, Map.delete(args, "id"))
    end)
  end

  def scheduler_job_delete(%{"id" => id}) do
    with_resource(Scheduler, :get_job!, id, &Scheduler.delete_job/1)
  end

  def scheduler_job_run_now(%{"id" => id}) do
    case Scheduler.run_now(id) do
      {:ok, summary} -> {:ok, summary}
      {:error, :not_found} -> {:error, :not_found}
      other -> other
    end
  end

  # -----------------------------------------------------------------------
  # Integrations
  # -----------------------------------------------------------------------

  def integration_list(_args \\ %{}), do: {:ok, Integrations.list_integrations()}

  def integration_get(%{"id" => id}), do: safe_get(Integrations, :get_integration!, id)

  def integration_create(args), do: Integrations.create_integration(args)

  def integration_update(%{"id" => id} = args) do
    with_resource(Integrations, :get_integration!, id, fn integration ->
      Integrations.update_integration(integration, Map.delete(args, "id"))
    end)
  end

  def integration_delete(%{"id" => id}) do
    with_resource(Integrations, :get_integration!, id, &Integrations.delete_integration/1)
  end

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
  # Chat
  # -----------------------------------------------------------------------

  def chat_send(%{"prompt" => prompt} = args) do
    session = Map.get(args, "session_id", Chat.default_session())
    Chat.ensure_session(session)
    :ok = Chat.send_message(session, prompt)
    {:ok, :sent}
  end

  def chat_messages(args) do
    session = Map.get(args, "session_id", Chat.default_session())
    Chat.ensure_session(session)
    {:ok, Chat.messages(session)}
  end

  def chat_clear(args) do
    session = Map.get(args, "session_id", Chat.default_session())
    Chat.ensure_session(session)
    :ok = Chat.clear(session)
    {:ok, :cleared}
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

  defp now_utc, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # -----------------------------------------------------------------------
  # Catalog
  # -----------------------------------------------------------------------

  defp commands_catalog,
    do: [
      # Sources
      %{
        name: "source_list",
        type: :read,
        tier: :safe,
        description: "List all configured sources.",
        args: %{}
      },
      %{
        name: "source_get",
        type: :read,
        tier: :safe,
        description: "Fetch a source by ID.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "source_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a new source.",
        args: %{
          "url" => %{type: :string, required: true, description: "RSS or page URL"},
          "type" => %{type: :string, required: true, enum: ["rss", "url"]},
          "name" => %{type: :string, required: false},
          "tags" => %{type: :map, required: false},
          "browser_engine" => %{type: :string, required: false},
          "cookies" => %{type: :map, required: false},
          "enabled" => %{type: :boolean, required: false, default: true}
        }
      },
      %{
        name: "source_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a source.",
        args: %{
          "id" => %{type: :integer, required: true},
          "url" => %{type: :string, required: false},
          "type" => %{type: :string, required: false, enum: ["rss", "url"]},
          "name" => %{type: :string, required: false},
          "tags" => %{type: :map, required: false},
          "browser_engine" => %{type: :string, required: false},
          "cookies" => %{type: :map, required: false},
          "enabled" => %{type: :boolean, required: false}
        }
      },
      %{
        name: "source_delete",
        type: :mutate,
        tier: :restricted,
        description: "Delete a source.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "source_ingest",
        type: :trigger,
        tier: :safe,
        description: "Fetch + parse + save documents from a source.",
        args: %{"id" => %{type: :integer, required: true}}
      },

      # Providers
      %{
        name: "provider_list",
        type: :read,
        tier: :safe,
        description: "List all configured LLM providers.",
        args: %{}
      },
      %{
        name: "provider_get",
        type: :read,
        tier: :safe,
        description: "Fetch a provider by ID.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "provider_active",
        type: :read,
        tier: :safe,
        description: "Return the currently active provider.",
        args: %{}
      },
      %{
        name: "provider_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a new provider.",
        args: %{
          "name" => %{type: :string, required: true},
          "type" => %{
            type: :string,
            required: true,
            enum: ["anthropic", "gemini", "codex", "openai", "openrouter", "ollama", "custom"]
          },
          "model" => %{type: :string, required: true},
          "api_key" => %{
            type: :string,
            required: false,
            description: "Required for every type except ollama."
          },
          "base_url" => %{type: :string, required: false},
          "active" => %{type: :boolean, required: false, default: false},
          "priority" => %{type: :integer, required: false, default: 100}
        }
      },
      %{
        name: "provider_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a provider.",
        args: %{
          "id" => %{type: :integer, required: true},
          "name" => %{type: :string, required: false},
          "type" => %{type: :string, required: false},
          "model" => %{type: :string, required: false},
          "api_key" => %{type: :string, required: false},
          "base_url" => %{type: :string, required: false},
          "active" => %{type: :boolean, required: false},
          "priority" => %{type: :integer, required: false}
        }
      },
      %{
        name: "provider_delete",
        type: :mutate,
        tier: :restricted,
        description: "Delete a provider.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "provider_set_active",
        type: :mutate,
        tier: :restricted,
        description: "Mark a provider as active (deactivates others).",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "provider_test",
        type: :trigger,
        tier: :safe,
        description: "Test connection to a provider's endpoint.",
        args: %{"id" => %{type: :integer, required: true}}
      },

      # Documents
      %{
        name: "document_list",
        type: :read,
        tier: :safe,
        description: "List all indexed documents.",
        args: %{}
      },
      %{
        name: "document_get",
        type: :read,
        tier: :safe,
        description: "Fetch a document by ID.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "document_read",
        type: :read,
        tier: :safe,
        description: "Read the raw markdown contents of a document.",
        args: %{"id" => %{type: :integer, required: true}}
      },
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
          "tags" => %{type: :map, required: false},
          "source_id" => %{type: :integer, required: false}
        }
      },
      %{
        name: "document_delete",
        type: :mutate,
        tier: :restricted,
        description: "Delete a document's file and mark it deleted.",
        args: %{"id" => %{type: :integer, required: true}}
      },

      # Reports
      %{
        name: "report_list",
        type: :read,
        tier: :safe,
        description: "List all analysis reports.",
        args: %{}
      },
      %{
        name: "report_get",
        type: :read,
        tier: :safe,
        description: "Fetch a report by ID.",
        args: %{"id" => %{type: :integer, required: true}}
      },

      # Analysis
      %{
        name: "analysis_job_list",
        type: :read,
        tier: :safe,
        description: "List all analysis jobs.",
        args: %{}
      },
      %{
        name: "analysis_queue",
        type: :trigger,
        tier: :safe,
        description: "Queue a document for analysis.",
        args: %{
          "document_id" => %{type: :integer, required: true},
          "provider_id" => %{type: :integer, required: false},
          "intentions" => %{type: :string, required: false}
        }
      },
      %{
        name: "analysis_run_pending",
        type: :trigger,
        tier: :restricted,
        description: "Run up to N pending analysis jobs.",
        args: %{
          "max" => %{type: :integer, required: false, default: 1}
        }
      },
      %{
        name: "analysis_run_job",
        type: :trigger,
        tier: :restricted,
        description: "Run a specific analysis job.",
        args: %{"id" => %{type: :integer, required: true}}
      },

      # Memory
      %{
        name: "memory_list",
        type: :read,
        tier: :safe,
        description: "List all persistent memory entries.",
        args: %{}
      },
      %{
        name: "memory_remember",
        type: :mutate,
        tier: :restricted,
        description: "Save a new memory.",
        args: %{"text" => %{type: :string, required: true}}
      },
      %{
        name: "memory_forget",
        type: :mutate,
        tier: :restricted,
        description: "Delete a memory by ID.",
        args: %{"id" => %{type: :integer, required: true}}
      },

      # Events
      %{
        name: "event_list",
        type: :read,
        tier: :safe,
        description: "List all calendar events.",
        args: %{}
      },
      %{
        name: "event_get",
        type: :read,
        tier: :safe,
        description: "Fetch an event by ID.",
        args: %{"id" => %{type: :integer, required: true}}
      },
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
      %{
        name: "event_delete",
        type: :mutate,
        tier: :restricted,
        description: "Delete a calendar event.",
        args: %{"id" => %{type: :integer, required: true}}
      },

      # MCP servers
      %{
        name: "mcp_server_list",
        type: :read,
        tier: :safe,
        description: "List configured MCP servers.",
        args: %{}
      },
      %{
        name: "mcp_server_get",
        type: :read,
        tier: :safe,
        description: "Fetch an MCP server by ID.",
        args: %{"id" => %{type: :integer, required: true}}
      },
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
      %{
        name: "mcp_server_delete",
        type: :mutate,
        tier: :restricted,
        description: "Delete an MCP server config.",
        args: %{"id" => %{type: :integer, required: true}}
      },

      # Webhooks
      %{
        name: "webhook_list",
        type: :read,
        tier: :safe,
        description: "List all webhooks.",
        args: %{}
      },
      %{
        name: "webhook_get",
        type: :read,
        tier: :safe,
        description: "Fetch a webhook by ID.",
        args: %{"id" => %{type: :integer, required: true}}
      },
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
            enum: ["run_analysis", "ingest_url", "run_scheduler", "shell"]
          },
          "secret" => %{type: :string, required: false},
          "custom_cmd" => %{type: :string, required: false},
          "deliver_to" => %{type: :string, required: false},
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
          "action" => %{type: :string, required: false},
          "secret" => %{type: :string, required: false},
          "custom_cmd" => %{type: :string, required: false},
          "deliver_to" => %{type: :string, required: false},
          "enabled" => %{type: :boolean, required: false}
        }
      },
      %{
        name: "webhook_delete",
        type: :mutate,
        tier: :restricted,
        description: "Delete a webhook.",
        args: %{"id" => %{type: :integer, required: true}}
      },
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
      %{name: "hook_list", type: :read, tier: :safe, description: "List all hooks.", args: %{}},
      %{
        name: "hook_get",
        type: :read,
        tier: :safe,
        description: "Fetch a hook by ID.",
        args: %{"id" => %{type: :integer, required: true}}
      },
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
      %{
        name: "hook_delete",
        type: :mutate,
        tier: :restricted,
        description: "Delete a hook.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "hook_test",
        type: :trigger,
        tier: :safe,
        description: "Test-run a single hook.",
        args: %{
          "id" => %{type: :integer, required: true},
          "payload" => %{type: :map, required: false}
        }
      },
      %{
        name: "hook_event_execute",
        type: :trigger,
        tier: :restricted,
        description: "Fire all hooks bound to an event.",
        args: %{
          "event" => %{type: :string, required: true},
          "payload" => %{type: :map, required: false}
        }
      },

      # Delivery destinations
      %{
        name: "delivery_destination_list",
        type: :read,
        tier: :safe,
        description: "List delivery destinations.",
        args: %{}
      },
      %{
        name: "delivery_destination_get",
        type: :read,
        tier: :safe,
        description: "Fetch a delivery destination by ID.",
        args: %{"id" => %{type: :integer, required: true}}
      },
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
            enum: ["slack", "discord", "telegram", "email", "webhook"]
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
      %{
        name: "delivery_destination_delete",
        type: :mutate,
        tier: :restricted,
        description: "Delete a delivery destination.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "delivery_destination_test",
        type: :trigger,
        tier: :safe,
        description: "Send a test payload to a destination.",
        args: %{
          "id" => %{type: :integer, required: true},
          "payload" => %{type: :map, required: false}
        }
      },

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
      %{
        name: "scheduler_job_list",
        type: :read,
        tier: :safe,
        description: "List scheduler jobs.",
        args: %{}
      },
      %{
        name: "scheduler_job_get",
        type: :read,
        tier: :safe,
        description: "Fetch a scheduler job by ID.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "scheduler_job_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a scheduler job.",
        args: %{
          "job_id" => %{type: :string, required: true},
          "type" => %{type: :string, required: true},
          "cron" => %{type: :string, required: true},
          "enabled" => %{type: :boolean, required: false, default: true},
          "custom_cmd" => %{type: :string, required: false},
          "deliver_to" => %{type: :string, required: false}
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
          "type" => %{type: :string, required: false},
          "cron" => %{type: :string, required: false},
          "enabled" => %{type: :boolean, required: false},
          "custom_cmd" => %{type: :string, required: false},
          "deliver_to" => %{type: :string, required: false}
        }
      },
      %{
        name: "scheduler_job_delete",
        type: :mutate,
        tier: :restricted,
        description: "Delete a scheduler job.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "scheduler_job_run_now",
        type: :trigger,
        tier: :restricted,
        description: "Run a scheduler job immediately.",
        args: %{"id" => %{type: :integer, required: true}}
      },

      # Integrations
      %{
        name: "integration_list",
        type: :read,
        tier: :safe,
        description: "List service integrations.",
        args: %{}
      },
      %{
        name: "integration_get",
        type: :read,
        tier: :safe,
        description: "Fetch an integration by ID.",
        args: %{"id" => %{type: :integer, required: true}}
      },
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
      %{
        name: "integration_delete",
        type: :mutate,
        tier: :restricted,
        description: "Delete an integration.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "integration_poll",
        type: :trigger,
        tier: :safe,
        description: "Poll a single integration.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "integration_poll_all",
        type: :trigger,
        tier: :safe,
        description: "Poll every enabled integration.",
        args: %{}
      },
      %{
        name: "integration_run_list",
        type: :read,
        tier: :safe,
        description: "List integration run history.",
        args: %{
          "integration_id" => %{type: :integer, required: false}
        }
      },

      # Chat
      %{
        name: "chat_send",
        type: :trigger,
        tier: :safe,
        description: "Send a prompt to the active provider (async).",
        args: %{
          "prompt" => %{type: :string, required: true},
          "session_id" => %{type: :string, required: false, default: "default"}
        }
      },
      %{
        name: "chat_messages",
        type: :read,
        tier: :safe,
        description: "Get chat session message history.",
        args: %{
          "session_id" => %{type: :string, required: false, default: "default"}
        }
      },
      %{
        name: "chat_clear",
        type: :mutate,
        tier: :safe,
        description: "Clear a chat session's history.",
        args: %{
          "session_id" => %{type: :string, required: false, default: "default"}
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
      %{
        name: "runtime_status",
        type: :read,
        tier: :safe,
        description: "Snapshot of process and system state.",
        args: %{}
      }
    ]
end
