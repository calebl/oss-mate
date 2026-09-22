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
    *) ARGS+=("$1"); shift ;;
  esac
done
if [ "$METHOD" = PATCH ]; then
  ENDPOINT=${ARGS[${#ARGS[@]}-1]:-}
  printf 'PATCH %s\n' "$ENDPOINT" >> "$FAKE_MUTATIONS"
  printf '{}\n'
  exit 0
fi
is_graphql=0
for arg in "${ARGS[@]}"; do
  [ "$arg" = graphql ] && is_graphql=1
done
fake_pr_fetch_count() {
  count=$(cat "${FAKE_PR_FETCHES_FILE:-/dev/null}" 2>/dev/null || printf '0')
  count=$((count + 1))
  printf '%s' "$count" > "${FAKE_PR_FETCHES_FILE:?}"
  printf '%s' "$count"
}
if [ "$is_graphql" -eq 1 ]; then
  FAKE_PR_FETCHES=$(fake_pr_fetch_count)
  if [ -n "${FAKE_DATE_FILE:-}" ]; then
    now=$(cat "$FAKE_DATE_FILE")
    now=$((now + ${FAKE_DATE_STEP:-1}))
    printf '%s' "$now" > "$FAKE_DATE_FILE"
  elif [ "${FAKE_SLOW:-0}" -gt 0 ] && [ "$FAKE_PR_FETCHES" -ge "${FAKE_SLOW_FROM:-1}" ]; then
    sleep "$FAKE_SLOW"
  fi
  owner= name= number=
  i=0
  while [ "$i" -lt "${#ORIG[@]}" ]; do
    case "${ORIG[$i]}" in
      -f)
        val=${ORIG[$((i + 1))]}
        case "$val" in
          owner=*) owner=${val#owner=} ;;
          name=*) name=${val#name=} ;;
        esac
        i=$((i + 2))
        ;;
      -F)
        val=${ORIG[$((i + 1))]}
        case "$val" in
          number=*) number=${val#number=} ;;
          *) number=$val ;;
        esac
        i=$((i + 2))
        ;;
      *) i=$((i + 1)) ;;
    esac
  done
  file="$FAKE_RESPONSES/gql-${owner}-${name}-${number}.json"
  [ -f "$file" ] || file="$FAKE_RESPONSES/gql-default.json"
  cat "$file"
  exit 0
fi
ENDPOINT=${ARGS[${#ARGS[@]}-1]:-}
if [ "$ENDPOINT" = user ]; then
  jq -n --arg login "${FAKE_LOGIN:-me}" '{login:$login}'
  exit 0
fi
case "$ENDPOINT" in
  /search/issues*)
    if printf '%s' "$ENDPOINT" | grep -q -- '%2B-author%3A\|-author%3A\|-author:'; then
      if printf '%s' "$ENDPOINT" | grep -q -- '%2B-user%3A\|-user%3A\|-user:'; then
        file="$FAKE_RESPONSES/search-mine.json"
      else
        file="$FAKE_RESPONSES/search-theirs.json"
      fi
    else
      file="$FAKE_RESPONSES/search-mine.json"
    fi
    [ -f "$file" ] || file="$FAKE_RESPONSES/search-default.json"
    cat "$file"
    exit 0
    ;;
esac
if [[ "$ENDPOINT" =~ ^repos/[^/]+/[^/]+/pulls/[0-9]+$ ]]; then
  FAKE_PR_FETCHES=$(fake_pr_fetch_count)
  if [ -n "${FAKE_DATE_FILE:-}" ]; then
    now=$(cat "$FAKE_DATE_FILE")
    now=$((now + ${FAKE_DATE_STEP:-1}))
    printf '%s' "$now" > "$FAKE_DATE_FILE"
  elif [ "${FAKE_SLOW:-0}" -gt 0 ] && [ "$FAKE_PR_FETCHES" -ge "${FAKE_SLOW_FROM:-1}" ]; then
    sleep "$FAKE_SLOW"
  fi
  repo=${ENDPOINT#repos/}
  repo=${repo%/pulls/*}
  num=${ENDPOINT##*/}
  file="$FAKE_RESPONSES/pull-${repo//\//-}-$num.json"
  [ -f "$file" ] || file="$FAKE_RESPONSES/pull-default.json"
  cat "$file"
  exit 0
fi
printf 'unknown endpoint: %s\n' "$ENDPOINT" >&2
exit 1
FAKE
chmod +x "$TMP/fakebin/gh"
export PATH="$TMP/fakebin:$PATH"
export OSS_MATE_MIN_POLL_SECONDS=60
export FAKE_LOG="$TMP/log" FAKE_MUTATIONS="$TMP/mutations" FAKE_LOGIN=me FAKE_RESPONSES="$TMP/responses"
export FAKE_PR_FETCHES_FILE="$TMP/pr-fetches" FAKE_DATE_FILE="$TMP/fake-date"
SCRIPT="$ROOT/bin/github-open-prs"

search_item() {
  jq -n --argjson number "$1" --arg repo "$2" --arg author "$3" --arg title "$4" \
    '{number:$number,title:$title,repository_url:("https://api.github.com/repos/" + $repo),user:{login:$author}}'
}
pull_fixture() {
  jq -n --argjson number "$1" --arg repo "$2" --arg author "$3" --arg title "$4" \
    --argjson mergeable "$5" --argjson private "$6" --arg state "${7:-open}" \
    '{number:$number,state:$state,mergeable:$mergeable,title:$title,user:{login:$author},
      base:{repo:{full_name:$repo,private:$private}}}'
}
gql_fixture() {
  jq -n --argjson number "$1" --arg title "$2" --arg updated "$3" --arg mergeable "$4" \
    --arg review "${5:-}" --arg checks "${6:-SUCCESS}" --argjson private "${7:-false}" \
    '{data:{repository:{isPrivate:$private,pullRequest:{
      number:$number,title:$title,updatedAt:$updated,mergeable:$mergeable,
      reviewDecision:(if $review=="" then null else $review end),
      commits:{nodes:[{commit:{statusCheckRollup:{state:$checks}}}]}}}}}'
}
search_page() { jq -s --argjson total "$1" '{total_count:$total,items:.}'; }

