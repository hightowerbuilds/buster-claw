defmodule BusterClaw.ContactsTest do
  @moduledoc """
  The point of these tests is the *seam*: a contact row and the markdown policy
  file are different things, and the UI must never be able to show one while the
  gate enforces the other. Most of what follows is pinning that.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{Contacts, TrustedNumbers, TrustedSenders}

  setup do
    # Each test gets a private workspace so the policy files it writes can't leak
    # into the next one (both policies cache in :persistent_term, keyed by path).
    tmp = Path.join(System.tmp_dir!(), "contacts-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "memory"))
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, tmp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:buster_claw, :workspace_root, prev),
        else: Application.delete_env(:buster_claw, :workspace_root)

      File.rm_rf(tmp)
    end)

    :ok
  end

  describe "identity" do
    test "a contact needs at least one way to be reached" do
      assert {:error, changeset} = Contacts.create_contact(%{name: "Ghost"})
      assert "a contact needs a phone number or an email address" in errors_on(changeset).phone
    end

    test "phone is stored E.164 so it compares against events and policy alike" do
      {:ok, contact} = Contacts.create_contact(%{name: "Dana", phone: "(503) 341-2655"})
      assert contact.phone == "+15033412655"
    end

    test "email is downcased" do
      {:ok, contact} = Contacts.create_contact(%{name: "Dana", email: "Dana@Example.COM"})
      assert contact.email == "dana@example.com"
    end

    test "a blank optional field is nil, not an empty string" do
      # A form posts "" for an untouched input. If that reached the DB, two
      # email-less contacts would collide on the unique index.
      {:ok, a} = Contacts.create_contact(%{"name" => "A", "phone" => "5033412655", "email" => ""})
      {:ok, b} = Contacts.create_contact(%{"name" => "B", "phone" => "5035550177", "email" => ""})
      assert is_nil(a.email)
      assert is_nil(b.email)
    end

    test "the same face falls out of the smoke for the same person" do
      {:ok, a} = Contacts.create_contact(%{name: "Dana", phone: "+15033412655"})
      Contacts.delete_contact(a)
      {:ok, b} = Contacts.create_contact(%{name: "Dana Again", phone: "+15033412655"})
      assert a.face_seed == b.face_seed
    end
  end

  describe "trust is derived from the policy file, never stored" do
    test "a new contact is not trusted — the safe default survives" do
      {:ok, contact} = Contacts.create_contact(%{name: "Stranger", phone: "+15033412655"})
      refute Contacts.trusted?(contact)
    end

    test "set_trusted writes the gate that Drain and GmailSync actually read" do
      {:ok, contact} =
        Contacts.create_contact(%{name: "Luke", phone: "+15033412655", email: "l@example.com"})

      {:ok, _} = Contacts.set_trusted(contact, true)

      # Not "the struct says trusted" — the policy files themselves.
      assert TrustedNumbers.trusted?("+15033412655")
      assert TrustedSenders.trusted?("l@example.com")
      assert Contacts.trusted?(contact)
    end

    test "revoking removes both entries" do
      {:ok, contact} =
        Contacts.create_contact(%{name: "Luke", phone: "+15033412655", email: "l@example.com"})

      {:ok, _} = Contacts.set_trusted(contact, true)
      {:ok, _} = Contacts.set_trusted(contact, false)

      refute TrustedNumbers.trusted?("+15033412655")
      refute TrustedSenders.trusted?("l@example.com")
      refute Contacts.trusted?(contact)
    end

    test "trust granted outside the UI still shows on the contact" do
      # The agent adds a number over the CLI; the contact must reflect it. This is
      # the whole reason trust is read from the file instead of cached on the row.
      {:ok, contact} = Contacts.create_contact(%{name: "Dana", phone: "+15033412655"})
      refute Contacts.trusted?(contact)

      {:ok, _} = TrustedNumbers.add_entry("(503) 341-2655")

      assert Contacts.trusted?(contact)
    end

    test "either channel being trusted trusts the person" do
      {:ok, contact} =
        Contacts.create_contact(%{name: "Dana", phone: "+15033412655", email: "d@example.com"})

      {:ok, _} = TrustedSenders.add_entry("d@example.com")

      assert Contacts.trusted?(contact)
      assert Contacts.email_trusted?(contact)
      refute Contacts.phone_trusted?(contact)
    end

    test "a domain wildcard trusts a contact nobody listed individually" do
      {:ok, contact} = Contacts.create_contact(%{name: "Colleague", email: "new@acme.com"})
      {:ok, _} = TrustedSenders.add_entry("*@acme.com")

      assert Contacts.trusted?(contact)
    end

    test "deleting a contact does not silently revoke trust" do
      # Tidying the address book must not edit the security policy. The entry
      # survives as an orphan, visibly, until someone means to remove it.
      {:ok, contact} = Contacts.create_contact(%{name: "Luke", phone: "+15033412655"})
      {:ok, _} = Contacts.set_trusted(contact, true)

      {:ok, _} = Contacts.delete_contact(contact)

      assert TrustedNumbers.trusted?("+15033412655")
      assert "+15033412655" in Contacts.orphan_entries().numbers
    end
  end

  describe "orphans — the gate is bigger than the contact list" do
    test "a wildcard is always an orphan and never disappears from view" do
      {:ok, _} = TrustedSenders.add_entry("*@acme.com")
      {:ok, _} = Contacts.create_contact(%{name: "Colleague", email: "new@acme.com"})

      values = Enum.map(Contacts.orphan_entries().emails, & &1.value)
      assert "*@acme.com" in values
    end

    test "an address with a contact behind it is not an orphan" do
      {:ok, contact} = Contacts.create_contact(%{name: "Luke", email: "l@example.com"})
      {:ok, _} = Contacts.set_trusted(contact, true)

      values = Enum.map(Contacts.orphan_entries().emails, & &1.value)
      refute "l@example.com" in values
    end

    test "an address the agent trusted over the CLI shows as an orphan" do
      {:ok, _} = TrustedSenders.add_entry("cli@example.com")

      values = Enum.map(Contacts.orphan_entries().emails, & &1.value)
      assert "cli@example.com" in values
    end
  end
end
