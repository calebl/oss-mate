# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

## Shape

There is one operator entry point, `bin/github-daily-review`, with one state file, one daily check line, and one pending view.
Keep it that way; do not add a second tool, state file, or check line for a new kind of GitHub work.
Its script header and `--help` are the authoritative interface reference, and `README.md` explains the three sets and the ack handshake.
Agent skills live at `skills/<name>/SKILL.md` with the frontmatter shape of `skills/oss-contribute/SKILL.md`; after adding one, confirm `npx skills add <worktree path> --list` discovers it and add its README section.

## Standing rules for tools in this repository

Authenticate through the logged-in `gh` CLI; never manage, read, or store a token.
Keep tools generic: never name a framework, employer, role, or private repository anywhere in code, tests, docs, or output.
Exclusions come only from the local owned-elsewhere config file the operator passes in.
Never draft a response or do work beyond what the invoked verb explicitly does.
Recommend a daily cadence, because the goal is never losing track of a relevant thread rather than real-time response.
Every read path stays read-only; a mutation is always its own explicit verb behind `--yes`, never reached from a read path.
Never add agent attribution to a commit, pull request, or any file.

## Conventions

Markdown uses one full sentence per line and a plain dash for bullets.
`shellcheck -S error bin/* tests/*.sh` and every `tests/*.test.sh` must pass; CI runs exactly that (`.github/workflows/test.yml`).
Behavior tests drive a fake `gh` on `PATH` rather than the network; add coverage there, not by relaxing a check.
Validate an authenticated change against a throwaway `--state-dir` inside the worktree, never the operator's state directory.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
