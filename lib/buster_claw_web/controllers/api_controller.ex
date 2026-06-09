defmodule BusterClawWeb.ApiController do
  @moduledoc """
  HTTP frontend for `BusterClaw.Commands`. See
  `docs/COMMAND_SURFACE.md` for the catalog.

  - `GET /api/commands` — catalog metadata (unauthenticated).
  - `POST /api/run` — invoke a command (Bearer token required).
  """

  use BusterClawWeb, :controller

  alias BusterClaw.Commands

  def commands(conn, _params) do
    catalog =
      Commands.list_commands()
      |> Enum.map(&serialize_catalog_entry/1)

    json(conn, %{ok: true, commands: catalog})
  end

  def run(conn, %{"command" => name} = params) do
    args = Map.get(params, "args", %{})
    caller = Map.get(conn.assigns, :caller, :trusted)

    case Commands.call(name, args, caller: caller) do
      {:ok, value} ->
        json(conn, %{ok: true, result: serialize(value)})

      {:error, :requires_confirmation} ->
        send_error(conn, 403, "requires_confirmation")

      {:error, :unknown_command} ->
        send_error(conn, 404, "unknown_command")

      {:error, :not_found} ->
        send_error(conn, 404, "not_found")

      {:error, :unauthorized} ->
        send_error(conn, 401, "unauthorized")

      {:error, :disabled} ->
        send_error(conn, 409, "disabled")

      {:error, :empty_query} ->
        send_error(conn, 400, "empty_query")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{
          ok: false,
          error: "validation",
          errors: changeset_errors(changeset)
        })

      {:error, reason} when is_atom(reason) ->
        send_error(conn, 400, to_string(reason))

      {:error, reason} ->
        send_error(conn, 500, BusterClawWeb.ErrorFormatter.format(reason))
    end
  end

  def run(conn, _params) do
    send_error(conn, 400, "missing command")
  end

  # ---- Helpers ----

  defp send_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{ok: false, error: message})
  end

  defp serialize_catalog_entry(%{args: args} = entry) do
    %{entry | args: stringify_keys(args)}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(map) when is_map(map), do: stringify_keys(map)
  defp stringify_value(other), do: other

  defp serialize(value), do: BusterClaw.Commands.Result.to_json(value)

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
