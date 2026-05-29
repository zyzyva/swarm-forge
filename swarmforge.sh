#!/usr/bin/env zsh
set -euo pipefail

AGENT_WINDOW="swarm"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

WORKING_DIR="${1:-$PWD}"
WORKING_DIR="$(cd "$WORKING_DIR" && pwd)"

# Namespace tmux sessions by project directory basename so multiple
# swarms can run in parallel without colliding. Override with
# SWARMFORGE_PREFIX=myname if you need a custom name.
SESSION_PREFIX="${SWARMFORGE_PREFIX:-swarmforge-$(basename "$WORKING_DIR")}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_FORGE_DIR="$WORKING_DIR/swarmforge"
SWARM_TOOLS_DIR="$WORKING_DIR/swarmtools"
WORKTREES_DIR="$WORKING_DIR/.worktrees"
CONFIG_FILE="$SWARM_FORGE_DIR/swarmforge.conf"
ROLES_DIR="$SWARM_FORGE_DIR"
CONSTITUTION_FILE="$SWARM_FORGE_DIR/constitution.prompt"
STATE_DIR="$WORKING_DIR/.swarmforge"
WINDOW_IDS_FILE="$STATE_DIR/window-ids"
WINDOW_STATE_FILE="$STATE_DIR/windows.tsv"
WINDOW_WATCHDOG_LOG="$STATE_DIR/window-watchdog.log"
SESSIONS_FILE="$STATE_DIR/sessions.tsv"
PROMPTS_DIR="$STATE_DIR/prompts"
TMUX_SOCKET_DIR="/private/tmp/swarmforge-${UID}"
PROJECT_SOCKET_ID="$(printf '%s' "$WORKING_DIR" | cksum)"
PROJECT_SOCKET_ID="${PROJECT_SOCKET_ID%% *}"
TMUX_SOCKET="$TMUX_SOCKET_DIR/$PROJECT_SOCKET_ID.sock"
TMUX_SOCKET_FILE="$STATE_DIR/tmux-socket"
TERMINAL_BACKEND=""

typeset -a ROLES=()
typeset -a AGENTS=()
typeset -a SESSIONS=()
typeset -a DISPLAY_NAMES=()
typeset -a WORKTREE_NAMES=()
typeset -a WORKTREE_PATHS=()
typeset -a NOTIFY_TARGETS=()
typeset -A ROLE_INDEX=()
typeset -A WORKTREE_INDEX=()
typeset -i CLEANUP_OWNER_INDEX=1
typeset -i TMUX_WINDOW_BASE_INDEX=0
typeset -i TMUX_PANE_BASE_INDEX=0
typeset -i i=0

check_dependency() {
  if ! command -v "$1" &>/dev/null; then
    echo -e "${RED}Error:${RESET} '$1' is required but not installed."
    exit 1
  fi
}

get_tmux_option() {
  local option="$1"
  local scope="$2"
  local default_value="$3"
  local value=""

  case "$scope" in
    session)
      value="$(tmux -S "$TMUX_SOCKET" show-options -gqv "$option" 2>/dev/null || true)"
      ;;
    window)
      value="$(tmux -S "$TMUX_SOCKET" show-window-options -gqv "$option" 2>/dev/null || true)"
      ;;
  esac

  if [[ "$value" == <-> ]]; then
    echo "$value"
  else
    echo "$default_value"
  fi
}

detect_tmux_base_indexes() {
  local probe_session=""

  mkdir -p "$TMUX_SOCKET_DIR"
  if ! tmux -S "$TMUX_SOCKET" info >/dev/null 2>&1; then
    probe_session="swarmforge-probe-$$"
    tmux -S "$TMUX_SOCKET" new-session -d -s "$probe_session" "sleep 60" >/dev/null
  fi

  TMUX_WINDOW_BASE_INDEX="$(get_tmux_option base-index session 0)"
  TMUX_PANE_BASE_INDEX="$(get_tmux_option pane-base-index window 0)"

  if [[ -n "$probe_session" ]]; then
    tmux -S "$TMUX_SOCKET" kill-session -t "$probe_session" >/dev/null 2>&1 || true
  fi
}

