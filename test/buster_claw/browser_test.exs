defmodule BusterClaw.BrowserTest do
  use BusterClaw.DataCase

  alias BusterClaw.Browser

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "fetches a rendered page through the HTTP fallback boundary" do
    Req.Test.stub(BusterClaw.BrowserHTTP, fn conn ->
      Req.Test.html(
        conn,
        "<html><head><title>Rendered</title></head><body><p>Hello</p></body></html>"
      )
    end)

    assert {:ok, page} =
             Browser.fetch("https://example.com",
               req_options: [plug: {Req.Test, BusterClaw.BrowserHTTP}]
             )

    assert page.title == "Rendered"
    assert page.markdown =~ "Hello"
    assert Browser.status().mode == "http-fallback"
  end
end
