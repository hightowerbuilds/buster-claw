defmodule BusterClaw.Commands.Notes do
  @moduledoc """
  Note commands (the operator's notebook). Delegated from `BusterClaw.Commands`.

  Deliberately narrow. There is no absolute-path write and no delete: every
  argument is a path *relative to the vault*, validated by `BusterClaw.Notes`,
  and the destructive verb stays a human one. Notes is the operator's writing —
  the agent reads and edits it when asked, and never uses it as an activity log
  (that is `journal_append`, always).

  `note_save` requires the revision the agent read, so a save that would land on
  top of someone else's edit fails loudly instead of silently winning. The
  conflict reply carries the current revision but **not** the current body: a
  merge starts with a deliberate `note_read`, not with a diff smuggled into an
  error.
  """

  alias BusterClaw.Notes

  @doc "List every note in the vault (paths and titles; no bodies)."
  def note_list(_args \\ %{}) do
    {:ok, %{notes: Enum.map(Notes.list(), &summary/1)}}
  end

  @doc "Read one note by its vault-relative path."
  def note_read(%{"path" => path}) do
    case Notes.get(path) do
      note when is_map(note) -> {:ok, Map.take(note, [:path, :title, :revision, :body])}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def note_read(_args), do: {:error, :missing_path}

  @doc """
  Create a note, optionally with a body.

  The body is written as a second step through the same revision-checked save
  the editor uses, so a note created and filled here is indistinguishable from
  one typed by hand.
  """
  def note_create(%{"title" => title} = args) do
    folder = Map.get(args, "folder", "")
    body = Map.get(args, "body")

    with {:ok, note} <- Notes.create(title, folder) do
      write_initial_body(note, body)
    end
  end

  def note_create(_args), do: {:error, :missing_title}

  @doc "Overwrite a note whose on-disk revision still matches `revision`."
  def note_save(%{"path" => path, "body" => body, "revision" => revision}) do
    case Notes.save(path, body, revision) do
      {:ok, note} -> {:ok, Map.take(note, [:path, :title, :revision])}
      {:error, {:conflict, current}} -> {:error, {:conflict, current.revision}}
      {:error, reason} -> {:error, reason}
    end
  end

  def note_save(_args), do: {:error, :missing_path_body_or_revision}

  @doc "Search note titles and bodies, returning paths with a short snippet."
  def note_search(%{"query" => query}) do
    {:ok, %{results: Enum.map(Notes.search(query), &Map.take(&1, [:path, :title, :snippet]))}}
  end

  def note_search(_args), do: {:error, :missing_query}

  defp write_initial_body(note, body) when is_binary(body) and body != "" do
    case Notes.save(note.path, body, note.revision) do
      {:ok, saved} -> {:ok, summary(saved)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_initial_body(note, _body), do: {:ok, summary(note)}

  defp summary(note), do: Map.take(note, [:path, :title, :revision, :size, :updated_at])
end
