# Chat skins — three looks for the homepage chat, switched from Settings

**Scoped 08-08-26 · Status: Phases 0–3 SHIPPED 08-09. Only the acceptance walk
is left, and it needs the operator.**

| Phase | State |
|---|---|
| 0 — The setting, and the wire that carries it | **DONE** (`6458a32`) |
| 1 — Give the markup something to grab | **DONE** (`a89f6b7`) |
| 2 — The three skins, in CSS | **DONE** (`064d6b2`) |
| 3 — The dropdown, and a preview that proves it | **DONE** |
| 4 — What we are not building yet | Decided below, not deferred silently |
| 5 — Text size, a second axis | **DONE 08-09** (operator ask, added after Phase 3) |

**What changed from the plan, and why.** Three things, all recorded where they
happened:

1. The preview does **not** need `chat_bubble/1` promoted to public. Putting
   `transcript_preview/1` inside `ChatPanel` lets it call the private bubble
   directly, so the API never widened. Better than the plan.
2. The Settings key is `chat_skin`, not `chat.skin` — every other key in the
   store is flat snake_case and one dotted key would have been the odd one out.
3. The reason skin CSS beats the markup's utilities is **not** specificity, which
   is what this document originally claimed. Hand-written rules in `app.css` are
   *unlayered* and Tailwind's utilities live in `@layer utilities`; unlayered
   wins outright, whatever the specificity. Verified against the built
   stylesheet. Specificity still decides against the other unlayered `.ic-*`
   rules, which is why beating `.ic-home .ic-panel` takes three selectors.

**Three defects were found by writing Phase 2**, all the same shape — a rule
correct for the *look* and wrong for the *panel*: `gap: 0` on every role would
have crushed the tool line's icon against its text; Workplace's avatar-less rows
would not have lined up with the rows that have one; and zeroing the textarea's
border silently removed the **focus indicator** in both new skins, because
`focus:border-primary` cannot colour a 0-width border. That last one is the one
worth remembering: a skin can delete an accessibility affordance while looking
finished, and nothing in the suite would have said so.

**The ask (operator, 08-08):** the homepage chat harness gets three looks —
**minimalist** (vim / pi-agent), **Slack**, and **what it is now** — chosen from a
dropdown in Settings, with the change visible immediately.

---

## The one finding that shapes everything

The transcript is a **LiveView stream** (`phx-update="stream"` on
`#agent-chat-log`, `lib/buster_claw_web/components/chat_panel.ex:178`). Stream
children are rendered once, on insert. When the parent re-renders with a new
assign, LiveView sends no stream ops, so **every message already on screen keeps
the DOM and the classes it was born with.**

So the obvious implementation — branch the bubble's class list on the current skin
— produces the worst possible bug: you switch skins, the composer and header
change, and the ten messages above them stay in the old look until you reload or
say something new. Half-skinned. It would demo fine on an empty chat and fail on
every real one.

There are only two ways out:

1. **Re-stream the transcript on every switch** (`stream(..., reset: true)`). The
   socket does not keep the message list — it is stream-only, capped by
   `limit: -@max_chat_messages` — so this means introducing a parallel list
   assign that duplicates the stream and has to be kept in step with it forever.
   Rejected.
2. **Make the skin a CSS-only concern.** The skin changes one attribute on an
   ancestor; every visual difference is a descendant rule. Existing DOM restyles
   instantly, with zero churn and zero server round-trip for the nodes.

**Decision: (2).** Which yields the contract this whole map hangs from:

> ### The rendered DOM is identical under all three skins.
>
> The only difference the server emits is `data-chat-skin` on the panel's root
> `<section>`. An element one skin needs — Slack's author line, the vim
> prompt-glyph — is rendered by **every** skin and hidden by CSS in the others.

That is not a style preference, it is what keeps the feature from being
half-applied. And it is cheaply testable: render the panel three times, assert
the HTML is byte-identical once the attribute is normalized away. A future
`if @skin == "slack"` in the template fails that test on the spot.

---

## Naming, before it collides

The app already has a `data-theme` — daisyUI's, values `dark` and `light`, owned
by the whole window. This is a different axis and must not be called a theme in
code. The setting is a **skin**: `data-chat-skin`, values `industrial`, `minimal`,
`slack`. The dropdown may say "Chat theme" to the operator; nothing in the source
should.

