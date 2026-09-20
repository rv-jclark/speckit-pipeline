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
# Every tool path up here with the others. Defining one partway down the file
# makes it unbound for anything inserted above it, and with `set -u` that fails a
# whole block of assertions in a way that looks like a product bug. This has now
# bitten twice: mkbare, then SPEC_ROADMAP.
SPEC_RUN="$PKG/bin/spec-run"
SPEC_BOOTSTRAP="$PKG/bin/spec-bootstrap"
SPEC_STATUS="$PKG/bin/spec-status"
SPEC_ROADMAP="$PKG/bin/spec-roadmap"
SPEC_UPGRADE="$PKG/bin/spec-upgrade"

# The suite must not inherit the developer's runner. SPEC_RUN_CLAUDE_BIN is meant
# to be exported from a shell profile — that is the documented way to use a
# wrapper for every run — so on a machine that does, every assertion about
# default-runner behaviour was silently testing the wrapper instead. Caught by
# the no-TTY warning below: the "default runner does not trip it" case failed on
# a laptop whose ~/.zshrc exported claude-edits, and would have passed in CI.
# Individual tests opt back in with --claude-bin.
unset SPEC_RUN_CLAUDE_BIN
# Same reasoning for the config override: a stray SPEC_RUN_CONFIG would point
# every phase-table assertion at a file the suite does not control.
unset SPEC_RUN_CONFIG

pass=0; fail=0; skipped=0

# Prefixed on purpose. lib/common.sh — which this suite sources in order to test
# it — defines its own ok(). Naming the harness's counter function `ok` let that
# definition clobber it halfway through the run: every later assertion printed a
# tick and incremented nothing, so a suite of ~80 assertions reported "9 passed,
# 0 failed" and exited 0. Green, and lying about how much it had checked.
t_note() { printf '  %s\n' "$1"; }
t_pass() { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
# ⚠️ `return 0` is load-bearing. Without it t_fail's status is that of its last
# command — the `[ -n "${2:-}" ]` test — so a one-argument t_fail returned 1, and
# the `cond && t_fail "X" || t_pass "X"` form used below then ran BOTH branches:
# one assertion printed a ✗ AND a ✓ and was counted twice. Measured: a genuinely
# failing grandchild-reap check reported `451 passed, 1 failed` with a tally of
# 452 against a README advertising 451, so the count check blamed the README for
# a defect in the harness. t_pass has never had this problem (printf returns 0),
# which is why the far more common `&& t_pass || t_fail` form was always safe.
t_fail() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; return 0; }
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

# The libraries are sourced HERE, before any assertion, because a helper defined
# partway down the file is unbound for everything above it and `set -u` turns that
# into a block of failures that read like product bugs. This is the third time
# file order has done that — mkbare, then SPEC_ROADMAP, then jqd — so the rule is
# now: every path and every library at the top.
#
# verify.sh depends on common.sh and refuses to load without it, so the order
# matters; it is the order the engine uses.
# shellcheck source=../plugins/speckit-pipeline/lib/common.sh
. "$PKG/lib/common.sh"
# shellcheck source=../plugins/speckit-pipeline/lib/verify.sh
. "$PKG/lib/verify.sh"
# shellcheck source=../plugins/speckit-pipeline/lib/roadmap.sh
. "$PKG/lib/roadmap.sh"

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
  files=("$SPEC_RUN" "$SPEC_BOOTSTRAP" "$PKG/bin/spec-status" "$PKG/bin/spec-roadmap" "$PKG/bin/spec-upgrade"
         "$PKG/lib/common.sh" "$PKG/lib/verify.sh" "$PKG/lib/roadmap.sh"
         "$ROOT/bin/spec-run" "$ROOT/bin/spec-bootstrap" "$ROOT/bin/spec-status"
         "$ROOT/bin/spec-roadmap" "$ROOT/bin/spec-upgrade" "$ROOT/tests/run.sh")
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
assert_eq "$ids" "specify,clarify,plan,tasks,analyze,remediate,converge,implement,review" \
  "the phase list is exactly the nine phases this suite covers"

assert_eq "$(jq -r '.phases[]|select(.id=="specify").model' "$CONFIG")" "opus" "specify runs on opus"
assert_eq "$(jq -r '.phases[]|select(.id=="plan").model' "$CONFIG")" "opus" "plan runs on opus"
assert_eq "$(jq -r '.phases[]|select(.id=="tasks").model' "$CONFIG")" "sonnet" "tasks runs on sonnet"
assert_eq "$(jq -r '.phases[]|select(.id=="implement").model' "$CONFIG")" "sonnet" "implement runs on sonnet"
assert_eq "$(jq -r '.phases[]|select(.id=="review").model' "$CONFIG")" "opus" "review runs on opus"

# review is the last phase and it is NOT optional. Both halves matter and neither
# is implied by the other: positioned before implement it would be reviewing code
# that does not exist yet, and made optional it would run on the days somebody
# remembers to ask rather than the days it is needed.
assert_eq "$(jq -r '.phases[-1].id' "$CONFIG")" "review" \
  "review runs LAST — there is nothing to review before implement has run"
# 🛑 `select(…).optional // false` is WRONG here and looked right: when select
# matches nothing, `empty // false` yields false, so the filter emits one `false`
# per non-matching phase and the comparison is against an eight-line string. The
# bracket form makes the subject singular before the default is applied.
assert_eq "$(jq -r '[.phases[]|select(.id=="review")][0].optional // false' "$CONFIG")" "false" \
  "and it is not optional, unlike analyze, remediate, and converge"
# Its verdict has to be able to stop the run, and it has to have an artifact to
# form a verdict FROM: a phase declaring no artifact records `unevaluated`, which
# this suite already asserts is not a pass. A final review that cannot fail is
# decoration.
assert_eq "$(jq -r '.phases[]|select(.id=="review").artifact' "$CONFIG")" "review.md" \
  "review declares an artifact, so its outcome is checked rather than unevaluated"
# The default write scope, NOT implement's null. review appends remediation tasks
# and must never fix anything itself — a reviewer that can edit the code it is
# judging has no independent verdict to give.
assert_eq "$(jq -r '.phases[]|select(.id=="review") | has("write_scope")' "$CONFIG")" "false" \
  "review inherits the default write scope, so it cannot touch code"

# Every phase carries a ceiling. A phase with no budget and no turn cap is an
# unbounded spend that looks identical to a bounded one until it runs away.
uncapped=$(jq -r '[.phases[] | select((.max_budget_usd|not) and (.max_turns|not)) | .id] | join(",")' "$CONFIG")
assert_eq "$uncapped" "" "every phase has a budget or turn ceiling"

# The permission mode is not a free choice. Measured: under acceptEdits and
# dontAsk, a Bash command with a LEADING ENVIRONMENT ASSIGNMENT is denied —
# `PROBE=1 echo hi` refused where `echo hi` is allowed — and that is the shape
# spec-kit's own branch script needs (`GIT_BRANCH_NAME=... create-new-feature-
# branch.sh`). A real specify phase was refused four times, created no feature
# branch, and still reported success. Only bypassPermissions and auto allow it.
pmode=$(jqd "$CONFIG" '.defaults.permission_mode' "")
case "$pmode" in
  bypassPermissions|auto) t_pass "the permission mode ($pmode) allows env-prefixed commands";;
  *) t_fail "the permission mode allows env-prefixed commands" \
       "$pmode denies them, so spec-kit's branch script cannot run";;
esac
# What that trades away is smaller than it looks, and also measured:
# --disallowed-tools still applies under bypassPermissions, so pushing, merging
# and deploying stay withheld. The invocation assertions below check the deny list
# is still passed; this one checks the mode does not make the phases useless.

