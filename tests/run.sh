#!/usr/bin/env bash
#
# speckit-pipeline test suite.
#
# Every assertion here has been mutation-checked: the mutation is named in a
# comment where it is not obvious. An assertion that passes against a broken
# implementation is a test defect, not coverage — and the cheapest place to
# introduce one is a check whose premise it supplies itself.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PKG="$ROOT/plugins/speckit-pipeline"
SPEC_RUN="$PKG/bin/spec-run"
SPEC_BOOTSTRAP="$PKG/bin/spec-bootstrap"

pass=0; fail=0; skipped=0

# Prefixed on purpose. lib/common.sh — which this suite sources in order to test
# it — defines its own ok(). Naming the harness's counter function `ok` let that
# definition clobber it halfway through the run: every later assertion printed a
# tick and incremented nothing, so a suite of ~80 assertions reported "9 passed,
# 0 failed" and exited 0. Green, and lying about how much it had checked.
t_note() { printf '  %s\n' "$1"; }
t_pass() { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
t_fail() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
t_skip() { skipped=$((skipped+1)); printf '  \033[33m-\033[0m %s (skipped: %s)\n' "$1" "$2"; }

# A floor on the tally, because the failure above is invisible by construction:
# nothing else in a passing run distinguishes "every assertion ran" from "most of
# them printed and were never counted".
TALLY_FLOOR=65

assert_contains() { # <haystack> <needle> <label>
  case "$1" in *"$2"*) t_pass "$3";; *) t_fail "$3" "expected to contain: $2";; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) t_fail "$3" "should NOT contain: $2";; *) t_pass "$3";; esac
}
assert_eq() { [ "$1" = "$2" ] && t_pass "$3" || t_fail "$3" "expected '$2', got '$1'"; }

# printf %q output is paste-safe, so spaces and parens arrive backslash-escaped.
# Strip the escapes before matching: an assertion that fails on the QUOTING has
# not looked at the content, and one that passes on it is worse.
unquote() { printf '%s' "$1" | LC_ALL=C tr -d '\\'; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/speckit-pipeline-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# =============================================================== shellcheck ===
printf '\nshellcheck\n'
if command -v shellcheck >/dev/null 2>&1; then
  # Pinned expectations: an unpinned linter means "lint" does not mean the same
  # thing on a laptop as in CI.
  out=$(shellcheck --version | awk '/^version:/{print $2}')
  t_note "shellcheck $out"
  files=("$SPEC_RUN" "$SPEC_BOOTSTRAP" "$PKG/lib/common.sh" "$PKG/lib/verify.sh"
         "$ROOT/bin/spec-run" "$ROOT/bin/spec-bootstrap" "$ROOT/tests/run.sh")
  if sc=$(shellcheck -x -S warning "${files[@]}" 2>&1); then
    t_pass "all scripts clean at -S warning"
  else
    t_fail "shellcheck findings" "$(printf '%s' "$sc" | head -30)"
  fi
else
  t_skip "shellcheck" "not installed — brew install shellcheck"
fi

# ================================================================== config ====
printf '\nphase config\n'
CONFIG="$PKG/lib/phases.json"
if jq -e . "$CONFIG" >/dev/null 2>&1; then t_pass "phases.json is valid JSON"
else t_fail "phases.json is valid JSON"; fi

missing=$(jq -r '[.phases[] | select(
            (.id|type)!="string" or (.skill|type)!="string" or
            (.model|type)!="string" or (.effort|type)!="string" or
            (.gate|type)!="string" or (has("artifact")|not)
          ) | .id] | join(",")' "$CONFIG")
assert_eq "$missing" "" "every phase declares id, skill, model, effort, gate, artifact"

# The list must be exhaustive: a phase added to the config but not to this list
# is a phase nobody decided the model for. A completeness check with no
# exhaustiveness assertion is decoration.
ids=$(jq -r '[.phases[].id] | join(",")' "$CONFIG")
assert_eq "$ids" "specify,clarify,plan,tasks,analyze,implement" \
  "the phase list is exactly the six phases this suite covers"

assert_eq "$(jq -r '.phases[]|select(.id=="specify").model' "$CONFIG")" "opus" "specify runs on opus"
assert_eq "$(jq -r '.phases[]|select(.id=="plan").model' "$CONFIG")" "opus" "plan runs on opus"
assert_eq "$(jq -r '.phases[]|select(.id=="tasks").model' "$CONFIG")" "sonnet" "tasks runs on sonnet"
assert_eq "$(jq -r '.phases[]|select(.id=="implement").model' "$CONFIG")" "sonnet" "implement runs on sonnet"

