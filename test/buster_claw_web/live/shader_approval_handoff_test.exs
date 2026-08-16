defmodule BusterClawWeb.ShaderApprovalHandoffTest do
  @moduledoc """
  The handoff — `AGENT_APPLIED_SHADERS_ROADMAP`, end to end.

  Four layers were built in parallel by four agents on disjoint files, and each
  proved its own half: the store hashes, the page mints, the command consults,
  the docs say so. **Nothing proved they meet.** This does, in the only order a
  person will actually perform:

      the operator clicks a workspace shader  →  the model applies it by name

  It is deliberately not in any of those four suites. A seam that lives inside
  one side's test file gets maintained by whoever owns that side, and this one
  has no owner — which is exactly why it is the part most likely to be missing.
  """
  # async: false — points the global :workspace_root at a tmp dir and writes
  # app_settings rows through the shared Settings store.
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Appearance
  alias BusterClaw.Commands

  setup do
    root = Path.join(System.tmp_dir!(), "bc_handoff_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "shaders"))
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    # Drain the day-one backfill against the empty workspace, so every shader
    # written below is a genuinely new file that needs the click. Without this
    # the whole suite passes on the grant and never exercises the handoff.
    Appearance.approved_shaders()

    {:ok, root: root}
  end

  defp write_shader(root, name, tint \\ "1.0") do
    File.write!(
      Path.join([root, "shaders", name <> ".wgsl"]),
      "@fragment\nfn fs_main(in: VOut) -> @location(0) vec4<f32> { return vec4<f32>(#{tint}); }\n"
    )
  end

  defp apply_by_command(mode) do
    Commands.call("background_set", %{"surface" => "terminal", "mode" => mode})
  end

  test "the operator clicks once, and the model can apply it from then on",
       %{conn: conn, root: root} do
    write_shader(root, "nebula")

    # 1. Before the click, the command refuses — and the refusal is the one the
    #    roadmap requires: it names the fix rather than just saying no.
    assert {:error, message} = apply_by_command("nebula")
    assert message =~ "Settings → Appearance"
    assert Appearance.background(:terminal).shader != "nebula"

    # 2. background_list says so in advance, so a model never has to discover
    #    the boundary by being refused (VI.2).
    assert {:ok, before} = Commands.call("background_list", %{})
    assert option(before, "nebula").approved == false

    # 3. The operator clicks it on the Appearance page.
    {:ok, view, _html} = live(conn, "/appearance")

    view
    |> element("[data-bg-option='nebula'] button[phx-value-surface='home']")
    |> render_click()

    # 4. And now the command works — on the OTHER surface, because approval is
    #    keyed by shader rather than by surface (VI.3). A per-surface store
    #    would pass every test above and fail here.
    assert {:ok, _result} = apply_by_command("nebula")
    assert Appearance.background(:terminal).shader == "nebula"

    assert {:ok, listing} = Commands.call("background_list", %{})
    assert option(listing, "nebula").approved == true
  end

  test "the model editing the shader takes the capability back", %{conn: conn, root: root} do
    write_shader(root, "nebula")

    {:ok, view, _html} = live(conn, "/appearance")

    view
    |> element("[data-bg-option='nebula'] button[phx-value-surface='home']")
    |> render_click()

    assert {:ok, _} = apply_by_command("nebula")

    # The whole point of hashing the contents. What the operator approved was the
    # code they were shown; different code is a different question, and a store
    # keyed on the name would answer the old one.
    write_shader(root, "nebula", "0.25")

    assert {:error, message} = apply_by_command("nebula")
    assert message =~ "Settings → Appearance"

    assert {:ok, listing} = Commands.call("background_list", %{})
    assert option(listing, "nebula").approved == false
  end

  test "approval never crosses from one shader to another", %{conn: conn, root: root} do
    write_shader(root, "nebula")
    write_shader(root, "stranger")

    {:ok, view, _html} = live(conn, "/appearance")

    view
    |> element("[data-bg-option='nebula'] button[phx-value-surface='home']")
    |> render_click()

    assert {:ok, _} = apply_by_command("nebula")
    assert {:error, _} = apply_by_command("stranger")
  end

  defp option(listing, key), do: Enum.find(listing.options, &(&1.key == key))
end