tmux_agent_target() {
  local session="$1"
  local window="$2"

  echo "${session}:${window}.${TMUX_PANE_BASE_INDEX}"
}

ensure_initial_gitignore() {
  local gitignore_file="$WORKING_DIR/.gitignore"

  if [[ ! -f "$gitignore_file" ]]; then
    cat > "$gitignore_file" <<'EOF'
.swarmforge/
.worktrees/
.sidecar/
swarmtools/
logs/
agent_context/
EOF
    return
  fi

  if ! grep -qx 'logs/' "$gitignore_file"; then
    echo 'logs/' >> "$gitignore_file"
  fi

  if ! grep -qx 'agent_context/' "$gitignore_file"; then
    echo 'agent_context/' >> "$gitignore_file"
  fi

  if ! grep -qx '.swarmforge/' "$gitignore_file"; then
    echo '.swarmforge/' >> "$gitignore_file"
  fi

  if ! grep -qx '.worktrees/' "$gitignore_file"; then
    echo '.worktrees/' >> "$gitignore_file"
  fi

  if ! grep -qx 'swarmtools/' "$gitignore_file"; then
    echo 'swarmtools/' >> "$gitignore_file"
  fi

  if ! grep -qx '.sidecar/' "$gitignore_file"; then
    echo '.sidecar/' >> "$gitignore_file"
  fi
}

ensure_runtime_git_excludes() {
  local exclude_file
  exclude_file="$(git -C "$WORKING_DIR" rev-parse --git-path info/exclude)"
  mkdir -p "${exclude_file:h}"
  touch "$exclude_file"

  local pattern
  for pattern in ".swarmforge/" ".worktrees/" "swarmtools/" "logs/" "agent_context/"; do
    if ! grep -qx "$pattern" "$exclude_file"; then
      echo "$pattern" >> "$exclude_file"
    fi
  done
}

initialize_git_repo() {
  if [[ -d "$WORKING_DIR/.git" ]]; then
    return
  fi

  git init "$WORKING_DIR" >/dev/null
  git -C "$WORKING_DIR" branch -M master >/dev/null
  ensure_initial_gitignore
  git -C "$WORKING_DIR" add .
  git -C "$WORKING_DIR" commit -m "Initial swarmforge repository" >/dev/null
}

has_command() {
  command -v "$1" &>/dev/null
}

source "$SCRIPT_DIR/swarm-terminal-adapter.sh"

remove_nonessential_clone_files() {
  if [[ "${WORKING_DIR:t}" == "swarm-forge" ]]; then
    return
  fi

  if [[ -d "$STATE_DIR" ]]; then
    return
  fi

  rm -rf "$WORKING_DIR/README.md" "$WORKING_DIR/SwarmForgeInitSpec.md" "$WORKING_DIR/examples"
}

display_name_for_role() {
  local role="$1"
  local normalized="${role//[-_]/ }"
  local -a parts
  local part
  local label=""

  parts=(${=normalized})
  for part in "${parts[@]}"; do
    part="${(C)part}"
    if [[ -n "$label" ]]; then
      label+=" "
    fi
    label+="$part"
  done

  echo "$label"
}

session_name_for_role() {
  echo "${SESSION_PREFIX}-$1"
}

worktree_path_for_name() {
  echo "$WORKTREES_DIR/$1"
}

