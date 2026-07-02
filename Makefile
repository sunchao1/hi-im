# hi-im meta repo Makefile

COMPOSE_DIR := deploy/compose
COMPOSE := docker compose -f $(COMPOSE_DIR)/docker-compose.yml -f $(COMPOSE_DIR)/docker-compose.m3.yml
PROFILES := --profile infra --profile hub --profile smoke
ENV_FILE := $(COMPOSE_DIR)/.env

ifneq (,$(wildcard $(ENV_FILE)))
COMPOSE += --env-file $(ENV_FILE)
endif

HIIM_HUB_BUILD_CONTEXT ?= $(abspath ../hi-im-core)
export HIIM_HUB_BUILD_CONTEXT

.PHONY: help m3-up m3-down m3-smoke m3-logs versions-validate

help:
	@echo "Targets:"
	@echo "  make m3-up              Start M3 stack (hub + redis + smoke services)"
	@echo "  make m3-down            Stop M3 stack"
	@echo "  make m3-smoke           Up + unicast smoke + down (exit 0/1)"
	@echo "  make m3-logs            Tail compose logs"
	@echo "  make versions-validate  Check versions/lock.yaml"

m3-up:
	$(COMPOSE) $(PROFILES) up -d --build

m3-down:
	$(COMPOSE) $(PROFILES) down -v --remove-orphans

m3-smoke:
	$(COMPOSE) $(PROFILES) up --build --abort-on-container-exit --exit-code-from smoke-runner
	@$(MAKE) m3-down

m3-logs:
	$(COMPOSE) $(PROFILES) logs -f --tail=200

versions-validate:
	@test -f versions/lock.yaml
	@grep -q '^schema:' versions/lock.yaml
	@grep -q '^bundle:' versions/lock.yaml
	@echo "versions/lock.yaml: ok"
