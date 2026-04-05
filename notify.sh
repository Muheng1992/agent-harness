#!/bin/bash
# notify.sh — 通知系統（macOS 桌面通知 + 終端鈴聲）
# 用法：
#   ./notify.sh "訊息"                    # 一般通知（info）
#   ./notify.sh "訊息" --level success    # 成功通知
#   ./notify.sh "訊息" --level error      # 錯誤通知
#   ./notify.sh "訊息" --level escalated  # 升級通知（含鈴聲）
#   ./notify.sh "訊息" --level done       # 全部完成通知（含鈴聲）
#
# 環境變數：
#   AGENT_NOTIFY_BELL=1      啟用終端鈴聲（預設啟用）
#   AGENT_NOTIFY_DESKTOP=1   啟用桌面通知（預設啟用）
#   AGENT_NOTIFY_LOG=1       寫入通知日誌（預設啟用）
#
# Exit code: always 0（通知失敗不應中斷 orchestration）
set -euo pipefail

MESSAGE="${1:-Agent Harness event}"
LEVEL="info"

# 解析參數
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level)
      LEVEL="${2:-info}"; shift 2 ;;
    *)
      shift ;;
  esac
done

# 設定
BELL="${AGENT_NOTIFY_BELL:-1}"
DESKTOP="${AGENT_NOTIFY_DESKTOP:-1}"
LOG="${AGENT_NOTIFY_LOG:-1}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/db/notify.log"

# 根據層級選擇音效和標題
case "$LEVEL" in
  success)
    SOUND="Glass"
    TITLE="✅ Agent Harness"
    ;;
  error)
    SOUND="Basso"
    TITLE="❌ Agent Harness"
    ;;
  escalated)
    SOUND="Sosumi"
    TITLE="🚨 Agent Harness — 需要介入"
    ;;
  done)
    SOUND="Hero"
    TITLE="🎉 Agent Harness — 全部完成"
    ;;
  *)
    SOUND="Glass"
    TITLE="Agent Harness"
    ;;
esac

# ── 桌面通知 ──────────────────────────────────────────────
if [ "$DESKTOP" = "1" ]; then
  osascript -e "display notification \"${MESSAGE}\" with title \"${TITLE}\" sound name \"${SOUND}\"" 2>/dev/null || true
fi

# ── 終端鈴聲 ──────────────────────────────────────────────
# escalated 和 done 層級會發出鈴聲
if [ "$BELL" = "1" ]; then
  case "$LEVEL" in
    escalated)
      # 三次鈴聲，引起注意
      printf '\a' 2>/dev/null || true
      sleep 0.3
      printf '\a' 2>/dev/null || true
      sleep 0.3
      printf '\a' 2>/dev/null || true
      ;;
    done)
      # 兩次鈴聲
      printf '\a' 2>/dev/null || true
      sleep 0.5
      printf '\a' 2>/dev/null || true
      ;;
    error)
      printf '\a' 2>/dev/null || true
      ;;
    *)
      # info / success 不發鈴聲（避免打擾）
      ;;
  esac
fi

# ── 寫入日誌 ──────────────────────────────────────────────
if [ "$LOG" = "1" ]; then
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$TIMESTAMP] [$LEVEL] $MESSAGE" >> "$LOG_FILE" 2>/dev/null || true
fi

exit 0
