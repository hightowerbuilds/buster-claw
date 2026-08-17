#!/usr/bin/env bash
# File-size gate — the thing that makes regrowth visible.
#
# This repo has decomposed large files three times and been undone twice,
# because nothing asserted the result:
#
#   * CODE_QUALITY_REFACTOR_ROADMAP took `mix xref` cycles 6 -> 2; a third
#     appeared within a day and went unnoticed. That is why check_cycles.sh
#     now names its accepted cycles instead of counting them.
#   * TradingLive was cut 3,503 -> 1,900 (-46%) and had grown back to 2,174 by
#     the time the file was deleted. The extraction held; the file still regrew.
#   * MODULARIZATION_ROADMAP recorded status_live.ex at 1,460 lines on 08-08 and
#     measured 1,526 the same week.
#
# So the lesson is a rate, not a job, and this is the part that holds it.
#
# Modelled on check_cycles.sh deliberately: it asserts a NAMED INVENTORY WITH
# REASONS, not a global rule, and it fails in BOTH directions. A file over its
# cap fails. A file far under its cap also fails, so the number gets ratcheted
# in the same commit that earns it rather than drifting into meaninglessness.
#
# Two tiers, because "do not grow" and "do not grow, and you owe a cut" are
# different promises:
#
#   HELD   — decomposed, in a shape the roadmap signed off. Capped at roughly
#            +10% of the post-split size: ordinary maintenance is fine, a new
#            feature landing whole in one of these is not.
#
#   FROZEN — a target of an unstarted roadmap phase. Capped at TODAY'S size with
#            no headroom, because these are already too big. They may shrink
#            (which trips the ratchet, which is the point) but never grow.
#
# Adding a file here is cheap and is the right instinct. Removing one requires
# saying why in the same commit.
set -euo pipefail
cd "$(dirname "$0")/.."

# A file this far under its cap means the cap is stale. 0.8 rather than 1.0 so
# ordinary deletions do not nag; a real extraction always clears it.
RATCHET_RATIO=80

fail=0
over=""
under=""

check() { # path cap tier
  local path="$1" cap="$2" tier="$3" lines
  if [ ! -f "$path" ]; then
    echo "FAIL: ${path} is capped here but does not exist."
    echo "      If it was deleted or renamed, update this script in the same commit."
    fail=1
    return
  fi
  lines=$(wc -l < "$path" | tr -d ' ')
  if [ "$lines" -gt "$cap" ]; then
    over="${over}  ${path}: ${lines} lines, cap ${cap} (${tier})\n"
    fail=1
  elif [ "$((lines * 100))" -lt "$((cap * RATCHET_RATIO))" ]; then
    under="${under}  ${path}: ${lines} lines, cap ${cap} — lower it to $(( (lines * 110 + 99) / 100 ))\n"
    fail=1
  fi
}

# --- HELD: decomposed 08-08-26, MODULARIZATION_ROADMAP Phases 1 and 2 --------

# The Explained tab: a rail and a dispatch, one module per tutorial.
#
# Caps raised 08-08 for the demo contract: every worked example on these pages
# now carries four required fact attrs (prerequisites, side effects, where the
# stop is, expected result + failure state), which is roughly +5 lines per
# example and is the whole point of that commit. The two new tutorials are
# capped at their as-written size — they are content files with one function
# each, so the honest cap is "don't grow", not "don't exceed a split target".
#
# `ramshackle.ex` (08-09) is the widest tutorial in the rail and is capped on
# arrival at its as-written size. The reason it is bigger than `phone.ex` is not
# sprawl: it is the only tutorial whose subject has NO surface to point at, so
# where the others can say "click this and look", it has to carry the whole
# mechanism as prose — five worked cycles, the six selector weights, and the
# three splice constants. If it ever grows, the seam is the mechanism sections
# (pipeline, origins, lattice, numbers), which are self-contained and would
# extract as a sibling cleanly; the five `.example` cycles would not.
#
# It was `voice.ex` for part of that day, one tab covering both the cut-up and
# the chime surface. Splitting it into `studio.ex` + `ramshackle.ex` did NOT
# shrink it — the cut-up content was always the whole file, and `studio.ex` is
# new writing rather than an extraction. Recorded here because the pair of caps
# below otherwise reads like a decomposition, and it was not one.
#
# `studio.ex` is the other half of that split and capped on arrival: the library,
# the routing table, the four editing verbs, and the one gated `sound_apply`.
#
# `cmd_table.ex` (08-09) renders the whole catalog inside the Command List
# tutorial, because the two links that used to say "the live, complete list is
# there" both pointed at `/cmd-list` — which is the terminal CHEATSHEET editor,
# not the command catalog. Operator called it. It is capped on arrival and is a
# sibling rather than part of `cmd.ex` for the ordinary reason: that file was at
# 411 against a 430 cap and this is 203 lines. Note it is GENERATED from
# `Commands.list_commands/0`, so unlike the tutorials it does not grow when the
# surface does — 203 commands and 33 groups render from the same markup as 300
# would. Growth here means new markup, and should be questioned.
#
# `explained_panel.ex` 104 -> 105 for the eighth tutorial. One line, and worth
# naming because two Studio modules cite this file BY NAME as the minimal
# example ("the rail and the dispatch, and nothing else"). It still is: the line
# is a dispatch line. If a raise here ever buys anything other than an import or
# a `:if`, that citation is what it is spending.
#
# 105 -> 113, and by that rule this raise IS spending the citation, so it says
# what it bought. The rail moved to a sidebar and the CRT chrome moved with it,
# off the tutorial pane, which is long-form reading and was being overlaid with
# scanlines. That needed one non-scrolling wrapper: `.ic-scanlines::after` is
# `absolute; inset: 0`, so on the scrolling rail it sizes to the visible box and
# then scrolls away, baring the bottom of a scrolled rail. Two of the eight added
# lines are that wrapper; the other six are the two comments explaining it and
# the left-edge marker, both of which are CSS traps a later reader would
# otherwise "tidy" straight back into a bug. Structure is still rail + dispatch.
#
# `registry.ex` 172 -> 190 -> 210 -> 219 across the same day: a feature entry per
# tab, each a long `body`, plus the comment explaining the one entry whose `path`
# points at the command list rather than at the tab it describes.
#
# The last nine bought a REORDER, not content. The operator moved the two
# outbound site tabs to the bottom of the rail, which meant they could no longer
# be a literal spliced in front of `@features` — they are now `@sites`, their own
# named list, and `@tabs`/`@tiles` compose the three. That is why the file grew
# while the tab count did not: the ordering is now stated once, in one place,
# instead of being implied twice by the shape of two literals.
check lib/buster_claw_web/components/explained_panel.ex        118 HELD
# 565 -> 570 on 08-14: the tab's opening claim changed, not its content. It said
# "there is no screen for this yet"; Studio -> Voice now shows the corpus, so it
# says which half has a screen and which does not. Two lines, and they were owed
# — a lockstep test in status_live_test.exs failed the moment Voice was built,
# which is exactly what it was written to do.
# 307 -> 450 on 08-16, and this is a MERGE rather than growth: `ramshackle.ex`
# (575) was deleted and the half of it worth keeping — the origin/confidence
# table and the cut-up verbs as copyable commands — moved here, along with the
# Sketch Pad section and the experimental framing. Net for the Explained folder
# is -432 lines, which is the number that matters.
#
# The two tabs existed on a real argument (someone wanting a custom chime should
# not have to read about dynamic time warping first) and it still cost more than
# it bought: two tabs described two ENGINES rather than one place you go to make
# something, and the Ramshackle tab had drifted into claiming the Voice surface
# was unbuilt months after it shipped.
check lib/buster_claw_web/components/explained/studio.ex       450 HELD
# 460 -> 660 on 08-15. The tab gained a SECOND SPINE rather than more of the
# first: three capabilities with three unrelated blockers (inbound voice works;
# outbound SMS is built and blocked on Twilio paperwork; outbound voice needs no
# A2P at all and is simply unbuilt). That distinction is the most confusing thing
# about this feature and the operator hit it in the console the same day.
#
# It is prose and one table, not extractable logic — splitting it would put half
# a tutorial's argument in another module, which is the failure `ramshackle.ex`'s
# cap comment already describes for the same reason.
#
# 660 -> 690 later the same day, in two steps: `phone_call` shipped and turned
# the third spine's "you cannot" cycle into a worked demo, then the keypad button
# shipped and the G-37 disclosure paragraph had to explain a sentence that had
# been deleted rather than just assert a new one. That is the cap paying for
# things becoming true, not for more prose about the same thing.
#
# 690 -> 710 when Phase 0 was decided: the caller-ID choice has a consequence
# the tab had not stated (a call back is an UNTRUSTED inbound, so it is archived
# and never queued), and the operator asked the question the A2P section had left
# implied — whether any of this needs a business. It does not, and a tutorial
# that leaves a reader believing otherwise costs them the feature.
check lib/buster_claw_web/components/explained/phone.ex        710 HELD
check lib/buster_claw_web/components/explained/cmd.ex          430 HELD
# 340 -> 350: the tab taught two surfaces and there are three
# (WIDGET_BACKGROUND Phase 4). Named rather than counted — a page that says
# "two" while the picker shows three is the drift this feature spent a day on.
check lib/buster_claw_web/components/explained/shaders.ex      350 HELD
check lib/buster_claw_web/components/explained/browser.ex      310 HELD
check lib/buster_claw_web/components/explained/models.ex       305 HELD
check lib/buster_claw_web/components/explained/gws.ex          278 HELD
check lib/buster_claw_web/components/explained/cmd_table.ex    203 HELD
check lib/buster_claw_web/components/explained/shared.ex       182 HELD
# 245 -> 252 on 08-16: the `@command_stats` block gained a comment naming the
# five verbs that moved every number in it (the contribution surface). The stats
# themselves are a hand-maintained mirror of the live catalog, and a drift test
# compares the two — the comment is what makes the next recompute reviewable
# rather than a diff of seven integers.
check lib/buster_claw_web/components/explained/registry.ex     252 HELD
# The ninth tutorial (08-15). Pockets earns a tile where five parked candidates
# did not, and the argument is worth keeping: it is already load-bearing in three
# other surfaces — backgrounds, brand art and contact faces all live in Pockets —
# so a user meets the word three times with no page to send them to. Capped on
# arrival.
check lib/buster_claw_web/components/explained/pockets.ex      365 HELD
check lib/buster_claw_web/components/explained/intro.ex        151 HELD