# Every phase carries a ceiling. A phase with no budget and no turn cap is an
# unbounded spend that looks identical to a bounded one until it runs away.
uncapped=$(jq -r '[.phases[] | select((.max_budget_usd|not) and (.max_turns|not)) | .id] | join(",")' "$CONFIG")
assert_eq "$uncapped" "" "every phase has a budget or turn ceiling"

# ================================================================== verify ====
printf '\nartifact verification\n'
# verify.sh depends on common.sh; sourcing it alone is now a hard error rather
# than a silent miscomparison, so source both in the order the engine does.
# shellcheck source=../plugins/speckit-pipeline/lib/common.sh
. "$PKG/lib/common.sh"
# shellcheck source=../plugins/speckit-pipeline/lib/verify.sh
. "$PKG/lib/verify.sh"
FD="$WORK/feature"; mkdir -p "$FD"

status=$(verify_phase specify "$FD" spec.md | cut -f1)
assert_eq "$status" "failed" "an absent spec.md fails"

printf 'too short\n' > "$FD/spec.md"
status=$(verify_phase specify "$FD" spec.md | cut -f1)
assert_eq "$status" "failed" "a spec.md below the byte floor fails"
# mutation: raising MIN_ARTIFACT_BYTES to 0 flips this to ok — checked.

{ printf '# Spec\n'; for i in $(seq 1 60); do printf 'substantive line %s of specification body\n' "$i"; done; } > "$FD/spec.md"
status=$(verify_phase specify "$FD" spec.md | cut -f1)
assert_eq "$status" "ok" "a full spec.md passes"

printf '[NEEDS CLARIFICATION: which auth provider?]\n' >> "$FD/spec.md"
res=$(verify_phase specify "$FD" spec.md)
assert_eq "$(cut -f1 <<<"$res")" "needs_input" "an unresolved marker is needs_input, not failure"
assert_contains "$(cut -f2 <<<"$res")" "1 unresolved" "the marker count is reported"

status=$(verify_phase analyze "$FD" "" | cut -f1)
assert_eq "$status" "unevaluated" "a phase with no artifact reports unevaluated, never ok"
# This is the load-bearing one. "The check passed" and "the check never ran" are
# the pair this tool exists to separate; collapsing them here would reproduce
# the tidy-zero defect inside the thing built to detect it.

{ printf '# Tasks\n'; for i in $(seq 1 40); do printf 'padding line %s to clear the byte floor\n' "$i"; done; } > "$FD/tasks.md"
status=$(verify_phase tasks "$FD" tasks.md | cut -f1)
assert_eq "$status" "failed" "a tasks.md with no checkboxes fails"

printf -- '- [ ] T001 first\n- [ ] T002 second\n- [x] T003 done\n' >> "$FD/tasks.md"
res=$(verify_phase tasks "$FD" tasks.md)
assert_eq "$(cut -f1 <<<"$res")" "ok" "a tasks.md with checkboxes passes"
assert_contains "$(cut -f2 <<<"$res")" "3 task" "the task total is reported"

res=$(verify_phase implement "$FD" tasks.md)
assert_eq "$(cut -f1 <<<"$res")" "needs_input" "implement with unchecked tasks is needs_input"
assert_contains "$(cut -f2 <<<"$res")" "2 of 3" "the remainder is reported WITH its denominator"
# A bare "incomplete" claims less than it knows; report the denominator with the count.

sed -i'' -e 's/- \[ \]/- [x]/g' "$FD/tasks.md"
res=$(verify_phase implement "$FD" tasks.md)
assert_eq "$(cut -f1 <<<"$res")" "ok" "implement with every task checked passes"

( unset -f file_sha 2>/dev/null
  out=$(bash -c ". '$PKG/lib/verify.sh'" 2>&1); rc=$?
  [ "$rc" -ne 0 ] && printf 'GUARD_FIRED\n' || printf 'GUARD_SILENT\n' ) > "$WORK/guard"
assert_eq "$(cat "$WORK/guard")" "GUARD_FIRED" \
  "verify.sh refuses to load without common.sh instead of miscomparing"

# ============================================================ scope check =====
printf '\nscope check\n'
SR="$WORK/scoperepo"; mkdir -p "$SR/specs/001-x" "$SR/src"
git -C "$SR" init -q; git -C "$SR" config user.email t@t.invalid; git -C "$SR" config user.name t
printf 'x\n' > "$SR/README.md"; git -C "$SR" add -A; git -C "$SR" commit -qm init
SCOPE=("specs/" ".specify/")
SNAP="$WORK/snap"

