#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/handoff-lib.sh"

usage() {
  echo "Usage: send-handoff.sh <target-role> --file <body-file> [--sender <sender-role>] [--type handoff|resend-request]" >&2
}

if [[ $# -lt 3 ]]; then
  usage
  exit 1
fi

TARGET="$1"
shift

BODY_FILE=""
SENDER_ARG=""
MESSAGE_TYPE="handoff"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      BODY_FILE="$2"
      shift 2
      ;;
    --sender)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      SENDER_ARG="$2"
      shift 2
      ;;
    --type)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      MESSAGE_TYPE="$2"
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ "$MESSAGE_TYPE" != "handoff" && "$MESSAGE_TYPE" != "resend-request" ]]; then
  usage
  exit 1
fi

if [[ -z "$BODY_FILE" || ! -f "$BODY_FILE" ]]; then
  echo "Body file not found: $BODY_FILE" >&2
  exit 1
fi

SENDER="$(handoff_role_or_default "$SENDER_ARG")"
STREAM="${SENDER}-${TARGET}"
SEQUENCE="$(handoff_next_sequence "$STREAM")"
MESSAGE_ID="$(handoff_message_id "$MESSAGE_TYPE" "$SENDER" "$TARGET" "$SEQUENCE")"
BODY="$(< "$BODY_FILE")"

MESSAGE=$(cat <<EOF
message type: $MESSAGE_TYPE
message id: $MESSAGE_ID
sender role: $SENDER
target role: $TARGET
message sequence: $SEQUENCE

$BODY
EOF
)

ARCHIVE_FILE="$(handoff_temp_file "send-handoff")"
printf '%s' "$MESSAGE" > "$ARCHIVE_FILE"
handoff_archive_sent "$STREAM" "$SEQUENCE" "$MESSAGE"
"$SCRIPT_DIR/notify-agent.sh" "$TARGET" --file "$ARCHIVE_FILE"
handoff_append_logbook "sent" "$MESSAGE" "$MESSAGE_TYPE $MESSAGE_ID sent to $TARGET"

echo "Sent $MESSAGE_ID"
