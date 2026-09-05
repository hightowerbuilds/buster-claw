defmodule BusterClawWeb.WorkspaceLiveTest do
  use BusterClawWeb.ConnCase

  import Phoenix.LiveViewTest

  alias BusterClaw.Calendar
  alias BusterClaw.Commands
  alias BusterClaw.LocalTime

  setup do
    root =
      Path.join(System.tmp_dir!(), "buster-claw-ws-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "library"))
    File.write!(Path.join(root, "readme.md"), "# workspace\n")

    prev_ws = Application.get_env(:buster_claw, :workspace_root)
    prev_lib = Application.get_env(:buster_claw, :library_root)
    Application.put_env(:buster_claw, :workspace_root, root)
    Application.put_env(:buster_claw, :library_root, Path.join(root, "library"))

    on_exit(fn ->
      if prev_ws, do: Application.put_env(:buster_claw, :workspace_root, prev_ws)
      if prev_lib, do: Application.put_env(:buster_claw, :library_root, prev_lib)
      File.rm_rf(root)
    end)

    %{root: root, root_abs: Path.expand(root)}
  end

  test "renders the workspace tree with manage controls", %{conn: conn, root_abs: root_abs} do
    {:ok, _view, html} = live(conn, ~p"/workspace")
    assert html =~ "Workspace"
    assert html =~ root_abs
    assert html =~ "readme.md"
    assert html =~ "library"
    assert html =~ "+ Folder"
  end

  test "selecting a file previews its contents", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element(~s|#workspace button[phx-click="select"]|)
    |> render_click()

    # .md files render as a sanitized blog-style HTML preview (not raw source).
    html = render(view)
    assert html =~ "md-prose"
    assert html =~ "<h1>workspace</h1>"
  end

  test "create a folder then delete it via the tree", %{
    conn: conn,
    root: root,
    root_abs: root_abs
  } do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element(~s|#workspace button[phx-value-kind="dir"][phx-value-parent="#{root_abs}"]|)
    |> render_click()

    view
    |> element(~s|#workspace form[phx-submit="submit_create"]|)
    |> render_submit(%{"name" => "fresh"})

    assert File.dir?(Path.join(root, "fresh"))

    # Deleting is a two-step inline confirm (no native window.confirm — it
    # silently no-ops in the webview shell).
    view
    |> element(
      ~s|#workspace button[phx-click="start_delete"][phx-value-path="#{Path.join(root_abs, "fresh")}"]|
    )
    |> render_click()

    view
    |> element(
      ~s|#workspace button[phx-click="delete"][phx-value-path="#{Path.join(root_abs, "fresh")}"]|
    )
    |> render_click()

    refute File.exists?(Path.join(root, "fresh"))
  end

  test "deletes an existing non-empty folder via the tree", %{
    conn: conn,
    root: root,
    root_abs: root_abs
  } do
    File.write!(Path.join([root, "library", "note.md"]), "# note\n")
    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element(
      ~s|#workspace button[phx-click="start_delete"][phx-value-path="#{Path.join(root_abs, "library")}"]|
    )
    |> render_click()

    view
    |> element(
      ~s|#workspace button[phx-click="delete"][phx-value-path="#{Path.join(root_abs, "library")}"]|
    )
    |> render_click()

    refute File.exists?(Path.join(root, "library"))
  end

  test "navigates up to the parent directory and offers to set it as workspace", %{
    conn: conn,
    root: root
  } do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    html = view |> element("button", "Up") |> render_click()

    # The parent listing now includes the old workspace folder as a child,
    # and since we're above the workspace we can re-root or set a new one.
    assert html =~ Path.basename(Path.expand(root))
    assert html =~ "Set as workspace"
    assert html =~ "Go to workspace"
  end

  # ── Notes and Calendar, moved from the homepage on 09-05 ──────────────────
  #
  # These eighteen tests came out of `status_live_test.exs` unchanged except for
  # where they point: the route, the tab event, and the two component ids. That
  # they needed nothing else is the evidence the move was a move — both surfaces
  # are the same `LiveComponent` they always were, and only the page providing
  # the chrome changed.
  describe "Workspace sub-tabs" do
    test "the rail and the select_workspace_tab guard cannot disagree", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspace")

      # Every tab the rail offers must be one the server accepts. Home shipped
      # this bug once — a button the guard had never heard of, and the click
      # raised — which is why both come from one list and why this asserts it.
      for {key, _label} <- BusterClawWeb.WorkspaceLive.workspace_tabs() do
        assert has_element?(view, "button[phx-value-tab='#{key}']")
        render_click(view, "select_workspace_tab", %{"tab" => key})
        assert has_element?(view, "button[phx-value-tab='#{key}'].bg-primary")
      end
    end

    test "Directory is the default view and the tabs are in order", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspace")

      # A review-forcing snapshot, the same service `status_live_test` does for
      # Home: a tab added here or removed must fail so somebody looks.
      assert BusterClawWeb.WorkspaceLive.workspace_tabs() == [
               {"directory", "Directory"},
               {"notes", "Notes"},
               {"calendar", "Calendar"}
             ]

      assert has_element?(view, "button[phx-value-tab='directory'].bg-primary")
      assert has_element?(view, "#workspace-tree")
      refute has_element?(view, "#workspace-notes")
    end

    test "the Calendar sub-tab renders today's calendar events", %{conn: conn} do
      today = LocalTime.today()

      {:ok, _event} =
        Calendar.create_event(%{
          event_id: "home-today-event",
          date: today,
          start_time: ~T[09:30:00],
          title: "Home page planning block",
          notes: "Visible on the daily agenda.",
          color: "work"
        })

      {:ok, view, _html} = live(conn, ~p"/workspace")

      # Chat is the default; the calendar (and its events) appear once the Calendar
      # sub-tab is selected, mounting the embedded CalendarComponent.
      html = render_click(view, "select_workspace_tab", %{"tab" => "calendar"})

      assert html =~ ~s(id="calendar-grid")
      assert html =~ "Home page planning block"
      assert html =~ "09:30"
    end

    test "the calendar anchors to the app-local date, not UTC", %{conn: conn} do
      previous = Application.get_env(:buster_claw, :local_today)
      Application.put_env(:buster_claw, :local_today, ~D[2026-05-26])

      on_exit(fn ->
        if previous do
          Application.put_env(:buster_claw, :local_today, previous)
        else
          Application.delete_env(:buster_claw, :local_today)
        end
      end)

      {:ok, _event} =
        Calendar.create_event(%{
          event_id: "home-local-today",
          date: ~D[2026-05-26],
          title: "Local today event"
        })

      # An event in the REAL current (UTC) month. The calendar opens on the
      # app-local month (May 2026), so this event's month is never shown — if the
      # grid used UTC "today" instead, this title would render and the May event
      # would not.
      {:ok, _event} =
        Calendar.create_event(%{
          event_id: "home-utc-month",
          date: Date.utc_today(),
          title: "UTC month event"
        })

      {:ok, view, _html} = live(conn, ~p"/workspace")
      html = render_click(view, "select_workspace_tab", %{"tab" => "calendar"})

      assert html =~ "Local today event"
      refute html =~ "UTC month event"
    end

    test "the Calendar sub-tab shows the calendar and hides the directory", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspace")

      render_click(view, "select_workspace_tab", %{"tab" => "calendar"})

      assert has_element?(view, "#calendar-grid")
      # The event form lives in a modal now — closed until Add Events opens it.
      assert has_element?(view, "#calendar-add-events")
      refute has_element?(view, "#event-form")
      assert has_element?(view, "button[phx-value-tab='calendar'].bg-primary")

      # ...and switching back to Directory hides the calendar again. The tab this
      # returns to is the only line that changed when this test moved: on Home
      # the alternative was Chat, and here it is the file tree.
      render_click(view, "select_workspace_tab", %{"tab" => "directory"})
      refute has_element?(view, "#calendar-grid")
    end

    test "the Notes sub-tab creates, edits, and saves a Markdown file",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/workspace")

      render_click(view, "select_workspace_tab", %{"tab" => "notes"})
      refute has_element?(view, "#calendar-grid")
      assert has_element?(view, "#workspace-notes")
      assert has_element?(view, "#notes-empty-state")
      assert has_element?(view, "button[phx-value-tab='notes'].bg-primary")

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Remote access"}})
      |> render_submit()

      assert has_element?(view, "#notes-editor-pane")
      # The model and the view the NoteEditor hook renders into. The surface is
      # `phx-update="ignore"` and stays empty on the server, so there is nothing
      # here to assert about its contents — that is the JS suite's job.
      assert has_element?(view, "#note-editor")
      assert has_element?(view, ~s(#note-surface[phx-update="ignore"][contenteditable="true"]))

      view
      |> form("#note-editor-form", %{
        "editor" => %{"body" => "# Remote access\n\n- Keep Phoenix on loopback"}
      })
      |> render_change()

      assert has_element?(view, ~s(#note-save-status[data-state="saved"]))

      assert File.read!(Path.join([root, "notes", "Remote access.md"])) =~
               "Keep Phoenix on loopback"
    end

    test "the Notes editor preserves a draft when the file changes on disk",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Shared draft"}})
      |> render_submit()

      path = Path.join([root, "notes", "Shared draft.md"])
      File.write!(path, "newer disk version")

      view
      |> form("#note-editor-form", %{"editor" => %{"body" => "my unsaved draft"}})
      |> render_change()

      assert has_element?(view, ~s(#note-save-status[data-state="conflict"]))
      assert has_element?(view, "#note-conflict")
      assert has_element?(view, "#reload-note-button")
      assert has_element?(view, "#overwrite-note-button")
      assert File.read!(path) == "newer disk version"
    end

    test "the Notes rail files a note into a folder and moves it back out",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      # The folder form is behind its toggle until asked for.
      refute has_element?(view, "#new-folder-form")
      view |> element("#new-folder-button") |> render_click()

      view
      |> form("#new-folder-form", %{"folder" => %{"name" => "Projects"}})
      |> render_submit()

      refute has_element?(view, "#new-folder-form")
      assert File.dir?(Path.join([root, "notes", "Projects"]))

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Launch", "folder" => "Projects"}})
      |> render_submit()

      assert File.exists?(Path.join([root, "notes", "Projects", "Launch.md"]))
      assert has_element?(view, ~s([data-note-heading="Projects"]))
      assert has_element?(view, ~s(button[phx-value-path="Projects/Launch.md"]))

      # Rename and move in one submission: the file lands under its new name at
      # the vault root and nothing is left behind at the old path. The form is
      # opened by double-clicking the title, which is a hook pushing the same
      # event the removed pencil pushed (W1).
      refute has_element?(view, "#rename-note-form")
      view |> element("#note-title") |> render_hook("toggle_rename", %{})
      assert has_element?(view, "#rename-note-form")

      view
      |> form("#rename-note-form", %{"rename" => %{"title" => "Launch plan", "folder" => ""}})
      |> render_submit()

      assert File.exists?(Path.join([root, "notes", "Launch plan.md"]))
      refute File.exists?(Path.join([root, "notes", "Projects", "Launch.md"]))
      refute has_element?(view, ~s([data-note-heading="Projects"]))
      assert has_element?(view, ~s(button[phx-value-path="Launch plan.md"]))
    end

    test "rename and delete are gestures, not buttons in the editor header",
         %{conn: conn, root: root} do
      # daily-growth/archive/08-09-26-notes-editor.md W1/W2. The operator asked for the pencil and the
      # trash can to go; asserting their absence is the only way "we put one
      # back for convenience" ever gets noticed.
      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Doomed"}})
      |> render_submit()

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Kept"}})
      |> render_submit()

      refute has_element?(view, "#rename-note-button")
      refute has_element?(view, "#delete-note-button")

      # The title is the rename trigger: hook-bound, focusable, and carrying the
      # phx-target that routes its push back to this component.
      assert has_element?(view, ~s(#note-title[phx-hook="NoteTitle"][tabindex="0"]))

      # What the rail owes the context menu: a marked row per note, carrying the
      # path, and one hook-owned menu whose Delete item is otherwise the header
      # button that used to do this.
      assert has_element?(view, ~s(button[data-note-row="Doomed.md"]))
      assert has_element?(view, ~s(button[data-note-row="Kept.md"]))
      assert has_element?(view, ~s(#notes-ctx[phx-hook="NoteContextMenu"][phx-update="ignore"]))
      assert has_element?(view, ~s(#notes-ctx-delete[data-ctx-delete][phx-click="delete_note"]))

      # The path is the hook's to fill in, so the server must not ship one — a
      # hardcoded value here would delete the wrong note on the first click.
      refute view |> element("#notes-ctx-delete") |> render() =~ "phx-value-path"

      # Deleting a note that is not the open one leaves the editor alone. The
      # click goes through the menu item itself with the path the hook would
      # have set, which is also what proves `phx-target` routes it here rather
      # than at StatusLive.
      view |> element(~s(button[data-note-row="Kept.md"])) |> render_click()
      view |> element("#notes-ctx-delete") |> render_click(%{"path" => "Doomed.md"})

      refute File.exists?(Path.join([root, "notes", "Doomed.md"]))
      refute has_element?(view, ~s(button[data-note-row="Doomed.md"]))
      assert has_element?(view, "#notes-editor-pane")

      # Deleting the open one closes it.
      view |> element("#notes-ctx-delete") |> render_click(%{"path" => "Kept.md"})

      refute File.exists?(Path.join([root, "notes", "Kept.md"]))
      refute has_element?(view, "#notes-editor-pane")
      assert has_element?(view, "#notes-empty-state")
    end

    test "the Notes editor reports Unsaved, saves on demand, and reconciles with disk",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Field notes"}})
      |> render_submit()

      path = Path.join([root, "notes", "Field notes.md"])

      # "Saving…" is CSS keyed to `#notes-editor-pane:has(form[data-note-editor]
      # .phx-change-loading)`. Nothing else asserts that anchor, and losing it
      # would drop one save state silently.
      assert has_element?(view, "#notes-editor-pane form[data-note-editor]")
      assert has_element?(view, "#note-save-status [data-note-saving]")

      # The hook's clean -> dirty announcement, which is the only reason the chip
      # can say Unsaved during the 700ms the server hears nothing.
      view |> element("#notes-editor-pane") |> render_hook("note_dirty", %{})
      assert has_element?(view, ~s(#note-save-status[data-state="unsaved"]))

      # ⌘S submits the same form the debounce would have.
      view
      |> form("#note-editor-form", %{"editor" => %{"body" => "# Field notes\n"}})
      |> render_submit()

      assert has_element?(view, ~s(#note-save-status[data-state="saved"]))
      assert File.read!(path) == "# Field notes\n"

      # Clean editor, changed file: adopt disk silently. Refusing to show the
      # newer file would be the surprising half of this.
      File.write!(path, "# From another editor\n")
      view |> element("#notes-editor-pane") |> render_hook("check_revision", %{})

      assert has_element?(view, ~s(#note-save-status[data-state="saved"]))
      assert view |> element("#note-editor") |> render() =~ "From another editor"

      # Draft in flight, changed file: the same fact becomes a conflict, and the
      # newer bytes stay on disk.
      view |> element("#notes-editor-pane") |> render_hook("note_dirty", %{})
      File.write!(path, "# From a third editor\n")
      view |> element("#notes-editor-pane") |> render_hook("check_revision", %{})

      assert has_element?(view, ~s(#note-save-status[data-state="conflict"]))
      assert has_element?(view, "#copy-draft-button")
      assert File.read!(path) == "# From a third editor\n"

      # Autosave has stopped: a further keystroke updates the draft only.
      view
      |> form("#note-editor-form", %{"editor" => %{"body" => "still typing"}})
      |> render_change()

      assert has_element?(view, ~s(#note-save-status[data-state="conflict"]))
      assert File.read!(path) == "# From a third editor\n"
    end

    test "the toolbar renders every command as a client-only button", %{conn: conn} do
      # No `phx-click` anywhere in it, deliberately: formatting is a text edit
      # the hook makes locally, and a round-trip between pressing Bold and
      # seeing bold would undo the point of the surface. What the buttons DO is
      # the JS suite's; that they exist, and that they are inert to the server,
      # is this one's.
      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Formatted"}})
      |> render_submit()

      assert has_element?(view, ~s(#note-toolbar[role="toolbar"]))

      for %{cmd: cmd} <- BusterClawWeb.Notes.Toolbar.commands() do
        assert has_element?(view, ~s(#note-cmd-#{cmd}[data-note-cmd="#{cmd}"][type="button"])),
               "the toolbar is missing a button for #{cmd}"
      end

      refute view |> element("#note-toolbar") |> render() =~ "phx-click"
    end

    test "a save does not echo the draft back into the editor field", %{conn: conn, root: root} do
      # The regression guard for the "flickering between saved and unsaved"
      # report (08-09). The <textarea> is hidden and never focused, and LiveView
      # only declines to clobber a FOCUSED input — so re-rendering it on every
      # save pushed the server's copy over the client's live draft mid-keystroke.
      #
      # The fix is that a save assigns :body but NOT :editor_form, so the diff
      # carries no update for that element at all. This asserts the mechanism:
      # the rendered field must be byte-identical across a save, even though the
      # file on disk changed. It looks like asserting staleness, and it is —
      # the client owns the draft, the server only confirms it.
      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Echo"}})
      |> render_submit()

      before = view |> element("#note-editor") |> render()

      view
      |> form("#note-editor-form", %{"editor" => %{"body" => "# Typed by the client\n"}})
      |> render_change()

      assert has_element?(view, ~s(#note-save-status[data-state="saved"]))
      assert File.read!(Path.join([root, "notes", "Echo.md"])) == "# Typed by the client\n"

      assert view |> element("#note-editor") |> render() == before,
             "the save re-rendered the editor field, which clobbers the client's draft"
    end

    test "the editor is the preview: there is no second pane and no toggle",
         %{conn: conn} do
      # daily-growth/archive/08-09-26-notes-editor.md D7. Asserted rather than assumed, because "the
      # preview came back" is a regression nothing else in this file would see.
      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Toggle me"}})
      |> render_submit()

      refute has_element?(view, "#note-preview")
      refute has_element?(view, "#toggle-preview-button")
      assert has_element?(view, "#note-surface")
    end

    test "a Markdown file too large to edit is listed but never opened",
         %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "notes"))
      File.write!(Path.join([root, "notes", "Huge.md"]), String.duplicate("x", 1_000_001))

      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      assert has_element?(view, ~s(button[phx-value-path="Huge.md"]))
      view |> element(~s(button[phx-value-path="Huge.md"])) |> render_click()

      assert has_element?(view, "#notes-unsupported")
      refute has_element?(view, "#note-editor")
      refute render(view) =~ "xxxxxxxxxx"

      view |> element("#unsupported-back-button") |> render_click()
      assert has_element?(view, "#notes-empty-state")
    end

    test "the Notes rail searches bodies and shows a snippet", %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "notes"))
      File.write!(Path.join([root, "notes", "Tunnel.md"]), "Keep Phoenix on loopback.\n")
      File.write!(Path.join([root, "notes", "Groceries.md"]), "Oat milk.\n")

      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      assert has_element?(view, ~s(button[phx-value-path="Groceries.md"]))

      view
      |> form("#notes-search-form", %{"search" => %{"query" => "loopback"}})
      |> render_change()

      assert has_element?(view, ~s(button[phx-value-path="Tunnel.md"]))
      refute has_element?(view, ~s(button[phx-value-path="Groceries.md"]))
      assert render(view) =~ "Keep Phoenix on loopback."

      view
      |> form("#notes-search-form", %{"search" => %{"query" => "zzz no match"}})
      |> render_change()

      assert render(view) =~ "No notes match."

      view
      |> form("#notes-search-form", %{"search" => %{"query" => ""}})
      |> render_change()

      assert has_element?(view, ~s(button[phx-value-path="Groceries.md"]))
    end

    test "the switcher jumps to a note by keyboard", %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "notes"))
      File.write!(Path.join([root, "notes", "Alpha.md"]), "first\n")
      File.write!(Path.join([root, "notes", "Beta.md"]), "second\n")

      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      refute has_element?(view, "#note-switcher")
      view |> element("#workspace-notes") |> render_hook("open_switcher", %{})

      assert has_element?(view, "#note-switcher")
      assert has_element?(view, ~s(#note-switcher-input[aria-activedescendant]))
      assert has_element?(view, ~s(li[role="option"][aria-selected="true"]), "Alpha")

      # Arrow down moves the selection; Enter opens whatever it landed on.
      view |> element("#workspace-notes") |> render_hook("switcher_move", %{"dir" => "down"})
      assert has_element?(view, ~s(li[role="option"][aria-selected="true"]), "Beta")

      view |> element("#workspace-notes") |> render_hook("switcher_select", %{})
      refute has_element?(view, "#note-switcher")
      assert has_element?(view, "#notes-editor-pane")
      assert render(view) =~ "Beta.md"

      # Escape closes without touching the note.
      view |> element("#workspace-notes") |> render_hook("open_switcher", %{})
      view |> element("#workspace-notes") |> render_hook("close_switcher", %{})
      refute has_element?(view, "#note-switcher")
      assert has_element?(view, "#notes-editor-pane")
    end

    test "wiki links open notes, offer to create missing ones, and list backlinks",
         %{conn: conn, root: root} do
      File.mkdir_p!(Path.join(root, "notes"))
      File.write!(Path.join([root, "notes", "Remote access.md"]), "# Remote access\n")

      File.write!(
        Path.join([root, "notes", "Launch.md"]),
        "See [[Remote access]] and [[Ghost]].\n"
      )

      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})
      view |> element(~s(button[phx-value-path="Launch.md"])) |> render_click()

      # The editor sends the raw target and nothing else — one event for both
      # cases, because only the server can tell them apart. A known link opens
      # the note it names...
      view
      |> element("#notes-editor-pane")
      |> render_hook("follow_link", %{"target" => "Remote access"})

      assert has_element?(view, ~s(#notes-editor-pane[data-note-path="Remote access.md"]))
      # ...and the note it came from is listed as a backlink.
      assert has_element?(view, "#note-backlinks")
      assert has_element?(view, ~s(#note-backlinks button[phx-value-path="Launch.md"]))

      # ...while a missing one is created rather than dead-ending.
      view
      |> element("#notes-editor-pane")
      |> render_hook("follow_link", %{"target" => "Ghost"})

      assert File.exists?(Path.join([root, "notes", "Ghost.md"]))
      assert has_element?(view, ~s(button[phx-value-path="Ghost.md"]))
    end

    test "the new-note chord reveals the rail by clearing the selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Open one"}})
      |> render_submit()

      assert has_element?(view, "#notes-editor-pane")

      view |> element("#workspace-notes") |> render_hook("new_note", %{})

      refute has_element?(view, "#notes-editor-pane")
      assert has_element?(view, "#new-note-title")
    end

    test "an agent's note command reaches an open Notes rail without a tab switch",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      refute has_element?(view, ~s(button[phx-value-path="Agent note.md"]))

      {:ok, _created} =
        Commands.call("note_create", %{"title" => "Agent note", "body" => "from the terminal\n"})

      assert has_element?(view, ~s(button[phx-value-path="Agent note.md"]))
      assert File.exists?(Path.join([root, "notes", "Agent note.md"]))
    end

    test "an agent edit colliding with an open draft preserves both versions",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, ~p"/workspace")
      render_click(view, "select_workspace_tab", %{"tab" => "notes"})

      view
      |> form("#new-note-form", %{"note" => %{"title" => "Shared"}})
      |> render_submit()

      # The operator is mid-sentence: a draft the server knows about but has not
      # saved (exactly the window `phx-debounce` opens).
      view |> element("#notes-editor-pane") |> render_hook("note_dirty", %{})
      assert has_element?(view, ~s(#note-save-status[data-state="unsaved"]))

      {:ok, read} = Commands.call("note_read", %{"path" => "Shared.md"})

      {:ok, _saved} =
        Commands.call("note_save", %{
          "path" => "Shared.md",
          "body" => "the agent's version\n",
          "revision" => read.revision
        })

      # The broadcast reaches the open panel: conflict, not a silent swap.
      assert has_element?(view, ~s(#note-save-status[data-state="conflict"]))
      assert has_element?(view, "#note-conflict")
      assert has_element?(view, "#copy-draft-button")
      assert File.read!(Path.join([root, "notes", "Shared.md"])) == "the agent's version\n"
    end
  end
end
