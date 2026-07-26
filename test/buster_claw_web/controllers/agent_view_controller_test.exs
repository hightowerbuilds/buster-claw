defmodule BusterClawWeb.AgentViewControllerTest do
  @moduledoc """
  The mirror's transport. The frame *content* is proven against a real engine in
  `ScreencastLiveTest`; what matters here is the HTTP contract — the multipart
  envelope a plain `<img>` needs, and that an unknown run is a clean 404 rather
  than a hung connection.
  """
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.BrowserControl.Screencast

  test "an unknown run is 404, not a stalled stream", %{conn: conn} do
    conn = get(conn, ~p"/browser/agent-view/no-such-run")
    assert response(conn, 404) =~ "no such run"
  end

  test "a frame is framed as a multipart JPEG part the browser can decode" do
    # The encoder is the contract: boundary line, content-type, correct length,
    # then the raw bytes. Getting Content-Length wrong makes an <img> hang on a
    # part forever, which looks exactly like "the agent froze".
    jpeg = <<0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4>>
    part = BusterClawWeb.AgentViewController.encode_part(Base.encode64(jpeg))

    assert part =~ "--busterclawframe\r\n"
    assert part =~ "Content-Type: image/jpeg\r\n"
    assert part =~ "Content-Length: #{byte_size(jpeg)}\r\n"
    assert String.ends_with?(part, <<"\r\n\r\n">> <> jpeg <> "\r\n")
  end

  test "a corrupt frame is skipped rather than crashing the stream" do
    assert BusterClawWeb.AgentViewController.encode_part("not base64!!") == nil
  end

  test "no caster exists for a run nobody is watching" do
    assert Screencast.whereis("unwatched-run") == nil
  end
end
