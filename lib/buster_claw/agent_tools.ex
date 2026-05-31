defmodule BusterClaw.AgentTools do
  @moduledoc """
  Expose `BusterClaw.Commands` to the active chat provider as tool calls.

  Only safe-tier commands are exposed — mutations, deletes, and destructive
  triggers are not callable from inside a chat session.
  """

  alias BusterClaw.Commands
  alias BusterClaw.Commands.{Result, Schema}

  @doc "Safe-tier commands, serialized into Anthropic's tool-definition format."
  def anthropic_tools do
    safe_commands()
    |> Enum.map(fn cmd ->
      %{
        name: cmd.name,
        description: cmd.description,
        input_schema: Schema.to_json_schema(cmd.args)
      }
    end)
  end

  @doc """
  Execute a tool call from the model. Returns `{:ok, text}` (success) or
  `{:error, text}` (failure) — both as strings, ready to be embedded back into
  a `tool_result` content block.

  Refuses to execute restricted-tier commands.
  """
  def execute(name, args) when is_binary(name) do
    cond do
      not has_safe_command?(name) ->
        {:error, "tool not available: #{name}"}

      true ->
        case Commands.call(name, args || %{}, caller: :agent) do
          {:ok, value} ->
            {:ok, format_value(value)}

          {:error, reason} ->
            {:error, format_error(reason)}
        end
    end
  end

  defp safe_commands, do: Commands.safe_commands()

  defp has_safe_command?(name) do
    Enum.any?(safe_commands(), &(&1.name == name))
  end

  defp format_value(value) do
    value
    |> Result.to_json()
    |> Jason.encode!()
  end

  defp format_error(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    Jason.encode!(%{error: "validation", errors: errors})
  end

  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error(reason), do: BusterClawWeb.ErrorFormatter.format(reason)
end
