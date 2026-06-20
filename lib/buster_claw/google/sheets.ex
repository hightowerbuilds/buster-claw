defmodule BusterClaw.Google.Sheets do
  @moduledoc "Google Sheets read/write helpers for connected Google Workspace accounts."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Client

  @sheets_base_url "https://sheets.googleapis.com/v4"
  @default_value_input "USER_ENTERED"

  @doc "Fetch spreadsheet metadata (`spreadsheets.get`)."
  def get(%Account{} = account, spreadsheet_id, opts \\ []) do
    opts = Keyword.put(opts, :base_url, @sheets_base_url)

    with {:ok, body} <- Client.get_json(account, "spreadsheets/#{enc(spreadsheet_id)}", opts) do
      {:ok, summary(body)}
    end
  end

  @doc "Read a range of values (`values.get`). Returns the 2-D value list."
  def get_values(%Account{} = account, spreadsheet_id, range, opts \\ []) do
    opts = Keyword.put(opts, :base_url, @sheets_base_url)
    path = "spreadsheets/#{enc(spreadsheet_id)}/values/#{enc(range)}"

    with {:ok, body} <- Client.get_json(account, path, opts) do
      {:ok, %{range: Map.get(body, "range"), values: Map.get(body, "values", []), raw: body}}
    end
  end

  @doc "Create a spreadsheet with a title (`spreadsheets.create`)."
  def create(%Account{} = account, title, opts \\ []) do
    opts = Keyword.put(opts, :base_url, @sheets_base_url)
    body = %{"properties" => %{"title" => title}}

    with {:ok, body} <- Client.post_json(account, "spreadsheets", body, opts) do
      {:ok, summary(body)}
    end
  end

  @doc "Overwrite a range with `values` (`values.update`, PUT)."
  def update_values(%Account{} = account, spreadsheet_id, range, values, opts \\ [])
      when is_list(values) do
    opts =
      opts
      |> Keyword.put(:base_url, @sheets_base_url)
      |> Keyword.put(:params, [{"valueInputOption", value_input(opts)}])

    path = "spreadsheets/#{enc(spreadsheet_id)}/values/#{enc(range)}"

    with {:ok, body} <-
           Client.put_json(account, path, %{"range" => range, "values" => values}, opts) do
      {:ok, body}
    end
  end

  @doc "Append `values` after a range/table (`values.append`)."
  def append_values(%Account{} = account, spreadsheet_id, range, values, opts \\ [])
      when is_list(values) do
    opts =
      opts
      |> Keyword.put(:base_url, @sheets_base_url)
      |> Keyword.put(:params, [{"valueInputOption", value_input(opts)}])

    path = "spreadsheets/#{enc(spreadsheet_id)}/values/#{enc(range)}:append"

    with {:ok, body} <- Client.post_json(account, path, %{"values" => values}, opts) do
      {:ok, body}
    end
  end

  @doc "Clear a range's values (`values.clear`)."
  def clear_values(%Account{} = account, spreadsheet_id, range, opts \\ []) do
    opts = Keyword.put(opts, :base_url, @sheets_base_url)
    path = "spreadsheets/#{enc(spreadsheet_id)}/values/#{enc(range)}:clear"

    with {:ok, body} <- Client.post_json(account, path, %{}, opts) do
      {:ok, body}
    end
  end

  @doc """
  Apply structural edit requests (`spreadsheets.batchUpdate`) — add/delete sheets,
  formatting, etc. `requests` is the raw Google request list.
  """
  def batch_update(%Account{} = account, spreadsheet_id, requests, opts \\ [])
      when is_list(requests) do
    opts = Keyword.put(opts, :base_url, @sheets_base_url)
    path = "spreadsheets/#{enc(spreadsheet_id)}:batchUpdate"

    with {:ok, body} <- Client.post_json(account, path, %{"requests" => requests}, opts) do
      {:ok, body}
    end
  end

  defp value_input(opts), do: Keyword.get(opts, :value_input_option, @default_value_input)

  defp summary(body) do
    %{
      spreadsheet_id: Map.get(body, "spreadsheetId"),
      title: get_in(body, ["properties", "title"]),
      spreadsheet_url: Map.get(body, "spreadsheetUrl"),
      raw: body
    }
  end

  defp enc(value), do: URI.encode_www_form(to_string(value))
end
