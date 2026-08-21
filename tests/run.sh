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
TALLY_FLOOR=90

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

# A stub runner shadows the real `claude` for the whole suite, on purpose. The
# suite must behave identically on a laptop and in CI, and it did not: CI has no
# claude, so 30 assertions exited at the prerequisite check having never reached
# an argv — all of them green locally, on a machine that happened to have it
# installed. Nothing here is allowed to spend money or need a login; the tests
# that care about a MISSING runner name one explicitly with --claude-bin, so
# they are unaffected by PATH.
FAKE="$WORK/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/claude" <<'STUBEOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "--help" ] && exit 0; done
echo '{"total_cost_usd":0.01,"num_turns":1,"duration_ms":10,"result":"STATUS: ok"}'
STUBEOF
chmod +x "$FAKE/claude"
PATH="$FAKE:$PATH"; export PATH

# =============================================================== shellcheck ===
printf '\nshellcheck\n'
if command -v shellcheck >/dev/null 2>&1; then
  # Pinned expectations: an unpinned linter means "lint" does not mean the same
  # thing on a laptop as in CI.
  out=$(shellcheck --version | awk '/^version:/{print $2}')
  t_note "shellcheck $out"
  files=("$SPEC_RUN" "$SPEC_BOOTSTRAP" "$PKG/bin/spec-status"
         "$PKG/lib/common.sh" "$PKG/lib/verify.sh"
         "$ROOT/bin/spec-run" "$ROOT/bin/spec-bootstrap" "$ROOT/bin/spec-status"
         "$ROOT/tests/run.sh")
  if sc=$(shellcheck -x -S warning "${files[@]}" 2>&1); then
    t_pass "all scripts clean at -S warning"
  else
    t_fail "shellcheck findings" "$(printf '%s' "$sc" | head -30)"
  fi
else
  t_skip "shellcheck" "not installed — brew install shellcheck"
fi

# bash 3.2 is what macOS ships, so it is the floor. Grep for the constructs that
# silently do nothing there rather than trusting whoever edits this next.
b4=$(grep -nE '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)|declare -A|\$\{[A-Za-z_]+(,,|\^\^)' \
       "$SPEC_RUN" "$SPEC_BOOTSTRAP" "$PKG/lib/common.sh" "$PKG/lib/verify.sh" \
       "$ROOT/bin/spec-run" "$ROOT/bin/spec-bootstrap" 2>/dev/null | grep -v '^\s*#' || true)
assert_eq "$b4" "" "no bash-4-only construct in the shipped scripts (macOS ships 3.2)"
t_note "running under bash ${BASH_VERSION}"

