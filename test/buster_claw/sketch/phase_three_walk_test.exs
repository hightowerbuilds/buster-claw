defmodule BusterClaw.Sketch.PhaseThreeWalkTest do
  @moduledoc """
  The Phase 3 walk — written before the phase was built, and deliberately owned
  by neither half of it.

  The command layer and the drawing surface were built in parallel against a
  pinned contract (`Element`'s `:text` kind, `Document`, `Authorship`). That is
  the arrangement this repo already found works, and it comes with a rule: **the
  end-to-end test is written by the integrator, not by either side**, because a
  test written beside an implementation inherits its blind spot, and two of those
  inherit each other's.

  So this asserts the seams rather than the parts:

  * `D6` — the model may change and delete what the model drew, and asking about
    the operator's marks. The single decision the whole phase exists for.
  * `D5` — an unknown id is refused **by name**, never silently skipped.
  * The stamp — an element's author is decided by *who called*, never by what the
    caller said.
  * Escaping — model-supplied text reaches an SVG renderer, and this is where a
    quoted string stops being data.
  """
  use ExUnit.Case, async: false

  alias BusterClaw.Commands
  alias BusterClaw.Sketch.{Authorship, Document, Element, Store, Svg}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_p3_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  # The operator's own drawing, made the way the surface makes one.
  defp operator_sketch(name) do
    {:ok, mark} =
      Element.new(%{
        "kind" => "stroke",
        "author" => "operator",
        "points" => [[10, 10], [90, 90]],
        "color" => "#F4F1EA",
        "width" => 2
      })

    {:ok, _} = Store.save(name, Document.add(Document.new(%{title: name}), mark))
    mark
  end

  defp load!(name) do
    {:ok, doc} = Store.load(name)
    doc
  end

  defp model_adds(name, attrs) do
    Commands.call("sketch_add", Map.put(attrs, "name", name), caller: :agent_untrusted)
  end

  describe "the model draws on its own work" do
    test "adds a mark, and it is stamped as the model's" do
      operator_sketch("plan")

      assert {:ok, _} =
               model_adds("plan", %{
                 "kind" => "text",
                 "content" => "this button is unreachable",
                 "color" => "#FF4D1C",
                 "size" => 18,
                 "x" => 120,
                 "y" => 60
               })

      doc = load!("plan")
      added = Enum.find(doc.elements, &(&1.kind == :text))

      assert added.author == :model, "an unstamped mark is one the model may never touch again"
      assert added.content == "this button is unreachable"
    end

    test "changes and removes what it added, with no confirmation in the way" do
      # The half of D6 that makes the model useful at all: iterate freely — draw,
      # look, redraw, delete a false start — without asking each time.
      operator_sketch("plan")

      {:ok, _} =
        model_adds("plan", %{
          "kind" => "text",
          "content" => "draft",
          "color" => "#FF4D1C",
          "x" => 10,
          "y" => 10
        })

      mine = Enum.find(load!("plan").elements, &(&1.author == :model))

      assert {:ok, _} =
               Commands.call(
                 "sketch_update",
                 %{"name" => "plan", "id" => mine.id, "content" => "revised"},
                 caller: :agent_untrusted
               )

      assert {:ok, _} =
               Commands.call("sketch_delete", %{"name" => "plan", "id" => mine.id},
                 caller: :agent_untrusted
               )

      refute Enum.any?(load!("plan").elements, &(&1.id == mine.id))
    end
  end

  describe "the model is gated on the operator's work — the whole point of D6" do
    test "deleting an operator's mark asks rather than doing it" do
      # This is the Cleo failure mode refused structurally: an agent reverting a
      # user's edit because it conflicts with the agent's own plan. Gated, not
      # blocked — the operator can still say yes.
      mark = operator_sketch("plan")

      assert {:error, :requires_confirmation} =
               Commands.call("sketch_delete", %{"name" => "plan", "id" => mark.id},
                 caller: :agent_untrusted
               )

      assert Enum.any?(load!("plan").elements, &(&1.id == mark.id)),
             "the operator's mark was removed by a call that reported it had not been"
    end

    test "moving an operator's mark asks too" do
      mark = operator_sketch("plan")

      assert {:error, :requires_confirmation} =
               Commands.call(
                 "sketch_update",
                 %{"name" => "plan", "id" => mark.id, "dx" => 20, "dy" => 0},
                 caller: :agent_untrusted
               )

      assert load!("plan").elements |> hd() |> Map.get(:points) == [[10.0, 10.0], [90.0, 90.0]]
    end

    test "every agent tier is bounded, not just the untrusted one" do
      # `:agent` and `:mcp` are narrower than `:agent_untrusted`, so a rule that
      # only caught the untrusted tier would be the wrong shape rather than a
      # partial one.
      mark = operator_sketch("plan")

      for caller <- [:agent, :agent_untrusted, :mcp] do
        assert {:error, reason} =
                 Commands.call("sketch_delete", %{"name" => "plan", "id" => mark.id},
                   caller: caller
                 )

        assert reason in [:requires_confirmation, :policy_blocked],
               "#{caller} was allowed to delete an operator's mark"
      end
    end

    test "the operator is not subject to their own boundary" do
      mark = operator_sketch("plan")

      assert {:ok, _} =
               Commands.call("sketch_delete", %{"name" => "plan", "id" => mark.id},
                 caller: :trusted
               )

      assert load!("plan").elements == []
    end
  end

  describe "D5 — refused by name, never silently" do
    test "an unknown id is not found rather than quietly doing nothing" do
      # "The delete did nothing" is the failure that cannot be diagnosed from
      # outside, and a model that believes it succeeded will build on it.
      operator_sketch("plan")

      assert {:error, :not_found} =
               Commands.call("sketch_delete", %{"name" => "plan", "id" => "el_nope"},
                 caller: :agent_untrusted
               )

      assert {:error, :not_found} =
               Commands.call(
                 "sketch_update",
                 %{"name" => "plan", "id" => "el_nope", "dx" => 1, "dy" => 1},
                 caller: :agent_untrusted
               )
    end
  end

  describe "what the caller says about itself is ignored" do
    test "a model cannot claim an element is the operator's, or choose its id" do
      # Either would defeat D6 with a field: claiming `operator` makes a mark the
      # model can never touch again; choosing an id lets it address one it does
      # not own.
      operator_sketch("plan")

      {:ok, _} =
        model_adds("plan", %{
          "kind" => "text",
          "content" => "mine",
          "color" => "#FF4D1C",
          "x" => 5,
          "y" => 5,
          "author" => "operator",
          "id" => "el_chosen_by_the_model"
        })

      added = Enum.find(load!("plan").elements, &(&1.kind == :text))

      assert added.author == :model
      refute added.id == "el_chosen_by_the_model"
    end
  end

  describe "model-supplied text reaches a renderer" do
    test "markup in a label is escaped, not rendered" do
      # The one place in this phase where a model-supplied STRING becomes part of
      # a document that something parses. A sketch is drawn from validated data
      # precisely so no model-authored markup ever reaches a DOM — a label is the
      # exception that has to be escaped rather than trusted.
      {:ok, label} =
        Element.new(%{
          "kind" => "text",
          "author" => "model",
          "content" => ~s[</text><script>alert("x")</script> & more],
          "color" => "#FF4D1C",
          "x" => 10,
          "y" => 10
        })

      svg = Svg.to_document(Document.add(Document.new(), label), sketch: "plan")

      refute svg =~ "<script>", "model-supplied text was rendered as markup"
      assert svg =~ "&lt;" or svg =~ "&amp;lt;"
      assert svg =~ "&amp;"
    end
  end

  describe "the contract the two halves were built against" do
    test "authorship answers the same question the commands ask" do
      # Both halves call this rather than testing caller atoms themselves. If it
      # ever disagreed with the commands, the surface and the command layer would
      # enforce different rules and only one of them would be D6.
      {:ok, theirs} =
        Element.new(%{
          "kind" => "text",
          "content" => "a",
          "color" => "#FF4D1C",
          "x" => 1,
          "y" => 1
        })

      {:ok, mine} =
        Element.new(%{
          "kind" => "text",
          "content" => "b",
          "color" => "#FF4D1C",
          "x" => 1,
          "y" => 1,
          "author" => "model"
        })

      assert Authorship.check_element(theirs, :agent_untrusted) ==
               {:error, :requires_confirmation}

      assert Authorship.check_element(mine, :agent_untrusted) == :ok
      assert Authorship.check_element(theirs, :trusted) == :ok
      assert Authorship.author_for(:trusted) == :operator
      assert Authorship.author_for(:agent) == :model
    end
  end
end
