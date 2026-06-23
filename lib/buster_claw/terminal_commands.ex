defmodule BusterClaw.TerminalCommands do
  @moduledoc """
  Whitelisted role-specific CLI commands for visible terminal sessions.

  This catalog is intentionally small and explicit. It feeds terminal startup
  profiles and the terminal-only Commands menu, so neither surface accepts
  arbitrary shell text.
  """

  @roles [
    %{
      key: "agent-setup",
      label: "Install Claude Code",
      aliases: ["claude-setup", "install-claude"],
      startup_profile: "agent-setup",
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
      aliases: ["mail-triage", "gmail-poller", "on-duty", "off-duty"],
      startup_profile: "mailman",
      commands: [
        %{
          key: "on-duty",
          label: "Go On Duty",
          description:
            "Watch Gmail and let the agent work and reply in-thread to trusted-sender requests, until you stand down (Ctrl-C).",
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
          description: "Stand down — stop the active shift.",
          command: "./buster-claw off-duty"
        }
      ]
    },
    %{
      key: "shift",
      label: "Shift",
      aliases: ["on-shift", "duty"],
      startup_profile: "shift",
      commands: [
        %{
          key: "shift-status",
          label: "Shift Status",
          description: "Whether a shift is active, its mode, and dispatched/done/failed counts.",
          command: "./buster-claw shift status",
          default?: true
        },
        %{
          key: "on-duty",
          label: "Go On Duty",
          description:
            "The one command: open an unattended shift AND watch Gmail. The agent works the queue and replies in-thread to trusted-sender requests under the per-shift run cap + kill-switch + no-sleep. Ctrl-C stands down.",
          command: "./buster-claw on-duty"
        },
        %{
          key: "off-duty",
          label: "Off Duty",
          description:
            "End the active shift — the Dispatcher stops pumping and no-sleep is released.",
          command: "./buster-claw off-duty"
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
      commands: [
        %{
          key: "welcome-introduction",
          command: "Welcome to Buster Claw. Please read the introduction.",
          default?: true
        },
        %{
          key: "skills-methodology",
          label: "Skills — Full Walkthrough",
          description:
            "Have the agent explain composition skills end to end: what they are, how to list/run/author them, the enable gate, the trust model, and the self-improving loop.",
          command:
            "Walk me through the Buster Claw skills methodology in full. First read skills/README.md and the introduction, then explain: " <>
              "(1) WHAT a composition skill is — one markdown file at skills/<name>.md whose `steps` are an ordered list of existing native commands, so it adds new *sequencing*, never new capability. " <>
              "(2) DISCOVER — `./buster-claw commands` lists skills tagged [skill] alongside native commands; they are read live from disk, so a new one shows up with no restart. " <>
              "(3) RUN — `./buster-claw run <name> --json '{...}'`, where `$arg` fills a skill input and `$prior` threads the previous step's result into the next. " <>
              "(4) AUTHOR — drop a .md file with frontmatter (name = filename stem, description, tier: safe|restricted, enabled, handler_kind: composition, args, and steps as a JSON array of {\"command\",\"args\"}); it goes live the moment the file lands. " <>
              "(5) ENABLE GATE — `enabled: false` by default, so a skill stays staged-but-inert until I explicitly set it true. " <>
              "(6) TRUST MODEL — a skill can never exceed the trust of whoever invoked it, and every step is re-checked against the same tier/gating as a direct command call, all recorded on the Sentinel audit feed. " <>
              "(7) SELF-IMPROVING LOOP — `skill_analyze` proposes a skill from repeated command sequences, `skill_suggestions` lists pending proposals, and `skill_suggestion_approve`/`skill_suggestion_reject` decide (never auto-enabled). " <>
              "Finish by showing me the bundled `save-note` skill as a worked example and how I'd add one of my own."
        }
      ]
    }
  ]

  @doc "Return every visible terminal role command group."
  def roles, do: @roles

  @doc "Find a role by key or alias."
  def role(key) when is_binary(key) do
    normalized = normalize_key(key)

    Enum.find(roles(), fn role ->
      normalized == role.key or normalized in role.aliases
    end)
  end

  def role(_key), do: nil

  @doc "Return the startup profile for a role key or alias."
  def startup_profile_for_role(role_key) do
    case role(role_key) do
      %{startup_profile: startup_profile} -> startup_profile
      nil -> nil
    end
  end

  @doc "Return the default startup command for a startup profile."
  def startup_command(profile) when is_binary(profile) do
    Enum.find_value(roles(), fn role ->
      if role.startup_profile == profile do
        role.commands
        |> Enum.find(&Map.get(&1, :default?, false))
        |> case do
          %{command: command} -> command
          nil -> nil
        end
      end
    end)
  end

  def startup_command(_profile), do: nil

  defp normalize_key(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end
end
