#!/usr/bin/env bash
#
# install.sh — put every speckit-pipeline command on your PATH, from this clone.
#
#   ./install.sh                 link into the first writable of ~/.local/bin,
#                                /opt/homebrew/bin, /usr/local/bin
#   ./install.sh --bin-dir DIR   link into DIR instead
#   ./install.sh --uninstall     remove the links this clone made, and nothing else
#
# It makes links, not copies, so `git pull` is the upgrade and editing the clone
# changes what runs. Never sudo: a root-owned link in a user's PATH is one more
# thing that later needs sudo to remove. Every command in bin/ is linked, so a
# command added later needs no change here.
#
# Safe to re-run. A link that already points here is left alone. A file of the
# same name that is NOT one of ours is never overwritten. It is reported, and
# the install exits non-zero.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR=""; UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir)   BIN_DIR="${2:-}"; [ -n "$BIN_DIR" ] || { echo "x --bin-dir needs a directory" >&2; exit 3; }; shift 2;;
    --uninstall) UNINSTALL=1; shift;;
    -h|--help)   sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *)           echo "x unknown option: $1" >&2; exit 3;;
  esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
note() { printf '  \033[33m!\033[0m %s\n' "$*"; }

cmds=()
for f in "$HERE"/bin/*; do [ -f "$f" ] && [ -x "$f" ] && cmds+=("$f"); done
[ ${#cmds[@]} -gt 0 ] || { bad "no commands found in $HERE/bin"; exit 1; }

if [ -z "$BIN_DIR" ]; then
  for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
    if [ -d "$d" ] && [ -w "$d" ]; then BIN_DIR="$d"; break; fi
  done
  # ~/.local/bin is the XDG default and safe to create; the system ones are not.
  if [ -z "$BIN_DIR" ]; then BIN_DIR="$HOME/.local/bin"; mkdir -p "$BIN_DIR"; fi
fi
mkdir -p "$BIN_DIR" 2>/dev/null
[ -w "$BIN_DIR" ] || { bad "$BIN_DIR is not writable — pass --bin-dir <dir>"; exit 1; }
BIN_DIR=$(cd -- "$BIN_DIR" && pwd)

ours() { # is $1 a link into this clone's bin/?
  [ -L "$1" ] && case "$(readlink "$1")" in "$HERE"/bin/*) return 0;; esac
  return 1
}

if [ "$UNINSTALL" -eq 1 ]; then
  say "removing links into $HERE/bin from $BIN_DIR"
  n=0
  for f in "$BIN_DIR"/*; do
    if ours "$f"; then rm -f "$f" && ok "removed $(basename "$f")"; n=$((n+1)); fi
  done
  [ "$n" -eq 0 ] && say "  nothing to remove"
  exit 0
fi

say "linking ${#cmds[@]} command(s) into $BIN_DIR"
clash=0
for src in "${cmds[@]}"; do
  name=$(basename "$src"); dst="$BIN_DIR/$name"
  if ours "$dst" && [ "$(readlink "$dst")" = "$src" ]; then
    ok "$name (already linked)"
  elif [ -e "$dst" ] || [ -L "$dst" ]; then
    if [ -L "$dst" ]; then
      bad "$name: $dst already links to $(readlink "$dst") — left alone"
    else
      bad "$name: $dst is a file this install did not make — left alone"
    fi
    clash=1
  else
    ln -s "$src" "$dst" && ok "$name"
  fi
done

# Prerequisites, named rather than discovered mid-run. Only jq and git are hard
# requirements of the pipeline itself.
say ""
say "prerequisites"
for t in jq git; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t missing — brew install $t"; clash=1; fi
done
command -v python3 >/dev/null 2>&1 && ok "python3 (for spec-dashboard)" \
  || note "python3 missing — only spec-dashboard needs it (xcode-select --install)"
command -v claude >/dev/null 2>&1 && ok "claude" \
  || note "claude not on PATH — install Claude Code, or see \"Using a different runner\" in the README"

# Run the link, not the file, so a broken PATH or link shows here.
say ""
case ":$PATH:" in
  *":$BIN_DIR:"*)
    if v=$("$BIN_DIR/spec-run" --version 2>/dev/null); then
      ok "spec-run runs from PATH: $v"
    else
      bad "spec-run is linked but does not run — try $BIN_DIR/spec-run --version"; clash=1
    fi
    resolved=$(command -v spec-run)
    [ "$resolved" = "$BIN_DIR/spec-run" ] || note "spec-run resolves to $resolved first, not this install"
    ;;
  *)
    note "$BIN_DIR is not on your PATH. Add this to ~/.zshrc, then open a new terminal:"
    say  "      export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

say ""
say "next:  spec-dashboard --open      every pipeline, in a browser"
say "       spec-bootstrap <repo>      prepare a project, once per repo"
exit "$clash"