# The Message Machine's three panels, and the registry that decides which of
# them a sub-tab shows. `registry.ex` is capped on arrival: it is data-only by
# construction (a `when` guard reads it at compile time), so growth here means a
# third sub-tab, which is exactly the change that should cost a decision.
check lib/buster_claw_web/components/phone/contact_list.ex   330 HELD
check lib/buster_claw_web/components/phone/playback.ex       314 HELD
check lib/buster_claw_web/components/phone/log.ex            256 HELD
# 176 -> 200 on 08-15, for the second thing this app prices. The cost breakdown
# renderer had the three voicemail components inlined as a literal; an outbound
# call has two legs and different labels, so the parts became an ordered list and
# gained `priced_kind?/1` — which is here rather than in `Playback` so the panel
# that shows a Cost line and the query that fills it in cannot disagree.
check lib/buster_claw_web/components/phone/shared.ex         200 HELD
check lib/buster_claw_web/components/phone/registry.ex        62 HELD

# The Google Workspace console: a rail, and one module per pane.
check lib/buster_claw_web/components/gws_panels.ex           135 HELD
check lib/buster_claw_web/components/gws/mail.ex             255 HELD
check lib/buster_claw_web/components/gws/accounts.ex         127 HELD
check lib/buster_claw_web/components/gws/calendar_sync.ex    101 HELD

# The homepage. 891 rather than the roadmap's original <600 target: what remains
# is mount, render, and 55 message-handling clauses, which is the coordinator's
# job and not residue. See the Phase 2 status block for why that target retired.
# Raised 08-08 for chat attachments (drag/paste of images and files), and the
# reason is on the record because a silent raise is what this gate exists to
# stop. The FEATURE did not land here: it is 546 lines in
# `status/chat_attachments.ex`, created for it. What these two absorbed is the
# part that provably cannot live anywhere else — `allow_upload` is a LiveView
# configuration and must be on the LiveView, and an `apply_chat` clause must sit
# at the dispatch point. Every substantive call in the added lines delegates
# straight back out (`init`, `pending`, `marker`, `decode`, `hydrate`,
# `place_in_pool`). If a later reader finds real logic in these lines rather than
# wiring, this raise was wrong and the cut is owed.
# Raised again 08-08, by 11 lines, for `explained_try_in_chat` — the handler behind
# a tutorial's "Try in Chat" button. It belongs here for the same reason
# `email_contact` above it does: switching the home tab and pushing the composer
# prefill are both operations on THIS LiveView's own state, and the panel that
# owns the button renders behind `:if` and cannot hold either. It delegates
# nothing because there is nothing to delegate to — two lines of socket plumbing
# and a size bound.
# Raised 08-09 for the chat's text size. status_live.ex stays at 945 — the two new
# axes cost it ONE line, because `status/chat.ex` absorbed the wiring: one
# `subscribe_chat_look/0`, one `assign_chat_look/1`, and one `handle_info` clause
# keyed on the axis name serving both skin and size. That is the shape this cap is
# meant to produce, and it is why chat.ex moves instead.
# LOWERED 08-09 from 945, banking the extraction the previous note said was
# owed. The homepage banner became swappable and the heading moved out to
# `components/brand_art.ex` rather than growing here: 944 -> 929. The cap follows
# the file down in the same commit, which is the ratchet this script exists for.
# Raised 08-09, 929 -> 942, for the Studio tab's Mix|Voice sub-tabs
# (STUDIO_ROADMAP VI.0b). Thirteen lines, and the SHELL is not here: the rail, the
# dispatch and the placeholder are 142 lines in `components/studio_panel.ex` and
# the whitelist is in `status/studio.ex`, both created/extended for it. What
# landed here is the irreducible part — the `:studio_tab` assign (a home panel
# renders behind `:if`, so the sub-tab cannot be held by the panel that shows it),
# one `handle_event` clause that delegates in full, and the toolbar's condition
# gaining `and @studio_tab == "mix"` because that toolbar belongs to Mix. The
# dispatch swap was net ZERO: the frozen component's ten assign lines moved from
# a `.live_component` call to a `.studio_panel` one. If a later reader finds rail
# markup or tab logic in this file, this raise was wrong.
# Raised 08-14, 942 -> 955, for the Voice sub-tab (STUDIO_ROADMAP VI.1). The
# same shape as every raise above it, and the same test: what landed HERE is
# only what provably cannot live anywhere else. Three `handle_event` clauses
# that each delegate in full to `Status.Voice`, one alias, one mount assign, and
# six attrs on the panel call. The corpus read, the filtering, the sentence
# grading and every pane of markup are in the two modules created for them.
#
# Note what did NOT land here: the lazy corpus load. `select_studio_tab` already
# routes through `Status.Studio`, so the "arriving at Voice reads the corpus"
# rule lives there and this file's tab clause is unchanged.
# 955 -> 970: the widget surface's assign, subscription and one `handle_info`
# (WIDGET_BACKGROUND Phase 2). Its own topic and its own assign — the homepage's
# background and the corner card's are two surfaces that share a page, not one.
# 970 -> 977 on 08-16 for the Contribute sub-tab (STUDIO_ROADMAP V.6-V.8), and
# this raise was BUDGETED before the feature was written rather than discovered
# after. It bought twelve lines and no logic: an `alias`, one `assign_contribute`
# in the mount pipe, one `attr` pass-through, and two `handle_event` clauses that
# delegate whole.
#
# Two shaping decisions kept it to twelve, both worth preserving. Contribute's
# state is ONE map assign rather than the six scalars Voice threads through, so
# the panel takes one `attr` instead of eight. And its six sub-actions share a
# single `handle_event("contribute", %{"do" => action})` clause that delegates to
# `Status.Contribute.handle/3`, rather than six near-identical clauses here —
# this file is at its cap for a reason, and spending the last of it on
# punctuation would be the wrong trade.
#
# The surface is 251 lines and its state 233, both in modules created for it. The
# standing test applies: if device enumeration, PCM handling or bank logic ever
# appears in THIS file, the raise was wrong and the cut is owed.
# 977 -> 995 on 08-16 for the Voice Library's own navigation: three delegating
# `handle_event` clauses (section, word selection, build preview) and the five
# assigns the panel needs. Still no logic — every clause is one line into
# `Status.Voice`. If a later reader finds a `case` or a domain call in one of
# them, this raise was wrong.
# 995 -> 1005: three more delegating clauses for take curation (prefer, unprefer,
# delete) and the notice assign they write. Still one line each into
# `Status.Voice`; the standing test applies.
# 1005 -> 1050: the selected clip's effect chain — four delegating clauses, the
# `studio_preview` assign, and one integer coercion. They are HERE rather than in
# the component because `Status.Studio.mutate_open_mix/2` is what records undo,
# and an effect that could not be undone would be the first arrangement change in
# the Studio that could not. The standing test still applies: no `case`, no
# domain call, one line each into `Status.Studio`.
# 1050 -> 1060: `select_clip`, and the bug it fixes is the reason to keep the
# lines rather than trim them. A hook's `pushEvent` reaches the LIVEVIEW; only
# `pushEventTo` reaches a component. That clause was missing, so every click on
# a clip crashed the LiveView and the remount threw the operator back to Chat.
# Two reports, no failing test, and comments in two files asserting the opposite
# routing — which is why the comment here is longer than the clause.
# 1060 -> 810 on 08-16: the Studio moved off Home to `/studio`, taking ~30
# handle_event clauses, four handle_info clauses, twelve assigns, `to_int/1` and
# the panel render with it. The ratchet is what asked for this number — the file
# came in at 738 and a cap left at 1060 would have quietly re-opened 300 lines
# of room the extraction had just closed.
check lib/buster_claw_web/live/status_live.ex                810 HELD
check lib/buster_claw_web/live/status/chat.ex                685 HELD

# Added 08-09 when the chat skins pushed this past 1,000 lines. It has never been
# decomposed, so this is not a post-split cap being defended — it is the first
# number anyone has put on the file, set where the skins left it. The growth was
# +152 lines for three skins' worth of markup anchors, an author line, a shared
# `log_class/0` and the Appearance preview, and the reason it landed HERE rather
# than in a new module is the skin contract: the preview must render the SAME
# private `chat_bubble/1` the live chat renders, or the surface you check a skin
# on is the one place a drift would not show. A second module would have meant
# either a public bubble API or a copy of the markup.
#
# The honest reading of 1,000 lines is that the bubble family (five roles, the
# scene card, the SVG modal) is a coherent module hiding inside a panel module,
# and it is the obvious cut when this next needs headroom.
# Raised 08-09 by 20 for the text size: two `attr` declarations, the
# `data-chat-text-size` attribute, and the preview passing it through. The FEATURE
# is not here — it is one CSS custom property in app.css and a 100-line module.
# What this file gained is the opposite of bulk: five Tailwind type literals
# LEFT it (`text-[17px]` and friends), because a utility class cannot be
# multiplied and the sizes had to become `calc(x * var(--chat-scale, 1))`.
check lib/buster_claw_web/components/chat_panel.ex          1040 HELD