# ------------------------------------------------------- suite hygiene ---------
printf '\nsuite hygiene\n'
# Library sourcing must ALL happen above the first assertion. This has now cost
# four debugging sessions — `mkbare`, `SPEC_ROADMAP`, `jqd`, and most recently
# `roadmap_state_init`, where the missing helper left the state file unseeded and
# an assertion PASSED anyway: the run exited 1 for an unrelated reason and the
# "budget stops the run" tick was reading that. A sourcing line below the first
# assert is invisible to review and produces a false pass, not an error.
#
# Watch the primitive (`. "$PKG/lib/...`), not any one library name, so adding a
# fifth library is covered without touching this guard.
# Both scans are single awk passes on purpose. `grep ... | head -1` SIGPIPEs its
# writer, and under `pipefail` that reports failure despite a match — the trap
# this repo has already documented twice. And the pattern must match a CALL, not
# a definition: `assert_eq() {` has no space before its paren, so requiring one
# after the name skips the harness's own three definitions. Without that, the
# first "assertion" is line 41 and every real sourcing line reads as late.
first_assert=$(awk '/^[[:space:]]*assert_[a-z_]+[[:space:]]/{print NR; exit}' "$0")
late_src=$(awk -v f="${first_assert:-0}" '
  NR > f && /^[[:space:]]*(\.|source)[[:space:]]/ && index($0, "$PKG/lib/") \
    { printf "%s ", NR }' "$0")
late_src=${late_src% }
assert_eq "${late_src:-none}" "none" \
  "every library is sourced before the first assertion"
[ -n "$late_src" ] && printf '      sourced late at line(s): %s\n' "$late_src"

# 🛑 The harness checks itself, because every number it reports depends on this.
# A one-argument t_fail must return 0, or the `cond && t_fail "X" || t_pass "X"`
# form runs BOTH branches (see the note on t_fail) and one assertion prints a ✗
# AND a ✓ while being counted twice. Measured: `451 passed, 1 failed` with a tally
# of 452 against a README advertising 451, so the count check blamed the README
# for a defect in the harness — the count is only as trustworthy as this.
#
# The REAL t_fail is called on purpose rather than a copy of it: a copy would go
# stale exactly when this matters. Its output is discarded and the counter it
# bumped is restored, so the self-check costs one assertion and no failure.
_f_before=$fail
t_fail "harness self-check — not a real failure" >/dev/null 2>&1; _t_fail_rc=$?
fail=$_f_before
assert_eq "$_t_fail_rc" "0" \
  "t_fail returns 0, so a failing 'cond && t_fail || t_pass' counts once, not twice"

# And no assertion may run AFTER the tally is printed. Nine of them did on the
# first attempt at this section: the summary reported "339 passed, 0 failed"
# while 348 assertions had actually run, so a failure among the last nine would
# have been counted in the exit code and NOT in the line a human reads. Same
# class as the harness function that was shadowed and printed ticks without
# incrementing — the tally has to describe the whole run or it describes nothing.
summary_line=$(awk '/^printf .\\n%s passed, %s failed./{print NR; exit}' "$0")
post_tally=$(awk -v f="${summary_line:-0}" '
  NR > f && /^[[:space:]]*assert_[a-z_]+[[:space:]]/ { printf "%s ", NR }' "$0")
assert_eq "${post_tally:-none}" "none" \
  "every assertion runs before the tally is printed"
[ -n "$post_tally" ] && printf '      asserted after the tally at line(s): %s\n' "$post_tally"

# A per-entry total written into prose goes stale the moment a ceiling moves —
# which just happened: raising plan from $8 to $12 left "$58 for one entry"
# asserted in two files, a false statement about the code in the exact shape of
# "a doc line is a claim; assert it or delete it". So it is derived and compared.
# 🛑 Scan the SHIPPED code only, and never restate the figure here. Two earlier
# attempts both failed, in opposite directions, and the pair is the lesson:
#
#   1. Scanning this file too matched the test's OWN explanatory prose, which had
#      to name the stale figure in order to explain it — reported got '5868'.
#   2. "Just strip comments" then broke it the other way: the claim being checked
#      LIVES in a comment, so stripping them left nothing to compare and the
#      figure became unverifiable while looking guarded.
#
# A comment cannot be told apart from a comment-about-the-comment by shape, so
# the scan is scoped to one file that states the figure once, and this file
# refers to phases.json instead of quoting a number.
#
# No phase ships a dollar ceiling any more, so there is no sum to quote and the
# prose must not quote one. Both halves are asserted together: re-adding a cap
# without updating the comment puts a stale figure back in front of a reader,
# which is the exact failure the $58/$68 history above records.
capped=$(jq -r '[.phases[] | select(has("max_budget_usd")) | .id] | join(" ")' \
         "$PKG/lib/phases.json")
declared=$(grep -ohE 'that is \$[0-9]+' "$PKG/bin/spec-roadmap" 2>/dev/null \
           | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')
assert_eq "$(printf '%s|%s' "$capped" "$(printf '%s' "$declared" | tr -d ' ')")" "|" \
  "no phase ships a dollar ceiling, and no stale per-entry figure is quoted"

# ------------------------------------------------------- documented commands ---
# Every `spec-*` command the README tells someone to type must exist and be
# executable. A README is the one surface where an invented command is
# indistinguishable from a real one until somebody tries it — and this caught a
# real instance: the usage section told readers to run `spec-status` when only the
# plugin's /spec-status existed and there was no such script.
printf '\ndocumented commands\n'
README="$ROOT/README.md"
# Extracted from COMMAND POSITION inside fenced bash blocks — the first token of
# a line — not from any matching token anywhere in the file. The denylist version
# of this ('spec-kit', 'spec-run-config', …) was fragile by construction: it
# failed the moment prose mentioned `spec-template.md`, which is a filename, not
# something anyone types. What the check means is "if the README tells someone to
# TYPE a spec-* command, it must exist", so it should read where commands are
# typed.
doc_cmds=$(awk '
  /^```bash$/ {inblock=1; next}
  /^```/      {inblock=0; next}
  inblock {
    line=$0
    sub(/^[[:space:]]+/, "", line)
    # An unescaped / inside a bracket expression ends the regex literal in awk,
    # so strip any leading path with a plain conditional instead.
    if (line ~ /\/bin\//) sub(/.*\/bin\//, "", line)
    sub(/^"/, "", line)
    n=split(line, w, /[[:space:]"]+/)
    if (n > 0 && w[1] ~ /^spec-[a-z]+$/) print w[1]
  }' "$README" | sort -u)
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
                    (.max_budget_usd // "—" | tostring), (.max_turns|tostring),
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
[ "$diag_models" -eq 9 ] && t_pass "the diagram covers all nine phases" \
  || t_fail "the diagram covers all nine phases" "found $diag_models model labels"
# Position matters, not just membership: the diagram is the first thing a reader
# sees, and a correct set in the wrong order is the more misleading failure.

# the assertion count the README advertises must be the count this suite reaches
#
# 🛑 EVERY occurrence, not the first. The README states this figure twice, and the
# pattern used to match only the `N fixture assertions` phrasing — so the other
# copy (`N assertions, ~3.5 minutes`) was unasserted, and it drifted the moment
# somebody added tests: it sat at 505 while the checked one had moved to 512,
# which is a false statement about the code in precisely the shape this section
# exists to catch. An unchecked duplicate of a checked claim is worse than no
# claim, because the reader cannot tell which copy is the live one.
doc_counts=$(grep -oE 'shellcheck \+ [0-9]+ (fixture )?assertions' "$README" | grep -oE '[0-9]+' || true)
doc_count=$(printf '%s\n' "$doc_counts" | head -1)
n_doc_counts=$(printf '%s\n' "$doc_counts" | grep -c . || true)
[ -n "$doc_count" ] && t_pass "the README states an assertion count ($doc_count)" \
  || t_fail "the README states an assertion count" "no 'N assertions' line found"
[ "${n_doc_counts:-0}" -ge 2 ] && t_pass "and states it in $n_doc_counts places, all of them checked" \
  || t_fail "every stated assertion count is found" "only $n_doc_counts — the pattern has drifted"
assert_eq "$(printf '%s\n' "$doc_counts" | sort -u | grep -c .)" "1" \
  "every copy of the count in the README states the SAME number"
DOC_ASSERTION_COUNT="${doc_count:-0}"    # checked against the real tally at the end

# ================================================================== verify ====
printf '\nartifact verification\n'
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

# Prose ABOUT the marker must not count as a marker. A real plan wrote
# 'Every "NEEDS CLARIFICATION" candidate was resolved by reading the tree' above a
# table of resolutions, and the pipeline stopped a roadmap for a question that did
# not exist. Mutation: match the bare phrase again and this assertion fails.
printf 'Every "NEEDS CLARIFICATION" candidate was resolved; see research.md.\n' >> "$FD/spec.md"
res=$(verify_phase specify "$FD" spec.md)
assert_eq "$(cut -f1 <<<"$res")" "ok" "prose mentioning the marker is NOT an open marker"
assert_contains "$(cut -f2 <<<"$res")" "no open markers" "and it says so"

printf '[NEEDS CLARIFICATION: which auth provider?]\n' >> "$FD/spec.md"
res=$(verify_phase specify "$FD" spec.md)
assert_eq "$(cut -f1 <<<"$res")" "needs_input" "an unresolved marker is needs_input, not failure"
assert_contains "$(cut -f2 <<<"$res")" "1 unresolved" "the marker count is reported"

status=$(verify_phase analyze "$FD" "" | cut -f1)
assert_eq "$status" "unevaluated" "a phase with no artifact reports unevaluated, never ok"
# This is the load-bearing one. "The check passed" and "the check never ran" are
# the pair this tool exists to separate; collapsing them here would reproduce
# the tidy-zero defect inside the thing built to detect it.

# 🛑 A MISSING FEATURE DIRECTORY NAMES THE DIRECTORY — AND STILL STOPS THE RUN.
# Measured in a real run: `tasks` wrote 65 tasks correctly, verify_phase was handed a
# feature dir that did not resolve, and the run reported `✗ tasks — tasks.md was not
# created` — while the phase's own STATUS line in the same output said `ok`. Two
# adjacent contradicting lines. So the MESSAGE must not accuse the phase.
#
# ⚠️ The VERDICT is a different question, and softening it to `unevaluated` (which
# only warns) was measured to be far worse than the misleading message: see the
# pipeline-halt test below. The message is honest; the stop is unconditional.
res=$(verify_phase tasks "$WORK/no-such-feature-dir" tasks.md)
assert_eq "$(cut -f1 <<<"$res")" "failed" \
  "a missing feature directory still stops the run"
assert_not_contains "$(cut -f2 <<<"$res")" "tasks.md was not created" \
  "but it does NOT accuse the phase of not writing its artifact"
assert_contains "$(cut -f2 <<<"$res")" "feature directory does not exist" \
  "and the message names the real cause"
assert_contains "$(cut -f2 <<<"$res")" "no-such-feature-dir" \
  "and names the directory it looked in, so the cause is legible"

# The ordinary case must keep its own wording, or the message above becomes a way to
# describe every missing artifact: an EXISTING directory missing its artifact is
# still failed, and is still reported as the phase not having written it.
res=$(verify_phase tasks "$FD" tasks-definitely-absent.md)
assert_eq "$(cut -f1 <<<"$res")" "failed" \
  "an existing directory missing its artifact is still failed"
assert_contains "$(cut -f2 <<<"$res")" "was not created" \
  "and that one IS the phase's own failure to write it"

{ printf '# Tasks\n'; for i in $(seq 1 40); do printf 'padding line %s to clear the byte floor\n' "$i"; done; } > "$FD/tasks.md"
status=$(verify_phase tasks "$FD" tasks.md | cut -f1)
assert_eq "$status" "failed" "a tasks.md with no checkboxes fails"

# --- a task the SPEC marks BLOCKED is owed, not missing
# 🛑 Every entry of one roadmap ended at needs_input over post-deploy tasks —
# T064, T057, T068–T071 — each time needing a human to open tasks.md and confirm
# the remainder was all work that cannot be done from a phase: a deployed-surface
# read, a browser pass, a measurement against a real dashboard. A gate with
# nothing to decide is a gate that trains you to click through it.
BLK="$WORK/blocked-tasks"; mkdir -p "$BLK"
# Over MIN_ARTIFACT_BYTES on purpose: the size floor is checked BEFORE the task
# count, so a tiny fixture fails as an unfinished write and never reaches the
# branch under test. My first version of this was 90 bytes and reported
# "tasks.md is only 0 bytes", which says nothing about BLOCKED handling.
_blk_pad() { printf '%s\n' "$1"; printf '  %s\n' "context line for size, this file must clear the artifact floor before the task count is even looked at"; }
{
  echo '# Tasks: blocked-marker fixture'
  echo
  echo '## Phase 1'
  _blk_pad '- [X] T001 real work that is done'
  _blk_pad '- [ ] T002 🛑 BLOCKED — the post-merge deployed-surface read'
  _blk_pad '- [ ] T003 [P] 🛑 BLOCKED — the 24-step browser pass'
} > "$BLK/tasks.md"
IFS=$'\t' read -r v m < <(verify_phase implement "$BLK" tasks.md)
assert_eq "$v" "ok" "a phase whose only leftovers are BLOCKED does not gate"
assert_contains "$m" "owed not missing" "and says they are owed rather than absent"

# But one unmarked leftover still gates — otherwise the marker becomes a place to
# hide unfinished work, and the count stops meaning anything.
printf -- '- [ ] T004 genuinely unfinished\n' >> "$BLK/tasks.md"
IFS=$'\t' read -r v m < <(verify_phase implement "$BLK" tasks.md)
assert_eq "$v" "needs_input" "one unmarked leftover still gates"
assert_contains "$m" "marked BLOCKED" "while still reporting how many were marked"

# A TICKED task carrying the marker must not count — nor one that merely mentions
# the word in passing. Precision here is the difference between a disclosure and
# a loophole.
{
  echo '# Tasks: marker-precision fixture'
  echo
  echo '## Phase 1'
  _blk_pad '- [X] T001 🛑 BLOCKED — carries the marker but is TICKED, so it is done'
  _blk_pad '- [ ] T002 mentions BLOCKED in its text but carries no marker at the front'
} > "$BLK/tasks.md"
IFS=$'\t' read -r v m < <(verify_phase implement "$BLK" tasks.md)
assert_eq "$v" "needs_input" "a ticked marker and a passing mention both fail to qualify"

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

# --- review: the one artifact whose verifier looks for evidence of READING
# Every other verdict here is artifact-shaped — present, over the floor, no
# template markers, boxes ticked — which is what a dead phase cannot fake. A
# review is entirely prose, and prose can be fluent, confident, well-organised
# and completely unfounded with nothing about its shape differing. So the check is
# for specific locations, which a phase cannot produce without having looked.
_pad40() { i=1; while [ "$i" -le 40 ]; do printf 'padding line %s\n' "$i"; i=$((i+1)); done; }

{ printf '# Review\n\n## Verdict\n\nIt hangs together.\n'; _pad40
  printf 'No findings. Read src/orders/repo.py:412 and src/api.py:88.\n'; } > "$FD/review.md"
res=$(verify_phase review "$FD" review.md)
assert_eq "$(cut -f1 <<<"$res")" "ok" "a cited review with no blocking findings passes"
assert_contains "$(cut -f2 <<<"$res")" "citation" "and the citation count is reported"

# The uncited case is a FAILURE, not a warning, and it is checked BEFORE the
# findings count. That order is the assertion: a review that cannot show it read
# anything has a worthless verdict, and a worthless CLEAN verdict is the most
# expensive thing this file could wave through — it advances the run.
{ printf '# Review\n\n## Verdict\n\nEverything looks great to me.\n'; _pad40
  printf 'No findings.\n'; } > "$FD/review.md"
res=$(verify_phase review "$FD" review.md)
assert_eq "$(cut -f1 <<<"$res")" "failed" "an uncited review fails rather than passing clean"
assert_contains "$(cut -f2 <<<"$res")" "nothing shows the code was read" \
  "saying what is missing is the evidence, not the findings"

# An unresolved blocking finding gates. Unchecked means unresolved, on the same
# convention as tasks.md, and the marker must be at the FRONT — prose that merely
# mentions the word must not gate, or the check becomes unusable in a review that
# explains its own severity scale.
{ printf '# Review\n\n## Findings\n\n'
  printf -- '- [ ] 🛑 BLOCKER F1 — the producer writes a shape the consumer cannot read\n'
  printf '      where:  src/queue/worker.ts:145\n'; _pad40; } > "$FD/review.md"
res=$(verify_phase review "$FD" review.md)
assert_eq "$(cut -f1 <<<"$res")" "needs_input" "an unresolved BLOCKER stops the run"
assert_contains "$(cut -f2 <<<"$res")" "1 unresolved" "and is counted"

{ printf '# Review\n\n## Findings\n\n'
  printf -- '- [ ] MAJOR F2 — two passes each added their own retry helper\n'
  printf '      where:  src/a.py:10, src/b.py:20\n'; _pad40; } > "$FD/review.md"
assert_eq "$(verify_phase review "$FD" review.md | cut -f1)" "needs_input" \
  "a MAJOR gates as well as a BLOCKER"

{ printf '# Review\n\n## Findings\n\n'
  printf -- '- [x] 🛑 BLOCKER F1 — already dealt with, src/x.py:9\n'
  printf -- '- MINOR F3 — safe to ship, src/y.py:4\n'
  printf -- '- NOTE F4 — BLOCKER severity is defined in the skill, for reference\n'; _pad40
  } > "$FD/review.md"
res=$(verify_phase review "$FD" review.md)
assert_eq "$(cut -f1 <<<"$res")" "ok" \
  "a TICKED blocker, an unboxed MINOR and a NOTE mentioning the word all fail to gate"
# That trio is the point: each is a different way the count could have been
# inflated into a gate with nothing to decide — which is the failure the
# BLOCKED-task rule above already exists to undo.

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
# The pointer to the feature being worked. Tracked, it would differ on every
# roadmap branch and conflict on every merge, over a file that only describes
# the checkout it sits in.
assert_contains "$(cat "$BS/.gitignore" 2>/dev/null)" ".specify/feature.json" \
  "and so is the current-feature pointer"
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
# The agent context file (CLAUDE.md and friends) is written by spec-kit's own
# tooling, so a phase writing it is not going off-piste. WHERE that list is
# declared changed between versions, and the derivation reads both:
#   0.7.x   core's update-agent-context.sh, 25 files hardcoded as *_FILE=
#   0.11.x+ the opt-in agent-context extension, declared as data
acp=$(agent_context_paths "$BS" | tr '\n' ' ')
assert_contains "$acp" "CLAUDE.md" "the agent context file is derived, not assumed"
n_acp=$(agent_context_paths "$BS" | grep -c . || true)
[ "${n_acp:-0}" -ge 1 ] && t_pass "the derivation finds it ($n_acp path(s))" \
  || t_fail "the derivation finds the context file" "found none, so a legitimate write would be flagged"

# the 0.7.x shape: a core script enumerating every agent's file
V07="$WORK/v07shape"; mkdir -p "$V07/.specify/scripts/bash"
cat > "$V07/.specify/scripts/bash/update-agent-context.sh" <<'V07EOF'
#!/usr/bin/env bash
CLAUDE_FILE="$REPO_ROOT/CLAUDE.md"
GEMINI_FILE="$REPO_ROOT/GEMINI.md"
COPILOT_FILE="$REPO_ROOT/.github/agents/copilot-instructions.md"
V07EOF
acp07=$(agent_context_paths "$V07" | tr '\n' ' ')
assert_contains "$acp07" "GEMINI.md" "the 0.7.x core-script shape is still read"
assert_contains "$acp07" ".github/agents/copilot-instructions.md" "including its nested paths"

# the 0.11.x+ shape: the extension declares its targets as data
V11S="$WORK/v11shape"; mkdir -p "$V11S/.specify/extensions/agent-context"
printf '{"agents":{"claude":"CLAUDE.md","codex":"AGENTS.md"}}\n' \
  > "$V11S/.specify/extensions/agent-context/agent-context-defaults.json"
printf 'context_file: ""\ncontext_files: []\n' \
  > "$V11S/.specify/extensions/agent-context/agent-context-config.yml"
printf '{"integration":"codex"}\n' > "$V11S/.specify/init-options.json"
acp11=$(agent_context_paths "$V11S" | tr '\n' ' ')
assert_contains "$acp11" "AGENTS.md" "an undeclared config falls back to the project's integration default"
assert_not_contains "$acp11" "CLAUDE.md" "and not to some other agent's file"
# The fallback is keyed by the integration recorded at init, so a codex project
# must not be told CLAUDE.md is fair game.

printf 'context_files:\n  - AGENTS.md\n  - CLAUDE.md\n' \
  > "$V11S/.specify/extensions/agent-context/agent-context-config.yml"
acp11=$(agent_context_paths "$V11S" | tr '\n' ' ')
assert_contains "$acp11" "AGENTS.md" "an explicit context_files list is read"
assert_contains "$acp11" "CLAUDE.md" "all of it"

printf 'context_file: JUSTONE.md\ncontext_files: []\n' \
  > "$V11S/.specify/extensions/agent-context/agent-context-config.yml"
acp11=$(agent_context_paths "$V11S" | tr '\n' ' ')
assert_contains "$acp11" "JUSTONE.md" "and so is a single context_file"

# no extension at all: the honest answer is nothing, because nothing writes them
NOEXT="$WORK/noext"; mkdir -p "$NOEXT/.specify/scripts/bash"
assert_eq "$(agent_context_paths "$NOEXT")" "" "a project where nothing maintains a context file yields NO paths"
# Inventing entries here would silently permit writes nobody makes.

# and the pair that makes the scope check meaningful
scope_snapshot "$BS" "$WORK/snap2" "${SCOPE[@]}"
printf 'agent context\n' > "$BS/CLAUDE.md"
v=$(scope_violations_since "$BS" "$WORK/snap2" "${SCOPE[@]}")
assert_contains "$v" "CLAUDE.md" "without the derived paths, a legitimate CLAUDE.md write IS flagged"
ACP=()
while IFS= read -r _p; do [ -n "$_p" ] && ACP+=("$_p"); done < <(agent_context_paths "$BS")
v=$(scope_violations_since "$BS" "$WORK/snap2" "${SCOPE[@]}" "${ACP[@]}")
assert_not_contains "$v" "CLAUDE.md" "with them, it is not"

# ------------------------------------------------------- custom claude binary --
printf '\ncustom phase runner\n'
# ⚠️ Deliberately an unmistakably-fake name. This fixture was called
# `claude-edits`, which is also a REAL pexpect wrapper on at least one
# developer's PATH — and when a run failed because that tool was configured via
# SPEC_RUN_CLAUDE_BIN, the shared name led straight to the wrong diagnosis ("a
# test polluted the shipped config"). A fixture must not be confusable with a
# tool someone actually has installed.
cat > "$FAKE/claude-wrapper-fixture" <<'FAKEEOF'
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

# 🛑 A RELATIVE --feature-dir RESOLVES AGAINST $REPO, NOT THE CALLER'S CWD.
# `discover_feature_dir` has always absolutised against $REPO; an explicit flag was
# taken verbatim, so the two paths into one variable meant different things and a
# relative value silently depended on where the caller stood. Every other test in
# this file passes an ABSOLUTE --feature-dir, which is exactly why the bug survived
# the suite — so this one is deliberately run from a SUBDIRECTORY of the repo.
# Mutation: remove the normalisation in spec-run and the reported feature path
# becomes <subdir>/specs/001-t, which is where the real run went looking.
mkdir -p "$BS/services/somewhere-deep"
# ⚠️ Compare against the CANONICAL repo path, not $BS. spec-run does
# `REPO=$(cd -- "$REPO" && pwd)`, so a $TMPDIR ending in `/` (which macOS's does)
# leaves $BS carrying a double slash that $REPO does not — and the assertion fails
# against a CORRECT fix. Caught by this test on its first run.
BS_REAL=$(cd "$BS" && pwd)
out=$(cd "$BS/services/somewhere-deep" && "$SPEC_RUN" --repo "$BS" \
        --feature-dir specs/001-t --only plan --dry-run 2>&1)
assert_contains "$out" "feature $BS_REAL/specs/001-t" \
  "a relative --feature-dir resolves against \$REPO, not the caller's cwd"
# ⚠️ This second one does NOT catch the mutation on its own — with the normalisation
# removed the runner echoes the raw relative value (`feature specs/001-t`), so the
# subdirectory never appears in the output either way. Kept because it pins that the
# caller's cwd is never spliced in, but the assertion ABOVE is the load-bearing one.
assert_not_contains "$out" "somewhere-deep/specs/001-t" \
  "and never against the subdirectory the caller happened to be in"

# An absolute --feature-dir is unchanged by the normalisation.
out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS_REAL/specs/001-t" --only plan --dry-run 2>&1)
assert_contains "$out" "feature $BS_REAL/specs/001-t" "an absolute --feature-dir is passed through as-is"

# 🛑 A SPECIFY THAT WRITES NOTHING STOPS THE PIPELINE — THE WHOLE PIPELINE.
# This is the ONLY test that runs a NEW feature end to end against a runner that
# exits 0 and writes nothing, and it exists because nothing else covers the state
# every new feature starts in: before specify there is no feature directory, so
# spec-run passes `/nonexistent` and verify_phase's missing-directory branch is
# reached on the FIRST phase of every run. Every other test here supplies a
# feature dir that exists, which is exactly why a regression here went unseen.
#
# Measured with verify.sh reporting `unevaluated` (a warning, not a stop) for a
# missing directory: specify, plan, tasks AND implement all ran to completion
# against a directory that never existed — implement being a 1200-turn phase.
# The suite was fully green while the pipeline had no stop at all.
#
# Mutation: change that branch's verdict from `failed` to `unevaluated` and this
# fails on the `→ plan` assertion — the run carries on past a dead specify.
NOTHING="$WORK/writes-nothing"; mkbare "$NOTHING" main
"$SPEC_BOOTSTRAP" "$NOTHING" >/dev/null 2>&1
git -C "$NOTHING" add -A >/dev/null 2>&1
git -C "$NOTHING" commit -qm bootstrap >/dev/null 2>&1
# The suite's default stub `claude` is already this runner: exits 0, returns a
# well-formed and fully-measured envelope, and creates no files. No --claude-bin
# here on purpose — the point is the DEFAULT path.
out=$("$SPEC_RUN" --repo "$NOTHING" "a feature whose specify writes nothing" \
        --gate none 2>&1); rc=$?
assert_eq "$rc" "1" "a specify that writes nothing exits 1 rather than continuing"
assert_contains "$out" "feature directory does not exist" \
  "and says the directory is missing, not that the phase failed to write spec.md"
assert_not_contains "$out" "→ plan" \
  "and the pipeline never reaches plan"
assert_not_contains "$out" "→ implement" \
  "and above all never reaches implement, which is a 1200-turn phase"

argv=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" \
        --only plan --claude-bin claude-wrapper-fixture --dry-run 2>&1)
assert_contains "$argv" "claude-wrapper-fixture -p" "--claude-bin runs the named executable, not claude"

argv=$(SPEC_RUN_CLAUDE_BIN=claude-wrapper-fixture "$SPEC_RUN" --repo "$BS" \
        --feature-dir "$BS/specs/001-t" --only plan --dry-run 2>&1)
assert_contains "$argv" "claude-wrapper-fixture -p" "SPEC_RUN_CLAUDE_BIN is honoured too"

out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only plan \
        --claude-bin definitely-not-installed --dry-run 2>&1); rc=$?
assert_eq "$rc" "1" "a phase runner that is not on PATH exits 1 before any spend"
assert_contains "$out" "not on PATH" "and says so, naming the command"

out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" \
        --only plan --claude-bin claude-quiet --dry-run 2>&1)
assert_contains "$out" "exited non-zero on --help" "a runner that will not answer --help is reported"
assert_contains "$out" "result.json" "and the reader is told where its stderr will be kept"
assert_not_contains "$out" "rejects --" "no per-flag claim is made — that probe was removed, not softened"

# A runner that needs a terminal, in a run that has none. Unlike flag support,
# this is a fact about the ENVIRONMENT — `[ -t 0 ]` — and the failure it predicts
# is total: a pexpect wrapper calls child.interact(), tcgetattr fails, and every
# phase dies at once before writing anything. Measured on a real specify phase,
# whose entire account was a Python traceback ending in `termios.error: (19,
# 'Operation not supported by device')` — naming neither this tool, nor the
# runner, nor SPEC_RUN_CLAUDE_BIN. The suite runs without a TTY, so the condition
# is live here.
printf '\nrunner: needs a terminal\n'
out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" \
        --only plan --claude-bin claude-wrapper-fixture --dry-run 2>&1)
assert_contains "$out" "no controlling terminal" "a non-default runner with no TTY is warned about up front"
assert_contains "$out" "--claude-bin claude" "and the remedy names the default runner"
# The warning must NOT fire for the default runner, or it is noise on every
# ordinary headless run and will be tuned out exactly when it matters.
out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" \
        --only plan --dry-run 2>&1)
assert_not_contains "$out" "no controlling terminal" "the default runner does not trip it"

# And the same failure recognised after the fact, from the runner's own output —
# matched on the signature, not the runner's name, so an unknown wrapper is
# caught too.
looks_like_tty_failure "termios.error: (19, 'Operation not supported by device')" \
  && t_pass "a termios failure is recognised as a runner problem" \
  || t_fail "a termios failure is recognised as a runner problem"
looks_like_tty_failure "mode = tty.tcgetattr(self.STDIN_FILENO)" \
  && t_pass "so is a raw tcgetattr traceback line" \
  || t_fail "so is a raw tcgetattr traceback line"
looks_like_tty_failure "STATUS: needs_input — which model should own the cache?" \
  && t_fail "an ordinary phase question is NOT a tty failure" \
  || t_pass "an ordinary phase question is NOT a tty failure"
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

# ------------------------------- killed AFTER streaming, and out of turns ------
# The fake above prints NOTHING before dying, so the "no parseable result" branch
# catches it. That is not how a real phase dies. These two cases were both
# measured on one entry and both were recorded `ok`.
printf '\ninterrupted phase, mid-stream\n'
cat > "$FAKE/claude-killed-streaming" <<'FAKEEOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] && exit 0
{ printf '# Implementation Plan\n\n'
  for i in $(seq 1 40); do printf 'a wholly plausible plan line %s\n' "$i"; done
  printf '\n## Complexity Tracking\n\n> Not applicable.\n'; } > "$SPEC_TEST_ARTIFACT"
# stream as a real phase does, then die BEFORE the result envelope. The last
# object is valid JSON and carries no cost — which is why "some JSON parsed" is
# not evidence of completion.
printf '{"type":"system","subtype":"init","session_id":"s1"}\n'
printf '{"type":"system","subtype":"thinking_tokens","estimated_tokens":6100}\n'
exit 143
FAKEEOF
chmod +x "$FAKE/claude-killed-streaming"
mkdir -p "$KL/specs/002-x"
out=$(SPEC_TEST_ARTIFACT="$KL/specs/002-x/plan.md" \
      "$SPEC_RUN" --repo "$KL" --feature-dir "$KL/specs/002-x" \
        --only plan --claude-bin claude-killed-streaming 2>&1); rc=$?
assert_eq "$rc" "1" "a phase killed AFTER streaming fails despite a plausible artifact"
assert_contains "$out" "did not complete: exit 143" "and the signal is still named"
# Mutation: revert extract_result_json to extract_json and this reports `ok` —
# the trailing thinking_tokens line parses, so the unmeasured flag never sets and
# the interrupted-phase guard cannot fire. Measured exactly so on entry 014.

printf '\nout of turns\n'
cat > "$FAKE/claude-maxturns" <<'FAKEEOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] && exit 0
# The supporting artifacts get written; the MAIN one is left as the template.
d=$(dirname "$SPEC_TEST_ARTIFACT")
printf '# Research\n\nplenty of real content here, repeated for bulk.\n' > "$d/research.md"
{ printf '# Implementation Plan: [FEATURE]\n\n'
  printf '**Date**: [DATE]\n\n## Project Structure\n\n'
  printf '# [REMOVE IF UNUSED] Option 1: Single project\n'
  for i in $(seq 1 40); do printf 'template filler line %s\n' "$i"; done; } > "$SPEC_TEST_ARTIFACT"
# A real result envelope, reporting its own failure. exit 0 — the runner exits
# cleanly having given up, which is why the exit code alone cannot catch this.
printf '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":81,"total_cost_usd":4.63,"duration_ms":742815}\n'
exit 0
FAKEEOF
chmod +x "$FAKE/claude-maxturns"
mkdir -p "$KL/specs/003-x"
out=$(SPEC_TEST_ARTIFACT="$KL/specs/003-x/plan.md" \
      "$SPEC_RUN" --repo "$KL" --feature-dir "$KL/specs/003-x" \
        --only plan --claude-bin claude-maxturns 2>&1); rc=$?
assert_eq "$rc" "1" "a phase that ran out of turns FAILS even though it exited 0"
assert_contains "$out" "OUT OF TURNS" "and says so in the runner's own terms"
assert_contains "$out" "raise max_turns" "and names the actionable remedy"
# Mutation: drop the is_error branch and this reports `ok` at 81 turns with a
# cost, because the template clears the size floor and asks no questions.

# --------------------------------------- a phase that emits TWO result envelopes
# 🛑 Measured 2026-09-15 on the SDLC roadmap's entry 8: the implement pass hit
# `API Error: No response from API`, the CLI retried WITHIN the same invocation,
# and the stream carried two `result` records. `extract_result_json`'s non-stream
# branch used bare `jq` over what is a SEQUENCE, so it returned BOTH envelopes
# and every figure downstream became two lines — observed in that log as
# `$21.8689346\n22.644156`, `194\n6 turns`, `(success\nsuccess)` and
# `[: 0\n0: integer expression expected`.
#
# The one that stopped the roadmap is the VERDICT: the first envelope is the
# ABORTED attempt, so its `is_error` outvoted the retry's success and a pass that
# exited 0 reporting `STATUS: ok` with 27 of 94 tasks ticked was recorded
# `failed`. Hence the fake below: attempt one errors, the retry succeeds. That
# ORDER is the whole point — with two clean envelopes `$(…)` strips the trailing
# newlines and the same defect is silent, which is why this case must not be
# written as two successes (the first version of it was, and it could not see
# the failure at all).
#
# The artifact is fine and the exit code is 0, so nothing else in this suite can
# see this: it is entirely a defect in reading the runner's own report.
printf '\ntwo result envelopes (an in-invocation retry)\n'
cat > "$FAKE/claude-two-results" <<'FAKEEOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] && exit 0
{ printf '# Implementation Plan: Two envelopes\n\n'
  for i in $(seq 1 40); do printf 'a wholly plausible plan line %s\n' "$i"; done
  printf '\n## Complexity Tracking\n\n> Not applicable.\n'; } > "$SPEC_TEST_ARTIFACT"
printf '{"type":"system","subtype":"init","session_id":"s1"}\n'
# Attempt one, abandoned mid-flight; then the retry that finished the work.
# Figures differ so the test can say WHICH envelope was read.
printf '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":194,"total_cost_usd":21.8689346,"duration_ms":900000,"permission_denials":[],"result":"API Error: No response from API"}\n'
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":6,"total_cost_usd":22.6441566,"duration_ms":40000,"permission_denials":[],"result":"STATUS: ok the retry finished the pass"}\n'
exit 0
FAKEEOF
chmod +x "$FAKE/claude-two-results"
mkdir -p "$KL/specs/004-x"
out=$(SPEC_TEST_ARTIFACT="$KL/specs/004-x/plan.md" \
      "$SPEC_RUN" --repo "$KL" --feature-dir "$KL/specs/004-x" \
        --only plan --claude-bin claude-two-results 2>&1); rc=$?
assert_eq "$rc" "0" "a phase whose CLI retried and emitted TWO result envelopes SUCCEEDS"
# The specific wreckage the two-envelope parse produced, each asserted ABSENT —
# a bare rc check passes against a build that merely fails differently.
case "$out" in
  *"integer expression expected"*) t_fail "no shell error from a two-line figure" "found 'integer expression expected'";;
  *) t_pass "no shell error from a two-line figure";;
esac
case "$out" in
  *"the runner reported failure"*) t_fail "the ABANDONED attempt's error does not outvote the retry" "found 'the runner reported failure'";;
  *) t_pass "the ABANDONED attempt's error does not outvote the retry";;
esac
# And it reads the LAST envelope, not the first: the retry is the one that
# describes how the invocation actually ended.
assert_contains "$out" "6 turns" "the LAST envelope's turn count is the one recorded"
case "$out" in
  *194*) t_fail "the superseded first envelope is not reported" "found '194' from the first attempt";;
  *) t_pass "the superseded first envelope is not reported";;
esac

# The template check stands on its own, independent of how the phase exited.
printf '\nan unfilled template is not an artifact\n'
TPL="$WORK/tpl.md"
printf '# Implementation Plan: [FEATURE]\n\n# [REMOVE IF UNUSED] Option 1\n' > "$TPL"
for i in $(seq 1 40); do printf 'filler %s\n' "$i" >> "$TPL"; done
IFS=$'\t' read -r st note < <(verify_phase plan "$WORK" "tpl.md")
assert_eq "$st" "failed" "a plan.md still carrying template placeholders fails"
assert_contains "$note" "still the TEMPLATE" "and says which way it is unfinished"
# And the inverse: a filled document with ordinary lowercase placeholders in an
# example table must still pass, or the check is useless in practice.
printf '# Implementation Plan: Trust and access\n\n' > "$TPL"
printf 'Call `[endpoint]` with `[action]` for user [name]; see US1.\n' >> "$TPL"
for i in $(seq 1 40); do printf 'real content %s\n' "$i" >> "$TPL"; done
IFS=$'\t' read -r st note < <(verify_phase plan "$WORK" "tpl.md")
assert_eq "$st" "ok" "a FILLED plan keeping lowercase example placeholders passes"

# ------------------------------------ the vendored bundle is self-consistent ----
printf '\nthe bundle satisfies its own preflight\n'
# spec-bootstrap installs the vendored assets; spec-run then reads the project's
# own extensions.yml to decide which skills are required. Those two must agree,
# and nothing made them: the vendored extensions.yml hooked
# `speckit.agent-context.update` while that skill was not vendored, so bootstrap
# produced a project that failed its own preflight immediately — and the remedy it
# printed was to run bootstrap again, which could not help.
SC="$WORK/selfconsistent"; mkbare "$SC" main
"$SPEC_BOOTSTRAP" "$SC" >/dev/null 2>&1
out=$("$SPEC_RUN" --repo "$SC" --only specify --dry-run "probe" 2>&1); rc=$?
assert_eq "$rc" "0" "a freshly bootstrapped project passes preflight"
assert_not_contains "$out" "missing skills" "with no skill left unvendored"

# and state it directly, so the failure names the cause rather than a symptom
hooked=$(grep -E "command:" "$PKG/assets/specify/extensions.yml" 2>/dev/null |
         sed 's/.*command:[[:space:]]*//' | sort -u)
unvendored=""
for c in $hooked; do
  sk=$(printf '%s' "$c" | tr '.' '-')
  [ -d "$PKG/assets/claude-skills/$sk" ] || unvendored="${unvendored:+$unvendored }$sk"
done
assert_eq "$unvendored" "" "every skill the vendored extensions.yml hooks is also vendored"
n_hooked=$(printf '%s\n' "$hooked" | grep -c . || true)
[ "${n_hooked:-0}" -ge 2 ] && t_pass "and there are $n_hooked hooked commands to check" \
  || t_fail "the hook extraction found commands" "only $n_hooked — the pattern has drifted"

# ------------------------------------------- which skills are REQUIRED ---------
printf '\nrequired skills are derived, not assumed\n'
# spec-kit 0.7.3 ships five git-* skills and a mandatory before_specify hook that
# creates the branch. 0.11.3 REMOVED the git extension entirely and lets specify
# create the directory without one. A hardcoded requirement on
# speckit-git-feature refused to run in every 0.11.3 project — and the remedy it
# printed would have installed 0.7.3's git skills into a 0.11.3 project, mixing
# two versions. So the requirement is read from the project: the phase skills come
# from phases.json, the rest from whatever .specify/extensions.yml hooks.

# a 0.11.3-shaped project: phase skills, no git-* skills, no hooks needing them
V11="$WORK/v11"; mkbare "$V11" main
mkdir -p "$V11/.specify/scripts/bash" "$V11/.specify/templates" "$V11/specs"
for sk in specify plan tasks implement analyze remediate clarify converge review; do mkdir -p "$V11/.claude/skills/speckit-$sk"; done
printf 'installed:\n- agent-context\nhooks:\n  after_specify:\n  - extension: agent-context\n    command: speckit.agent-context.update\n' \
  > "$V11/.specify/extensions.yml"
mkdir -p "$V11/.claude/skills/speckit-agent-context-update"
out=$("$SPEC_RUN" --repo "$V11" --only specify --dry-run "probe" 2>&1); rc=$?
assert_eq "$rc" "0" "a project with no git-* skills is accepted when it hooks none"
assert_contains "$(unquote "$out")" "/speckit-specify" "and the phase is still invoked"

# the same project, but hooking a skill it does not have
printf 'hooks:\n  before_specify:\n  - extension: git\n    command: speckit.git.feature\n' \
  > "$V11/.specify/extensions.yml"
out=$("$SPEC_RUN" --repo "$V11" --only specify --dry-run "probe" 2>&1); rc=$?
assert_eq "$rc" "1" "but a project that HOOKS a missing skill is refused"
assert_contains "$out" "speckit-git-feature" "naming the skill its own hooks ask for"
assert_contains "$out" "extensions.yml" "and where that requirement came from"
# Derived both ways: the same project is fine or broken depending only on what it
# declares, which is the difference between reading a requirement and inventing
# one. Mutation: hardcode the git-* list again and the FIRST assertion fails.

# a phase skill is required unconditionally, because a phase cannot run without it
rm -rf "$V11/.claude/skills/speckit-plan"
printf 'installed: []\n' > "$V11/.specify/extensions.yml"
out=$("$SPEC_RUN" --repo "$V11" --only specify --dry-run "probe" 2>&1); rc=$?
assert_eq "$rc" "1" "a missing PHASE skill is refused even with no hooks at all"
assert_contains "$out" "speckit-plan" "naming it"
# Note it refuses even though only `specify` was selected: a config naming a skill
# the project lacks is broken whether or not this particular run would reach it.

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
  /speckit-review*)    { printf '# Review\n'; pad; printf 'No findings. Checked src/main.py:12.\n'; } > "$dir/review.md";;
esac
echo '{"total_cost_usd":0.01,"num_turns":1,"duration_ms":5,"result":"STATUS: ok",
       "usage":{"cache_read_input_tokens":900,"cache_creation_input_tokens":300,
                "input_tokens":10,"output_tokens":40}}'
