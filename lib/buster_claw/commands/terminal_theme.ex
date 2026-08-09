defmodule BusterClaw.Commands.TerminalTheme do
  @moduledoc """
  The `terminal_theme_*` command surface — the model recolours the terminal it
  is running in (TERMINAL_PAINT_ROADMAP Phase 3). Delegated to from
  `BusterClaw.Commands`.

  Four verbs and no more: list what exists, select one, paint the agent's own
  slot, reset. `BusterClaw.TerminalTheme` owns the palettes, the slots and the
  legibility floor; `BusterClaw.TerminalPaint` owns the "wear this now"
  broadcast. This module only turns those answers into wire-shaped maps and
  turns their refusals into sentences.

  ## Every write ends in an announce, because nothing else reaches a terminal

  The selected theme lives in `localStorage["bc:term-theme"]` in the operator's
  browser. **Nothing on the server knows which theme is active, and writing a
  Setting cannot change what a terminal looks like.** A command has no socket,
  so it cannot `push_event` either. The one route out is
  `TerminalPaint.announce/2` → `BusterClawWeb.ChromeHook` → `theme.js`, and that
  is why each of the three mutating verbs below ends with the same call: a write
  that does not announce is a change nobody sees until they reload.

  `announce/2` is fire-and-forget by design. A browser that is not open has
  nothing to apply, so these verbs report what they *did*, never how many
  terminals were listening.

  ## Nothing here can touch the operator's theme

  There is one custom slot, `set_custom/3` overwrites it wholesale, and an agent
  writing there would delete a palette the operator built with a colour picker
  and named. So no function in this module calls it — `paint` writes
  `set_agent/2` and `reset` calls `clear_agent/0`, both of which address the
  agent's own slot only. The enforcement is the **absence** of a call, held in
  place by a call-graph test in
  `test/buster_claw/commands/terminal_theme_test.exs` rather than by a policy
  check, the same way Pockets kept mounting out of the command surface.

  ## Refusals are sentences

  A caller that cannot read the refusal cannot correct it, and an unattended run
  has nobody to interpret `inspect/1` output for it. So an unknown key names the
  keys that exist, and an illegible palette names the field and the ratio it
  scored — which is the whole reason `set_agent/2` returns the field rather than
  a bare `:error`.
  """

  alias BusterClaw.TerminalPaint
  alias BusterClaw.TerminalTheme

  # ---------------------------------------------------------------------------
  # What exists
  # ---------------------------------------------------------------------------

  @doc """
  Every theme, both dynamic slots, and the colour fields `paint` accepts.

  Deliberately does **not** report which theme is selected: that is
  `localStorage` in the operator's browser and the server has never known it.
  Reporting a guess would be worse than reporting nothing.
  """
  def terminal_theme_list(_args \\ %{}) do
    {:ok,
     %{
       default: TerminalTheme.default(),
       themes: Enum.map(TerminalTheme.themes(), &theme_entry/1),
       slots: %{
         agent: agent_slot(),
         custom: custom_slot()
       },
       fields:
         Enum.map(TerminalTheme.fields(), fn {name, label} -> %{name: name, label: label} end)
     }}
  end

  # ---------------------------------------------------------------------------
  # Wearing one
  # ---------------------------------------------------------------------------

  @doc """
  Select an existing theme, live.

  The palette is sent along rather than left for the client to look up, because
  a page that loaded before the agent slot was written has never heard of it —
  `announce/2` takes both for exactly this case, and `palette/1` answering `nil`
  for `industrial` is the token-derived signal the client already understands.
  """
  def terminal_theme_select(%{"key" => key}) when is_binary(key) do
    if TerminalTheme.valid?(key) do
      TerminalPaint.announce(key, TerminalTheme.palette(key))
      {:ok, %{selected: key, label: TerminalTheme.label(key), applied: true}}
    else
      {:error, unknown_key(key)}
    end
  end

  def terminal_theme_select(_args), do: {:error, missing_key()}

  # ---------------------------------------------------------------------------
  # Painting the agent's own slot
  # ---------------------------------------------------------------------------

  @doc """
  Write the agent slot from a partial `colors` map and wear it.

  Everything that could refuse — the merge base, the malformed hex, and the
  palette the operator could not read — belongs to
  `TerminalTheme.set_agent/2`. An omitted `name` is passed on as `nil`, which
  that function reads as "keep whatever this slot is already called", rather
  than being defaulted here: a second copy of the naming rule is a second thing
  to get wrong, and a caller who omits `name` is changing colours, not renaming
  a theme.
  """
  def terminal_theme_paint(%{"colors" => colors} = args) when is_map(colors) do
    case TerminalTheme.set_agent(paint_name(args), colors) do
      {:ok, theme} ->
        TerminalPaint.announce(theme.key, theme.palette)

        {:ok,
         %{
           selected: theme.key,
           label: theme.label,
           palette: theme.palette,
           applied: true
         }}

      {:error, reason} ->
        {:error, paint_refusal(reason)}
    end
  end

  def terminal_theme_paint(_args), do: {:error, missing_colors()}

  # ---------------------------------------------------------------------------
  # Putting it back
  # ---------------------------------------------------------------------------

  @doc """
  Clear the agent slot and wear the default theme.

  Clearing happens first so the announced palette is read from a store that no
  longer holds the agent's, and so a caller watching both cannot observe the
  default selected while the agent's theme is still in the picker.
  """
  def terminal_theme_reset(_args \\ %{}) do
    TerminalTheme.clear_agent()
    key = TerminalTheme.default()
    TerminalPaint.announce(key, TerminalTheme.palette(key))

    {:ok, %{selected: key, label: TerminalTheme.label(key), cleared: true, applied: true}}
  end

  # ---------------------------------------------------------------------------
  # Shaping
  # ---------------------------------------------------------------------------

  defp theme_entry(theme) do
    %{
      key: theme.key,
      label: theme.label,
      swatch: theme.swatch,
      token_derived: is_nil(theme.palette)
    }
  end

  # The agent's slot: writable, and reported as empty rather than omitted so the
  # model can tell "I have not painted yet" from "painting is unavailable".
  defp agent_slot do
    slot(TerminalTheme.agent_key(), TerminalTheme.agent(), true)
  end

  # The operator's slot. `writable: false` is a statement about this surface, not
  # about the store: it is written from Settings, and no command reaches it.
  defp custom_slot do
    slot(TerminalTheme.custom_key(), TerminalTheme.custom(), false)
  end

  defp slot(key, nil, writable?), do: %{key: key, saved: false, label: nil, writable: writable?}

  defp slot(key, theme, writable?),
    do: %{key: key, saved: true, label: theme.label, writable: writable?}

  # `nil` is the "keep the name it has" signal `set_agent/2` documents, so an
  # absent name is passed on rather than resolved here.
  defp paint_name(args) do
    case args["name"] do
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Refusals, as sentences
  # ---------------------------------------------------------------------------

  defp unknown_key(key) do
    "There is no terminal theme called \"#{key}\". The keys that exist right now are: " <>
      Enum.join(TerminalTheme.keys(), ", ") <>
      ". Call terminal_theme_list for their labels, or terminal_theme_paint to make one of your own."
  end

  defp missing_key do
    "terminal_theme_select needs a key. Valid keys right now: " <>
      Enum.join(TerminalTheme.keys(), ", ") <> "."
  end

  defp missing_colors do
    ~s|terminal_theme_paint needs a colors map, e.g. {"foreground": "#ff4d1c"}. | <>
      "It may name as few fields as you like — the rest keep their current value. " <>
      "terminal_theme_list reports every field name it accepts."
  end

  # `{:illegible, field, ratio}` is the refusal worth spelling out: the model can
  # fix a named field and cannot fix "invalid".
  defp paint_refusal({:illegible, field, ratio}) do
    "That palette would be hard to read, so it was refused whole: #{field} scores " <>
      "#{format_ratio(ratio)}:1 contrast against the background. Text needs 4.5:1, the cursor " <>
      "2.0:1, and at least 10 of the 16 ANSI colours need 2.0:1 — an agent that can hide its " <>
      "own output is the one thing this refuses. Move #{field} further from the background and " <>
      "paint again."
  end

  defp paint_refusal(:invalid_colors) do
    "Every colour must be a \"#rrggbb\" literal — six hex digits after a #, no names, no " <>
      "shorthand, no rgb(). The whole palette is refused rather than half-applied. " <>
      "terminal_theme_list reports every field name this accepts."
  end

  defp paint_refusal(:invalid_name) do
    "That theme name will not do: it must not be blank and must be 40 characters or fewer."
  end

  defp paint_refusal(reason) when is_atom(reason) do
    "The palette was refused: #{String.replace(Atom.to_string(reason), "_", " ")}."
  end

  defp paint_refusal(reason) when is_binary(reason), do: reason

  defp paint_refusal(_reason) do
    "The palette was refused, and the reason did not survive being reported. " <>
      "Try a smaller change — one field at a time is always accepted or named."
  end

  defp format_ratio(ratio) when is_float(ratio), do: :erlang.float_to_binary(ratio, decimals: 2)
  defp format_ratio(ratio) when is_integer(ratio), do: Integer.to_string(ratio)
  defp format_ratio(ratio), do: to_string(ratio)
end
