#!/usr/bin/env bash
# Shared helpers for spec-run. Sourced, never executed directly.

# ---------------------------------------------------------------- output ------

_c_reset=$'\033[0m'; _c_dim=$'\033[2m'; _c_red=$'\033[31m'
_c_green=$'\033[32m'; _c_yellow=$'\033[33m'; _c_blue=$'\033[34m'
if [ ! -t 1 ]; then _c_reset=""; _c_dim=""; _c_red=""; _c_green=""; _c_yellow=""; _c_blue=""; fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s→%s %s\n' "$_c_blue" "$_c_reset" "$*"; }
ok()   { printf '%s✓%s %s\n' "$_c_green" "$_c_reset" "$*"; }
warn() { printf '%s!%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
dim()  { printf '%s%s%s\n' "$_c_dim" "$*" "$_c_reset"; }
dim_s() { printf '%s%s%s' "$_c_dim" "$*" "$_c_reset"; }  # inline, no newline

# Every failure states its own reason. A remedy that cannot help, printed over a
# cause it does not name, is worse than no message at all.
die() { err "$1"; [ -n "${2:-}" ] && printf '  %s\n' "$2" >&2; exit 1; }
# A malformed invocation is exit 3, per the documented codes: a caller can tell
# "you typed it wrong" from "the work failed" without parsing prose.
die_usage() { err "$1"; [ -n "${2:-}" ] && printf '  %s\n' "$2" >&2; exit 3; }

# ------------------------------------------------------------- utilities ------

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Kill every descendant of a pid, depth-first.
#
# A phase runs inside a command substitution, so its pid is never ours to hold —
# and signalling the runner therefore leaves the `claude -p` child ORPHANED AND
# STILL RUNNING, with every tool it had. Measured, and it is worse than it sounds:
# an implement phase whose parent was killed carried on for ~2 HOURS, ticked its
# remaining tasks, and COMMITTED to the repository — while a human was separately
# verifying and merging that same work. Nothing in the run reported it; the commit
# simply appeared on the branch afterwards, authored by the repo's git identity
# and indistinguishable from a person's.
#
# Depth-first so a grandchild dies before the parent that would otherwise be
# reaped and lose the link to it.
kill_descendants() { # kill_descendants <pid>
  local parent="$1" child
  [ -n "$parent" ] || return 0
  for child in $(ps -eo pid=,ppid= 2>/dev/null | awk -v p="$parent" '$2==p {print $1}'); do
    kill_descendants "$child"
    kill -TERM "$child" 2>/dev/null || true
  done
  return 0
}

# A temp file, always rooted in TMPDIR. Never call `mktemp` with no template.
#
# macOS mktemp with no template ignores TMPDIR entirely and writes to the Darwin
# per-user temp dir (confstr _CS_DARWIN_USER_TEMP_DIR, /var/folders/...). Under a
# sandbox that grants writes to TMPDIR and nothing else — which is what Claude
# Code's own Bash sandbox does — every bare mktemp therefore fails, and it fails
# in the worst available way: the command substitution yields an empty string, so
# the failure surfaces later as `line 211: : No such file or directory` against
# whatever line used the path. Measured on macOS 25.5: `spec-upgrade --check`
# printed 60 such lines plus an integer-comparison error, naming neither mktemp
# nor the sandbox anywhere in the output.
#
# Exporting TMPDIR does not fix it. Only passing a template does.
mktmp()  { mktemp    "${TMPDIR:-/tmp}/speckit-pipeline.XXXXXXXX"; }
mktmpd() { mktemp -d "${TMPDIR:-/tmp}/speckit-pipeline.XXXXXXXX"; }

file_sha() {
  [ -f "$1" ] || { printf 'absent\n'; return 0; }
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}

# jq -e on a possibly-absent key: prints the value, or the given default.
jqd() { # jqd <file> <filter> <default>
  local v
  v=$(jq -r "$2 // empty" "$1" 2>/dev/null) || v=""
  [ -n "$v" ] && [ "$v" != "null" ] && printf '%s\n' "$v" || printf '%s\n' "$3"
}

# --------------------------------------------------------------- version ------
# Every tool can say what it is. The first thing anyone needs in a bug report is
# which copy they are running, and with two install paths (a clone and a plugin
# cache that a plugin update replaces) "the latest" is not an answer.
pipeline_version() {
  local m="$SPECKIT_PIPELINE_ROOT/.claude-plugin/plugin.json"
  local v sk
  v=$(jqd "$m" '.version' unknown)
  sk=$(jqd "$m" '.metadata.speckit_version' unknown)
  printf 'speckit-pipeline %s (vendored spec-kit %s)\n' "$v" "$sk"
  printf 'installed at %s\n' "$SPECKIT_PIPELINE_ROOT"
  # Which spec-kit the PROJECT has is a different fact from which one is
  # vendored here, and only the first one runs.
  if [ -n "${1:-}" ] && [ -f "$1/.specify/integration.json" ]; then
    printf 'this project scaffolded with %s\n' \
      "$(jqd "$1/.specify/integration.json" '.version' unknown)"
  fi
}

# ------------------------------------------------------------ live progress ----
# A phase is a separate process, so by default the only thing visible is its
# result: one line, minutes later. `--output-format stream-json` emits an event
# per step, so a filter over that stream can show what the phase is DOING without
# putting its whole transcript on screen.
#
# The filter passes every line through unchanged — the result event is the last
# JSON object on stdout, which is what the caller parses — and writes its
# condensed view to STDERR, so capturing stdout with $(...) still works and the
# progress is visible while it happens.

stream_progress() { # reads the event stream on stdin; $1 = repo root to strip
  local line kind repo="${1:-}" turns=0 out_tok=0 delta running=""
  # `|| [ -n "$line" ]` handles a final line with no trailing newline. Claude's
  # stream is newline-terminated, so this looks redundant — but a phase killed
  # mid-write leaves a partial last line, and that is the one worth showing.
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"

    # Count BEFORE the display filter. A phase's spend was invisible until its
    # result event, so a run killed partway through reported `unmeasured` and
    # there was no way to see how far it had got — the stream carried
    # `message.usage` all along and it was thrown away.
    #
    # 🛑 Turns and output tokens only, never a dollar estimate. Converting
    # tokens to money needs a per-model price table, and a hardcoded table that
    # decides the figures this tool reports cannot be corrected without a
    # release — the authoritative cost arrives in the result event, which is the
    # one number that should ever be printed with a currency sign.
    case "$line" in
      *'"type":"assistant"'*)
        turns=$((turns + 1))
        delta=$(printf '%s' "$line" | jq -r '.message.usage.output_tokens // 0' 2>/dev/null) || delta=0
        case "$delta" in ''|*[!0-9]*) delta=0;; esac
        out_tok=$((out_tok + delta))
        ;;
    esac
    if [ "$turns" -gt 0 ]; then
      if [ "$out_tok" -ge 1000 ]; then
        running=$(printf '[%dt · %d.%dk out]' "$turns" $((out_tok / 1000)) $(( (out_tok % 1000) / 100 )))
      else
        running=$(printf '[%dt · %d out]' "$turns" "$out_tok")
      fi
    fi

    case "$line" in
      *'"tool_use"'*) ;;
      *'"type":"result"'*) ;;
      *) continue;;
    esac
    # Three corrections over the first version, all from watching a real run:
    #
    #  * `.input.skill` — the Skill tool's argument is named `skill`, so every
    #    line read "· Skill " with nothing after it.
    #  * strip the repo prefix BEFORE truncating. Absolute paths in a worktree
    #    are ~70 characters of prefix, so truncating first left every line
    #    reading ".../worktrees/scorecard-entries/services/bluepri" — the same
    #    text for every file, with the filename always cut off. Sed-ing the
    #    output afterwards cannot recover it; the loss happens here.
    #  * keep the TAIL when a value is still too long. For a path the
    #    interesting part is the end.
    kind=$(printf '%s' "$line" | jq -r --arg repo "$repo" '
      def shorten:
        tostring
        | if ($repo != "" and startswith($repo + "/")) then .[($repo|length + 1):] else . end
        | if (length > 76) then "…" + .[-75:] else . end;
      if .type == "result" then
        "      \(if .is_error then "!" else "·" end) done: \(.num_turns) turns, $\(.total_cost_usd // 0)"
      else
        [ (.message.content // [])[] | select(.type == "tool_use") |
          "      · \(.name) \(
             ( .input.skill // .input.file_path // .input.pattern // .input.command
               // .input.path // .input.description // "" ) | shorten )"
        ] | join("\n")
      end' 2>/dev/null) || kind=""
    case "$line" in
      *'"type":"result"'*) [ -n "$kind" ] && printf '%s%s%s\n' "$_c_dim" "$kind" "$_c_reset" >&2;;
      *) [ -n "$kind" ] && printf '%s%s %s%s\n' "$_c_dim" "$kind" "$running" "$_c_reset" >&2;;
    esac
  done
}

