defmodule BusterClaw.Agent.Conversations do
  @moduledoc """
  Durable list of chat conversations — one per tab. Each row's `id` is the
  `conv_id` used by `BusterClaw.Agent.Chat` (the per-conversation GenServer),
  `BusterClaw.Agent.Transcript`, and the PubSub topic. Closing a tab archives the
  row (`archived_at`) rather than deleting, so the transcript stays queryable.
  """
  import Ecto.Query

  alias BusterClaw.Agent.Conversation
  alias BusterClaw.Repo

  @default_id "default"
  @default_title "New chat"

  @doc "The seeded default conversation id (matches `Chat.default_conv_id/0`)."
  def default_id, do: @default_id

  @doc "Title given to a fresh chat until its first message renames it."
  def default_title, do: @default_title

  @doc """
  Open (non-archived) Home conversations, in stable creation order.

  Home only — a Trading tab must never appear in Home's chat strip, which is the
  whole reason `kind` exists. Use `list_kinds/1` for the Trading page.
  """
  def list do
    ensure_seeded()
    query_kinds(["home"])
  end

  @doc """
  Open conversations of the given kinds, in stable creation order.

  The Trading page passes `Trading.tab_kinds/0` and gets its tab strip,
  left to right, with the pinned Robinhood conversation first because it was
  seeded first.
  """
  def list_kinds(kinds) when is_list(kinds), do: query_kinds(kinds)

  defp query_kinds(kinds) do
    Conversation
    |> where([c], is_nil(c.archived_at) and c.kind in ^kinds)
    |> order_by(asc: :inserted_at, asc: :id)
    |> Repo.all()
  end

  @doc """
  Ensure a specific conversation row exists, without resurrecting a closed one.

  Used for the first Robinhood tab: its transcript already lives under the
  `"trading"` conv_id from when the conversation was deliberately DB-less, so
  seeding that exact id adopts the existing history rather than starting over.

  Never resurrects: a row the operator closed stays closed (it comes back
  archived, and `list_kinds/1` still omits it). Keeping at least one tab on
  screen is the caller's job, exactly as it is for Home.
  """
  def ensure(id, attrs) when is_binary(id) do
    case get(id) do
      nil ->
        {:ok, conv} = create(Map.merge(Map.new(attrs), %{id: id}))
        conv

      conv ->
        conv
    end
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

  @doc """
  Set a Trading conversation's kind — which decides its toolset on the next turn.

  The caller is responsible for stopping the conversation's `Chat` process
  afterwards. That is not incidental: the session id lives in that process, so
  stopping it means the next message starts a FRESH claude session instead of
  `--resume`-ing one whose context was gathered under the old kind. Retyping a
  Robinhood chat to Chart Build would otherwise hand account balances to a run
  that is supposed to have no account access at all — and which can reach the
  web.
  """
  def set_kind(id, kind) when is_binary(kind) do
    case get(id) do
      nil -> {:error, :not_found}
      conv -> conv |> Conversation.changeset(%{kind: kind}) |> Repo.update()
    end
  end

  @doc "Dock a conversation into the sub-tab system, or float it back out."
  def set_docked(id, docked?) when is_boolean(docked?) do
    case get(id) do
      nil -> {:error, :not_found}
      conv -> conv |> Conversation.changeset(%{docked: docked?}) |> Repo.update()
    end
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
