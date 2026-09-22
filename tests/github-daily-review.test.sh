#!/usr/bin/env bash
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
fail() { printf 'not ok - %s\n' "$*"; exit 1; }
ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$PASS" "$*"; }
mkdir -p "$TMP/fakebin" "$TMP/responses" "$TMP/state"

cat > "$TMP/fakebin/date" <<'DATE'
#!/usr/bin/env bash
if [ "$1" = +%s ] && [ -f "${FAKE_DATE_FILE:-}" ]; then
  cat "$FAKE_DATE_FILE"
  exit 0
fi
exec /bin/date "$@"
DATE
chmod +x "$TMP/fakebin/date"

cat > "$TMP/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_LOG"
ORIG=("$@")
METHOD=GET
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method) METHOD=$2; shift 2 ;;
    -f|-F) shift 2 ;;
    -i) shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
if [ "$METHOD" = PATCH ]; then
  ENDPOINT=${ARGS[${#ARGS[@]}-1]:-}
  thread=${ENDPOINT#notifications/threads/}
  printf 'PATCH %s\n' "$ENDPOINT" >> "$FAKE_MUTATIONS"
  if [ -n "${FAKE_PATCH_FAIL:-}" ] && [ -f "$FAKE_PATCH_FAIL" ] && grep -qx "$thread" "$FAKE_PATCH_FAIL"; then
    printf '{"message":"fail"}\n'
    exit 1
  fi
  printf '{}\n'
  exit 0
fi
step_clock() {
  if [ -n "${FAKE_DATE_FILE:-}" ] && [ -n "${FAKE_DATE_STEP:-}" ]; then
    now=$(cat "$FAKE_DATE_FILE")
    printf '%s' "$((now + FAKE_DATE_STEP))" > "$FAKE_DATE_FILE"
  fi
}
is_graphql=0
for arg in ${ARGS[@]+"${ARGS[@]}"}; do
  [ "$arg" = graphql ] && is_graphql=1
done
if [ "$is_graphql" -eq 1 ]; then
  step_clock
  if [ -n "${FAKE_GRAPHQL_FAIL:-}" ]; then
    printf 'graphql unavailable\n' >&2
    exit 1
  fi
  query=
  i=0
  while [ "$i" -lt "${#ORIG[@]}" ]; do
    case "${ORIG[$i]}" in
      -f) val=${ORIG[$((i + 1))]}; case "$val" in query=*) query=${val#query=} ;; esac; i=$((i + 2)) ;;
      *) i=$((i + 1)) ;;
    esac
  done
  : > "$FAKE_NODE_TMP"
  for id in $(printf '%s' "$query" | grep -o '"[A-Za-z0-9_=+/:.-]*"' | tr -d '"'); do
    file="$FAKE_RESPONSES/node-$id.json"
    [ -f "$file" ] || continue
    cat "$file" >> "$FAKE_NODE_TMP"
  done
  jq -s '{data:{nodes:.}}' "$FAKE_NODE_TMP"
  exit 0
fi
ENDPOINT=${ARGS[${#ARGS[@]}-1]:-}
if [ "$ENDPOINT" = user ]; then
  jq -n --arg login "${FAKE_LOGIN:-me}" '{login:$login}'
  exit 0
fi
case "$ENDPOINT" in
  /search/issues*)
    step_clock
    if printf '%s' "$ENDPOINT" | grep -q 'is%3Aissue'; then
      file="$FAKE_RESPONSES/search-new-issues.json"
    elif printf '%s' "$ENDPOINT" | grep -q 'author%3A' && printf '%s' "$ENDPOINT" | grep -q -- '-user%3A'; then
      file="$FAKE_RESPONSES/search-my-prs.json"
    else
      file="$FAKE_RESPONSES/search-new-prs.json"
    fi
    [ -f "$file" ] || file="$FAKE_RESPONSES/search-empty.json"
    cat "$file"
    exit 0
    ;;
  /notifications*)
    file="$FAKE_RESPONSES/notifications.json"
    [ -f "$file" ] || file="$FAKE_RESPONSES/notifications-empty.json"
    printf 'HTTP/2.0 200 OK\r\n'
    printf 'X-Poll-Interval: %s\r\n' "${FAKE_POLL:-60}"
    printf '\r\n'
    cat "$file"
    exit 0
    ;;
esac
if [[ "$ENDPOINT" =~ ^repos/[^/]+/[^/]+/issues/[0-9]+$ ]]; then
  repo=${ENDPOINT#repos/}
  repo=${repo%/issues/*}
  num=${ENDPOINT##*/}
  file="$FAKE_RESPONSES/issue-${repo//\//-}-$num.json"
  [ -f "$file" ] || { printf 'no issue fixture: %s\n' "$ENDPOINT" >&2; exit 1; }
  cat "$file"
  exit 0
fi
if [[ "$ENDPOINT" =~ ^repos/[^/]+/[^/]+/pulls/[0-9]+$ ]]; then
  repo=${ENDPOINT#repos/}
  repo=${repo%/pulls/*}
  num=${ENDPOINT##*/}
  file="$FAKE_RESPONSES/pull-${repo//\//-}-$num.json"
  [ -f "$file" ] || { printf 'no pull fixture: %s\n' "$ENDPOINT" >&2; exit 1; }
  cat "$file"
  exit 0
fi
printf 'unknown endpoint: %s\n' "$ENDPOINT" >&2
exit 1
FAKE
chmod +x "$TMP/fakebin/gh"

export PATH="$TMP/fakebin:$PATH"
export OSS_MATE_MIN_POLL_SECONDS=60
export FAKE_LOG="$TMP/log" FAKE_MUTATIONS="$TMP/mutations" FAKE_LOGIN=me
export FAKE_RESPONSES="$TMP/responses" FAKE_NODE_TMP="$TMP/nodes-tmp"
SCRIPT="$ROOT/bin/github-daily-review"

# Fixture builders. search_item mirrors the GitHub search item fields the script reads.
search_item() {
  jq -n --argjson number "$1" --arg repo "$2" --arg node "$3" \
    '{number:$number,node_id:$node,repository_url:("https://api.github.com/repos/" + $repo)}'
}
search_page() { jq -s --argjson total "$1" '{total_count:$total,items:.}'; }
issue_node() {
  jq -n --arg id "$1" --argjson number "$2" --arg repo "$3" --arg title "$4" \
    --arg created "$5" --arg author "$6" --argjson private "${7:-false}" \
    '{__typename:"Issue",id:$id,number:$number,title:$title,createdAt:$created,updatedAt:$created,
      author:{login:$author},
      repository:{nameWithOwner:$repo,isPrivate:$private,owner:{login:($repo|split("/")[0])}}}'
}
pr_node() {
  jq -n --arg id "$1" --argjson number "$2" --arg repo "$3" --arg title "$4" \
    --arg created "$5" --arg author "$6" --argjson private "${7:-false}" \
    '{__typename:"PullRequest",id:$id,number:$number,title:$title,createdAt:$created,updatedAt:$created,
      author:{login:$author},
      repository:{nameWithOwner:$repo,isPrivate:$private,owner:{login:($repo|split("/")[0])}}}'
}
mine_node() {
  jq -n --arg id "$1" --argjson number "$2" --arg repo "$3" --arg title "$4" \
    --arg updated "$5" --arg mergeable "$6" --arg review "${7:-}" --arg checks "${8:-SUCCESS}" \
    --argjson private "${9:-false}" \
    '{__typename:"PullRequest",id:$id,number:$number,title:$title,createdAt:"2024-01-01T00:00:00Z",
      updatedAt:$updated,mergeable:$mergeable,
      reviewDecision:(if $review=="" then null else $review end),
      author:{login:"me"},
      repository:{nameWithOwner:$repo,isPrivate:$private,owner:{login:($repo|split("/")[0])}},
      commits:{nodes:[{commit:{statusCheckRollup:{state:$checks}}}]}}'
}
notification() {
  jq -n --arg id "$1" --arg updated "$2" --arg repo "$3" --argjson private "$4" \
    --arg reason "$5" --arg type "$6" --arg url "$7" --arg title "$8" \
    '{id:$id,reason:$reason,updated_at:$updated,
      subject:{type:$type,title:$title,url:$url},
      repository:{private:$private,full_name:$repo,owner:{login:($repo|split("/")[0])}}}'
}
pull_fixture() {
  jq -n --argjson number "$1" --arg repo "$2" --arg author "$3" --arg title "$4" \
    --argjson mergeable "$5" --arg state "${6:-open}" \
    '{number:$number,state:$state,mergeable:$mergeable,title:$title,user:{login:$author},
      base:{repo:{full_name:$repo,private:false}}}'
}

