defmodule BusterClaw.Commands.Orchestration do
  @moduledoc "Runtime status, activity report, model policy, terminal workspace, and orchestration-shift commands. Delegated to from `BusterClaw.Commands`."

  alias BusterClaw.{ModelPolicy, Orchestration, TerminalCommands, TerminalWorkspace}
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
  # Model policy — which model each agent surface runs on
  # -----------------------------------------------------------------------

  @doc """
  Read or set the model each agent surface runs on.

  With no `surface`, lists what is in force everywhere: the model, the `source`
  that decided it (`surface` | `floor` | `default` | `cli`), and the surface's
  floor where it has one. That triple is the answer to "I set a default, so why
  is trading on something else?" — printing the model alone would not be.

  With `surface` and `model`, records one; `surface: "default"` sets the global
  default. `clear: true` removes an entry so the surface inherits again; a blank
  `model` is refused rather than stored, because a blank would silently never
  apply. Nothing stored means no `--model` flag is passed at all.

  `trading_read` and `order_submit` carry a floor the global default cannot
  lower — see `BusterClaw.ModelPolicy` for the 07-28 measurement behind it.
  """
  def model_policy(args \\ %{})

  def model_policy(%{"surface" => surface} = args) when is_binary(surface) and surface != "" do
    with {:ok, key} <- parse_surface(surface),
         {:ok, model} <- parse_model(args) do
      write_policy(surface, key, model)
    end
  end

  def model_policy(_args) do
    {:ok,
     %{
       in_force: shape_policy(ModelPolicy.in_force()),
       operator_set: shape_stored(ModelPolicy.stored()),
       surfaces: surface_names(),
       known_models: ModelPolicy.known_models()
     }}
  end

  defp write_policy(surface, key, model) do
    case ModelPolicy.put(key, model) do
      {:ok, in_force} ->
        {:ok, %{surface: surface, model: model, in_force: shape_policy(in_force)}}

      {:error, {:unknown_surface, _key}} ->
        unknown_surface(surface)

      {:error, :blank_model} ->
        blank_model()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Never `String.to_atom/1` here: the surface name arrives from an operator or
  # a model. Matching against the known keys keeps the atom table bounded.
  defp parse_surface(given) do
    case Enum.find([:default | ModelPolicy.surface_keys()], &(Atom.to_string(&1) == given)) do
      nil -> unknown_surface(given)
      key -> {:ok, key}
    end
  end

  # `clear` is the honest way to unset: `ModelPolicy.put/2` refuses "" rather
  # than storing a value that could never apply, so an empty string is not it.
  defp parse_model(%{"clear" => true}), do: {:ok, nil}

  defp parse_model(%{"model" => model}) when is_binary(model) do
    if ModelPolicy.valid_model?(model), do: {:ok, model}, else: blank_model()
  end

  defp parse_model(_args) do
    {:error, {:missing_model, "pass \"model\", or \"clear\": true to unset this surface"}}
  end

  defp unknown_surface(given), do: {:error, {:unknown_surface, given, surface_names()}}

  defp blank_model do
    {:error, {:blank_model, "a model must be a non-blank string; \"clear\": true unsets it"}}
  end

  defp surface_names, do: Enum.map([:default | ModelPolicy.surface_keys()], &Atom.to_string/1)

  defp shape_policy(in_force) do
    Enum.map(ModelPolicy.surface_keys(), fn surface ->
      entry = Map.fetch!(in_force, surface)

      %{
        surface: Atom.to_string(surface),
        model: entry.model,
        source: Atom.to_string(entry.source),
        floor: entry.floor,
        description: entry.description
      }
    end)
  end

  defp shape_stored(stored) do
    stored
    |> Enum.map(fn {surface, model} -> %{surface: Atom.to_string(surface), model: model} end)
    |> Enum.sort_by(& &1.surface)
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
