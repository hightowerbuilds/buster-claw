defmodule BusterClawWeb.Explained.Stub do
  @moduledoc """
  A feature tab before its tutorial exists.

  Renders from a `Registry` feature entry, so a new sub-tab is a real page with
  true copy and a working deep link from the moment its key is added — never a
  dead rail button.
  """
  use BusterClawWeb, :html

  attr :stub, :map, required: true

  # A feature tab before its tutorial exists: a true paragraph about the
  # surface, a deep link into the real tab, and an honest note that the
  # walkthrough is still being written. Phase 2 replaces these one at a time.
  def stub_panel(assigns) do
    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-5 px-6 py-8">
      <div>
        <p class="ic-eyebrow">{@stub.eyebrow}</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          {@stub.label}
        </h2>
      </div>

      <p class="text-sm leading-relaxed text-base-content/80">{@stub.body}</p>

      <.link
        navigate={@stub.path}
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" />
        {@stub.path_label}
      </.link>

      <p class="font-mono text-xs uppercase tracking-wide text-base-content/45">
        Tutorial in the works — the full walkthrough lands on this tab.
      </p>
    </div>
    """
  end
end