reset_case() {
  rm -rf "$TMP/state" "$TMP/responses"
  rm -f "$TMP/log" "$TMP/mutations" "$TMP/fake-date" "$TMP/patch-fail"
  mkdir -p "$TMP/state" "$TMP/responses"
  : > "$TMP/log"
  : > "$TMP/mutations"
  printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-empty.json"
  printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-new-issues.json"
  printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-new-prs.json"
  printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-my-prs.json"
  printf '[]\n' > "$TMP/responses/notifications.json"
  printf '[]\n' > "$TMP/responses/notifications-empty.json"
  unset FAKE_DATE_FILE FAKE_DATE_STEP FAKE_GRAPHQL_FAIL FAKE_PATCH_FAIL || true
}
run_check() { OSS_MATE_NOW=$1 "$SCRIPT" --state-dir "$TMP/state" check; }
run_pending() { "$SCRIPT" --state-dir "$TMP/state" pending; }

# --- all three sets populated and grouped -----------------------------------
reset_case
search_item 5 me/owned I_a | search_page 1 > "$TMP/responses/search-new-issues.json"
search_item 6 me/owned PR_b | search_page 1 > "$TMP/responses/search-new-prs.json"
{ search_item 10 public/upstream PR_c; search_item 11 public/other PR_d; } \
  | search_page 2 > "$TMP/responses/search-my-prs.json"
