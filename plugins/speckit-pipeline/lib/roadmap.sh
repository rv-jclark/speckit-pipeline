#!/usr/bin/env bash
# Roadmap helpers: the file format, the run state, and — the load-bearing part —
# deciding whether an entry has actually landed on the base branch.
#
# Sourced by bin/spec-roadmap. Needs lib/common.sh.

if ! declare -F die >/dev/null 2>&1; then
  printf 'roadmap.sh: needs lib/common.sh sourced first\n' >&2
  return 1 2>/dev/null || exit 1
fi

# The complete entry-status vocabulary. Anything outside it is a bug, and the
# test suite asserts this list against every status the code can write — a
# vocabulary nobody checks is how a sixth state appears and no reader handles it.
ROADMAP_STATUSES="pending in_progress awaiting_merge done blocked"
export ROADMAP_STATUSES

# ------------------------------------------------------- the base branch ------
# `origin/main` is a guess, and it is wrong for a repository whose default is
# master, one with no remote at all, and one whose remote is not called origin.
# Guessing wrong here does not fail cleanly: the base ref does not resolve, every
# entry reports `unknown`, and the roadmap refuses to move with a message about
# fetching. So the base is DETECTED, and the answer says how it was reached —
# "you asked for this" and "I picked it" are different facts, and only the second
# is worth double-checking.
detect_base() { # detect_base <repo>  -> prints "<ref>\t<how>"
  local repo="$1" head remote ref
  head=$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$head" ]; then
    printf '%s\torigin/HEAD points at it\n' "${head#refs/remotes/}"; return 0
  fi
  for remote in $(git -C "$repo" remote 2>/dev/null); do
    for ref in main master trunk; do
      if git -C "$repo" rev-parse --verify --quiet "$remote/$ref" >/dev/null 2>&1; then
        printf '%s/%s\tthe only matching branch on remote %s\n' "$remote" "$ref" "$remote"; return 0
      fi
    done
  done
  for ref in main master trunk; do
    if git -C "$repo" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
      printf '%s\ta local branch (this repository has no matching remote)\n' "$ref"; return 0
    fi
  done
  ref=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -n "$ref" ] && [ "$ref" != HEAD ]; then
    printf '%s\tthe current branch, for want of anything better — check this\n' "$ref"; return 0
  fi
  printf '\tno branch could be identified\n'; return 1
}

