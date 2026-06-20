defmodule BusterClaw.Google.Tasks do
  @moduledoc "Google Tasks read/write helpers for connected Google Workspace accounts."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Client

  @tasks_base_url "https://tasks.googleapis.com/tasks/v1"
  @default_max_results 100

  @doc "List the account's task lists."
  def list_tasklists(%Account{} = account, opts \\ []) do
    params = [{"maxResults", max_results(opts)}] |> maybe_put_page_token(opts)

    with {:ok, body} <- get(account, "users/@me/lists", params, opts) do
      {:ok,
       %{
         tasklists: body |> Map.get("items", []) |> Enum.map(&tasklist_summary/1),
         next_page_token: Map.get(body, "nextPageToken")
       }}
    end
  end

  @doc "List the tasks in a task list (defaults to showing completed + hidden)."
  def list_tasks(%Account{} = account, tasklist_id, opts \\ []) do
    params =
      [
        {"maxResults", max_results(opts)},
        {"showCompleted", to_string(Keyword.get(opts, :show_completed, true))},
        {"showHidden", to_string(Keyword.get(opts, :show_hidden, true))}
      ]
      |> maybe_put_page_token(opts)

    with {:ok, body} <- get(account, "lists/#{enc(tasklist_id)}/tasks", params, opts) do
      {:ok,
       %{
         tasklist_id: to_string(tasklist_id),
         tasks: body |> Map.get("items", []) |> Enum.map(&task_summary/1),
         next_page_token: Map.get(body, "nextPageToken")
       }}
    end
  end

  @doc "Fetch a single task."
  def get_task(%Account{} = account, tasklist_id, task_id, opts \\ []) do
    with {:ok, body} <-
           get(account, "lists/#{enc(tasklist_id)}/tasks/#{enc(task_id)}", [], opts) do
      {:ok, task_summary(body)}
    end
  end

  @doc "Create a task (`tasks.insert`). `attrs` accepts title/notes/due/status."
  def create_task(%Account{} = account, tasklist_id, attrs, opts \\ []) when is_map(attrs) do
    opts = Keyword.put(opts, :base_url, @tasks_base_url)

    with {:ok, body} <-
           Client.post_json(account, "lists/#{enc(tasklist_id)}/tasks", attrs, opts) do
      {:ok, task_summary(body)}
    end
  end

  @doc "Patch a task (`tasks.patch`) — title/notes/due/status (`completed`/`needsAction`)."
  def update_task(%Account{} = account, tasklist_id, task_id, attrs, opts \\ [])
      when is_map(attrs) do
    opts = Keyword.put(opts, :base_url, @tasks_base_url)
    path = "lists/#{enc(tasklist_id)}/tasks/#{enc(task_id)}"

    with {:ok, body} <- Client.patch_json(account, path, attrs, opts) do
      {:ok, task_summary(body)}
    end
  end

  @doc "Delete a task (`tasks.delete`, irreversible)."
  def delete_task(%Account{} = account, tasklist_id, task_id, opts \\ []) do
    opts = Keyword.put(opts, :base_url, @tasks_base_url)
    path = "lists/#{enc(tasklist_id)}/tasks/#{enc(task_id)}"

    with {:ok, _} <- Client.delete(account, path, opts) do
      {:ok, %{id: to_string(task_id), tasklist_id: to_string(tasklist_id), deleted: true}}
    end
  end

  defp get(account, path, params, opts) do
    opts = opts |> Keyword.put(:base_url, @tasks_base_url) |> Keyword.put(:params, params)
    Client.get_json(account, path, opts)
  end

  defp tasklist_summary(list) do
    %{
      id: Map.get(list, "id"),
      title: Map.get(list, "title"),
      updated: Map.get(list, "updated")
    }
  end

  defp task_summary(task) do
    %{
      id: Map.get(task, "id"),
      title: Map.get(task, "title"),
      notes: Map.get(task, "notes"),
      status: Map.get(task, "status"),
      due: Map.get(task, "due"),
      completed: Map.get(task, "completed"),
      parent: Map.get(task, "parent"),
      position: Map.get(task, "position"),
      raw: task
    }
  end

  defp max_results(opts) do
    opts |> Keyword.get(:max_results, @default_max_results) |> to_string()
  end

  defp maybe_put_page_token(params, opts) do
    case Keyword.get(opts, :page_token) do
      token when token in [nil, ""] -> params
      token -> [{"pageToken", token} | params]
    end
  end

  defp enc(value), do: URI.encode_www_form(to_string(value))
end
