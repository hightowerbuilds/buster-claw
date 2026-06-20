defmodule BusterClaw.Commands do
  @moduledoc """
  Canonical command surface for Buster Claw.

  Every external surface (HTTP API, MCP server, CLI escript) dispatches through
  this module. See
  `docs/COMMAND_SURFACE.md` for a command-surface overview.

  ## Contract

  - All commands accept a single map argument (string keys preferred for wire
    parity; atom keys are normalized).
  - All commands return `{:ok, value}` or `{:error, reason_or_changeset}`.
  - Bang getters raise; their `Commands.*` wrappers translate to
    `{:error, :not_found}`.

  ## Dispatch

  - `list_commands/0` returns the catalog (used by MCP `tools/list` and CLI `--help`).
  - `call/2` dispatches by string command name (used by HTTP and MCP frontends).
  - Direct calls (`Commands.document_list(%{})`) work for internal callers.
  """

  alias BusterClaw.{
    Browser,
    Calendar,
    Dispatch,
    Finance,
    Google,
    Integrations,
    Jobs,
    Library,
    Orchestration,
    Search,
    TerminalWorkspace
  }

  alias BusterClaw.Runtime.Status

  # -----------------------------------------------------------------------
  # Catalog
  #
  # The catalog is pure/constant, so it is built exactly once (lazily, on first
  # use) and cached in :persistent_term — along with a name-index map and the
  # safe-tier subset. `by_name/0` gives O(1) lookups for `has_command?/1`,
  # `command_tier/1`, and `command_type/1` instead of re-scanning a freshly
  # rebuilt list on every call. (Local functions can't be invoked from a module
  # attribute during compilation, so this is memoized at runtime rather than
  # baked in at compile time.)
  # -----------------------------------------------------------------------

  @id_required %{"id" => %{type: :integer, required: true}}

  defp list_entry(name, desc),
    do: %{name: name, type: :read, tier: :safe, description: desc, args: %{}}

  defp get_entry(name, desc),
    do: %{name: name, type: :read, tier: :safe, description: desc, args: @id_required}

  # Deletes are irreversible, so they are `gated`: an autonomous run working
  # untrusted-origin content (`:agent_untrusted`) cannot fire them — they surface
  # for human approval instead. See `command_gated?/1` and `authorize/2`.
  defp delete_entry(name, desc),
    do: %{
      name: name,
      type: :mutate,
      tier: :restricted,
      gated: true,
      description: desc,
      args: @id_required
    }

  defp id_trigger_entry(name, desc, tier),
    do: %{name: name, type: :trigger, tier: tier, description: desc, args: @id_required}

  defp build_catalog,
    do: [
      # Documents
      list_entry("document_list", "List all indexed documents."),
      get_entry("document_get", "Fetch a document by ID."),
      get_entry("document_read", "Read the raw markdown contents of a document."),
      %{
        name: "document_save",
        type: :mutate,
        tier: :restricted,
        description: "Write a new raw document to the library and index it.",
        args: %{
          "name" => %{type: :string, required: true},
          "body" => %{type: :string, required: true},
          "source_url" => %{type: :string, required: false},
          "date" => %{type: :string, required: false, description: "ISO 8601 date"},
          "tags" => %{type: :map, required: false}
        }
      },
      delete_entry("document_delete", "Delete a document's file and mark it deleted."),

      # Events
      list_entry("event_list", "List all calendar events."),
      get_entry("event_get", "Fetch an event by ID."),
      %{
        name: "event_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a calendar event.",
        args: %{
          "event_id" => %{type: :string, required: true},
          "date" => %{type: :string, required: true, description: "ISO 8601 date"},
          "title" => %{type: :string, required: true},
          "notes" => %{type: :string, required: false}
        }
      },
      %{
        name: "event_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a calendar event.",
        args: %{
          "id" => %{type: :integer, required: true},
          "event_id" => %{type: :string, required: false},
          "date" => %{type: :string, required: false},
          "title" => %{type: :string, required: false},
          "notes" => %{type: :string, required: false}
        }
      },
      delete_entry("event_delete", "Delete a calendar event."),

      # Integrations
      list_entry("integration_list", "List service integrations."),
      get_entry("integration_get", "Fetch an integration by ID."),
      %{
        name: "integration_create",
        type: :mutate,
        tier: :restricted,
        description: "Create an integration.",
        args: %{
          "name" => %{type: :string, required: true},
          "service_type" => %{type: :string, required: true},
          "base_url" => %{type: :string, required: false},
          "token" => %{type: :string, required: false},
          "webhook_secret" => %{type: :string, required: false},
          "config" => %{type: :map, required: false},
          "enabled" => %{type: :boolean, required: false, default: true},
          "polling_interval_minutes" => %{type: :integer, required: false, default: 60}
        }
      },
      %{
        name: "integration_update",
        type: :mutate,
        tier: :restricted,
        description: "Update an integration.",
        args: %{
          "id" => %{type: :integer, required: true},
          "name" => %{type: :string, required: false},
          "service_type" => %{type: :string, required: false},
          "base_url" => %{type: :string, required: false},
          "token" => %{type: :string, required: false},
          "webhook_secret" => %{type: :string, required: false},
          "config" => %{type: :map, required: false},
          "enabled" => %{type: :boolean, required: false},
          "polling_interval_minutes" => %{type: :integer, required: false}
        }
      },
      delete_entry("integration_delete", "Delete an integration."),
      id_trigger_entry("integration_poll", "Poll a single integration.", :safe),
      list_entry("integration_poll_all", "Poll every enabled integration.")
      |> Map.put(:type, :trigger),
      %{
        name: "integration_run_list",
        type: :read,
        tier: :safe,
        description: "List integration run history.",
        args: %{
          "integration_id" => %{type: :integer, required: false}
        }
      },

      # Google Workspace accounts
      list_entry("google_account_list", "List configured Google Workspace accounts."),
      get_entry("google_account_get", "Fetch a Google Workspace account summary."),
      %{
        name: "google_account_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Google Workspace account credential shell.",
        args: %{
          "email" => %{type: :string, required: true},
          "client_id" => %{type: :string, required: true},
          "client_secret" => %{type: :string, required: false},
          "refresh_token" => %{type: :string, required: false},
          "access_token" => %{type: :string, required: false},
          "access_token_expires_at" => %{type: :string, required: false},
          "scopes" => %{type: :string, required: false},
          "default_query" => %{type: :string, required: false},
          "enabled" => %{type: :boolean, required: false, default: true}
        }
      },
      %{
        name: "google_account_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a Google Workspace account credential shell.",
        args: %{
          "id" => %{type: :integer, required: true},
          "email" => %{type: :string, required: false},
          "client_id" => %{type: :string, required: false},
          "client_secret" => %{type: :string, required: false},
          "refresh_token" => %{type: :string, required: false},
          "access_token" => %{type: :string, required: false},
          "access_token_expires_at" => %{type: :string, required: false},
          "scopes" => %{type: :string, required: false},
          "default_query" => %{type: :string, required: false},
          "enabled" => %{type: :boolean, required: false}
        }
      },
      delete_entry("google_account_delete", "Delete a Google Workspace account."),
      %{
        name: "gmail_label_list",
        type: :read,
        tier: :safe,
        description: "List Gmail labels for a connected Google Workspace account.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false}
        }
      },
      %{
        name: "gmail_search",
        type: :read,
        tier: :safe,
        description: "Search Gmail messages for a connected Google Workspace account.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "query" => %{type: :string, required: false},
          "limit" => %{type: :integer, required: false, default: 10},
          "incremental" => %{type: :boolean, required: false, default: false},
          "start_history_id" => %{type: :string, required: false}
        }
      },
      %{
        name: "gmail_read",
        type: :read,
        tier: :safe,
        description: "Read one Gmail message by message ID.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "message_id" => %{type: :string, required: true}
        }
      },
      %{
        name: "gmail_sync",
        type: :trigger,
        tier: :safe,
        description: "Sync Gmail search results or history deltas into Library raw documents.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "query" => %{type: :string, required: false},
          "limit" => %{type: :integer, required: false, default: 10},
          "incremental" => %{type: :boolean, required: false, default: false},
          "start_history_id" => %{type: :string, required: false}
        }
      },
      %{
        name: "gmail_draft_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Gmail draft for a connected Google Workspace account.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "to" => %{type: :string, required: false},
          "recipient" => %{type: :string, required: false, description: "Alias for to."},
          "cc" => %{type: :string, required: false},
          "bcc" => %{type: :string, required: false},
          "subject" => %{type: :string, required: true},
          "body" => %{type: :string, required: true},
          "attachments" => %{
            type: :array,
            required: false,
            description:
              "File paths (relative to the workspace, or absolute), or objects with path/filename/content_type."
          }
        }
      },
      %{
        name: "gmail_send",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Send a Gmail message from a connected Google Workspace account.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "to" => %{type: :string, required: false},
          "recipient" => %{type: :string, required: false, description: "Alias for to."},
          "cc" => %{type: :string, required: false},
          "bcc" => %{type: :string, required: false},
          "subject" => %{type: :string, required: true},
          "body" => %{type: :string, required: true},
          "attachments" => %{
            type: :array,
            required: false,
            description:
              "File paths (relative to the workspace, or absolute), or objects with path/filename/content_type."
          },
          "confirm_send" => %{type: :boolean, required: true, default: false}
        }
      },
      %{
        name: "gmail_modify",
        type: :mutate,
        tier: :restricted,
        description:
          "Add/remove labels on a Gmail message (archive = remove INBOX, mark read = remove UNREAD).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "message_id" => %{type: :string, required: true},
          "add" => %{type: :array, required: false, description: "Label IDs to add."},
          "remove" => %{type: :array, required: false, description: "Label IDs to remove."}
        }
      },
      %{
        name: "gmail_trash",
        type: :mutate,
        tier: :restricted,
        description: "Move a Gmail message to the trash (recoverable).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "message_id" => %{type: :string, required: true}
        }
      },
      %{
        name: "gmail_delete",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Permanently delete a Gmail message (irreversible).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "message_id" => %{type: :string, required: true}
        }
      },
      %{
        name: "google_calendar_sync",
        type: :trigger,
        tier: :safe,
        description: "One-way sync Google Calendar events into the app calendar.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "calendar_id" => %{type: :string, required: false, default: "primary"},
          "days_ahead" => %{type: :integer, required: false, default: 90},
          "force_full" => %{type: :boolean, required: false, default: false}
        }
      },
      %{
        name: "gcal_event_create",
        type: :mutate,
        tier: :restricted,
        description:
          "Create a Google Calendar event. `event` is the raw Google event resource (summary/start/end/...).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "calendar_id" => %{type: :string, required: false, default: "primary"},
          "event" => %{type: :object, required: true}
        }
      },
      %{
        name: "gcal_event_update",
        type: :mutate,
        tier: :restricted,
        description: "Patch a Google Calendar event. `event` holds the fields to change.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "calendar_id" => %{type: :string, required: false, default: "primary"},
          "event_id" => %{type: :string, required: true},
          "event" => %{type: :object, required: true}
        }
      },
      %{
        name: "gcal_event_delete",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Delete a Google Calendar event (irreversible).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "calendar_id" => %{type: :string, required: false, default: "primary"},
          "event_id" => %{type: :string, required: true}
        }
      },
      %{
        name: "tasks_list",
        type: :read,
        tier: :safe,
        description:
          "List Google task lists, or the tasks in a list when `tasklist_id` is given.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "tasklist_id" => %{type: :string, required: false}
        }
      },
      %{
        name: "tasks_get",
        type: :read,
        tier: :safe,
        description: "Read one Google task.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "tasklist_id" => %{type: :string, required: true},
          "task_id" => %{type: :string, required: true}
        }
      },
      %{
        name: "tasks_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Google task in a list.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "tasklist_id" => %{type: :string, required: true},
          "title" => %{type: :string, required: true},
          "notes" => %{type: :string, required: false},
          "due" => %{type: :string, required: false, description: "RFC 3339 timestamp."},
          "status" => %{type: :string, required: false, description: "needsAction or completed."}
        }
      },
      %{
        name: "tasks_update",
        type: :mutate,
        tier: :restricted,
        description: "Patch a Google task (title/notes/due/status).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "tasklist_id" => %{type: :string, required: true},
          "task_id" => %{type: :string, required: true},
          "title" => %{type: :string, required: false},
          "notes" => %{type: :string, required: false},
          "due" => %{type: :string, required: false},
          "status" => %{type: :string, required: false}
        }
      },
      %{
        name: "tasks_delete",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Delete a Google task (irreversible).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "tasklist_id" => %{type: :string, required: true},
          "task_id" => %{type: :string, required: true}
        }
      },

      # Google Drive
      %{
        name: "drive_list",
        type: :read,
        tier: :safe,
        description: "List/search Google Drive files. `q` is a Drive query string.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "q" => %{type: :string, required: false},
          "order_by" => %{type: :string, required: false},
          "page_size" => %{type: :integer, required: false, default: 50},
          "page_token" => %{type: :string, required: false}
        }
      },
      %{
        name: "drive_get",
        type: :read,
        tier: :safe,
        description: "Get a Google Drive file's metadata.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "file_id" => %{type: :string, required: true}
        }
      },
      %{
        name: "drive_download",
        type: :read,
        tier: :safe,
        description:
          "Download a Drive file's bytes into the workspace. Returns the saved path.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "file_id" => %{type: :string, required: true},
          "destination" => %{
            type: :string,
            required: false,
            description: "Workspace-relative (or absolute) path to write to."
          }
        }
      },
      %{
        name: "drive_export",
        type: :read,
        tier: :safe,
        description:
          "Export a Google-native doc (Docs/Sheets/Slides) to a MIME type into the workspace.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "file_id" => %{type: :string, required: true},
          "mime_type" => %{type: :string, required: true},
          "destination" => %{type: :string, required: false}
        }
      },
      %{
        name: "drive_folder_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a folder in Google Drive.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "name" => %{type: :string, required: true},
          "parent_id" => %{type: :string, required: false}
        }
      },
      %{
        name: "drive_upload",
        type: :mutate,
        tier: :restricted,
        description: "Upload a local workspace file to Google Drive.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "path" => %{
            type: :string,
            required: true,
            description: "Local file path (workspace-relative or absolute) to upload."
          },
          "name" => %{type: :string, required: false, description: "Drive file name; defaults to the basename."},
          "parent_id" => %{type: :string, required: false},
          "content_type" => %{type: :string, required: false}
        }
      },
      %{
        name: "drive_update",
        type: :mutate,
        tier: :restricted,
        description: "Rename/star a Drive file, or move it via add_parents/remove_parents.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "file_id" => %{type: :string, required: true},
          "name" => %{type: :string, required: false},
          "starred" => %{type: :boolean, required: false},
          "add_parents" => %{type: :string, required: false},
          "remove_parents" => %{type: :string, required: false}
        }
      },
      %{
        name: "drive_copy",
        type: :mutate,
        tier: :restricted,
        description: "Copy a Drive file.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "file_id" => %{type: :string, required: true},
          "name" => %{type: :string, required: false},
          "parent_id" => %{type: :string, required: false}
        }
      },
      %{
        name: "drive_share",
        type: :mutate,
        tier: :restricted,
        description:
          "Grant a permission on a Drive file (may email the grantee). Requires confirm_share.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "file_id" => %{type: :string, required: true},
          "role" => %{type: :string, required: true, description: "reader/commenter/writer/owner."},
          "type" => %{type: :string, required: true, description: "user/group/domain/anyone."},
          "grantee_email" => %{type: :string, required: false},
          "notify" => %{type: :boolean, required: false, default: false},
          "confirm_share" => %{type: :boolean, required: true, default: false}
        }
      },
      %{
        name: "drive_delete",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Permanently delete a Drive file (irreversible, bypasses trash).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "file_id" => %{type: :string, required: true}
        }
      },

      # Google Docs
      %{
        name: "docs_get",
        type: :read,
        tier: :safe,
        description: "Get a Google Doc's structure/content.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "document_id" => %{type: :string, required: true}
        }
      },
      %{
        name: "docs_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Google Doc with a title.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "title" => %{type: :string, required: true}
        }
      },
      %{
        name: "docs_batch_update",
        type: :mutate,
        tier: :restricted,
        description: "Apply edit requests to a Google Doc (insertText, replaceAllText, …).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "document_id" => %{type: :string, required: true},
          "requests" => %{type: :array, required: true, description: "Google Docs request list."}
        }
      },

      # Google Sheets
      %{
        name: "sheets_get",
        type: :read,
        tier: :safe,
        description: "Get a Google Sheet's metadata.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "spreadsheet_id" => %{type: :string, required: true}
        }
      },
      %{
        name: "sheets_get_values",
        type: :read,
        tier: :safe,
        description: "Read a range of cell values from a Google Sheet (A1 notation).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "spreadsheet_id" => %{type: :string, required: true},
          "range" => %{type: :string, required: true}
        }
      },
      %{
        name: "sheets_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Google Sheet with a title.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "title" => %{type: :string, required: true}
        }
      },
      %{
        name: "sheets_update_values",
        type: :mutate,
        tier: :restricted,
        description: "Overwrite a range with values (USER_ENTERED).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "spreadsheet_id" => %{type: :string, required: true},
          "range" => %{type: :string, required: true},
          "values" => %{type: :array, required: true, description: "2-D array of row values."}
        }
      },
      %{
        name: "sheets_append_values",
        type: :mutate,
        tier: :restricted,
        description: "Append rows after a range/table.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "spreadsheet_id" => %{type: :string, required: true},
          "range" => %{type: :string, required: true},
          "values" => %{type: :array, required: true, description: "2-D array of row values."}
        }
      },
      %{
        name: "sheets_clear_values",
        type: :mutate,
        tier: :restricted,
        description: "Clear the values in a range (keeps formatting).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "spreadsheet_id" => %{type: :string, required: true},
          "range" => %{type: :string, required: true}
        }
      },
      %{
        name: "sheets_batch_update",
        type: :mutate,
        tier: :restricted,
        description: "Apply structural edit requests to a Sheet (add/delete sheets, formatting).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "spreadsheet_id" => %{type: :string, required: true},
          "requests" => %{type: :array, required: true, description: "Google Sheets request list."}
        }
      },

      # Google Slides
      %{
        name: "slides_get",
        type: :read,
        tier: :safe,
        description: "Get a Google Slides presentation.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "presentation_id" => %{type: :string, required: true}
        }
      },
      %{
        name: "slides_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Google Slides presentation with a title.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "title" => %{type: :string, required: true}
        }
      },
      %{
        name: "slides_batch_update",
        type: :mutate,
        tier: :restricted,
        description: "Apply edit requests to a presentation (createSlide, insertText, …).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "presentation_id" => %{type: :string, required: true},
          "requests" => %{type: :array, required: true, description: "Google Slides request list."}
        }
      },

      # Contacts (People)
      %{
        name: "contacts_list",
        type: :read,
        tier: :safe,
        description: "List the account's Google Contacts.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "page_size" => %{type: :integer, required: false, default: 100},
          "page_token" => %{type: :string, required: false},
          "sync_token" => %{type: :string, required: false}
        }
      },
      %{
        name: "contacts_search",
        type: :read,
        tier: :safe,
        description: "Search the account's Google Contacts.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "query" => %{type: :string, required: true}
        }
      },
      %{
        name: "contacts_get",
        type: :read,
        tier: :safe,
        description: "Get one contact by resource name (e.g. people/c123).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "resource_name" => %{type: :string, required: true}
        }
      },
      %{
        name: "contacts_create",
        type: :mutate,
        tier: :restricted,
        description:
          "Create a contact. Provide a raw `contact` Person resource, or given_name/family_name/contact_email/phone.",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "contact" => %{type: :object, required: false},
          "given_name" => %{type: :string, required: false},
          "family_name" => %{type: :string, required: false},
          "contact_email" => %{type: :string, required: false},
          "phone" => %{type: :string, required: false}
        }
      },
      %{
        name: "contacts_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a contact. Requires the current etag (from contacts_get).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "resource_name" => %{type: :string, required: true},
          "etag" => %{type: :string, required: true},
          "contact" => %{type: :object, required: false},
          "given_name" => %{type: :string, required: false},
          "family_name" => %{type: :string, required: false},
          "contact_email" => %{type: :string, required: false},
          "phone" => %{type: :string, required: false}
        }
      },
      %{
        name: "contacts_delete",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Delete a contact (irreversible).",
        args: %{
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false},
          "resource_name" => %{type: :string, required: true}
        }
      },

      # Search
      %{
        name: "web_search",
        type: :trigger,
        tier: :safe,
        description: "DuckDuckGo web search.",
        args: %{
          "query" => %{type: :string, required: true},
          "limit" => %{type: :integer, required: false, default: 10}
        }
      },

      # Browser
      %{
        name: "browser_fetch",
        type: :trigger,
        tier: :safe,
        description: "Fetch a URL and convert to markdown.",
        args: %{"url" => %{type: :string, required: true}}
      },
      %{
        name: "browser_download",
        type: :mutate,
        tier: :restricted,
        description:
          "Download a URL's raw bytes (SSRF-guarded) into the workspace downloads folder. Returns the saved path — chain into drive_upload to push it to Google Drive.",
        args: %{
          "url" => %{type: :string, required: true},
          "filename" => %{
            type: :string,
            required: false,
            description: "Override the saved filename (defaults to the server/URL name)."
          }
        }
      },

      # Finance (read-only research; every result carries source + as-of)
      %{
        name: "finance_filings",
        type: :read,
        tier: :safe,
        description: "Recent SEC EDGAR filings for a ticker (10-K/10-Q/8-K …), newest first.",
        args: %{"symbol" => %{type: :string, required: true}}
      },
      %{
        name: "finance_fundamentals",
        type: :read,
        tier: :safe,
        description: "Latest SEC XBRL fundamentals for a ticker (revenue, net income, assets …).",
        args: %{"symbol" => %{type: :string, required: true}}
      },
      %{
        name: "finance_quote",
        type: :read,
        tier: :safe,
        description: "Latest quote for a ticker (Finnhub; needs FINNHUB_API_KEY). Carries as-of.",
        args: %{"symbol" => %{type: :string, required: true}}
      },
      %{
        name: "finance_news",
        type: :read,
        tier: :safe,
        description: "Recent company news for a ticker (Finnhub; needs FINNHUB_API_KEY).",
        args: %{"symbol" => %{type: :string, required: true}}
      },

      # Runtime
      list_entry("runtime_status", "Snapshot of process and system state."),
      %{
        name: "activity_report",
        type: :read,
        tier: :safe,
        description:
          "Summary of work Buster Claw handled over a recent window: requests done/blocked/failed, currently open, and unattended runs.",
        args: %{"days" => %{type: :integer, required: false, default: 7}}
      },

      # Visible terminal workspace
      %{
        name: "terminal_tab_open",
        type: :trigger,
        tier: :safe,
        description: "Open a new visible in-app terminal tab for a role.",
        args: %{
          "role_key" => %{type: :string, required: true},
          "label" => %{type: :string, required: false},
          "agent_name" => %{type: :string, required: false},
          "purpose" => %{type: :string, required: false},
          "session_key" => %{type: :string, required: false},
          "startup_profile" => %{type: :string, required: false, enum: ["mailman"]},
          "activate" => %{type: :boolean, required: false, default: true}
        }
      },

      # Orchestration shift — agent-drivable so the on-shift model can start/stop it.
      list_entry("shift_status", "Whether an orchestration shift is active, plus counts."),
      %{
        name: "shift_start",
        type: :trigger,
        tier: :safe,
        description:
          "Start an orchestration shift (runs until stopped) with job/agent assignment metadata. Set `unattended` to let the Dispatcher work the queue with headless agent runs (no human in the terminal).",
        args: %{
          "job" => %{type: :string, required: false, default: "lookout"},
          "agent_name" => %{type: :string, required: false},
          "shell" => %{type: :string, required: false},
          "unattended" => %{
            type: :boolean,
            required: false,
            default: false,
            description: "Let the Dispatcher drive headless agent runs against the queue."
          }
        }
      },
      %{
        name: "shift_stop",
        type: :trigger,
        tier: :safe,
        description: "Stop the active orchestration shift.",
        args: %{"reason" => %{type: :string, required: false}}
      },
      %{
        name: "shift_assignment_start",
        type: :trigger,
        tier: :safe,
        description: "Start a specialist role/session inside the active shift.",
        args: %{
          "role_key" => %{type: :string, required: true},
          "agent_name" => %{type: :string, required: false},
          "shell" => %{type: :string, required: false},
          "purpose" => %{type: :string, required: false},
          "dedupe_key" => %{type: :string, required: false},
          "notes" => %{type: :string, required: false}
        }
      },
      %{
        name: "shift_assignment_status",
        type: :read,
        tier: :safe,
        description: "List active specialist role sessions inside the active shift.",
        args: %{}
      },
      %{
        name: "shift_assignment_stop",
        type: :trigger,
        tier: :safe,
        description: "Stop or block an active specialist role/session.",
        args: %{
          "id" => %{type: :integer, required: false},
          "role_key" => %{type: :string, required: false},
          "dedupe_key" => %{type: :string, required: false},
          "status" => %{type: :string, required: false, default: "stopped"},
          "notes" => %{type: :string, required: false}
        }
      },

      # Job descriptions (the role roster).
      list_entry("job_list", "List the defined jobs (role roster)."),
      %{
        name: "job_show",
        type: :read,
        tier: :safe,
        description: "Read one job description by key.",
        args: %{"key" => %{type: :string, required: true}}
      },

      # Dispatch queue (pull model) — the terminal agent's worklist + write-back.
      %{
        name: "dispatch_list",
        type: :read,
        tier: :safe,
        description: "List open Dispatch items (or by status), optionally for one job.",
        args: %{
          "status" => %{type: :string, required: false},
          "job" => %{type: :string, required: false},
          "limit" => %{type: :integer, required: false}
        }
      },
      get_entry("dispatch_show", "Fetch a Dispatch item by ID."),
      %{
        name: "dispatch_claim",
        type: :mutate,
        tier: :safe,
        description: "Claim the next open Dispatch item (optionally scoped to one job).",
        args: %{
          "job" => %{type: :string, required: false},
          "source" => %{type: :string, required: false},
          "claimed_by" => %{type: :string, required: false}
        }
      },
      %{
        name: "dispatch_done",
        type: :mutate,
        tier: :safe,
        description: "Mark a Dispatch item done.",
        args: %{
          "id" => %{type: :integer, required: true},
          "note" => %{type: :string, required: false}
        }
      },
      %{
        name: "dispatch_block",
        type: :mutate,
        tier: :safe,
        description: "Mark a Dispatch item blocked.",
        args: %{
          "id" => %{type: :integer, required: true},
          "note" => %{type: :string, required: false}
        }
      },
      %{
        name: "dispatch_reply",
        type: :mutate,
        tier: :restricted,
        description:
          "Send a threaded Gmail reply to a Dispatch item's sender and mark the item done.",
        args: %{
          "id" => %{type: :integer, required: true},
          "body" => %{type: :string, required: true},
          "account_id" => %{type: :integer, required: false},
          "email" => %{type: :string, required: false}
        }
      }
    ]

  # The catalog is constant, but local functions can't be called from a module
  # attribute during compilation, so build it once at runtime and cache it —
  # plus the derived name-index and safe subset — in :persistent_term for O(1)
  # reuse instead of rebuilding/rescanning a fresh list on every call.
  defp catalog do
    case :persistent_term.get({__MODULE__, :catalog}, nil) do
      nil ->
        built = build_catalog()
        :persistent_term.put({__MODULE__, :catalog}, built)
        :persistent_term.put({__MODULE__, :by_name}, Map.new(built, &{&1.name, &1}))

        :persistent_term.put(
          {__MODULE__, :safe_commands},
          Enum.filter(built, &(&1.tier == :safe))
        )

        built

      built ->
        built
    end
  end

  defp by_name do
    catalog()
    :persistent_term.get({__MODULE__, :by_name})
  end

  defp safe_catalog do
    catalog()
    :persistent_term.get({__MODULE__, :safe_commands})
  end

  # -----------------------------------------------------------------------
  # Dispatch
  # -----------------------------------------------------------------------

  @doc """
  Dispatch a command by string name with the given args. Returns
  `{:error, :unknown_command}` if the name is not in the catalog.

  Accepts an optional `:caller` (`:trusted | :agent_untrusted | :agent | :mcp`,
  default `:trusted`):

  - `:trusted` — internal callers and the user's own CLI/`/api/run`; runs anything.
  - `:agent_untrusted` — an autonomous run working untrusted-origin content; runs
    anything EXCEPT the `gated` (outbound/irreversible) set, which is refused.
  - `:agent` / `:mcp` — may only run `:safe`-tier commands.

  A refused command returns `{:error, :requires_confirmation}`, is recorded via
  `Sentinel.Pending`, and is NOT executed.
  """
  def call(name, args \\ %{}, opts \\ []) when is_binary(name) do
    caller = Keyword.get(opts, :caller, :trusted)

    result =
      case authorize(name, caller) do
        :ok ->
          dispatch(name, args)

        {:error, :requires_confirmation} = refusal ->
          BusterClaw.Sentinel.Pending.record(name, args, caller)
          refusal
      end

    audit(name, args, caller, result)
    result
  end

  # Feed the Sentinel audit/notify spine. Refused restricted calls are critical
  # security blocks; otherwise only consequential (mutating/triggering) commands
  # are recorded — pure reads are skipped to keep the audit log signal-rich.
  defp audit(name, args, caller, {:error, :requires_confirmation}) do
    record(
      :security_block,
      ~s(Refused restricted command "#{name}" for #{caller} caller),
      %{command: name, args: args, caller: caller, tier: command_tier(name)}
    )

    :ok
  end

  defp audit(name, args, caller, result) do
    if command_type(name) in [:mutate, :trigger] do
      outcome = if match?({:ok, _}, result), do: "ok", else: "error"

      record(
        :command_invoke,
        "#{name} (#{outcome})",
        %{command: name, args: args, caller: caller, tier: command_tier(name), outcome: outcome}
      )
    end

    :ok
  end

  # Sentinel persistence + broadcast is on the hot command path. In tests it must
  # run inline so it shares the request's Ecto sandbox connection (tests read the
  # audit rows back synchronously). In dev/prod it is offloaded to a Task so the
  # caller doesn't block on a DB insert + PubSub broadcast.
  defp record(category, message, meta) do
    if inline_audit?() do
      BusterClaw.Sentinel.observe(category, message, meta)
    else
      # Fire-and-forget: observe/4 is best-effort and rescues its own failures, so
      # an unsupervised task is acceptable here and keeps it off the caller's path.
      Task.start(fn -> BusterClaw.Sentinel.observe(category, message, meta) end)
    end

    :ok
  end

  # Audit must run inline under the test Ecto sandbox so it shares the request's
  # checked-out connection. We detect that without a Mix-env runtime call: when the
  # Repo is configured with the SQL.Sandbox pool (test only), run inline. An
  # explicit `:sentinel_inline_audit` config value overrides the detection.
  defp inline_audit? do
    case Application.get_env(:buster_claw, :sentinel_inline_audit) do
      nil -> BusterClaw.Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox
      flag -> flag
    end
  end

  @doc "Return the command catalog as a list of maps."
  def list_commands, do: catalog()

  @doc "Return only the `:safe`-tier commands (the ones untrusted callers may run)."
  def safe_commands, do: safe_catalog()

  @doc """
  The tier (`:safe | :restricted`) of a command by name, or `nil` when the name
  is not in the catalog.
  """
  def command_tier(name) do
    case Map.get(by_name(), name) do
      %{tier: tier} -> tier
      nil -> nil
    end
  end

  @doc """
  The type (`:read | :mutate | :trigger`) of a command by name, or `nil` when
  the name is not in the catalog.
  """
  def command_type(name) do
    case Map.get(by_name(), name) do
      %{type: type} -> type
      nil -> nil
    end
  end

  @doc """
  Whether a command is `gated` — an outbound or irreversible action (`gmail_send`
  and the `*_delete` commands). An autonomous run working *untrusted-origin*
  content (`caller: :agent_untrusted`) may not fire these; they are refused and
  surfaced for human approval. Trusted callers are unaffected.
  """
  def command_gated?(name), do: match?(%{gated: true}, Map.get(by_name(), name))

  defp dispatch(name, args) do
    if has_command?(name) do
      apply(__MODULE__, String.to_existing_atom(name), [normalize_args(args)])
    else
      {:error, :unknown_command}
    end
  end

  # An autonomous run working untrusted-origin content is trusted enough to do a
  # lot without asking (drafts, saves, calendar edits, the dispatch verbs) — it is
  # only stopped from the `gated` set (outbound/irreversible), which surfaces for
  # human approval. This is the one guardrail kept for the "agent does a lot
  # without asking" model: untrusted input must not autonomously send or delete.
  defp authorize(name, :agent_untrusted) do
    if command_gated?(name), do: {:error, :requires_confirmation}, else: :ok
  end

  # Untrusted callers (chat agent / MCP) may only run safe-tier commands.
  # Unknown names fall through to `dispatch/2`, which returns
  # `{:error, :unknown_command}` — we don't leak "restricted" for those.
  defp authorize(name, caller) when caller in [:agent, :mcp] do
    case command_tier(name) do
      :restricted -> {:error, :requires_confirmation}
      _ -> :ok
    end
  end

  defp authorize(_name, _caller), do: :ok

  defp has_command?(name), do: Map.has_key?(by_name(), name)

  defp normalize_args(args) when is_map(args) do
    Map.new(args, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_args(_), do: %{}

  # -----------------------------------------------------------------------
  # CRUD: list/get/create/update/delete for every resource whose context
  # module exposes the canonical 5-function shape. Each tuple expands to
  # five command functions named `<prefix>_list`, `<prefix>_get`,
  # `<prefix>_create`, `<prefix>_update`, `<prefix>_delete`, all of which
  # honor the `{:ok, _} | {:error, reason}` contract used by `call/2`.
  # -----------------------------------------------------------------------

  for {prefix, context, ctx_singular, ctx_plural} <- [
        {:event, Calendar, :event, :events},
        {:integration, Integrations, :integration, :integrations}
      ] do
    list_fn = :"list_#{ctx_plural}"
    get_fn = :"get_#{ctx_singular}!"
    create_fn = :"create_#{ctx_singular}"
    update_fn = :"update_#{ctx_singular}"
    delete_fn = :"delete_#{ctx_singular}"

    def unquote(:"#{prefix}_list")(_args \\ %{}),
      do: {:ok, apply(unquote(context), unquote(list_fn), [])}

    def unquote(:"#{prefix}_get")(%{"id" => id}),
      do: safe_get(unquote(context), unquote(get_fn), id)

    def unquote(:"#{prefix}_create")(args),
      do: apply(unquote(context), unquote(create_fn), [args])

    def unquote(:"#{prefix}_update")(%{"id" => id} = args) do
      with_resource(unquote(context), unquote(get_fn), id, fn record ->
        apply(unquote(context), unquote(update_fn), [record, Map.delete(args, "id")])
      end)
    end

    def unquote(:"#{prefix}_delete")(%{"id" => id}) do
      with_resource(unquote(context), unquote(get_fn), id, fn record ->
        apply(unquote(context), unquote(delete_fn), [record])
      end)
    end
  end

  # -----------------------------------------------------------------------
  # Documents (asymmetric: read/save/delete wrap raw files)
  # -----------------------------------------------------------------------

  def document_list(_args \\ %{}), do: {:ok, Library.list_documents()}

  def document_get(%{"id" => id}), do: safe_get(Library, :get_document!, id)

  def document_read(%{"id" => id}) do
    with_resource(Library, :get_document!, id, &Library.read_raw_document/1)
  end

  def document_save(args), do: Library.save_raw_document(args)

  def document_delete(%{"id" => id}) do
    with_resource(Library, :get_document!, id, &Library.delete_raw_document/1)
  end

  # -----------------------------------------------------------------------
  # Integrations (extras)
  # -----------------------------------------------------------------------

  def integration_poll(%{"id" => id}) do
    case Integrations.poll_integration(id, []) do
      {:ok, run} -> {:ok, run}
      {:error, _} = err -> err
    end
  end

  def integration_poll_all(_args \\ %{}), do: {:ok, Integrations.poll_all([])}

  def integration_run_list(args) do
    case Map.get(args, "integration_id") do
      nil ->
        {:ok, Integrations.list_runs()}

      id ->
        with_resource(Integrations, :get_integration!, id, fn integration ->
          {:ok, Integrations.list_runs_for_integration(integration)}
        end)
    end
  end

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
      BusterClaw.Google.Gmail.labels(account)
    end)
  end

  def gmail_search(args) do
    with_google_account(args, fn account ->
      query = Map.get(args, "query") || account.default_query || "newer_than:7d"
      limit = Map.get(args, "limit", 10)
      BusterClaw.Google.Gmail.search(account, query, limit: limit)
    end)
  end

  def gmail_read(args) do
    message_id = Map.get(args, "message_id") || Map.get(args, "id")

    if message_id in [nil, ""] do
      {:error, :missing_message_id}
    else
      with_google_account(args, fn account ->
        BusterClaw.Google.Gmail.read(account, message_id)
      end)
    end
  end

  def gmail_sync(args) do
    with_google_account(args, fn account ->
      query = Map.get(args, "query") || account.default_query || "newer_than:7d"
      limit = Map.get(args, "limit", 10)

      BusterClaw.Google.GmailSync.sync(account,
        query: query,
        limit: limit,
        incremental: truthy?(Map.get(args, "incremental", false)),
        start_history_id: Map.get(args, "start_history_id")
      )
    end)
  end

  def gmail_draft_create(args) do
    with_google_account(args, fn account ->
      BusterClaw.Google.Gmail.create_draft(account, args)
    end)
  end

  def gmail_send(args) do
    if send_confirmed?(args) do
      with_google_account(args, fn account ->
        BusterClaw.Google.Gmail.send_message(account, args)
      end)
    else
      {:error, :missing_send_confirmation}
    end
  end

  def google_calendar_sync(args) do
    with_google_account(args, fn account ->
      BusterClaw.Google.CalendarSync.sync(account,
        calendar_id: Map.get(args, "calendar_id", "primary"),
        days_ahead: Map.get(args, "days_ahead", 90),
        force_full?: truthy?(Map.get(args, "force_full", false))
      )
    end)
  end

  def gmail_modify(args) do
    with_message_id(args, fn account, message_id ->
      BusterClaw.Google.Gmail.modify(account, message_id, args)
    end)
  end

  def gmail_trash(args) do
    with_message_id(args, fn account, message_id ->
      BusterClaw.Google.Gmail.trash(account, message_id)
    end)
  end

  def gmail_delete(args) do
    with_message_id(args, fn account, message_id ->
      BusterClaw.Google.Gmail.delete(account, message_id)
    end)
  end

  def gcal_event_create(args) do
    event = Map.get(args, "event")

    if is_map(event) do
      with_google_account(args, fn account ->
        BusterClaw.Google.Calendar.create_event(
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
      event_id in [nil, ""] -> {:error, :missing_event_id}
      not is_map(event) -> {:error, :missing_event}
      true ->
        with_google_account(args, fn account ->
          BusterClaw.Google.Calendar.update_event(
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
        BusterClaw.Google.Calendar.delete_event(
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
        id when id in [nil, ""] -> BusterClaw.Google.Tasks.list_tasklists(account)
        tasklist_id -> BusterClaw.Google.Tasks.list_tasks(account, tasklist_id)
      end
    end)
  end

  def tasks_get(args) do
    with_tasklist_and_task(args, fn account, tasklist_id, task_id ->
      BusterClaw.Google.Tasks.get_task(account, tasklist_id, task_id)
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
          BusterClaw.Google.Tasks.create_task(account, tasklist_id, task_attrs(args))
        end)
    end
  end

  def tasks_update(args) do
    with_tasklist_and_task(args, fn account, tasklist_id, task_id ->
      BusterClaw.Google.Tasks.update_task(account, tasklist_id, task_id, task_attrs(args))
    end)
  end

  def tasks_delete(args) do
    with_tasklist_and_task(args, fn account, tasklist_id, task_id ->
      BusterClaw.Google.Tasks.delete_task(account, tasklist_id, task_id)
    end)
  end

  def drive_list(args \\ %{}) do
    with_google_account(args, fn account ->
      BusterClaw.Google.Drive.list(account,
        q: Map.get(args, "q"),
        order_by: Map.get(args, "order_by"),
        page_size: Map.get(args, "page_size", 50),
        page_token: Map.get(args, "page_token")
      )
    end)
  end

  def drive_get(args) do
    with_file_id(args, fn account, file_id ->
      BusterClaw.Google.Drive.get(account, file_id)
    end)
  end

  def drive_download(args) do
    with_file_id(args, fn account, file_id ->
      with {:ok, data} <- BusterClaw.Google.Drive.download(account, file_id),
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
        with {:ok, data} <- BusterClaw.Google.Drive.export(account, file_id, mime_type),
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
        BusterClaw.Google.Drive.create_folder(
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
            BusterClaw.Google.Drive.upload(account, %{
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

      BusterClaw.Google.Drive.update_metadata(account, file_id, drive_update_attrs(args), opts)
    end)
  end

  def drive_copy(args) do
    with_file_id(args, fn account, file_id ->
      attrs =
        %{}
        |> put_attr("name", Map.get(args, "name"))
        |> put_parents_attr(Map.get(args, "parent_id"))

      BusterClaw.Google.Drive.copy(account, file_id, attrs)
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

          BusterClaw.Google.Drive.share(account, file_id, permission,
            notify: truthy?(Map.get(args, "notify", false))
          )
        end)
    end
  end

  def drive_delete(args) do
    with_file_id(args, fn account, file_id ->
      BusterClaw.Google.Drive.delete(account, file_id)
    end)
  end

  def docs_get(args) do
    with_required(args, "document_id", :missing_document_id, fn account, document_id ->
      BusterClaw.Google.Docs.get(account, document_id)
    end)
  end

  def docs_create(args) do
    with_required(args, "title", :missing_title, fn account, title ->
      BusterClaw.Google.Docs.create(account, title)
    end)
  end

  def docs_batch_update(args) do
    with_requests(args, "document_id", :missing_document_id, fn account, document_id, requests ->
      BusterClaw.Google.Docs.batch_update(account, document_id, requests)
    end)
  end

  def sheets_get(args) do
    with_required(args, "spreadsheet_id", :missing_spreadsheet_id, fn account, id ->
      BusterClaw.Google.Sheets.get(account, id)
    end)
  end

  def sheets_get_values(args) do
    with_range(args, fn account, id, range ->
      BusterClaw.Google.Sheets.get_values(account, id, range)
    end)
  end

  def sheets_create(args) do
    with_required(args, "title", :missing_title, fn account, title ->
      BusterClaw.Google.Sheets.create(account, title)
    end)
  end

  def sheets_update_values(args) do
    with_range_values(args, fn account, id, range, values ->
      BusterClaw.Google.Sheets.update_values(account, id, range, values)
    end)
  end

  def sheets_append_values(args) do
    with_range_values(args, fn account, id, range, values ->
      BusterClaw.Google.Sheets.append_values(account, id, range, values)
    end)
  end

  def sheets_clear_values(args) do
    with_range(args, fn account, id, range ->
      BusterClaw.Google.Sheets.clear_values(account, id, range)
    end)
  end

  def sheets_batch_update(args) do
    with_requests(args, "spreadsheet_id", :missing_spreadsheet_id, fn account, id, requests ->
      BusterClaw.Google.Sheets.batch_update(account, id, requests)
    end)
  end

  def slides_get(args) do
    with_required(args, "presentation_id", :missing_presentation_id, fn account, id ->
      BusterClaw.Google.Slides.get(account, id)
    end)
  end

  def slides_create(args) do
    with_required(args, "title", :missing_title, fn account, title ->
      BusterClaw.Google.Slides.create(account, title)
    end)
  end

  def slides_batch_update(args) do
    with_requests(args, "presentation_id", :missing_presentation_id, fn account, id, requests ->
      BusterClaw.Google.Slides.batch_update(account, id, requests)
    end)
  end

  def contacts_list(args \\ %{}) do
    with_google_account(args, fn account ->
      BusterClaw.Google.People.list(account,
        page_size: Map.get(args, "page_size", 100),
        page_token: Map.get(args, "page_token"),
        sync_token: Map.get(args, "sync_token")
      )
    end)
  end

  def contacts_search(args) do
    with_required(args, "query", :missing_query, fn account, query ->
      BusterClaw.Google.People.search(account, query)
    end)
  end

  def contacts_get(args) do
    with_required(args, "resource_name", :missing_resource_name, fn account, resource_name ->
      BusterClaw.Google.People.get(account, resource_name)
    end)
  end

  def contacts_create(args) do
    case person_resource(args) do
      resource when resource == %{} ->
        {:error, :missing_contact}

      resource ->
        with_google_account(args, fn account ->
          BusterClaw.Google.People.create(account, resource)
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
          BusterClaw.Google.People.update(account, resource_name, person_resource(args), etag)
        end)
    end
  end

  def contacts_delete(args) do
    with_required(args, "resource_name", :missing_resource_name, fn account, resource_name ->
      BusterClaw.Google.People.delete(account, resource_name)
    end)
  end

  # -----------------------------------------------------------------------
  # Search
  # -----------------------------------------------------------------------

  def web_search(%{"query" => query} = args) do
    limit = Map.get(args, "limit", 10)
    Search.search(query, limit: limit)
  end

  # -----------------------------------------------------------------------
  # Browser
  # -----------------------------------------------------------------------

  def browser_fetch(%{"url" => url}), do: Browser.fetch(url, [])

  def browser_download(%{"url" => url} = args) when is_binary(url) and url != "" do
    with {:ok, dl} <- Browser.download(url) do
      filename = sanitize_download_name(Map.get(args, "filename") || dl.filename)
      rel = Path.join(["downloads", Date.to_iso8601(BusterClaw.LocalTime.today()), filename])
      abs = resolve_workspace_path(rel)

      with :ok <- File.mkdir_p(Path.dirname(abs)),
           :ok <- File.write(abs, dl.body) do
        {:ok,
         %{
           path: rel,
           absolute_path: abs,
           url: url,
           content_type: dl.content_type,
           bytes: byte_size(dl.body)
         }}
      end
    end
  end

  def browser_download(_args), do: {:error, :missing_url}

  # -----------------------------------------------------------------------
  # Finance (read-only research)
  # -----------------------------------------------------------------------

  def finance_filings(%{"symbol" => symbol}) when is_binary(symbol) and symbol != "",
    do: Finance.filings(symbol)

  def finance_filings(_args), do: {:error, :missing_symbol}

  def finance_fundamentals(%{"symbol" => symbol}) when is_binary(symbol) and symbol != "",
    do: Finance.fundamentals(symbol)

  def finance_fundamentals(_args), do: {:error, :missing_symbol}

  def finance_quote(%{"symbol" => symbol}) when is_binary(symbol) and symbol != "",
    do: Finance.quote(symbol)

  def finance_quote(_args), do: {:error, :missing_symbol}

  def finance_news(%{"symbol" => symbol}) when is_binary(symbol) and symbol != "",
    do: Finance.news(symbol)

  def finance_news(_args), do: {:error, :missing_symbol}

  # -----------------------------------------------------------------------
  # Runtime
  # -----------------------------------------------------------------------

  def runtime_status(_args \\ %{}), do: {:ok, Status.snapshot()}

  def activity_report(args \\ %{}) do
    days =
      case Map.get(args, "days") do
        n when is_integer(n) and n > 0 -> n
        _ -> 7
      end

    {:ok, BusterClaw.ActivityReport.summary(days: days)}
  end

  # -----------------------------------------------------------------------
  # Visible terminal workspace
  # -----------------------------------------------------------------------

  def terminal_tab_open(args \\ %{}), do: TerminalWorkspace.open(args)

  # --- Orchestration shift (agent-drivable: the on-shift Claude starts/stops it) ---

  def shift_status(_args \\ %{}) do
    case Orchestration.active_shift() do
      nil ->
        {:ok, %{active: false}}

      shift ->
        {:ok,
         %{
           active: true,
           shift_id: shift.id,
           job_key: shift.job_key,
           job_name: shift.job_name,
           job_description: shift.job_description,
           agent_name: shift.agent_name,
           shell: shift.shell,
           unattended: shift.unattended,
           started_at: shift.started_at,
           dispatched: shift.dispatched_count,
           done: shift.done_count,
           failed: shift.failed_count
         }}
    end
  end

  def shift_start(args \\ %{}) do
    Orchestration.clear_kill_switch()

    case Orchestration.start_shift(args) do
      {:ok, shift} ->
        {:ok,
         %{
           shift_id: shift.id,
           status: shift.status,
           job_key: shift.job_key,
           job_name: shift.job_name,
           agent_name: shift.agent_name,
           shell: shift.shell,
           unattended: shift.unattended,
           started_at: shift.started_at
         }}

      {:error, _changeset} = error ->
        error
    end
  end

  def shift_stop(args \\ %{}) do
    reason = Map.get(args, "reason", "stopped by agent")

    case Orchestration.stop_shift(reason) do
      {:ok, shift} -> {:ok, %{shift_id: shift.id, status: shift.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def shift_assignment_start(args \\ %{}) do
    case Orchestration.start_shift_assignment(args) do
      {:ok, assignment} ->
        {:ok, assignment}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def shift_assignment_status(args \\ %{}), do: Orchestration.shift_assignment_status(args)

  def shift_assignment_stop(args \\ %{}) do
    case Orchestration.stop_shift_assignment(args) do
      {:ok, assignment} -> {:ok, assignment}
      {:error, reason} -> {:error, reason}
    end
  end

  # -----------------------------------------------------------------------
  # Dispatch queue (pull model)
  # -----------------------------------------------------------------------

  def dispatch_list(args \\ %{}) do
    items =
      case blank_to_nil(Map.get(args, "status")) do
        nil -> Dispatch.list_open()
        status -> Dispatch.list_items(status: status, limit: Map.get(args, "limit"))
      end

    {:ok, filter_by_job(items, blank_to_nil(Map.get(args, "job")))}
  end

  def dispatch_show(%{"id" => id}), do: safe_get(Dispatch, :get_item!, id)

  def dispatch_claim(args \\ %{}) do
    claimed_by =
      blank_to_nil(Map.get(args, "claimed_by")) || blank_to_nil(Map.get(args, "job")) || "agent"

    opts =
      [source: blank_to_nil(Map.get(args, "source")), role: blank_to_nil(Map.get(args, "job"))]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Dispatch.claim_next(claimed_by, opts) do
      {:ok, item} -> {:ok, item}
      {:error, :empty} -> {:ok, %{"empty" => true}}
      {:error, reason} -> {:error, reason}
    end
  end

  def dispatch_done(%{"id" => id} = args), do: finish_dispatch(id, "done", args)
  def dispatch_block(%{"id" => id} = args), do: finish_dispatch(id, "blocked", args)

  @doc """
  Send a threaded Gmail reply to a Dispatch item's sender and mark the item done.
  Restricted-tier: the act of calling it is the send authorization (no separate
  `confirm_send`). The reply threads via the stored RFC Message-ID + thread id and
  is sent from the account that received the original mail.
  """
  def dispatch_reply(%{"id" => id} = args) do
    with_resource(Dispatch, :get_item!, id, fn item ->
      cond do
        is_nil(blank_to_nil(Map.get(args, "body"))) -> {:error, :missing_body}
        is_nil(blank_to_nil(item.sender)) -> {:error, :no_reply_recipient}
        true -> send_dispatch_reply(item, blank_to_nil(Map.get(args, "body")), args)
      end
    end)
  end

  defp send_dispatch_reply(item, body, args) do
    selector =
      args
      |> Map.take(["account_id", "email"])
      |> put_new_string("email", blank_to_nil(item.source_account))

    with_google_account(selector, fn account ->
      case BusterClaw.Google.Gmail.send_message(account, reply_message_attrs(item, body)) do
        {:ok, sent} ->
          # The mail is already sent. If finishing the Dispatch item fails we must
          # NOT crash and report the whole reply as failed — surface the partial
          # success instead so the caller knows the send went through.
          thread_id = Map.get(sent, :thread_id) || item.gmail_thread_id

          BusterClaw.Sentinel.observe(
            :outbound_send,
            "Auto-replied to Dispatch item ##{item.id}",
            %{
              dispatch_item_id: item.id,
              to: item.sender,
              gmail_thread_id: item.gmail_thread_id
            }
          )

          case Dispatch.finish(item, "done", reply_finish_attrs(body)) do
            {:ok, finished} ->
              {:ok,
               %{
                 dispatch_item_id: finished.id,
                 status: finished.status,
                 to: item.sender,
                 subject: reply_subject(item.subject),
                 thread_id: thread_id
               }}

            {:error, reason} ->
              # Sent, but the item could not be marked done. Report partial success
              # rather than raising a MatchError.
              {:ok,
               %{
                 dispatch_item_id: item.id,
                 status: item.status,
                 sent: true,
                 finish_error: reason,
                 to: item.sender,
                 subject: reply_subject(item.subject),
                 thread_id: thread_id
               }}
          end

        error ->
          error
      end
    end)
  end

  defp reply_message_attrs(item, body) do
    %{
      "to" => item.sender,
      "subject" => reply_subject(item.subject),
      "body" => body,
      "in_reply_to" => item.gmail_rfc_message_id,
      "references" => item.gmail_rfc_message_id,
      "thread_id" => item.gmail_thread_id
    }
  end

  defp reply_subject(subject) do
    case blank_to_nil(subject) do
      nil -> "Re:"
      trimmed -> if Regex.match?(~r/^re:/i, trimmed), do: trimmed, else: "Re: " <> trimmed
    end
  end

  defp reply_finish_attrs(body) do
    %{outcome: "replied", notes: "Auto-replied: " <> String.slice(to_string(body), 0, 280)}
  end

  defp put_new_string(map, _key, nil), do: map

  defp put_new_string(map, key, value) do
    if Map.get(map, key) in [nil, ""], do: Map.put(map, key, value), else: map
  end

  # -----------------------------------------------------------------------
  # Job descriptions (the role roster)
  # -----------------------------------------------------------------------

  def job_list(_args \\ %{}), do: {:ok, Jobs.list()}

  def job_show(%{"key" => key}) do
    case Jobs.get(key) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end

  defp finish_dispatch(id, status, args) do
    with_resource(Dispatch, :get_item!, id, fn item ->
      attrs =
        case blank_to_nil(Map.get(args, "note")) do
          nil -> %{}
          note -> %{notes: note, outcome: note}
        end

      Dispatch.finish(item, status, attrs)
    end)
  end

  # -----------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp filter_by_job(items, nil), do: items
  defp filter_by_job(items, job), do: Enum.filter(items, &(&1.recommended_role_key == job))

  defp safe_get(module, fun, id) do
    {:ok, apply(module, fun, [id])}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp with_resource(module, getter, id, fun) do
    case safe_get(module, getter, id) do
      {:ok, resource} -> fun.(resource)
      error -> error
    end
  end

  defp with_google_account(args, fun) do
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
      Map.get(args, id_key) in [nil, ""] -> {:error, id_error}
      not is_list(requests) or requests == [] -> {:error, :missing_requests}
      true -> with_google_account(args, fn account -> fun.(account, Map.get(args, id_key), requests) end)
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
        with {:ok, meta} <- BusterClaw.Google.Drive.get(account, file_id) do
          {:ok, resolve_workspace_path(meta.name || to_string(file_id))}
        end
    end
  end

  defp resolve_workspace_path(path) do
    case Path.type(path) do
      :absolute -> Path.expand(path)
      _relative -> Path.expand(path, BusterClaw.Library.Artifact.workspace_root())
    end
  end

  # Reduce a downloaded filename to a safe basename (no path separators / traversal,
  # only word chars, dot and dash), so it can't escape the downloads folder.
  defp sanitize_download_name(name) do
    cleaned =
      name
      |> to_string()
      |> Path.basename()
      |> String.replace(~r/[^\w.\-]+/u, "_")
      |> String.trim("_")

    case cleaned do
      "" -> "download"
      "." -> "download"
      ".." -> "download"
      other -> other
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