FAKEEOF
chmod +x "$FAKE/claude-eats-stdin"

MP="$WORK/multiphase"; mkbare "$MP" main
"$SPEC_BOOTSTRAP" "$MP" >/dev/null 2>&1
git -C "$MP" add -A >/dev/null 2>&1; git -C "$MP" commit -qm bootstrap
out=$(SPEC_RUN_CLAUDE_BIN=claude-eats-stdin "$SPEC_RUN" --repo "$MP" "build the thing" 2>&1); rc=$?
assert_eq "$rc" "0" "a full run with a stdin-reading runner completes"
ran=$(jq -r '[.phases | to_entries[] | select(.value.status=="ok") | .key] | join(",")' \
      "$MP/specs/001-multi/.pipeline/state.json" 2>/dev/null)
assert_eq "$ran" "specify,plan,tasks,implement,review" \
  "and ALL FIVE default phases ran, in order, not just the first"
# Mutation: restore `done < <(jq -c '.phases[]' "$CONFIG")` and this reports
# "specify" alone — the exact shape the real run produced.
assert_contains "$out" "→ review" "the last phase was reached"
n_phase_lines=$(printf '%s\n' "$out" | grep -cE '^→ (specify|plan|tasks|implement|review)' || true)
assert_eq "$n_phase_lines" "5" "five phases were announced, so none was silently skipped"