**Both axes multiply.** Three skins × dark/light = **six** combinations that have
to be legible, and each skin also sits over a live WGSL shader background on the
homepage (`.ic-home .ic-panel` makes panels 70% opaque with a backdrop blur,
`assets/css/app.css:511`). Every colour a skin sets goes through daisyUI tokens
(`--color-base-*`, `--color-primary`) rather than a hex literal, or it will look
right in dark and be unreadable in light.

**No skin overrides the panel's translucency.** This document originally said the
opposite — that it was each skin's call — and both new skins shipped opaque on
08-09 before the operator corrected it the same day. The translucent blurred panel
is the *app's* surface treatment, shared by every tab on the homepage; a chat that
went solid was the only opaque panel on the page, and it read as a bug rather than
as a look. A skin may change the frame's geometry (border weight, radius, shadow)
and must leave `background` and `backdrop-filter` to `.ic-home .ic-panel`. The
general lesson: **matching the reference app beat matching our own app**, and the
reference was the wrong master.

---

## Phase 0 — The setting, and the wire that carries it

A new `BusterClaw.ChatSkin` module is the single source of truth: the three keys,
their operator-facing labels and one-line descriptions, the default, the
validator, the getter, the setter, and a PubSub topic. Everything else reads from
it — the dropdown's options, the panel's attribute whitelist, the tests. Adding a
fourth skin should be one entry here plus one CSS block.