reset_case() {
  rm -f "$TMP/log" "$TMP/mutations" "$TMP/pr-fetches" "$TMP/fake-date"
  rm -rf "$TMP/state"
  mkdir -p "$TMP/state"
  : > "$TMP/log"
  : > "$TMP/mutations"
  : > "$TMP/pr-fetches"
  printf '1000' > "$TMP/fake-date"
}
run_check() {
  OSS_MATE_NOW=$1 "$SCRIPT" --state-dir "$TMP/state" check
}

reset_case
{
  search_item 10 public/otherproj me 'My public PR'
  search_item 12 me/ownrepo me 'Own repo PR'
  search_item 11 secret/private me 'PRIVATE-MINE-TITLE'
} | search_page 3 > "$TMP/responses/search-mine.json"
{
  search_item 20 me/owned other 'Their public PR'
  search_item 21 me/listed other 'LISTED-TITLE'
} | search_page 2 > "$TMP/responses/search-theirs.json"
gql_fixture 10 'My public PR' '2025-01-01T00:00:00Z' CONFLICTING > "$TMP/responses/gql-public-otherproj-10.json"
gql_fixture 12 'Own repo PR' '2025-01-01T00:00:00Z' MERGEABLE > "$TMP/responses/gql-me-ownrepo-12.json"
gql_fixture 11 'PRIVATE-MINE-TITLE' '2025-01-01T00:00:00Z' MERGEABLE '' SUCCESS true > "$TMP/responses/gql-secret-private-11.json"
pull_fixture 20 me/owned other 'Their public PR' true false > "$TMP/responses/pull-me-owned-20.json"
pull_fixture 21 me/listed other 'LISTED-TITLE' false false > "$TMP/responses/pull-me-listed-21.json"
out=$("$SCRIPT" list)
case "$out" in *'mine repository=public/otherproj number=10'*) ;; *) fail "mine set line is wrong: $out" ;; esac
case "$out" in *'theirs repository=me/owned number=20'*) ;; *) fail "theirs set line is wrong: $out" ;; esac
case "$out" in *'mine private count=1'*) ;; *) fail "private count is wrong: $out" ;; esac
case "$out" in *me/ownrepo*|*Own\ repo*) fail "own-repo authored pull request leaked: $out" ;; esac
case "$out" in *PRIVATE*|*secret/private*) fail "private details leaked: $out" ;; esac
printf '{"owners":[],"repositories":["me/listed"]}\n' > "$TMP/config.json"
out=$("$SCRIPT" --config "$TMP/config.json" list)
case "$out" in *'theirs private count=1'*) ;; *) fail "config exclusion count is wrong: $out" ;; esac
case "$out" in *me/listed*|*LISTED*) fail "configured repository leaked: $out" ;; esac
[ ! -s "$TMP/mutations" ] || fail 'list made a mutating API call'
ok 'mine excludes own repositories, lists external open pull requests, and keeps private counts'

