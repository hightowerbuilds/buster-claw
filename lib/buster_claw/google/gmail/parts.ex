defmodule BusterClaw.Google.Gmail.Parts do
  @moduledoc """
  MIME part traversal for Gmail API payloads — the tree half of the inbound seam.

  A `format=full` payload is a tree (`multipart/*` nests freely), and two
  readers walk it: `BusterClaw.Google.Gmail.Parser` to find the text and HTML
  bodies, and the attachment path to list files and decode the ones Gmail
  inlines as data. This module owns the walk, the header map, and base64url
  decoding so there is one definition of each; it performs no HTTP and never
  raises on shape (missing fields come back as `nil` or `[]`).
  """

  @doc "Flatten a payload into its leaf parts, in document order."
  def flatten(payload) do
    parts = Map.get(payload, "parts", [])

    if parts == [] do
      [payload]
    else
      Enum.flat_map(parts, &flatten/1)
    end
  end

  @doc "Lower-cased header name → value for a payload or part."
  def headers_map(part) do
    part
    |> Map.get("headers", [])
    |> Map.new(fn header ->
      {header |> Map.get("name", "") |> String.downcase(), Map.get(header, "value")}
    end)
  end

  @doc """
  List the attachment parts of a payload — every leaf part that carries a
  filename or an `attachmentId`, in document order.

  Each entry is metadata only (never bytes), so a parsed message stays JSON
  printable: `attachment_id` is what `Gmail.attachment/4` fetches. Gmail inlines
  small attachments as `body.data` instead of issuing an id, in which case
  `attachment_id` is `nil` and `inline_data?` is true — `inline_attachment_data/2`
  decodes those out of the raw message. `inline?` reflects the Content-Disposition
  (a photo pasted into the body is `inline`, and it is still the receipt the
  sender meant to send, so callers should not treat inline as "skip").
  """
  def attachments(payload) do
    payload
    |> flatten()
    |> Enum.filter(&attachment_part?/1)
    |> Enum.map(&attachment_entry/1)
  end

  @doc """
  Decode the bytes of an attachment Gmail delivered inline (`body.data`, no
  `attachmentId`), addressed by its `part_id` in the raw message. Returns `nil`
  when the part is missing or carries no data.
  """
  def inline_attachment_data(raw_message, part_id) when is_map(raw_message) do
    raw_message
    |> Map.get("payload", %{})
    |> flatten()
    |> Enum.find(&(Map.get(&1, "partId") == part_id))
    |> case do
      nil -> nil
      part -> part |> Map.get("body", %{}) |> Map.get("data") |> decode_base64url()
    end
  end

  def inline_attachment_data(_raw_message, _part_id), do: nil

  @doc "Decode Gmail's base64url body data (unpadded); `nil` when absent or malformed."
  def decode_base64url(nil), do: nil

  def decode_base64url(data) do
    data
    |> pad_base64()
    |> Base.url_decode64()
    |> case do
      {:ok, decoded} -> decoded
      :error -> nil
    end
  end

  defp pad_base64(data) do
    case rem(String.length(data), 4) do
      0 -> data
      missing -> data <> String.duplicate("=", 4 - missing)
    end
  end

  defp attachment_part?(part) do
    filename = Map.get(part, "filename")
    attachment_id = part |> Map.get("body", %{}) |> Map.get("attachmentId")

    (is_binary(filename) and filename != "") or
      (is_binary(attachment_id) and attachment_id != "")
  end

  defp attachment_entry(part) do
    body = Map.get(part, "body", %{})
    headers = headers_map(part)
    attachment_id = present(Map.get(body, "attachmentId"))

    %{
      part_id: Map.get(part, "partId"),
      attachment_id: attachment_id,
      filename: present(Map.get(part, "filename")),
      mime_type: Map.get(part, "mimeType"),
      size: Map.get(body, "size"),
      content_id: headers |> Map.get("content-id") |> strip_angle_brackets(),
      inline?: inline_disposition?(Map.get(headers, "content-disposition")),
      inline_data?: is_nil(attachment_id) and is_binary(present(Map.get(body, "data")))
    }
  end

  defp inline_disposition?(nil), do: false
  defp inline_disposition?(value), do: value |> String.downcase() |> String.starts_with?("inline")

  defp strip_angle_brackets(nil), do: nil

  defp strip_angle_brackets(value),
    do: value |> String.trim() |> String.trim("<") |> String.trim(">")

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value
end
