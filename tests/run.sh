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

# Defined up here with the other helpers, not partway down: a fixture helper
# declared below its first use fails with "command not found" in the middle of an
# assertion block, which reads exactly like a product bug.
mkbare() { # mkbare <path> <branch>
  mkdir -p "$1"; git -C "$1" init -q -b "$2"
  git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name t
  printf 'x\n' > "$1/f"; git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm i
}

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
  files=("$SPEC_RUN" "$SPEC_BOOTSTRAP" "$PKG/bin/spec-status" "$PKG/bin/spec-roadmap"
         "$PKG/lib/common.sh" "$PKG/lib/verify.sh" "$PKG/lib/roadmap.sh"
         "$ROOT/bin/spec-run" "$ROOT/bin/spec-bootstrap" "$ROOT/bin/spec-status"
         "$ROOT/bin/spec-roadmap" "$ROOT/tests/run.sh")
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

# The plugin's slash commands shell out to ${CLAUDE_PLUGIN_ROOT}/bin/<x>. A
# command markdown naming a script that does not exist fails only when a user
# types it, in a session, with no useful error.
cmd_missing=""
for ref in $(grep -ohE 'CLAUDE_PLUGIN_ROOT\}/bin/[a-z-]+' "$PKG"/commands/*.md | sed 's|.*/bin/||' | sort -u); do
  [ -x "$PKG/bin/$ref" ] || cmd_missing="$cmd_missing $ref"
done
assert_eq "$cmd_missing" "" "every script a slash command invokes exists in the plugin's bin/"
n_refs=$(grep -ohE 'CLAUDE_PLUGIN_ROOT\}/bin/[a-z-]+' "$PKG"/commands/*.md | sed 's|.*/bin/||' | sort -u | grep -c . || true)
[ "${n_refs:-0}" -ge 2 ] && t_pass "and there are $n_refs distinct scripts referenced" \
  || t_fail "the slash-command extraction found scripts" "only $n_refs — the pattern has drifted"

# Every command markdown must also be a real file with frontmatter, or the
# plugin loads a command that does nothing.
for f in "$PKG"/commands/*.md; do
  head -1 "$f" | grep -q '^---$' || t_fail "$(basename "$f") starts with frontmatter" "no --- on line 1"
done
t_pass "every command markdown opens with frontmatter"
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
assert_contains "$(cat "$BS/.gitignore" 2>/dev/null)" "specs/*/.pipeline/" \
  "generated pipeline state is gitignored, not left to be discovered"
assert_contains "$(cat "$BS/.gitignore" 2>/dev/null)" ".specify/roadmaps/*.state.json" \
  "and so is roadmap progress"
printf 'my-own-entry\n' >> "$BS/.gitignore"
"$SPEC_BOOTSTRAP" "$BS" >/dev/null 2>&1
assert_eq "$(grep -c 'specs/\*/\.pipeline/' "$BS/.gitignore")" "1" \
  "re-running does not duplicate the gitignore entries"
assert_contains "$(cat "$BS/.gitignore")" "my-own-entry" "and never rewrites yours"
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

# ------------------------------------ every selected phase actually runs -------
printf '\nmulti-phase run\n'
# The bug this guards was invisible to every other test here. The driver loop was
# fed by `done < <(jq …)`, and `claude -p` READS STDIN — so the first phase
# swallowed the remaining phases' JSON and the loop ended after one iteration.
# Measured on a real roadmap entry: specify ran, plan/tasks/implement did not, and
# the run reported "pipeline complete" over a summary listing one phase.
#
# Reproducing it needs a runner that consumes stdin, which the ordinary fake does
# not — that is exactly why the suite was green while the tool did a quarter of
# its job.
cat > "$FAKE/claude-eats-stdin" <<'FAKEEOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] && exit 0
cat >/dev/null 2>&1 || true       # drain stdin, as the real CLI may
root=$(git rev-parse --show-toplevel 2>/dev/null)
prompt=""
for a in "$@"; do case "$a" in /speckit-*) prompt="$a";; esac; done
cur=$(sed -n 's/.*"feature_directory": *"\([^"]*\)".*/\1/p' "$root/.specify/feature.json" 2>/dev/null)
case "$prompt" in
  /speckit-specify*)
    rel="specs/001-multi"; mkdir -p "$root/$rel"
    git -C "$root" checkout -q -b 001-multi 2>/dev/null
    printf '{\n  "feature_directory": "%s"\n}\n' "$rel" > "$root/.specify/feature.json";;
  *) rel="$cur";;
esac
dir="$root/$rel"; mkdir -p "$dir"
pad() { for i in $(seq 1 40); do printf 'padding %s\n' "$i"; done; }
case "$prompt" in
  /speckit-specify*)   { printf '# Spec\n'; pad; } > "$dir/spec.md";;
  /speckit-plan*)      { printf '# Plan\n'; pad; } > "$dir/plan.md";;
  /speckit-tasks*)     { printf '# Tasks\n'; pad; printf -- '- [ ] T001 x\n'; } > "$dir/tasks.md";;
  /speckit-implement*) { printf '# Tasks\n'; pad; printf -- '- [x] T001 x\n'; } > "$dir/tasks.md";;
