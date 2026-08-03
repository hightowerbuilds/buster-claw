defmodule BusterClaw.TerminalCommands.Builtins do
  @moduledoc """
  The shipped terminal-command catalog and its protection model — the
  compile-time truth the merged catalog is built over.

  A leaf on purpose (CODE_QUALITY_REFACTOR_ROADMAP Phase 1): `Catalog.Role` and
  `RoleEdit` validate edits against `protected?/1` and `builtin_role/1`, and
  when those lived on the `TerminalCommands` facade the catalog submodules and
  the facade formed a dependency cycle.

  `@protected_keys` is the shift safety surface: roles an edit may never touch,
  because a customized `mailman` is how an unattended shift goes quietly wrong.
  """

  @protected_keys ["mailman", "agent-setup"]

  @roles [
    %{
      key: "agent-setup",
      label: "Install Claude Code",
      aliases: ["claude-setup", "install-claude"],
      startup_profile: "agent-setup",
      # Kept resolvable (the Setup wizard's install button + startup-profile
      # validation rely on it), but hidden from the terminal command menu.
      hidden: true,
      commands: [
        %{
          key: "install-claude",
          label: "Install Claude Code",
          description: "Install the Claude Code CLI with Homebrew.",
          command: "brew install --cask claude-code",
          default?: true
        }
      ]
    },
    %{
      key: "mailman",
      label: "On Duty",
      aliases: ["mail-triage", "gmail-poller", "on-duty", "off-duty", "shift", "on-shift", "duty"],
      startup_profile: "mailman",
      commands: [
        %{
          key: "on-duty",
          label: "Go On Duty",
          description:
            "Open an unattended shift AND watch Gmail: the agent works the queue and replies in-thread to trusted-sender requests under the per-shift run cap + kill-switch + no-sleep. Ctrl-C stands down.",
          command: "./buster-claw on-duty",
          default?: true
        },
        %{
          key: "on-duty-minute",
          label: "Go On Duty — Poll Every Minute",
          description: "Same, with a 60-second Gmail poll cadence.",
          command: "./buster-claw on-duty --interval 60"
        },
        %{
          key: "off-duty",
          label: "Off Duty",
          description: "Stand down — end the active shift (the Dispatcher stops pumping).",
          command: "./buster-claw off-duty"
        },
        %{
          key: "shift-status",
          label: "Shift Status",
          description: "Whether a shift is active, its mode, and dispatched/done/failed counts.",
          command: "./buster-claw shift status"
        }
      ]
    },
    %{
      key: "queue",
      label: "Dispatch Queue",
      aliases: ["dispatch-queue", "queue"],
      startup_profile: "queue",
      commands: [
        %{
          key: "dispatch-list",
          label: "List Queue",
          description: "Show the open Dispatch items (queued / claimed / running).",
          command: "./buster-claw dispatch list"
        },
        %{
          key: "dispatch-claim",
          label: "Claim Next",
          description: "Claim the oldest single-strategy item to work it.",
          command: "./buster-claw dispatch claim"
        },
        %{
          key: "dispatch-strategy-swarm",
          label: "Mark Item → Swarm",
          description:
            "Opt a queued item into the parallel coordinator (it decomposes into role-typed sub-runs). Replace <id> with the item id from `dispatch list`.",
          command: "./buster-claw dispatch strategy <id> swarm"
        }
      ]
    },
    %{
      key: "toolbox",
      label: "Commands",
      aliases: ["surface", "toolbox"],
      startup_profile: "toolbox",
      commands: [
        %{
          key: "commands-list",
          label: "List Commands",
          description: "Print the full command surface, including runtime skills ([skill]).",
          command: "./buster-claw commands"
        },
        %{
          key: "runtime-status",
          label: "Runtime Status",
          description: "Quick health/status snapshot of the running app.",
          command: "./buster-claw run runtime_status"
        },
        %{
          key: "memory-search",
          label: "Search Memory",
          description:
            "Recall past run summaries by full-text query. Edit the query text before running.",
          command: ~s(./buster-claw run memory_search --json '{"query":"shift"}')
        }
      ]
    },
    %{
      key: "prompts",
      label: "Prompts",
      aliases: ["prompt"],
      startup_profile: "prompts",
      # One static default prompt; a prompt per enabled skill is synthesized
      # from the `skills/` folder at display time (see `skill_prompt_commands/0`
      # and `with_skill_prompts/1`), so the Prompts flyout tracks the folder
      # with no recompile and no restated rows here.
      commands: [
        %{
          key: "welcome-introduction",
          command:
            "Welcome to Buster Claw. Please read the introduction at .buster-claw/INTRODUCTION.md.",
          kind: :prompt,
          default?: true
        }
      ]
    }
  ]

  @doc "The shipped, compile-time catalog (pre-merge)."
  def builtin_roles, do: @roles

  @doc "Find a shipped role by exact key (aliases don't count here)."
  def builtin_role(key), do: Enum.find(@roles, &(&1.key == key))

  @doc "Role keys that can never be customized (the shift safety surface)."
  def protected_keys, do: @protected_keys

  @doc "Whether a role key is protected from customization."
  def protected?(key), do: key in @protected_keys
end
