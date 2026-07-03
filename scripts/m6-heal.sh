#!/usr/bin/env bash
# Heal M6 ONLINE path after partial docker restarts (hub SUB + gateway resync).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_DIR="$ROOT/deploy/compose"
ENV_FILE="$COMPOSE_DIR/.env"

COMPOSE=(docker compose -f "$COMPOSE_DIR/docker-compose.yml" -f "$COMPOSE_DIR/docker-compose.m3.yml" -f "$COMPOSE_DIR/docker-compose.m6.yml")
PROFILES=(--profile infra --profile hub --profile biz --profile demo)
if [[ -f "$ENV_FILE" ]]; then
  COMPOSE+=(--env-file "$ENV_FILE")
fi

hub_port=18080
demo_port=8088
gw1=28080
if [[ -f "$ENV_FILE" ]]; then
  line=$(grep '^HIIM_HEALTH_HOST_PORT=' "$ENV_FILE" | tail -1 || true)
  [[ -n "$line" ]] && hub_port="${line#HIIM_HEALTH_HOST_PORT=}"
  line=$(grep '^HIIM_DEMO_WEB_PORT=' "$ENV_FILE" | tail -1 || true)
  [[ -n "$line" ]] && demo_port="${line#HIIM_DEMO_WEB_PORT=}"
  line=$(grep '^HIIM_GATEWAY1_HTTP_PORT=' "$ENV_FILE" | tail -1 || true)
  [[ -n "$line" ]] && gw1="${line#HIIM_GATEWAY1_HTTP_PORT=}"
fi

echo "[m6-heal] rebuild + restart hub..."
"${COMPOSE[@]}" "${PROFILES[@]}" up -d --build hub

echo "[m6-heal] wait hub ready..."
for i in $(seq 1 30); do
  curl -sf "http://127.0.0.1:${hub_port}/readyz" >/dev/null 2>&1 && break
  sleep 1
done

echo "[m6-heal] restart backends (usrsvr, msgsvr, seqsvr)..."
"${COMPOSE[@]}" "${PROFILES[@]}" up -d --build usrsvr msgsvr seqsvr

echo "[m6-heal] wait usrsvr/msgsvr ready..."
for i in $(seq 1 30); do
  docker exec hi-im-usrsvr-1 wget -qO- http://127.0.0.1:8081/readyz >/dev/null 2>&1 && \
  docker exec hi-im-msgsvr-1 wget -qO- http://127.0.0.1:8082/readyz >/dev/null 2>&1 && break
  sleep 1
done

echo "[m6-heal] restart gateways..."
"${COMPOSE[@]}" "${PROFILES[@]}" up -d --build gateway gateway-2

echo "[m6-heal] wait gateways ready..."
for i in $(seq 1 30); do
  curl -sf "http://127.0.0.1:${gw1}/readyz" >/dev/null 2>&1 && break
  sleep 1
done

echo "[m6-heal] online probe via demo-web..."
cd "$ROOT/examples/smoke-group"
HIIM_USRSVR_URL="http://127.0.0.1:${demo_port}" \
HIIM_GATEWAY_A_WS="ws://127.0.0.1:${gw1}/ws" \
go run . -online-only

echo ""
echo "M6 heal OK. Open: http://127.0.0.1:${demo_port}/group.html?gw=1"
