defmodule BusterClaw.Voice.GreetingTest do
  @moduledoc """
  The greeting is the one thing in this app that changes what **other people**
  experience — a stranger dialling a phone number. Every wire call here goes
  through a `Req.Test` plug, which `Telephony.Relay` was built to accept, so the
  upload is exercised for real rather than described.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.Telephony.Relay
  alias BusterClaw.Voice.Greeting

  @relay [req_options: [plug: {Req.Test, __MODULE__}]]

  setup do
    root = Path.join(System.tmp_dir!(), "bc_greet_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous_root = Application.get_env(:buster_claw, :workspace_root)
    previous_url = Application.get_env(:buster_claw, :telephony_relay_url)
    previous_key = Application.get_env(:buster_claw, :telephony_relay_key)

    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :telephony_relay_url, "https://relay.test")
    Application.put_env(:buster_claw, :telephony_relay_key, "service-role-key")

    on_exit(fn ->
      restore(:workspace_root, previous_root)
      restore(:telephony_relay_url, previous_url)
      restore(:telephony_relay_key, previous_key)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "the text" do
    test "the default carries the access-code instructions, because it is ONE recording" do
      # The Edge Function speaks the greeting and the PIN prompt as a single
      # <Say>. A recorded greeting that omits the instructions leaves callers
      # with no idea a PIN exists — they are one utterance or none.
      assert Greeting.default_text() =~ "access code"
      assert Greeting.default_text() =~ "leave a message"
    end

    test "an edit sticks, and a blank one resets rather than silencing the line" do
      assert :ok = Greeting.put_text("Hi, it's Luke's machine. Leave a message.")
      assert Greeting.text() == "Hi, it's Luke's machine. Leave a message."

      # A phone number that answers with silence is worse than one that answers
      # with Polly.
      assert :ok = Greeting.put_text("   ")
      assert Greeting.text() == Greeting.default_text()
    end

    test "reset puts the seeded line back" do
      assert :ok = Greeting.put_text("Something else.")
      assert :ok = Greeting.reset()
      assert Greeting.text() == Greeting.default_text()
    end
  end

  describe "publishing" do
    test "uploads the rendered bytes to the greeting path", %{root: root} do
      audio = Path.join(root, "greeting.wav")
      File.write!(audio, wav_bytes())
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:uploaded, conn.method, conn.request_path, body})
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      assert :ok = Greeting.publish(audio, @relay)

      assert_received {:uploaded, "POST", path, body}
      assert path == "/storage/v1/object/recordings/" <> Relay.greeting_path()
      assert body == File.read!(audio), "the bytes on the wire must be the rendered audio"
    end

    test "refuses to publish silence", %{root: root} do
      # The worst failure this has: a phone number that answers with nothing, and
      # is indistinguishable from success once it is done.
      empty = Path.join(root, "empty.wav")
      File.write!(empty, "")

      Req.Test.stub(__MODULE__, fn _conn -> flunk("must not reach the wire") end)

      assert {:error, :empty_audio} = Greeting.publish(empty, @relay)
    end

    test "a file that is not there is refused", %{root: root} do
      assert {:error, :enoent} = Greeting.publish(Path.join(root, "nope.wav"), @relay)
    end

    test "a storage failure is reported and the digest is not recorded", %{root: root} do
      audio = Path.join(root, "greeting.wav")
      File.write!(audio, wav_bytes())

      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

      assert {:error, {:storage_status, 503, _}} = Greeting.publish(audio, @relay)

      # And nothing claims to be published.
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      refute Greeting.status(@relay).published?
    end
  end

  describe "status" do
    test "asks storage rather than trusting a local flag" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
      assert Greeting.status(@relay).published?

      # A Mac restored from a backup can hold a flag for audio that is not there.
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
      refute Greeting.status(@relay).published?
    end

    test "editing after publishing is reported as stale, not as unpublished", %{root: root} do
      audio = Path.join(root, "greeting.wav")
      File.write!(audio, wav_bytes())

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      assert :ok = Greeting.publish(audio, @relay)

      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
      status = Greeting.status(@relay)
      assert status.published?
      refute status.stale?

      # The old audio still plays — that is exactly why the operator has to be
      # told, rather than shown a screen that quietly disagrees with the phone.
      assert :ok = Greeting.put_text("Completely different words now.")
      status = Greeting.status(@relay)
      assert status.published?
      assert status.stale?
    end

    test "with no relay configured, nothing claims to be published" do
      Application.delete_env(:buster_claw, :telephony_relay_url)
      refute Greeting.status(@relay).published?
    end
  end

  test "unpublishing puts callers back on the synthesized voice" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:deleted, conn.method, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = Greeting.unpublish(@relay)
    assert_received {:deleted, "DELETE", path}
    assert path == "/storage/v1/object/recordings/" <> Relay.greeting_path()
  end

  test "an already-absent greeting is success, not an error to retry forever" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
    assert :ok = Greeting.unpublish(@relay)
  end

  describe "the two halves that never talk" do
    @function "supabase/functions/voice/index.ts"

    test "Elixir and the Edge Function agree on where the greeting lives" do
      # The Mac uploads it and Deno serves it, in different languages, in
      # different processes, deployed separately. They share exactly one string
      # and nothing enforces it but this. Get it wrong and the phone answers in
      # Polly forever while the settings page cheerfully reports "published".
      source = File.read!(@function)

      assert [[_, path]] = Regex.scan(~r/GREETING_PATH\s*=\s*"([^"]+)"/, source)

      assert path == Relay.greeting_path(), """
      #{@function} looks for the greeting at "#{path}" but the Mac publishes it to
      "#{Relay.greeting_path()}". Change both, or callers hear the synthesized
      voice while everything reports success.
      """
    end

    test "the media route is reachable without a signature, and only that route" do
      # Twilio fetches <Play> media with an unsigned GET, so `event=greeting` sits
      # ahead of the POST and signature gates. That bypass is safe for audio every
      # caller already hears — and dangerous for anything else, so this pins that
      # it is the only event handled before verification.
      source = File.read!(@function)

      [preamble | _] = String.split(source, "verifyTwilioSignature(authToken")

      assert preamble =~ ~s|searchParams.get("event") === "greeting"|

      for event <- ~w(pin recording transcription) do
        refute preamble =~ ~s("#{event}"),
               "#{event} is handled before the Twilio signature is verified"
      end
    end
  end

  defp wav_bytes do
    rate = 22_050
    data = :binary.copy(<<0::little-signed-16>>, div(rate, 10))
    len = byte_size(data)

    <<"RIFF", 36 + len::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data", len::little-32>> <>
      data
  end

  defp restore(key, nil), do: Application.delete_env(:buster_claw, key)
  defp restore(key, value), do: Application.put_env(:buster_claw, key, value)
end
