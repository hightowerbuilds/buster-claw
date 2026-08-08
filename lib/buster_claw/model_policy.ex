defmodule BusterClaw.ModelPolicy do
  @moduledoc """
  Which **harness** each agent surface runs in, and which **model** inside it.

  Buster Claw drives the operator's own agent CLI. Until 08-03 it never told that
  CLI which model to use, and it never let anyone choose the CLI either —
  `AgentRunner.detect/0` took whichever was first on PATH. This module is what
  the six run call sites ask for both answers.

  ## The shape

  A **global default plus per-surface overrides**, for the backend and the model
  alike, so there is one mental model rather than two:

      backend:  default → per-surface override
      model:    default → per-surface override, WITHIN the chosen backend

  ## Models are keyed by `{backend, surface}`, not by surface

  A model ID is only meaningful inside its harness. `claude-opus-5` means nothing
  to opencode, which wants `opencode-go/glm-5.1`; codex has its own namespace
  again. Keying by surface alone would force a choice between showing a stale
  model as "in force" (a lie) and discarding the operator's choice the moment
  they switched harness. Keying on the pair makes switching harness — and
  switching back — **lossless**.

  ## `nil` still means "pass nothing"

  An unset model omits `--model`; an unset backend omits `:agent` and leaves
  `AgentRunner.detect/0` in charge exactly as before. Both defaults are unset, so
  installing this changes nothing about what an existing install does.

  **An unset backend reads the `:claude` model bucket.** Every model stored
  before backends existed was a claude model, claude is first in the detection
  order, and guessing per-machine at read time would make the same stored policy
  mean different things on different machines. An operator who wants codex's
  models chooses codex.

  ## Floors, and why they are claude-only *explicitly*

  A surface may declare a floor: a capability level a lowered *global* default
  cannot reach, though naming that surface explicitly still can. **No surface
  declares one today** — the two that did, the broker read and the order
  submission, left with the trading stack on 08-08.

  The mechanism is kept, and the reason it existed is worth keeping with it. A
  cheap model was measured on 07-28 invoking its tool in only 1 of 2 runs, and on
  the miss it **invented the answer** rather than reporting a problem. It did not
  error; it fabricated. That is the failure a floor is for, and it is not
  specific to money.

  **The floor is claude-only, and `floor_applies?/2` says so in the data.** The
  ranks are claude model IDs and the 07-28 measurement was taken on claude, so a
  floor cannot be honestly enforced against a codex or opencode model. Left
  implicit it would still "work" — an unranked model passes `below_floor?/2`
  untouched — but it would look like protection while being a no-op. The
  operator chose (08-03) to allow any backend on a floored surface *with a loud
  warning*; a warning can only be loud if the code knows when the floor stopped
  applying.

  ## Where the values live

  Shipped defaults are in code so they can be improved on upgrade; the operator's
  choices live in `Settings`. A seeded workspace file could never be corrected on
  an install that already had one — see `LAUNCH_ROADMAP` **V.8**.

  ## Leaf, deliberately

  Nothing here calls a surface, and nothing here detects or spawns. Every surface
  calls in. Hanging this off a surface module or `AgentRunner` for convenience is
  exactly the placement that produced the `Trading → ChartBuilder → Portfolio`
  cycle on 08-03 — a lesson that outlived the modules in it.
  """

  alias BusterClaw.AgentBackend

  @settings_key "model_policy"

  # Capability order, least capable first. Used ONLY to evaluate floors, and ONLY
  # for claude — an unranked model (a new release, an alias, an operator's own
  # string) is never blocked, because refusing to run something we don't
  # recognise is worse than the floor going unenforced for it.
  @capability_rank %{
    "claude-haiku-4-5" => 1,
    "claude-sonnet-4-6" => 2,
    "claude-sonnet-5" => 2,
    "claude-opus-4-6" => 3,
    "claude-opus-4-7" => 3,
    "claude-opus-4-8" => 3,
    "claude-opus-5" => 3,
    "claude-fable-5" => 4
  }

  # Every surface that spawns a run, and what it is.
  @surfaces %{
    chat: "Chat — the homepage conversations",
    dispatcher: "On-duty dispatcher — the unattended queue worker",
    swarm_planner: "Swarm planner — the single run that shapes a swarm",
    swarm_run: "Swarm sub-runs — the fan-out"
  }

  # No surface carries a floor today. The two that did — the Robinhood read and
  # the order submission — left with the trading stack on 08-08. The mechanism
  # stays because the next money-shaped surface should not have to reinvent it.
  @floors %{}

  # The floor's ranks and its measurement are both claude's. See the moduledoc.
  @floor_backend :claude

  # Surfaces PINNED to claude, whatever the global default says.
  #
  # Not a preference and not a floor — a capability fact. Their confinement is
  # written in claude's flag vocabulary (`--allowedTools` / `--disallowedTools` /
  # `--strict-mcp-config`, all three measured load-bearing on 07-28), and codex
  # rejects those outright: `error: unexpected
  # argument '--disallowedTools'`, measured 08-03. A codex or opencode run on
  # these surfaces does not run cheaply, or unsafely — it does not run at all.
  #
  # The operator's 08-03 call was to allow any harness here with a loud warning.
  # That was made before the flags were known to be untranslatable; once they
  # were, "allow it and warn" would have meant offering a choice whose only
  # outcome is a failed run. Reversed 08-03 with the reason stated. If per-backend
  # confinement is ever built (AGENT_BACKEND_ROADMAP Phase 3.5), this pin is what
  # should be lifted, and only then.
  @claude_only %{}

  # Which bucket an unset backend reads. See the moduledoc.
  @implicit_backend :claude

  @doc "Every surface key, with a human description."
  def surfaces, do: @surfaces

  @doc "Surface keys only, in a stable order."
  def surface_keys, do: @surfaces |> Map.keys() |> Enum.sort()

  @doc "Surfaces carrying a capability floor, and the floor model."
  def floors, do: @floors

  @doc """
  The models to offer for `backend` without asking its CLI.

  Per backend since 08-03: only claude ships a list. See
  `AgentBackend.enumerate_models/1` for opencode, which can list its own.
  """
  def known_models(backend \\ @implicit_backend),
    do: AgentBackend.known_models(bucket(backend))

  @doc "Backends the picker may offer, in detection order."
  def backends, do: AgentBackend.order()

  @doc "Rank for floor comparison, or `nil` when the model is unranked."
  def capability_rank(model), do: Map.get(@capability_rank, model)

  @doc """
  Whether a floor can be honestly enforced for `surface` on `backend`.

  False for every backend but claude, and false for a surface with no floor.
  `nil` (an unset backend) counts as claude — see the moduledoc.
  """
  def floor_applies?(backend, surface) do
    Map.has_key?(@floors, surface) and bucket(backend) == @floor_backend
  end

  # --- backend ---------------------------------------------------------------

  @doc """
  The harness for `surface`, or `nil` to let `AgentRunner.detect/0` decide.

  Resolution mirrors the model's: the surface's own override wins, then the
  global default, then unset.
  """
  def backend_for(surface) when is_atom(surface) do
    if claude_only?(surface), do: @floor_backend, else: resolve_backend(surface)
  end

  @doc """
  Surfaces that can only run on claude, and why.

  See `@claude_only` — this is a capability fact, not a preference: the other
  harnesses reject the confinement flags these surfaces depend on.
  """
  def claude_only, do: @claude_only

  @doc "True if `surface` is pinned to claude."
  def claude_only?(surface), do: Map.has_key?(@claude_only, surface)

  defp resolve_backend(surface) do
    backends = stored_backends()

    # `Map.fetch/2`, not `Map.get/2` + an `is_atom/1` guard: `nil` is an atom, so
    # a guard would match the ABSENT case and return nil instead of falling
    # through to the global default.
    case Map.fetch(backends, surface) do
      {:ok, backend} -> backend
      :error -> Map.get(backends, :default)
    end
  end

  @doc """
  Set the harness for one surface, or the global default with `:default`.
  `nil` clears back to auto-detection.
  """
  def put_backend(surface, backend)

  def put_backend(surface, backend) when is_atom(surface) do
    cond do
      not known_surface?(surface) -> {:error, {:unknown_surface, surface}}
      claude_only?(surface) -> {:error, {:claude_only, surface, @claude_only[surface]}}
      is_nil(backend) -> write(&put_in_backends(&1, surface, nil))
      not AgentBackend.known?(backend) -> {:error, {:unknown_backend, backend}}
      true -> write(&put_in_backends(&1, surface, backend))
    end
  end

  def put_backend(surface, _backend), do: {:error, {:unknown_surface, surface}}

  # --- model -----------------------------------------------------------------

  @doc """
  The model for `surface` under its resolved backend, or `nil` for the CLI's own
  default.
  """
  def for_surface(surface) when is_atom(surface),
    do: model_for(backend_for(surface), surface)

  @doc """
  The model stored for `surface` under a specific `backend`, floor applied.

  Reading an explicit backend is what makes switching harness lossless: the
  models set for claude are still there after a detour through codex.
  """
  def model_for(backend, surface) when is_atom(surface) do
    models = stored_models(backend)

    case Map.get(models, surface) do
      model when is_binary(model) -> model
      _ -> apply_floor(backend, surface, Map.get(models, :default))
    end
  end

  @doc """
  Set a model for `surface` under `backend`. `nil` clears it.

  `backend` may be `nil`, meaning the implicit claude bucket.
  """
  def put_model(backend, surface, model) do
    cond do
      not known_surface?(surface) ->
        {:error, {:unknown_surface, surface}}

      not is_nil(backend) and not AgentBackend.known?(backend) ->
        {:error, {:unknown_backend, backend}}

      is_binary(model) and String.trim(model) == "" ->
        {:error, :blank_model}

      is_binary(model) or is_nil(model) ->
        write(&put_in_models(&1, bucket(backend), surface, model))

      true ->
        {:error, {:bad_model, model}}
    end
  end

  @doc """
  Set a model for `surface` under whichever backend that surface resolves to.

  The convenience form the command and Settings use when the operator is editing
  the harness they are already looking at.
  """
  def put(surface, model) when is_atom(surface),
    do: put_model(backend_for(surface), surface, model)

  def put(surface, _model), do: {:error, {:unknown_surface, surface}}

  @doc """
  True if `model` looks usable. Deliberately permissive: any non-blank string
  passes, because the CLIs accept aliases and models we do not know about. The
  picker's list is a convenience, not a gate.
  """
  def valid_model?(model), do: is_binary(model) and String.trim(model) != ""

  # --- reporting -------------------------------------------------------------

  @doc """
  What is actually in force per surface — the answer to "I set a default, so why
  is this surface on something else?".

  Each entry carries the resolved `backend` and `model`, the `source` that
  decided each (`:surface`, `:floor`, `:default`, `:cli`/`:auto`), the surface's
  `floor`, and **`floor_applies`** — false whenever the chosen harness puts the
  surface beyond what the floor can honestly enforce.
  """
  def in_force do
    backends = stored_backends()

    Map.new(surface_keys(), fn surface ->
      backend = backend_for(surface)
      models = stored_models(backend)

      {surface,
       %{
         backend: backend,
         backend_source: backend_source(surface, backends),
         model: model_for(backend, surface),
         source: model_source(backend, surface, models),
         floor: Map.get(@floors, surface),
         floor_applies: floor_applies?(backend, surface),
         description: Map.fetch!(@surfaces, surface)
       }}
    end)
  end

  @doc """
  Floored surfaces whose harness has put them beyond the floor's reach.

  **Always empty since the money surfaces were pinned to claude**, and kept as a
  live assertion rather than deleted: if a future change lifts the pin (see
  `@claude_only`) without also giving the floor a per-backend measurement, this
  starts returning entries and the test guarding it fails. That is the whole
  point — the pin and the floor have to move together.
  """
  def unfloored_money_surfaces do
    for {surface, _floor} <- @floors,
        not floor_applies?(backend_for(surface), surface),
        do: surface
  end

  @doc "Only what the operator set, unresolved: `%{backends: …, models: …}`."
  def stored do
    %{backends: stored_backends(), models: all_stored_models()}
  end

  # --- internals -------------------------------------------------------------

  # A floor raises the GLOBAL default only, and only where it can be honestly
  # enforced. An unranked claude model passes untouched: blocking a string we
  # don't recognise would break the escape hatch the picker depends on.
  defp apply_floor(backend, surface, model) do
    floor = Map.get(@floors, surface)

    cond do
      is_nil(model) or is_nil(floor) -> model
      not floor_applies?(backend, surface) -> model
      below_floor?(model, floor) -> floor
      true -> model
    end
  end

  defp below_floor?(model, floor) do
    case {capability_rank(model), capability_rank(floor)} do
      {mine, theirs} when is_integer(mine) and is_integer(theirs) -> mine < theirs
      _ -> false
    end
  end

  defp backend_source(surface, backends) do
    cond do
      is_atom(Map.get(backends, surface)) and not is_nil(Map.get(backends, surface)) -> :surface
      is_nil(Map.get(backends, :default)) -> :auto
      true -> :default
    end
  end

  defp model_source(backend, surface, models) do
    default = Map.get(models, :default)

    cond do
      is_binary(Map.get(models, surface)) -> :surface
      is_nil(default) -> :cli
      apply_floor(backend, surface, default) != default -> :floor
      true -> :default
    end
  end

  defp known_surface?(surface),
    do: surface == :default or Map.has_key?(@surfaces, surface)

  # An unset backend reads claude's bucket — see the moduledoc.
  defp bucket(nil), do: @implicit_backend
  defp bucket(backend), do: backend

  # --- storage ---------------------------------------------------------------
  #
  # One JSON row holds everything:
  #
  #     {"backend": {"default": "codex", "chat": "claude"},
  #      "model":   {"claude": {"default": "claude-opus-5"},
  #                  "codex":  {"chat": "gpt-5.1-codex"}}}
  #
  # Before backends existed the row was flat — `{"default": "claude-opus-5",
  # "chat": …}` — and `migrate/1` lifts that into the claude bucket, because
  # every model anyone stored then was a claude model. An operator who set a
  # policy yesterday keeps it.

  defp raw do
    with value when is_binary(value) <- BusterClaw.Settings.get(@settings_key),
         {:ok, %{} = decoded} <- Jason.decode(value) do
      migrate(decoded)
    else
      _ -> %{"backend" => %{}, "model" => %{}}
    end
  end

  defp migrate(%{"model" => %{}} = decoded),
    do: Map.put_new(decoded, "backend", %{})

  # The pre-backend shape: a flat surface => model string map.
  defp migrate(decoded) do
    legacy = for {k, v} <- decoded, is_binary(v), into: %{}, do: {k, v}
    %{"backend" => %{}, "model" => %{Atom.to_string(@implicit_backend) => legacy}}
  end

  defp stored_backends do
    for {key, value} <- Map.get(raw(), "backend", %{}),
        surface = parse_surface(key),
        surface != nil,
        backend = parse_backend(value),
        backend != nil,
        into: %{},
        do: {surface, backend}
  end

  defp all_stored_models do
    for {name, entries} <- Map.get(raw(), "model", %{}),
        backend = parse_backend(name),
        backend != nil,
        is_map(entries),
        into: %{},
        do: {backend, surface_map(entries)}
  end

  defp stored_models(backend) do
    raw()
    |> Map.get("model", %{})
    |> Map.get(Atom.to_string(bucket(backend)), %{})
    |> surface_map()
  end

  defp surface_map(entries) when is_map(entries) do
    for {key, value} <- entries,
        surface = parse_surface(key),
        surface != nil,
        is_binary(value) and value != "",
        into: %{},
        do: {surface, value}
  end

  defp surface_map(_entries), do: %{}

  defp put_in_backends(row, surface, nil),
    do: update_in(row, ["backend"], &Map.delete(&1, Atom.to_string(surface)))

  defp put_in_backends(row, surface, backend),
    do: put_in(row, ["backend", Atom.to_string(surface)], Atom.to_string(backend))

  defp put_in_models(row, backend, surface, model) do
    name = Atom.to_string(backend)
    bucket = row |> Map.get("model", %{}) |> Map.get(name, %{})

    bucket =
      if model,
        do: Map.put(bucket, Atom.to_string(surface), model),
        else: Map.delete(bucket, Atom.to_string(surface))

    put_in(row, ["model", name], bucket)
  end

  # Every surface lives in ONE JSON row, so setting one is a read-modify-write.
  # Two concurrent writes can lose an update: the second read can happen before
  # the first write lands, and one surface's change is dropped.
  #
  # Deliberately NOT wrapped in `Repo.transaction/1`. That was tried on 08-03 and
  # reverted, measured: it takes a write lock on the single pooled SQLite
  # connection (`pool_size: 1`, see `config/test.exs`) and starves every other
  # writer — 2 suite failures became 83, in modules that never touch this one.
  #
  # The race is real but narrow: these setters are driven by a human in Settings
  # or by the `model_policy` command, never concurrently in normal use. Recorded
  # rather than papered over — if this ever needs to be atomic, the fix is a
  # compare-and-swap on the row's value, not a transaction.
  defp write(update) do
    BusterClaw.Settings.put(@settings_key, raw() |> update.() |> Jason.encode!())
    {:ok, in_force()}
  end

  # Operator-supplied keys stay out of the atom table unless they name something
  # real — `String.to_atom/1` on stored JSON keys would be unbounded.
  defp parse_surface("default"), do: :default

  defp parse_surface(key) when is_binary(key),
    do: Enum.find(surface_keys(), &(Atom.to_string(&1) == key))

  defp parse_surface(_key), do: nil

  defp parse_backend(name) when is_binary(name),
    do: Enum.find(AgentBackend.order(), &(Atom.to_string(&1) == name))

  defp parse_backend(_name), do: nil
end
