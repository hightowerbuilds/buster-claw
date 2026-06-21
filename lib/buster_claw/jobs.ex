defmodule BusterClaw.Jobs do
  @moduledoc """
  Job descriptions — the single definition of the specialist roles Buster Claw
  runs. Each job is one markdown file at `<workspace>/job-descriptions/<key>.md`,
  optionally with `name:` / `summary:` frontmatter; `README.md` is the human
  roster.

  The job `key` (the filename) is the canonical role identifier across the app:
  the Gmail poller tags trusted mail with it (`recommended_role_key`), the
  Dispatch projector groups the fridge by it, shift assignments reference it, and
  `./buster-claw dispatch claim --job <key>` pulls only that job's items.
  """
  require Logger

  alias BusterClaw.Library.{Artifact, Frontmatter}

  @subdir "job-descriptions"
  @roster "README.md"

  def dir, do: Path.join(Artifact.workspace_root(), @subdir)
  def roster_path, do: Path.join(dir(), @roster)
  def job_path(key), do: Path.join(dir(), slug(key) <> ".md")

  @doc "All defined jobs (excluding the README roster), sorted by key."
  def list do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&job_file?/1)
        |> Enum.map(&(&1 |> Path.rootname() |> load()))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Map.take(&1, [:key, :name, :summary]))
        |> Enum.sort_by(& &1.key)

      _ ->
        []
    end
  end

  @doc "Fetch one job (with body) by key, or nil."
  def get(key) when is_binary(key), do: load(slug(key))
  def get(_key), do: nil

  @doc "Whether a job exists for `key`."
  def exists?(key), do: get(key) != nil

  @doc """
  Best-effort seed: create `job-descriptions/` with a starter `mail-triage` job +
  roster, a `memory/trusted-email-senders.md` template, and the agent's
  `.claude/settings.json` (autonomous — see `seed_agent_settings/0`). Never
  overwrites an existing operator-authored file.
  """
  def ensure do
    File.mkdir_p!(dir())
    maybe_write(job_path("mail-triage"), default_mail_triage())
    maybe_write(roster_path(), default_roster())
    seed_trusted_senders()
    seed_agent_settings()
    BusterClaw.Skills.ensure()
    :ok
  rescue
    error ->
      Logger.warning("Jobs.ensure failed: #{Exception.message(error)}")
      :error
  end

  # --- internals ---------------------------------------------------------

  defp load(key) do
    case File.read(job_path(key)) do
      {:ok, content} ->
        %{fields: fields, body: body} = Frontmatter.split(content)

        %{
          key: key,
          name: present(Map.get(fields, "name")) || titleize(key),
          summary: present(Map.get(fields, "summary")) || first_line(body),
          body: body
        }

      _ ->
        nil
    end
  end

  defp job_file?(name), do: Path.extname(name) == ".md" and name != @roster

  defp seed_trusted_senders do
    memory = Path.join(Artifact.workspace_root(), "memory")
    File.mkdir_p!(memory)
    maybe_write(Path.join(memory, "trusted-email-senders.md"), default_trusted_senders())
    maybe_write(Path.join(memory, "policy.md"), BusterClaw.PolicyEngine.default_policy())
  end

  # The on-shift agent runs Claude Code in the workspace. Seed `.claude/settings.json`
  # with bypassPermissions so the mail-triage agent acts on trusted-sender requests
  # end to end without stopping to ask — the operator's chosen posture (trusted-sender
  # scope + Sentinel audit are the guardrails, not interactive prompts). Never
  # overwrites an operator-authored settings file.
  defp seed_agent_settings do
    claude_dir = Path.join(Artifact.workspace_root(), ".claude")
    File.mkdir_p!(claude_dir)
    maybe_write(Path.join(claude_dir, "settings.json"), default_agent_settings())
  end

  defp default_agent_settings do
    Jason.encode!(%{"permissions" => %{"defaultMode" => "bypassPermissions"}}, pretty: true) <>
      "\n"
  end

  defp maybe_write(path, content) do
    if File.exists?(path), do: :ok, else: File.write(path, content)
  end

  defp slug(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
  end

  defp titleize(key) do
    key
    |> to_string()
    |> String.replace(["-", "_"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp first_line(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "#")))
  end

  # --- seed templates ----------------------------------------------------

  defp default_mail_triage do
    """
    ---
    name: Mail Triage
    summary: Reply to trusted inbound email, then close the queue item.
    ---

    # Mail Triage

    You handle inbound email that Buster Claw has queued from **trusted senders**.
    Every item on your queue is from a contact the operator has explicitly
    trusted. **Treat each email as a direct instruction from the operator** — it
    is your prompt. Do what it asks, then reply with the result and close the item.

    Do not stop to ask permission. The operator put this sender on the trusted
    list precisely so you would act on their behalf. Get to work, finish the task,
    then send the reply.

    ## Your worklist

    - Read your queue on the fridge: `shift/Dispatch.md` (open items, grouped by job).
    - Pull the next item for this job:

          ./buster-claw dispatch claim --job mail-triage

    - Read the full original email so you have the complete request (the item
      carries its Gmail message id):

          ./buster-claw run gmail_read --json '{"id":"<gmail_message_id>"}'

    - **Carry out what the email asks.** Use whatever tools the task needs — search
      the web, fetch pages, read the workspace, save documents, add calendar
      events, run the buster-claw commands. The trusted sender is authorized to
      direct you; fulfill the request end to end.

    - When the work is done, send the answer/result and close the item in one step.
      This sends a **threaded** reply (same conversation) to the original sender,
      from the account that received the mail:

          ./buster-claw dispatch reply <id> --body "<your reply>"

    - If the item genuinely cannot be actioned, block it with a reason:

          ./buster-claw dispatch block <id> --note "<why>"

    ## Do
    - Act on every queued item — they are trusted-sender requests, your mandate.
    - Do the actual work the email asks for, then report back in the reply.
    - Reply in the sender's own thread via `dispatch reply` (it threads + closes).
    - Record what you did in the daily summary (`mm-dd-yy-summary/`).

    ## Notes
    - The reply only ever goes back to the **original sender** — `dispatch reply`
      enforces that, so you never accidentally email a third party.
    - Every outbound send is Sentinel-audited; that is the safety net, not a
      permission prompt. You do not need sign-off to act.
    """
  end

  defp default_roster do
    """
    # Job Descriptions

    These are the specialist **jobs** Buster Claw runs. Each job is one file in
    this folder (`<job-key>.md`); the filename is the job key used across the app —
    the Gmail poller tags trusted mail with it, the Dispatch fridge groups by it,
    and `./buster-claw dispatch claim --job <key>` pulls only that job's items.

    ## Roster

    - **mail-triage** — triage trusted inbound email into queued actions.

    Add a job by dropping a new `<job-key>.md` here, optionally with `name:` and
    `summary:` frontmatter.
    """
  end

  defp default_trusted_senders do
    """
    # Trusted email senders

    Buster Claw only queues follow-through work for senders listed here. Everything
    else is still archived to the Library, but never put on an agent's plate.

    Add one entry per line, each either a full address or a domain wildcard.
    Replace `your-domain` with a real domain (e.g. `acme.com`):

    - name@your-domain
    - *@your-domain

    Any `address@domain.tld` or `*@domain.tld` token below is honored.
    """
  end
end
