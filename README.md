# oss-mate

This repository owns agent skills and small tools for monitoring and contributing to external open-source projects.

## Daily GitHub review

`bin/github-daily-review` is the single operator entry point.
It performs one bounded read-only pass over GitHub and reports three sets:

1. `new-issues` are issues opened in public repositories the authenticated user owns, since the last successfully reported review.
2. `new-prs` are pull requests opened by other authors in those same repositories, since that same point.
3. `my-prs` is every open pull request the authenticated user authored in a public repository they do not own.

The third set is the whole inventory rather than a stale list, so a healthy pull request still appears.
Each `my-pr` row carries a mergeability verdict of `stale`, `mergeable`, or `unknown`, and an `action` list only when it needs attention.
The action values are `stale`, `changes-requested`, `checks-failing`, and `new-activity`, all derived read-only from GitHub data.
`new-activity` means the pull request was updated since the last successfully reported review.
Stale means the pull request is not mergeable into its repository default branch per GitHub's `mergeable` field, never from age, inactivity, or commits-behind.
An unknown or still-computing mergeability is reported as `unknown` and is never treated as stale.

The tool uses the logged-in `gh` CLI, resolves the authenticated login once per run, and never prints it.
It manages no token of its own.

### The boundary and the reporting handshake

New and changed are judged against the last **successfully reported** review, not the last poll.

- `check` is daily-gated, collects the review, and prints exactly one line when the review has anything.
- `pending` (alias `show`) prints the redacted review grouped in the three sets; that output is the report.
- `ack` records the review as successfully reported, which advances the boundary and clears pending.

Until `ack` runs, a later `check` re-includes everything that was never reported, so an interruption loses no work.
A partial API failure mid-collection leaves the previous pending review intact, prints one line, and exits nonzero.
Nothing is written to the state file until a collection completes, so a failed or budget-exhausted run publishes nothing.

```
github daily review: new-issues=2 new-prs=3 my-prs=6 (action=2 stale=1) excluded=5; run github-daily-review pending
```

A single atomic mode-0600 `github-daily-review.json` under the state directory holds the last successfully reported review time, the prior inventory of the third set, the already-reported issue and pull request keys, the notification dedup keys, and the notification thread ids behind the current pending review.
The default state directory is `$OSS_MATE_STATE_DIR`, then `$XDG_STATE_HOME/oss-mate`, then `~/.local/state/oss-mate`.
The script header and `--help` are the authoritative interface reference.

### Evidence and deduplication

GitHub search supplies the three inventories and the notifications endpoint supplies arrival signals for the two owned-repository sets.
Issues and pull requests are deduplicated by repository plus number, and notification threads by thread id, so an item present in both sources is reported once.
Notifications whose reason is `ci_activity` advance the dedup set but never surface.
Per-item pull request detail is read in batched GraphQL requests of roughly thirty nodes each rather than one request per pull request, so a full review completes well inside the default budget.
Later notification polls overlap their stored cursor by six hours and never reach back further than seven days, because the durable boundary lives in the search inventories.

### Redaction

A public item is reported with its repository, number, author flag, timestamps, bounded title, and indicators.
A private repository, or one listed in the optional owned-elsewhere config file, appears only as a per-set count.
Its name, number, and title are neither printed nor persisted.

```json
{
  "owners": ["another-owner"],
  "repositories": ["public-owner/already-owned-repository"]
}
```

Owner and repository comparisons are case-insensitive.
The default config path is `oss-mate-owned.json` in the state directory, falling back to `github-notifications-owned.json` there; `--config` or `$OSS_MATE_OWNED_CONFIG` selects another path.
No issue body, pull request body, or comment text is fetched, printed, or persisted.
Titles from public repositories are untrusted display data, stripped of control characters, and limited to 160 characters.

### The two explicit mutations

`check`, `pending`, `show`, and `ack` are read-only and never invoke either of the following.

`mark-read [--yes] [thread-id ...]` marks read on GitHub only the notification threads behind the last acknowledged review.
It refuses before any review has been acknowledged, so a summary that was never delivered is never dismissed.
Without `--yes` it prints how many threads it would mark read and makes no GitHub call.
With `--yes` it PATCHes one thread at a time and clears each local row only after that thread's remote success, so a failure stops with a one-line summary and a later run resumes the remainder.
Optional thread ids narrow the set to the acknowledged or current pending review and never widen it.

`close [--yes] owner/repo#N [...]` closes only explicitly named pull requests that are open, stale, and self-authored.
Without `--yes` it prints exactly what it would close and makes no mutation.
It has no bulk or `--all` form, and no read path ever calls it.

## Running it daily

The `check` verb prints one line only when there is something to review, so any scheduler or agent hook can run it.
Daily is enough because the goal is never losing track of a relevant thread, not real-time response.

```cron
0 9 * * * /absolute/path/to/oss-mate/bin/github-daily-review --state-dir "$HOME/.local/state/oss-mate" --config "$HOME/.config/oss-mate/oss-mate-owned.json" check
```

The script also enforces a daily minimum between API polls by default, so a more frequent caller stays silent without making an API call.
`OSS_MATE_MIN_POLL_SECONDS` overrides that minimum when a different cadence is deliberately required, while GitHub's `X-Poll-Interval` remains an additional floor.
The default budget is 20 seconds and can be changed with `--budget` when the calling system has a different execution limit.
On budget exhaustion the run stops with one line and a nonzero exit, keeping the previous pending review intact.

After a nonempty check line, run the same command with `pending`, report the review, and only then run `ack`.
The non-user-invocable skill at `skills/github-daily-review/SKILL.md` owns the generic read-only classification and summary procedure.
`mark-read --yes` and `close --yes` remain separate explicit steps the operator decides on after the summary.

## Development

Run the executable behavior suite with `tests/github-daily-review.test.sh`.
Run `shellcheck bin/*` before proposing changes.
Pull requests and pushes to `main` run the same shellcheck and behavior-test suite in GitHub Actions.
