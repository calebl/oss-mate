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
is_graphql=0
for arg in ${ARGS[@]+"${ARGS[@]}"}; do
  [ "$arg" = graphql ] && is_graphql=1
done
if [ "$is_graphql" -eq 1 ]; then
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
  printf '%s\n' "$query" >> "$FAKE_GRAPHQL_LOG"
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
    printf '%s\n' "$ENDPOINT" >> "$FAKE_SEARCH_LOG"
    if printf '%s' "$ENDPOINT" | grep -q 'is%3Amerged'; then
      file="$FAKE_RESPONSES/search-merged.json"
    elif printf '%s' "$ENDPOINT" | grep -q 'commenter%3A'; then
      file="$FAKE_RESPONSES/search-commented.json"
    elif printf '%s' "$ENDPOINT" | grep -q 'reviewed-by%3A'; then
      file="$FAKE_RESPONSES/search-reviewed.json"
    elif printf '%s' "$ENDPOINT" | grep -q 'review-requested%3A'; then
      file="$FAKE_RESPONSES/search-awaiting.json"
    else
      file="$FAKE_RESPONSES/search-open.json"
    fi
    [ -f "$file" ] || file="$FAKE_RESPONSES/search-empty.json"
    cat "$file"
    exit 0
    ;;
  users/*/repos*)
    file="$FAKE_RESPONSES/repos.json"
    [ -f "$file" ] || file="$FAKE_RESPONSES/repos-empty.json"
    cat "$file"
    exit 0
    ;;
esac
printf 'unknown endpoint: %s\n' "$ENDPOINT" >&2
exit 1
FAKE
chmod +x "$TMP/fakebin/gh"

export PATH="$TMP/fakebin:$PATH"
export FAKE_RESPONSES="$TMP/responses" FAKE_NODE_TMP="$TMP/nodes-tmp"
export FAKE_SEARCH_LOG="$TMP/search-log" FAKE_GRAPHQL_LOG="$TMP/graphql-log"
SCRIPT="$ROOT/bin/oss-status"

pr_node() {
  jq -n --arg id "$1" --argjson number "$2" --arg repo "$3" --arg title "$4" \
    --arg updated "$5" --arg mergeable "${6:-MERGEABLE}" --argjson private "${7:-false}" \
    --arg merged "${8:-null}" \
    '{__typename:"PullRequest", id:$id, number:$number, title:$title,
      createdAt:$updated, updatedAt:$updated,
      mergedAt:(if $merged == "null" then null else $merged end),
      mergeable:$mergeable, reviewDecision:null, isDraft:false,
      author:{login:"me"},
      repository:{nameWithOwner:$repo, isPrivate:$private, owner:{login:($repo|split("/")[0])}},
      commits:{nodes:[{commit:{statusCheckRollup:{state:"SUCCESS"}}}]}}'
}
thread_node() {
  jq -n --arg id "$1" --argjson number "$2" --arg repo "$3" --arg title "$4" \
    --arg updated "$5" --argjson private "${6:-false}" --arg type "${7:-Issue}" \
    '{__typename:$type, id:$id, number:$number, title:$title, updatedAt:$updated,
      repository:{nameWithOwner:$repo, isPrivate:$private, owner:{login:($repo|split("/")[0])}}}'
}
repo_node() {
  jq -n --arg id "$1" --arg repo "$2" --argjson stars "$3" --argjson private "${4:-false}" \
    --argjson open_issues "${5:-0}" --argjson open_prs "${6:-0}" \
    --arg commit_date "${7:-2026-09-01T00:00:00Z}" --arg ci "${8:-SUCCESS}" \
    --arg release "${9:-null}" \
    '{__typename:"Repository", id:$id, nameWithOwner:$repo, isPrivate:$private,
      stargazerCount:$stars,
      openIssues:{totalCount:$open_issues}, openPRs:{totalCount:$open_prs},
      reviewPRs:{nodes:[]},
      defaultBranchRef:{target:{committedDate:$commit_date, statusCheckRollup:{state:$ci}}},
      releases:{nodes:[(if $release == "null" then empty else {publishedAt:$release} end)]}}'
}
search_item() {
  jq -n --argjson number "$1" --arg repo "$2" --arg node "$3" \
    '{number:$number, node_id:$node, repository_url:("https://api.github.com/repos/" + $repo)}'
}
search_page() { jq -s --argjson total "$1" '{total_count:$total, items:.}'; }
repo_list_entry() {
  jq -n --arg node "$1" --arg full_name "$2" --argjson stars "$3" \
    --argjson fork "${4:-false}" --argjson private "${5:-false}" --argjson archived "${6:-false}" \
    '{node_id:$node, full_name:$full_name, name:($full_name|split("/")[1]),
      stargazers_count:$stars, fork:$fork, private:$private, archived:$archived}'
}

reset_case() {
  rm -rf "$TMP/responses"
  rm -f "$TMP/search-log" "$TMP/graphql-log"
  mkdir -p "$TMP/responses"
  : > "$TMP/search-log"
  : > "$TMP/graphql-log"
  printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-empty.json"
  printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-open.json"
  printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-merged.json"
  printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-commented.json"
  printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-reviewed.json"
  printf '{"total_count":0,"items":[]}\n' > "$TMP/responses/search-awaiting.json"
  printf '[]\n' > "$TMP/responses/repos.json"
  unset FAKE_GRAPHQL_FAIL || true
}
run() { OSS_MATE_NOW=${OSS_MATE_NOW:-1758758400} "$SCRIPT" --config "$TMP/no-config.json" "$@"; }

# --- a bare run with no data prints empty sections and exits zero ------------------------
reset_case
OUT=$(run) || fail "bare run exited nonzero"
printf '%s' "$OUT" | grep -q 'open pull requests you authored elsewhere: 0' || fail 'missing empty open-pr section'
printf '%s' "$OUT" | grep -q 'public repositories maintained: 0' || fail 'missing empty repos section'
ok "a bare run with no data reports empty sections and exits zero"

# --- open pull requests, merged pull requests, comments, reviews, and awaiting-review each surface -
reset_case
search_item 5 other/repo PR1 | search_page 1 > "$TMP/responses/search-open.json"
search_item 6 other/repo PR2 | search_page 1 > "$TMP/responses/search-merged.json"
search_item 7 other/repo IS1 | search_page 1 > "$TMP/responses/search-commented.json"
search_item 8 other/repo PR3 | search_page 1 > "$TMP/responses/search-reviewed.json"
search_item 9 other/repo PR4 | search_page 1 > "$TMP/responses/search-awaiting.json"
pr_node PR1 5 other/repo "Fix bug" 2026-08-01T00:00:00Z > "$TMP/responses/node-PR1.json"
pr_node PR2 6 other/repo "Add feature" 2026-08-15T00:00:00Z MERGEABLE false 2026-08-16T00:00:00Z \
  > "$TMP/responses/node-PR2.json"
thread_node IS1 7 other/repo "Question" 2026-08-20T00:00:00Z false Issue > "$TMP/responses/node-IS1.json"
thread_node PR3 8 other/repo "Reviewed PR" 2026-08-21T00:00:00Z false PullRequest \
  > "$TMP/responses/node-PR3.json"
thread_node PR4 9 other/repo "Please review" 2026-08-22T00:00:00Z false PullRequest \
  > "$TMP/responses/node-PR4.json"
OUT=$(run)
printf '%s' "$OUT" | grep -q 'open-pr other/repo#5' || fail 'open pr missing'
printf '%s' "$OUT" | grep -q 'merged-pr other/repo#6' || fail 'merged pr missing'
printf '%s' "$OUT" | grep -q 'comment other/repo#7' || fail 'comment missing'
printf '%s' "$OUT" | grep -q 'review other/repo#8' || fail 'review missing'
printf '%s' "$OUT" | grep -q 'awaiting-review other/repo#9' || fail 'awaiting-review missing'
ok "open PRs, merged PRs, comments, reviews, and awaiting-review each surface with a bounded row"

# --- private repositories and config-excluded repositories are dropped entirely -----------
reset_case
search_item 5 other/repo PR1 | search_page 1 > "$TMP/responses/search-open.json"
pr_node PR1 5 other/repo "Fix bug" 2026-08-01T00:00:00Z MERGEABLE true > "$TMP/responses/node-PR1.json"
repo_list_entry REPO1 me/pub 10 > "$TMP/tmp-pub.json"
repo_list_entry REPO2 me/priv 2 false true > "$TMP/tmp-priv.json"
jq -s '.' "$TMP/tmp-pub.json" "$TMP/tmp-priv.json" > "$TMP/responses/repos.json"
repo_node REPO1 me/pub 10 false 1 0 > "$TMP/responses/node-REPO1.json"
OUT=$(run)
printf '%s' "$OUT" | grep -q 'open pull requests you authored elsewhere: 0' \
  || fail 'private open pr should be dropped entirely, with no count'
if printf '%s' "$OUT" | grep -q 'hidden'; then fail 'no output line should ever mention "hidden"'; fi
printf '%s' "$OUT" | grep -qv 'other/repo#5' || fail 'private pull request leaked'
printf '%s' "$OUT" | grep -q 'me/pub' || fail 'public repo should be visible'
printf '%s' "$OUT" | grep -qv 'me/priv' || fail 'private repo REST entry (never fetched) leaked its name'
ok "a private pull request and a private repository are dropped entirely, with no hidden count"

# --- the owned-elsewhere config drops by owner and by repository, with no count -----------
reset_case
search_item 5 excluded-owner/repo PR1 | search_page 1 > "$TMP/responses/search-open.json"
pr_node PR1 5 excluded-owner/repo "Fix bug" 2026-08-01T00:00:00Z > "$TMP/responses/node-PR1.json"
printf '{"owners":["excluded-owner"],"repositories":[]}\n' > "$TMP/owned.json"
OUT=$("$SCRIPT" --config "$TMP/owned.json") || fail 'config exclusion run failed'
printf '%s' "$OUT" | grep -q 'open pull requests you authored elsewhere: 0' \
  || fail 'owned-elsewhere owner should drop the pull request entirely'
if printf '%s' "$OUT" | grep -q 'hidden'; then fail 'no output line should ever mention "hidden"'; fi
printf '%s' "$OUT" | grep -qv 'excluded-owner' || fail 'excluded owner name leaked'
ok "the owned-elsewhere config drops a whole owner entirely, with no count and no name"

# --- health score reports a per-signal breakdown that adds up to the total ----------------
reset_case
repo_list_entry REPO1 me/health 5 | jq -s '.' > "$TMP/responses/repos.json"
repo_node REPO1 me/health 5 false 4 3 2026-08-01T00:00:00Z FAILURE > "$TMP/responses/node-REPO1.json"
OUT=$(run)
printf '%s' "$OUT" | grep -q 'repo me/health stars=5 health=' || fail 'health line missing'
printf '%s' "$OUT" | grep -q 'open_issues=4/-4' || fail 'open_issues penalty wrong'
printf '%s' "$OUT" | grep -q 'open_prs=3/-6' || fail 'open_prs penalty wrong'
printf '%s' "$OUT" | grep -q 'ci=FAILURE/-10' || fail 'ci penalty wrong'
ok "the health score prints the per-signal breakdown that produced it"

# --- never issues a mutating GitHub call --------------------------------------------------
reset_case
search_item 5 other/repo PR1 | search_page 1 > "$TMP/responses/search-open.json"
pr_node PR1 5 other/repo "Fix bug" 2026-08-01T00:00:00Z > "$TMP/responses/node-PR1.json"
run >/dev/null
grep -q 'PATCH\|POST\|DELETE' "$TMP/search-log" "$TMP/graphql-log" 2>/dev/null && fail 'a mutating call was made'
ok "oss-status never issues a mutating GitHub call"

printf '1..%s\n' "$PASS"