# Added 08-09 when the terminal theme editor took this from 705 to ~991. Never
# decomposed, so like chat_panel.ex above this is the first number on the file
# rather than a post-split cap. It is a settings page whose job is genuinely broad
# — backgrounds for two surfaces, an image pool with uploads, the app theme, the
# terminal palette with a 21-field colour editor, and the chat's two axes — and the
# palettes themselves live in `BusterClaw.TerminalTheme`, not here.
#
# The obvious cut when this next needs room: the terminal-theme block (its five
# events, the draft helpers and the colour rows) is a coherent component, and the
# background catalog is a second one.
#
# Raised 08-09, 1010 -> 1035, for the agent's theme slot (TERMINAL_PAINT_ROADMAP
# Phase 1). The slot itself is not here — it is `agent/0`, `set_agent/2` and the
# legibility floor in `BusterClaw.TerminalTheme`, and this page cannot write it
# at all. What landed is the 22 lines that make it VISIBLE: a badge on the
# picker row, an `agent_slot?/2`, one assign, and the sentence telling the
# operator whose theme that is. There is deliberately no editor and no delete
# button for it — the model's `terminal_theme_reset` clears it, and this surface
# does not own that.
# Lowered 08-14, 1035 -> 1000, banking the image-shader Phase 3 split: the
# per-surface block moved to `components/surface_panel.ex` and the shader canvas
# to `components/shader_canvas.ex`, so this page lost 97 lines while GAINING the
# overlay picker. Not lowered to 972+10%: this file is a settings page for a
# genuinely broad surface and the review named its two remaining seams (the
# terminal-theme block, the background catalog), so leaving a little room is
# honest rather than generous.
# 1000 -> 1060 on 08-15: minting approval on the human click
# (AGENT_APPLIED_SHADERS Phase 2) — two call sites, one shared key extractor, and
# the disclosure line that keeps a silent grant from being silent. About 25 lines
# of code to 45 of comment and markup.
#
# EXTRACTION OWED (operator, 08-15) and this file is the reason it was asked for:
# it was already at its cap with no headroom before this landed. See
# LEFTOVERS_SURFACES; `workspace_shader/1` here is the third copy of the mode
# grammar and is the obvious first thing to leave.
# 1060 -> 1075: the catalog row's label now yields (WIDGET_BACKGROUND Phase 3).
# Flex children do not shrink below their content, so a long option name pushed
# the buttons out of the row instead of ellipsing — invisible with two surfaces,
# reachable with three. The EXTRACTION OWED above is unchanged and now overdue.
check lib/buster_claw_web/live/appearance_live.ex            1075 HELD
check lib/buster_claw_web/live/status/comms.ex               125 HELD
# Raised 08-09, 114 -> 150, for the Studio's Mix|Voice sub-tab (STUDIO_ROADMAP
# VI.0b). This module moved instead of `status_live.ex` — which is at its cap and
# is the point of these two numbers sitting next to each other: it took the mount
# default (`assign_studio_tab/1`) and the whitelist (`select_studio_tab/2`, which
# reads `StudioPanel.tab_keys/0`, so the rail, the guard and the dispatch cannot
# disagree), and left the LiveView one assign, one clause and one condition. Most
# of the +33 is the `@doc`s stating why the assign is not the panel's.
# 150 -> 240 on 08-16 for clip effects. This module was the arranger's state and
# is now also the effect chain's: `effect_change/2` (every mutation, through
# undo), `preview_clip/1` (render one clip through its chain), and the preview
# versioning that stops the browser replaying a stale chain.
#
# The seam if it grows again: the ARRANGER half (history, open mix, selection)
# and the CLIP half (effects, preview) share only `mutate_open_mix/2`. Splitting
# there is clean; splitting anywhere else is not.
check lib/buster_claw_web/live/status/studio.ex              240 HELD
check lib/buster_claw_web/live/status/weather.ex              97 HELD

# The Studio tab's sub-tab rail (STUDIO_ROADMAP VI.0b, 08-09): Mix is the
# existing studio, Voice is a placeholder until Parts V and VI land. Capped ON
# ARRIVAL, and the two numbers are deliberately different.
#
# `studio_panel.ex` has NO headroom: it is the rail and the dispatch and nothing
# else — the shape `explained_panel.ex` above proved — so its first line of growth
# means a Voice surface is landing in the dispatcher instead of in its own module,
# which is the decision this gate should make someone defend. Note what it does
# NOT do: `sound_studio_component.ex` is FROZEN at exactly its size, so the rail
# lives ABOVE it and Mix renders it unchanged. That is why the frozen cap below
# still holds with a whole sub-tab axis added.
#
# `registry.ex` gets a little room on purpose. The design promise is that adding
# a sub-tab — or splitting Voice into recording and dictionary, which the roadmap
# expects — is ONE edit in the registry; a zero-headroom cap would quietly make it
# two.
# Raised 08-14, 142 -> 170, when Voice stopped being a placeholder and became
# VI.1's Ramshackle surface. This is the raise the note above says to question,
# so it says what it bought: an `alias`, a six-attr block, and a 12-line
# dispatch that renders `Studio.Voice.voice/1` and nothing else. The SURFACE is
# 220 lines in `components/studio/voice.ex` and its state is 166 in
# `live/status/voice.ex`, both created for it. If a later reader finds pane
# markup, filtering, or corpus reads in this file, this raise was wrong and the
# cut is owed.
# Raised 08-16, 170 -> 185 and 75 -> 85, for the THIRD sub-tab: Contribute, the
# recorder (STUDIO_ROADMAP V.6-V.8). This is the split the note above predicted
# in as many words — "or splitting Voice into recording and dictionary, which the
# roadmap expects" — so it is the raise that note was written to permit, and it
# bought exactly what was forecast: one `@tabs` entry plus one word in `@built`
# in the registry, and one `alias` + one `attr` + a 6-line dispatch in the panel.
#
# The registry's share is mostly PROSE, not tabs: its moduledoc now records that
# the one-edit promise held when tested. If a later reader is tempted to reclaim
# that, note the tab data itself is 15 lines of the 79.
#
# The same test still applies: if pane markup, device enumeration or PCM handling
# ever appears in `studio_panel.ex`, this raise was wrong. The surface is 251
# lines in `components/studio/contribute.ex` and its state 233 in
# `live/status/contribute.ex`, both created for it.
# 195 -> 215 on 08-16 for the Sketch Pad's dispatch: an alias, a four-line
# `:if` block and the comment above it. The "NO headroom" note above still
# stands as the rule — this file is a rail and a dispatch and must not become a
# place features live — and a third tab arriving is exactly the growth it was
# capped to make visible rather than to forbid.
check lib/buster_claw_web/components/studio_panel.ex         215 HELD
check lib/buster_claw_web/components/studio/registry.ex       85 HELD

# Voice, the Ramshackle surface (VI.1), capped on arrival. `voice.ex` is the two
# panes; `status/voice.ex` is their state, in `StatusLive` for the reason every
# home panel's is — the panel renders behind `:if` and a half-typed sentence
# must survive a glance at Chat.
#
# The seam if either grows: Pane 2 (takes, waveform, audition) is the missing
# third pane and needs a route that serves a take's audio. That is a sibling
# module and its own surface, not another section of these two.
# 230 -> 240 on 08-15: both forms gained `phx-submit` after the packaged build
# showed Enter navigating away from the tab, and the raise is almost entirely the
# two comments explaining why an apparently decorative attribute is load-bearing
# (DMG-review-8-15, finding 3). A later reader tidying those attributes away
# would reintroduce the bug; form_submit_test.exs now fails if they do.
# `studio/voice.ex` was DELETED 08-16: the Voice Library's Words and Sentence
# panes are what it became, so leaving it would have left a module nothing
# renders. Its cap is replaced by the Library's, split by SECTION rather than
# by layer — `voice_library.ex` is the sidebar and the dispatch, each pane is
# its own file, which is why none of them is large.
#
# `words.ex` and `sentence.ex` carry `data-play` / `data-source` / `data-start`
# / `data-end` / `data-version`. That is `voice_audition.js`'s contract for
# playing a slice of a file; renaming one breaks audition with the suite green.
check lib/buster_claw_web/components/studio/voice_library.ex 190 HELD
# 180 -> 225 on 08-16 for take curation: each take now carries a play button, a
# "use this one" toggle and a delete, plus the line explaining what happens when
# nothing is marked. That is three controls per row where there was one link.
#
# The toggle is a TOGGLE and not a radio group deliberately — clicking the chosen
# take again clears the choice and hands selection back to `Cutup.Select`, which
# a radio has no way to express. If a later reader "fixes" it into a radio, that
# is the behaviour they are removing.
check lib/buster_claw_web/components/studio/words.ex         225 HELD
# 170 -> 185: the per-word chips became BUTTONS with two destinations —
# `chip_event/1` sends a word that exists to Words and a word that does not to
# the recorder, because a recording is the only thing that changes a `missing`.
# The raise is mostly the tooltips, which now say where a chip GOES: two
# destinations from chips differing only by colour would otherwise surprise.
check lib/buster_claw_web/components/studio/sentence.ex      185 HELD
# 175 -> 182 -> 320 on 08-16. The big raise is the Voice Library's merge, and it
# is the one entry here that should be questioned first if this area grows again.
#
# What it bought: `load_report/1` scoped to the active bank, plus the three
# things the Library added that are STATE rather than markup — the section
# switch, the selected word and its takes (VI.1's pane 2), and the sentence
# preview with its version counter. Each is small; together they are ~120 lines.
#
# Why they are here rather than in a fourth module: they are one surface's
# state, and every one of them must outlive the `:if` that discards the panel on
# a home-tab switch. A separate module would have to be threaded through
# `StatusLive` anyway, and `StatusLive` is the file with no room.
#
# `status/recorder.ex` is the deliberate exception — it is the microphone half,
# shares nothing with this but the bank, and stayed separate for that reason.
# 320 -> 400 on 08-16 for take curation — select/prefer/unprefer/delete and the
# sentences that report what a deletion actually removed. This file is now the
# one to question first in this area: it is the Library's whole non-hardware
# state, and the seam if it grows again is the TAKE half (selection, preference,
# deletion) splitting from the CORPUS half (report, query, phrase, preview).
check lib/buster_claw_web/live/status/voice.ex               400 HELD

