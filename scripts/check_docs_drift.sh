#!/usr/bin/env bash
# Docs-drift check: every `./buster-claw <verb>` example in the LIVE docs must
# reference a verb the current CLI actually dispatches, or a command the
# catalog actually carries. Renaming a CLI verb without updating the docs
# fails this check (and CI) instead of silently rotting the front door.
#
# Validated sources of truth:
#   1. the CLI dispatch table in lib/buster_claw/cli.ex (the `case args do` block)
#   2. the command catalog (dumped from the compiled app — exact, not grepped)
set -euo pipefail
cd "$(dirname "$0")/.."

DOCS=(README.md docs/*.md user-guide/*.md)

# --- source of truth 1: catalog command names -------------------------------
CATALOG=$(mix run --no-start -e \
  'BusterClaw.Commands.Catalog.entries() |> Enum.each(&IO.puts(&1.name))')

# --- source of truth 2: CLI dispatch verbs ----------------------------------
# Lines like `["dispatch", "claim"] ->` / `["on-duty"] ->` become
# "dispatch claim" / "on-duty".
VERBS=$(sed -n '/case args do/,/^    end$/p' lib/buster_claw/cli.ex |
  grep -oE '\["[a-z-]+"(, "[a-z-]+")?' |
  sed 's/\["//; s/", "/ /; s/"//g')

known_verb() { grep -qxF "$1" <<<"$VERBS"; }
known_family() { grep -qE "^$1( |\$)" <<<"$VERBS"; }
known_command() { grep -qxF "$1" <<<"$CATALOG"; }

# --- scan the docs -----------------------------------------------------------
fail=0
while IFS= read -r hit; do
  file=${hit%%:*}
  rest=${hit#*:}
  line=${rest%%:*}
  inv=${rest#*:}

  # Tokens after `./buster-claw`, flags/placeholders excluded by the regex.
  read -r tok1 tok2 <<<"$(sed 's|.*\./buster-claw ||' <<<"$inv") "

  ok=0
  if [[ $tok1 == run ]]; then
    # `run <name>` — the name must be a real catalog command.
    [[ -n ${tok2:-} ]] && known_command "$tok2" && ok=1
  elif [[ -n ${tok2:-} ]] && known_verb "$tok1 $tok2"; then
    ok=1 # explicit two-word dispatch verb (dispatch claim, jobs show, ...)
  elif known_verb "$tok1"; then
    ok=1 # explicit one-word dispatch verb (on-duty, commands, help, ...)
  elif [[ -z ${tok2:-} ]] && known_family "$tok1"; then
    ok=1 # bare family mention in prose ("the ./buster-claw dispatch verbs")
  elif [[ -n ${tok2:-} ]] && known_command "${tok1}_${tok2}"; then
    ok=1 # generic noun-verb fallthrough (document list -> document_list)
  elif [[ -z ${tok2:-} ]] && known_command "$tok1"; then
    ok=1 # generic single-command fallthrough
  fi

  if [[ $ok -eq 0 ]]; then
    echo "DRIFT $file:$line: \`./buster-claw $tok1${tok2:+ $tok2}\` is not a CLI verb or catalog command" >&2
    fail=1
  fi
done < <(grep -rnoE '\./buster-claw +[a-z][a-z0-9_-]*( +[a-z][a-z0-9_-]*)?' "${DOCS[@]}")

if [[ $fail -ne 0 ]]; then
  echo "" >&2
  echo "Docs reference CLI verbs/commands that don't exist. Fix the doc (or the" >&2
  echo "dispatch table in lib/buster_claw/cli.ex if the verb was renamed)." >&2
  exit 1
fi

echo "docs drift check: OK (README, docs/, user-guide against CLI + catalog)"
