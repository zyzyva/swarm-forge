#!/usr/bin/env zsh

# One Terminal.app window per project. Role sessions are unchanged (so
# notify-agent / handoff / sessions.tsv targeting keeps working); this backend
# adds a "viewer" tmux session on the project socket whose single window holds
# one tiled pane per role, each pane running a nested tmux client attached to
# that role's session. The single GUI window attaches to the viewer.
#
# Lifecycle: every role shares the one window id, so the watchdog's semantics
# carry over — closing the window makes the cleanup owner's window go missing,
# which tears the whole swarm down (same intent as closing the architect's
# window under the plain terminal-app backend). Killing the role sessions
# makes each nested client exit, which closes its pane; the viewer session
# dies with its last pane.
#
# Keybinding note: the tmux prefix is captured by the viewer (pane
# navigation); press the prefix twice to send it to the inner role session
# (default binding: C-b C-b).

TILED_VIEWER_SESSION="viewer"

terminal_backend_label() {
  echo "Terminal (one tiled window)"
}

terminal_backend_can_open_sessions() {
  return 0
}

terminal_backend_tracks_windows() {
  return 0
}

tiled_window_id_file() {
  echo "$WORKING_DIR/.swarmforge/tiled-window-id"
}

terminal_window_exists() {
  local window_id="$1"
  [[ -n "$window_id" ]] || return 1

  local result
  result="$(osascript - "$window_id" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
  set targetId to item 1 of argv as integer
  tell application "Terminal"
    repeat with terminalWindow in windows
      if id of terminalWindow is targetId then return "yes"
    end repeat
  end tell
  return "no"
end run
APPLESCRIPT
)"

  [[ "$result" == "yes" ]]
}

# Called by the launcher after it kills leftover role sessions: retire the
# previous launch's viewer session and GUI window so each relaunch reuses a
# single fresh window instead of stranding a dead one (the accumulation bug
# the plain terminal-app backend has).
terminal_backend_prelaunch() {
  tmux -S "$TMUX_SOCKET" kill-session -t "=$TILED_VIEWER_SESSION" 2>/dev/null || true

  local stale_id
  stale_id="$(cat "$(tiled_window_id_file)" 2>/dev/null || true)"
  if [[ -n "$stale_id" ]]; then
    # Let the window's attach client exit after the viewer dies before
    # closing; closing while the process is still alive can trigger
    # Terminal's "terminate running processes?" prompt and strand the window.
    local i
    for i in {1..10}; do
      sleep 0.3
      terminal_close_window "$stale_id"
      terminal_window_exists "$stale_id" || break
    done
  fi
  rm -f "$(tiled_window_id_file)"
}

terminal_open_session() {
  local session="$1"
  local title="$2"
  local attach_cmd="TMUX= exec tmux -S ${(qq)TMUX_SOCKET} attach-session -t ${(qq)session}"

  if tmux -S "$TMUX_SOCKET" has-session -t "=$TILED_VIEWER_SESSION" 2>/dev/null; then
    # Viewer already exists (a prior role created it this launch): add a pane
    # for this role, retile, and reuse the one window id.
    tmux -S "$TMUX_SOCKET" split-window -d -t "${TILED_VIEWER_SESSION}:" "$attach_cmd"
    tmux -S "$TMUX_SOCKET" select-layout -t "${TILED_VIEWER_SESSION}:" tiled
    cat "$(tiled_window_id_file)" 2>/dev/null
    return
  fi

  # First role of this launch: build the viewer (oversized canvas so many
  # panes fit before the GUI client attaches and takes over sizing) and open
  # the single Terminal window attached to it. The outer status bar is
  # redundant — each pane shows its role session's own status line — so turn
  # it off.
  tmux -S "$TMUX_SOCKET" new-session -d -s "$TILED_VIEWER_SESSION" -n all -x 400 -y 200 "$attach_cmd"
  tmux -S "$TMUX_SOCKET" set-option -t "$TILED_VIEWER_SESSION" status off

  local window_id
  window_id="$(osascript - "$WORKING_DIR" "$TILED_VIEWER_SESSION" "SwarmForge ${WORKING_DIR:t}" "$TMUX_SOCKET" <<'APPLESCRIPT'
on run argv
  set workingDir to item 1 of argv
  set tmuxSession to item 2 of argv
  set windowTitle to item 3 of argv
  set tmuxSocket to item 4 of argv

  tell application "Terminal"
    activate
    set newTab to do script ""
    do script "cd " & quoted form of workingDir & " && exec tmux -S " & quoted form of tmuxSocket & " attach-session -t " & quoted form of tmuxSession in newTab
    set custom title of newTab to windowTitle
    return id of front window
  end tell
end run
APPLESCRIPT
)"

  printf '%s\n' "$window_id" > "$(tiled_window_id_file)"
  echo "$window_id"
}

terminal_close_window() {
  local window_id="$1"
  [[ -n "$window_id" ]] || return 0

  osascript - "$window_id" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set targetId to item 1 of argv as integer
  tell application "Terminal"
    try
      close (first window whose id is targetId) saving no
    end try
  end tell
end run
APPLESCRIPT
}
