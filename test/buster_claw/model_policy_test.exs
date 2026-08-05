defmodule BusterClaw.ModelPolicyTest do
  # async: false — every case here writes the `model_policy` Settings row, and
  # SQLite serializes writers ("Database busy" under concurrency).
  use BusterClaw.DataCase, async: false

  alias BusterClaw.ModelPolicy

  describe "the unset default" do
    # The whole feature is meant to be additive: an install that upgrades into
    # it must behave exactly as it did the day before. If this ever returns a
    # model, every existing install silently changes model on upgrade.
    test "every surface resolves to nil when nothing is set" do
      for surface <- ModelPolicy.surface_keys() do
        assert ModelPolicy.for_surface(surface) == nil,
               "#{surface} resolved to a model with an empty policy"
      end
    end

    test "in_force reports :cli as the source when nothing is set" do
      for {_surface, entry} <- ModelPolicy.in_force() do
        assert entry.source == :cli
        assert entry.model == nil
      end
    end
  end

  describe "the global default" do
    test "reaches every surface it is allowed to reach" do
      {:ok, _} = ModelPolicy.put(:default, "claude-opus-5")

      assert ModelPolicy.for_surface(:chat) == "claude-opus-5"
      assert ModelPolicy.for_surface(:dispatcher) == "claude-opus-5"
      assert ModelPolicy.for_surface(:swarm_run) == "claude-opus-5"
      assert ModelPolicy.in_force()[:chat].source == :default
    end

    test "clearing it returns every surface to nil" do
      {:ok, _} = ModelPolicy.put(:default, "claude-opus-5")
      {:ok, _} = ModelPolicy.put(:default, nil)

      assert ModelPolicy.for_surface(:chat) == nil
      assert ModelPolicy.for_surface(:trading_read) == nil
    end
  end

  # This is the regression guard for the 07-28 measurement recorded in
  # trading.ex: haiku on the trading read invoked the broker tool in only 1 of 2
  # runs, and on the miss it FABRICATED the answer rather than erroring. Without
  # these assertions the floor is a comment in a moduledoc.
  describe "the money-surface floor" do
    test "a cheap global default cannot reach the trading surfaces" do
      {:ok, _} = ModelPolicy.put(:default, "claude-haiku-4-5")

      assert ModelPolicy.for_surface(:chat) == "claude-haiku-4-5",
             "the floor should not apply to surfaces that don't touch money"

      assert ModelPolicy.for_surface(:trading_read) == "claude-sonnet-5"
      assert ModelPolicy.for_surface(:order_submit) == "claude-sonnet-5"
    end

    test "in_force names the floor as the reason, so the UI can explain it" do
      {:ok, _} = ModelPolicy.put(:default, "claude-haiku-4-5")
      in_force = ModelPolicy.in_force()

      assert in_force[:trading_read].source == :floor
      assert in_force[:trading_read].floor == "claude-sonnet-5"
      assert in_force[:chat].source == :default
    end

    test "a capable global default passes through untouched" do
      {:ok, _} = ModelPolicy.put(:default, "claude-opus-5")

      assert ModelPolicy.for_surface(:trading_read) == "claude-opus-5"
      assert ModelPolicy.in_force()[:trading_read].source == :default
    end

    # The floor is a guard against lowering cost by accident, not a lock. An
    # operator who names the money surface itself has made a deliberate choice.
    test "naming the surface itself still goes below the floor" do
      {:ok, _} = ModelPolicy.put(:default, "claude-opus-5")
      {:ok, _} = ModelPolicy.put(:trading_read, "claude-haiku-4-5")

      assert ModelPolicy.for_surface(:trading_read) == "claude-haiku-4-5"
      assert ModelPolicy.in_force()[:trading_read].source == :surface
      assert ModelPolicy.for_surface(:order_submit) == "claude-opus-5"
    end

    # A model we don't rank must not be silently swapped for the floor — that
    # would break the free-text escape hatch the picker depends on.
    test "an unranked global default is left alone" do
      {:ok, _} = ModelPolicy.put(:default, "some-future-model")

      assert ModelPolicy.for_surface(:trading_read) == "some-future-model"
    end
  end

  describe "per-surface overrides" do
    test "win over the global default without touching other surfaces" do
      {:ok, _} = ModelPolicy.put(:default, "claude-sonnet-5")
      {:ok, _} = ModelPolicy.put(:swarm_planner, "claude-opus-5")

      assert ModelPolicy.for_surface(:swarm_planner) == "claude-opus-5"
      assert ModelPolicy.for_surface(:swarm_run) == "claude-sonnet-5"
    end

    test "clearing one falls back to the default, not to nil" do
      {:ok, _} = ModelPolicy.put(:default, "claude-sonnet-5")
      {:ok, _} = ModelPolicy.put(:swarm_run, "claude-haiku-4-5")
      {:ok, _} = ModelPolicy.put(:swarm_run, nil)

      assert ModelPolicy.for_surface(:swarm_run) == "claude-sonnet-5"
    end
  end

  describe "put/2 validation" do
    test "refuses a surface that no run site reads" do
      assert {:error, {:unknown_surface, :nonsense}} = ModelPolicy.put(:nonsense, "claude-opus-5")
    end

    test "refuses a blank model rather than storing one that never applies" do
      assert {:error, :blank_model} = ModelPolicy.put(:chat, "   ")
    end

    test "refuses a non-string model" do
      assert {:error, {:bad_model, 5}} = ModelPolicy.put(:chat, 5)
    end
  end

  describe "stored/0" do
    test "ignores junk keys rather than growing the atom table" do
      BusterClaw.Settings.put(
        "model_policy",
        Jason.encode!(%{"chat" => "claude-opus-5", "not_a_surface" => "x", "" => "y"})
      )

      assert ModelPolicy.stored() == %{backends: %{}, models: %{claude: %{chat: "claude-opus-5"}}}
    end

    test "survives a corrupt value instead of crashing every run site" do
      BusterClaw.Settings.put("model_policy", "not json at all")

      assert ModelPolicy.stored() == %{backends: %{}, models: %{}}
      assert ModelPolicy.for_surface(:chat) == nil
    end
  end

  describe "the backend (harness)" do
    test "is unset by default, so AgentRunner keeps detecting exactly as before" do
      # Except the pinned money surfaces, which are claude by capability rather
      # than by preference — see "the money surfaces are pinned to claude".
      for surface <- ModelPolicy.surface_keys(), not ModelPolicy.claude_only?(surface) do
        assert ModelPolicy.backend_for(surface) == nil
      end

      assert ModelPolicy.in_force()[:chat].backend_source == :auto
    end

    test "a global default reaches every surface it is allowed to reach" do
      {:ok, _} = ModelPolicy.put_backend(:default, :codex)

      assert ModelPolicy.backend_for(:chat) == :codex
      assert ModelPolicy.backend_for(:dispatcher) == :codex
      assert ModelPolicy.in_force()[:chat].backend_source == :default
    end

    test "a per-surface override wins without touching the others" do
      {:ok, _} = ModelPolicy.put_backend(:default, :codex)
      {:ok, _} = ModelPolicy.put_backend(:swarm_planner, :opencode)

      assert ModelPolicy.backend_for(:swarm_planner) == :opencode
      assert ModelPolicy.backend_for(:chat) == :codex
      assert ModelPolicy.in_force()[:swarm_planner].backend_source == :surface
    end

    test "clearing returns a surface to auto-detection" do
      {:ok, _} = ModelPolicy.put_backend(:default, :opencode)
      {:ok, _} = ModelPolicy.put_backend(:default, nil)

      assert ModelPolicy.backend_for(:chat) == nil
    end

    test "refuses a harness that does not exist" do
      assert {:error, {:unknown_backend, :gemini}} = ModelPolicy.put_backend(:default, :gemini)
      assert {:error, {:unknown_surface, :nope}} = ModelPolicy.put_backend(:nope, :codex)
    end
  end

  # The reason models are keyed by {backend, surface} rather than by surface. A
  # model ID means nothing outside its harness, so switching harness must not
  # destroy the models set for the old one — otherwise trying codex for an hour
  # silently costs the operator their whole claude policy.
  describe "models are remembered per harness" do
    test "switching harness and back is lossless" do
      {:ok, _} = ModelPolicy.put(:chat, "claude-opus-5")

      {:ok, _} = ModelPolicy.put_backend(:default, :opencode)
      assert ModelPolicy.for_surface(:chat) == nil, "claude's model must not leak to opencode"

      {:ok, _} = ModelPolicy.put(:chat, "opencode-go/kimi-k3")
      assert ModelPolicy.for_surface(:chat) == "opencode-go/kimi-k3"

      {:ok, _} = ModelPolicy.put_backend(:default, nil)
      assert ModelPolicy.for_surface(:chat) == "claude-opus-5"
    end

    test "each harness keeps its own default" do
      {:ok, _} = ModelPolicy.put_model(:claude, :default, "claude-opus-5")
      {:ok, _} = ModelPolicy.put_model(:codex, :default, "gpt-5.1-codex")

      assert ModelPolicy.model_for(:claude, :chat) == "claude-opus-5"
      assert ModelPolicy.model_for(:codex, :chat) == "gpt-5.1-codex"
    end

    # Every model stored before harnesses existed was a claude model, and claude
    # is first in the detection order. Reading a different bucket per machine
    # would make one stored policy mean different things on different machines.
    test "an unset backend reads the claude bucket" do
      {:ok, _} = ModelPolicy.put_model(:claude, :chat, "claude-sonnet-5")

      assert ModelPolicy.backend_for(:chat) == nil
      assert ModelPolicy.for_surface(:chat) == "claude-sonnet-5"
    end

    test "put_model refuses an unknown harness or surface" do
      assert {:error, {:unknown_backend, :gemini}} =
               ModelPolicy.put_model(:gemini, :chat, "x")

      assert {:error, {:unknown_surface, :nope}} =
               ModelPolicy.put_model(:claude, :nope, "x")
    end
  end

  # REVERSED 08-03, and the reversal is the interesting part. The operator first
  # chose to allow any harness on the money surfaces with a loud warning. Then the
  # flags turned out to be untranslatable — codex answers `--disallowedTools` with
  # "unexpected argument" — so "allow it and warn" would have meant offering a
  # choice whose only outcome is a failed run. These surfaces are pinned instead.
  describe "the money surfaces are pinned to claude" do
    test "a global default cannot move them" do
      {:ok, _} = ModelPolicy.put_backend(:default, :codex)

      assert ModelPolicy.backend_for(:chat) == :codex
      assert ModelPolicy.backend_for(:trading_read) == :claude
      assert ModelPolicy.backend_for(:order_submit) == :claude
    end

    test "naming one is refused, with the reason" do
      assert {:error, {:claude_only, :order_submit, why}} =
               ModelPolicy.put_backend(:order_submit, :codex)

      assert why =~ "confinement"
      assert ModelPolicy.backend_for(:order_submit) == :claude
    end

    test "claude_only?/1 names exactly the floored surfaces" do
      assert Enum.sort(Map.keys(ModelPolicy.claude_only())) ==
               Enum.sort(Map.keys(ModelPolicy.floors()))
    end

    # The pin and the floor have to move together. If a future change lifts the
    # pin without giving the floor a per-backend measurement, this fails.
    test "so the floor always applies, and nothing is ever unfloored" do
      {:ok, _} = ModelPolicy.put_backend(:default, :opencode)

      assert ModelPolicy.unfloored_money_surfaces() == []
      assert ModelPolicy.floor_applies?(ModelPolicy.backend_for(:trading_read), :trading_read)
    end

    test "the floor still bites through a cheap global default" do
      {:ok, _} = ModelPolicy.put_backend(:default, :codex)
      {:ok, _} = ModelPolicy.put_model(:claude, :default, "claude-haiku-4-5")

      assert ModelPolicy.for_surface(:trading_read) == "claude-sonnet-5"
    end
  end

  # An operator who set a policy before harnesses existed keeps it.
  describe "migration from the pre-backend row" do
    test "a flat surface => model row is read as claude's models" do
      BusterClaw.Settings.put(
        "model_policy",
        Jason.encode!(%{"default" => "claude-opus-5", "swarm_run" => "claude-haiku-4-5"})
      )

      assert ModelPolicy.for_surface(:chat) == "claude-opus-5"
      assert ModelPolicy.for_surface(:swarm_run) == "claude-haiku-4-5"
      assert ModelPolicy.model_for(:claude, :chat) == "claude-opus-5"
      assert ModelPolicy.backend_for(:chat) == nil
    end

    test "the floor still holds across the migration" do
      BusterClaw.Settings.put("model_policy", Jason.encode!(%{"default" => "claude-haiku-4-5"}))

      assert ModelPolicy.for_surface(:trading_read) == "claude-sonnet-5"
    end

    test "writing after a migration does not lose the migrated values" do
      BusterClaw.Settings.put("model_policy", Jason.encode!(%{"default" => "claude-opus-5"}))
      {:ok, _} = ModelPolicy.put(:chat, "claude-sonnet-5")

      assert ModelPolicy.for_surface(:chat) == "claude-sonnet-5"
      assert ModelPolicy.for_surface(:dispatcher) == "claude-opus-5"
    end
  end

  describe "the catalog" do
    test "every floor names a real surface" do
      for {surface, _model} <- ModelPolicy.floors() do
        assert surface in ModelPolicy.surface_keys()
      end
    end

    test "every floor model is ranked, or the floor can never be enforced" do
      for {_surface, model} <- ModelPolicy.floors() do
        assert ModelPolicy.capability_rank(model),
               "floor #{model} is unranked, so below_floor?/2 can never fire"
      end
    end

    test "every offered model is valid" do
      for model <- ModelPolicy.known_models(), do: assert(ModelPolicy.valid_model?(model))
    end

    # An unset harness reads the implicit claude bucket for its MODEL list too,
    # not an empty one. Getting this wrong emptied the Settings picker on a fresh
    # install — the state every install starts in.
    test "an unset harness still offers claude's models" do
      assert ModelPolicy.known_models(nil) == ModelPolicy.known_models(:claude)
      refute ModelPolicy.known_models(nil) == []
    end

    # opencode's list is per-machine and read live, so it ships none — and it must
    # not silently fall back to claude's, which would offer bare IDs to a harness
    # that needs provider/model.
    test "a harness with no shipped list offers none rather than claude's" do
      assert ModelPolicy.known_models(:opencode) == []
      refute ModelPolicy.known_models(:codex) == ModelPolicy.known_models(:claude)
      refute ModelPolicy.known_models(:codex) == []
    end

    test "valid_model?/1 rejects blanks and non-strings" do
      refute ModelPolicy.valid_model?("")
      refute ModelPolicy.valid_model?("  ")
      refute ModelPolicy.valid_model?(nil)
      refute ModelPolicy.valid_model?(:claude)
    end
  end
end
