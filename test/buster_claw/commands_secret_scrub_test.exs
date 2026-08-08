defmodule BusterClaw.CommandsSecretScrubTest do
  @moduledoc """
  Clinch Phase 0: a credential passed as a command argument must never reach a
  Sentinel sink in the clear.

  The value used throughout is deliberately *password-shaped* — short, no
  credential prefix, not 40+ chars, not Luhn-valid — because that is precisely
  the shape every one of Sentinel's generic nets misses. A `ghp_`-prefixed or
  40-char value would be masked by `mask_secret_values/1` and would prove
  nothing about the scrub under test.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl.Secrets
  alias BusterClaw.Commands
  alias BusterClaw.Sentinel
  alias BusterClaw.Sentinel.Pending

  # Short, unprefixed, mixed but under every length floor, and 8 digits is not a
  # card. Sentinel's key-name list does not contain "value" either, so nothing
  # generic can catch this.
  @password "Hunter2!x"
  @args %{"name" => "acme-login", "value" => @password, "note" => "the note"}

  # Two pieces of global state, both outside the Ecto sandbox — hence async: false.
  # Pending is a named GenServer in the app supervision tree (clear it, don't start
  # a second one), and the Notes vault is real files on disk, so the note case needs
  # its own temporary workspace or it fails `{:error, :exists}` on the second run.
  setup do
    Pending.clear()

    root = Path.join(System.tmp_dir!(), "bc_scrub_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Pending.clear()
      Application.put_env(:buster_claw, :workspace_root, previous)
      File.rm_rf(root)
    end)

    :ok
  end

  defp event_blobs do
    Sentinel.list_events(limit: 100)
    |> Enum.map(&Jason.encode!(&1.metadata))
  end

  describe "the accepted path (trusted caller, command_invoke audit)" do
    test "stores the secret but never writes its value to security_events" do
      assert {:ok, %{name: "acme-login"}} =
               Commands.call("browser_secret_put", @args, caller: :trusted)

      # The command really did its job — the scrub must not have reached dispatch.
      assert {:ok, @password} = Secrets.fetch("acme-login")

      blobs = event_blobs()

      assert Enum.any?(blobs, &String.contains?(&1, "browser_secret_put")),
             "expected a command_invoke audit row for browser_secret_put"

      refute Enum.any?(blobs, &String.contains?(&1, @password)),
             "the credential leaked into security_events"

      assert Enum.any?(blobs, &String.contains?(&1, "#{byte_size(@password)} bytes")),
             "expected the value to be reduced to a byte count"
    end

    test "the surrounding args survive so the audit row stays useful" do
      assert {:ok, _} = Commands.call("browser_secret_put", @args, caller: :trusted)

      blobs = event_blobs()
      assert Enum.any?(blobs, &String.contains?(&1, "acme-login"))
      assert Enum.any?(blobs, &String.contains?(&1, "the note"))
    end
  end

  describe "the refused path (gated command, untrusted caller)" do
    test "neither the security_block event nor Pending carries the value" do
      assert {:error, :requires_confirmation} =
               Commands.call("browser_secret_put", @args, caller: :agent_untrusted)

      refute Enum.any?(event_blobs(), &String.contains?(&1, @password)),
             "the credential leaked into a security_block refusal row"

      pending = Jason.encode!(Pending.list() |> Enum.map(& &1.args))

      refute String.contains?(pending, @password),
             "the credential leaked into Sentinel.Pending"
    end

    test "a blocked caller's refusal row is scrubbed too" do
      assert {:error, reason} = Commands.call("browser_secret_put", @args, caller: :mcp)
      assert reason in [:requires_confirmation, :policy_blocked]

      refute Enum.any?(event_blobs(), &String.contains?(&1, @password))
    end
  end

  describe "the scrub is centralized, not per-sink" do
    test "note bodies are still reduced (the pre-existing clause survived the move)" do
      assert {:ok, _} =
               Commands.call(
                 "note_create",
                 %{"title" => "scrub-check", "body" => "private prose here"},
                 caller: :trusted
               )

      blobs = event_blobs()
      refute Enum.any?(blobs, &String.contains?(&1, "private prose here"))
      assert Enum.any?(blobs, &String.contains?(&1, "bytes"))
    end
  end
end