esac
echo '{"total_cost_usd":0.01,"num_turns":1,"duration_ms":5,"result":"STATUS: ok"}'
FAKEEOF
chmod +x "$FAKE/claude-eats-stdin"

MP="$WORK/multiphase"; mkbare "$MP" main
"$SPEC_BOOTSTRAP" "$MP" >/dev/null 2>&1
git -C "$MP" add -A >/dev/null 2>&1; git -C "$MP" commit -qm bootstrap
out=$(SPEC_RUN_CLAUDE_BIN=claude-eats-stdin "$SPEC_RUN" --repo "$MP" "build the thing" 2>&1); rc=$?
assert_eq "$rc" "0" "a full run with a stdin-reading runner completes"
ran=$(jq -r '[.phases | to_entries[] | select(.value.status=="ok") | .key] | join(",")' \
      "$MP/specs/001-multi/.pipeline/state.json" 2>/dev/null)
assert_eq "$ran" "specify,plan,tasks,implement" \
  "and ALL FOUR default phases ran, in order, not just the first"
# Mutation: restore `done < <(jq -c '.phases[]' "$CONFIG")` and this reports
# "specify" alone — the exact shape the real run produced.
assert_contains "$out" "→ implement" "the last phase was reached"
n_phase_lines=$(printf '%s\n' "$out" | grep -cE '^→ (specify|plan|tasks|implement)' || true)
assert_eq "$n_phase_lines" "4" "four phases were announced, so none was silently skipped"

# ------------------------------------------------- a name that does not exist --
printf '\nunknown phase names\n'
# `--only nosuchphase` used to select nothing, run nothing, print six "not
# selected" lines and exit 0 — a silent no-op reported as success, which is the
# one outcome indistinguishable from the work having been done.
for flag in --only --from --stop-after --with --gate; do
  out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" "$flag" nosuchphase \
          --dry-run 2>&1); rc=$?
  [ "$rc" -eq 3 ] && t_pass "$flag with an unknown phase exits 3 (usage)" \
    || t_fail "$flag with an unknown phase exits 3" "got $rc"
  assert_contains "$out" "does not exist: nosuchphase" "$flag names the bad value"
done
out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only nosuchphase --dry-run 2>&1)
assert_contains "$out" "configured phases are:" "and lists the ones that do exist"

out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --model nope=opus --dry-run 2>&1); rc=$?
assert_eq "$rc" "3" "an override naming an unknown phase is a usage error too"
out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --model opus --dry-run 2>&1); rc=$?
assert_eq "$rc" "3" "and so is an override missing its ="

# valid selections still work, or the check above would be a nice way to break everything
out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only specify --dry-run 2>&1); rc=$?
assert_eq "$rc" "0" "a valid --only still runs"
out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --gate all --dry-run 2>&1); rc=$?
assert_eq "$rc" "0" "--gate all is not treated as a phase name"
out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --gate none --dry-run 2>&1); rc=$?
assert_eq "$rc" "0" "nor is --gate none"
# That pair is the point of the check being a vocabulary rather than a guess:
# `all` and `none` are legitimate values that are not phases.

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

# =================================================================== spec-status
printf '\nspec-status\n'
SPEC_STATUS="$PKG/bin/spec-status"
ST_REPO="$WORK/statusrepo"; mkbare "$ST_REPO" main
"$SPEC_BOOTSTRAP" "$ST_REPO" >/dev/null 2>&1

out=$("$SPEC_STATUS" --repo "$ST_REPO" 2>&1); rc=$?
assert_eq "$rc" "1" "with no current feature it exits 1"
assert_contains "$out" "no current feature" "and says so rather than printing an empty table"

# A feature with artifacts but NO recorded state: the distinction spec-status
# exists to make.
mkdir -p "$ST_REPO/specs/001-thing"
printf '{"feature_directory":"specs/001-thing"}\n' > "$ST_REPO/.specify/feature.json"
{ printf '# Plan\n'; for i in $(seq 1 40); do printf 'line %s\n' "$i"; done; } > "$ST_REPO/specs/001-thing/plan.md"
out=$("$SPEC_STATUS" --repo "$ST_REPO" 2>&1); rc=$?
assert_eq "$rc" "1" "artifacts without state is not a success"
assert_contains "$out" "no pipeline state recorded" "it says nothing is recorded"
assert_contains "$out" "does not guess" "and refuses to infer progress from the file listing"
assert_contains "$out" "plan.md" "while still showing what is present, so the reader can look"
# A present plan.md cannot distinguish "planning finished" from "planning was
# killed halfway through writing it". Inferring from the listing is exactly the
# mistake this tool exists to avoid, so it must not make it in its own reporting.

