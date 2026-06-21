defmodule BusterClawWeb.ApiController do
  @moduledoc """
  HTTP frontend for `BusterClaw.Commands`. See
  `docs/COMMAND_SURFACE.md` for the catalog.

  - `GET /api/commands` — catalog metadata (unauthenticated).
  - `POST /api/run` — invoke a command (Bearer token required).
  """

  use BusterClawWeb, :controller

  alias BusterClaw.Commands

  @serialized_catalog_key {__MODULE__, :serialized_catalog}

  def commands(conn, _params) do
    json(conn, %{ok: true, commands: serialized_catalog() ++ serialized_skills()})
  end

  # The native catalog is immutable, so its JSON-ready/string-keyed form is
  # stringified once and cached in :persistent_term. Composition skills are
  # runtime-discovered files, so they are serialized fresh per request (cheap, and
  # there is no cache to invalidate when a skill file is added/removed).
  defp serialized_catalog do
    case :persistent_term.get(@serialized_catalog_key, :miss) do
      :miss ->
        catalog = Enum.map(Commands.list_commands(), &serialize_catalog_entry/1)
        :persistent_term.put(@serialized_catalog_key, catalog)
        catalog

      catalog ->
        catalog
    end
  end

  defp serialized_skills, do: Enum.map(Commands.list_skills(), &serialize_catalog_entry/1)

  def run(conn, %{"command" => name} = params) do
    args = Map.get(params, "args", %{})
    caller = Map.get(conn.assigns, :caller, :trusted)

    case Commands.call(name, args, caller: caller) do
      {:ok, value} ->
        json(conn, %{ok: true, result: serialize(value)})

      {:error, :requires_confirmation} ->
        send_error(conn, 403, "requires_confirmation")

      {:error, :policy_blocked} ->
        send_error(conn, 403, "policy_blocked")

      {:error, :rate_limited} ->
        send_error(conn, 429, "rate_limited")

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

  # Every entry carries a `source` (`native | composition`) so consumers can tell a
  # built-in command from a runtime-added skill. Native entries don't set it.
  defp serialize_catalog_entry(%{args: args} = entry) do
    entry |> Map.put_new(:source, :native) |> Map.put(:args, stringify_keys(args))
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
