#!/usr/bin/env bash
# ai-review-kit notify helper — one desktop notification, no other capability.
# Exists so the headless babysitter can surface "ready for merge" / escalations
# without an allowlist entry for raw osascript (AppleScript can do far too much).
# Usage: ai-review-notify.sh "<message>"
set -euo pipefail
MSG="${1:-ai-review-kit: (empty notification)}"
if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"${MSG//\"/\\\"}\" with title \"ai-review-kit\""
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "ai-review-kit" "$MSG"
else
  echo "[notify] $MSG"
fi