# The recorder — the Library's Record section (V.6-V.8). Its meter subtree is
# `phx-update="ignore"` and its interior belongs to `voice_recorder.js`: the
# device readout, the meter, the peak hold and the button label are painted by
# the hook, so markup that looks unused here may be the hook's contract.
# `data-role` attributes ARE that contract.
#
# `status/recorder.ex` is the microphone half of the Library's state and stayed
# separate from `status/voice.ex` on purpose: they share nothing but the bank.
# Its 250 -> 265 raise was the two error tables becoming MAPS with a default
# rather than a clause per atom — longer, and the length is the point, since a
# clause set covering every error its callee returns makes the catch-all
# unreachable (a Dialyzer `pattern_match_cov` finding) and deleting the
# catch-all to satisfy it makes the function partial.
check lib/buster_claw_web/components/studio/recorder.ex      280 HELD
check lib/buster_claw_web/live/status/recorder.ex            265 HELD

# --- The Studio, on its own route (08-16) ------------------------------------
#
# `studio_live.ex` is what `StatusLive` handed over: the Studio's whole event
# surface, unchanged. Every clause still delegates one line deep into
# `Status.Studio` / `Status.Voice` / `Status.Recorder`, which did not move — so
# growth here means a handler that stopped delegating, which is the thing to
# look at rather than the line count itself.
check lib/buster_claw_web/live/studio_live.ex                415 HELD
# The Sketch Pad's markup. Capped on arrival at close to its size because the
# whole point of its first version is to be small: a canvas, five colours, three
# sizes, an eraser and clear. If it grows, the question is whether SAVING
# arrived — and that is a `sketch_*` command and a workspace path, which is a
# roadmap rather than more markup here.
#
# 155 -> 190 on 08-16, in two steps. The first was NEITHER of the things the cap
# asks about.
# It grew for a third reason: `data-active` + `aria-pressed` on all three toggle
# groups, replacing pressed styling that JS assembled by hand and half-applied
# (the size buttons kept a `text-primary` nothing removed, and the eraser never
# marked itself at all). State moved OUT of the classes and into one attribute,
# which costs markup here and removes a whole class of bug. No control was added.
#
# The second step answers the cap's question YES: **SAVING ARRIVED**
# (SKETCH_ROADMAP Phase 1). It came as the roadmap said it would — a workspace
# path and a document, not more markup — but the toolbar grew with it, because a
# document has Undo, a Delete for the selection, and tools that only mean
# something once marks are addressable. The file also stopped being
# markup-for-a-canvas: it is now the toolbar and status line for a surface whose
# state lives in `SketchComponent`, and the drawing moved to `Studio.SketchSvg`.
# Three files where there was one, and this is the smallest of them.
check lib/buster_claw_web/components/studio/sketch.ex        190 HELD

# The Sketch Pad's document (SKETCH_ROADMAP Phase 1) and its images (Phase 4).
# Capped on arrival, the rule this repo adopted on 08-16. This is the substrate a
# model will write through in Phase 3, so growth in any of them is a question
# about what a sketch IS rather than about markup.
#
# `element.ex` is the validation boundary and the one most likely to grow
# legitimately — it holds two kinds today and the roadmap adds text and shapes
# later. Each new kind is a `build/2` clause plus its field validators; raise this
# when one lands, and say which.
#
# `paths.ex` exists to BREAK A CYCLE rather than to hold logic: `Store.delete/1`
# removes a sketch's sidecar and `Assets` needed the sketch's path, so the two
# called each other and check_cycles.sh caught a third cycle in a repo that
# accepts two. It should stay small — if it grows, something has moved into it
# that belongs in one of its two callers.
#
# `image_info.ex` is a header parser, not a decoder. It grows only when a format
# is added, which is a decision rather than maintenance.
check lib/buster_claw/sketch/element.ex                       275 HELD
check lib/buster_claw/sketch/store.ex                         235 HELD
check lib/buster_claw/sketch/assets.ex                        190 HELD
check lib/buster_claw/sketch/image_info.ex                    180 HELD
check lib/buster_claw/sketch/document.ex                      140 HELD
check lib/buster_claw/sketch/paths.ex                          80 HELD
check lib/buster_claw/sketch/placement.ex                      90 HELD

# The Sketch Pad's state and its surface, split from `studio/sketch.ex` when the
# document arrived. The component owns loading, saving, undo, uploads and the
# event handlers; the renderer owns drawing and nothing else. Growth in the
# component is a new tool or a new phase; growth in the renderer is a new
# element kind.
check lib/buster_claw_web/live/sketch_component.ex            410 HELD
check lib/buster_claw_web/components/studio/sketch_svg.ex     215 HELD

# The Notes vault: state in the live_component, markup in three function
# components. Split at ~810 lines during the Home Activity + Notes roadmap's
# Phase 2 (archive/08-08-26-home-activity-notes.md) rather than
# after, because Phase 3 (search, switcher, wikilinks, backlinks) landed in all
# of them.
#
# Raised in the Phase 3 commit, which is the intended use of this gate rather
# than a failure of it: the component gained search, the switcher's six events,
# wiki-link open/create, and backlinks; the rail gained the search field and
# snippets. The switcher came out as its own file instead of a fourth section of
# the component. The roadmap is closed, so the next change to any of these owes
# a reason here.
#
# The reason, 08-09 (daily-growth/archive/08-09-26-notes-editor.md W1/W2): the rail gained the vault's
# right-click menu, because delete moved off the editor header and onto the
# list. It is a net move — `editor.ex` lost the pencil and the trash can in the
# same change and stays under its own cap — so the +26 buys the rail a menu it
# now owns outright, not a second feature. `editor.ex` keeps 300 rather than
# ratcheting down: at 292 it is nowhere near the 80% floor, and the header it
# lost was traded for the docs explaining what replaced it.
check lib/buster_claw_web/live/notes_component.ex              744 HELD
check lib/buster_claw_web/components/notes/editor.ex           300 HELD
check lib/buster_claw_web/components/notes/rail.ex             250 HELD
check lib/buster_claw_web/components/notes/switcher.ex         134 HELD

# --- FROZEN: named by an unstarted phase; capped at today's size -------------

# Phase 3. 20% markup, so ~987 lines of logic in a live_component. The source
# catalog comes out to core, where the missing sound_* CLI will need it.
# 1235 -> 1206 on 08-16, and DOWN is the direction this row has been waiting for.
# The mixdown, the effect chain and `placement/1` moved to `Studio.Render`, which
# is where they wanted to be once clips gained effects — a render is domain work
# and was only ever in a LiveView because it was three short functions.
#
# The gate is what forced it: this file could not have grown to hold the chain,
# so the choice was extract or do not ship. That is the whole argument for FROZEN.
# 1184 -> 1178 on 08-16. A `duplicate_clip` handler needed four lines, and FROZEN
# means a new feature is funded by an EXTRACTION rather than a raised cap — so
# `render_error/1` moved to `SoundStudio.Format`, where the rest of this tab's
# pure presentation already lives. Net six lines down, and the gate is the only
# reason the right thing happened rather than the easy one.
# 1178 -> 1038 on 08-16: the frozen Phase 3 was finally taken. The source
# catalog — five item builders, the group roster and the folded-groups setting —
# moved to `BusterClaw.Notifications.StudioCatalog` in CORE, with the web's
# `url` decoration left behind in `SoundStudio.Catalog`.
#
# That split is what unfroze this file, and it only worked because of the
# correction the 08-13 review made to the original plan: four builders baked
# router `~p` URLs, so a naive move would have dragged `BusterClawWeb.Router`
# into `lib/buster_claw/`. Core carries a filesystem PATH — which is what the
# unbuilt `sound_*` CLI needs — and the web adds the URL on top.
#
# **The 140 lines are banked here rather than left as headroom on purpose.**
# The Mix tab is about to gain a menu bar, and it goes in its own module beside
# `arranger.ex` and `overlays.ex` — which is the pattern this file already
# follows and the reason FROZEN keeps producing extractions instead of growth.
#
# 1038 -> 995 the same day, when the menu bar landed and took the tab-bar
# toolbar with it: New mix and Import moved onto the surface they act on. The
# sidebar (202 lines, ungated) was deleted outright.
# 995 -> 985 when the music library manager was deleted on 08-16: its render
# branch, the `:library` kind guards and the `@player` thread went with it.
# 985 -> 972 on 08-16, and the direction is the point. Clip trim needed ~70
# lines of handlers in here, and FROZEN means a feature is funded by an
# EXTRACTION rather than a raised cap — so the socket-free edit block went to
# `SoundStudio.Edits`, which the 08-13 review had already named as the better
# second cut of the frozen Phase 3. Third time the freeze produced an extraction
# instead of growth, and the file ended up SMALLER than before the feature.
#
# UNFROZEN 08-16 (operator). FROZEN -> HELD, 972 -> 1070.
#
# **By the letter of this file's own rule.** FROZEN means "a target of an
# unstarted roadmap phase", and Phase 3 — the phase it was frozen FOR — was
# taken the same day. A tier whose stated condition has been met and which
# nobody re-argues is how a gate stops meaning what it says.
#
# What the freeze was worth, recorded because the number alone does not show it:
# **1,235 -> 972 while GAINING the effect chain, duplicate-clip, a menu bar and
# clip trim.** Four extractions, three of them producing files that exist only
# because a feature could not be paid for any other way — `Studio.Render`,
# `SoundStudio.Format`, `SoundStudio.Edits`. Nobody set out to refactor on any
# of those days.
#
# HELD at +10% is the ordinary contract: maintenance is fine, a feature landing
# whole in here is not. **If it reaches 1070, the question is not "raise it" —
# it is whether the 29 event clauses want the same treatment the catalog got.**
check lib/buster_claw_web/live/sound_studio_component.ex     1070 HELD
# The Studio's effect chain, capped on arrival. `effects.ex` is the registry AND
# the DSP: adding an effect is a `@catalog` entry plus an `apply_one/2` clause,
# and it then appears in the inspector, saves into the mix, applies on render and
# is audible in preview with nothing else touched. That is the extension point
# the operator asked for, so the thing to watch is whether it stays one.
#
# If it grows past this, the seam is REGISTRY vs DSP — the catalog and the
# clamping are contract, the comb filters are arithmetic. They are together today
# because splitting four effects across two files would be ceremony.
#
# `render.ex` is the mixdown, extracted from the FROZEN component on 08-16. Watch
# for source RESOLUTION appearing here: it is passed in as a function on purpose,
# because it spans the sidebar's three groups and belongs to the surface.
check lib/buster_claw/notifications/studio/effects.ex         400 HELD
# 160 -> 175: the window is now applied here, and the comment explaining why
# doing so was SAFE (add_clip sets duration to the source's own length, so the
# cut is a no-op on every mix written before trim) is worth more than the line.
check lib/buster_claw/notifications/studio/render.ex          175 HELD
# The clip inspector: remove, and the chain. Renders `Effects.catalog/0`, so a new
# effect needs no edit here. Its controls carry NO `phx-target` — they bubble to
# `StatusLive` so they route through undo — and a later reader "fixing" that by
# adding one would silently remove ⌘Z from every effect.
check lib/buster_claw_web/components/sound_studio/clip_inspector.ex 240 HELD
# The Mix menu bar — the file bar that replaced the sidebar on 08-16. Most of
# its length is menu markup, and the part to watch is not the size: it is the
# table in its moduledoc saying where each deleted sidebar control went. If a
# control lands here with no row in that table, something was orphaned.
# The Mix tab's socket-free edit operations, extracted 08-16 to pay for clip
# trim. Two things called "trim" live near each other now and are opposites:
# `Edits.apply_trim/2` cuts a FILE and writes a new source; `StudioMix.trim_clip/4`
# narrows a clip's window and touches nothing on disk. Its moduledoc says so.
check lib/buster_claw_web/components/sound_studio/edits.ex    130 HELD
check lib/buster_claw_web/components/sound_studio/menu_bar.ex     400 HELD

