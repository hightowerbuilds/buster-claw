defmodule BusterClawWeb.FileTree do
  @moduledoc """
  Reusable IDE-style file tree (LiveComponent). Lazily lists directories via
  `BusterClaw.FileManager`, expands/collapses folders, selects files for preview,
  and — in `:manage` mode — supports new/rename/move/delete. In `:select` mode it
  offers "Use as workspace" on folders (for relocating the workspace root).

  Parent-process messages:
    * `{:file_selected, path}`     — a file row was clicked
    * `{:set_workspace, path}`     — "Use as workspace" clicked (`:select` mode)

  Assigns: `id`, `root` (start dir), `base` (allowed root for ops), `mode`.
  """
  use BusterClawWeb, :live_component

  alias BusterClaw.FileManager

  @impl true
  def update(assigns, socket) do
    root = Path.expand(assigns.root)
    root_changed? = Map.get(socket.assigns, :root) != assigns.root

    socket =
      socket
      |> assign(assigns)
      |> assign(:root_abs, root)

    socket =
      if root_changed? do
        assign(socket,
          expanded: MapSet.new([root]),
          children: %{},
          selected: nil,
          action: nil,
          fm_error: nil
        )
      else
        socket
        |> assign_new(:expanded, fn -> MapSet.new([root]) end)
        |> assign_new(:children, fn -> %{} end)
        |> assign_new(:selected, fn -> nil end)
        |> assign_new(:action, fn -> nil end)
        |> assign_new(:fm_error, fn -> nil end)
      end

    {:ok, ensure_loaded(socket, root)}
  end

  @impl true
  def handle_event("toggle", %{"path" => path}, socket) do
    expanded = socket.assigns.expanded

    socket =
      if MapSet.member?(expanded, path) do
        assign(socket, :expanded, MapSet.delete(expanded, path))
      else
        socket
        |> assign(:expanded, MapSet.put(expanded, path))
        |> ensure_loaded(path)
      end

    {:noreply, socket}
  end

  def handle_event("select", %{"path" => path}, socket) do
    send(self(), {:file_selected, path})
    {:noreply, assign(socket, :selected, path)}
  end

  def handle_event("use_workspace", %{"path" => path}, socket) do
    send(self(), {:set_workspace, path})
    {:noreply, socket}
  end

  def handle_event("start_create", %{"parent" => parent, "kind" => kind}, socket) do
    kind = if kind == "dir", do: :dir, else: :file

    socket =
      socket
      |> assign(:action, {:create, parent, kind})
      |> assign(:fm_error, nil)
      |> then(fn s -> if parent == s.assigns.root_abs, do: s, else: open(s, parent) end)

    {:noreply, socket}
  end

  def handle_event("submit_create", %{"name" => name}, socket) do
    case socket.assigns.action do
      {:create, parent, :dir} ->
        apply_op(socket, FileManager.create_dir(parent, name, base(socket)), parent)

      {:create, parent, :file} ->
        apply_op(socket, FileManager.create_file(parent, name, base(socket)), parent)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("start_rename", %{"path" => path}, socket) do
    {:noreply, assign(socket, action: {:rename, path}, fm_error: nil)}
  end

  def handle_event("submit_rename", %{"name" => name}, socket) do
    case socket.assigns.action do
      {:rename, path} ->
        apply_op(socket, FileManager.rename(path, name, base(socket)), Path.dirname(path))

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("start_move", %{"path" => path}, socket) do
    {:noreply, assign(socket, action: {:move, path}, fm_error: nil)}
  end

  def handle_event("submit_move", %{"dest" => dest}, socket) do
    case socket.assigns.action do
      {:move, path} ->
        socket = reload(socket, Path.dirname(path))
        apply_op(socket, FileManager.move(path, dest, base(socket)), dest)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("start_delete", %{"path" => path}, socket) do
    {:noreply, assign(socket, action: {:delete, path}, fm_error: nil)}
  end

  def handle_event("delete", %{"path" => path}, socket) do
    parent = Path.dirname(path)

    case FileManager.delete(path, base(socket)) do
      :ok ->
        selected = if socket.assigns.selected == path, do: nil, else: socket.assigns.selected

        {:noreply,
         socket |> assign(selected: selected, action: nil, fm_error: nil) |> reload(parent)}

      {:error, reason} ->
        {:noreply,
         assign(socket, action: nil, fm_error: "Delete failed: #{humanize_error(reason)}")}
    end
  end

  def handle_event("cancel_action", _params, socket) do
    {:noreply, assign(socket, :action, nil)}
  end

  # --- render -------------------------------------------------------------

  @impl true
  def render(assigns) do
    creating_root? =
      case assigns.action do
        {:create, parent, _kind} -> parent == assigns.root_abs
        _ -> false
      end

    assigns =
      assigns
      |> assign(:creating_root?, creating_root?)
      |> assign(:tree, %{
        expanded: assigns.expanded,
        children: assigns.children,
        selected: assigns.selected,
        action: assigns.action,
        mode: assigns.mode,
        target: assigns.myself
      })

    ~H"""
    <div class="flex h-full min-h-0 flex-col">
      <div
        :if={@mode == :manage}
        class="flex flex-wrap items-center gap-2 border-b-2 border-base-content/15 pb-2"
      >
        <button
          type="button"
          phx-click="start_create"
          phx-value-parent={@root_abs}
          phx-value-kind="dir"
          phx-target={@myself}
          class="rounded-sm border-2 border-base-content/25 px-2 py-1 font-mono text-xs uppercase tracking-wide hover:border-primary hover:text-primary"
        >
          + Folder
        </button>
        <button
          type="button"
          phx-click="start_create"
          phx-value-parent={@root_abs}
          phx-value-kind="file"
          phx-target={@myself}
          class="rounded-sm border-2 border-base-content/25 px-2 py-1 font-mono text-xs uppercase tracking-wide hover:border-primary hover:text-primary"
        >
          + File
        </button>
      </div>

      <p
        :if={@fm_error}
        class="mt-2 rounded-sm border-2 border-warning/40 bg-warning/10 px-3 py-2 font-mono text-xs text-warning"
      >
        {@fm_error}
      </p>

      <div
        :if={match?({:move, _}, @action)}
        class="mt-2 flex items-center justify-between gap-2 rounded-sm border-2 border-primary/40 bg-primary/10 px-3 py-2 text-xs"
      >
        <span class="font-mono">
          Moving <b>{Path.basename(elem(@action, 1))}</b> — pick a destination folder.
        </span>
        <button type="button" phx-click="cancel_action" phx-target={@myself} class="underline">
          cancel
        </button>
      </div>

      <div :if={@creating_root?} class="mt-2">
        <.create_form action={@action} target={@myself} />
      </div>

      <div class="mt-2 min-h-0 flex-1 overflow-auto">
        <.nodes entries={Map.get(@children, @root_abs, [])} depth={0} tree={@tree} />
      </div>
    </div>
    """
  end

  # Recursive tree renderer.
  attr :entries, :list, required: true
  attr :depth, :integer, required: true
  attr :tree, :map, required: true

  defp nodes(assigns) do
    ~H"""
    <ul class="font-mono text-sm">
      <li :for={e <- @entries}>
        <div
          class={[
            "group flex items-center gap-1 rounded-sm px-1 py-0.5 hover:bg-base-200",
            @tree.selected == e.path && "bg-base-200"
          ]}
          style={"padding-left: #{@depth * 0.85 + 0.25}rem"}
        >
          <button
            :if={e.type == :dir}
            type="button"
            phx-click="toggle"
            phx-value-path={e.path}
            phx-target={@tree.target}
            class="grid size-4 shrink-0 place-items-center text-base-content/60"
          >
            <.icon
              name={
                if MapSet.member?(@tree.expanded, e.path),
                  do: "hero-chevron-down",
                  else: "hero-chevron-right"
              }
              class="size-3"
            />
          </button>
          <span :if={e.type == :file} class="size-4 shrink-0"></span>

          <button
            type="button"
            phx-click={if e.type == :dir, do: "toggle", else: "select"}
            phx-value-path={e.path}
            phx-target={@tree.target}
            class="flex min-w-0 flex-1 items-center gap-2 text-left"
          >
            <.icon
              name={if e.type == :dir, do: "hero-folder", else: "hero-document"}
              class={[
                "size-4 shrink-0",
                if(e.type == :dir, do: "text-primary", else: "text-base-content/60")
              ]}
            />
            <span class="truncate">{e.name}</span>
          </button>

          <div :if={@tree.mode == :select and e.type == :dir} class="shrink-0">
            <button
              type="button"
              phx-click="use_workspace"
              phx-value-path={e.path}
              phx-target={@tree.target}
              class="rounded-sm border-2 border-base-content/25 px-2 py-0.5 text-[0.65rem] uppercase opacity-0 transition group-hover:opacity-100 hover:border-primary hover:text-primary"
            >
              Use here
            </button>
          </div>

          <div
            :if={@tree.mode == :manage}
            class="flex shrink-0 items-center gap-1 opacity-0 transition group-hover:opacity-100"
          >
            <button
              :if={match?({:move, _}, @tree.action) and e.type == :dir}
              type="button"
              phx-click="submit_move"
              phx-value-dest={e.path}
              phx-target={@tree.target}
              class="rounded-sm border-2 border-primary/50 px-2 py-0.5 text-[0.65rem] uppercase text-primary"
            >
              Move here
            </button>
            <button
              :if={e.type == :dir}
              type="button"
              phx-click="start_create"
              phx-value-parent={e.path}
              phx-value-kind="dir"
              phx-target={@tree.target}
              title="New folder inside"
              class="text-base-content/50 hover:text-primary"
            >
              <.icon name="hero-folder-plus" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="start_rename"
              phx-value-path={e.path}
              phx-target={@tree.target}
              title="Rename"
              class="text-base-content/50 hover:text-primary"
            >
              <.icon name="hero-pencil-square" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="start_move"
              phx-value-path={e.path}
              phx-target={@tree.target}
              title="Move"
              class="text-base-content/50 hover:text-primary"
            >
              <.icon name="hero-arrows-right-left" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="start_delete"
              phx-value-path={e.path}
              phx-target={@tree.target}
              title="Delete"
              class="text-base-content/50 hover:text-error"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </div>
        </div>

        <div
          :if={@tree.action == {:rename, e.path}}
          style={"padding-left: #{(@depth + 1) * 0.85 + 0.25}rem"}
          class="py-1"
        >
          <.rename_form name={e.name} target={@tree.target} />
        </div>

        <div
          :if={@tree.action == {:delete, e.path}}
          style={"padding-left: #{(@depth + 1) * 0.85 + 0.25}rem"}
          class="py-1"
        >
          <.delete_confirm name={e.name} path={e.path} type={e.type} target={@tree.target} />
        </div>

        <%= if e.type == :dir and MapSet.member?(@tree.expanded, e.path) do %>
          <div
            :if={creating_in?(@tree.action, e.path)}
            style={"padding-left: #{(@depth + 1) * 0.85 + 0.25}rem"}
            class="py-1"
          >
            <.create_form action={@tree.action} target={@tree.target} />
          </div>
          <.nodes entries={Map.get(@tree.children, e.path, [])} depth={@depth + 1} tree={@tree} />
        <% end %>
      </li>
    </ul>
    """
  end

  attr :action, :any, required: true
  attr :target, :any, required: true

  defp create_form(assigns) do
    {:create, _parent, kind} = assigns.action
    assigns = assign(assigns, :kind, kind)

    ~H"""
    <form phx-submit="submit_create" phx-target={@target} class="flex items-center gap-2">
      <input
        type="text"
        name="name"
        autocomplete="off"
        placeholder={if @kind == :dir, do: "new-folder", else: "new-file.md"}
        class="input input-sm w-48 font-mono"
        phx-mounted={JS.focus()}
      />
      <button
        type="submit"
        class="rounded-sm border-2 border-primary/50 px-2 py-1 text-xs text-primary"
      >
        Create {@kind}
      </button>
      <button type="button" phx-click="cancel_action" phx-target={@target} class="text-xs underline">
        cancel
      </button>
    </form>
    """
  end

  attr :name, :string, required: true
  attr :target, :any, required: true

  defp rename_form(assigns) do
    ~H"""
    <form phx-submit="submit_rename" phx-target={@target} class="flex items-center gap-2">
      <input
        type="text"
        name="name"
        value={@name}
        autocomplete="off"
        class="input input-sm w-48 font-mono"
        phx-mounted={JS.focus()}
      />
      <button
        type="submit"
        class="rounded-sm border-2 border-primary/50 px-2 py-1 text-xs text-primary"
      >
        Rename
      </button>
      <button type="button" phx-click="cancel_action" phx-target={@target} class="text-xs underline">
        cancel
      </button>
    </form>
    """
  end

  attr :name, :string, required: true
  attr :path, :string, required: true
  attr :type, :atom, required: true
  attr :target, :any, required: true

  defp delete_confirm(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 rounded-sm border-2 border-error/40 bg-error/10 px-3 py-2 text-xs">
      <span class="font-mono">
        Delete <b>{@name}</b>{if @type == :dir, do: " and everything inside", else: ""}? This can't be undone.
      </span>
      <button
        type="button"
        phx-click="delete"
        phx-value-path={@path}
        phx-target={@target}
        class="rounded-sm border-2 border-error/60 px-2 py-0.5 font-mono uppercase text-error transition hover:bg-error hover:text-error-content"
      >
        Delete
      </button>
      <button type="button" phx-click="cancel_action" phx-target={@target} class="underline">
        cancel
      </button>
    </div>
    """
  end

  # --- internals ----------------------------------------------------------

  defp creating_in?({:create, parent, _kind}, path), do: parent == path
  defp creating_in?(_action, _path), do: false

  defp base(socket), do: socket.assigns.base

  defp open(socket, dir) do
    socket
    |> assign(:expanded, MapSet.put(socket.assigns.expanded, dir))
    |> ensure_loaded(dir)
  end

  defp ensure_loaded(socket, dir) do
    if Map.has_key?(socket.assigns.children, dir), do: socket, else: reload(socket, dir)
  end

  defp reload(socket, dir) do
    case FileManager.list(dir, socket.assigns.base) do
      {:ok, entries} ->
        assign(socket, :children, Map.put(socket.assigns.children, dir, entries))

      {:error, reason} ->
        assign(socket, :fm_error, "Couldn't open folder: #{inspect(reason)}")
    end
  end

  defp apply_op(socket, result, reload_dir) do
    case result do
      {:ok, _path} ->
        {:noreply, socket |> assign(action: nil, fm_error: nil) |> reload(reload_dir)}

      {:error, reason} ->
        {:noreply, assign(socket, :fm_error, "#{humanize_error(reason)}")}
    end
  end

  defp humanize_error(:already_exists), do: "That name already exists."
  defp humanize_error(:invalid_name), do: "Invalid name (no slashes or “..”)."
  defp humanize_error(:outside_base), do: "That location is outside the allowed folder."
  defp humanize_error(:not_a_directory), do: "Destination is not a folder."
  defp humanize_error(:cannot_delete_base), do: "Can't delete the workspace root from inside it."
  defp humanize_error(:eacces), do: "Permission denied."
  defp humanize_error(reason), do: "Operation failed: #{inspect(reason)}"
end
