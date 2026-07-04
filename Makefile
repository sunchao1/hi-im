# hi-im meta repo Makefile

COMPOSE_DIR := deploy/compose
COMPOSE_M3 := docker compose -f $(COMPOSE_DIR)/docker-compose.yml -f $(COMPOSE_DIR)/docker-compose.m3.yml
COMPOSE_M6 := docker compose -f $(COMPOSE_DIR)/docker-compose.yml -f $(COMPOSE_DIR)/docker-compose.m3.yml -f $(COMPOSE_DIR)/docker-compose.m6.yml
PROFILES_M3 := --profile infra --profile hub --profile m3-smoke
PROFILES_M6_BIZ := --profile infra --profile hub --profile biz
PROFILES_M6_SMOKE := --profile infra --profile hub --profile biz --profile smoke
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

.PHONY: help m3-up m3-down m3-smoke m3-logs m6-up m6-down m6-smoke m6-demo m6-heal m6-wait-ready m6-logs versions-validate

help:
	@echo "Targets:"
	@echo "  make m3-up              Start M3 stack (hub + redis + smoke services)"
	@echo "  make m3-down            Stop M3 stack"
	@echo "  make m3-smoke           Up + unicast smoke + down (exit 0/1)"
	@echo "  make m3-logs            Tail compose logs"
	@echo "  make m6-up              Start M6 stack (group chat)"
	@echo "  make m6-smoke           M6 dual-window group chat smoke"
	@echo "  make m6-demo            M6 stack + demo-web (see deploy/compose/.env HIIM_DEMO_WEB_PORT)"
	@echo "  make m6-heal            Ordered restart + demo-web + ONLINE probe (after partial docker restart)"
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
	$(COMPOSE_M6) $(PROFILES_M6_BIZ) up -d --build

m6-down:
	$(COMPOSE_M6) $(PROFILES_M6_BIZ) --profile demo down -v --remove-orphans

m6-smoke:
	$(COMPOSE_M6) $(PROFILES_M6_SMOKE) up --build --abort-on-container-exit --exit-code-from m6-smoke-runner
	@$(MAKE) m6-down

m6-demo:
	$(COMPOSE_M6) $(PROFILES_M6_BIZ) --profile demo up -d --build
	@$(MAKE) m6-wait-ready
	@port=8088; hub_port=18080; gw1=28080; \
	if [ -f $(ENV_FILE) ]; then \
	  line=$$(grep '^HIIM_DEMO_WEB_PORT=' $(ENV_FILE) | tail -1); \
	  if [ -n "$$line" ]; then port=$${line#HIIM_DEMO_WEB_PORT=}; fi; \
	  line=$$(grep '^HIIM_HEALTH_HOST_PORT=' $(ENV_FILE) | tail -1); \
	  if [ -n "$$line" ]; then hub_port=$${line#HIIM_HEALTH_HOST_PORT=}; fi; \
	  line=$$(grep '^HIIM_GATEWAY1_HTTP_PORT=' $(ENV_FILE) | tail -1); \
	  if [ -n "$$line" ]; then gw1=$${line#HIIM_GATEWAY1_HTTP_PORT=}; fi; \
	fi; \
	echo ""; \
	echo "hi-im M6 群聊 Demo（勿用 8088，那是 beehive 旧 demo）:"; \
	echo "  窗口 A: http://127.0.0.1:$$port/group.html?gw=1  uid=100001"; \
	echo "  窗口 B: http://127.0.0.1:$$port/group.html?gw=2  uid=100002"; \
	echo "  先点「注册并连接」，日志出现 ONLINE ok 后再建群"; \
  echo "  若仍 ONLINE-ACK 超时: make m6-heal  (或 make m6-down && make m6-demo)"; \
	echo "  自检: curl -sf http://127.0.0.1:$$hub_port/readyz && curl -sf http://127.0.0.1:$$gw1/readyz"; \
	echo ""

m6-heal:
	@bash scripts/m6-heal.sh

m6-wait-ready:
	@hub_port=18080; gw1=28080; gw2=28081; probe_port=8088; \
	if [ -f $(ENV_FILE) ]; then \
	  line=$$(grep '^HIIM_HEALTH_HOST_PORT=' $(ENV_FILE) | tail -1); \
	  if [ -n "$$line" ]; then hub_port=$${line#HIIM_HEALTH_HOST_PORT=}; fi; \
	  line=$$(grep '^HIIM_GATEWAY1_HTTP_PORT=' $(ENV_FILE) | tail -1); \
	  if [ -n "$$line" ]; then gw1=$${line#HIIM_GATEWAY1_HTTP_PORT=}; fi; \
	  line=$$(grep '^HIIM_GATEWAY2_HTTP_PORT=' $(ENV_FILE) | tail -1); \
	  if [ -n "$$line" ]; then gw2=$${line#HIIM_GATEWAY2_HTTP_PORT=}; fi; \
	  line=$$(grep '^HIIM_DEMO_WEB_PORT=' $(ENV_FILE) | tail -1); \
	  if [ -n "$$line" ]; then probe_port=$${line#HIIM_DEMO_WEB_PORT=}; fi; \
	fi; \
	echo "Waiting for M6 stack..."; \
	ready=0; \
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do \
	  curl -sf "http://127.0.0.1:$$hub_port/readyz" >/dev/null 2>&1 && \
	  curl -sf "http://127.0.0.1:$$gw1/readyz" >/dev/null 2>&1 && \
	  curl -sf "http://127.0.0.1:$$gw2/readyz" >/dev/null 2>&1 && \
	  docker exec hi-im-usrsvr-1 wget -qO- http://127.0.0.1:8081/readyz >/dev/null 2>&1 && \
	  docker exec hi-im-msgsvr-1 wget -qO- http://127.0.0.1:8082/readyz >/dev/null 2>&1 && \
	  ready=1 && break; \
	  sleep 2; \
	done; \
	if [ "$$ready" != 1 ]; then \
	  echo "WARN: stack not fully ready; run make m6-heal if ONLINE-ACK times out."; \
	  exit 0; \
	fi; \
	echo "M6 stack ready."; \
	echo "Running ONLINE probe..."; \
	(cd examples/smoke-group && HIIM_USRSVR_URL=http://127.0.0.1:$$probe_port HIIM_GATEWAY_A_WS=ws://127.0.0.1:$$gw1/ws go run . -online-only) || \
	  (echo "WARN: ONLINE probe failed — run: make m6-heal"; exit 0)

m6-logs:
	$(COMPOSE_M6) $(PROFILES_M6_BIZ) --profile demo logs -f --tail=200

versions-validate:
	@test -f versions/lock.yaml
	@grep -q '^schema:' versions/lock.yaml
	@grep -q '^bundle:' versions/lock.yaml
	@echo "versions/lock.yaml: ok"
