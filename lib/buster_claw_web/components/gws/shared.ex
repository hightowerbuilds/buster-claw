defmodule BusterClawWeb.Gws.Shared do
  @moduledoc """
  The pane shell every Google Workspace tool tab is built in, and the small
  account-status formatters the panes and the accounts list share.

  Imported rather than aliased, so a pane still writes `<.tool_pane title="…">`
  and `account_options(@accounts)` exactly as it did when the console was one
  three-hundred-line function.
  """
  use BusterClawWeb, :html

  # A tool tab's body: a fixed-width form card on the left, its results filling
  # the rest. The form goes in the `:form` slot; results are the default block.
  attr :title, :string, required: true
  slot :form, required: true
  slot :inner_block, required: true

  def tool_pane(assigns) do
    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-100">
      <div class="border-b border-base-300 px-4 py-3">
        <h2 class="text-sm font-semibold">{@title}</h2>
      </div>
      <div class="grid gap-5 p-4 lg:grid-cols-[20rem_minmax(0,1fr)]">
        <div class="rounded border border-base-300 p-3">
          {render_slot(@form)}
        </div>
        <div class="min-w-0 space-y-4">
          {render_slot(@inner_block)}
        </div>
      </div>
    </section>
    """
  end

  def account_options(accounts), do: Enum.map(accounts, &{&1.email, &1.id})

  def account_enabled_class(true), do: "rounded bg-success/15 px-2 py-1 text-xs text-success"
  def account_enabled_class(false), do: "rounded bg-warning/15 px-2 py-1 text-xs text-warning"

  def account_token_class(true), do: "rounded bg-info/15 px-2 py-1 text-xs text-info"
  def account_token_class(false), do: "rounded bg-error/15 px-2 py-1 text-xs text-error"

  def token_expiry_label(nil), do: "not connected"
  def token_expiry_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  # One line per account: "Mail ✓ · Calendar ✓ · Drive ✗ (HTTP 403: ...)".
  # Green checks are the whole point of the post-connect self-test — the
  # failing surface is *named* instead of surfacing later as a mystery.
  def self_test_label(nil), do: "not yet tested — run Self-test"

  def self_test_label(%{results: results, at: at}) do
    line =
      Enum.map_join(BusterClaw.Google.SelfTest.surfaces(), " · ", fn surface ->
        name = surface |> Atom.to_string() |> String.capitalize()

        case Map.get(results, Atom.to_string(surface)) do
          "ok" -> "#{name} ✓"
          nil -> "#{name} —"
          error -> "#{name} ✗ (#{error})"
        end
      end)

    if at, do: "#{line} · tested #{at}", else: line
  end

  def missing_scopes?(account) do
    granted =
      (account.scopes || "")
      |> String.split(~r/\s+/, trim: true)
      |> MapSet.new()

    Enum.any?(BusterClaw.Google.OAuth.default_scopes(), &(not MapSet.member?(granted, &1)))
  end
end
