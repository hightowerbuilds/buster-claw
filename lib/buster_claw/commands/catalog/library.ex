defmodule BusterClaw.Commands.Catalog.Library do
  @moduledoc "Catalog entries: library documents and calendar events."

  alias BusterClaw.Commands.Catalog.Helpers

  @doc "Documents + Events catalog entries."
  def entries,
    do: [
      # Documents
      Helpers.list_entry("document_list", "List all indexed documents."),
      Helpers.get_entry("document_get", "Fetch a document by ID."),
      Helpers.get_entry("document_read", "Read the raw markdown contents of a document."),
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
      Helpers.delete_entry("document_delete", "Delete a document's file and mark it deleted."),

      # Journal (the Activity record — the one activity log, on the Activity tab)
      %{
        name: "journal_append",
        type: :mutate,
        tier: :restricted,
        description:
          "Append a timestamped entry to the Activity record — THE one place Buster Claw activity is logged, shown on the homepage Activity tab. Every command run, reply sent, and notable decision goes here; there is no second activity log.",
        args: %{
          "text" => %{type: :string, required: true}
        }
      },
      %{
        name: "journal_read",
        type: :read,
        tier: :safe,
        description: "Read one day's Activity record (the homepage Activity tab's document).",
        args: %{
          "date" => %{
            type: :string,
            required: false,
            description: "ISO 8601 date; defaults to today"
          }
        }
      },

      # Notes (the operator's notebook — NOT the activity log). No delete: the
      # destructive verb stays a human one, behind the UI's confirmation.
      #
      # All three reads are `:restricted`, unlike `journal_read`, `document_read`
      # and `memory_search`, which are `:safe` reads of the same workspace. The
      # difference is whose writing it is: the journal is the agent's own record
      # and the Library is artifacts it produced, while `notes/` is the
      # operator's private writing — including the titles, which is why even
      # `note_list` is not safe-tier.
      #
      # Be clear about what this does and does not buy. `:restricted` gates the
      # `:agent` and `:mcp` callers; it does NOT gate `:agent_untrusted`, which
      # the baseline stops only at `gated` commands. So an autonomous run working
      # untrusted-origin content can still read the notebook. What contains that
      # is the other half: every outbound send is `gated`, so the read cannot
      # leave the machine without a human in the loop. Reads were not marked
      # `gated` because that flag means outbound/irreversible, and diluting it
      # would weaken the check that is actually doing the work.
      %{
        name: "note_list",
        type: :read,
        tier: :restricted,
        description:
          "List the operator's notes (paths and titles, no bodies). Notes is the operator's own Markdown notebook on the homepage Notes tab — never the activity log; that is journal_append.",
        args: %{}
      },
      %{
        name: "note_read",
        type: :read,
        tier: :restricted,
        description:
          "Read one note. Returns its body and the revision you must pass back to note_save.",
        args: %{
          "path" => %{
            type: :string,
            required: true,
            description: "Vault-relative path, e.g. Projects/Launch.md"
          }
        }
      },
      %{
        name: "note_search",
        type: :read,
        tier: :restricted,
        description: "Search note titles and bodies; returns paths with a short snippet.",
        args: %{"query" => %{type: :string, required: true}}
      },
      %{
        name: "note_create",
        type: :mutate,
        tier: :restricted,
        description:
          "Create a note in the operator's notebook, optionally with a body. Only when the operator asked for a note; findings and reports belong in the Library (document_save).",
        args: %{
          "title" => %{type: :string, required: true},
          "folder" => %{
            type: :string,
            required: false,
            description: "Existing vault folder; defaults to the vault root"
          },
          "body" => %{type: :string, required: false}
        }
      },
      %{
        name: "note_save",
        type: :mutate,
        tier: :restricted,
        description:
          "Overwrite a note. Requires the revision from note_read; if the file changed since, the save is refused with the current revision so you can re-read and merge rather than silently winning.",
        args: %{
          "path" => %{type: :string, required: true},
          "body" => %{type: :string, required: true},
          "revision" => %{
            type: :string,
            required: true,
            description: "The revision returned by note_read"
          }
        }
      },

      # Events
      Helpers.list_entry("event_list", "List all calendar events."),
      Helpers.get_entry("event_get", "Fetch an event by ID."),
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
      Helpers.delete_entry("event_delete", "Delete a calendar event.")
    ]
end
