defmodule BusterClaw.Messages.StatusTest do
  use ExUnit.Case, async: true

  alias BusterClaw.Messages.Status

  defp snapshot do
    %{
      "version" => "0.15.6",
      "protocol_version" => 1,
      "database" => %{"ready" => true, "path" => "/private/person/chat.db"},
      "methods" => ~w(chats.list messages.history watch.subscribe send),
      "bridge" => %{"ready" => true, "error" => "private diagnostic"}
    }
  end

  test "readiness exposes neither personal paths nor a promise that sends work" do
    assert {:ok, status} = Status.from_rpc(snapshot())
    assert status.state == :read_ready
    assert status.read_ready
    refute status.send_ready
    assert status.send_state == :not_tested
    refute inspect(status) =~ "private"
    refute Map.has_key?(status, :bridge)
  end

  test "unreadable database is distinct from empty history and can recover" do
    unavailable = put_in(snapshot(), ["database"], %{"ready" => false, "error" => "private"})

    assert {:ok, %{state: :database_unavailable, read_ready: false}} =
             Status.from_rpc(unavailable)

    assert {:ok, %{state: :read_ready}} = Status.from_rpc(snapshot())
  end

  test "rejects untested versions, protocols, missing capabilities and malformed readiness" do
    assert {:error, :unsupported_version} = Status.from_rpc(%{snapshot() | "version" => "0.16.0"})

    assert {:error, :unsupported_protocol} =
             Status.from_rpc(%{snapshot() | "protocol_version" => 2})

    assert {:error, :missing_read_capabilities} =
             Status.from_rpc(%{snapshot() | "methods" => ["send"]})

    assert {:error, :invalid_status} = Status.from_rpc(%{snapshot() | "methods" => [true]})
    assert {:error, :invalid_status} = Status.from_rpc(%{snapshot() | "database" => %{}})
    assert {:error, :invalid_status} = Status.from_rpc(nil)
  end
end
