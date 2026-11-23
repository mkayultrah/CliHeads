#!/bin/zsh
# Builds and opens CliHeads for local use.
set -euo pipefail
cd "${0:A:h}"

# `open` reuses a running copy even after the binary changes, so quit it first.
if pgrep -x CliHeads >/dev/null 2>&1; then
  echo 'Quitting the running CliHeads (it saves its chats first)...'
  osascript -e 'tell application "CliHeads" to quit' >/dev/null 2>&1 || true
  for _ in {1..10}; do pgrep -x CliHeads >/dev/null 2>&1 || break; sleep 0.2; done
  if pgrep -x CliHeads >/dev/null 2>&1; then
    echo 'CliHeads is still running. Quit it from the menu bar icon, then run this again.'
    exit 1
  fi
fi

./Scripts/make-app.sh
open dist/CliHeads.app
