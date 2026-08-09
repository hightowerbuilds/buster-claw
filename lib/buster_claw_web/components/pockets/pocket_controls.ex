defmodule BusterClawWeb.Pockets.PocketControls do
  @moduledoc """
  The Pockets tab's three write affordances, and only those three: **New**,
  **Mount…**, and the `↗` glyph that marks a mounted Pocket.

  Named exactly that in roadmap D9, which states the tab's minimalism as a
  constraint rather than a mood. Anything beyond these three belongs in a
  conversation, not in this file.

  Markup only. Every event is handled by `BusterClawWeb.PocketsPanel`, and every
  mount goes through `BusterClaw.Pockets.Operator` — never `Mounts` directly,
  which knows nothing about roles.

  ## Why a typed path and not a folder picker

  There is no dialog plugin anywhere in `desktop/tauri/`, and adding one means a
  new dependency plus capability and `build.rs` registration — the lockstep this
  codebase has already lost a feature to once. The workspace root itself is
  chosen by typing a path today (`workspace_live.ex`), so this matches the app
  rather than inventing a second convention. Roadmap I.4.
  """
  use BusterClawWeb, :html

  attr :target, :any, required: true
  attr :open, :string, default: nil, doc: "which control is expanded: \"new\" or nil"
  attr :error, :string, default: nil

  @doc "The header row: the New control, and its form when open."
  def new_pocket(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-2 px-4 py-2">
      <p class="font-mono text-[10px] uppercase tracking-wide text-base-content/45">
        Your Pockets
      </p>
      <button
        type="button"
        phx-click="toggle_new"
        phx-target={@target}
        class="rounded border border-base-content/20 px-2 py-1 font-mono text-[10px] uppercase tracking-wide transition hover:bg-base-content/10"
      >
        {if @open == "new", do: "Cancel", else: "New"}
      </button>
    </div>

    <form
      :if={@open == "new"}
      id="pocket-new-form"
      phx-submit="create_pocket"
      phx-target={@target}
      class="flex flex-wrap items-center gap-2 px-4 pb-3"
    >
      <input
        type="text"
        name="name"
        placeholder="hazard-icons"
        autocomplete="off"
        class="input input-xs flex-1 font-mono"
      />
      <button
        type="submit"
        class="rounded bg-primary px-2 py-1 font-mono text-[10px] uppercase tracking-wide text-primary-content"
      >
        Create
      </button>
      <p class="w-full font-mono text-[10px] text-base-content/45">
        Lowercase letters, digits and hyphens. It appears under <span class="text-base-content/70">pockets/</span>.
      </p>
      <p :if={@error} class="w-full font-mono text-[10px] text-error">{@error}</p>
    </form>
    """
  end

  attr :row, :map, required: true
  attr :target, :any, required: true
  attr :open, :string, default: nil, doc: "the pocket name whose mount form is expanded"
  attr :error, :string, default: nil

  @doc """
  The mount controls for one open Pocket: mount it somewhere, or unmount it.

  Unmounting **deletes nothing** — that asymmetry is the point of a recorded
  mount, and it is why the two buttons use different words.
  """
  def mount_controls(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 border-t-2 border-base-content/10 px-4 py-3">
      <div class="min-w-0 flex-1">
        <p class="font-mono text-[10px] uppercase tracking-wide text-base-content/45">
          {location_text(@row.pocket)}
        </p>
      </div>

      <button
        :if={mounted?(@row.pocket)}
        type="button"
        phx-click="unmount_pocket"
        phx-value-name={@row.name}
        phx-target={@target}
        data-claw-confirm="Unmount this Pocket? The folder and its files are left exactly where they are."
        class="rounded border border-base-content/20 px-2 py-1 font-mono text-[10px] uppercase tracking-wide transition hover:bg-base-content/10"
      >
        Unmount
      </button>
      <button
        type="button"
        phx-click="toggle_mount"
        phx-value-name={@row.name}
        phx-target={@target}
        class="rounded border border-base-content/20 px-2 py-1 font-mono text-[10px] uppercase tracking-wide transition hover:bg-base-content/10"
      >
        {cond do
          @open == @row.name -> "Cancel"
          mounted?(@row.pocket) -> "Move…"
          true -> "Mount…"
        end}
      </button>
    </div>

    <form
      :if={@open == @row.name}
      id={"pocket-mount-#{@row.name}"}
      phx-submit="mount_pocket"
      phx-target={@target}
      class="flex flex-wrap items-center gap-2 border-t border-base-content/10 px-4 py-3"
    >
      <input type="hidden" name="name" value={@row.name} />
      <input
        type="text"
        name="path"
        placeholder="/Users/you/Pictures/icons"
        autocomplete="off"
        class="input input-xs flex-1 font-mono"
      />
      <label class="flex items-center gap-1 font-mono text-[10px] uppercase tracking-wide">
        <input type="checkbox" name="writable" value="true" class="checkbox checkbox-xs" /> Writable
      </label>
      <button
        type="submit"
        class="rounded bg-primary px-2 py-1 font-mono text-[10px] uppercase tracking-wide text-primary-content"
      >
        Mount
      </button>
      <p class="w-full font-mono text-[10px] text-base-content/45">
        An absolute path to a folder. Its files become this Pocket's contents; the
        folder is only ever read unless you tick Writable.
      </p>
      <p :if={@error} class="w-full font-mono text-[10px] text-error">{@error}</p>
    </form>
    """
  end

  attr :pocket, :map, default: nil

  @doc "The `↗` that marks a mounted Pocket in the list. A glyph, not a badge."
  def mount_glyph(assigns) do
    ~H"""
    <span
      :if={mounted?(@pocket)}
      title="Mounted — its files live outside the workspace"
      class="font-mono text-[10px] text-primary"
    >
      ↗
    </span>
    """
  end

  defp mounted?(%{binding: {:mounted, _path, _writable}}), do: true
  defp mounted?(_pocket), do: false

  defp location_text(%{binding: {:mounted, path, writable}}),
    do: "↗ #{path}#{if writable, do: " · writable", else: ""}"

  defp location_text(_pocket), do: "in the workspace"
end