reset_case
{
  search_item 10 public/otherproj me 'My public PR'
} | search_page 1 > "$TMP/responses/search-mine.json"
printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-theirs.json"
gql_fixture 10 'My public PR' '2025-01-01T00:00:00Z' CONFLICTING > "$TMP/responses/gql-public-otherproj-10.json"
"$SCRIPT" list >/dev/null
search_path=$(grep -o '/search/issues[^ ]*' "$TMP/log" | head -1)
[ -n "$search_path" ] || fail 'list did not call search/issues'
case "$search_path" in *%2B*) fail "search path encodes + as %2B: $search_path" ;; esac
case "$search_path" in
  *%20is%3Aopen*|*' is:open'*) ;;
  *) fail "search qualifiers are not space-separated: $search_path" ;;
esac
ok 'search query encodes space-separated qualifiers without literal plus signs'

reset_case
{
  search_item 30 public/otherproj me 'Mergeable mine'
  search_item 31 public/otherproj me 'Stale mine'
  search_item 32 public/otherproj me 'Unknown mine'
} | search_page 3 > "$TMP/responses/search-mine.json"
printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-theirs.json"
gql_fixture 30 'Mergeable mine' '2025-01-01T00:00:00Z' MERGEABLE > "$TMP/responses/gql-public-otherproj-30.json"
gql_fixture 31 'Stale mine' '2025-01-01T00:00:00Z' CONFLICTING > "$TMP/responses/gql-public-otherproj-31.json"
gql_fixture 32 'Unknown mine' '2025-01-01T00:00:00Z' UNKNOWN > "$TMP/responses/gql-public-otherproj-32.json"
export FAKE_DATE_STEP=1
if OSS_MATE_CHECK_BUDGET=2 "$SCRIPT" list 2>"$TMP/err"; then fail 'budget exhaustion did not exit nonzero'; fi
grep -q 'budget exhausted after 2 of 3 pull requests' "$TMP/err" \
  || fail "budget exhaustion message is wrong: $(cat "$TMP/err")"
grep -q 'invalid time interval' "$TMP/err" && fail 'budget exhaustion invoked timeout with empty interval'
unset FAKE_DATE_STEP
ok 'budget exhaustion exits cleanly with progress and without empty timeout'

reset_case
{
  search_item 30 public/otherproj me 'Mergeable mine'
  search_item 31 public/otherproj me 'Stale mine'
  search_item 32 public/otherproj me 'Unknown mine'
} | search_page 3 > "$TMP/responses/search-mine.json"
printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-theirs.json"
gql_fixture 30 'Mergeable mine' '2025-01-01T00:00:00Z' MERGEABLE > "$TMP/responses/gql-public-otherproj-30.json"
gql_fixture 31 'Stale mine' '2025-01-01T00:00:00Z' CONFLICTING > "$TMP/responses/gql-public-otherproj-31.json"
gql_fixture 32 'Unknown mine' '2025-01-01T00:00:00Z' UNKNOWN > "$TMP/responses/gql-public-otherproj-32.json"
out=$("$SCRIPT" list)
case "$out" in *'number=30'*mergeability=mergeable*) ;; *) fail "mergeable mine missing from list: $out" ;; esac
case "$out" in *'number=32'*mergeability=unknown*) ;; *) fail "unknown mine missing from list: $out" ;; esac
out=$("$SCRIPT" --stale list)
[ "$out" = 'mine repository=public/otherproj number=31 author=self mergeability=stale title="Stale mine"' ] \
  || fail "--stale filter is wrong: $out"
[ ! -s "$TMP/mutations" ] || fail '--stale list made a mutating API call'
ok '--stale filters list only and all non-stale mine pull requests still list'

reset_case
pull_fixture 40 public/otherproj other 'Wrong author' false false > "$TMP/responses/pull-public-otherproj-40.json"
if "$SCRIPT" close public/otherproj#40 2>"$TMP/err"; then fail 'close accepted another author'; fi
grep -q 'not authored by the authenticated user' "$TMP/err" || fail 'close author refusal message is wrong'

