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

  alias BusterClaw.Skills.Suggestions

  alias BusterClaw.{
    Analyzer,
    Browser,
    Calendar,
    Dispatch,
    Finance,
    Google,
    Integrations,
    Jobs,
    Library,
    Memory,
    Orchestration,
    PolicyEngine,
    Search,
    Skills,
    TerminalWorkspace,
    Wallets
  }

  alias BusterClaw.Runtime.Status
  alias BusterClaw.Commands.Catalog
  alias BusterClaw.Commands.Google

  import BusterClaw.Commands.Helpers

  # The catalog (its declarative data lives in `BusterClaw.Commands.Catalog`) is
  # constant, but local functions can't be called from a module attribute during
  # compilation, so build it once at runtime and cache it — plus the derived
  # name-index and safe subset — in :persistent_term for O(1) reuse instead of
  # rebuilding/rescanning a fresh list on every call.
  defp catalog do
    case :persistent_term.get({__MODULE__, :catalog}, nil) do
      nil ->
        built = Catalog.entries()
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

    # Native commands win. A name that misses the catalog may resolve to an
    # enabled composition skill (a runtime-added, file-defined ordered list of
    # native commands). Unknown names fall back to native dispatch, which returns
    # {:error, :unknown_command}.
    if has_command?(name) do
      call_native(name, args, caller)
    else
      case Skills.fetch(name) do
        {:ok, skill} -> call_skill(skill, args, caller)
        :error -> call_native(name, args, caller)
      end
    end
  end

  defp call_native(name, args, caller) do
    request = %{
      name: name,
      caller: caller,
      tier: command_tier(name),
      gated: command_gated?(name),
      source: :native
    }

    case PolicyEngine.check(request) do
      :allow ->
        rate_limited(name, args, caller)

      decision ->
        refuse(name, args, caller, decision)
    end
  end

  # Policy authorizes *what* may run; the rate limiter bounds *how often*. Checked
  # only for calls policy already allowed, so refusals don't consume quota.
  defp rate_limited(name, args, caller) do
    case BusterClaw.RateLimiter.check(caller, name) do
      :ok ->
        result = dispatch(name, args)
        audit_invoke(name, args, caller, result)
        result

      {:error, :rate_limited} ->
        record(
          :security_block,
          "Rate limit exceeded: #{name} for #{caller} caller",
          %{command: name, args: args, caller: caller, reason: :rate_limited}
        )

        {:error, :rate_limited}
    end
  end

  # A composition skill owns no new capability: every step is dispatched back
  # through `call/2` as the *same* caller, so the policy check + catalog tier/gated
  # rules apply per step and the skill can never exceed its invoker's trust. Steps
  # go through `call/2`, never `apply/3` — the load-bearing security rule (see
  # daily-growth/research/s0.5-dynamic-skill-threat-model.md). The skill name
  # itself is also policy-checked here (declared `tier` + operator deny rules).
  defp call_skill(skill, args, caller) do
    request = %{
      name: skill.name,
      caller: caller,
      tier: skill.tier,
      gated: false,
      source: :composition
    }

    case PolicyEngine.check(request) do
      :allow ->
        record(
          :command_invoke,
          "skill #{skill.name} (#{length(skill.steps)} steps)",
          %{skill: skill.name, caller: caller, tier: skill.tier, steps: length(skill.steps)}
        )

        run_steps(skill, args, caller)

      decision ->
        refuse(skill.name, args, caller, decision)
    end
  end

  # A baseline gate (`{:confirm, _}`) surfaces the action for human approval via
  # `Sentinel.Pending` and returns `:requires_confirmation`. An operator `deny`
  # (`{:block, _}`) is a hard refusal — there is nothing to confirm — and returns
  # `:policy_blocked`. Both land on the Sentinel feed as a critical security block.
  defp refuse(name, args, caller, {:confirm, meta}) do
    BusterClaw.Sentinel.Pending.record(name, args, caller)

    record(
      :security_block,
      "Refused #{name} for #{caller} caller",
      refusal_meta(name, args, meta)
    )

    {:error, :requires_confirmation}
  end

  defp refuse(name, args, caller, {:block, meta}) do
    record(
      :security_block,
      "Blocked #{name} for #{caller} caller",
      refusal_meta(name, args, meta)
    )

    {:error, :policy_blocked}
  end

  # Keep `command`/`args` in the recorded metadata (the audit feed + tests key off
  # them) and carry the policy decision's own fields (reason, rule source).
  defp refusal_meta(name, args, meta) do
    meta |> Map.put(:command, name) |> Map.put(:args, args)
  end

  # Run a skill's steps in order, threading each step's args through the skill's
  # invocation args (`$name`) and the previous step's value (`$prior`). Steps must
  # be native commands (no skill-to-skill recursion in this slice). Stops at the
  # first failing step. Returns `{:ok, results}` (a list of `%{command, result}`)
  # or `{:error, {:step_failed, command, reason}}`.
  defp run_steps(%{steps: steps}, args, caller) do
    steps
    |> Enum.reduce_while({[], nil}, fn step, {acc, prior} ->
      command = step["command"]
      step_args = resolve_args(Map.get(step, "args", %{}), args, prior)

      cond do
        not has_command?(command) ->
          {:halt, {:error, {:step_failed, command, :unknown_command}}}

        true ->
          case call(command, step_args, caller: caller) do
            {:ok, value} -> {:cont, {[%{command: command, result: value} | acc], value}}
            {:error, reason} -> {:halt, {:error, {:step_failed, command, reason}}}
          end
      end
    end)
    |> case do
      {:error, _reason} = err -> err
      {results, _prior} -> {:ok, Enum.reverse(results)}
    end
  end

  defp resolve_args(step_args, args, prior) when is_map(step_args) do
    Map.new(step_args, fn {key, value} -> {key, resolve_value(value, args, prior)} end)
  end

  defp resolve_args(_step_args, _args, _prior), do: %{}

  # A value that is exactly "$prior" passes the previous result through unchanged
  # (any type). Otherwise tokens are interpolated into strings; non-string values
  # pass through untouched.
  defp resolve_value("$prior", _args, prior), do: prior

  defp resolve_value(value, args, prior) when is_binary(value) do
    value
    |> replace_prior(prior)
    |> replace_args(args)
  end

  defp resolve_value(value, _args, _prior), do: value

  defp replace_prior(value, prior) when is_binary(prior),
    do: String.replace(value, "$prior", prior)

  defp replace_prior(value, _prior), do: value

  defp replace_args(value, args) do
    Regex.replace(~r/\$([a-zA-Z_][a-zA-Z0-9_]*)/, value, fn whole, name ->
      case Map.fetch(args, name) do
        {:ok, v} when is_binary(v) -> v
        {:ok, v} when is_number(v) or is_atom(v) -> to_string(v)
        # Non-scalar (map/list) or missing arg: leave the token literal rather
        # than crash interpolation.
        _ -> whole
      end
    end)
  end

  # Feed the Sentinel audit/notify spine for a *dispatched* command (refusals are
  # recorded in `refuse/4`). Only consequential (mutating/triggering) commands are
  # recorded — pure reads are skipped to keep the audit log signal-rich.
  defp audit_invoke(name, args, caller, result) do
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

  @doc "Return the native command catalog as a list of maps."
  def list_commands, do: catalog()

  @doc """
  Return enabled composition skills as catalog-style entries (marked
  `source: :composition`). A skill whose name collides with a native command is
  dropped — native always wins. Kept separate from `list_commands/0` so the native
  catalog's invariant (every entry is a dispatchable function) holds.
  """
  def list_skills do
    native_names = MapSet.new(catalog(), & &1.name)
    Enum.reject(Skills.catalog_entries(), &MapSet.member?(native_names, &1.name))
  end

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

  # Authorization (the gated/tier baseline + operator deny rules) now lives in
  # `BusterClaw.PolicyEngine.check/1`, evaluated at the `call/2` choke point for
  # native commands and composition-skill steps alike.

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
        {:integration, Integrations, :integration, :integrations},
        {:wallet, Wallets, :wallet, :wallets}
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
  # Wallets (ledger transactions + budgets; CRUD comes from the auto-loop)
  # -----------------------------------------------------------------------

  def wallet_list_transactions(%{"wallet_id" => wallet_id}) do
    with_resource(Wallets, :get_wallet!, wallet_id, fn wallet ->
      {:ok, Wallets.list_transactions(wallet)}
    end)
  end

  def wallet_add_transaction(%{"wallet_id" => wallet_id} = args) do
    with_resource(Wallets, :get_wallet!, wallet_id, fn wallet ->
      Wallets.add_transaction(wallet, Map.delete(args, "wallet_id"))
    end)
  end

  def wallet_set_budget(%{"wallet_id" => wallet_id} = args) do
    with_resource(Wallets, :get_wallet!, wallet_id, fn wallet ->
      Wallets.upsert_budget(wallet, Map.delete(args, "wallet_id"))
    end)
  end

  def wallet_budget_summary(%{"wallet_id" => wallet_id, "month" => month}) do
    with_resource(Wallets, :get_wallet!, wallet_id, fn wallet ->
      {:ok, Wallets.budget_summary(wallet, month)}
    end)
  end

  def wallet_feed_list(%{"wallet_id" => wallet_id}) do
    with_resource(Wallets, :get_wallet!, wallet_id, fn wallet ->
      {:ok, Wallets.list_feeds(wallet)}
    end)
  end

  def wallet_feed_create(%{"wallet_id" => wallet_id} = args) do
    with_resource(Wallets, :get_wallet!, wallet_id, fn wallet ->
      Wallets.create_feed(wallet, Map.delete(args, "wallet_id"))
    end)
  end

  def wallet_feed_update(%{"id" => id} = args) do
    with_resource(Wallets, :get_feed!, id, fn feed ->
      Wallets.update_feed(feed, Map.delete(args, "id"))
    end)
  end

  def wallet_feed_delete(%{"id" => id}) do
    with_resource(Wallets, :get_feed!, id, fn feed ->
      Wallets.delete_feed(feed)
    end)
  end

  def wallet_poll(%{"id" => id}) do
    with_resource(Wallets, :get_wallet!, id, fn wallet ->
      {:ok, %{results: length(Wallets.poll_wallet_feeds(wallet))}}
    end)
  end

  # -----------------------------------------------------------------------
  # Google Workspace (account CRUD, Gmail, Calendar, Tasks, Drive,
  # Docs/Sheets/Slides, Contacts). Implementations live in
  # `BusterClaw.Commands.Google`; dispatch still funnels through `call/2`.
  # -----------------------------------------------------------------------

  defdelegate contacts_create(args), to: Google
  defdelegate contacts_delete(args), to: Google
  defdelegate contacts_get(args), to: Google
  defdelegate contacts_list(args \\ %{}), to: Google
  defdelegate contacts_search(args), to: Google
  defdelegate contacts_update(args), to: Google
  defdelegate docs_batch_update(args), to: Google
  defdelegate docs_create(args), to: Google
  defdelegate docs_get(args), to: Google
  defdelegate drive_copy(args), to: Google
  defdelegate drive_delete(args), to: Google
  defdelegate drive_download(args), to: Google
  defdelegate drive_export(args), to: Google
  defdelegate drive_folder_create(args), to: Google
  defdelegate drive_get(args), to: Google
  defdelegate drive_list(args \\ %{}), to: Google
  defdelegate drive_share(args), to: Google
  defdelegate drive_update(args), to: Google
  defdelegate drive_upload(args), to: Google
  defdelegate gcal_event_create(args), to: Google
  defdelegate gcal_event_delete(args), to: Google
  defdelegate gcal_event_update(args), to: Google
  defdelegate gmail_delete(args), to: Google
  defdelegate gmail_draft_create(args), to: Google
  defdelegate gmail_label_list(args \\ %{}), to: Google
  defdelegate gmail_modify(args), to: Google
  defdelegate gmail_read(args), to: Google
  defdelegate gmail_search(args), to: Google
  defdelegate gmail_send(args), to: Google
  defdelegate gmail_sync(args), to: Google
  defdelegate gmail_trash(args), to: Google
  defdelegate google_account_create(args), to: Google
  defdelegate google_account_delete(args), to: Google
  defdelegate google_account_get(args), to: Google
  defdelegate google_account_list(args \\ %{}), to: Google
  defdelegate google_account_update(args), to: Google
  defdelegate google_calendar_sync(args), to: Google
  defdelegate sheets_append_values(args), to: Google
  defdelegate sheets_batch_update(args), to: Google
  defdelegate sheets_clear_values(args), to: Google
  defdelegate sheets_create(args), to: Google
  defdelegate sheets_get(args), to: Google
  defdelegate sheets_get_values(args), to: Google
  defdelegate sheets_update_values(args), to: Google
  defdelegate slides_batch_update(args), to: Google
  defdelegate slides_create(args), to: Google
  defdelegate slides_get(args), to: Google
  defdelegate tasks_create(args), to: Google
  defdelegate tasks_delete(args), to: Google
  defdelegate tasks_get(args), to: Google
  defdelegate tasks_list(args \\ %{}), to: Google
  defdelegate tasks_update(args), to: Google
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

  def browser_download(%{"url" => url} = args) when is_binary(url) and url != "" do
    with {:ok, dl} <- Browser.download(url) do
      filename = sanitize_download_name(Map.get(args, "filename") || dl.filename)
      rel = Path.join(["downloads", Date.to_iso8601(BusterClaw.LocalTime.today()), filename])
      abs = resolve_workspace_path(rel)

      with :ok <- File.mkdir_p(Path.dirname(abs)),
           :ok <- File.write(abs, dl.body) do
        {:ok,
         %{
           path: rel,
           absolute_path: abs,
           url: url,
           content_type: dl.content_type,
           bytes: byte_size(dl.body)
         }}
      end
    end
  end

  def browser_download(_args), do: {:error, :missing_url}

  def browser_screenshot(_args \\ %{}) do
    BusterClaw.Browser.Capture.request()
  end

  def bookmark_add(args) do
    url = Map.get(args, "url")
    label = Map.get(args, "label")
    tags = List.wrap(Map.get(args, "tags", []))

    if url in [nil, ""] do
      {:error, :missing_url}
    else
      BusterClaw.Bookmarks.add(url, label, tags)
      {:ok, %{url: url, label: label || url, tags: BusterClaw.Bookmarks.normalize_tags(tags)}}
    end
  end

  def bookmark_list(args \\ %{}) do
    tag = blank_to_nil(Map.get(args, "tag"))
    opts = if tag, do: [tag: tag], else: []
    {:ok, BusterClaw.Bookmarks.list(opts)}
  end

  def bookmark_remove(%{"url" => url}) do
    BusterClaw.Bookmarks.remove(url)
    {:ok, %{removed: url}}
  end

  def bookmark_remove(_args), do: {:error, :missing_url}

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

  def memory_search(%{"query" => query} = args) when is_binary(query) do
    limit = normalize_limit(Map.get(args, "limit"))

    case Memory.search(query, limit: limit) do
      {:ok, summaries} -> {:ok, Enum.map(summaries, &memory_view/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  def memory_search(_args), do: {:error, :empty_query}

  defp normalize_limit(n) when is_integer(n) and n > 0, do: min(n, 100)

  defp normalize_limit(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} when i > 0 -> min(i, 100)
      _ -> 20
    end
  end

  defp normalize_limit(_), do: 20

  defp memory_view(summary) do
    %{
      goal: summary.goal,
      outcome: summary.outcome,
      detail: summary.detail,
      agent: summary.agent,
      provenance: summary.provenance,
      source: summary.source,
      at: summary.inserted_at
    }
  end

  def skill_analyze(args) do
    # Only override the configured threshold when the caller explicitly sets one.
    opts =
      case Map.get(args, "min_occurrences") do
        nil -> []
        raw -> [analyzer_min_occurrences: to_int(raw)]
      end

    {:ok, Analyzer.scan(opts)}
  end

  def skill_suggestions(args) do
    opts =
      [limit: normalize_limit(Map.get(args, "limit"))]
      |> maybe_put(:status, Map.get(args, "status"))

    {:ok, Enum.map(Suggestions.list(opts), &suggestion_view/1)}
  end

  def skill_suggestion_approve(%{"id" => id}) do
    case Suggestions.approve(to_int(id)) do
      {:ok, name} -> {:ok, %{approved: name}}
      {:error, reason} -> {:error, reason}
    end
  end

  def skill_suggestion_approve(_args), do: {:error, :missing_id}

  def skill_suggestion_reject(%{"id" => id}) do
    case Suggestions.reject(to_int(id)) do
      {:ok, _} -> {:ok, %{rejected: to_int(id)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def skill_suggestion_reject(_args), do: {:error, :missing_id}

  defp suggestion_view(s) do
    %{
      id: s.id,
      name: s.name,
      signature: s.signature,
      description: s.description,
      occurrences: s.occurrences,
      status: s.status
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      _ -> 0
    end
  end

  defp to_int(_), do: 0

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
  Set a queued item's execution strategy (`single` | `swarm`). `swarm` opts the
  item into the Phase 4 coordinator (parallel fan-out); only a still-queued item
  may be re-targeted.
  """
  def dispatch_strategy(%{"id" => id} = args) do
    with_resource(Dispatch, :get_item!, id, fn item ->
      case blank_to_nil(Map.get(args, "strategy")) do
        s when s in ["single", "swarm"] -> Dispatch.set_strategy(item, s)
        _ -> {:error, :bad_strategy}
      end
    end)
  end

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

    Google.with_google_account(selector, fn account ->
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

  defp filter_by_job(items, nil), do: items
  defp filter_by_job(items, job), do: Enum.filter(items, &(&1.recommended_role_key == job))
end
