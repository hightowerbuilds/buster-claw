defmodule BusterClaw.Commands.Catalog do
  @moduledoc """
  The native command catalog: a pure, constant list of command metadata
  (`name`, `type`, `tier`, gating, arg schema, `description`).

  Split out of `BusterClaw.Commands` so the facade carries dispatch/policy logic
  while this module carries the large, declarative data. `entries/0` is rebuilt
  on each call; `BusterClaw.Commands` memoizes it in `:persistent_term`, so this
  stays a plain function (a module attribute can't call local functions at
  compile time, which is why the catalog is assembled at runtime).
  """

  @id_required %{"id" => %{type: :integer, required: true}}

  # Google commands all accept an optional account selector — `account_id` or
  # `email` — to choose which connected Workspace account to act as. `google_args/1`
  # merges that shared pair into each command's own args, so the selector is
  # defined once here instead of repeated on every Google entry.
  @google_account %{
    "account_id" => %{type: :integer, required: false},
    "email" => %{type: :string, required: false}
  }

  defp google_args(extra), do: Map.merge(@google_account, extra)

  defp list_entry(name, desc),
    do: %{name: name, type: :read, tier: :safe, description: desc, args: %{}}

  defp get_entry(name, desc),
    do: %{name: name, type: :read, tier: :safe, description: desc, args: @id_required}

  # Deletes are irreversible, so they are `gated`: an autonomous run working
  # untrusted-origin content (`:agent_untrusted`) cannot fire them — they surface
  # for human approval instead. See `command_gated?/1` and `PolicyEngine.check/1`.
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

  @doc "Return the native command catalog as a list of metadata maps."
  def entries,
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

      # Wallets (financial management: ledger + budgets)
      list_entry("wallet_list", "List wallets."),
      get_entry("wallet_get", "Fetch a wallet by ID."),
      %{
        name: "wallet_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a wallet (business or personal).",
        args: %{
          "name" => %{type: :string, required: true},
          "type" => %{type: :string, required: false, enum: ["business", "personal"]},
          "currency" => %{type: :string, required: false, default: "USD"}
        }
      },
      %{
        name: "wallet_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a wallet.",
        args: %{
          "id" => %{type: :integer, required: true},
          "name" => %{type: :string, required: false},
          "type" => %{type: :string, required: false, enum: ["business", "personal"]},
          "currency" => %{type: :string, required: false},
          "archived" => %{type: :boolean, required: false}
        }
      },
      delete_entry("wallet_delete", "Delete a wallet and its transactions."),
      %{
        name: "wallet_list_transactions",
        type: :read,
        tier: :safe,
        description: "List a wallet's ledger transactions.",
        args: %{"wallet_id" => %{type: :integer, required: true}}
      },
      %{
        name: "wallet_add_transaction",
        type: :mutate,
        tier: :restricted,
        description: "Add an income or expense transaction to a wallet's ledger.",
        args: %{
          "wallet_id" => %{type: :integer, required: true},
          "kind" => %{type: :string, required: true, enum: ["income", "expense"]},
          "amount_cents" => %{type: :integer, required: true},
          "category" => %{type: :string, required: false},
          "description" => %{type: :string, required: false},
          "occurred_on" => %{type: :string, required: false},
          "source" => %{type: :string, required: false}
        }
      },
      %{
        name: "wallet_set_budget",
        type: :mutate,
        tier: :restricted,
        description: "Set (or update) a wallet's monthly budget targets.",
        args: %{
          "wallet_id" => %{type: :integer, required: true},
          "month" => %{type: :string, required: true},
          "income_target_cents" => %{type: :integer, required: false},
          "expense_target_cents" => %{type: :integer, required: false},
          "savings_target_cents" => %{type: :integer, required: false}
        }
      },
      %{
        name: "wallet_budget_summary",
        type: :read,
        tier: :safe,
        description: "Budget actuals vs. targets for a wallet/month.",
        args: %{
          "wallet_id" => %{type: :integer, required: true},
          "month" => %{type: :string, required: true}
        }
      },
      %{
        name: "wallet_feed_list",
        type: :read,
        tier: :safe,
        description: "List a wallet's external polling feeds.",
        args: %{"wallet_id" => %{type: :integer, required: true}}
      },
      %{
        name: "wallet_feed_create",
        type: :mutate,
        tier: :restricted,
        description: "Add a polling feed (market/url/integration/gmail) to a wallet.",
        args: %{
          "wallet_id" => %{type: :integer, required: true},
          "kind" => %{
            type: :string,
            required: true,
            enum: ["market", "url", "integration", "gmail"]
          },
          "config" => %{type: :map, required: false},
          "polling_interval_minutes" => %{type: :integer, required: false, default: 60},
          "enabled" => %{type: :boolean, required: false, default: true}
        }
      },
      %{
        name: "wallet_feed_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a wallet feed.",
        args: %{
          "id" => %{type: :integer, required: true},
          "config" => %{type: :map, required: false},
          "polling_interval_minutes" => %{type: :integer, required: false},
          "enabled" => %{type: :boolean, required: false}
        }
      },
      delete_entry("wallet_feed_delete", "Delete a wallet feed."),
      id_trigger_entry("wallet_poll", "Poll a wallet's external feeds now.", :restricted),

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
        args: @google_account
      },
      %{
        name: "gmail_search",
        type: :read,
        tier: :safe,
        description: "Search Gmail messages for a connected Google Workspace account.",
        args:
          google_args(%{
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
          google_args(%{
            "message_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "gmail_sync",
        type: :trigger,
        tier: :safe,
        description: "Sync Gmail search results or history deltas into Library raw documents.",
        args:
          google_args(%{
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
          google_args(%{
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
          google_args(%{
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
          google_args(%{
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
          google_args(%{
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
          google_args(%{
            "message_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "google_calendar_sync",
        type: :trigger,
        tier: :safe,
        description: "One-way sync Google Calendar events into the app calendar.",
        args:
          google_args(%{
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
          google_args(%{
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
          google_args(%{
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
          google_args(%{
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
          google_args(%{
            "tasklist_id" => %{type: :string, required: false}
          })
      },
      %{
        name: "tasks_get",
        type: :read,
        tier: :safe,
        description: "Read one Google task.",
        args:
          google_args(%{
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
          google_args(%{
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
          google_args(%{
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
          google_args(%{
            "tasklist_id" => %{type: :string, required: true},
            "task_id" => %{type: :string, required: true}
          })
      },

      # Google Drive
      %{
        name: "drive_list",
        type: :read,
        tier: :safe,
        description: "List/search Google Drive files. `q` is a Drive query string.",
        args:
          google_args(%{
            "q" => %{type: :string, required: false},
            "order_by" => %{type: :string, required: false},
            "page_size" => %{type: :integer, required: false, default: 50},
            "page_token" => %{type: :string, required: false}
          })
      },
      %{
        name: "drive_get",
        type: :read,
        tier: :safe,
        description: "Get a Google Drive file's metadata.",
        args:
          google_args(%{
            "file_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "drive_download",
        type: :read,
        tier: :safe,
        description: "Download a Drive file's bytes into the workspace. Returns the saved path.",
        args:
          google_args(%{
            "file_id" => %{type: :string, required: true},
            "destination" => %{
              type: :string,
              required: false,
              description: "Workspace-relative (or absolute) path to write to."
            }
          })
      },
      %{
        name: "drive_export",
        type: :read,
        tier: :safe,
        description:
          "Export a Google-native doc (Docs/Sheets/Slides) to a MIME type into the workspace.",
        args:
          google_args(%{
            "file_id" => %{type: :string, required: true},
            "mime_type" => %{type: :string, required: true},
            "destination" => %{type: :string, required: false}
          })
      },
      %{
        name: "drive_folder_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a folder in Google Drive.",
        args:
          google_args(%{
            "name" => %{type: :string, required: true},
            "parent_id" => %{type: :string, required: false}
          })
      },
      %{
        name: "drive_upload",
        type: :mutate,
        tier: :restricted,
        description: "Upload a local workspace file to Google Drive.",
        args:
          google_args(%{
            "path" => %{
              type: :string,
              required: true,
              description: "Local file path (workspace-relative or absolute) to upload."
            },
            "name" => %{
              type: :string,
              required: false,
              description: "Drive file name; defaults to the basename."
            },
            "parent_id" => %{type: :string, required: false},
            "content_type" => %{type: :string, required: false}
          })
      },
      %{
        name: "drive_update",
        type: :mutate,
        tier: :restricted,
        description: "Rename/star a Drive file, or move it via add_parents/remove_parents.",
        args:
          google_args(%{
            "file_id" => %{type: :string, required: true},
            "name" => %{type: :string, required: false},
            "starred" => %{type: :boolean, required: false},
            "add_parents" => %{type: :string, required: false},
            "remove_parents" => %{type: :string, required: false}
          })
      },
      %{
        name: "drive_copy",
        type: :mutate,
        tier: :restricted,
        description: "Copy a Drive file.",
        args:
          google_args(%{
            "file_id" => %{type: :string, required: true},
            "name" => %{type: :string, required: false},
            "parent_id" => %{type: :string, required: false}
          })
      },
      %{
        name: "drive_share",
        type: :mutate,
        tier: :restricted,
        description:
          "Grant a permission on a Drive file (may email the grantee). Requires confirm_share.",
        args:
          google_args(%{
            "file_id" => %{type: :string, required: true},
            "role" => %{
              type: :string,
              required: true,
              description: "reader/commenter/writer/owner."
            },
            "type" => %{type: :string, required: true, description: "user/group/domain/anyone."},
            "grantee_email" => %{type: :string, required: false},
            "notify" => %{type: :boolean, required: false, default: false},
            "confirm_share" => %{type: :boolean, required: true, default: false}
          })
      },
      %{
        name: "drive_delete",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Permanently delete a Drive file (irreversible, bypasses trash).",
        args:
          google_args(%{
            "file_id" => %{type: :string, required: true}
          })
      },

      # Google Docs
      %{
        name: "docs_get",
        type: :read,
        tier: :safe,
        description: "Get a Google Doc's structure/content.",
        args:
          google_args(%{
            "document_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "docs_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Google Doc with a title.",
        args:
          google_args(%{
            "title" => %{type: :string, required: true}
          })
      },
      %{
        name: "docs_batch_update",
        type: :mutate,
        tier: :restricted,
        description: "Apply edit requests to a Google Doc (insertText, replaceAllText, …).",
        args:
          google_args(%{
            "document_id" => %{type: :string, required: true},
            "requests" => %{
              type: :array,
              required: true,
              description: "Google Docs request list."
            }
          })
      },

      # Google Sheets
      %{
        name: "sheets_get",
        type: :read,
        tier: :safe,
        description: "Get a Google Sheet's metadata.",
        args:
          google_args(%{
            "spreadsheet_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "sheets_get_values",
        type: :read,
        tier: :safe,
        description: "Read a range of cell values from a Google Sheet (A1 notation).",
        args:
          google_args(%{
            "spreadsheet_id" => %{type: :string, required: true},
            "range" => %{type: :string, required: true}
          })
      },
      %{
        name: "sheets_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Google Sheet with a title.",
        args:
          google_args(%{
            "title" => %{type: :string, required: true}
          })
      },
      %{
        name: "sheets_update_values",
        type: :mutate,
        tier: :restricted,
        description: "Overwrite a range with values (USER_ENTERED).",
        args:
          google_args(%{
            "spreadsheet_id" => %{type: :string, required: true},
            "range" => %{type: :string, required: true},
            "values" => %{type: :array, required: true, description: "2-D array of row values."}
          })
      },
      %{
        name: "sheets_append_values",
        type: :mutate,
        tier: :restricted,
        description: "Append rows after a range/table.",
        args:
          google_args(%{
            "spreadsheet_id" => %{type: :string, required: true},
            "range" => %{type: :string, required: true},
            "values" => %{type: :array, required: true, description: "2-D array of row values."}
          })
      },
      %{
        name: "sheets_clear_values",
        type: :mutate,
        tier: :restricted,
        description: "Clear the values in a range (keeps formatting).",
        args:
          google_args(%{
            "spreadsheet_id" => %{type: :string, required: true},
            "range" => %{type: :string, required: true}
          })
      },
      %{
        name: "sheets_batch_update",
        type: :mutate,
        tier: :restricted,
        description: "Apply structural edit requests to a Sheet (add/delete sheets, formatting).",
        args:
          google_args(%{
            "spreadsheet_id" => %{type: :string, required: true},
            "requests" => %{
              type: :array,
              required: true,
              description: "Google Sheets request list."
            }
          })
      },

      # Google Slides
      %{
        name: "slides_get",
        type: :read,
        tier: :safe,
        description: "Get a Google Slides presentation.",
        args:
          google_args(%{
            "presentation_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "slides_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Google Slides presentation with a title.",
        args:
          google_args(%{
            "title" => %{type: :string, required: true}
          })
      },
      %{
        name: "slides_batch_update",
        type: :mutate,
        tier: :restricted,
        description: "Apply edit requests to a presentation (createSlide, insertText, …).",
        args:
          google_args(%{
            "presentation_id" => %{type: :string, required: true},
            "requests" => %{
              type: :array,
              required: true,
              description: "Google Slides request list."
            }
          })
      },

      # Contacts (People)
      %{
        name: "contacts_list",
        type: :read,
        tier: :safe,
        description: "List the account's Google Contacts.",
        args:
          google_args(%{
            "page_size" => %{type: :integer, required: false, default: 100},
            "page_token" => %{type: :string, required: false},
            "sync_token" => %{type: :string, required: false}
          })
      },
      %{
        name: "contacts_search",
        type: :read,
        tier: :safe,
        description: "Search the account's Google Contacts.",
        args:
          google_args(%{
            "query" => %{type: :string, required: true}
          })
      },
      %{
        name: "contacts_get",
        type: :read,
        tier: :safe,
        description: "Get one contact by resource name (e.g. people/c123).",
        args:
          google_args(%{
            "resource_name" => %{type: :string, required: true}
          })
      },
      %{
        name: "contacts_create",
        type: :mutate,
        tier: :restricted,
        description:
          "Create a contact. Provide a raw `contact` Person resource, or given_name/family_name/contact_email/phone.",
        args:
          google_args(%{
            "contact" => %{type: :object, required: false},
            "given_name" => %{type: :string, required: false},
            "family_name" => %{type: :string, required: false},
            "contact_email" => %{type: :string, required: false},
            "phone" => %{type: :string, required: false}
          })
      },
      %{
        name: "contacts_update",
        type: :mutate,
        tier: :restricted,
        description: "Update a contact. Requires the current etag (from contacts_get).",
        args:
          google_args(%{
            "resource_name" => %{type: :string, required: true},
            "etag" => %{type: :string, required: true},
            "contact" => %{type: :object, required: false},
            "given_name" => %{type: :string, required: false},
            "family_name" => %{type: :string, required: false},
            "contact_email" => %{type: :string, required: false},
            "phone" => %{type: :string, required: false}
          })
      },
      %{
        name: "contacts_delete",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Delete a contact (irreversible).",
        args:
          google_args(%{
            "resource_name" => %{type: :string, required: true}
          })
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
      %{
        name: "browser_screenshot",
        type: :trigger,
        tier: :restricted,
        description:
          "Capture a PNG of the active browser tab the user is currently viewing, saved into the workspace. Returns the path + URL. Requires the desktop app to be open.",
        args: %{}
      },
      %{
        name: "browser_current",
        type: :read,
        tier: :restricted,
        description:
          "Read the active browser tab the user is currently viewing: returns its URL and page title. Requires the desktop app to be open.",
        args: %{}
      },
      %{
        name: "browser_navigate",
        type: :trigger,
        tier: :restricted,
        description:
          "Navigate the active browser tab to a URL, driving the user's live view. Provide a full http(s) URL including scheme. Requires the desktop app to be open.",
        args: %{"url" => %{type: :string, required: true}}
      },
      %{
        name: "browser_open_tab",
        type: :trigger,
        tier: :restricted,
        description:
          "Open a new browser tab at a URL and make it active in the user's live view. Provide a full http(s) URL including scheme. Requires the desktop app to be open.",
        args: %{"url" => %{type: :string, required: true}}
      },

      # Bookmarks
      %{
        name: "bookmark_add",
        type: :mutate,
        tier: :restricted,
        description: "Save a browser bookmark with optional tags.",
        args: %{
          "url" => %{type: :string, required: true},
          "label" => %{type: :string, required: false},
          "tags" => %{type: :array, required: false}
        }
      },
      %{
        name: "bookmark_list",
        type: :read,
        tier: :safe,
        description: "List bookmarks, optionally filtered by tag.",
        args: %{
          "tag" => %{type: :string, required: false}
        }
      },
      %{
        name: "bookmark_remove",
        type: :mutate,
        tier: :restricted,
        description: "Remove a bookmark by URL.",
        args: %{
          "url" => %{type: :string, required: true}
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
        name: "dispatch_strategy",
        type: :mutate,
        tier: :restricted,
        description:
          "Set a queued Dispatch item's execution strategy (single | swarm). Swarm opts it into the parallel coordinator.",
        args: %{
          "id" => %{type: :integer, required: true},
          "strategy" => %{type: :string, required: true}
        }
      },
      %{
        name: "dispatch_enqueue",
        type: :mutate,
        tier: :restricted,
        description:
          "Enqueue a manual Dispatch item (operator/agent worklist entry, not from Gmail). strategy=swarm opts it into the parallel coordinator.",
        args: %{
          "summary" => %{type: :string, required: true},
          "subject" => %{type: :string, required: false},
          "source" => %{type: :string, required: false},
          "strategy" => %{type: :string, required: false},
          "trusted" => %{type: :boolean, required: false}
        }
      },
      %{
        name: "dispatch_reply",
        type: :mutate,
        tier: :restricted,
        description:
          "Send a threaded Gmail reply to a Dispatch item's sender and mark the item done.",
        args:
          google_args(%{
            "id" => %{type: :integer, required: true},
            "body" => %{type: :string, required: true}
          })
      },
      # Cross-run memory (Phase 2) — recall what past runs did.
      %{
        name: "memory_search",
        type: :read,
        tier: :safe,
        description: "Full-text search past agent run summaries (what was done before).",
        args: %{
          "query" => %{type: :string, required: true},
          "limit" => %{type: :integer, required: false}
        }
      },
      # Self-improvement (Phase 3) — propose, review, and approve composition skills.
      %{
        name: "skill_analyze",
        type: :trigger,
        tier: :restricted,
        description: "Scan command history for repeated sequences and file skill suggestions.",
        args: %{"min_occurrences" => %{type: :integer, required: false}}
      },
      %{
        name: "skill_suggestions",
        type: :read,
        tier: :safe,
        description: "List proposed (pending) composition skills.",
        args: %{
          "status" => %{type: :string, required: false},
          "limit" => %{type: :integer, required: false}
        }
      },
      # Approving a suggestion creates an *enabled* skill, so it is gated — a human
      # action, never an autonomous untrusted one (threat model T5).
      %{
        name: "skill_suggestion_approve",
        type: :mutate,
        tier: :restricted,
        gated: true,
        description: "Approve a suggestion: write the enabled skill file.",
        args: %{"id" => %{type: :integer, required: true}}
      },
      %{
        name: "skill_suggestion_reject",
        type: :mutate,
        tier: :restricted,
        description: "Reject a proposed skill suggestion.",
        args: %{"id" => %{type: :integer, required: true}}
      }
    ]
end
