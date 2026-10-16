defmodule BusterClawWeb.Explained.Models do
  @moduledoc """
  The Models tutorial — which agent CLI and model run each surface.

  The surface list and the floor/claude-only badges render FROM
  `BusterClaw.ModelPolicy`, so those cannot describe a policy that no longer
  exists.

  **The prose is not protected the same way, and once wasn't.** Until 08-09 this
  page taught capability floors as a live mechanism — a whole rung of the
  decision diagram, its `aria-label`, the figcaption, and a worked example —
  after `@floors` had emptied out with the trading stack on 08-08. The badge
  test kept passing because it iterates `ModelPolicy.floors()`, and an empty map
  makes that loop vacuous. Derive-from-source protects the thing derived and
  nothing else on the page; if you add a sentence here that quotes a count or
  names a surface set, it is a string literal and it will rot.
  """
  use BusterClawWeb, :html
  import BusterClawWeb.Explained.Shared

  alias BusterClaw.ModelPolicy

  # The Models tutorial — the original ask behind the model-versatility work.
  # It teaches the *shape* before the setting: the CLI is the operator's, so the
  # model and the bill are theirs; the surfaces have different stakes; and unset
  # is a real state, not a blank to fill in.
  #
  # The surface list and the floor model are READ FROM `ModelPolicy` rather than
  # retyped, so this page cannot drift from the policy it describes — the copy
  # in the other tutorials is guarded by a test, this one by construction.
  #
  # Nothing here promises a per-chat picker or a spend report: both are Phase 4
  # of the roadmap and neither exists.
  def models_panel(assigns) do
    assigns = assign(assigns, surfaces: surface_rows())

    ~H"""
    <div class="mx-auto flex max-w-2xl flex-col gap-8 px-6 py-8">
      <div>
        <p class="ic-eyebrow">The engine</p>
        <h2 class="mt-2 font-display text-2xl font-black tracking-tight">
          Models — whose model, whose bill, and which surface
        </h2>
      </div>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/80">
        <p>
          Buster Claw has no AI inside it. Each run shells out to a supported agent
          CLI you installed and signed in to: <code>claude</code>, <code>codex</code>,
          or <code>opencode</code>. Any surface can use any of the three. The app
          holds no Claude API key and bills you nothing for tokens: the login,
          model, and invoice are yours.
        </p>
        <p>
          Out of the box the app says nothing about which model to use. It passes
          no <code>--model</code> at all, and your CLI decides — exactly what happens
          when you type <code>claude</code> in a terminal. That is not a blank waiting
          to be filled in. It is a real, sane setting, and it is what a fresh
          install does.
        </p>
        <p>
          What the app adds is the ability to <span class="font-semibold text-base-content">name a model per surface</span>,
          because the surfaces are not alike. A chat you are sitting in front of, a
          dispatcher grinding through a queue while you sleep, and a fan-out of
          sub-runs are not the same job, and the cheapest model that is fine for
          one is not automatically fine for the next.
        </p>
      </div>

      <figure class="flex flex-col gap-2">
        <svg
          viewBox="0 0 560 198"
          role="img"
          aria-label="Within the selected harness, the surface's own model wins; otherwise that harness's default applies. If neither is set, the CLI decides."
          class="w-full text-base-content/70"
        >
          <defs>
            <marker
              id="mp-arrow"
              viewBox="0 0 8 8"
              refX="7"
              refY="4"
              markerWidth="6"
              markerHeight="6"
              orient="auto-start-reverse"
            >
              <path d="M0,0 L8,4 L0,8 z" fill="currentColor" />
            </marker>
          </defs>

          <text
            x="14"
            y="20"
            class="font-mono"
            fill="currentColor"
            font-size="9"
            font-weight="bold"
          >
            ASKED PER SURFACE, FIRST MATCH WINS
          </text>

          <line
            x1="24"
            y1="34"
            x2="24"
            y2="184"
            stroke="currentColor"
            stroke-width="1.5"
            marker-end="url(#mp-arrow)"
          />

          <g fill="none" stroke="currentColor" stroke-width="1.5">
            <rect x="40" y="34" width="250" height="38" />
            <rect x="40" y="86" width="250" height="38" />
          </g>
          <rect
            x="40"
            y="138"
            width="250"
            height="38"
            fill="none"
            stroke="var(--color-primary)"
            stroke-width="2"
          />

          <g class="font-mono" fill="currentColor" font-size="10">
            <text x="54" y="58" font-weight="bold">THIS SURFACE'S OWN MODEL</text>
            <text x="54" y="110" font-weight="bold">THIS HARNESS'S DEFAULT</text>
            <text x="54" y="162" font-weight="bold">NOTHING SET</text>
          </g>

          <g class="font-mono" fill="currentColor" font-size="8">
            <text x="302" y="52">honoured as-is,</text>
            <text x="302" y="63">whatever you name</text>
            <text x="302" y="104">same harness,</text>
            <text x="302" y="115">no surface override</text>
          </g>
          <g class="font-mono" fill="var(--color-primary)" font-size="8">
            <text x="302" y="156">no --model is passed;</text>
            <text x="302" y="167">your CLI decides</text>
          </g>
        </svg>
        <figcaption class="text-xs leading-relaxed text-base-content/60">
          The bottom rung is the shipped state — nothing is set, and that is an
          answer rather than a gap.
        </figcaption>
      </figure>

      <section class="flex flex-col gap-3">
        <h3 class="font-display text-base font-black uppercase tracking-wide">
          The surfaces
        </h3>
        <ul class="ic-unfold" style="list-style: none; padding-left: 0;">
          <li :for={surface <- @surfaces} data-model-surface={surface.name}>
            <span class="font-mono font-bold text-base-content">{surface.name}</span>
            — {surface.description}
            <span
              :if={surface.floor}
              class="ml-1 whitespace-nowrap font-mono text-[0.62rem] font-bold uppercase tracking-wide text-primary"
            >
              floor: {surface.floor}
            </span>
            <span
              :if={surface.claude_only}
              data-claude-only
              class="ml-1 whitespace-nowrap font-mono text-[0.62rem] font-bold uppercase tracking-wide text-primary"
            >
              Claude only
            </span>
          </li>
        </ul>
      </section>

      <.example
        n={1}
        title="What am I actually running?"
        want="Before you change anything, find out what is in force."
        needs="An agent CLI installed and signed in. Nothing configured — this is the first thing to run on a fresh install."
        touches="Reads the model policy. Changes nothing."
        confirm="The command is restricted and policy-gated, including this read-only use. Run it from your trusted chat or terminal, or inspect Configuration."
        result="A per-surface list in chat, each row naming the model and where it came from. On a fresh install every row says your CLI decides, which is the shipped state rather than an error."
      >
        <.prompt text="Which model is each part of Buster Claw running right now — and if I set one default, where would it not apply?" />
        <ol class="ic-unfold">
          <li>
            <code>model_policy</code> with no arguments lists every surface: the model
            in force, and where that came from — the surface's own setting, the
            global default, or your CLI.
          </li>
          <li>
            On a fresh install the answer is "your CLI" on every surface, because
            nothing is set and no <code>--model</code> is passed. That is the
            shipped state, not a gap.
          </li>
          <li>
            The same list, with pickers, is in the model section of <.link
              navigate="/settings"
              class="font-semibold text-primary hover:opacity-80"
            >
              Configuration
            </.link>. Reading it there and reading it in chat give the same answer.
          </li>
        </ol>
      </.example>

      <.example
        n={2}
        title="Set a default for your harness"
        want="Share a model choice across surfaces using the same harness."
        needs="A model name your chosen harness recognizes — model names do not carry across harnesses."
        touches="Writes the selected harness's default model. Surfaces using that harness without their own override inherit it; other harnesses keep their own choices."
        confirm="model_policy is policy-gated: an untrusted-origin run is refused. Your trusted chat, terminal, and Configuration controls can change it."
        result="The new default shows in the model section of Configuration and in `model_policy`. Name a model your harness does not know and the failure surfaces on the next run from that CLI, not here."
      >
        <.prompt text="Show me my current harness and model choices, then help me choose a cheaper default for the harness I use for errands." />
        <ol class="ic-unfold">
          <li>
            Pick a harness first in Configuration, then set its default model.
            Through <code>model_policy</code>, name <code>surface: default</code>
            and the model. Only surfaces using that harness without their own
            model override inherit the choice.
          </li>
          <li>
            Read the per-surface list after a change to see what each surface
            will use. Existing conversations can retain their current session;
            start a new conversation when you want the new choice immediately.
          </li>
          <li>
            Clearing the default puts you back to unset, which means back to no <code>--model</code>
            at all. Nothing is sticky that you can't undo.
          </li>
        </ol>
      </.example>

      <div class="flex flex-col gap-3 text-sm leading-relaxed text-base-content/70">
        <p>
          <span class="font-semibold text-base-content">Three harnesses, not one.</span>
          Buster Claw can run a surface through <code>claude</code>, <code>codex</code>
          or <code>opencode</code>
          — whichever you have installed. Pick the harness
          first, then the model inside it, because a model name only means something
          to its own harness. Claude and Codex accept model IDs; OpenCode uses
          a <code>provider/model</code>
          name. Your models are remembered
          per harness, so trying one and going back does not lose the other's
          settings. Leave it on <code>auto</code>
          and the app uses whichever CLI it
          finds — that is the shipped behaviour and it is a perfectly good answer.
        </p>
        <p>
          <span class="font-semibold text-base-content">What this doesn't do yet.</span>
          There is no per-conversation model picker — the choice is per surface, so
          every chat runs on the chat surface's model. Every harness does report
          what a run cost — Claude and OpenCode in dollars, Codex in tokens —
          but there is no per-surface or per-day total anywhere yet. A
          conversation keeps its thread between turns on every harness — Codex
          and OpenCode each run through one long-lived server connection the app
          opens on first use.
        </p>
      </div>

      <.link
        navigate="/settings"
        class="inline-flex w-fit items-center gap-2 rounded-xs bg-primary px-4 py-1.5 font-mono text-xs font-bold uppercase tracking-wide text-primary-content transition hover:opacity-85"
      >
        <.icon name="hero-arrow-right" class="size-3.5" /> Open Configuration
      </.link>
    </div>
    """
  end

  # Every surface exactly as `ModelPolicy` defines them — descriptions, floors
  # and claude-only pins all come from the policy module, so the tutorial cannot
  # describe a surface set that no longer exists. Deliberately not a count: see
  # the moduledoc for what happened the last time this page hardcoded one.
  defp surface_rows do
    descriptions = ModelPolicy.surfaces()
    floors = ModelPolicy.floors()

    Enum.map(ModelPolicy.surface_keys(), fn key ->
      %{
        name: Atom.to_string(key),
        description: Map.fetch!(descriptions, key),
        floor: Map.get(floors, key),
        claude_only: ModelPolicy.claude_only?(key)
      }
    end)
  end
end
