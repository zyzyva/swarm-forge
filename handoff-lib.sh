#!/usr/bin/env zsh

handoff_usage_role() {
  echo "Set SWARMFORGE_ROLE or pass --sender/--receiver." >&2
}

handoff_role_or_default() {
  local role="${1:-}"
  if [[ -n "$role" ]]; then
    echo "$role"
    return 0
  fi
  if [[ -n "${SWARMFORGE_ROLE:-}" ]]; then
    echo "$SWARMFORGE_ROLE"
    return 0
  fi
  handoff_usage_role
  return 1
}

handoff_state_dir() {
  echo "$PWD/.swarmforge/handoffs"
}

handoff_temp_file() {
  local dir
  dir="$(handoff_state_dir)/tmp"
  mkdir -p "$dir"
  mktemp "$dir/$1.XXXXXX"
}

handoff_logbook_file() {
  echo "$PWD/logbook.jsonl"
}

handoff_timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

handoff_id_timestamp() {
  date '+%Y%m%d-%H%M%S'
}

handoff_random_hex() {
  od -An -N3 -tx1 /dev/urandom | tr -d ' \n'
}

handoff_json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

handoff_append_logbook() {
  local direction="$1"
  local message="$2"
  local note="$3"
  local logbook
  logbook="$(handoff_logbook_file)"
  printf '{"timestamp":"%s","direction":"%s","message":"%s","note":"%s"}\n' \
    "$(handoff_json_escape "$(handoff_timestamp)")" \
    "$(handoff_json_escape "$direction")" \
    "$(handoff_json_escape "$message")" \
    "$(handoff_json_escape "$note")" >> "$logbook"
}

handoff_next_sequence() {
  local stream="$1"
  local state_dir seq_file last next
  state_dir="$(handoff_state_dir)/outgoing"
  mkdir -p "$state_dir"
  seq_file="$state_dir/$stream.seq"
  if [[ -f "$seq_file" ]]; then
    last="$(< "$seq_file")"
  else
    last=0
  fi
  if [[ ! "$last" == <-> ]]; then
    last=0
  fi
  next=$((last + 1))
  printf '%06d\n' "$next" > "$seq_file"
  printf '%06d' "$next"
}

handoff_message_id() {
  local type="$1"
  local sender="$2"
  local target="$3"
  local sequence="$4"
  printf '%s-%s-%s-%s-%s-%s' \
    "$type" \
    "$(handoff_id_timestamp)" \
    "$sender" \
    "$target" \
    "$sequence" \
    "$(handoff_random_hex)"
}

handoff_field() {
  local field="$1"
  local file="$2"
  local line
  line="$(grep -m 1 -E "^${field}: " "$file" || true)"
  if [[ -z "$line" ]]; then
    return 1
  fi
  printf '%s' "${line#*: }"
}

handoff_sequence_from_id() {
  local message_id="$1"
  local sequence="${message_id%-*}"
  sequence="${sequence##*-}"
  if [[ "$sequence" == [0-9][0-9][0-9][0-9][0-9][0-9] ]]; then
    echo "$sequence"
    return 0
  fi
  return 1
}

handoff_sequence_number() {
  local sequence="$1"
  echo $((10#$sequence))
}

handoff_sequence_range() {
  local start="$1"
  local end="$2"
  printf '%06d-%06d' "$start" "$end"
}

handoff_archive_sent() {
  local stream="$1"
  local sequence="$2"
  local message="$3"
  local dir
  dir="$(handoff_state_dir)/sent/$stream"
  mkdir -p "$dir"
  printf '%s' "$message" > "$dir/$sequence.txt"
}

handoff_archive_received() {
  local stream="$1"
  local sequence="$2"
  local message="$3"
  local archive_status="$4"
  local dir
  dir="$(handoff_state_dir)/received/$stream/$archive_status"
  mkdir -p "$dir"
  printf '%s' "$message" > "$dir/$sequence.txt"
}

handoff_last_received_file() {
  local stream="$1"
  local dir
  dir="$(handoff_state_dir)/incoming"
  mkdir -p "$dir"
  echo "$dir/$stream.seq"
}
