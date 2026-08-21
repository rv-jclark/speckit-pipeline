---
description: Plan or execute a roadmap — a series of specs that must ship in order, one merge at a time
argument-hint: "plan \"<the larger goal>\" | show | run"
allowed-tools: Bash, Read, Edit, Glob, Grep
---

Roadmap operation: **$ARGUMENTS**

## What to do

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/spec-roadmap" $ARGUMENTS
```

A roadmap is a series of specs that ship **in order**, each as its own branch and
pull request, each merged before the next begins. The runner takes one entry
through the full pipeline and then stops — because the next entry has to plan
against the code the previous one actually landed.

**Do not run any phase yourself, and do not merge anything.** You are the front
end: launch the runner, read what it reports, help with the parts that need a
human. Merging is the user's act, and no phase here is given the tools for it.

## Reading the exit code

| Exit | Meaning | What you do |
|---|---|---|
| `0` | every entry has landed | report the summary |
| `1` | an entry failed, or a prerequisite is missing | diagnose from the printed reason |
| `2` | **waiting on the user** — see below | help them get unblocked |
| `3` | usage error | fix the invocation |

## On exit 2

Read what it printed; it distinguishes three situations and so should you.

**An entry's pipeline finished and is waiting to be merged.** Offer to help
review it: read the branch's diff and the entry's `spec.md`/`tasks.md`, and say
whether the work matches what the roadmap entry asked for. Then let the user open
and merge the PR themselves. When they have, `spec-roadmap run` continues.

**A phase inside the entry needs input.** That is a `spec-run` gate, not a
roadmap one. Surface the questions here, in conversation, and continue with
`spec-run --resume` before returning to the roadmap.

**It cannot tell whether an entry has landed.** This is deliberately *not*
treated as "not merged" — starting the next entry against a base that may already
contain this one produces a spec built on a false premise. Read the reason it
gave (usually a fetch that failed, or a base ref that does not exist), fix that,
and re-run.

## When planning a roadmap

`spec-roadmap plan "<goal>"` writes `.specify/roadmaps/<slug>.json` and stops.
**Read it back to the user before anything runs** — the split is the expensive
decision here. A wrong entry 1 poisons every entry above it, and finding that out
four specs deep costs four pipelines and four review cycles. Check in particular:

- is each entry shippable **on its own**, leaving the repo working?
- is the ordering a real dependency, or just a narrative?
- does each description say what the entry does **not** do, and which entry picks
  it up? That boundary is what the specify phase most often gets wrong when it
  cannot see the rest of the roadmap.

Edit the JSON directly if any of that is wrong. It is a plain authored file, and
correcting it before the first run is far cheaper than after.