# ------------------------------------------------------------- preflight ------
# Check every prerequisite BEFORE spending a phase budget. A missing dependency
# discovered three phases in has already cost real money; and a run that reaches
# a write it cannot perform pays full price for a guess.

preflight() { # preflight <repo_root>
  local root="$1" missing=0

  # NOT `command -v claude`: the runner is configurable, and checking the default
  # name blocks anyone whose only runner is a wrapper — which is precisely the
  # case the --claude-bin option exists to serve. probe_claude_bin checks the
  # configured binary; this function must not second-guess it with a hardcoded
  # name. (Found by CI, which has no `claude`: 30 assertions never reached an
  # argv, and every one of them had passed on a laptop that happened to have it.)
  command -v jq >/dev/null 2>&1 || {
    err "jq not on PATH"
    printf '  install: brew install jq  (or apt-get install jq)\n' >&2
    missing=1
  }
  command -v git >/dev/null 2>&1 || { err "git not on PATH"; missing=1; }

  [ "$missing" -eq 0 ] || return 1

  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    err "not a git repository: $root"
    printf '  spec-run needs git to name the feature branch and to scope-check each phase\n' >&2
    return 1
  }

  [ -d "$root/.specify" ] || {
    err "no .specify/ directory in $root"
    printf '  run: %s/bin/spec-bootstrap %s\n' "$SPECKIT_PIPELINE_ROOT" "$root" >&2
    return 1
  }

  return 0
}