# A slug is interpolated into a file path, so it may not BE a path. `--slug
# ../../etc/passwd` resolved to .specify/roadmaps/../../etc/passwd.json, which is
# sloppy rather than dangerous — the caller already owns the machine — but a name
# that escapes its directory is never what anyone meant, and the auto-derived
# form is already restricted to this same character set.
valid_slug() { # valid_slug <slug>
  case "$1" in
    ""|*/*|*..*) return 1;;
    *) case "$1" in
         [a-z0-9]*) printf '%s' "$1" | grep -qE '^[a-z0-9][a-z0-9._-]*$' && return 0 || return 1;;
         *) return 1;;
       esac;;
  esac
}

roadmap_dir()  { printf '%s/.specify/roadmaps\n' "$1"; }
roadmap_file() { printf '%s/.specify/roadmaps/%s.json\n' "$1" "$2"; }
roadmap_state(){ printf '%s/.specify/roadmaps/%s.state.json\n' "$1" "$2"; }

# ------------------------------------------------------------- the file -------
# One authored file per roadmap. The prose lives INSIDE the entries rather than
# in a companion markdown doc: two stores for one fact always drift, and a
# roadmap whose doc and machine-readable form disagree is worse than either.
# `spec-roadmap show` is how you read it.

roadmap_validate() { # roadmap_validate <file>  -> prints reason and returns 1 on failure
  local f="$1"
  [ -f "$f" ] || { printf 'no such roadmap file: %s\n' "$f"; return 1; }
  jq -e . "$f" >/dev/null 2>&1 || { printf 'not valid JSON: %s\n' "$f"; return 1; }

  # An ARRAY, specifically. `jq '.entries | length'` counts an object's keys too,
  # so an object here validated cleanly and then failed at run time: the runner
  # reads `.entries[$i]` by index, which is null for an object. Order is the whole
  # point of a roadmap, and an object does not have one.
  if ! jq -e '(.entries | type) == "array"' "$f" >/dev/null 2>&1; then
    printf 'entries must be a JSON array (it is %s) — a roadmap is ordered, and an object is not\n' \
      "$(jq -r '.entries | type' "$f" 2>/dev/null || echo missing)"
    return 1
  fi

  local n
  n=$(jq -r '(.entries // []) | length' "$f")
  if [ "${n:-0}" -lt 1 ]; then
    printf 'roadmap has no entries — a roadmap with nothing in it is not a roadmap\n'; return 1
  fi

  # Every entry needs a slug and a description: the slug names the branch, the
  # description IS the feature description handed to the specify phase. An entry
  # missing either cannot be run, and finding that out three entries in is the
  # expensive way.
  local bad
  bad=$(jq -r '[ (.entries // []) | to_entries[]
                 | select((.value.slug // "") == "" or (.value.description // "") == "")
                 | (.key + 1 | tostring) ] | join(", ")' "$f")
  if [ -n "$bad" ]; then
    printf 'entries missing a slug or description (1-indexed): %s\n' "$bad"; return 1
  fi

  local dupes
  dupes=$(jq -r '[(.entries // [])[].slug] | group_by(.) | map(select(length>1) | .[0]) | join(", ")' "$f")
  if [ -n "$dupes" ]; then
    printf 'duplicate slugs: %s — each entry becomes its own feature branch\n' "$dupes"; return 1
  fi
  return 0
}

# ----------------------------------------------------------- source doc -------
# The design document the entries were transcribed from, when `plan --from-doc`
# wrote one (or an author added it by hand).
#
# This is a pointer, but a LOAD-BEARING one, and it is deliberately not part of
# roadmap_validate. Every description that --from-doc produces instructs its
# phase to read this file before specifying — that instruction is the only reason
# any phase sees the document at all, because nothing here passes it. So a path
# that no longer resolves silently strips the grounding from every entry while
# each phase still reports success, which is the worst shape a broken link can
# take. Surfaced by `show`, and warned about before a `run`.
#
# A warning and not a refusal: the transcription contract requires each
# description to stand on its own ("inline the substance and point at the
# document for the rest"), so a missing document degrades an entry rather than
# breaking it — and refusing would wedge a roadmap over a document someone
# deliberately retired after its entries were written.
roadmap_source_doc() { # <roadmap_file>  -> repo-relative path, or nothing
  jq -r '.source_doc // empty' "$1" 2>/dev/null
}

# ------------------------------------------------------------- run state ------
# Definition and progress are separate files on purpose: the roadmap is authored,
# the state is generated. The same split as spec.md versus .pipeline/state.json.

roadmap_state_init() { # <state_file> <roadmap_file> <slug> <base>
  local f="$1"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] && return 0
  jq -n --arg rm "$2" --arg slug "$3" --arg base "$4" --arg t "$(now_iso)" \
    '{version:1, roadmap:$rm, slug:$slug, base:$base, created_at:$t, entries:{}}' > "$f"
}

roadmap_entry_get() { # <state_file> <slug> <field> <default>
  jqd "$1" ".entries[\"$2\"].$3" "$4"
}

roadmap_entry_set() { # <state_file> <slug> <json_object_of_fields>
  local f="$1" tmp; tmp=$(mktmp)
  jq --arg s "$2" --argjson patch "$3" --arg t "$(now_iso)" \
    '.entries[$s] = ((.entries[$s] // {}) + $patch + {updated_at:$t})' "$f" > "$tmp" && mv "$tmp" "$f"
}

# ------------------------------------------------------- has it landed? -------
# The whole merge gate rests on this, so it is worth being exact about.
#
# `git merge-base --is-ancestor <branch> <base>` is the obvious check and it is
# WRONG on its own: a squash merge replays the branch as one new commit, so the
# branch's own commits never become ancestors of the base. Measured on a real
# repository — a spec that shipped in a merged pull request reported
# `ancestor: NO` while every one of its artifacts was present on main. Relying on
# the ancestor check alone would wedge every roadmap in a squash-merging repo
# permanently, at the first entry.
#
# The squash-proof question is whether the entry's WORK is on the base branch,
# which is also the question the next entry actually cares about. So: ancestry if
# it is there, artifact presence otherwise, and the answer says which one
# replied — "merged" reached two different ways have different confidence, and a
# reader deserves to know which.

roadmap_fetch_base() { # roadmap_fetch_base <repo> <base>  -> 0 fresh, 1 stale
  local repo="$1" base="$2" remote
  case "$base" in
    */*) remote=${base%%/*};;
    *)   return 0;;    # a local ref needs no fetch
  esac
  git -C "$repo" fetch --quiet "$remote" 2>/dev/null && return 0
  return 1
}

# entry_landed <repo> <base> <feature_dir_rel> <branch> <fresh:0|1>
# What description does a feature directory's own pipeline state record?
#
# 🛑 This exists because the obvious test — "is the directory named NNN-<slug>?"
# — IS WRONG, and the roadmap's own production data says so. spec-run is invoked
# with the entry's DESCRIPTION, not its slug, and spec-kit derives the branch and
# directory name from that description through a sanitiser that replaces every
# non-alphanumeric with a dash. The two coincide often enough to look like a
# rule and are not one. Measured across one real 9-entry roadmap:
#
#   mastery-rule             → specs/012-mastery-rule              matches
#   contacts-job-attribution → specs/013-contact-network            DIFFERS
#   gear-and-stash           → specs/017-loot-gear-v1               DIFFERS
#   perk-milestones          → specs/018-skill-perks                DIFFERS
#
# Three of nine. Rejecting a directory on a slug mismatch would therefore have
# discarded a third of that roadmap's legitimate feature directories. (The same
# caveat applies to the slug fallback in entry_landed below: it is best-effort
# and fails safe by finding nothing, which is why it is sound there and would not
# have been here.)
#
# The description is convention-free: spec-run writes it into state.json at
# init, so it is what the directory itself says it was created for.
# Prints the recorded description, or nothing when there is no state to read —
# and the caller must treat "nothing" as unknown, never as a mismatch.
feature_dir_description() { # feature_dir_description <repo> <feature_dir_rel>
  local st="$1/${2:-}/.pipeline/state.json"
  [ -f "$st" ] || return 0
  jq -r '.description // empty' "$st" 2>/dev/null || true
}

#   prints "<state>\t<how>", always exits 0
#     done       the work is on the base branch
#     not_landed it is not, and we could see clearly enough to say so
#     unknown    the question could not be answered — NOT a synonym for "no"
entry_landed() {
  local repo="$1" base="$2" fdir="$3" branch="$4" fresh="$5" slug="${6:-}"

  if ! git -C "$repo" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
    printf 'unknown\tthe base ref %s does not exist in this repository\n' "$base"; return 0
  fi

  # Ancestry is only evidence if the branch HAS commits of its own. spec-kit's
  # auto-commit hook is optional and routinely declined, so a feature branch
  # often sits at exactly the base commit with all its work uncommitted — and
  # `merge-base --is-ancestor` is then trivially TRUE. Measured: an entry that
  # had never been merged reported "landed", the gate opened, and the roadmap
  # would have marched through every remaining entry without a single merge.
  # That is worse than the squash problem: it does not stall, it lies.
  if [ -n "$branch" ] && git -C "$repo" rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
    local own
    own=$(git -C "$repo" rev-list --count "$base..$branch" 2>/dev/null || echo 0)
    if [ "${own:-0}" -gt 0 ] && git -C "$repo" merge-base --is-ancestor "$branch" "$base" 2>/dev/null; then
      printf 'done\t%s is an ancestor of %s, with %s commit(s) of its own\n' "$branch" "$base" "$own"
      return 0
    fi
  fi

  # Squash-safe: is the entry's own work present on the base branch? tasks.md is
  # the last artifact the pipeline writes, so its presence means the whole spec
  # landed rather than a partial merge.
  if [ -n "$fdir" ] && git -C "$repo" cat-file -e "$base:$fdir/tasks.md" 2>/dev/null; then
    printf 'done\t%s/tasks.md is present on %s (squash-merged, so not an ancestor)\n' "$fdir" "$base"
    return 0
  fi

  # 🛑 The state file is not the only place that knows where an entry's work is —
  # git does too, and git is the thing that cannot be reset by a stray `git stash`.
  # `feature_dir` is load-bearing for the check above, and it lives ONLY in
  # .specify/roadmaps/<slug>.state.json. Measured: hand-picking a landing set
  # dropped the pipeline's own state commit, the field went missing, a COMPLETED
  # entry read as pending, and the next run started specify again from scratch —
  # caught 30 seconds in, but it was on course to re-spend a full pipeline. The
  # failure mode of losing this field is paying for finished work twice, which is
  # the most expensive way for state loss to surface.
  #
  # So: derive it. spec-kit names feature directories `NNN-<slug>` and the roadmap
  # entry knows its slug, so the answer is already committed on the base ref.
  if [ -z "$fdir" ] && [ -n "$slug" ]; then
    local name derived=""
    while IFS= read -r name; do
      name=${name%/}
      [ -n "$name" ] || continue
      # Strip the numeric prefix at the FIRST dash only — a slug may contain
      # dashes itself (`board-ui`, `cutover-backfill-v1-retirement`), so this is a
      # string comparison rather than a pattern, and needs no escaping.
      case "$name" in
        [0-9]*-*) [ "${name#*-}" = "$slug" ] && { derived="$name"; break; };;
      esac
    done <<EOF
$(git -C "$repo" ls-tree --name-only "$base:specs" 2>/dev/null)
EOF
    if [ -n "$derived" ] && git -C "$repo" cat-file -e "$base:specs/$derived/tasks.md" 2>/dev/null; then
      printf 'done\tspecs/%s/tasks.md is present on %s — found by slug, because no feature_dir was recorded\n' \
        "$derived" "$base"
      return 0
    fi
  fi

  # Only now does "no" become sayable — and only if the ref is fresh. A stale ref
  # cannot distinguish "not merged yet" from "merged since I last looked", and
  # the asymmetry matters: a stale ref that says MERGED is still trustworthy,
  # because merging does not un-happen.
  if [ "$fresh" -ne 0 ]; then
    printf 'unknown\tcould not fetch %s, and a stale ref cannot tell "not merged yet" from "merged since I last looked"\n' "$base"
    return 0
  fi

  if [ -z "$branch" ] && [ -z "$fdir" ]; then
    printf 'unknown\tno branch or feature directory recorded for this entry yet\n'; return 0
  fi
  printf 'not_landed\tneither %s nor %s is on %s\n' "${branch:-its branch}" "${fdir:-its artifacts}" "$base"
  return 0
}

# ----------------------------------------------------------- tree safety ------
# The runner switches branches between entries, so it must not do that over
# somebody's uncommitted work — and it must not refuse over its own.
#
# Two corrections are baked in here. First, `git status --porcelain` non-empty is
# the WRONG test: `spec-roadmap plan` writes the roadmap file into the repository,
# so the first `run` after it saw a dirty tree and refused. The tool dirtied the
# tree and then blocked on it, which would have stopped every roadmap at entry
# one. Second, and more generally: UNTRACKED files are safe to switch branches
# over. Git carries them across a checkout and refuses outright if one would be
# clobbered. What actually blocks or loses work is a TRACKED modification.
#
# So tracked changes refuse, untracked ones warn, and the tool's own bookkeeping
# is silent.

# Paths that are this tool's own generated state, not anybody's work.
_is_tool_bookkeeping() {
  case "$1" in
    .specify/roadmaps/*|specs/*/.pipeline/*|.specify/feature.json) return 0;;
    *) return 1;;
  esac
}

# tracked_changes <repo>  -> prints "XY path" lines for tracked modifications
tracked_changes() {
  local line path
  git -C "$1" status --porcelain 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in '??'*) continue;; esac      # untracked handled separately
    path=${line:3}
    case "$path" in *" -> "*) path=${path##* -> };; esac
    path=${path%\"}; path=${path#\"}
    _is_tool_bookkeeping "$path" && continue
    printf '%s\n' "$line"
  done
  return 0
}

# untracked_files <repo>  -> prints untracked paths that are not our bookkeeping
untracked_files() {
  local line path
  git -C "$1" status --porcelain -uall 2>/dev/null | while IFS= read -r line; do
    case "$line" in '??'*) ;; *) continue;; esac
    path=${line:3}
    path=${path%\"}; path=${path#\"}
    _is_tool_bookkeeping "$path" && continue
    printf '%s\n' "$path"
  done
  return 0
}

# ---------------------------------------------------------------- spend ---------
roadmap_spent() { # <repo> <state_file> — total spent across the roadmap
  # An entry's own `cost_usd` is only written when the entry finishes, so an
  # IN-PROGRESS entry contributes a value that stops moving after its first
  # phase. Measured on a live run: the entry read $3.71 (specify alone) while its
  # phases summed to $10.40 — so a ceiling checked against the recorded figure is
  # optimistic by however much the current entry has spent since. Prefer the live
  # per-phase sum whenever the pipeline state is still on disk, and fall back to
  # the recorded value for entries whose feature directory is gone.
  local repo="$1" st="$2" slug fdir rec live total=0
  # 🛑 NOT tab-delimited. Tab is IFS *whitespace*, so bash collapses a RUN of
  # tabs — an entry with no `feature_dir` emits "one\t\t9.5", the empty middle
  # field vanishes, and the fields shift left: fdir="9.5", rec="". Measured: a
  # $9.50 entry then priced itself at $0 and five budget assertions went green
  # on a ceiling that could never be reached. The unit separator is not IFS
  # whitespace, so empty fields survive.
  while IFS=$'\037' read -r slug fdir rec; do
    [ -n "$slug" ] || continue
    live=""
    if [ -n "$fdir" ] && [ -f "$repo/$fdir/.pipeline/state.json" ]; then
      # 🛑 A state file that EXISTS but records no cost is not a spend of $0.
      # Every phase run by a stub (or killed before its result event) carries
      # `cost_usd: null`, so summing with `// 0` returns a confident 0 that then
      # beats the recorded figure — measured: five budget assertions went green
      # on a ceiling that could never be reached, because a $9.50 entry priced
      # itself at nothing. Unmeasured and zero are different states, and only
      # the second one is a number.
      live=$(jq -r 'if ([.phases[]? | select(.cost_usd != null)] | length) == 0
                    then "" else ([.phases[].cost_usd // 0] | add) end' \
             "$repo/$fdir/.pipeline/state.json" 2>/dev/null) || live=""
    fi
    total=$(awk -v t="$total" -v l="${live:-}" -v r="${rec:-0}" \
      'BEGIN{ v = (l == "" ? r : l); printf "%.6f", t + v }')
  done <<EOF
$(jq -r '.entries | to_entries[]
         | [.key, (.value.feature_dir // ""), ((.value.cost_usd // 0)|tostring)]
         | join("\u001f")' "$st" 2>/dev/null)
EOF
  # Trim the trailing zeroes printf leaves, so the figure reads like money.
  awk -v t="$total" 'BEGIN{ printf "%g", t }'
}

# ------------------------------------------------------------- auto-merge ------
# The merge gate, taken by the ENGINE rather than by whoever is watching it.
#
# Why here and not in prose: a roadmap only works if entry N+1 is cut from a base
# that already holds entry N, so every entry used to stop for a human merge — and
# the agent supervising the run, told "do not merge anything", correctly refused
# to be that human. Deleting the sentence would have left the merge to that
# agent's judgement, in a ~900k-token window, with no fixed conditions: the
# failure the gate was written against (an agent told in prose to stop merged
# two pull requests and deployed them). So the conditions live in code, and the
# phases and the supervising agent still have no merge of their own.
#
# It merges only when BOTH hold, and otherwise stops at the gate exactly as the
# manual flow did, saying which one failed:
#   * review.md passed verification — the review phase ran, cited code, and left
#     no unresolved BLOCKER or MAJOR finding (verify.sh decides, not the phase);
#   * every check on the pull request finished green. A PR with NO checks is not
#     green: "CI passed" cannot be established, so it stops.
# It never passes --admin, so branch protection that wants a human approval
# still wants one, and gh's refusal is reported as the reason.
#
# Sets AUTO_MERGE_WHY to the reason whenever it declines. Returns 0 when the PR
# is merged (or was already), 2 when it stopped at the gate.
#
# Timings are overridable for the test suite; the defaults are for real CI.
AUTO_MERGE_WHY=""
AUTO_MERGE_PR=""
: "${SPEC_ROADMAP_CHECKS_POLL:=30}"      # seconds between looks at the checks
: "${SPEC_ROADMAP_CHECKS_GRACE:=180}"    # how long "no checks yet" may last
: "${SPEC_ROADMAP_CHECKS_TIMEOUT:=3600}" # how long checks may stay pending

_am_decline() { AUTO_MERGE_WHY="$1"; return 2; }

# Every path the entry changed, tracked or new, minus our own bookkeeping.
_am_changed_paths() { # <repo>
  local l p
  {
    tracked_changes "$1" | while IFS= read -r l; do
      p=${l:3}
      case "$p" in (*" -> "*) p=${p##* -> };; esac
      p=${p%\"}; p=${p#\"}
      printf '%s\n' "$p"
    done
    untracked_files "$1"
  } | sort -u
}

# auto_merge_remote <repo> <base>  -> prints "<remote>\t<branch>", or nothing
auto_merge_remote() {
  local repo="$1" base="$2"
  case "$base" in
    */*) git -C "$repo" remote 2>/dev/null | grep -qx "${base%%/*}" && \
           printf '%s\t%s\n' "${base%%/*}" "${base#*/}"; return 0;;
  esac
  git -C "$repo" remote 2>/dev/null | grep -qx origin && printf 'origin\t%s\n' "$base"
  return 0
}

