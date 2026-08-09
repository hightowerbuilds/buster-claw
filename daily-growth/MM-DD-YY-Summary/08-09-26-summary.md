# 08-09-26 — Three looks for the chat, three for the terminal

Scoped `CHAT_SKINS_ROADMAP.md` and shipped all four phases: the homepage chat now
has three skins — **Industrial Claw** (as it was), **Minimal** (a terminal
transcript), **Workplace** (avatar, author line, hoverable rows) — chosen from a
dropdown in Settings → Appearance, applying the moment you pick it.

`6458a32` the setting and the wire · `a89f6b7` the markup anchors · `064d6b2` the
three skins in CSS · `040d648` the dropdown and the preview. Then a second ask the
same day: **a text size**, four steps from 100% to 150%, as an independent axis.

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

## The text size, and why it is a second axis

Four steps (Normal / Large / Larger / Largest — 100 / 115 / 130 / 150%) in a
`ChatTextSize` module mirroring `ChatSkin`, with its own key, topic and dropdown,
sharing the same preview. **Two axes rather than twelve skins:** wanting larger
text must not cost you the look you chose. They multiply — every font-size in the
chat is `calc(<its own size> * var(--chat-scale, 1))` and the setting supplies the
one number.

`normal` is scale 1 and therefore writes **no CSS at all**, because the `var()`
fallback already means "as designed". Same argument as the empty `industrial`
block, and same payoff: the shipped reading size cannot regress through the
stylesheet.

**The type sizes had to leave the markup.** `text-[17px]` and four siblings *were*
the chat's type scale, and a utility class cannot be multiplied. So they became
`calc()` expressions in `app.css`, which narrows the Phase 2 claim honestly: the
*skin* block is still empty, but the type scale is now shared and lives in CSS. A
test refuses a `text-[17px]` coming back, because a bubble that pinned its own size
would sit still while everything around it grew.

Scaled: the things a reader reads — bodies, tool lines, run notes, composer, empty
state, Workplace's author line. **Not** scaled: buttons, chips, labels. The ask was
readable text, not a magnified UI, and scaling chrome is how an interface starts
clipping.

The one number lives in two places (the module's `scale`, the stylesheet's
`--chat-scale`) and cannot drift: the CSS test reads the scales out of the module
and requires each to appear in `app.css`. A UI promising 130% while CSS applies
1.15 fails the suite.

`status_live.ex` sat one line under its cap and both axes cost it exactly one more,
because `status/chat.ex` absorbed the wiring — `subscribe_chat_look/0`,
`assign_chat_look/1`, and a single `handle_info` clause guarded on
`axis in [:chat_skin, :chat_text_size]`, where the axis name *is* the assign name.
That is the shape the size gate exists to produce rather than to punish.

## The opaque draft, corrected the same day

Both new skins shipped **opaque**, on the reasoning that a vim window should look
like a vim window and a workplace app should feel solid. The operator caught it
within the hour: every panel on the homepage is translucent with a backdrop blur
(`.ic-home .ic-panel`) so the live shader reads through, and a solid chat was the
only solid panel on the page — it read as a bug, not a look.

Both now leave `background` and `backdrop-filter` alone and change only the frame's
geometry: Minimal a hairline square border with no offset shadow, Workplace a
rounded hairline with a diffuse one. Workplace's composer box went from
`base-100` to a 55% tint for the same reason — a solid box inside a blurred panel
is the same mistake one level down.

**The lesson is about which master a skin serves.** "Slack is opaque" and "vim is
opaque" are both true and both irrelevant: a skin lives inside *this* app's surface
treatment, and matching the reference beat matching ourselves. The roadmap had even
licensed it — it said translucency was "each skin's call" — so the document was
wrong before the CSS was, and it now says the opposite with the reason attached.

## The gap under Theme, and a grid trap

Chat theme shipped full-width below everything, which left an empty half-column
under **Theme** while the terminal palette filled the right side. Moved into that
gap, and compacted for it: the two dropdowns share a row, the copy is one line
each, the preview takes the width it is given (a transcript is narrow anyway).

**The obvious move is wrong.** Making Chat theme a third child of the two-column
grid puts it in column 1 **row 2** — below the tall terminal column's baseline —
so the gap survives while the markup looks correct. The left cell has to become a
stack containing both panels. A test asserts document order (chat heading before
"Terminal theme") precisely because that is the mistake a future refactor would
make while looking right.

## Cuts, taken as decisions

- **No smaller sizes.** Nobody asked to shrink the chat, and Minimal already runs
  the tightest type in the app. A "Small" step is one line if it is ever wanted.
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


---

