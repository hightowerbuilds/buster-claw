defmodule BusterClaw.Commands.Catalog.GoogleFiles do
  @moduledoc "Catalog entries: Google Drive, Docs, Sheets, and Slides."

  alias BusterClaw.Commands.Catalog.Helpers

  @doc "Google Drive + Docs + Sheets + Slides catalog entries."
  def entries,
    do: [
      # Google Drive
      %{
        name: "drive_list",
        type: :read,
        tier: :safe,
        description: "List/search Google Drive files. `q` is a Drive query string.",
        args:
          Helpers.google_args(%{
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
          Helpers.google_args(%{
            "file_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "drive_download",
        type: :read,
        tier: :safe,
        description: "Download a Drive file's bytes into the workspace. Returns the saved path.",
        args:
          Helpers.google_args(%{
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
          Helpers.google_args(%{
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
          Helpers.google_args(%{
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
          Helpers.google_args(%{
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
          Helpers.google_args(%{
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
          Helpers.google_args(%{
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
          Helpers.google_args(%{
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
          Helpers.google_args(%{
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
          Helpers.google_args(%{
            "document_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "docs_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Google Doc with a title.",
        args:
          Helpers.google_args(%{
            "title" => %{type: :string, required: true}
          })
      },
      %{
        name: "docs_batch_update",
        type: :mutate,
        tier: :restricted,
        description: "Apply edit requests to a Google Doc (insertText, replaceAllText, …).",
        args:
          Helpers.google_args(%{
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
          Helpers.google_args(%{
            "spreadsheet_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "sheets_get_values",
        type: :read,
        tier: :safe,
        description: "Read a range of cell values from a Google Sheet (A1 notation).",
        args:
          Helpers.google_args(%{
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
          Helpers.google_args(%{
            "title" => %{type: :string, required: true}
          })
      },
      %{
        name: "sheets_update_values",
        type: :mutate,
        tier: :restricted,
        description: "Overwrite a range with values (USER_ENTERED).",
        args:
          Helpers.google_args(%{
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
          Helpers.google_args(%{
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
          Helpers.google_args(%{
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
          Helpers.google_args(%{
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
          Helpers.google_args(%{
            "presentation_id" => %{type: :string, required: true}
          })
      },
      %{
        name: "slides_create",
        type: :mutate,
        tier: :restricted,
        description: "Create a Google Slides presentation with a title.",
        args:
          Helpers.google_args(%{
            "title" => %{type: :string, required: true}
          })
      },
      %{
        name: "slides_batch_update",
        type: :mutate,
        tier: :restricted,
        description: "Apply edit requests to a presentation (createSlide, insertText, …).",
        args:
          Helpers.google_args(%{
            "presentation_id" => %{type: :string, required: true},
            "requests" => %{
              type: :array,
              required: true,
              description: "Google Slides request list."
            }
          })
      }
    ]
end