# Phase 4 STARTED 08-15, so this stops being FROZEN and becomes HELD: 936 -> 643,
# banked here at 708. It was frozen as "four unrelated features sharing a
# render/1"; three still share one, but the page now has a rail and the first
# feature has its own module, which is a different promise from "do not grow,
# you owe a cut".
#
# The remaining cut is GOOGLE WORKSPACE, and it is named rather than left to be
# rediscovered: 12 handle_event clauses, and the only section whose refresh
# arrives as a `handle_info` (`:google_account_changed`), so moving it needs a
# `send_update/2` relay rather than a straight lift. It was deliberately NOT
# half-moved in the same pass. Profile and Credentials are small and may simply
# stay.
check lib/buster_claw_web/live/settings_live.ex               708 HELD

# Configuration's rail, copying the registry shape for the third time —
# `Explained.Registry` and `Studio.Registry` first. The rail, the
# `select_settings_tab` whitelist and the dispatch all read the registry, so a
# tab cannot exist in one and not the others; that property has already caught a
# rail button the guard refused and a console tab that fell back silently.
#
# `registry.ex` gets headroom on purpose and `rail.ex` gets none — the same pair
# of numbers, for the same reason, as `studio/registry.ex` and
# `studio_panel.ex`. "Adding a tab is one edit in the registry" is a promise a
# zero-headroom cap would turn into a lie; a rail that grows is a rail that has
# stopped being only a rail.
check lib/buster_claw_web/live/settings/models_component.ex    470 HELD
check lib/buster_claw_web/components/settings/registry.ex       95 HELD
check lib/buster_claw_web/components/settings/rail.ex           65 HELD

# Phase 5. Needs its state machine written down BEFORE it is split — eleven-plus
# transition sites and no diagram anywhere. Frozen so it cannot gain a twelfth.
# Raised 08-08 for chat attachments, and this one BROKE THE FROZEN PROMISE — a
# frozen file is meant to shrink or hold, never grow, and this grew by 160. The
# raise is recorded rather than quiet because a quiet one is the failure this
# gate exists to catch, and the debt is filed in roadmaps/agent-core/LEFTOVERS_AGENT_CORE.md rather than left
# as a number nobody remembers earning.
#
# What could NOT be extracted: roughly half the growth is documentation, and the
# rest is a GenServer message gaining a field — every `handle_call({:submit, …})`
# clause, the queue that carries a message until its turn runs, and the resolve
# step. You cannot extract "this process's messages carry one more thing".
#
# What WAS kept out: the delivery logic itself. How a file reaches a CLI lives in
# ChatTransport (+112) and claude_duplex (+51), not here — deliberately, because
# there are three ways a turn leaves the BEAM and putting it here would have
# reached exactly one of them.
check lib/buster_claw/agent/chat.ex                          1510 FROZEN

# Phase 7, DONE 08-08-26: 758 -> 146. The 657-line heredoc is now
# `introduction/*.md`, composed at compile time.
#
# The cap fell 850 -> 161 in the same commit that earned it, which is the whole
# point of the under-cap half of this script. Note what the old cap's comment
# argued: this file grew with the command surface, so it was given room rather
# than frozen. That is now moot — the part that grew is a markdown file, and
# this module is just the composer.
check lib/buster_claw/introduction.ex                         161 HELD

# Phase 7's other half: three seed templates (162 lines of heredoc) became
# `skill-seeds/*.md`, so the two skill seeds are now the same kind of file they
# seed and can be validated as skills without being unpacked from a string.
check lib/buster_claw/skills.ex                               379 HELD

# Phase 1's fourth file, deliberately not split (15 small functions, reads fine).
# Frozen instead: capping it was always the cheaper half of that decision.
# FROZEN 699 -> HELD 130, decomposed 08-15 (WIDGET_BACKGROUND Phase 0). Three
# tabs shared this file because they share a *card* — a fact about layout, not
# about what any of them does. None touched another's helpers, so the cut was
# clean. What is left is a rail, a dispatch and the tab registry.
#
# Split with NO feature attached, on purpose: the roadmap that needed the room
# makes the Time & Place shader selectable, and a decomposition in the same
# commit as a behaviour change loses track of which one broke something.
check lib/buster_claw_web/components/home_widget.ex           148 HELD
# The three panels, capped at their as-written size — this was a move, not a
# rewrite, so there is no post-split target to leave headroom against.
check lib/buster_claw_web/components/widget/place_panel.ex    205 HELD
check lib/buster_claw_web/components/widget/comms_panel.ex    175 HELD
check lib/buster_claw_web/components/widget/notify_panel.ex   275 HELD

# These were the two largest surviving mixed files, frozen so the next roadmap
# would inherit them no worse than it found them.
#
# calendar_component.ex came off FROZEN 08-14: 866 -> 473, and the cap follows it
# down in the same commit, which is the under-cap half of this script working as
# intended. It was ~45% markup wrapped around ~190 lines of date arithmetic
# wrapped around fourteen `handle_event` clauses, and both outer layers left
# along their own seam. The markup is `components/calendar/views.ex`; the
# arithmetic is `calendar/grid.ex`, which is in CORE and now has a test file with
# no LiveView in it — the test you cannot write while `view_range/2` is a `defp`
# on a component.
#
# The two new files are capped ON ARRIVAL at their as-written size, and neither
# may become a nested live_component. A host renders the calendar behind `:if`,
# which DISCARDS a live_component's assigns rather than hiding them, so any state
# pushed down into a child would vanish on a tab switch — silently, and only on
# the homepage. Function components and a plain module hold nothing, so there is
# nothing to lose. Growth in views.ex therefore means new markup; growth in
# grid.ex means a new question about dates; growth in the component itself means
# a fifteenth event, which is exactly the decision this cap should cost.
check lib/buster_claw_web/live/calendar_component.ex          520 HELD
check lib/buster_claw_web/components/calendar/views.ex        310 HELD
check lib/buster_claw/calendar/grid.ex                        221 HELD
# Raised 08-10, 541 -> 560, for the `Messages | Contacts` sub-tab rail: the rail
# markup, one guarded event, and the two `:if` wrappers the panels moved inside.
# The rail is HERE rather than in a panel module for the reason `StudioPanel`
# records — each panel brings its own `.ic-panel`, which on the homepage is
# translucent, so nesting one inside another doubles the blur. The tab LIST is
# not here at all; it is `Phone.Registry`, which is the point of the change.
#
# Raised 08-15, 560 -> 590, for the Call button. This is what is LEFT after the
# extraction the cap forced and should have had anyway: three `handle_event`
# clauses, which cannot be imported. The flow behind them is `Phone.CallFlow` and
# the markup is `Phone.CallAction`, both capped below.
check lib/buster_claw_web/live/phone_component.ex             590 HELD

# Outbound calling's two halves, capped on arrival (OUTBOUND_VOICE Phase 4). Two
# files rather than one because a confirmation flow and the words it renders fail
# differently: the flow is wrong when it lets a call through, the copy is wrong
# when it names no fix.
check lib/buster_claw_web/live/phone/call_flow.ex             105 HELD
check lib/buster_claw_web/components/phone/call_action.ex     190 HELD

