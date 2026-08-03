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

      assert ModelPolicy.stored() == %{chat: "claude-opus-5"}
    end

    test "survives a corrupt value instead of crashing every run site" do
      BusterClaw.Settings.put("model_policy", "not json at all")

      assert ModelPolicy.stored() == %{}
      assert ModelPolicy.for_surface(:chat) == nil
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

    test "valid_model?/1 rejects blanks and non-strings" do
      refute ModelPolicy.valid_model?("")
      refute ModelPolicy.valid_model?("  ")
      refute ModelPolicy.valid_model?(nil)
      refute ModelPolicy.valid_model?(:claude)
    end
  end
end
