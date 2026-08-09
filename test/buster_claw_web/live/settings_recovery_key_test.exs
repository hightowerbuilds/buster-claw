defmodule BusterClawWeb.SettingsRecoveryKeyTest do
  @moduledoc """
  Clinch Phase 2's acceptance criterion: **the recovery key never appears in a
  LiveView payload.**

  It used to. `settings_live` assigned `Recovery.recovery_key/0` at mount and
  rendered it into a readonly input — so the value that decrypts every other
  credential in the app was in the socket's assigns and in the rendered diff, on
  every visit to Settings, whether or not anyone clicked Reveal.

  That was survivable while loopback meant "sitting at the Mac". It is exactly
  the wrong shape once an SSH tunnel exists, which is what this whole roadmap is
  building toward. Now Rust reads the Keychain and hands the value to a DOM node
  the hook owns; the server never sees it.

  This test would have failed before the change and passes after — which is the
  only reason to write it.
  """
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.RuntimeConfig

  test "the master key is in neither the rendered HTML nor the socket assigns", %{conn: conn} do
    key = RuntimeConfig.secret_key_base()

    assert is_binary(key) and byte_size(key) > 16,
           "this test is meaningless without a real key configured"

    {:ok, view, html} = live(conn, ~p"/settings")

    refute html =~ key,
           "the recovery key was rendered into the mount payload"

    refute render(view) =~ key,
           "the recovery key was rendered into the LiveView diff"

    # The assigns are the other half: a value can be in state without being
    # rendered yet, and one `:if` flip would put it on the wire.
    assigns = :sys.get_state(view.pid).socket.assigns

    refute Map.has_key?(assigns, :recovery_key),
           "settings_live still assigns the recovery key"

    refute assigns |> Map.values() |> Enum.any?(&(&1 == key)),
           "the recovery key is held in a socket assign under some other name"
  end

  test "the reveal control is present but carries no value to reveal", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "data-recovery-toggle"
    assert html =~ ~s(phx-hook="RecoveryKey")

    # The panel the hook writes into ships empty and hidden.
    assert html =~ "data-recovery-value"
    refute html =~ RuntimeConfig.secret_key_base()
  end

  test "the Clinch panel lists names without values", %{conn: conn} do
    assert {:ok, _} = BusterClaw.Clinch.put({:sign_in, "acme-login"}, "Hunter2!x", note: "acme")

    {:ok, _view, html} = live(conn, ~p"/settings")

    assert html =~ "acme-login"
    refute html =~ "Hunter2!x"
  end

  test "the management form is not a LiveView form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings")

    [form] = Regex.run(~r/<form[^>]*data-clinch-form.*?<\/form>/s, html)

    refute form =~ "phx-change",
           "a phx-change on the Clinch form would put the credential in a LiveView event"

    refute form =~ "phx-submit",
           "a phx-submit on the Clinch form would put the credential in a LiveView event"
  end
end
