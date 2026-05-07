defmodule BusterClaw.DeliveryTest do
  use BusterClaw.DataCase

  alias BusterClaw.Delivery

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "manages delivery destinations through a focused context" do
    assert {:ok, destination} =
             Delivery.create_destination(%{
               name: "team-slack",
               type: "slack",
               url: "https://example.com/slack"
             })

    assert [^destination] = Delivery.list_destinations()
    assert [^destination] = Delivery.list_enabled_destinations()

    assert {:ok, destination} = Delivery.update_destination(destination, %{enabled: false})
    refute destination.enabled
    assert [] = Delivery.list_enabled_destinations()

    assert {:ok, _destination} = Delivery.delete_destination(destination)
    assert [] = Delivery.list_destinations()
  end

  test "dispatch_destination records sent attempts through Req test stubs" do
    Req.Test.stub(BusterClaw.DeliveryHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "Report ready"
      Req.Test.json(conn, %{ok: true})
    end)

    assert {:ok, destination} =
             Delivery.create_destination(%{
               name: "discord",
               type: "discord",
               url: "https://example.com/discord",
               token: "secret"
             })

    assert {:ok, attempt} =
             Delivery.dispatch_destination(
               destination,
               %{title: "Report ready", body: "Summary"},
               req_options: [plug: {Req.Test, BusterClaw.DeliveryHTTP}]
             )

    assert attempt.status == "sent"
    assert attempt.title == "Report ready"
    assert attempt.started_at
    assert attempt.finished_at
  end

  test "dispatch_destination records failed attempts for non-2xx responses" do
    Req.Test.stub(BusterClaw.DeliveryFailureHTTP, fn conn ->
      Plug.Conn.send_resp(conn, 503, "bad")
    end)

    assert {:ok, destination} =
             Delivery.create_destination(%{
               name: "telegram",
               type: "telegram",
               url: "https://example.com/telegram"
             })

    assert {:ok, attempt} =
             Delivery.dispatch_destination(
               destination,
               %{title: "Report ready"},
               req_options: [plug: {Req.Test, BusterClaw.DeliveryFailureHTTP}]
             )

    assert attempt.status == "failed"
    assert attempt.error == "HTTP 503"
  end
end
