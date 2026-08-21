---
description: Upgrade a project's spec-kit scaffold to the vendored version, preserving what the project customised
argument-hint: "--check | --dry-run | --scan ~/code"
allowed-tools: Bash, Read
---

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/spec-upgrade" $ARGUMENTS
```

## What to do

**Run `--dry-run` first and show the user the plan**, unless they explicitly asked
you to just do it. This writes to their scaffold, and the plan is short enough to
read.

| Exit | Meaning | What you do |
|---|---|---|
| `0` | upgraded, already current, or a clean `--check` | report what changed |
| `1` | refused, or something needs a human | relay the reason; do not work around it |
| `2` | `--check`/`--scan` found drift | report which projects and offer the dry run |
| `3` | usage error | fix the invocation |

## On a refusal

The usual cause is uncommitted changes in `.specify/` or `.claude/skills/`. Do
**not** stash or commit them on the user's behalf to get past it — git is the only
undo this operation has, and clearing the way removes it. Show what is dirty and
let them decide.

## After an upgrade

Report the review and undo commands it printed, and say whether any templates
were preserved as overrides. If it reports that the upgraded scaffold fails the
pipeline's skill check, that is a bug in the vendored bundle — tell the user to
`git checkout -- .specify .claude/skills` and say so plainly rather than trying to
patch around it.

## Never

- Never pass `--prune` unless the user asked. It deletes scaffold files the new
  version no longer ships, and "no longer shipped" is not the same as "unused
  here".
- Never pass `--pristine` unless the user asked. It replaces templates they
  edited instead of preserving them as overrides.
- Never upgrade a project the user has not named. `--scan` is read-only and safe;
  the upgrade is not, and a directory under `~/code` is not necessarily theirs.