issue_node I_a 5 me/owned 'Owned issue' '2033-05-17T12:00:00Z' someone > "$TMP/responses/node-I_a.json"
pr_node PR_b 6 me/owned 'Owned pull request' '2033-05-17T12:00:00Z' someone > "$TMP/responses/node-PR_b.json"
mine_node PR_c 10 public/upstream 'My stale PR' '2025-06-02T00:00:00Z' CONFLICTING > "$TMP/responses/node-PR_c.json"
mine_node PR_d 11 public/other 'My healthy PR' '2025-06-02T00:00:00Z' MERGEABLE > "$TMP/responses/node-PR_d.json"
out=$(run_check 2000000000)
[ "$out" = 'github daily review: new-issues=1 new-prs=1 my-prs=2 (action=1 stale=1) excluded=0; run github-daily-review pending' ] \
  || fail "three-set check line is wrong: $out"
pending=$(run_pending)
case "$pending" in *'new-issue repository=me/owned number=5 author=other'*) ;; *) fail "set 1 line is wrong: $pending" ;; esac
case "$pending" in *'new-pr repository=me/owned number=6 author=other'*) ;; *) fail "set 2 line is wrong: $pending" ;; esac
case "$pending" in *'my-pr repository=public/upstream number=10 mergeability=stale action=stale'*) ;; *) fail "set 3 stale line is wrong: $pending" ;; esac
case "$pending" in *'my-pr repository=public/other number=11 mergeability=mergeable title='*) ;; *) fail "set 3 non-stale line is wrong: $pending" ;; esac
first=$(printf '%s\n' "$pending" | head -1)
last=$(printf '%s\n' "$pending" | tail -1)
case "$first" in new-issue*) ;; *) fail "sets are not grouped in order: $first" ;; esac
case "$last" in my-pr*) ;; *) fail "sets are not grouped in order: $last" ;; esac
[ ! -s "$TMP/mutations" ] || fail 'check or pending made a mutating API call'
ok 'all three sets populate, group in order, and set 3 keeps non-stale pull requests'

# --- own-repo pull requests never enter set 3 -------------------------------
reset_case
{ search_item 10 public/upstream PR_c; search_item 12 me/ownrepo PR_own; } \
  | search_page 2 > "$TMP/responses/search-my-prs.json"
mine_node PR_c 10 public/upstream 'My PR' '2025-06-02T00:00:00Z' MERGEABLE > "$TMP/responses/node-PR_c.json"
mine_node PR_own 12 me/ownrepo 'Own repo PR' '2025-06-02T00:00:00Z' MERGEABLE > "$TMP/responses/node-PR_own.json"
run_check 2000000000 >/dev/null
pending=$(run_pending)
case "$pending" in *me/ownrepo*|*'Own repo PR'*) fail "own-repo authored pull request leaked into set 3: $pending" ;; esac
case "$pending" in *'number=10'*) ;; *) fail "external authored pull request missing from set 3: $pending" ;; esac
ok 'set 3 excludes pull requests in repositories the user owns'

# --- owned-repo sets respect the reported boundary and ack advances it ------
reset_case
search_item 5 me/owned I_a | search_page 1 > "$TMP/responses/search-new-issues.json"
issue_node I_a 5 me/owned 'First issue' '2033-05-17T12:00:00Z' someone > "$TMP/responses/node-I_a.json"
run_check 2000000000 >/dev/null
"$SCRIPT" --state-dir "$TMP/state" ack
[ "$(jq -r '.reported_at' "$TMP/state/github-daily-review.json")" = '2033-05-18T03:33:20Z' ] \
  || fail 'ack did not advance the reported boundary'
{ search_item 5 me/owned I_a; search_item 7 me/owned I_new; } \
  | search_page 2 > "$TMP/responses/search-new-issues.json"
issue_node I_new 7 me/owned 'Second issue' '2033-05-19T00:00:00Z' someone > "$TMP/responses/node-I_new.json"
out=$(run_check 2000000061)
case "$out" in *'new-issues=1'*) ;; *) fail "boundary did not limit the second review: $out" ;; esac
pending=$(run_pending)
case "$pending" in *'number=7'*) ;; *) fail "newer issue missing after ack: $pending" ;; esac
case "$pending" in *'number=5'*) fail "already reported issue reappeared after ack: $pending" ;; esac
ok 'owned-repo sets report only items newer than the last reported review and ack advances the boundary'

