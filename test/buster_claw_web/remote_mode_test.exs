defmodule BusterClawWeb.RemoteModeTest do
  @moduledoc """
  Clinch Phase 5's preconditions — the parts provable without a tunnel.

  Phase 5 lets an operator reach their own Mac over SSH. The roadmap's rule is
  *prove the tunnel first, no settings UI until it works*, and proving it needs a
  person, two machines and a laptop that goes to sleep. **These are the
  properties that must already be true before any of that is worth doing**, and
  every one of them is a thing a later change could quietly undo.

  The SSH roadmap was honest about the ground it stood on:

  > Browser pages have no account-login gate because loopback plus the desktop
  > shell is currently the gate. Anyone who can reach the loopback listener can
  > operate the UI.

  That is fine while "loopback" means sitting at the Mac. **The moment a tunnel
  exists it reads: anyone who reaches the tunnel operates the UI** — so what the
  UI can reach becomes the security boundary, and these tests are what pin it.
  """
  use BusterClawWeb.ConnCase, async: false

  describe "the web layer cannot reach the command surface" do
    # Phase 5's stated exit criterion: "a regression test that no LiveView calls
    # Commands.call/3".
    #
    # Why it matters, precisely: `Commands.call/3` defaults to `caller: :trusted`
    # (commands.ex). A LiveView carries no API token, so a call from one would run
    # as FULLY TRUSTED — and a remote browser driving that LiveView would inherit
    # it, bypassing the tier system entirely. The tiers only mean anything while
    # the command surface is reached with a token.
    #
    # `ApiController` is the one allowed caller because it is the one place that
    # has authenticated a token and can pass a real caller through.
    @allowed ["lib/buster_claw_web/controllers/api_controller.ex"]

    defp web_files, do: Path.wildcard("lib/buster_claw_web/**/*.ex")

    # Strip doc heredocs and comment lines: prose about the command surface is
    # documentation, not a call. Same approach as `Clinch.ChokepointTest`.
    defp code_only(source) do
      source
      |> String.split(~s("""))
      |> Enum.with_index()
      |> Enum.filter(fn {_part, i} -> rem(i, 2) == 0 end)
      |> Enum.map_join("\n", fn {part, _i} -> part end)
      |> String.split("\n")
      |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
      |> Enum.join("\n")
    end

    test "only the API controller calls Commands.call/3" do
      offenders =
        for file <- web_files(),
            file not in @allowed,
            code = code_only(File.read!(file)),
            String.contains?(code, "Commands.call("),
            do: file

      assert offenders == [],
             """
             These web-layer files call Commands.call/3:

             #{Enum.map_join(offenders, "\n", &"  #{&1}")}

             `Commands.call/3` defaults to caller: :trusted, and a LiveView has no
             token to authenticate with — so this runs as fully trusted, and a
             REMOTE BROWSER driving that LiveView inherits it. The tier system only
             holds while the command surface is reached with a token.

             Call the context module directly, or route it through
             BusterClawWeb.ApiController, which has a real caller to pass.
             """
    end

    test "the scan sees the one allowed call" do
      # Without this the test above passes just as happily if the pattern stops
      # matching anything — a stripper bug reading as a clean codebase, which is
      # the vacuously-green failure this repo keeps finding.
      code = code_only(File.read!(hd(@allowed)))

      assert String.contains?(code, "Commands.call("),
             "the API controller no longer calls Commands.call/3, or the stripper " <>
               "ate it — either way the scan above is proving nothing"
    end
  end

  describe "credential management is unreachable without a token" do
    # Phase 5's other stated proof: "a hand-rolled fetch to /api/clinch from a
    # tunneled browser returns 401". A tunneled browser has no API token — it has
    # a session, which these routes do not accept — so this is that proof, minus
    # the tunnel.
    test "an unauthenticated request to the Clinch is refused", %{conn: _conn} do
      for {method, path, params} <- [
            {:post, ~p"/api/clinch", %{"kind" => "sign_in", "name" => "x", "value" => "y"}},
            {:delete, ~p"/api/clinch", %{"kind" => "sign_in", "name" => "x"}},
            {:post, ~p"/api/clinch/rotate", %{"new_key" => "k"}}
          ] do
        conn =
          case method do
            :post -> post(build_conn(), path, params)
            :delete -> delete(build_conn(), path, params)
          end

        assert conn.status in [401, 403],
               "#{method} #{path} answered #{conn.status} without a token. A remote " <>
                 "browser reaches every LiveView; it must not reach credential " <>
                 "management, and a session is not a token."
      end
    end
  end

  describe "check_origin" do
    # The roadmap says it in capitals: "Do not loosen it to `false`." It is the
    # tempting fix when a tunneled WebSocket refuses to upgrade, and it turns the
    # origin check off for every caller rather than for the tunnel.
    #
    # Read from source rather than config, because the test environment is not the
    # production one and asking the running app would prove nothing about what
    # ships.
    test "production does not disable it" do
      runtime = File.read!("config/runtime.exs")

      [_ | after_key] = String.split(runtime, "check_origin:", parts: 2)
      value = after_key |> hd() |> String.split("\n") |> hd() |> String.trim()

      refute value =~ "false",
             "config/runtime.exs sets check_origin: #{value}. Phase 5 tunnels a " <>
               "browser to this endpoint, and `false` accepts a WebSocket from any " <>
               "origin — including a page an attacker controls. The tunneled client " <>
               "binds locally, so //127.0.0.1 and //localhost already match it."

      refute value =~ "true",
             "check_origin: true derives the origin from the endpoint's :url host, " <>
               "which a tunneled client does not send. Keep the explicit list."
    end
  end
end
