defmodule BusterClaw.Clinch.AppKeysTest do
  @moduledoc """
  Phase 3b: the app's own credentials resolve **at the moment of use**, not at
  boot, so a key typed into Settings works without restarting and a deleted one
  stops working on the next call.

  These assert the property that made the change necessary. `Application.get_env`
  is resolved when the app starts; a packaged `.app` inherits launchd's
  environment rather than your shell's, so an env-only credential is invisible to
  the shipped product no matter what your terminal shows.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Clinch
  alias BusterClaw.Clinch.AppKeys
  alias BusterClaw.Telephony.Relay

  setup do
    prev_url = Application.get_env(:buster_claw, :telephony_relay_url)
    prev_key = Application.get_env(:buster_claw, :telephony_relay_key)

    on_exit(fn ->
      Application.put_env(:buster_claw, :telephony_relay_url, prev_url)
      Application.put_env(:buster_claw, :telephony_relay_key, prev_key)
    end)

    :ok
  end

  describe "resolution order" do
    test "the Clinch wins over the environment" do
      Application.put_env(:buster_claw, :finnhub_api_key, "from-env")
      assert AppKeys.get("finnhub_api_key") == "from-env"
      assert AppKeys.source("finnhub_api_key") == :env

      assert {:ok, _} = Clinch.put({:app_key, "finnhub_api_key"}, "from-clinch")

      assert AppKeys.get("finnhub_api_key") == "from-clinch"
      assert AppKeys.source("finnhub_api_key") == :clinch
    end

    test "the environment is still the fallback, so dev and CI keep working" do
      Application.put_env(:buster_claw, :finnhub_api_key, "from-env")
      assert AppKeys.get("finnhub_api_key") == "from-env"
    end

    test "deleting the stored value falls back rather than going dark" do
      Application.put_env(:buster_claw, :finnhub_api_key, "from-env")
      assert {:ok, _} = Clinch.put({:app_key, "finnhub_api_key"}, "from-clinch")
      assert AppKeys.get("finnhub_api_key") == "from-clinch"

      assert {:ok, _} = Clinch.delete({:app_key, "finnhub_api_key"})

      assert AppKeys.get("finnhub_api_key") == "from-env"
      assert AppKeys.source("finnhub_api_key") == :env
    end

    test "unset is reported as unset, not as an empty string" do
      Application.put_env(:buster_claw, :finnhub_api_key, nil)
      assert AppKeys.get("finnhub_api_key") == nil
      assert AppKeys.source("finnhub_api_key") == :unset
    end

    test "a blank environment value counts as unset" do
      Application.put_env(:buster_claw, :finnhub_api_key, "   ")
      assert AppKeys.get("finnhub_api_key") == nil
      assert AppKeys.source("finnhub_api_key") == :unset
    end

    test "an unknown name is nil rather than a crash" do
      assert AppKeys.get("not_a_real_key") == nil
      assert AppKeys.definition("not_a_real_key") == nil
    end
  end

  describe "reads are live, which is the whole point" do
    test "storing the relay pair configures it with no restart" do
      Application.put_env(:buster_claw, :telephony_relay_url, nil)
      Application.put_env(:buster_claw, :telephony_relay_key, nil)

      refute Relay.configured?(), "precondition: the relay must start unconfigured"

      assert {:ok, _} = Clinch.put({:app_key, "supabase_url"}, "https://x.supabase.co")
      assert {:ok, _} = Clinch.put({:app_key, "supabase_service_role_key"}, "service-role")

      # No restart, no re-read of config, no supervisor change.
      assert Relay.configured?()
    end

    test "deleting a credential un-configures it on the next call" do
      Application.put_env(:buster_claw, :telephony_relay_url, nil)
      Application.put_env(:buster_claw, :telephony_relay_key, nil)

      assert {:ok, _} = Clinch.put({:app_key, "supabase_url"}, "https://x.supabase.co")
      assert {:ok, _} = Clinch.put({:app_key, "supabase_service_role_key"}, "service-role")
      assert Relay.configured?()

      assert {:ok, _} = Clinch.delete({:app_key, "supabase_service_role_key"})

      refute Relay.configured?(), "revocation must take effect without a restart"
    end
  end

  describe "the registry" do
    test "every name has a definition, and every definition resolves" do
      refute Enum.empty?(AppKeys.all())

      for key <- AppKeys.all() do
        assert key.name in AppKeys.names()
        assert AppKeys.definition(key.name) == key
        # Every registered key must be readable — a name in the list that get/1
        # cannot resolve is a row the settings screen would render and then fail
        # to save against.
        assert AppKeys.source(key.name) in [:clinch, :env, :unset]
      end
    end

    test "names are storable — the registry cannot list a name the Clinch refuses" do
      for key <- AppKeys.all() do
        assert {:ok, _} = Clinch.put({:app_key, key.name}, "value-for-#{key.name}"),
               "#{key.name} is in the registry but the Clinch will not store it — " <>
                 "the name probably breaks Types.name_format/0"
      end
    end
  end

  describe "audit" do
    test "config reads do not write security events" do
      assert {:ok, _} = Clinch.put({:app_key, "finnhub_api_key"}, "from-clinch")
      before = Repo.aggregate("security_events", :count)

      for _ <- 1..5, do: AppKeys.get("finnhub_api_key")

      assert Repo.aggregate("security_events", :count) == before,
             "a poller reading its own configuration must not bury the audit feed — " <>
               "AppKeys resolves with audit: false, and agent $secret use stays audited"
    end
  end
end
