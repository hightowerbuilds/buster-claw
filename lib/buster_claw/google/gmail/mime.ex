defmodule BusterClaw.Google.Gmail.Mime do
  @moduledoc """
  Composes the RFC 5322 / MIME bytes for outbound Gmail drafts and sends.

  Owns everything between a caller's `attrs` map and the raw message string that
  `Gmail.create_draft/3` and `Gmail.send_message/3` hand to Google: header
  selection and normalization, the single-part vs `multipart/mixed` decision,
  attachment loading, and base64 part encoding. It performs no HTTP.

  Two rules in here are load-bearing security code, not tidiness. Outbound email
  is an exfiltration channel — anything this module reads or writes leaves the
  machine. Do not relax either one:

    * **The attachment fence.** `resolve_attachment_path/1` refuses any path that
      does not resolve inside the workspace root, via
      `BusterClaw.FileManager.within?/2` (which canonicalizes through symlinks).
      Without it, a caller — or a prompt-injected draft flow — naming
      `~/.ssh/id_ed25519` would simply mail it.

    * **MIME header sanitization.** `render_attachment_part/1` strips CR, LF and
      `"` from the caller-supplied filename and content type before they are
      interpolated into header lines. A CRLF there terminates the header and
      injects arbitrary ones (a `Bcc:` to an attacker); a quote escapes the
      quoted parameter.

  Both are covered by tests in `test/buster_claw/google/gmail_test.exs`.
  """

  alias BusterClaw.Library.Artifact

  @doc """
  Build the raw MIME message for `attrs`.

  Returns `{:ok, mime}` or an error tuple describing the first missing or
  unusable input (`:missing_recipient`, `:missing_subject`, `:missing_body`,
  `:missing_attachment_path`, `{:attachment_outside_workspace, abs}`,
  `{:attachment_unreadable, abs, reason}`, `:invalid_attachment`).
  """
  def message_mime(attrs) do
    with {:ok, to} <- required_header(attrs, "to", :missing_recipient),
         {:ok, subject} <- required_header(attrs, "subject", :missing_subject),
         {:ok, body} <- required_body(attrs),
         {:ok, attachments} <- load_attachments(attrs) do
      base_headers =
        [
          {"To", to},
          optional_header("Cc", attrs, "cc"),
          optional_header("Bcc", attrs, "bcc"),
          optional_header("In-Reply-To", attrs, "in_reply_to"),
          optional_header("References", attrs, "references"),
          {"Subject", subject},
          {"MIME-Version", "1.0"}
        ]
        |> Enum.reject(&is_nil/1)

      {:ok, render_mime(base_headers, body, attachments)}
    end
  end

  # No attachments: a plain single-part text/plain message (backward compatible).
  defp render_mime(base_headers, body, []) do
    render_headers(base_headers ++ [{"Content-Type", ~s(text/plain; charset="UTF-8")}]) <>
      "\r\n\r\n" <> body
  end

  # With attachments: a multipart/mixed message — text body first, then each file.
  defp render_mime(base_headers, body, attachments) do
    boundary = mime_boundary()

    top =
      render_headers(
        base_headers ++ [{"Content-Type", ~s(multipart/mixed; boundary="#{boundary}")}]
      )

    body_part =
      render_headers([{"Content-Type", ~s(text/plain; charset="UTF-8")}]) <> "\r\n\r\n" <> body

    parts = [body_part | Enum.map(attachments, &render_attachment_part/1)]

    encoded_parts =
      Enum.map_join(parts, "", fn part -> "--#{boundary}\r\n" <> part <> "\r\n" end)

    top <> "\r\n\r\n" <> encoded_parts <> "--#{boundary}--\r\n"
  end

  defp render_attachment_part(%{filename: filename, content_type: content_type, data: data}) do
    encoded = data |> Base.encode64() |> chunk_base64()

    # Both values are caller-supplied and land inside header lines: a CRLF in
    # either would terminate the header and inject arbitrary ones, and a `"` in
    # the filename would escape its quoted parameter. Stripped rather than
    # escaped — no legitimate filename or MIME type carries any of them.
    filename = String.replace(filename, ~r/[\r\n"]/, "")
    content_type = String.replace(content_type, ~r/[\r\n]/, "")

    render_headers([
      {"Content-Type", ~s(#{content_type}; name="#{filename}")},
      {"Content-Transfer-Encoding", "base64"},
      {"Content-Disposition", ~s(attachment; filename="#{filename}")}
    ]) <> "\r\n\r\n" <> encoded
  end

  defp render_headers(headers) do
    headers
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("\r\n", fn {key, value} -> "#{key}: #{value}" end)
  end

  # RFC 2045 caps base64 lines at 76 characters.
  defp chunk_base64(encoded) do
    encoded
    |> String.to_charlist()
    |> Enum.chunk_every(76)
    |> Enum.map_join("\r\n", &List.to_string/1)
  end

  defp mime_boundary do
    "=_bc_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end

  defp load_attachments(attrs) do
    attrs
    |> get_attr("attachments")
    |> normalize_attachment_list()
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case load_attachment(spec) do
        {:ok, attachment} -> {:cont, {:ok, [attachment | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp normalize_attachment_list(nil), do: []
  defp normalize_attachment_list(list) when is_list(list), do: list
  defp normalize_attachment_list(single), do: [single]

  defp load_attachment(path) when is_binary(path), do: load_attachment(%{"path" => path})

  defp load_attachment(%{} = spec) do
    with {:ok, abs} <- resolve_attachment_path(spec_path(spec)),
         {:ok, data} <- read_attachment(abs) do
      filename = spec_filename(spec) || Path.basename(abs)
      content_type = spec_content_type(spec) || guess_content_type(filename)
      {:ok, %{filename: filename, content_type: content_type, data: data}}
    end
  end

  defp load_attachment(_other), do: {:error, :invalid_attachment}

  defp spec_path(spec),
    do: nilify(Map.get(spec, "path") || Map.get(spec, "file") || Map.get(spec, "filepath"))

  defp spec_filename(spec), do: nilify(Map.get(spec, "filename") || Map.get(spec, "name"))

  defp spec_content_type(spec),
    do: nilify(Map.get(spec, "content_type") || Map.get(spec, "mime_type"))

  defp resolve_attachment_path(nil), do: {:error, :missing_attachment_path}
  defp resolve_attachment_path(""), do: {:error, :missing_attachment_path}

  # Attachments may only come from inside the workspace. Outbound email is the
  # one channel where an unfenced read becomes an exfiltration — a caller (or a
  # prompt-injected draft flow) naming `~/.ssh/id_ed25519` here would mail it —
  # and every other file-reaching surface in the app fences the same way.
  # `FileManager.within?/2` canonicalizes through symlinks, so a link planted
  # inside the workspace cannot smuggle a path outside it.
  defp resolve_attachment_path(path) do
    root = Artifact.workspace_root()

    expanded =
      case Path.type(path) do
        :absolute -> Path.expand(path)
        _relative -> Path.expand(path, root)
      end

    if BusterClaw.FileManager.within?(expanded, root) do
      {:ok, expanded}
    else
      {:error, {:attachment_outside_workspace, expanded}}
    end
  end

  defp read_attachment(abs) do
    case File.read(abs) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:attachment_unreadable, abs, reason}}
    end
  end

  # A flat extension→MIME lookup table. Cyclomatic complexity counts each branch
  # as a decision, but there is no decision here — adding a file type is not
  # added complexity. The metric is measuring the wrong thing; don't "fix" this
  # by splitting the table.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp guess_content_type(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".pdf" -> "application/pdf"
      ".html" -> "text/html"
      ".htm" -> "text/html"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".csv" -> "text/csv"
      ".json" -> "application/json"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".doc" -> "application/msword"
      ".docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      ".xls" -> "application/vnd.ms-excel"
      ".xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      ".zip" -> "application/zip"
      _ -> "application/octet-stream"
    end
  end

  defp nilify(""), do: nil
  defp nilify(value), do: value

  defp required_header(attrs, key, error) do
    case header_value(get_attr(attrs, key)) do
      "" -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp optional_header(label, attrs, key) do
    case header_value(get_attr(attrs, key)) do
      "" -> nil
      value -> {label, value}
    end
  end

  defp required_body(attrs) do
    case get_attr(attrs, "body") do
      value when value in [nil, ""] -> {:error, :missing_body}
      value -> {:ok, to_string(value)}
    end
  end

  @doc """
  Read one logical attribute out of a caller `attrs` map, tolerating string or
  atom keys and the accepted aliases for each field.

  Public because `Gmail` reads the same maps for non-MIME purposes (thread ids,
  label lists) and there must be exactly one definition of what a key means.
  """
  # Same shape as guess_content_type/1: a flat key→attribute lookup, not branching
  # logic. Left as one readable table on purpose.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def get_attr(attrs, key) when is_binary(key) do
    case key do
      "to" ->
        Map.get(attrs, "to") || Map.get(attrs, :to) || Map.get(attrs, "recipient") ||
          Map.get(attrs, :recipient)

      "cc" ->
        Map.get(attrs, "cc") || Map.get(attrs, :cc)

      "bcc" ->
        Map.get(attrs, "bcc") || Map.get(attrs, :bcc)

      "subject" ->
        Map.get(attrs, "subject") || Map.get(attrs, :subject)

      "body" ->
        Map.get(attrs, "body") || Map.get(attrs, :body)

      "in_reply_to" ->
        Map.get(attrs, "in_reply_to") || Map.get(attrs, :in_reply_to)

      "references" ->
        Map.get(attrs, "references") || Map.get(attrs, :references)

      "thread_id" ->
        Map.get(attrs, "thread_id") || Map.get(attrs, :thread_id)

      _other ->
        Map.get(attrs, key)
    end
  end

  @doc """
  Normalize a value into a single-line header value: lists are joined with
  `", "`, and CR/LF runs collapse to a space so a caller-supplied value can
  never open a header line of its own. Returns `""` when there is no value.

  Public for the same reason as `get_attr/2` — `Gmail` normalizes the thread id
  with it before putting it on the wire.
  """
  def header_value(nil), do: ""

  def header_value(values) when is_list(values) do
    values
    |> Enum.map(&header_value/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  def header_value(value) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.trim()
  end
end