# The model alias is resolved by the CLI, but a typo in phases.json should fail
# here rather than inside a phase that has already been billed for a turn.
valid_model() {
  case "$1" in opus|sonnet|haiku|fable|claude-*) return 0;; *) return 1;; esac
}
valid_effort() {
  case "$1" in low|medium|high|xhigh|max) return 0;; *) return 1;; esac
}

# ------------------------------------------------------------ state file ------
# The state file is the resume authority. Artifact presence alone cannot tell
# "plan.md is finished" from "plan.md was half-written when the phase was killed",
# so a run that starts is recorded BEFORE it can fail: an absent record and a
# failed record must never collapse into one state.

state_init() { # state_init <state_file> <feature_dir> <branch> <description>
  local f="$1"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] && return 0
  jq -n \
    --arg fd "$2" --arg br "$3" --arg desc "$4" --arg t "$(now_iso)" \
    '{version:1, feature_dir:$fd, branch:$br, description:$desc,
      created_at:$t, phases:{}}' > "$f"
}

state_phase_get() { # state_phase_get <state_file> <phase> <field> <default>
  jqd "$1" ".phases[\"$2\"].$3" "$4"
}

state_phase_start() { # state_phase_start <state_file> <phase> <session_id> <model> <effort>
  local f="$1" tmp
  tmp=$(mktmp)
  # `runner_pid` is what makes "running" falsifiable. Without it, a phase killed
  # by a Ctrl-C, a reboot or an OOM stays `running` forever, and "in flight",
  # "killed" and "crashed" become one state with no cost and no outcome — the
  # shape where the absence of a record is itself unrecorded.
  jq --arg p "$2" --arg sid "$3" --arg m "$4" --arg e "$5" --arg t "$(now_iso)" \
     --arg pid "$$" \
    '.phases[$p] = ((.phases[$p] // {}) + {
        status:"running", session_id:$sid, model:$m, effort:$e,
        started_at:$t, runner_pid:($pid|tonumber),
        attempts:(((.phases[$p].attempts) // 0) + 1)
     })' "$f" > "$tmp" && mv "$tmp" "$f"
}

