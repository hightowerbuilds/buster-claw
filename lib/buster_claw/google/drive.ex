defmodule BusterClaw.Google.Drive do
  @moduledoc "Google Drive read/write helpers for connected Google Workspace accounts."

  alias BusterClaw.Google.Account
  alias BusterClaw.Google.Client

  @drive_base_url "https://www.googleapis.com/drive/v3"
  @folder_mime "application/vnd.google-apps.folder"
  @file_fields "id,name,mimeType,parents,webViewLink,modifiedTime,size,trashed,starred"
  @list_fields "nextPageToken,files(#{@file_fields})"
  @default_page_size 50

  @doc "List/search files. `opts[:q]` is a Drive query; supports paging + ordering."
  def list(%Account{} = account, opts \\ []) do
    params =
      [
        {"pageSize", opts |> Keyword.get(:page_size, @default_page_size) |> to_string()},
        {"fields", @list_fields},
        {"spaces", Keyword.get(opts, :spaces, "drive")}
      ]
      |> put_present("q", Keyword.get(opts, :q))
      |> put_present("orderBy", Keyword.get(opts, :order_by))
      |> put_present("pageToken", Keyword.get(opts, :page_token))

    with {:ok, body} <- get(account, "files", params, opts) do
      {:ok,
       %{
         files: body |> Map.get("files", []) |> Enum.map(&file_summary/1),
         next_page_token: Map.get(body, "nextPageToken")
       }}
    end
  end

  @doc "Fetch a file's metadata."
  def get(%Account{} = account, file_id, opts \\ []) when is_binary(file_id) do
    with {:ok, body} <- get(account, "files/#{enc(file_id)}", [{"fields", @file_fields}], opts) do
      {:ok, file_summary(body)}
    end
  end

  @doc "Download raw file bytes (`alt=media`). Returns `{:ok, binary}`."
  def download(%Account{} = account, file_id, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:base_url, @drive_base_url)
      |> Keyword.put(:params, [{"alt", "media"}])
      |> Keyword.put(:decode, false)

    Client.get_json(account, "files/#{enc(file_id)}", opts)
  end

  @doc "Export a Google-native doc to `mime_type` (e.g. application/pdf). Returns `{:ok, binary}`."
  def export(%Account{} = account, file_id, mime_type, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:base_url, @drive_base_url)
      |> Keyword.put(:params, [{"mimeType", mime_type}])
      |> Keyword.put(:decode, false)

    Client.get_json(account, "files/#{enc(file_id)}/export", opts)
  end

  @doc "Create a folder."
  def create_folder(%Account{} = account, name, parent_id, opts \\ []) do
    metadata =
      %{"name" => name, "mimeType" => @folder_mime}
      |> put_parents(parent_id)

    opts = Keyword.put(opts, :base_url, @drive_base_url)

    with {:ok, body} <-
           Client.post_json(
             account,
             "files",
             metadata,
             Keyword.put(opts, :params, [{"fields", @file_fields}])
           ) do
      {:ok, file_summary(body)}
    end
  end

  @doc """
  Upload a file. `attrs` = `%{name, data, content_type, parent_id}` — `data` is the
  raw bytes. Sent as a `multipart/related` upload via `Client.upload/4`.
  """
  def upload(%Account{} = account, attrs, opts \\ []) when is_map(attrs) do
    metadata =
      %{"name" => Map.get(attrs, :name) || Map.get(attrs, "name")}
      |> put_parents(Map.get(attrs, :parent_id) || Map.get(attrs, "parent_id"))

    upload_attrs = %{
      metadata: metadata,
      data: Map.get(attrs, :data) || Map.get(attrs, "data"),
      content_type:
        Map.get(attrs, :content_type) || Map.get(attrs, "content_type") ||
          "application/octet-stream"
    }

    opts = Keyword.put(opts, :params, [{"fields", @file_fields}])

    with {:ok, body} <- Client.upload(account, "files", upload_attrs, opts) do
      {:ok, file_summary(body)}
    end
  end

  @doc """
  Update file metadata (rename, star) and/or move it. Pass `opts[:add_parents]` /
  `opts[:remove_parents]` to move (Drive requires these as query params).
  """
  def update_metadata(%Account{} = account, file_id, attrs, opts \\ []) when is_map(attrs) do
    params =
      [{"fields", @file_fields}]
      |> put_present("addParents", Keyword.get(opts, :add_parents))
      |> put_present("removeParents", Keyword.get(opts, :remove_parents))

    opts = opts |> Keyword.put(:base_url, @drive_base_url) |> Keyword.put(:params, params)

    with {:ok, body} <- Client.patch_json(account, "files/#{enc(file_id)}", attrs, opts) do
      {:ok, file_summary(body)}
    end
  end

  @doc "Copy a file. `attrs` may set name/parents on the copy."
  def copy(%Account{} = account, file_id, attrs, opts \\ []) when is_map(attrs) do
    opts =
      opts
      |> Keyword.put(:base_url, @drive_base_url)
      |> Keyword.put(:params, [{"fields", @file_fields}])

    with {:ok, body} <- Client.post_json(account, "files/#{enc(file_id)}/copy", attrs, opts) do
      {:ok, file_summary(body)}
    end
  end

  @doc "Delete a file (irreversible — bypasses the trash)."
  def delete(%Account{} = account, file_id, opts \\ []) do
    opts = Keyword.put(opts, :base_url, @drive_base_url)

    with {:ok, _} <- Client.delete(account, "files/#{enc(file_id)}", opts) do
      {:ok, %{id: to_string(file_id), deleted: true}}
    end
  end

  @doc """
  Share a file by granting a permission. `permission` = `%{role, type, emailAddress}`
  (e.g. role=reader/writer, type=user/anyone). Outbound — may email the grantee.
  """
  def share(%Account{} = account, file_id, permission, opts \\ []) when is_map(permission) do
    params =
      [{"sendNotificationEmail", to_string(Keyword.get(opts, :notify, false))}]

    opts = opts |> Keyword.put(:base_url, @drive_base_url) |> Keyword.put(:params, params)

    with {:ok, body} <-
           Client.post_json(account, "files/#{enc(file_id)}/permissions", permission, opts) do
      {:ok,
       %{
         id: Map.get(body, "id"),
         role: Map.get(body, "role"),
         type: Map.get(body, "type"),
         raw: body
       }}
    end
  end

  defp get(account, path, params, opts) do
    opts = opts |> Keyword.put(:base_url, @drive_base_url) |> Keyword.put(:params, params)
    Client.get_json(account, path, opts)
  end

  defp put_parents(metadata, parent_id) when parent_id in [nil, ""], do: metadata
  defp put_parents(metadata, parent_id), do: Map.put(metadata, "parents", [parent_id])

  defp put_present(params, _key, value) when value in [nil, ""], do: params
  defp put_present(params, key, value), do: params ++ [{key, to_string(value)}]

  defp file_summary(file) do
    %{
      id: Map.get(file, "id"),
      name: Map.get(file, "name"),
      mime_type: Map.get(file, "mimeType"),
      parents: Map.get(file, "parents", []),
      web_view_link: Map.get(file, "webViewLink"),
      modified_time: Map.get(file, "modifiedTime"),
      size: Map.get(file, "size"),
      trashed: Map.get(file, "trashed"),
      starred: Map.get(file, "starred"),
      raw: file
    }
  end

  defp enc(value), do: URI.encode_www_form(to_string(value))
end
