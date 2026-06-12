#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/handoff-lib.sh"

usage() {
  echo "Usage: resend-handoff.sh --stream <sender-target> --sequences <start-end> --target <target-role>" >&2
}

STREAM=""
SEQUENCES=""
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stream)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      STREAM="$2"
      shift 2
      ;;
    --sequences)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      SEQUENCES="$2"
      shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      TARGET="$2"
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$STREAM" || -z "$SEQUENCES" || -z "$TARGET" ]]; then
  usage
  exit 1
fi

START="${SEQUENCES%-*}"
END="${SEQUENCES#*-}"
if [[ "$START" != [0-9][0-9][0-9][0-9][0-9][0-9] || "$END" != [0-9][0-9][0-9][0-9][0-9][0-9] ]]; then
  usage
  exit 1
fi

start_num="$(handoff_sequence_number "$START")"
end_num="$(handoff_sequence_number "$END")"
if (( start_num > end_num )); then
  usage
  exit 1
fi

sent_dir="$(handoff_state_dir)/sent/$STREAM"
for (( n = start_num; n <= end_num; n++ )); do
  seq="$(printf '%06d' "$n")"
  archived="$sent_dir/$seq.txt"
  if [[ ! -f "$archived" ]]; then
    echo "Archived handoff not found: $archived" >&2
    exit 1
  fi
  "$SCRIPT_DIR/notify-agent.sh" "$TARGET" --file "$archived"
  handoff_append_logbook "sent" "$(< "$archived")" "resent $STREAM sequence $seq to $TARGET"
  echo "Resent $STREAM $seq"
done
