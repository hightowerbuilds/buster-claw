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
      label: "Mailman",
      aliases: ["mail-triage", "gmail-poller"],
      startup_profile: "mailman",
      commands: [
        %{
          key: "poll",
          label: "Poll Gmail",
          description: "Continuously sync Gmail through the local command API.",
          command: "./buster-claw mailman poll",
          default?: true
        },
        %{
          key: "poll-once",
          label: "Poll Once",
          description: "Run one Gmail sync and return.",
          command: "./buster-claw mailman poll --once"
        },
        %{
          key: "poll-minute",
          label: "Poll Every Minute",
          description: "Sync Gmail every 60 seconds.",
          command: "./buster-claw mailman poll --interval 60"
        },
        %{
          key: "poll-shift-log",
          label: "Poll + Shift Log",
          description: "Continuously sync Gmail and append output to the shift log.",
          command:
            "./buster-claw mailman poll 2>&1 | tee -a shift/2026-06-08/mailman-native-poll.log"
        }
      ]
    },
    %{
      key: "shift",
      label: "Shift & Autopilot",
      aliases: ["on-shift", "duty", "autopilot", "auto", "hands-off"],
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
          key: "shift-start-headless",
          label: "Start Headless Shift",
          description:
            "Open an UNATTENDED shift: the Dispatcher works the queue with headless agent runs until stopped, under the per-shift run cap + kill-switch + no-sleep. Walk away.",
          command: ~s(./buster-claw shift start --json '{"unattended":true}')
        },
        %{
          key: "shift-stop",
          label: "Stop Shift",
          description:
            "End the active shift — the Dispatcher stops pumping and no-sleep is released.",
          command: "./buster-claw shift stop"
        },
        %{
          key: "autopilot-once",
          label: "Autopilot — Work It Once",
          description:
            "No shift needed: sync trusted Gmail, then run headless Claude once to work the open items behind a TUI. The lightweight 'watch it work' tool (no run cap / no-sleep).",
          command: "./buster-claw autopilot"
        },
        %{
          key: "autopilot-loop",
          label: "Autopilot — Every Minute",
          description:
            "Loop the autopilot TUI: poll mail, work the queue, wait 60s, repeat. Ctrl-C stops it.",
          command: "while true; do ./buster-claw autopilot; sleep 60; done"
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
