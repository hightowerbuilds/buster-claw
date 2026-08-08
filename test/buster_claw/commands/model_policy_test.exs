defmodule BusterClaw.Commands.ModelPolicyTest do
  @moduledoc """
  The `model_policy` command: the operator-facing half of
  `BusterClaw.ModelPolicy`. The listing has to explain itself — "I set a
  default, so why is trading on something else?" is the question this answers —
  and the write half has to stay out of reach of callers that are not the human.
  """
  # async: false — every case writes the global `model_policy` Settings row.
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Commands, ModelPolicy}

  defp entry(listing, surface), do: Enum.find(listing.in_force, &(&1.surface == surface))

  describe "choosing a harness" do
    test "sets a backend on its own, without naming a model" do
      assert {:ok, result} =
               Commands.model_policy(%{"surface" => "default", "backend" => "codex"})

      assert result.backend == "codex"
      assert ModelPolicy.backend_for(:chat) == :codex
      assert entry(result.in_force, "chat").backend == "codex"
    end

    # Switching harness must not destroy the models set for the old one, or the
    # operator loses their whole policy by trying codex for an hour.
    test "switching harness leaves the other harness's models intact" do
      {:ok, _} = Commands.model_policy(%{"surface" => "chat", "model" => "claude-opus-5"})
      {:ok, _} = Commands.model_policy(%{"surface" => "default", "backend" => "opencode"})

      assert ModelPolicy.for_surface(:chat) == nil

      {:ok, _} = Commands.model_policy(%{"surface" => "default", "backend" => "auto"})
      assert ModelPolicy.for_surface(:chat) == "claude-opus-5"
    end

    test "backend and model can be set in one call" do
      assert {:ok, _} =
               Commands.model_policy(%{
                 "surface" => "swarm_run",
                 "backend" => "opencode",
                 "model" => "opencode-go/kimi-k3"
               })

      assert ModelPolicy.backend_for(:swarm_run) == :opencode
      assert ModelPolicy.for_surface(:swarm_run) == "opencode-go/kimi-k3"
    end

    test "\"auto\" gives the choice back to PATH detection" do
      {:ok, _} = Commands.model_policy(%{"surface" => "chat", "backend" => "codex"})
      {:ok, _} = Commands.model_policy(%{"surface" => "chat", "backend" => "auto"})

      assert ModelPolicy.backend_for(:chat) == nil
    end

    test "an unknown harness names the real ones instead of crashing" do
      assert {:error, {:unknown_backend, "gemini", names}} =
               Commands.model_policy(%{"surface" => "chat", "backend" => "gemini"})

      assert "auto" in names and "codex" in names
      assert ModelPolicy.stored() == %{backends: %{}, models: %{}}
    end

    # The listing must not offer a harness this machine cannot run.
    test "the listing reports which harnesses are actually installed" do
      assert {:ok, listing} = Commands.model_policy()
      assert Enum.all?(listing.backends_available, &(&1 in listing.backends))
    end

    # `@claude_only` and `@floors` are empty since the trading stack left on
    # 08-08. The refusal and the floor-naming behaviour they proved are still in
    # `ModelPolicy`; nothing declares itself pinned or floored to exercise them.
  end

  describe "the listing" do
    test "covers every surface, and says nothing is set" do
      assert {:ok, listing} = Commands.model_policy()

      assert Enum.map(listing.in_force, & &1.surface) ==
               Enum.map(ModelPolicy.surface_keys(), &Atom.to_string/1)

      # Unset is the shipped state: no model, and the CLI is what decided.
      for surface <- listing.in_force do
        assert surface.model == nil
        assert surface.source == "cli"
      end

      assert listing.operator_set == %{backends: [], models: []}
      assert "default" in listing.surfaces
      assert "claude-opus-5" in listing.known_models
    end
  end

  describe "setting" do
    test "a surface round-trips and shows as its own source" do
      assert {:ok, result} =
               Commands.model_policy(%{"surface" => "swarm_run", "model" => "claude-opus-5"})

      assert result.surface == "swarm_run"
      assert result.model == "claude-opus-5"

      assert {:ok, listing} = Commands.model_policy()
      assert entry(listing, "swarm_run").model == "claude-opus-5"
      assert entry(listing, "swarm_run").source == "surface"

      assert %{surface: "swarm_run", backend: "claude", model: "claude-opus-5"} in listing.operator_set.models
    end

    test "clear removes an entry so the surface inherits again" do
      assert {:ok, _} =
               Commands.model_policy(%{"surface" => "default", "model" => "claude-sonnet-5"})

      assert {:ok, _} = Commands.model_policy(%{"surface" => "chat", "model" => "claude-opus-5"})
      assert {:ok, _} = Commands.model_policy(%{"surface" => "chat", "clear" => true})

      assert {:ok, listing} = Commands.model_policy()
      assert entry(listing, "chat").model == "claude-sonnet-5"
      assert entry(listing, "chat").source == "default"
    end

    test "clearing the default returns every surface to the CLI" do
      assert {:ok, _} =
               Commands.model_policy(%{"surface" => "default", "model" => "claude-opus-5"})

      assert {:ok, _} = Commands.model_policy(%{"surface" => "default", "clear" => true})

      assert {:ok, listing} = Commands.model_policy()
      assert Enum.all?(listing.in_force, &(&1.model == nil and &1.source == "cli"))
      assert listing.operator_set == %{backends: [], models: []}
    end
  end

  describe "refusals" do
    test "an unknown surface names the valid ones instead of crashing" do
      assert {:error, {:unknown_surface, "trading", valid}} =
               Commands.model_policy(%{"surface" => "trading", "model" => "claude-opus-5"})

      assert "dispatcher" in valid
      assert "default" in valid
      assert ModelPolicy.stored() == %{backends: %{}, models: %{}}
    end

    test "a blank model is refused with the way to unset instead" do
      assert {:error, {:blank_model, hint}} =
               Commands.model_policy(%{"surface" => "chat", "model" => "   "})

      assert hint =~ "clear"
      assert ModelPolicy.stored() == %{backends: %{}, models: %{}}
    end

    test "naming a surface with no model at all is an error, not a silent clear" do
      assert {:error, {:missing_model, hint}} = Commands.model_policy(%{"surface" => "chat"})
      assert hint =~ "clear"
    end
  end

  describe "the trust boundary" do
    # Not a judgement call. This command can lower the model on :order_submit,
    # the irreversible money path — an unattended token must not be able to
    # downgrade it quietly, and neither must a run reading untrusted content.
    test "the command is restricted and gated" do
      assert Commands.command_tier("model_policy") == :restricted
      assert Commands.command_gated?("model_policy")
    end

    test "an MCP caller is refused rather than allowed to downgrade a surface" do
      assert {:error, :requires_confirmation} =
               Commands.call(
                 "model_policy",
                 %{"surface" => "order_submit", "model" => "claude-haiku-4-5"},
                 caller: :mcp
               )

      assert ModelPolicy.for_surface(:order_submit) == nil
    end

    test "an untrusted agent run is refused too — that is what gated buys" do
      assert {:error, :requires_confirmation} =
               Commands.call(
                 "model_policy",
                 %{"surface" => "order_submit", "model" => "claude-haiku-4-5"},
                 caller: :agent_untrusted
               )

      assert ModelPolicy.stored() == %{backends: %{}, models: %{}}
    end
  end

  describe "the catalog entry" do
    test "offers exactly the surfaces that exist" do
      %{args: args} = Enum.find(Commands.list_commands(), &(&1.name == "model_policy"))

      assert args["surface"].enum ==
               ["default" | Enum.map(ModelPolicy.surface_keys(), &Atom.to_string/1)]
    end
  end
end
