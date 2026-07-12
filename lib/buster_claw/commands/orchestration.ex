defmodule BusterClaw.Commands.Orchestration do
  @moduledoc "Runtime status, activity report, terminal workspace, and orchestration-shift commands. Delegated to from `BusterClaw.Commands`."

  alias BusterClaw.{Orchestration, TerminalCommands, TerminalWorkspace}
  alias BusterClaw.Runtime.Status

  def runtime_status(_args \\ %{}), do: {:ok, Status.snapshot()}

  def activity_report(args \\ %{}) do
    days =
      case Map.get(args, "days") do
        n when is_integer(n) and n > 0 -> n
        _ -> 7
      end

    {:ok, BusterClaw.ActivityReport.summary(days: days)}
  end

  # -----------------------------------------------------------------------
  # Visible terminal workspace
  # -----------------------------------------------------------------------

  def terminal_tab_open(args \\ %{}), do: TerminalWorkspace.open(args)

  # -----------------------------------------------------------------------
  # Terminal cmd-list catalog (the editable command cheatsheet)
  # -----------------------------------------------------------------------

  @doc "List the editable (non-protected) cmd-list roles and their commands."
  def terminal_command_list(_args \\ %{}) do
    roles =
      TerminalCommands.load()
      |> Enum.reject(& &1.protected)
      |> Enum.map(fn role ->
        %{
          role_key: role.key,
          label: role.label,
          commands:
            Enum.map(role.commands, fn c ->
              %{
                key: c.key,
                label: c.label,
                description: c.description,
                command: c.command,
                kind: c.kind,
                default: c.default?,
                builtin: c.builtin
              }
            end)
        }
      end)

    {:ok, %{roles: roles}}
  end

  @doc "Edit (or add) one command/prompt in a non-protected cmd-list role."
  def terminal_command_set(args \\ %{}) do
    case TerminalCommands.set_command(args) do
      {:ok, %{commands_changed: changed}} ->
        {:ok,
         %{
           role_key: Map.get(args, "role_key"),
           command_key: Map.get(args, "command_key"),
           commands_changed: changed
         }}

      {:error, :protected} ->
        {:error, :protected_role}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :missing_command} ->
        {:error, :missing_command}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, {:invalid, changeset_errors(changeset)}}
    end
  end

  # Flatten a validation changeset to a plain field => [messages] map for the
  # agent (Ecto error tuples don't serialize cleanly to JSON).
  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  # --- Orchestration shift (agent-drivable: the on-shift Claude starts/stops it) ---

  def shift_status(_args \\ %{}) do
    case Orchestration.active_shift() do
      nil ->
        {:ok, %{active: false}}

      shift ->
        {:ok,
         %{
           active: true,
           shift_id: shift.id,
           job_key: shift.job_key,
           job_name: shift.job_name,
           job_description: shift.job_description,
           agent_name: shift.agent_name,
           shell: shift.shell,
           unattended: shift.unattended,
           started_at: shift.started_at,
           dispatched: shift.dispatched_count,
           done: shift.done_count,
           failed: shift.failed_count
         }}
    end
  end

  def shift_start(args \\ %{}) do
    Orchestration.clear_kill_switch()

    case Orchestration.start_shift(args) do
      {:ok, shift} ->
        {:ok,
         %{
           shift_id: shift.id,
           status: shift.status,
           job_key: shift.job_key,
           job_name: shift.job_name,
           agent_name: shift.agent_name,
           shell: shift.shell,
           unattended: shift.unattended,
           started_at: shift.started_at
         }}

      {:error, _changeset} = error ->
        error
    end
  end

  def shift_stop(args \\ %{}) do
    reason = Map.get(args, "reason", "stopped by agent")

    case Orchestration.stop_shift(reason) do
      {:ok, shift} -> {:ok, %{shift_id: shift.id, status: shift.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def shift_assignment_start(args \\ %{}) do
    case Orchestration.start_shift_assignment(args) do
      {:ok, assignment} ->
        {:ok, assignment}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def shift_assignment_status(args \\ %{}), do: Orchestration.shift_assignment_status(args)

  def shift_assignment_stop(args \\ %{}) do
    case Orchestration.stop_shift_assignment(args) do
      {:ok, assignment} -> {:ok, assignment}
      {:error, reason} -> {:error, reason}
    end
  end
end