# ------------------------------------------------ the token split is recorded --
# The whole reason to keep a cost log is to be able to answer "where did it go",
# and cost plus turns cannot: they say what was spent, not what it was spent on.
# Measured across 40 real phase envelopes, cache reads are 60-75% of a phase's
# bill and output is 10-15% — so a log without the split points at the 13% and
# stays silent about the 70%.
MPCOST="$MP/specs/001-multi/.pipeline/cost.log"
assert_contains "$(head -1 "$MPCOST")" "cache_read" "cost.log carries a cache_read column"
_cl=$(awk -F'\t' '$2=="review"{print $8"/"$9"/"$10"/"$11}' "$MPCOST" | tail -1)
assert_eq "$_cl" "900/300/10/40" \
  "and the four token counts land in their own columns, from the envelope's usage block"
_su=$(jq -r '.phases.review.usage | "\(.cache_read_tokens)/\(.cache_write_tokens)/\(.input_tokens)/\(.output_tokens)"' \
      "$MP/specs/001-multi/.pipeline/state.json")
assert_eq "$_su" "900/300/10/40" "the state file records them too, so spec-status can read them"
assert_contains "$out" "token profile" "and the run prints a token profile"
# read/turn is the figure worth printing: cache_read over turns is the AVERAGE
# RESIDENT CONTEXT, because every turn re-reads everything before it. One real
# plan phase read 17,946,392 cached tokens over 96 turns — ~187k carried on every
# turn — and that, not the turn count, is what a shorter pass actually moves.
assert_contains "$out" "READ/TURN" "naming the average resident context"

# An UNMEASURED figure must not record as a measured zero, exactly as with cost.
# A stub that reports no usage block is the ordinary case for an older runner, and
# "this phase read nothing" would be remarkable news rather than a missing field.
assert_eq "$(fmt_tokens "")" "unmeasured" "an absent token count reads as unmeasured, not 0"
assert_eq "$(fmt_tokens "null")" "unmeasured" "and so does a null one"
assert_eq "$(fmt_tokens 17946392)" "17.9M" "a large count is abbreviated for comparison"
assert_eq "$(fmt_tokens 900)" "900" "a small one is left alone"
assert_eq "$(fmt_read_per_turn 17946392 96)" "187k" "read/turn is cache reads over turns"
assert_eq "$(fmt_read_per_turn 17946392 "")" "" "with no turn count it prints nothing"
assert_eq "$(fmt_read_per_turn 17946392 0)" "" "and never divides by zero to reach a confident 0"

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
assert_not_contains "$argv" "--max-budget-usd" "no spend ceiling is passed when none is configured"
# The absence above is only half the claim. On its own it also passes if the flag
# were dropped entirely, so assert the plumbing still works when a ceiling IS
# configured — that is the half a bare absence check cannot see.
capcfg="$WORK/phases-capped.json"
jq '(.phases[] | select(.id == "specify")) |= (. + {max_budget_usd: 7})' \
   "$CONFIG" > "$capcfg"
argv_capped=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only specify \
              --config "$capcfg" --dry-run 2>&1)
assert_contains "$argv_capped" "--max-budget-usd 7" \
  "a configured ceiling is still passed through"
deny=$(unquote "$argv")
assert_contains "$deny" "Bash(gh pr merge:*)" "merging is denied to the specify phase"
assert_contains "$deny" "Bash(git push:*)" "pushing is denied to the specify phase"
assert_contains "$argv" "--strict-mcp-config" "specify drops MCP servers it cannot use"

# The handoff contract is a load-bearing prompt, and nothing asserted its content
# until a phase proved why it matters. A phase launched a 5-seed balance run in the
# BACKGROUND, then spent its remaining budget on `sleep 1` and `echo waiting`,
# waiting for a "monitor notification" that cannot arrive in a headless process —
# its last real edit was 40 minutes earlier. Same trap as delegating to a subagent
# and waiting; background Bash is the second door into it.
contract=$(unquote "$argv")
assert_contains "$contract" "YOU ARE HEADLESS" \
  "the phase is told it is headless"
assert_contains "$contract" "SYNCHRONOUSLY" \
  "and to run long commands synchronously rather than polling for them"
assert_contains "$contract" "/dev/null" \
  "and to redirect stdin so a prompting command fails instead of blocking"
assert_contains "$contract" "Do this phase and stop" \
  "and not to run the next phase"
# Phase-specific additions must reach the phase they are for, and NOT the others.
assert_not_contains "$contract" "TICK EACH TASK" \
  "specify is not told to tick tasks — it has none"

# implement is, because a batched tasks.md is a lost handoff: one interrupted phase
# had modified 34 files with 0 of 57 ticked, costing a $8.06 converge pass to
# re-derive from source what the file should have stated.
argv_impl=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only implement --dry-run 2>&1)
contract_impl=$(unquote "$argv_impl")
assert_contains "$contract_impl" "TICK EACH TASK" \
  "implement is told to tick each task as it finishes"
assert_contains "$contract_impl" "HANDOFF" \
  "and told why: tasks.md is the handoff, not a closing report"
assert_contains "$contract_impl" "YOU ARE HEADLESS" \
  "and still gets the shared contract"
assert_contains "$contract_impl" "ONE PASS OF A CHUNKED PHASE" \
  "and, being chunked, is told to do one ## Phase group and stop"

# 🛑 Cost in a pass is dominated by re-reading its own transcript, not by output:
# one measured pass reported 27,706,579 cache-read tokens against 28,608 output
# tokens (968:1). So anything large dumped EARLY is paid for again by every turn
# after it — that pass carried 9 tool results over 4k chars, ~27k tokens, mostly
# full-suite output from runs made between tasks.
#
# The instruction is narrow-then-broad rather than "defer all verification",
# because ticking a task requires knowing it passed: a deferred check would mean
# ticking on faith and discovering the failure a pass later.
assert_contains "$contract_impl" "VERIFY NARROWLY AS YOU GO, BROADLY ONCE AT THE END" \
  "implement is told where to put its verification, not just to do it"
assert_contains "$contract_impl" "27,706,579" \
  "and given the measurement, so the next reader can check the reasoning"
assert_contains "$contract_impl" "tail -30" \
  "and a concrete truncation to use rather than a vague instruction to be brief"

# 🛑 Cost within a pass grows with roughly the SQUARE of its length, because every
# turn re-reads everything before it. So two short passes beat one long pass over
# the same tasks — each starts from a clean prefix. Measured across one entry's 14
# passes: 39 94 90 67 60 45 70 97 75 94 76 58 104 46 turns (mean 72, max 104).
#
# ⚠️ Expressed in WALL CLOCK, not turns, because a phase cannot observe its own turn
# count — the CLI reports num_turns only in its final result, so a turn target would
# be an instruction it could not act on. This repo already learned that when a
# transcript showing 414 messages turned out to belong to a phase the CLI had not
# stopped at a 400 cap.
assert_contains "$contract_impl" "PREFER TO STOP EARLY WHEN A PASS RUNS LONG" \
  "a chunked pass is told to stop early rather than run a group to its end"
assert_contains "$contract_impl" "15 minutes" \
  "with a concrete threshold it can actually observe"
assert_contains "$contract_impl" "cannot observe your own turn count" \
  "and told why the threshold is time rather than turns"

# 🛑 The runner already knows where the next pass should start, and used to throw
# it away. tasks_unchecked() reads the same file the pass then re-scanned for
# itself: the run logs of one entry show passes opening on shapes like
#   awk '/^#+ Phase/{...} /- \[/{if ($0 ~ /- \[ \]/) unchecked[phase]++}' tasks.md
# to work out which group was next. Those turns are not merely their own cost —
# their output joins the prefix that EVERY later turn of the pass re-reads, so a
# discovery turn is paid for once and then again per turn thereafter.
DG="$WORK/digest"; mkdir -p "$DG/specs/001-d"
cp -R "$BS/.specify" "$BS/.claude" "$DG/" 2>/dev/null
( cd "$DG" && git init -q && git add -A >/dev/null 2>&1 && git commit -qm f )
{ printf '# Tasks\n\n## Phase 1: Setup\n\n'
  printf -- '- [x] T001 done already\n- [x] T002 also done\n\n'
  printf '## Phase 2: Core endpoints\n\n'
  printf -- '- [x] T003 done\n- [ ] T004 write the handler\n- [ ] T005 wire it up\n\n'
  printf '## Phase 3: Polish\n\n'
  printf -- '- [ ] T006 docs\n'; } > "$DG/specs/001-d/tasks.md"
argv_dg=$(unquote "$("$SPEC_RUN" --repo "$DG" --feature-dir "$DG/specs/001-d" \
                     --only implement --dry-run 2>&1)")
assert_contains "$argv_dg" "WHERE YOU ARE IN tasks.md" \
  "a chunked pass is handed its place in tasks.md rather than made to find it"
assert_contains "$argv_dg" "Phase 2: Core endpoints" \
  "naming the next group with unfinished work, not the first group"
assert_contains "$argv_dg" "T004 T005" \
  "and that group's unchecked task ids, in order"
assert_not_contains "$argv_dg" "T003" \
  "while leaving out the ones already ticked"
assert_contains "$argv_dg" "3 unchecked of 6" \
  "with the overall count, so the pass knows how much is left beyond its group"
assert_contains "$argv_dg" "2 group(s) with work left" \
  "and how many groups still have work"
# 🛑 The digest also says WHERE the group sits, so the pass can Read that slice
# rather than the file. Measured across 58 implement transcripts in one week:
# every pass Read all of tasks.md (61 reads) at a median 49 KB, maximum 184 KB —
# 12k to 46k tokens carried by every later turn of the pass, almost all of it
# groups already ticked or not yet due. In the fixture, Phase 2's heading is
# line 8 and its last line before the Phase 3 heading is 13, of 16.
assert_contains "$argv_dg" "at lines:    8-13 of 16" \
  "the digest names the line range the next group occupies"
assert_contains "$argv_dg" "READ ONLY THOSE LINES" \
  "and tells the pass to read that slice rather than the whole file"
assert_contains "$argv_dg" "offset 8 and limit 6" \
  "with the Read arguments spelled out so the instruction can be followed literally"
# The digest is a POINTER, not a replacement for reading: skipping Phase 1
# entirely is the whole behaviour under test, and a digest that named Phase 1
# would send every pass back to work that is already done.

# Non-chunked phases must not receive it. They have no pass to place, and a
# prompt that describes a loop the phase is not in is worse than no prompt.
assert_not_contains "$contract" "WHERE YOU ARE IN tasks.md" \
  "and specify, which is not chunked, is not handed one"

# 🛑 A phase runs for tens of minutes; `pmset` on the machine this was written for
# reports `sleep 1`. So every phase races a sleep it does not hold off, and the
# engine must hold the assertion rather than relying on whoever launched it.
# Measured cost of not doing so, in one entry: the tasks phase died with exit 137
# and an empty stderr (reads like an OOM, is not), and one implement pass spent
# $7.89 to return "your computer went to sleep mid-response" and tick nothing.
argv_wake=$(unquote "$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" \
             --only plan --dry-run 2>&1)")
if command -v caffeinate >/dev/null 2>&1; then
  assert_contains "$argv_wake" "caffeinate -i" \
    "the phase is launched under a power assertion"
  # -i only: -d would keep the display awake for no reason, and -s applies only on
  # AC power, so it would silently do nothing on battery — the case that matters.
  assert_not_contains "$argv_wake" "caffeinate -d" \
    "and not one that also pins the display awake"
  assert_not_contains "$argv_wake" "caffeinate -s" \
    "nor one that quietly does nothing on battery"
else
  t_pass "power assertion skipped — caffeinate is not on this platform"
  # 🛑 The three assertions above CANNOT run here, so the suite's total is
  # platform-dependent — and the README count is a single number, so it could not
  # be true in both places at once. Measured: 3 assertions on macOS vs this 1 pass
  # on Linux, a gap of 2, which left CI red on main from 2026-08-24 (442 against a
  # README advertising 444) while the same tree was green locally.
  #
  # Recording the shortfall rather than padding with fake passes: a t_pass per
  # unrunnable assertion would make the number agree by asserting nothing, which is
  # the opposite of what this count exists to detect.
  PLATFORM_GATED_ASSERTIONS=$((${PLATFORM_GATED_ASSERTIONS:-0} + 2))
fi
# The runner must still be the named executable, with caffeinate in front of it
# rather than in place of it.
assert_contains "$argv_wake" "-p " \
  "and the runner itself is still invoked, not replaced"

# ------------------------------------------------------ chunked implement ------
# Cost is ~linear in cache_read, which grows with turn count, so one long phase
# costs ~90k*T + 0.7k*T^2 tokens and k shorter passes divide the quadratic term by
# k. The loop only pays off if it also cannot run away, so both guards matter more
# than the saving.
printf '\nimplement: chunked passes\n'
CH="$WORK/chunked"; mkbare "$CH" main
"$SPEC_BOOTSTRAP" "$CH" >/dev/null 2>&1
git -C "$CH" add -A >/dev/null 2>&1; git -C "$CH" commit -qm bootstrap
mkdir -p "$CH/specs/001-c"
# Generous: the artifact check enforces a 400-byte minimum, and a fixture that
# trips it fails the phase for reasons that have nothing to do with chunking.
pad_c() { for i in $(seq 1 60); do printf 'padding line %s with enough text to clear the size floor\n' "$i"; done; }
{ printf '# Spec\n'; pad_c; } > "$CH/specs/001-c/spec.md"
{ printf '# Plan\n'; pad_c; } > "$CH/specs/001-c/plan.md"

# A runner that ticks exactly ONE box per pass: three passes to clear three tasks.
cat > "$FAKE/claude-ticks-one" <<'FAKEEOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "--help" ] && exit 0; done
root=$(pwd); f="$root/specs/001-c/tasks.md"
# tick the first unchecked box, if any
if grep -q '^- \[ \]' "$f" 2>/dev/null; then
  awk 'BEGIN{done=0} /^- \[ \]/ && !done {sub(/\[ \]/,"[x]"); done=1} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
fi
echo '{"total_cost_usd":0.02,"num_turns":3,"duration_ms":5,"result":"STATUS: ok",
       "usage":{"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,
                "input_tokens":5,"output_tokens":50}}'
FAKEEOF
chmod +x "$FAKE/claude-ticks-one"

{ printf '# Tasks\n'; pad_c; printf -- '- [ ] T001 a\n- [ ] T002 b\n- [ ] T003 c\n'; } > "$CH/specs/001-c/tasks.md"
out=$(SPEC_RUN_CLAUDE_BIN=claude-ticks-one "$SPEC_RUN" --repo "$CH" \
        --feature-dir "$CH/specs/001-c" --only implement 2>&1); rc=$?
assert_eq "$rc" "0" "a chunked implement clears a multi-task list"
assert_eq "$(grep -c '^- \[ \]' "$CH/specs/001-c/tasks.md")" "0" "every box is ticked"
assert_contains "$out" "pass 3/" "and it took a pass per task"
assert_contains "$out" "task list clear after 3 pass" "reporting how many passes it took"
# The roll-up matters: state_phase_finish runs per PASS, so without accumulation
# the recorded cost is the last pass alone and the run looks 3x cheaper than it was.
assert_eq "$(jq -r '.phases.implement.cost_usd' "$CH/specs/001-c/.pipeline/state.json")" "0.06" \
  "cost is the sum of all passes, not the last one"
assert_eq "$(jq -r '.phases.implement.passes' "$CH/specs/001-c/.pipeline/state.json")" "3" \
  "and the pass count is recorded"
# The tokens roll up the same way, and this is the field where getting it wrong
# would matter most: implement is both the most expensive phase and the only
# chunked one, so a per-pass figure recorded as the phase's would understate
# exactly the thing worth measuring — by an order of magnitude on twelve passes.
_ru=$(jq -r '.phases.implement.usage | "\(.cache_read_tokens)/\(.cache_write_tokens)/\(.input_tokens)/\(.output_tokens)"' \
      "$CH/specs/001-c/.pipeline/state.json")
assert_eq "$_ru" "3000/600/15/150" "the token counts are summed over all three passes, not the last"
# Every pass also keeps its own line, because the per-pass numbers are what show
# a long pass costing more than two short ones.
assert_eq "$(awk -F'\t' '$2=="implement"{n++} END{print n+0}' "$CH/specs/001-c/.pipeline/cost.log")" "3" \
  "while cost.log keeps one line per pass"

# 🛑 The guard that keeps this from being worse than truncation: a pass that ticks
# nothing must END the loop. Otherwise a phase that cannot progress spends
# indefinitely, silently, at cost per turn.
cat > "$FAKE/claude-ticks-none" <<'FAKEEOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "--help" ] && exit 0; done
echo '{"total_cost_usd":0.02,"num_turns":3,"duration_ms":5,"result":"STATUS: ok"}'
FAKEEOF
chmod +x "$FAKE/claude-ticks-none"
{ printf '# Tasks\n'; pad_c; printf -- '- [ ] T001 a\n- [ ] T002 b\n'; } > "$CH/specs/001-c/tasks.md"
rm -rf "$CH/specs/001-c/.pipeline"
out=$(SPEC_RUN_CLAUDE_BIN=claude-ticks-none "$SPEC_RUN" --repo "$CH" \
        --feature-dir "$CH/specs/001-c" --only implement 2>&1); rc=$?
# Exit 2, not 1: a stalled loop is "waiting on you", and the roadmap treats those
# differently — 1 fails the entry and stops the roadmap, 2 hands it over with the
# work intact. Measured on the entry that prompted this: 50 of 51 tasks done, the
# remaining one a browser check a headless phase structurally cannot do. Nothing
# had failed.
assert_eq "$rc" "2" "a pass that ticks nothing stops the loop as needs-a-human, not failed"
assert_contains "$out" "ticked nothing" "naming the reason"
assert_contains "$out" "need a human" "and saying what to look for"
assert_not_contains "$out" "pass 2/" "and does NOT try a second pass"

