defmodule BusterClaw.Appearance do
  @moduledoc """
  Global appearance preferences that are richer than a plain `Settings` value —
  currently the user-uploaded terminal background image.

  The image bytes live under `<workspace>/appearance/` (writable in both dev and
  the packaged release, unlike the read-only `priv/static` bundle).
  `BusterClaw.Settings` holds the relative path plus an `updated_at` stamp used
  to cache-bust the served URL, and `BusterClawWeb.AppearanceController` streams
  the file back to the webview.

  A single global image is intentional: in a split pane both terminals share one
  continuous background painted on the split container (see `SplitLive`), so
  there is only ever one image to store.
  """

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Settings

  @path_key "terminal_background_path"
  @stamp_key "terminal_background_updated_at"
  @subdir "appearance"
  @basename "terminal-background"
  @topic "appearance:terminal_background"

  # Accepted upload extensions mapped to the content-type used when serving.
  @content_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".gif" => "image/gif"
  }

  @doc "PubSub topic broadcast when the terminal background changes."
  def topic, do: @topic

  @doc "Upload extensions accepted by the picker (`allow_upload` `:accept`)."
  def accepted_extensions, do: Map.keys(@content_types)

  @doc "Absolute path to the appearance directory under the workspace."
  def dir, do: Path.join(Artifact.workspace_root(), @subdir)

  @doc """
  The current terminal background as `%{path: abs_path, url: served_url}`, or
  `nil` when none is configured or the stored file has gone missing.
  """
  def terminal_background do
    with path when is_binary(path) <- present(Settings.get(@path_key)),
         abs = Path.join(Artifact.workspace_root(), path),
         true <- File.regular?(abs) do
      %{path: abs, url: terminal_background_url()}
    else
      _ -> nil
    end
  end

  @doc "Served URL (with cache-busting stamp) or `nil` when unset."
  def terminal_background_url do
    case present(Settings.get(@path_key)) do
      nil -> nil
      _path -> "/appearance/terminal-background?v=#{Settings.get(@stamp_key, "0")}"
    end
  end

  @doc """
  Persist an uploaded image as the terminal background. `src_path` is a readable
  file (e.g. a LiveView upload temp path); `client_name` supplies the extension.
  Returns `{:ok, url}` or `{:error, :unsupported_type}`.
  """
  def put_terminal_background(src_path, client_name) do
    ext = client_name |> Path.extname() |> String.downcase()

    case Map.has_key?(@content_types, ext) do
      true ->
        File.mkdir_p!(dir())
        # Drop any prior image (possibly a different extension) so only one wins.
        clear_files()
        dest = Path.join(dir(), @basename <> ext)
        File.cp!(src_path, dest)

        Settings.put(@path_key, Path.relative_to(dest, Artifact.workspace_root()))
        Settings.put(@stamp_key, stamp())

        url = terminal_background_url()
        broadcast(url)
        {:ok, url}

      false ->
        {:error, :unsupported_type}
    end
  end

  @doc "Remove the terminal background image and clear its settings."
  def clear_terminal_background do
    clear_files()
    Settings.delete(@path_key)
    Settings.delete(@stamp_key)
    broadcast(nil)
    :ok
  end

  @doc "Content-type for a stored image path, by extension."
  def content_type(path) do
    ext = path |> Path.extname() |> String.downcase()
    Map.get(@content_types, ext, "application/octet-stream")
  end

  defp clear_files do
    Enum.each(accepted_extensions(), fn ext ->
      File.rm(Path.join(dir(), @basename <> ext))
    end)
  end

  defp broadcast(url) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:terminal_background, url})
  end

  defp stamp, do: Integer.to_string(System.system_time(:second))

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value
end