# --- repeated check before ack re-includes unreported work ------------------
reset_case
search_item 5 me/owned I_a | search_page 1 > "$TMP/responses/search-new-issues.json"
issue_node I_a 5 me/owned 'Unacked issue' '2033-05-17T12:00:00Z' someone > "$TMP/responses/node-I_a.json"
run_check 2000000000 >/dev/null
out=$(run_check 2000000061)
case "$out" in *'new-issues=1'*) ;; *) fail "unacked item was dropped by a second check: $out" ;; esac
ok 'a second check before ack still reports work that was never acknowledged'

# --- action indicators ------------------------------------------------------
reset_case
{ search_item 20 public/a PR_stale; search_item 21 public/b PR_cr; search_item 22 public/c PR_ck; } \
  | search_page 3 > "$TMP/responses/search-my-prs.json"
mine_node PR_stale 20 public/a 'Stale' '2025-06-02T00:00:00Z' CONFLICTING > "$TMP/responses/node-PR_stale.json"
mine_node PR_cr 21 public/b 'Changes' '2025-06-02T00:00:00Z' MERGEABLE CHANGES_REQUESTED > "$TMP/responses/node-PR_cr.json"
mine_node PR_ck 22 public/c 'Checks' '2025-06-02T00:00:00Z' MERGEABLE '' FAILURE > "$TMP/responses/node-PR_ck.json"
run_check 2000000000 >/dev/null
pending=$(run_pending)
case "$pending" in *'number=20 mergeability=stale action=stale'*) ;; *) fail "stale action is wrong: $pending" ;; esac
case "$pending" in *'number=21 mergeability=mergeable action=changes-requested'*) ;; *) fail "changes-requested action is wrong: $pending" ;; esac
case "$pending" in *'number=22 mergeability=mergeable action=checks-failing'*) ;; *) fail "checks-failing action is wrong: $pending" ;; esac
ok 'stale, changes-requested, and checks-failing indicators come from batched pull request detail'

# --- new-activity is judged against the last reported review ----------------
reset_case
search_item 30 public/a PR_act | search_page 1 > "$TMP/responses/search-my-prs.json"
mine_node PR_act 30 public/a 'Quiet' '2033-05-17T00:00:00Z' MERGEABLE > "$TMP/responses/node-PR_act.json"
run_check 2000000000 >/dev/null
pending=$(run_pending)
case "$pending" in *action=*) fail "first review flagged new-activity with no prior boundary: $pending" ;; esac
"$SCRIPT" --state-dir "$TMP/state" ack
run_check 2000000061 >/dev/null
pending=$(run_pending)
case "$pending" in *action=*) fail "unchanged pull request was flagged new-activity: $pending" ;; esac
mine_node PR_act 30 public/a 'Quiet' '2033-05-18T00:00:00Z' MERGEABLE > "$TMP/responses/node-PR_act.json"
"$SCRIPT" --state-dir "$TMP/state" ack
run_check 2000000122 >/dev/null
pending=$(run_pending)
case "$pending" in *'action=new-activity'*) ;; *) fail "new-activity was not detected: $pending" ;; esac
ok 'new-activity flags a pull request updated since the last successfully reported review'

# --- notification and search evidence dedup ---------------------------------
reset_case
search_item 5 me/owned I_a | search_page 1 > "$TMP/responses/search-new-issues.json"
issue_node I_a 5 me/owned 'Shared issue' '2033-05-17T12:00:00Z' someone > "$TMP/responses/node-I_a.json"
{
  notification t1 2033-05-17T12:00:00Z me/owned false subscribed Issue \
    https://api.github.com/repos/me/owned/issues/5 'Shared issue'
} | jq -s '.' > "$TMP/responses/notifications.json"
out=$(run_check 2000000000)
case "$out" in *'new-issues=1'*) ;; *) fail "item in both sources was not reported once: $out" ;; esac
[ "$(run_pending | grep -c 'number=5')" -eq 1 ] || fail 'item in both sources was reported twice'
[ "$(jq -r '.pending.threads | length' "$TMP/state/github-daily-review.json")" -eq 1 ] \
  || fail 'notification thread id was not recorded once'
ok 'an item present in both notification and search evidence is reported exactly once'

# --- notification-only arrival signal still surfaces ------------------------
reset_case
{
  notification t2 2033-05-17T12:00:00Z me/owned false subscribed Issue \
    https://api.github.com/repos/me/owned/issues/9 'Lagging issue'
} | jq -s '.' > "$TMP/responses/notifications.json"
jq -n '{number:9,title:"Lagging issue",created_at:"2033-05-17T12:00:00Z",updated_at:"2033-05-17T12:00:00Z",user:{login:"someone"}}' \
  > "$TMP/responses/issue-me-owned-9.json"
