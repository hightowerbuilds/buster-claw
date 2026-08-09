defmodule BusterClawWeb.ErrorFormatter do
  @moduledoc """
  Convert internal error terms into user-safe strings.

  - Known shapes get a short, accurate summary.
  - Unknown shapes get a generic `"unexpected error"` and the full term is
    logged at `:warning` level. `Plug.RequestId` populates `request_id`
    metadata for HTTP requests, so the log line is grep-correlatable.

  Never call `inspect/1` on a value that may carry secrets — Ecto changesets
  may include `api_key` / `token` fields, Req structs may carry `Authorization`
  headers. Use this module instead of `inspect/1` in user-facing error paths.
  """

  require Logger

  @doc "Format an error term as a user-safe string."
  def format(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} ->
      "#{field} #{Enum.join(msgs, ", ")}"
    end)
  end

  def format({:bad_status, status}) when is_integer(status), do: "HTTP #{status}"
  def format({:bad_status, status, _body}) when is_integer(status), do: "HTTP #{status}"
  def format({:http_error, status, _body}) when is_integer(status), do: "HTTP #{status}"

  def format({:google_oauth_error, status, body}) when is_integer(status) do
    case google_oauth_message(body) do
      nil -> "Google OAuth HTTP #{status}"
      message -> "Google OAuth HTTP #{status}: #{message}"
    end
  end

  def format({:google_api_error, status, body}) when is_integer(status) do
    case google_oauth_message(body) do
      nil -> "Google API HTTP #{status}"
      message -> "Google API HTTP #{status}: #{message}"
    end
  end

  def format({:google_api_rate_limited, status, retry_after, _body}) when is_integer(status) do
    case retry_after do
      seconds when is_integer(seconds) ->
        "Google API rate limited (HTTP #{status}); retry after #{seconds}s"

      _ ->
        "Google API rate limited (HTTP #{status})"
    end
  end

  # Browser text targeting refused to guess between several matching elements.
  # The count is deliberate and the labels are deliberately absent: labels are
  # page content, and an error path is not egress-accounted. Point the caller at
  # the primitives that are.
  def format({:ambiguous_text, count}) when is_integer(count) do
    "text target matched #{count} elements — refusing to guess. " <>
      "Use a `selector`, or call `find_elements`/`extract` to disambiguate first."
  end

  # A failure reported by the desktop JS bridge, wrapped by
  # `BrowserCommandController`. The string is the bridge's own message and is
  # already capped at 200 chars there, so passing it through adds no egress the
  # cap did not already bound.
  #
  # There was no clause here until 08-08, which meant this tuple fell to the
  # fallback and EVERY desktop-side browser failure rendered as "unexpected
  # error" — the controller truncated a real diagnosis specifically so it could
  # be shown, and the formatter dropped it. The message survived only as a
  # :warning on stdout, which under `tauri dev` is terminal scrollback, not a
  # file. Found in the field, after it cost a multi-probe investigation and an
  # unnecessary detour onto Agent Mode.
  def format({:browser_failed, msg}) when is_binary(msg), do: "browser: #{msg}"

  def format({:missing_config, key}), do: "missing config: #{key}"
  def format({:unexpected_response, _body}), do: "unexpected response from upstream"

  def format(:not_found), do: "not found"
  def format(:unauthorized), do: "unauthorized"
  def format(:disabled), do: "disabled"
  def format(:empty_query), do: "query is empty"
  def format(:timeout), do: "request timed out"
  def format(:closed), do: "connection closed"
  def format(:econnrefused), do: "connection refused"
  def format(:nxdomain), do: "domain not found"
  def format(:ehostunreach), do: "host unreachable"
  def format(:enetunreach), do: "network unreachable"
  def format(:max_tool_iterations), do: "tool-use loop exceeded maximum iterations"
  def format(:unknown_command), do: "unknown command"

  def format(atom) when is_atom(atom), do: humanize_atom(atom)

  # Req transport errors carry a `:reason` atom that's safe to format.
  def format(%{__struct__: Req.TransportError, reason: reason}) do
    "transport error: #{format(reason)}"
  end

  # Req HTTPError — don't deep-inspect, may carry headers
  def format(%{__struct__: Req.HTTPError}), do: "HTTP error"

  def format(binary) when is_binary(binary), do: binary

  def format(reason) do
    log_unknown(reason)
    "unexpected error"
  end

  defp humanize_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp google_oauth_message(body) when is_map(body) do
    error = Map.get(body, "error") || Map.get(body, :error)
    description = Map.get(body, "error_description") || Map.get(body, :error_description)

    case {error, description} do
      {"invalid_client", description} when is_binary(description) ->
        "invalid client. Re-check that the client ID and client secret came from the same Desktop app OAuth client. Google said: #{description}"

      {error, description} when is_binary(error) and is_binary(description) ->
        "#{error}: #{description}"

      {error, _description} when is_binary(error) ->
        error

      _other ->
        nil
    end
  end

  defp google_oauth_message(_body), do: nil

  defp log_unknown(reason) do
    Logger.warning(fn ->
      "[error_formatter] unknown error shape: " <>
        inspect(reason, limit: 50, printable_limit: 500)
    end)
  end
end
