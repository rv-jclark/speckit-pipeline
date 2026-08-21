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
  local f="$1" tmp; tmp=$(mktemp)
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
#   prints "<state>\t<how>", always exits 0
#     done       the work is on the base branch
#     not_landed it is not, and we could see clearly enough to say so
#     unknown    the question could not be answered — NOT a synonym for "no"
entry_landed() {
  local repo="$1" base="$2" fdir="$3" branch="$4" fresh="$5"

  if ! git -C "$repo" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
    printf 'unknown\tthe base ref %s does not exist in this repository\n' "$base"; return 0
  fi

  if [ -n "$branch" ] && git -C "$repo" rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
    if git -C "$repo" merge-base --is-ancestor "$branch" "$base" 2>/dev/null; then
      printf 'done\t%s is an ancestor of %s\n' "$branch" "$base"; return 0
    fi
  fi

  # Squash-safe: is the entry's own work present on the base branch? tasks.md is
  # the last artifact the pipeline writes, so its presence means the whole spec
  # landed rather than a partial merge.
  if [ -n "$fdir" ] && git -C "$repo" cat-file -e "$base:$fdir/tasks.md" 2>/dev/null; then
    printf 'done\t%s/tasks.md is present on %s (squash-merged, so not an ancestor)\n' "$fdir" "$base"
    return 0
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
# The runner switches branches between entries, so it must never do that over
# somebody's uncommitted work. Refuse and say what is dirty; never stash.

tree_is_clean() { # tree_is_clean <repo>  -> 0 clean, else prints the dirty paths
  local dirty
  dirty=$(git -C "$1" status --porcelain 2>/dev/null | head -20)
  [ -z "$dirty" ] && return 0
  printf '%s\n' "$dirty"
  return 1
}