# An ABSENT task list is not a finished one — chunking has nothing to measure, so
# it must run once rather than skip, which would be a silent no-op.
rm -f "$CH/specs/001-c/tasks.md"; rm -rf "$CH/specs/001-c/.pipeline"
out=$(SPEC_RUN_CLAUDE_BIN=claude-ticks-none "$SPEC_RUN" --repo "$CH" \
        --feature-dir "$CH/specs/001-c" --only implement 2>&1); rc=$?
assert_contains "$out" "no tasks.md to chunk on" "an absent task list is reported, not treated as done"
assert_contains "$out" "→ implement" "and the phase still runs once"

# ------------------------------------------------- orphaned phase children -----
# 🛑 A phase runs inside a command substitution, so its pid is never the runner's
# to hold, and signalling the runner used to leave the `claude -p` child running
# with every tool it had. Measured: an implement phase whose parent was killed
# carried on for ~2 hours, ticked its remaining tasks, and COMMITTED to the
# repository while a human was separately verifying and merging that same work.
# The commit simply appeared, authored by the repo's git identity.
printf '\nsignals: the phase dies with the runner\n'
# 🛑 The precondition is the EXACT query kill_descendants makes, not
# `command -v ps`. Under Claude Code's own Bash sandbox `ps` IS on PATH and
# `ps -eo pid=,ppid=` is refused with "operation not permitted" — so the process
# table reads as EMPTY, kill_descendants finds no children, and this assertion
# goes red against a function that is correct. Verified both ways on macOS 25.5:
# refused inside the sandbox, and outside it the grandchild is found and reaped.
#
# Probing for the binary would have succeeded and still left the failure, which
# is why the probe is the query rather than the command. An environment that
# cannot answer it must SKIP: this is the guard over the worst bug in this repo's
# history, and a red tick on it that means "your shell cannot run ps" is how a
# reader learns to skim failures on the assertions that matter most.
_orph_parent=""; _orph_child=""
if [ "$(ps -eo pid=,ppid= 2>/dev/null | grep -c .)" -eq 0 ]; then
  t_skip "kill_descendants reaps a grandchild" \
         "the process table is unreadable here, so the function cannot be exercised"
  # Gated, not padded — same accounting as the caffeinate block above, and for
  # the same reason: the README advertises one number and it has to be true on a
  # host that can read the table and on one that cannot.
  PLATFORM_GATED_ASSERTIONS=$((${PLATFORM_GATED_ASSERTIONS:-0} + 1))
else
  ( sleep 45 & echo $! > "$WORK/orphan.pid"; wait ) >/dev/null 2>&1 &
  _orph_parent=$!
  sleep 1
  _orph_child=$(cat "$WORK/orphan.pid" 2>/dev/null)
  if [ -n "$_orph_child" ] && kill -0 "$_orph_child" 2>/dev/null; then
    kill_descendants "$_orph_parent"
    kill -TERM "$_orph_parent" 2>/dev/null
    # Reap it, or bash prints an async "Terminated" job notice into the results.
    wait "$_orph_parent" 2>/dev/null || true
    sleep 1
    kill -0 "$_orph_child" 2>/dev/null \
      && t_fail "kill_descendants reaps a grandchild, not just the child" \
      || t_pass "kill_descendants reaps a grandchild, not just the child"
  else
    t_skip "kill_descendants reaps a grandchild" "could not stage the process tree"
    PLATFORM_GATED_ASSERTIONS=$((${PLATFORM_GATED_ASSERTIONS:-0} + 1))
  fi
  # Tear the staged tree down on every path out. The skip above left a 45-second
  # `sleep` and its subshell running — harmless, but this is the section about not
  # orphaning processes, and a leak here would be the joke writing itself.
  kill_descendants "$_orph_parent" 2>/dev/null || true
  kill -TERM "$_orph_parent" 2>/dev/null || true
  wait "$_orph_parent" 2>/dev/null || true
  if [ -n "$_orph_child" ]; then kill -9 "$_orph_child" 2>/dev/null || true; fi
fi
# And the runner installs it, so an interrupted run cannot leave a phase behind.
assert_contains "$(cat "$SPEC_RUN")" "trap _on_signal INT TERM" \
  "spec-run traps INT and TERM"
assert_contains "$(cat "$SPEC_RUN")" "kill_descendants \$\$" \
  "and takes its phase down with it"

# The Monitor watcher is spawned by the AGENT following commands/*.md, not by
# spec-run, so no trap can reach it — the instruction to reap it is the only
# mechanism available, which makes the instruction itself load-bearing and worth
# asserting. Measured 2026-09-01: 17 orphaned tail+grep pairs, the oldest following
# a log five days stale, on a host that had reached load average 338 with swap 97%.
# Whitespace is normalised before matching: these phrases are hard-wrapped in the
# markdown, and a raw substring search reports a phrase that IS present as ABSENT,
# which invites the next reader to paste it in again rather than fix the match.
for _cmd_doc in "$PKG/commands/spec-run.md" "$PKG/commands/spec-roadmap.md"; do
  _doc_flat="$(tr -s '[:space:]' ' ' < "$_cmd_doc")"
  _doc_name="$(basename "$_cmd_doc")"
  assert_contains "$_doc_flat" 'pkill -f "tail -f -n +1 <logfile>"' \
    "$_doc_name tells the agent how to reap its watcher"
  assert_contains "$_doc_flat" "Reap the watcher when the run ends" \
    "$_doc_name names reaping as a required step"
  assert_contains "$_doc_flat" "full logfile path" \
    "$_doc_name warns against a broad pkill that hits a concurrent run's watcher"
done

argv=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only tasks --dry-run 2>&1)
assert_contains "$argv" "--model sonnet" "tasks is invoked on sonnet"

argv=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only implement --dry-run 2>&1)
assert_contains "$argv" "--model sonnet" "implement is invoked on sonnet"
# implement DROPS its MCP servers, reversing the earlier default. Every tool
# definition sits in the cached prefix of every turn, so a phase that never calls
# one pays for the whole list once per turn — a fixed cost paid T times, which is
# cheaper to remove than the work is to shorten.
assert_contains "$argv" "--strict-mcp-config" "implement drops its MCP servers"

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

# --mcp, in its OWN variable. Reusing `argv` here is a real trap and was one
# while this was being written: the deny assertions above read whatever `argv`
# last held, so an invocation inserted between them silently changed what they
# were checking — `implement MAY push its own branch` started failing against a
# plan invocation that legitimately denies it.
argv_mcp=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only implement \
            --mcp implement=inherit --dry-run 2>&1)
assert_not_contains "$argv_mcp" "--strict-mcp-config" \
  "--mcp implement=inherit restores the servers the config drops"
argv_mcp=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only plan \
            --mcp plan=none --dry-run 2>&1)
assert_contains "$argv_mcp" "--strict-mcp-config" \
  "and --mcp plan=none takes them from the one phase that keeps them"
# Both directions, deliberately: a flag that cannot restore what the default
# removed is not an override, and the measurement this exists to enable — run one
# feature both ways, compare cache_read — needs the same phase to go BOTH ways.
assert_contains "$argv_mcp" "--model opus" "without disturbing anything else about the phase"

# A misspelled value must not silently mean `inherit`. The two spellings are
# indistinguishable in the output: the run would simply cost more than the flag
# said it would, which is the exact failure this flag exists to measure.
out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --mcp implement=non --dry-run 2>&1); rc=$?
assert_eq "$rc" "3" "--mcp with a value that is neither none nor inherit is a usage error"
assert_contains "$out" "none or inherit" "naming what it does take"
out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --mcp nope=none --dry-run 2>&1); rc=$?
assert_eq "$rc" "3" "and --mcp naming an unknown phase is one too"
# The `info` line states which way it went, for the same reason an unapplied
# ceiling must not read as an applied one: whether a tool list was loaded is
# otherwise invisible, and it is one of the larger things a phase pays for.
assert_contains "$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" \
                    --only implement --dry-run 2>&1)" "mcp none" \
  "and the run says which way it went"

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

# =================================================================== spec-upgrade
printf '\nspec-upgrade\n'

# A project on an older scaffold. Built by hand rather than bootstrapped, so the
# "older" files are genuinely different from the vendored ones.
mkold() { # mkold <path>
  mkbare "$1" main
  mkdir -p "$1/.specify/scripts/bash" "$1/.specify/templates" "$1/.specify/memory" "$1/specs/001-old"
  for sk in specify plan tasks implement analyze clarify constitution checklist \
            taskstoissues converge git-commit git-feature git-initialize \
            git-remote git-validate agent-context-update; do
    mkdir -p "$1/.claude/skills/speckit-$sk"
    printf -- '---\nname: speckit-%s\n---\nold body\n' "$sk" > "$1/.claude/skills/speckit-$sk/SKILL.md"
  done
  printf 'old plan template\n' > "$1/.specify/templates/plan-template.md"
  printf 'old spec template\n' > "$1/.specify/templates/spec-template.md"
  printf 'MY CONSTITUTION, hands off\n' > "$1/.specify/memory/constitution.md"
  printf '{"feature_directory":"specs/001-old"}\n' > "$1/.specify/feature.json"
  printf 'my spec\n' > "$1/specs/001-old/spec.md"
  printf '{"integration":"claude","version":"0.7.3"}\n' > "$1/.specify/integration.json"
  printf 'hooks:\n  before_specify:\n  - extension: git\n    command: speckit.git.feature\n' \
    > "$1/.specify/extensions.yml"
  git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm scaffold
}

UP="$WORK/upgrade"; mkold "$UP"

# --- --check reports drift without touching anything
before=$(git -C "$UP" rev-parse HEAD)
out=$("$SPEC_UPGRADE" --repo "$UP" --check 2>&1); rc=$?
assert_eq "$rc" "2" "--check exits 2 when the project is behind (so CI can gate)"
assert_contains "$out" "0.7.3" "reporting the version it found"
assert_eq "$(git -C "$UP" rev-parse HEAD)" "$before" "and changes nothing"
assert_eq "$(git -C "$UP" status --porcelain | grep -c . || true)" "0" "not even in the working tree"

# --- --dry-run prints the plan and changes nothing
out=$("$SPEC_UPGRADE" --repo "$UP" --dry-run 2>&1); rc=$?
assert_eq "$rc" "0" "--dry-run exits 0"
assert_contains "$out" "nothing was changed" "and says so"
assert_eq "$(git -C "$UP" status --porcelain | grep -c . || true)" "0" "leaving the tree clean"

# --- it refuses over uncommitted work in the paths it would rewrite
printf 'my edit\n' >> "$UP/.specify/templates/plan-template.md"
out=$("$SPEC_UPGRADE" --repo "$UP" --yes 2>&1); rc=$?
assert_eq "$rc" "1" "it refuses when the scaffold has uncommitted changes"
assert_contains "$out" "git diff is how you review" "explaining that git is the undo"
assert_contains "$(cat "$UP/.specify/templates/plan-template.md")" "my edit" "and leaves the edit alone"
git -C "$UP" checkout -- .specify

# --- an EDITED template is preserved as an override; an untouched one is upgraded
printf 'MY OWN GATES\n' >> "$UP/.specify/templates/plan-template.md"
git -C "$UP" add -A >/dev/null 2>&1; git -C "$UP" commit -qm "customise the plan template"
out=$("$SPEC_UPGRADE" --repo "$UP" --yes 2>&1); rc=$?
assert_eq "$rc" "0" "the upgrade succeeds"
assert_contains "$(cat "$UP/.specify/templates/overrides/plan-template.md" 2>/dev/null)" "MY OWN GATES" \
  "the EDITED template is preserved as an override"
assert_not_contains "$(cat "$UP/.specify/templates/spec-template.md")" "old spec template" \
  "while the untouched one is actually upgraded"
[ -f "$UP/.specify/templates/overrides/spec-template.md" ] \
  && t_fail "an untouched template is NOT preserved" "it was frozen as an override" \
  || t_pass "and is NOT frozen as an override"
# That distinction is the whole tool. "Differs from what we vendor" answers
# neither question; preserving everything that differs pins the project on its old
# templates forever, which is the opposite of upgrading. git answers it exactly:
# a scaffold file imported once and never touched has one commit.

# --- the project's own assertions and state are untouched
assert_eq "$(cat "$UP/.specify/memory/constitution.md")" "MY CONSTITUTION, hands off" \
  "the constitution is never rewritten"
assert_contains "$(cat "$UP/.specify/feature.json")" "001-old" "nor the current-feature pointer"
assert_eq "$(cat "$UP/specs/001-old/spec.md")" "my spec" "nor anything under specs/"

# --- the version marker is UPDATED, not replaced and not pruned
assert_eq "$(jq -r '.version' "$UP/.specify/integration.json")" "0.16.5" \
  "the recorded version is updated to the vendored one"
assert_eq "$(jq -r '.integration' "$UP/.specify/integration.json")" "claude" \
  "while the rest of the record survives"
# The first dry-run of this tool offered to PRUNE integration.json, which would
# have left the project unversioned and every later --check unable to answer.

# --- idempotent, and --check now agrees
out=$("$SPEC_UPGRADE" --repo "$UP" --check 2>&1); rc=$?
assert_eq "$rc" "0" "--check exits 0 once upgraded"
assert_contains "$out" "no drift" "reporting no drift"
out=$("$SPEC_UPGRADE" --repo "$UP" --yes 2>&1)
assert_contains "$out" "nothing to do" "and a second upgrade is a no-op"

# --- the upgraded scaffold must satisfy the pipeline it feeds
out=$("$SPEC_RUN" --repo "$UP" --only specify --dry-run "probe" 2>&1); rc=$?
assert_eq "$rc" "0" "spec-run accepts the upgraded project"

printf '\nspec-upgrade: the fleet view\n'
# --scan answers a question upstream cannot: which of my projects are on what.
FLEET="$WORK/fleet"; mkdir -p "$FLEET"
mkold "$FLEET/behind"
mkbare "$FLEET/current" main; "$SPEC_BOOTSTRAP" "$FLEET/current" >/dev/null 2>&1
mkbare "$FLEET/legacy" main
mkdir -p "$FLEET/legacy/.specify/templates" "$FLEET/legacy/.claude/commands"
for c in specify plan tasks implement; do printf 'old command\n' > "$FLEET/legacy/.claude/commands/speckit.$c.md"; done
mkbare "$FLEET/notspeckit" main

out=$("$SPEC_UPGRADE" --scan "$FLEET" 2>&1); rc=$?
assert_eq "$rc" "2" "--scan exits 2 when anything is behind"
assert_contains "$out" "behind" "listing the project that is"
assert_contains "$out" "commands:4" "and naming the pre-skills integration by shape"
assert_contains "$out" "pre-skills" "with a note that the pipeline cannot drive it"
assert_not_contains "$out" "notspeckit" "while skipping directories with no .specify at all"
assert_contains "$out" "of 3 on" "and reporting the count against the total, not a bare number"
# "unknown / 0 skills" was the first version of that column, and it reads like a
# broken install when it is a legitimate older generation. An absent value has to
# state its reason.

# a legacy command install is reported, never deleted
out=$("$SPEC_UPGRADE" --repo "$FLEET/legacy" --dry-run 2>&1)
assert_contains "$out" "pre-skills COMMAND integration" "an older command install is called out"
assert_contains "$out" "will not delete files it did" "and left for the human to remove"
# Matched on a fragment that cannot span the wrap: the message is printed across
# two say() calls, so the full sentence never appears on one line. Asserting the
# whole sentence failed against output that says exactly the right thing.
[ -f "$FLEET/legacy/.claude/commands/speckit.specify.md" ] \
  && t_pass "the old commands are still there after a dry run" \
  || t_fail "the old commands survive" "they were removed"

out=$("$SPEC_UPGRADE" --help 2>&1); assert_eq "$?" "0" "--help exits 0"
out=$("$SPEC_UPGRADE" --nonsense 2>&1); assert_eq "$?" "3" "an unknown option exits 3"
out=$("$SPEC_UPGRADE" --scan "$WORK/does-not-exist" 2>&1); rc=$?
assert_eq "$rc" "1" "--scan on a missing directory fails"

# ------------------------------------------------------- the progress filter ----
printf '\nstream_progress\n'
# What the filter shows is the only live view of a phase, and the first version
# was unreadable for the case that matters most. Both defects came from watching a
# real run, not from review.
ev() { printf '%s\n' "$1" | stream_progress "${2:-}" >/dev/null; }

# 1. the Skill tool's argument is named `skill`, so every line read "· Skill "
sk=$(printf '%s' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"speckit-plan"}}]}}' \
     | stream_progress 2>&1 >/dev/null)
assert_contains "$sk" "Skill speckit-plan" "a Skill call names the skill it invoked"

# 2. strip the repo prefix BEFORE truncating, and keep the tail
long='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/repo/services/blueprint/app/orgs/[podSlug]/scorecard-dashboards/team-cards/TeamCardsSummary.tsx"}}]}}'
out=$(printf '%s' "$long" | stream_progress /repo 2>&1 >/dev/null)
assert_contains "$out" "TeamCardsSummary.tsx" "a long path keeps its FILENAME"

# A running phase's spend was invisible until its result event, so a run killed
# partway through reported `unmeasured` with no way to see how far it got — while
# `message.usage` was in the stream all along and being discarded.
prog=$(printf '%s\n' \
 '{"type":"assistant","message":{"usage":{"output_tokens":1200},"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/r/a/b.ts"}}]}}' \
 '{"type":"assistant","message":{"usage":{"output_tokens":900},"content":[{"type":"tool_use","name":"Bash","input":{"command":"pnpm test"}}]}}' \
 '{"type":"result","is_error":false,"num_turns":2,"total_cost_usd":0.42}' \
 | stream_progress /r 2>&1 >/dev/null)