out=$(run_check 2000000000)
case "$out" in *'new-issues=1'*) ;; *) fail "notification-only arrival signal was lost: $out" ;; esac
case "$(run_pending)" in *'number=9'*) ;; *) fail 'notification-only item missing from pending' ;; esac
ok 'a notification arrival signal the search inventory missed still reaches the review'

# --- ci_activity never surfaces --------------------------------------------
reset_case
{
  notification t3 2033-05-17T12:00:00Z me/owned false ci_activity PullRequest \
    https://api.github.com/repos/me/owned/pulls/3 'Build failed'
} | jq -s '.' > "$TMP/responses/notifications.json"
out=$(run_check 2000000000)
[ -z "$out" ] || fail "ci_activity produced a check line: $out"
[ -z "$(run_pending)" ] || fail 'ci_activity entered pending output'
[ "$(jq -r '.pending.threads | length' "$TMP/state/github-daily-review.json")" -eq 0 ] \
  || fail 'ci_activity thread entered the pending review'
[ "$(jq -r '.notification_seen | length' "$TMP/state/github-daily-review.json")" -eq 1 ] \
  || fail 'ci_activity did not advance the dedup set'
ok 'ci_activity advances the dedup set without surfacing'

# --- private and excluded repositories are counts only ----------------------
reset_case
{ search_item 5 me/owned I_a; search_item 8 me/secret I_p; } \
  | search_page 2 > "$TMP/responses/search-new-issues.json"
{ search_item 10 public/upstream PR_c; search_item 13 secret/hidden PR_p; search_item 14 listed/repo PR_l; } \
  | search_page 3 > "$TMP/responses/search-my-prs.json"
issue_node I_a 5 me/owned 'Owned issue' '2033-05-17T12:00:00Z' someone > "$TMP/responses/node-I_a.json"
issue_node I_p 8 me/secret 'PRIVATE-ISSUE-TITLE' '2033-05-17T12:00:00Z' someone true > "$TMP/responses/node-I_p.json"
mine_node PR_c 10 public/upstream 'My PR' '2025-06-02T00:00:00Z' MERGEABLE > "$TMP/responses/node-PR_c.json"
mine_node PR_p 13 secret/hidden 'PRIVATE-PR-TITLE' '2025-06-02T00:00:00Z' MERGEABLE '' SUCCESS true > "$TMP/responses/node-PR_p.json"
mine_node PR_l 14 listed/repo 'LISTED-PR-TITLE' '2025-06-02T00:00:00Z' MERGEABLE > "$TMP/responses/node-PR_l.json"
printf '{"owners":[],"repositories":["listed/repo"]}\n' > "$TMP/config.json"
out=$(OSS_MATE_NOW=2000000000 "$SCRIPT" --state-dir "$TMP/state" --config "$TMP/config.json" check)
case "$out" in *'new-issues=1'*'my-prs=1'*'excluded=3'*) ;; *) fail "excluded counts are wrong: $out" ;; esac
pending=$("$SCRIPT" --state-dir "$TMP/state" pending)
case "$pending" in *'new-issues excluded count=1'*) ;; *) fail "set 1 excluded count line missing: $pending" ;; esac
case "$pending" in *'my-prs excluded count=2'*) ;; *) fail "set 3 excluded count line missing: $pending" ;; esac
all="$out $pending $(cat "$TMP/state/github-daily-review.json")"
case "$all" in *PRIVATE-ISSUE-TITLE*|*PRIVATE-PR-TITLE*|*LISTED-PR-TITLE*) fail 'a hidden title leaked' ;; esac
case "$all" in *me/secret*|*secret/hidden*|*listed/repo*) fail 'a hidden repository name leaked' ;; esac
ok 'private and config-excluded repositories are counts only, with no name or title in output or state'

# --- gate silence -----------------------------------------------------------
reset_case
search_item 10 public/upstream PR_c | search_page 1 > "$TMP/responses/search-my-prs.json"
mine_node PR_c 10 public/upstream 'My PR' '2025-06-02T00:00:00Z' MERGEABLE > "$TMP/responses/node-PR_c.json"
run_check 2000000000 >/dev/null
log_lines=$(wc -l < "$TMP/log")
out=$(run_check 2000000030)
[ -z "$out" ] || fail "gated check was not silent: $out"
[ "$(wc -l < "$TMP/log")" -eq "$log_lines" ] || fail 'gated check made an API call'
ok 'a gated check prints nothing and makes no further API call'

# --- partial failure keeps the previous pending review ----------------------
reset_case
search_item 10 public/upstream PR_c | search_page 1 > "$TMP/responses/search-my-prs.json"
mine_node PR_c 10 public/upstream 'Original PR' '2025-06-02T00:00:00Z' MERGEABLE > "$TMP/responses/node-PR_c.json"
run_check 2000000000 >/dev/null
before=$(run_pending)
{ search_item 10 public/upstream PR_c; search_item 15 public/new PR_e; } \
  | search_page 2 > "$TMP/responses/search-my-prs.json"
