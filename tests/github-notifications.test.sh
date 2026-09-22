#!/usr/bin/env bash
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
fail() { printf 'not ok - %s\n' "$*"; exit 1; }
ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$PASS" "$*"; }
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_LOG"
if [ "$1" = api ] && [ "$2" = --method ] && [ "$3" = PATCH ]; then
  thread=${4#notifications/threads/}
  if [ -n "${FAKE_PATCH_FAIL:-}" ] && [ -f "$FAKE_PATCH_FAIL" ] && grep -qx "$thread" "$FAKE_PATCH_FAIL"; then
    printf 'HTTP/2.0 500 Internal Server Error\r\n\r\n{"message":"fail"}'
    exit 1
  fi
  printf 'HTTP/2.0 200 OK\r\n\r\n{}'
  exit 0
fi
if [ "${*: -1}" = user ]; then
  jq -n --arg login "${FAKE_LOGIN:-me}" '{login:$login}'
  exit 0
fi
n=1
[ ! -f "$FAKE_COUNTER" ] || n=$(( $(cat "$FAKE_COUNTER") + 1 ))
printf '%s\n' "$n" > "$FAKE_COUNTER"
file="$FAKE_RESPONSES/$n.json"
[ -f "$file" ] || file="$FAKE_RESPONSES/default.json"
printf 'HTTP/2.0 200 OK\r\n'
printf 'Last-Modified: Wed, 01 Jan 2025 00:00:00 GMT\r\n'
printf 'X-Poll-Interval: %s\r\n' "${FAKE_POLL:-60}"
printf '\r\n'
cat "$file"
FAKE
chmod +x "$TMP/fakebin/gh"
export PATH="$TMP/fakebin:$PATH"
export OSS_MATE_FIRST_RUN_LOOKBACK_SECONDS=86400 OSS_MATE_MIN_POLL_SECONDS=60
export FAKE_LOG="$TMP/log" FAKE_COUNTER="$TMP/counter" FAKE_LOGIN=me
SCRIPT="$ROOT/bin/github-notifications"

reset_case() {
  rm -rf "$TMP/state" "$TMP/responses" "$TMP/counter" "$TMP/log"
  mkdir -p "$TMP/state" "$TMP/responses"
  export FAKE_RESPONSES="$TMP/responses"
}
notification() {
  jq -n --arg id "$1" --arg updated "$2" --arg repo "$3" --arg owner "$4" \
    --argjson private "$5" --arg title "$6" --arg body "$7" \
    '{id:$id,reason:"mention",updated_at:$updated,subject:{type:"Issue",title:$title,body:$body},repository:{private:$private,full_name:$repo,owner:{login:$owner}}}'
}
response() {
  jq -s '.' > "$1"
}
run_check() {
  OSS_MATE_NOW=$1 "$SCRIPT" --state-dir "$TMP/state" check
}

reset_case
notification 1 2025-01-01T00:00:00Z public/project public false 'Please review' 'SECRET-BODY' | response "$TMP/responses/1.json"
cp "$TMP/responses/1.json" "$TMP/responses/default.json"
out=$(run_check 2000000000)
[ "$out" = 'github notifications: external=1; excluded=0; run github-notifications pending' ] || fail 'first check did not wake'
out=$(OSS_MATE_NOW=2000000060 "$SCRIPT" --state-dir "$TMP/state" check)
[ -z "$out" ] || fail 'repeated thread was not silent'
[ "$(cat "$TMP/counter")" -eq 2 ] || fail 'repeat did not poll'
"$SCRIPT" --state-dir "$TMP/state" ack
[ -z "$("$SCRIPT" --state-dir "$TMP/state" pending)" ] || fail 'ack did not clear pending details'
[ "$(jq '.seen|length' "$TMP/state/github-notifications.json")" -eq 1 ] || fail 'ack changed the dedup boundary'
ok 'cursor idempotence, acknowledgment, and silent no-news check'

notification 1 2025-01-01T00:00:00Z public/project public false old ignored | response "$TMP/responses/1.json"
notification 1 2025-01-01T00:01:00Z public/project public false changed ignored | response "$TMP/responses/2.json"
rm -rf "$TMP/state"; mkdir "$TMP/state"; rm -f "$TMP/counter" "$TMP/log"
out=$(run_check 2000000000)
out=$(OSS_MATE_NOW=2000000060 "$SCRIPT" --state-dir "$TMP/state" check)
case "$out" in *'external=1'*) ;; *) fail 'updated thread in overlap was not surfaced' ;; esac
[ "$(jq '.seen|length' "$TMP/state/github-notifications.json")" -eq 2 ] || fail 'updated keys were not deduplicated by id and updated_at'
grep -q 'since=2033-05-17T21:33:20Z' "$TMP/log" || fail 'daily cursor overlap was not six hours'
ok 'six-hour overlapping cursor windows deduplicate exact thread versions'