assert_contains "$prog" "[1t · 1.2k out]" "a running phase reports its turn count and output tokens"
assert_contains "$prog" "[2t · 2.1k out]" "and both accumulate across turns"

# 🛑 The guard that matters: turns and tokens are FACTS the stream carries, but a
# dollar figure mid-run would have to be computed from a per-model price table,
# and a hardcoded table deciding the figures this tool reports cannot be
# corrected without a release. The authoritative cost arrives in the result
# event, so that is the ONLY line allowed to print a currency sign.
midrun=$(printf '%s\n' "$prog" | grep -v 'done:' || true)
assert_not_contains "$midrun" '$' "no progress line ever prints an estimated cost"
assert_contains "$prog" 'done: 2 turns, $0.42' "the measured cost is reported once, with the result"

# 🛑 A phase runs in a ONE-SHOT headless process, so delegating work to a
# background subagent and waiting is a dead end: there is no session to receive
# the completion notification and no later turn to resume in. Measured on entry 2
# of a real roadmap — the phase spawned a `ppc-python-agent`, polled it three
# times with ListAgents, called ScheduleWakeup, then ended its own turn with
# "The backend agent is still running. I'll wait for its completion notification
# before proceeding to frontend work." It never continued. 42 turns and $10.71
# spent, 0 of 103 tasks ticked, and the 27 edits it had made were unattributed to
# any task.
#
# Prose telling the model not to delegate is the wrong mechanism (the phase
# prompt already says to do the work itself). Withholding the tools is the
# structural one, exactly as with `git push`.
# 🛑 An unattended phase must not be able to reach the network or read a
# credentials file. Measured on entry 2 of a real roadmap: to satisfy two tasks
# that said "measure on a real dashboard" and "the post-merge deployed-surface
# read", implement sourced `ppc-agent-context/.env`, refreshed a Pontifex token and
# curled the PRODUCTION context agent with a bearer header. All three were refused
# and it stopped — but the deny list contained none of those patterns at the time,
# so the refusal came from elsewhere (most likely the sandbox) and the boundary held
# by luck rather than by design.
#
# Blocking the TOOL is the structural fix. Pattern-matching production hostnames is
# the fragile shape-based alternative: there are too many ways to write a URL, and
# the guard would be defeated by the first one nobody thought of.
# ⚠️ NOT 'Bash(. *.env*)'. That pattern was added here and removed after one pass
# in production: it matched
#     cd <repo> PYTHONPATH=. .venv/bin/alembic upgrade head
# because `PYTHONPATH=.` ends in a dot, the next word is `.venv/...`, and `.venv`
# glob-matches `*.env*`. In a Python repo that is most commands, so the guard
# blocked migrations the phase legitimately needed — a guard that stops real work
# gets removed or worked around, and either way stops guarding. A one-character
# command name is a terrible pattern anchor; `source` is a whole word and cannot
# collide the same way.
assert_eq "$(jq -r '[.defaults.deny_tools[] | select(. == "Bash(. *.env*)")] | length' \
            "$PKG/lib/phases.json")" "0" \
  "the dot-source pattern is NOT present — it blocked .venv commands"

for t in 'Bash(curl:*)' 'Bash(wget:*)' 'Bash(http:*)' 'Bash(source *.env*)' 'WebFetch'; do
  n=$(jq -r --arg t "$t" '[.defaults.deny_tools[] | select(. == $t)] | length' \
      "$PKG/lib/phases.json")
  assert_eq "$n" "1" "a phase cannot reach the network or read credentials via $t"
done

for t in Task Agent ScheduleWakeup ListAgents SendMessage; do
  n=$(jq -r --arg t "$t" '[.defaults.deny_tools[] | select(. == $t)] | length' \
      "$PKG/lib/phases.json")
  assert_eq "$n" "1" "a phase cannot call $t — it has no way to wait for one"
done
assert_not_contains "$out" "/repo/" "with the repo prefix stripped"
# Truncating first left every line reading ".../worktrees/<name>/services/bluepri"
# — identical for every file, filename always cut. And no downstream sed can
# recover it, because the loss happens here.

out=$(printf '%s' "$long" | stream_progress 2>&1 >/dev/null)
assert_contains "$out" "TeamCardsSummary.tsx" "and keeps it even with no repo root to strip"

# 3. the stream is passed through unchanged, or the caller loses its metrics
through=$(printf '%s\n%s\n' '{"type":"assistant","message":{"content":[]}}' '{"type":"result","num_turns":3,"total_cost_usd":0.5}' | stream_progress 2>/dev/null)
assert_contains "$(extract_json "$through")" '"num_turns":3' "the result event survives the filter"

printf '\nroadmap: a budget that cannot be forgotten\n'
# A ceiling passed only on the command line is one somebody forgets, and a
# forgotten ceiling is silently unlimited.
BR2="$WORK/budgetfile"; mkbare "$BR2" main
"$SPEC_BOOTSTRAP" "$BR2" >/dev/null 2>&1
git -C "$BR2" add -A >/dev/null 2>&1; git -C "$BR2" commit -qm bootstrap
mkdir -p "$BR2/.specify/roadmaps"
printf '{"goal":"g","base":"main","budget_usd":4,"entries":[{"slug":"one","title":"t","description":"d"},{"slug":"two","title":"t2","description":"d2"}]}\n' \
  > "$BR2/.specify/roadmaps/rm.json"
BRST2="$BR2/.specify/roadmaps/rm.state.json"
roadmap_state_init "$BRST2" ".specify/roadmaps/rm.json" rm main
roadmap_entry_set "$BRST2" one '{"status":"done","cost_usd":9}'
out=$(SPEC_RUN_CLAUDE_BIN=claude-pipeline "$SPEC_ROADMAP" run --repo "$BR2" --slug rm --base main 2>&1); rc=$?
assert_eq "$rc" "1" "budget_usd in the roadmap file stops the run with no --budget flag"
assert_contains "$out" 'budget of $4' "using the file's value"

out=$(SPEC_RUN_CLAUDE_BIN=claude-pipeline "$SPEC_ROADMAP" run --repo "$BR2" --slug rm --base main \
        --budget 100 --dry-run 2>&1); rc=$?
assert_eq "$rc" "0" "--budget overrides the file for a single run"
# The bound is documented rather than fixed: this is checked BEFORE each entry, so
# it caps how many entries start, not what one entry spends. The per-phase
# ceilings are the only mid-flight stop, and their sum over all phases in
# phases.json is what one entry can spend.

# ------------------------------------------------------ reading outside the repo
printf '\n--add-dir\n'
# A git worktree has no copy of a gitignored sibling checkout, so grounding a spec
# in code that lives elsewhere needs read access outside the repository. The write
# scope is unchanged and still checked afterwards: this widens what a phase may
# LOOK at, not what it may leave behind.
EXTRA="$WORK/elsewhere"; mkdir -p "$EXTRA"
argv=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only specify \
        --add-dir "$EXTRA" --dry-run 2>&1)
assert_contains "$(unquote "$argv")" "--add-dir $EXTRA" "--add-dir reaches the phase invocation"
argv=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only specify \
        --add-dir "$EXTRA" --add-dir "$WORK" --dry-run 2>&1)
n_add=$(printf '%s\n' "$(unquote "$argv")" | LC_ALL=C grep -o -- '--add-dir' | grep -c . || true)
assert_eq "$n_add" "2" "and it is repeatable"

out=$("$SPEC_RUN" --repo "$BS" --feature-dir "$BS/specs/001-t" --only specify \
        --add-dir "$WORK/nope" --dry-run 2>&1); rc=$?
assert_eq "$rc" "3" "a directory that does not exist is a usage error"
assert_contains "$out" "not a directory" "named, before any spend"
# Silently useless otherwise: the phase starts, cannot see what it was told to
# read, and produces a spec grounded in nothing.

printf '\nroadmap: --from-doc\n'
# A roadmap document a human already wrote is better input than a decomposition:
# it encodes decisions and constraints no from-scratch split would reproduce. The
# JSON is a projection of that document, not a replacement for it.
DOCR="$WORK/docroadmap"; mkbare "$DOCR" main
"$SPEC_BOOTSTRAP" "$DOCR" >/dev/null 2>&1
mkdir -p "$DOCR/docs/proposals"
printf '# A plan\n\n## Spec sequence\n\n1. **first thing.**\n2. **second thing.**\n' \
  > "$DOCR/docs/proposals/my-thing-roadmap.md"

out=$("$SPEC_ROADMAP" plan --repo "$DOCR" --from-doc "$DOCR/docs/proposals/my-thing-roadmap.md" \
        --dry-run 2>&1); rc=$?
assert_eq "$rc" "0" "--from-doc dry-runs cleanly"
assert_contains "$out" "transcribing" "and says it is transcribing, not decomposing"
assert_contains "$out" "my-thing-roadmap" "naming the roadmap after the document"
# Named after the doc exactly, so the two stay findable from each other. An
# earlier version tried to strip a "-roadmap" suffix and could not: tr turns
# basename's trailing newline into a dash, so the anchored substitution never
# matched.

out=$("$SPEC_ROADMAP" plan --repo "$DOCR" --from-doc "$DOCR/nope.md" --dry-run 2>&1); rc=$?
assert_eq "$rc" "3" "a document that does not exist is a usage error"
assert_contains "$out" "no such roadmap document" "saying which"

printf 'outside\n' > "$WORK/outside-roadmap.md"
out=$("$SPEC_ROADMAP" plan --repo "$DOCR" --from-doc "$WORK/outside-roadmap.md" --dry-run 2>&1); rc=$?
assert_eq "$rc" "3" "a document outside the repository is refused"
assert_contains "$out" "outside the repository" "because the specify phase reads it FROM the repo"
# Each entry's description tells the phase to read that document. A path the phase
# cannot reach makes every entry reference something invisible.

out=$("$SPEC_ROADMAP" plan --repo "$DOCR" --dry-run 2>&1); rc=$?
assert_eq "$rc" "1" "plan with neither a goal nor a document still fails"
assert_contains "$out" "no goal given" "mentioning both ways in"

# ==================================================================== roadmap =
printf '\nroadmap: has this entry landed?\n'

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

# --- the state file is not the only thing that knows where the work is
# 🛑 `feature_dir` is load-bearing for the squash check above, and it lives ONLY in
# the roadmap state file. Measured: hand-picking a landing set dropped the
# pipeline's own state commit, the field went missing, a COMPLETED entry read as
# pending, and the next run started specify again. Caught 30 seconds in, but on
# course to re-spend a full pipeline — losing this field means paying for finished
# work twice, which is the most expensive way for state loss to surface.
#
# The answer is already committed: spec-kit names directories `NNN-<slug>` and the
# entry knows its slug. So an empty feature_dir must NOT be able to un-land an
# entry whose artifacts are sitting on the base ref.
IFS=$'\t' read -r landed how < <(entry_landed "$RB" main "" 002-second 0 second)
assert_eq "$landed" "done" \
  "an entry with NO feature_dir recorded is still found, by slug, on the base ref"
assert_contains "$how" "found by slug" \
  "and says so, rather than implying the state file answered"

# The slug must actually have to match — otherwise the fallback would call every
# entry landed the moment any spec directory existed. With a branch recorded but no
# matching directory, the answer is a definite not_landed.
IFS=$'\t' read -r landed how < <(entry_landed "$RB" main "" 001-first 0 no-such-entry)
assert_eq "$landed" "not_landed" \
  "a slug matching no directory on the base is still not_landed"

# ⚠️ In a SEPARATE repository on purpose. The first version of this case added a
# branch and two commits to $RB, the fixture the rest of this file shares — and
# broke six later assertions that depend on its shape. A test that mutates a shared
# fixture to prove a point about isolation is its own counter-example.
HB="$WORK/hyphen-slug"; mkbare "$HB" main
git -C "$HB" checkout -q -b 004-multi-part-slug main
mkdir -p "$HB/specs/004-multi-part-slug"
printf -- '- [X] T001 done\n' > "$HB/specs/004-multi-part-slug/tasks.md"
git -C "$HB" add -A >/dev/null 2>&1; git -C "$HB" commit -qm "entry four"
git -C "$HB" checkout -q main
git -C "$HB" merge --squash -q 004-multi-part-slug >/dev/null 2>&1
git -C "$HB" commit -qm "entry four (squashed) (#14)"
# Splitting on the LAST dash, or on every dash, would compare the wrong thing and
# silently stop matching any hyphenated name — which is most of them (`board-ui`,
# `cutover-backfill-v1-retirement`).
IFS=$'\t' read -r landed how < <(entry_landed "$HB" main "" "" 0 multi-part-slug)
assert_eq "$landed" "done" "a hyphenated slug still matches after the numeric prefix"

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
# ⚠️ A roadmap of its OWN, with slugs that match no spec directory on main. The
# `good` roadmap's entries are `first`/`second`, and this repo's main carries
# `specs/001-first` and `specs/002-second` from the squash-merge fixture above —
# so once entry_landed learned to find a directory by slug, every `good` entry
# correctly reported LANDED and `run` exited 0 before it ever reached the
# dirty-tree check these assertions exist to exercise. The guard was right; the
# precondition was stale.
cat > "$RB/.specify/roadmaps/tree.json" <<'TREEEOF'
{"goal":"tree safety","base":"main","entries":[
 {"slug":"never-merged-anywhere","title":"t","description":"d"}]}
TREEEOF
printf '{}\n' > "$RB/.specify/roadmaps/good.state.json"
printf '{}\n' > "$RB/specs/001-first/.pipeline/state.json"
assert_eq "$(tracked_changes "$RB")" "" "the tool's own state files are not 'uncommitted changes'"
assert_eq "$(untracked_files "$RB")" "" "nor are they reported as stray untracked files"
# This was a real wedge: `spec-roadmap plan` writes the roadmap file INTO the
# repository, so the first `run` after it saw a dirty tree and refused. The tool
# dirtied the tree and then blocked on it — every roadmap stopped at entry one.
# Mutation: drop _is_tool_bookkeeping and both assertions fail.

out=$("$SPEC_ROADMAP" run --repo "$RB" --slug tree --base main --dry-run 2>&1); rc=$?
assert_eq "$rc" "0" "and a run proceeds with only tool state present"

# --- a TRACKED modification refuses, because that is what a checkout can block
printf 'edited by a human\n' >> "$RB/README.md"
assert_contains "$(tracked_changes "$RB")" "README.md" "a tracked modification IS reported"
out=$("$SPEC_ROADMAP" run --repo "$RB" --slug tree --base main 2>&1); rc=$?
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
out=$("$SPEC_ROADMAP" run --repo "$RB" --slug tree --base main --dry-run 2>&1); rc=$?
assert_eq "$rc" "0" "an untracked file does NOT block the run"
assert_contains "$out" "will follow this checkout" "it warns instead, and says why it matters"
[ -f "$RB/scratch.txt" ] && t_pass "and the untracked file is left where it was" \
  || t_fail "the untracked file is left alone"
rm -f "$RB/scratch.txt"
# Refusing here would be the wedge again in another costume: the specify phase
# creates untracked spec files, so an untracked-blocks rule stops the roadmap
# immediately after its own first phase.

out=$("$SPEC_ROADMAP" run --repo "$RB" --slug tree --base main --dry-run 2>&1)
assert_contains "$out" "would run: spec-run" "--dry-run shows the spec-run it would invoke"
assert_not_contains "$out" "waiting on you" "and does not pretend to have run anything"

# A description is handed VERBATIM to the specify phase, and `plan --from-doc`
# tells the planner to write several paragraphs into it: the entry's substance,
# the document sections that constrain it, and what it must NOT take on because a
# later entry owns it. The reader was `IFS=$'\037' read -r slug title description`
# — and `read` reads a LINE, so everything after the first newline was dropped.
# Measured on a real 7-entry roadmap: descriptions of 3,000–5,000 characters over
# 13–22 lines each arrived as their first line only, losing every scope boundary.
# Nothing warned, and --dry-run printed the truncated string looking plausible.
# The third assertion is the one that matters: a boundary in the LAST paragraph.
printf '%s\n' '{"goal":"g","base":"main","entries":[{"slug":"ml","title":"t","description":"FIRST LINE.\n\nSECOND PARAGRAPH.\n\nDO NOT take on the other thing."}]}' \
  > "$RB/.specify/roadmaps/multiline.json"
out=$("$SPEC_ROADMAP" run --repo "$RB" --slug multiline --base main --dry-run 2>&1)
assert_contains "$out" "FIRST LINE" "a multi-line description keeps its first line"
assert_contains "$out" "SECOND PARAGRAPH" "and the paragraph after the first newline"
assert_contains "$out" "DO NOT take on" "and the scope boundary in its last paragraph"

# `source_doc` used to be written by `plan --from-doc` and read by nothing — dead
# metadata in the shape of a link. It matters because the descriptions are the
# ONLY thing that points a phase at that document; nothing here passes it. So a
# path that stops resolving strips the grounding from every entry at once, while
# each phase still reports success.
printf '\nroadmap: source_doc\n'
mkdir -p "$RB/docs"
printf 'the design\n' > "$RB/docs/design.md"
printf '%s\n' '{"goal":"g","base":"main","source_doc":"docs/design.md","entries":[{"slug":"sd","title":"t","description":"d"}]}' \
  > "$RB/.specify/roadmaps/withdoc.json"