# Is the runner that recorded this phase still running?
#
#   0  alive — the pid is live AND is a spec-run
#   1  gone  — it is not running, or is some unrelated process holding a reused pid
#   2  CANNOT TELL — the process table is unreadable here
#
# 🛑 The third outcome is the whole point, and its absence was a real defect
# against the state file that is the resume authority. The check used to end on
#
#     ps -o command= -p "$pid" | grep -q spec-run
#
# so where `ps` is DENIED rather than merely unhelpful, the grep matched nothing
# and a LIVE runner reported as gone. Measured against a live roadmap on this
# machine: pid 12199 was a running spec-run, and the same call returned FALSE
# inside Claude Code's Bash sandbox (`ps` → "operation not permitted") and TRUE
# outside it. state_reconcile_running then relabels that phase `interrupted` and
# WRITES it, so any spec-status or spec-run from a sandboxed session recorded a
# lie about a run that was still working — and invited a resume over work in
# flight.
#
# The comment this replaces had the right instinct and guarded only one
# direction: it worried that a reused pid would report an interrupted phase as
# still running, because "an unsatisfiable block is worse than a wrong label".
# Both errors are now representable, so neither has to be guessed.
_runner_alive() { # _runner_alive <pid>
  local pid="${1:-}" cmd
  # No pid, or a malformed one, is GONE and not unknown: there is nothing to
  # check, which is the same evidence as a phase that recorded no runner at all.
  case "$pid" in ''|*[!0-9]*) return 1;; esac

  # ⚠️ READABILITY IS A PRECONDITION, checked before anything else and not as a
  # fallback. Two attempts got this wrong in the same way, so the ordering is the
  # fix and deserves the emphasis:
  #
  #   * `ps … | grep -q spec-run` alone — a refused ps matched nothing, so a live
  #     runner read as gone.
  #   * `kill -0` first, then probe ps — under Claude Code's Bash sandbox
  #     `kill -0` on a FOREIGN pid is itself refused (EPERM), and EPERM is
  #     indistinguishable from ESRCH by exit status, so it returned `gone` and
  #     never reached the probe at all. Measured on pid 12199, a live spec-run:
  #     `kill -0` → "operation not permitted", `ps` → "operation not permitted",
  #     `kill -0 $$` → fine. Signalling OURSELVES is allowed; that is why a
  #     self-probe is the only trustworthy capability test here.
  #
  # The command line is REQUIRED for a positive answer — a bare pid check is
  # defeated by pid reuse — so if the table cannot be read, the question is
  # unanswerable however the pid check behaves. Probe with our own pid, which
  # certainly exists, and answer CANNOT TELL.
  [ -n "$(ps -o command= -p $$ 2>/dev/null)" ] || return 2

  # From here the table IS readable, so its silence is evidence: no row for the
  # pid means gone. `kill -0` is deliberately not used — ps answers existence and
  # identity together, and one primitive has one failure mode instead of two.
  cmd=$(ps -o command= -p "$pid" 2>/dev/null) || cmd=""
  [ -n "$cmd" ] || return 1
  case "$cmd" in *spec-run*) return 0;; *) return 1;; esac
}

state_reconcile_running() { # <state_file> — a `running` phase whose runner is
  # gone is `interrupted`: it ran, it produced no outcome, and nobody recorded
  # why. That is a distinct state from `failed` (which was measured) and from
  # never having started, and only the reader can tell the difference, because
  # by definition the writer was killed before it could.
  local f="$1" tmp stale p
  [ -f "$f" ] || return 0
  stale=$(jq -r '.phases | to_entries[]
                 | select(.value.status == "running")
                 | "\(.key)\t\(.value.runner_pid // "")"' "$f" 2>/dev/null) || return 0
  [ -n "$stale" ] || return 0
  local alive
  while IFS="$(printf '\t')" read -r p pid; do
    [ -n "$p" ] || continue
    alive=0; _runner_alive "$pid" || alive=$?
    [ "$alive" -eq 0 ] && continue
    # 🛑 CANNOT TELL is not permission to relabel. Leaving the phase `running` is
    # the recoverable error: a phase that really is alive keeps its true status
    # and will record its own outcome, whereas writing `interrupted` over a live
    # run puts a falsehood in the file the resume path trusts. Said out loud
    # rather than skipped silently, because a `running` phase that nothing can
    # verify is a different claim from one that was just confirmed.
    if [ "$alive" -eq 2 ]; then
      warn "$p is recorded running, and this shell cannot read the process table"
      printf '  so whether its runner is alive is unknown — leaving it as running.\n' >&2
      printf '  Re-run from a shell that can use `ps` to have it reconciled.\n' >&2
      continue
    fi
    tmp=$(mktmp)
    jq --arg p "$p" --arg t "$(now_iso)" \
      '.phases[$p] += {status:"interrupted", ended_at:$t,
                       note:"the runner exited without recording an outcome; cost and turns are unmeasured"}' \
      "$f" > "$tmp" && mv "$tmp" "$f"
  done <<EOF
$stale
EOF
}

