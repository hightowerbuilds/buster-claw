defmodule BusterClaw.Google.Docs do
  @moduledoc "Google Docs read/write helpers for connected Google Workspace accounts."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Client

  @docs_base_url "https://docs.googleapis.com/v1"

  @doc "Fetch a document's full structure (`documents.get`)."
  def get(%Account{} = account, document_id, opts \\ []) do
    opts = Keyword.put(opts, :base_url, @docs_base_url)

    with {:ok, body} <- Client.get_json(account, "documents/#{enc(document_id)}", opts) do
      {:ok, summary(body)}
    end
  end

  @doc "Create an empty document with a title (`documents.create`)."
  def create(%Account{} = account, title, opts \\ []) do
    opts = Keyword.put(opts, :base_url, @docs_base_url)

    with {:ok, body} <- Client.post_json(account, "documents", %{"title" => title}, opts) do
      {:ok, summary(body)}
    end
  end

  @doc """
  Apply a list of edit requests (`documents.batchUpdate`) — insertText,
  replaceAllText, updateTextStyle, etc. `requests` is the raw Google request list.
  """
  def batch_update(%Account{} = account, document_id, requests, opts \\ [])
      when is_list(requests) do
    opts = Keyword.put(opts, :base_url, @docs_base_url)
    path = "documents/#{enc(document_id)}:batchUpdate"

    with {:ok, body} <- Client.post_json(account, path, %{"requests" => requests}, opts) do
      {:ok, body}
    end
  end

  defp summary(body) do
    %{
      document_id: Map.get(body, "documentId"),
      title: Map.get(body, "title"),
      revision_id: Map.get(body, "revisionId"),
      raw: body
    }
  end

  defp enc(value), do: URI.encode_www_form(to_string(value))
end
