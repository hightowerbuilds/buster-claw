defmodule BusterClaw.Commands.Google.Calendar do
  @moduledoc """
  Google Calendar and Tasks command implementations: calendar sync, event
  create/update/delete, and task-list/task CRUD.

  Account resolution funnels through
  `BusterClaw.Commands.Google.Accounts.with_google_account/2`. Each function keeps
  the canonical `{:ok, _} | {:error, reason}` contract and takes a single
  string-keyed args map.
  """

  import BusterClaw.Commands.Google.Accounts, only: [with_google_account: 2, truthy?: 1]

  alias BusterClaw.Google.{Calendar, CalendarSync, Tasks}

  def google_calendar_sync(args) do
    with_google_account(args, fn account ->
      CalendarSync.sync(account,
        calendar_id: Map.get(args, "calendar_id", "primary"),
        days_ahead: Map.get(args, "days_ahead", 90),
        force_full?: truthy?(Map.get(args, "force_full", false))
      )
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
end
