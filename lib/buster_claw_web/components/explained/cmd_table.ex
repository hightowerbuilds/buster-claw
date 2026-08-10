defmodule BusterClawWeb.Explained.CmdTable do
  @moduledoc """
  The whole command catalog, rendered inside the Command List tutorial.

  ## Why this is inline rather than a link

  The tutorial used to end with "Browse the full command list" pointing at
  `/cmd-list`. **That route is not the command catalog.** `CmdListLive` is
  *"Settings → cmd-list sub-tab: edit the terminal's command cheatsheet"* — the
  queue/toolbox/prompts rows the terminal offers, a different surface with a
  confusingly similar name. So the tutorial's two claims that the "live, complete
  list" lived there were simply wrong, and a reader following either link landed
  on an editor for something else. Operator called it on 08-09; the list is here
  now, and the links are gone.

  ## Generated, never transcribed

  Every row comes from `Commands.list_commands/0` at render time. Nothing here is
  a copy of the catalog, so a command added anywhere in
  `BusterClaw.Commands.Catalog.*` appears on this page with no edit — which is the
  same property `Explained.Registry` gives the rail, and the opposite of that
  module's `@command_stats`, which IS a transcription and needs a contract test
  to stay honest. There is nothing to keep in sync here.

  ## Grouped by prefix, which is derived and therefore self-filing

  33 groups, from `sound_` at 29 commands down to several with one. Hand-curated
  families would read better and would drift the first time someone added a verb
  whose home was ambiguous; a prefix is mechanical, so a new command files itself.
  Groups are alphabetical rather than by size — a reader looking for `sound_` is
  looking it up, not touring.

  ## Collapsed by default

  203 descriptions, the longest 2,562 characters, is not a page anyone reads top
  to bottom. Each command is a `<details>`: the summary line carries the name and
  its three pieces of metadata, and the body carries the full description and the
  arguments. Native `<details>` rather than LiveView state, for the reason
  `Explained.Intro`'s Get Started block gives — the panel renders behind an `:if`,
  so open/closed state kept server-side would be discarded on every tab switch,
  and the browser's own is not.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Commands

  @doc """
  Every native catalog command, grouped by name prefix.

  Composition skills (`Commands.list_skills/0`) are deliberately excluded: they
  are user-authored and per-workspace, so they are not part of the surface this
  tutorial documents.
  """
  def command_table(assigns) do
    commands = Commands.list_commands()

    groups =
      commands
      |> Enum.group_by(&(&1.name |> String.split("_") |> hd()))
      |> Enum.map(fn {prefix, cmds} -> {prefix, Enum.sort_by(cmds, & &1.name)} end)
      |> Enum.sort_by(&elem(&1, 0))

    assigns = assign(assigns, groups: groups, total: length(commands))

    ~H"""
    <section class="flex flex-col gap-4" id="explained-command-atlas">
      <div>
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          Every command, all {@total} of them
        </h3>
        <p class="mt-2 text-sm leading-relaxed text-base-content/80">
          Read from the catalog as this page renders, so it cannot go stale. Open a
          row for what it does, what it takes, and what it costs you in trust.
          <span class="font-semibold text-base-content">You are not meant to memorize these</span>
          — say the outcome in Chat and let the agent pick the verb. This is here so
          you can check what it picked, and what it could have picked.
        </p>
      </div>

      <nav class="flex flex-wrap gap-1" aria-label="Command groups">
        <a
          :for={{prefix, cmds} <- @groups}
          href={"#cmdgroup-#{prefix}"}
          class="rounded-sm border border-base-content/20 px-1.5 py-0.5 font-mono text-[0.62rem] font-semibold uppercase tracking-wide text-base-content/60 transition hover:border-primary hover:text-primary"
        >
          {prefix}<span class="text-base-content/35">·{length(cmds)}</span>
        </a>
      </nav>

      <div :for={{prefix, cmds} <- @groups} id={"cmdgroup-#{prefix}"} class="flex flex-col gap-1">
        <h4 class="ic-eyebrow border-b border-base-content/15 pb-1">
          {prefix}_ <span class="text-base-content/35">{length(cmds)}</span>
        </h4>

        <details :for={cmd <- cmds} id={"cmd-#{cmd.name}"} class="group">
          <summary class="flex cursor-pointer flex-wrap items-center gap-2 py-1">
            <code class="font-mono text-[0.8rem] font-bold text-base-content">{cmd.name}</code>
            <.badge kind={cmd.type} />
            <.badge kind={cmd.tier} />
            <.badge :if={Map.get(cmd, :gated, false)} kind={:gated} />
          </summary>

          <div class="flex flex-col gap-2 border-l-2 border-base-content/15 py-2 pl-3">
            <p class="text-sm leading-relaxed text-base-content/80">{cmd.description}</p>
            <.args args={cmd.args} />
          </div>
        </details>
      </div>
    </section>
    """
  end

  attr :kind, :atom, required: true

  # The three axes the taxonomy section above the table explains, as one chip
  # each. Colour carries meaning rather than decoration: hazard orange is spent
  # only on the two that cost trust — a write, and a gate — so a row that is
  # merely `:read`/`:safe` stays quiet and the eye lands on the ones that are not.
  defp badge(assigns) do
    ~H"""
    <span class={[
      "rounded-sm border px-1 py-px font-mono text-[0.58rem] font-bold uppercase tracking-wide",
      case @kind do
        :gated -> "border-primary bg-primary text-primary-content"
        :mutate -> "border-primary text-primary"
        :trigger -> "border-primary/50 text-primary/80"
        :restricted -> "border-base-content/35 text-base-content/60"
        _ -> "border-base-content/20 text-base-content/45"
      end
    ]}>
      {@kind}
    </span>
    """
  end

  attr :args, :map, required: true

  # Required before optional, because that is the order a caller has to think in.
  # A command with no arguments says so rather than rendering an empty row — an
  # absent list reads as "not documented", and these are documented as taking
  # nothing.
  defp args(assigns) do
    {required, optional} =
      assigns.args
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.split_with(fn {_name, spec} -> Map.get(spec, :required, false) end)

    assigns = assign(assigns, required: required, optional: optional)

    ~H"""
    <p :if={@required == [] and @optional == []} class="font-mono text-[0.62rem] text-base-content/40">
      no arguments
    </p>

    <div :if={@required != [] or @optional != []} class="flex flex-col gap-1">
      <.arg_row :if={@required != []} label="required" args={@required} strong />
      <.arg_row :if={@optional != []} label="optional" args={@optional} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :args, :list, required: true
  attr :strong, :boolean, default: false

  defp arg_row(assigns) do
    ~H"""
    <div class="flex flex-wrap items-baseline gap-1.5">
      <span class="ic-eyebrow shrink-0">{@label}</span>
      <span
        :for={{name, spec} <- @args}
        class={[
          "rounded-sm border px-1 py-px font-mono text-[0.62rem]",
          if(@strong,
            do: "border-base-content/30 text-base-content/75",
            else: "border-base-content/15 text-base-content/50"
          )
        ]}
        title={arg_title(spec)}
      >
        {name}<span class="text-base-content/35">:{spec.type}</span>
      </span>
    </div>
    """
  end

  # The tooltip carries what the chip has no room for: the default a caller gets
  # by staying silent, and the closed set of values when there is one.
  defp arg_title(spec) do
    [
      case Map.fetch(spec, :default) do
        {:ok, value} -> "default #{inspect(value)}"
        :error -> nil
      end,
      case Map.fetch(spec, :enum) do
        {:ok, values} -> "one of: #{Enum.join(values, ", ")}"
        :error -> nil
      end
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end
end
