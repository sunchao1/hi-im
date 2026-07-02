# Changelog

All notable changes to the hi-im meta repo (compose bundles, smoke scripts, version lock).

## [Unreleased]

### Added

- M3 minimal Compose stack: hub, redis, hubclient stub, unicast smoke runner
- `versions/lock.yaml` locking hi-im-core / hi-im-api / hi-im-hubclient v0.1.0
- `make m3-up`, `make m3-down`, `make m3-smoke`, `make versions-validate`
- `scripts/smoke/m3-unicast.sh` — FORWARD consumer + BACKEND producer unicast path
- `examples/hubclient-stub` — minimal Go stub for M3 smoke
- GitHub Actions workflow `smoke-m3.yml`

### Known limits (M3)

- No gateway / WebSocket / msgsvr / group chat demo
- Hub image defaults to local build from sibling `hi-im-core` checkout
