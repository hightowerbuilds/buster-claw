defmodule BusterClaw.SetupTest do
  use BusterClaw.DataCase

  alias BusterClaw.Google
  alias BusterClaw.Providers
  alias BusterClaw.Setup

  test "fresh install reports 0 of 4 complete" do
    status = Setup.status()
    assert status.completed == 0
    assert status.total == 4
    refute status.complete?
  end

  test "profile completes with either a name or an org" do
    refute Setup.profile_complete?()

    Setup.put_profile("", "Acme Corp")
    assert Setup.profile_complete?()

    Setup.put_profile("", "")
    refute Setup.profile_complete?()

    Setup.put_profile("Ada", "")
    assert Setup.profile_complete?()
  end

  test "workspace completes only after explicit confirmation" do
    refute Setup.workspace_complete?()
    Setup.confirm_workspace()
    assert Setup.workspace_complete?()
  end

  test "google and provider steps derive from real state" do
    refute Setup.google_complete?()
    refute Setup.provider_complete?()

    {:ok, _} =
      Google.upsert_account(%{"email" => "a@b.com", "client_id" => "cid", "enabled" => true})

    {:ok, _} =
      Providers.create_provider(%{"type" => "ollama", "model" => "llama3", "name" => "local"})

    assert Setup.google_complete?()
    assert Setup.provider_complete?()
  end

  test "completing all steps flips complete? and the count" do
    Setup.put_profile("Ada", "")
    Setup.confirm_workspace()

    {:ok, _} =
      Google.upsert_account(%{"email" => "a@b.com", "client_id" => "cid", "enabled" => true})

    {:ok, _} =
      Providers.create_provider(%{"type" => "ollama", "model" => "llama3", "name" => "local"})

    status = Setup.status()
    assert status.completed == 4
    assert status.complete?
  end
end
