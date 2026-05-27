#!/usr/bin/env bash
# Smoke-test the command surface end-to-end. Requires `mix phx.server`
# (or the bundled release) to be running on :4000.
#
# Usage:
#   ./scripts/smoke_command_surface.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

URL="${BUSTER_CLAW_URL:-http://127.0.0.1:4000}"
TOKEN_FILE="$HOME/Library/Application Support/BusterClaw/api_token"
TOKEN="${BUSTER_CLAW_API_TOKEN:-}"

if [[ -z "$TOKEN" && -f "$TOKEN_FILE" ]]; then
  TOKEN="$(cat "$TOKEN_FILE")"
fi

if [[ -z "$TOKEN" ]]; then
  echo "error: no API token (set BUSTER_CLAW_API_TOKEN or create $TOKEN_FILE)" >&2
  exit 1
fi

pass() { echo "  pass: $1"; }
fail() { echo "  FAIL: $1" >&2; exit 1; }

REQUIRED_COMMANDS=(
  runtime_status
  source_list
  provider_active
  gmail_sync
  gmail_draft_create
  gmail_send
  google_calendar_sync
  chat_send
  web_search
)

assert_commands_present() {
  local body="$1"
  local label="$2"

  for command in "${REQUIRED_COMMANDS[@]}"; do
    echo "$body" | grep -q "\"name\":\"$command\"" \
      || fail "$label missing $command"
  done
}

echo "==> Phoenix server"
curl -fsS "$URL/_health" > /dev/null || fail "phx.server not reachable at $URL"
pass "_health responds"

echo "==> HTTP API"

CATALOG_BODY=$(curl -fsS "$URL/api/commands")
assert_commands_present "$CATALOG_BODY" "GET /api/commands"
pass "GET /api/commands includes representative commands"

UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$URL/api/run" \
  -H "Content-Type: application/json" \
  -d '{"command":"source_list"}')
[[ "$UNAUTH_CODE" == "401" ]] || fail "/api/run without auth returned $UNAUTH_CODE, expected 401"
pass "POST /api/run rejects unauthenticated"

STATUS_BODY=$(curl -fsS -X POST "$URL/api/run" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"command":"runtime_status"}')

echo "$STATUS_BODY" | grep -q '"ok":true' || fail "runtime_status didn't return ok:true"
echo "$STATUS_BODY" | grep -q '"app"' || fail "runtime_status missing app field"
pass "POST /api/run runtime_status works"

echo "==> CLI escript"

if [[ ! -x "$REPO_ROOT/buster-claw" ]]; then
  echo "  building escript..."
  mix escript.build > /dev/null
fi

COMMANDS_OUT=$(BUSTER_CLAW_API_TOKEN="$TOKEN" BUSTER_CLAW_URL="$URL" ./buster-claw commands)
for command in "${REQUIRED_COMMANDS[@]}"; do
  echo "$COMMANDS_OUT" | grep -q "$command" \
    || fail "./buster-claw commands missing $command"
done
pass "./buster-claw commands runs"

CLI_OUT=$(BUSTER_CLAW_API_TOKEN="$TOKEN" BUSTER_CLAW_URL="$URL" ./buster-claw run runtime_status)
echo "$CLI_OUT" | grep -q '"app":' || fail "./buster-claw run runtime_status missing app"
pass "./buster-claw run runtime_status works"

echo "==> MCP server"

INIT_BODY=$(curl -fsS -X POST "$URL/mcp" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","method":"initialize","id":1}')

echo "$INIT_BODY" | grep -q '"serverInfo"' || fail "MCP initialize missing serverInfo"
pass "POST /mcp initialize works"

TOOLS_BODY=$(curl -fsS -X POST "$URL/mcp" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":2}')

assert_commands_present "$TOOLS_BODY" "POST /mcp tools/list"
pass "POST /mcp tools/list includes representative commands"

CALL_BODY=$(curl -fsS -X POST "$URL/mcp" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","method":"tools/call","id":3,"params":{"name":"runtime_status","arguments":{}}}')

echo "$CALL_BODY" | grep -q '"isError":false' || fail "MCP tools/call runtime_status isError != false"
pass "POST /mcp tools/call runtime_status works"

echo ""
echo "==> All checks passed."
