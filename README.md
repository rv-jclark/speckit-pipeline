# speckit-pipeline

Run the [spec-kit](https://github.com/github/spec-kit) phases as **separate
`claude -p` processes** — one model, effort level, tool allowance and spend
ceiling per phase — instead of one long conversation that does all four.

```
specify  →  [clarify]  →  plan  →  tasks  →  [analyze]  →  implement
 opus         opus         opus    sonnet      opus         sonnet
 high         high         high    medium      high         medium
```
Bracketed phases are opt-in (`--with clarify`). Every value there is data, not
code — see [Phases](#phases).

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

### Step 0 — prerequisites

```bash
jq --version        # required
git --version       # required
bash --version      # 3.2 is the floor (that is what macOS ships)
claude --version    # or your wrapper — see "Using a different runner" below
```

`spec-run` checks all of these before the first phase is billed for anything, and
names whichever one is missing rather than failing later and vaguely.

### Step 1 — get the tool

**Either** clone it:

```bash
git clone git@github.com:rv-jclark/speckit-pipeline.git ~/code/speckit-pipeline
sudo ln -s ~/code/speckit-pipeline/bin/spec-run       /usr/local/bin/spec-run
sudo ln -s ~/code/speckit-pipeline/bin/spec-bootstrap /usr/local/bin/spec-bootstrap
spec-run --list      # should print the six phases
```

**Or** install it as a Claude Code plugin, which gives you `/spec-run` and
`/spec-status` inside every project with no per-project setup:

```
/plugin marketplace add rv-jclark/speckit-pipeline
/plugin install speckit-pipeline
```

Both paths ship the same engine — the plugin bundles it — so this is a matter of
whether you want a shell command, slash commands, or both. The clone also gives
you a place to edit `lib/phases.json` that a plugin update will not overwrite.

⚠️ **This repository is private.** The marketplace install resolves over git, so
it works for anyone with read access and fails for everyone else. To share it,
make the repository public or add the person as a collaborator. There is no third
option, and "it worked on my machine" here means "I am the owner".

### Step 2 — prepare each project (once per repo)

**You do not need to install spec-kit separately.** This tool vendors it: the
spec-kit skills and the `.specify` scaffold ship inside
`plugins/speckit-pipeline/assets/`. There is no `uvx specify init`, no separate
package, and no network access needed.

But installing the tool does not prepare a *project*. Run this once in each repo
you want to use it in:

```bash
cd ~/code/my-project
spec-bootstrap                    # or: ~/code/speckit-pipeline/bin/spec-bootstrap .
```

That copies in, without overwriting anything you have authored:

| Path | What it is |
|---|---|
| `.claude/skills/speckit-*` | the 14 spec-kit skills the phases invoke |
| `.specify/scripts/`, `templates/`, `extensions/` | the scaffold those skills execute |
| `.specify/memory/constitution.md` | seeded from the template **only if absent** |
| `specs/` | where features land |

It is idempotent — run it again any time; a second run reports `0 installed`. If a
vendored file already exists and differs, it says so and **leaves yours alone**
unless you pass `--force`. A difference is not necessarily wrong: you may have
customised a template deliberately.

### Step 3 — write your constitution

`spec-bootstrap` says this out loud when it seeds one, and it is worth repeating:
a freshly-seeded `.specify/memory/constitution.md` is a **template**, not a
neutral default. Every phase reads it, so placeholder text shapes every artifact
the pipeline produces. Fill it in, or generate it:

```bash
claude "/speckit-constitution"
```

### Step 4 — first run

```bash
spec-run "add a CSV export to the metrics page"
```

You should see the specify phase start on opus, a feature branch appear, and
`specs/NNN-slug/spec.md` written. If specify verifies clean, plan follows on
opus, then tasks and implement on sonnet.

## Using a different runner (e.g. `claude-edits`)

If your organisation blocks permission bypass and you drive Claude through a
wrapper that answers the prompts, point the engine at it. Three ways, in
increasing order of how long the setting survives:

**One run** — a flag:

```bash
spec-run --claude-bin claude-edits "add a CSV export"
```

**Every run** — an environment variable, so put it in `~/.zshrc`:

```bash
export SPEC_RUN_CLAUDE_BIN=claude-edits
```

This is the one to use in plugin mode. The `/spec-run` command shells out to the
engine, which inherits your shell environment, so it applies to both the CLI and
the slash command.

**Committed with your tuning** — `claude_bin` in `phases.json`, alongside the
per-phase models:

```json
{ "defaults": { "claude_bin": "claude-edits", "permission_mode": "acceptEdits" } }
```

🛑 **In plugin mode, do not edit the bundled `phases.json` in place.** It lives
under `~/.claude/plugins/cache/…`, and a plugin update replaces that directory —
your tuning is a customisation with a deletion date. Keep your own copy and point
at it:

```bash
cp ~/.claude/plugins/cache/*/speckit-pipeline/*/lib/phases.json ~/.config/spec-run/phases.json
export SPEC_RUN_CONFIG=~/.config/spec-run/phases.json     # in ~/.zshrc
```

`--config <file>` beats `SPEC_RUN_CONFIG` for a one-off. A `SPEC_RUN_CONFIG` that
does not exist is a hard error naming the file — it does **not** fall back to the
bundled default, because that would silently run every phase on the model you
thought you had changed.

Whatever you name is checked for existence and runnability before the first phase
is billed. The check looks for **the runner you configured**, not for `claude` —
which was a real defect: `preflight()` once hardcoded `command -v claude` and so
blocked anyone whose only runner was a wrapper, exactly the case this option
exists to serve.

## Day-to-day usage

```bash
# start a feature (runs specify → plan → tasks → implement)
spec-run "add a CSV export to the metrics page"

# scope only — spec and plan, no code. The stop is structural, not a request.
spec-run --stop-after plan "rework the auth flow"

# ask me the ambiguous questions first
spec-run --with clarify "rework the auth flow"

# pick up where it stopped; phases already verified ok are skipped, so this is
# cheap and safe to repeat
spec-run --resume

# re-run one phase after editing its input
spec-run --only plan --force

# see the invocation without spending anything
spec-run --dry-run --only implement

# bigger than one spec? see Roadmaps below
spec-roadmap plan "the larger goal"
spec-roadmap run

# what has run, on what, for how much
spec-run --list                  # the configured phases
spec-status                      # inside Claude Code: /spec-status
cat specs/*/.pipeline/cost.log  # per-attempt cost, turns, duration
```

Per-run overrides, when a phase deserves a different model than the config says:

```bash
spec-run --model plan=sonnet --effort tasks=low --budget 25 "..."
```

### When it stops

It stops for one of three reasons, and says which:

| It printed | What happened | What to do |
|---|---|---|
| `needs_input` | the artifact exists but records an open question | answer it, then `spec-run --resume` |
| `failed` | the artifact is absent, thin, or the phase did not complete | read the reason; fix the cause before retrying |
| `gate:` | a configured pause (`clarify`, or `--stop-after`) | review the artifact, then `spec-run --resume` |

In the first two cases it prints the phase's own account and two commands:

```
claude --resume 6f2c…     # pick that phase's thread back up, in conversation
spec-run --resume         # carry on
```

Resuming the phase's own session is usually what you want — your answers land in
the context that asked the question, with its full history. The engine cannot ask
you anything mid-run (see below), so this is the channel.

### Where everything is written

```
specs/NNN-my-feature/
├── spec.md, plan.md, tasks.md      the artifacts, written by the skills
├── research.md, data-model.md …    plan's supporting output
└── .pipeline/
    ├── state.json                  per-phase status, model, cost, session ids
    ├── cost.log                    one tab-separated line per attempt
    └── <phase>.result.json         that phase's stdout, stderr and exit code
```

`.pipeline/` is run state, not source. To keep it out of git:

```bash
echo 'specs/*/.pipeline/' >> .gitignore
```

## Roadmaps — a series of specs that ship in order

When the work is bigger than one spec, a roadmap holds the ordered series and
runs them one at a time.

```bash
spec-roadmap plan "replace the CSV pipeline with a streaming importer"
spec-roadmap show                 # read the split before anything runs
spec-roadmap run                  # run the next entry, then stop
spec-roadmap list                 # roadmaps in this repo
```

`plan` writes one authored file — `.specify/roadmaps/<slug>.json` — with an entry
per spec: a slug, a title, the description handed verbatim to the specify phase,
and the rationale for its position. The prose lives *inside* the entries rather
than in a companion markdown doc, because two stores for one fact always drift.

**Read the split before you run it.** It is the expensive decision: a wrong entry
1 poisons everything above it, and finding out four specs deep costs four
pipelines and four review cycles. The file is plain JSON — edit it.

### How a run proceeds

```
main ──┬── 001-first ──► PR ──► you merge
       │                          │
       └──────────────────────────┴── 002-second ──► PR ──► you merge
                                                       │
                                                       └── 003-third
```

Each entry is cut from the base (`origin/main` by default), taken through
specify → plan → tasks → implement, and then **the roadmap stops** and hands you
the branch. You review and merge; `spec-roadmap run` picks up the next entry from
the updated base, so it plans against your merged code rather than a guess at it.

Merging is yours. No phase is given the tools for it, and neither is the runner.

### How it knows an entry has landed

⚠️ **The obvious check is wrong, and wrong in a way that would wedge every
roadmap permanently.** `git merge-base --is-ancestor` returns false for a
squash-merged branch, because a squash replays the branch as one new commit and
the branch's own commits never become ancestors of the base. Measured on a real
squash-merging repository: a spec that shipped in a merged pull request reported
`ancestor: NO` while every one of its artifacts was present on `main`. A roadmap
relying on ancestry alone would stop at entry 1 and never advance.

So an entry counts as landed when **either** its branch is an ancestor of the base
**or** its `tasks.md` is present on the base — and the run reports which of the
two answered, because they are not the same confidence.

There is a third answer, and it is not a synonym for "no":

| Answer | Meaning | What happens |
|---|---|---|
| landed | the work is on the base | continue to the next entry |
| not landed | it is not, and the base ref is fresh enough to say so | stop; you merge |
| **unknown** | the question could not be answered | **stop** — it does not guess |

`unknown` covers a base ref that does not exist and a fetch that failed. Treating
it as "not merged" would start the next entry against a base that may already
contain this one, producing a spec built on a false premise. One asymmetry is
deliberate: a *stale* ref that says **landed** is still trusted, because merging
does not un-happen — only the negative is unsafe to read from a stale ref.

### Safety

- **A dirty working tree stops the run** before any branch switch, naming the
  files. It will not stash on your behalf: that is the one unrecoverable thing
  this runner could do.
- **Entry state is separate from the roadmap file.** Progress lives in
  `.specify/roadmaps/<slug>.state.json` — status, branch, feature directory and
  cost per entry — because the roadmap is authored and the state is generated.
- **`--budget` caps the whole roadmap,** checked before each entry starts rather
  than discovered after.

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

## Permissions

Each phase runs `--permission-mode acceptEdits` (configurable as
`defaults.permission_mode` in `phases.json`). In print mode there is **no
interactive prompt**: a tool call the harness will not allow is *denied and
reported to the model*, which then works around it or gives up — it does not hang
waiting for a human. Measured on the smoke runs, spec-kit's own
`create-new-feature.sh` and `update-agent-context.sh` both ran fine under
`acceptEdits`.

Denied tool calls are **counted and named**, not inferred. The CLI reports its own
refusals in the result (`permission_denials`), so a phase's note reads
`3 tool call(s) were DENIED to this phase (Bash, Write)` rather than leaving you
to guess from a thin artifact. An empty spec and "17 denials" are the same
artifact with completely different remedies.

Worth trying before reaching for a wrapper: the CLI accepts `dontAsk` and
`bypassPermissions` as well as `acceptEdits`, and that is one line of data in
`phases.json`. If your organisation's policy is what blocks those, a wrapper is
the answer — see [Using a different runner](#using-a-different-runner-eg-claude-edits).

**Flag support is deliberately not probed.** The version that tried was vacuously
permissive: passing a flag alongside `--help` short-circuits before option
validation, so a flag that cannot exist came back "accepted", and a second probe
form disagreed with the first about the same input. A check whose verdict depends
on how you phrase it gets reported as a guarantee and is not one, so it was
removed rather than softened into a warning.

That failure is caught where it happens instead. A runner that rejects a flag
exits without doing any work, so its artifact does not move, the completion check
fails the phase by name, and the runner's own stderr, stdout and exit code are
kept in `.pipeline/<phase>.result.json`. You get the exact flag it objected to, in
its own words — strictly more than the probe was telling you.

One measured aside on why documentation is a bad basis for this: `--max-turns` is
accepted by `claude` 2.1.238 and appears **nowhere** in its `--help`. The
help-reading probe duly warned that a ceiling was missing while it was being
applied.

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

MIT (`LICENSE`), with the vendored-code position recorded separately in
`NOTICE`: `plugins/speckit-pipeline/assets/` comes from
[github/spec-kit](https://github.com/github/spec-kit) (also MIT) and stays under
its own upstream copyright.

The split is deliberate rather than tidy-mindedness. That note was originally
appended to `LICENSE`, which broke GitHub's exact-match detection — the
repository reported *"no licence detected"* while containing a complete MIT
grant, and a licence tooling cannot see is one some consumers will treat as
absent.

## Vendored spec-kit

`plugins/speckit-pipeline/assets/` carries the spec-kit skills and `.specify`
scaffold, so a fresh repository needs one `spec-bootstrap` and no separate
spec-kit install. Provenance and the pinned version are in
[`assets/UPSTREAM.md`](plugins/speckit-pipeline/assets/UPSTREAM.md).

Two deliberate deviations from the scaffold it was copied from, both recorded in
`UPSTREAM.md` so neither is silent:

- **The plan template's Constitution Check is upstream's placeholder.** The
  scaffold had five concrete gates written into it — one project's architecture
  principles, naming an internal service, hardcoded into the template every other
  project would inherit. Gates belong in a project's own
  `.specify/memory/constitution.md`, which is where the plan phase reads them
  from; `.specify/templates/overrides/` is there if you do want them at template
  level.
- **The spec template's `Testing Strategy *(mandatory)*` section is kept.** It is
  an addition to upstream, but unlike the gates it names nothing
  project-specific: it asks what needs automated coverage, and what is
  deliberately not covered, before planning starts.

⚠️ These assets are a **0.7.3-era** scaffold, not upstream `main`, and the gap is
wide — measured 2026-08-20, `common.sh` is 12KB here against 38KB upstream. Most
of what a diff shows as local customisation is simply age. The pin is held rather
than chased because the engine depends on the `feature.json` and
`check-prerequisites.sh --json` contracts, which have not been re-validated
against main; refreshing is a real piece of work with real regression risk.

The skills install into the project as **unnamespaced** `.claude/skills/speckit-*`
rather than being served from the plugin namespace. That is not incidental:
spec-kit's mandatory `before_specify` hook resolves `speckit.git.feature` to the
slash command `/speckit-git-feature`, a bare name. Under a plugin namespace that
hook silently fails to resolve, no feature branch is created, and the phase
reports success over a directory the rest of the pipeline cannot find.

## Tests

```bash
./tests/run.sh          # shellcheck + 138 fixture assertions
```

**The suite is hermetic.** A stub runner shadows the real `claude` for the whole
run, so nothing spends money, nothing needs a login, and the result is the same
on a laptop as in CI. It asserts that property explicitly, because it is
invisible on a machine where the real binary happens to be installed. The tests
that care about a *missing* runner name one explicitly and so are unaffected by
`PATH`.

That was not free either: CI has no `claude`, and the first run there failed
**30** assertions that were green locally — they exited at the prerequisite check
having never reached an argv. The fixture was more permissive than the
environment it claimed to describe.

Assertions are mutation-checked, and where a mutation is not obvious it is named
in a comment. Five defects in this suite are worth knowing about, because every
one of them passed while checking nothing:

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
- A scope assertion snapshotted the tree **after** the write it meant to detect,
  so the check was correctly silent and the test failed against working code. The
  fix is ordering, and the lesson is that a baseline taken too late proves
  nothing.

## What it cost, measured

Real numbers from the smoke feature (a `--version` flag on a one-file CLI), with
both phases **overridden to sonnet** — so read them as a floor, not as what the
configured opus defaults cost:

| Phase | Model | Turns | Cost | Wall clock |
|---|---|---|---|---|
| specify | sonnet | 15 | $0.62 | 75s |
| plan | sonnet | 18 | $0.31 | 70s |

Every run appends to `specs/<feature>/.pipeline/cost.log`, so the answer to "is
opus on plan worth it" is measurable in your repo rather than arguable. Attempts
that could not be measured are recorded `unmeasured`, never as `$0`.
