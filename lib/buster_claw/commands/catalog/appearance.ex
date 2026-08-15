defmodule BusterClaw.Commands.Catalog.Appearance do
  @moduledoc """
  Catalog entries for the two surfaces that have a background — the terminal and
  the homepage (DMG review B1).

  **Two verbs.** `background_list` says what exists and what each surface is
  showing, `background_set` points one surface at one option. There is no upload
  verb, no delete verb, no palette verb and no per-surface family: the image pool
  is filled in Settings by the operator, and the surface is an *argument* because
  `Appearance` is written against a surface table rather than per-surface.

  ## What this changes about `Appearance` having no commands, and what it does not

  `Catalog.TerminalTheme`'s moduledoc says `Appearance` has no commands at all,
  because only a human click may put user-authored GPU code on a screen. B1 asked
  for exactly one half of that back, and the half it asked for is **selection**:
  `background_set` chooses among `Appearance.options/0`, which is `off`, the
  bundled shaders, the `shaders/*.wgsl` the operator wrote, and the images the
  operator uploaded. The rule that stands is the other half — **no command
  authors a shader or adds an image**, at any tier. An agent picking one of the
  operator's own designs is a different act from an agent writing WGSL and
  running it, and it is the second one that D1 was about.

  ## Why the write is `:restricted` and not gated

  `:restricted`, because it changes what the operator is looking at without
  asking, and `:safe` would let any MCP/agent token repaint the machine — the
  same line `terminal_theme_select` sits on.

  **Not gated**, and the argument is the shape of the act rather than its
  loudness. Compare the two entries that *are* gated: `sound_apply` changes what
  the machine does when nobody is watching, and `sound_record` opens the
  microphone. A background is neither. It writes one `Settings` key, touches no
  file, sends nothing outbound, is visible the instant it happens, and is undone
  by one more call or one click in Settings. A confirmation dialog for it would
  be theatre, and gating an act whose whole failure mode is "the operator sees
  something they did not pick" trains the operator to click through gates that
  matter.

  The containment that makes that defensible is the reach, not a policy check:
  the set of backgrounds this verb can select is exactly the set the operator
  already put on their own machine. The worst an unattended run can do with it is
  show them one of their own images.

  ## Why the read is `:safe`

  It reports the option keys and labels already rendered into the operator's own
  Settings page, plus which mode each surface resolves to. No secret, no path
  outside the served image URLs the webview already fetches, nothing written and
  nothing applied. The verb that CHANGES what the operator sees is `_set`, and it
  is deliberately absent from the safe tier.
  """

  @doc "Background catalog entries."
  def entries,
    do: [
      %{
        name: "background_list",
        type: :read,
        tier: :safe,
        description:
          "Every background the terminal and the homepage can show, and what each is showing right now. `options` is the shared catalog both surfaces draw from: `off`, the bundled shader designs, any shaders the operator wrote into their workspace, and the image pool — each with a `filled` flag, because an EMPTY image slot is listed (the picker shows it as a placeholder) and is never a valid target. `surfaces` reports each surface's RESOLVED mode, kind (none / shader / image / image_shader), shader, slot and image URL — resolved, not stored, so a mode whose shader file was deleted or whose image slot was cleared reports the default it degrades to rather than a value that would render nothing. `image_shaders` is the exact set of shader names that may be laid OVER an image in the `image:<slot>+<shader>` form; any other shader is refused for that form. Unlike terminal_theme_list, current state is reported and can be: a background lives on the server, not in the operator's browser.",
        args: %{}
      },
      %{
        name: "background_set",
        type: :mutate,
        tier: :restricted,
        description:
          "Point one surface at one background, live — every open terminal and the homepage re-render immediately, no reload and no click. `surface` is `terminal` or `home`. `mode` is one of: `off`; a shader name from background_list; `image:<slot>` for an uploaded image; or `image:<slot>+<shader>` for an image with an image-reactive shader over it. Refusals are specific and correctable: an empty slot names the slots that DO hold an image, a shader that would not react to the image names the ones that would, and an unrecognised mode restates the grammar and lists the keys that exist. You cannot upload an image or write a shader from any command — this chooses among what the operator already put on their machine, so if what you want is not in background_list, ask them for it. This changes what the operator is looking at, so say what you are doing and why.",
        args: %{
          "surface" => %{
            type: :string,
            required: true,
            description:
              "Which surface to change: terminal (the in-app terminal) or home (the homepage chat). One surface at a time; the same option may back both."
          },
          "mode" => %{
            type: :string,
            required: true,
            description:
              "off, a shader name, image:<slot>, or image:<slot>+<shader>. Keys come from background_list's `options`; overlay shader names come from its `image_shaders`."
          }
        }
      }
    ]
end
