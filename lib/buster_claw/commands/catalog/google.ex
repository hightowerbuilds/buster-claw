defmodule BusterClaw.Commands.Catalog.Google do
  @moduledoc "Catalog entries: Google Workspace accounts, Gmail, Calendar, and Tasks."

  alias BusterClaw.Commands.Catalog.Helpers

  @doc "Google Workspace accounts + Gmail + Google Calendar + Tasks catalog entries."
  def entries,
    do: [
      # Google Workspace accounts
      Helpers.list_entry("google_account_list", "List configured Google Workspace accounts."),
      Helpers.get_entry("google_account_get", "Fetch a Google Workspace account summary."),
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
      Helpers.delete_entry("google_account_delete", "Delete a Google Workspace account."),
      %{
        name: "gmail_label_list",
        type: :read,
        tier: :safe,
        description: "List Gmail labels for a connected Google Workspace account.",
        args: Helpers.google_args(%{})
      },
      %{
        name: "gmail_search",
        type: :read,
        tier: :safe,
        description: "Search Gmail messages for a connected Google Workspace account.",
        args:
          Helpers.google_args(%{
            "query" => %{type: :string, required: false},
            "limit" => %{type: :integer, required: false, default: 10},
            "incremental" => %{type: :boolean, required: false, default: false},
            "start_history_id" => %{type: :string, required: false}
          })
      },
      %{
        name: "gmail_read",
        type: :read,
        tier: :safe,
        description: "Read one Gmail message by message ID.",
        args:
          Helpers.google_args(%{
            "message_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "gmail_sync",
        type: :trigger,
        tier: :safe,
        description: "Sync Gmail search results or history deltas into Library raw documents.",
        args:
          Helpers.google_args(%{
            "query" => %{type: :string, required: false},
            "limit" => %{type: :integer, required: false, default: 10},
            "incremental" => %{type: :boolean, required: false, default: false},
            "start_history_id" => %{type: :string, required: false}
          })
      },
      %{
        name: "gmail_draft_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Gmail draft for a connected Google Workspace account.",
        args:
          Helpers.google_args(%{
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
          })
      },
      %{
        name: "gmail_send",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Send a Gmail message from a connected Google Workspace account.",
        args:
          Helpers.google_args(%{
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
          })
      },
      %{
        name: "gmail_modify",
        type: :mutate,
        tier: :restricted,
        description:
          "Add/remove labels on a Gmail message (archive = remove INBOX, mark read = remove UNREAD).",
        args:
          Helpers.google_args(%{
            "message_id" => %{type: :string, required: true},
            "add" => %{type: :array, required: false, description: "Label IDs to add."},
            "remove" => %{type: :array, required: false, description: "Label IDs to remove."}
          })
      },
      %{
        name: "gmail_trash",
        type: :mutate,
        tier: :restricted,
        description: "Move a Gmail message to the trash (recoverable).",
        args:
          Helpers.google_args(%{
            "message_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "gmail_delete",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Permanently delete a Gmail message (irreversible).",
        args:
          Helpers.google_args(%{
            "message_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "google_calendar_sync",
        type: :trigger,
        tier: :safe,
        description: "One-way sync Google Calendar events into the app calendar.",
        args:
          Helpers.google_args(%{
            "calendar_id" => %{type: :string, required: false, default: "primary"},
            "days_ahead" => %{type: :integer, required: false, default: 90},
            "force_full" => %{type: :boolean, required: false, default: false}
          })
      },
      %{
        name: "gcal_event_create",
        type: :mutate,
        tier: :restricted,
        description:
          "Create a Google Calendar event. `event` is the raw Google event resource (summary/start/end/...).",
        args:
          Helpers.google_args(%{
            "calendar_id" => %{type: :string, required: false, default: "primary"},
            "event" => %{type: :object, required: true}
          })
      },
      %{
        name: "gcal_event_update",
        type: :mutate,
        tier: :restricted,
        description: "Patch a Google Calendar event. `event` holds the fields to change.",
        args:
          Helpers.google_args(%{
            "calendar_id" => %{type: :string, required: false, default: "primary"},
            "event_id" => %{type: :string, required: true},
            "event" => %{type: :object, required: true}
          })
      },
      %{
        name: "gcal_event_delete",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Delete a Google Calendar event (irreversible).",
        args:
          Helpers.google_args(%{
            "calendar_id" => %{type: :string, required: false, default: "primary"},
            "event_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "tasks_list",
        type: :read,
        tier: :safe,
        description:
          "List Google task lists, or the tasks in a list when `tasklist_id` is given.",
        args:
          Helpers.google_args(%{
            "tasklist_id" => %{type: :string, required: false}
          })
      },
      %{
        name: "tasks_get",
        type: :read,
        tier: :safe,
        description: "Read one Google task.",
        args:
          Helpers.google_args(%{
            "tasklist_id" => %{type: :string, required: true},
            "task_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "tasks_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Google task in a list.",
        args:
          Helpers.google_args(%{
            "tasklist_id" => %{type: :string, required: true},
            "title" => %{type: :string, required: true},
            "notes" => %{type: :string, required: false},
            "due" => %{type: :string, required: false, description: "RFC 3339 timestamp."},
            "status" => %{
              type: :string,
              required: false,
              description: "needsAction or completed."
            }
          })
      },
      %{
        name: "tasks_update",
        type: :mutate,
        tier: :restricted,
        description: "Patch a Google task (title/notes/due/status).",
        args:
          Helpers.google_args(%{
            "tasklist_id" => %{type: :string, required: true},
            "task_id" => %{type: :string, required: true},
            "title" => %{type: :string, required: false},
            "notes" => %{type: :string, required: false},
            "due" => %{type: :string, required: false},
            "status" => %{type: :string, required: false}
          })
      },
      %{
        name: "tasks_delete",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Delete a Google task (irreversible).",
        args:
          Helpers.google_args(%{
            "tasklist_id" => %{type: :string, required: true},
            "task_id" => %{type: :string, required: true}
          })
      }
    ]
end
