defmodule BusterClawWeb.SettingsLiveTest do
  @moduledoc """
  Configuration's four sections became a sub-tab rail on 08-15, so only one of
  them is on the page at a time. Every test below that exercises a section other
  than **Agent & models** — the tab the rail leads with — names its tab in the
  URL: `~p"/settings?tab=credentials"`.

  That param is read at mount and never written back (see
  `BusterClawWeb.Settings.Rail` for why the rail does not patch the URL), which
  is what makes it usable here: it is a one-token change to a mount rather than
  a `render_click` inserted into twenty tests, and it exercises the same
  `Registry.resolve/1` whitelist the rail click goes through.

  The model and harness tests are deliberately left on bare `~p"/settings"` —
  they pass only because Models is the default tab, which is an assertion worth
  having spread across the file rather than stated once.
  """
  use BusterClawWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias BusterClaw.ModelPolicy
  alias BusterClawWeb.Settings.Registry

  defp secret_key_base,
    do: Application.get_env(:buster_claw, BusterClawWeb.Endpoint)[:secret_key_base]

  test "GET /settings renders the recovery-key panel without exposing the key", %{conn: conn} do
    response = conn |> get(~p"/settings?tab=credentials") |> html_response(200)

    assert response =~ "Recovery key"
    assert response =~ "Reveal key"
    # The key itself is hidden until the user reveals it.
    refute response =~ secret_key_base()
  end

  # Was: "revealing the recovery key shows the configured secret" — it clicked
  # Reveal and asserted the key appeared in the re-rendered HTML. That behaviour
  # was removed deliberately in Clinch Phase 2: revealing the master key is now a
  # Keychain read performed by the desktop shell, written into a DOM node the
  # `RecoveryKey` hook owns. There is no server round-trip to assert on, which is
  # the point — the key that decrypts every other credential is no longer a
  # LiveView assign, so it cannot cross a tunnel.
  #
  # The replacement assertions live in `SettingsRecoveryKeyTest`.
  test "revealing is a client-side affair — no phx-click, no server round-trip", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/settings?tab=credentials")

    assert html =~ ~s(phx-hook="RecoveryKey")
    assert html =~ "data-recovery-toggle"
    assert html =~ "RESTORE_SECRET_KEY"

    refute html =~ "toggle_recovery",
           "the old server-side reveal event is still wired up"

    refute render(view) =~ secret_key_base()
  end

  describe "the Configuration sub-tab rail" do
    # The same property the GWS console rail underneath needed on 08-08: the
    # rail, the guard and the dispatch must agree. Two of the three are read
    # from `Settings.Registry`; the third is the `:if` branches in
    # `SettingsLive.render/1`, and the `ic-panel` assertion is what catches a
    # registry key that has no branch — without it a new tab would open a blank
    # page and this test would still pass.
    test "every tab the rail offers opens a section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      for key <- Registry.keys() do
        assert has_element?(view, "#settings-config-tab-#{key}"),
               "the rail does not render a button for #{key}"

        html = render_click(view, "select_settings_tab", %{"tab" => key})

        assert has_element?(view, ~s(#settings-config-tab-#{key}[aria-selected="true"])),
               "clicking #{key} did not open it — the guard and the rail disagree"

        assert html =~ "ic-panel",
               "#{key} is in the registry but render/1 has no branch for it — the " <>
                 "rail highlights a tab with nothing under it"
      end
    end

    test "an unknown tab key falls back to the default rather than blanking the page",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_click(view, "select_settings_tab", %{"tab" => "../../etc"})

      assert has_element?(
               view,
               ~s(#settings-config-tab-#{Registry.default()}[aria-selected="true"])
             )

      assert html =~ "ic-panel"
    end

    test "?tab= opens that tab, and an unknown one still lands somewhere real", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings?tab=credentials")
      assert html =~ "Recovery key"
      refute html =~ "Agent harness"

      {:ok, _view, html} = live(conn, ~p"/settings?tab=nope")
      assert html =~ "Agent harness"
    end

    # `SplitLive` mounts this view with `live_render/3`, and a child mounted
    # outside the router gets the ATOM `:not_mounted_at_router` where a params
    # map would be. Reading `?tab=` with `params["tab"]` took the whole pane
    # down; this is the walk that caught it.
    test "mounts in a split pane, where there are no params at all", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/split?left=/settings&right=/calendar")

      assert html =~ "Agent harness"
    end

    # Models leads because it is the only section that has to be right for the
    # app to run at all — the 08-15 DMG review opened to a dead picker.
    test "Models is the tab a bare /settings lands on", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert Registry.default() == "models"
      assert html =~ "Agent harness"
      # Not the h2 — the rail's own button says "Google Workspace" on every tab.
      refute html =~ "Connect the Google account"
      refute html =~ "Recovery key"
    end
  end

  # DMG-review-8-15 findings 1+2: the packaged app showed every harness disabled
  # and said nothing about why. Detection was fixed in `BusterClaw.AgentBackend`;
  # this is the sentence that is owed regardless, because "greyed out" reads as
  # "unsupported" and the real cause is a PATH the app never saw.
  #
  # Both directions are asserted. The PATH is pinned rather than mocked: with
  # `:login_shell_path` set to nil `ShellPath` falls back to the process PATH,
  # so pointing that at an empty directory makes nothing findable, and dropping
  # three executable stubs into it makes everything findable.
  describe "why a harness is greyed out" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      prev_login = Application.get_env(:buster_claw, :login_shell_path, :unset)
      prev_path = System.get_env("PATH")

      Application.put_env(:buster_claw, :login_shell_path, nil)
      System.put_env("PATH", tmp_dir)

      on_exit(fn ->
        if prev_path, do: System.put_env("PATH", prev_path)

        case prev_login do
          :unset -> Application.delete_env(:buster_claw, :login_shell_path)
          value -> Application.put_env(:buster_claw, :login_shell_path, value)
        end
      end)

      :ok
    end

    test "says what disabled means, and what to do about it", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      text = String.replace(html, ~r/\s+/, " ")

      # The picker really is in the state the note is explaining.
      assert BusterClaw.AgentBackend.installed() == []
      assert text =~ "(not installed)"

      assert text =~ "Greyed out means not found, not unsupported"
      # The diagnosis, which is the half a user cannot possibly guess.
      assert text =~ "inherits the system PATH rather than your shell&#39;s"
      assert text =~ "~/.local/bin"
      # And the action.
      assert text =~ "install it and reopen this page"
    end

    test "is silent when every harness resolves", %{conn: conn, tmp_dir: tmp_dir} do
      for backend <- BusterClaw.ModelPolicy.backends() do
        stub = Path.join(tmp_dir, BusterClaw.AgentBackend.executable(backend))
        File.write!(stub, "#!/bin/sh\n")
        File.chmod!(stub, 0o755)
      end

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert BusterClaw.AgentBackend.installed() == BusterClaw.ModelPolicy.backends()
      refute html =~ "Greyed out means not found"
      refute html =~ "(not installed)"
    end
  end

  describe "the harness picker" do
    test "offers every harness plus auto, and marks uninstalled ones", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render(view)

      assert html =~ "— auto —"

      for backend <- BusterClaw.ModelPolicy.backends() do
        assert html =~ Atom.to_string(backend)
      end

      # A harness that is not installed must be visible-but-disabled, not hidden:
      # hiding it makes the app look like it does not support codex at all.
      for backend <- BusterClaw.ModelPolicy.backends(),
          backend not in BusterClaw.AgentBackend.installed() do
        assert html =~ "#{backend} (not installed)"
      end
    end

    # The gap the operator found on 08-04: per-surface rows had a harness picker
    # and the GLOBAL default never did, so the only harness anyone could reach
    # from Settings was whichever one PATH detection happened to pick.
    test "the global harness can be chosen, not just per surface", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("#model-default-backend-form")
      |> render_change(%{"backend" => "codex"})

      assert BusterClaw.ModelPolicy.backend_for(:default) == :codex
      assert BusterClaw.ModelPolicy.backend_for(:chat) == :codex
    end

    test "the global harness offers all three, and auto", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render(view)

      assert html =~ "Global harness"
      assert html =~ "whichever CLI is found"

      for backend <- BusterClaw.ModelPolicy.backends() do
        assert html =~ Atom.to_string(backend)
      end
    end

    # The model list is claude's only while claude is chosen. Offering claude
    # model IDs to an operator running opencode is the one mistake that is
    # unambiguous — opencode needs provider/model.
    test "the model list follows the chosen harness", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      assert render(view) =~ "claude-opus-5"

      view
      |> element("#model-default-backend-form")
      |> render_change(%{"backend" => "opencode"})

      html = render(view)
      refute html =~ "claude-opus-5"
      assert html =~ "cannot list its own models from here"
      assert html =~ "your opencode CLI decides"
    end

    test "codex offers its own models, the way claude does", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("#model-default-backend-form")
      |> render_change(%{"backend" => "codex"})

      html = render(view)

      for model <- BusterClaw.ModelPolicy.known_models(:codex) do
        assert html =~ model
      end

      # And claude's models are gone — a bare claude ID is meaningless to codex.
      refute html =~ "claude-fable-5"
      # A harness WITH a list must not show the "nothing to pick" note.
      refute html =~ "cannot list its own models from here"
    end

    test "choosing a harness for one surface stores it and leaves others alone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("#model-backend-chat")
      |> render_change(%{"surface" => "chat", "backend" => "codex"})

      assert BusterClaw.ModelPolicy.backend_for(:chat) == :codex
      assert BusterClaw.ModelPolicy.backend_for(:dispatcher) == nil
    end

    test "auto gives the choice back to detection", %{conn: conn} do
      {:ok, _} = BusterClaw.ModelPolicy.put_backend(:chat, :codex)
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("#model-backend-chat")
      |> render_change(%{"surface" => "chat", "backend" => "auto"})

      assert BusterClaw.ModelPolicy.backend_for(:chat) == nil
    end

    # The pinned money surfaces (`trading_read`, `order_submit`) left with the
    # trading stack on 08-08, so no surface is claude-only or floored today. The
    # picker's *mechanism* for both is still exercised by the rows that remain.
  end

  describe "the agent model picker" do
    test "renders every surface, and says so when nothing is set", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render(view)

      assert html =~ "Agent harness"

      for {_surface, description} <- ModelPolicy.surfaces() do
        # The em-dashed tail is copy; the head is what identifies the row.
        head = description |> String.split(" — ") |> List.first()
        assert html =~ head, "the #{head} surface is missing from the picker"
      end

      # Unset is the shipped state, and it has to read as an answer rather than
      # as a blank — every row should say the CLI is deciding.
      assert html =~ "Your claude CLI decides"
      assert ModelPolicy.stored() == %{backends: %{}, models: %{}}
    end

    test "a per-surface override moves only that surface", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> form("#model-default-form", %{"model" => "claude-opus-5"}) |> render_change()

      html =
        view
        |> form("#model-surface-chat", %{"model" => "claude-haiku-4-5"})
        |> render_change()

      in_force = ModelPolicy.in_force()
      assert in_force[:chat].model == "claude-haiku-4-5"
      assert in_force[:chat].source == :surface
      assert in_force[:dispatcher].model == "claude-opus-5"
      assert in_force[:dispatcher].source == :default
      assert in_force[:swarm_run].model == "claude-opus-5"
      assert html =~ "set for this surface"
    end

    test "clearing a surface returns it to inheriting the default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> form("#model-default-form", %{"model" => "claude-opus-5"}) |> render_change()
      view |> form("#model-surface-chat", %{"model" => "claude-haiku-4-5"}) |> render_change()
      assert ModelPolicy.in_force()[:chat].source == :surface

      html = view |> form("#model-surface-chat", %{"model" => ""}) |> render_change()

      assert ModelPolicy.in_force()[:chat].model == "claude-opus-5"
      assert ModelPolicy.in_force()[:chat].source == :default
      assert html =~ "inherits the global default again"
    end

    test "free text is accepted for a model we do not ship in the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#model-custom-form", %{"target" => "swarm_run", "model" => "  my-own-alias  "})
        |> render_submit()

      assert ModelPolicy.for_surface(:swarm_run) == "my-own-alias"
      assert ModelPolicy.in_force()[:swarm_run].source == :surface
      # An unlisted model still has to render as the selected option, or the row
      # would claim it was inheriting.
      assert html =~ "my-own-alias"
    end

    test "blank free text is refused without taking the LiveView down", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> form("#model-default-form", %{"model" => "claude-opus-5"}) |> render_change()

      html =
        view
        |> form("#model-custom-form", %{"target" => "default", "model" => "   "})
        |> render_submit()

      assert html =~ "Type a model name"
      # Blank is not a clear: the default the operator already set survives.
      assert ModelPolicy.for_surface(:chat) == "claude-opus-5"
      assert render(view) =~ "Agent harness"
    end
  end

  describe "the Google Workspace console rail" do
    # The rail is rendered from GwsPanels.console_tab_keys/0 and the click is
    # resolved by SettingsLive's own guard. Those were two hand-written lists
    # until 08-08, so a sixth tab would have rendered a button that silently
    # fell back to Accounts. This walks every key the rail actually offers.
    test "every tab the rail offers is a tab the guard opens", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings?tab=google")

      for key <- BusterClawWeb.GwsPanels.console_tab_keys() do
        assert has_element?(view, "#gws-tab-#{key}"),
               "the rail does not render a button for #{key}"

        render_click(view, "gws_tab", %{"tab" => to_string(key)})

        assert has_element?(view, ~s(#gws-tab-#{key}[aria-current="page"])),
               "clicking #{key} did not open it — the guard and the rail disagree"
      end
    end

    test "an unknown tab key falls back to Accounts rather than crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings?tab=google")

      render_click(view, "gws_tab", %{"tab" => "../../etc"})

      assert has_element?(view, ~s(#gws-tab-accounts[aria-current="page"]))
    end
  end

  # Phase 3d. The panel's whole reason for existing is that a packaged app cannot
  # see shell environment variables, so BusterPhone was unconfigurable outside a
  # dev terminal. These assert the two things that makes true: the rows exist, and
  # they say where each value is coming from.
  describe "service credentials panel" do
    setup do
      prev = Application.get_env(:buster_claw, :finnhub_api_key)
      on_exit(fn -> Application.put_env(:buster_claw, :finnhub_api_key, prev) end)
      :ok
    end

    test "renders a row per registry entry, grouped", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings?tab=credentials")

      for key <- BusterClaw.Clinch.AppKeys.all() do
        assert html =~ key.label, "#{key.name} is in the registry but not on the screen"
      end

      assert html =~ "BusterPhone"
      assert html =~ "Service credentials"
    end

    test "shows where each value comes from, and updates when that changes", %{conn: conn} do
      Application.put_env(:buster_claw, :finnhub_api_key, nil)

      {:ok, view, html} = live(conn, ~p"/settings?tab=credentials")
      assert html =~ "Not set"

      assert {:ok, _} = BusterClaw.Clinch.put({:app_key, "finnhub_api_key"}, "stored-value")

      # The hook pushes this after the shell stores a credential; the panel must
      # re-read the SOURCE, not just the list of names.
      html = render_hook(view, "clinch:changed", %{})
      assert html =~ "Stored"
    end

    test "an environment-sourced key says so, and says why it matters", %{conn: conn} do
      Application.put_env(:buster_claw, :finnhub_api_key, "from-the-shell")

      {:ok, _view, html} = live(conn, ~p"/settings?tab=credentials")

      assert html =~ "Environment"
      # The diagnosis, not just the label — this is the sentence that turns
      # "it works in my terminal but not in the app" into an explanation.
      assert html =~ "packaged app cannot"
      assert html =~ "FINNHUB_API_KEY"
    end

    # The load-bearing property of this whole panel design, and the one a future
    # refactor to a "normal" LiveView form would silently destroy.
    test "no credential input carries a phx- binding", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings?tab=credentials")

      [_ | rows] = String.split(html, "data-app-key=")

      for row <- rows do
        # Just the row's own markup, up to the next element boundary we control.
        fragment = row |> String.split("data-app-key-status") |> List.first()

        refute fragment =~ "phx-change",
               "a service-credential row grew a phx-change — the value would " <>
                 "travel over the LiveView channel and land in the diff"

        refute fragment =~ "phx-submit",
               "a service-credential row grew a phx-submit — same leak"
      end
    end

    test "values are never rendered, not even a stored one", %{conn: conn} do
      assert {:ok, _} =
               BusterClaw.Clinch.put({:app_key, "twilio_auth_token"}, "super-secret-token")

      {:ok, _view, html} = live(conn, ~p"/settings?tab=credentials")

      refute html =~ "super-secret-token"
    end
  end

  # Invariant 5: a rotated key must never SILENTLY unconfigure anything. The
  # warning is the difference between an empty-looking app that is fine and an
  # empty-looking app that is an emergency.
  describe "unreadable-credential warning" do
    setup do
      prev = Application.get_env(:buster_claw, :secret_key_base)
      prev_env = System.get_env("SECRET_KEY_BASE")
      System.delete_env("SECRET_KEY_BASE")

      Application.put_env(
        :buster_claw,
        :secret_key_base,
        "settings-old-key-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      )

      on_exit(fn ->
        Application.put_env(:buster_claw, :secret_key_base, prev)
        if prev_env, do: System.put_env("SECRET_KEY_BASE", prev_env)
      end)

      :ok
    end

    test "is absent when every credential reads", %{conn: conn} do
      assert {:ok, _} = BusterClaw.Clinch.put({:sign_in, "acme"}, "value")

      {:ok, _view, html} = live(conn, ~p"/settings?tab=credentials")

      refute html =~ "cannot be read with the current master key"
    end

    test "appears, counts, and says the values are recoverable", %{conn: conn} do
      assert {:ok, _} = BusterClaw.Clinch.put({:sign_in, "acme"}, "value")

      # The key changes with no rotation — the situation the warning is for.
      Application.put_env(
        :buster_claw,
        :secret_key_base,
        "settings-new-key-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      )

      {:ok, _view, html} = live(conn, ~p"/settings?tab=credentials")

      # Collapse whitespace: HEEx keeps the newline+indent inside a sentence, so a
      # phrase that reads as one line in the template is not contiguous in the
      # HTML. The property is what the copy SAYS, not how it is wrapped.
      text = html |> String.replace(~r/\s+/, " ")

      assert text =~ "cannot be read with the current master key"
      assert text =~ "browser_secrets"

      # Recoverability is the point. A warning that only says "broken" invites
      # the one action that makes it permanent — re-entering everything and
      # discarding a key that would have brought it all back.
      assert text =~ "still on disk and still encrypted"
      assert text =~ "restore the previous key and the credentials come back"
    end
  end
end
