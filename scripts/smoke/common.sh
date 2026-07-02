#!/usr/bin/env bash
# Shared helpers for hi-im integration smoke scripts.
set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-deploy/compose}"
COMPOSE_FILES="${COMPOSE_FILES:--f docker-compose.yml -f docker-compose.m3.yml}"
COMPOSE_PROFILES="${COMPOSE_PROFILES:---profile infra --profile hub --profile smoke}"

compose_cmd() {
  # shellcheck disable=SC2086
  docker compose ${COMPOSE_FILES} ${COMPOSE_PROFILES} "$@"
}

wait_ready() {
  local url="${1:?url required}"
  local timeout="${2:-${HIIM_SMOKE_TIMEOUT:-30}}"
  local deadline=$((SECONDS + timeout))

  echo "wait_ready: ${url} (timeout=${timeout}s)"
  while (( SECONDS < deadline )); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      echo "wait_ready: ok"
      return 0
    fi
    sleep 1
  done
  echo "wait_ready: timeout after ${timeout}s" >&2
  return 1
}

wait_file() {
  local path="${1:?path required}"
  local timeout="${2:-${HIIM_SMOKE_TIMEOUT:-30}}"
  local deadline=$((SECONDS + timeout))

  echo "wait_file: ${path} (timeout=${timeout}s)"
  while (( SECONDS < deadline )); do
    if [[ -f "${path}" ]]; then
      echo "wait_file: ok"
      return 0
    fi
    sleep 1
  done
  echo "wait_file: timeout after ${timeout}s" >&2
  return 1
}

read_recv_count() {
  local path="${1:?path required}"
  if [[ ! -f "${path}" ]]; then
    echo 0
    return 0
  fi
  tr -dc '0-9' < "${path}" | head -c 16 || true
}

log_tail() {
  echo "==== compose logs (last 200 lines) ===="
  compose_cmd logs --tail=200 2>/dev/null || true
}

assert_exit() {
  local code="${1:?exit code required}"
  if [[ "${code}" -ne 0 ]]; then
    log_tail
    exit "${code}"
  fi
}
