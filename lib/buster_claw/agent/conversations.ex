defmodule BusterClaw.Agent.Conversations do
  @moduledoc """
  Durable list of chat conversations — one per tab. Each row's `id` is the
  `conv_id` used by `BusterClaw.Agent.Chat` (the per-conversation GenServer),
  `BusterClaw.Agent.Transcript`, and the PubSub topic. Closing a tab archives the
  row (`archived_at`) rather than deleting, so the transcript stays queryable.
  """
  import Ecto.Query

  alias BusterClaw.Repo
  alias BusterClaw.Agent.Conversation

  @default_id "default"
  @default_title "New chat"

  @doc "The seeded default conversation id (matches `Chat.default_conv_id/0`)."
  def default_id, do: @default_id

  @doc "Title given to a fresh chat until its first message renames it."
  def default_title, do: @default_title

  @doc "Open (non-archived) conversations, in stable creation order (left-to-right tabs)."
  def list do
    ensure_seeded()

    Conversation
    |> where([c], is_nil(c.archived_at))
    |> order_by(asc: :inserted_at, asc: :id)
    |> Repo.all()
  end

  def get(id), do: Repo.get(Conversation, id)

  @doc "Create a new conversation (auto-id + default title unless given)."
  def create(attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:id, generate_id())
      |> Map.put_new(:title, @default_title)

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Rename a conversation (used to title a 'New chat' from its first message)."
  def rename(id, title) when is_binary(title) and title != "" do
    case get(id) do
      nil -> {:error, :not_found}
      conv -> conv |> Conversation.changeset(%{title: title}) |> Repo.update()
    end
  end

  @doc "Bump last-active so a reload can re-select the most recently used chat."
  def touch(id) do
    {_, _} =
      Conversation
      |> where([c], c.id == ^id)
      |> Repo.update_all(set: [updated_at: now()])

    :ok
  end

  @doc "Archive (close) a conversation — keeps its transcript, drops it from the tabs."
  def close(id) do
    {_, _} =
      Conversation
      |> where([c], c.id == ^id and is_nil(c.archived_at))
      |> Repo.update_all(set: [archived_at: now()])

    :ok
  end

  # Seed the default conversation only on a virgin table, so the pre-existing
  # "default" transcript surfaces as the first tab — without resurrecting a
  # conversation the user later closed.
  defp ensure_seeded do
    if Repo.aggregate(Conversation, :count) == 0 do
      create(%{id: @default_id, title: "Chat"})
    end

    :ok
  end

  defp generate_id do
    "conv-" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
