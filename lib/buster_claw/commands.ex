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

  - `list_commands/0` returns the catalog (used by `GET /api/commands` and CLI `--help`).
  - `call/2` dispatches by string command name (used by the HTTP and CLI frontends).
  - Direct calls (`Commands.document_list(%{})`) work for internal callers.
  """

  alias BusterClaw.{
    Calendar,
    Integrations,
    PolicyEngine,
    Skills
  }

  alias BusterClaw.Commands.Catalog

  import BusterClaw.Commands.Helpers

  # The catalog (its declarative data lives in `BusterClaw.Commands.Catalog`) is
  # constant, but local functions can't be called from a module attribute during
  # compilation, so it is built once at runtime and cached — plus the derived
  # name-index and safe subset — in :persistent_term for O(1) reuse instead of
  # rebuilding/rescanning a fresh list on every dispatch.
  #
  # Except in dev, where that cache outlives code reloading. Phoenix recompiles
  # the catalog modules on the next request, but nothing invalidates the cached
  # list, so a newly-added command answers `unknown_command` until the server is
  # restarted — which cost time on 07-28 adding a new command and would
  # cost it again for whoever adds the next one. Dev therefore rebuilds on every
  # call: a few hundred literal maps, far cheaper than the confusion.
  #
  # Cache invalidation can't be done properly here on the cheap. The entries are
  # spread across a dozen `Catalog.*` modules, so keying the cache on any one
  # module's identity would miss edits to the others — and "mostly invalidates"
  # is worse than either honest option.
  #
  # Read at RUNTIME, not via compile_env. The compile-time version turned any
  # stale _build into a hard boot failure ("different value set for key
  # :memoize_catalog during runtime compared to compile time"), which is a
  # miserable trade for what is only a dev convenience — it broke the operator's
  # server on 07-28. One ETS lookup per dispatch is nothing next to the work it
  # guards.
  defp memoize_catalog?, do: Application.get_env(:buster_claw, :memoize_catalog, true)

  defp build_catalog do
    entries = Catalog.entries()

    %{
      catalog: entries,
      by_name: Map.new(entries, &{&1.name, &1}),
      safe_commands: Enum.filter(entries, &(&1.tier == :safe))
    }
  end

  defp catalog_part(key) do
    if memoize_catalog?() do
      case :persistent_term.get({__MODULE__, key}, nil) do
        nil ->
          built = build_catalog()

          Enum.each(built, fn {part, value} -> :persistent_term.put({__MODULE__, part}, value) end)

          Map.fetch!(built, key)

        value ->
          value
      end
    else
      build_catalog() |> Map.fetch!(key)
    end
  end

  defp catalog, do: catalog_part(:catalog)
  defp by_name, do: catalog_part(:by_name)
  defp safe_catalog, do: catalog_part(:safe_commands)

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
        result = dispatch(name, args, caller)
        audit_invoke(name, args, caller, result)
        surface_confirmation(name, args, caller, result)
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
    # Pending is the one Sentinel sink that does not go through `record/3`, so it
    # gets the catalog-aware scrub explicitly. Its own `redact/1` is a generic
    # key-name net and stays as the second layer; this is the command-specific
    # knowledge that only lives here.
    BusterClaw.Sentinel.Pending.record(name, scrub_args(name, args), caller)

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

      if has_command?(command) do
        case call(command, step_args, caller: caller) do
          {:ok, value} -> {:cont, {[%{command: command, result: value} | acc], value}}
          {:error, reason} -> {:halt, {:error, {:step_failed, command, reason}}}
        end
      else
        {:halt, {:error, {:step_failed, command, :unknown_command}}}
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

  # A command that ran and decided for ITSELF that it needs the operator's say-so.
  #
  # `refuse/4` covers the refusals `PolicyEngine` makes before dispatch — by tier,
  # by the gated set, by an operator deny rule. It cannot cover a rule that
  # depends on the *data being touched*, because that is only knowable once the
  # command has loaded it. `D6` of SKETCH_ROADMAP is the first of those: deleting
  # the model's own mark is free, deleting the operator's asks.
  #
  # Without this the promise would have been hollow. The command returned
  # `:requires_confirmation` and **nothing was recorded** — no `Sentinel.Pending`
  # entry, no security event — so "gated, surfaced for approval" meant a string
  # the caller saw and the operator never did. A refusal nobody can see is a
  # refusal that may as well have been a silent no-op, which is the exact failure
  # the Sentinel spine exists to prevent.
  #
  # Deliberately generic rather than sketch-specific: any command may reach this
  # conclusion, and the invariant worth holding is that **however a call comes to
  # need confirmation, it lands in the same two places.**
  defp surface_confirmation(name, args, caller, {:error, :requires_confirmation}) do
    BusterClaw.Sentinel.Pending.record(name, scrub_args(name, args), caller)

    record(
      :security_block,
      "Refused #{name} for #{caller} caller",
      %{
        command: name,
        args: args,
        caller: caller,
        tier: command_tier(name),
        policy: :command,
        reason: "the command refused this target for this caller"
      }
    )

    :ok
  end

  defp surface_confirmation(_name, _args, _caller, _result), do: :ok

  # Feed the Sentinel audit/notify spine for a *dispatched* command (refusals are
  # recorded in `refuse/4`). Only consequential (mutating/triggering) commands are
  # recorded — pure reads are skipped to keep the audit log signal-rich.
  defp audit_invoke(name, args, caller, result) do
    if command_type(name) in [:mutate, :trigger] do
      outcome = if match?({:ok, _}, result), do: "ok", else: "error"

      record(
        :command_invoke,
        "#{name} (#{outcome})",
        %{
          command: name,
          args: args,
          caller: caller,
          tier: command_tier(name),
          outcome: outcome
        }
      )
    end

    :ok
  end

  # Sentinel's redaction is key-name + value-shape based, which can't see a
  # secret nested inside a command's own payload under a generic key. Reduce
  # those to lengths before the args reach any Sentinel sink.
  #
  # Deliberately per-command rather than widening Sentinel's `@sensitive_fragments`
  # with a generic key like "value": that fragment appears all over the catalog on
  # arguments that are not secrets, and over-redacting them would gut the audit
  # feed's usefulness to hide three commands' worth of real risk.
  #
  # `browser_flow`'s `fill` step values (operator call, 07-18).
  defp scrub_args("browser_flow", %{"steps" => steps} = args) when is_list(steps),
    do: Map.put(args, "steps", BusterClaw.Commands.Web.redact_flow_steps(steps))

  # `browser_secret_put`'s whole payload is a credential, carried under the
  # generic key "value" that neither Sentinel's key-name list nor its value-shape
  # masks can catch — an ordinary site password is short, unprefixed and not
  # Luhn-valid, so it matched none of them and landed in `security_events` in the
  # clear. That is the exact opposite of `BrowserControl.Secret`'s promise that the
  # value "never appears in a dump of the database" (Clinch Phase 0).
  defp scrub_args("browser_secret_put", %{"value" => value} = args) when is_binary(value),
    do: Map.put(args, "value", "<#{byte_size(value)} bytes>")

  # A note is the operator's private writing. The audit row records that a note
  # changed, which one, and how much — never what it says. (Home Activity + Notes
  # Phase 4: "note path and revision but not entire private note bodies".)
  defp scrub_args(name, %{"body" => body} = args)
       when name in ["note_create", "note_save"] and is_binary(body),
       do: Map.put(args, "body", "<#{byte_size(body)} bytes>")

  defp scrub_args(_name, args), do: args

  # Every Sentinel sink in this module goes through `record/3`, so the scrub lives
  # here rather than at each call site. It used to sit inline in `audit_invoke`
  # only — which left the rate-limit block, both refusal paths and their metadata
  # carrying raw args, so a credential refused for an untrusted caller leaked even
  # though the same credential accepted for a trusted one did not. One door.
  defp scrub_meta(%{command: name, args: args} = meta) when is_binary(name) and is_map(args),
    do: %{meta | args: scrub_args(name, args)}

  defp scrub_meta(meta), do: meta

  # Sentinel persistence + broadcast is on the hot command path. In tests it must
  # run inline so it shares the request's Ecto sandbox connection (tests read the
  # audit rows back synchronously). In dev/prod it is offloaded to a Task so the
  # caller doesn't block on a DB insert + PubSub broadcast.
  defp record(category, message, meta) do
    meta = scrub_meta(meta)

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

  # A command whose behaviour depends on WHO is calling declares that by defining
  # **arity 2**, and gets the caller as its second argument. Everything else keeps
  # the one-argument shape it has always had.
  #
  # Until 08-16 no command had ever known its caller: authorization was entirely
  # the `PolicyEngine`'s, decided from the command's *name* before it ran. That is
  # still the right default and most of the catalog needs nothing else.
  #
  # `D6` of SKETCH_ROADMAP is the first rule that cannot be expressed that way.
  # "The model may delete what the model drew, and asking about the operator's
  # marks" is a decision about the *data being touched*, not about the verb — the
  # same call is fine or gated depending on which element it names. No tier can
  # encode that, so the command itself has to be told.
  #
  # Opt-in by arity rather than a registry or a magic `_caller` key in the args
  # map: a registry goes stale silently, and a reserved key is invisible in the
  # signature and would ride along into every command that never asked for it.
  # This way "this command's answer depends on who asked" is legible where it
  # matters — in the function head.
  defp dispatch(name, args, caller) do
    if has_command?(name) do
      fun = String.to_existing_atom(name)
      normalized = normalize_args(args)

      if function_exported?(__MODULE__, fun, 2) do
        apply(__MODULE__, fun, [normalized, caller])
      else
        apply(__MODULE__, fun, [normalized])
      end
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
        {:integration, Integrations, :integration, :integrations}
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
  # Journal (the Activity record)

  defdelegate journal_append(args), to: BusterClaw.Commands.Journal
  defdelegate journal_read(args \\ %{}), to: BusterClaw.Commands.Journal
  # Notes (the operator's notebook — never the activity log)
  defdelegate note_list(args \\ %{}), to: BusterClaw.Commands.Notes
  defdelegate note_read(args), to: BusterClaw.Commands.Notes
  defdelegate note_create(args), to: BusterClaw.Commands.Notes
  defdelegate note_save(args), to: BusterClaw.Commands.Notes
  defdelegate note_search(args), to: BusterClaw.Commands.Notes
  # Integrations (extras; CRUD comes from the auto-loop above)
  defdelegate integration_poll(args), to: BusterClaw.Commands.Integrations
  defdelegate integration_poll_all(args \\ %{}), to: BusterClaw.Commands.Integrations
  defdelegate integration_run_list(args), to: BusterClaw.Commands.Integrations
  # Notify (timers, alarms, reminders)
  defdelegate notify_list(args \\ %{}), to: BusterClaw.Commands.Notify
  defdelegate notify_get(args), to: BusterClaw.Commands.Notify
  defdelegate notify_create(args), to: BusterClaw.Commands.Notify
  defdelegate notify_snooze(args), to: BusterClaw.Commands.Notify
  defdelegate notify_dismiss(args), to: BusterClaw.Commands.Notify
  defdelegate notify_delete(args), to: BusterClaw.Commands.Notify
  # Sound library + Studio (reads)
  defdelegate sound_list(args \\ %{}), to: BusterClaw.Commands.Sound
  defdelegate sound_routes(args \\ %{}), to: BusterClaw.Commands.Sound
  defdelegate sound_sources(args \\ %{}), to: BusterClaw.Commands.Sound
  defdelegate sound_probe(args), to: BusterClaw.Commands.Sound
  # The door into the studio: a Library recording becomes an editable source
  defdelegate sound_import(args), to: BusterClaw.Commands.Sound
  # Cut-up: transcripts (no timings), word indexes (timings), assembly
  defdelegate sound_transcript_search(args), to: BusterClaw.Commands.Sound
  defdelegate sound_transcript_words(args \\ %{}), to: BusterClaw.Commands.Sound
  defdelegate sound_corpus(args \\ %{}), to: BusterClaw.Commands.Sound
  defdelegate sound_index_list(args \\ %{}), to: BusterClaw.Commands.Sound
  defdelegate sound_index_words(args \\ %{}), to: BusterClaw.Commands.Sound
  defdelegate sound_index_search(args), to: BusterClaw.Commands.Sound
  defdelegate sound_index_import(args), to: BusterClaw.Commands.Sound
  defdelegate sound_index_delete(args), to: BusterClaw.Commands.Sound
  defdelegate sound_align(args), to: BusterClaw.Commands.Sound
  # Query by example: the matcher that fills an index, and the sentence that
  # chooses between the takes in one
  defdelegate sound_find(args), to: BusterClaw.Commands.Sound
  defdelegate sound_sentence(args), to: BusterClaw.Commands.Sound
  defdelegate sound_assemble(args), to: BusterClaw.Commands.Sound
  # Editing: one pure SoundStudio function each, rendered to a NEW source
  defdelegate sound_trim(args), to: BusterClaw.Commands.Sound
  defdelegate sound_fade(args), to: BusterClaw.Commands.Sound
  defdelegate sound_normalize(args), to: BusterClaw.Commands.Sound
  defdelegate sound_concat(args), to: BusterClaw.Commands.Sound
  defdelegate sound_delete(args), to: BusterClaw.Commands.Sound
  # The gated end of the walk, and the way back from it
  defdelegate sound_apply(args), to: BusterClaw.Commands.Sound
  defdelegate sound_restore_defaults(args \\ %{}), to: BusterClaw.Commands.Sound
  # Capture, and the coverage report a donor passage is written against
  # (STUDIO_ROADMAP Part V). A separate module: these point at the microphone and
  # the OS mixer, not at the cutting surface.
  defdelegate sound_gaps(args \\ %{}), to: BusterClaw.Commands.SoundCapture
  defdelegate sound_devices(args \\ %{}), to: BusterClaw.Commands.SoundCapture
  defdelegate sound_input_level(args \\ %{}), to: BusterClaw.Commands.SoundCapture
  defdelegate sound_input_level_set(args), to: BusterClaw.Commands.SoundCapture
  # Gated: the microphone is the one input an unattended run must not open alone
  defdelegate sound_record(args), to: BusterClaw.Commands.SoundCapture
  # The in-app recorder's write half, and the voice banks that keep one
  # contributor's takes from being spliced into another's (STUDIO_ROADMAP V.0:
  # banks never merge, and a bank is a voice-and-channel, not a folder).
  defdelegate sound_record_save(args), to: BusterClaw.Commands.SoundCapture
  defdelegate voice_bank_list(args \\ %{}), to: BusterClaw.Commands.SoundCapture
  defdelegate voice_bank_create(args), to: BusterClaw.Commands.SoundCapture
  defdelegate voice_bank_select(args), to: BusterClaw.Commands.SoundCapture
  defdelegate voice_bank_delete(args), to: BusterClaw.Commands.SoundCapture
  # Pockets — the operator's own folders of media, READ ONLY. There is no verb
  # here that records, changes or removes a mount, at any tier: mounting is an
  # operator act in the UI, and the absence is the enforcement (POCKETS_ROADMAP
  # D4). `test/buster_claw/commands/pocket_test.exs` fails if one ever appears.
  defdelegate pocket_list(args \\ %{}), to: BusterClaw.Commands.Pocket
  defdelegate pocket_describe(args), to: BusterClaw.Commands.Pocket
  defdelegate pocket_read(args), to: BusterClaw.Commands.Pocket
  # Sketch Pad — two reads and four writes (SKETCH_ROADMAP Phases 2 and 3). The
  # three that touch an existing mark take the CALLER as a second argument, which
  # `dispatch/3` supplies: `D6` decides what may be changed by WHO MADE IT, not
  # by tier, so `Sketch.Authorship` needs the caller and must never read it from
  # `args` — that map is the model's own input. There is deliberately no verb
  # that deletes a whole sketch; a sketch is a file the operator owns (`D9`).
  defdelegate sketch_list(args \\ %{}), to: BusterClaw.Commands.Sketch
  defdelegate sketch_get(args), to: BusterClaw.Commands.Sketch
  defdelegate sketch_create(args), to: BusterClaw.Commands.Sketch
  defdelegate sketch_add(args, caller \\ :agent), to: BusterClaw.Commands.Sketch
  defdelegate sketch_update(args, caller \\ :agent), to: BusterClaw.Commands.Sketch
  defdelegate sketch_delete(args, caller \\ :agent), to: BusterClaw.Commands.Sketch
  # Terminal colours — the model repaints the terminal it is running in. The
  # writes reach the agent's OWN theme slot only: nothing here calls
  # `TerminalTheme.set_custom/3`, so the operator's saved palette survives
  # whatever the model does, and `commands/terminal_theme_test.exs` fails if a
  # call to it ever appears (TERMINAL_PAINT_ROADMAP D3).
  defdelegate terminal_theme_list(args \\ %{}), to: BusterClaw.Commands.TerminalTheme
  defdelegate terminal_theme_select(args), to: BusterClaw.Commands.TerminalTheme
  defdelegate terminal_theme_paint(args), to: BusterClaw.Commands.TerminalTheme
  defdelegate terminal_theme_reset(args \\ %{}), to: BusterClaw.Commands.TerminalTheme
  # Backgrounds — the other half of dressing a surface (DMG review B1). Selection
  # only: these choose among the built-in designs, the images the operator
  # uploaded, and the workspace shaders whose CURRENT bytes the operator has
  # approved by applying them once (AGENT_APPLIED_SHADERS). No command at any
  # tier authors a shader or adds an image. Every write goes through
  # `Appearance.set_background/2`, which is the app's one definition of a valid
  # background; `commands/appearance_test.exs` fails if this module ever reaches
  # past it to a Settings key.
  defdelegate background_list(args \\ %{}), to: BusterClaw.Commands.Appearance
  defdelegate background_set(args), to: BusterClaw.Commands.Appearance
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
  defdelegate browser_find_elements(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_click(args), to: BusterClaw.Commands.Web
  defdelegate browser_fill(args), to: BusterClaw.Commands.Web
  defdelegate browser_wait(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_extract(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_assert(args), to: BusterClaw.Commands.Web
  defdelegate browser_flow(args), to: BusterClaw.Commands.Web
  defdelegate browser_check_save(args), to: BusterClaw.Commands.Web
  defdelegate browser_check_list(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_control_probe(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_check_run(args), to: BusterClaw.Commands.Web
  defdelegate browser_egress_level(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_secret_put(args), to: BusterClaw.Commands.Web
  defdelegate browser_secret_list(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_secret_delete(args), to: BusterClaw.Commands.Web
  defdelegate browser_tabs(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate browser_navigate(args), to: BusterClaw.Commands.Web
  # Agent Mode runs (browser-engine UI slice)
  defdelegate agent_run_start(args), to: BusterClaw.Commands.AgentRuns
  defdelegate agent_run_navigate(args), to: BusterClaw.Commands.AgentRuns
  defdelegate agent_run_act(args), to: BusterClaw.Commands.AgentRuns
  defdelegate agent_run_cart(args), to: BusterClaw.Commands.AgentRuns
  defdelegate agent_run_status(args \\ %{}), to: BusterClaw.Commands.AgentRuns
  defdelegate agent_run_stop(args), to: BusterClaw.Commands.AgentRuns
  defdelegate agent_run_finish(args), to: BusterClaw.Commands.AgentRuns
  defdelegate agent_run_resume(args), to: BusterClaw.Commands.AgentRuns
  defdelegate agent_run_confirm_purchase(args), to: BusterClaw.Commands.AgentRuns
  defdelegate browser_open_tab(args), to: BusterClaw.Commands.Web
  defdelegate bookmark_add(args), to: BusterClaw.Commands.Web
  defdelegate bookmark_list(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate bookmark_remove(args), to: BusterClaw.Commands.Web
  defdelegate bookmark_export(args \\ %{}), to: BusterClaw.Commands.Web
  defdelegate bookmark_import(args), to: BusterClaw.Commands.Web
  defdelegate history_search(args), to: BusterClaw.Commands.Web
  defdelegate history_recent(args \\ %{}), to: BusterClaw.Commands.Web
  # Finance
  defdelegate finance_sources(args \\ %{}), to: BusterClaw.Commands.Finance
  defdelegate finance_filings(args), to: BusterClaw.Commands.Finance
  defdelegate finance_fundamentals(args), to: BusterClaw.Commands.Finance
  defdelegate finance_quote(args), to: BusterClaw.Commands.Finance
  defdelegate finance_news(args), to: BusterClaw.Commands.Finance
  # BusterPhone (the Message Machine)
  defdelegate phone_list(args \\ %{}), to: BusterClaw.Commands.Telephony
  defdelegate phone_get(args), to: BusterClaw.Commands.Telephony
  defdelegate phone_stats(args \\ %{}), to: BusterClaw.Commands.Telephony
  defdelegate phone_mark_heard(args), to: BusterClaw.Commands.Telephony
  defdelegate phone_trusted_list(args \\ %{}), to: BusterClaw.Commands.Telephony
  defdelegate phone_trusted_add(args), to: BusterClaw.Commands.Telephony
  defdelegate phone_trusted_remove(args), to: BusterClaw.Commands.Telephony
  defdelegate phone_pin_set(args), to: BusterClaw.Commands.Telephony
  defdelegate phone_pin_remove(args), to: BusterClaw.Commands.Telephony
  defdelegate phone_pin_list(args \\ %{}), to: BusterClaw.Commands.Telephony
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
  defdelegate model_policy(args \\ %{}), to: BusterClaw.Commands.Orchestration
  defdelegate terminal_tab_open(args \\ %{}), to: BusterClaw.Commands.Orchestration
  defdelegate terminal_command_list(args \\ %{}), to: BusterClaw.Commands.Orchestration
  defdelegate terminal_command_set(args \\ %{}), to: BusterClaw.Commands.Orchestration
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