parse_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error:${RESET} Config not found at $CONFIG_FILE"
    exit 1
  fi

  if [[ ! -f "$CONSTITUTION_FILE" ]]; then
    echo -e "${RED}Error:${RESET} Constitution prompt not found at $CONSTITUTION_FILE"
    exit 1
  fi

  local line keyword role agent worktree line_no=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line[1]}" == "#" ]] && continue

    local -a fields
    fields=(${=line})
    if (( ${#fields[@]} < 4 || ${#fields[@]} > 5 )); then
      echo -e "${RED}Error:${RESET} Invalid config line $line_no: $line (expected 4-5 fields)"
      exit 1
    fi

    keyword="${fields[1]}"
    role="${fields[2]}"
    agent="${fields[3]:l}"
    worktree="${fields[4]}"
    local notify_target="${fields[5]:-}"

    if [[ "$keyword" != "window" ]]; then
      echo -e "${RED}Error:${RESET} Unknown config directive on line $line_no: $keyword"
      exit 1
    fi

    if [[ -n "${ROLE_INDEX[$role]:-}" ]]; then
      echo -e "${RED}Error:${RESET} Duplicate role '$role' in $CONFIG_FILE"
      exit 1
    fi

    if [[ "$worktree" != "none" && "$worktree" != "master" && -n "${WORKTREE_INDEX[$worktree]:-}" ]]; then
      echo -e "${RED}Error:${RESET} Duplicate worktree '$worktree' in $CONFIG_FILE"
      exit 1
    fi

    if [[ "$worktree" == *"/"* || "$worktree" == "." || "$worktree" == ".." ]]; then
      echo -e "${RED}Error:${RESET} Invalid worktree '$worktree' for role '$role'"
      exit 1
    fi

    case "$agent" in
      claude|codex|aider|copilot|grok|none) ;;
      *)
        echo -e "${RED}Error:${RESET} Unsupported agent '$agent' for role '$role'"
        exit 1
        ;;
    esac

    if [[ "$agent" != "none" && ! -f "$ROLES_DIR/$role.prompt" ]]; then
      echo -e "${RED}Error:${RESET} Missing role prompt $ROLES_DIR/$role.prompt"
      exit 1
    fi

    ROLE_INDEX[$role]=${#ROLES[@]}
    if [[ "$worktree" != "none" && "$worktree" != "master" ]]; then
      WORKTREE_INDEX[$worktree]=${#ROLES[@]}
    fi
    ROLES+=("$role")
    AGENTS+=("$agent")
    SESSIONS+=("$(session_name_for_role "$role")")
    DISPLAY_NAMES+=("$(display_name_for_role "$role")")
    WORKTREE_NAMES+=("$worktree")
    NOTIFY_TARGETS+=("$notify_target")
    if [[ "$worktree" == "none" || "$worktree" == "master" ]]; then
      WORKTREE_PATHS+=("$WORKING_DIR")
    else
      WORKTREE_PATHS+=("$(worktree_path_for_name "$worktree")")
    fi
  done < "$CONFIG_FILE"

  if (( ${#ROLES[@]} == 0 )); then
    echo -e "${RED}Error:${RESET} No windows defined in $CONFIG_FILE"
    exit 1
  fi

  local j nt
  for (( j = 1; j <= ${#ROLES[@]}; j++ )); do
    nt="${NOTIFY_TARGETS[$j]}"
    if [[ -n "$nt" && -z "${ROLE_INDEX[$nt]:-}" ]]; then
      echo -e "${RED}Error:${RESET} Notify target '$nt' for role '${ROLES[$j]}' not found in config"
      exit 1
    fi
  done
}

write_sessions_file() {
  : > "$SESSIONS_FILE"
  local i
  for (( i = 1; i <= ${#ROLES[@]}; i++ )); do
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$i" \
      "${ROLES[$i]}" \
      "${SESSIONS[$i]}" \
      "${DISPLAY_NAMES[$i]}" \
      "${AGENTS[$i]}" >> "$SESSIONS_FILE"
  done
}

check_helper_scripts() {
  local helper
  for helper in swarm-cleanup.sh swarm-window-watchdog.sh swarm-terminal-adapter.sh swarmlog.sh swarm-aider-sidecar.sh; do
    if [[ ! -x "$SCRIPT_DIR/$helper" ]]; then
      echo -e "${RED}Error:${RESET} Required helper script not found or not executable: $SCRIPT_DIR/$helper"
      exit 1
    fi
  done

  for helper in terminal-app.sh ghostty.sh windows-terminal.sh none.sh; do
    if [[ ! -x "$SCRIPT_DIR/terminal-adapters/$helper" ]]; then
      echo -e "${RED}Error:${RESET} Required terminal adapter not found or not executable: $SCRIPT_DIR/terminal-adapters/$helper"
      exit 1
    fi
  done
}

write_notify_script() {
  cat > "$SWARM_TOOLS_DIR/notify-agent.sh" <<'EOF'
#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

find_project_dir() {
  local git_common_dir

  if git_common_dir=$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null); then
    if [[ "$git_common_dir" != /* ]]; then
      git_common_dir="$(cd "$SCRIPT_DIR/$git_common_dir" && pwd)"
    fi
    local project_dir="${git_common_dir:h}"
    if [[ -f "$project_dir/.swarmforge/sessions.tsv" ]]; then
      echo "$project_dir"
      return 0
    fi
  fi

  echo "${SCRIPT_DIR:h}"
}

PROJECT_DIR="$(find_project_dir)"
SESSIONS_FILE="$PROJECT_DIR/.swarmforge/sessions.tsv"
LOG_FILE="$PROJECT_DIR/logs/agent_messages.log"
TMUX_SOCKET_FILE="$PROJECT_DIR/.swarmforge/tmux-socket"
if [[ ! -f "$TMUX_SOCKET_FILE" ]]; then
  echo "Tmux socket file not found: $TMUX_SOCKET_FILE" >&2
  exit 1
fi
TMUX_SOCKET="$(< "$TMUX_SOCKET_FILE")"
TMUX_WINDOW_BASE_INDEX="$(tmux -S "$TMUX_SOCKET" show-options -gqv base-index 2>/dev/null || echo 0)"
if [[ ! "$TMUX_WINDOW_BASE_INDEX" == <-> ]]; then
  TMUX_WINDOW_BASE_INDEX=0
fi
TMUX_PANE_BASE_INDEX="$(tmux -S "$TMUX_SOCKET" show-window-options -gqv pane-base-index 2>/dev/null || echo 0)"
if [[ ! "$TMUX_PANE_BASE_INDEX" == <-> ]]; then
  TMUX_PANE_BASE_INDEX=0
fi

MERGE_BRANCH=""
if [[ "${1:-}" == "--merge" ]]; then
  MERGE_BRANCH="$2"
  shift 2
fi

if [[ $# -lt 2 ]]; then
  echo "Usage: notify-agent.sh [--merge <branch>] <target-role-or-index> \"message\"" >&2
  echo "       notify-agent.sh [--merge <branch>] <target-role-or-index> --file <message-file>" >&2
  exit 1
fi

if [[ ! -f "$SESSIONS_FILE" ]]; then
  echo "Sessions file not found: $SESSIONS_FILE" >&2
  exit 1
fi

resolve_target() {
  local target="${1:l}"
  local index role session display agent

  while IFS=$'\t' read -r index role session display agent; do
    if [[ "$target" == "${index:l}" || "$target" == "${role:l}" ]]; then
      echo "${session}\t${role}\t${agent}"
      return 0
    fi
  done < "$SESSIONS_FILE"

  return 1
}

TARGET_INFO=$(resolve_target "$1") || {
  echo "Unknown target: $1" >&2
  exit 1
}

TARGET_SESSION="${TARGET_INFO%%$'\t'*}"
TARGET_ROLE_AGENT="${TARGET_INFO#*$'\t'}"
TARGET_ROLE="${TARGET_ROLE_AGENT%%$'\t'*}"
TARGET_AGENT="${TARGET_ROLE_AGENT#*$'\t'}"

shift
if [[ "${1:-}" == "--file" ]]; then
  if [[ $# -ne 2 ]]; then
    echo "Usage: notify-agent.sh [--merge <branch>] <target-role-or-index> --file <message-file>" >&2
    exit 1
  fi
  MESSAGE_FILE="$2"
  if [[ ! -f "$MESSAGE_FILE" ]]; then
    echo "Message file not found: $MESSAGE_FILE" >&2
    exit 1
  fi
  MESSAGE="$(< "$MESSAGE_FILE")"
else
  MESSAGE="$*"
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
mkdir -p "$PROJECT_DIR/logs"
echo "[$TIMESTAMP] [$TARGET_SESSION] $MESSAGE" >> "$LOG_FILE"

if [[ -n "$MERGE_BRANCH" && "$TARGET_AGENT" == "aider" ]]; then
  OPS_QUEUE="$PROJECT_DIR/.swarmforge/ops/${TARGET_ROLE}.queue"
  mkdir -p "$(dirname "$OPS_QUEUE")"
  echo "merge $MERGE_BRANCH" >> "$OPS_QUEUE"
  echo "[$TIMESTAMP] [$TARGET_SESSION] [ops] merge $MERGE_BRANCH" >> "$LOG_FILE"
fi

tmux -S "$TMUX_SOCKET" send-keys -t "${TARGET_SESSION}:${TMUX_WINDOW_BASE_INDEX}.${TMUX_PANE_BASE_INDEX}" -l -- "$MESSAGE"
sleep 0.15
tmux -S "$TMUX_SOCKET" send-keys -t "${TARGET_SESSION}:${TMUX_WINDOW_BASE_INDEX}.${TMUX_PANE_BASE_INDEX}" C-m
sleep 0.05
tmux -S "$TMUX_SOCKET" send-keys -t "${TARGET_SESSION}:${TMUX_WINDOW_BASE_INDEX}.${TMUX_PANE_BASE_INDEX}" C-j
EOF

  chmod +x "$SWARM_TOOLS_DIR/notify-agent.sh"
}

prepare_workspace() {
  mkdir -p "$WORKING_DIR/logs" "$WORKING_DIR/agent_context" "$STATE_DIR" "$PROMPTS_DIR" "$SWARM_TOOLS_DIR" "$WORKTREES_DIR" "$TMUX_SOCKET_DIR" "$STATE_DIR/ops"
  printf '%s\n' "$TMUX_SOCKET" > "$TMUX_SOCKET_FILE"
  check_helper_scripts
  write_sessions_file
  write_notify_script
}

write_worktree_notify_wrapper() {
  local worktree_path="$1"
  local wrapper_dir="$worktree_path/swarmtools"
  local wrapper="$wrapper_dir/notify-agent.sh"
  local canonical_notify="$SWARM_TOOLS_DIR/notify-agent.sh"

  mkdir -p "$wrapper_dir"
  {
    echo '#!/usr/bin/env zsh'
    echo 'set -euo pipefail'
    printf 'CANONICAL_NOTIFY_AGENT=%q\n' "$canonical_notify"
    echo 'exec "$CANONICAL_NOTIFY_AGENT" "$@"'
  } > "$wrapper"
  chmod +x "$wrapper"
}

prepare_worktrees() {
  local i worktree_name worktree_path branch_name
  for (( i = 1; i <= ${#ROLES[@]}; i++ )); do
    worktree_name="${WORKTREE_NAMES[$i]}"
    worktree_path="${WORKTREE_PATHS[$i]}"
    branch_name="swarmforge-${worktree_name}"

    if [[ "$worktree_name" == "none" || "$worktree_name" == "master" ]]; then
      continue
    fi

    if [[ ! -e "$worktree_path/.git" && ! -d "$worktree_path/.git" ]]; then
      git -C "$WORKING_DIR" worktree add --force -B "$branch_name" "$worktree_path" HEAD >/dev/null
    fi

    write_worktree_notify_wrapper "$worktree_path"
  done
}

check_backend_dependencies() {
  local i
  for (( i = 1; i <= ${#AGENTS[@]}; i++ )); do
    case "${AGENTS[$i]}" in
      claude) check_dependency claude ;;
      codex) check_dependency codex ;;
      aider) check_dependency aider ;;
      copilot) check_dependency copilot ;;
      grok) check_dependency grok ;;
    esac
  done
}

create_role_session() {
  local session="$1"
  local title="$2"

  tmux -S "$TMUX_SOCKET" new-session -d -s "$session" -n "$AGENT_WINDOW"
  tmux -S "$TMUX_SOCKET" rename-window -t "$session:$AGENT_WINDOW" "$title"
  tmux -S "$TMUX_SOCKET" set-window-option -t "$session:$title" allow-rename off
}

write_agent_instruction_file() {
  local role="$1"
  local prompt_file="$2"
  local agent="${3:-claude}"

  if [[ "$agent" == "aider" ]]; then
    cat > "$prompt_file" <<EOF
Read swarmforge/constitution.prompt, then read every file it refers to recursively, and obey all of those instructions.
Read swarmforge/${role}.prompt, then read every file it refers to recursively, and follow all of those instructions.

A sidecar process handles operations you cannot perform directly:
- Merges from other branches happen automatically. When notified of a merge, re-read any files you are working on.
- To run a shell command, write it as a single line to .sidecar/commands (append, do not overwrite). The sidecar executes it and writes output to .sidecar/results. Wait a few seconds then read .sidecar/results.
- Destructive commands (rm -rf, git push, git reset --hard, etc.) are blocked by the sidecar safety filter.
- Outbound handoff notifications are sent automatically when you commit. Focus on your work and commit when a slice is complete.
EOF
  else
    cat > "$prompt_file" <<EOF
Read swarmforge/constitution.prompt, then read every file it refers to recursively, and obey all of those instructions.
Read swarmforge/${role}.prompt, then read every file it refers to recursively, and follow all of those instructions.
EOF
  fi
}

send_initial_grok_prompt() {
  local session="$1"
  local display="$2"
  local prompt_file="$3"

  (
    sleep 3
    tmux -S "$TMUX_SOCKET" send-keys -t "$(tmux_agent_target "$session" "$display")" -l -- "$(< "$prompt_file")"
    sleep 0.15
    tmux -S "$TMUX_SOCKET" send-keys -t "$(tmux_agent_target "$session" "$display")" C-m
    sleep 0.05
    tmux -S "$TMUX_SOCKET" send-keys -t "$(tmux_agent_target "$session" "$display")" C-j
  ) &!
}

launch_role() {
  local index="$1"
  local role="${ROLES[$index]}"
  local agent="${AGENTS[$index]}"
  local session="${SESSIONS[$index]}"
  local display="${DISPLAY_NAMES[$index]}"
  local role_worktree="${WORKTREE_PATHS[$index]}"
  local prompt_file="$PROMPTS_DIR/${role}.md"
  local launch_cmd=""

  if [[ "$agent" == "none" ]]; then
    if [[ "$role" == "logger" ]]; then
      tmux -S "$TMUX_SOCKET" send-keys -t "$(tmux_agent_target "$session" "$display")" \
        "cd '$WORKING_DIR' && touch logs/agent_messages.log && tail -f logs/agent_messages.log" Enter
    fi
    echo -e "  ${CYAN}[${display}]${RESET} opened without agent backend"
    return
  fi

  write_agent_instruction_file "$role" "$prompt_file" "$agent"

  # Pin the Claude Code effort level per role so each agent runs at an
  # appropriate reasoning budget regardless of shell or tmux env
  # inheritance. Per-role env vars win; SWARMFORGE_EFFORT is a shared
  # fallback. All roles default to xhigh because every role now runs on
  # Opus, which honors xhigh and benefits from it. Override per-role with
  # SWARMFORGE_<ROLE>_EFFORT (e.g. SWARMFORGE_CODER_EFFORT=high).
  # Effort levels are a Claude Code concept and do not apply to the aider
  # backend.
  local agent_effort
  case "$role" in
    architect|architect-*)
      agent_effort="${SWARMFORGE_ARCHITECT_EFFORT:-${SWARMFORGE_EFFORT:-xhigh}}"
      ;;
    coder|coder-*)
      agent_effort="${SWARMFORGE_CODER_EFFORT:-${SWARMFORGE_EFFORT:-xhigh}}"
      ;;
    reviewer|reviewer-*)
      agent_effort="${SWARMFORGE_REVIEWER_EFFORT:-${SWARMFORGE_EFFORT:-xhigh}}"
      ;;
    *)
      agent_effort="${SWARMFORGE_EFFORT:-high}"
      ;;
  esac

  # Pick the model per role. Opus is the default for every role. For
  # claude and codex backends this selects an Anthropic model; for aider
  # it can be any provider/model string that aider supports
  # (e.g. fireworks_ai/accounts/fireworks/models/kimi-k2-6). Per-role
  # env vars win; SWARMFORGE_MODEL is a shared fallback. Empty string
  # means "let the backend inherit its own default". Override the coder
  # back to Sonnet with SWARMFORGE_CODER_MODEL=claude-sonnet-4-6 if cost
  # becomes the constraint again.
  local agent_model
  case "$role" in
    architect|architect-*)
      agent_model="${SWARMFORGE_ARCHITECT_MODEL:-${SWARMFORGE_MODEL:-claude-opus-4-7}}"
      ;;
    coder|coder-*)
      agent_model="${SWARMFORGE_CODER_MODEL:-${SWARMFORGE_MODEL:-claude-opus-4-7}}"
      ;;
    reviewer|reviewer-*)
      agent_model="${SWARMFORGE_REVIEWER_MODEL:-${SWARMFORGE_MODEL:-claude-opus-4-7}}"
      ;;
    *)
      agent_model="${SWARMFORGE_MODEL:-}"
      ;;
  esac
  local model_flag=""
  [[ -n "$agent_model" ]] && model_flag="--model '$agent_model' "

  # Permission mode for the claude CLI. Defaults to auto so the swarm can
  # make progress without permission prompts. Override with
  # SWARMFORGE_PERMISSION_MODE (values: default, plan, acceptEdits, auto,
  # bypassPermissions, dontAsk).
  local agent_permission="${SWARMFORGE_PERMISSION_MODE:-auto}"

  case "$agent" in
    claude)
      launch_cmd="export PATH='$SWARM_TOOLS_DIR:$SCRIPT_DIR':\$PATH && export CLAUDE_CODE_EFFORT_LEVEL='$agent_effort' && cd '$role_worktree' && claude ${model_flag}--append-system-prompt-file '$prompt_file' --permission-mode '$agent_permission' -n 'SwarmForge ${display}' \"\$(cat '$prompt_file')\""
      ;;
    codex)
      launch_cmd="export PATH='$SWARM_TOOLS_DIR:$SCRIPT_DIR':\$PATH && cd '$role_worktree' && codex -C '$role_worktree' \"\$(cat '$prompt_file')\""
      ;;
    aider)
      local aider_flags="${SWARMFORGE_AIDER_FLAGS:-}"
      local notify_target="${NOTIFY_TARGETS[$index]}"
      local sidecar_cmd="'$SCRIPT_DIR/swarm-aider-sidecar.sh' '$role_worktree' '$role' '$WORKING_DIR' '$session' '$notify_target' &"
      launch_cmd="export PATH='$SWARM_TOOLS_DIR:$SCRIPT_DIR':\$PATH && cd '$role_worktree' && $sidecar_cmd aider ${model_flag}--yes-always --read '$SWARM_FORGE_DIR/constitution.prompt' --read '$SWARM_FORGE_DIR/${role}.prompt' --read '$prompt_file' $aider_flags --message \"\$(cat '$prompt_file')\""
      ;;
    copilot)
      launch_cmd="export PATH='$SWARM_TOOLS_DIR:$SCRIPT_DIR':\$PATH && cd '$role_worktree' && copilot -C '$role_worktree' --name 'SwarmForge ${display}' -i \"\$(cat '$prompt_file')\""
      ;;
    grok)
      launch_cmd="export PATH='$SWARM_TOOLS_DIR:$SCRIPT_DIR':\$PATH && cd '$role_worktree' && grok --cwd '$role_worktree' --permission-mode acceptEdits --rules \"\$(cat '$prompt_file')\""
      ;;
  esac

  if [[ "$index" -eq "${CLEANUP_OWNER_INDEX}" ]]; then
    launch_cmd="${launch_cmd}; exit_code=\$?; SWARMFORGE_TERMINAL_BACKEND='$TERMINAL_BACKEND' nohup '$SCRIPT_DIR/swarm-cleanup.sh' '$TMUX_SOCKET' '$WINDOW_IDS_FILE'"
    local session_name
    for session_name in "${SESSIONS[@]}"; do
      [[ -n "$session_name" ]] || continue
      launch_cmd+=" '$session_name'"
    done
    launch_cmd+=" >/dev/null 2>&1 &!; exit \$exit_code"
  fi

  tmux -S "$TMUX_SOCKET" send-keys -t "$(tmux_agent_target "$session" "$display")" "$launch_cmd" Enter
  if [[ "$agent" == "grok" ]]; then
    send_initial_grok_prompt "$session" "$display" "$prompt_file"
  fi
  echo -e "  ${CYAN}[${display}]${RESET} started in session ${session}"
}

choose_cleanup_owner() {
  CLEANUP_OWNER_INDEX=1
}

check_dependency tmux
check_dependency git
detect_tmux_base_indexes
remove_nonessential_clone_files
initialize_git_repo
ensure_runtime_git_excludes
parse_config
check_backend_dependencies
prepare_workspace
prepare_worktrees
choose_cleanup_owner
TERMINAL_BACKEND="$(detect_terminal_backend)"
load_terminal_backend "$TERMINAL_BACKEND"

local_session=""
for local_session in "${SESSIONS[@]}"; do
  [[ -n "$local_session" ]] || continue
  if tmux -S "$TMUX_SOCKET" has-session -t "$local_session" 2>/dev/null; then
    echo -e "${YELLOW}Existing SwarmForge session found: ${local_session}. Killing it...${RESET}"
    tmux -S "$TMUX_SOCKET" kill-session -t "$local_session"
  fi
done

echo -e "${CYAN}${BOLD}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║           SwarmForge v1.0 Starting            ║"
echo "  ║   Disciplined agents build better software    ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "${GREEN}Launching SwarmForge tmux sessions...${RESET}"
for (( i = 1; i <= ${#ROLES[@]}; i++ )); do
  create_role_session "${SESSIONS[$i]}" "${DISPLAY_NAMES[$i]}"
done

echo -e "${GREEN}Starting agents...${RESET}"
for (( i = 1; i <= ${#ROLES[@]}; i++ )); do
  launch_role "$i"
done

echo ""
echo -e "${GREEN}${BOLD}SwarmForge is ready.${RESET}"
echo -e "Working directory: ${WORKING_DIR}"
echo -e "Sessions:"
for (( i = 1; i <= ${#ROLES[@]}; i++ )); do
  echo -e "  ${DISPLAY_NAMES[$i]}: ${SESSIONS[$i]}"
done
echo ""
echo -e "${GREEN}Tip: Use $WORKING_DIR/swarmtools/notify-agent.sh <role-or-index> --file <message-file> while the swarm is running.${RESET}"
echo -e "${GREEN}Tip: Reattach manually with 'tmux -S $TMUX_SOCKET attach-session -t <session-name>' if needed.${RESET}"
echo ""

if terminal_backend_can_open_sessions; then
  echo -e "Opening separate $(terminal_backend_label) surfaces for each session..."
  if terminal_backend_tracks_windows; then
    : > "$WINDOW_IDS_FILE"
    : > "$WINDOW_STATE_FILE"
  fi
  previous_window_id=""
  for (( i = 1; i <= ${#ROLES[@]}; i++ )); do
    window_id="$(terminal_open_session "${SESSIONS[$i]}" "SwarmForge ${DISPLAY_NAMES[$i]}" "$previous_window_id")"
    if terminal_backend_tracks_windows; then
      echo "$window_id" >> "$WINDOW_IDS_FILE"
      printf '%s\t%s\t%s\t%s\n' \
        "$i" \
        "$window_id" \
        "${SESSIONS[$i]}" \
        "SwarmForge ${DISPLAY_NAMES[$i]}" >> "$WINDOW_STATE_FILE"
      previous_window_id="$window_id"
    fi
  done
  if terminal_backend_tracks_windows; then
    nohup "$SCRIPT_DIR/swarm-window-watchdog.sh" \
      "$WINDOW_STATE_FILE" \
      "$WINDOW_IDS_FILE" \
      "$CLEANUP_OWNER_INDEX" \
      "$TMUX_SOCKET" \
      "$WORKING_DIR" \
      "$TERMINAL_BACKEND" > "$WINDOW_WATCHDOG_LOG" 2>&1 &
  else
    echo -e "${YELLOW}$(terminal_backend_label) surfaces are not trackable; window watchdog is disabled for this backend.${RESET}"
  fi
else
  echo -e "${YELLOW}No terminal backend found; attaching current shell to '${SESSIONS[$CLEANUP_OWNER_INDEX]}' instead.${RESET}"
  tmux -S "$TMUX_SOCKET" attach-session -t "${SESSIONS[$CLEANUP_OWNER_INDEX]}"
fi
