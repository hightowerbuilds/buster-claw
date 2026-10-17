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

  describe "the Settings tabs that open a section of this page" do
    # The guard and the dispatch must agree, and the tab bar must offer every
    # section: a key with no `:if` branch would render a page with nothing under
    # the tab bar, and a section with no tab would be unreachable.
    test "every section has a tab, and opens", %{conn: conn} do
      for key <- Registry.keys() do
        {:ok, view, html} = live(conn, "/settings?tab=#{key}")

        assert has_element?(view, ~s(#settings-tab-#{key}[aria-current="page"])),
               "#{key} has no tab in the Settings bar, or it is not marked current"

        assert html =~ "ic-panel",
               "#{key} is in the registry but render/1 has no branch for it"
      end
    end

    test "every tab in the bar that points here is a registry key" do
      for %{path: "/settings?tab=" <> key} <- BusterClawWeb.SettingsTabs.tabs() do
        assert key in Registry.keys(),
               "the Settings bar links to ?tab=#{key}, which is no section"
      end
    end

    test "an unknown tab key falls back to the default rather than blanking the page",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/settings?tab=../../etc")

      assert has_element?(view, ~s(#settings-tab-#{Registry.default()}[aria-current="page"]))
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
      # Not the h2 — the tab bar's own link says "Google Workspace" on every tab.
      refute html =~ "Connect the Google account"
      refute html =~ "Recovery key"
    end
  end

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