# With state, it reports the table and what to do next.
mkdir -p "$ST_REPO/specs/001-thing/.pipeline"
cat > "$ST_REPO/specs/001-thing/.pipeline/state.json" <<'STEOF'
{"version":1,"feature_dir":"specs/001-thing","branch":"001-thing","phases":{
  "specify":{"status":"ok","model":"opus","effort":"high","cost_usd":0.61,"num_turns":15},
  "plan":{"status":"needs_input","model":"opus","effort":"high","cost_usd":0.3,
          "num_turns":9,"note":"plan.md carries 2 unresolved markers",
          "session_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}}}
STEOF
out=$("$SPEC_STATUS" --repo "$ST_REPO" 2>&1); rc=$?
assert_eq "$rc" "0" "with state it exits 0"
assert_contains "$out" "specify" "listing each phase"
assert_contains "$out" "0.61" "with its cost"
assert_contains "$out" "TOTAL" "and a total"
assert_contains "$out" "plan needs input" "naming the blocked phase"
assert_contains "$out" "2 unresolved markers" "quoting its recorded reason"
assert_contains "$out" "claude --resume aaaaaaaa" "and offering that phase's own thread"
# The resume command is the whole point of recording session ids; a status
# display that knows the id and does not offer it is making the reader look it up.

# An unmeasured cost must not read as zero.
python3 - "$ST_REPO/specs/001-thing/.pipeline/state.json" <<'PYEOF'
import json,sys
f=sys.argv[1]; d=json.load(open(f))
d["phases"]["tasks"]={"status":"ok","model":"sonnet","effort":"medium",
                      "cost_usd":None,"num_turns":None}
json.dump(d,open(f,"w"))
PYEOF
out=$("$SPEC_STATUS" --repo "$ST_REPO" 2>&1)
assert_contains "$out" "unmeasured" "a null cost prints as unmeasured, never \$0"
assert_not_contains "$out" '$null' "and never leaks the raw null"

# no phase blocked -> it says so positively rather than staying silent
python3 - "$ST_REPO/specs/001-thing/.pipeline/state.json" <<'PYEOF'
import json,sys
f=sys.argv[1]; d=json.load(open(f))
for k in d["phases"]: d["phases"][k]["status"]="ok"
json.dump(d,open(f,"w"))
PYEOF
out=$("$SPEC_STATUS" --repo "$ST_REPO" 2>&1)
assert_contains "$out" "no phase is blocked" "an unblocked pipeline says so positively"
# Silence would be ambiguous with "I did not check".

out=$("$SPEC_STATUS" --help 2>&1); assert_eq "$?" "0" "--help exits 0"
out=$("$SPEC_STATUS" --repo "$WORK" 2>&1); rc=$?
assert_eq "$rc" "1" "a directory that is not a git repo exits 1"

# ==================================================================== roadmap =
printf '\nroadmap: has this entry landed?\n'
# shellcheck source=../plugins/speckit-pipeline/lib/roadmap.sh
. "$PKG/lib/roadmap.sh"
SPEC_ROADMAP="$PKG/bin/spec-roadmap"

# A repo with a real base branch and a real feature, so the landed checks run
# against git rather than a mock of it.
RB="$WORK/roadmaprepo"; mkdir -p "$RB"
git -C "$RB" init -q -b main
git -C "$RB" config user.email t@t.invalid; git -C "$RB" config user.name t
mkdir -p "$RB/specs/001-first"
printf 'base\n' > "$RB/README.md"
git -C "$RB" add -A >/dev/null 2>&1; git -C "$RB" commit -qm base

git -C "$RB" checkout -q -b 001-first
printf '# Tasks\n- [x] T001\n' > "$RB/specs/001-first/tasks.md"
git -C "$RB" add -A >/dev/null 2>&1; git -C "$RB" commit -qm "entry one"
git -C "$RB" checkout -q main

IFS=$'\t' read -r landed how < <(entry_landed "$RB" main specs/001-first 001-first 0)
assert_eq "$landed" "not_landed" "an unmerged entry is not landed"

# --- a MERGE COMMIT: the branch becomes an ancestor
git -C "$RB" merge --no-ff -q -m "merge entry one" 001-first
IFS=$'\t' read -r landed how < <(entry_landed "$RB" main specs/001-first 001-first 0)
assert_eq "$landed" "done" "after a merge commit the entry is landed"
assert_contains "$how" "ancestor" "reported via ancestry"

# --- a SQUASH MERGE: the branch is NOT an ancestor, and this is the case that
# would wedge every roadmap in a squash-merging repo at its first entry.
git -C "$RB" checkout -q -b 002-second
mkdir -p "$RB/specs/002-second"
printf '# Tasks\n- [x] T001\n' > "$RB/specs/002-second/tasks.md"
git -C "$RB" add -A >/dev/null 2>&1; git -C "$RB" commit -qm "entry two"
git -C "$RB" checkout -q main
git -C "$RB" merge --squash -q 002-second >/dev/null 2>&1
git -C "$RB" commit -qm "entry two (squashed) (#12)"

git -C "$RB" merge-base --is-ancestor 002-second main 2>/dev/null \
  && t_fail "the squash fixture really squashed" "the branch is still an ancestor" \
  || t_pass "the squashed branch is NOT an ancestor of main (the trap)"
IFS=$'\t' read -r landed how < <(entry_landed "$RB" main specs/002-second 002-second 0)
assert_eq "$landed" "done" "a SQUASH-merged entry is still recognised as landed"
assert_contains "$how" "squash-merged" "and the answer says which signal replied"
# Measured on a real repository before this was written: a spec that shipped in a
# merged pull request reported ancestor:NO while all of its artifacts were on
# main. Mutation: delete the artifact-presence branch and this assertion returns
# not_landed, which is a roadmap that can never advance past entry one.

# --- unknown is not a synonym for no
IFS=$'\t' read -r landed how < <(entry_landed "$RB" no-such-ref specs/001-first 001-first 0)
assert_eq "$landed" "unknown" "a base ref that does not exist is unknown, not not_landed"
assert_contains "$how" "does not exist" "naming what was missing"

IFS=$'\t' read -r landed how < <(entry_landed "$RB" main specs/003-third 003-third 1)
assert_eq "$landed" "unknown" "a STALE ref cannot say not_landed"
assert_contains "$how" "stale ref" "and says why it will not guess"
# The asymmetry is deliberate and worth keeping: a stale ref that says LANDED is
# still trusted, because merging does not un-happen. Only the negative is unsafe.

IFS=$'\t' read -r landed how < <(entry_landed "$RB" main specs/002-second 002-second 1)
assert_eq "$landed" "done" "but a stale ref that says LANDED is still trusted"

printf '\nroadmap: the file\n'
RMD="$RB/.specify/roadmaps"; mkdir -p "$RMD"
printf '{"goal":"g","base":"main","entries":[]}\n' > "$RMD/empty.json"
out=$(roadmap_validate "$RMD/empty.json" 2>&1); rc=$?
assert_eq "$rc" "1" "a roadmap with no entries is rejected"
assert_contains "$out" "no entries" "and says so"

printf '{"goal":"g","entries":[{"slug":"a","description":"d"},{"title":"t"}]}\n' > "$RMD/partial.json"
out=$(roadmap_validate "$RMD/partial.json" 2>&1); rc=$?
assert_eq "$rc" "1" "an entry missing slug or description is rejected"
assert_contains "$out" "2" "naming which entry, 1-indexed"
# Found three entries in is the expensive way to learn this.

printf '{"goal":"g","entries":[{"slug":"a","description":"d"},{"slug":"a","description":"e"}]}\n' > "$RMD/dupe.json"
out=$(roadmap_validate "$RMD/dupe.json" 2>&1); rc=$?
assert_eq "$rc" "1" "duplicate slugs are rejected"
assert_contains "$out" "duplicate" "because each entry becomes its own branch"

cat > "$RMD/good.json" <<'RMEOF'
{"goal":"ship the thing","base":"main","entries":[
 {"slug":"first","title":"the first bit","description":"do the first bit"},
 {"slug":"second","title":"the second bit","description":"do the second bit"}]}
RMEOF
roadmap_validate "$RMD/good.json" >/dev/null 2>&1 \
  && t_pass "a well-formed roadmap validates" || t_fail "a well-formed roadmap validates"

printf '{"goal":"g","entries":{"a":{"slug":"x","description":"y"}}}\n' > "$RMD/object.json"
out=$(roadmap_validate "$RMD/object.json" 2>&1); rc=$?
assert_eq "$rc" "1" "entries as an OBJECT is rejected"
assert_contains "$out" "must be a JSON array" "because a roadmap is ordered and an object is not"
# `jq '.entries | length'` counts an object's keys too, so this validated cleanly
# and then failed at run time, where the runner reads .entries[$i] by index and
# gets null. Mutation: drop the type check and this is ACCEPTED.

printf '\nroadmap: a slug names a file\n'
for bad in "../../etc/passwd" "a/b" "..hidden" "" "Upper" "-leading"; do
  if valid_slug "$bad"; then
    t_fail "the slug '$bad' is rejected" "it was accepted, and it names a path or a file"
  else
    t_pass "the slug '$(printf '%s' "${bad:-<empty>}")' is rejected"
  fi
done
for good in "config-file" "v2.plan" "a" "roadmap_1"; do
  valid_slug "$good" && t_pass "the slug '$good' is accepted" \
    || t_fail "the slug '$good' is accepted" "a legitimate name was refused"
done
out=$("$SPEC_ROADMAP" show --repo "$RB" --slug "../../etc/passwd" 2>&1); rc=$?
assert_eq "$rc" "3" "and the CLI refuses one as a usage error"
assert_contains "$out" "not a usable roadmap name" "saying what is wrong with it"
# `--slug ../../etc/passwd` resolved to .specify/roadmaps/../../etc/passwd.json.
# Sloppy rather than dangerous — the caller owns the machine — but a name that
# escapes its own directory is never what anybody meant.

printf '\nroadmap: the CLI\n'
out=$("$SPEC_ROADMAP" --help 2>&1); assert_eq "$?" "0" "--help exits 0"
assert_contains "$out" "squash-merges" "the help states the merge-detection rule"
out=$("$SPEC_ROADMAP" nonsense --repo "$RB" 2>&1); assert_eq "$?" "3" "an unknown command exits 3"

"$SPEC_BOOTSTRAP" "$RB" >/dev/null 2>&1
# Commit the scaffold: an unbootstrapped fixture reports 47 stray files and every
# tree-safety assertion below would be measuring the fixture, not the code.
git -C "$RB" add -A >/dev/null 2>&1; git -C "$RB" commit -qm "bootstrap" >/dev/null 2>&1
out=$("$SPEC_ROADMAP" list --repo "$RB" 2>&1)
assert_contains "$out" "good" "list names the roadmaps present"

out=$("$SPEC_ROADMAP" show --repo "$RB" --slug good 2>&1)
assert_contains "$out" "first" "show lists every entry"
assert_contains "$out" "0 of 2 landed" "with a count against the total, not a bare number"

out=$("$SPEC_ROADMAP" show --repo "$RB" 2>&1); rc=$?
assert_eq "$rc" "1" "show with several roadmaps and no --slug refuses"
assert_contains "$out" "name one with --slug" "rather than picking one for you"

# --- tree safety: the tool must not refuse over its OWN bookkeeping
printf '\nroadmap: tree safety\n'
mkdir -p "$RB/.specify/roadmaps" "$RB/specs/001-first/.pipeline"
printf '{}\n' > "$RB/.specify/roadmaps/good.state.json"
printf '{}\n' > "$RB/specs/001-first/.pipeline/state.json"
assert_eq "$(tracked_changes "$RB")" "" "the tool's own state files are not 'uncommitted changes'"
assert_eq "$(untracked_files "$RB")" "" "nor are they reported as stray untracked files"
# This was a real wedge: `spec-roadmap plan` writes the roadmap file INTO the
# repository, so the first `run` after it saw a dirty tree and refused. The tool
# dirtied the tree and then blocked on it — every roadmap stopped at entry one.
# Mutation: drop _is_tool_bookkeeping and both assertions fail.

out=$("$SPEC_ROADMAP" run --repo "$RB" --slug good --base main --dry-run 2>&1); rc=$?
assert_eq "$rc" "0" "and a run proceeds with only tool state present"

# --- a TRACKED modification refuses, because that is what a checkout can block
printf 'edited by a human\n' >> "$RB/README.md"
assert_contains "$(tracked_changes "$RB")" "README.md" "a tracked modification IS reported"
out=$("$SPEC_ROADMAP" run --repo "$RB" --slug good --base main 2>&1); rc=$?
assert_eq "$rc" "1" "and it stops the roadmap before any branch switch"
assert_contains "$out" "uncommitted tracked changes" "saying what kind of problem it is"
assert_contains "$out" "README.md" "and naming the file"
assert_contains "$out" "will not stash on your behalf" "and promising not to touch it"
[ -n "$(git -C "$RB" status --porcelain README.md)" ] && \
  t_pass "the modification is left exactly as it was" || \
  t_fail "the modification is left alone" "it was stashed or reverted"
git -C "$RB" checkout -- README.md

# --- an UNTRACKED file only warns: git carries those across a checkout
printf 'scratch\n' > "$RB/scratch.txt"
assert_eq "$(tracked_changes "$RB")" "" "an untracked file is not a tracked change"
assert_contains "$(untracked_files "$RB")" "scratch.txt" "but it is reported as stray"
out=$("$SPEC_ROADMAP" run --repo "$RB" --slug good --base main --dry-run 2>&1); rc=$?
assert_eq "$rc" "0" "an untracked file does NOT block the run"
assert_contains "$out" "will follow this checkout" "it warns instead, and says why it matters"
[ -f "$RB/scratch.txt" ] && t_pass "and the untracked file is left where it was" \
  || t_fail "the untracked file is left alone"
rm -f "$RB/scratch.txt"
# Refusing here would be the wedge again in another costume: the specify phase
# creates untracked spec files, so an untracked-blocks rule stops the roadmap
# immediately after its own first phase.

out=$("$SPEC_ROADMAP" run --repo "$RB" --slug good --base main --dry-run 2>&1)
assert_contains "$out" "would run: spec-run" "--dry-run shows the spec-run it would invoke"
assert_not_contains "$out" "waiting on you" "and does not pretend to have run anything"

# the status vocabulary must be exactly what the code writes
printf '\nroadmap: status vocabulary\n'
# Two syntaxes write a status: a JSON literal ("status":"done") and jq object
# construction (status:"awaiting_merge"). The first version of this pattern
# matched only the former, found 2 of 5, and reported no undeclared statuses —
# a completeness check that had read less than half of what it claimed to cover.
written=$(grep -oE '"?status"?:[[:space:]]*"[a-z_]+"' "$SPEC_ROADMAP" |
          sed 's/.*"\([a-z_]*\)"$/\1/' | sort -u | tr '\n' ' ')
for w in $written; do
  case " $ROADMAP_STATUSES " in
    *" $w "*) ;;
    *) t_fail "every status the runner writes is in the vocabulary" "'$w' is not declared";;
  esac
done
t_pass "every status the runner writes is declared in ROADMAP_STATUSES ($written)"
n_written=$(printf '%s\n' "$written" | tr ' ' '\n' | grep -c . || true)
[ "${n_written:-0}" -ge 4 ] && t_pass "and the extraction found $n_written of them" \
  || t_fail "the extraction found statuses" "only $n_written — the pattern has drifted"
# The second assertion keeps the first honest: a grep that matches nothing
# reports no undeclared statuses, which reads exactly like success.

# ---------------------------------------------------- roadmap: base detection --
printf '\nroadmap: which branch is the base?\n'
# `origin/main` is a guess. It is wrong for a master repo, a repo with no remote,
# and a repo whose remote is not called origin — and it does not fail cleanly:
# the ref does not resolve, every entry reports unknown, and the roadmap refuses
# to move while complaining about fetching.
mkbare "$WORK/b-main" main
IFS=$'\t' read -r base how < <(detect_base "$WORK/b-main")
assert_eq "$base" "main" "a local main is found"
assert_contains "$how" "no matching remote" "and the answer says how it was reached"

mkbare "$WORK/b-master" master
IFS=$'\t' read -r base how < <(detect_base "$WORK/b-master")
assert_eq "$base" "master" "a master repo is not forced to main"

mkbare "$WORK/b-weird" some-other-name
IFS=$'\t' read -r base how < <(detect_base "$WORK/b-weird")
assert_eq "$base" "some-other-name" "a repo with neither falls back to the current branch"
assert_contains "$how" "check this" "and says out loud that this one is a guess"
# "You asked for this" and "I picked it" are different facts, and only the second
# is worth double-checking — so the run prints which.

# a remote that is not origin
mkbare "$WORK/b-remote-src" main
mkbare "$WORK/b-remote" main
git -C "$WORK/b-remote" remote add upstream "$WORK/b-remote-src"
git -C "$WORK/b-remote" fetch -q upstream 2>/dev/null
IFS=$'\t' read -r base how < <(detect_base "$WORK/b-remote")
assert_eq "$base" "upstream/main" "a remote that is not called origin is still found"

# --------------------------------------------- roadmap: resume, not duplicate --
printf '\nroadmap: an interrupted entry resumes\n'
# A fake runner stands in for the whole pipeline: it writes the artifacts a real
# specify+plan+tasks+implement would leave, so the roadmap loop, the state
# transitions and the merge gate are all exercised without spending anything.
cat > "$FAKE/claude-pipeline" <<'FAKEEOF'
#!/usr/bin/env bash
# A stand-in for the whole pipeline. It has to be PHASE-AWARE, exactly as
# spec-kit is: only /speckit-specify creates a feature and a branch; every later
# phase reuses the current one. The first version of this fake created a new
# directory on every invocation, so specify wrote 001, plan wrote 002, and
# verification chased a moving target — which is a fixture bug that looks
# identical to a product bug in the output.
[ "${1:-}" = "--help" ] && exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null)
prompt=""
for a in "$@"; do case "$a" in /speckit-*) prompt="$a";; esac; done

