defmodule BusterClaw.Commands.Catalog.Web do
  @moduledoc "Catalog entries: web search, browser, and bookmarks."

  @doc "Search + Browser + Bookmarks catalog entries."
  def entries,
    do: [
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
        description: "Save a browser bookmark with optional tags and folder.",
        args: %{
          "url" => %{type: :string, required: true},
          "label" => %{type: :string, required: false},
          "tags" => %{type: :array, required: false},
          "folder" => %{
            type: :string,
            required: false,
            description: "Folder to file the bookmark under (blank = root)."
          }
        }
      },
      %{
        name: "bookmark_list",
        type: :read,
        tier: :safe,
        description: "List bookmarks, optionally filtered by tag and/or folder.",
        args: %{
          "tag" => %{type: :string, required: false},
          "folder" => %{
            type: :string,
            required: false,
            description: "Only list bookmarks in this folder (blank = root)."
          }
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
      %{
        name: "bookmark_export",
        type: :read,
        tier: :safe,
        description:
          "Export all bookmarks as a portable string: JSON (default) or Netscape bookmark HTML.",
        args: %{
          "format" => %{
            type: :string,
            required: false,
            description: ~s|Output format: "json" (default) or "html".|
          }
        }
      },
      %{
        name: "bookmark_import",
        type: :mutate,
        tier: :restricted,
        description:
          "Merge a bookmark list into the store, deduped by URL (tags unioned, blank folders filled). New URLs are appended.",
        args: %{
          "bookmarks" => %{
            type: :array,
            required: false,
            description: "Bookmarks to merge — an array of {url, label, tags, folder} maps."
          },
          "json" => %{
            type: :string,
            required: false,
            description: "Alternatively, a JSON string encoding the same array."
          }
        }
      }
    ]
end
