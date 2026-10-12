defmodule BusterClawWeb.VoxCommandRemovalTest do
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.Commands

  @removed ~w(
    voice_clip_make voice_clip_list voice_clip_delete
    voice_message_create voice_message_list voice_message_fire voice_message_delete
  )

  setup do
    root = Path.join(System.tmp_dir!(), "bc_vox_commands_#{System.unique_integer([:positive])}")
    previous_root = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, previous_root)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "the CLI/API discovery catalog and safe-tier catalog omit the removed commands", %{
    conn: conn
  } do
    assert %{"ok" => true, "commands" => entries} =
             conn |> get(~p"/api/commands") |> json_response(200)

    names = Enum.map(entries, & &1["name"])
    safe_names = Enum.map(Commands.safe_commands(), & &1.name)

    for name <- @removed do
      refute name in names
      refute name in safe_names
      assert Commands.command_type(name) == nil
    end

    for name <- ~w(notify_create notify_list sound_import sound_apply sound_record) do
      assert name in names
    end
  end

  test "removed commands return the normal unknown response for trusted and MCP-tier callers" do
    # The MCP server was retired earlier; its safe API token tier still shares
    # this endpoint and dispatcher with the CLI.
    for token <- ["test-token-loopback-only", "test-mcp-token-safe-tier-only"],
        name <- @removed do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/run", %{"command" => name, "args" => %{}})

      assert %{"ok" => false, "error" => "unknown_command"} = json_response(conn, 404)
    end

    for caller <- [:trusted, :mcp], name <- @removed do
      assert {:error, :unknown_command} = Commands.call(name, %{}, caller: caller)
    end
  end
end