export FAKE_GRAPHQL_FAIL=1
set +e
out=$(run_check 2000000061 2>"$TMP/err")
status=$?
set -e
unset FAKE_GRAPHQL_FAIL
[ "$status" -ne 0 ] || fail 'partial API failure did not exit nonzero'
[ -z "$out" ] || fail "partial API failure printed a check line: $out"
[ "$(grep -c '^github-daily-review: ' "$TMP/err")" -eq 1 ] \
  || fail "partial API failure did not print exactly one tool line: $(cat "$TMP/err")"
[ "$(run_pending)" = "$before" ] || fail 'partial API failure replaced the previous pending review'
ok 'a partial API failure leaves the previous pending review intact and exits nonzero with one line'

# --- budget exhaustion ------------------------------------------------------
reset_case
search_item 10 public/upstream PR_c | search_page 1 > "$TMP/responses/search-my-prs.json"
mine_node PR_c 10 public/upstream 'My PR' '2025-06-02T00:00:00Z' MERGEABLE > "$TMP/responses/node-PR_c.json"
printf '1000' > "$TMP/fake-date"
export FAKE_DATE_FILE="$TMP/fake-date" FAKE_DATE_STEP=2
set +e
OSS_MATE_CHECK_BUDGET=2 run_check 2000000000 2>"$TMP/err"
status=$?
set -e
unset FAKE_DATE_FILE FAKE_DATE_STEP
[ "$status" -ne 0 ] || fail 'budget exhaustion did not exit nonzero'
grep -q 'budget exhausted' "$TMP/err" || fail "budget exhaustion message is wrong: $(cat "$TMP/err")"
grep -q 'invalid time interval' "$TMP/err" && fail 'budget exhaustion invoked timeout with an empty interval'
[ ! -f "$TMP/state/github-daily-review.json" ] || fail 'budget exhaustion published a partial review'
ok 'budget exhaustion stops with one line, a nonzero exit, and no published review'

# --- batching keeps per-item detail off the one-request-per-pull-request path
reset_case
: > "$TMP/many-items"
for n in $(seq 1 40); do search_item "$n" "public/repo$n" "PR_m$n" >> "$TMP/many-items"; done
search_page 40 < "$TMP/many-items" > "$TMP/responses/search-my-prs.json"
for n in $(seq 1 40); do
  mine_node "PR_m$n" "$n" "public/repo$n" "PR $n" '2025-06-02T00:00:00Z' MERGEABLE \
    > "$TMP/responses/node-PR_m$n.json"
done
out=$(run_check 2000000000)
case "$out" in *'my-prs=40'*) ;; *) fail "batched review lost pull requests: $out" ;; esac
graphql_calls=$(grep -c 'graphql' "$TMP/log" || true)
[ "$graphql_calls" -le 2 ] || fail "40 pull requests took $graphql_calls GraphQL requests instead of batching"
ok '40 authored pull requests resolve in at most two batched GraphQL requests'

# --- search encoding --------------------------------------------------------
reset_case
run_check 2000000000 >/dev/null
search_path=$(grep -o '/search/issues[^ ]*' "$TMP/log" | head -1)
[ -n "$search_path" ] || fail 'check did not call search/issues'
case "$search_path" in *%2B*) fail "search path encodes + as %2B: $search_path" ;; esac
case "$search_path" in *%20*) ;; *) fail "search qualifiers are not %20 separated: $search_path" ;; esac
ok 'the search request path uses %20 separators and never %2B'

# --- read paths never mutate ------------------------------------------------
reset_case
search_item 10 public/upstream PR_c | search_page 1 > "$TMP/responses/search-my-prs.json"
mine_node PR_c 10 public/upstream 'My PR' '2025-06-02T00:00:00Z' CONFLICTING > "$TMP/responses/node-PR_c.json"
{
  notification t9 2033-05-17T12:00:00Z public/upstream false comment PullRequest \
    https://api.github.com/repos/public/upstream/pulls/10 'Comment'
} | jq -s '.' > "$TMP/responses/notifications.json"
run_check 2000000000 >/dev/null
run_pending >/dev/null
"$SCRIPT" --state-dir "$TMP/state" show >/dev/null
"$SCRIPT" --state-dir "$TMP/state" ack
[ ! -s "$TMP/mutations" ] || fail 'check, pending, show, or ack made a mutating API call'
grep -q -- '--method PATCH' "$TMP/log" && fail 'a read path issued PATCH'
ok 'check, pending, show, and ack never issue a mutating GitHub call'

