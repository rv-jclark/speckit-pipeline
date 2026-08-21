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

## Upgrading a project's spec-kit

Upstream has no project-upgrade command. `specify self` upgrades the CLI, not a
project; the only way to refresh a scaffold is `specify init --here --force`,
which overwrites — no diff, no backup, and no notion of what you customised.

```bash
spec-upgrade --scan ~/code          # which projects are on what (read-only)
spec-upgrade --check                # is THIS project current? exit 2 if not
spec-upgrade --dry-run              # the exact plan, nothing touched
spec-upgrade                        # do it
```

### The distinction the whole tool rests on

"Differs from what we vendor" answers two different questions at once, and
conflating them breaks the upgrade in the quietest possible way. A template can
differ because **you edited it** or because **upstream changed it**. Preserving
everything that differs pins the project on its old templates forever — the
opposite of upgrading. Replacing everything that differs silently discards your
work.

git answers it exactly, offline: a scaffold file imported once and never touched
has **one commit**. Measured on two real projects — one unmodified (every template
1 commit) and one customised (`plan-template` 3, `spec-template` 2,
`tasks-template` 1, which is precisely which ones had been edited).

So an edited template is copied to `.specify/templates/overrides/` before the
pristine upstream file lands. Overrides are **Priority 1** in spec-kit's own
template resolution, so your version keeps winning while everything else
upgrades. A file it cannot classify — untracked, or no git — is treated as
customised, because keeping something somebody may have written beats replacing
it.

### What it will not do

- **Touch `.specify/memory/constitution.md`, `.specify/feature.json`, or `specs/`.**
  Your assertions and your state, not scaffold.
- **Run over uncommitted changes** in the paths it would rewrite. git is the undo
  here — `git diff` is the review, `git checkout` is the revert — and neither
  works on top of existing edits.
- **Delete anything it did not install.** Files the new version retired are
  reported and left; `--prune` removes them. A pre-skills command install is
  called out as superseded and left for you.
- **Revoke your extensions.** Extensions the project has that the bundle lacks
  stay.

It updates `.specify/integration.json`'s `version` field rather than replacing the
file — that record is the project's, and it *must* be updated or `--check`
reports drift forever. (The first dry-run of this tool offered to **prune** that
file, which would have left the project unversioned.)

Afterwards it runs the same skill check `spec-run` does, so a scaffold that cannot
drive the pipeline is reported there rather than at the start of your next
feature.

### The fleet view

`--scan` answers a question upstream cannot: which of my projects are on what.
It reports the **integration shape** as well as the version, because those are
different facts and only the first decides whether the pipeline can drive a
project at all:

```
  · agents          0.7.3    skills:14    259    → 0.16.5
  · ganttlet-web    0.11.3   skills:11    0      → 0.16.5
  · some-old-repo   unknown  commands:9   9      pre-skills — spec-run cannot drive it
  ✓ fresh-project   0.16.5   skills:16    0
```

Exit 2 when anything is behind, so it can gate CI. Read-only.

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
*and carries commits of its own*, **or** its `tasks.md` is present on the base —
and the run reports which of the two answered, because they are not the same
confidence.

🛑 **That "commits of its own" clause is not a detail.** spec-kit's auto-commit
hook is optional and routinely declined, so a feature branch normally sits at
*exactly* the base commit with all its work uncommitted — and
`--is-ancestor` is then trivially **true**. Measured: an entry that had never
been merged reported `landed`, the gate opened, and the roadmap would have
marched through every remaining entry without a single merge. That is worse than
the squash problem: the squash version stalls, this version *lies*.

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

### Exit codes

`spec-roadmap` uses the same convention as `spec-run`, so a wrapper script can
treat them alike:

| Code | Meaning |
|---|---|
| 0 | every entry has landed on the base |
| 1 | an entry failed, or a prerequisite is missing |
| 2 | waiting on you — a merge, a gate, or a question |
| 3 | usage error |

A `2` is the normal resting state of a healthy roadmap: it means the runner has
done its part and the next move is a human's.

### Safety

- **A dirty working tree stops the run** before any branch switch, naming the
  files. It will not stash on your behalf: that is the one unrecoverable thing
  this runner could do.