# The tree the phase inherits is ALREADY dirty: a bootstrap installed skills, the
# caller left a log lying around. None of it is the phase's doing.
mkdir -p "$SR/.claude/skills/speckit-specify"
printf 'skill\n' > "$SR/.claude/skills/speckit-specify/SKILL.md"
printf 'log\n'   > "$SR/run.log"
printf 'pre-existing edit\n' >> "$SR/README.md"

scope_snapshot "$SR" "$SNAP" "${SCOPE[@]}"
printf 'spec\n' > "$SR/specs/001-x/spec.md"          # in scope: fine
v=$(scope_violations_since "$SR" "$SNAP" "${SCOPE[@]}")
assert_eq "$v" "" "a tree that was ALREADY dirty outside the scope is not the phase's violation"
# This is the defect the first real run found: comparing against a CLEAN tree
# attributed 14 freshly-bootstrapped skill files and the caller's own log to the
# phase, and failed a specify that had done everything right. Mutation: swap in a
# clean-tree comparison and this assertion fails, naming all four paths.

printf 'code\n' > "$SR/src/main.py"
v=$(scope_violations_since "$SR" "$SNAP" "${SCOPE[@]}")
assert_contains "$v" "src/main.py" "a NEW file outside the scope is caught"
assert_not_contains "$v" "run.log" "and the pre-existing dirt is still not reported"

printf 'more\n' >> "$SR/README.md"
v=$(scope_violations_since "$SR" "$SNAP" "${SCOPE[@]}")
assert_contains "$v" "README.md" "a file that was ALREADY dirty and is changed AGAIN is caught"
# The line-comparison shortcut misses this one: an untracked-or-modified file
# edited in place keeps its porcelain line byte for byte. Content hashing is what
# closes it, and this assertion is the only thing that distinguishes the two.

rm "$SR/.claude/skills/speckit-specify/SKILL.md"
v=$(scope_violations_since "$SR" "$SNAP" "${SCOPE[@]}")
assert_contains "$v" ".claude/skills/speckit-specify/SKILL.md" \
  "a DELETED out-of-scope file is caught even though it left the dirty list"

# =============================================================== preflight ====
printf '\npreflight\n'
BARE="$WORK/bare"; mkdir -p "$BARE"; git -C "$BARE" init -q
out=$("$SPEC_RUN" --repo "$BARE" --only plan 2>&1); rc=$?
assert_eq "$rc" "1" "a repo with no .specify/ exits 1"
assert_contains "$out" "no .specify/ directory" "the failure names the missing thing"
assert_contains "$out" "spec-bootstrap" "the failure prints a remedy that can actually help"

NOGIT="$WORK/nogit"; mkdir -p "$NOGIT/.specify"
out=$("$SPEC_RUN" --repo "$NOGIT" --only plan 2>&1); rc=$?
assert_eq "$rc" "1" "a non-git directory exits 1"
assert_contains "$out" "not a git repository" "the non-git failure names its own cause"
# Not "no .specify/" — a remedy over a cause it does not name is worse than none.

out=$("$SPEC_RUN" --list 2>&1); rc=$?
assert_eq "$rc" "0" "--list exits 0"
assert_contains "$out" "implement" "--list names the phases"
out=$("$SPEC_RUN" --help 2>&1); assert_eq "$?" "0" "--help exits 0"
out=$("$SPEC_RUN" --nonsense 2>&1); assert_eq "$?" "3" "an unknown option exits 3, not 1"

# =============================================================== bootstrap ====
printf '\nbootstrap\n'
BS="$WORK/bs"; mkdir -p "$BS"; git -C "$BS" init -q
out=$("$SPEC_BOOTSTRAP" "$BS" 2>&1); rc=$?
assert_eq "$rc" "0" "bootstrap into an empty git repo succeeds"
[ -d "$BS/.claude/skills/speckit-specify" ] && t_pass "the specify skill is installed" || t_fail "the specify skill is installed"
[ -d "$BS/.claude/skills/speckit-git-feature" ] && t_pass "the git-feature skill is installed" \
  || t_fail "the git-feature skill is installed"
# git-feature is the mandatory before_specify hook. Vendoring the phase skills
# without it produces a run that reports success and creates no branch.
[ -x "$BS/.specify/scripts/bash/create-new-feature.sh" ] && t_pass ".specify scripts are executable" \
  || t_fail ".specify scripts are executable"
[ -f "$BS/.specify/memory/constitution.md" ] && t_pass "a constitution is seeded" || t_fail "a constitution is seeded"
[ -d "$BS/specs" ] && t_pass "specs/ is created" || t_fail "specs/ is created"
assert_contains "$out" "TEMPLATE" "a freshly-seeded constitution is flagged as a template, not a default"

