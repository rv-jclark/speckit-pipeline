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
git clone git@github.com:rv-jclark/speckit-pipeline.git ~/code/speckit-pipeline
ln -s ~/code/speckit-pipeline/bin/spec-run      /usr/local/bin/spec-run
ln -s ~/code/speckit-pipeline/bin/spec-bootstrap /usr/local/bin/spec-bootstrap
```

### Option B — as a Claude Code plugin

```
/plugin marketplace add rv-jclark/speckit-pipeline
/plugin install speckit-pipeline
```

Installed at user scope, so `/spec-run` and `/spec-status` are available in
**every** project without per-project setup. The plugin bundles the engine, so
both options give you the same thing.

⚠️ **This repository is private.** The marketplace install resolves over git, so
it works for anyone with read access and fails for everyone else. To share it,
either make the repository public or add the person as a collaborator — there is
no third option, and "it worked on my machine" here means "I am the owner".

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

## Permissions, and a custom phase runner

Each phase runs `--permission-mode acceptEdits` (configurable in
`phases.json`). In print mode there is **no interactive prompt**: a tool call the
harness will not allow is *denied and reported to the model*, which then either
works around it or gives up — it does not hang waiting for a human. Measured on
the smoke runs, spec-kit's own `create-new-feature.sh` and
`update-agent-context.sh` both ran fine under `acceptEdits`.

If your organisation blocks permission bypass and you drive Claude through a
wrapper that answers the prompts, point the engine at it:

```bash
spec-run --claude-bin claude-edits "..."     # or SPEC_RUN_CLAUDE_BIN=claude-edits
                                             # or defaults.claude_bin in phases.json
```

The named command is checked for two things before the first phase is billed:
that it **exists**, and that it **runs**. Flag support is deliberately *not*
probed. The version that tried was vacuously permissive — passing a flag
alongside `--help` short-circuits before option validation, so a flag that cannot
exist came back "accepted", and a second probe form disagreed with the first
about the same input. A check whose verdict depends on how you phrase it gets
reported as a guarantee and isn't one, so it was removed rather than softened
into a warning.

That failure is caught where it actually happens instead. A runner that rejects a
flag exits without doing any work, so the phase's artifact does not move and the
non-run rule fails it by name — with the runner's own stderr, stdout and exit
code preserved in `.pipeline/<phase>.result.json`. You get the exact flag it
objected to, in its own words, which is strictly more than the probe was telling
you.

One measured aside on why documentation is a bad basis for this: `--max-turns` is
accepted by `claude` 2.1.238 and appears **nowhere** in its `--help`. The
help-reading probe duly warned that a ceiling was missing while it was being
applied.

Denied tool calls are **counted and named**, not inferred. The CLI reports its
own refusals in the result (`permission_denials`), so a phase's note reads
`3 tool call(s) were DENIED to this phase (Bash, Write)` rather than leaving you
to guess from a thin artifact. An empty spec and "17 denials" are the same
artifact with completely different remedies.

Worth trying before reaching for a wrapper: `permission_mode` is already data in
`phases.json`, and the CLI accepts `dontAsk` and `bypassPermissions` as well as
`acceptEdits`. If your organisation's policy is what blocks those, the wrapper is
the answer; if it was only the interactive prompt, a one-line config change is.

### Can a phase ask you something mid-run?

No — and that is the real cost of the process boundary. A headless phase has no
channel to ask and wait, so its questions arrive **at the end**:

- the handoff contract requires every phase to close with
  `STATUS: ok | needs_input | failed — <sentence>` plus the specific questions a
  human must answer;
- the parent reads that from the phase's JSON, prints it under *"the phase's own
  account"*, and **writes it to `specs/<feature>/.pipeline/<phase>.result.json`**
  so it survives terminal scrollback;
- the phase's session id is recorded, so `claude --resume <id>` puts you in the
  thread that asked, with its full context intact.

What a phase cannot do is pause halfway and wait for you. If a decision is
genuinely needed *before* the work, that is what `clarify` is for — it is
configured `gate: always`, because asking is its entire job.

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

And a **completion check**. With `--output-format json`, a normal completion
always returns a result envelope — so no envelope plus a non-zero exit means the
phase did not finish, and what its artifact looks like is beside the point. This
was measured: SIGTERM-ing a live `plan` phase left a 3088-byte `plan.md` ending
at a plausible heading with no open markers, and it verified **`ok`** — the later
artifacts a finished plan writes (`research.md`, `data-model.md`, `contracts/`)
were simply absent and nothing looked for them. Byte counts and marker checks
cannot tell "finished" from "interrupted somewhere that happens to look
finished"; the exit code can. A rolling restart, a Ctrl-C and an OOM kill all
land here. The partial artifact is left on disk deliberately — it is the only
record of how far the phase got, and the next attempt overwrites it anyway.

And a **non-run check**. If a phase returns no parseable result *and* leaves its
artifact byte-identical, it is recorded `failed` — "the phase returned no
parseable result and did not change plan.md — it appears not to have run at
all". This is not hypothetical: reusing a `--session-id` that already exists
makes the CLI refuse and exit in about two seconds, and the plan phase then
verified clean against the `plan.md` its *previous* attempt had written. Two
seconds, empty output, reported `ok`. The pre/post artifact hash is what
separates "verified" from "nothing happened", and each attempt now gets a fresh
session id (the history is kept in `state.json`, so earlier threads stay
resumable).

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
- **A runner's flag support is unverified.** See above: it is detected at first
  use, not predicted.
- **`--max-budget-usd` is documented as bounding API spend.** On subscription
  auth, confirm it enforces before treating it as the safety rail; `--max-turns`
  is the fallback ceiling and is always set.
- **No `--json-schema` on the phase result.** The artifact is the authority, so a
  second, unverified report channel would add risk without adding information.
  The phase's prose is kept only to show you when something goes wrong.
- **A no-op is indistinguishable from an idempotent success** when the phase
  *does* return a parseable result. The non-run check only fires when both
  signals agree, which is deliberate: firing on an unchanged artifact alone would
  fail every legitimate re-run.
- **A phase cannot be interrupted with a question.** See above; questions arrive
  at the end, or `clarify` asks them up front.
- **All phases share one working tree,** because the handoff is the files. If you
  want isolation, make the worktree yourself and point `--repo` at it.
- **`--bare` is deliberately unused.** It would trim the phase's context, but it
  forces `ANTHROPIC_API_KEY`-only auth and never reads OAuth or the keychain.

## Licence

MIT, with one thing worth knowing: `plugins/speckit-pipeline/assets/` is vendored
from [github/spec-kit](https://github.com/github/spec-kit) (also MIT) and stays
under its own upstream licence. See `assets/UPSTREAM.md`.

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
./tests/run.sh          # shellcheck + 92 fixture assertions
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
- `mapfile` is bash 4; macOS ships **bash 3.2**, so it failed silently and left
  an array unbound, which made the *next* assertion pass with fewer arguments
  than it meant to check. A grep-based guard now fails the suite on any bash-4
  construct in the shipped scripts.
- The harness named its counter `ok()`, which `common.sh` also defines. The
  library's definition won partway through the run, so ~80 assertions printed
  ticks and incremented nothing: the suite reported **"9 passed, 0 failed"** and
  exited 0. Hence `TALLY_FLOOR` — a run that counts fewer assertions than the
  floor fails, because nothing else distinguishes "all of them ran" from "most of
  them printed".