- **Entry state is separate from the roadmap file.** Progress lives in
  `.specify/roadmaps/<slug>.state.json` — status, branch, feature directory and
  cost per entry — because the roadmap is authored and the state is generated.
- **`--budget` caps the whole roadmap,** checked before each entry starts rather
  than discovered after.
- **An interrupted entry resumes; it does not restart.** An entry recorded
  `in_progress` already has a feature, and handing the description to `spec-run`
  again would make spec-kit cut a *second* branch for the same entry — two specs,
  one state slot that can only point at one of them. Reached by a Ctrl-C, a
  rolling restart, a deleted state file, or a laptop lid.
- **A failing entry stops the roadmap.** Continuing would build the next entry
  against a base that does not contain this one's work — a spec written on a
  false premise, which is the whole failure this gate exists to prevent.
- **The base branch is detected, not assumed.** `origin/HEAD`, then the remotes,
  then local `main`/`master`/`trunk`. The run prints *why* it chose one, so a
  wrong guess is visible rather than surfacing later as "every entry is unknown".

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
- **A phase name that does not exist is a usage error (exit 3), not a quiet
  nothing.** `--only nosuchphase` used to select nothing, run nothing, print six
  "not selected" lines and exit 0 — indistinguishable from the work having been
  done. All of `--only`, `--with`, `--from`, `--stop-after`, `--gate` and the
  `--model`/`--effort` overrides are checked against the configured phases, and a
  run that executes zero phases fails whatever emptied the selection.
- **A description always means a NEW feature.** `spec-run "…"` no longer adopts
  whatever `.specify/feature.json` points at; use `--resume` or `--feature-dir`
  to continue one. Before this, a second feature in the same repository silently
  continued the first: the stale pointer was adopted, its specify phase read
  `ok`, and nothing ran.
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

### Which spec-kit versions this works with

The vendored copy is **spec-kit v0.16.5** (current upstream) with the `git` and
`agent-context` extensions, so `spec-bootstrap` gives you branch-per-feature and a
maintained `CLAUDE.md`. It also runs against whatever a project already has,
because the required skills are **read from the project** rather than assumed:

| | 0.7.x | 0.11.x – 0.16.x |
|---|---|---|
| a feature is | a git **branch** | a **directory**; a branch only if the `git` extension is installed |
| `git-*` skills | in core | moved to the opt-in `git` extension |
| agent context file | `update-agent-context.sh` in core, 25 files hardcoded | the opt-in `agent-context` extension, declared as data |
| `spec-run` | ✅ validated live | ✅ validated live on 0.16.5 |
| `spec-roadmap` | ✅ validated through a squash merge | ✅ **with** the `git` extension; without it there are no per-entry branches to review |

⚠️ **`spec-roadmap` needs a branch per entry.** That is what makes each entry its
own pull request, which is the whole point of the merge gate. Post-0.7.x that
means the `git` extension must be installed — `specify extension add git`. The
vendored bundle includes it; a project that predates it or opted out will produce
entries with nothing to review.

The phase skills come from `phases.json`; anything else comes from whatever
`.specify/extensions.yml` hooks into those phases, with `speckit.git.feature`
mapping to `/speckit-git-feature` exactly as the skills themselves document. An
earlier version hardcoded the five `git-*` skills and so refused to run in every
0.11.x project — and the remedy it printed would have installed 0.7.3's git
skills alongside 0.11.x's, mixing two versions. **A requirement this tool invents
rather than reads is a compatibility bug waiting for the next release.**

⚠️ **Do not `spec-bootstrap --force` a project on a newer spec-kit than the
vendored 0.7.3** — it would downgrade the scaffold and add back skills that
version deliberately removed. Without `--force` it reports the difference and
leaves everything alone, which is the right outcome.

The skills install into the project as **unnamespaced** `.claude/skills/speckit-*`
rather than being served from the plugin namespace. That is not incidental:
spec-kit's mandatory `before_specify` hook resolves `speckit.git.feature` to the
slash command `/speckit-git-feature`, a bare name. Under a plugin namespace that
hook silently fails to resolve, no feature branch is created, and the phase
reports success over a directory the rest of the pipeline cannot find.