state_phase_finish() { # ... <state_file> <phase> <status> <cost> <turns> <duration_ms> <artifact_sha> <note>
  local f="$1" tmp
  tmp=$(mktmp)
  jq --arg p "$2" --arg s "$3" --arg c "$4" --arg n "$5" --arg d "$6" \
     --arg sha "$7" --arg note "$8" --arg t "$(now_iso)" \
    '.phases[$p] += {
        status:$s,
        # An empty figure records as null, never as 0. "$0.00 spent" and "nobody
        # measured it" are different facts, and `// 0` erases the difference:
        # a phase that never ran recorded a tidy $0 and 0 turns.
        cost_usd:(if $c == "" then null else ($c|tonumber? // null) end),
        num_turns:(if $n == "" then null else ($n|tonumber? // null) end),
        duration_ms:(if $d == "" then null else ($d|tonumber? // null) end),
        artifact_sha:$sha, note:$note, finished_at:$t
     }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# An absent figure states its reason. "$0.00" and "nobody measured it" are
# different facts and only one of them is good news.
fmt_cost() { [ -n "${1:-}" ] && printf '$%s' "$1" || printf 'cost unmeasured'; }

# The token split for one phase, kept SEPARATE from state_phase_finish rather than
# bolted onto its signature. That function already takes eight positional
# arguments; a twelfth would be the kind of call nobody can read at the site, and
# every existing caller and test would have to move for a field none of them use.
#
# `usage` is written as a whole object so a partially-reported envelope cannot
# leave three measured fields beside one stale one. Every field is null-unless-
# measured, on the same principle as cost_usd: an unmeasured 0 reads as thrift.
state_phase_set_usage() { # <state_file> <phase> <cache_read> <cache_write> <in> <out>
  local f="$1" tmp
  [ -f "$f" ] || return 0
  tmp=$(mktmp)
  jq --arg p "$2" --arg cr "$3" --arg cw "$4" --arg ti "$5" --arg to "$6" \
    '.phases[$p] += { usage: {
        cache_read_tokens:(if $cr == "" then null else ($cr|tonumber? // null) end),
        cache_write_tokens:(if $cw == "" then null else ($cw|tonumber? // null) end),
        input_tokens:(if $ti == "" then null else ($ti|tonumber? // null) end),
        output_tokens:(if $to == "" then null else ($to|tonumber? // null) end)
     } }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# Average resident context: cache reads divided by turns. Printed rather than
# derived at each call site because it is the one figure worth looking at and the
# one most easily got wrong — dividing by a null turn count yields a confident 0.
# Prints nothing when either input is missing, so an absent number stays absent.
fmt_read_per_turn() { # fmt_read_per_turn <cache_read_tokens> <turns>
  local r="${1:-}" t="${2:-}"
  case "$r" in ''|null|*[!0-9]*) return 0;; esac
  case "$t" in ''|null|*[!0-9]*) return 0;; esac
  [ "$t" -gt 0 ] || return 0
  awk -v r="$r" -v t="$t" 'BEGIN{printf "%.0fk", (r/t)/1000}'
}

# Token counts run to eight digits and a column of them is unreadable. k/M is not
# decoration here: the interesting comparison is between phases, and 17.9M beside
# 1.6M states the ratio at a glance where 17946392 beside 1583648 does not.
fmt_tokens() { # fmt_tokens <n>
  local n="${1:-}"
  case "$n" in ''|null) printf 'unmeasured'; return 0;; esac
  case "$n" in *[!0-9]*) printf '%s' "$n"; return 0;; esac
  if   [ "$n" -ge 1000000 ]; then awk -v n="$n" 'BEGIN{printf "%.1fM", n/1000000}'
  elif [ "$n" -ge 1000 ];    then awk -v n="$n" 'BEGIN{printf "%.1fk", n/1000}'
  else printf '%s' "$n"
  fi
}

# Every attempt gets its OWN session id. Reusing one is not a way back into a
# thread — `claude --session-id <existing>` refuses and exits in about two
# seconds, which is how a re-run of the plan phase came back "ok" over the
# artifact its previous attempt had left behind. Resuming is `--resume`; starting
# is a fresh id. The history is kept so an earlier thread stays reachable.
state_phase_push_session() { # <state_file> <phase> <session_id>
  local f="$1" tmp; tmp=$(mktmp)
  jq --arg p "$2" --arg sid "$3" \
    '.phases[$p] = ((.phases[$p] // {}) + {
        session_id:$sid,
        sessions:(((.phases[$p].sessions) // []) + [$sid])
     })' "$f" > "$tmp" && mv "$tmp" "$f"
}

# The LAST JSON object in the output.
#
# Two shapes arrive here and they must not be confused. `--output-format json`
# returns one pretty-printed object across many lines; `--output-format
# stream-json` returns one object PER LINE, with the result last. An earlier
# version short-circuited on "does the whole text parse as an object?", which is
# TRUE for JSONL — jq reads each line as its own input — so the streaming path
# handed every later `jq` the entire stream. `.permission_denials | length` then
# produced one 0 per event, `[ "0\n0\n0…" -gt 0 ]` failed as a non-integer, and
# the run printed a column of zeroes. Slurping answers the real question: how many
# objects are there, and what is the last one.
extract_json() { # extract_json <text>
  local text="$1" n line
  n=$(printf '%s' "$text" | jq -s 'length' 2>/dev/null) || n=""
  case "${n:-x}" in
    1)  printf '%s' "$text" | jq -c '.' 2>/dev/null && return 0;;
    ''|x|0) ;;
    *)  printf '%s' "$text" | jq -c -s '.[-1]' 2>/dev/null && return 0;;
  esac
  # Not wholly parseable: a wrapper may have printed its own chatter around the
  # result, so look for the last line that is an object on its own.
  while IFS= read -r line; do
    case "$line" in
      \{*\}) jq -e 'type == "object"' >/dev/null 2>&1 <<<"$line" && printf '%s' "$line" && return 0;;
    esac
  done < <(printf '%s\n' "$text" | tail -r 2>/dev/null || printf '%s\n' "$text")
  return 1
}

# The FINAL result envelope, not merely the last JSON object. A phase killed
# mid-stream leaves an ordinary stream line as its last object — measured: a plan
# phase SIGTERMed at exit 143 ended on
# {"type":"system","subtype":"thinking_tokens",...}, which parses cleanly and
# carries no cost, so "some JSON parsed" was read as "the phase completed" and a
# 3,779-byte stub plan.md was recorded ok. Only a result envelope means finished.
#
# 🛑 IT MUST RETURN EXACTLY ONE ENVELOPE, and the FIRST version did not — a phase
# can emit TWO. Measured 2026-09-15 on the SDLC roadmap's entry 8: the implement
# pass hit `API Error: No response from API`, the CLI retried inside the same
# invocation, and the stream carried two `result` records. The non-stream branch
# below used bare `jq` (no `-s`), which over a SEQUENCE emits one line per match
# — so it returned BOTH, matched non-empty, and the streamed branch below (which
# already took `last`, correctly) never ran.
#
# Every downstream `jq -r … <<<"$json"` then produced two lines. Observed in that
# run's log: `$21.8689346\n22.644156`, `194\n6 turns`, `(success\nsuccess)` and
# `[: 0\n0: integer expression expected` from the denial count. And the VERDICT
# went the wrong way: `cli_error` is read from `.is_error`, and the FIRST
# envelope is the ABORTED attempt — so its error verdict outvoted the retry's
# success. A pass that exited 0 reporting `STATUS: ok`, having ticked 27 of 94
# tasks, was recorded `failed`, and the roadmap stopped on it.
#
# ⚠️ Whether the defect is fatal or silent depends on WHICH attempt failed,
# because `$(…)` strips TRAILING newlines: two clean envelopes give "\n\n" -> ""
# and read as no error, while an error followed by a success gives "1\n" -> "1"
# and reads as an error. Never put an emptiness test over a jq sequence.
#
# The LAST envelope is the right one by definition — it is the attempt that
# actually ended the invocation. So slurp and take it.
# ⚠️ Stated bound: `total_cost_usd` looks cumulative across the invocation but
# `num_turns` is per-segment, so a retried phase's recorded turns describe the
# FINAL segment only (6, against ~200 really executed in that run). A lower
# bound, not a measurement.
extract_result_json() { # extract_result_json <text>
  local text="$1" whole out
  # Non-stream --output-format json: the whole output is one (possibly
  # pretty-printed) value, which the line-wise pass below would miss.
  whole=$(printf '%s' "$text" \
          | jq -c -s 'map(select(type == "object"
                                 and (.type == "result" or has("total_cost_usd"))))
                      | last // empty' \
            2>/dev/null) || whole=""
  if [ -n "$whole" ] && [ "$whole" != null ]; then printf '%s' "$whole"; return 0; fi
  # Streamed: one object per line. Filter to object-shaped lines first — a
  # truncated tail line is not valid JSON and would fail the whole slurp.
  out=$(printf '%s\n' "$text" | grep -E '^\{.*\}$' 2>/dev/null \
        | jq -c -s 'map(select(type == "object"
                               and (.type == "result" or has("total_cost_usd"))))
                    | last // empty' 2>/dev/null) || out=""
  if [ -n "$out" ] && [ "$out" != null ]; then printf '%s' "$out"; return 0; fi
  return 1
}

state_total_cost() { jq '[.phases[].cost_usd // 0] | add // 0' "$1"; }

# Where a run's tokens went, per phase. Lives here rather than in spec-run or
# spec-status because both print it and a second copy would drift: the two
# summaries disagreeing about the same state file is worse than either being
# absent, since only one of them can be right and nothing says which.
#
# Prints NOTHING when no phase recorded usage. An older state file predates these
# fields entirely, and a table of "unmeasured" rows looks like a measurement that
# came back empty rather than one that was never taken.
print_token_profile() { # print_token_profile <state_file>
  local f="$1" any
  [ -f "$f" ] || return 0
  any=$(jq -r '[.phases[] | select(.usage.cache_read_tokens != null)] | length' "$f" 2>/dev/null) || return 0
  [ "${any:-0}" -gt 0 ] || return 0

  # The spacing belongs to the block, not to its callers: a caller that printed
  # the blank line itself would leave a stray one behind on the return above,
  # which is the common case on any state file written before these fields.
  say ""
  say "token profile  $(dim_s "read/turn is the average resident context — the figure a shorter pass moves")"
  printf '  %-10s %12s %12s %9s %9s %11s\n' PHASE 'CACHE READ' 'CACHE WRITE' INPUT OUTPUT 'READ/TURN'
  jq -r '.phases | to_entries[] |
         [.key,
          (.value.usage.cache_read_tokens  // "" | tostring),
          (.value.usage.cache_write_tokens // "" | tostring),
          (.value.usage.input_tokens       // "" | tostring),
          (.value.usage.output_tokens      // "" | tostring),
          (.value.num_turns                // "" | tostring)] | @tsv' "$f" |
    while IFS=$'\t' read -r p cr cw ti to nt; do
      printf '  %-10s %12s %12s %9s %9s %11s\n' \
        "$p" "$(fmt_tokens "$cr")" "$(fmt_tokens "$cw")" \
        "$(fmt_tokens "$ti")" "$(fmt_tokens "$to")" \
        "$(fmt_read_per_turn "$cr" "$nt")"
    done
  # Totals are summed over the phases that HAVE a figure, and the row says how
  # many those were. A total that silently covers four of seven phases is the
  # shape of understatement this whole block exists to remove.
  jq -r '[.phases[] | select(.usage.cache_read_tokens != null)] as $m |
         [($m|length), (.phases|length),
          ([$m[].usage.cache_read_tokens  // 0] | add // 0),
          ([$m[].usage.cache_write_tokens // 0] | add // 0),
          ([$m[].usage.input_tokens       // 0] | add // 0),
          ([$m[].usage.output_tokens      // 0] | add // 0)] | @tsv' "$f" |
    while IFS=$'\t' read -r nm np cr cw ti to; do
      printf '  %-10s %12s %12s %9s %9s\n' TOTAL \
        "$(fmt_tokens "$cr")" "$(fmt_tokens "$cw")" "$(fmt_tokens "$ti")" "$(fmt_tokens "$to")"
      [ "$nm" = "$np" ] || dim "  ($nm of $np phase(s) reported usage; the rest are not in this total)"
    done
}

# Overwrite a phase's cost/turns with a total, and record how many passes made it.
# A chunked phase runs as SEVERAL processes, and state_phase_finish is called by
# each one — so without this the recorded figure is the last pass alone and the
# run looks far cheaper than it was. cost.log keeps every pass individually; this
# is the roll-up the summary and any --budget check read.
state_phase_set_totals() { # <state_file> <phase> <cost> <turns> <passes>
  local f="$1" tmp
  tmp=$(mktmp)
  jq --arg p "$2" --arg c "$3" --arg n "$4" --arg k "$5" \
    '.phases[$p] += {
        cost_usd:(if $c == "" then null else ($c|tonumber? // null) end),
        num_turns:(if $n == "" then null else ($n|tonumber? // null) end),
        passes:($k|tonumber? // null)
     }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# ----------------------------------------------- spec-kit's own write targets --
# The plan phase legitimately writes the AGENT CONTEXT file at the repo root —
# spec-kit's `update-agent-context.sh` maintains it, complete with the
# <!-- SPECKIT START/END --> plan pointer. A scope of specs/ and .specify/ alone
# therefore fails a plan that did exactly what it is supposed to do, which is
# what the first real two-phase run reported: STATUS ok, 26 turns, every artifact
# written, marked `failed` over CLAUDE.md.
#
# The list is DERIVED from that script rather than copied out of it. It names 25
# possible files (CLAUDE.md, GEMINI.md, AGENTS.md, .cursor/rules/..., and so on),
# and a hand-maintained copy would silently go stale the first time the vendored
# spec-kit is refreshed — reintroducing this same false failure for whichever
# agent got added. Enumerate the primitive, not a snapshot of it.
agent_context_paths() { # agent_context_paths <repo_root>
  # Which files a phase may legitimately write outside specs/ — the agent context
  # file (CLAUDE.md and its equivalents), which spec-kit's own tooling maintains.
  #
  # It is DECLARED in two different places depending on the version, and the
  # difference is not cosmetic:
  #   0.7.x  — core ships update-agent-context.sh with the whole list of 25
  #            possible files hardcoded as *_FILE="$REPO_ROOT/…" variables.
  #   0.11.x+ — agent-context became an OPT-IN extension that declares its
  #            targets as data: context_files / context_file in its config, or a
  #            per-integration default keyed by .specify/init-options.json.
  #
  # Read both, and read nothing when nothing can write those files: on 0.16.5
  # without the extension the answer is genuinely the empty list, and a scope
  # check that invented entries there would be permitting writes nobody makes.
  local root="$1" f

  # --- 0.7.x: scrape core's own enumeration
  f="$root/.specify/scripts/bash/update-agent-context.sh"
  [ -f "$f" ] && sed -nE 's/^[A-Z_]+_FILE="\$REPO_ROOT\/(.+)"$/\1/p' "$f"

  # --- 0.11.x+: read the extension's declaration
  local cfg="$root/.specify/extensions/agent-context/agent-context-config.yml"
  local defs="$root/.specify/extensions/agent-context/agent-context-defaults.json"
  if [ -f "$cfg" ]; then
    local listed
    # context_files takes precedence over context_file, per the extension's own
    # documented rule — not our guess at which wins.
    listed=$(awk '
      /^context_files:[[:space:]]*\[\]/ {next}
      /^context_files:/ {inlist=1; next}
      inlist && /^[[:space:]]*-[[:space:]]*/ {sub(/^[[:space:]]*-[[:space:]]*/,""); gsub(/"/,""); if ($0 != "") print; next}
      inlist && /^[^[:space:]-]/ {inlist=0}
      /^context_file:[[:space:]]*[^"[:space:]]/ {sub(/^context_file:[[:space:]]*/,""); gsub(/"/,""); if ($0 != "") print}
    ' "$cfg" 2>/dev/null)
    if [ -n "$listed" ]; then
      printf '%s\n' "$listed"
    elif [ -f "$defs" ]; then
      # Nothing declared: the extension self-seeds from the integration recorded
      # at init time, so that is the file it will write.
      local integ
      integ=$(jqd "$root/.specify/init-options.json" '.integration' "")
      [ -n "$integ" ] || integ=$(jqd "$root/.specify/integration.json" '.integration' "")
      [ -n "$integ" ] && jq -r --arg k "$integ" '.agents[$k] // empty' "$defs" 2>/dev/null
    fi
  fi | sort -u
  return 0
}

# ------------------------------------------------------- the claude binary -----
# The engine does not assume it is driving `claude` itself. An organisation that
# blocks permission bypass may need a wrapper that answers the prompts, so the
# executable is configurable.
#
# What is checked: the command EXISTS and RUNS. What is deliberately NOT checked:
# whether it accepts each flag the engine passes. An earlier version probed that
# by passing the flag alongside --help, and it was vacuously permissive — help
# short-circuits before option validation, so a flag that cannot exist came back
# "accepted". A second probe form disagreed with the first about the same
# nonsense flag, which settles it: a check that returns different verdicts for
# the same input is worse than no check, because it is reported as a guarantee.
#
# The failure it was meant to catch is caught instead where it actually happens.
# A runner that rejects a flag exits immediately without doing any work, so the
# phase's artifact does not move and the non-run rule fails it by name — with the
# runner's own stderr preserved in .pipeline/<phase>.result.json, which says more
# than any probe would have. Detection at the point of truth, not a guess before.

probe_claude_bin() { # probe_claude_bin <bin>  -> 0 ok, 1 not on PATH, 2 unreadable
  command -v "$1" >/dev/null 2>&1 || return 1
  "$1" --help >/dev/null 2>&1 || return 2
  return 0
}

# Whether a NON-DEFAULT runner is being asked to work with no controlling
# terminal. That combination — and not the runner alone — is what kills a run.
#
# This is not the flag probe above in another costume. Flag support cannot be
# guessed; the presence of a TTY is a fact about the environment, readable with
# `[ -t 0 ]`, and the failure it predicts is fully deterministic: a pexpect-based
# wrapper calls child.interact(), which does tcgetattr on stdin, so with no
# terminal EVERY phase dies at once with the same Python traceback. Measured: a
# specify phase died before writing anything, and reported
#   termios.error: (19, 'Operation not supported by device')
# which names neither spec-run, nor the runner, nor the setting responsible.
# README documents the hazard in prose; nothing checked it.
#
# A warning rather than a refusal, because a wrapper that works headless is
# perfectly possible and this cannot tell the two apart — only that the
# combination is the known cause of the traceback that follows.
runner_needs_tty_risk() { # runner_needs_tty_risk <bin> <default_bin> -> 0 if at risk
  [ -t 0 ] && return 1                 # a terminal exists; the hazard cannot bite
  [ "$1" = "$2" ] && return 1          # the plain CLI does not need one
  return 0
}

# Does this text carry the signature of a runner that demanded a terminal?
# Matched on the failure rather than on the runner's name, so it also catches a
# wrapper nobody here has heard of.
looks_like_tty_failure() { # looks_like_tty_failure <text>
  case "$1" in
    *termios.error*|*tcgetattr*|*"Operation not supported by device"*|\
    *pexpect*|*"child.interact"*) return 0;;
    *) return 1;;
  esac
}