printf 'MY OWN CONSTITUTION\n' > "$BS/.specify/memory/constitution.md"
out=$("$SPEC_BOOTSTRAP" "$BS" 2>&1)
assert_eq "$(cat "$BS/.specify/memory/constitution.md")" "MY OWN CONSTITUTION" \
  "re-running bootstrap NEVER overwrites an authored constitution"
assert_contains "$out" "0 installed" "a second run installs nothing (idempotent)"

printf 'drifted\n' >> "$BS/.specify/templates/spec-template.md"
out=$("$SPEC_BOOTSTRAP" "$BS" 2>&1)
assert_contains "$out" "differing" "an edited vendored file is reported, not silently replaced"
assert_contains "$(cat "$BS/.specify/templates/spec-template.md")" "drifted" \
  "and it is left in place without --force"
out=$("$SPEC_BOOTSTRAP" --force "$BS" 2>&1)
assert_not_contains "$(cat "$BS/.specify/templates/spec-template.md")" "drifted" \
  "--force replaces it"

# ============================================================== invocation ====
printf '\ninvocation (--dry-run)\n'
argv=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only specify --dry-run 2>&1)
assert_contains "$argv" "--model opus"   "specify is invoked on opus"
assert_contains "$argv" "--effort high"  "specify is invoked at high effort"
assert_contains "$argv" "/speckit-specify" "the phase invokes the skill as a slash command"
assert_contains "$argv" "--session-id"   "a session id is pinned so the phase can be resumed"
assert_contains "$argv" "--output-format json" "output is json so cost and turns are recorded"
assert_contains "$argv" "--max-budget-usd" "a spend ceiling is passed"
deny=$(unquote "$argv")
assert_contains "$deny" "Bash(gh pr merge:*)" "merging is denied to the specify phase"
assert_contains "$deny" "Bash(git push:*)" "pushing is denied to the specify phase"
assert_contains "$argv" "--strict-mcp-config" "specify drops MCP servers it cannot use"

argv=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only tasks --dry-run 2>&1)
assert_contains "$argv" "--model sonnet" "tasks is invoked on sonnet"

argv=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only implement --dry-run 2>&1)
assert_contains "$argv" "--model sonnet" "implement is invoked on sonnet"
assert_not_contains "$argv" "--strict-mcp-config" "implement keeps its MCP servers"
deny=$(unquote "$argv")
assert_contains "$deny" "Bash(gh pr merge:*)" "merging is denied even to implement"
assert_not_contains "$deny" "Bash(git push:*)" "implement MAY push its own branch"
assert_not_contains "$deny" "Bash(gh pr create:*)" "implement MAY open a pull request"
# Both of these were vacuous before the unquote: the literal never appeared in
# %q output at all, so they passed against a build that denied pushing to every
# phase. A surviving mutation is a test defect, and this was one.
# The withheld set is not uniform, and the asymmetry is the point: a phase that
# cannot push cannot open a PR at all, and a phase that can merge needs no human.

argv=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only plan --model plan=sonnet --dry-run 2>&1)
assert_contains "$argv" "--model sonnet" "--model plan=sonnet overrides the config"

out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only plan --model plan=gpt4 --dry-run 2>&1); rc=$?
assert_eq "$rc" "1" "an unknown model alias is rejected before any spend"
assert_contains "$out" "not a model alias" "and the rejection says what was wrong"

out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --dry-run 2>&1)
assert_not_contains "$out" "/speckit-clarify" "clarify does not run unless named in --with"
out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --with clarify --dry-run 2>&1)
assert_contains "$out" "/speckit-clarify" "--with clarify includes it"

out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --from tasks --dry-run 2>&1)
assert_not_contains "$out" "/speckit-plan" "--from tasks skips the earlier phases"
assert_contains "$out" "/speckit-tasks" "--from tasks starts where it says"

# ================================================================== summary ===
printf '\n%s passed, %s failed' "$pass" "$fail"
[ "$skipped" -gt 0 ] && printf ', %s skipped' "$skipped"
printf '\n'

if [ $((pass + fail)) -lt "$TALLY_FLOOR" ]; then
  printf '\n  \033[31m✗\033[0m only %s assertions were COUNTED, expected at least %s.\n' \
    "$((pass + fail))" "$TALLY_FLOOR"
  printf '    Assertions are running but not registering — most likely a sourced\n'
  printf '    library has redefined one of the t_* harness functions.\n\n'
  exit 1
fi
printf '\n'
[ "$fail" -eq 0 ] || exit 1
