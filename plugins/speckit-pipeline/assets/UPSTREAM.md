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

## Deviations from the scaffold this was copied from

Two, both deliberate, because a vendored copy that quietly differs is worse than
one that says how.

**The plan template's Constitution Check was reset to upstream's placeholder.**
The scaffold had five concrete gates written into it — one project's architecture
principles, hardcoded into the template every other project would inherit. Gates
belong in a project's own `memory/constitution.md`, which is where the plan phase
reads them from; a project that wants template-level gates can put a copy in
`.specify/templates/overrides/`, which `resolve_template()` prefers.

**The spec template's "Testing Strategy *(mandatory)*" section was kept.** It is
an addition to upstream, and unlike the gates it names nothing project-specific:
it asks what needs automated coverage and what is intentionally out of scope,
before planning begins. That is good practice anywhere, so it stays.

## Drift

The version above is pinned so drift is **visible**. Two facts stay separate,
because only the second answers anything at run time:

- what upstream spec-kit currently ships, and
- what this directory contains.

⚠️ **This is a 0.7.3-era scaffold, not upstream `main`, and the gap is large.**
Measured 2026-08-20 against `github/spec-kit@main`: `common.sh` is **12KB here
against 38KB upstream**, and `create-new-feature.sh` 12KB against 16KB. Most of
what looks like local customisation in a diff is simply age.

The pin is held rather than chased on purpose. The engine reads
`.specify/feature.json` and `check-prerequisites.sh --json` to locate a feature
directory, and those contracts have not been re-validated against upstream main.
Refreshing is a real piece of work with real regression risk, not a copy — do it
deliberately, and re-run a live `specify` → `plan` afterwards, because the
templates and scripts are what those phases actually execute.

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
