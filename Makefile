# ---------------------------------------------------------------
# Root orchestration
#
# Usage:
#   make infra                               start shared services
#   make infra-down                          stop shared services
#   make pair FRONT=angular BACK=spring      run a frontend + backend pair
#   make fullstack STACK=nextjs              run a standalone fullstack impl
#   make test BACK=spring                    run backend test suite
#   make logs                                tail infra logs
# ---------------------------------------------------------------

# Load shared secrets + infra values; export all to child processes.
ifneq (,$(wildcard .env))
  include .env
  export
endif

FRONT ?= react
BACK  ?= django-drf
STACK ?= nextjs

.PHONY: infra infra-down pair fullstack test logs help \
        _require-env _require-pair-stacks _require-fullstack-stack

# ---------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------

infra: _require-env
	docker compose up -d
	@echo ""
	@echo "  Postgres  → localhost:$(POSTGRES_PORT)"
	@echo "  Redis     → localhost:$(REDIS_PORT)"
	@echo "  Mailpit   → http://localhost:$(MAILPIT_UI_PORT)"
	@echo "  MinIO     → http://localhost:$(MINIO_CONSOLE_PORT)"
	@echo ""

infra-down:
	docker compose down

logs:
	docker compose logs -f

# ---------------------------------------------------------------
# Pair: any frontend + any backend
#
# Variable injection:
#   → backend  receives FRONTEND_URL (for CORS allowlist)
#   → frontend receives API_URL and WS_URL (to reach the backend)
#   Both receive all shared secrets from root .env
# ---------------------------------------------------------------

pair: _require-env _require-pair-stacks
	$(eval BACKEND_PORT  := $(shell grep ^BACKEND_PORT  backend/$(BACK)/stack.env  | cut -d= -f2 | tr -d ' '))
	$(eval FRONTEND_PORT := $(shell grep ^FRONTEND_PORT frontend/$(FRONT)/stack.env | cut -d= -f2 | tr -d ' '))
	@echo ""
	@echo "  backend/$(BACK)   → http://localhost:$(BACKEND_PORT)"
	@echo "  frontend/$(FRONT) → http://localhost:$(FRONTEND_PORT)"
	@echo ""
	BACKEND_PORT=$(BACKEND_PORT) \
	FRONTEND_PORT=$(FRONTEND_PORT) \
	FRONTEND_URL=http://localhost:$(FRONTEND_PORT) \
	API_URL=http://localhost:$(BACKEND_PORT)/api/v1 \
	WS_URL=ws://localhost:$(BACKEND_PORT)/ws \
	npx --yes concurrently \
		--names "$(BACK),$(FRONT)" \
		--prefix-colors "cyan,magenta" \
		--kill-others-on-fail \
		"$(MAKE) --no-print-directory -C backend/$(BACK) dev" \
		"$(MAKE) --no-print-directory -C frontend/$(FRONT) dev"

# ---------------------------------------------------------------
# Fullstack: self-contained implementation
#
# Variable injection:
#   → receives all shared secrets from root .env
#   → receives FRONTEND_URL set to its own origin (for OAuth redirect_uri)
# ---------------------------------------------------------------

fullstack: _require-env _require-fullstack-stack
	$(eval FULLSTACK_PORT := $(shell grep ^FULLSTACK_PORT fullstack/$(STACK)/stack.env | cut -d= -f2 | tr -d ' '))
	@echo ""
	@echo "  fullstack/$(STACK) → http://localhost:$(FULLSTACK_PORT)"
	@echo ""
	FULLSTACK_PORT=$(FULLSTACK_PORT) \
	FRONTEND_URL=http://localhost:$(FULLSTACK_PORT) \
	$(MAKE) --no-print-directory -C fullstack/$(STACK) dev

# ---------------------------------------------------------------
# Tests: run the test suite for a backend or fullstack stack
# ---------------------------------------------------------------

test: _require-env
	$(MAKE) --no-print-directory -C backend/$(BACK) test

# ---------------------------------------------------------------
# Guards
# ---------------------------------------------------------------

_require-env:
	@[ -f .env ] || { \
		echo ""; \
		echo "  Error: .env not found."; \
		echo "  Run: cp .env.example .env  then fill in the values."; \
		echo ""; \
		exit 1; \
	}

_require-pair-stacks:
	@[ -f backend/$(BACK)/stack.env ] || { \
		echo ""; \
		echo "  Error: backend/$(BACK)/stack.env not found."; \
		echo "  Create it with BACKEND_PORT=<port>."; \
		echo ""; \
		exit 1; \
	}
	@[ -f frontend/$(FRONT)/stack.env ] || { \
		echo ""; \
		echo "  Error: frontend/$(FRONT)/stack.env not found."; \
		echo "  Create it with FRONTEND_PORT=<port>."; \
		echo ""; \
		exit 1; \
	}

_require-fullstack-stack:
	@[ -f fullstack/$(STACK)/stack.env ] || { \
		echo ""; \
		echo "  Error: fullstack/$(STACK)/stack.env not found."; \
		echo "  Create it with FULLSTACK_PORT=<port>."; \
		echo ""; \
		exit 1; \
	}

# ---------------------------------------------------------------
# Help
# ---------------------------------------------------------------

help:
	@echo ""
	@echo "Usage:"
	@echo "  make infra                              Start shared services (Postgres, Redis, Mailpit, MinIO)"
	@echo "  make infra-down                         Stop shared services"
	@echo "  make pair FRONT=angular BACK=spring     Run a frontend + backend pair"
	@echo "  make fullstack STACK=nextjs             Run a standalone fullstack implementation"
	@echo "  make test BACK=spring                   Run the backend test suite"
	@echo "  make logs                               Tail infra container logs"
	@echo ""
	@echo "Available backends:"
	@ls backend/ 2>/dev/null | xargs -I{} echo "  {}" || echo "  (none yet)"
	@echo ""
	@echo "Available frontends:"
	@ls frontend/ 2>/dev/null | xargs -I{} echo "  {}" || echo "  (none yet)"
	@echo ""
	@echo "Available fullstack:"
	@ls fullstack/ 2>/dev/null | xargs -I{} echo "  {}" || echo "  (none yet)"
	@echo ""
