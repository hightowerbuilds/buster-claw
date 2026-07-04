defmodule BusterClaw.DispatchProjector do
  @moduledoc """
  Projects the Dispatch queue to the workspace on every `"dispatch"` event, in
  two views (see `daily-growth/roadmaps/06-09-26-terminal-pull-queue-roadmap.md`):

  - **Fridge** — `shift/Dispatch.md`: a full overwrite of the currently-open
    items (queued/claimed/running), grouped by job. The agent's primary read —
    "what's on my plate right now."
  - **Diary** — `shift/<date>/Dispatch.md` + `Dispatch.jsonl`: the dated record.
    The `.jsonl` is append-only (one line per primary event); the `.md` is a
    readable render of that day's events.

  Coherence: SQLite is the source of truth. The fridge `.md` is a full overwrite
  (so it never accumulates stale items) and carries no wall-clock, so re-rendering
  with no change is byte-identical. The dated diary `.jsonl` **and** `.md` are
  append-only — one line/row per logged event, never re-read or re-rendered — so a
  busy day is O(1) per event, not O(n²). `render_diary/2` reproduces the diary
  bytes from a decoded event list.

  Writes are best-effort: a filesystem error logs and never crashes the projector
  or the action that triggered it.
  """
  use GenServer

  require Logger

  alias BusterClaw.Dispatch
  alias BusterClaw.Library.Artifact
  alias BusterClaw.LocalTime

  # Events that get a dated `.jsonl` line. `:dispatch_item_updated` (heartbeats,
  # incidental field changes) is not logged, so a single mark_running/finish —
  # which also fires `:dispatch_item_updated` — does not double-log.
  @logged_events ~w(dispatch_item_queued dispatch_item_claimed dispatch_item_running dispatch_item_finished)a

  # Events that can change the OPEN set (queued/claimed/running) and so require a
  # fridge re-render. These are exactly the status-transition events broadcast by
  # `Dispatch`; bare `:dispatch_item_updated` (heartbeats, incidental field
  # changes) leaves the open set unchanged and would only rewrite byte-identical
  # output, so it skips the fridge entirely.
  @fridge_events ~w(dispatch_item_queued dispatch_item_claimed dispatch_item_running dispatch_item_finished)a

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Dispatch.subscribe()
    # On boot, return orphaned in-flight items to the queue, then render so the
    # fridge reflects the reconciled state.
    _ = safe_reclaim()
    safe_render(nil, nil)
    {:ok, %{}}
  end

  defp safe_reclaim do
    Dispatch.reclaim_orphans()
  rescue
    error ->
      Logger.warning("DispatchProjector boot reclaim failed: #{Exception.message(error)}")
      0
  end

  @impl true
  def handle_info({:dispatch, event, item}, state) do
    safe_render(event, item)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- rendering ---------------------------------------------------------

  defp safe_render(event, item) do
    render(event, item)
  rescue
    error ->
      Logger.warning("DispatchProjector render failed: #{Exception.message(error)}")
      :error
  end

  defp render(event, item) do
    # Only re-render the fridge when the open set can have changed. The boot
    # render (event == nil) always refreshes it; bare `:dispatch_item_updated`
    # heartbeats leave the open set untouched and would only rewrite
    # byte-identical output, so they skip the (otherwise per-event) full
    # `list_open()` + overwrite of `shift/Dispatch.md`.
    if is_nil(event) or event in @fridge_events, do: write_fridge()
    # The initial boot render (event == nil) only refreshes the fridge; dated
    # diary files appear lazily once the first real event arrives.
    if event, do: write_diary(LocalTime.today(), event, item)
    :ok
  end

  defp write_fridge do
    path = fridge_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, render_fridge(Dispatch.list_open()))
  end

  # Append-only: each logged event adds one `.jsonl` line and one diary `.md` row
  # (writing the header first when the day's file is new). No re-read of the
  # growing file, so a day's projection is O(1) per event. Heartbeats/incidental
  # updates aren't logged, so they touch neither file.
  defp write_diary(date, event, item) do
    if event in @logged_events and item do
      dir = diary_dir(date)
      File.mkdir_p!(dir)
      entry = event_entry(event, item)

      File.write!(Path.join(dir, "Dispatch.jsonl"), Jason.encode!(entry) <> "\n", [:append])

      md = Path.join(dir, "Dispatch.md")
      row = diary_row(entry)

      if File.exists?(md),
        do: File.write!(md, row, [:append]),
        else: File.write!(md, diary_header(date) <> row)
    end
  end

  # --- fridge (live open worklist) ---------------------------------------

  @doc """
  Render the fridge view from a list of open `Dispatch.Item` structs. Pure: the
  output depends only on the items, so identical input yields identical bytes.
  """
  def render_fridge(items) do
    header = "# Dispatch — open items\n\n#{length(items)} open\n"

    body =
      case items do
        [] ->
          "\n_Nothing open._\n"

        _ ->
          items
          |> Enum.group_by(&job_key/1)
          |> Enum.sort_by(fn {job, _} -> job end)
          |> Enum.map_join("\n", fn {job, group} -> render_job_group(job, group) end)
      end

    header <> "\n" <> body
  end

  defp render_job_group(job, items) do
    "## #{job}\n\n" <> Enum.map_join(items, "\n", &render_item/1)
  end

  defp render_item(item) do
    """
    ### ##{item.id} — #{inline(item.subject) || "(no subject)"}

    - status: #{item.status}
    - source: #{inline(item.source)}#{sender_line(item)}

    #{fenced(item.request_body_excerpt)}
    """
  end

  defp sender_line(%{sender: sender}) when is_binary(sender) and sender != "",
    do: "\n- sender: #{inline(sender)}"

  defp sender_line(_item), do: ""

  # --- diary (dated record) ----------------------------------------------

  @doc """
  Render the dated diary `.md` from a list of decoded `.jsonl` events. Pure, and
  byte-identical to the append-only file for the same event sequence.
  """
  def render_diary(date, events) do
    diary_header(date) <> Enum.map_join(events, "", &diary_row/1)
  end

  defp diary_header(date), do: "# Dispatch — #{Date.to_iso8601(date)}\n\n"

  defp diary_row(event) do
    ts = Map.get(event, "ts", "?")
    name = Map.get(event, "event", "?")
    id = Map.get(event, "id", "?")
    status = Map.get(event, "status", "?")
    subject = inline(Map.get(event, "subject")) || "(no subject)"
    sender = Map.get(event, "sender")
    suffix = if is_binary(sender) and sender != "", do: " (#{inline(sender)})", else: ""

    "- #{ts} · #{name} · ##{id} · #{status} · #{subject}#{suffix}\n"
  end

  # One decoded event map (string keys, matching the `.jsonl`), fed to both the
  # appended `.jsonl` line and the appended `.md` row so they stay in lockstep.
  defp event_entry(event, item) do
    %{
      "ts" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "event" => short_event(event),
      "id" => item.id,
      "status" => item.status,
      "source" => item.source,
      "sender" => item.sender,
      "subject" => item.subject
    }
  end

  defp short_event(event) do
    event |> Atom.to_string() |> String.replace_prefix("dispatch_item_", "")
  end

  # --- helpers -----------------------------------------------------------

  defp job_key(%{recommended_role_key: role}) when is_binary(role) and role != "", do: role
  defp job_key(_item), do: "unassigned"

  # Untrusted inbound content (e.g. an email body) is rendered as an indented
  # code block: every line is prefixed with four spaces, so the content is inert
  # data the agent reads — it cannot break out of the block or inject markdown,
  # because an indented code block has no closing delimiter to escape.
  defp fenced(nil), do: "    (no body)"
  defp fenced(""), do: "    (no body)"

  defp fenced(text) do
    text
    |> to_string()
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end

  # Collapse a value to a single inline-safe line (newlines would corrupt the
  # bullet/heading they sit in).
  defp inline(nil), do: nil

  defp inline(value) do
    value |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp shift_root, do: Artifact.workspace_path("shift")
  defp fridge_path, do: Path.join(shift_root(), "Dispatch.md")
  defp diary_dir(date), do: Path.join(shift_root(), Date.to_iso8601(date))
end
