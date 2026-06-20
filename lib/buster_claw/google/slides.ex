defmodule BusterClaw.Google.Slides do
  @moduledoc "Google Slides read/write helpers for connected Google Workspace accounts."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Client

  @slides_base_url "https://slides.googleapis.com/v1"

  @doc "Fetch a presentation (`presentations.get`)."
  def get(%Account{} = account, presentation_id, opts \\ []) do
    opts = Keyword.put(opts, :base_url, @slides_base_url)

    with {:ok, body} <- Client.get_json(account, "presentations/#{enc(presentation_id)}", opts) do
      {:ok, summary(body)}
    end
  end

  @doc "Create a presentation with a title (`presentations.create`)."
  def create(%Account{} = account, title, opts \\ []) do
    opts = Keyword.put(opts, :base_url, @slides_base_url)

    with {:ok, body} <- Client.post_json(account, "presentations", %{"title" => title}, opts) do
      {:ok, summary(body)}
    end
  end

  @doc """
  Apply edit requests (`presentations.batchUpdate`) — createSlide, insertText, etc.
  `requests` is the raw Google request list.
  """
  def batch_update(%Account{} = account, presentation_id, requests, opts \\ [])
      when is_list(requests) do
    opts = Keyword.put(opts, :base_url, @slides_base_url)
    path = "presentations/#{enc(presentation_id)}:batchUpdate"

    with {:ok, body} <- Client.post_json(account, path, %{"requests" => requests}, opts) do
      {:ok, body}
    end
  end

  defp summary(body) do
    %{
      presentation_id: Map.get(body, "presentationId"),
      title: Map.get(body, "title"),
      revision_id: Map.get(body, "revisionId"),
      slide_count: body |> Map.get("slides", []) |> length(),
      raw: body
    }
  end

  defp enc(value), do: URI.encode_www_form(to_string(value))
end
