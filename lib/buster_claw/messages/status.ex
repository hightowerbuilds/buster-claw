defmodule BusterClaw.Messages.Status do
  @moduledoc """
  Redacted readiness for the pinned Messages adapter.

  Database access is not proof of an online Apple account or permission to send.
  Raw adapter errors, paths, account data, and private-bridge capabilities never
  leave this boundary. Only the ordinary read surface is considered here.
  """

  @version "0.15.6"
  @read_methods ~w(chats.list messages.history watch.subscribe)

  def version, do: @version

  def from_rpc(%{"version" => @version, "protocol_version" => 1} = result) do
    case result do
      %{"database" => %{"ready" => ready}, "methods" => methods}
      when is_boolean(ready) and is_list(methods) ->
        classify(ready, methods)

      _ ->
        {:error, :invalid_status}
    end
  end

  def from_rpc(%{"version" => version}) when version != @version,
    do: {:error, :unsupported_version}

  def from_rpc(%{"protocol_version" => protocol}) when protocol != 1,
    do: {:error, :unsupported_protocol}

  def from_rpc(_), do: {:error, :invalid_status}

  defp classify(ready, methods) do
    cond do
      not Enum.all?(methods, &is_binary/1) ->
        {:error, :invalid_status}

      ready and not Enum.all?(@read_methods, &(&1 in methods)) ->
        {:error, :missing_read_capabilities}

      true ->
        {:ok,
         %{
           adapter: "imsg",
           version: @version,
           protocol_version: 1,
           state: if(ready, do: :read_ready, else: :database_unavailable),
           read_ready: ready,
           send_ready: false,
           send_state: :not_tested
         }}
    end
  end
end
