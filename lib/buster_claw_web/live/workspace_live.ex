defmodule BusterClawWeb.WorkspaceLive do
  @moduledoc """
  Workspace file manager. Hosts the reusable `FileTree` with a preview pane and
  free directory navigation — an "Up" button, a clickable breadcrumb, and Home —
  so you can browse anywhere (e.g. up to the Desktop). Any folder you navigate to
  can be made the workspace via "Set as workspace", which applies immediately
  (no restart) and is persisted for the next launch.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.FileManager
  alias BusterClaw.Library.Artifact
  alias BusterClaw.Setup

  @impl true
  def mount(_params, _session, socket) do
    workspace = Artifact.workspace_root()

    {:ok,
     socket
     |> assign(:page_title, "Workspace")
     |> assign(:workspace_root, workspace)
     |> assign(:tree_root, workspace)
     |> assign(:tree_base, workspace)
     |> assign(:preview, nil)
     |> assign(:sidebar_open, true)
     |> assign(:note, nil)
     |> assign(:tree_version, 0)
     |> allow_upload(:import,
       accept: :any,
       max_entries: 25,
       max_file_size: 200_000_000,
       auto_upload: true,
       progress: &handle_import_progress/3
     )
     |> assign_path_view()}
  end

  # Files dropped from the OS (Finder) land here via phx-drop-target + auto_upload.
  # Each finished entry is copied into the folder currently in view (tree_root)
  # through FileManager (name-deduped), then the tree is nudged to re-list.
  defp handle_import_progress(:import, entry, socket) do
    if entry.done? do
      dest = socket.assigns.tree_root

      result =
        consume_uploaded_entry(socket, entry, fn %{path: tmp} ->
          {:ok, FileManager.import_file(tmp, dest, entry.client_name, dest)}
        end)

      socket =
        case result do
          {:ok, _target} ->
            socket
            |> update(:tree_version, &(&1 + 1))
            |> assign(:note, "Added #{entry.client_name}.")

          {:error, reason} ->
            assign(socket, :note, "Couldn't add #{entry.client_name}: #{inspect(reason)}")
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, update(socket, :sidebar_open, &(not &1))}
  end

  @impl true
  def handle_event("up", _params, socket) do
    {:noreply, navigate(socket, Path.dirname(socket.assigns.tree_root))}
  end

  def handle_event("nav", %{"path" => path}, socket) do
    {:noreply, navigate(socket, path)}
  end

  def handle_event("go_home", _params, socket) do
    {:noreply, navigate(socket, FileManager.home())}
  end

  def handle_event("go_workspace", _params, socket) do
    {:noreply, navigate(socket, socket.assigns.workspace_root)}
  end

  def handle_event("set_workspace", _params, socket) do
    path = socket.assigns.tree_root

    case set_workspace_root(path) do
      :ok ->
        {:noreply,
         socket
         |> assign(:workspace_root, path)
         |> assign(:note, "Workspace is now #{path}.")
         |> assign_path_view()}

      {:error, message} ->
        {:noreply, assign(socket, :note, "Couldn't set workspace: #{message}")}
    end
  end

  # Native OS-file drop (Tauri): the WorkspaceDropzone hook delivers real source
  # paths; copy each into the folder in view. Copying by path works even though
  # the workspace root may be a symlink — the OS follows it, and FileManager's
  # containment check canonicalizes symlinks.
  def handle_event("import_paths", %{"paths" => paths}, socket) when is_list(paths) do
    dest = socket.assigns.tree_root

    {added, failed} =
      Enum.reduce(paths, {0, 0}, fn src, {added, failed} ->
        src = to_string(src)

        case FileManager.import_file(src, dest, Path.basename(src), dest) do
          {:ok, _target} -> {added + 1, failed}
          {:error, _reason} -> {added, failed + 1}
        end
      end)

    note =
      cond do
        added > 0 and failed == 0 -> "Added #{added} #{plural(added, "item")}."
        added > 0 -> "Added #{added}; #{failed} couldn't be added."
        true -> "Couldn't add #{failed} #{plural(failed, "item")}."
      end

    {:noreply, socket |> update(:tree_version, &(&1 + 1)) |> assign(:note, note)}
  end

  @impl true
  def handle_info({:file_selected, path}, socket) do
    {:noreply, assign(socket, :preview, preview_for(path, socket.assigns.tree_base))}
  end

  # Navigate the tree to a directory (always allowed); ops stay scoped to it.
  defp navigate(socket, dir) do
    dir = Path.expand(dir)

    socket
    |> assign(:tree_root, dir)
    |> assign(:tree_base, dir)
    |> assign(:preview, nil)
    |> assign_path_view()
  end

  # Derive the breadcrumb + position flags once, whenever tree_root or
  # workspace_root changes, instead of recomputing them on every render.
  defp assign_path_view(socket) do
    tree_root = socket.assigns.tree_root
    workspace_root = socket.assigns.workspace_root

    socket
    |> assign(:crumbs, crumbs(tree_root))
    |> assign(:at_workspace?, Path.expand(tree_root) == Path.expand(workspace_root))
    |> assign(:at_root?, Path.dirname(tree_root) == tree_root)
  end

  defp crumbs(path) do
    parts = Path.split(Path.expand(path))
    paths = Enum.scan(parts, fn part, acc -> Path.join(acc, part) end)

    Enum.zip(parts, paths)
    |> Enum.map(fn {label, p} -> %{label: label, path: p} end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket}>
      <section id="workspace" class="flex min-h-0 flex-1 flex-col space-y-4">
        <div class="flex flex-wrap items-end justify-between gap-3 border-b-2 border-base-content/20 pb-4">
          <.page_wordmark src={~p"/images/brand/workspace-icon.png"} alt="Workspace" />
          <p class="font-mono text-xs text-base-content/55">
            Active workspace: {@workspace_root}
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            phx-click="up"
            disabled={@at_root?}
            title="Up one level"
            class="flex items-center gap-1 rounded-sm border-2 border-base-content/25 px-2 py-1 font-mono text-xs uppercase tracking-wide transition hover:border-primary hover:text-primary disabled:opacity-40"
          >
            <.icon name="hero-arrow-up" class="size-3" /> Up
          </button>
          <button
            type="button"
            phx-click="go_home"
            title="Home"
            class="rounded-sm border-2 border-base-content/25 px-2 py-1 font-mono text-xs uppercase tracking-wide transition hover:border-primary hover:text-primary"
          >
            Home
          </button>

          <nav class="flex min-w-0 flex-wrap items-center gap-1 font-mono text-xs" aria-label="Path">
            <span :for={{crumb, i} <- Enum.with_index(@crumbs)} class="flex items-center gap-1">
              <span :if={i > 0} class="text-base-content/40">/</span>
              <button
                type="button"
                phx-click="nav"
                phx-value-path={crumb.path}
                class="rounded px-1 hover:bg-base-200 hover:text-primary"
              >
                {crumb.label}
              </button>
            </span>
          </nav>

          <div class="ml-auto flex shrink-0 gap-2">
            <button
              :if={not @at_workspace?}
              type="button"
              phx-click="go_workspace"
              class="rounded border-2 border-base-content/30 px-3 py-2 text-sm font-semibold transition hover:bg-base-200"
            >
              Go to workspace
            </button>
            <button
              :if={not @at_workspace?}
              type="button"
              phx-click="set_workspace"
              class="rounded bg-primary px-3 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
            >
              Set as workspace
            </button>
          </div>
        </div>

        <p
          :if={@note}
          class="rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-sm"
        >
          {@note}
        </p>

        <div
          id="workspace-dropzone"
          phx-hook="WorkspaceDropzone"
          phx-drop-target={@uploads.import.ref}
          class="relative flex min-h-0 flex-1 gap-4"
        >
          <%!-- Drop overlay: the WorkspaceDropzone hook adds bc-dropzone-active to
                the container while OS files are dragged over; CSS reveals this.
                Files land in the folder currently in view. --%>
          <div class="bc-drop-overlay pointer-events-none absolute inset-0 z-20 place-items-center rounded-lg border-2 border-dashed border-primary bg-base-100/85">
            <div class="text-center">
              <.icon name="hero-arrow-down-tray" class="mx-auto size-8 text-primary" />
              <p class="mt-2 text-sm font-semibold">Drop to add to this folder</p>
              <p class="font-mono text-xs text-base-content/60">{@tree_root}</p>
            </div>
          </div>
          <.live_file_input upload={@uploads.import} class="sr-only" />
          <p
            :for={err <- upload_errors(@uploads.import)}
            class="absolute left-3 top-3 z-20 rounded-sm border-2 border-warning/40 bg-warning/10 px-2 py-1 text-xs text-warning"
          >
            {upload_error_to_string(err)}
          </p>

          <div class="flex min-h-0 shrink-0">
            <section class={[
              "ic-panel min-h-0 w-[20rem] overflow-hidden p-3",
              not @sidebar_open && "hidden"
            ]}>
              <.live_component
                module={BusterClawWeb.FileTree}
                id="workspace-tree"
                root={@tree_root}
                base={@tree_base}
                mode={:manage}
                version={@tree_version}
              />
            </section>

            <button
              type="button"
              phx-click="toggle_sidebar"
              title={if @sidebar_open, do: "Collapse file tree", else: "Expand file tree"}
              aria-label={if @sidebar_open, do: "Collapse file tree", else: "Expand file tree"}
              aria-expanded={@sidebar_open}
              class="group flex w-2.5 shrink-0 items-center justify-center border-y-2 border-r-2 border-base-content/15 bg-primary/15 transition hover:bg-primary/30"
            >
              <.icon
                name={if @sidebar_open, do: "hero-chevron-left", else: "hero-chevron-right"}
                class="size-3 text-primary"
              />
            </button>
          </div>

          <section class="ic-panel flex min-h-0 flex-1 flex-col overflow-hidden">
            <.preview preview={@preview} />
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :preview, :any, required: true

  defp preview(assigns) do
    ~H"""
    <div
      :if={is_nil(@preview)}
      class="grid h-full place-items-center p-8 text-center text-sm text-base-content/50"
    >
      Select a file to preview it.
    </div>

    <div :if={@preview} class="flex min-h-0 flex-1 flex-col">
      <div class="border-b-2 border-base-content/15 px-4 py-3">
        <p class="ic-eyebrow">Preview</p>
        <p class="mt-1 break-all font-mono text-xs text-base-content/70">{@preview.path}</p>
      </div>
      <div class={[
        "min-h-0 flex-1 overflow-auto p-6",
        @preview.kind == :image && "grid place-items-center bg-base-200/40"
      ]}>
        <div :if={@preview.kind == :markdown} class="md-prose">{raw(@preview.html)}</div>
        <pre
          :if={@preview.kind == :text}
          class="whitespace-pre-wrap break-words font-mono text-xs leading-6"
        >{@preview.content}</pre>
        <img
          :if={@preview.kind == :image}
          src={@preview.url}
          alt={Path.basename(@preview.path)}
          class="max-h-full max-w-full object-contain"
        />
        <p :if={@preview.kind == :error} class="font-mono text-xs text-warning">{@preview.message}</p>
      </div>
    </div>
    """
  end

  # --- internals ----------------------------------------------------------

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  defp upload_error_to_string(:too_large), do: "That file is larger than 200 MB."
  defp upload_error_to_string(:too_many_files), do: "Too many files at once (max 25)."
  defp upload_error_to_string(:not_accepted), do: "That file type isn't accepted."
  defp upload_error_to_string(_), do: "That file couldn't be added."

  @markdown_exts ~w(.md .markdown)

  defp preview_for(path, base) do
    if FileManager.image?(path) do
      image_preview(path, base)
    else
      text_preview(path, base)
    end
  end

  # Images are served as bytes (never read as text — that's what wrongly hit the
  # "too large" / "binary" paths). The `?v=` mtime stamp busts the webview cache
  # when a file is replaced under the same path.
  defp image_preview(path, base) do
    case FileManager.servable_file(path, base) do
      {:ok, abs} ->
        v =
          case File.stat(abs, time: :posix) do
            {:ok, %{mtime: mtime}} -> mtime
            _ -> 0
          end

        %{path: path, kind: :image, url: ~p"/ws/image?#{[path: path, v: v]}"}

      {:error, _reason} ->
        %{path: path, kind: :error, message: "Couldn't read image."}
    end
  end

  defp text_preview(path, base) do
    case FileManager.read_file(path, base) do
      {:ok, content} ->
        if String.downcase(Path.extname(path)) in @markdown_exts do
          %{path: path, kind: :markdown, html: BusterClaw.Markdown.to_html(content)}
        else
          %{path: path, kind: :text, content: content}
        end

      {:error, :too_large} ->
        %{path: path, kind: :error, message: "File is too large to preview."}

      {:error, :binary} ->
        %{path: path, kind: :error, message: "Binary file — no text preview."}

      {:error, reason} ->
        %{path: path, kind: :error, message: "Couldn't read file: #{inspect(reason)}"}
    end
  end

  # Persist the new workspace root to the Tauri-read boot file, apply it live to
  # the running session, scaffold the layout, and mark setup complete.
  defp set_workspace_root(path) do
    path = Path.expand(path)

    with :ok <- File.mkdir_p(path),
         :ok <- write_boot_file(path) do
      Application.put_env(:buster_claw, :workspace_root, path)
      Application.put_env(:buster_claw, :library_root, Path.join(path, "library"))
      Artifact.ensure_workspace_dirs()
      BusterClaw.Introduction.ensure()
      BusterClaw.Pages.ensure()
      BusterClaw.WorkspaceCLI.ensure()
      Setup.confirm_workspace()
      :ok
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp write_boot_file(path) do
    file = boot_file()

    with :ok <- File.mkdir_p(Path.dirname(file)) do
      File.write(file, path)
    end
  end

  # Mirrors the Tauri shell's data dir (dirs::data_dir()/BusterClaw) so main.rs
  # reads the same `workspace_root` file at next launch.
  defp boot_file do
    base =
      case :os.type() do
        {:unix, :darwin} ->
          Path.expand("~/Library/Application Support/BusterClaw")

        {:unix, _} ->
          Path.join(
            System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"),
            "BusterClaw"
          )

        _ ->
          Path.expand("~/.buster_claw")
      end

    Path.join(base, "workspace_root")
  end
end
