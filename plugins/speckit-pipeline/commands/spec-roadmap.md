---
description: Plan or execute a roadmap — a series of specs that ship in order, each merged by the runner before the next begins
argument-hint: "plan \"<the larger goal>\" | show | run"
allowed-tools: Bash, Read, Edit, Glob, Grep
---

Roadmap operation: **$ARGUMENTS**

## What to do

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/spec-roadmap" $ARGUMENTS
```

A roadmap is a series of specs that ship **in order**, each as its own branch and
pull request, each merged before the next begins — because the next entry has to
plan against the code the previous one actually landed.

**The runner merges each entry itself**, by default: once `review.md` is clean
and every check on the pull request is green, it commits, pushes, opens (or
reuses) the PR and merges it, then starts the next entry. It stops at the merge
gate only when one of those conditions fails, and says which.

**Do not run any phase yourself, and do not merge by hand to get past the gate.**
You are the front end: launch the runner, read what it reports, and help with
what it stopped on. When it stops at the merge gate, the fix is the reason it
printed — a failing check, a review finding, a branch-protection refusal — and
then re-running `spec-roadmap run`, which retries the merge. Merging around that
reason with `gh pr merge` skips exactly the check that stopped it. The user can
merge by hand; that is their call, not yours. If they want every merge to be
theirs, `--no-auto-merge` or `"auto_merge": false` in the roadmap file does it.

## Make the run visible to the user

A `Bash` tool call **buffers**: it returns one blob when the command finishes, and
its output is shown to you and *not reliably to the user*. A phase takes minutes
and a full entry far longer than the foreground window, so it will be backgrounded
anyway. Invoking this from a slash command does not change any of that — a skill
is instructions, not an executor.

So do these two things, in this order, every time:

1. **Launch it in the background, logging to a path the user can follow.** Use
   `~/code/speckit-pipeline/.runs/<name>.log`, not a random `/tmp` name only you
   know, and tell them the `tail -f` command. Use exactly this shape, as a `Bash`
   call with `run_in_background: true`:

   ```bash
   mkdir -p ~/code/speckit-pipeline/.runs
   "${CLAUDE_PLUGIN_ROOT}/bin/spec-roadmap" run --stream > ~/code/speckit-pipeline/.runs/<name>.log 2>&1
   ```

   🛑 **`2>&1` is not optional.** The engine writes `✗` (a phase failed) and `!`
   (a stall, a phase that needs input) to STDERR. Redirect stdout alone and the
   log shows phases starting and then nothing — no filter can match a failure
   line that never reached the file. Measured 2026-09-24: 75 of 424 launches in
   the author's transcripts redirected stdout only, and every one of them could
   fail silently. `run_in_background: true` is the other half: the exit
   notification arrives whatever the log contains, so the end of the run is
   never something you have to notice.
2. **Attach a `Monitor` to that log**, so progress reaches the conversation as it
   happens instead of when you next check:

   ```
   Monitor({
     command: "tail -f -n +1 <logfile> | grep -E --line-buffered '^→|^✓|^✗|^!|^Traceback|: line [0-9]+: '",
     description: "<what is running>",
     timeout_ms: 3000000
   })
   ```

   Filter to **phase markers and failure signatures only** — `→` a phase starts,
   `✓` one finished, `✗` one failed, `!` a warning or a stall, and a shell or
   Python crash. Per Monitor's own rule the filter must match failure states too;
   one that greps only for success is silent through a crash. The run's END needs
   no pattern: the backgrounded command's own exit notification reports it.

   🛑 **Every event re-reads this whole conversation, on this conversation's
   model.** Measured 2026-09-24 across 108 sessions that supervised a run: 3,773
   Monitor events led to ~30,000 follow-up calls and **18.2B tokens** — 45% of
   everything those sessions spent, and more than half the cost of every headless
   phase combined. The filter used to include `· (Write|Edit|MultiEdit)` and a bare
   `Error`; those alone were 1,072 events, each one waking a context of 400k–966k
   tokens to learn that a file had been written. So:

   - On a `→` or `✓` event, **reply in one line and make no tool calls.** Do not
     run `spec-status`, tail the log or open an artifact to confirm what the event
     already said.
   - Investigate only on `✗`, `!`, a crash line, or the run exiting.
   - When the Monitor **expires**, do not re-arm it. The backgrounded run still
     notifies you when it exits; a re-armed watcher is one more source of wakes.
3. 🛑 **Reap the watcher when the run ends — on EVERY exit path, including failure
   and abandonment:**

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/spec-reap" <logfile>
   ```

   Use that, not `pkill` directly. It matches on the **full logfile path** so a
   concurrent roadmap's watcher is left alone, ignores a `tail -200` somebody is
   reading with, and picks a process-table query the host can actually answer —
   **`pkill` and `pgrep` do not exist under Git Bash on Windows**, where msys
   ships neither, so the bare `pkill` form failed with `command not found` and
   leaked the watcher it was supposed to reap. Exit `1` means the process table
   could not be read and **nothing is known**, which is not a clean reap; it
   prints the manual command to run from a shell that can.

   A roadmap runs many entries and so spawns many watchers, which makes this worse
   here than in `spec-run`: measured 2026-09-01, **17** orphaned `tail`+`grep` pairs
   were following logs from finished runs, the oldest **five days** stale. See
   `spec-run.md` for the full measurement — `timeout_ms` bounds the Monitor, not the
   pipeline it launched, so the watcher outlives it by days. `spec-reap --all`
   reaps every watcher on a `.runs/` log, which is the one to reach for once a
   roadmap has left a pile of them.

Pass `--stream` so there is per-step output to filter in the first place.

If the user wants to watch closely, offer to let them launch it themselves —
`! spec-roadmap run --stream` puts the output natively in their view and sidesteps
all of the above. It is also the cheapest way to run one: no event reaches this
conversation at all, so nothing here is re-read while the phases work.

## Reading the exit code

| Exit | Meaning | What you do |
|---|---|---|
| `0` | every entry has landed | report the summary |
| `1` | an entry failed, or a prerequisite is missing | diagnose from the printed reason |
| `2` | **waiting on the user** — see below | help them get unblocked |
| `3` | usage error | fix the invocation |

## On exit 2

Read what it printed; it distinguishes three situations and so should you.

**An entry's pipeline finished but the runner did not merge it.** It printed
`not merged automatically: <reason>`. Work on that reason: read the failing
check's log, the unresolved finding in `review.md`, or the protection rule gh
quoted. Fixing code means resuming the entry (`spec-run --resume` re-enters
implement on the tasks review appended); then `spec-roadmap run` retries the
merge. If auto-merge is off for this roadmap, offer to review the diff against
the entry's `spec.md`, and let the user merge it.

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
