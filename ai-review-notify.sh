#!/usr/bin/env bash
# ai-review-kit notify helper — one desktop notification, no other capability.
# Exists so the headless babysitter can surface "ready for merge" / escalations
# without an allowlist entry for raw osascript (AppleScript can do far too much).
# Usage: ai-review-notify.sh "<message>"
#
# Best-effort BY CONTRACT: a notification that can't be delivered (no GUI session,
# SSH, no notifier installed) must never fail the calling sweep — always exit 0.
# The message is passed as an argv item, never interpolated into AppleScript source
# (interpolation = injection: a crafted PR title could execute arbitrary AppleScript).
set -u
MSG="${1:-ai-review-kit: (empty notification)}"
if command -v osascript >/dev/null 2>&1; then
  osascript -e 'on run argv' \
            -e 'display notification (item 1 of argv) with title "ai-review-kit"' \
            -e 'end run' -- "$MSG" 2>/dev/null || echo "[notify-fallback] $MSG"
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "ai-review-kit" "$MSG" 2>/dev/null || echo "[notify-fallback] $MSG"
else
  echo "[notify] $MSG"
fi
exit 0
