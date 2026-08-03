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
        description:
          "Fetch a URL and convert to markdown. JS-heavy pages that come back empty over plain HTTP are automatically re-rendered in a hidden ephemeral desktop webview (never the user's session) when the app is open.",
        args: %{
          "url" => %{type: :string, required: true},
          "render" => %{
            type: :string,
            required: false,
            description: "\"live\" forces the hidden-webview render; \"off\" forbids it."
          }
        }
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
        name: "browser_control_probe",
        type: :trigger,
        tier: :restricted,
        description:
          "Diagnostic: prove the BrowserControl engine end to end — detect an installed Chromium-family browser, launch it headless over the CDP pipe, navigate, read a page title back, and exit cleanly. Returns the report either way (ok: true/false); never launders the failing step.",
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
          "Click an element in the active tab — this acts inside the user's live, logged-in session (Sentinel-audited with target, label, and how it matched). Target exactly one of: selector (CSS), text (exact-then-substring match on visible actionable elements), or index from the latest browser_find_elements. Selector/text resolve at click time; indices go stale on navigation (call browser_find_elements again first). Requires the desktop app to be open.",
        args: %{
          "selector" => %{
            type: :string,
            required: false,
            description: "CSS selector of the element to click."
          },
          "text" => %{
            type: :string,
            required: false,
            description: "Visible text of the element to click (exact match, then substring)."
          },
          "index" => %{
            type: :integer,
            required: false,
            description: "Element index from the latest browser_find_elements."
          }
        }
      },
      %{
        name: "browser_fill",
        type: :mutate,
        tier: :restricted,
        description:
          "Fill a fillable element (input/textarea/select) in the active tab with a value, dispatching input+change events — this types into the user's live, logged-in session (Sentinel-audited with target, label, how it matched, and value length). Target exactly one of: selector (CSS), text (exact-then-substring match on visible actionable elements), or index from the latest browser_find_elements. Selector/text resolve at fill time; indices go stale on navigation (call browser_find_elements again first). Requires the desktop app to be open.",
        args: %{
          "selector" => %{
            type: :string,
            required: false,
            description: "CSS selector of the element to fill."
          },
          "text" => %{
            type: :string,
            required: false,
            description: "Visible text of the element to fill (exact match, then substring)."
          },
          "index" => %{
            type: :integer,
            required: false,
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
      %{
        name: "browser_wait",
        type: :read,
        # The only :safe-tier co-presence command, and a deliberate one
        # (operator-ratified 07-18): it returns just matched: true/false, so no
        # page content reaches the agent, and frictionless polling is the whole
        # point of a wait primitive. The accepted trade: it is a yes/no oracle
        # about the live tab. Don't "fix" this to :restricted without revisiting
        # that call — every wait inside a flow pays the tier.
        tier: :safe,
        description:
          "Wait for the active browser tab to settle or match a condition — navigation complete, a CSS selector present/visible, or text on the page. Read-only polling inside the desktop shell; never acts on the page and ingests nothing. An exhausted budget returns matched: false, not an error. Requires the desktop app to be open.",
        args: %{
          "until" => %{
            type: :string,
            required: false,
            description: ~s|Condition: "navigation" (default), "selector", "visible", or "text".|
          },
          "value" => %{
            type: :string,
            required: false,
            description:
              ~s|CSS selector or text to wait for (required unless until: "navigation").|
          },
          "timeout_ms" => %{
            type: :integer,
            required: false,
            description: "Max wait in milliseconds (default 10000, cap 30000)."
          }
        }
      },
      %{
        name: "browser_extract",
        type: :read,
        tier: :restricted,
        description:
          "Extract content from the active browser tab as the user's live session sees it (Sentinel-audited): the whole page (url, title, text) by default, or up to 50 CSS-selector matches as {text, href/value, attr} entries. Requires the desktop app to be open.",
        args: %{
          "selector" => %{
            type: :string,
            required: false,
            description: "CSS selector to match; omit to read the whole page (url, title, text)."
          },
          "attr" => %{
            type: :string,
            required: false,
            description: "Attribute name to read from each selector match."
          }
        }
      },
      %{
        name: "browser_assert",
        type: :read,
        tier: :restricted,
        description:
          "Check a condition against the active browser tab: url_contains / title_contains (current tab), or selector / text (a one-shot 250ms probe). Returns passed: true|false — a failed assertion is a result, not an error. Requires the desktop app to be open.",
        args: %{
          "kind" => %{
            type: :string,
            required: true,
            description: ~s|"url_contains", "title_contains", "selector", or "text".|
          },
          "value" => %{
            type: :string,
            required: true,
            description: "URL/title substring, CSS selector, or page text to check for."
          }
        }
      },
      %{
        name: "browser_flow",
        type: :mutate,
        tier: :restricted,
        description:
          "Run an ordered browser flow: steps of navigate/wait/click/fill/extract/assert/find_elements, halting at the first failure with a per-step report. Step arguments are recorded on the security audit feed. Max 25 steps. engine \"tab\" (default) drives the user's live tab and requires the desktop app; \"background\" runs headlessly on the user's installed Chromium (no desktop needed), scope-locked to the flow's own navigate hosts.",
        args: %{
          "steps" => %{
            type: :array,
            required: true,
            description:
              "Ordered step maps: {\"action\": \"navigate\" | \"wait\" | \"click\" | \"fill\" | \"extract\" | \"assert\" | \"find_elements\", ...that command's args}."
          },
          "engine" => %{
            type: :string,
            required: false,
            description: "\"tab\" (live tab, default) or \"background\" (headless CDP engine)."
          }
        }
      },
      %{
        name: "browser_check_save",
        type: :mutate,
        tier: :restricted,
        description:
          "Save a named, re-runnable site check — a browser flow stored as markdown in <workspace>/checks/ with an append-only run history. Overwriting keeps the history.",
        args: %{
          "name" => %{
            type: :string,
            required: true,
            description: "Slug: lowercase letters, digits, hyphens."
          },
          "steps" => %{
            type: :array,
            required: true,
            description: "Flow steps, same shape as browser_flow."
          },
          "description" => %{type: :string, required: false},
          "engine" => %{
            type: :string,
            required: false,
            description:
              "Where the check runs: \"tab\" (live tab, default) or \"background\" (headless CDP engine — runs unattended)."
          }
        }
      },
      %{
        name: "browser_check_list",
        type: :read,
        tier: :safe,
        description: "List saved site checks with step counts and each check's last run result.",
        args: %{}
      },
      # Agent Mode runs (the browse tab's mode switch)
      %{
        name: "agent_run_start",
        type: :mutate,
        tier: :restricted,
        description:
          "Start a supervised Agent Mode run: a headful window of the user's installed Chromium, scope frozen from intent + domains (navigation outside the allowlist halts). commerce: true turns payment pages into a human handoff (cart in, human pays) instead of a halt. The browse tab switches into agent-workspace mode while a run is active.",
        args: %{
          "intent" => %{type: :string, required: true, description: "The task, verbatim."},
          "domains" => %{
            type: :array,
            required: true,
            description: "Allowed hosts (subdomains included); everything else halts."
          },
          "commerce" => %{
            type: :boolean,
            required: false,
            description: "Payment pages hand off to the human instead of halting."
          }
        }
      },
      %{
        name: "agent_run_navigate",
        type: :mutate,
        tier: :restricted,
        description:
          "Navigate an Agent Mode run under its frozen scope. Off-scope URLs come back result: \"halted\"; a payment page on a commerce run comes back result: \"handoff\" with the frozen cart (the human pays from the browse tab).",
        args: %{
          "id" => %{type: :string, required: true},
          "url" => %{type: :string, required: true}
        }
      },
      %{
        name: "agent_run_act",
        type: :mutate,
        tier: :restricted,
        description:
          "One page action in an Agent Mode run: click | fill | extract | read | find_elements | wait. Target by selector/text/index; fill takes value ($secret.<name> resolves in the executor and never enters the record); wait takes until/timeout_ms. find_elements and extract both narrow on selector — on a busy page, pass one rather than paging through the first 100 elements; a find_elements index still refers to the whole page, so it stays valid for click. Content-returning actions come back egress-prepared (policy + redaction), never raw page text.",
        args: %{
          "id" => %{type: :string, required: true},
          "action" => %{type: :string, required: true},
          "selector" => %{type: :string, required: false},
          "text" => %{type: :string, required: false},
          "index" => %{type: :integer, required: false},
          "value" => %{type: :string, required: false},
          "until" => %{type: :string, required: false},
          "timeout_ms" => %{type: :integer, required: false}
        }
      },
      %{
        name: "agent_run_cart",
        type: :mutate,
        tier: :restricted,
        description:
          "Attach/replace the run's cart (commerce): items of {name, unit_cents, qty}. Frozen at the payment handoff — the human is shown exactly what the ledger may bill.",
        args: %{
          "id" => %{type: :string, required: true},
          "items" => %{
            type: :array,
            required: true,
            description: "Line items: {\"name\", \"unit_cents\", \"qty\" (default 1)}."
          }
        }
      },
      %{
        name: "agent_run_status",
        type: :read,
        tier: :safe,
        description:
          "Live status of an Agent Mode run (mode, step/egress summary, cart) by id, or all registered runs without one.",
        args: %{"id" => %{type: :string, required: false}}
      },
      %{
        name: "agent_run_stop",
        type: :mutate,
        tier: :restricted,
        description:
          "Stop an Agent Mode run (halts before its next action) and shut down its browser window. The trajectory stays inspectable.",
        args: %{"id" => %{type: :string, required: true}}
      },
      %{
        name: "agent_run_finish",
        type: :mutate,
        tier: :restricted,
        description:
          "Finish an Agent Mode run successfully (mode becomes \"done\") and shut down its browser window. This is how a run ENDS when the task is complete — agent_run_stop means halted, not finished. Call it when the errand is done; a commerce run needing a receipt uses the purchase confirmation instead.",
        args: %{"id" => %{type: :string, required: true}}
      },
      %{
        name: "agent_run_resume",
        type: :mutate,
        tier: :restricted,
        description:
          "Take the wheel back after a handoff: an Agent Mode run waiting on the human returns to \"agent_working\", the only mode in which the agent may act.",
        args: %{"id" => %{type: :string, required: true}}
      },
      %{
        name: "browser_egress_level",
        type: :mutate,
        tier: :restricted,
        description:
          "Read or set how much page content may leave the machine for a host during Agent Mode runs. With no args, lists the levels in force. With \"host\" and \"level\" (full | structure_only | never), records one; level null removes it. Applies to the host and its subdomains; most specific wins and ties break stricter. Runs freeze these at start, so a change applies to the next run.",
        args: %{
          "host" => %{type: :string, required: false},
          "level" => %{
            type: :string,
            required: false,
            description: "full | structure_only | never, or null to clear the host's entry."
          }
        }
      },
      %{
        name: "agent_run_confirm_purchase",
        type: :mutate,
        tier: :restricted,
        description:
          "Receipt a purchase the human already paid for by hand: capture the confirmation page, append a durable receipt, and finish the run. Spends nothing — the payment already happened in the real window. Only legal for a run in \"awaiting_human\" with a non-empty cart. Read the order number off the confirmation page and pass it as \"confirmation\".",
        args: %{
          "id" => %{type: :string, required: true},
          "confirmation" => %{
            type: :string,
            required: false,
            description: "The order id or confirmation URL shown on the page."
          }
        }
      },
      %{
        name: "browser_check_run",
        type: :mutate,
        tier: :restricted,
        description:
          "Run a saved site check as a browser flow on its saved engine (live tab, or the background CDP engine — no desktop needed) and append the pass/fail result to its run history.",
        args: %{
          "name" => %{type: :string, required: true},
          "engine" => %{
            type: :string,
            required: false,
            description: "Override the saved engine for this run: \"tab\" or \"background\"."
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
