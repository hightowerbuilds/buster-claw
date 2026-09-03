defmodule BusterClawWeb.VoiceAudioControllerTest do
  use BusterClawWeb.ConnCase, async: false

  alias BusterClaw.Voice.{Clips, Reference, Renderer}

  setup do
    root = Path.join(System.tmp_dir!(), "bc_vaudio_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:buster_claw, :workspace_root, previous),
        else: Application.delete_env(:buster_claw, :workspace_root)

      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "serves a reference recording by name, as wav, nosniffed", %{conn: conn} do
    {:ok, saved} = Reference.save(tone(2_500), 44_100)

    conn = get(conn, ~p"/voice-audio/#{saved.name}")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["audio/wav"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert byte_size(conn.resp_body) > 44
  end

  test "serves a clip and a bare cache file by name", %{conn: conn} do
    Renderer.ensure()
    {:ok, path} = Renderer.path_for("Hello.")
    File.write!(path, :binary.copy(<<0>>, 200))
    Clips.record("Hello.", path)

    assert get(conn, ~p"/voice-audio/#{Path.basename(path)}").status == 200
  end

  test "anything not in a listing is a 404 — including a traversal shaped like a name", %{
    conn: conn,
    root: root
  } do
    # A real file that is NOT in any listing must not be reachable by name.
    secret = Path.join(root, "sounds/voice/reference/../../../secret.wav")
    File.mkdir_p!(Path.dirname(secret))
    File.write!(secret, "nope")

    assert get(conn, ~p"/voice-audio/secret.wav").status == 404

    assert get(conn, ~p"/voice-audio/#{URI.encode("../secret.wav", &URI.char_unreserved?/1)}").status ==
             404

    assert get(conn, ~p"/voice-audio/zz.wav").status == 404
  end

  defp tone(ms, rate \\ 44_100) do
    count = div(rate * ms, 1000)

    floats =
      for i <- 0..(count - 1), into: <<>> do
        <<:math.sin(2 * :math.pi() * 440 * i / rate) * 0.3::float-little-32>>
      end

    Base.encode64(floats)
  end
end
