defmodule BusterClaw.Clinch.RekeyTest do
  @moduledoc """
  Phase 4's acceptance: *rotating the recovery key preserves every integration,
  `$secret`, and Google account.*

  The property under test is end-to-end and deliberately not mocked — write real
  credentials under one key, rotate, then read them back through the ordinary
  application path with the new key live. A rotation that passes a unit test and
  loses a Google refresh token is the failure this whole phase exists to prevent.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Clinch
  alias BusterClaw.Clinch.Rekey
  alias BusterClaw.Google
  alias BusterClaw.Integrations

  @old_base "old-secret-key-base-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @new_base "new-secret-key-base-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  setup do
    prev = Application.get_env(:buster_claw, :secret_key_base)
    prev_env = System.get_env("SECRET_KEY_BASE")

    # The vault reads SECRET_KEY_BASE first, so a stray one in the environment
    # would quietly make every "rotation" below a no-op against the same key.
    System.delete_env("SECRET_KEY_BASE")
    Application.put_env(:buster_claw, :secret_key_base, @old_base)

    on_exit(fn ->
      Application.put_env(:buster_claw, :secret_key_base, prev)
      if prev_env, do: System.put_env("SECRET_KEY_BASE", prev_env)
    end)

    :ok
  end

  defp live_key(base), do: Application.put_env(:buster_claw, :secret_key_base, base)

  describe "the acceptance criterion" do
    test "rotating preserves every integration, $secret, app_key and Google account" do
      # Written under the OLD key, through the ordinary write paths.
      assert {:ok, _} = Clinch.put({:sign_in, "acme"}, "sign-in-value")
      assert {:ok, _} = Clinch.put({:app_key, "finnhub_api_key"}, "app-key-value")

      assert {:ok, integration} =
               Integrations.create_integration(%{
                 name: "gh",
                 service_type: "github",
                 token: "gh-token",
                 webhook_secret: "hook-secret"
               })

      assert {:ok, account} =
               Google.create_account(%{
                 "email" => "rekey@example.com",
                 "client_id" => "client-id",
                 "client_secret" => "client-secret"
               })

      assert {:ok, report} = Rekey.run(@old_base, @new_base)
      assert report.unreadable == 0
      assert report.rekeyed >= 5

      # The new key goes live only AFTER the data moved — the order the module
      # documents, and the order the shell must follow.
      live_key(@new_base)

      assert {:ok, "sign-in-value"} = Clinch.resolve({:sign_in, "acme"})
      assert {:ok, "app-key-value"} = Clinch.resolve({:app_key, "finnhub_api_key"})

      reloaded = Repo.get!(Integrations.Integration, integration.id)
      assert reloaded.token == "gh-token"
      assert reloaded.webhook_secret == "hook-secret"

      account = Repo.get!(Google.Account, account.id)
      assert {:ok, "client-secret"} = Google.Account.decrypt(account, :client_secret)
    end

    test "without the rotation, the same key change loses everything" do
      # The negative control. If this passed too, the test above would prove
      # nothing about the rotation — only that the values round-trip.
      assert {:ok, _} = Clinch.put({:sign_in, "acme"}, "sign-in-value")

      live_key(@new_base)

      assert :error = Clinch.resolve({:sign_in, "acme"}),
             "a key change with no re-key must fail closed — if this resolves, " <>
               "the vault is not actually keyed on secret_key_base and the " <>
               "rotation test above is measuring nothing"
    end
  end

  describe "refusals" do
    test "rotating a key to itself is refused rather than silently succeeding" do
      assert {:error, :same_key} = Rekey.run(@old_base, @old_base)
    end

    test "a blank key is refused" do
      assert {:error, :blank_key} = Rekey.run(@old_base, "")
      assert {:error, :blank_key} = Rekey.run("", @new_base)
    end

    test "a non-binary key is refused" do
      assert {:error, :invalid_key} = Rekey.run(@old_base, nil)
    end
  end

  describe "a value that cannot be read" do
    test "is left byte-for-byte, counted, and does not abort the rotation" do
      assert {:ok, _} = Clinch.put({:sign_in, "readable"}, "fine")

      # A row whose ciphertext belongs to some other key entirely — exactly what a
      # previous unrecoverable key change leaves behind.
      junk = <<1>> <> :crypto.strong_rand_bytes(40)

      Repo.insert_all("browser_secrets", [
        %{
          kind: "sign_in",
          name: "orphaned",
          value: junk,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])

      assert {:ok, report} = Rekey.run(@old_base, @new_base)

      assert report.unreadable == 1
      assert ["browser_secrets.value#" <> _] = report.skipped

      # Untouched: it is the only copy, and a restored key might still read it.
      after_rekey =
        Repo.one(from s in "browser_secrets", where: s.name == "orphaned", select: s.value)

      assert after_rekey == junk

      # And the readable value still moved — one bad row must not strand the rest.
      live_key(@new_base)
      assert {:ok, "fine"} = Clinch.resolve({:sign_in, "readable"})
    end
  end

  describe "the store list" do
    # A new encrypted column that nobody adds to @stores would be silently skipped
    # by every future rotation — a partial rotation reporting complete success.
    # This is the guard against that, and it derives the truth from the schemas.
    test "covers every BusterClaw.Encrypted column in the app" do
      declared =
        Rekey.stores()
        |> Enum.flat_map(fn {table, columns} -> Enum.map(columns, &{table, &1}) end)
        |> MapSet.new()

      actual =
        for {schema, source} <- [
              {BusterClaw.Clinch.Secret, "browser_secrets"},
              {BusterClaw.Integrations.Integration, "integrations"}
            ],
            field <- schema.__schema__(:fields),
            schema.__schema__(:type, field) == BusterClaw.Encrypted,
            into: MapSet.new(),
            do: {source, field}

      # google_accounts uses :binary columns with explicit crypto rather than the
      # Encrypted type, so it cannot be derived the same way — named here so the
      # set is complete rather than quietly partial.
      google =
        MapSet.new([
          {"google_accounts", :client_secret_enc},
          {"google_accounts", :refresh_token_enc},
          {"google_accounts", :access_token_enc}
        ])

      missing = MapSet.difference(MapSet.union(actual, google), declared)

      assert MapSet.size(missing) == 0,
             "encrypted column(s) missing from Rekey.stores/0: " <>
               "#{inspect(MapSet.to_list(missing))}. A rotation would skip them " <>
               "silently and report success, leaving values under the old key with " <>
               "no key that reads everything."
    end
  end

  # Invariant 5's other half. Re-keying gives a bad key change a way out; this
  # gives it a way to be SEEN. Without it, "nothing configured" and "everything
  # unreadable" render identically, because Encrypted fails closed to nil.
  describe "unreadable/0" do
    test "a healthy store reports zero" do
      assert {:ok, _} = Clinch.put({:sign_in, "acme"}, "value")

      assert %{count: 0, stores: []} = Rekey.unreadable()
    end

    test "counts values written under a different key, and names their stores" do
      assert {:ok, _} = Clinch.put({:sign_in, "acme"}, "value")

      assert {:ok, _} =
               Integrations.create_integration(%{
                 name: "gh",
                 service_type: "github",
                 token: "gh-token"
               })

      # The key changes and nothing is rotated — the exact situation.
      live_key(@new_base)

      report = Rekey.unreadable()

      assert report.count == 2
      assert report.stores == ["browser_secrets", "integrations"]
    end

    test "a rotation clears it" do
      assert {:ok, _} = Clinch.put({:sign_in, "acme"}, "value")

      live_key(@new_base)
      assert Rekey.unreadable().count == 1

      # Rotate FROM the old key, which is still what the data is under.
      assert {:ok, _} = Rekey.run(@old_base, @new_base)

      assert %{count: 0} = Rekey.unreadable()
    end

    test "legacy plaintext is not damage and is not counted" do
      # `Encrypted` passes through a value that is not framed as our ciphertext,
      # by design, so the column can migrate lazily. Reporting it as unreadable
      # would be a false alarm about something that works.
      Repo.insert_all("browser_secrets", [
        %{
          kind: "sign_in",
          name: "legacy",
          value: "plain-old-string",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])

      assert %{count: 0} = Rekey.unreadable()
    end

    test "no master key at all is not reported as every credential being damaged" do
      assert {:ok, _} = Clinch.put({:sign_in, "acme"}, "value")

      Application.put_env(:buster_claw, :secret_key_base, nil)

      # "There is no key" is a different state from "these values are corrupt",
      # and a machine with no key yet must not be told its credentials are broken.
      assert %{count: 0} = Rekey.unreadable()
    end
  end
end