Storage is `Settings.get/put` under `chat.skin` (strings, already the house
mechanism). The live-update path is the one Appearance already proved: set →
broadcast on the topic → `StatusLive` `handle_info` re-assigns → re-render
(`lib/buster_claw_web/live/status_live.ex:68` subscribes, `:613` handles the
background's equivalent message). Copy that shape exactly; do not invent a second
one.

An unknown or missing value resolves to `industrial`. A skin that fails to
resolve must never render an unstyled panel.

**Watch the file-size gate.** `status_live.ex` is at 931 lines against a **945**
cap held in `scripts/check_file_sizes.sh:117`. The subscribe line, the
`handle_info`, and the assign are about a dozen lines — enough to trip it. Put
the handler in `BusterClawWeb.Status.Chat` where the rest of the chat's socket
work already lives, rather than raising a cap that was set deliberately.

**Done when:** the setting round-trips, an invalid value resolves to the default,
setting it broadcasts, and an open homepage receives the broadcast and re-renders
with the new attribute — asserted in a LiveView test, not by eye.

---

## Phase 1 — Give the markup something to grab

No CSS, no visual change, no dropdown. This phase only adds the handles the next
one needs, so the risky commit and the boring commit are not the same commit.

Every part of the panel a skin needs to address gets a stable `data-` anchor —
the log, each bubble by role, the author line, the header, the composer, the
delivery chips. The bubbles already carry ad-hoc anchors for other reasons
(`data-delivery-chip`, `data-attach-image`); this extends the habit rather than
starting it. Class lists stay exactly as they are: `industrial` is the current
look, and the way to guarantee it did not shift is to not touch it.

The two elements no skin renders today but one skin needs — Slack's author name
and the vim prompt glyph — are added here, unstyled and invisible, because the
DOM-is-identical contract says they must exist in all three. They are `::before`
candidates instead if that turns out cleaner; the point is that the decision
lands in Phase 1, once, and not per-skin.

**Done when:** `mix test` is green with no snapshot churn beyond the new
attributes, and the homepage looks pixel-identical to `main`.

---

## Phase 2 — The three skins, in CSS

One block per skin in `assets/css/app.css`, under a section banner, next to the
existing `.ic-*` surface rules. (A separate `chat_skins.css` is tempting for
discoverability but `@import` ordering against the Tailwind and daisyUI plugin
blocks is a build risk for no functional gain. If the block passes ~250 lines,
revisit.)

**`industrial` — what it is now.** Deliberately *empty*: the baseline is the
Tailwind utilities already in the markup. An empty block is the proof that the
default path cannot regress, since there is nothing in it to be wrong. The two
elements Phase 1 added are hidden here.

**`minimal` — vim / pi-agent.** A terminal transcript, not a chat app. No
bubbles, no borders, no bubble backgrounds; IBM Plex Mono throughout at a tighter
line height; roles distinguished by a prompt glyph and dimming rather than colour
and alignment; everything left-aligned in one column, including the user, because
right-alignment is the bubble idiom this skin is rejecting. The composer loses its
box and becomes a prompt line. Hazard orange survives as the single accent — this
is still Industrial Claw, not a beige reskin.

**`slack` — the workplace look.** Both roles left-aligned as rows: author line
above, message body below, generous row padding, a hover tint on the row, sans
throughout (IBM Plex Sans is already loaded), rounded corners, a bordered
composer box with the send control inside it. **Its translucency stays** (see
above): the composer box itself is tinted rather than solid, so it still reads as a
box without becoming the one opaque thing in a blurred panel.

Two things this phase must not do: introduce a hex colour (tokens only, or light
mode breaks), or hide a control. A skin may restyle **Stop**, **Steer now** and
the attach affordance; a skin that makes any of them invisible is a bug, and that
deserves its own assertion.

**Done when:** each skin is asserted to produce a non-empty rule set and the
DOM-identity test from the contract passes. The visual judgement itself is
eyeball work and belongs to Phase 3's preview.

---

## Phase 3 — The dropdown, and a preview that proves it

**Where it goes: Settings → Appearance** (`/appearance`). It is the settings tab
that already owns how the app looks, already owns per-surface visual choices, and
already has the broadcast-and-re-render plumbing this reuses. Configuration
(`/settings`) is the credentials-and-backends tab; a look-and-feel dropdown there
would be the odd one out. If the operator wants it on Configuration instead it is
a one-line move of the component call.

The control is a `<select>` on `phx-change`, options from `ChatSkin`, each with
its one-line description, persisting on change with no Save button — matching
Appearance's existing click-to-apply behaviour.

**The preview is the load-bearing half of this phase.** "See the change
immediately" cannot mean the homepage, because you are on the Settings page and
cannot see it. So Appearance renders a **live transcript preview**: a
`data-chat-skin` wrapper around four canned messages — user, assistant, tool,
meta — that restyles the instant the dropdown changes.

It must render the **real** bubble markup, not a facsimile. A second copy of the
bubble HTML in a preview would drift from the real one within a month, and the
drift would be invisible precisely because the preview is where you go to check.
That means promoting `chat_bubble/1` from private to public with a docstring
saying why.

The preview shows the **transcript only, not the composer**, and says so in one
line of copy. The composer is a `<form>` carrying `phx-hook="Composer"`,
`phx-submit="chat_send"` and hard-coded DOM ids; mounting it on Appearance means
live hooks with no LiveView behind them and a submit that would crash the page.
Not worth it — and the honest label costs one sentence.

Meanwhile the homepage does update live for real, via Phase 0's broadcast. Both
paths, one setting.

**Done when:** changing the dropdown persists the setting, updates the preview in
the same commit-free round-trip, and an already-open homepage restyles without a
reload — all three asserted.

---

## Phase 4 — What we are not building yet, and why

Written down so these come back as choices rather than as things that were
quietly dropped.

- **Timestamps.** The Slack look wants a clock on every row and **there is no
  timestamp to show.** The message map is `{id, role, text, svg_ids, delivery,
  scenes, attachments}` (`lib/buster_claw_web/live/status/chat.ex:387`) — no
  `at`. Adding one to `push_msg/7` is easy for new messages, but the
  transcript-reload path rebuilds history from stored rows (`:481`, `:539`), so
  either old messages get a blank column or we invent a time for them. Inventing
  one is out. **Cut from V1; Slack rows carry no clock.** Revisit as its own
  small change that starts by checking whether the stored rows have a usable
  stamp.
- **Avatars.** Slack's identity block is an initialled colour square drawn in
  CSS, not a picture. There is no operator avatar in the app and no reason to add
  a file-upload path for one here.
- **Skinning the terminal or any other surface.** There is exactly one chat
  transcript in the app — `chat_panel` has a single call site
  (`status_live.ex:863`) — which is what makes this map small. Keep it that way;
  a per-surface skin matrix is a different project with a different reason to
  exist.
- **Operator-authored skins.** A user-supplied CSS file would be arbitrary CSS
  injected into the app shell, which is a security question, not a styling one.
  The three skins ship as source. Note the shape of the precedent already set
  next door: `Appearance` accepts arbitrary user `.wgsl` but has **no commands
  at all**, because only a human click may ever put user-authored GPU code on
  screen. A CSS-skin feature would owe the same argument before it ships.

---

---

## Phase 5 — Text size, a second axis

**Asked for 08-09, after Phase 3 shipped: "allow users to make the font bigger in
the chat."** `BusterClaw.ChatTextSize` mirrors `ChatSkin` exactly — four steps
(Normal / Large / Larger / Largest, 100 / 115 / 130 / 150%), own `Settings` key,
own topic, own dropdown in the same Appearance section, same preview.

**Two axes, not twelve skins.** Wanting larger text must not cost you the look you
chose, so size is independent and the two multiply: every font-size in the chat is
written `calc(<its own size> * var(--chat-scale, 1))` and the setting supplies the
one number. `normal` is scale 1 and therefore writes **no CSS at all** — the
`var()` fallback already means "as designed", which is the same argument as the
empty `industrial` block, and it means the shipped reading size cannot regress
through the stylesheet.

**The type sizes had to leave the markup.** `text-[17px]` and four other Tailwind
literals were the chat's type scale, and a utility class cannot be multiplied. So
they moved into `app.css` as `calc()` expressions. This is a real narrowing of the
Phase 2 claim that "Industrial is the utilities in the markup" — the *skin* block
is still empty, but the type scale is now shared and lives in CSS. `ChatPanelTest`
refuses a `text-[17px]` coming back, because a bubble that pinned its own size
would sit still while everything around it grew.

**Scaled: the things a reader reads** — message bodies, the tool line, the run
notes, the composer, the empty state, and Workplace's author line. **Not scaled:
buttons, chips, labels.** The ask is more readable text, not a magnified UI, and
scaling chrome is how an interface starts clipping.

**The one number lives in two places** — `ChatTextSize`'s `scale` (which the
dropdown's percentage is computed from) and the stylesheet. They cannot drift: the
CSS test reads the scales out of the module and requires each to appear in
`app.css`, so a UI promising 130% and CSS applying 1.15 fails the suite.

**`status_live.ex` did not grow.** It was one line under its cap, and both axes
cost it exactly one more, because `status/chat.ex` absorbed the wiring:
`subscribe_chat_look/0`, `assign_chat_look/1`, and a single `handle_info` clause
guarded on `axis in [:chat_skin, :chat_text_size]` — the axis name *is* the assign
name, which is why one clause serves both and why an unknown broadcast cannot
write an arbitrary assign.

**Layout, 08-09:** the section is **not** full-width. It sits in the left cell of
the Theme / Terminal-theme grid, stacked under Theme, filling a half-column that
was empty because the terminal palette is tall. Worth knowing before rearranging
it: making it a *third grid child* puts it in column 1 **row 2**, below the
terminal column's baseline, so the gap survives and the markup looks fine. The
left cell must be a stack. A test asserts document order for exactly that reason.

**Only enlargement is offered.** Nobody asked to make the chat smaller and Minimal
already runs the tightest type in the app; a "Small" step is a one-line addition
if it is ever wanted.

---

## Acceptance, end to end

The walk a person does once, in a packaged build, and which no test replaces:
open Settings → Appearance, change the dropdown three times and watch the
preview; go to the homepage with a conversation already on screen and confirm
**old messages** restyle, not just new ones; toggle dark/light against each skin;
send a message, start a run, and confirm **Stop**, **Steer now** and attach are
all reachable in all three. That is six skin/theme combinations and four
controls, and it is the one thing here that needs the operator rather than CI —
same bucket as LAUNCH **G-40**.

**Phase 5 adds one thing to that walk that is worth doing deliberately:** set the
text to **Largest** and check the chat still *fits* — a long message at 150%, the
composer with two lines in it, and the queue rail open. Type scales and the panel
does not, which is the intended trade, and the place it could go wrong is
wrapping and overflow rather than colour.
