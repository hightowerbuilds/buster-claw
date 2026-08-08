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
check lib/buster_claw_web/components/explore_panel.ex        102 HELD
check lib/buster_claw_web/components/explore/cmd.ex          396 HELD
check lib/buster_claw_web/components/explore/browser.ex      302 HELD
check lib/buster_claw_web/components/explore/models.ex       301 HELD
check lib/buster_claw_web/components/explore/gws.ex          261 HELD
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
check lib/buster_claw_web/live/status_live.ex                891 HELD
check lib/buster_claw_web/live/status/chat.ex                588 HELD
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
check lib/buster_claw/agent/chat.ex                          1376 FROZEN

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
