#!/bin/zsh
# Records a take of the droplet on the real notch, for the README.
#
# Starts four sessions on this Mac's OpenChamber in ~/projects/personal/droplet-demo
# and records the whole display:
#   "Grabando"  three long sessions are already reading and editing: hover the notch
#   "Fuera"     move the pointer away; a session asks to run `pnpm test`
#               answer the card with Allow once; its Done card follows
# Writes shots/takes/take-<time>.openscreen (OpenScreen's project) and take-<time>.mov
# (ffmpeg's copy), then stops and deletes the sessions.
#
#   scripts/demo-take.sh [seconds]     about 35 s to get ready before "Grabando"
#   FORCE=1 records even with other sessions running
#
# Needs OpenChamber Desktop's local server, OpenScreen in /Applications, ffmpeg and jq, and
# the demo project: a small git repo whose date tests fail in a timezone behind UTC. Nothing
# else should be running, here or on a remote host, or its rows and cards land in the take.
# docs/images/demo.gif is ffmpeg's copy cut to 1100x640 around the notch, waits sped up.
set -euo pipefail

DEMO=$HOME/projects/personal/droplet-demo
TAKES=${0:A:h:h}/shots/takes
SETTINGS=$HOME/.config/openchamber/settings.json
API="http://127.0.0.1:$(jq -r .desktopLocalPort $SETTINGS)/api"
TOKEN=$(jq -r .desktopLocalClientToken $SETTINGS)
DIR_HEADER=$(jq -rn --arg d $DEMO '$d|@uri')
# Opus at xhigh thinks for the whole take; OpenAI's model reads and edits, so its rows
# narrate; Sonnet asks quickly. A fourth claude-code session stalls the others.
SLOW='{"id":"claude-opus-5-5[1m]","providerID":"claude-code","variant":"xhigh"}'
FAST='{"id":"claude-sonnet-5-5","providerID":"claude-code","variant":"medium"}'
OTHER='{"id":"gpt-6.1-sol","providerID":"openai"}'
OPENSCREEN=/Applications/Openscreen.app/Contents/MacOS/Openscreen
WARM=${WARM:-25}
LENGTH=${1:-35}
HOVER=${HOVER:-8}
sessions=()

api() {
  curl -fsS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -H "x-opencode-directory: $DIR_HEADER" "$@"
}

# session <title> <model> <ask|auto>: OpenChamber answers every request of an `auto` session itself.
session() {
  local id effect=allow
  [[ $3 == ask ]] && effect=ask
  id=$(api -X POST "$API/session" -d "$(jq -n --arg t $1 --arg d $DEMO --arg e $effect --argjson m $2 \
    '{title: $t, agent: "build", model: $m, location: {directory: $d}, permissions: [{action: "shell", resource: "*", effect: $e}]}')" \
    | jq -r .data.id)
  api -o /dev/null -X PUT "$API/permission-auto-accept/sessions/$id" -d "$(jq -n --arg m $3 --arg d $DEMO '{mode: $m, directory: $d}')"
  sessions+=($id)
  REPLY=$id
}

prompt() {
  api -o /dev/null -X POST "$API/session/$1/prompt" -d "$(jq -n --arg t $2 '{text: $t}')"
}

# Once the first request is answered, the session runs its later commands without
# asking, so no second card lands in the middle of the take.
allow_after_first_answer() {
  trap - EXIT
  local seen=
  for _ in {1..240}; do
    sleep 0.5
    if api "$API/sessions/status" | jq -e --arg id $1 \
      '[.pending | .. | objects | select(.sessionID? == $id and has("action"))] | length > 0' >/dev/null; then
      seen=1
    elif [[ -n $seen ]]; then
      api -o /dev/null -X PATCH "$API/session/$1" -d '{"permissions": [{"action": "shell", "resource": "*", "effect": "allow"}]}'
      return
    fi
  done
}

cleanup() {
  kill ${watcher:-} 2>/dev/null || true
  for id in $sessions; do
    api -o /dev/null -X POST "$API/session/$id/interrupt" || true
  done
  sleep 2
  for id in $sessions; do
    api -o /dev/null -X DELETE "$API/session/$id" || true
  done
  git -C $DEMO reset -q --hard && git -C $DEMO clean -qfd
}
trap cleanup EXIT

mkdir -p $TAKES
git -C $DEMO reset -q --hard && git -C $DEMO clean -qfd

# Give the session that launched this time to end its turn before counting.
sleep 8
running=$(api "$API/session/active" | jq '.data | length')
if (( running > 0 )) && [[ -z ${FORCE:-} ]]; then
  say "Hay $running sesiones corriendo. Cancelo."
  exit 1
fi

session "Plan the config file" $SLOW auto; config=$REPLY
session "Add retries to the HTTP client" $OTHER auto; retries=$REPLY
session "Write the README" $OTHER auto; readme=$REPLY
session "Fix the flaky date test" $FAST ask; datetest=$REPLY
prompt $config 'Read every file in src/ and test/. Then design a config file for this CLI (default city, units, cache TTL, request timeout): weigh JSON, TOML and environment variables, pick one, and write the plan with an example file and a migration note to docs/config.md. Do not run any commands.'
# The OpenAI sessions are quicker, so they start 10 s before the take and are past their
# first thought, reading files, when it begins, and still working when it ends.
sleep $(( WARM - 10 ))
prompt $retries 'Read src/http.ts, src/geocode.ts, src/forecast.ts and src/cli.ts, one at a time. Then add retry with exponential backoff and jitter to fetchJson in src/http.ts (three attempts, retrying on 5xx responses and network errors), thread a `retries` option through the other three files one at a time, add JSDoc to every exported function in src/, and add tests for the retry in test/http.test.ts. Do not run any commands.'
prompt $readme 'Read every file in src/ and test/, one at a time. Then write README.md (what the CLI does, install, usage with an example for every flag, how caching works, how to run the tests), then docs/architecture.md with a section per module, then a short usage comment at the top of every file in src/. Do not run any commands.'
sleep 10

# OpenScreen records the pointer as data, for a smoothed cursor in its export; ffmpeg keeps
# a plain copy in case OpenScreen's take is unusable.
take=$TAKES/take-$(date +%H%M%S)
$OPENSCREEN record --display 0 --duration $LENGTH --project $take.openscreen --json > $take.ndjson 2>/dev/null &
recorder=$!
ffmpeg -hide_banner -loglevel error -f avfoundation -framerate 30 -capture_cursor 1 -i "Capture screen 0:none" \
  -t $LENGTH -c:v h264_videotoolbox -b:v 24M $take.mov 2>/dev/null &
backup=$!
for _ in {1..50}; do
  grep -q '"Recording started"' $take.ndjson && break
  sleep 0.2
done
say "Grabando"

sleep $HOVER
say "Fuera"
sleep 1
prompt $datetest 'Run `pnpm test` on its own first, with no pipes or other commands. Then find why the date tests fail and fix src/format.ts.'
allow_after_first_answer $datetest &
watcher=$!

wait $recorder $backup
say "Listo"
echo $take.openscreen
