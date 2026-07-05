defmodule BusterClawWeb.CmdListLiveTest do
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Sentinel
  alias BusterClaw.Settings
  alias BusterClaw.TerminalCommands

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
    assert Settings.get(TerminalCommands.settings_key()) == nil

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
    assert Settings.get(TerminalCommands.settings_key()) == nil
  end

  test "a forged submit against a protected role is refused and audited", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    render_submit(view, "save_role", %{
      "role_key" => "mailman",
      "role" => %{"commands" => %{"0" => %{"key" => "on-duty", "command" => "evil"}}}
    })

    assert render(view) =~ "protected and cannot be edited"
    assert Settings.get(TerminalCommands.settings_key()) == nil
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
    assert Settings.get(TerminalCommands.settings_key()) == nil
  end

  test "multiline text in a shell command is rejected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    params = put_command(role_params("toolbox"), "0", "command", "echo hi\nrm -rf /")
    render_submit(view, "save_role", %{"role_key" => "toolbox", "role" => params})

    assert render(view) =~ "must be a single line"
    assert Settings.get(TerminalCommands.settings_key()) == nil
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

  test "reset_role on a protected role is refused", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    render_click(view, "reset_role", %{"role_key" => "mailman"})

    assert render(view) =~ "protected and cannot be edited"
  end

  test "reset all deletes the user catalog entirely", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cmd-list")

    params = put_command(role_params("toolbox"), "0", "command", "./custom")
    render_submit(view, "save_role", %{"role_key" => "toolbox", "role" => params})
    assert Settings.get(TerminalCommands.settings_key())

    render_click(view, "reset_all", %{})

    assert Settings.get(TerminalCommands.settings_key()) == nil
    assert render(view) =~ "restored to the shipped defaults"
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
