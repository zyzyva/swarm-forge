#!/usr/bin/env zsh
set -euo pipefail

WORKTREE_PATH="$1"
ROLE="$2"
PROJECT_DIR="$3"
SESSION="$4"
NOTIFY_TARGET="${5:-}"

NOTIFY_SCRIPT="$PROJECT_DIR/swarmtools/notify-agent.sh"
OPS_QUEUE="$PROJECT_DIR/.swarmforge/ops/${ROLE}.queue"
CMD_QUEUE="$WORKTREE_PATH/.sidecar/commands"
CMD_RESULTS="$WORKTREE_PATH/.sidecar/results"
SIDECAR_LOG="$PROJECT_DIR/logs/sidecar-${ROLE}.log"
POLL_INTERVAL="${SWARMFORGE_SIDECAR_INTERVAL:-5}"

mkdir -p "$(dirname "$OPS_QUEUE")" "$WORKTREE_PATH/.sidecar" "$(dirname "$SIDECAR_LOG")"
touch "$OPS_QUEUE" "$CMD_QUEUE"
: > "$CMD_RESULTS"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [sidecar:${ROLE}] $*" >> "$SIDECAR_LOG"
}

notify_aider() {
  tmux send-keys -t "${SESSION}:0.0" -l -- "$1" 2>/dev/null || true
  sleep 0.15
  tmux send-keys -t "${SESSION}:0.0" C-m 2>/dev/null || true
  sleep 0.05
  tmux send-keys -t "${SESSION}:0.0" C-j 2>/dev/null || true
}

# ── Commit Watcher ────────────────────────────────────────────────

LAST_HASH="$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo "")"

check_commits() {
  [[ -z "$NOTIFY_TARGET" ]] && return

  local current_hash
  current_hash="$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo "")"
  [[ -z "$current_hash" || "$current_hash" == "$LAST_HASH" ]] && return

  local branch short_hash commit_msg
  branch="$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
  short_hash="${current_hash:0:8}"
  commit_msg="$(git -C "$WORKTREE_PATH" log --format='%s' -1 2>/dev/null || echo "unknown")"

  log "Commit detected on $branch ($short_hash): $commit_msg"
  "$NOTIFY_SCRIPT" "$NOTIFY_TARGET" \
    "Review your rules. ${ROLE} committed on branch ${branch} (${short_hash}): ${commit_msg}" \
    2>/dev/null || log "Failed to notify $NOTIFY_TARGET"

  LAST_HASH="$current_hash"
}

# ── Ops Queue (merges from other agents) ──────────────────────────

process_ops() {
  [[ ! -s "$OPS_QUEUE" ]] && return

  local tmpfile="${OPS_QUEUE}.processing"
  mv "$OPS_QUEUE" "$tmpfile"
  touch "$OPS_QUEUE"

  local line op args
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    op="${line%% *}"
    args="${line#* }"

    case "$op" in
      merge)
        log "Merging from $args"
        local merge_output
        if merge_output=$(git -C "$WORKTREE_PATH" merge "$args" --no-edit 2>&1); then
          log "Merge succeeded"
          notify_aider "Sidecar merged $args into your worktree. Re-read any files you are working on."
        else
          log "Merge failed: $merge_output"
          if git -C "$WORKTREE_PATH" merge --abort 2>/dev/null; then
            notify_aider "Sidecar merge from $args FAILED and was aborted: $merge_output"
          else
            notify_aider "Sidecar merge from $args FAILED: $merge_output — manual resolution may be needed."
          fi
        fi
        ;;
      *)
        log "Unknown op: $line"
        ;;
    esac
  done < "$tmpfile"
  rm -f "$tmpfile"
}

# ── Command Queue (shell commands from aider) ─────────────────────

DENIED_PATTERNS=(
  'rm -rf'
  'rm -r /'
  'git push'
  'git reset --hard'
  'git checkout .'
  'git checkout -- .'
  'git clean -f'
  'git clean -d'
  'git stash drop'
  'git branch -D'
  'sudo '
  '| sh'
  '| bash'
  '| zsh'
  'curl.*| '
  'wget.*| '
  'mkfs'
  'dd if='
  '> /dev/'
  'chmod 777'
  ':(){ :|:& };:'
)

command_is_denied() {
  local cmd="$1"
  local pattern
  for pattern in "${DENIED_PATTERNS[@]}"; do
    if [[ "$cmd" == *"$pattern"* ]]; then
      return 0
    fi
  done
  return 1
}

process_commands() {
  [[ ! -s "$CMD_QUEUE" ]] && return

  local tmpfile="${CMD_QUEUE}.processing"
  mv "$CMD_QUEUE" "$tmpfile"
  touch "$CMD_QUEUE"

  local line count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue

    if command_is_denied "$line"; then
      log "DENIED command: $line"
      {
        echo "--- Command: $line"
        echo "--- DENIED by sidecar safety filter"
        echo "---"
      } >> "$CMD_RESULTS"
      count=$((count + 1))
      continue
    fi

    log "Executing: $line"
    local cmd_output="" exit_code=0
    cmd_output=$(cd "$WORKTREE_PATH" && eval "$line" 2>&1) || exit_code=$?

    {
      echo "--- Command: $line"
      echo "--- Exit: $exit_code"
      echo "$cmd_output"
      echo "---"
    } >> "$CMD_RESULTS"

    log "Exit $exit_code"
    count=$((count + 1))
  done < "$tmpfile"
  rm -f "$tmpfile"

  if (( count > 0 )); then
    notify_aider "Sidecar executed $count command(s). Read .sidecar/results for output."
  fi
}

# ── Main Loop ─────────────────────────────────────────────────────

log "Starting: worktree=$WORKTREE_PATH notify=${NOTIFY_TARGET:-none}"

while true; do
  sleep "$POLL_INTERVAL"
  check_commits
  process_ops
  process_commands
done
