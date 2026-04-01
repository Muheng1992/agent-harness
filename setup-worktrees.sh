#!/bin/bash
# setup-worktrees.sh — Initialize git worktrees for parallel workers
# Usage: ./setup-worktrees.sh [MAX_WORKERS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

MAX_WORKERS="${1:-4}"

echo "Setting up $MAX_WORKERS worktrees..." >&2

for i in $(seq 0 $((MAX_WORKERS - 1))); do
  BRANCH="agent/worker-${i}"
  WORKTREE=".worktrees/w${i}"

  if [ -d "$WORKTREE" ]; then
    echo "Worktree $WORKTREE already exists, skipping." >&2
    continue
  fi

  # Create branch if it doesn't exist (from current HEAD)
  if ! git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    git branch "$BRANCH" HEAD
    echo "Created branch $BRANCH" >&2
  fi

  # Create worktree
  mkdir -p .worktrees
  git worktree add "$WORKTREE" "$BRANCH"
  echo "Created worktree $WORKTREE on branch $BRANCH" >&2
done

echo "All $MAX_WORKERS worktrees ready." >&2
