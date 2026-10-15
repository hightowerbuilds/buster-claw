defmodule BusterClaw.Commands.Google.Drive do
  @moduledoc """
  Google Drive command implementations: list/get, download/export to the
  workspace, folder/file create + upload, metadata update, copy, share, and
  delete.

  Every path a caller names — a download/export `destination`, an upload
  source — goes through `Helpers.fenced_workspace_path/1`. Until 10-14 none of
  them did: an absolute destination could overwrite any file the app could
  write, and an upload could read (and ship to Drive) any file it could read.

  Account resolution funnels through
  `BusterClaw.Commands.Google.Accounts.with_google_account/2`. Each function keeps
  the canonical `{:ok, _} | {:error, reason}` contract and takes a single
  string-keyed args map.
  """

  import BusterClaw.Commands.Helpers

  import BusterClaw.Commands.Google.Accounts,
    only: [with_google_account: 2, truthy?: 1, put_attr: 3, put_opt: 3, confirmed?: 2]

  alias BusterClaw.Google.Drive

  def drive_list(args \\ %{}) do
    with_google_account(args, fn account ->
      Drive.list(account,
        q: Map.get(args, "q"),
        order_by: Map.get(args, "order_by"),
        page_size: Map.get(args, "page_size", 50),
        page_token: Map.get(args, "page_token")
      )
    end)
  end

  def drive_get(args) do
    with_file_id(args, fn account, file_id ->
      Drive.get(account, file_id)
    end)
  end

  @google_native_prefix "application/vnd.google-apps."

  @doc """
  Download a Drive file's bytes into the workspace. Metadata is fetched first so
  a Google-native file (Docs/Sheets/Slides — Drive refuses `alt=media` for
  those with a 403) is turned away with a pointer to `drive_export` instead of
  an opaque API error, and so the default filename is the file's own name.
  """
  def drive_download(args) do
    with_file_id(args, fn account, file_id ->
      with {:ok, meta} <- Drive.get(account, file_id),
           :ok <- downloadable(meta),
           {:ok, dest} <- download_destination(meta, args, ""),
           {:ok, data} <- Drive.download(account, file_id) do
        write_download(dest, data, %{id: file_id, name: meta.name, mime_type: meta.mime_type})
      end
    end)
  end

  @doc """
  Export a Google-native file to `mime_type` and save it in the workspace. The
  default filename is the file's own name plus the extension that MIME type
  implies, so "Q3 invoice" exported as PDF lands as `Q3_invoice.pdf`.
  """
  def drive_export(args) do
    mime_type = Map.get(args, "mime_type")

    with_file_id(args, fn account, file_id ->
      if mime_type in [nil, ""] do
        {:error, :missing_mime_type}
      else
        with {:ok, meta} <- Drive.get(account, file_id),
             {:ok, dest} <- download_destination(meta, args, export_extension(mime_type)),
             {:ok, data} <- Drive.export(account, file_id, mime_type) do
          write_download(dest, data, %{id: file_id, name: meta.name, mime_type: mime_type})
        end
      end
    end)
  end

  def drive_folder_create(args) do
    if Map.get(args, "name") in [nil, ""] do
      {:error, :missing_name}
    else
      with_google_account(args, fn account ->
        Drive.create_folder(
          account,
          Map.get(args, "name"),
          Map.get(args, "parent_id")
        )
      end)
    end
  end

  # The source path is fenced: an upload is the one Drive verb where an unfenced
  # read becomes an exfiltration (name `~/.ssh/id_ed25519` and it leaves the
  # machine), exactly the case `Gmail.Mime`'s attachment fence exists for.
  def drive_upload(args) do
    path = Map.get(args, "path")

    if path in [nil, ""] do
      {:error, :missing_path}
    else
      with {:ok, abs} <- fenced_workspace_path(path),
           {:ok, data} <- read_upload(abs) do
        with_google_account(args, fn account ->
          Drive.upload(account, %{
            "name" => Map.get(args, "name") || Path.basename(abs),
            "data" => data,
            "content_type" => Map.get(args, "content_type"),
            "parent_id" => Map.get(args, "parent_id")
          })
        end)
      end
    end
  end

  defp read_upload(abs) do
    case File.read(abs) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:file_unreadable, abs, reason}}
    end
  end

  def drive_update(args) do
    with_file_id(args, fn account, file_id ->
      opts =
        []
        |> put_opt(:add_parents, Map.get(args, "add_parents"))
        |> put_opt(:remove_parents, Map.get(args, "remove_parents"))

      Drive.update_metadata(account, file_id, drive_update_attrs(args), opts)
    end)
  end

  def drive_copy(args) do
    with_file_id(args, fn account, file_id ->
      attrs =
        %{}
        |> put_attr("name", Map.get(args, "name"))
        |> put_parents_attr(Map.get(args, "parent_id"))

      Drive.copy(account, file_id, attrs)
    end)
  end

  def drive_share(args) do
    cond do
      not confirmed?(args, "confirm_share") ->
        {:error, :missing_confirmation}

      Map.get(args, "role") in [nil, ""] ->
        {:error, :missing_role}

      Map.get(args, "type") in [nil, ""] ->
        {:error, :missing_type}

      true ->
        with_file_id(args, fn account, file_id ->
          permission =
            %{"role" => Map.get(args, "role"), "type" => Map.get(args, "type")}
            |> put_attr("emailAddress", Map.get(args, "grantee_email"))

          Drive.share(account, file_id, permission,
            notify: truthy?(Map.get(args, "notify", false))
          )
        end)
    end
  end

  def drive_delete(args) do
    with_file_id(args, fn account, file_id ->
      Drive.delete(account, file_id)
    end)
  end

  defp with_file_id(args, fun) do
    file_id = Map.get(args, "file_id") || Map.get(args, "id")

    if file_id in [nil, ""] do
      {:error, :missing_file_id}
    else
      with_google_account(args, fn account -> fun.(account, file_id) end)
    end
  end

  defp downloadable(%{mime_type: mime_type}) when is_binary(mime_type) do
    if String.starts_with?(mime_type, @google_native_prefix) do
      {:error, {:google_native_file, mime_type}}
    else
      :ok
    end
  end

  defp downloadable(_meta), do: :ok

  # Where a Drive download/export is written. An explicit destination wins and
  # is fenced to the workspace; otherwise the file's own name (a Drive-side
  # string, reduced to a safe basename — a file named `../../.zshrc` is just a
  # file) plus `ext` lands at the workspace root.
  defp download_destination(meta, args, ext) do
    case Map.get(args, "destination") do
      dest when is_binary(dest) and dest != "" ->
        fenced_workspace_path(dest)

      _ ->
        name = sanitize_download_name(meta.name || meta.id || "download")
        fenced_workspace_path(with_extension(name, ext))
    end
  end

  defp with_extension(name, ""), do: name

  defp with_extension(name, ext) do
    if String.downcase(Path.extname(name)) == ext, do: name, else: name <> ext
  end

  defp write_download(dest, data, info) do
    with :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- File.write(dest, data) do
      {:ok,
       Map.merge(info, %{
         path: Path.relative_to(dest, BusterClaw.Library.Artifact.workspace_root()),
         absolute_path: dest,
         bytes: byte_size(data)
       })}
    end
  end

  # The extension a Drive export MIME type implies. A flat table, not logic.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp export_extension(mime_type) do
    case mime_type do
      "application/pdf" -> ".pdf"
      "text/plain" -> ".txt"
      "text/csv" -> ".csv"
      "text/html" -> ".html"
      "text/markdown" -> ".md"
      "application/rtf" -> ".rtf"
      "application/epub+zip" -> ".epub"
      "application/zip" -> ".zip"
      "image/png" -> ".png"
      "image/jpeg" -> ".jpg"
      "image/svg+xml" -> ".svg"
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> ".docx"
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -> ".xlsx"
      "application/vnd.openxmlformats-officedocument.presentationml.presentation" -> ".pptx"
      "application/vnd.oasis.opendocument.text" -> ".odt"
      "application/vnd.oasis.opendocument.spreadsheet" -> ".ods"
      "application/vnd.oasis.opendocument.presentation" -> ".odp"
      _other -> ""
    end
  end

  defp drive_update_attrs(args) do
    %{}
    |> put_attr("name", Map.get(args, "name"))
    |> put_starred(Map.get(args, "starred"))
  end

  defp put_starred(attrs, nil), do: attrs
  defp put_starred(attrs, value), do: Map.put(attrs, "starred", truthy?(value))

  defp put_parents_attr(attrs, parent_id) when parent_id in [nil, ""], do: attrs
  defp put_parents_attr(attrs, parent_id), do: Map.put(attrs, "parents", [parent_id])
end