reset_case
pull_fixture 41 public/otherproj me 'Still mergeable' true false > "$TMP/responses/pull-public-otherproj-41.json"
if "$SCRIPT" close public/otherproj#41 2>"$TMP/err"; then fail 'close accepted a mergeable pull request'; fi
grep -q 'not stale' "$TMP/err" || fail 'close mergeable refusal message is wrong'

reset_case
pull_fixture 42 public/otherproj me 'Stale mine' false false > "$TMP/responses/pull-public-otherproj-42.json"
out=$("$SCRIPT" close public/otherproj#42)
[ "$out" = 'would close: public/otherproj#42' ] || fail "close without --yes is wrong: $out"
[ ! -s "$TMP/mutations" ] || fail 'close without --yes mutated GitHub'

reset_case
pull_fixture 42 public/otherproj me 'Stale mine' false false > "$TMP/responses/pull-public-otherproj-42.json"
"$SCRIPT" close --yes public/otherproj#42 >/dev/null
grep -q 'PATCH repos/public/otherproj/pulls/42' "$TMP/mutations" || fail 'close with --yes did not patch the pull request'
ok 'close refuses invalid targets, dry-runs without --yes, and closes stale self-authored pull requests with --yes'

reset_case
{
  search_item 50 public/otherproj me 'Stale mine'
  search_item 51 public/otherproj me 'Mergeable mine'
} | search_page 2 > "$TMP/responses/search-mine.json"
{
  search_item 60 me/owned other 'Their PR'
} | search_page 1 > "$TMP/responses/search-theirs.json"
gql_fixture 50 'Stale mine' '2025-01-01T00:00:00Z' CONFLICTING > "$TMP/responses/gql-public-otherproj-50.json"
gql_fixture 51 'Mergeable mine' '2025-01-01T00:00:00Z' MERGEABLE > "$TMP/responses/gql-public-otherproj-51.json"
pull_fixture 60 me/owned other 'Their PR' true false > "$TMP/responses/pull-me-owned-60.json"
out=$(run_check 2000000000)
[ "$out" = 'github open prs: mine=2 (action=1 stale=1 new-stale=1) theirs=1 (new=1 stale=0) excluded=0; run github-open-prs pending' ] \
  || fail "first check summary is wrong: $out"
[ -f "$TMP/state/github-open-prs.json" ] || fail 'first check did not store state'
log_lines=$(wc -l < "$TMP/log")
out=$(run_check 2000000030)
[ -z "$out" ] || fail 'gated check was not silent'
[ "$(wc -l < "$TMP/log")" -eq "$log_lines" ] || fail 'gated check made an API call'
ok 'first check prints the summary line and stores state; gated check is silent without API calls'

reset_case
{
  search_item 70 public/otherproj me 'Was mergeable'
  search_item 71 public/otherproj me 'Still stale'
} | search_page 2 > "$TMP/responses/search-mine.json"
printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-theirs.json"
gql_fixture 70 'Was mergeable' '2025-01-01T00:00:00Z' MERGEABLE > "$TMP/responses/gql-public-otherproj-70.json"
gql_fixture 71 'Still stale' '2025-01-01T00:00:00Z' CONFLICTING > "$TMP/responses/gql-public-otherproj-71.json"
run_check 2000000000 >/dev/null
gql_fixture 70 'Was mergeable' '2025-01-01T00:00:00Z' CONFLICTING > "$TMP/responses/gql-public-otherproj-70.json"
run_check 2000000061 >/dev/null
pending=$("$SCRIPT" --state-dir "$TMP/state" pending)
case "$pending" in *'number=70'*'status=new-stale'*'action=stale'*) ;; *) fail "new-stale status is wrong: $pending" ;; esac
case "$pending" in *'number=71'*'status=still-stale'*) ;; *) fail "still-stale status is wrong: $pending" ;; esac
ok 'after the gate a mergeable pull request that became stale is new-stale and an already stale one is still-stale'

reset_case
{
  search_item 80 public/otherproj me 'Needs changes'
} | search_page 1 > "$TMP/responses/search-mine.json"
printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-theirs.json"
gql_fixture 80 'Needs changes' '2025-01-01T00:00:00Z' MERGEABLE CHANGES_REQUESTED > "$TMP/responses/gql-public-otherproj-80.json"
run_check 2000000000 >/dev/null
pending=$("$SCRIPT" --state-dir "$TMP/state" pending)
case "$pending" in *'action=changes-requested'*) ;; *) fail "changes-requested action is wrong: $pending" ;; esac
ok 'changes-requested maps from reviewDecision'

