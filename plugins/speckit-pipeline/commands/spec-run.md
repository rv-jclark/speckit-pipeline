---
description: Run the spec-kit pipeline — one isolated claude process per phase, each with its own model
argument-hint: "<feature description> | --resume | --stop-after plan | --with clarify"
allowed-tools: Bash, Read, Edit, Glob, Grep
---

Run the spec-kit pipeline for: **$ARGUMENTS**

## What to do

Run the engine and let it own the phases:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/spec-run" $ARGUMENTS
```

Each phase runs as its own `claude -p` process with its own model, effort level,
tool allowance and spend ceiling. **Do not run any phase yourself in this
conversation.** You are the front end: your job is to launch the engine, read
what it reports, and help with the parts that need a human. Re-deriving a phase
here defeats the entire point — it puts the transcript back in this window and
runs it on this window's model.

## Make the run visible to the user

A `Bash` tool call **buffers**: it returns one blob when the command finishes, and
its output is shown to you and *not reliably to the user*. A phase takes minutes
and a full entry far longer than the foreground window, so it will be backgrounded
anyway. Invoking this from a slash command does not change any of that — a skill
is instructions, not an executor.

So do these two things, in this order, every time:

1. **Launch it in the background, logging to a path the user can follow.** Use
   `~/code/speckit-pipeline/.runs/<name>.log` (create the directory if needed), not
   a random `/tmp` name only you know. Tell them the `tail -f` command.
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
   and abandonment.** The `tail -f` above outlives the Monitor that started it, and
   nothing else reaps it:

   ```
   "${CLAUDE_PLUGIN_ROOT}/bin/spec-reap" <logfile>
   ```

   Use that, not `pkill` directly. It matches on the **full logfile path** so a
   concurrent run's watcher survives, ignores a `tail -200` somebody is reading
   with, and picks a process-table query the host can actually answer — **`pkill`
   and `pgrep` do not exist under Git Bash on Windows**, where msys ships
   neither, so the bare `pkill` form failed with `command not found` and leaked
   the watcher it was supposed to reap. Exit `1` means the process table could
   not be read and **nothing is known**, which is not the same as a clean reap;
   it prints the manual command to run from a shell that can.

   `spec-reap --all` reaps every watcher on a `.runs/` log, which is the one to
   reach for when they have already accumulated.

   ⚠️ Measured 2026-09-01 on the author's machine: **17 orphaned watchers**, each a
   `tail` plus a `grep`, the oldest following a log last written **five days**
   earlier, one already reparented to `ppid=1`. They cost little individually and
   accumulate silently — the host they were found on had reached load average 338
   with swap 97% consumed, and these were part of it. The leak is *here*, in the
   thing that spawns them: `timeout_ms: 3000000` bounds the Monitor, not the pipeline
   it launched, so a watcher survives its Monitor by days. Do not rely on a periodic
   cleanup elsewhere to cover this — the spawner reaps what it spawns.

Pass `--stream` so there is per-step output to filter in the first place.

If the user wants to watch closely, offer to let them launch it themselves —
`! spec-run --stream "<description>"` puts the output natively in their view and sidesteps
all of the above. It is also the cheapest way to run one: no event reaches this
conversation at all, so nothing here is re-read while the phases work.

## Reading the exit code

| Exit | Meaning | What you do |
|---|---|---|
| `0` | every selected phase verified ok | report the summary table and the total cost |
| `1` | a phase failed, or a prerequisite is missing | diagnose from the printed reason; the engine names the cause |
| `2` | a gate, or a phase needs human input | see below |
| `3` | usage error | fix the invocation |

## On exit 2

The engine has already printed which phase stopped and why. Do this:

1. Read the artifact it names (`spec.md`, `plan.md`, `tasks.md`) and the run
   state at `specs/<feature>/.pipeline/state.json`.
2. Surface the open questions **here, in conversation** — this is the one thing a
   headless phase cannot do, and the reason this command exists.
3. When the user has answered, prefer picking the phase's own thread back up so
   the answers land in the context that asked:
   `claude --resume <session_id from state.json>`
   Otherwise edit the artifact directly to record the decision.
4. Continue with `"${CLAUDE_PLUGIN_ROOT}/bin/spec-run" --resume`. Phases already
   recorded `ok` are skipped, so this is cheap and safe to repeat.

## On exit 1

Report the failure verbatim and stop. Do not retry the phase automatically and
do not work around it — a phase that failed verification did not produce a usable
artifact, and a second attempt over a half-written file is how a bad spec becomes
a bad plan. Fix the named cause first.

## Never

- Never hand-write `spec.md`, `plan.md` or `tasks.md`. They are generated by the
  skills, which carry the project's constitution, templates and hooks.
- Never pass `--gate none` to get past a gate the user has not seen.
- Never merge a pull request or trigger a deploy as part of this command. Those
  tools are withheld from the phases deliberately, and that applies to you here.
