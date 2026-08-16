defmodule BusterClawWeb.Pockets.BrandSlots do
  @moduledoc """
  The brand section of the Pockets tab: the six app-art slots, what is filling
  each, and the upload that replaces one.

  Markup only. The upload state and every event live in
  `BusterClawWeb.PocketsPanel`, because `allow_upload/3` configures the socket
  that owns it — this module renders what that socket already decided.

  Split out so the panel does not absorb a second feature's markup; the same
  reason `BusterClawWeb.BrandArt` exists.
  """
  use BusterClawWeb, :html

  attr :slots, :list, required: true
  attr :uploads, :map, required: true
  attr :upload_role, :string, default: nil
  attr :upload_error, :string, default: nil
  attr :target, :any, required: true

  def brand_slots(assigns) do
    ~H"""
    <section id="pockets-brand" class="border-b-2 border-base-content/15 bg-base-200/25">
      <header class="flex flex-wrap items-baseline justify-between gap-2 px-4 py-3">
        <h3 class="font-display text-xs font-black uppercase tracking-tight">App art</h3>
        <p class="font-mono text-[10px] uppercase tracking-wide text-base-content/45">
          One image each · two or more and the slot shows text
        </p>
      </header>

      <ul id="brand-slot-list" class="divide-y divide-base-content/10">
        <li
          :for={slot <- @slots}
          id={"brand-slot-#{slot.role}"}
          class="flex flex-wrap items-center gap-3 px-4 py-2.5"
        >
          <div class="flex size-9 shrink-0 items-center justify-center rounded border border-base-content/15 bg-base-100">
            <img :if={slot.url} src={slot.url} alt="" class="max-h-7 max-w-7 object-contain" />
            <span
              :if={!slot.url}
              class="font-mono text-[9px] uppercase text-base-content/40"
              title="This slot is showing its text label"
            >
              txt
            </span>
          </div>

          <div class="min-w-0 flex-1">
            <p class="font-display text-sm font-bold tracking-tight">{slot.label}</p>
            <p class={[
              "font-mono text-[10px] uppercase tracking-wide",
              error?(slot.status) && "text-error",
              !error?(slot.status) && "text-base-content/45"
            ]}>
              {status_text(slot)}
            </p>
          </div>

          <div class="flex shrink-0 items-center gap-1.5">
            <button
              type="button"
              phx-click="pick_brand"
              phx-value-role={slot.role}
              phx-target={@target}
              class="rounded border border-base-content/20 px-2 py-1 font-mono text-[10px] uppercase tracking-wide transition hover:bg-base-content/10"
            >
              {if slot.status == :default, do: "Add art", else: "Replace"}
            </button>
            <button
              :if={slot.status != :default}
              type="button"
              phx-click="clear_brand"
              phx-value-role={slot.role}
              phx-target={@target}
              class="rounded border border-base-content/20 px-2 py-1 font-mono text-[10px] uppercase tracking-wide transition hover:bg-base-content/10"
            >
              Use default
            </button>
          </div>

          <.upload_form
            :if={@upload_role == slot.role}
            role={slot.role}
            uploads={@uploads}
            upload_error={@upload_error}
            target={@target}
          />
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  The file picker for one slot, plus every reason an upload can fail.

  Shared with `AppIconSlot` rather than copied. The error rendering below is the
  load-bearing part: with none of it drawn, a refused file looked exactly like a
  file that had not been chosen, which is how this read as "the upload does
  nothing". A second copy of that is a second place for it to go missing.
  """
  attr :role, :string, required: true
  attr :uploads, :map, required: true
  attr :upload_error, :string, default: nil
  attr :target, :any, required: true

  def upload_form(assigns) do
    ~H"""
    <form
      id={"brand-upload-#{@role}"}
      phx-submit="upload_brand"
      phx-change="validate_brand"
      phx-target={@target}
      class="w-full pt-1"
    >
      <.live_file_input upload={@uploads.brand} class="file-input file-input-xs w-full" />
      <p class="pt-1 font-mono text-[10px] text-base-content/45">
        Choosing a file applies it straight away.
      </p>

      <p :for={err <- upload_errors(@uploads.brand)} class="pt-1 font-mono text-[10px] text-error">
        {error_text(err)}
      </p>
      <div :for={entry <- @uploads.brand.entries} class="pt-1">
        <p
          :for={err <- upload_errors(@uploads.brand, entry)}
          class="font-mono text-[10px] text-error"
        >
          {entry.client_name}: {error_text(err)}
        </p>
        <progress
          :if={entry.progress > 0 and entry.progress < 100}
          class="progress progress-primary h-1 w-full"
          value={entry.progress}
          max="100"
        />
      </div>
      <p :if={@upload_error} class="pt-1 font-mono text-[10px] text-error">
        {@upload_error}
      </p>
    </form>
    """
  end

  # LiveView's upload error atoms, said in the operator's terms.
  defp error_text(:too_large), do: "that file is bigger than 8 MB"
  defp error_text(:too_many_files), do: "one image at a time"
  defp error_text(:not_accepted), do: "that is not an image type we can show"
  defp error_text(other), do: to_string(other)

  defp error?({:error, _, _}), do: true
  defp error?(_status), do: false

  # The message is deliberately flat and does not ask for anything. The operator
  # may ignore it for as long as they like; the app stays usable with a text
  # label, and removing the extra file — here or in Finder — brings the art back
  # with no further step.
  defp status_text(%{status: {:error, :too_many, n}, pocket: pocket}),
    do: "#{n} images in pockets/#{pocket}/ — remove all but one to show art again"

  defp status_text(%{status: :custom}), do: "your image"
  defp status_text(%{status: :default}), do: "shipped default"
end
