defmodule BusterClawWeb.EndpointTest do
  use ExUnit.Case, async: true

  alias BusterClawWeb.Endpoint

  test "captures the raw body on the webhook path" do
    conn = Plug.Test.conn(:post, "/integrations/gmail/webhook", "payload")
    assert {:ok, "payload", conn} = Endpoint.cache_raw_body(conn, [])
    assert conn.assigns[:raw_body] == "payload"
  end

  test "does not duplicate the body on unrelated paths" do
    conn = Plug.Test.conn(:post, "/api/run", "payload")
    assert {:ok, "payload", conn} = Endpoint.cache_raw_body(conn, [])
    # Only the webhook path pays the raw-body copy; everything else reads through.
    assert conn.assigns[:raw_body] == nil
  end
end
