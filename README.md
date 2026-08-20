# speckit-pipeline

Run the [spec-kit](https://github.com/github/spec-kit) phases as **separate
`claude -p` processes** — one model, effort level, tool allowance and spend
ceiling per phase — instead of one long conversation that does all four.

```
specify → [clarify] → plan → tasks → [analyze] → implement
 opus                 opus   sonnet            sonnet
```

## Why processes rather than one session

Running the whole pipeline in one context has four problems that only a
per-process boundary fixes:

- **One model for four different jobs.** Writing a specification and ticking off
  47 mechanical tasks do not want the same model or the same reasoning effort.
  `--model` and `--effort` are per-process flags; there is no way to change them
  mid-conversation.
- **You keep paying for the transcript.** Every tool call, file dump and test
  run from the specify phase is still in the window during implementation. Here
  each phase's transcript dies with its process. The handoff is the files on
  disk, which is what spec-kit already writes.
- **No ceiling.** `--max-budget-usd` and `--max-turns` bound a phase by
  arithmetic. Inside a session, a phase that goes wrong is bounded by you
  noticing.
- **"Please stop before implementing" is not a control.** Told exactly that in
  prose, an orchestrator agent once ran the full pipeline, merged two pull
  requests and deployed them. `--disallowed-tools` is enforced by the harness:
  for every phase but implementation, pushing and merging are simply not tools
  the process has.

What you give up is conversation. A headless phase cannot ask you anything — so
when a phase needs a human, the pipeline stops and hands you the session id to
pick that phase back up interactively. See [Gates](#gates).

## Install

### Option A — clone and run

```bash
git clone https://github.com/<you>/speckit-pipeline ~/code/speckit-pipeline
ln -s ~/code/speckit-pipeline/bin/spec-run      /usr/local/bin/spec-run
ln -s ~/code/speckit-pipeline/bin/spec-bootstrap /usr/local/bin/spec-bootstrap
```

### Option B — as a Claude Code plugin

```
/plugin marketplace add <you>/speckit-pipeline
/plugin install speckit-pipeline
```

Installed at user scope, so `/spec-run` and `/spec-status` are available in
**every** project without per-project setup. The plugin bundles the engine, so
both options give you the same thing.

Requires `claude`, `jq`, `git`, and `bash`. `spec-run` checks all of them before
spending anything.

## Use

Once per repository:

```bash
spec-bootstrap                    # installs .claude/skills/speckit-* and .specify/
```

Then, per feature:

```bash
spec-run "add a CSV export to the metrics page"   # start
spec-run --resume                                 # continue where it stopped
spec-run --with clarify --stop-after plan "..."   # scope only, no code
spec-run --dry-run --only plan                    # print the invocation, run nothing
spec-run --list                                   # show the configured phases
```

Or from inside Claude Code: `/spec-run <description>` and `/spec-status`.

## Phases

| Phase | Model | Effort | Ceiling | MCP | Optional |
|---|---|---|---|---|---|
| specify | opus | high | $5 / 60 turns | dropped | |
| clarify | opus | high | $3 / 40 turns | dropped | `--with clarify` |
| plan | opus | high | $8 / 80 turns | dropped | |
| tasks | sonnet | medium | $5 / 60 turns | dropped | |
| analyze | opus | high | $3 / 30 turns | dropped | `--with analyze` |
| implement | sonnet | medium | $40 / 400 turns | kept | |

All of that is data, in
[`plugins/speckit-pipeline/lib/phases.json`](plugins/speckit-pipeline/lib/phases.json).
Retuning which model runs which phase must never require editing the engine, so
it doesn't. Per-run overrides:

```bash
spec-run --model plan=sonnet --effort tasks=low --budget 25 "..."
```

Phases that talk to nothing external run with `--strict-mcp-config` and an empty
server list: a phase should not pay for a tool list it cannot use. Implementation
keeps its MCP servers.

## Verification

**A phase's own report is never the authority.** A process can exit 0 without
having done the thing, and a model can narrate a success it did not achieve. So
after every phase the engine reads the artifact off disk and judges that:

| Verdict | Meaning |
|---|---|
| `ok` | the artifact is present and coherent — advance |
| `needs_input` | it exists but records an open question (an unresolved `[NEEDS CLARIFICATION]`, or tasks left unchecked) — stop and ask |
| `failed` | absent, or too thin to have been finished |
| `unevaluated` | the phase declares no artifact. **Not a pass.** "The check passed" and "the check never ran" are different facts. |

Then a **scope check**: whatever the phase touched is compared against its
declared `write_scope`. A specify phase that writes source code is reported and
the run stops. Paired with the deny list, a stray write cannot reach anything
irreversible.

The comparison is against the tree **as it was when that phase started**, never
against a clean tree — the working tree is yours, and a file that was already
dirty is not the phase's doing. Content hashes are used rather than `git status`
lines, so a file that was already dirty and is then changed *again* is still
attributed correctly. (Both of those are corrections: the first version compared
against clean, and on the first real run it blamed a phase for the 14 skill files
`spec-bootstrap` had just installed and for the caller's own log file, failing a
`specify` that had done everything right.)

State is recorded at `specs/<feature>/.pipeline/state.json` — status, session id,
model, effort, cost, turns and artifact hash per phase — with a tab-separated
`cost.log` beside it. That file is the resume authority, because a present
`plan.md` cannot distinguish "planning finished" from "planning was killed
halfway through writing it".

## Gates

A gate is a stop the **pipeline** owns, not a sentence in a prompt.

- `gate: on_needs_input` (default) — advance while the artifact verifies clean.
- `gate: always` — always pause. `clarify` is configured this way; it exists to
  ask you things.
- `--stop-after plan`, `--gate all`, `--gate none` override per run.

`--gate none` waives the *configured pauses* only. It cannot suppress a
`needs_input` or `failed` stop: those are returned before the gate policy is
consulted, so there is no flag that carries the pipeline past an unresolved
`[NEEDS CLARIFICATION]` or a task list that is still half-unchecked.

When the pipeline stops it prints both continuations:

```
claude --resume 6f2c…        # pick that phase's own thread back up, in conversation
spec-run --resume            # carry on; phases already ok are skipped
```

Resuming into the phase's own session is usually what you want: your answers land
in the context that asked the question.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | every selected phase verified ok |
| 1 | a phase failed, or a prerequisite is missing |
| 2 | stopped at a gate, or a phase needs input |
| 3 | usage error |

Suitable for `make`, CI, or a cron job — with the caveat that a `2` means a human
is genuinely required.

## Known bounds

Stated rather than implied, because the next reader will otherwise assume the
guarantee is bigger than it is.

- **The deny list withholds tools; it does not verify intent.** A phase cannot
  merge a pull request. It can still write a bad spec, and nothing here detects
  that. Merging is withheld from *every* phase, including implementation.
- **The scope check detects, it does not prevent.** A specify phase that writes
  source is caught after the fact, not stopped mid-write. Prevention would need
  path-scoped tool denials, which are not verified here.
- **`--max-budget-usd` is documented as bounding API spend.** On subscription
  auth, confirm it enforces before treating it as the safety rail; `--max-turns`
  is the fallback ceiling and is always set.
- **No `--json-schema` on the phase result.** The artifact is the authority, so a
  second, unverified report channel would add risk without adding information.
  The phase's prose is kept only to show you when something goes wrong.
- **All phases share one working tree,** because the handoff is the files. If you
  want isolation, make the worktree yourself and point `--repo` at it.
- **`--bare` is deliberately unused.** It would trim the phase's context, but it
  forces `ANTHROPIC_API_KEY`-only auth and never reads OAuth or the keychain.

## Vendored spec-kit

`plugins/speckit-pipeline/assets/` carries the spec-kit skills and `.specify`
scaffold, so a fresh repository needs one `spec-bootstrap` and no separate
spec-kit install. Provenance and the pinned version are in
[`assets/UPSTREAM.md`](plugins/speckit-pipeline/assets/UPSTREAM.md).

The skills install into the project as **unnamespaced** `.claude/skills/speckit-*`
rather than being served from the plugin namespace. That is not incidental:
spec-kit's mandatory `before_specify` hook resolves `speckit.git.feature` to the
slash command `/speckit-git-feature`, a bare name. Under a plugin namespace that
hook silently fails to resolve, no feature branch is created, and the phase
reports success over a directory the rest of the pipeline cannot find.

## Tests

```bash
./tests/run.sh          # shellcheck + 70 fixture assertions
```

No test spends money: the invocation assertions run under `--dry-run` and check
the exact argv. Assertions here are mutation-checked, and where a mutation is not
obvious it is named in a comment. Three defects in this suite are worth knowing
about, because each one passed while checking nothing:

- Two assertions matched `printf %q` **escaping** rather than content, and passed
  against a build that denied pushing to every phase.
- `verify.sh` was sourced without `common.sh`, so `file_sha` was missing, every
  hash compared empty-to-empty, and two scope assertions passed because
  *everything* looked changed. The library now refuses to load without its
  dependency rather than miscomparing.
- The harness named its counter `ok()`, which `common.sh` also defines. The
  library's definition won partway through the run, so ~80 assertions printed
  ticks and incremented nothing: the suite reported **"9 passed, 0 failed"** and
  exited 0. Hence `TALLY_FLOOR` — a run that counts fewer assertions than the
  floor fails, because nothing else distinguishes "all of them ran" from "most of
  them printed".
