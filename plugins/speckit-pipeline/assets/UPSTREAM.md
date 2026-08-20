# Vendored spec-kit assets — provenance

Everything under this directory is **vendored**, not authored here. It is a copy
so that a fresh repository needs one `spec-bootstrap` and no separate spec-kit
installation.

| | |
|---|---|
| Upstream | [github/spec-kit](https://github.com/github/spec-kit) |
| Integration | `claude` |
| Pinned version | **0.7.3** (recorded in `.claude-plugin/plugin.json` as `metadata.speckit_version`) |
| Copied | 2026-08-20 |
| Copied from | a spec-kit 0.7.3 project scaffold (`.claude/skills/speckit-*` + `.specify/`) |

## What is here

| Path | What it is |
|---|---|
| `claude-skills/speckit-*` | the 14 spec-kit skills, verbatim — six phase skills plus the `git-*` extension skills |
| `specify/scripts/bash/` | `create-new-feature.sh`, `check-prerequisites.sh`, `setup-plan.sh`, `update-agent-context.sh`, `common.sh` |
| `specify/templates/` | the spec, plan, tasks, checklist, constitution and agent-file templates |
| `specify/extensions/git/` | the git extension: hook commands and scripts |
| `specify/extensions.yml` | hook registrations, verbatim upstream |

## What is deliberately NOT here

- **`memory/constitution.md`.** A constitution is the project's own assertion
  about how it works. `spec-bootstrap` seeds it from
  `templates/constitution-template.md` only when absent, never overwrites it,
  and says out loud that a freshly-seeded one is a **template** — an unfilled
  constitution is not a neutral default, it is placeholder text shaping every
  artifact the pipeline produces.
- **`feature.json`.** A pointer to whichever feature the source project happened
  to have open.

## Drift

The version above is pinned so drift is **visible**. Two facts stay separate,
because only the second answers anything at run time:

- what upstream spec-kit currently ships, and
- what this directory contains.

`spec-bootstrap` reports a vendored file that differs from what a project already
has and leaves it alone unless you pass `--force`. A difference is not
necessarily wrong — a project may have deliberately customised a template. Look
before you force.

## Refreshing

```bash
# from a repo with a newer spec-kit scaffold installed:
cp -R <repo>/.claude/skills/speckit-*  assets/claude-skills/
cp    <repo>/.specify/scripts/bash/*.sh assets/specify/scripts/bash/
cp    <repo>/.specify/templates/*.md    assets/specify/templates/
cp    <repo>/.specify/extensions.yml    assets/specify/extensions.yml
cp -R <repo>/.specify/extensions        assets/specify/
```

Then update `metadata.speckit_version` in `.claude-plugin/plugin.json`, and run
`./tests/run.sh` — it asserts that `speckit-git-feature` is installed by
bootstrap, which is the skill a partial refresh is most likely to drop. Losing it
produces a run that reports success and creates no feature branch.
