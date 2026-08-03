defmodule BusterClaw.ModelPolicy do
  @moduledoc """
  Which model each agent surface runs on.

  Buster Claw drives the operator's own `claude` CLI, and until 08-03 it never
  told the CLI which model to use — `AgentRunner` accepted `:model` and nothing
  passed it. Every run inherited whatever that CLI was configured for. This
  module is what the six run call sites ask.

  ## The shape

  One **global default**, plus **per-surface overrides**. `for_surface/1`
  resolves them, and returns `nil` when nothing applies.

  **`nil` means "pass no `--model` at all".** Not an empty string, not a named
  default. Unset is the shipped state, so installing this changes nothing about
  what an existing install does — the CLI keeps deciding, exactly as before.
  Callers must omit the flag rather than send `--model ""`.

  ## Floors, and why two surfaces have one

  `trading.ex` records what happened the last time a money surface ran cheap:

  > *"NOT haiku. It was chosen when these reads were cheap and their failure
  > mode was assumed to be an error; measured on 07-28 it invoked the broker
  > tool in only 1 of 2 runs, and on the miss it invented the answer rather than
  > reporting a problem."*

  It did not error. It **fabricated**, on a surface that reads real balances.
  So `:trading_read` and `:order_submit` carry a **floor**: lowering the global
  default cannot reach them. An operator who genuinely wants a cheaper model
  there must name that surface explicitly — the cost-saving gesture and the
  money-touching consequence are deliberately not the same gesture.

  A floor is a *minimum capability*, not a pin. Setting `:trading_read` to
  something above the floor is honoured as-is.

  ## Where the values live

  Shipped defaults are in **code** so they can be improved on upgrade; the
  operator's choices live in `Settings`. A seeded workspace file could never be
  corrected on an install that already had one — see `LAUNCH_ROADMAP` **V.8**.

  ## Leaf, deliberately

  Nothing here calls into a surface; every surface calls in. Hanging this off
  `Trading` or `AgentRunner` for convenience is exactly the placement that
  produced the `Trading → ChartBuilder → Portfolio` cycle on 08-03.
  """

  @settings_key "model_policy"

  # The models the picker offers, most capable first. A fixed list plus a
  # free-text escape hatch: this set has changed repeatedly, and the CLI accepts
  # aliases we do not control, so refusing an unlisted string would age badly.
  @known_models [
    "claude-fable-5",
    "claude-opus-5",
    "claude-sonnet-5",
    "claude-haiku-4-5"
  ]

  # Capability order, least capable first. Used ONLY to evaluate floors — an
  # unranked model (a new release, an alias, an operator's own string) is never
  # blocked by a floor, because refusing to run something we simply don't
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
    chat: "Chat — the homepage and Trading tab conversations",
    trading_read: "Trading reads — balances, positions, market data",
    order_submit: "Order submission — the one path that moves money",
    dispatcher: "On-duty dispatcher — the unattended queue worker",
    swarm_planner: "Swarm planner — the single run that shapes a swarm",
    swarm_run: "Swarm sub-runs — the fan-out"
  }

  # Money surfaces may not be dragged below this by the GLOBAL default. Named
  # explicitly per-surface, an operator can still go lower — see the moduledoc.
  @floors %{
    trading_read: "claude-sonnet-5",
    order_submit: "claude-sonnet-5"
  }

  @doc "Every surface key, with a human description."
  def surfaces, do: @surfaces

  @doc "Surface keys only, in a stable order."
  def surface_keys, do: @surfaces |> Map.keys() |> Enum.sort()

  @doc "The models offered in the picker. Not a whitelist — see `valid_model?/1`."
  def known_models, do: @known_models

  @doc "Surfaces carrying a capability floor, and the floor model."
  def floors, do: @floors

  @doc """
  The model for `surface`, or `nil` to let the CLI decide.

  Resolution: the surface's own override wins outright; otherwise the global
  default applies, raised to the surface's floor if it falls below one.
  """
  def for_surface(surface) when is_atom(surface) do
    stored = stored()

    case Map.get(stored, surface) do
      model when is_binary(model) -> model
      _ -> apply_floor(surface, Map.get(stored, :default))
    end
  end

  @doc """
  What is actually in force, per surface — the answer to "I set a default, so
  why is trading on something else?".

  Each entry carries the resolved `model`, the `source` that decided it
  (`:surface`, `:floor`, `:default`, or `:cli`), and the surface's `floor`.
  """
  def in_force do
    stored = stored()

    Map.new(surface_keys(), fn surface ->
      {surface,
       %{
         model: for_surface(surface),
         source: source_for(surface, stored),
         floor: Map.get(@floors, surface),
         description: Map.fetch!(@surfaces, surface)
       }}
    end)
  end

  @doc "Only what the operator set, with no resolution applied."
  def stored do
    with raw when is_binary(raw) <- BusterClaw.Settings.get(@settings_key),
         {:ok, %{} = decoded} <- Jason.decode(raw) do
      for {key, value} <- decoded,
          surface = parse_surface(key),
          surface != nil,
          is_binary(value) and value != "",
          into: %{},
          do: {surface, value}
    else
      _ -> %{}
    end
  end

  @doc """
  Set one surface's model, or the global default with `:default`. `nil` clears.

  Refuses an unknown surface and a blank model rather than storing something
  that would silently never apply.
  """
  def put(surface, model)

  def put(surface, model) when is_atom(surface) do
    cond do
      surface != :default and not Map.has_key?(@surfaces, surface) ->
        {:error, {:unknown_surface, surface}}

      is_binary(model) and String.trim(model) == "" ->
        {:error, :blank_model}

      is_binary(model) or is_nil(model) ->
        write(surface, model)

      true ->
        {:error, {:bad_model, model}}
    end
  end

  def put(surface, _model), do: {:error, {:unknown_surface, surface}}

  @doc """
  True if `model` looks usable. Deliberately permissive: any non-blank string
  passes, because the CLI accepts aliases and models we do not know about. The
  picker's list is a convenience, not a gate.
  """
  def valid_model?(model), do: is_binary(model) and String.trim(model) != ""

  @doc "Rank for floor comparison, or `nil` when the model is unranked."
  def capability_rank(model), do: Map.get(@capability_rank, model)

  # --- internals -------------------------------------------------------------

  # A floor raises the GLOBAL default only. An unranked model passes untouched:
  # blocking a string we don't recognise would break the escape hatch the whole
  # picker depends on.
  defp apply_floor(surface, model) do
    floor = Map.get(@floors, surface)

    cond do
      is_nil(model) or is_nil(floor) -> model
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

  defp source_for(surface, stored) do
    cond do
      is_binary(Map.get(stored, surface)) -> :surface
      is_nil(Map.get(stored, :default)) -> :cli
      apply_floor(surface, Map.get(stored, :default)) != Map.get(stored, :default) -> :floor
      true -> :default
    end
  end

  defp write(surface, model) do
    entries =
      stored()
      |> then(fn m -> if model, do: Map.put(m, surface, model), else: Map.delete(m, surface) end)

    BusterClaw.Settings.put(
      @settings_key,
      Jason.encode!(Map.new(entries, fn {k, v} -> {Atom.to_string(k), v} end))
    )

    {:ok, in_force()}
  end

  # Operator-supplied keys stay out of the atom table unless they name a real
  # surface — `String.to_atom/1` on stored JSON keys would be unbounded.
  defp parse_surface("default"), do: :default

  defp parse_surface(key) when is_binary(key) do
    Enum.find(surface_keys(), &(Atom.to_string(&1) == key))
  end

  defp parse_surface(_key), do: nil
end
