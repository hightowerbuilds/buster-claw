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
     |> assign(:note, nil)}
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
         |> assign(:note, "Workspace is now #{path}.")}

      {:error, message} ->
        {:noreply, assign(socket, :note, "Couldn't set workspace: #{message}")}
    end
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
  end

  defp crumbs(path) do
    parts = Path.split(Path.expand(path))
    paths = Enum.scan(parts, fn part, acc -> Path.join(acc, part) end)

    Enum.zip(parts, paths)
    |> Enum.map(fn {label, p} -> %{label: label, path: p} end)
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:crumbs, crumbs(assigns.tree_root))
      |> assign(
        :at_workspace?,
        Path.expand(assigns.tree_root) == Path.expand(assigns.workspace_root)
      )
      |> assign(:at_root?, Path.dirname(assigns.tree_root) == assigns.tree_root)

    ~H"""
    <Layouts.app flash={@flash}>
      <section id="workspace" class="flex flex-1 flex-col space-y-4">
        <div class="flex flex-wrap items-end justify-between gap-3 border-b-2 border-base-content/20 pb-4">
          <div>
            <p class="ic-eyebrow">Files</p>
            <h1 class="font-display text-3xl font-black uppercase tracking-tight">Workspace</h1>
          </div>
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

        <div class="flex min-h-0 flex-1 gap-4">
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
              />
            </section>

            <button
              type="button"
              phx-click="toggle_sidebar"
              title={if @sidebar_open, do: "Collapse file tree", else: "Expand file tree"}
              aria-label={if @sidebar_open, do: "Collapse file tree", else: "Expand file tree"}
              aria-expanded={@sidebar_open}
              class="group flex w-5 shrink-0 items-center justify-center border-y-2 border-r-2 border-base-content/15 bg-primary/15 transition hover:bg-primary/30"
            >
              <.icon
                name={if @sidebar_open, do: "hero-chevron-left", else: "hero-chevron-right"}
                class="size-4 text-primary"
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
      <div class="min-h-0 flex-1 overflow-auto p-6">
        <div :if={@preview.kind == :markdown} class="md-prose">{raw(@preview.html)}</div>
        <pre
          :if={@preview.kind == :text}
          class="whitespace-pre-wrap break-words font-mono text-xs leading-6"
        >{@preview.content}</pre>
        <p :if={@preview.kind == :error} class="font-mono text-xs text-warning">{@preview.message}</p>
      </div>
    </div>
    """
  end

  # --- internals ----------------------------------------------------------

  @markdown_exts ~w(.md .markdown)

  defp preview_for(path, base) do
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
