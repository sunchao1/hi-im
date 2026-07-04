#!/usr/bin/env bash
# Heal M6 ONLINE path after partial docker restarts (hub SUB + gateway nid resync).
# Order per doc/常见错误集.md §2: hub → usrsvr/msgsvr → gateway (once each wave).
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
gw2=28081
if [[ -f "$ENV_FILE" ]]; then
  line=$(grep '^HIIM_HEALTH_HOST_PORT=' "$ENV_FILE" | tail -1 || true)
  [[ -n "$line" ]] && hub_port="${line#HIIM_HEALTH_HOST_PORT=}"
  line=$(grep '^HIIM_DEMO_WEB_PORT=' "$ENV_FILE" | tail -1 || true)
  [[ -n "$line" ]] && demo_port="${line#HIIM_DEMO_WEB_PORT=}"
  line=$(grep '^HIIM_GATEWAY1_HTTP_PORT=' "$ENV_FILE" | tail -1 || true)
  [[ -n "$line" ]] && gw1="${line#HIIM_GATEWAY1_HTTP_PORT=}"
  line=$(grep '^HIIM_GATEWAY2_HTTP_PORT=' "$ENV_FILE" | tail -1 || true)
  [[ -n "$line" ]] && gw2="${line#HIIM_GATEWAY2_HTTP_PORT=}"
fi

# compose healthcheck: interval 5s * retries 12 => up to ~60s; add buffer.
HEALTH_TIMEOUT="${HIIM_M6_HEALTH_TIMEOUT:-70}"
SETTLE_SECS="${HIIM_M6_SETTLE_SECS:-6}"
PROBE_RETRIES="${HIIM_M6_PROBE_RETRIES:-3}"

ctr_hub=hi-im-hub-1
ctr_usrsvr=hi-im-usrsvr-1
ctr_msgsvr=hi-im-msgsvr-1
ctr_gw1=hi-im-gateway-1
ctr_gw2=hi-im-gateway-2-1
ctr_demo=hi-im-demo-web-1

wait_readyz() {
  local url="$1"
  local timeout="${2:-$HEALTH_TIMEOUT}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if curl -sf "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "[m6-heal] ERROR: readyz timeout: $url" >&2
  return 1
}

wait_container_healthy() {
  local name="$1"
  local timeout="${2:-$HEALTH_TIMEOUT}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    local status
    status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || echo missing)
    case "$status" in
      healthy) return 0 ;;
      missing)
        echo "[m6-heal] ERROR: container not found: $name" >&2
        return 1
        ;;
      unhealthy)
        echo "[m6-heal] WARN: $name unhealthy, waiting..." >&2
        ;;
    esac
    sleep 1
  done
  echo "[m6-heal] ERROR: $name not healthy after ${timeout}s (last=$status)" >&2
  return 1
}

wait_backends_ready() {
  wait_container_healthy "$ctr_usrsvr" "$HEALTH_TIMEOUT"
  wait_container_healthy "$ctr_msgsvr" "$HEALTH_TIMEOUT"
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if docker exec "$ctr_usrsvr" wget -qO- http://127.0.0.1:8081/readyz >/dev/null 2>&1 && \
       docker exec "$ctr_msgsvr" wget -qO- http://127.0.0.1:8082/readyz >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "[m6-heal] ERROR: backend readyz timeout" >&2
  return 1
}

wait_gateways_ready() {
  wait_container_healthy "$ctr_gw1" "$HEALTH_TIMEOUT"
  wait_container_healthy "$ctr_gw2" "$HEALTH_TIMEOUT"
  wait_readyz "http://127.0.0.1:${gw1}/readyz" 30
  wait_readyz "http://127.0.0.1:${gw2}/readyz" 30
  # Stability pass: both gateways must stay ready after health flips.
  sleep 2
  wait_readyz "http://127.0.0.1:${gw1}/readyz" 10
  wait_readyz "http://127.0.0.1:${gw2}/readyz" 10
}

settle() {
  echo "[m6-heal] settle ${SETTLE_SECS}s..."
  sleep "$SETTLE_SECS"
}

# Single ordered wave: hub clears nid table → backends SUB → gateways register once.
# Never restart gateways again without restarting hub first (stale async_send nid).
ordered_restart() {
  echo "[m6-heal] restart hub..."
  docker restart "$ctr_hub" >/dev/null
  wait_container_healthy "$ctr_hub" "$HEALTH_TIMEOUT"
  wait_readyz "http://127.0.0.1:${hub_port}/readyz" 30
  settle

  echo "[m6-heal] restart backends (usrsvr, msgsvr)..."
  docker restart "$ctr_usrsvr" "$ctr_msgsvr" >/dev/null
  wait_backends_ready
  settle

  echo "[m6-heal] restart gateways..."
  docker restart "$ctr_gw1" "$ctr_gw2" >/dev/null
  wait_gateways_ready
  settle
}

ensure_demo_web() {
  if docker inspect --format='{{.State.Running}}' "$ctr_demo" 2>/dev/null | grep -q true; then
    echo "[m6-heal] demo-web already running, skip start"
    return 0
  fi
  echo "[m6-heal] start demo-web (--no-deps, deps already healthy)..."
  "${COMPOSE[@]}" "${PROFILES[@]}" up -d --no-deps demo-web
}

run_online_probe() {
  cd "$ROOT/examples/smoke-group"
  HIIM_USRSVR_URL="http://127.0.0.1:${demo_port}" \
  HIIM_GATEWAY_A_WS="ws://127.0.0.1:${gw1}/ws" \
  go run . -online-only
}

echo "[m6-heal] ensure M6 containers exist (rebuild hub for bridge IM-header routing)..."
"${COMPOSE[@]}" "${PROFILES[@]}" up -d --build hub
"${COMPOSE[@]}" "${PROFILES[@]}" up -d usrsvr msgsvr seqsvr gateway gateway-2

echo "[m6-heal] ordered restart wave (hub → backends → gateways)..."
ordered_restart

ensure_demo_web

echo "[m6-heal] wait demo-web ready..."
wait_readyz "http://127.0.0.1:${demo_port}/group.html" 30
sleep 2

echo "[m6-heal] online probe via demo-web (up to ${PROBE_RETRIES} attempts)..."
probe_ok=0
for attempt in $(seq 1 "$PROBE_RETRIES"); do
  if [[ "$attempt" -gt 1 ]]; then
    backoff=$((attempt * 4))
    echo "[m6-heal] probe attempt ${attempt}/${PROBE_RETRIES} (backoff ${backoff}s)..."
    sleep "$backoff"
    echo "[m6-heal] probe retry: full ordered restart..."
    ordered_restart
    ensure_demo_web
    wait_readyz "http://127.0.0.1:${demo_port}/group.html" 30
    sleep 2
  fi
  if run_online_probe; then
    probe_ok=1
    break
  fi
  echo "[m6-heal] WARN: online probe attempt ${attempt} failed" >&2
done

if [[ "$probe_ok" != 1 ]]; then
  echo "[m6-heal] ERROR: online probe failed after ${PROBE_RETRIES} attempts" >&2
  echo "[m6-heal] hints:" >&2
  echo "  docker logs $ctr_gw1 2>&1 | grep 'online:' | tail -3" >&2
  echo "  docker logs $ctr_usrsvr 2>&1 | grep 'online:' | tail -3" >&2
  echo "  docker logs $ctr_hub 2>&1 | grep bridge | tail -5" >&2
  exit 1
fi

echo ""
echo "M6 heal OK. Open: http://127.0.0.1:${demo_port}/group.html?gw=1"
