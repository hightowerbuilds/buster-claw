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
  'BusterClaw.Commands.Catalog.entries() |> Enum.each(fn entry -> IO.puts("__BUSTER_CLAW_COMMAND__" <> entry.name) end)' |
  sed -n 's/^__BUSTER_CLAW_COMMAND__//p')

# --- source of truth 2: CLI dispatch verbs ----------------------------------
# Route heads like `defp route(["dispatch", "claim" | rest], opts)` /
# `defp route(["on-duty"], opts)` become "dispatch claim" / "on-duty".
VERBS=$(grep -oE 'defp route\(\["[a-z-]+"(, "[a-z-]+")?' lib/buster_claw/cli.ex |
  sed 's/.*\["//; s/", "/ /; s/"//g')

# A broken extraction must fail loudly: an empty verb list once aborted this
# script silently (via set -e) after the dispatch table was refactored, and the
# whole gate rotted unnoticed.
if [[ -z $VERBS ]]; then
  echo "check_docs_drift: extracted zero CLI verbs from lib/buster_claw/cli.ex — dispatch table moved?" >&2
  exit 1
fi

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

# --- source of truth 3: where the API token actually lives -------------------
# The desktop shell keeps the token in the macOS Keychain and DELETES any
# plaintext copy once it has migrated the value (`ensure_secret`, main.rs), and
# dev uses a literal from config/dev.exs. Nothing writes a token file. From the
# move to the Keychain until 2026-08-02 the README nonetheless told users to
# `cat` one, which is a recipe that cannot work on any current install — a
# broken front door that no test could see, because it was prose.
# Matched on the trailing path segment, not the full path: the README's own
# version escaped the space (`Application\ Support/...`), so a pattern anchored
# on "Application Support" sailed straight past the very line it was written to
# catch. Verified by re-adding that line and watching this fail.
if grep -rnE 'BusterClaw/api_token|buster_claw/api_token' "${DOCS[@]}" >&2; then
  echo "" >&2
  echo "A live doc points at an api_token FILE. There isn't one: the packaged" >&2
  echo "shell stores the token in the Keychain (service BusterClaw, account" >&2
  echo "api_token) and deletes any plaintext copy; dev uses the literal in" >&2
  echo "config/dev.exs. Document one of those instead." >&2
  exit 1
fi

# --- source of truth 4: how many commands there actually are -----------------
# Every "N commands" in a live doc must equal the real catalog size. This is a
# number that cannot be maintained by hand: three sessions add commands to the
# catalog concurrently, and nobody adding one thinks to grep the prose for a
# count. It has been wrong twice — the README said 191 and busterclaw.lol said
# ~160 on 2026-08-10, against a real catalog of 203.
#
# Unlike the checks above, a failure here is usually the DOC being stale rather
# than the code being wrong, so the message says which number to change.
CATALOG_COUNT=$(wc -l <<<"$CATALOG" | tr -d ' ')
count_fail=0
while IFS= read -r hit; do
  file=${hit%%:*}
  rest=${hit#*:}
  line=${rest%%:*}
  stated=$(grep -oE '[0-9]+' <<<"${rest#*:}" | head -1)
  if [[ $stated != "$CATALOG_COUNT" ]]; then
    echo "DRIFT $file:$line: says $stated commands; the catalog has $CATALOG_COUNT" >&2
    count_fail=1
  fi
done < <(grep -rnoE '[0-9]+ commands' "${DOCS[@]}" || true)

if [[ $count_fail -ne 0 ]]; then
  echo "" >&2
  echo "A live doc states a command count that no longer matches the catalog." >&2
  echo "The catalog is the source of truth ($CATALOG_COUNT); update the prose." >&2
  echo "NOTE: busterclaw.lol states this number too and is NOT covered by this" >&2
  echo "gate — it lives in another repository. Update it by hand." >&2
  exit 1
fi

echo "docs drift check: OK (README, docs/, user-guide against CLI + catalog + token source + $CATALOG_COUNT commands)"
