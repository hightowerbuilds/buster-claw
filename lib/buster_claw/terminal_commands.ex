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
      key: "prompts",
      label: "Prompts",
      aliases: ["prompt"],
      startup_profile: "prompts",
      commands: [
        %{
          key: "welcome-introduction",
          label: "Welcome / Read Introduction",
          description: "Greet the agent and point it at the introduction to start a session.",
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