reset_case
printf '[]\n' > "$TMP/responses/1.json"; cp "$TMP/responses/1.json" "$TMP/responses/default.json"
run_check 2000000000 >/dev/null
grep -q 'since=2033-05-17T03:33:20Z' "$TMP/log" || fail 'first run was not bounded to one day'
ok 'first run has a bounded lookback'

reset_case
{
  notification 10 2025-01-01T00:00:00Z secret/private secret-owner true 'PRIVATE-TITLE' 'PRIVATE-BODY'
  notification 11 2025-01-01T00:00:01Z acme/widgets acme false 'ACME-TITLE' 'ACME-BODY'
  notification 12 2025-01-01T00:00:02Z public/project public false 'PUBLIC-TITLE' 'PUBLIC-BODY'
} | response "$TMP/responses/1.json"
cp "$TMP/responses/1.json" "$TMP/responses/default.json"
out=$(run_check 2000000000)
pending=$($SCRIPT --state-dir "$TMP/state" pending)
all="$out $pending $(cat "$TMP/state/github-notifications.json")"
case "$all" in *PRIVATE-TITLE*|*PRIVATE-BODY*|*secret/private*|*secret-owner*) fail 'private details leaked' ;; esac
case "$all" in *ACME-BODY*|*PUBLIC-BODY*) fail 'notification body leaked' ;; esac
case "$pending" in *'repository=acme/widgets'*'ACME-TITLE'*'repository=public/project'*'PUBLIC-TITLE'*'excluded count=1'*) ;; *) fail 'redacted pending projection is wrong' ;; esac
ok 'private data and all bodies are absent from output and durable state'

reset_case
{
  notification 20 2025-01-01T00:00:00Z other/repo other false owned-owner ignored
  notification 21 2025-01-01T00:00:01Z listed/repo listed false owned-repo ignored
  notification 22 2025-01-01T00:00:02Z free/repo free false external ignored
} | response "$TMP/responses/1.json"
cp "$TMP/responses/1.json" "$TMP/responses/default.json"
printf '{"owners":["other"],"repositories":["listed/repo"]}\n' > "$TMP/config.json"
out=$(OSS_MATE_NOW=2000000000 "$SCRIPT" --state-dir "$TMP/state" --config "$TMP/config.json" check)
case "$out" in *'external=1; excluded=2'*) ;; *) fail 'configured routing partition is wrong' ;; esac
pending=$($SCRIPT --state-dir "$TMP/state" pending)
all="$pending $(cat "$TMP/state/github-notifications.json")"
case "$all" in *other/repo*|*listed/repo*|*owned-owner*|*owned-repo*) fail 'configured owned repository leaked' ;; esac
ok 'routing config adds owners and repositories to the excluded count'

reset_case
{
  notification 30 2025-01-01T00:00:00Z me/project me false new-pr ignored | jq '.reason="subscribed" | .subject.type="PullRequest"'
  notification 31 2025-01-01T00:00:01Z me/project me false new-issue ignored | jq '.reason="subscribed"'
  notification 32 2025-01-01T00:00:02Z watched/project watched false watched-pr ignored | jq '.reason="subscribed" | .subject.type="PullRequest"'
  notification 33 2025-01-01T00:00:03Z upstream/project upstream false pr-comment ignored | jq '.reason="comment" | .subject.type="PullRequest"'
  notification 34 2025-01-01T00:00:04Z upstream/project upstream false pr-merged ignored | jq '.reason="state_change" | .subject.type="PullRequest"'
} | response "$TMP/responses/1.json"
cp "$TMP/responses/1.json" "$TMP/responses/default.json"
out=$(run_check 2000000000)
case "$out" in *'external=4; excluded=0'*) ;; *) fail 'owned and participating coverage count is wrong' ;; esac
pending=$("$SCRIPT" --state-dir "$TMP/state" pending)
case "$pending" in *new-pr*new-issue*pr-comment*pr-merged*) ;; *) fail 'required owned and participating cases did not surface' ;; esac
case "$pending" in *watched-pr*|*watched/project*) fail 'non-owned subscribed thread surfaced' ;; esac
[ "$(jq '.seen|length' "$TMP/state/github-notifications.json")" -eq 5 ] || fail 'filtered subscribed thread did not advance dedup state'
if grep '/notifications' "$TMP/log" | grep -q 'participating=true'; then fail 'notifications request still used participating=true'; fi
ok 'owned-repository openings and participating PR updates surface without watched noise'

