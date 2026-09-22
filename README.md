# oss-mate

This repository owns agent skills and small tools for monitoring and contributing to external open-source projects.

## GitHub notification monitor

`bin/github-notifications` performs a bounded read-only poll of relevant notifications for the authenticated GitHub user.
It uses the logged-in `gh` CLI, requests all notification threads, applies its narrow relevance filter locally, follows pagination, honors GitHub's `X-Poll-Interval`, and never marks notifications read or mutates a repository.
Participating reasons surface comments on the user's pull requests in other open-source repositories and state changes when those pull requests merge.
Subscribed or manual notifications surface a pull request or issue opened by someone else in a public repository owned by the authenticated user.
Subscribed notifications from other watched repositories are excluded.
The authenticated login is resolved read-only for this classification, cached with the cursor, and never printed.
The first poll looks back 24 hours by default instead of loading full history.
Later polls overlap the durable cursor by six hours and deduplicate on thread id plus `updated_at`.
The script atomically stores its successful cursor, GitHub `Last-Modified` value, dedup keys, and redacted pending projection in `github-notifications.json` under its state directory.
Notifications whose reason is `ci_activity` advance the cursor and dedup set but never appear in the check line, pending output, or durable pending projection.
The default state directory is `$OSS_MATE_STATE_DIR`, then `$XDG_STATE_HOME/oss-mate`, then `~/.local/state/oss-mate`.
The script header and `--help` are the authoritative interface reference.

A relevant public notification is external by default.
A relevant private notification is excluded and reported only as part of a count.
An optional config file lists additional owners and repositories whose notifications are excluded and reported only as part of that count.
The default config path is `github-notifications-owned.json` in the state directory, and `--config` or `$OSS_MATE_OWNED_CONFIG` can select another path.

```json
{
  "owners": ["another-owner"],
  "repositories": ["public-owner/already-owned-repository"]
}
```

Owner and repository comparisons are case-insensitive.
No notification body or comment text is fetched, printed, or persisted.
Private and config-listed repository names and subject titles are neither printed nor persisted.
Subject titles from public external repositories are untrusted display data, stripped of control characters, and limited to 160 characters.

## Running it periodically

The `check` verb prints one line only when something new surfaced, so any scheduler or agent hook can run it.
Daily is enough because the goal is never losing track of a relevant thread, not real-time response.
The following cron entry runs the check once daily at 09:00 with explicit durable state and config paths.

```cron
0 9 * * * /absolute/path/to/oss-mate/bin/github-notifications --state-dir "$HOME/.local/state/oss-mate" --config "$HOME/.config/oss-mate/github-notifications-owned.json" check
```

The script also enforces a daily minimum between API polls by default, so a more frequent caller stays silent without making an API call.
`OSS_MATE_MIN_POLL_SECONDS` overrides that minimum when a different cadence is deliberately required, while GitHub's `X-Poll-Interval` remains an additional floor.
The default budget is 20 seconds and can be changed with `--budget` when the calling system has a different execution limit.
Run `bin/github-notifications --state-dir "$HOME/.local/state/oss-mate" pending` to inspect the redacted durable details after a nonempty check result.
After the details have been classified and reported to the operator, run the same command with `ack` to clear the local pending projection while preserving the cursor and dedup set.
`ack` does not mark anything read on GitHub.
To mark the pending threads read on GitHub, run the same command with `mark-read --yes`.
Without `--yes`, `mark-read` prints how many pending threads would be marked read and makes no GitHub mutation.
`mark-read` processes pending threads one at a time, clears each local row only after its remote mark-read succeeds, and stops with a one-line summary if a remote call fails so a later run can resume the remainder.
Optional thread ids after `mark-read` narrow the set but never widen it beyond the current pending projection.
`check`, `pending`, `show`, and `ack` never mark a thread read on GitHub.
The non-user-invocable skill at `skills/github-notification-triage/SKILL.md` owns the generic read-only classification and summary procedure.

## Development

Run the executable behavior suite with `tests/github-notifications.test.sh`.
Run `shellcheck bin/*` before proposing changes.