## Tests

```bash
./tests/run.sh          # shellcheck + 303 fixture assertions
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

## The bug worth reading about

Every other defect in this repository's history was found by a real run and then
guarded by a test. This one was found by a real run that had *never happened
before*, and it is the reason the suite now insists on it.

`spec-run` ran **only the specify phase** and reported `pipeline complete`, with a
summary listing one phase. Plan, tasks and implement never ran — and no line was
printed for them at all. Nothing failed. Three quarters of the work simply did
not happen.

The driver loop was fed by `done < <(jq -c '.phases[]' "$CONFIG")`, and
`claude -p` **reads stdin**. So the first phase's process swallowed the remaining
phases' JSON and the loop ended after one iteration.

What makes it worth writing down is why nothing caught it:

- every real run until then had been `--only <one phase>`, so two phases had
  never been executed in a single invocation;
- the fake runner in the tests does not read stdin, so the fixtures ran all four
  phases happily;
- and the outcome was `exit 0` with a cheerful summary, so there was nothing to
  investigate.

The loop now iterates by index and the phase gets `</dev/null`, either of which
would have been enough. The regression test uses a runner that deliberately
drains stdin, because that is the only kind of fake that can reproduce it —
mutation-verified: restoring the stream-fed loop makes the assertion report
`specify` alone, exactly as production did.

## What it cost, measured

A complete roadmap entry — spec through working code — on a small Python CLI,
with every phase **overridden to sonnet**. Read these as a floor, not as what the
configured opus defaults cost:

| Phase | Turns | Cost | Output |
|---|---|---|---|
| specify | 14 | $0.70 | `spec.md`, 11KB, plus a requirements checklist |
| plan | 30 | $0.88 | `plan.md`, `research.md`, `data-model.md`, `contracts/` |
| tasks | 15 | $0.50 | 18 tasks |
| implement | 30 | $0.95 | all 18 checked off; the CLI went 7 → 85 lines and runs |
| **total** | **89** | **$3.03** | then stopped at the merge gate |

Separately, decomposing a goal into a 3-entry roadmap cost **$0.75** on
opus/high.

Every run appends to `specs/<feature>/.pipeline/cost.log`, so "is opus on plan
worth it" is measurable in your repo rather than arguable. Attempts that could
not be measured are recorded `unmeasured`, never as `$0`.

## Tests, and what they cost to run

```bash
./tests/run.sh          # shellcheck + 303 assertions, ~2 minutes
```

Hermetic: a stub runner shadows the real `claude` for the whole run, so nothing
spends money, nothing needs a login, and the result is identical on a laptop and
in CI. The suite asserts that property explicitly, because it is invisible on a
machine where the real binary happens to be installed.

Seven defects in this suite are worth knowing about, because every one of them
passed while checking nothing:

- two assertions matched `printf %q` **escaping** rather than content, and passed
  against a build that denied pushing to every phase;
- `verify.sh` was sourced without `common.sh`, so `file_sha` was missing, every
  hash compared empty-to-empty, and two scope assertions passed because
  *everything* looked changed;
- `mapfile` is bash 4 and macOS ships **3.2**, so it failed silently and left an
  array unbound, making the *next* assertion pass with fewer arguments than it
  meant to check;
- the harness named its counter `ok()`, which `common.sh` also defines, so the
  library's definition won partway through and ~80 assertions printed ticks
  without incrementing: **"9 passed, 0 failed"**, exit 0. Hence `TALLY_FLOOR`;
- a scope assertion snapshotted the tree **after** the write it meant to detect,
  so the check was correctly silent and the test failed against working code;
- the status-vocabulary check read 2 of 5 statuses (JSON literals but not jq
  object syntax) and duly reported nothing undeclared;
- and a fake pipeline created a new feature directory on **every** phase, so
  verification chased a moving target — a fixture bug whose output is
  indistinguishable from a product bug.

Every guard here carries a companion assertion that would fail if its extraction
found nothing, because a check that matches nothing reports no problems, which
reads exactly like success.
