#!/bin/bash
# run-task.sh — Execute a single task via headless Claude
# Usage: ./run-task.sh TASK_ID
# Env: WORKER_ID (optional, defaults to 0)
# Exit codes: 0=success, 1=task failed, 2=system error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

TASK_ID="${1:?Usage: run-task.sh TASK_ID}"
WORKER_ID="${WORKER_ID:-0}"
DB_PATH="db/agent.db"
OUTPUT_FILE="/tmp/claude-out-${TASK_ID}.txt"

# ── Cleanup on exit ─────────────────────────────────────
cleanup() {
  rm -f "/tmp/agent-harness-${TASK_ID}.pid"
}
trap cleanup EXIT INT TERM

# Record PID
echo $$ > "/tmp/agent-harness-${TASK_ID}.pid"

# ── 1. Read task details ────────────────────────────────
TASK_JSON=$(python3 task_picker.py get "$TASK_ID")
if [ -z "$TASK_JSON" ]; then
  echo "[run-task] ERROR: Task $TASK_ID not found." >&2
  exit 2
fi

GOAL=$(echo "$TASK_JSON" | jq -r '.goal')
PROJECT=$(echo "$TASK_JSON" | jq -r '.project')
PROJECT_DIR=$(echo "$TASK_JSON" | jq -r '.project_dir // empty')
ATTEMPT=$(echo "$TASK_JSON" | jq -r '.attempt_count')
MAX_ATTEMPTS=$(echo "$TASK_JSON" | jq -r '.max_attempts')
ROLE=$(echo "$TASK_JSON" | jq -r '.role // "implementer"')
TOUCHES=$(echo "$TASK_JSON" | jq -r '.touches // [] | .[]' 2>/dev/null | sed 's/^/  - /' || true)

# ── 1b. Read role definition ──────────────────────────────
ROLE_FILE="${SCRIPT_DIR}/roles/${ROLE}.md"
ROLE_PROMPT=""
ALLOWED_TOOLS=""
if [ -f "$ROLE_FILE" ]; then
  # 讀取 frontmatter 中的 allowed_tools
  ALLOWED_TOOLS=$(sed -n '/^---$/,/^---$/p' "$ROLE_FILE" | grep 'allowed_tools:' | cut -d':' -f2- | tr -d ' ') || true
  # 讀取 frontmatter 之後的內容作為角色 prompt
  ROLE_PROMPT=$(sed '1,/^---$/d; 1,/^---$/d' "$ROLE_FILE") || true
fi
# 如果角色定義有 allowed_tools，用它覆蓋預設值
if [ -n "$ALLOWED_TOOLS" ]; then
  CLAUDE_TOOLS="$ALLOWED_TOOLS"
else
  CLAUDE_TOOLS="Edit,Write,Bash,Read"
fi

echo "[run-task] Running task $TASK_ID (attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS, worker $WORKER_ID)" >&2
echo "[run-task] Role: $ROLE | Tools: $CLAUDE_TOOLS" >&2

# ── 2. Read memory context ──────────────────────────────
MEMORY_CONTEXT=$(python3 memory.py read "$TASK_ID" 2>/dev/null) || MEMORY_CONTEXT=""

# ── 2b. Read upstream context (前置任務產出 + 祖先決策) ──
UPSTREAM_CONTEXT=$(python3 memory.py read-upstream "$TASK_ID" 2>/dev/null) || UPSTREAM_CONTEXT=""

# ── 2c. Read project brief (所有已完成任務的共享 context) ──
PROJECT_BRIEF=$(python3 memory.py read-brief "$TASK_ID" 2>/dev/null) || PROJECT_BRIEF=""

# ── 2d. Read spawn context (如果是被父任務 spawn 的子任務) ──
SPAWN_CONTEXT=$(python3 memory.py read-spawn-context "$TASK_ID" 2>/dev/null) || SPAWN_CONTEXT=""

# ── 3. Check for previous errors (heal prompt) ──────────
ERROR_HISTORY=$(echo "$TASK_JSON" | jq -r '.last_error // empty')
ERROR_CLASS=$(echo "$TASK_JSON" | jq -r '.error_class // empty')
HEAL_PROMPT=""
if [ -n "$ERROR_HISTORY" ]; then
  HEAL_PROMPT="

PREVIOUS ATTEMPT FAILED with this error:
${ERROR_HISTORY}

Analyze the error and try a different approach. Do NOT repeat the same mistake."
fi

# 迴圈偵測：注入更強的強制指令
if [ "$ERROR_CLASS" = "looping" ]; then
  HEAL_PROMPT="${HEAL_PROMPT}

CRITICAL: 此任務已被偵測為循環卡住（連續產出相同結果）。
你必須使用完全不同的方法。禁止重複任何先前嘗試的方法。
先列出你打算採用的新方法，再開始實作。"
fi

# ── 4. Build prompt ─────────────────────────────────────
PROMPT="${ROLE_PROMPT:+${ROLE_PROMPT}

}You are an autonomous coding agent working on project '${PROJECT}'.

TASK: ${GOAL}
${TOUCHES:+
SCOPE — files you should focus on (do not modify files outside this list unless necessary):
${TOUCHES}
}
${PROJECT_BRIEF:+PROJECT BRIEF (shared context from all completed tasks in this project — key interfaces and decisions):
${PROJECT_BRIEF}
}${UPSTREAM_CONTEXT:+UPSTREAM TASKS (decisions are shown inline; source code must be Read):
${UPSTREAM_CONTEXT}
}${SPAWN_CONTEXT:+PARENT TASK CONTEXT (detailed analysis from the task that spawned you):
${SPAWN_CONTEXT}
}${MEMORY_CONTEXT:+CONTEXT FROM YOUR PREVIOUS ATTEMPTS ON THIS TASK:
${MEMORY_CONTEXT}
}${HEAL_PROMPT}

