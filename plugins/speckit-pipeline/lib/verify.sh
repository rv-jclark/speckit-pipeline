#!/usr/bin/env bash
# Artifact verification. Sourced by bin/spec-run.
#
# The phase process reports its own outcome, and that report is NOT the authority.
# A process can exit 0 without having done the thing; a model can narrate success
# it did not achieve. So every phase is judged by the state of the file it exists
# to produce, read off disk after the process is gone.
#
# Each verifier prints "<status>\t<note>" and always exits 0.
#   ok           the artifact is present and coherent — advance
#   needs_input  the artifact exists but records an open question — stop, ask
#   failed       the artifact is absent or unusably thin — stop
#   unevaluated  the phase declares no artifact. NOT a pass. A check that never
#                ran and a check that passed are the pair this tool separates.

# This file needs file_sha() from common.sh. Declare the dependency loudly: with
# it absent, every hash compares empty-against-empty, the scope check reports the
# whole dirty tree, and two of this project's own tests passed on that — a check
# that cannot compute its comparison must fail, not accuse.
if ! declare -F file_sha >/dev/null 2>&1; then
  printf 'verify.sh: file_sha() is unavailable — source lib/common.sh first\n' >&2
  return 1 2>/dev/null || exit 1
fi

MIN_ARTIFACT_BYTES=${MIN_ARTIFACT_BYTES:-400}

_bytes() { [ -f "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }

_clarification_markers() { # count unresolved template markers
  local n
  [ -f "$1" ] || { echo 0; return; }
  # The BRACKETED form only. spec-kit writes a real marker as
  # `[NEEDS CLARIFICATION: what is unclear]`, and matching the bare phrase is
  # defeated by prose ABOUT the phrase — which is not hypothetical: a real plan
  # wrote "Every \"NEEDS CLARIFICATION\" candidate was resolved by reading the
  # tree" above a table of resolutions, and the pipeline stopped the roadmap for
  # a question that did not exist. A guard whose target phrase can appear in a
  # sentence saying the target is absent has to match the SYNTAX, not the words.
  #
  # grep -c PRINTS 0 and EXITS 1 when there is no match, so `|| echo 0` emits
  # two lines and every later integer test on it errors out — while still
  # reaching the right branch, which is how that survived a passing suite too.
  n=$(grep -cE '\[NEEDS CLARIFICATION' "$1" 2>/dev/null || true)
  printf '%s\n' "${n:-0}"
}

_template_placeholders() { # count UNFILLED template placeholders
  local n
  [ -f "$1" ] || { echo 0; return; }
  # Precision over recall, deliberately. The vendored templates carry dozens of
  # lowercase placeholders (`[name]`, `[endpoint]`, `[action]`) that a filled
  # document may legitimately still contain in a table or an example, and
  # `[US1]` is ordinary prose in a real tasks.md. These three cannot survive a
  # genuine fill: they are the title, the date, and an instruction addressed to
  # the author. Derived from assets/specify/templates/, not invented.
  #
  # Measured: a plan phase that ran out of turns left plan.md as the untouched
  # template — `# Implementation Plan: [FEATURE]` over three `[REMOVE IF UNUSED]`
  # option blocks — and it verified `ok` at 3,779 bytes with no open markers,
  # because a template is comfortably over the size floor and asks no questions.
  n=$(grep -cE '\[REMOVE IF UNUSED\]|\[FEATURE( NAME)?\]|\[DATE\]' "$1" 2>/dev/null || true)
  printf '%s\n' "${n:-0}"
}

_task_counts() { # prints "<unchecked> <total>"
  local f="$1" unchecked total
  [ -f "$f" ] || { echo "0 0"; return; }
  unchecked=$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' "$f" 2>/dev/null || true)
  total=$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[[[:space:]xX]\]' "$f" 2>/dev/null || true)
  echo "${unchecked:-0} ${total:-0}"
}

verify_phase() { # verify_phase <phase_id> <feature_dir> <artifact_rel|""> [chunked]
  local phase="$1" fdir="$2" rel="$3" chunked="${4:-false}"
  local path="" markers bytes counts unchecked total

  if [ -z "$rel" ] || [ "$rel" = "null" ]; then
    printf 'unevaluated\tphase declares no artifact; nothing was checked\n'
    return 0
  fi
  path="$fdir/$rel"

  if [ ! -f "$path" ]; then
    printf 'failed\t%s was not created\n' "$rel"
    return 0
  fi

  bytes=$(_bytes "$path")
  if [ "$bytes" -lt "$MIN_ARTIFACT_BYTES" ]; then
    printf 'failed\t%s is only %s bytes (min %s) — the phase did not finish writing it\n' \
      "$rel" "$bytes" "$MIN_ARTIFACT_BYTES"
    return 0
  fi

  # Before any per-phase judgement: an artifact that is still (partly) the
  # template was never written, however large it is and whatever phase produced
  # it. Checked here rather than per-branch so tasks.md gets the same guarantee
  # as plan.md.
  local placeholders
  placeholders=$(_template_placeholders "$path")
  if [ "$placeholders" -gt 0 ]; then
    printf 'failed\t%s is still the TEMPLATE — %s unfilled placeholder(s) (%s bytes); the phase did not write it\n' \
      "$rel" "$placeholders" "$bytes"
    return 0
  fi

  case "$phase" in
    specify|clarify|plan)
      markers=$(_clarification_markers "$path")
      if [ "$markers" -gt 0 ]; then
        printf 'needs_input\t%s carries %s unresolved [NEEDS CLARIFICATION] marker(s)\n' \
          "$rel" "$markers"
        return 0
      fi
      printf 'ok\t%s written, %s bytes, no open markers\n' "$rel" "$bytes"
      ;;

    tasks)
      counts=$(_task_counts "$path"); unchecked=${counts% *}; total=${counts#* }
      if [ "$total" -eq 0 ]; then
        printf 'failed\t%s contains no task checkboxes — generation produced no work list\n' "$rel"
        return 0
      fi
      printf 'ok\t%s written with %s task(s)\n' "$rel" "$total"
      ;;

    implement)
      counts=$(_task_counts "$path"); unchecked=${counts% *}; total=${counts#* }
      if [ "$total" -eq 0 ]; then
        printf 'failed\t%s has no checkboxes to complete\n' "$rel"
        return 0
      fi
      if [ "$unchecked" -gt 0 ]; then
        # A CHUNKED pass is supposed to leave work behind — it does one group and
        # stops, and the loop in spec-run decides when the list is clear. Gating
        # here would end that loop on its first pass, which is exactly what
        # happened before this branch existed: pass 1 ticked a task, verification
        # called the leftovers `needs_input`, and the run stopped at a gate having
        # done a third of the work. Progress is the loop's business; this only
        # reports what remains.
        if [ "$chunked" = true ]; then
          printf 'ok\tpass done — %s of %s task(s) left for the next pass\n' \
            "$unchecked" "$total"
          return 0
        fi
        printf 'needs_input\t%s of %s task(s) still unchecked in %s\n' \
          "$unchecked" "$total" "$rel"
        return 0
      fi
      printf 'ok\tall %s task(s) checked off\n' "$total"
      ;;

    *)
      printf 'ok\t%s present, %s bytes (no phase-specific rule)\n' "$rel" "$bytes"
      ;;
  esac
  return 0
}

