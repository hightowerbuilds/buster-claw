defmodule BusterClawWeb.CmdListLiveTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Sentinel
  alias BusterClaw.TerminalCommands

  setup do
    root = Path.join(System.tmp_dir!(), "bc_cmdlist_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    :ok
  end

  # Full editor params for a role, built the same way the rendered form posts
  # them (indexed map, no embed ids — the handler's base matches positionally).
  defp role_params(role_key, overrides \\ %{}) do
    base = TerminalCommands.role_edit(role_key)

    commands =
      base.commands
      |> Enum.with_index()
      |> Map.new(fn {c, i} ->
        {to_string(i),
         %{
           "key" => c.key,
           "label" => c.label || "",
           "description" => c.description || "",
           "command" => c.command,
           "kind" => c.kind
         }}
      end)

    Map.merge(%{"commands" => commands, "default_key" => base.default_key || ""}, overrides)
  end

  defp put_command(params, index, field, value),
    do: put_in(params, ["commands", index, field], value)

  defp write_skill(name) do
    dir = BusterClaw.Library.Artifact.workspace_path("skills")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "#{name}.md"), """
    ---
    name: #{name}
    description: The #{name} skill.
    tier: safe
    enabled: true
    handler_kind: composition
    args: {}
    steps: [{"command":"runtime_status","args":{}}]
    ---

    # #{name}
    """)
  end

  defp catalog_doc do
    case File.read(TerminalCommands.catalog_path()) do
      {:ok, json} -> Jason.decode!(json)
      _ -> nil
    end
  end

  test "renders protected roles read-only and editable roles as forms", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/cmd-list")

    # Protected: no form, no delete/reset controls, lock + note shown.
    refute has_element?(view, "#cmd-list-form-mailman")
    refute has_element?(view, "#cmd-list-reset-mailman")
    assert has_element?(view, "#cmd-list-role-mailman [aria-label='Protected']")
    assert html =~ "Part of the shift safety surface"
    assert has_element?(view, "#cmd-list-row-mailman-on-duty")

    # agent-setup is protected too (hidden from the menu, still shown here).
    refute has_element?(view, "#cmd-list-form-agent-setup")

    # Editable roles get forms with save/reset/add controls.
    for role <- ~w(queue toolbox prompts) do
      assert has_element?(view, "#cmd-list-form-#{role}")
      assert has_element?(view, "#cmd-list-save-#{role}")
      assert has_element?(view, "#cmd-list-reset-#{role}")
      assert has_element?(view, "#cmd-list-add-#{role}")
    end
  end

  test "editing a command persists, survives reload, and reaches the terminal flyout", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    params = put_command(role_params("toolbox"), "0", "command", "./buster-claw commands --json")
    render_submit(view, "save_role", %{"role_key" => "toolbox", "role" => params})

    assert render(view) =~ "Saved."
    assert render(view) =~ "./buster-claw commands --json"

    # Survives a fresh mount.
    {:ok, view2, _html} = live(conn, ~p"/cmd-list")
    assert render(view2) =~ "./buster-claw commands --json"

    # And the already-open terminal flyout picks it up via PubSub.
    {:ok, terminal, _html} = live(conn, ~p"/terminal")
    terminal |> element("button[data-terminal-commands-button]") |> render_click()
    assert render(terminal) =~ "./buster-claw commands --json"
  end

  test "choosing a startup default changes what the profile runs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    refute TerminalCommands.startup_command("toolbox")

    params = Map.put(role_params("toolbox"), "default_key", "runtime-status")
    render_submit(view, "save_role", %{"role_key" => "toolbox", "role" => params})

    assert TerminalCommands.startup_command("toolbox") == "./buster-claw run runtime_status"
  end

  test "adding a command stages a row, saving persists it, deleting removes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    # Stage a new row via the sort param (the Add command checkbox). The new
    # row appends after the existing built-in prompts, so its index is the
    # current command count.
    params = role_params("prompts")
    new_index = to_string(map_size(params["commands"]))
    staged = Map.put(params, "commands_sort", Map.keys(params["commands"]) ++ ["new"])
    render_change(view, "validate", %{"role_key" => "prompts", "role" => staged})

    # The staged row renders but nothing persists yet.
    assert has_element?(view, "#cmd-list-prompts_commands_#{new_index}_command")
    refute File.exists?(TerminalCommands.catalog_path())

    # Fill it in and save.
    filled =
      put_in(params, ["commands", new_index], %{
        "key" => "",
        "label" => "Mine",
        "command" => "say hello",
        "kind" => "prompt"
      })

    render_submit(view, "save_role", %{"role_key" => "prompts", "role" => filled})

    prompts = TerminalCommands.roles() |> Enum.find(&(&1.key == "prompts"))
    mine = Enum.find(prompts.commands, &(&1.label == "Mine"))
    assert mine.command == "say hello"
    refute mine.builtin

    # Delete it again via the drop param, keyed to the merged row.
    params = role_params("prompts")
    dropped = Map.put(params, "commands_drop", [new_index])
    render_submit(view, "save_role", %{"role_key" => "prompts", "role" => dropped})

    prompts = TerminalCommands.roles() |> Enum.find(&(&1.key == "prompts"))
    refute Enum.any?(prompts.commands, &(&1.label == "Mine"))
  end

  test "dropping a built-in command is refused server-side", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    params = role_params("toolbox")
    forged = Map.put(params, "commands_drop", ["0"])
    render_submit(view, "save_role", %{"role_key" => "toolbox", "role" => forged})

    assert render(view) =~ "built-in commands cannot be deleted"
    refute File.exists?(TerminalCommands.catalog_path())
  end

  test "a forged submit against a protected role is refused and audited", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    render_submit(view, "save_role", %{
      "role_key" => "mailman",
      "role" => %{"commands" => %{"0" => %{"key" => "on-duty", "command" => "evil"}}}
    })

    assert render(view) =~ "protected and cannot be edited"
    refute File.exists?(TerminalCommands.catalog_path())
    assert TerminalCommands.startup_command("mailman") == "./buster-claw on-duty"

    assert Enum.any?(
             Sentinel.list_events(),
             &(&1.category == "settings_change" and &1.severity == "warning")
           )
  end

  test "a validation error renders in the form and blocks the save", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    params = put_command(role_params("toolbox"), "0", "command", "")
    render_submit(view, "save_role", %{"role_key" => "toolbox", "role" => params})

    assert render(view) =~ "can&#39;t be blank"
    refute File.exists?(TerminalCommands.catalog_path())
  end

  test "multiline text in a shell command is rejected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    params = put_command(role_params("toolbox"), "0", "command", "echo hi\nrm -rf /")
    render_submit(view, "save_role", %{"role_key" => "toolbox", "role" => params})

    assert render(view) =~ "must be a single line"
    refute File.exists?(TerminalCommands.catalog_path())
  end

  test "reset role restores the shipped commands", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    params = put_command(role_params("toolbox"), "0", "command", "./custom")
    render_submit(view, "save_role", %{"role_key" => "toolbox", "role" => params})
    assert render(view) =~ "./custom"

    render_click(view, "reset_role", %{"role_key" => "toolbox"})

    assert render(view) =~ "restored to the shipped commands"
    toolbox = TerminalCommands.roles() |> Enum.find(&(&1.key == "toolbox"))
    assert Enum.find(toolbox.commands, &(&1.key == "commands-list")).command ==
             "./buster-claw commands"
  end

  test "skill-generated prompts render read-only and never persist on save", %{conn: conn} do
    write_skill("save-note")

    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    # The generated prompt shows as a read-only row (with a skills/… badge) and
    # exposes no editable input.
    assert has_element?(view, "#cmd-list-generated-prompts-skill-save-note")
    assert render(view) =~ "skills/save-note.md"
    assert render(view) =~ "From your skills folder"
    refute has_element?(view, "#cmd-list-prompts_commands_0_command[value*='save-note']")

    # Saving the prompts role (its editable base is just welcome-introduction)
    # must not serialize the generated row into the catalog file.
    render_submit(view, "save_role", %{
      "role_key" => "prompts",
      "role" => role_params("prompts")
    })

    prompts = Enum.find(catalog_doc()["roles"], &(&1["key"] == "prompts"))
    refute Enum.any?(prompts["commands"] || [], &(&1["key"] == "skill-save-note"))

    # ...yet it still appears in the live terminal flyout.
    {:ok, terminal, _html} = live(conn, ~p"/terminal")
    terminal |> element("button[data-terminal-commands-button]") |> render_click()
    assert render(terminal) =~ "Skill — Save Note"
  end

  test "an override row shadows the generated skill prompt", %{conn: conn} do
    write_skill("save-note")

    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    # Add a same-key row with custom wording and save.
    params = role_params("prompts")
    new_index = to_string(map_size(params["commands"]))
    staged = Map.put(params, "commands_sort", Map.keys(params["commands"]) ++ ["new"])
    render_change(view, "validate", %{"role_key" => "prompts", "role" => staged})

    filled =
      put_in(params, ["commands", new_index], %{
        "key" => "skill-save-note",
        "label" => "My Save Note",
        "command" => "My own wording.",
        "kind" => "prompt"
      })

    render_submit(view, "save_role", %{"role_key" => "prompts", "role" => filled})

    row =
      TerminalCommands.role("prompts").commands
      |> Enum.filter(&(&1.key == "skill-save-note"))

    # Exactly one row for the key, and it's the user's (not generated).
    assert [%{command: "My own wording.", generated: false}] = row
  end

  test "reset_role on a protected role is refused", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    render_click(view, "reset_role", %{"role_key" => "mailman"})

    assert render(view) =~ "protected and cannot be edited"
  end

  test "reset all restores the shipped defaults", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    params = put_command(role_params("toolbox"), "0", "command", "./custom")
    render_submit(view, "save_role", %{"role_key" => "toolbox", "role" => params})
    assert File.exists?(TerminalCommands.catalog_path())
    assert render(view) =~ "./custom"

    render_click(view, "reset_all", %{})

    assert render(view) =~ "restored to the shipped defaults"
    refute render(view) =~ "./custom"

    assert TerminalCommands.role("toolbox").commands
           |> Enum.find(&(&1.key == "commands-list"))
           |> Map.get(:command) == "./buster-claw commands"
  end

  test "an open terminal refreshes its flyout when another session edits", %{conn: conn} do
    {:ok, terminal, _html} = live(conn, ~p"/terminal")
    terminal |> element("button[data-terminal-commands-button]") |> render_click()
    refute render(terminal) =~ "./buster-claw commands --json"

    # Edit arrives from elsewhere (another tab / the CLI) via put_catalog,
    # which broadcasts to the subscribed terminal.
    doc = %{
      "version" => 1,
      "roles" => [
        %{
          "key" => "toolbox",
          "commands" => [
            %{"key" => "commands-list", "command" => "./buster-claw commands --json"}
          ]
        }
      ]
    }

    assert :ok = TerminalCommands.put_catalog(doc)

    assert render(terminal) =~ "./buster-claw commands --json"
  end
end
