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
        name: "browser_read",
        type: :read,
        tier: :restricted,
        description:
          "Read the active browser tab's RENDERED page — title, visible text, and links — as the user's live session sees it (logged-in views included; Sentinel-audited). Requires the desktop app to be open.",
        args: %{}
      },
      %{
        name: "browser_capture_page",
        type: :trigger,
        tier: :restricted,
        description:
          "Capture the active browser tab into the Library: files the rendered page (title, text, links; Sentinel-audited via browser_read) as a markdown artifact, plus a best-effort screenshot into the workspace. Requires the desktop app to be open.",
        args: %{
          "title" => %{
            type: :string,
            required: false,
            description: "Override the artifact title (defaults to the page title, then the URL)."
          }
        }
      },
      %{
        name: "browser_find_elements",
        type: :read,
        tier: :restricted,
        description:
          "List the visible interactive elements (links, buttons, inputs) of the active browser tab — the user's live, logged-in session (Sentinel-audited). Returns indexed {i, tag, type, label, value, href} entries for browser_click/browser_fill. The index registry is per-page: navigation invalidates it, so re-run this after navigating. Requires the desktop app to be open.",
        args: %{
          "query" => %{
            type: :string,
            required: false,
            description: "Case-insensitive substring filter on element labels."
          }
        }
      },
      %{
        name: "browser_click",
        type: :mutate,
        tier: :restricted,
        description:
          "Click element #index from the latest browser_find_elements — this acts inside the user's live, logged-in session (Sentinel-audited with index + label). Indices go stale on navigation: call browser_find_elements again first. Requires the desktop app to be open.",
        args: %{
          "index" => %{
            type: :integer,
            required: true,
            description: "Element index from the latest browser_find_elements."
          }
        }
      },
      %{
        name: "browser_fill",
        type: :mutate,
        tier: :restricted,
        description:
          "Fill element #index (input/textarea/select) from the latest browser_find_elements with a value, dispatching input+change events — this types into the user's live, logged-in session (Sentinel-audited with index, label, and value length). Indices go stale on navigation: call browser_find_elements again first. Requires the desktop app to be open.",
        args: %{
          "index" => %{
            type: :integer,
            required: true,
            description: "Element index from the latest browser_find_elements."
          },
          "value" => %{
            type: :string,
            required: true,
            description: "The value to set on the element."
          }
        }
      },
      %{
        name: "browser_tabs",
        type: :read,
        tier: :restricted,
        description:
          "List the browser's open tabs (url, label, active index) from the durable tab state. Works even while the browser is hidden.",
        args: %{
          "surface" => %{
            type: :string,
            required: false,
            description: ~s|Browser surface id ("main" default; "left"/"right" for split panes).|
          }
        }
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
          "Open a new browser tab at a URL and make it active in the user's live view. By DEFAULT the tab is an ephemeral sandbox (non-persistent session — no user cookies, nothing saved, excluded from restore); pass session: \"user\" to explicitly ride the user's logged-in session. Provide a full http(s) URL including scheme. Requires the desktop app to be open.",
        args: %{
          "url" => %{type: :string, required: true},
          "session" => %{
            type: :string,
            required: false,
            description:
              ~s|"ephemeral" (default: sandboxed, no user cookies) or "user" (the user's live session).|
          }
        }
      },

      # Cloud browser (Browserbase) — the agent's own driven sessions.
      %{
        name: "web_session_open",
        type: :trigger,
        tier: :restricted,
        description:
          "Open an agent-driven CLOUD browser session (Browserbase) — separate from the user's local tabs. Returns a session_id to pass to every other web_* command, plus a live_view_url the user can watch. Optionally pass url to navigate immediately.",
        args: %{
          "url" => %{
            type: :string,
            required: false,
            description: "Navigate here immediately after opening (full http(s) URL)."
          }
        }
      },
      %{
        name: "web_session_close",
        type: :trigger,
        tier: :restricted,
        description:
          "Close an agent cloud session and release the cloud browser (stops billing). Idempotent.",
        args: %{"session_id" => %{type: :string, required: true}}
      },
      %{
        name: "web_session_list",
        type: :read,
        tier: :restricted,
        description:
          "List the open agent cloud sessions (session_id, live_view_url, timestamps).",
        args: %{}
      },
      %{
        name: "web_navigate",
        type: :trigger,
        tier: :restricted,
        description:
          "Navigate an agent cloud session to a URL (SSRF-guarded, full http(s) URL). Sentinel-audited.",
        args: %{
          "session_id" => %{type: :string, required: true},
          "url" => %{type: :string, required: true}
        }
      },
      %{
        name: "web_read",
        type: :read,
        tier: :restricted,
        description:
          "Read an agent cloud session's rendered page as markdown (title + content, 200 KB cap). Sentinel-audited.",
        args: %{"session_id" => %{type: :string, required: true}}
      },
      %{
        name: "web_find_elements",
        type: :read,
        tier: :restricted,
        description:
          "List interactive elements of an agent cloud session's page — returns stable CSS selectors + roles/labels for web_fill/web_select/web_click. Sentinel-audited.",
        args: %{
          "session_id" => %{type: :string, required: true},
          "query" => %{
            type: :string,
            required: false,
            description: "Case-insensitive substring filter on element labels."
          }
        }
      },
      %{
        name: "web_fill",
        type: :mutate,
        tier: :restricted,
        description:
          "Fill a form field (by CSS selector) in an agent cloud session. Sentinel-audited with the value's length only — never the raw value.",
        args: %{
          "session_id" => %{type: :string, required: true},
          "selector" => %{type: :string, required: true},
          "value" => %{type: :string, required: true}
        }
      },
      %{
        name: "web_select",
        type: :mutate,
        tier: :restricted,
        description:
          "Select a dropdown option (by CSS selector) in an agent cloud session. Sentinel-audited.",
        args: %{
          "session_id" => %{type: :string, required: true},
          "selector" => %{type: :string, required: true},
          "value" => %{
            type: :string,
            required: true,
            description: "Option value or visible label to select."
          }
        }
      },
      %{
        name: "web_click",
        type: :mutate,
        tier: :restricted,
        description:
          "Click an element (by CSS selector) in an agent cloud session. REFUSES submit/pay/checkout-shaped selectors — purchasing is Phase 4, gated. Sentinel-audited.",
        args: %{
          "session_id" => %{type: :string, required: true},
          "selector" => %{type: :string, required: true}
        }
      },
      %{
        name: "web_screenshot",
        type: :trigger,
        tier: :restricted,
        description:
          "Capture a PNG of an agent cloud session's page into the workspace downloads folder. Returns the saved path.",
        args: %{"session_id" => %{type: :string, required: true}}
      },
      %{
        name: "web_extract",
        type: :read,
        tier: :restricted,
        description:
          "Extract structured data from an agent cloud session via a selector map: spec = %{\"fields\" => %{name => css_selector}} for one object, or %{\"type\" => \"list\", \"item\" => css, \"fields\" => %{...}} for rows. Sentinel-audited.",
        args: %{
          "session_id" => %{type: :string, required: true},
          "spec" => %{
            type: :map,
            required: true,
            description: "Selector map (field → CSS selector), or a list spec with item + fields."
          }
        }
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
      },
      %{
        name: "history_search",
        type: :read,
        tier: :safe,
        description: "Search the in-app browser's visit history (FTS-ranked by relevance).",
        args: %{
          "query" => %{type: :string, required: true},
          "limit" => %{
            type: :integer,
            required: false,
            description: "Max results (default 20, cap 100)."
          }
        }
      },
      %{
        name: "history_recent",
        type: :read,
        tier: :safe,
        description: "Recently visited pages from the in-app browser (newest visit per URL).",
        args: %{
          "limit" => %{
            type: :integer,
            required: false,
            description: "Max results (default 20, cap 100)."
          }
        }
      }
    ]
end