# The suite must not reach a real claude. If this fails, an assertion somewhere
# is about to spend money or depend on a login.
resolved=$(command -v claude 2>/dev/null || true)
case "$resolved" in
  "$FAKE"/*) t_pass "the suite is hermetic — claude resolves to the stub";;
  *)         t_fail "the suite is hermetic" "claude resolves to $resolved";;
esac

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

# ------------------------------------------------------- documented commands ---
# Every `spec-*` command the README tells someone to type must exist and be
# executable. A README is the one surface where an invented command is
# indistinguishable from a real one until somebody tries it — and this caught a
# real instance: the usage section told readers to run `spec-status` when only the
# plugin's /spec-status existed and there was no such script.
printf '\ndocumented commands\n'
README="$ROOT/README.md"
doc_cmds=$(grep -oE '(^|[^a-zA-Z/-])spec-[a-z]+' "$README" |
           grep -oE 'spec-[a-z]+' | sort -u |
           grep -vE '^spec-(kit|run-config)$' || true)
missing=""
for c in $doc_cmds; do
  [ -x "$ROOT/bin/$c" ] || missing="$missing $c"
done
assert_eq "$missing" "" "every spec-* command the README names exists in bin/"
n_cmds=$(printf '%s\n' "$doc_cmds" | grep -c . || true)
[ "${n_cmds:-0}" -ge 3 ] && t_pass "and there are $n_cmds of them to check" \
  || t_fail "the extraction found commands" "only $n_cmds — the pattern has drifted"
# The second assertion is the one that keeps the first honest: a grep that
# matches nothing reports no missing commands, which reads exactly like success.

# ------------------------------------------------------------- doc claims -----
# The README states which model, effort and ceiling each phase uses, in a table
# and again in the diagram at the top. Those are CLAIMS about phases.json, and a
# claim that matched when it was written is exactly what drifts the first time
# somebody retunes a model. Assert them, or delete them from the README.
printf '\ndocumented claims\n'
README="$ROOT/README.md"

# the table: "| id | model | effort | $B / T turns | mcp | ... |"
doc_table=$(sed -n '/^| Phase | Model | Effort/,/^$/p' "$README" |
  awk -F'|' '$2 ~ /[a-z]/ && $2 !~ /Phase/ {
      gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3)
      gsub(/^[ \t]+|[ \t]+$/,"",$4); gsub(/^[ \t]+|[ \t]+$/,"",$5)
      gsub(/^[ \t]+|[ \t]+$/,"",$6)
      gsub(/\$/,"",$5); gsub(/ turns/,"",$5); gsub(/ \/ /,"\t",$5)
      print $2"\t"$3"\t"$4"\t"$5"\t"$6 }')
cfg_table=$(jq -r '.phases[] | [.id, .model, .effort,
                    (.max_budget_usd|tostring), (.max_turns|tostring),
                    (if .mcp == "none" then "dropped" else "kept" end)] | @tsv' "$CONFIG")
if [ "$doc_table" = "$cfg_table" ]; then
  t_pass "the README phase table matches phases.json exactly"
else
  t_fail "the README phase table matches phases.json" \
    "$(diff <(printf '%s\n' "$cfg_table") <(printf '%s\n' "$doc_table") | head -6 | tr '\n' ' ')"
fi
# Mutation-verified: changing any model, effort or ceiling in phases.json fails
# this, naming the row. That is the point — the config is the source of truth and
# the README is a projection of it, so the projection has to be checked.

# the diagram at the top of the README: two rows of bare words under the phases
diag_models=$(grep -A2 '^specify  →' "$README" | sed -n '2p' | tr -s ' ' '\n' | grep -c . || true)
diag_models_list=$(grep -A2 '^specify  →' "$README" | sed -n '2p' | tr -s ' ' ' ' | sed 's/^ //;s/ $//')
cfg_models=$(jq -r '[.phases[].model] | join(" ")' "$CONFIG")
assert_eq "$diag_models_list" "$cfg_models" "the README diagram names the same models, in order"
diag_efforts=$(grep -A3 '^specify  →' "$README" | sed -n '3p' | tr -s ' ' ' ' | sed 's/^ //;s/ $//')
cfg_efforts=$(jq -r '[.phases[].effort] | join(" ")' "$CONFIG")
assert_eq "$diag_efforts" "$cfg_efforts" "and the same effort levels, in order"
[ "$diag_models" -eq 6 ] && t_pass "the diagram covers all six phases" \
  || t_fail "the diagram covers all six phases" "found $diag_models model labels"
# Position matters, not just membership: the diagram is the first thing a reader
# sees, and a correct set in the wrong order is the more misleading failure.

# the assertion count the README advertises must be the count this suite reaches
doc_count=$(grep -oE 'shellcheck \+ [0-9]+ fixture assertions' "$README" | grep -oE '[0-9]+' || true)
[ -n "$doc_count" ] && t_pass "the README states an assertion count ($doc_count)" \
  || t_fail "the README states an assertion count" "no 'N fixture assertions' line found"
DOC_ASSERTION_COUNT="${doc_count:-0}"    # checked against the real tally at the end

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

# ------------------------------------------------- spec-kit's own write targets
printf '\nagent context scope\n'
acp=$(agent_context_paths "$BS" | tr '\n' ' ')
assert_contains "$acp" "CLAUDE.md" "the agent context file is derived from spec-kit's own script"
assert_contains "$acp" "AGENTS.md" "and so are the other agents' context files"
n_acp=$(agent_context_paths "$BS" | grep -c . || true)
[ "${n_acp:-0}" -ge 15 ] && t_pass "the derivation finds the whole list ($n_acp paths)" \
  || t_fail "the derivation finds the whole list" "only $n_acp paths; the sed pattern has drifted"
# Derived, never copied: the script names 25 possible files, and a hand-kept copy
# goes stale the first time the vendored spec-kit is refreshed — reintroducing
# this exact false failure for whichever agent was added.

# NOT mapfile: macOS ships bash 3.2, where it does not exist. It failed silently
# enough that the NEXT assertion passed with an unbound array — i.e. vacuously,
# for the third time in this suite. Nothing in this project may use bash 4.
ACP=()
while IFS= read -r _p; do [ -n "$_p" ] && ACP+=("$_p"); done < <(agent_context_paths "$BS")

# Snapshot BEFORE the write, or the write is already in the baseline and the
# check is correctly silent — which is how the first version of this test failed
# while the code was right.
scope_snapshot "$BS" "$WORK/snap2" "${SCOPE[@]}"
printf 'agent context\n' > "$BS/CLAUDE.md"
v=$(scope_violations_since "$BS" "$WORK/snap2" "${SCOPE[@]}")
assert_contains "$v" "CLAUDE.md" "without the derived paths, a legitimate CLAUDE.md write IS flagged"
v=$(scope_violations_since "$BS" "$WORK/snap2" "${SCOPE[@]}" "${ACP[@]}")
assert_not_contains "$v" "CLAUDE.md" "with them, it is not"
# The pair matters: the first assertion is what makes the second meaningful. A
# real plan run cost $0.65 and reported STATUS ok with every artifact written,
# and was marked `failed` over precisely this file.

# ------------------------------------------------------- custom claude binary --
printf '\ncustom phase runner\n'
cat > "$FAKE/claude-edits" <<'FAKEEOF'
#!/usr/bin/env bash
# accepts anything, like a passthrough wrapper
for a in "$@"; do [ "$a" = "--help" ] && exit 0; done
echo '{"total_cost_usd":0.01,"num_turns":1,"duration_ms":10,"result":"STATUS: ok"}'
FAKEEOF
cat > "$FAKE/claude-quiet" <<'FAKEEOF'
#!/usr/bin/env bash
exit 3                      # never answers --help: the probe cannot read it
FAKEEOF
cat > "$FAKE/claude-nogate" <<'FAKEEOF'
#!/usr/bin/env bash
# rejects the flag that carries the structural gate
for a in "$@"; do [ "$a" = "--disallowed-tools" ] && exit 64; done
for a in "$@"; do [ "$a" = "--help" ] && exit 0; done
echo '{}'
FAKEEOF
cat > "$FAKE/claude-noceiling" <<'FAKEEOF'
#!/usr/bin/env bash
# accepts the gate, rejects a ceiling
for a in "$@"; do [ "$a" = "--max-budget-usd" ] && exit 64; done
for a in "$@"; do [ "$a" = "--help" ] && exit 0; done
echo '{}'
FAKEEOF
chmod +x "$FAKE"/claude-*

argv=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" \
        --only plan --claude-bin claude-edits --dry-run 2>&1)
assert_contains "$argv" "claude-edits -p" "--claude-bin runs the named executable, not claude"

argv=$(SPEC_RUN_CLAUDE_BIN=claude-edits "$SPEC_RUN" --repo "$BS" \
        --feature-dir "$BS/specs/001-t" --only plan --dry-run 2>&1)
assert_contains "$argv" "claude-edits -p" "SPEC_RUN_CLAUDE_BIN is honoured too"

out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only plan \
        --claude-bin definitely-not-installed --dry-run 2>&1); rc=$?
assert_eq "$rc" "1" "a phase runner that is not on PATH exits 1 before any spend"
assert_contains "$out" "not on PATH" "and says so, naming the command"

out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" \
        --only plan --claude-bin claude-quiet --dry-run 2>&1)
assert_contains "$out" "exited non-zero on --help" "a runner that will not answer --help is reported"
assert_contains "$out" "result.json" "and the reader is told where its stderr will be kept"
assert_not_contains "$out" "rejects --" "no per-flag claim is made — that probe was removed, not softened"
# It was removed because it was vacuously permissive: passing a flag alongside
# --help short-circuits before option validation, so a flag that cannot exist
# came back accepted, and a second probe form disagreed with the first about the
# same input. A check whose verdict depends on how you phrase it is reported as a
# guarantee and is not one. The failure it aimed at is caught below instead.

# A runner that rejects a flag does no work, so the artifact does not move — and
# THAT is what fails the phase, with the runner's own words kept on disk.
cat > "$FAKE/claude-rejects" <<'FAKEEOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] && exit 0
echo "error: unknown option '--max-budget-usd'" >&2
exit 64
FAKEEOF
chmod +x "$FAKE/claude-rejects"
RJ="$WORK/rejects"; mkdir -p "$RJ"; git -C "$RJ" init -q
git -C "$RJ" config user.email t@t.invalid; git -C "$RJ" config user.name t
"$SPEC_BOOTSTRAP" "$RJ" >/dev/null 2>&1
git -C "$RJ" add -A >/dev/null 2>&1; git -C "$RJ" commit -qm scaffold
mkdir -p "$RJ/specs/001-x"
{ printf '# Plan\n'; for i in $(seq 1 40); do printf 'a plausible plan line %s\n' "$i"; done; } \
  > "$RJ/specs/001-x/plan.md"
out=$("$SPEC_RUN" --repo "$RJ" --feature-dir "$RJ/specs/001-x" \
        --only plan --claude-bin claude-rejects 2>&1); rc=$?
assert_eq "$rc" "1" "a runner that rejects a flag fails the phase"
assert_contains "$out" "did not complete: exit 64" \
  "reported by its exit code, not guessed at beforehand"
# It exits non-zero, so the completion rule catches it before the
# unchanged-artifact rule needs to; both are correct, this one is more precise.
assert_contains "$(cat "$RJ/specs/001-x/.pipeline/plan.result.json" 2>/dev/null)" \
  "unknown option" "and the runner's own error is preserved on disk"
# This says strictly more than the probe did: the reader gets the exact flag the
# runner objected to, in the runner's words.

# ---------------------------------------------------- configuration sources ----
printf '\nconfiguration sources\n'
MYCFG="$WORK/my-phases.json"
jq '(.phases[] | select(.id=="plan").model) = "haiku"' "$CONFIG" > "$MYCFG"

argv=$(SPEC_RUN_CONFIG="$MYCFG" "$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" \
        --only plan --dry-run 2>&1)
assert_contains "$argv" "--model haiku" "SPEC_RUN_CONFIG points at your own phases.json"
# In plugin mode the bundled config lives under ~/.claude/plugins/cache/ and a
# plugin UPDATE replaces that directory, so editing it there is a customisation
# with a deletion date. This is the durable route.

argv=$(SPEC_RUN_CONFIG="$MYCFG" "$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" \
        --only plan --config "$CONFIG" --dry-run 2>&1)
assert_contains "$argv" "--model opus" "--config beats the environment, for a one-off"

out=$(SPEC_RUN_CONFIG="$WORK/not-a-file.json" "$SPEC_RUN" --repo "$BS" \
        --feature-dir "$BS/specs/001-t" --only plan --dry-run 2>&1); rc=$?
assert_eq "$rc" "1" "a SPEC_RUN_CONFIG that does not exist fails loudly"
assert_contains "$out" "phase config not found" "naming the file, not falling back silently"
# Falling back to the bundled default here would run every phase on a model the
# user thought they had changed — the worst kind of working.

# ------------------------------------------------------- permission denials ----
printf '\npermission denials\n'
cat > "$FAKE/claude-denied" <<'FAKEEOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] && exit 0
printf 'touched by the phase\n' >> "$SPEC_TEST_ARTIFACT"
cat <<'J'
{"total_cost_usd":0.03,"num_turns":5,"duration_ms":50,"result":"STATUS: ok",
 "permission_denials":[{"tool_name":"Bash"},{"tool_name":"Bash"},{"tool_name":"Write"}]}
J
FAKEEOF
chmod +x "$FAKE/claude-denied"
DN="$WORK/denied"; mkdir -p "$DN"; git -C "$DN" init -q
git -C "$DN" config user.email t@t.invalid; git -C "$DN" config user.name t
"$SPEC_BOOTSTRAP" "$DN" >/dev/null 2>&1
git -C "$DN" add -A >/dev/null 2>&1; git -C "$DN" commit -qm scaffold
mkdir -p "$DN/specs/001-x"
{ printf '# Plan\n'; for i in $(seq 1 40); do printf 'plan line %s\n' "$i"; done; } > "$DN/specs/001-x/plan.md"
# The fake MUST move the artifact, or the non-run rule fires instead of this one
# and the test would pass for the wrong reason.
out=$(SPEC_TEST_ARTIFACT="$DN/specs/001-x/plan.md" \
      "$SPEC_RUN" --repo "$DN" --feature-dir "$DN/specs/001-x" \
        --only plan --claude-bin claude-denied 2>&1)
assert_contains "$out" "3 tool call(s) were DENIED" "denied tool calls are counted and reported"
assert_contains "$out" "Bash, Write" "and the tools are named, de-duplicated"
# The CLI reports its own refusals, so what a phase was blocked from doing is
# MEASURED rather than inferred from a thin artifact. An empty spec and "17
# denials" are the same artifact with completely different remedies.

# --------------------------------------------------- a phase killed mid-write --
printf '\ninterrupted phase\n'
cat > "$FAKE/claude-killed" <<'FAKEEOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] && exit 0
# writes a PLAUSIBLE, complete-looking artifact and then dies, as a phase killed
# by a rolling restart or a Ctrl-C does
{ printf '# Implementation Plan\n\n'
  for i in $(seq 1 40); do printf 'a wholly plausible plan line %s\n' "$i"; done
  printf '\n## Complexity Tracking\n\n> Not applicable.\n'; } > "$SPEC_TEST_ARTIFACT"
exit 143
FAKEEOF
chmod +x "$FAKE/claude-killed"
KL="$WORK/killed"; mkdir -p "$KL"; git -C "$KL" init -q
git -C "$KL" config user.email t@t.invalid; git -C "$KL" config user.name t
"$SPEC_BOOTSTRAP" "$KL" >/dev/null 2>&1
git -C "$KL" add -A >/dev/null 2>&1; git -C "$KL" commit -qm scaffold
mkdir -p "$KL/specs/001-x"
out=$(SPEC_TEST_ARTIFACT="$KL/specs/001-x/plan.md" \
      "$SPEC_RUN" --repo "$KL" --feature-dir "$KL/specs/001-x" \
        --only plan --claude-bin claude-killed 2>&1); rc=$?
assert_eq "$rc" "1" "a phase killed mid-write FAILS despite a plausible artifact"
assert_contains "$out" "did not complete: exit 143" "and the exit signal is named"
assert_contains "$out" "may be partially written" "and the artifact is called into question, not trusted"
# This one was measured, not imagined: SIGTERM-ing a real plan phase left a
# 3088-byte plan.md ending at a plausible heading, with no open markers — and it
# verified `ok`. The artifact HAD moved, so the unchanged-artifact rule could not
# see it. Byte-count and marker checks cannot distinguish "finished" from
# "interrupted somewhere that happens to look finished"; the exit code can.
# Mutation: drop the rc test and this reports ok on all three assertions.
[ -s "$KL/specs/001-x/plan.md" ] && t_pass "the partial artifact is LEFT on disk for inspection" \
  || t_fail "the partial artifact is left on disk"
# Deleting it would be worse: it is the only record of how far the phase got, and
# the next attempt overwrites it anyway.

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

# The README advertises a number. If it is wrong, one of the two is stale — and
# a count in a README is the single easiest claim to leave behind.
if [ "${DOC_ASSERTION_COUNT:-0}" -gt 0 ] && [ $((pass + fail)) -ne "$DOC_ASSERTION_COUNT" ]; then
  printf '\n  \033[31m✗\033[0m the README advertises %s assertions; this run had %s.\n' \
    "$DOC_ASSERTION_COUNT" "$((pass + fail))"
  printf '    Update the count in README.md, or work out which assertions stopped running.\n\n'
  exit 1
fi

if [ $((pass + fail)) -lt "$TALLY_FLOOR" ]; then
  printf '\n  \033[31m✗\033[0m only %s assertions were COUNTED, expected at least %s.\n' \
    "$((pass + fail))" "$TALLY_FLOOR"
  printf '    Assertions are running but not registering — most likely a sourced\n'
  printf '    library has redefined one of the t_* harness functions.\n\n'
  exit 1
fi
printf '\n'
[ "$fail" -eq 0 ] || exit 1
