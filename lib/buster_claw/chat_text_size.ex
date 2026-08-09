defmodule BusterClaw.ChatTextSize do
  @moduledoc """
  How large the chat's text is — four steps, one setting, independent of the skin.

  Sibling of `BusterClaw.ChatSkin` and deliberately a separate axis: a reader who
  wants bigger text should not have to give up the look they chose, and a skin
  should not have to ship four copies of itself. The two multiply, so every skin
  expresses its font sizes as `calc(<its own size> * var(--chat-scale, 1))` and
  this setting supplies the one number.

  ## The same contract as the skin, for the same reason

  The transcript is a LiveView **stream**: children are rendered once, on insert,
  so a message already on screen is never re-rendered when an assign changes.
  Size is therefore CSS-only — the server varies `data-chat-text-size` on the
  panel's root `<section>` and nothing else, and `ChatPanelTest` asserts the
  rendered HTML is byte-identical across every skin *and* every size.

  ## Why the default has no CSS

  `normal` is scale 1, and `calc(x * var(--chat-scale, 1))` already resolves to
  `x` when the property is unset. So the default writes nothing, exactly as the
  `industrial` skin writes nothing: there is no rule that can be wrong, so the
  out-of-the-box reading experience cannot regress through the stylesheet.

  The scale numbers live here and are read back out of the stylesheet by
  `BusterClawWeb.ChatSkinCssTest`, so the percentage the UI promises and the
  multiplier the CSS applies cannot drift apart.

  Only enlargement is offered. Nobody asked to make the chat smaller, and Minimal
  already runs the tightest type in the app.
  """

  alias BusterClaw.Settings

  @setting_key "chat_text_size"
  @topic "chat:text_size"

  # In dropdown order, default first. `scale` is the multiplier the CSS applies;
  # the UI shows it as a percentage so the choice is legible rather than vague.
  @sizes [
    %{key: "normal", label: "Normal", scale: 1.0},
    %{key: "large", label: "Large", scale: 1.15},
    %{key: "larger", label: "Larger", scale: 1.3},
    %{key: "largest", label: "Largest", scale: 1.5}
  ]

  @default hd(@sizes).key
  @keys Enum.map(@sizes, & &1.key)

  @doc "Every size as `%{key, label, scale}`, in dropdown order."
  def sizes, do: @sizes

  @doc "Every valid size key, in dropdown order."
  def keys, do: @keys

  @doc "The size a missing or unrecognized setting resolves to."
  def default, do: @default

  @doc "PubSub topic a size change is announced on."
  def topic, do: @topic

  @doc "Subscribe the calling process to size changes."
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc "The `Settings` key the size is stored under."
  def setting_key, do: @setting_key

  @doc "Whether `key` names a size that exists."
  def valid?(key), do: key in @keys

  @doc "Percentage a size renders at — 115 for `large`. Whole numbers by construction."
  def percent(key) do
    case Enum.find(@sizes, &(&1.key == key)) do
      nil -> nil
      size -> round(size.scale * 100)
    end
  end

  @doc "The size in force; anything unrecognized resolves to `default/0`."
  def get do
    case Settings.get(@setting_key) do
      key when key in @keys -> key
      _ -> @default
    end
  end

  @doc """
  Set the chat text size, announcing it on `topic/0`.

  Returns `{:ok, key}` or `{:error, :invalid_size}`. Like the skin, a re-select of
  the current size still broadcasts: a control that appears to do nothing reads as
  broken, and one cheap re-render is the better trade.
  """
  def set(key) when is_binary(key) do
    if valid?(key) do
      Settings.put(@setting_key, key)
      Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:chat_text_size, key})
      {:ok, key}
    else
      {:error, :invalid_size}
    end
  end

  def set(_key), do: {:error, :invalid_size}
end
