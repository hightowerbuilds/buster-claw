defmodule BusterClaw.Hooks do
  @moduledoc "Hook configuration and test helpers."

  import Ecto.Query

  alias BusterClaw.{Automation, Repo, Workflow}
  alias BusterClaw.Automation.Hook

  @max_output 8_000

  def list_hooks do
    Hook
    |> order_by([hook], asc: hook.event, asc: hook.name)
    |> Repo.all()
  end

  def get_hook!(id), do: Automation.get_hook!(id)
  def create_hook(attrs), do: Automation.create_hook(attrs)
  def update_hook(%Hook{} = hook, attrs), do: Automation.update_hook(hook, attrs)
  def delete_hook(%Hook{} = hook), do: Automation.delete_hook(hook)

  def change_hook(%Hook{} = hook \\ %Hook{}, attrs \\ %{}) do
    Hook.changeset(hook, attrs)
  end

  def test_hook(%Hook{} = hook, opts \\ []) do
    payload = Keyword.get(opts, :payload, %{"test" => true})
    execute_hook(hook, payload, opts)
  end

  defp execute_hook(%Hook{} = hook, payload, opts) do
    started_at = timestamp()
    start_native = System.monotonic_time()

    result =
      case hook.type do
        "shell" -> execute_shell(hook)
        "webhook" -> execute_webhook(hook, payload, opts)
        other -> {:error, %{error: "Unsupported hook type: #{other}"}}
      end

    duration_ms =
      System.monotonic_time()
      |> Kernel.-(start_native)
      |> System.convert_time_unit(:native, :millisecond)

    observe_hook(hook, result)

    attrs = run_attrs(hook, payload, started_at, duration_ms, result)

    with {:ok, run} <- Workflow.create_hook_run(attrs) do
      {:ok, run}
    end
  end

  # Hooks reach outside the box (webhook URL) or run a shell — both are
  # consequential and recorded on the Sentinel audit spine.
  defp observe_hook(%Hook{type: "webhook"} = hook, result) do
    BusterClaw.Sentinel.observe(
      :outbound_send,
      "Webhook hook \"#{hook.name}\" → #{hook.target} (#{hook_outcome(result)})",
      %{hook: hook.name, event: hook.event, url: hook.target, outcome: hook_outcome(result)}
    )
  end

  defp observe_hook(%Hook{type: "shell"} = hook, result) do
    BusterClaw.Sentinel.observe(
      :command_invoke,
      "Shell hook \"#{hook.name}\" executed (#{hook_outcome(result)})",
      %{hook: hook.name, event: hook.event, target: hook.target, outcome: hook_outcome(result)},
      severity: :warning
    )
  end

  defp observe_hook(_hook, _result), do: :ok

  defp hook_outcome({:ok, %{success: true}}), do: "ok"
  defp hook_outcome(_), do: "error"

  defp execute_shell(hook) do
    {output, status_code} = System.cmd("sh", ["-c", hook.target], stderr_to_stdout: true)

    {:ok,
     %{
       stdout: bounded(output),
       stderr: nil,
       status_code: status_code,
       success: status_code == 0,
       error: if(status_code == 0, do: nil, else: "Shell hook exited with #{status_code}")
     }}
  rescue
    error -> {:error, %{error: Exception.message(error)}}
  end

  defp execute_webhook(hook, payload, opts) do
    req_options =
      opts
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(url: hook.target, json: webhook_payload(hook, payload))

    case Req.post(req_options) do
      {:ok, response} ->
        {:ok,
         %{
           stdout: response_body(response.body),
           stderr: nil,
           status_code: response.status,
           success: response.status in 200..299,
           error: if(response.status in 200..299, do: nil, else: "HTTP #{response.status}")
         }}

      {:error, reason} ->
        {:error, %{error: inspect(reason)}}
    end
  end

  defp webhook_payload(hook, payload) do
    %{
      hook: %{
        id: hook.id,
        name: hook.name,
        event: hook.event,
        type: hook.type
      },
      payload: payload
    }
  end

  defp run_attrs(hook, payload, started_at, duration_ms, {:ok, result}) do
    %{
      hook_id: hook.id,
      event: hook.event,
      type: hook.type,
      started_at: started_at,
      duration_ms: duration_ms,
      success: result.success,
      error: result.error,
      stdout: result.stdout,
      stderr: result.stderr,
      status_code: result.status_code,
      payload: payload
    }
  end

  defp run_attrs(hook, payload, started_at, duration_ms, {:error, result}) do
    %{
      hook_id: hook.id,
      event: hook.event,
      type: hook.type,
      started_at: started_at,
      duration_ms: duration_ms,
      success: false,
      error: bounded(result.error || inspect(result)),
      payload: payload
    }
  end

  defp response_body(body) when is_binary(body), do: bounded(body)
  defp response_body(body), do: body |> inspect() |> bounded()

  defp bounded(text) do
    if String.length(text) > @max_output,
      do: String.slice(text, 0, @max_output) <> "\n[truncated]",
      else: text
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