# --- mark-read --------------------------------------------------------------
reset_case
search_item 10 public/upstream PR_c | search_page 1 > "$TMP/responses/search-my-prs.json"
mine_node PR_c 10 public/upstream 'My PR' '2025-06-02T00:00:00Z' CONFLICTING > "$TMP/responses/node-PR_c.json"
{
  notification t10 2033-05-17T12:00:00Z public/upstream false comment PullRequest \
    https://api.github.com/repos/public/upstream/pulls/10 'Comment'
  notification t11 2033-05-17T12:00:01Z public/upstream false review_requested PullRequest \
    https://api.github.com/repos/public/upstream/pulls/10 'Review'
} | jq -s '.' > "$TMP/responses/notifications.json"
run_check 2000000000 >/dev/null
set +e
"$SCRIPT" --state-dir "$TMP/state" mark-read >"$TMP/out" 2>"$TMP/err"
status=$?
set -e
[ "$status" -ne 0 ] || fail 'mark-read did not refuse before ack'
grep -q 'no review has been acknowledged' "$TMP/err" || fail "mark-read refusal message is wrong: $(cat "$TMP/err")"
set +e
"$SCRIPT" --state-dir "$TMP/state" mark-read --yes >"$TMP/out" 2>"$TMP/err"
status=$?
set -e
[ "$status" -ne 0 ] || fail 'mark-read --yes did not refuse before ack'
[ ! -s "$TMP/mutations" ] || fail 'mark-read mutated GitHub before any ack'
"$SCRIPT" --state-dir "$TMP/state" ack
out=$("$SCRIPT" --state-dir "$TMP/state" mark-read)
[ "$out" = 'mark-read: would mark 2 threads read on GitHub' ] || fail "mark-read dry run is wrong: $out"
[ ! -s "$TMP/mutations" ] || fail 'mark-read without --yes mutated GitHub'
out=$("$SCRIPT" --state-dir "$TMP/state" mark-read --yes)
[ "$out" = 'mark-read: marked=2 failed=0 remaining=0' ] || fail "mark-read summary is wrong: $out"
[ "$(grep -c 'PATCH notifications/threads/' "$TMP/mutations")" -eq 2 ] \
  || fail "mark-read PATCHed the wrong number of threads: $(cat "$TMP/mutations")"
grep -qx 'PATCH notifications/threads/t10' "$TMP/mutations" || fail 'mark-read skipped an acknowledged thread'
grep -qx 'PATCH notifications/threads/t11' "$TMP/mutations" || fail 'mark-read skipped an acknowledged thread'
[ "$(jq -r '.acked_threads | length' "$TMP/state/github-daily-review.json")" -eq 0 ] \
  || fail 'mark-read did not clear the acknowledged threads'
ok 'mark-read refuses before ack and PATCHes exactly the acknowledged thread ids with --yes'

# --- mark-read resumes after a per-thread failure ---------------------------
reset_case
{
  notification t20 2033-05-17T12:00:00Z me/owned false subscribed Issue \
    https://api.github.com/repos/me/owned/issues/5 'A'
  notification t21 2033-05-17T12:00:01Z me/owned false subscribed Issue \
    https://api.github.com/repos/me/owned/issues/5 'B'
} | jq -s '.' > "$TMP/responses/notifications.json"
search_item 5 me/owned I_a | search_page 1 > "$TMP/responses/search-new-issues.json"
issue_node I_a 5 me/owned 'A' '2033-05-17T12:00:00Z' someone > "$TMP/responses/node-I_a.json"
run_check 2000000000 >/dev/null
"$SCRIPT" --state-dir "$TMP/state" ack
printf 't21\n' > "$TMP/patch-fail"
export FAKE_PATCH_FAIL="$TMP/patch-fail"
set +e
out=$("$SCRIPT" --state-dir "$TMP/state" mark-read --yes 2>/dev/null)
status=$?
set -e
[ "$status" -ne 0 ] || fail 'a per-thread mark-read failure did not exit nonzero'
[ "$out" = 'mark-read: marked=1 failed=1 remaining=1' ] || fail "partial mark-read summary is wrong: $out"
[ "$(jq -r '.acked_threads | join(",")' "$TMP/state/github-daily-review.json")" = t21 ] \
  || fail 'mark-read did not durably clear the succeeded thread only'
rm -f "$TMP/patch-fail"
unset FAKE_PATCH_FAIL
out=$("$SCRIPT" --state-dir "$TMP/state" mark-read --yes)
[ "$out" = 'mark-read: marked=1 failed=0 remaining=0' ] || fail "mark-read resume summary is wrong: $out"
ok 'mark-read clears each thread only after its remote success and resumes the remainder'

