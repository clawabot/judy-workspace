#!/bin/bash
# Gateway error log collector — reads from /tmp/openclaw/openclaw-DATE.log
LOG="/root/.openclaw/workspace/memory/maintenance/errors-$(date +%Y-%m-%d).log"
TODAY_LOG="/tmp/openclaw/openclaw-$(date +%Y-%m-%d).log"
YESTERDAY_LOG="/tmp/openclaw/openclaw-$(date -d yesterday +%Y-%m-%d).log"

{
  [ -f "$TODAY_LOG" ] && grep -iE "error|fail|rejected|abort|timeout|refused|WARN.*error" "$TODAY_LOG"
  [ -f "$YESTERDAY_LOG" ] && grep -iE "error|fail|rejected|abort|timeout|refused|WARN.*error" "$YESTERDAY_LOG"
} | grep -v "HEARTBEAT_OK\|heartbeat" | tail -50 > "$LOG"

echo "$(wc -l < "$LOG")"