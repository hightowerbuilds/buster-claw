defmodule BusterClaw.ClinchTest do
  @moduledoc """
  The Clinch's contract: two verbs, and the line between them.

  The tests that matter most here are the negative ones. `list/0` returning no
  values, and `put/3` returning no value for the thing it just stored, are not
  incidental — they are the property the whole design rests on, and the kind of
  thing a convenience change would quietly undo.
  """
  use BusterClaw.DataCase, async: true

  alias BusterClaw.Clinch
  alias BusterClaw.Clinch.Types
  alias BusterClaw.Sentinel

  @ref {:sign_in, "acme-login"}
  @value "Hunter2!x"

  describe "use" do
    test "resolve/2 returns the plaintext for a stored credential" do
      assert {:ok, _} = Clinch.put(@ref, @value)
      assert {:ok, @value} = Clinch.resolve(@ref)
    end

    test "resolve/2 is :error for absent, unmanaged and malformed refs alike" do
      assert :error = Clinch.resolve({:sign_in, "never-stored"})
      assert :error = Clinch.resolve({:device_key, "laptop"})
      assert :error = Clinch.resolve({:sign_in, nil})
      assert :error = Clinch.resolve(:not_a_ref)
    end

    test "resolver/2 reads on demand, so a mid-run delete stops resolving" do
      assert {:ok, _} = Clinch.put(@ref, @value)
      resolve = Clinch.resolver(:sign_in)

      assert {:ok, @value} = resolve.("acme-login")
      assert {:ok, _} = Clinch.delete(@ref)
      assert :error = resolve.("acme-login")
    end

    test "a resolve emits a credential_use event carrying the name but never the value" do
      assert {:ok, _} = Clinch.put(@ref, @value)
      assert {:ok, @value} = Clinch.resolve(@ref, caller: :agent_untrusted)

      assert [event] =
               Sentinel.list_events(limit: 50)
               |> Enum.filter(&(&1.category == "credential_use"))

      assert event.metadata["name"] == "acme-login"
      assert event.metadata["kind"] == "sign_in"
      assert event.caller == "agent_untrusted"
      assert event.severity == "info"

      refute Jason.encode!(event) =~ @value
    end

    test "known?/1 does not record a use — an existence check consumes nothing" do
      assert {:ok, _} = Clinch.put(@ref, @value)
      assert Clinch.known?(@ref)
      refute Clinch.known?({:sign_in, "never-stored"})

      assert [] =
               Sentinel.list_events(limit: 50) |> Enum.filter(&(&1.category == "credential_use"))
    end
  end

  describe "manage" do
    test "put/3 returns the ref and note, never the value it just stored" do
      assert {:ok, entry} = Clinch.put(@ref, @value, note: "the acme account")

      assert entry.name == "acme-login"
      assert entry.note == "the acme account"
      assert entry.kind == :sign_in
      refute Map.has_key?(entry, :value)
    end

    test "put/3 replaces an existing name rather than duplicating it" do
      assert {:ok, _} = Clinch.put(@ref, "first")
      assert {:ok, _} = Clinch.put(@ref, "second")

      assert {:ok, "second"} = Clinch.resolve(@ref)
      assert [_only_one] = Clinch.list(:sign_in)
    end

    test "put/3 refuses an unmanaged kind rather than pretending to store it" do
      assert {:error, :unmanaged_kind} = Clinch.put({:device_key, "laptop"}, "ssh-ed25519 AAAA")
      assert {:error, :unmanaged_kind} = Clinch.put({:oauth, "a@b.com"}, "token")
    end

    test "put/3 refuses an empty value" do
      assert {:error, :missing_name_or_value} = Clinch.put(@ref, "")
      assert {:error, :missing_name_or_value} = Clinch.put(@ref, nil)
    end

    test "put/3 enforces the name grammar" do
      assert {:error, errors} = Clinch.put({:sign_in, "Not Allowed!"}, @value)
      assert errors[:name]
    end

    test "names are normalized so case and whitespace cannot fork a credential" do
      assert {:ok, _} = Clinch.put({:sign_in, "  ACME-Login  "}, @value)
      assert {:ok, @value} = Clinch.resolve(@ref)
      assert [%{name: "acme-login"}] = Clinch.list(:sign_in)
    end

    test "delete/1 reports a miss rather than succeeding silently" do
      assert {:error, :not_found} = Clinch.delete({:sign_in, "never-stored"})
      assert {:error, :unmanaged_kind} = Clinch.delete({:device_key, "laptop"})
    end
  end

  describe "list" do
    test "carries names and metadata across kinds, and no values anywhere" do
      assert {:ok, _} = Clinch.put(@ref, @value, note: "a note")

      entries = Clinch.list()

      assert Enum.any?(entries, &(&1.name == "acme-login" and &1.kind == :sign_in))

      refute Enum.any?(entries, &Map.has_key?(&1, :value)),
             "a listing entry must never carry a value"

      refute Jason.encode!(entries) =~ @value
    end

    test "every entry has the full shape, so the Phase 3 screen can rely on it" do
      assert {:ok, _} = Clinch.put(@ref, @value)

      for entry <- Clinch.list() do
        assert entry.kind in Types.kinds()
        assert is_binary(entry.name)
        assert is_boolean(entry.managed?)
        assert Map.has_key?(entry, :note)
        assert Map.has_key?(entry, :updated_at)
      end
    end

    test "unmanaged kinds are listed as unmanaged rather than omitted or editable" do
      assert Clinch.list(:sign_in) |> Enum.all?(& &1.managed?)
      assert Clinch.list(:oauth) |> Enum.all?(&(not &1.managed?))
      assert Clinch.list(:service_key) |> Enum.all?(&(not &1.managed?))
    end

    # The guard on 4c/Pattern A. The three `list/1` clauses used to assert
    # `managed?` as a literal, which agreed with `Types.managed_kinds/0` by
    # coincidence; they now derive it. This is the test that fails if the two
    # ever diverge again — and it drives the real `list/0`, so it catches a
    # re-inlined literal in any clause, present or future.
    test "managed? agrees with Types.managed_kinds/0 for every listed kind" do
      # Non-empty, or the whole assertion below could pass with every kind
      # read-only — the vacuously-green failure mode this repo keeps hitting.
      refute Enum.empty?(Types.managed_kinds()),
             "managed_kinds/0 is empty — nothing is writable, and the check below proves nothing"

      # A row of every readable kind, so no clause is exercised vacuously.
      assert {:ok, _} = Clinch.put(@ref, @value)

      assert {:ok, _} =
               BusterClaw.Google.create_account(%{
                 "email" => "managed-check@example.com",
                 "client_id" => "client-id",
                 "client_secret" => "client-secret"
               })

      assert {:ok, _} =
               BusterClaw.Integrations.create_integration(%{
                 name: "managed-check",
                 service_type: "github",
                 token: "a-token"
               })

      entries = Clinch.list()
      listed_kinds = entries |> Enum.map(& &1.kind) |> Enum.uniq()

      assert :sign_in in listed_kinds
      assert :oauth in listed_kinds
      assert :service_key in listed_kinds

      for entry <- entries do
        assert entry.managed? == entry.kind in Types.managed_kinds(),
               "#{entry.kind}/#{entry.name} lists managed? = #{entry.managed?}, but " <>
                 "Types.managed_kinds/0 says #{entry.kind in Types.managed_kinds()}. " <>
                 "The write boundary has two answers again — Clinch.list/1 must derive " <>
                 "the flag from Types.managed_kinds/0, never restate it."
      end
    end

    test "kinds with no readable store list nothing rather than inventing names" do
      assert [] = Clinch.list(:loopback_token)
      assert [] = Clinch.list(:device_key)
    end
  end

  # A round-trip test cannot catch this. If a refactor dropped `:google` from
  # BOTH the encrypt and the decrypt side, encrypt→decrypt would still agree and
  # every Google test would stay green — while every column already on a real
  # user's disk became permanently unreadable. So this pins the *wire format*
  # rather than the round trip: these bytes must be Google-vault bytes, and the
  # app vault must NOT be able to read them.
  describe "the Google columns keep their own vault" do
    alias BusterClaw.Google
    alias BusterClaw.Repo

    test "client_secret_enc is written by the Google vault, not the app vault" do
      assert {:ok, _account} =
               Google.create_account(%{
                 "email" => "vault-check@example.com",
                 "client_id" => "client-id",
                 "client_secret" => "client-secret"
               })

      raw =
        Repo.one(
          from a in "google_accounts",
            where: a.email == "vault-check@example.com",
            select: a.client_secret_enc
        )

      assert is_binary(raw)

      assert {:ok, "client-secret"} = BusterClaw.Google.Vault.decrypt(raw),
             "the google_accounts columns must stay readable by the Google vault"

      assert {:error, :invalid_ciphertext} = BusterClaw.Vault.decrypt(raw),
             "the app vault must NOT be able to read a Google column — if it can, " <>
               "the vaults were merged without the Phase 4 migration and existing " <>
               "installs are about to lose their Google credentials"
    end
  end

  describe "the BrowserControl adapter still keeps its own contract" do
    alias BusterClaw.BrowserControl.Secrets

    test "round-trips through the Clinch without changing shape" do
      assert {:ok, %{name: "acme-login", note: "n"}} = Secrets.put("acme-login", @value, "n")
      assert {:ok, @value} = Secrets.fetch("acme-login")
      assert Secrets.known?("acme-login")

      assert [%{name: "acme-login", note: "n"}] = Secrets.names()
      refute Jason.encode!(Secrets.names()) =~ @value

      assert {:ok, _} = Secrets.delete("acme-login")
      assert :error = Secrets.fetch("acme-login")
      assert {:error, :not_found} = Secrets.delete("acme-login")
    end

    test "resolver/0 is still the executor's drop-in function" do
      assert {:ok, _} = Secrets.put("acme-login", @value)
      resolve = Secrets.resolver()

      assert {:ok, @value} = resolve.("acme-login")
      assert :error = resolve.("nope")
    end
  end

  # Phase 3 gave the Clinch a second writable kind, so Twilio / Supabase / Finnhub
  # could stop being environment variables and start being rotatable. These assert
  # the kind is genuinely separate storage rather than a label on the same row.
  describe ":app_key — the app's own service credentials" do
    @app_ref {:app_key, "twilio_auth_token"}

    test "round-trips through put, resolve and delete" do
      assert {:ok, entry} = Clinch.put(@app_ref, "sk-live-abc", note: "Twilio")
      assert entry.kind == :app_key
      assert entry.name == "twilio_auth_token"
      # The value never comes back, not even on the write that just set it.
      refute Map.has_key?(entry, :value)

      assert {:ok, "sk-live-abc"} = Clinch.resolve(@app_ref)
      assert {:ok, _} = Clinch.delete(@app_ref)
      assert :error = Clinch.resolve(@app_ref)
    end

    test "a name is unique within its kind, not across kinds" do
      assert {:ok, _} = Clinch.put({:app_key, "shared-name"}, "app-value")
      assert {:ok, _} = Clinch.put({:sign_in, "shared-name"}, "sign-in-value")

      # Two credentials, not one overwritten twice.
      assert {:ok, "app-value"} = Clinch.resolve({:app_key, "shared-name"})
      assert {:ok, "sign-in-value"} = Clinch.resolve({:sign_in, "shared-name"})
    end

    test "deleting one kind's name leaves the other kind's alone" do
      assert {:ok, _} = Clinch.put({:app_key, "collide"}, "app-value")
      assert {:ok, _} = Clinch.put({:sign_in, "collide"}, "sign-in-value")

      assert {:ok, _} = Clinch.delete({:app_key, "collide"})

      assert :error = Clinch.resolve({:app_key, "collide"})
      assert {:ok, "sign-in-value"} = Clinch.resolve({:sign_in, "collide"})
    end

    test "lists separately from an integration's token, which stays unmanaged" do
      assert {:ok, _} = Clinch.put(@app_ref, "sk-live-abc")

      assert {:ok, _} =
               BusterClaw.Integrations.create_integration(%{
                 name: "some-integration",
                 service_type: "github",
                 token: "gh-token"
               })

      assert [app] = Clinch.list(:app_key)
      assert app.name == "twilio_auth_token"
      assert app.managed?

      assert [integration] = Clinch.list(:service_key)
      assert integration.name == "some-integration"
      # The Integrations screen owns it; deleting from here would strand the row.
      refute integration.managed?
    end

    test "an unmanaged kind still refuses writes" do
      assert {:error, :unmanaged_kind} = Clinch.put({:service_key, "nope"}, "value")
      assert {:error, :unmanaged_kind} = Clinch.delete({:service_key, "nope"})
      assert {:error, :unmanaged_kind} = Clinch.put({:oauth, "a@b.com"}, "value")
    end
  end

end
