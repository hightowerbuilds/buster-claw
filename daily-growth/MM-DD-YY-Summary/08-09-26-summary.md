# 08-09-26 — Three looks for the chat, and the stream that decided how

Scoped `CHAT_SKINS_ROADMAP.md` and shipped all four phases: the homepage chat now
has three skins — **Industrial Claw** (as it was), **Minimal** (a terminal
transcript), **Workplace** (avatar, author line, hoverable rows) — chosen from a
dropdown in Settings → Appearance, applying the moment you pick it.

`6458a32` the setting and the wire · `a89f6b7` the markup anchors · `064d6b2` the
three skins in CSS · `040d648` the dropdown and the preview.

## The finding that wrote the design

The obvious build is to branch the bubble's class list on the current skin. It
produces the worst available bug, and only on a chat that already has messages in
it.

The transcript is a **LiveView stream**. Stream children are rendered once, on
insert; a later parent re-render sends no stream ops, so a message already on
screen keeps the DOM and the classes it was born with. Switch skins and the
header and composer change while the ten messages above them stay in the old
look, until a reload. **It would have demoed perfectly on an empty chat.**

The only other way out was to re-stream on every switch, which needs a list
assign duplicating a stream that is deliberately capped and stream-only. So:

> The rendered DOM is identical under all three skins. The server varies exactly
> one thing — `data-chat-skin` on the panel's root section — and every visual
> difference is a CSS descendant rule.

That is not a style preference. It is what keeps the feature from being
half-applied, and it is cheap to assert: render the panel three times, normalize
the attribute away, demand byte equality. A future `if @skin == "slack"` in the
template fails on the spot. An element one skin needs is rendered by all three and
hidden in the others.

## Why it works without a single !important

The document originally justified this by specificity — two-selector rules beating
single-class utilities. That reasoning is true but not the mechanism. Hand-written
rules in `app.css` are **unlayered**; Tailwind's utilities live in
`@layer utilities`; unlayered CSS beats layered CSS outright, whatever the
specificity. Checked against the built `priv/static/assets/css/app.css` rather
than asserted, and the roadmap was corrected. Specificity still decides against
the *other* unlayered `.ic-*` rules in the file, which is why beating
`.ic-home .ic-panel` takes three selectors.

## Content in the DOM, decoration in CSS

Two elements no skin renders today but one skin needs had to land somewhere, and
they split on a rule worth keeping:

- **The author name is content**, so it is a real `sr-only` span. Consequence
  nobody asked for and everybody gets: it is announced by a screen reader in
  **every** skin, where alignment and colour never were. It also survives
  copy-paste.
- **Minimal's `>` sigil is decoration**, so it is a `::before` and appears nowhere
  in the markup. A screen reader should not read a glyph aloud, and it should not
  land in copied text.

`sr-only` being `position: absolute` is also why adding the author line moved
nothing: out of flow, so the parent's `gap` never saw it.

## Three defects, all the same shape

Every one was a rule that was correct for the *look* and wrong for the *panel*:

1. `gap: 0` on every `[data-chat-role]` would have crushed the tool line's icon
   against its text — that row is a flex row, not a stack.
2. Workplace's avatar-less rows (tool, meta, error) would not have lined up with
   the rows that have one, because the log gave up its horizontal padding so each
   row could own it.
3. Zeroing the textarea's border **silently removed the focus indicator** in both
   new skins: `focus:border-primary` cannot colour a 0-width border. Minimal now
   focuses a left prompt bar, Workplace focuses the box.

The third is the one to remember. **A skin can delete an accessibility affordance
while looking finished**, and nothing in the suite would have said so. Which is
why the CSS gate now also asserts no skin sets `display: none` on anything — a
control may be restyled, never removed.

## A stylesheet nothing had ever asserted

`ChatSkinCssTest` reads `app.css` and holds five things: every non-default skin
has rules; **the default skin has none** (its baseline is the utilities in the
markup, so an empty block is proof it cannot regress through this file); no hex
literals, because three skins against dark and light is six combinations and a
literal can only be right in one; no `display: none`; and every `data-chat-*`
selector in the stylesheet exists in `ChatPanel`, so no rule is dead. Its pair in
`ChatPanelTest` names the anchors from the other side.

## The preview is the feature, not a garnish

"See it immediately" cannot mean the homepage — the operator is on the settings
page. So Appearance renders a live transcript preview that restyles in the same
round-trip, and it renders the **same private `chat_bubble/1`** the live chat
does, in the same container (extracted to `log_class/0`). A second copy of the
bubble markup would drift within a month, and this is the single surface where a
drift would go unnoticed, because it is where you go to check.

It did **not** need the public bubble API the roadmap assumed: putting
`transcript_preview/1` inside `ChatPanel` lets it call the private clause
directly.

Two omissions are stated in the UI rather than implied — the composer is not
previewed (a form with live hooks and a `chat_send` submit that would crash the
page), and neither is the panel chrome (those rules describe a panel over the
homepage's shader, which no settings page has). Both are real gaps, and an
unlabelled preview is exactly the quiet promise this app keeps having to un-learn.

## Cuts, taken as decisions

- **No timestamps.** Workplace wants a clock and there is none to show: the
  message map has no `at`, and history is rebuilt from stored rows, so old
  messages would get a blank column or an invented time. Cut, with the revisit
  starting from "do the stored rows have a usable stamp."
- **No avatars from real identity** — Workplace's is a coloured square in CSS.
- **No other surface.** `chat_panel` has one call site, which is what kept this
  small.
- **No operator-authored skins.** That is arbitrary CSS in the app shell — a
  security question, not a styling one. Note the precedent next door: Appearance
  accepts arbitrary user `.wgsl` and has **no commands at all**, because only a
  human click may put user GPU code on screen. A CSS-skin feature owes the same
  argument first.

## Housekeeping

`chat_panel.ex` crossed 1,000 lines and entered the file-size inventory at
**1,020** — the first number anyone has put on it, set where the skins left it,
with the next cut named in the same comment (the bubble family is a coherent
module hiding inside a panel module). The acceptance walk went to `LAUNCH_ROADMAP`
**G-40**, since it is a build and a person looking: six skin/theme combinations,
four controls, and the one claim CI cannot make — whether it reads well.

Also worth recording: another session held `pockets.ex` in a warning state and ran
the suite concurrently for much of the afternoon. `MIX_TEST_PARTITION=skins` gave
this work its own SQLite lane, which is the difference between "30 failures" and
"Database busy."