# Terminal themes — one list, three presets, and a palette of your own

`TERMINAL_THEME_ROADMAP.md`, all three phases (`d0d1363` + the editor). The ask was
a UI for custom colours and then a cull to Industrial / Nord / Monokai.

## Two things that were not what they looked like

**A theme is 21 colours, not three.** The picker's swatch shows background,
foreground and accent, which is why this reads as a simple feature. An xterm palette
is five core values plus **8 ANSI colours and 8 bright variants** — and those 16 are
what colour `ls` and `git status`.

**The list already existed twice.** The palettes were in `assets/js/lib/theme.js`;
a second, partial copy (key, label, three swatch colours) was in `AppearanceLive`,
kept in step by a **comment** and nothing else, with **no test touching terminal
themes at all**. Which makes the cull precisely the shape this repo keeps getting
bitten by: delete from one language and the suite stays green either way, leaving
either a dead palette or a swatch that selects a theme which no longer exists and
silently renders the default.

So the cull came *second*. `BusterClaw.TerminalTheme` owns the list, `theme.js`
applies it, the payload arrives as `<meta name="bc-term-palettes">` — in the head
rather than on the picker, because a terminal can mount on a page that has no
picker. A `<meta>` rather than a JSON `<script>` block because the CSP here is
`script-src 'self'` with nothing inline: a data block is not executed and so not
actually blocked, but the repo deliberately removed its last inline script to drop
the nonce, and re-adding a tag that merely *looks* like a violation buys nothing.

**Industrial stays a `null` palette, meaning token-derived.** It is resolved in the
browser from `--color-base-*` and `--color-primary`, which is what makes it the only
theme that follows the app's light/dark switch. Elixir cannot read computed CSS, so
it declares the fact and leaves the resolving where it has to happen. Flattening
every theme into fixed hex would have killed that on the **default** theme — the
kind of regression nobody files, they just notice the terminal stopped matching the
app.

## The custom theme is a copy, and that is the design

The editor opens on **"Start from Nord / Monokai"**, which copies that palette whole.
Two things follow, and they are the point:

- The palette is **always complete**, so a custom theme can never be the
  half-applied thing where the background is yours and `ls` is xterm's.
- The common case is **one edit** — "Nord but a black background" — not a
  twenty-one-field form.

**Industrial is not offered as a starting point**, because it has nothing fixed to
copy. Offering it would either snapshot whichever app theme happened to be on, or
produce a palette missing its ANSI values.

## A test caught a field that could never have worked

`selectionForeground` was in my field list and in **neither surviving preset** — so
a copy was a 20-colour palette against a validator demanding 21, and *no custom
theme could ever have been saved*. Cut, with the better reason on top: unset, xterm
leaves selected text in its own colour, so a selected error line stays red. Adding
it later means adding it to both presets at once, which is a visible change to them
and therefore a decision rather than a fill-in.

## Live apply without a new mechanism

The `<meta>` is server-rendered and cannot change without a reload, so an edit
reaches the browser as a `push_event` that patches the cached table and restyles
every terminal on the page. The browser then mirrors the palette into
`localStorage`, where the **existing** `storage` listener carries it to other
windows. `Settings` is the durable store; `localStorage` is only the cross-window
nudge, which is why load time trusts the `<meta>` and not it. No terminal-hosting
LiveView had to subscribe to anything.

## Refusals, and one form

Every colour is validated as `#rrggbb` and normalized — these strings go to xterm
*and* into the swatch's `style` attribute, so an unvalidated one is a markup
question rather than a styling one. A **partial** palette is refused rather than
merged: the editor always holds a complete one, so a partial save means a form that
lost inputs, and merging would accept it silently. A stored palette that has gone
bad resolves to **no custom theme** rather than a partly applied one.

The editor is **one form** carrying the whole palette, so the params *are* the
palette and there is no per-field event to keep in step with the field list. The hex
is shown rather than typed: a second text input sharing a field's `name` would put
two values on the wire for one field.

## The cull

Industrial, Nord, Monokai survive. Dracula, Solarized, Gruvbox, Tokyo Night, Light
and Matrix are gone from **both** languages, asserted in both. `currentTermTheme()`
now resolves a stored key against the themes that exist, so whoever had picked
Dracula lands on the default *with the swatch highlighted* rather than on a legible
terminal with nothing selected — which would have read as the setting being lost
rather than retired. Losing `light` costs nothing: Industrial already tracks the
app's light theme, which a fixed palette cannot.

`appearance_live.ex` enters the file-size inventory at 1,010 with the cut named (the
terminal-theme block is a coherent component; so is the background catalog).
