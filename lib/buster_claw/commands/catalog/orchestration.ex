defmodule BusterClaw.Commands.Catalog.Orchestration do
  @moduledoc "Catalog entries: runtime, terminal workspace, shifts, jobs, dispatch, memory, and skills."

  alias BusterClaw.Commands.Catalog.Helpers

  @doc "Runtime + terminal + shift + jobs + dispatch + memory + self-improvement catalog entries."
  def entries,
    do: [
      # Runtime
      Helpers.list_entry("runtime_status", "Snapshot of process and system state."),
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
      Helpers.list_entry(
        "shift_status",
        "Whether an orchestration shift is active, plus counts."
      ),
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
      Helpers.list_entry("job_list", "List the defined jobs (role roster)."),
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
      Helpers.get_entry("dispatch_show", "Fetch a Dispatch item by ID."),
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
          Helpers.google_args(%{
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