reset_case
{
  notification 40 2025-01-01T00:00:00Z public/build public false build-status ignored | jq '.reason="ci_activity"'
  notification 31 2025-01-01T00:00:01Z private/build private true secret-build ignored | jq '.reason="ci_activity"'
} | response "$TMP/responses/1.json"
cp "$TMP/responses/1.json" "$TMP/responses/default.json"
out=$(run_check 2000000000)
[ -z "$out" ] || fail 'ci_activity produced a check line'
[ -z "$("$SCRIPT" --state-dir "$TMP/state" pending)" ] || fail 'ci_activity entered pending output'
[ "$(jq '.seen|length' "$TMP/state/github-notifications.json")" -eq 2 ] || fail 'ci_activity did not advance dedup state'
[ "$(jq '(.external|length) + (.excluded|length)' "$TMP/state/github-notifications.json")" -eq 0 ] || fail 'ci_activity entered durable pending state'
ok 'ci_activity advances dedup state without surfacing'

reset_case
{
  notification 50 2025-01-01T00:00:00Z secret/private secret-owner true 'PRIVATE-TITLE' 'PRIVATE-BODY'
  notification 51 2025-01-01T00:00:01Z public/project public false 'PUBLIC-TITLE' 'PUBLIC-BODY'
} | response "$TMP/responses/1.json"
cp "$TMP/responses/1.json" "$TMP/responses/default.json"
run_check 2000000000 >/dev/null
[ "$(jq '[.excluded[].id] | index("50") != null' "$TMP/state/github-notifications.json")" = true ] \
  || fail 'excluded record did not retain thread id'
state=$(cat "$TMP/state/github-notifications.json")
case "$state" in *PRIVATE-TITLE*|*secret/private*|*secret-owner*) fail 'excluded id storage leaked private details' ;; esac
pending=$($SCRIPT --state-dir "$TMP/state" pending)
case "$pending" in *'excluded count=1'*) ;; *) fail 'excluded count line missing' ;; esac
case "$pending" in *50*) fail 'excluded thread id leaked in pending output' ;; esac
ok 'excluded records retain id without leaking private details'

reset_case
notification 60 2025-01-01T00:00:00Z public/project public false 'TITLE' ignored | response "$TMP/responses/1.json"
cp "$TMP/responses/1.json" "$TMP/responses/default.json"
run_check 2000000000 >/dev/null
"$SCRIPT" --state-dir "$TMP/state" check >/dev/null
"$SCRIPT" --state-dir "$TMP/state" pending >/dev/null
"$SCRIPT" --state-dir "$TMP/state" ack
"$SCRIPT" --state-dir "$TMP/state" show >/dev/null
grep -q -- '--method PATCH' "$TMP/log" && fail 'read-only verbs issued PATCH'
ok 'check, pending, show, and ack never PATCH GitHub'

reset_case
{
  notification 70 2025-01-01T00:00:00Z public/a public false 'A' ignored
  notification 71 2025-01-01T00:00:01Z public/b public false 'B' ignored
} | response "$TMP/responses/1.json"
cp "$TMP/responses/1.json" "$TMP/responses/default.json"
run_check 2000000000 >/dev/null
out=$("$SCRIPT" --state-dir "$TMP/state" mark-read)
[ "$out" = 'mark-read: would mark 2 threads read on GitHub' ] || fail 'dry-run count wrong'
grep -q -- '--method PATCH' "$TMP/log" && fail 'dry-run mark-read issued PATCH'
ok 'mark-read without --yes prints count and makes no mutating call'

