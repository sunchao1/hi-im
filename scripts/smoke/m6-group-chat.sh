#!/usr/bin/env bash
# M6 group chat smoke: dual gateway + GROUP-CREAT/JOIN/CHAT end-to-end.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-deploy/compose}"
COMPOSE_FILES="-f docker-compose.yml -f docker-compose.m3.yml -f docker-compose.m6.yml"
COMPOSE_PROFILES="--profile infra --profile hub --profile biz --profile smoke"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

HIIM_USRSVR_URL="${HIIM_USRSVR_URL:-http://usrsvr:8081}"
HIIM_GATEWAY_A_WS="${HIIM_GATEWAY_A_WS:-ws://gateway:8080/ws}"
HIIM_GATEWAY_B_WS="${HIIM_GATEWAY_B_WS:-ws://gateway-2:8080/ws}"
HIIM_SMOKE_BIN="${HIIM_SMOKE_BIN:-/usr/local/bin/smoke-group}"
HIIM_SMOKE_TIMEOUT="${HIIM_SMOKE_TIMEOUT:-60}"

trap 'log_tail; exit 1' ERR

echo "== M6 group chat smoke =="

wait_ready "http://hub:8080/readyz" "${HIIM_SMOKE_TIMEOUT}"
wait_ready "${HIIM_USRSVR_URL}/readyz" "${HIIM_SMOKE_TIMEOUT}"
wait_ready "http://gateway:8080/readyz" "${HIIM_SMOKE_TIMEOUT}"
wait_ready "http://gateway-2:8080/readyz" "${HIIM_SMOKE_TIMEOUT}"
wait_ready "http://msgsvr:8082/readyz" "${HIIM_SMOKE_TIMEOUT}"
sleep 2

export HIIM_USRSVR_URL HIIM_GATEWAY_A_WS HIIM_GATEWAY_B_WS
"${HIIM_SMOKE_BIN}"

echo "M6 PASS: dual-window group chat"
