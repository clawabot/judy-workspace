#!/bin/bash
# Watchdog для MCP-сервера на judy-infra (192.168.3.41)
# Проверяет доступность MCP, перезапускает при падении

set -e

MCP_HOST="192.168.3.41"
MCP_PORT="8765"
SSH_USER="root"
SSH_PASS="19735"
CONTAINER="judy-infra-app"
LOG_FILE="/root/.openclaw/workspace/memory/maintenance/watchdog-mcp.log"
ALERT_FILE="/root/.openclaw/workspace/memory/maintenance/watchdog-mcp.alert"
MAX_RETRIES=2
COOLDOWN_SEC=60

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Проверка доступности MCP
check_mcp() {
    curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${MCP_HOST}:${MCP_PORT}/" 2>/dev/null || echo "000"
}

# Проверить кулдаун (не дёргать чаще COOLDOWN_SEC)
check_cooldown() {
    if [ -f "$ALERT_FILE" ]; then
        local last_ts=$(cat "$ALERT_FILE")
        local now=$(date +%s)
        if [ $((now - last_ts)) -lt $COOLDOWN_SEC ]; then
            return 1  # кулдаун активен
        fi
    fi
    return 0
}

# Основная логика
status_code=$(check_mcp)

if [ "$status_code" != "200" ] && [ "$status_code" != "404" ]; then
    log "WARN: MCP недоступен (HTTP $status_code)"

    if ! check_cooldown; then
        log "Кулдаун активен, пропускаю"
        exit 0
    fi

    # SSH на сервер и попытка перезапуска
    log "Перезапускаю контейнер $CONTAINER..."
    if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${MCP_HOST}" \
        "docker compose -f /root/judy-infra/docker-compose.yml restart ${CONTAINER}" 2>&1 | tee -a "$LOG_FILE"; then
        log "Контейнер перезапущен, жду 10 сек..."
        sleep 10

        # Повторная проверка
        new_status=$(check_mcp)
        if [ "$new_status" == "200" ] || [ "$new_status" == "404" ]; then
            log "OK: MCP восстановлен (HTTP $new_status)"
            rm -f "$ALERT_FILE"
        else
            log "ERROR: MCP не восстановился после перезапуска (HTTP $new_status)"
            date +%s > "$ALERT_FILE"
        fi
    else
        log "ERROR: Не удалось подключиться к серверу по SSH"
        date +%s > "$ALERT_FILE"
    fi
else
    # MCP жив — сбрасываем алерт
    rm -f "$ALERT_FILE"
fi