out=$("$SPEC_ROADMAP" show --repo "$RB" --slug withdoc --base main 2>&1)
assert_contains "$out" "docs/design.md" "show names the source document"
assert_not_contains "$out" "that document is missing" "and does not cry wolf when it resolves"
out=$("$SPEC_ROADMAP" run --repo "$RB" --slug withdoc --base main --dry-run 2>&1)
assert_not_contains "$out" "does not resolve" "a run over a resolving source_doc is quiet"

# The mutation that matters: the path stops resolving.
rm -f "$RB/docs/design.md"
out=$("$SPEC_ROADMAP" show --repo "$RB" --slug withdoc --base main 2>&1)
assert_contains "$out" "that document is missing" "show flags a source_doc that is gone"
out=$("$SPEC_ROADMAP" run --repo "$RB" --slug withdoc --base main --dry-run 2>&1); rc=$?
assert_contains "$out" "does not resolve" "and a run warns before any phase is billed"
assert_eq "$rc" "0" "but does not refuse — a description must stand on its own"

# A roadmap with no source_doc at all must stay silent, not report a missing one.
out=$("$SPEC_ROADMAP" run --repo "$RB" --slug good --base main --dry-run 2>&1)
assert_not_contains "$out" "does not resolve" "no source_doc means no complaint"

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
  /speckit-review*)  { printf '# Review\n'; pad; printf 'No findings. Checked src/app.py:7.\n'; } > "$dir/review.md";;
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

# --------------------------------- roadmap: an entry with no branch of its own --
printf '\nroadmap: an entry that never got a branch\n'
# The merge gate exists because each entry becomes its own branch and its own pull
# request. If spec-kit cannot create the branch — which happened for real, its
# script denied four times in a worktree — the phase still reports success, and
# continuing would march the roadmap on with its central promise quietly broken.
cat > "$FAKE/claude-nobranch" <<'FAKEEOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] && exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null)
prompt=""; for a in "$@"; do case "$a" in /speckit-*) prompt="$a";; esac; done
rel="specs/001-nobranch"; mkdir -p "$root/$rel"
# writes the artifacts but deliberately creates NO branch
printf '{\n  "feature_directory": "%s"\n}\n' "$rel" > "$root/.specify/feature.json"
pad() { for i in $(seq 1 40); do printf 'padding %s\n' "$i"; done; }
case "$prompt" in
  /speckit-specify*)   { printf '# Spec\n'; pad; } > "$root/$rel/spec.md";;
  /speckit-plan*)      { printf '# Plan\n'; pad; } > "$root/$rel/plan.md";;
  /speckit-tasks*)     { printf '# Tasks\n'; pad; printf -- '- [ ] T1 x\n'; } > "$root/$rel/tasks.md";;
  /speckit-implement*) { printf '# Tasks\n'; pad; printf -- '- [x] T1 x\n'; } > "$root/$rel/tasks.md";;
  /speckit-review*)    { printf '# Review\n'; pad; printf 'No findings. Checked src/x.py:3.\n'; } > "$root/$rel/review.md";;
esac
echo '{"total_cost_usd":0.02,"num_turns":2,"duration_ms":30,"result":"STATUS: ok"}'
FAKEEOF
chmod +x "$FAKE/claude-nobranch"
NB="$WORK/nobranch"; mkbare "$NB" main
"$SPEC_BOOTSTRAP" "$NB" >/dev/null 2>&1
git -C "$NB" add -A >/dev/null 2>&1; git -C "$NB" commit -qm bootstrap
mkdir -p "$NB/.specify/roadmaps"
printf '{"goal":"g","base":"main","entries":[{"slug":"one","title":"first","description":"do one"},{"slug":"two","title":"second","description":"do two"}]}\n' \
  > "$NB/.specify/roadmaps/rm.json"
git -C "$NB" add -A >/dev/null 2>&1; git -C "$NB" commit -qm roadmap

out=$(SPEC_RUN_CLAUDE_BIN=claude-nobranch "$SPEC_ROADMAP" run --repo "$NB" --slug rm --base main 2>&1); rc=$?
assert_eq "$rc" "1" "the roadmap FAILS when an entry has no branch of its own"
assert_contains "$out" "no branch of its own" "saying exactly that"
assert_contains "$out" "permission_denials" "and pointing at the likely cause"
assert_not_contains "$out" "second" "and it does not continue to the next entry"
assert_eq "$(jq -r '.entries.one.status' "$NB/.specify/roadmaps/rm.state.json")" "blocked" \
  "recording the entry as blocked, not awaiting_merge"
# Mutation: drop the entry_has_own_branch check and this reports awaiting_merge,
# which is the tidy lie — a gate with nothing to gate.

# ------------------------------------------- roadmap: inside a git worktree ----
printf '\nroadmap: a base checked out in another worktree\n'
# A branch can only be checked out in ONE worktree, and running several at once is
# normal practice in some workspaces. So `git checkout main` inside a worktree
# fails with "already used by worktree at …". Cutting from the remote ref instead
# would be WORSE than failing: it silently drops whatever the worktree has
# committed that the base does not have — which, the first time this was hit, was
# the scaffold upgrade the run depended on.
WTBASE="$WORK/wtbase"; mkbare "$WTBASE" main
"$SPEC_BOOTSTRAP" "$WTBASE" >/dev/null 2>&1
git -C "$WTBASE" add -A >/dev/null 2>&1; git -C "$WTBASE" commit -qm bootstrap
mkdir -p "$WTBASE/.specify/roadmaps"
printf '{"goal":"g","base":"main","entries":[{"slug":"one","title":"first","description":"do one"}]}\n' \
  > "$WTBASE/.specify/roadmaps/rm.json"
git -C "$WTBASE" add -A >/dev/null 2>&1; git -C "$WTBASE" commit -qm roadmap

WTREE="$WORK/wtree"
git -C "$WTBASE" worktree add -q -b feature-branch "$WTREE" main 2>/dev/null
printf 'work only on the branch\n' > "$WTREE/branch-only.txt"
git -C "$WTREE" add -A >/dev/null 2>&1; git -C "$WTREE" commit -qm "a commit the base does not have"

# COUNT, do not `grep -q`. Under `set -o pipefail`, grep -q exits on the first
# match and SIGPIPEs its writer, so the pipeline reports failure DESPITE the
# match — which made this assertion fail against a fixture that reproduces the
# case perfectly.
held_msg=$(git -C "$WTREE" checkout main 2>&1 | grep -c "already used by worktree" || true)
[ "${held_msg:-0}" -gt 0 ] \
  && t_pass "the fixture reproduces it: the worktree cannot check out main" \
  || t_fail "the fixture reproduces the held-branch case" "main was checkoutable"

out=$(SPEC_RUN_CLAUDE_BIN=claude-pipeline "$SPEC_ROADMAP" run --repo "$WTREE" --slug rm \
        --base main 2>&1); rc=$?
assert_contains "$out" "checked out elsewhere" "the run says why it cannot use the base branch"
assert_contains "$out" "already contains" "and that the current branch supersedes it"
assert_eq "$(git -C "$WTREE" log --format=%s -1 main..feature-branch 2>/dev/null | grep -c . || echo 1)" "1" \
  "the worktree's own commit is still reachable"
[ -f "$WTREE/branch-only.txt" ] && t_pass "and its work is still present" \
  || t_fail "the worktree's work survives" "cutting from the remote ref dropped it"
assert_eq "$rc" "2" "and the entry runs, stopping at its merge gate"
# Mutation: replace the ancestor branch with a plain `checkout` and the run dies
# with "could not check out main", naming neither the holder nor the remedy.

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

# 🛑 A blocked entry must be reported as ITSELF, and must be retryable. Both
# halves were wrong: `blocked` shared the merge gate, so a FAILED pipeline was
# announced as "this entry's pipeline is finished — review and merge it" (the
# opposite remedy), and because that gate always exited 2 a blocked entry could
# never be retried without hand-editing the state file. The status and its
# recorded note were both on hand and both discarded.
out=$(SPEC_RUN_CLAUDE_BIN=claude-broken "$SPEC_ROADMAP" run --repo "$FR" --slug rm \
        --base main 2>&1) || true
assert_not_contains "$out" "pipeline is finished" \
  "a blocked entry is never described as finished-and-ready-to-merge"
assert_not_contains "$out" "Review and merge it" \
  "nor handed the merge remedy for a failure"
assert_contains "$out" "retrying an entry that failed" \
  "it says it is retrying"
assert_contains "$out" "spec-run exited" \
  "and repeats the reason it was blocked, rather than dropping it"

# 🛑 And a retried entry must RESUME its feature, not cut a second one. Testing
# only `in_progress` for that made the retry path useless in practice: a blocked
# entry with a recorded feature_dir went down the create path and refused with
# "cannot cut this entry from main", because the base is not an ancestor of the
# branch the feature already sits on. Measured on the real roadmap.
mkdir -p "$FR/specs/001-one"
roadmap_entry_set "$FR/.specify/roadmaps/rm.state.json" one \
  '{"status":"blocked","feature_dir":"specs/001-one","branch":"001-one","note":"spec-run exited 1"}'
out=$(SPEC_RUN_CLAUDE_BIN=claude-broken "$SPEC_ROADMAP" run --repo "$FR" --slug rm \
        --base main 2>&1) || true
assert_contains "$out" "resuming its existing feature: specs/001-one" \
  "a retried entry resumes the feature it already has"
assert_not_contains "$out" "cannot cut this entry" \
  "and never tries to cut a second branch for it"

# the fallback names the status it actually holds
roadmap_entry_set "$FR/.specify/roadmaps/rm.state.json" one \
  '{"status":"blocked","feature_dir":"specs/404-gone","branch":"001-one"}'
out=$(SPEC_RUN_CLAUDE_BIN=claude-broken "$SPEC_ROADMAP" run --repo "$FR" --slug rm \
        --base main 2>&1) || true
assert_contains "$out" "recorded as blocked" \
  "a blocked entry with no feature directory is not described as in progress"

# 🛑 A failed entry must never adopt a FOREIGN, already-merged feature directory
# via .specify/feature.json. That file is repo-wide, not scoped to this entry or
# even this roadmap — it is whatever the last spec-run invocation ANYWHERE last
# wrote. claude-broken fails before writing anything at all, which is exactly
# what a missing-skill precondition check does in the real pipeline: it exits 1
# before feature-dir discovery ever runs. Measured on a real roadmap: a stale
# pointer left over from a different, already-landed roadmap's entry got
# attributed to a brand-new entry that had never run a single phase, and the
# next `run` found that unrelated entry's real tasks.md on main and reported the
# new entry "done" — cost $0 of actual work credited as a fully landed feature.
FS="$WORK/foreignstale"; mkbare "$FS" main
"$SPEC_BOOTSTRAP" "$FS" >/dev/null 2>&1
git -C "$FS" add -A >/dev/null 2>&1; git -C "$FS" commit -qm bootstrap
# An unrelated feature, already landed on main — nothing to do with the roadmap
# entry about to run.
mkdir -p "$FS/specs/900-unrelated-done"
{ printf '# Tasks\n'; for i in $(seq 1 40); do printf 'padding %s\n' "$i"; done; printf -- '- [x] T1 x\n'; } \
  > "$FS/specs/900-unrelated-done/tasks.md"
git -C "$FS" add -A >/dev/null 2>&1; git -C "$FS" commit -qm "unrelated feature, already landed"
mkdir -p "$FS/.specify/roadmaps"
printf '{"goal":"g","base":"main","entries":[{"slug":"one","title":"first","description":"do one"}]}\n' \
  > "$FS/.specify/roadmaps/rm.json"
git -C "$FS" add -A >/dev/null 2>&1; git -C "$FS" commit -qm roadmap
# The stale pointer: as if the last spec-run anywhere touched this unrelated dir.
printf '{\n  "feature_directory": "specs/900-unrelated-done"\n}\n' > "$FS/.specify/feature.json"

out=$(SPEC_RUN_CLAUDE_BIN=claude-broken "$SPEC_ROADMAP" run --repo "$FS" --slug rm --base main 2>&1); rc=$?
assert_eq "$rc" "1" "the entry still fails (claude-broken writes nothing)"
assert_eq "$(jq -r '.entries.one.status' "$FS/.specify/roadmaps/rm.state.json")" "blocked" \
  "and is recorded blocked, not done"
assert_eq "$(jq -r '.entries.one.feature_dir' "$FS/.specify/roadmaps/rm.state.json")" "" \
  "the foreign, already-merged directory is NOT attributed to this entry"
assert_not_contains "$out" "landed on main" \
  "and the run never claims this brand-new entry has landed"
# Mutation: drop the already-merged guard on the failure-recording path and
# entries.one.feature_dir becomes "specs/900-unrelated-done", status flips to
# "done" on the very next `run`, and the roadmap silently skips entry one having
# never run a single phase for it.

out2=$(SPEC_ROADMAP_QUIET=1 "$SPEC_ROADMAP" show --repo "$FS" --slug rm 2>&1)
assert_contains "$out2" "0 of 1 landed" \
  "show agrees: nothing has landed, despite the foreign tasks.md sitting on main"

# The same foreign-pointer risk applies to the RESUME probe (a blocked/in_progress
# entry with no feature_dir of its own falls back to .specify/feature.json too).
roadmap_entry_set "$FS/.specify/roadmaps/rm.state.json" one '{"status":"blocked"}'
printf '{\n  "feature_directory": "specs/900-unrelated-done"\n}\n' > "$FS/.specify/feature.json"
out3=$(SPEC_RUN_CLAUDE_BIN=claude-broken "$SPEC_ROADMAP" run --repo "$FS" --slug rm --base main 2>&1) || true
assert_not_contains "$out3" "resuming its existing feature: specs/900-unrelated-done" \
  "the resume fallback also refuses an already-merged foreign directory"
assert_eq "$(jq -r '.entries.one.feature_dir' "$FS/.specify/roadmaps/rm.state.json")" "" \
  "and still does not attribute it to this entry"

# 🛑 The claim the guard exists to prevent, asserted rather than described. The
# comment above stated that without it the status "flips to done on the very next
# run"; that was true — verified by removing the guard and running twice: the
# second run printed "✓ one — landed on main" AND "✓ roadmap 'rm' complete — all
# 1 entries landed on main", with the entry recorded done. So the roadmap
# declared ITSELF finished having never run a phase. A stated measurement with no
# assertion behind it is exactly what this suite exists to stop drifting.
out4=$(SPEC_RUN_CLAUDE_BIN=claude-broken "$SPEC_ROADMAP" run --repo "$FS" --slug rm --base main 2>&1) || true
assert_not_contains "$out4" "landed on main" \
  "a SECOND run still does not report the never-run entry as landed"
assert_not_contains "$out4" "entries landed on main" \
  "nor declare the whole roadmap complete over work that was never built"
assert_eq "$(jq -r '.entries.one.status' "$FS/.specify/roadmaps/rm.state.json")" "blocked" \
  "and the status stays blocked instead of flipping to done"

# --- an UNMERGED foreign pointer: the merged test alone does not catch it
# "Already merged" is a SYMPTOM of the invariant, not the invariant. The real
# rule is "this directory is this entry's", and a manual `spec-run` on a side
# branch satisfies the first test while failing the second. Measured with the
# merged test alone: the pointer was recorded as the entry's feature_dir and the
# next run printed "resuming its existing feature: specs/915-manual-sidefix",
# handing spec-run --feature-dir another feature's plan and tasks.md.
#
# 🛑 Tested on the DESCRIPTION and on pointer freshness, never on the slug. The
# slug looks like the directory's name and is not: spec-run is given the entry's
# description, and spec-kit derives the directory from that through a sanitiser.
# Measured on one real 9-entry roadmap, three entries disagree —
# contacts-job-attribution → specs/013-contact-network, gear-and-stash →
# specs/017-loot-gear-v1, perk-milestones → specs/018-skill-perks — so a
# slug-mismatch rejection would have discarded a third of its legitimate
# directories. This fixture keeps the two apart on purpose: the foreign
# directory's name below would ALSO fail a slug test, so only asserting the
# messages distinguishes the rule that shipped from the one that did not.
FU="$WORK/foreignunmerged"; mkbare "$FU" main
"$SPEC_BOOTSTRAP" "$FU" >/dev/null 2>&1
git -C "$FU" add -A >/dev/null 2>&1; git -C "$FU" commit -qm bootstrap
mkdir -p "$FU/.specify/roadmaps"
printf '{"goal":"g","base":"main","entries":[{"slug":"one","title":"first","description":"do one"}]}\n' \
  > "$FU/.specify/roadmaps/rm.json"
git -C "$FU" add -A >/dev/null 2>&1; git -C "$FU" commit -qm roadmap
# A foreign feature committed on a SIDE BRANCH only — never merged to main.
git -C "$FU" checkout -q -b side-manual-fix
mkdir -p "$FU/specs/915-manual-sidefix"
{ printf '# Tasks\n'; for i in $(seq 1 40); do printf 'padding %s\n' "$i"; done; printf -- '- [ ] T1 unrelated\n'; } \
  > "$FU/specs/915-manual-sidefix/tasks.md"
git -C "$FU" add -A >/dev/null 2>&1; git -C "$FU" commit -qm "manual side feature, NOT merged"
git -C "$FU" checkout -q main
# the directory stays on disk, as it would after a manual run, pointer and all
mkdir -p "$FU/specs/915-manual-sidefix"
git -C "$FU" show side-manual-fix:specs/915-manual-sidefix/tasks.md \
  > "$FU/specs/915-manual-sidefix/tasks.md"
