# hi-im meta repo Makefile

COMPOSE_DIR := deploy/compose
COMPOSE_M3 := docker compose -f $(COMPOSE_DIR)/docker-compose.yml -f $(COMPOSE_DIR)/docker-compose.m3.yml
COMPOSE_M6 := docker compose -f $(COMPOSE_DIR)/docker-compose.yml -f $(COMPOSE_DIR)/docker-compose.m3.yml -f $(COMPOSE_DIR)/docker-compose.m6.yml
PROFILES_M3 := --profile infra --profile hub --profile m3-smoke
PROFILES_M6 := --profile infra --profile hub --profile biz --profile smoke
PROFILES_DEMO := --profile infra --profile hub --profile biz --profile demo
ENV_FILE := $(COMPOSE_DIR)/.env

ifneq (,$(wildcard $(ENV_FILE)))
COMPOSE_M3 += --env-file $(ENV_FILE)
COMPOSE_M6 += --env-file $(ENV_FILE)
endif

HIIM_HUB_BUILD_CONTEXT ?= $(abspath ../hi-im-core)
HIIM_BUILD_ROOT ?= $(abspath ..)
export HIIM_HUB_BUILD_CONTEXT
export HIIM_BUILD_ROOT

.PHONY: help m3-up m3-down m3-smoke m3-logs m6-up m6-down m6-smoke m6-demo m6-logs versions-validate

help:
	@echo "Targets:"
	@echo "  make m3-up              Start M3 stack (hub + redis + smoke services)"
	@echo "  make m3-down            Stop M3 stack"
	@echo "  make m3-smoke           Up + unicast smoke + down (exit 0/1)"
	@echo "  make m3-logs            Tail compose logs"
	@echo "  make m6-up              Start M6 stack (group chat)"
	@echo "  make m6-smoke           M6 dual-window group chat smoke"
	@echo "  make m6-demo            M6 stack + demo-web (http://127.0.0.1:8088/group.html)"
	@echo "  make m6-down            Stop M6 stack"
	@echo "  make m6-logs            Tail M6 compose logs"
	@echo "  make versions-validate  Check versions/lock.yaml"

m3-up:
	$(COMPOSE_M3) $(PROFILES_M3) up -d --build

m3-down:
	$(COMPOSE_M3) $(PROFILES_M3) down -v --remove-orphans

m3-smoke:
	$(COMPOSE_M3) $(PROFILES_M3) up --build --abort-on-container-exit --exit-code-from smoke-runner
	@$(MAKE) m3-down

m3-logs:
	$(COMPOSE_M3) $(PROFILES_M3) logs -f --tail=200

m6-up:
	$(COMPOSE_M6) $(PROFILES_M6) up -d --build

m6-down:
	$(COMPOSE_M6) $(PROFILES_M6) down -v --remove-orphans

m6-smoke:
	$(COMPOSE_M6) $(PROFILES_M6) up --build --abort-on-container-exit --exit-code-from m6-smoke-runner
	@$(MAKE) m6-down

m6-demo:
	$(COMPOSE_M6) $(PROFILES_DEMO) up -d --build
	@echo "Open http://127.0.0.1:$${HIIM_DEMO_WEB_PORT:-8088}/group.html (two browser windows)"

m6-logs:
	$(COMPOSE_M6) $(PROFILES_DEMO) logs -f --tail=200

versions-validate:
	@test -f versions/lock.yaml
	@grep -q '^schema:' versions/lock.yaml
	@grep -q '^bundle:' versions/lock.yaml
	@echo "versions/lock.yaml: ok"