reset_case
{
  search_item 81 public/otherproj me 'Checks failing'
} | search_page 1 > "$TMP/responses/search-mine.json"
printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-theirs.json"
gql_fixture 81 'Checks failing' '2025-01-01T00:00:00Z' MERGEABLE '' FAILURE > "$TMP/responses/gql-public-otherproj-81.json"
run_check 2000000000 >/dev/null
pending=$("$SCRIPT" --state-dir "$TMP/state" pending)
case "$pending" in *'action=checks-failing'*) ;; *) fail "checks-failing action is wrong: $pending" ;; esac
ok 'checks-failing maps from status check rollup'

reset_case
{
  search_item 82 public/otherproj me 'New activity'
} | search_page 1 > "$TMP/responses/search-mine.json"
printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-theirs.json"
gql_fixture 82 'New activity' '2025-01-01T00:00:00Z' MERGEABLE > "$TMP/responses/gql-public-otherproj-82.json"
run_check 2000000000 >/dev/null
gql_fixture 82 'New activity' '2025-01-02T00:00:00Z' MERGEABLE > "$TMP/responses/gql-public-otherproj-82.json"
run_check 2000000061 >/dev/null
pending=$("$SCRIPT" --state-dir "$TMP/state" pending)
case "$pending" in *'action=new-activity'*) ;; *) fail "new-activity action is wrong: $pending" ;; esac
ok 'new-activity maps from updated_at newer than the previous snapshot'

reset_case
{
  search_item 90 public/otherproj me 'Mine only'
} | search_page 1 > "$TMP/responses/search-mine.json"
printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-theirs.json"
gql_fixture 90 'Mine only' '2025-01-01T00:00:00Z' MERGEABLE > "$TMP/responses/gql-public-otherproj-90.json"
run_check 2000000000 >/dev/null
{
  search_item 90 public/otherproj me 'Mine only'
} | search_page 1 > "$TMP/responses/search-mine.json"
{
  search_item 91 me/owned other 'New theirs'
} | search_page 1 > "$TMP/responses/search-theirs.json"
gql_fixture 90 'Mine only' '2025-01-01T00:00:00Z' MERGEABLE > "$TMP/responses/gql-public-otherproj-90.json"
pull_fixture 91 me/owned other 'New theirs' true false > "$TMP/responses/pull-me-owned-91.json"
run_check 2000000061 >/dev/null
pending=$("$SCRIPT" --state-dir "$TMP/state" pending)
case "$pending" in *'number=91'*'status=new'*) ;; *) fail "new theirs status is wrong: $pending" ;; esac
ok 'a new pull request by another author in an owned repository is flagged new'

reset_case
printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-mine.json"
printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-theirs.json"
out=$(run_check 2000000000)
[ -z "$out" ] || fail "empty inventory printed output: $out"
ok 'empty inventory prints nothing'

reset_case
{
  search_item 10 public/otherproj me 'My public PR'
  search_item 11 secret/private me 'PRIVATE-MINE-TITLE'
} | search_page 2 > "$TMP/responses/search-mine.json"
printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-theirs.json"
gql_fixture 10 'My public PR' '2025-01-01T00:00:00Z' CONFLICTING > "$TMP/responses/gql-public-otherproj-10.json"
gql_fixture 11 'PRIVATE-MINE-TITLE' '2025-01-01T00:00:00Z' MERGEABLE '' SUCCESS true > "$TMP/responses/gql-secret-private-11.json"
run_check 2000000000 >/dev/null
pending=$("$SCRIPT" --state-dir "$TMP/state" pending)
all="$pending $(cat "$TMP/state/github-open-prs.json")"
case "$all" in *PRIVATE*|*secret/private*) fail 'private details leaked into state or pending' ;; esac
"$SCRIPT" --state-dir "$TMP/state" check >/dev/null
"$SCRIPT" --state-dir "$TMP/state" pending >/dev/null
[ ! -s "$TMP/mutations" ] || fail 'check or pending made a mutating API call'
ok 'check and pending are read-only and private names never appear in state or output'

printf '1..%s\n' "$PASS"
