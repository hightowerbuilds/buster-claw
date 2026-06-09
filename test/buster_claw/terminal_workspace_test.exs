defmodule BusterClaw.TerminalWorkspaceTest do
  use ExUnit.Case, async: false

  alias BusterClaw.TerminalWorkspace

  setup do
    TerminalWorkspace.drain_pending()
    :ok
  end

  test "open/1 queues and broadcasts an in-app terminal request" do
    TerminalWorkspace.subscribe()

    assert {:ok, request} =
             TerminalWorkspace.open(%{
               "role_key" => "Mail Triage",
               "agent_name" => "Mail Agent",
               "label" => "Mail Triage",
               "purpose" => "Handle incoming email",
               "session_key" => "mail triage!"
             })

    assert request.role_key == "mail-triage"
    assert request.agent_name == "Mail Agent"
    assert request.label == "Mail Triage"
    assert request.purpose == "Handle incoming email"
    assert request.session_key == "mail-triage"
    assert request.startup_profile == "mailman"

    assert request.path ==
             "/terminal?session=mail-triage&label=Mail+Triage&startup_profile=mailman"

    assert request.activate == true

    assert_receive {:terminal_workspace, {:open, ^request}}
    assert [^request] = TerminalWorkspace.drain_pending()
  end

  test "open/1 requires a role key" do
    assert {:error, :missing_role_key} = TerminalWorkspace.open(%{})
    assert [] = TerminalWorkspace.drain_pending()
  end

  test "open/1 can queue without activating the tab" do
    assert {:ok, request} =
             TerminalWorkspace.open(%{
               "role_key" => "ci-fix",
               "activate" => false
             })

    assert request.activate == false
    assert request.label == "Ci Fix"
  end

  test "mailman can be requested as an explicit startup profile" do
    assert {:ok, request} =
             TerminalWorkspace.open(%{
               "role_key" => "email",
               "startup_profile" => "mailman"
             })

    assert request.startup_profile == "mailman"
    assert request.path =~ "startup_profile=mailman"
  end
end
