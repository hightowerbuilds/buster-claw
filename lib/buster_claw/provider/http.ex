defmodule BusterClaw.Provider.HTTP do
  @moduledoc false

  def post(url, options) do
    req_options = Application.get_env(:buster_claw, :provider_req_options, [])

    url
    |> Req.post(Keyword.merge(options, req_options))
    |> normalize_response()
  end

  defp normalize_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp normalize_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp normalize_response({:error, reason}), do: {:error, reason}
end
