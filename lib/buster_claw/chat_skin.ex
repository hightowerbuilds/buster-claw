defmodule BusterClaw.ChatSkin do
  @moduledoc """
  The look of the homepage chat transcript — three skins, one setting.

  This module is the single source of truth: the keys, their operator-facing
  labels and blurbs, the default, the validator, the store, and the topic a
  change is announced on. The dropdown's options, the panel's attribute and the
  tests all read from here, so adding a fourth skin is one entry in `@skins`
  plus one CSS block in `assets/css/app.css`.

  ## Skin, not theme

  The app already has a `data-theme` — daisyUI's, values `dark` and `light`,
  owned by the whole window. This is a different axis, so nothing here is called
  a theme: the attribute is `data-chat-skin` and the values are `industrial`,
  `minimal` and `slack`. The two axes multiply — three skins against dark and
  light is six combinations that all have to be legible — which is why a skin's
  CSS may only reach for daisyUI tokens (`--color-base-*`, `--color-primary`)
  and never a hex literal.

  ## The contract that makes a skin CSS-only

  The transcript is a LiveView **stream**. Stream children are rendered once, on
  insert; a later parent re-render sends no stream ops, so a message already on
  screen keeps the DOM and the classes it was born with. Branching the bubble's
  class list on the current skin would therefore half-apply: the header and
  composer would change and every message above them would not, until a reload.

  So the rendered DOM is **identical under all three skins**. The only thing the
  server varies is `data-chat-skin` on the panel's root `<section>`; every
  visual difference is a CSS descendant rule, and an element one skin needs is
  rendered by all three and hidden in the others.
  `BusterClawWeb.ChatPanelTest` asserts that byte-for-byte, so a future
  `if @skin == "slack"` in the template fails immediately.

  ## Storage and liveness

  `Settings` holds the key; a change broadcasts `{:chat_skin, key}` on `topic/0`
  so an open homepage restyles without a reload — the same set → broadcast →
  re-render path `BusterClaw.Appearance` uses for backgrounds. A stored value
  that is not a known skin resolves to the default rather than rendering an
  unstyled panel.
  """

  alias BusterClaw.Settings

  @setting_key "chat_skin"
  @topic "chat:skin"

  # In dropdown order, default first. `blurb` is what the operator reads under
  # the option; it describes the look rather than naming another product, since
  # these ship in a release.
  @skins [
    %{
      key: "industrial",
      label: "Industrial Claw",
      blurb: "Bubbles, hard borders, hazard orange. The app's own look."
    },
    %{
      key: "minimal",
      label: "Minimal",
      blurb: "One monospace column, no bubbles — reads like a terminal session."
    },
    %{
      key: "slack",
      label: "Workplace",
      blurb: "Author above message, roomy rows — the group-chat look."
    }
  ]

  @default hd(@skins).key
  @keys Enum.map(@skins, & &1.key)

  @doc "Every skin as `%{key, label, blurb}`, in dropdown order."
  def skins, do: @skins

  @doc "Every valid skin key, in dropdown order."
  def keys, do: @keys

  @doc "The skin a missing or unrecognized setting resolves to."
  def default, do: @default

  @doc "PubSub topic a skin change is announced on."
  def topic, do: @topic

  @doc "Subscribe the calling process to skin changes."
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc "The `Settings` key the skin is stored under."
  def setting_key, do: @setting_key

  @doc "Whether `key` names a skin that exists."
  def valid?(key), do: key in @keys

  @doc "Operator-facing label for a skin key, or `nil` when there is no such skin."
  def label(key) do
    case Enum.find(@skins, &(&1.key == key)) do
      nil -> nil
      skin -> skin.label
    end
  end

  @doc """
  The skin in force.

  Anything stored that is not a known skin — a hand-edited row, a skin removed
  in a later release — resolves to `default/0`.
  """
  def get do
    case Settings.get(@setting_key) do
      key when key in @keys -> key
      _ -> @default
    end
  end

  @doc """
  Point the chat at skin `key`, announcing it on `topic/0`.

  Returns `{:ok, key}` or `{:error, :invalid_skin}`. Writing is idempotent and
  still broadcasts: a re-select of the current skin costs one cheap re-render,
  which is preferable to a dropdown that silently does nothing.
  """
  def set(key) when is_binary(key) do
    if valid?(key) do
      Settings.put(@setting_key, key)
      Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:chat_skin, key})
      {:ok, key}
    else
      {:error, :invalid_skin}
    end
  end

  def set(_key), do: {:error, :invalid_skin}
end