# A real manual run leaves pipeline state behind, and that state is what says
# whose directory this is.
mkdir -p "$FU/specs/915-manual-sidefix/.pipeline"
printf '{"version":1,"feature_dir":"specs/915-manual-sidefix","description":"a manual side fix","phases":{}}\n' \
  > "$FU/specs/915-manual-sidefix/.pipeline/state.json"
printf '{\n  "feature_directory": "specs/915-manual-sidefix"\n}\n' > "$FU/.specify/feature.json"
# The precondition that makes this a different case from the block above.
git -C "$FU" cat-file -e "main:specs/915-manual-sidefix/tasks.md" 2>/dev/null \
  && t_fail "the foreign directory is NOT on main" "it is merged, so this fixture tests the wrong thing" \
  || t_pass "the foreign directory is not on main, so the merged test cannot catch it"

out5=$(SPEC_RUN_CLAUDE_BIN=claude-broken "$SPEC_ROADMAP" run --repo "$FU" --slug rm --base main 2>&1) || true
assert_eq "$(jq -r '.entries.one.feature_dir' "$FU/.specify/roadmaps/rm.state.json")" "" \
  "an UNMERGED foreign directory is refused too, on pointer freshness"
assert_contains "$out5" "this run never updated it" \
  "because the pointer is unchanged from before the run, not because of its name"
assert_not_contains "$out5" "slug is not" \
  "and never on a slug comparison, which real directory names do not satisfy"

out6=$(SPEC_RUN_CLAUDE_BIN=claude-broken "$SPEC_ROADMAP" run --repo "$FU" --slug rm --base main 2>&1) || true
assert_not_contains "$out6" "resuming its existing feature: specs/915-manual-sidefix" \
  "so no later run resumes spec-run into another feature's directory"
assert_contains "$out6" "created for different work" \
  "the resume probe refuses it on what the directory's own state records"
# 🛑 Mutation, both halves, and the second is why the first is not enough: drop
# the pointer-freshness clause and feature_dir becomes specs/915-manual-sidefix;
# drop the probe's description clause and out6 carries that resume line even with
# feature_dir empty, because the probe re-reads the same repo-wide pointer. The
# damage is not a label — resume_dir is passed as --feature-dir, so implement
# writes code against another feature's plan.

# ...and the same probe still ADOPTS a directory whose state says it is this
# entry's. Without this, the guard above could be "refuse everything", which
# would cut a duplicate feature and build the entry twice — a silent doubling
# that looks like success.
printf '{"version":1,"feature_dir":"specs/915-manual-sidefix","description":"do one","phases":{}}\n' \
  > "$FU/specs/915-manual-sidefix/.pipeline/state.json"
printf '{\n  "feature_directory": "specs/915-manual-sidefix"\n}\n' > "$FU/.specify/feature.json"
out7=$(SPEC_RUN_CLAUDE_BIN=claude-broken "$SPEC_ROADMAP" run --repo "$FU" --slug rm --base main 2>&1) || true
assert_contains "$out7" "resuming its existing feature: specs/915-manual-sidefix" \
  "a directory whose recorded description IS this entry's is still resumed"

# An ABSENT state.json is unknown, not a mismatch, and must still adopt: it may
# be this entry's own half-created work, and refusing it costs a duplicate build.
rm -rf "$FU/specs/915-manual-sidefix/.pipeline"
printf '{\n  "feature_directory": "specs/915-manual-sidefix"\n}\n' > "$FU/.specify/feature.json"
out8=$(SPEC_RUN_CLAUDE_BIN=claude-broken "$SPEC_ROADMAP" run --repo "$FU" --slug rm --base main 2>&1) || true
assert_contains "$out8" "resuming its existing feature: specs/915-manual-sidefix" \
  "and a directory with no pipeline state at all is adopted rather than refused"

# --- the reader itself
DESCDIR="$WORK/descread"; mkdir -p "$DESCDIR/specs/001-x/.pipeline"
printf '{"version":1,"description":"build the thing","phases":{}}\n' \
  > "$DESCDIR/specs/001-x/.pipeline/state.json"
assert_eq "$(feature_dir_description "$DESCDIR" "specs/001-x")" "build the thing" \
  "feature_dir_description reads what the directory says it was created for"
assert_eq "$(feature_dir_description "$DESCDIR" "specs/404-absent")" "" \
  "and reports nothing — unknown, not a mismatch — when there is no state to read"
printf '{"version":1,"phases":{}}\n' > "$DESCDIR/specs/001-x/.pipeline/state.json"
assert_eq "$(feature_dir_description "$DESCDIR" "specs/001-x")" "" \
  "nor invents one from state that records no description"

# the merge gate still gates the case it was written for
MG="$WORK/mergegate"; mkbare "$MG" main
"$SPEC_BOOTSTRAP" "$MG" >/dev/null 2>&1
git -C "$MG" add -A >/dev/null 2>&1; git -C "$MG" commit -qm bootstrap
mkdir -p "$MG/.specify/roadmaps"
printf '{"goal":"g","base":"main","entries":[{"slug":"one","title":"t","description":"d"}]}\n' \
  > "$MG/.specify/roadmaps/rm.json"
MGST="$MG/.specify/roadmaps/rm.state.json"
roadmap_state_init "$MGST" ".specify/roadmaps/rm.json" rm main
roadmap_entry_set "$MGST" one \
  '{"status":"awaiting_merge","branch":"001-one","feature_dir":"specs/001-one"}'
out=$(SPEC_RUN_CLAUDE_BIN=claude-pipeline "$SPEC_ROADMAP" run --repo "$MG" --slug rm \
        --base main 2>&1); rc=$?
assert_eq "$rc" "2" "an entry awaiting merge still stops the roadmap"
assert_contains "$out" "Review and merge it" "with the merge remedy"
assert_not_contains "$out" "retrying" "and is not mistaken for a failure"
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
# --------------------------------------------- a killed phase is not "running" --
printf '\nan interrupted phase\n'
# `running` with no way to falsify it means a phase killed by a Ctrl-C, a reboot
# or an OOM stays in flight forever: "still working", "killed" and "crashed"
# collapse into one state carrying no cost and no outcome. Measured on a real
# run — two implement phases sat at `running` with cost `unmeasured` because
# both were killed before their result event.
IRD="$WORK/interrupted"; mkdir -p "$IRD"
IRS="$IRD/state.json"
printf '{"version":1,"phases":{}}\n' > "$IRS"

# 🛑 Liveness is only ANSWERABLE where the process table can be read, and this
# suite runs in both kinds of place — so the assertions split accordingly rather
# than pretending one answer is universal. Inside Claude Code's Bash sandbox both
# `ps` and `kill -0` on a foreign pid are refused, and the honest verdict there
# is CANNOT TELL, not "gone". The gated block below is what that costs.
_ps_ok=0
[ -n "$(ps -o command= -p $$ 2>/dev/null)" ] && _ps_ok=1

if [ "$_ps_ok" -eq 1 ]; then
  # a runner that is definitely gone: claim a pid that cannot be ours
  printf '%s\n' '{"version":1,"phases":{
    "specify":{"status":"ok","cost_usd":1.5},
    "implement":{"status":"running","runner_pid":999999}}}' > "$IRS"
  state_reconcile_running "$IRS"
  assert_eq "$(jqd "$IRS" '.phases.implement.status' '')" "interrupted" \
    "a running phase whose runner is gone becomes interrupted"
  assert_contains "$(jqd "$IRS" '.phases.implement.note' '')" "unmeasured" \
    "saying the cost and turns were never recorded"

  # a LIVE pid that is not ours must still not be trusted: a bare pid check is
  # defeated by pid reuse, so identity is checked as well as existence.
  printf '%s\n' '{"version":1,"phases":{"plan":{"status":"running","runner_pid":1}}}' > "$IRS"
  state_reconcile_running "$IRS"
  assert_eq "$(jqd "$IRS" '.phases.plan.status' '')" "interrupted" \
    "pid 1 is alive but is not a spec-run, so the phase is still interrupted"
else
  t_skip "a gone runner becomes interrupted" "the process table is unreadable here"
  PLATFORM_GATED_ASSERTIONS=$((${PLATFORM_GATED_ASSERTIONS:-0} + 3))
fi

# Independent of ps either way: a finished phase is never touched by reconcile.
printf '%s\n' '{"version":1,"phases":{
  "specify":{"status":"ok","cost_usd":1.5},
  "implement":{"status":"running","runner_pid":999999}}}' > "$IRS"
state_reconcile_running "$IRS" >/dev/null 2>&1
assert_eq "$(jqd "$IRS" '.phases.specify.status' '')" "ok" \
  "and a finished phase is left alone"

# a phase recorded before runner_pid existed has nothing to check against
printf '%s\n' '{"version":1,"phases":{"tasks":{"status":"running"}}}' > "$IRS"
state_reconcile_running "$IRS"
assert_eq "$(jqd "$IRS" '.phases.tasks.status' '')" "interrupted" \
  "a running phase with no runner_pid at all is interrupted, not trusted"

# 🛑 …and an UNREADABLE process table is none of the above. It is the case that
# made this a real defect rather than a tidiness argument: `ps` is present on
# PATH inside Claude Code's Bash sandbox and `ps -eo`/`ps -p` is REFUSED, so the
# old `ps … | grep -q spec-run` matched nothing and a live runner read as gone.
# Measured against a live roadmap on this machine: pid 12199 was a running
# spec-run, and the same call returned FALSE inside the sandbox and TRUE outside
# it — so a spec-status from a sandboxed session wrote `interrupted` over a phase
# that was still working, into the file the resume path trusts.
PSF="$WORK/psfake"; mkdir -p "$PSF"
printf '#!/usr/bin/env bash\nexit 1\n' > "$PSF/ps"; chmod +x "$PSF/ps"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$PSF/spec-run-probe"; chmod +x "$PSF/spec-run-probe"

# These two hold everywhere: both return before any probe is needed.
_al=0; _runner_alive "" || _al=$?
assert_eq "$_al" "1" "an absent pid is GONE, not unknown — there is nothing to check"
_al=0; _runner_alive "not-a-pid" || _al=$?
assert_eq "$_al" "1" "and so is a malformed one"

# CANNOT TELL is reachable in EVERY environment, by shadowing ps with one that
# fails — so the case the defect got wrong is asserted even where the real table
# is readable, and even where it is not.
_al=$( PATH="$PSF:$PATH"; _runner_alive 999999; echo $? )
assert_eq "$_al" "2" "with the process table unreadable, liveness reports CANNOT TELL"

# …and the reconciler must not act on that. Leaving `running` is the recoverable
# error: a live phase keeps its true status and records its own outcome, whereas
# `interrupted` written over a live run is a falsehood in the resume authority.
printf '%s\n' '{"version":1,"phases":{"implement":{"status":"running","runner_pid":4242}}}' > "$IRS"
_rec=$( PATH="$PSF:$PATH"; state_reconcile_running "$IRS" 2>&1 )
assert_eq "$(jqd "$IRS" '.phases.implement.status' '')" "running" \
  "a running phase is LEFT running when liveness cannot be determined"
assert_contains "$_rec" "cannot read the process table" \
  "and says so, because an unverifiable running phase is a different claim"
# 🛑 Mutation: restore either two-outcome form — the bare `ps | grep -q`, or
# `kill -0` before the readability probe — and this pair fails, recording
# `interrupted` and printing nothing. That is exactly what a live crimeball run
# got from a sandboxed spec-status.

if [ "$_ps_ok" -eq 1 ]; then
  # A live process whose command really contains spec-run, so ALIVE is reachable
  # rather than asserted only in its negative forms — without which "leave it
  # running" could be satisfied by a check that never says alive at all.
  "$PSF/spec-run-probe" & _sr_pid=$!
  sleep 1
  _al=0; _runner_alive "$_sr_pid" || _al=$?
  assert_eq "$_al" "0" "a live process whose command is a spec-run reports ALIVE"
  _al=0; _runner_alive 999999 || _al=$?
  assert_eq "$_al" "1" "a pid that is not running reports GONE"
  _al=0; _runner_alive 1 || _al=$?
  assert_eq "$_al" "1" "a live pid that is not a spec-run also reports GONE"

  printf '%s\n' "{\"version\":1,\"phases\":{\"implement\":{\"status\":\"running\",\"runner_pid\":$_sr_pid}}}" > "$IRS"
  _rec=$(state_reconcile_running "$IRS" 2>&1)
  assert_eq "$(jqd "$IRS" '.phases.implement.status' '')" "running" \
    "a verifiably live runner keeps its phase running"
  assert_eq "$_rec" "" "with nothing to report"
  # Killing it makes the SAME state reconcile to interrupted — which is what keeps
  # the assertion above from passing merely because nothing is ever relabelled.
  kill "$_sr_pid" 2>/dev/null; wait "$_sr_pid" 2>/dev/null || true
  state_reconcile_running "$IRS"
  assert_eq "$(jqd "$IRS" '.phases.implement.status' '')" "interrupted" \
    "and once that runner is really dead, the same state becomes interrupted"
else
  t_skip "live-runner liveness" "the process table is unreadable here"
  PLATFORM_GATED_ASSERTIONS=$((${PLATFORM_GATED_ASSERTIONS:-0} + 6))
fi

# ------------------------------------------------ spend is read, not remembered --
printf '\nroadmap spend\n'
# An entry's cost_usd is only written when the entry FINISHES, so an in-progress
# entry contributes a figure frozen at its first phase. Measured live: the entry
# read $3.71 (specify alone) while its phases summed to $10.40 — a ceiling
# checked against the recorded value is optimistic by everything since.
SPD="$WORK/spend"; mkdir -p "$SPD/specs/001-a/.pipeline"
printf '%s\n' '{"version":1,"phases":{
  "specify":{"status":"ok","cost_usd":3.71},
  "plan":{"status":"ok","cost_usd":5.45},
  "tasks":{"status":"ok","cost_usd":1.24}}}' > "$SPD/specs/001-a/.pipeline/state.json"
SPST="$SPD/state.json"
printf '%s\n' '{"entries":{"a":{"status":"in_progress","feature_dir":"specs/001-a","cost_usd":3.71}}}' \
  > "$SPST"
assert_eq "$(roadmap_spent "$SPD" "$SPST")" "10.4" \
  "an in-progress entry is priced from its phases, not its stale total"

# 🛑 A state file that exists but records NO cost is not a spend of $0. Every
# phase run by the stub carries `cost_usd: null`, and summing those with `// 0`
# produced a confident zero that beat the recorded figure — which silently
# disarmed five budget assertions: a $9.50 entry priced itself at nothing, so
# the ceiling could never be reached and the tests passed on a budget check that
# no longer checked anything.
mkdir -p "$SPD/specs/002-b/.pipeline"
printf '%s\n' '{"version":1,"phases":{
  "specify":{"status":"ok","cost_usd":null},
  "plan":{"status":"interrupted"}}}' > "$SPD/specs/002-b/.pipeline/state.json"
printf '%s\n' '{"entries":{"b":{"status":"in_progress","feature_dir":"specs/002-b","cost_usd":9.5}}}' \
  > "$SPST"
assert_eq "$(roadmap_spent "$SPD" "$SPST")" "9.5" \
  "an entry whose phases are all unmeasured keeps its recorded figure, not \$0"

# 🛑 The field-collapse case, which is what actually broke five budget checks.
# An entry with NO feature_dir emits an empty middle field; tab is IFS
# whitespace, so bash collapses the run and every later field shifts left. This
# fixture is the shape `roadmap_state_init` + `roadmap_entry_set` really produce.
printf '%s\n' '{"entries":{"c":{"status":"done","cost_usd":9.5}}}' > "$SPST"
assert_eq "$(roadmap_spent "$SPD" "$SPST")" "9.5" \
  "an entry with no feature_dir keeps its cost in the cost field"

# an entry whose feature directory is gone still contributes what was recorded
printf '%s\n' '{"entries":{"gone":{"status":"done","feature_dir":"specs/404-x","cost_usd":7.5}}}' \
  > "$SPST"
assert_eq "$(roadmap_spent "$SPD" "$SPST")" "7.5" \
  "and one whose pipeline state is gone falls back to the recorded figure"


printf '\n'

printf '\n%s passed, %s failed' "$pass" "$fail"
[ "$skipped" -gt 0 ] && printf ', %s skipped' "$skipped"
# The README advertises a number. If it is wrong, one of the two is stale — and
# a count in a README is the single easiest claim to leave behind.
# Assertions that CANNOT run on this platform are added back, so the advertised number
# is the number of assertions the suite HAS rather than the number this host could
# execute. Without this the count is unsatisfiable in two places at once: macOS runs 3
# caffeinate assertions where Linux runs 1, so a README true locally is false in CI —
# which is exactly how main sat red from 2026-08-24 while the same tree passed locally.
_tally=$((pass + fail + ${PLATFORM_GATED_ASSERTIONS:-0}))
if [ "${PLATFORM_GATED_ASSERTIONS:-0}" -gt 0 ]; then
  printf ', %s not applicable on this platform' "$PLATFORM_GATED_ASSERTIONS"
fi
if [ "${DOC_ASSERTION_COUNT:-0}" -gt 0 ] && [ "$_tally" -ne "$DOC_ASSERTION_COUNT" ]; then
  printf '\n  \033[31m✗\033[0m the README advertises %s assertions; this run had %s.\n' \
    "$DOC_ASSERTION_COUNT" "$_tally"
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
