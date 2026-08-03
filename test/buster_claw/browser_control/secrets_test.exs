defmodule BusterClaw.BrowserControl.SecretsTest do
  @moduledoc """
  The store behind `$secret.<name>` — the half of the reference design that was
  never built, so every reference failed and no unattended run could sign in.

  The load-bearing property is negative: values go in and drive a fill, and no
  command, listing, or log returns one.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl.Egress.SecretRef
  alias BusterClaw.BrowserControl.Secrets
  alias BusterClaw.Commands
  alias BusterClaw.Repo

  test "a stored secret resolves a reference, and the resolver is what a run gets" do
    assert {:ok, %{name: "amazon_password"}} =
             Secrets.put("amazon_password", "hunter2", "amazon.com sign-in")

    resolver = Secrets.resolver()
    assert resolver.("amazon_password") == {:ok, "hunter2"}

    # End to end through the pure reference module, which is what the executor
    # calls just before the value reaches the browser.
    assert {:ok, "hunter2"} = SecretRef.resolve("$secret.amazon_password", resolver)
  end

  test "an unknown name fails the whole resolve rather than half-filling a form" do
    {:ok, _} = Secrets.put("known", "yes")
    resolver = Secrets.resolver()

    assert resolver.("nope") == :error

    # "known" resolves and "nope" does not: the resolve still fails whole, so a
    # form never gets one real credential and one empty box.
    assert {:error, {:unknown_secret, "nope"}} =
             SecretRef.resolve("user: $secret.known and $secret.nope", resolver)
  end

  test "the resolver reads on demand, so deleting mid-run stops resolving" do
    {:ok, _} = Secrets.put("token", "abc")
    resolver = Secrets.resolver()
    assert resolver.("token") == {:ok, "abc"}

    {:ok, _} = Secrets.delete("token")

    # No plaintext was captured in the closure — the run's state never holds it.
    assert resolver.("token") == :error
  end

  test "the value is ciphertext at rest, not readable from the row" do
    {:ok, _} = Secrets.put("card_pin", "9134")

    # Read the raw column, bypassing the Encrypted type entirely.
    [raw] = Repo.query!("SELECT value FROM browser_secrets WHERE name = 'card_pin'").rows |> hd()

    assert is_binary(raw)
    refute raw =~ "9134"
  end

  test "names are normalized and validated against the reference grammar" do
    assert {:ok, %{name: "shipping_address"}} = Secrets.put("  Shipping_Address  ", "12 Main St")
    assert Secrets.fetch("SHIPPING_ADDRESS") == {:ok, "12 Main St"}

    # A name SecretRef could never match would be stored and never resolvable.
    assert {:error, errors} = Secrets.put("has spaces", "x")
    assert errors[:name]

    assert {:error, :missing_name_or_value} = Secrets.put("ok_name", "")
  end

  test "storing an existing name replaces it" do
    {:ok, _} = Secrets.put("pw", "old")
    {:ok, _} = Secrets.put("pw", "new", "rotated")

    assert Secrets.fetch("pw") == {:ok, "new"}
    assert [%{name: "pw", note: "rotated"}] = Secrets.names()
  end

  describe "the command surface" do
    test "lists names and notes and NEVER a value" do
      {:ok, _} = Secrets.put("amazon_password", "hunter2", "amazon.com sign-in")

      assert {:ok, %{secrets: [secret], count: 1}} = Commands.browser_secret_list()
      assert secret.name == "amazon_password"
      assert secret.note == "amazon.com sign-in"

      # The whole design in one assertion: nothing the model can call hands the
      # value back. If a read command is ever added, this test should be the
      # thing that stops it.
      refute Map.has_key?(secret, :value)
      refute inspect(secret) =~ "hunter2"

      {:ok, listing} = Commands.browser_secret_list()
      refute inspect(listing) =~ "hunter2"
    end

    test "put returns the name, not the value it just stored" do
      assert {:ok, result} = Commands.browser_secret_put(%{"name" => "pw", "value" => "hunter2"})
      assert result.name == "pw"
      refute inspect(result) =~ "hunter2"
    end

    test "delete names an unknown secret rather than passing quietly" do
      assert {:error, :not_found} = Commands.browser_secret_delete(%{"name" => "ghost"})

      {:ok, _} = Secrets.put("pw", "x")
      assert {:ok, %{name: "pw"}} = Commands.browser_secret_delete(%{"name" => "pw"})
      assert Secrets.fetch("pw") == :error
    end

    test "missing args are named, not guessed" do
      assert {:error, :missing_name_or_value} = Commands.browser_secret_put(%{"name" => "x"})
      assert {:error, :missing_name} = Commands.browser_secret_delete(%{})
    end

    # Writing a credential is gated so an untrusted agent's attempt surfaces for
    # human approval; listing is safe because names are all the model may see.
    test "the tiers match what each command exposes" do
      assert Commands.command_tier("browser_secret_put") == :restricted
      assert Commands.command_gated?("browser_secret_put")

      assert Commands.command_tier("browser_secret_delete") == :restricted
      assert Commands.command_gated?("browser_secret_delete")

      assert Commands.command_tier("browser_secret_list") == :safe

      # There is no read-a-value command, and adding one should fail here first.
      refute Commands.command_tier("browser_secret_get")
      refute Commands.command_tier("browser_secret_read")
      refute Commands.command_tier("browser_secret_show")
    end
  end
end
