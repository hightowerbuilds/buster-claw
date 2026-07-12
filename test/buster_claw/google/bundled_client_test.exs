defmodule BusterClaw.Google.BundledClientTest do
  use ExUnit.Case, async: false

  alias BusterClaw.Google.BundledClient

  setup do
    previous_client = Application.get_env(:buster_claw, :google_bundled_client)
    previous_url = Application.get_env(:buster_claw, :google_bundled_client_url)
    previous_req = Application.get_env(:buster_claw, :google_req_options)

    BundledClient.reset()

    on_exit(fn ->
      restore(:google_bundled_client, previous_client)
      restore(:google_bundled_client_url, previous_url)
      restore(:google_req_options, previous_req)
      BundledClient.reset()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore(key, value), do: Application.put_env(:buster_claw, key, value)

  defp put_compiled(value), do: Application.put_env(:buster_claw, :google_bundled_client, value)

  defp stub_remote(fun) do
    Application.put_env(
      :buster_claw,
      :google_bundled_client_url,
      "https://example.test/oauth.json"
    )

    Application.put_env(:buster_claw, :google_req_options,
      plug: {Req.Test, BusterClaw.GoogleHTTP}
    )

    Req.Test.stub(BusterClaw.GoogleHTTP, fun)
  end

  test "returns nil when nothing is configured" do
    Application.delete_env(:buster_claw, :google_bundled_client)
    Application.delete_env(:buster_claw, :google_bundled_client_url)

    assert BundledClient.get() == nil
    refute BundledClient.available?()
  end

  test "returns the compiled config" do
    put_compiled(%{client_id: "compiled-id", client_secret: "compiled-secret"})

    assert %{client_id: "compiled-id", client_secret: "compiled-secret"} = BundledClient.get()
    assert BundledClient.available?()
  end

  test "accepts string keys and trims values; rejects incomplete config" do
    put_compiled(%{"client_id" => "  id  ", "client_secret" => "  s3cret "})
    assert %{client_id: "id", client_secret: "s3cret"} = BundledClient.get()

    put_compiled(%{client_id: "id-only"})
    assert BundledClient.get() == nil

    put_compiled(%{client_id: "id", client_secret: "   "})
    assert BundledClient.get() == nil
  end

  test "remote config wins over compiled after refresh" do
    put_compiled(%{client_id: "compiled-id", client_secret: "compiled-secret"})

    stub_remote(fn conn ->
      Req.Test.json(conn, %{"client_id" => "remote-id", "client_secret" => "remote-secret"})
    end)

    BundledClient.refresh()
    assert %{client_id: "remote-id", client_secret: "remote-secret"} = BundledClient.get()
  end

  test "remote failure falls back to the compiled config" do
    put_compiled(%{client_id: "compiled-id", client_secret: "compiled-secret"})

    stub_remote(fn conn -> Plug.Conn.send_resp(conn, 500, "nope") end)

    BundledClient.refresh()
    assert %{client_id: "compiled-id"} = BundledClient.get()
  end

  test "malformed remote body falls back to the compiled config" do
    put_compiled(%{client_id: "compiled-id", client_secret: "compiled-secret"})

    stub_remote(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(200, "not json at all")
    end)

    BundledClient.refresh()
    assert %{client_id: "compiled-id"} = BundledClient.get()
  end

  test "lazy first get with a URL configured returns the fallback without blocking" do
    put_compiled(%{client_id: "compiled-id", client_secret: "compiled-secret"})

    # A plain function plug, NOT Req.Test: the fetch runs in a background task
    # with no ownership link to this test, and a non-owner hitting Req.Test
    # crashes its ownership server for every later test in the run.
    Application.put_env(
      :buster_claw,
      :google_bundled_client_url,
      "https://example.test/oauth.json"
    )

    Application.put_env(:buster_claw, :google_req_options,
      plug: fn conn ->
        Req.Test.json(conn, %{"client_id" => "remote-id", "client_secret" => "remote-secret"})
      end
    )

    # First call kicks a background refresh and immediately serves the
    # compiled fallback; it must never block on the network.
    assert %{client_id: "compiled-id"} = BundledClient.get()
  end
end
