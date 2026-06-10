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

  Coherence: SQLite is the source of truth. Both `.md` files are full overwrites
  (so they never accumulate stale items); only the dated `.jsonl` is appended (so
  history is never rewritten). The rendered `.md` content is a pure function of
  its inputs — no wall-clock — so re-rendering with no change is byte-identical.

  Writes are best-effort: a filesystem error logs and never crashes the projector
  or the action that triggered it.
  """
  use GenServer

  require Logger

  alias BusterClaw.Dispatch
  alias BusterClaw.Library.Artifact
  alias BusterClaw.LocalTime

  # Events that get a dated `.jsonl` line. `:dispatch_item_updated` (heartbeats,
  # incidental field changes) still refreshes the snapshots but is not logged, so
  # a single mark_running/finish — which also fires `:dispatch_item_updated` —
  # does not double-log.
  @logged_events ~w(dispatch_item_queued dispatch_item_claimed dispatch_item_running dispatch_item_finished)a

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Dispatch.subscribe()
    # Best-effort initial render so the fridge reflects current state on boot.
    safe_render(nil, nil)
    {:ok, %{}}
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
    write_fridge()
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

  defp write_diary(date, event, item) do
    dir = diary_dir(date)
    File.mkdir_p!(dir)
    jsonl = Path.join(dir, "Dispatch.jsonl")

    if event in @logged_events and item do
      File.write!(jsonl, event_line(event, item), [:append])
    end

    File.write!(Path.join(dir, "Dispatch.md"), render_diary(date, read_events(jsonl)))
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

  @doc "Render the dated diary `.md` from the day's decoded `.jsonl` events. Pure."
  def render_diary(date, events) do
    header = "# Dispatch — #{Date.to_iso8601(date)}\n\n#{length(events)} events\n\n"

    rows =
      case events do
        [] -> "_No events yet._\n"
        _ -> Enum.map_join(events, "\n", &diary_row/1) <> "\n"
      end

    header <> rows
  end

  defp diary_row(event) do
    ts = Map.get(event, "ts", "?")
    name = Map.get(event, "event", "?")
    id = Map.get(event, "id", "?")
    status = Map.get(event, "status", "?")
    subject = inline(Map.get(event, "subject")) || "(no subject)"
    sender = Map.get(event, "sender")
    suffix = if is_binary(sender) and sender != "", do: " (#{inline(sender)})", else: ""

    "- #{ts} · #{name} · ##{id} · #{status} · #{subject}#{suffix}"
  end

  defp event_line(event, item) do
    Jason.encode!(%{
      ts: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      event: short_event(event),
      id: item.id,
      status: item.status,
      source: item.source,
      sender: item.sender,
      subject: item.subject
    }) <> "\n"
  end

  defp short_event(event) do
    event |> Atom.to_string() |> String.replace_prefix("dispatch_item_", "")
  end

  defp read_events(jsonl) do
    case File.read(jsonl) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, map} -> [map]
            _ -> []
          end
        end)

      _ ->
        []
    end
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

  defp shift_root, do: Path.join(Artifact.workspace_root(), "shift")
  defp fridge_path, do: Path.join(shift_root(), "Dispatch.md")
  defp diary_dir(date), do: Path.join(shift_root(), Date.to_iso8601(date))
end
