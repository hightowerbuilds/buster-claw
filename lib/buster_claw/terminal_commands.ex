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
      key: "server",
      label: "Dev Server",
      aliases: ["phoenix", "phx", "start-server"],
      startup_profile: "server",
      commands: [
        %{
          key: "dev-server",
          label: "Start App (Phoenix + window)",
          description:
            "Run in your OWN macOS terminal (Terminal.app), NOT this in-app terminal — this one opens in your workspace folder, not the code. Boots Phoenix, waits for health, opens the desktop window. Stop any running server first (Ctrl-C).",
          command: "cd ~/Developer/buster-claw && ./scripts/dev.sh",
          default?: true
        },
        %{
          key: "phx-server",
          label: "Restart Phoenix Only",
          description:
            "Run in your OWN macOS terminal. Just the Phoenix server (no new window); the open window reconnects when it's back. A restart is what picks up new supervised processes (like the chat backend) that a refresh can't.",
          command: "cd ~/Developer/buster-claw && mix phx.server"
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
      label: "Shift",
      aliases: ["on-shift", "duty"],
      startup_profile: "shift",
      commands: [
        %{
          key: "shift-run",
          label: "Open Shift",
          description:
            "Start an orchestration shift, then poll trusted mail (Ctrl-C ends polling).",
          command: "./buster-claw shift run",
          default?: true
        },
        %{
          key: "shift-stop",
          label: "Close Shift",
          description: "End the current shift — the agent stops claiming new work.",
          command: "./buster-claw shift stop"
        }
      ]
    },
    %{
      key: "autopilot",
      label: "Autopilot",
      aliases: ["auto", "hands-off"],
      startup_profile: "autopilot",
      commands: [
        %{
          key: "autopilot-once",
          label: "Open Mail + Work It",
          description:
            "Sync trusted Gmail, then run headless Claude once to work the open items — behind a space-themed TUI that shows what the agent is doing.",
          command: "./buster-claw autopilot",
          default?: true
        },
        %{
          key: "autopilot-loop",
          label: "Autopilot (every minute)",
          description:
            "Loop the autopilot TUI: poll mail, work the queue, wait 60s, repeat. Ctrl-C stops it.",
          command: "while true; do ./buster-claw autopilot; sleep 60; done"
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
