#!/usr/bin/env zsh
# bootstrap.sh — wire SwarmForge helpers into the user's shell.
#
# Idempotent. Re-running replaces the sentinel-guarded block in your shell rc
# so layout fixes propagate cleanly on re-install.
#
# After running, open a new shell (or `source ~/.zshrc`) and you get:
#   swarmforge                 — start a swarm in the current directory
#   swarm                      — backward-compatible alias for swarmforge
#   swarm-attach <role>        — attach tmux to a running swarm session
#   swarm-attach <TAB>         — completes to architect/coder/reviewer/logger
#   swarmlog                   — log helper

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
COMPLETIONS_DIR="$SCRIPT_DIR/completions"
SENTINEL_BEGIN="# >>> swarm-forge bootstrap >>>"
SENTINEL_END="# <<< swarm-forge bootstrap <<<"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

note()  { echo -e "  ${GREEN}+${RESET} $*"; }
skip()  { echo -e "  ${YELLOW}=${RESET} $*"; }

detect_rc() {
  local shell_name="${SHELL:t}"
  case "$shell_name" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash)
      if [[ -f "$HOME/.bashrc" ]]; then echo "$HOME/.bashrc"
      elif [[ -f "$HOME/.bash_profile" ]]; then echo "$HOME/.bash_profile"
      fi ;;
    *)
      [[ -f "$HOME/.zshrc" ]] && echo "$HOME/.zshrc" && return
      [[ -f "$HOME/.bashrc" ]] && echo "$HOME/.bashrc" && return
      ;;
  esac
}

SHELL_RC="$(detect_rc)"
if [[ -z "$SHELL_RC" ]]; then
  echo "swarm-forge bootstrap: could not detect shell rc file." >&2
  echo "Append manually to your shell rc:" >&2
  echo "  export PATH=\"$BIN_DIR:\$PATH\"" >&2
  exit 1
fi

echo "Bootstrapping swarm-forge helpers from $SCRIPT_DIR"
echo "PATH entries will point to: $BIN_DIR"
echo "Target shell rc:           $SHELL_RC"
echo ""

# 1. Create bin/ with command symlinks. Using bin/ avoids a name collision
#    with the repo-root swarmforge/ directory that holds default prompts.
mkdir -p "$BIN_DIR"

declare -A LINKS=(
  [swarmforge]="../swarm"
  [swarm]="../swarm"
  [swarm-attach]="../swarm-attach"
  [swarmlog]="../swarmlog.sh"
)

for name target in ${(kv)LINKS}; do
  if [[ -L "$BIN_DIR/$name" ]]; then
    skip "bin/$name already exists"
  elif [[ -e "$BIN_DIR/$name" ]]; then
    skip "bin/$name exists and is not a symlink — leaving alone"
  else
    ln -s "$target" "$BIN_DIR/$name"
    note "linked bin/$name -> $target"
  fi
done

# 2. Make sure the underlying helper scripts are executable.
for helper in swarm swarmforge.sh swarm-attach swarmlog.sh \
              swarm-cleanup.sh swarm-window-watchdog.sh swarm-aider-sidecar.sh; do
  if [[ -f "$SCRIPT_DIR/$helper" && ! -x "$SCRIPT_DIR/$helper" ]]; then
    chmod +x "$SCRIPT_DIR/$helper"
    note "chmod +x $helper"
  fi
done

# 3. Refresh the shell rc block. We always remove the old block (if any) and
#    write the current one so re-running picks up layout changes cleanly.
#    We do NOT print the file contents — sed -i edits in place.
if grep -qF "$SENTINEL_BEGIN" "$SHELL_RC" 2>/dev/null; then
  sed -i.swarm-forge.bak "/^# >>> swarm-forge bootstrap >>>$/,/^# <<< swarm-forge bootstrap <<<$/d" "$SHELL_RC"
  rm -f "${SHELL_RC}.swarm-forge.bak"
  note "removed existing swarm-forge block from $SHELL_RC"
fi

{
  echo ""
  echo "$SENTINEL_BEGIN"
  echo "export PATH=\"$BIN_DIR:\$PATH\""
  echo "if [[ -n \"\${ZSH_VERSION:-}\" ]]; then"
  echo "  fpath=(\"$COMPLETIONS_DIR\" \$fpath)"
  echo "  autoload -Uz compinit && compinit -u"
  echo "fi"
  echo "$SENTINEL_END"
} >> "$SHELL_RC"
note "appended PATH + completion block to $SHELL_RC"

echo ""
echo "Done. Reload your shell or run:"
echo "  source $SHELL_RC"
echo ""
echo "Then from a project directory:"
echo "  swarmforge                   # start the swarm"
echo "  swarm-attach <role>          # attach to a session"
echo "  swarm-attach <TAB>           # completes to architect/coder/reviewer/logger"