# --- close ------------------------------------------------------------------
reset_case
pull_fixture 40 public/upstream other 'Wrong author' false > "$TMP/responses/pull-public-upstream-40.json"
if "$SCRIPT" close public/upstream#40 2>"$TMP/err"; then fail 'close accepted another author'; fi
grep -q 'not authored by the authenticated user' "$TMP/err" || fail 'close author refusal message is wrong'
pull_fixture 41 public/upstream me 'Still mergeable' true > "$TMP/responses/pull-public-upstream-41.json"
if "$SCRIPT" close public/upstream#41 2>"$TMP/err"; then fail 'close accepted a mergeable pull request'; fi
grep -q 'not stale' "$TMP/err" || fail 'close mergeable refusal message is wrong'
pull_fixture 42 public/upstream me 'Closed already' false closed > "$TMP/responses/pull-public-upstream-42.json"
if "$SCRIPT" close public/upstream#42 2>"$TMP/err"; then fail 'close accepted a closed pull request'; fi
grep -q 'not open' "$TMP/err" || fail 'close state refusal message is wrong'
pull_fixture 43 public/upstream me 'Stale mine' false > "$TMP/responses/pull-public-upstream-43.json"
out=$("$SCRIPT" close public/upstream#43)
[ "$out" = 'would close: public/upstream#43' ] || fail "close without --yes is wrong: $out"
[ ! -s "$TMP/mutations" ] || fail 'close without --yes mutated GitHub'
"$SCRIPT" close --yes public/upstream#43 >/dev/null
grep -qx 'PATCH repos/public/upstream/pulls/43' "$TMP/mutations" \
  || fail 'close with --yes did not patch the pull request'
ok 'close refuses invalid targets, dry-runs without --yes, and closes a stale self-authored pull request'

# --- empty review -----------------------------------------------------------
reset_case
out=$(run_check 2000000000)
[ -z "$out" ] || fail "empty review printed a check line: $out"
[ -z "$(run_pending)" ] || fail 'empty review printed pending lines'
ok 'an empty review prints nothing'


# --- unknown mergeability is never stale ------------------------------------
reset_case
search_item 50 public/a PR_u | search_page 1 > "$TMP/responses/search-my-prs.json"
mine_node PR_u 50 public/a 'Computing' '2025-06-02T00:00:00Z' UNKNOWN > "$TMP/responses/node-PR_u.json"
out=$(run_check 2000000000)
case "$out" in *'my-prs=1 (action=0 stale=0)'*) ;; *) fail "unknown mergeability was counted stale: $out" ;; esac
case "$(run_pending)" in *'mergeability=unknown'*) ;; *) fail 'unknown mergeability is missing from pending' ;; esac
ok 'unknown or computing mergeability is reported as unknown and is never stale'

# --- X-Poll-Interval is an additional floor ---------------------------------
reset_case
FAKE_POLL=90 run_check 2000000000 >/dev/null
calls=$(grep -c '/notifications' "$TMP/log" || true)
OSS_MATE_NOW=2000000089 "$SCRIPT" --state-dir "$TMP/state" check >/dev/null
[ "$(grep -c '/notifications' "$TMP/log" || true)" -eq "$calls" ] || fail 'X-Poll-Interval was not respected'
OSS_MATE_NOW=2000000090 "$SCRIPT" --state-dir "$TMP/state" check >/dev/null
[ "$(grep -c '/notifications' "$TMP/log" || true)" -gt "$calls" ] || fail 'the poll did not resume at the interval'
ok 'X-Poll-Interval raises the gate above the configured minimum'

# --- notification cursor overlap --------------------------------------------
reset_case
search_item 10 public/upstream PR_c | search_page 1 > "$TMP/responses/search-my-prs.json"
mine_node PR_c 10 public/upstream 'My PR' '2025-06-02T00:00:00Z' MERGEABLE > "$TMP/responses/node-PR_c.json"
run_check 2000000000 >/dev/null
"$SCRIPT" --state-dir "$TMP/state" ack
run_check 2000000061 >/dev/null
grep -q 'since=2033-05-17T21:33:20Z' "$TMP/log" || fail 'the notification cursor did not overlap by six hours'
ok 'later notification polls overlap their stored cursor by six hours'

# --- notification thread versions deduplicate -------------------------------
reset_case
{
  notification t30 2033-05-17T12:00:00Z public/upstream false comment PullRequest \
    https://api.github.com/repos/public/upstream/pulls/10 'Comment'
} | jq -s '.' > "$TMP/responses/notifications.json"
run_check 2000000000 >/dev/null
run_check 2000000061 >/dev/null
[ "$(jq -r '.notification_seen | length' "$TMP/state/github-daily-review.json")" -eq 1 ] \
  || fail 'an unchanged thread returned by the overlap was counted twice'
[ "$(jq -r '.pending.threads | length' "$TMP/state/github-daily-review.json")" -eq 1 ] \
  || fail 'an unchanged thread entered the pending review twice'
ok 'a thread returned again inside the overlap window deduplicates on id and updated_at'

printf '1..%s\n' "$PASS"