# ------------------------------------------------------------ scope check -----
# A non-implement phase has no business editing source. Rather than bet on a
# path-scoped tool deny, the escape is DETECTED: whatever the phase touched is
# compared against its declared scope once the process has exited. Paired with
# the Bash deny list (no push, no merge, no deploy), a stray write cannot reach
# anything irreversible — it is reported, and the run stops.
#
# The comparison is against the tree AS IT WAS WHEN THE PHASE STARTED, never
# against a clean tree. The working tree is the user's: a dirty file that was
# already there is not this phase's doing, and reporting it as a violation is
# both wrong and the kind of wrong that trains people to pass --gate none.
# Measured on the first real run: comparing against clean attributed 14
# freshly-bootstrapped skill files and the caller's own log to the phase, and
# failed a specify that had in fact done everything right.

_out_of_scope_dirty() { # <root> <prefix...>  -> prints out-of-scope dirty paths
  local root="$1"; shift
  local -a prefixes=("$@")
  local line p path in_scope

  # -uall so an untracked new file counts; a phase that writes source outside
  # its scope usually creates rather than modifies.
  git -C "$root" status --porcelain -uall 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] || continue
    path=${line:3}
    # rename/copy entries read "old -> new"; judge the destination
    case "$path" in *" -> "*) path=${path##* -> };; esac
    path=${path%\"}; path=${path#\"}
    in_scope=0
    for p in "${prefixes[@]}"; do
      case "$path" in "$p"*) in_scope=1; break;; esac
    done
    [ "$in_scope" -eq 0 ] && printf '%s\n' "$path"
  done
  return 0
}

# Snapshot the out-of-scope dirty paths and their contents, so that a file which
# was ALREADY dirty and is then changed again is still attributable. The
# candidate set is only the out-of-scope dirty paths, so hashing them is cheap.
scope_snapshot() { # scope_snapshot <root> <outfile> <prefix...>
  local root="$1" out="$2"; shift 2
  : > "$out"
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s\t%s\n' "$(file_sha "$root/$path")" "$path" >> "$out"
  done < <(_out_of_scope_dirty "$root" "$@")
  return 0
}

# Paths that are newly out-of-scope-dirty, or whose contents changed, since the
# snapshot. A path present in the snapshot and unchanged is somebody else's.
scope_violations_since() { # scope_violations_since <root> <snapshot> <prefix...>
  local root="$1" snap="$2"; shift 2
  local path before after
  {
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      after=$(file_sha "$root/$path")
      before=$(awk -F'\t' -v p="$path" '$2==p {print $1; exit}' "$snap" 2>/dev/null)
      if [ -z "$before" ] || [ "$before" != "$after" ]; then
        printf '%s\n' "$path"
      fi
    done < <(_out_of_scope_dirty "$root" "$@")

    # A path the phase DELETED leaves the dirty list entirely if it was already
    # untracked, so check the snapshot's own paths for disappearance.
    while IFS=$'\t' read -r before path; do
      [ -n "$path" ] || continue
      after=$(file_sha "$root/$path")
      [ "$after" = "$before" ] || printf '%s\n' "$path"
    done < "$snap"
  } | sort -u
  return 0
}
