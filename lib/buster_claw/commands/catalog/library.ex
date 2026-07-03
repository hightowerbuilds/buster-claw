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