# auto_merge_entry <repo> <base> <feature_dir_rel> <branch> <slug> <title>
auto_merge_entry() {
  local repo="$1" base="$2" fdir="$3" branch="$4" slug="$5" title="$6"
  local st review remote base_branch info method out n paths
  # shellcheck disable=SC2034 # read by bin/spec-roadmap
  AUTO_MERGE_WHY=""; AUTO_MERGE_PR=""

  # 1. The review. Checked first because it costs nothing and needs no network.
  st="$repo/$fdir/.pipeline/state.json"
  review=$(jq -r '.phases.review.status // "absent"' "$st" 2>/dev/null) || review=absent
  case "$review" in
    ok) ;;
    absent) _am_decline "the review phase has not run for this entry"; return 2;;
    needs_input) _am_decline "review.md has unresolved BLOCKER or MAJOR findings"; return 2;;
    *) _am_decline "the review phase did not pass (status: $review)"; return 2;;
  esac

  # 2. Everything that can refuse WITHOUT changing anything, before the commit:
  #    a declined merge must leave the tree exactly as the pipeline left it.
  [ -n "$branch" ] && [ "$branch" != HEAD ] || { _am_decline "the entry has no branch recorded"; return 2; }
  IFS=$'\t' read -r remote base_branch < <(auto_merge_remote "$repo" "$base")
  [ -n "$remote" ] || { _am_decline "no git remote to push $branch to"; return 2; }
  [ "$branch" != "$base_branch" ] || { _am_decline "the entry is on $base_branch itself, not a branch of its own"; return 2; }
  command -v gh >/dev/null 2>&1 || { _am_decline "the GitHub CLI (gh) is not installed"; return 2; }
  info=$(cd "$repo" && gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed 2>&1) || {
    _am_decline "gh cannot read this repository: $(printf '%s' "$info" | head -1)"; return 2; }
  method=$(jq -r 'if .squashMergeAllowed then "squash" elif .mergeCommitAllowed then "merge"
                  elif .rebaseMergeAllowed then "rebase" else "" end' <<<"$info" 2>/dev/null)
  [ -n "$method" ] || { _am_decline "the repository allows no merge method gh can use"; return 2; }

  # 3. Commit what the pipeline left uncommitted. Implement commits only
  #    sometimes, so without this nearly every entry would reach the push with
  #    its work still in the tree. Our own bookkeeping (.pipeline/, roadmap
  #    state, feature.json) is never swept in — it changes after this commit.
  paths=$(_am_changed_paths "$repo")
  if [ -n "$paths" ]; then
    n=$(printf '%s\n' "$paths" | grep -c .)
    # shellcheck disable=SC2086 # one path per line; word-splitting is wanted, globbing is not
    ( set -f; IFS=$'\n'; git -C "$repo" add -A -- $paths ) >/dev/null 2>&1 &&
    git -C "$repo" commit -q -m "feat($slug): ${title:-$slug}" \
        -m "Committed by spec-roadmap auto-merge: the pipeline's uncommitted output ($n path(s))." \
        >/dev/null 2>&1 || { _am_decline "could not commit the entry's $n uncommitted path(s)"; return 2; }
    say "    committed $n path(s) the pipeline left uncommitted"
    printf '%s\n' "$paths" | head -8 | sed 's/^/      /'
    [ "$n" -gt 8 ] && dim "      … and $((n - 8)) more"
  fi

  # 4. Push. Never forced: a rejected push means the remote branch has work this
  #    one does not, and that is for a human to reconcile.
  out=$(git -C "$repo" push --quiet -u "$remote" "$branch" 2>&1) || {
    _am_decline "git push was refused: $(printf '%s' "$out" | tail -1)"; return 2; }

  # 5. The PR — reusing one a phase or a human already opened.
  n=$(cd "$repo" && gh pr list --head "$branch" --base "$base_branch" --state open \
        --json number --jq '.[0].number // empty' 2>/dev/null)
  if [ -z "$n" ]; then
    if [ -n "$(cd "$repo" && gh pr list --head "$branch" --base "$base_branch" --state merged \
                 --json number --jq '.[0].number // empty' 2>/dev/null)" ]; then
      say "    its pull request is already merged"
      return 0
    fi
    out=$(cd "$repo" && gh pr create --base "$base_branch" --head "$branch" \
            --title "${title:-$slug}" \
            --body "Roadmap entry \`$slug\`, built by spec-roadmap.

- spec: \`$fdir/spec.md\`
- review: \`$fdir/review.md\` (passed: no unresolved BLOCKER or MAJOR findings)

Merged automatically once every check is green (\`--no-auto-merge\` turns this off)." 2>&1) || {
      _am_decline "gh pr create failed: $(printf '%s' "$out" | tail -1)"; return 2; }
    n=$(printf '%s' "$out" | grep -oE '/pull/[0-9]+' | tail -1 | tr -dc 0-9)
    [ -n "$n" ] || { _am_decline "gh pr create did not report a pull request number"; return 2; }
    say "    opened pull request #$n"
  else
    say "    reusing its pull request #$n"
  fi
  # shellcheck disable=SC2034 # read by bin/spec-roadmap
  AUTO_MERGE_PR="$n"
  say "    waiting for the checks on #$n"

  # 6. CI. Polled rather than `--watch`ed so "no checks at all" and "checks not
  #    registered yet" can be told apart: a fresh push often has none for a
  #    minute, and a repo without CI has none forever.
  local waited=0 checks pending failed total
  while :; do
    checks=$(cd "$repo" && gh pr checks "$n" --json name,bucket 2>/dev/null) || true
    total=$(jq -r 'length' <<<"${checks:-[]}" 2>/dev/null) || total=0
    if [ "${total:-0}" -eq 0 ]; then
      if [ "$waited" -ge "$SPEC_ROADMAP_CHECKS_GRACE" ]; then
        _am_decline "pull request #$n has no CI checks, so CI green cannot be established"; return 2
      fi
    else
      failed=$(jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(", ")' <<<"$checks")
      [ -z "$failed" ] || { _am_decline "checks failed on pull request #$n: $failed"; return 2; }
      pending=$(jq -r '[.[] | select(.bucket == "pending")] | length' <<<"$checks")
      [ "${pending:-0}" -eq 0 ] && break
      if [ "$waited" -ge "$SPEC_ROADMAP_CHECKS_TIMEOUT" ]; then
        _am_decline "checks on pull request #$n were still pending after ${waited}s"; return 2
      fi
    fi
    sleep "$SPEC_ROADMAP_CHECKS_POLL"
    waited=$((waited + SPEC_ROADMAP_CHECKS_POLL))
  done
  say "    all $total check(s) green"

  # 7. Merge. No --admin, no --delete-branch: protection rules still apply, and
  #    the branch is left for anyone who wants to read it later.
  out=$(cd "$repo" && gh pr merge "$n" "--$method" 2>&1) || {
    _am_decline "gh pr merge #$n was refused: $(printf '%s' "$out" | tail -1)"; return 2; }
  say "    merged #$n ($method)"

  # 8. Bring the base up to date so the landed check — and the NEXT entry, which
  #    is cut from it — see the merge. A local base (`--base main`) is not moved
  #    by a remote merge, so it is fast-forwarded explicitly.
  git -C "$repo" fetch --quiet "$remote" 2>/dev/null || true
  case "$base" in
    */*) ;;
    *) git -C "$repo" fetch --quiet "$remote" "$base_branch:$base_branch" 2>/dev/null || \
         warn "    could not fast-forward local $base_branch; the landed check may not see the merge yet";;
  esac
  return 0
}
