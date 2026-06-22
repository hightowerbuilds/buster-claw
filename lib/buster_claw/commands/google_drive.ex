defmodule BusterClaw.Commands.Google.Drive do
  @moduledoc """
  Google Drive command implementations: list/get, download/export to the
  workspace, folder/file create + upload, metadata update, copy, share, and
  delete.

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

  def drive_download(args) do
    with_file_id(args, fn account, file_id ->
      with {:ok, data} <- Drive.download(account, file_id),
           {:ok, dest} <- download_destination(account, file_id, args),
           :ok <- File.mkdir_p(Path.dirname(dest)),
           :ok <- File.write(dest, data) do
        {:ok, %{id: file_id, path: dest, bytes: byte_size(data)}}
      end
    end)
  end

  def drive_export(args) do
    mime_type = Map.get(args, "mime_type")

    with_file_id(args, fn account, file_id ->
      if mime_type in [nil, ""] do
        {:error, :missing_mime_type}
      else
        with {:ok, data} <- Drive.export(account, file_id, mime_type),
             {:ok, dest} <- download_destination(account, file_id, args),
             :ok <- File.mkdir_p(Path.dirname(dest)),
             :ok <- File.write(dest, data) do
          {:ok, %{id: file_id, path: dest, bytes: byte_size(data), mime_type: mime_type}}
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

  def drive_upload(args) do
    path = Map.get(args, "path")

    if path in [nil, ""] do
      {:error, :missing_path}
    else
      abs = resolve_workspace_path(path)

      case File.read(abs) do
        {:ok, data} ->
          with_google_account(args, fn account ->
            Drive.upload(account, %{
              "name" => Map.get(args, "name") || Path.basename(abs),
              "data" => data,
              "content_type" => Map.get(args, "content_type"),
              "parent_id" => Map.get(args, "parent_id")
            })
          end)

        {:error, reason} ->
          {:error, {:file_unreadable, abs, reason}}
      end
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

  # Where a Drive download/export is written. An explicit destination wins;
  # otherwise save under the workspace using the file's own name.
  defp download_destination(account, file_id, args) do
    case Map.get(args, "destination") do
      dest when is_binary(dest) and dest != "" ->
        {:ok, resolve_workspace_path(dest)}

      _ ->
        with {:ok, meta} <- Drive.get(account, file_id) do
          {:ok, resolve_workspace_path(meta.name || to_string(file_id))}
        end
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
