defmodule BusterClawWeb.MemoryLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Memory
  alias BusterClaw.Memory.Memory, as: MemoryRecord
  alias BusterClaw.Runtime.Status

  @impl true
  def mount(_params, _session, socket) do
    snapshot = Status.snapshot()

    {:ok,
     socket
     |> assign(:page_title, "Memory")
     |> assign(:editing_memory, nil)
     |> assign(:result, nil)
     |> assign(:database_path, snapshot.database_path)
     |> assign(:database_exists?, snapshot.database_exists?)
     |> assign_form(MemoryRecord.changeset(%MemoryRecord{}, default_attrs()))
     |> load_memories()}
  end

  @impl true
  def handle_event("validate", %{"memory" => params}, socket) do
    memory = socket.assigns.editing_memory || %MemoryRecord{}

    changeset =
      memory
      |> MemoryRecord.changeset(normalize_params(params))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"memory" => params}, socket) do
    params = normalize_params(params)

    result =
      case socket.assigns.editing_memory do
        nil -> Memory.create_memory(params)
        memory -> Memory.update_memory(memory, params)
      end

    case result do
      {:ok, _memory} ->
        {:noreply,
         socket
         |> assign(:editing_memory, nil)
         |> assign(:result, "Memory saved.")
         |> assign_form(MemoryRecord.changeset(%MemoryRecord{}, default_attrs()))
         |> load_memories()}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    memory = Memory.get_memory!(id)

    {:noreply,
     socket
     |> assign(:editing_memory, memory)
     |> assign(:result, nil)
     |> assign_form(MemoryRecord.changeset(memory, %{}))}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_memory, nil)
     |> assign(:result, nil)
     |> assign_form(MemoryRecord.changeset(%MemoryRecord{}, default_attrs()))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    memory = Memory.get_memory!(id)
    {:ok, _memory} = Memory.delete_memory(memory)

    {:noreply,
     socket
     |> assign(:editing_memory, nil)
     |> assign(:result, "Memory deleted.")
     |> assign_form(MemoryRecord.changeset(%MemoryRecord{}, default_attrs()))
     |> load_memories()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="space-y-6">
        <BusterClawWeb.AdvancedTabs.tabs active={:memory} />

        <p :if={@result} class="rounded border border-base-300 bg-base-100 px-4 py-3 text-sm">
          {@result}
        </p>

        <section class="rounded-lg border border-base-300 bg-base-100 p-5">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <h2 class="text-sm font-semibold text-base-content/70">SQLite Database</h2>
              <p class="mt-2 break-words font-mono text-sm">{@database_path}</p>
            </div>
            <span class={[
              "rounded-full px-2 py-1 text-xs font-semibold",
              if(@database_exists?,
                do: "bg-success/15 text-success",
                else: "bg-warning/15 text-warning"
              )
            ]}>
              {if @database_exists?, do: "ready", else: "pending"}
            </span>
          </div>
        </section>

        <div class="grid gap-6 lg:grid-cols-[380px_minmax(0,1fr)]">
          <.form
            for={@form}
            id="memory-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4 rounded-lg border border-base-300 bg-base-100 p-5"
          >
            <h2 class="text-lg font-semibold">
              {if @editing_memory, do: "Edit Memory", else: "Add Memory"}
            </h2>
            <.input field={@form[:created_at]} label="Created At" />
            <.input field={@form[:text]} label="Text" type="textarea" />
            <div class="flex gap-2">
              <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100">
                Save
              </button>
              <button
                :if={@editing_memory}
                type="button"
                class="rounded border border-base-300 px-4 py-2 text-sm"
                phx-click="cancel"
              >
                Cancel
              </button>
            </div>
          </.form>

          <section class="rounded-lg border border-base-300 bg-base-100">
            <div class="border-b border-base-300 px-4 py-3 text-sm font-semibold">
              {@memories_count} memories
            </div>

            <div class="divide-y divide-base-300">
              <div :for={memory <- @memories} class="px-4 py-4">
                <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                  <div class="min-w-0">
                    <p class="whitespace-pre-wrap text-sm leading-6">{memory.text}</p>
                    <p class="mt-2 font-mono text-xs text-base-content/60">
                      {format_datetime(memory.created_at)}
                    </p>
                  </div>

                  <div class="flex gap-2">
                    <button
                      class="rounded border border-base-300 px-3 py-2 text-sm"
                      phx-click="edit"
                      phx-value-id={memory.id}
                    >
                      Edit
                    </button>
                    <button
                      class="rounded border border-error/40 px-3 py-2 text-sm text-error"
                      phx-click="delete"
                      phx-value-id={memory.id}
                    >
                      Delete
                    </button>
                  </div>
                </div>
              </div>

              <div :if={@memories == []} class="px-4 py-10 text-center text-sm text-base-content/60">
                No memories recorded yet.
              </div>
            </div>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_memories(socket) do
    memories =
      Memory.list_memories()
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

    socket
    |> assign(:memories, memories)
    |> assign(:memories_count, length(memories))
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  defp default_attrs do
    %{created_at: DateTime.utc_now() |> DateTime.truncate(:second)}
  end

  defp normalize_params(params) do
    params
    |> Map.update("created_at", nil, &parse_datetime/1)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    value
    |> String.replace(" UTC", "Z")
    |> String.replace(" ", "T")
    |> DateTime.from_iso8601()
    |> case do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> value
    end
  end

  defp parse_datetime(value), do: value

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp format_datetime(_datetime), do: ""
end