# Pockets (POCKETS_ROADMAP, 08-08/09). Capped ON ARRIVAL rather than after they
# sprawl — every file above this line was added to the inventory late, once it
# was already too big to cut cheaply. These are at their current size with no
# headroom, so the first line of growth is a decision someone has to defend.
#
# `pockets.ex` is the widest on purpose: it is the loader, the role table, the
# read fence and the mount entry point. If it grows, the fence
# (`resolve/2`/`asset_url/2`) is the seam to extract, because it is the part
# with its own test file already.
check lib/buster_claw/pockets.ex                              484 HELD
check lib/buster_claw/pockets/mounts.ex                       347 HELD
check lib/buster_claw/pocket.ex                               138 HELD
# Raised 08-09, 383 -> 467, for Phase 3's operator surface: New, Mount…, Unmount
# and the ↗ glyph. The MARKUP is not here — it is 174 lines in
# `pockets/pocket_controls.ex`, created for it. What landed here is four events,
# three assigns, and `write_error_text/1`, which turns every refusal the mount
# registry can return into a sentence. A reason rendered as `inspect/1` is a
# reason nobody acts on, and that mapping has to sit with the events that produce
# it. If a later reader finds control markup in this file, this raise was wrong.
# 467 -> 500 on 08-15 for the Dock icon (APP_ICON): two events, the status read,
# and the component call. The markup is `pockets/app_icon_slot.ex`, a sibling of
# `brand_slots.ex` for the same reason that one exists — and because this slot is
# the only one with a verb, so it does not belong in a list of six that follow
# their folder.
check lib/buster_claw_web/components/pockets_panel.ex         525 HELD
check lib/buster_claw_web/components/pockets/app_icon_slot.ex 135 HELD
# 210 -> 265 the same day: `put/2`, so the slot has the "Add art" button the six
# brand slots have. Filling a Pocket only in Finder is a Pocket most people never
# fill — operator found it in the first minute of using it.
check lib/buster_claw/pockets/app_icon.ex                     265 HELD
check desktop/tauri/src/app_icon.rs                           215 HELD
check lib/buster_claw_web/components/pockets/pocket_controls.ex  174 HELD
# Raised 08-10, 97 -> 108, for one `.wgsl` entry in the content-type table and
# the six lines saying why `text/plain` is the safe answer for it (nosniff is
# what makes it safe, not the type). The table is the file's whole point, so a
# raise that adds a row to it is the raise this cap exists to permit; a raise
# that adds path handling is not — see the moduledoc's "adds no path handling".
check lib/buster_claw_web/controllers/pocket_asset_controller.ex 108 HELD
check lib/buster_claw/commands/pocket.ex                      265 HELD
check lib/buster_claw/commands/catalog/pocket.ex               75 HELD
# Contact shaderfaces out of ONE Pocket (08-10). Capped on arrival. Two thirds
# of it is the moduledoc, and deliberately: it records the per-contact-Pocket
# design that was built up to and reversed, so the next reader does not re-derive
# it. The code is a name, a list, a merge and a two-step resolve.
check lib/buster_claw/pockets/faces.ex                        164 HELD

# Terminal paint (TERMINAL_PAINT_ROADMAP, 08-09) — the agent recolours the
# terminal it is running in. Capped on arrival, no headroom.
check lib/buster_claw/commands/terminal_theme.ex              246 HELD
check lib/buster_claw/commands/catalog/terminal_theme.ex      101 HELD

# Backgrounds on the command surface (B1, 08-15). Capped on arrival, no headroom.
#
# `appearance.ex` is comment-heavy on purpose and that is what the number buys:
# the one-verb argument (Appearance is written against its @surfaces table, so a
# per-surface verb pair would re-introduce per-surface code at the one layer that
# had none), and the refusal table that turns every atom set_background/2 can
# return into a sentence with the fix in it.
#
# The containment claim lives in the catalog moduledoc and is worth restating
# here, because it is what makes an ungated mutate verb defensible: these verbs
# SELECT from Appearance.options/0 and nothing more. No command at any tier
# uploads an image or authors a shaders/*.wgsl. If a raise here ever buys
# authoring rather than selection, it is the wrong raise — and
# appearance_test.exs's reach test fails on a Settings.put whatever it is named.
# 275 -> 355 the same day, and the raise is a SECURITY fix rather than growth.
# The original containment argument was "no command authors a shader" — true and
# insufficient, because authoring is a file write and the workspace is writable.
# An agent could write shaders/x.wgsl and then apply it by name, putting GPU code
# it wrote on the operator's screen with no human click: exactly the D1 property
# Explained.Shaders teaches. `refuse_authored_shader/1` and its refusal sentence
# are that hole closed, plus the comment explaining why the command surface is
# deliberately NARROWER than the Appearance page.
#
# If a later reader "simplifies" that check away, appearance_test.exs fails: it
# writes a shader as an agent would and asserts the command refuses it.
# 365 -> 430 on 08-15 for AGENT_APPLIED_SHADERS Phases 3 + VI.2: the check gains
# an approval branch, the refusal is rewritten to name the fix, and every option
# entry gains `approved`. Most of the growth is the comment block, which now has
# to carry BOTH why the refusal exists and why it has an exception — and that
# history is the thing that stops it being deleted again.
#
# EXTRACTION OWED (operator, 08-15). The seam is named in LEFTOVERS_SURFACES:
# the mode grammar `off | <name> | image:<slot> | image:<slot>+<shader>` is now
# parsed in three places, and `shader_component/1` here is one of them.
# 430 -> 445: reserving `default` at THIS layer too. `refuse_authored_shader/1`
# runs in front of `set_background/2`, so reserving the word in `Appearance`
# reserved it there and not here — an unapproved shaders/default.wgsl made the
# one undo every surface has refuse. Found by testing the model's path, not the
# page's.
check lib/buster_claw/commands/appearance.ex                  445 HELD
# 87 -> 100: the third surface in both descriptions, plus `default` as a mode.
# The moduledoc stops stating a COUNT — `Appearance.surfaces/0` is what the verbs
# validate against, so a fourth arrives with no edit here, and "two" outlived the
# truth by about an hour the first time.
check lib/buster_claw/commands/catalog/appearance.ex          100 HELD
check lib/buster_claw/terminal_paint.ex                        81 HELD

# Brand Pockets (POCKETS_ROADMAP Part XI, 08-09) — the dock icons and the
# homepage banner become swappable. `pockets_panel.ex` is raised 294 -> 338 for
# the upload: `allow_upload` configures the socket that owns it, so the state and
# the four events must be here. The MARKUP is not — it is 114 lines in
# `pockets/brand_slots.ex`, created for it. If a later reader finds slot markup
# in the panel, this raise was wrong.
#
# Raised again 08-09, 338 -> 383 and 114 -> 146, fixing an upload that rendered
# and did nothing. Both raises are the SAME defect: the feature had no way to
# report failure. The panel gained `handle_progress/3` (auto_upload fires
# phx-change on selection, before the entry is done, so consuming there silently
# returned []) and kept `Brand.put/3`'s error instead of swallowing it inside the
# `{:ok, _}` the consumer wants. brand_slots.ex gained the four places an upload
# can fail — config errors, per-entry errors, progress, and the server's refusal.
# None of it was rendered before, so a refused file looked exactly like a file
# that had not been chosen.
# Raised 08-09, 302 -> 347: replaced art is MOVED to the workspace root rather
# than deleted (operator call). That is `retire_all/1` plus the doc section
# explaining why a failed move leaves the original in place instead of destroying
# what it could not preserve. The collision rule is not reimplemented here —
# `FileManager.import_file/4` already had it.
# Raised again 08-09, 347 -> 362, for `topic/0` and the two broadcasts that make
# a swap reach surfaces the operator is not looking at.
check lib/buster_claw/pockets/brand.ex                        362 HELD
# 146 -> 175 on 08-15: the file picker became a shared `upload_form/1` so the
# Dock icon slot could use it. That is a NET reduction in risk, not growth for
# its own sake — the four places an upload can fail are rendered once instead of
# twice, and this file's own comment records what happened the last time they
# were missing.
check lib/buster_claw_web/components/pockets/brand_slots.ex   175 HELD
check lib/buster_claw_web/components/brand_art.ex              59 HELD
# The dock nav, lifted OUT of the layout so it can re-render (an app layout is
# rendered once at mount and never diffed). Capped at arrival with no headroom.
check lib/buster_claw_web/live/dock_nav_live.ex                45 HELD
# The visible brake (G-30, 08-16), a fourth sticky dock LiveView for the same
# layout-diff reason as the nav. Capped on arrival: over half of it is the
# argument for why it exists, why it renders nothing when idle, why it does not
# confirm, and why it must not be merged with the chat's Stop. If it grows, the
# growth is a second concern and the cap is where that gets noticed.
check lib/buster_claw_web/live/duty_live.ex                   142 HELD
# Raised 08-09, 71 -> 97, for terminal paint's Phase 0. This hook is now the one
# place that carries "wear this theme now" out to the browser, because the
# selected terminal theme lives in localStorage and a command has no socket. That
# is a second subscription and a second handler clause in a module whose whole
# job is app-chrome-for-every-LiveView, which is the right home for it.
#
# THIS RAISE WAS OWED IN 9a492ae AND WAS NOT TAKEN. That commit ran format and
# compile but not this gate, so it shipped the tree red and a parallel agent
# found it. The lesson is the boring one: the gate is part of the commit, not
# part of the review.
# 97 -> 125 on 08-15: the Dock icon push (APP_ICON Phase 3). This hook is where
# it belongs and nowhere else — it already subscribes on behalf of every
# LiveView, and an icon that only updated on the page you happened to be on is
# the fault this module was extracted to prevent. Most of the growth is the
# comment on why the push fires at MOUNT as well as on change.
check lib/buster_claw_web/chrome_hook.ex                      125 HELD

# --- The core layer enters the inventory (08-13/14, CODE_REVIEW_08-13-26) ----
#
# Every file above this line is web. That was the whole finding: the review
# measured 65,003 lines under `lib/buster_claw/` with NOT ONE of them capped,
# which is precisely where the heavyweights had drifted to while the gate
# watched the web layer. These are the files the five parallel refactors of
# 08-13/14 actually earned a number on — capped by the commit that cut them,
# not by a later pass that would have to re-measure by hand.