cur=$(sed -n 's/.*"feature_directory": *"\([^"]*\)".*/\1/p' "$root/.specify/feature.json" 2>/dev/null)
case "$prompt" in
  /speckit-specify*)
    n=$(ls -1d "$root"/specs/[0-9][0-9][0-9]-* 2>/dev/null | wc -l | tr -d ' ')
    num=$(printf '%03d' $((n + 1)))
    rel="specs/$num-fake"
    mkdir -p "$root/$rel"
    git -C "$root" checkout -q -b "$num-fake" 2>/dev/null
    printf '{\n  "feature_directory": "%s"\n}\n' "$rel" > "$root/.specify/feature.json"
    ;;
  *)
    rel="$cur"
    [ -n "$rel" ] || { echo "fake: no current feature" >&2; exit 1; }
    ;;
esac
dir="$root/$rel"
mkdir -p "$dir"
pad() { for i in $(seq 1 40); do printf 'padding line %s\n' "$i"; done; }
case "$prompt" in
  /speckit-specify*) { printf '# Spec\n'; pad; } > "$dir/spec.md";;
  /speckit-plan*)    { printf '# Plan\n'; pad; } > "$dir/plan.md";;
  /speckit-tasks*)   { printf '# Tasks\n'; pad; printf -- '- [ ] T001 do it\n'; } > "$dir/tasks.md";;
  /speckit-implement*) { printf '# Tasks\n'; pad; printf -- '- [x] T001 do it\n'; } > "$dir/tasks.md";;
