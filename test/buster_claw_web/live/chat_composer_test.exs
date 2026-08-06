defmodule BusterClawWeb.ChatComposerTest do
  @moduledoc """
  The composer's delivery contract, asserted through stable DOM ids on both
  surfaces.

  The thing under test is not "does a button render" — it is that **the button's
  label, the value it posts, and what actually happened never disagree**. A
  Steer button that silently queues is the single most damaging bug this feature
  can ship, and it would look completely normal on screen.
  """
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.Agent.Chat
  alias BusterClaw.Agent.FakeChatTransport

  # The seeded conversation the Home tab opens on. Started here with our own
  # options BEFORE the first submit: `Chat.ensure_started/2` is a no-op once a
  # process exists, so these win over the ones StatusLive would have passed.
  # That is the seam that lets a test choose the backend.
  @conv "default"

  defp start_conversation(opts) do
    {:ok, _pid} =
      Chat.start_link(
        [
          conv_id: @conv,
          spawner: fn _prompt, _opts -> {:ok, make_ref()} end,
          persist: false,
          audit: false
        ] ++ opts
      )

    @conv
  end

  defp home(conn), do: live(conn, ~p"/")

  describe "the primary action names what will actually happen" do
    test "idle: Send, posting the auto delivery", %{conn: conn} do
      start_conversation([])
      {:ok, view, _html} = home(conn)

      assert has_element?(view, "#home-composer")
      assert render(view) =~ "Send"

      assert view |> element("#home-composer [data-delivery]") |> render() =~ ~s(value="auto")

      # Nothing to steer into and nothing to queue behind, so no second action.
      refute has_element?(view, "#home-composer [data-secondary-action]")
    end

    test "running on a steerable backend: Steer now, with Queue next beside it", %{conn: conn} do
      conv = start_conversation(transport_mod: FakeChatTransport)
      {:ok, view, _html} = home(conn)

      # Drive the conversation into a running turn the way the real thing does.
      send(view.pid, {:agent_chat, conv, {:status, :running}})
      html = render(view)

      assert html =~ "Steer now"
      assert view |> element("#home-composer [data-delivery]") |> render() =~ ~s(value="steer")

      # The secondary is offered only because it does something different.
      assert has_element?(view, "#home-composer [data-secondary-action]")
      assert view |> element("#home-composer [data-secondary-action]") |> render() =~ "Queue next"
    end

    test "running on a backend that cannot steer: Queue next, and NO placebo", %{conn: conn} do
      # The real Phase 1 adapters cannot steer, which is the shipped default.
      conv = start_conversation([])
      {:ok, view, _html} = home(conn)

      send(view.pid, {:agent_chat, conv, {:status, :running}})
      html = render(view)

      assert html =~ "Queue next"
      refute html =~ "Steer now"

      # Crucially: the posted delivery is `next`, not `steer`. A composer that
      # posted `steer` here would get `:queued` back and have to walk the label
      # backwards.
      assert view |> element("#home-composer [data-delivery]") |> render() =~ ~s(value="next")

      # No second button, because it would do the same thing as the first.
      refute has_element?(view, "#home-composer [data-secondary-action]")
    end
  end

  describe "delivery outcomes" do
    test "a steered message is chipped, and does NOT enter the on-deck queue", %{conn: conn} do
      conv = start_conversation(transport_mod: FakeChatTransport)
      {:ok, view, _html} = home(conn)

      # Start a turn, then steer into it.
      render_submit(element(view, "#home-composer"), %{"message" => "first", "delivery" => "auto"})

      render_submit(element(view, "#home-composer"), %{
        "message" => "actually, do this instead",
        "delivery" => "steer"
      })

      assert has_element?(view, ~s([data-delivery-chip="steered"]))

      # The defining property of a steer: it belongs to the running turn, so it
      # is not waiting in the rail.
      assert Chat.queue(conv) == []
    end

    test "a queued message stays in the rail and is never chipped as steered", %{conn: conn} do
      conv = start_conversation(transport_mod: FakeChatTransport)
      {:ok, view, _html} = home(conn)

      render_submit(element(view, "#home-composer"), %{"message" => "first", "delivery" => "auto"})

      render_submit(element(view, "#home-composer"), %{
        "message" => "afterwards, run the tests",
        "delivery" => "next"
      })

      assert [%{text: "afterwards, run the tests"}] = Chat.queue(conv)
      refute has_element?(view, ~s([data-delivery-chip="steered"]))
    end

    test "a steer that lost the race is reported as queued, not steered", %{conn: conn} do
      conv = start_conversation(transport_mod: FakeChatTransport)
      {:ok, view, _html} = home(conn)

      render_submit(element(view, "#home-composer"), %{"message" => "first", "delivery" => "auto"})

      # `RACE` makes the fake report `:no_active_turn` — the turn finished
      # between the operator hitting send and the adapter being asked.
      render_submit(element(view, "#home-composer"), %{
        "message" => "RACE too late",
        "delivery" => "steer"
      })

      # The UI must follow what HAPPENED, not what was asked for.
      refute has_element?(view, ~s([data-delivery-chip="steered"]))
      assert [%{text: "RACE too late"}] = Chat.queue(conv)
    end

    test "an unrecognised delivery falls back to auto rather than claiming a steer", %{conn: conn} do
      conv = start_conversation(transport_mod: FakeChatTransport)
      {:ok, view, _html} = home(conn)

      render_submit(element(view, "#home-composer"), %{
        "message" => "hello",
        "delivery" => "nonsense"
      })

      assert Chat.running?(conv)
      refute has_element?(view, ~s([data-delivery-chip="steered"]))
    end
  end

  describe "accessibility" do
    test "delivery state is announced, not encoded by the chip alone", %{conn: conn} do
      start_conversation(transport_mod: FakeChatTransport)
      {:ok, view, _html} = home(conn)

      assert has_element?(view, "#home-composer-announcement[aria-live='polite']")

      render_submit(element(view, "#home-composer"), %{"message" => "first", "delivery" => "auto"})

      render_submit(element(view, "#home-composer"), %{
        "message" => "redirect",
        "delivery" => "steer"
      })

      announcement = view |> element("#home-composer-announcement") |> render()

      # It says the WAIT out loud: Phase 0 measured that the agent picks a
      # steered message up at its next tool boundary, which is not instant.
      assert announcement =~ "Steered"
      assert announcement =~ "next step"
    end

    test "a race demotion announces the demotion, not a success", %{conn: conn} do
      start_conversation(transport_mod: FakeChatTransport)
      {:ok, view, _html} = home(conn)

      render_submit(element(view, "#home-composer"), %{"message" => "first", "delivery" => "auto"})

      render_submit(element(view, "#home-composer"), %{
        "message" => "RACE too late",
        "delivery" => "steer"
      })

      announcement = view |> element("#home-composer-announcement") |> render()
      assert announcement =~ "queued"
      refute announcement =~ "Steered"
    end
  end

  describe "the composer is one implementation" do
    test "Trading renders the same composer contract as Home", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/trading")

      # Same hook, same delivery field, same primary-action marker — the point
      # of the shared component. Trading scopes its ids by conversation.
      assert has_element?(view, ~s(form[phx-hook="Composer"]))
      assert has_element?(view, "[data-delivery]")
      assert has_element?(view, "[data-primary-action]")
    end
  end
end
