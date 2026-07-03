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
    Calendar,
    Integrations,
    PolicyEngine,
    Skills,
    Wallets
  }

  alias BusterClaw.Commands.Catalog

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
    # These atoms are minted at COMPILE time (the `for` runs over a hardcoded
    # literal list during module compilation), so no runtime input can reach
    # them — UnsafeToAtom is a false positive here.
    # credo:disable-for-lines:5 Credo.Check.Warning.UnsafeToAtom
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

  # ---------------------------------------------------------------------
  # Command surface. Every command's implementation lives in a per-domain
  # `BusterClaw.Commands.*` module; these delegates keep each command
  # callable on this facade so `call/2` dispatch (apply/3) still resolves
  # it here, preserving the single policy/rate-limit choke point.
  # ---------------------------------------------------------------------

  # Documents
  defdelegate document_list(args \\ %{}), to: BusterClaw.Commands.Documents
  defdelegate document_get(args), to: BusterClaw.Commands.Documents
  defdelegate document_read(args), to: BusterClaw.Commands.Documents
  defdelegate document_save(args), to: BusterClaw.Commands.Documents
  defdelegate document_delete(args), to: BusterClaw.Commands.Documents
  # Integrations (extras; CRUD comes from the auto-loop above)
  defdelegate integration_poll(args), to: BusterClaw.Commands.Integrations
  defdelegate integration_poll_all(args \\ %{}), to: BusterClaw.Commands.Integrations
  defdelegate integration_run_list(args), to: BusterClaw.Commands.Integrations
  # Wallets (extras; CRUD comes from the auto-loop above)
  defdelegate wallet_list_transactions(args), to: BusterClaw.Commands.Wallets
  defdelegate wallet_add_transaction(args), to: BusterClaw.Commands.Wallets
  defdelegate wallet_set_budget(args), to: BusterClaw.Commands.Wallets
  defdelegate wallet_budget_summary(args), to: BusterClaw.Commands.Wallets
  defdelegate wallet_feed_list(args), to: BusterClaw.Commands.Wallets
  defdelegate wallet_feed_create(args), to: BusterClaw.Commands.Wallets
  defdelegate wallet_feed_update(args), to: BusterClaw.Commands.Wallets
  defdelegate wallet_feed_delete(args), to: BusterClaw.Commands.Wallets
  defdelegate wallet_poll(args), to: BusterClaw.Commands.Wallets
  # Google Workspace
  defdelegate google_account_list(args \\ %{}), to: BusterClaw.Commands.Google
  defdelegate google_account_get(args), to: BusterClaw.Commands.Google
  defdelegate google_account_create(args), to: BusterClaw.Commands.Google
  defdelegate google_account_update(args), to: BusterClaw.Commands.Google
  defdelegate google_account_delete(args), to: BusterClaw.Commands.Google
  defdelegate gmail_label_list(args \\ %{}), to: BusterClaw.Commands.Google
  defdelegate gmail_search(args), to: BusterClaw.Commands.Google
  defdelegate gmail_read(args), to: BusterClaw.Commands.Google
  defdelegate gmail_sync(args), to: BusterClaw.Commands.Google
  defdelegate gmail_draft_create(args), to: BusterClaw.Commands.Google
  defdelegate gmail_send(args), to: BusterClaw.Commands.Google
  defdelegate google_calendar_sync(args), to: BusterClaw.Commands.Google
  defdelegate gmail_modify(args), to: BusterClaw.Commands.Google
  defdelegate gmail_trash(args), to: BusterClaw.Commands.Google
  defdelegate gmail_delete(args), to: BusterClaw.Commands.Google
  defdelegate gcal_event_create(args), to: BusterClaw.Commands.Google
  defdelegate gcal_event_update(args), to: BusterClaw.Commands.Google
  defdelegate gcal_event_delete(args), to: BusterClaw.Commands.Google
  defdelegate tasks_list(args \\ %{}), to: BusterClaw.Commands.Google
  defdelegate tasks_get(args), to: BusterClaw.Commands.Google
  defdelegate tasks_create(args), to: BusterClaw.Commands.Google
  defdelegate tasks_update(args), to: BusterClaw.Commands.Google
  defdelegate tasks_delete(args), to: BusterClaw.Commands.Google
  defdelegate drive_list(args \\ %{}), to: BusterClaw.Commands.Google
  defdelegate drive_get(args), to: BusterClaw.Commands.Google
  defdelegate drive_download(args), to: BusterClaw.Commands.Google
  defdelegate drive_export(args), to: BusterClaw.Commands.Google
  defdelegate drive_folder_create(args), to: BusterClaw.Commands.Google
  defdelegate drive_upload(args), to: BusterClaw.Commands.Google
  defdelegate drive_update(args), to: BusterClaw.Commands.Google
  defdelegate drive_copy(args), to: BusterClaw.Commands.Google
  defdelegate drive_share(args), to: BusterClaw.Commands.Google
  defdelegate drive_delete(args), to: BusterClaw.Commands.Google
  defdelegate docs_get(args), to: BusterClaw.Commands.Google
  defdelegate docs_create(args), to: BusterClaw.Commands.Google
  defdelegate docs_batch_update(args), to: BusterClaw.Commands.Google
  defdelegate sheets_get(args), to: BusterClaw.Commands.Google
  defdelegate sheets_get_values(args), to: BusterClaw.Commands.Google
  defdelegate sheets_create(args), to: BusterClaw.Commands.Google
  defdelegate sheets_update_values(args), to: BusterClaw.Commands.Google
  defdelegate sheets_append_values(args), to: BusterClaw.Commands.Google
  defdelegate sheets_clear_values(args), to: BusterClaw.Commands.Google
  defdelegate sheets_batch_update(args), to: BusterClaw.Commands.Google
  defdelegate slides_get(args), to: BusterClaw.Commands.Google
  defdelegate slides_create(args), to: BusterClaw.Commands.Google
  defdelegate slides_batch_update(args), to: BusterClaw.Commands.Google
  defdelegate contacts_list(args \\ %{}), to: BusterClaw.Commands.Google
  defdelegate contacts_search(args), to: BusterClaw.Commands.Google
  defdelegate contacts_get(args), to: BusterClaw.Commands.Google
  defdelegate contacts_create(args), to: BusterClaw.Commands.Google
  defdelegate contacts_update(args), to: BusterClaw.Commands.Google
  defdelegate contacts_delete(args), to: BusterClaw.Commands.Google
  # Web (search, browser, bookmarks)
  defdelegate web_search(args), to: BusterClaw.Commands.Web
  defdelegate browser_fetch(args), to: BusterClaw.Commands.Web
  defdelegate browser_download(args), to: BusterClaw.Commands.Web
  defdelegate browser_screenshot(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_current(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_read(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_capture_page(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_tabs(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_navigate(args), to: BusterClaw.Commands.Web
  defdelegate browser_open_tab(args), to: BusterClaw.Commands.Web
  defdelegate bookmark_add(args), to: BusterClaw.Commands.Web
  defdelegate bookmark_list(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate bookmark_remove(args), to: BusterClaw.Commands.Web
  defdelegate bookmark_export(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate bookmark_import(args), to: BusterClaw.Commands.Web
  defdelegate history_search(args), to: BusterClaw.Commands.Web
  defdelegate history_recent(args \\ %{}), to: BusterClaw.Commands.Web
  # Finance
  defdelegate finance_filings(args), to: BusterClaw.Commands.Finance
  defdelegate finance_fundamentals(args), to: BusterClaw.Commands.Finance
  defdelegate finance_quote(args), to: BusterClaw.Commands.Finance
  defdelegate finance_news(args), to: BusterClaw.Commands.Finance
  # Memory
  defdelegate memory_search(args), to: BusterClaw.Commands.Memory
  # Skills
  defdelegate skill_analyze(args), to: BusterClaw.Commands.Skills
  defdelegate skill_suggestions(args), to: BusterClaw.Commands.Skills
  defdelegate skill_suggestion_approve(args), to: BusterClaw.Commands.Skills
  defdelegate skill_suggestion_reject(args), to: BusterClaw.Commands.Skills
  # Orchestration (runtime, terminal, shift)
  defdelegate runtime_status(args \\ %{}), to: BusterClaw.Commands.Orchestration
  defdelegate activity_report(args \\ %{}), to: BusterClaw.Commands.Orchestration
  defdelegate terminal_tab_open(args \\ %{}), to: BusterClaw.Commands.Orchestration
  defdelegate shift_status(args \\ %{}), to: BusterClaw.Commands.Orchestration
  defdelegate shift_start(args \\ %{}), to: BusterClaw.Commands.Orchestration
  defdelegate shift_stop(args \\ %{}), to: BusterClaw.Commands.Orchestration
  defdelegate shift_assignment_start(args \\ %{}), to: BusterClaw.Commands.Orchestration
  defdelegate shift_assignment_status(args \\ %{}), to: BusterClaw.Commands.Orchestration
  defdelegate shift_assignment_stop(args \\ %{}), to: BusterClaw.Commands.Orchestration
  # Dispatch queue
  defdelegate dispatch_list(args \\ %{}), to: BusterClaw.Commands.Dispatch
  defdelegate dispatch_show(args), to: BusterClaw.Commands.Dispatch
  defdelegate dispatch_claim(args \\ %{}), to: BusterClaw.Commands.Dispatch
  defdelegate dispatch_done(args), to: BusterClaw.Commands.Dispatch
  defdelegate dispatch_block(args), to: BusterClaw.Commands.Dispatch
  defdelegate dispatch_enqueue(args), to: BusterClaw.Commands.Dispatch
  defdelegate dispatch_strategy(args), to: BusterClaw.Commands.Dispatch
  defdelegate dispatch_reply(args), to: BusterClaw.Commands.Dispatch
  # Jobs
  defdelegate job_list(args \\ %{}), to: BusterClaw.Commands.Jobs
  defdelegate job_show(args), to: BusterClaw.Commands.Jobs
end
