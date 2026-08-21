# Vendored spec-kit assets — provenance

Everything under this directory is **vendored**, not authored here, so a fresh
repository needs one `spec-bootstrap` and no separate spec-kit installation.

| | |
|---|---|
| Upstream | [github/spec-kit](https://github.com/github/spec-kit) |
| Pinned version | **v0.16.5** (2026-08-19), recorded as `metadata.speckit_version` |
| Integration | `claude` |
| Extensions | `git`, `agent-context` |
| Produced by | `specify init --here --integration claude` then `specify extension add git` and `specify extension add agent-context`, at that tag |
| Vendored | 2026-08-21 |

## Why those two extensions

Post-0.7.x spec-kit moved both capabilities out of core into opt-in extensions,
and this pipeline needs them:

- **`git`** creates a feature branch per spec via the mandatory `before_specify`
  hook. Without it, `specify` creates a directory and leaves you on the branch
  you were already on — and `spec-roadmap`'s merge gate has nothing to gate,
  because each entry is meant to become its own pull request.
- **`agent-context`** maintains the agent context file (`CLAUDE.md` here) with
  the plan pointer. Without it nothing writes that file, which is *also* fine —
  the write-scope derivation returns an empty list and no phase is flagged. The
  extension is vendored because a maintained CLAUDE.md is worth having, not
  because the pipeline breaks without it.

Together they reproduce the behaviour set 0.7.x had in core, on current upstream.

## What is here

| Path | What it is |
|---|---|
| `claude-skills/speckit-*` | the 16 skills: the phase skills, the five `git-*`, and `agent-context-update` |
| `specify/scripts/bash/` | `create-new-feature.sh`, `check-prerequisites.sh`, `setup-plan.sh`, `setup-tasks.sh`, `resolve-template.sh`, `common.sh` |
| `specify/templates/` | spec, plan, tasks, checklist and constitution templates, **pristine upstream** |
| `specify/extensions/` | `git` and `agent-context`, with their hook commands and scripts |
| `specify/extensions.yml` | hook registrations, as the extensions installed them |
| `specify/workflows/`, `integrations/` | 0.16.x additions, copied as-is |

## What is deliberately NOT here

- **`memory/constitution.md`.** A constitution is the project's own assertion
  about how it works. `spec-bootstrap` seeds it from
  `templates/constitution-template.md` only when absent, never overwrites it, and
  says out loud that a freshly-seeded one is a **template** — an unfilled
  constitution is not a neutral default, it is placeholder text shaping every
  artifact the pipeline produces.
- **`feature.json`.** A pointer to whichever feature the source project had open.

## Upgrade history, and the two lessons from it

**0.7.3 → 0.16.5 (2026-08-21).** The earlier pin was a 0.7.3-era scaffold copied
out of an existing project, which brought two problems that are worth recording
because both are easy to repeat.

**It carried that project's customisations.** `plan-template.md` had five concrete
Constitution Check gates written into it — one project's architecture principles,
naming an internal service, hardcoded into the template every other project would
inherit. Templates here are now pristine upstream: gates belong in a project's own
`memory/constitution.md`, and `.specify/templates/overrides/` exists for anyone who
wants them at template level. (A `Testing Strategy` section that the old scaffold
added to `spec-template.md` is also gone. It was generic and useful; add it back as
an override if you want it.)

**The bundle did not satisfy its own preflight, and nothing checked.** The vendored
`extensions.yml` hooked `speckit.agent-context.update` while that skill had not been
copied, so `spec-bootstrap` produced a project that failed `spec-run`'s skill check
immediately — and the remedy it printed was to run `spec-bootstrap` again, which
could not help. The suite now bootstraps a fresh repository and requires it to pass
preflight, and separately asserts that every command `extensions.yml` hooks has a
vendored skill.

## Refreshing again

```bash
cd "$(mktemp -d)" && git init -q -b main
uvx --native-tls --from git+https://github.com/github/spec-kit.git@vX.Y.Z \
  specify init --here --force --non-interactive --integration claude
uvx --native-tls --from git+https://github.com/github/spec-kit.git@vX.Y.Z specify extension add git
uvx --native-tls --from git+https://github.com/github/spec-kit.git@vX.Y.Z specify extension add agent-context
# then copy .claude/skills/* -> assets/claude-skills/
#            .specify/{scripts,templates,extensions,extensions.yml,workflows,integrations,init-options.json}
#              -> assets/specify/   (never memory/constitution.md or feature.json)
```

Then update `metadata.speckit_version`, run `./tests/run.sh`, and **do a live
`specify` run** — the templates and scripts are what the phases actually execute,
so a green suite is necessary and not sufficient. Check in particular that the
`before_specify` hook still creates a branch and that `.specify/feature.json` is
still where feature discovery reads it; those two contracts are what the engine
and the roadmap rest on.