# Gmail, split three ways (`2ac945d`): the API surface kept the module name,
# the MIME composer and the response parser moved beside it. `mime.ex` is the
# one to watch — it owns the attachment fence and the header sanitizer, so
# growth here is either a new MIME concern (fine) or logic drifting into a
# security boundary (not). Its moduledoc says so; this cap is what makes
# someone read it.
check lib/buster_claw/google/gmail.ex                         330 HELD
check lib/buster_claw/google/gmail/mime.ex                    340 HELD
check lib/buster_claw/google/gmail/parser.ex                  260 HELD

# Integrations (`a23c702`), 539 -> 482 by collapsing five near-verbatim
# failure-recording blocks into one recorder.
#
# 500, not the 460 the review proposed. 460 was written against the review's
# estimate of where the dedup would land; the dedup landed at 482, so 460
# would demand deleting working code today to satisfy a number nobody
# measured. This is the honest post-cut cap with a little room, and it still
# ratchets 60 below the 560 the review would have opened at.
check lib/buster_claw/integrations.ex                         500 HELD
check lib/buster_claw/integrations/github.ex                  500 HELD

# The cut-up pipeline. The review read all twelve stages and found them
# correct — one stage per module, a test file each — so these are regrowth
# alarms, not split targets. Only the three files the 08-13 repairs touched
# are capped; the rest are healthy and un-nagged on purpose.
#
# `source_name.ex` is the consolidated traversal gate (`22de168`), capped on
# arrival with no headroom: it is a security boundary whose entire job is to
# be small and to be the ONLY copy. If it grows, ask what got added to a path
# check. The two stores below it shed their duplicate copies to it.
# The Studio's source catalog, extracted from the frozen component 08-16. Its
# whole discipline is that an item carries a PATH and never a URL — that is what
# lets it live in core at all, and what the unbuilt `sound_*` CLI will need. If
# it grows, ask whether a web concern crept back in.
check lib/buster_claw/notifications/studio_catalog.ex        255 HELD
check lib/buster_claw/notifications/cutup/source_name.ex      125 HELD
# Raised 08-16, 640 -> 655, for the `bank` field (STUDIO_ROADMAP V.0). Small and
# worth naming, because it is a field on a CONTRACT rather than a feature: an
# index now records whose voice it holds, which is what stops a cut-up splicing
# two speakers together. The added lines are `build/3`'s strict validation, the
# encode/decode pair, and `within_bank/2` on the search path.
#
# The rule that keeps this cheap lives in `Cutup.Bank`: a bank is METADATA, not
# a directory, so nothing here moved, and `Bank.of/1` is deliberately pure —
# putting a roster lookup in it would drop an Ecto query into this file's load
# path, which broke 46 tests the one time it was tried.
check lib/buster_claw/notifications/cutup/index.ex            655 HELD
# `bank.ex` capped on arrival. Two thirds of it is moduledoc, and deliberately:
# the rule it enforces (banks never merge; a bank is a voice-and-channel, not a
# folder) was derived three independent ways in STUDIO_ROADMAP V.0 and is the
# kind of constraint a later reader deletes as over-engineering unless the
# argument travels with the code. `of/1` alone carries 25 lines explaining why it
# must never read the roster.
#
# If it grows, ask whether a MEASUREMENT crept in. This module holds the roster
# and the pointer and nothing else — "how many takes has this bank?" belongs to
# `Cutup.Gaps`, because a registry that depends on the corpus it partitions is
# the coupling this split exists to avoid.
check lib/buster_claw/notifications/cutup/bank.ex             330 HELD
# `takes.ex` capped on arrival. Like `bank.ex` above it, much of it is the
# argument rather than the code: why a preference is a POINTER and not a bump to
# `confidence` (it would make the origin field lie, and origin is what the
# corpus's trust rests on), and the three-row table for what a deletion takes
# with it. The audio-retention row was UNCOVERED until `takes_test.exs` existed —
# breaking it failed nothing — so that test is load-bearing, not decoration.
check lib/buster_claw/notifications/cutup/takes.ex            320 HELD
# `capture/take.ex` — the recorder's server half. Capped 08-16 during the quality
# pass, which found it was the ONE module added that day with no cap: every
# sibling got one on arrival and this was missed, which is exactly the drift the
# inventory exists to make visible.
#
# Roughly half is the moduledoc's table of what one word versus a whole sentence
# produces (`:manual` at 1.0 vs `:aligned` capped below it). If it grows, ask
# whether DECODING and STORING have drifted apart — `decode/2` is pure and
# testable without a workspace, `store/3` writes files; that is the seam.
check lib/buster_claw/notifications/capture/take.ex           420 HELD
check lib/buster_claw/notifications/cutup/features.ex         760 HELD

# The web command surface (`1eee2f8`), 894 -> 848 by collapsing the six
# click/fill clause bodies.
#
# FROZEN, not HELD, and the difference is the point: that compression was
# real but it was not the split this file is owed. The review found four
# domains sharing one module — co-presence primitives, flows/checks/egress/
# secrets, bookmarks/history, and fetch/download — and named
# `Commands.WebCopresence` + `Commands.WebFlows` as the seams. Frozen at
# today's size so the next browser command has to either fit or take the
# split. One trap for whoever takes it: `browser_flow`'s `tab_step/2` calls
# the primitives as LOCAL functions deliberately, never through
# `Commands.call/3`, to avoid re-audit and double rate-limiting. That comment
# moves with them or the property is lost.
check lib/buster_claw/commands/web.ex                         848 FROZEN

# Appearance (08-14). Held out of yesterday's core section on purpose — it had
# uncommitted image-shader work in it and a cap on a moving file is a cap
# nobody can honour. Both landed since (`4c664cf`, then the migration split).
#
# `migration.ex` is the unusual one: it is capped at arrival and **is meant to
# reach zero**. Every line in it serves installs older than 08-08, so growth
# here means someone added a migration to a module whose whole argument is that
# it will one day be deleted with `rm`. If that is genuinely right, the raise
# needs to say which install it is for.
# 780 -> 800 on 08-15 for three `defdelegate`s and their docs
# (AGENT_APPLIED_SHADERS Phase 1). The approval STORE is a sibling module rather
# than more of this file, for two reasons that both bite: this file was at 764
# against 780, and `commands/appearance.ex` is held to a name-blind reach list
# plus a source-grep guard, so the command layer must reach approval through
# `Appearance` and must never name the settings store even in a comment.
# 800 -> 875 on 08-15 for the third surface (WIDGET_BACKGROUND Phase 1): the
# `:widget` table entry, the `@default_only_shaders`/`@bundled_shaders` split
# that lets a default be renderable without being selectable, and `"default"` as
# a mode. Most of it is the comment explaining why one list became two — that
# conflation is what would have shipped a blank card.
# 875 -> 895 for WIDGET_BACKGROUND Phase 2: `@daylight_shaders` and
# `needs_daylight?/1`. A third small list rather than reusing an existing one —
# "needs a clock", "is bundled" and "is offered" are three unrelated facts that
# happen to overlap today, and one list answering two questions is what nearly
# shipped a blank card in Phase 1.
check lib/buster_claw/appearance.ex                           895 HELD
check lib/buster_claw/appearance/shader_approval.ex           160 HELD
check lib/buster_claw/appearance/migration.ex                 170 HELD

# --- The JS and Rust layers enter, and the core's last stragglers (08-16) -----
#
# CODE_REVIEW_08-13-26 ranked this action #5 and called it "the cheapest thing
# that stops this review's findings from being undone". Three days later the
# core layer had entered piecemeal (capped by the commits that cut each file)
# and the other two layers had not moved at all:
#
#   assets/js         14,202 lines   ZERO capped
#   desktop/tauri/src  4,681 lines   ONE capped (app_icon.rs)
#
# Measured 08-16 rather than copied from the review, which matters twice: three
# of the review's proposed files no longer needed an entry (gmail.ex was split
# to 301, integrations.ex deduped to 494, scene3d.ex was deleted whole), and
# `studio_mix.ex` had grown 595 -> 781 in the interval with nothing to notice.
#
# Every cap below is today's size plus roughly 10% (HELD), or exactly today's
# size where the file is already too big and owes a cut (FROZEN). The verdicts
# are the review's own, per file — this pass measured and filed them, it did not
# re-diagnose them.

# ── JavaScript. The first entries this layer has ever had. ───────────────────
#
# The review's verdict on the layer was good: a real functional-core/imperative-
# shell split, pure logic in `lib/*` with sibling `.test.js` files under `bun
# test`, hooks kept thin. These three are the exceptions it named.
#
# chrome.js and tab_strip.js are FROZEN because both are OVERLOADED, not merely
# large. chrome.js is three UIs sharing one bar (bookmarks, omnibox suggestions,
# find bar) coordinating through flags. tab_strip.js is three jobs, one of which
# is the JS half of the Rust surface lifecycle — the app's most fragile
# cross-language seam, and the only part of the JS layer with no test at all.
# Frozen means the next feature either fits or takes the extraction.
check assets/js/chrome.js                                     864 FROZEN
check assets/js/hooks/tab_strip.js                            664 FROZEN
# note_editor.js is the opposite case and is capped as a regrowth alarm only:
# all parsing and commands are already extracted and tested, and ~120 lines are
# the design essay guarding against rebuilding the two editors that shipped
# green and were unusable. That essay is load-bearing — do not "clean it up" to
# get under a cap.
check assets/js/hooks/note_editor.js                          600 HELD
# The Sketch Pad's canvas hook, capped on arrival — the rule this repo wrote
# down on 08-16 after finding `capture/take.ex` was the one module added that
# day without one. It owns every pixel and the server is never told about a
# stroke, so growth here is either persistence (which belongs behind a command)
# or a tool, and both are worth being asked about.
#
# 185 -> 180 on 08-16 — ratcheted DOWN, which this gate also fails on. The tool
# state moved OUT
# to `assets/js/lib/sketch.js` (pure, 16 tests) and what stayed is DOM; the file
# briefly grew anyway, because the import block plus a real `paintToolbar` cost
# more lines than the buggy `mark()` it replaced. Then Phase 1 took the toolbar
# off this hook entirely (it is LiveView state now) and the canvas with it,
# leaving pointer handling and one in-flight path — so the cap comes down rather
# than staying stale over a file two-thirds its size.
check assets/js/hooks/sketch_pad.js                           180 HELD

