#!/bin/bash
# Атомарный деплой MCP сервера
set -e
echo "=== Building MCP ==="
ssh root@192.168.3.41 "cd /home/judy-infra && docker compose up -d --build mcp"
echo "=== Waiting for MCP ==="
sleep 5
echo "=== Restarting gateway ==="
systemctl restart openclaw-gateway
sleep 10
echo "=== Done ==="
echo "Verify: judy-memory__memory_list(limit=1)"
