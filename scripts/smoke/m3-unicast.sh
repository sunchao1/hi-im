#!/usr/bin/env bash
# M3 unicast smoke: FORWARD consumer + BACKEND producer via hub bridge.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

HIIM_HEALTH_URL="${HIIM_HEALTH_URL:-http://hub:8080/readyz}"
HIIM_SMOKE_READY_FILE="${HIIM_SMOKE_READY_FILE:-/smoke/consumer.ready}"
HIIM_SMOKE_STATE_FILE="${HIIM_SMOKE_STATE_FILE:-/smoke/recv.count}"
HIIM_STUB_BIN="${HIIM_STUB_BIN:-/usr/local/bin/hubclient-stub}"
HIIM_SMOKE_TIMEOUT="${HIIM_SMOKE_TIMEOUT:-30}"
HIIM_PRODUCER_NID="${HIIM_PRODUCER_NID:-50001}"

trap 'log_tail; exit 1' ERR

echo "== M3 unicast smoke =="

wait_ready "${HIIM_HEALTH_URL}" "${HIIM_SMOKE_TIMEOUT}"
wait_file "${HIIM_SMOKE_READY_FILE}" "${HIIM_SMOKE_TIMEOUT}"
sleep 1

export HIIM_NID="${HIIM_PRODUCER_NID}"
"${HIIM_STUB_BIN}" --role=producer --count=3

deadline=$((SECONDS + HIIM_SMOKE_TIMEOUT))
recv=0
while (( SECONDS < deadline )); do
  recv="$(read_recv_count "${HIIM_SMOKE_STATE_FILE}")"
  if [[ -n "${recv}" && "${recv}" -ge 1 ]]; then
    echo "M3 PASS: recv>=1 (recv=${recv})"
    exit 0
  fi
  sleep 1
done

echo "M3 FAIL: consumer recv=${recv}, want >=1 within ${HIIM_SMOKE_TIMEOUT}s" >&2
log_tail
exit 1
