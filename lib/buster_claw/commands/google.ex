defmodule BusterClaw.Commands.Google do
  @moduledoc """
  Facade over the per-service Google Workspace command modules.

  The implementations live in focused submodules — `Google.Accounts`,
  `Google.Mail`, `Google.Calendar` (calendar + tasks), `Google.Drive`,
  `Google.Docs` (docs/sheets/slides), and `Google.Contacts` — so each surface
  stays small and cohesive. This module re-exports them as a single flat
  namespace via `defdelegate` because the `BusterClaw.Commands` facade delegates
  here by name, and cross-domain callers (e.g. a Dispatch Gmail reply) reuse
  `with_google_account/2` from here. Every function keeps the canonical
  `{:ok, _} | {:error, reason}` contract and takes a single string-keyed args map.

  Shared account resolution and argument coercion live in `Google.Accounts`; the
  service modules import what they need from it so there is one definition of
  each helper.
  """

  alias BusterClaw.Commands.Google.{Accounts, Calendar, Contacts, Docs, Drive, Mail}

  # Account resolution — re-exported for cross-domain callers (e.g. Dispatch).
  defdelegate with_google_account(args, fun), to: Accounts

  # Google Workspace accounts
  defdelegate google_account_list(args \\ %{}), to: Accounts
  defdelegate google_account_get(args), to: Accounts
  defdelegate google_account_create(args), to: Accounts
  defdelegate google_account_update(args), to: Accounts
  defdelegate google_account_delete(args), to: Accounts

  # Gmail
  defdelegate gmail_label_list(args \\ %{}), to: Mail
  defdelegate gmail_search(args), to: Mail
  defdelegate gmail_read(args), to: Mail
  defdelegate gmail_sync(args), to: Mail
  defdelegate gmail_draft_create(args), to: Mail
  defdelegate gmail_send(args), to: Mail
  defdelegate gmail_modify(args), to: Mail
  defdelegate gmail_trash(args), to: Mail
  defdelegate gmail_delete(args), to: Mail

  # Calendar + Tasks
  defdelegate google_calendar_sync(args), to: Calendar
  defdelegate gcal_event_create(args), to: Calendar
  defdelegate gcal_event_update(args), to: Calendar
  defdelegate gcal_event_delete(args), to: Calendar
  defdelegate tasks_list(args \\ %{}), to: Calendar
  defdelegate tasks_get(args), to: Calendar
  defdelegate tasks_create(args), to: Calendar
  defdelegate tasks_update(args), to: Calendar
  defdelegate tasks_delete(args), to: Calendar

  # Drive
  defdelegate drive_list(args \\ %{}), to: Drive
  defdelegate drive_get(args), to: Drive
  defdelegate drive_download(args), to: Drive
  defdelegate drive_export(args), to: Drive
  defdelegate drive_folder_create(args), to: Drive
  defdelegate drive_upload(args), to: Drive
  defdelegate drive_update(args), to: Drive
  defdelegate drive_copy(args), to: Drive
  defdelegate drive_share(args), to: Drive
  defdelegate drive_delete(args), to: Drive

  # Docs / Sheets / Slides
  defdelegate docs_get(args), to: Docs
  defdelegate docs_create(args), to: Docs
  defdelegate docs_batch_update(args), to: Docs
  defdelegate sheets_get(args), to: Docs
  defdelegate sheets_get_values(args), to: Docs
  defdelegate sheets_create(args), to: Docs
  defdelegate sheets_update_values(args), to: Docs
  defdelegate sheets_append_values(args), to: Docs
  defdelegate sheets_clear_values(args), to: Docs
  defdelegate sheets_batch_update(args), to: Docs
  defdelegate slides_get(args), to: Docs
  defdelegate slides_create(args), to: Docs
  defdelegate slides_batch_update(args), to: Docs

  # Contacts (People)
  defdelegate contacts_list(args \\ %{}), to: Contacts
  defdelegate contacts_search(args), to: Contacts
  defdelegate contacts_get(args), to: Contacts
  defdelegate contacts_create(args), to: Contacts
  defdelegate contacts_update(args), to: Contacts
  defdelegate contacts_delete(args), to: Contacts
end