esac
echo '{"total_cost_usd":0.05,"num_turns":3,"duration_ms":100,"result":"STATUS: ok"}'
FAKEEOF
chmod +x "$FAKE/claude-pipeline"

IR="$WORK/interrupted"; mkbare "$IR" main
"$SPEC_BOOTSTRAP" "$IR" >/dev/null 2>&1
git -C "$IR" add -A >/dev/null 2>&1; git -C "$IR" commit -qm bootstrap
mkdir -p "$IR/.specify/roadmaps"
cat > "$IR/.specify/roadmaps/rm.json" <<'RMEOF'
{"goal":"g","base":"main","entries":[
 {"slug":"one","title":"first","description":"do one"},
 {"slug":"two","title":"second","description":"do two"}]}
RMEOF

# entry one runs and stops for the merge
out=$(SPEC_RUN_CLAUDE_BIN=claude-pipeline "$SPEC_ROADMAP" run --repo "$IR" --slug rm --base main 2>&1); rc=$?
assert_eq "$rc" "2" "the roadmap stops after the first entry, waiting for a merge"
assert_contains "$out" "pipeline complete" "saying the entry itself finished"
assert_contains "$out" "Open a pull request" "and what it needs from a human"
IRST="$IR/.specify/roadmaps/rm.state.json"
assert_eq "$(jq -r '.entries.one.status' "$IRST")" "awaiting_merge" "and records it as awaiting_merge"
first_dir=$(jq -r '.entries.one.feature_dir' "$IRST")
assert_contains "$first_dir" "specs/001" "with the feature directory it created"
n_specs=$(ls -1d "$IR"/specs/[0-9][0-9][0-9]-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$n_specs" "1" "exactly one feature exists"

# now simulate the interruption: the entry is mid-flight again
roadmap_entry_set "$IRST" one '{"status":"in_progress"}'
out=$(SPEC_RUN_CLAUDE_BIN=claude-pipeline "$SPEC_ROADMAP" run --repo "$IR" --slug rm --base main 2>&1)
assert_contains "$out" "resuming its existing feature" "an in_progress entry resumes rather than restarting"
n_specs=$(ls -1d "$IR"/specs/[0-9][0-9][0-9]-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$n_specs" "1" "and does NOT create a second feature for the same entry"
# Without this, an interrupted entry produces two specs, two branches and one
# state slot that can only point at one of them. Reached by a Ctrl-C, a rolling
# restart, a deleted state file, or a laptop lid.
# Mutation: remove the resume_dir branch and n_specs becomes 2.

# --- a resumed entry must tolerate its OWN uncommitted work
printf '\nroadmap: resuming over uncommitted work\n'
# An entry interrupted partway through implementation has modified tracked files
# by definition. The tree checks guard a BRANCH SWITCH, and a resume does not
# switch branches — so refusing here would block resume in exactly the situation
# resume exists for.
git -C "$IR" checkout -q 001-fake 2>/dev/null || true
printf 'work in progress\n' >> "$IR/f"          # f is tracked
roadmap_entry_set "$IRST" one '{"status":"in_progress"}'
out=$(SPEC_RUN_CLAUDE_BIN=claude-pipeline "$SPEC_ROADMAP" run --repo "$IR" --slug rm --base main 2>&1); rc=$?
assert_contains "$out" "resuming its existing feature" "a resume proceeds despite tracked modifications"
assert_not_contains "$out" "uncommitted tracked changes" "and does not refuse over the entry's own work"
[ -n "$(git -C "$IR" status --porcelain f)" ] && t_pass "the in-progress work is still there" \
  || t_fail "the in-progress work survives" "it was reverted or committed"
git -C "$IR" checkout -- f 2>/dev/null || true
# Mutation: hoist the tree checks back above the resume decision and the first
# two assertions fail — the run refuses instead of resuming.

# ------------------------------------------------ roadmap: the gate releases ---
printf '\nroadmap: the merge gate\n'
# Before merging: the entry's branch exists but nothing is committed on it, which
# is the NORMAL state — spec-kit's auto-commit hook is optional and routinely
# declined. The gate must stay shut.
IFS=$'\t' read -r landed how < <(entry_landed "$IR" main "$first_dir" 001-fake 0)
assert_eq "$landed" "not_landed" "an entry whose work is uncommitted has NOT landed"
git -C "$IR" merge-base --is-ancestor 001-fake main 2>/dev/null \
  && t_pass "even though its branch IS trivially an ancestor of main" \
  || t_fail "the fixture reproduces the trivial-ancestor case" "the branch has diverged"
# That pair is the whole point. A branch with no commits of its own sits at the
# base commit, so --is-ancestor is TRUE and the naive check reports "landed" for
# an entry nobody merged. It does not stall the roadmap, it marches it through
# every remaining entry unmerged — which is why ancestry now requires the branch
# to carry commits of its own.
# Mutation: drop the rev-list guard and the first assertion returns done.

# Now do what a human does: commit on the branch, then squash-merge it.
git -C "$IR" checkout -q 001-fake
git -C "$IR" add -A >/dev/null 2>&1; git -C "$IR" commit -qm "entry one work" >/dev/null 2>&1
git -C "$IR" checkout -q main
git -C "$IR" merge --squash -q 001-fake >/dev/null 2>&1
git -C "$IR" commit -qm "entry one (squashed) (#1)" >/dev/null 2>&1
git -C "$IR" merge-base --is-ancestor 001-fake main 2>/dev/null \
  && t_fail "the squash fixture really squashed" "the branch is still an ancestor" \
  || t_pass "after the squash the branch is NOT an ancestor of main"

IFS=$'\t' read -r landed how < <(entry_landed "$IR" main "$first_dir" 001-fake 0)
assert_eq "$landed" "done" "and the squash-merged entry now reads as landed"
assert_contains "$how" "squash-merged" "via the artifact check, naming which signal replied"

out=$(SPEC_RUN_CLAUDE_BIN=claude-pipeline "$SPEC_ROADMAP" run --repo "$IR" --slug rm --base main 2>&1); rc=$?
assert_contains "$out" "landed on main" "the runner agrees entry one has landed"
assert_contains "$out" "second" "and moves on to entry two"
assert_eq "$(jq -r '.entries.one.status' "$IRST")" "done" "entry one is recorded done"
assert_eq "$(jq -r '.entries.two.status' "$IRST")" "awaiting_merge" "and entry two now waits its turn"
assert_eq "$rc" "2" "the roadmap stops again for the second merge"
n_specs=$(ls -1d "$IR"/specs/[0-9][0-9][0-9]-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$n_specs" "2" "two entries, two features — entry two did not inherit entry one's"
two_dir=$(jq -r '.entries.two.feature_dir' "$IRST")
[ "$two_dir" != "$first_dir" ] && t_pass "and they are different features ($two_dir)" \
  || t_fail "entry two got its own feature" "it reused $first_dir"
# That last pair caught a bug outside roadmaps entirely: spec-run discovered the
# stale .specify/feature.json pointer BEFORE the specify phase, adopted the
# previous feature, found its specify already ok, skipped it, and ran nothing new
# — so `spec-run "a second feature"` in any repository silently continued the
# first one under a new description.

out=$(SPEC_ROADMAP_QUIET=1 "$SPEC_ROADMAP" show --repo "$IR" --slug rm 2>&1)
assert_contains "$out" "1 of 2 landed" "show agrees with the state after a real loop"

# ------------------------------------------------- roadmap: budget and failure -
printf '\nroadmap: ceilings and failures\n'
# The roadmap budget is checked BEFORE an entry starts, not discovered after.
BR="$WORK/budget"; mkbare "$BR" main
"$SPEC_BOOTSTRAP" "$BR" >/dev/null 2>&1
git -C "$BR" add -A >/dev/null 2>&1; git -C "$BR" commit -qm bootstrap
mkdir -p "$BR/.specify/roadmaps"
cat > "$BR/.specify/roadmaps/rm.json" <<'RMEOF'
{"goal":"g","base":"main","entries":[
 {"slug":"one","title":"first","description":"do one"},
 {"slug":"two","title":"second","description":"do two"}]}
RMEOF
BRST="$BR/.specify/roadmaps/rm.state.json"
roadmap_state_init "$BRST" ".specify/roadmaps/rm.json" rm main
roadmap_entry_set "$BRST" one '{"status":"done","cost_usd":9.5}'
out=$(SPEC_RUN_CLAUDE_BIN=claude-pipeline "$SPEC_ROADMAP" run --repo "$BR" --slug rm \
        --base main --budget 5 2>&1); rc=$?
assert_eq "$rc" "1" "the roadmap budget stops the next entry before it starts"
assert_contains "$out" "budget of \$5 reached" "naming the ceiling and what has been spent"
n=$(ls -1d "$BR"/specs/[0-9][0-9][0-9]-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$n" "0" "and no feature was created — checked before the spend, not after"

# A failing pipeline blocks the entry and stops the roadmap; it does not carry on.
cat > "$FAKE/claude-broken" <<'FAKEEOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] && exit 0
exit 1
FAKEEOF
chmod +x "$FAKE/claude-broken"
FR="$WORK/failing"; mkbare "$FR" main
"$SPEC_BOOTSTRAP" "$FR" >/dev/null 2>&1
git -C "$FR" add -A >/dev/null 2>&1; git -C "$FR" commit -qm bootstrap
mkdir -p "$FR/.specify/roadmaps"
cp "$BR/.specify/roadmaps/rm.json" "$FR/.specify/roadmaps/rm.json"
out=$(SPEC_RUN_CLAUDE_BIN=claude-broken "$SPEC_ROADMAP" run --repo "$FR" --slug rm --base main 2>&1); rc=$?
assert_eq "$rc" "1" "a failing entry fails the roadmap"
assert_contains "$out" "the roadmap stops here" "and says it is stopping rather than continuing"
assert_eq "$(jq -r '.entries.one.status' "$FR/.specify/roadmaps/rm.state.json")" "blocked" \
  "recording the entry as blocked"
assert_not_contains "$out" "second" "and never reaches the next entry"
# Carrying on past a failed entry would build entry two against a base that does
# not contain entry one's work — a spec written on a false premise, which is the
# expensive failure this whole gate exists to prevent.

# A plan phase that writes nothing usable leaves the file for inspection.
PR2="$WORK/planfail"; mkbare "$PR2" main
"$SPEC_BOOTSTRAP" "$PR2" >/dev/null 2>&1
cat > "$FAKE/claude-badplan" <<'FAKEEOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] && exit 0
for a in "$@"; do case "$a" in *".specify/roadmaps/"*) t=$(printf '%s' "$a" | grep -oE '/[^ ]*\.specify/roadmaps/[a-z-]+\.json');; esac; done
[ -n "${t:-}" ] && printf 'not json at all\n' > "$t"
echo '{"total_cost_usd":0.02,"num_turns":1,"duration_ms":10,"result":"wrote it"}'
FAKEEOF
chmod +x "$FAKE/claude-badplan"
out=$(SPEC_RUN_CLAUDE_BIN=claude-badplan "$SPEC_ROADMAP" plan --repo "$PR2" --slug bad \
        --base main "some larger goal" 2>&1); rc=$?
assert_eq "$rc" "1" "a plan phase that writes unusable JSON fails"
assert_contains "$out" "not usable" "saying the roadmap it wrote cannot be used"
assert_contains "$out" "left in place" "and that the file is kept for inspection"
[ -f "$PR2/.specify/roadmaps/bad.json" ] && t_pass "the unusable file really is still there" \
  || t_fail "the unusable file is kept" "it was deleted, so there is nothing to fix"
# Deleting it would leave the user with a failure and no artifact to look at; the
# next `plan` overwrites it anyway once they remove it.

out=$(SPEC_RUN_CLAUDE_BIN=claude-badplan "$SPEC_ROADMAP" plan --repo "$PR2" --slug bad \
        --base main "some larger goal" 2>&1); rc=$?
assert_eq "$rc" "1" "planning over an existing roadmap refuses"
assert_contains "$out" "already exists" "rather than overwriting authored content"

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
