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

      assert listing.operator_set == []
      assert "default" in listing.surfaces
      assert "claude-opus-5" in listing.known_models
    end

    # Printing the model alone would leave the operator staring at a trading
    # surface running something they never chose, with no reason given.
    test "names the floor, not just the model, when the floor is what decided" do
      assert {:ok, _} =
               Commands.model_policy(%{"surface" => "default", "model" => "claude-haiku-4-5"})

      assert {:ok, listing} = Commands.model_policy()

      trading = entry(listing, "trading_read")
      assert trading.model == "claude-sonnet-5"
      assert trading.source == "floor"
      assert trading.floor == "claude-sonnet-5"

      # A surface with no floor shows the default it actually got.
      chat = entry(listing, "chat")
      assert chat.model == "claude-haiku-4-5"
      assert chat.source == "default"
      assert chat.floor == nil
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
      assert %{surface: "swarm_run", model: "claude-opus-5"} in listing.operator_set
    end

    # The 07-28 measurement, as a command-level regression guard: a cheaper
    # model on a trading read invoked the broker tool in 1 of 2 runs and
    # INVENTED the answer on the miss. Lowering the global default is the cheap
    # gesture; it must not be the gesture that reaches the money path.
    test "a cheap global default does not change what order_submit runs" do
      assert {:ok, _} =
               Commands.model_policy(%{"surface" => "default", "model" => "claude-haiku-4-5"})

      assert {:ok, listing} = Commands.model_policy()
      assert entry(listing, "order_submit").model == "claude-sonnet-5"
      assert entry(listing, "order_submit").source == "floor"
      assert ModelPolicy.for_surface(:order_submit) == "claude-sonnet-5"
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
      assert listing.operator_set == []
    end
  end

  describe "refusals" do
    test "an unknown surface names the valid ones instead of crashing" do
      assert {:error, {:unknown_surface, "trading", valid}} =
               Commands.model_policy(%{"surface" => "trading", "model" => "claude-opus-5"})

      assert "trading_read" in valid
      assert "default" in valid
      assert ModelPolicy.stored() == %{}
    end

    test "a blank model is refused with the way to unset instead" do
      assert {:error, {:blank_model, hint}} =
               Commands.model_policy(%{"surface" => "chat", "model" => "   "})

      assert hint =~ "clear"
      assert ModelPolicy.stored() == %{}
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

      assert ModelPolicy.stored() == %{}
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
