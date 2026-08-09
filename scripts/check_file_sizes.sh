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

# The Explore tab: a rail and a dispatch, one module per tutorial.
#
# Caps raised 08-08 for the demo contract: every worked example on these pages
# now carries four required fact attrs (prerequisites, side effects, where the
# stop is, expected result + failure state), which is roughly +5 lines per
# example and is the whole point of that commit. The two new tutorials are
# capped at their as-written size — they are content files with one function
# each, so the honest cap is "don't grow", not "don't exceed a split target".
check lib/buster_claw_web/components/explore_panel.ex        104 HELD
check lib/buster_claw_web/components/explore/phone.ex        460 HELD
check lib/buster_claw_web/components/explore/cmd.ex          430 HELD
check lib/buster_claw_web/components/explore/shaders.ex      325 HELD
check lib/buster_claw_web/components/explore/browser.ex      310 HELD
check lib/buster_claw_web/components/explore/models.ex       305 HELD
check lib/buster_claw_web/components/explore/gws.ex          278 HELD
check lib/buster_claw_web/components/explore/shared.ex       182 HELD
check lib/buster_claw_web/components/explore/registry.ex     172 HELD
check lib/buster_claw_web/components/explore/intro.ex        151 HELD

# The Message Machine's three panels.
check lib/buster_claw_web/components/phone/contact_list.ex   330 HELD
check lib/buster_claw_web/components/phone/playback.ex       314 HELD
check lib/buster_claw_web/components/phone/log.ex            256 HELD
check lib/buster_claw_web/components/phone/shared.ex         176 HELD

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
# Raised again 08-08, by 11 lines, for `explore_try_in_chat` — the handler behind
# a tutorial's "Try in Chat" button. It belongs here for the same reason
# `email_contact` above it does: switching the home tab and pushing the composer
# prefill are both operations on THIS LiveView's own state, and the panel that
# owns the button renders behind `:if` and cannot hold either. It delegates
# nothing because there is nothing to delegate to — two lines of socket plumbing
# and a size bound.
check lib/buster_claw_web/live/status_live.ex                945 HELD
check lib/buster_claw_web/live/status/chat.ex                650 HELD

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
check lib/buster_claw_web/components/chat_panel.ex          1020 HELD
check lib/buster_claw_web/live/status/comms.ex               125 HELD
check lib/buster_claw_web/live/status/studio.ex              114 HELD
check lib/buster_claw_web/live/status/weather.ex              97 HELD

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
check lib/buster_claw_web/live/notes_component.ex              744 HELD
check lib/buster_claw_web/components/notes/editor.ex           300 HELD
check lib/buster_claw_web/components/notes/rail.ex             211 HELD
check lib/buster_claw_web/components/notes/switcher.ex         134 HELD

# --- FROZEN: named by an unstarted phase; capped at today's size -------------

# Phase 3. 20% markup, so ~987 lines of logic in a live_component. The source
# catalog comes out to core, where the missing sound_* CLI will need it.
check lib/buster_claw_web/live/sound_studio_component.ex     1235 FROZEN

# Phase 4. Four unrelated features sharing a 406-line render/1.
check lib/buster_claw_web/live/settings_live.ex               936 FROZEN

# Phase 5. Needs its state machine written down BEFORE it is split — eleven-plus
# transition sites and no diagram anywhere. Frozen so it cannot gain a twelfth.
# Raised 08-08 for chat attachments, and this one BROKE THE FROZEN PROMISE — a
# frozen file is meant to shrink or hold, never grow, and this grew by 160. The
# raise is recorded rather than quiet because a quiet one is the failure this
# gate exists to catch, and the debt is filed in LEFTOVERS.md rather than left
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
check lib/buster_claw_web/components/home_widget.ex           699 FROZEN

# Not in a phase, but the two largest surviving mixed files. Frozen so the next
# roadmap inherits them no worse than it found them.
check lib/buster_claw_web/live/calendar_component.ex          866 FROZEN
check lib/buster_claw_web/live/phone_component.ex             541 HELD

# Pockets (POCKETS_ROADMAP, 08-08/09). Capped ON ARRIVAL rather than after they
# sprawl — every file above this line was added to the inventory late, once it
# was already too big to cut cheaply. These are at their current size with no
# headroom, so the first line of growth is a decision someone has to defend.
#
# `pockets.ex` is the widest on purpose: it is the loader, the role table, the
# read fence and the mount entry point. If it grows, the fence
# (`resolve/2`/`asset_url/2`) is the seam to extract, because it is the part
# with its own test file already.
check lib/buster_claw/pockets.ex                              535 HELD
check lib/buster_claw/pockets/mounts.ex                       347 HELD
check lib/buster_claw/pocket.ex                               138 HELD
check lib/buster_claw_web/components/pockets_panel.ex         294 HELD
check lib/buster_claw_web/controllers/pocket_asset_controller.ex  97 HELD
check lib/buster_claw/commands/pocket.ex                      265 HELD
check lib/buster_claw/commands/catalog/pocket.ex               75 HELD

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
