#!/bin/bash
# Gateway error log collector — called from health-monitor cron
LOG="/root/.openclaw/workspace/memory/maintenance/errors-$(date +%Y-%m-%d).log"
journalctl -u openclaw-gateway --since "24 hours ago" 2>/dev/null | \
  grep -iE "error|fail|rejected|abort|timeout|refused|WARN.*error" | \
  grep -v "HEARTBEAT_OK\|heartbeat" | \
  tail -50 > "$LOG"
wc -l < "$LOG"
