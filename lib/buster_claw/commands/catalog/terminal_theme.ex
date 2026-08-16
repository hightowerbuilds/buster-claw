defmodule BusterClaw.Commands.Catalog.TerminalTheme do
  @moduledoc """
  Catalog entries for the terminal's colours — the first commands in this app
  that change **what the operator sees** (TERMINAL_PAINT_ROADMAP Phase 3).

  **Four verbs, and the roadmap's D6 says no more until something asks.**
  `terminal_theme_list` says what exists, `_select` wears one, `_paint` writes
  the agent's own slot and wears it, and `_reset` goes back to the default and
  forgets what the agent painted. There is no import, no export, no random, no
  animation and no per-surface theming.

  ## Why a palette needs no approval and a shader does

  `Appearance` accepts operator-authored `.wgsl`, and a command may apply one only
  when its exact bytes are approved — the operator's click, or the one-time
  backfill of files predating that gate — so an edit withdraws it. A palette needs
  no approval (roadmap D1): 21 validated `#rrggbb` values cannot execute or escape,
  where a shader is GPU code nobody has read. One table of colours, not appearance.

  ## Why the writes are `:restricted` and not gated

  They change the operator's environment without asking, which is exactly what
  `:restricted` means — `:safe` would let any MCP/agent token repaint the
  machine. They are **not** gated because a confirmation dialog for a colour is
  theatre, and it would make the toy unusable in the one place it is meant to be
  fun (roadmap D4).

  Unattended runs may fire them, and that is only defensible because of the
  legibility floor: `terminal_theme_paint` goes through
  `BusterClaw.TerminalTheme.set_agent/2`, which refuses a palette the operator
  could not read. An agent that could set `foreground` to `background` could
  **hide its own output**, and this app's whole audit layer is premised on the
  operator being able to see.

  ## The slot the writes cannot reach

  Nothing here writes the operator's `custom` slot. There is one custom slot,
  `set_custom/3` overwrites it wholesale, and an agent writing there would
  silently destroy a theme the operator built and named. The agent gets its own
  `agent` slot instead (roadmap D3), and the absence of any verb that reaches
  the operator's is the enforcement — `test/buster_claw/commands/terminal_theme_test.exs`
  fails if one ever appears.
  """

  @doc "Terminal-theme catalog entries."
  def entries,
    do: [
      %{
        name: "terminal_theme_list",
        type: :read,
        tier: :safe,
        description:
          "Every colour theme the in-app terminal can wear: each theme's key, operator-facing label, and the three swatch colours that represent it, plus which theme an unset selection falls back to. Also reports the two DYNAMIC slots and which of them currently holds a saved palette — `custom` is the operator's, written only from Settings and never by a command, and `agent` is yours, written by terminal_theme_paint. A theme marked token_derived (industrial) carries no fixed colours: it follows the app's own light/dark theme and is resolved in the browser. The `fields` list is the exact set of colour names terminal_theme_paint accepts. Which theme is CURRENTLY selected is deliberately not reported and cannot be — the selection lives in the operator's browser, not on the server — so read this for what EXISTS, and select or paint rather than guessing what is on screen.",
        args: %{}
      },
      %{
        name: "terminal_theme_select",
        type: :mutate,
        tier: :restricted,
        description:
          "Wear an existing theme, live, in every open terminal — no reload, no click. `key` must be one of the keys terminal_theme_list returns; anything else is refused with the valid keys named. This changes what the operator is looking at, so say what you are doing and why.",
        args: %{
          "key" => %{
            type: :string,
            required: true,
            description:
              "The theme key to select, from terminal_theme_list — e.g. industrial, nord, monokai, or agent once you have painted one."
          }
        }
      },
      %{
        name: "terminal_theme_paint",
        type: :mutate,
        tier: :restricted,
        description:
          "Write YOUR OWN theme slot and wear it immediately. `colors` is a map of colour name to \"#rrggbb\" and may be PARTIAL — it merges over the palette in the agent slot, or over the default starting palette when the slot is empty, so \"make the foreground orange\" is one field, not twenty-one. Colour names come from terminal_theme_list's `fields`. The merged result is validated whole and REFUSED whole: a malformed hex fails, and so does a palette the operator could not read — foreground must clear 4.5:1 contrast against background, the cursor 2.0:1, and at least 10 of the 16 ANSI colours 2.0:1. A refusal names the field and the ratio it scored, so correct that field and paint again. This never touches the operator's own `custom` theme; there is no command that can.",
        args: %{
          "colors" => %{
            type: :map,
            required: true,
            description:
              "Colour name to \"#rrggbb\", e.g. {\"foreground\": \"#ff4d1c\"}. Partial is fine and is the point — unnamed fields keep their current value."
          },
          "name" => %{
            type: :string,
            required: false,
            description:
              "What to call this theme in the operator's picker. Defaults to the agent slot's current name, or \"Agent\" the first time."
          }
        }
      },
      %{
        name: "terminal_theme_reset",
        type: :mutate,
        tier: :restricted,
        description:
          "Put the terminal back to the default theme and forget whatever you painted — the agent slot is cleared and disappears from the picker. This CLEARS rather than restores: which theme the operator had selected lives in their browser and the server has never known it, so the honest reset is a state they can recognise instead of a guess. Their own saved `custom` theme is untouched and still one click away.",
        args: %{}
      }
    ]
end
