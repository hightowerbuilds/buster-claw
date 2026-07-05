defmodule BusterClawWeb.CmdListLive do
  @moduledoc """
  Settings → cmd-list sub-tab: edit the terminal's command cheatsheet.

  Non-protected roles (queue, toolbox, prompts) are editable end-to-end —
  command string, label, description, per-role startup default, add/delete
  user rows. The protected roles (`mailman`, `agent-setup`) render read-only:
  the On Duty verbs are the shift safety surface, not a user preference, and
  the server refuses any submit that targets them regardless of what the UI
  sends. Row add/delete is staged in the form (`commands_sort`/`commands_drop`
  params) and only persists on "Save role".
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Sentinel
  alias BusterClaw.TerminalCommands
  alias BusterClaw.TerminalCommands.RoleEdit

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: TerminalCommands.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "cmd-list")
     |> assign_catalog()}
  end

  @impl true
  def handle_event("validate", %{"role_key" => role_key} = params, socket) do
    case socket.assigns.edits[role_key] do
      nil ->
        {:noreply, socket}

      %{base: base} ->
        form =
          base
          |> RoleEdit.changeset(Map.get(params, "role", %{}))
          |> Map.put(:action, :validate)
          |> to_edit_form(role_key)

        {:noreply, put_edit_form(socket, role_key, form)}
    end
  end

  def handle_event("save_role", %{"role_key" => role_key} = params, socket) do
    case socket.assigns.edits[role_key] do
      nil ->
        {:noreply, refuse_protected(socket, role_key, "save_role")}

      %{base: base} ->
        case TerminalCommands.save_role_edit(base, Map.get(params, "role", %{})) do
          {:ok, %{commands_changed: commands_changed}} ->
            observe(role_key, "save_role", if(commands_changed, do: :warning, else: :notice))

            {:noreply,
             socket
             |> assign_catalog()
             |> put_flash(:info, "Saved.")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, put_edit_form(socket, role_key, to_edit_form(changeset, role_key))}

          {:error, :protected} ->
            {:noreply, refuse_protected(socket, role_key, "save_role")}
        end
    end
  end

  def handle_event("reset_role", %{"role_key" => role_key}, socket) do
    case TerminalCommands.reset_role(role_key) do
      :ok ->
        observe(role_key, "reset_role", :notice)

        {:noreply,
         socket
         |> assign_catalog()
         |> put_flash(:info, "Role restored to the shipped commands.")}

      {:error, :protected} ->
        {:noreply, refuse_protected(socket, role_key, "reset_role")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not reset the role.")}
    end
  end

  def handle_event("reset_all", _params, socket) do
    :ok = TerminalCommands.reset_catalog()
    observe("*", "reset_all", :notice)

    {:noreply,
     socket
     |> assign_catalog()
     |> put_flash(:info, "Catalog restored to the shipped defaults.")}
  end

  @impl true
  def handle_info({:terminal_commands_updated, _roles}, socket) do
    # Another tab (or a save in this one) changed the catalog — re-sync.
    {:noreply, assign_catalog(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="cmd-list" class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:cmd_list} />

        <section class="ic-panel space-y-4 p-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="max-w-xl space-y-2">
              <h2 class="ic-eyebrow">Terminal command cheatsheet</h2>
              <p class="text-sm text-base-content/70">
                These are the commands the terminal's cmd-list flyout offers and the
                startup profiles type for you. Edit the wording, tune the commands,
                add your own — the On Duty verbs stay locked because the shift kill
                switch depends on them.
              </p>
            </div>
            <button
              id="cmd-list-reset-all"
              type="button"
              phx-click="reset_all"
              data-confirm="This will remove all your custom commands and restore the default catalog. Continue?"
              class={button_outline()}
            >
              Reset all to defaults
            </button>
          </div>
        </section>

        <section
          :for={role <- @roles}
          id={"cmd-list-role-#{role.key}"}
          class="ic-panel space-y-4 p-6"
        >
          <%= if role.protected do %>
            <.protected_role role={role} />
          <% else %>
            <.role_editor role={role} form={@edits[role.key].form} />
          <% end %>
        </section>
      </section>
    </Layouts.app>
    """
  end

  attr :role, :map, required: true

  defp protected_role(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4">
      <div>
        <p class="ic-eyebrow">Protected</p>
        <h2 class="font-display text-lg font-black uppercase">{@role.label}</h2>
      </div>
      <span role="img" aria-label="Protected" title="Protected" class="shrink-0">
        <.icon name="hero-lock-closed" class="size-5 text-base-content/50" />
      </span>
    </div>
    <p class="text-sm text-base-content/60">
      Part of the shift safety surface — not editable.
    </p>
    <div class="space-y-2">
      <article
        :for={command <- @role.commands}
        id={"cmd-list-row-#{@role.key}-#{command.key}"}
        class="rounded-sm border border-base-300 bg-base-100 p-3"
      >
        <div :if={command.label} class="mb-2">
          <h3 class="text-sm font-semibold">{command.label}</h3>
          <p :if={command.description} class="mt-1 text-xs leading-5 text-base-content/60">
            {command.description}
          </p>
        </div>
        <code class="block overflow-x-auto rounded-sm bg-base-200 px-2 py-1.5 font-mono text-xs text-base-content/75">
          {command.command}
        </code>
      </article>
    </div>
    """
  end

  attr :role, :map, required: true
  attr :form, Phoenix.HTML.Form, required: true

  defp role_editor(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4">
      <div>
        <p class="ic-eyebrow">Editable</p>
        <h2 id={"cmd-list-heading-#{@role.key}"} class="font-display text-lg font-black uppercase">
          {@role.label}
        </h2>
      </div>
      <button
        id={"cmd-list-reset-#{@role.key}"}
        type="button"
        phx-click="reset_role"
        phx-value-role_key={@role.key}
        data-confirm="This will remove all your custom commands from this role and restore the shipped defaults. Continue?"
        aria-label={"Reset #{@role.label} to defaults"}
        class={button_outline()}
      >
        Reset to defaults
      </button>
    </div>

    <p
      :if={@role.key == "prompts"}
      class="rounded-sm border-2 border-base-content/15 bg-base-200/60 px-3 py-2 text-xs leading-5 text-base-content/70"
    >
      One prompt per enabled skill is added to the terminal automatically from your
      <code class="font-mono">skills/</code>
      folder — those aren't listed here. To reword one, add a command with the key
      <code class="font-mono">skill-&lt;name&gt;</code>
      below; it shadows the generated prompt.
    </p>

    <.form
      for={@form}
      id={"cmd-list-form-#{@role.key}"}
      phx-change="validate"
      phx-submit="save_role"
      aria-labelledby={"cmd-list-heading-#{@role.key}"}
      class="space-y-3"
    >
      <input type="hidden" name="role_key" value={@role.key} />

      <.form_errors form={@form} />

      <.inputs_for :let={cf} field={@form[:commands]}>
        <input type="hidden" name="role[commands_sort][]" value={cf.index} />
        <article
          id={"cmd-list-row-#{@role.key}-#{cf.index}"}
          class="space-y-3 rounded-sm border border-base-300 bg-base-100 p-3"
        >
          <div class="flex items-center justify-between gap-3">
            <label
              :if={cf[:key].value}
              class="flex cursor-pointer items-center gap-2 font-mono text-[0.68rem] font-semibold uppercase tracking-wide text-base-content/65"
            >
              <input
                type="radio"
                name="role[default_key]"
                value={cf[:key].value}
                checked={to_string(@form[:default_key].value) == to_string(cf[:key].value)}
                class="size-3.5 accent-primary"
              />
              Startup default
            </label>
            <span
              :if={is_nil(cf[:key].value)}
              class="font-mono text-[0.68rem] uppercase tracking-wide text-base-content/45"
            >
              New command
            </span>

            <div class="flex items-center gap-2">
              <span
                :if={cf.data.builtin}
                class="inline-flex rounded-sm bg-base-200 px-1.5 py-0.5 font-mono text-[0.65rem] font-semibold uppercase leading-none text-base-content/55"
              >
                Built-in
              </span>
              <label
                :if={!cf.data.builtin}
                aria-label="Delete command"
                title="Delete command"
                class="grid size-7 cursor-pointer place-items-center rounded-sm text-base-content/60 transition hover:bg-base-content/10 hover:text-error"
              >
                <input type="checkbox" name="role[commands_drop][]" value={cf.index} class="hidden" />
                <.icon name="hero-trash" class="size-4" />
              </label>
            </div>
          </div>

          <.input field={cf[:key]} type="hidden" />
          <.input :if={cf.data.builtin} field={cf[:kind]} type="hidden" />

          <div class="grid gap-3 sm:grid-cols-2">
            <.input
              field={cf[:label]}
              type="text"
              label="Label"
              phx-debounce="blur"
              placeholder="Shown in the flyout"
            />
            <.input
              field={cf[:description]}
              type="text"
              label="Description"
              phx-debounce="blur"
              placeholder="One line of help text"
            />
          </div>

          <.input
            :if={!cf.data.builtin}
            field={cf[:kind]}
            type="select"
            label="Kind"
            options={[{"Shell command (single line)", "shell"}, {"Prompt (may be multiline)", "prompt"}]}
          />

          <.input
            :if={prompt_kind?(cf)}
            field={cf[:command]}
            type="textarea"
            label="Prompt"
            rows="4"
            phx-debounce="blur"
            class="w-full textarea font-mono text-xs"
          />
          <.input
            :if={!prompt_kind?(cf)}
            field={cf[:command]}
            type="text"
            label="Command"
            phx-debounce="blur"
            class="w-full input font-mono text-xs"
          />
        </article>
      </.inputs_for>
      <input type="hidden" name="role[commands_drop][]" />

      <div class="flex flex-wrap items-center justify-between gap-3 pt-1">
        <label
          id={"cmd-list-add-#{@role.key}"}
          aria-label={"Add command to #{@role.label}"}
          class={["cursor-pointer", button_outline()]}
        >
          <input type="checkbox" name="role[commands_sort][]" value="new" class="hidden" />
          <span class="inline-flex items-center gap-1.5">
            <.icon name="hero-plus" class="size-4" /> Add command
          </span>
        </label>
        <button
          id={"cmd-list-save-#{@role.key}"}
          type="submit"
          class="inline-flex items-center gap-2 rounded bg-primary px-4 py-2 text-sm font-semibold text-primary-content transition hover:opacity-85"
        >
          Save role
        </button>
      </div>
    </.form>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  # Role-level errors (dropped built-in, duplicate keys, bad default) don't
  # belong to any single input — surface them above the rows.
  defp form_errors(assigns) do
    ~H"""
    <div
      :if={@form.source.action && role_level_errors(@form) != []}
      class="rounded-sm border-2 border-error/40 bg-error/10 px-3 py-2 text-sm"
    >
      <p :for={message <- role_level_errors(@form)}>{message}</p>
    </div>
    """
  end

  defp role_level_errors(form) do
    for field <- [:commands, :default_key],
        {msg, opts} <- Keyword.get_values(form.source.errors, field) do
      translate_error({msg, opts})
    end
  end

  defp prompt_kind?(command_form), do: to_string(command_form[:kind].value) == "prompt"

  defp assign_catalog(socket) do
    roles = TerminalCommands.roles()

    edits =
      for role <- roles, not role.protected, into: %{} do
        base = TerminalCommands.role_edit(role.key)
        {role.key, %{base: base, form: to_edit_form(RoleEdit.changeset(base, %{}), role.key)}}
      end

    socket
    |> assign(:roles, roles)
    |> assign(:edits, edits)
  end

  defp to_edit_form(changeset, role_key),
    do: to_form(changeset, as: "role", id: "cmd-list-#{role_key}")

  defp put_edit_form(socket, role_key, form) do
    assign(socket, :edits, put_in(socket.assigns.edits, [role_key, :form], form))
  end

  defp refuse_protected(socket, role_key, action) do
    Sentinel.observe(
      :settings_change,
      "refused cmd-list edit to protected role",
      %{role: role_key, action: "#{action}_refused"},
      severity: :warning
    )

    put_flash(socket, :error, "That role is protected and cannot be edited.")
  end

  defp observe(role_key, action, severity) do
    Sentinel.observe(
      :settings_change,
      "terminal cmd-list edited",
      %{role: role_key, action: action},
      severity: severity
    )
  end

  defp button_outline,
    do:
      "rounded border-2 border-base-content/30 px-4 py-2 text-sm font-semibold transition hover:bg-base-200"
end
