defmodule BusterClaw.Commands.Google do
  @moduledoc """
  Google Workspace command implementations: account CRUD, Gmail, Calendar,
  Tasks, Drive, Docs/Sheets/Slides, and Contacts.

  Extracted from the `BusterClaw.Commands` facade, which delegates to these
  functions (via `defdelegate`) so dispatch, policy, and rate-limiting still
  funnel through the single `Commands.call/2` choke point. Every function keeps
  the canonical `{:ok, _} | {:error, reason}` contract and takes a single
  string-keyed args map.

  The account-resolution cluster (`with_google_account/2` and friends) is private
  here: each command resolves the target account (explicit `account_id`/`email`,
  else the default account) before calling the relevant `BusterClaw.Google.*`
  client.
  """

  import BusterClaw.Commands.Helpers

  alias BusterClaw.Google

  alias BusterClaw.Google.{
    Calendar,
    CalendarSync,
    Docs,
    Drive,
    Gmail,
    GmailSync,
    People,
    Sheets,
    Slides,
    Tasks
  }

  # -----------------------------------------------------------------------
  # Google Workspace accounts
  # -----------------------------------------------------------------------

  def google_account_list(_args \\ %{}), do: {:ok, Google.list_account_summaries()}

  def google_account_get(%{"id" => id}) do
    with_resource(Google, :get_account!, id, fn account ->
      {:ok, Google.account_summary(account)}
    end)
  end

  def google_account_create(args) do
    case Google.create_account(args) do
      {:ok, account} -> {:ok, Google.account_summary(account)}
      other -> other
    end
  end

  def google_account_update(%{"id" => id} = args) do
    with_resource(Google, :get_account!, id, fn account ->
      case Google.update_account(account, Map.delete(args, "id")) do
        {:ok, account} -> {:ok, Google.account_summary(account)}
        other -> other
      end
    end)
  end

  def google_account_delete(%{"id" => id}) do
    with_resource(Google, :get_account!, id, fn account ->
      case Google.delete_account(account) do
        {:ok, account} -> {:ok, Google.account_summary(account)}
        other -> other
      end
    end)
  end

  def gmail_label_list(args \\ %{}) do
    with_google_account(args, fn account ->
      Gmail.labels(account)
    end)
  end

  def gmail_search(args) do
    with_google_account(args, fn account ->
      query = Map.get(args, "query") || account.default_query || "newer_than:7d"
      limit = Map.get(args, "limit", 10)
      Gmail.search(account, query, limit: limit)
    end)
  end

  def gmail_read(args) do
    message_id = Map.get(args, "message_id") || Map.get(args, "id")

    if message_id in [nil, ""] do
      {:error, :missing_message_id}
    else
      with_google_account(args, fn account ->
        Gmail.read(account, message_id)
      end)
    end
  end

  def gmail_sync(args) do
    with_google_account(args, fn account ->
      query = Map.get(args, "query") || account.default_query || "newer_than:7d"
      limit = Map.get(args, "limit", 10)

      GmailSync.sync(account,
        query: query,
        limit: limit,
        incremental: truthy?(Map.get(args, "incremental", false)),
        start_history_id: Map.get(args, "start_history_id")
      )
    end)
  end

  def gmail_draft_create(args) do
    with_google_account(args, fn account ->
      Gmail.create_draft(account, args)
    end)
  end

  def gmail_send(args) do
    if send_confirmed?(args) do
      with_google_account(args, fn account ->
        Gmail.send_message(account, args)
      end)
    else
      {:error, :missing_send_confirmation}
    end
  end

  def google_calendar_sync(args) do
    with_google_account(args, fn account ->
      CalendarSync.sync(account,
        calendar_id: Map.get(args, "calendar_id", "primary"),
        days_ahead: Map.get(args, "days_ahead", 90),
        force_full?: truthy?(Map.get(args, "force_full", false))
      )
    end)
  end

  def gmail_modify(args) do
    with_message_id(args, fn account, message_id ->
      Gmail.modify(account, message_id, args)
    end)
  end

  def gmail_trash(args) do
    with_message_id(args, fn account, message_id ->
      Gmail.trash(account, message_id)
    end)
  end

  def gmail_delete(args) do
    with_message_id(args, fn account, message_id ->
      Gmail.delete(account, message_id)
    end)
  end

  def gcal_event_create(args) do
    event = Map.get(args, "event")

    if is_map(event) do
      with_google_account(args, fn account ->
        Calendar.create_event(
          account,
          Map.get(args, "calendar_id", "primary"),
          event
        )
      end)
    else
      {:error, :missing_event}
    end
  end

  def gcal_event_update(args) do
    event = Map.get(args, "event")
    event_id = Map.get(args, "event_id") || Map.get(args, "id")

    cond do
      event_id in [nil, ""] ->
        {:error, :missing_event_id}

      not is_map(event) ->
        {:error, :missing_event}

      true ->
        with_google_account(args, fn account ->
          Calendar.update_event(
            account,
            Map.get(args, "calendar_id", "primary"),
            event_id,
            event
          )
        end)
    end
  end

  def gcal_event_delete(args) do
    event_id = Map.get(args, "event_id") || Map.get(args, "id")

    if event_id in [nil, ""] do
      {:error, :missing_event_id}
    else
      with_google_account(args, fn account ->
        Calendar.delete_event(
          account,
          Map.get(args, "calendar_id", "primary"),
          event_id
        )
      end)
    end
  end

  def tasks_list(args \\ %{}) do
    with_google_account(args, fn account ->
      case Map.get(args, "tasklist_id") do
        id when id in [nil, ""] -> Tasks.list_tasklists(account)
        tasklist_id -> Tasks.list_tasks(account, tasklist_id)
      end
    end)
  end

  def tasks_get(args) do
    with_tasklist_and_task(args, fn account, tasklist_id, task_id ->
      Tasks.get_task(account, tasklist_id, task_id)
    end)
  end

  def tasks_create(args) do
    tasklist_id = Map.get(args, "tasklist_id")

    cond do
      tasklist_id in [nil, ""] ->
        {:error, :missing_tasklist_id}

      Map.get(args, "title") in [nil, ""] ->
        {:error, :missing_title}

      true ->
        with_google_account(args, fn account ->
          Tasks.create_task(account, tasklist_id, task_attrs(args))
        end)
    end
  end

  def tasks_update(args) do
    with_tasklist_and_task(args, fn account, tasklist_id, task_id ->
      Tasks.update_task(account, tasklist_id, task_id, task_attrs(args))
    end)
  end

  def tasks_delete(args) do
    with_tasklist_and_task(args, fn account, tasklist_id, task_id ->
      Tasks.delete_task(account, tasklist_id, task_id)
    end)
  end

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

  def docs_get(args) do
    with_required(args, "document_id", :missing_document_id, fn account, document_id ->
      Docs.get(account, document_id)
    end)
  end

  def docs_create(args) do
    with_required(args, "title", :missing_title, fn account, title ->
      Docs.create(account, title)
    end)
  end

  def docs_batch_update(args) do
    with_requests(args, "document_id", :missing_document_id, fn account, document_id, requests ->
      Docs.batch_update(account, document_id, requests)
    end)
  end

  def sheets_get(args) do
    with_required(args, "spreadsheet_id", :missing_spreadsheet_id, fn account, id ->
      Sheets.get(account, id)
    end)
  end

  def sheets_get_values(args) do
    with_range(args, fn account, id, range ->
      Sheets.get_values(account, id, range)
    end)
  end

  def sheets_create(args) do
    with_required(args, "title", :missing_title, fn account, title ->
      Sheets.create(account, title)
    end)
  end

  def sheets_update_values(args) do
    with_range_values(args, fn account, id, range, values ->
      Sheets.update_values(account, id, range, values)
    end)
  end

  def sheets_append_values(args) do
    with_range_values(args, fn account, id, range, values ->
      Sheets.append_values(account, id, range, values)
    end)
  end

  def sheets_clear_values(args) do
    with_range(args, fn account, id, range ->
      Sheets.clear_values(account, id, range)
    end)
  end

  def sheets_batch_update(args) do
    with_requests(args, "spreadsheet_id", :missing_spreadsheet_id, fn account, id, requests ->
      Sheets.batch_update(account, id, requests)
    end)
  end

  def slides_get(args) do
    with_required(args, "presentation_id", :missing_presentation_id, fn account, id ->
      Slides.get(account, id)
    end)
  end

  def slides_create(args) do
    with_required(args, "title", :missing_title, fn account, title ->
      Slides.create(account, title)
    end)
  end

  def slides_batch_update(args) do
    with_requests(args, "presentation_id", :missing_presentation_id, fn account, id, requests ->
      Slides.batch_update(account, id, requests)
    end)
  end

  def contacts_list(args \\ %{}) do
    with_google_account(args, fn account ->
      People.list(account,
        page_size: Map.get(args, "page_size", 100),
        page_token: Map.get(args, "page_token"),
        sync_token: Map.get(args, "sync_token")
      )
    end)
  end

  def contacts_search(args) do
    with_required(args, "query", :missing_query, fn account, query ->
      People.search(account, query)
    end)
  end

  def contacts_get(args) do
    with_required(args, "resource_name", :missing_resource_name, fn account, resource_name ->
      People.get(account, resource_name)
    end)
  end

  def contacts_create(args) do
    case person_resource(args) do
      resource when resource == %{} ->
        {:error, :missing_contact}

      resource ->
        with_google_account(args, fn account ->
          People.create(account, resource)
        end)
    end
  end

  def contacts_update(args) do
    resource_name = Map.get(args, "resource_name")
    etag = Map.get(args, "etag")

    cond do
      resource_name in [nil, ""] ->
        {:error, :missing_resource_name}

      etag in [nil, ""] ->
        {:error, :missing_etag}

      true ->
        with_google_account(args, fn account ->
          People.update(account, resource_name, person_resource(args), etag)
        end)
    end
  end

  def contacts_delete(args) do
    with_required(args, "resource_name", :missing_resource_name, fn account, resource_name ->
      People.delete(account, resource_name)
    end)
  end

  # ---------------------------------------------------------------------
  # Account resolution + resource-building helpers (Google-specific)
  # ---------------------------------------------------------------------

  @doc """
  Resolve the target Google account (explicit `account_id`/`email`, else the
  default account) and run `fun` with it; `{:error, :no_google_account}` when
  none resolves. Public so cross-domain callers (e.g. a Dispatch Gmail reply)
  can reuse account resolution without duplicating it.
  """
  def with_google_account(args, fun) do
    cond do
      account_id = Map.get(args, "account_id") ->
        with_resource(Google, :get_account!, account_id, fun)

      email = Map.get(args, "email") ->
        case Google.get_account_by_email(email) do
          nil -> {:error, :not_found}
          account -> fun.(account)
        end

      account = Google.default_account() ->
        fun.(account)

      true ->
        {:error, :no_google_account}
    end
  end

  defp with_message_id(args, fun) do
    message_id = Map.get(args, "message_id") || Map.get(args, "id")

    if message_id in [nil, ""] do
      {:error, :missing_message_id}
    else
      with_google_account(args, fn account -> fun.(account, message_id) end)
    end
  end

  defp with_tasklist_and_task(args, fun) do
    tasklist_id = Map.get(args, "tasklist_id")
    task_id = Map.get(args, "task_id") || Map.get(args, "id")

    cond do
      tasklist_id in [nil, ""] -> {:error, :missing_tasklist_id}
      task_id in [nil, ""] -> {:error, :missing_task_id}
      true -> with_google_account(args, fn account -> fun.(account, tasklist_id, task_id) end)
    end
  end

  # Build a Google Tasks resource from the supported flat fields, dropping blanks
  # so a patch only touches what was provided.
  defp task_attrs(args) do
    ~w(title notes due status)
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(args, key) do
        value when value in [nil, ""] -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # Resolve the Google account and require one string arg before calling `fun`.
  defp with_required(args, key, error, fun) do
    case Map.get(args, key) do
      value when value in [nil, ""] -> {:error, error}
      value -> with_google_account(args, fn account -> fun.(account, value) end)
    end
  end

  # Require an id arg plus a non-empty `requests` list (Docs/Sheets/Slides batchUpdate).
  defp with_requests(args, id_key, id_error, fun) do
    requests = Map.get(args, "requests")

    cond do
      Map.get(args, id_key) in [nil, ""] ->
        {:error, id_error}

      not is_list(requests) or requests == [] ->
        {:error, :missing_requests}

      true ->
        with_google_account(args, fn account -> fun.(account, Map.get(args, id_key), requests) end)
    end
  end

  # Require spreadsheet_id + range (Sheets reads/clear).
  defp with_range(args, fun) do
    id = Map.get(args, "spreadsheet_id")
    range = Map.get(args, "range")

    cond do
      id in [nil, ""] -> {:error, :missing_spreadsheet_id}
      range in [nil, ""] -> {:error, :missing_range}
      true -> with_google_account(args, fn account -> fun.(account, id, range) end)
    end
  end

  # Require spreadsheet_id + range + a 2-D values list (Sheets writes).
  defp with_range_values(args, fun) do
    values = Map.get(args, "values")

    with_range(args, fn account, id, range ->
      if is_list(values), do: fun.(account, id, range, values), else: {:error, :missing_values}
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

  defp put_attr(attrs, _key, value) when value in [nil, ""], do: attrs
  defp put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp put_parents_attr(attrs, parent_id) when parent_id in [nil, ""], do: attrs
  defp put_parents_attr(attrs, parent_id), do: Map.put(attrs, "parents", [parent_id])

  defp put_opt(opts, _key, value) when value in [nil, ""], do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp confirmed?(args, key) do
    Map.get(args, key) in [true, "true", "yes", "YES", "confirm", "CONFIRM"]
  end

  # Build a People `Person` resource: a raw `contact` object wins; otherwise
  # assemble one from the flat convenience fields.
  defp person_resource(args) do
    case Map.get(args, "contact") do
      %{} = contact when contact != %{} -> contact
      _ -> build_person(args)
    end
  end

  defp build_person(args) do
    %{}
    |> put_person_name(args)
    |> put_person_field("emailAddresses", Map.get(args, "contact_email"))
    |> put_person_field("phoneNumbers", Map.get(args, "phone"))
  end

  defp put_person_name(person, args) do
    given = Map.get(args, "given_name")
    family = Map.get(args, "family_name")

    if given in [nil, ""] and family in [nil, ""] do
      person
    else
      name = %{} |> put_attr("givenName", given) |> put_attr("familyName", family)
      Map.put(person, "names", [name])
    end
  end

  defp put_person_field(person, _key, value) when value in [nil, ""], do: person

  defp put_person_field(person, "emailAddresses", value),
    do: Map.put(person, "emailAddresses", [%{"value" => value}])

  defp put_person_field(person, "phoneNumbers", value),
    do: Map.put(person, "phoneNumbers", [%{"value" => value}])

  defp send_confirmed?(args) do
    Map.get(args, "confirm_send") in [true, "true", "send", "SEND"]
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, "yes", "YES", "on", "ON"]
end
