defmodule BusterClawWeb.PocketsPanel do
  @moduledoc """
  The home Pockets tab: the operator's own material, read-only.

  Scoped by `daily-growth/archive/08-09-26-pockets-roadmap.md` D9, which states the
  minimalism as a **constraint** rather than a mood: *two levels, one screen.*
  A list of Pockets, and one Pocket open. Nothing else — no tree, no sidebar,
  no reordering, no drag handles, no inspector panel, no preview modal.

  Three write affordances and no others, exactly as D9 names them: **New**,
  **Mount…**, and the `↗` glyph marking a mounted Pocket — plus the brand slots'
  upload, which Part XI added. There is deliberately **no Delete**: a Pocket is a
  folder, and removing an operator's folder is what Finder is for.

  Their markup lives in `BusterClawWeb.Pockets.PocketControls` and
  `BusterClawWeb.Pockets.BrandSlots`; only the state and the events are here.

  ## Why this is a live_component and `ExplorePanel` is not

  Explore keeps its sub-tab in the parent LiveView because a half-read tutorial
  must survive a glance at Chat. Which Pocket is open is not that: the list is
  the resting state, and coming back to it after a tab switch is the right
  answer rather than a lost one. So the selection lives here, where the feature
  lives, and `StatusLive` gains a tab entry and one render call — no more.

  ## Invalid is drawn, never dropped

  `Pockets.list_with_errors/0` exists for this screen. A malformed Pocket is
  rendered **as invalid, in place**, because a silently skipped one is
  indistinguishable from a missing one and the operator has no way to tell which
  folder they are looking at. That is the failure mode `Skills` already
  demonstrated, and it is a design requirement here rather than a nicety.

  ## Bytes reach the page one way

  Every image in this panel is an `asset_url/2` — a `/pockets/:name/:file` URL
  fenced by `Pockets.resolve/2`. This module never builds a path and never reads
  a file itself, so there is one fence to audit rather than two.
  """

  use BusterClawWeb, :live_component

  alias BusterClaw.Markdown
  alias BusterClaw.Pockets
  alias BusterClaw.Pockets.Brand
  alias BusterClaw.Pockets.Operator

  # How many thumbnails the list row shows. A strip, not a gallery — the row is
  # a glance and the open Pocket is where every file is listed.
  @strip_limit 6

  # What gets a thumbnail. Keyed off the file, not the Pocket's `kind`: a
  # `:free` Pocket full of PNGs should still look like one, and an `:icons`
  # Pocket holding a stray `.txt` should not render a broken image for it.
  @image_exts ~w(.png .jpg .jpeg .gif .webp .svg)

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open, nil)
     |> assign(:loaded, false)
     |> assign(:upload_role, nil)
     |> assign(:upload_error, nil)
     |> assign(:panel_open, nil)
     |> assign(:mount_open, nil)
     |> assign(:write_error, nil)
     # One upload for six slots, with `upload_role` naming the target. Six
     # `allow_upload` calls would be six live sockets kept open for a thing the
     # operator does once.
     #
     # `auto_upload: true` because the operator's spec was that choosing art
     # "makes the adjustment live". A submit button made picking a file do
     # nothing visible until a second click, which is exactly how this read as
     # broken. Now the change event carries the finished upload and there is no
     # second step.
     |> allow_upload(:brand,
       accept: Brand.accepted_extensions(),
       max_entries: 1,
       max_file_size: 8_000_000,
       auto_upload: true,
       # The `progress` callback, NOT the change event, is where a finished
       # upload is consumed. `auto_upload` fires `phx-change` on *selection*,
       # while the entry is still uploading, so consuming there returns `[]` and
       # the file silently goes nowhere — which is exactly the bug this fixes.
       progress: &handle_progress/3
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns.loaded do
      {:ok, socket}
    else
      {:ok, socket |> assign(:loaded, true) |> reload()}
    end
  end

  @impl true
  def handle_event("open_pocket", %{"name" => name}, socket) do
    {:noreply, assign(socket, :open, name)}
  end

  def handle_event("close_pocket", _params, socket) do
    {:noreply, assign(socket, :open, nil)}
  end

  def handle_event("pick_brand", %{"role" => role}, socket) do
    # Clicking the open slot again closes the picker, so the button is a toggle
    # rather than a one-way door.
    role = if socket.assigns.upload_role == role, do: nil, else: role
    {:noreply, socket |> assign(:upload_role, role) |> assign(:upload_error, nil)}
  end

  # Selection only. The upload is consumed in `handle_progress/3` once the entry
  # is actually done; doing it here would consume nothing (see the `progress:`
  # note above). Re-rendering is the point — it is what draws the entry's errors.
  def handle_event("validate_brand", _params, socket), do: {:noreply, socket}

  # Kept so a stray submit (Enter in the file field) is harmless rather than a
  # crash on an unhandled event.
  def handle_event("upload_brand", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_new", _params, socket) do
    open = if socket.assigns.panel_open == "new", do: nil, else: "new"
    {:noreply, socket |> assign(:panel_open, open) |> assign(:write_error, nil)}
  end

  def handle_event("create_pocket", %{"name" => name}, socket) do
    case Pockets.ensure_pocket(String.trim(name), %{
           kind: :free,
           description: "",
           body: "Say what this Pocket is for. The app reads this line back to you."
         }) do
      :ok ->
        {:noreply, socket |> assign(:panel_open, nil) |> assign(:write_error, nil) |> reload()}

      {:error, reason} ->
        {:noreply, assign(socket, :write_error, write_error_text(reason))}
    end
  end

  def handle_event("toggle_mount", %{"name" => name}, socket) do
    open = if socket.assigns.mount_open == name, do: nil, else: name
    {:noreply, socket |> assign(:mount_open, open) |> assign(:write_error, nil)}
  end

  def handle_event("mount_pocket", %{"name" => name, "path" => path} = params, socket) do
    # `Operator`, never `Mounts` — the role and app-owned refusals live there, and
    # going straight to the registry would skip both.
    case Operator.mount(name, String.trim(path), writable: params["writable"] == "true") do
      {:ok, _mount} ->
        {:noreply, socket |> assign(:mount_open, nil) |> assign(:write_error, nil) |> reload()}

      {:error, reason} ->
        {:noreply, assign(socket, :write_error, write_error_text(reason))}
    end
  end

  def handle_event("unmount_pocket", %{"name" => name}, socket) do
    Operator.unmount(name)
    {:noreply, socket |> assign(:write_error, nil) |> reload()}
  end

  def handle_event("clear_brand", %{"role" => role}, socket) do
    Brand.clear(role)
    {:noreply, reload(socket)}
  end

  # Called by LiveView as the upload advances. Only the finished entry is
  # consumed; anything earlier is just a re-render for the progress bar.
  #
  # The result of `Brand.put/3` is KEPT rather than discarded — an upload the
  # server refuses (unsupported type, unknown role) has to say so, and wrapping
  # it in the `{:ok, _}` the consumer wants is how that return value gets thrown
  # away without anyone noticing.
  defp handle_progress(:brand, entry, socket) do
    if entry.done? do
      role = socket.assigns.upload_role

      results =
        consume_uploaded_entries(socket, :brand, fn %{path: path}, e ->
          {:ok, Brand.put(role, path, e.client_name)}
        end)

      failed = Enum.find(results, &match?({:error, _}, &1))

      {:noreply,
       socket
       |> assign(:upload_error, failed && brand_error_text(elem(failed, 1)))
       # The picker closes on success and stays open on failure, so the error is
       # read next to the control that produced it.
       |> assign(:upload_role, failed && role)
       |> reload()}
    else
      {:noreply, socket}
    end
  end

  # Every refusal a write can produce, in the operator's words. A reason rendered
  # as `inspect/1` is a reason nobody acts on.
  defp write_error_text(:invalid_name),
    do: "the name must be lowercase letters, digits or hyphens"

  defp write_error_text(:not_absolute), do: "give the full path, starting with /"
  defp write_error_text(:not_found), do: "there is no folder at that path"
  defp write_error_text(:not_a_directory), do: "that path is a file, not a folder"
  defp write_error_text(:invalid_path), do: "that is not a path this can use"

  defp write_error_text(:too_broad),
    do: "too broad — pick a folder inside your home, not the whole of it"

  defp write_error_text(:app_owned),
    do: "the app writes into this Pocket, so it has to stay in the workspace"

  defp write_error_text(:role_bound),
    do: "a surface is using this Pocket, so it cannot move outside the workspace"

  defp write_error_text(other), do: "could not do that: #{inspect(other)}"

  defp brand_error_text(:unsupported_type), do: "that file type is not an image we can show"
  defp brand_error_text(:unknown_role), do: "that slot no longer exists"
  defp brand_error_text(other), do: "upload failed: #{inspect(other)}"

  # `pockets/` is an `:on_demand` entry in the workspace registry — created when
  # the operator opens the surface that owns it, which is this one, and never at
  # install.
  defp reload(socket) do
    Pockets.ensure()

    rows =
      Enum.map(Pockets.list_with_errors(), fn
        {:ok, pocket} -> row(pocket)
        {:error, name, reason} -> %{name: name, pocket: nil, error: reason, files: [], thumbs: []}
      end)

    socket |> assign(:rows, rows) |> assign(:brand, Brand.overview())
  end

  defp row(pocket) do
    files = Pockets.contents(pocket)
    %{name: pocket.name, pocket: pocket, error: nil, files: files, thumbs: thumbs(pocket, files)}
  end

  defp thumbs(pocket, files) do
    files
    |> Enum.filter(&image?(&1.name))
    |> Enum.take(@strip_limit)
    |> Enum.flat_map(fn file ->
      case Pockets.asset_url(pocket, file.name) do
        nil -> []
        url -> [%{name: file.name, url: url}]
      end
    end)
  end

  defp image?(name), do: name |> Path.extname() |> String.downcase() |> then(&(&1 in @image_exts))

  defp open_row(_rows, nil), do: nil
  defp open_row(rows, name), do: Enum.find(rows, &(&1.name == name and &1.pocket))

  defp file_count([]), do: "empty"
  defp file_count([_one]), do: "1 file"
  defp file_count(files), do: "#{length(files)} files"

  defp size_label(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp size_label(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp size_label(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  # Said in the operator's terms, not the atom's. Each one names the folder's
  # problem and the edit that fixes it, because this text is the only thing
  # standing between a broken Pocket and a folder that looks missing.
  defp reason_text(:no_manifest), do: "no POCKET.md — add one to make this a Pocket"
  defp reason_text(:name_mismatch), do: "the manifest's name does not match the folder"
  defp reason_text(:invalid_name), do: "the folder name must be lowercase letters, digits or -"
  defp reason_text({:unknown_kind, kind}), do: "unknown kind #{inspect(kind)}"
  defp reason_text(:invalid_roles), do: ~s(roles must be a JSON list, e.g. ["background"])
  defp reason_text(other), do: inspect(other)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :open_row, open_row(assigns.rows, assigns.open))

    ~H"""
    <section
      id={@id}
      class="ic-panel ic-scanlines flex min-h-0 flex-1 flex-col overflow-hidden"
    >
      <header class="flex shrink-0 flex-wrap items-baseline justify-between gap-2 border-b-2 border-base-content/20 px-4 py-3">
        <h2 class="font-display text-base font-black uppercase tracking-tight">Pockets</h2>
        <p class="font-mono text-[10px] uppercase tracking-wide text-base-content/45">
          Folders that know what they are for
        </p>
      </header>

      <div class="min-h-0 flex-1 overflow-y-auto">
        <BusterClawWeb.Pockets.BrandSlots.brand_slots
          :if={is_nil(@open_row)}
          slots={@brand}
          uploads={@uploads}
          upload_role={@upload_role}
          upload_error={@upload_error}
          target={@myself}
        />
        <BusterClawWeb.Pockets.PocketControls.new_pocket
          :if={is_nil(@open_row)}
          target={@myself}
          open={@panel_open}
          error={@write_error}
        />
        <.pocket_list :if={is_nil(@open_row)} rows={@rows} target={@myself} />
        <.pocket_open :if={@open_row} row={@open_row} target={@myself} />
        <BusterClawWeb.Pockets.PocketControls.mount_controls
          :if={@open_row}
          row={@open_row}
          target={@myself}
          open={@mount_open}
          error={@write_error}
        />
      </div>
    </section>
    """
  end

  # --- level one: the list ---------------------------------------------------

  attr :rows, :list, required: true
  attr :target, :any, required: true

  defp pocket_list(assigns) do
    ~H"""
    <div :if={@rows == []} id="pockets-empty" class="px-6 py-12 text-center">
      <.icon name="hero-folder-open" class="mx-auto size-7 text-base-content/25" />
      <p class="mt-3 font-display text-lg font-black uppercase tracking-tight">No Pockets yet</p>
      <p class="mx-auto mt-2 max-w-sm font-mono text-xs leading-relaxed text-base-content/50">
        A Pocket is a folder under <span class="text-base-content/70">pockets/</span>
        with a <span class="text-base-content/70">POCKET.md</span>
        in it saying what the folder is for. Make one by hand and it shows up here.
      </p>
    </div>

    <ul :if={@rows != []} id="pockets-list" class="divide-y-2 divide-base-content/10">
      <li :for={row <- @rows} id={"pocket-row-#{row.name}"}>
        <button
          :if={row.pocket}
          type="button"
          phx-click="open_pocket"
          phx-value-name={row.name}
          phx-target={@target}
          class="flex w-full items-center gap-3 px-4 py-3 text-left transition hover:bg-base-content/7"
        >
          <span class="w-44 shrink-0 truncate font-mono text-sm font-bold text-base-content">
            {row.name}
          </span>
          <span class="w-24 shrink-0 font-mono text-[10px] font-bold uppercase tracking-wide text-primary">
            {row.pocket.kind}
          </span>
          <span class="w-20 shrink-0 font-mono text-xs text-base-content/50">
            {file_count(row.files)}
          </span>
          <span class="flex min-w-0 flex-1 items-center gap-1 overflow-hidden">
            <img
              :for={thumb <- row.thumbs}
              src={thumb.url}
              alt={thumb.name}
              class="size-6 shrink-0 border border-base-content/15 object-cover"
            />
          </span>
        </button>

        <%!-- An invalid Pocket is SHOWN, greyed and unopenable, with the reason
              beside it. Leaving it out would make a broken folder look like one
              the operator never made. --%>
        <div
          :if={is_nil(row.pocket)}
          id={"pocket-invalid-#{row.name}"}
          class="flex w-full items-center gap-3 px-4 py-3"
        >
          <span class="w-44 shrink-0 truncate font-mono text-sm font-bold text-base-content/40">
            {row.name}
          </span>
          <span class="w-24 shrink-0 font-mono text-[10px] font-bold uppercase tracking-wide text-error">
            Invalid
          </span>
          <span class="min-w-0 flex-1 font-mono text-xs text-base-content/45">
            {reason_text(row.error)}
          </span>
        </div>
      </li>
    </ul>
    """
  end

  # --- level two: one Pocket open --------------------------------------------

  attr :row, :map, required: true
  attr :target, :any, required: true

  defp pocket_open(assigns) do
    ~H"""
    <div id="pocket-open" class="space-y-4 px-4 py-3">
      <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
        <button
          id="pocket-back"
          type="button"
          phx-click="close_pocket"
          phx-target={@target}
          class="font-mono text-xs font-bold uppercase tracking-wide text-primary transition hover:opacity-75"
        >
          ← All Pockets
        </button>
        <span class="font-mono text-sm font-bold text-base-content">{@row.name}</span>
        <BusterClawWeb.Pockets.PocketControls.mount_glyph pocket={@row.pocket} />
        <span class="font-mono text-[10px] uppercase tracking-wide text-base-content/45">
          {@row.pocket.kind} · {file_count(@row.files)}
        </span>
        <span
          :if={@row.pocket.roles != []}
          class="font-mono text-[10px] uppercase tracking-wide text-base-content/45"
        >
          · used by: {Enum.join(@row.pocket.roles, ", ")}
        </span>
      </div>

      <p :if={@row.pocket.description != ""} class="font-mono text-xs text-base-content/70">
        {@row.pocket.description}
      </p>

      <div :if={@row.thumbs != []} id="pocket-strip" class="flex flex-wrap gap-2">
        <img
          :for={thumb <- @row.thumbs}
          src={thumb.url}
          alt={thumb.name}
          class="size-16 border-2 border-base-content/15 object-cover"
        />
      </div>

      <ul id="pocket-contents" class="divide-y divide-base-content/10 border-y border-base-content/10">
        <li :if={@row.files == []} id="pocket-contents-empty" class="py-3">
          <p class="font-mono text-xs text-base-content/45">
            This Pocket holds no files yet.
          </p>
        </li>
        <li
          :for={file <- @row.files}
          class="flex items-baseline justify-between gap-3 py-1.5 font-mono text-xs"
        >
          <span class="min-w-0 truncate text-base-content/75">{file.name}</span>
          <span class="shrink-0 text-base-content/40">{size_label(file.bytes)}</span>
        </li>
      </ul>

      <%!-- The manifest body, as prose. The operator wrote it to be read, and
            it is the part a plain folder has never been able to carry. --%>
      <article
        :if={String.trim(@row.pocket.body) != ""}
        id="pocket-body"
        class="prose prose-sm max-w-none dark:prose-invert"
      >
        {raw(Markdown.to_html(@row.pocket.body))}
      </article>
    </div>
    """
  end
end
