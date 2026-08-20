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

# ------------------------------------------------------------- preflight ------
# Check every prerequisite BEFORE spending a phase budget. A missing dependency
# discovered three phases in has already cost real money; and a run that reaches
# a write it cannot perform pays full price for a guess.

preflight() { # preflight <repo_root>
  local root="$1" missing=0

  command -v claude >/dev/null 2>&1 || {
    err "claude CLI not on PATH"
    printf '  install: https://docs.claude.com/en/docs/claude-code\n' >&2
    missing=1
  }
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
  tmp=$(mktemp)
  jq --arg p "$2" --arg sid "$3" --arg m "$4" --arg e "$5" --arg t "$(now_iso)" \
    '.phases[$p] = ((.phases[$p] // {}) + {
        status:"running", session_id:$sid, model:$m, effort:$e,
        started_at:$t, attempts:(((.phases[$p].attempts) // 0) + 1)
     })' "$f" > "$tmp" && mv "$tmp" "$f"
}

state_phase_finish() { # ... <state_file> <phase> <status> <cost> <turns> <duration_ms> <artifact_sha> <note>
  local f="$1" tmp
  tmp=$(mktemp)
  jq --arg p "$2" --arg s "$3" --arg c "$4" --arg n "$5" --arg d "$6" \
     --arg sha "$7" --arg note "$8" --arg t "$(now_iso)" \
    '.phases[$p] += {
        status:$s, cost_usd:($c|tonumber? // 0), num_turns:($n|tonumber? // 0),
        duration_ms:($d|tonumber? // 0), artifact_sha:$sha, note:$note,
        finished_at:$t
     }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# An absent figure states its reason. "$0.00" and "nobody measured it" are
# different facts and only one of them is good news.
fmt_cost() { [ -n "${1:-}" ] && printf '$%s' "$1" || printf 'cost unmeasured'; }

state_total_cost() { jq '[.phases[].cost_usd // 0] | add // 0' "$1"; }