reset_case
{
  notification 80 2025-01-01T00:00:00Z public/a public false 'A' ignored
  notification 81 2025-01-01T00:00:01Z secret/private secret true 'PRIVATE' ignored
} | response "$TMP/responses/1.json"
cp "$TMP/responses/1.json" "$TMP/responses/default.json"
run_check 2000000000 >/dev/null
out=$("$SCRIPT" --state-dir "$TMP/state" mark-read --yes)
[ "$out" = 'mark-read: marked=2 failed=0 remaining=0' ] || fail 'mark-read success summary wrong'
grep -c -- '--method PATCH notifications/threads/' "$TMP/log" | grep -qx 2 || fail 'mark-read did not PATCH both pending threads'
[ -z "$("$SCRIPT" --state-dir "$TMP/state" pending)" ] || fail 'mark-read did not clear pending'
ok 'mark-read with --yes PATCHes pending threads and clears local projection'

reset_case
{
  notification 90 2025-01-01T00:00:00Z public/a public false 'A' ignored
  notification 91 2025-01-01T00:00:01Z public/b public false 'B' ignored
  notification 92 2025-01-01T00:00:02Z public/c public false 'C' ignored
} | response "$TMP/responses/1.json"
cp "$TMP/responses/1.json" "$TMP/responses/default.json"
run_check 2000000000 >/dev/null
printf '91\n' > "$TMP/patch-fail"
export FAKE_PATCH_FAIL="$TMP/patch-fail"
set +e
out=$("$SCRIPT" --state-dir "$TMP/state" mark-read --yes 2>/dev/null)
status=$?
set -e
[ "$status" -ne 0 ] || fail 'mid-way failure did not exit nonzero'
[ "$out" = 'mark-read: marked=1 failed=1 remaining=2' ] || fail "partial failure summary wrong: $out"
pending=$("$SCRIPT" --state-dir "$TMP/state" pending)
case "$pending" in *'id=90'*) fail 'first success was not cleared locally' ;; esac
case "$pending" in *'id=91'*) ;; *) fail 'failed thread did not remain pending' ;; esac
case "$pending" in *'id=92'*) ;; *) fail 'unprocessed thread did not remain pending' ;; esac
rm -f "$TMP/patch-fail"
out=$("$SCRIPT" --state-dir "$TMP/state" mark-read --yes)
[ "$out" = 'mark-read: marked=2 failed=0 remaining=0' ] || fail 'resume summary wrong'
[ -z "$("$SCRIPT" --state-dir "$TMP/state" pending)" ] || fail 'resume did not clear remaining pending'
patch_count=$(grep -c -- '--method PATCH notifications/threads/' "$TMP/log" || true)
[ "$patch_count" -eq 4 ] || fail "resume did not PATCH only remaining threads: $patch_count"
ok 'partial mark-read failure resumes and PATCHes only remaining threads'

reset_case
printf '[]\n' > "$TMP/responses/default.json"
out=$(env -u OSS_MATE_MIN_POLL_SECONDS OSS_MATE_NOW=2000000000 "$SCRIPT" --state-dir "$TMP/state" check)
[ -z "$out" ] || fail 'empty daily poll was not silent'
out=$(env -u OSS_MATE_MIN_POLL_SECONDS OSS_MATE_NOW=2000086399 "$SCRIPT" --state-dir "$TMP/state" check)
[ -z "$out" ] || fail 'daily cadence gate printed output'
[ "$(cat "$TMP/counter")" -eq 1 ] || fail 'daily cadence gate made an API call'
env -u OSS_MATE_MIN_POLL_SECONDS OSS_MATE_NOW=2000086400 "$SCRIPT" --state-dir "$TMP/state" check >/dev/null
[ "$(cat "$TMP/counter")" -eq 2 ] || fail 'daily cadence did not poll when the gate opened'
ok 'default daily cadence is silent and makes no early API call'

reset_case
printf '[]\n' > "$TMP/responses/default.json"
FAKE_POLL=90 run_check 2000000000 >/dev/null
OSS_MATE_NOW=2000000089 "$SCRIPT" --state-dir "$TMP/state" check >/dev/null
[ "$(cat "$TMP/counter")" -eq 1 ] || fail 'poll interval was not respected'
OSS_MATE_NOW=2000000090 "$SCRIPT" --state-dir "$TMP/state" check >/dev/null
[ "$(cat "$TMP/counter")" -eq 2 ] || fail 'poll did not resume at interval'
ok 'X-Poll-Interval gates API reads'

printf '1..%s\n' "$PASS"