INSTRUCTIONS:
- Complete the task fully and correctly.
- Work in the current directory.
- CRITICAL: The "關鍵決策" and "祖先決策" shown above are design decisions you must follow — they are NOT in the source code. Before writing ANY code, use the Read tool to read EVERY source code file and handoff manifest listed in UPSTREAM TASKS. Do NOT assume interfaces, naming, or structure — verify by reading the actual files.
- Do not ask questions; make reasonable decisions.

SUB-TASK SPAWNING:
If this task is too large for a single session (5+ files across multiple modules, or clearly separable concerns), you can decompose it:

1. Analyze the codebase first to understand the full scope
2. Write a context file with your analysis:
   cat > /tmp/spawn-context-${TASK_ID}.md << 'CTXEOF'
   <your detailed analysis, interface contracts, architecture notes>
   CTXEOF
3. Spawn sub-tasks:
   python3 ${SCRIPT_DIR}/task_picker.py spawn-subtasks \\
     --parent ${TASK_ID} \\
     --context-file /tmp/spawn-context-${TASK_ID}.md \\
     --subtasks '[{\"id\":\"${TASK_ID}-sub-1\",\"goal\":\"...\",\"verify\":\"...\",\"touches\":[\"...\"]},{\"id\":\"${TASK_ID}-sub-2\",\"goal\":\"...\",\"depends_on\":[\"${TASK_ID}-sub-1\"]}]'
4. After spawning, STOP working. Output your handoff manifest noting you spawned sub-tasks.

WHEN TO SPAWN vs JUST DO IT:
- DO IT if: < 4 files, single coherent change
- SPAWN if: 5+ independent modules, clearly separable concerns
- NEVER spawn for trivial tasks — spawning has overhead

HANDOFF OUTPUT:
When done (whether you completed the work or spawned sub-tasks), output:

\`\`\`json
{
  \"created_files\": [\"path/to/file1\", \"path/to/file2\"],
  \"interfaces\": [\"protocol Foo: func bar() -> String\"],
  \"decisions\": [\"Used X instead of Y because Z\"],
  \"notes\": \"Context for downstream tasks\"
}
\`\`\`

Then a brief markdown summary."

# ── 5. Mark task as running ──────────────────────────────
python3 task_picker.py mark-running "$TASK_ID" "$WORKER_ID"

# ── 6. Determine working directory ──────────────────────
# Priority: project_dir (跨專案) > worktree (並行隔離) > harness dir (fallback)
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
  # 跨專案模式：在目標專案目錄執行
  WORK_DIR="$PROJECT_DIR"
  echo "[run-task] Working in target project: $WORK_DIR" >&2
elif [ "$WORKER_ID" -gt 0 ] && [ -d ".worktrees/w${WORKER_ID}" ]; then
  WORK_DIR="$(pwd)/.worktrees/w${WORKER_ID}"
else
  WORK_DIR="$(pwd)"
fi

# ── 7. Save prompt for traceability ────────────────────
PROMPT_FILE="/tmp/prompt-${TASK_ID}.txt"
printf '%s' "$PROMPT" > "$PROMPT_FILE"

# ── 8. Execute Claude ───────────────────────────────────
START_TIME=$(date +%s)
CLAUDE_EXIT=0

cd "$WORK_DIR" && claude -p "$PROMPT" \
  --allowedTools "$CLAUDE_TOOLS" \
  --dangerously-skip-permissions \
  --output-format json \
  > "$OUTPUT_FILE" 2>&1 || CLAUDE_EXIT=$?

cd "$SCRIPT_DIR"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "[run-task] Claude finished in ${DURATION}s (exit=$CLAUDE_EXIT)" >&2

# ── 9. Write result to memory（含完整 prompt）──────────
python3 memory.py write "$TASK_ID" \
  --output-file "$OUTPUT_FILE" \
  --prompt-file "$PROMPT_FILE" \
  --worker-id "$WORKER_ID" \
  --attempt "$((ATTEMPT + 1))" \
  --duration "$DURATION" \
  --status "running" 2>/dev/null || true

# ── 10. Handle Claude failure ───────────────────────────
if [ "$CLAUDE_EXIT" -ne 0 ]; then
  echo "[run-task] ERROR: Claude execution failed for task $TASK_ID" >&2
  FAILURE_TEXT="Claude exited with code $CLAUDE_EXIT"
  if [ -f "$OUTPUT_FILE" ]; then
    FAILURE_TEXT=$(tail -c 2000 "$OUTPUT_FILE")
  fi
  python3 task_picker.py record-failure "$TASK_ID" "$FAILURE_TEXT"
  exit 1
fi

# ── 11. Extract and save handoff manifest ─────────────
# 從 Claude output 中提取結構化 handoff manifest 供下游任務使用
python3 memory.py extract-handoff "$TASK_ID" "$OUTPUT_FILE" 2>/dev/null || true

# ── 12. Update project brief ──────────────────────────
# 把這個任務的介面和決策追加到 project brief（並行任務共享）
python3 memory.py update-brief "$TASK_ID" 2>/dev/null || true

echo "[run-task] Task $TASK_ID execution complete." >&2
