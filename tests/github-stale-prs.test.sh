#!/usr/bin/env bash
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
fail() { printf 'not ok - %s\n' "$*"; exit 1; }
ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$PASS" "$*"; }
mkdir -p "$TMP/fakebin" "$TMP/responses"
cat > "$TMP/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_LOG"
METHOD=GET
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method) METHOD=$2; shift 2 ;;
    -f|-F) shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
ENDPOINT=${ARGS[${#ARGS[@]}-1]:-}
if [ "$METHOD" = PATCH ]; then
  printf 'PATCH %s\n' "$ENDPOINT" >> "$FAKE_MUTATIONS"
  printf '{}\n'
  exit 0
fi
if [ "$ENDPOINT" = user ]; then
  jq -n --arg login "${FAKE_LOGIN:-me}" '{login:$login}'
  exit 0
fi
case "$ENDPOINT" in
  /search/issues*)
    if printf '%s' "$ENDPOINT" | grep -q -- '%2B-author%3A\|-author%3A\|-author:'; then
      file="$FAKE_RESPONSES/search-theirs.json"
    else
      file="$FAKE_RESPONSES/search-mine.json"
    fi
    [ -f "$file" ] || file="$FAKE_RESPONSES/search-default.json"
    cat "$file"
    exit 0
    ;;
esac
if [[ "$ENDPOINT" =~ ^repos/[^/]+/[^/]+/pulls/[0-9]+$ ]]; then
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
export FAKE_LOG="$TMP/log" FAKE_MUTATIONS="$TMP/mutations" FAKE_LOGIN=me FAKE_RESPONSES="$TMP/responses"
SCRIPT="$ROOT/bin/github-stale-prs"

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
search_page() { jq -s --argjson total "$1" '{total_count:$total,items:.}'; }

reset_case() {
  rm -f "$TMP/log" "$TMP/mutations"
  : > "$TMP/log"
  : > "$TMP/mutations"
}

reset_case
{
  search_item 10 public/mine me 'My public PR'
  search_item 11 secret/private me 'PRIVATE-MINE-TITLE'
} | search_page 2 > "$TMP/responses/search-mine.json"
{
  search_item 20 owned/repo other 'Their public PR'
  search_item 21 listed/repo other 'LISTED-TITLE'
} | search_page 2 > "$TMP/responses/search-theirs.json"
pull_fixture 10 public/mine me 'My public PR' false false > "$TMP/responses/pull-public-mine-10.json"
pull_fixture 11 secret/private me 'PRIVATE-MINE-TITLE' true true > "$TMP/responses/pull-secret-private-11.json"
pull_fixture 20 owned/repo other 'Their public PR' true false > "$TMP/responses/pull-owned-repo-20.json"
pull_fixture 21 listed/repo other 'LISTED-TITLE' false false > "$TMP/responses/pull-listed-repo-21.json"
out=$("$SCRIPT" list)
case "$out" in
  *'mine repository=public/mine number=10 author=self mergeability=stale'*) ;;
  *) fail "mine set line is wrong: $out" ;;
esac
case "$out" in
  *'theirs repository=owned/repo number=20 author=other mergeability=mergeable'*) ;;
  *) fail "theirs set line is wrong: $out" ;;
esac
case "$out" in *'mine private count=1'*) ;; *) fail "private count is wrong: $out" ;; esac
case "$out" in *PRIVATE*|*secret/private*) fail "private details leaked: $out" ;; esac
printf '{"owners":["listed"],"repositories":[]}\n' > "$TMP/config.json"
out=$("$SCRIPT" --config "$TMP/config.json" list)
case "$out" in *'theirs private count=1'*) ;; *) fail "config exclusion count is wrong: $out" ;; esac
case "$out" in *listed/repo*|*LISTED*) fail "configured repository leaked: $out" ;; esac
[ ! -s "$TMP/mutations" ] || fail 'list made a mutating API call'
ok 'both sets list with tags, private and config counts, and no mutations'

reset_case
{
  search_item 30 public/mine me 'Mergeable mine'
  search_item 31 public/mine me 'Stale mine'
  search_item 32 public/mine me 'Unknown mine'
} | search_page 3 > "$TMP/responses/search-mine.json"
printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-theirs.json"
pull_fixture 30 public/mine me 'Mergeable mine' true false > "$TMP/responses/pull-public-mine-30.json"
pull_fixture 31 public/mine me 'Stale mine' false false > "$TMP/responses/pull-public-mine-31.json"
pull_fixture 32 public/mine me 'Unknown mine' null false > "$TMP/responses/pull-public-mine-32.json"
out=$("$SCRIPT" --stale list)
[ "$out" = 'mine repository=public/mine number=31 author=self mergeability=stale title="Stale mine"' ] \
  || fail "--stale filter is wrong: $out"
[ ! -s "$TMP/mutations" ] || fail '--stale list made a mutating API call'
ok '--stale keeps only non-mergeable pull requests and treats unknown as not stale'

reset_case
pull_fixture 40 public/mine other 'Wrong author' false false > "$TMP/responses/pull-public-mine-40.json"
if "$SCRIPT" close public/mine#40 2>"$TMP/err"; then fail 'close accepted another author'; fi
grep -q 'not authored by the authenticated user' "$TMP/err" || fail 'close author refusal message is wrong'

reset_case
pull_fixture 41 public/mine me 'Still mergeable' true false > "$TMP/responses/pull-public-mine-41.json"
if "$SCRIPT" close public/mine#41 2>"$TMP/err"; then fail 'close accepted a mergeable pull request'; fi
grep -q 'not stale' "$TMP/err" || fail 'close mergeable refusal message is wrong'

reset_case
pull_fixture 42 public/mine me 'Stale mine' false false > "$TMP/responses/pull-public-mine-42.json"
out=$("$SCRIPT" close public/mine#42)
[ "$out" = 'would close: public/mine#42' ] || fail "close without --yes is wrong: $out"
[ ! -s "$TMP/mutations" ] || fail 'close without --yes mutated GitHub'

reset_case
pull_fixture 42 public/mine me 'Stale mine' false false > "$TMP/responses/pull-public-mine-42.json"
"$SCRIPT" close --yes public/mine#42 >/dev/null
grep -q 'PATCH repos/public/mine/pulls/42' "$TMP/mutations" || fail 'close with --yes did not patch the pull request'
ok 'close refuses invalid targets, dry-runs without --yes, and closes stale self-authored pull requests with --yes'

printf '1..%s\n' "$PASS"
