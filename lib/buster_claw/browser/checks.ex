defmodule BusterClaw.Browser.Checks do
  @moduledoc """
  Saved site checks — named, re-runnable browser flows with a pass/fail
  history. One markdown file per check at `<workspace>/checks/<name>.md`:
  frontmatter carries the definition (name, description, steps), the body
  keeps an append-only `## Runs` log. File-first like skills and job
  descriptions — git-diffable, operator-editable, no DB.

  This module only stores and loads definitions and appends run records;
  running a check goes through `browser_flow` so the flow-level audit event
  and per-step Sentinel events fire exactly as they would for an ad-hoc flow.
  """

  require Logger

  alias BusterClaw.Browser.FlowRunner
  alias BusterClaw.Library.{Artifact, Frontmatter}

  @subdir "checks"
  @name_re ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/
  @runs_heading "## Runs"

  def dir, do: Artifact.workspace_path(@subdir)

  @doc """
  Save (or overwrite) a check definition. Steps are validated with
  `FlowRunner.validate/1` so a broken flow is refused now, not at run time.
  An existing check's run history survives a re-save.
  """
  def save(name, steps, description \\ nil) do
    with :ok <- validate_name(name),
         :ok <- FlowRunner.validate(steps) do
      File.mkdir_p!(dir())
      path = path_for(name)

      frontmatter =
        Frontmatter.build(%{
          name: name,
          description: description,
          steps: steps,
          saved: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      body = "#{@runs_heading}\n\n" <> existing_runs(path)

      case File.write(path, frontmatter <> body) do
        :ok -> {:ok, %{name: name, steps: length(steps), path: path}}
        {:error, reason} -> {:error, {:check_write_failed, reason}}
      end
    end
  end

  @doc "All saved checks: name, description, step count, and the last run line."
  def list do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(&summarize/1)
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        []
    end
  end

  @doc "Load one check's definition."
  def load(name) do
    with :ok <- validate_name(name),
         {:ok, markdown} <- read(name) do
      %{fields: fields} = Frontmatter.split(markdown)

      case fields do
        %{"steps" => steps} when is_list(steps) ->
          {:ok, %{name: name, steps: steps, description: fields["description"]}}

        _ ->
          {:error, :invalid_check}
      end
    end
  end

  @doc """
  Append one run record to the check's `## Runs` log. Best-effort by design —
  a failed append is logged, never raised, and never fails the run that
  produced it.
  """
  def record_run(name, report, total_ms) do
    with :ok <- validate_name(name),
         {:ok, markdown} <- read(name) do
      line = run_line(report, total_ms)

      case File.write(path_for(name), markdown <> line) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Checks: recording run for #{name} failed: #{inspect(reason)}")
          {:error, {:check_write_failed, reason}}
      end
    else
      error ->
        Logger.warning("Checks: recording run for #{name} failed: #{inspect(error)}")
        error
    end
  end

  defp run_line(%{status: "passed", steps: steps}, total_ms) do
    "- #{timestamp()} PASSED (#{length(steps)} steps in #{total_ms}ms)\n"
  end

  defp run_line(%{status: "failed", steps: steps, failed_step: failed}, total_ms) do
    %{action: action, detail: detail} = Enum.at(steps, failed - 1)

    "- #{timestamp()} FAILED at step #{failed} (#{action}) in #{total_ms}ms — #{failure_note(detail)}\n"
  end

  defp failure_note(%{error: error}), do: String.slice(to_string(error), 0, 160)
  defp failure_note(%{passed: false}), do: "assertion did not pass"
  defp failure_note(%{matched: false}), do: "wait condition never matched"
  defp failure_note(_detail), do: "step failed"

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp summarize(file) do
    name = Path.rootname(file)

    case load(name) do
      {:ok, check} ->
        %{
          name: name,
          description: check.description,
          steps: length(check.steps),
          last_run: last_run(name)
        }

      _ ->
        nil
    end
  end

  defp last_run(name) do
    case read(name) do
      {:ok, markdown} ->
        markdown
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "- "))
        |> List.last()

      _ ->
        nil
    end
  end

  defp existing_runs(path) do
    with {:ok, markdown} <- File.read(path),
         [_before, runs] <- String.split(markdown, @runs_heading, parts: 2) do
      String.trim_leading(runs, "\n")
    else
      _ -> ""
    end
  end

  defp read(name) do
    case File.read(path_for(name)) do
      {:ok, markdown} -> {:ok, markdown}
      {:error, :enoent} -> {:error, :check_not_found}
      {:error, reason} -> {:error, {:check_read_failed, reason}}
    end
  end

  defp path_for(name), do: Path.join(dir(), name <> ".md")

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(@name_re, name), do: :ok, else: {:error, :invalid_check_name}
  end

  defp validate_name(_name), do: {:error, :invalid_check_name}
end
