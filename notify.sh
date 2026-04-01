#!/bin/bash
# notify.sh — macOS notification via osascript
# Usage: ./notify.sh "message text"
# Exit code: always 0 (notification failure should not break orchestration)
set -euo pipefail

MESSAGE="${1:-Agent Harness event}"

osascript -e "display notification \"${MESSAGE}\" with title \"Agent Harness\" sound name \"Glass\"" 2>/dev/null || true