# The Sketch Pad's dropzone. TWO transports and a paste, which is most of its
# size: macOS WKWebView does not hand file contents to the DOM on an OS drag, so
# the packaged app takes a path from Tauri and a dev browser takes bytes through
# LiveView's upload. The accept/refuse judgement is NOT here — it is
# `lib/attachments.js`, shared with the chat and under bun test.
check assets/js/hooks/sketch_dropzone.js                      240 HELD
# The Mix menu bar's open/close behaviour and nothing else — it never writes
# markup, which is why it needs no `phx-update="ignore"`. Growth means it started
# owning content, and that is the thing to look at rather than the number.
check assets/js/hooks/studio_menu_bar.js                       73 HELD

# ── The Rust shell. The 07-22 shape, asserted at last. ───────────────────────
#
# Decisions live in pure, textually-guarded modules (js.rs, state.rs, labels.rs,
# geometry.rs — asserted tauri-free); effects live in shells too dumb to be
# wrong. The ACL lockstep test already covers all 40 commands. What none of it
# covered was size.
check desktop/tauri/src/browser/mod.rs                       1000 HELD
check desktop/tauri/src/main.rs                               850 HELD
# js.rs is the security-critical one: ~350 lines of injected payload and ~140 of
# escaping tests, which is the ratio wanted. Growth here should mean a new
# script WITH new tests in the same file, never a payload that skipped them.
check desktop/tauri/src/browser/js.rs                         650 HELD
check desktop/tauri/src/browser/state.rs                      520 HELD

# ── The core's largest ungoverned file, and it is not close. ─────────────────
#
# FROZEN at exactly today's size. 24 verbs, zero DSP, at least four verb
# families sharing ~50 lines of coercion helpers. The repo already conceded
# this in code: `Commands.SoundCapture`'s own moduledoc says it was split out
# on 08-09 "to stop the Sound module, already the largest file in lib/, from
# absorbing a second concern."
#
# The owed split is Library / Corpus / Render behind a delegating facade so
# `commands.ex` stays byte-identical, and the 2,524-line test file is the proof
# harness. Until then the number may not move up. One trap for whoever takes it:
# `under_library/1` is the security boundary of the whole family and must keep
# exactly one home.
check lib/buster_claw/commands/sound.ex                      2464 FROZEN

# ── Core files the review read and ruled feature-sized. ──────────────────────
#
# These are regrowth alarms, not split targets. The review's diagnosis for each
# is one line here; the argument lives in the module's own moduledoc.
#
# terminal_theme.ex — ~300 data + ~250 prose + ~310 logic in four coherent
# blocks. Seams if it ever grows: the WCAG legibility floor (~130 lines, one
# caller) and the HSL generator (~120).
check lib/buster_claw/terminal_theme.ex                       880 HELD
# workspace.ex — deliberately one file. Its whole argument is that layout used
# to be an emergent property of scattered calls; splitting the registry from
# the enforcement recreates the disease it cured. ~275 lines are the @entries
# registry with load-bearing history comments.
check lib/buster_claw/workspace.ex                            660 HELD
# agent_mode.ex — the reference shape, health-checked twice. All four moduledoc
# safety properties map to enforcement code rather than hope.
check lib/buster_claw/browser_control/agent_mode.ex           650 HELD
# notes.ex — one coherent contract (containment, UTF-8, size, atomic write,
# optimistic concurrency), every function one rule applied to one verb. The
# review called it one of the best files in the set.
check lib/buster_claw/notes.ex                                610 HELD
# finance/sources.ex — a registry, and growth here IS a new source entry, which
# is the sanctioned kind. Strict status parsing means a typo cannot promote a
# source to :verified.
check lib/buster_claw/finance/sources.ex                      580 HELD
# cli.ex — a thin escript HTTP client owning no command logic. Two of its
# longest comments memorialize real shipped bugs; they are not padding.
check lib/buster_claw/cli.ex                                 1000 HELD
# commands.ex — the back two-thirds is a wall of 218 defdelegates and the size
# IS the point: a reviewable inventory of the whole surface, and it must stay
# one module for `apply(__MODULE__, …)` to preserve the single policy door.
check lib/buster_claw/commands.ex                             790 HELD
# terminal_commands.ex — a different catalog entirely (the whitelisted cmd-list
# the in-app terminal reads). Pre-named seams: the merge/normalize block (~200)
# and skill-prompt synthesis (~50).
check lib/buster_claw/terminal_commands.ex                    840 HELD
# attachments.ex — the file IS its security argument: generated filenames,
# magic-byte sniffing, size-before-read, symlink refusal, read-back
# re-validation are one argument that splitting would scatter.
check lib/buster_claw/agent/attachments.ex                    960 HELD
# stream_event.ex — five observed wire schemas as pure clauses, every mapping
# citing a probe. No shared fallback between codex's two schemas is a
# deliberate correct call, not an oversight.
check lib/buster_claw/agent/stream_event.ex                   680 HELD
# agent_backend.ex — the measured-facts table; nearly half is dated evidence
# ("measured 08-03, --help quoted") which is the module's whole value. If it
# ever splits: per concern, NEVER per backend — the cross-backend comparisons
# in the comments are the point.
check lib/buster_claw/agent_backend.ex                        580 HELD
check lib/buster_claw/agent/open_code_server.ex               570 HELD
# dispatcher.ex — the unattended pump. Bulk is six flat record_outcome clauses;
# the subtle part (swarm worst-case budget reserved up front, reconciled on
# completion) is well-commented.
check lib/buster_claw/dispatcher.ex                           600 HELD
# model_policy.ex — a deliberate leaf. Watch item rather than growth item:
# @floors and @claude_only have been empty since the trading deletion, so the
# floor guards are all vacuously green.
check lib/buster_claw/model_policy.ex                         540 HELD
# catalog/web.ex — pure data, 37 documented entries at ~16 lines each: the
# honest cost of the surface, per the standing entries/0 ruling.
check lib/buster_claw/commands/catalog/web.ex                 660 HELD
check lib/buster_claw/commands/catalog/sound.ex               530 HELD
# telephony.ex — the one file in this batch the review did not diagnose
# individually. Capped as a plain regrowth alarm; if it trips, read it properly
# before raising the number.
check lib/buster_claw/telephony.ex                            630 HELD

# ── The audio family. ────────────────────────────────────────────────────────
#
# studio_mix.ex is why this section is dated 08-16 rather than 08-13: the review
# measured it at 595 and called it cohesive, and it is 781 today. Nothing was
# wrong with the growth — it is the arrangement model plus a v1->v2 migration —
# but a 31% increase in three days on a file nobody was watching is exactly the
# rate this gate exists to make visible.
# 800 -> 870 on 08-16 for the clip window: `offset_ms` on the type, `window/1`,
# `trim_clip/4`, and both ends of the on-disk format. Most of the added lines
# are the argument — that the window belongs to the CLIP and never to the file,
# which is the property a later reader is most likely to "simplify" away.
check lib/buster_claw/notifications/studio_mix.ex             870 HELD
# sound.ex — the two-layer library + routing walk the whole surface rests on.
check lib/buster_claw/notifications/sound.ex                  610 HELD
# sound_studio.ex — PCM16 editing core + studio folder catalog. Mildly two jobs;
# `SoundStudio.Store` is the seam IF the folder half grows, not before.
check lib/buster_claw/notifications/sound_studio.ex           800 HELD
# The remaining cut-up stages. The review read all twelve and found them the
# house's best work — one stage per module, a test file each, docs carrying
# measurements rather than adjectives. Every large one is a single algorithm
# plus its corrections. These are +10% maintenance room, nothing more.
#
# One structural risk they share, recorded where someone will meet it: the
# 25 ms / 10 ms frame clock is described everywhere as "pinned in Cutup.Types",
# but Types is prose-and-types only — the numbers live as independent attributes
# in signal.ex, vad.ex and dtw.ex. The pin is a convention, not a mechanism.
check lib/buster_claw/notifications/cutup/align.ex           1030 HELD
check lib/buster_claw/notifications/cutup/select.ex          1020 HELD
check lib/buster_claw/notifications/cutup/mfcc.ex             660 HELD
check lib/buster_claw/notifications/cutup/dtw.ex              630 HELD
check lib/buster_claw/notifications/cutup/vad.ex              620 HELD
check lib/buster_claw/notifications/cutup/signal.ex           570 HELD

if [ "$fail" -ne 0 ]; then
  echo "FAIL: the file-size inventory does not hold."
  echo
  if [ -n "$over" ]; then
    echo "OVER CAP — this file grew:"
    printf "%b" "$over"
    echo "  Extract, or raise the cap here and say in the commit why the file"
    echo "  earned the room. A raised cap with a reason is fine; a silent one is"
    echo "  how the last two decompositions were undone."
    echo
  fi
  if [ -n "$under" ]; then
    echo "UNDER CAP — congratulations, now bank it:"
    printf "%b" "$under"
    echo "  Lower the number in this script in the SAME commit that earned it."
    echo "  A cap nobody tightens stops meaning anything."
    echo
  fi
  exit 1
fi

echo "OK: file-size inventory holds."
