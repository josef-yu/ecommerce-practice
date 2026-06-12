# Orchestration

How to run any frontend + backend pair, or any fullstack implementation, with automatic variable injection and zero manual wiring.

---

## How it works

```
root/.env          ← shared secrets + infra addresses (one file, all stacks share it)
     │
     │  make pair FRONT=angular BACK=spring
     │
     ├──▶ backend/spring/stack.env   reads BACKEND_PORT=8080
     │         │
     │         │  Makefile injects:
     │         │    FRONTEND_URL=http://localhost:4200   ← where the frontend is
     │         │    + all root .env vars
     │         ▼
     │    backend/spring/  make dev  ────── runs on :8080
     │
     └──▶ frontend/angular/stack.env  reads FRONTEND_PORT=4200
               │
               │  Makefile injects:
               │    API_URL=http://localhost:8080/api/v1  ← where the backend is
               │    WS_URL=ws://localhost:8080/ws
               │    + PAYMENT_PUBLISHABLE_KEY from root .env
               ▼
          frontend/angular/  make dev  ───── runs on :4200
```

The root Makefile reads both ports, then injects the cross-references. No manual editing of URLs.

---

## Quick start

```bash
# 1. Copy and fill in shared secrets
cp .env.example .env

# 2. Start shared infrastructure (Postgres, Redis, Mailpit, MinIO)
make infra

# 3. Run a pair
make pair FRONT=angular BACK=spring

# 4. Or run a fullstack implementation
make fullstack STACK=nextjs
```

---

## The `stack.env` contract

Every stack must have a `stack.env` file at its root. This is the only thing the root Makefile reads from the individual stack — everything else flows through environment variables.

**`backend/<stack>/stack.env`**
```
BACKEND_PORT=8000
```

**`frontend/<stack>/stack.env`**
```
FRONTEND_PORT=4200
```

**`fullstack/<stack>/stack.env`**
```
FULLSTACK_PORT=3000
```

Use a different port for each stack so multiple implementations can coexist:

| Stack | Type | Port |
|---|---|---|
| django-drf | backend | 8000 |
| spring | backend | 8080 |
| express | backend | 3001 |
| rails | backend | 3030 |
| react | frontend | 5173 |
| angular | frontend | 4200 |
| vue | frontend | 5174 |
| nextjs | fullstack | 3000 |
| sveltekit | fullstack | 5000 |

---

## The `Makefile` contract

Every stack must expose two targets in its own `Makefile`. The root orchestrator calls these — it does not know anything else about the stack.

```makefile
dev   # Start the development server in the foreground (do not daemonise)
test  # Run the full test suite and exit with a non-zero code on failure
```

The stack's `make dev` reads its configuration entirely from environment variables — **not** from a local `.env` file. All variables arrive via the root Makefile's `export`.

---

## Variables injected into each stack

### Backend

| Variable | Source | Description |
|---|---|---|
| `FRONTEND_URL` | derived from `frontend/stack.env` | Set as the CORS allowed origin |
| `BACKEND_PORT` | from `backend/stack.env` | The port to bind to |
| `POSTGRES_DB` | root `.env` | |
| `POSTGRES_USER` | root `.env` | |
| `POSTGRES_PASSWORD` | root `.env` | |
| `POSTGRES_PORT` | root `.env` | |
| `REDIS_PORT` | root `.env` | |
| `SMTP_PORT` | root `.env` | |
| `MINIO_PORT` | root `.env` | |
| `MINIO_ROOT_USER` | root `.env` | |
| `MINIO_ROOT_PASSWORD` | root `.env` | |
| `JWT_SECRET` | root `.env` | |
| `PAYMENT_SECRET_KEY` | root `.env` | Server-side payment key |
| `PAYMENT_WEBHOOK_SECRET` | root `.env` | |
| `CARRIER_WEBHOOK_SECRET` | root `.env` | |
| `GOOGLE_CLIENT_ID` | root `.env` | |
| `GOOGLE_CLIENT_SECRET` | root `.env` | |

The backend's `Makefile` assembles higher-level connection strings from these primitives:

```makefile
# backend/spring/Makefile
dev:
	DATABASE_URL=postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@localhost:$(POSTGRES_PORT)/$(POSTGRES_DB) \
	REDIS_URL=redis://localhost:$(REDIS_PORT) \
	SMTP_HOST=localhost \
	STORAGE_ENDPOINT=http://localhost:$(MINIO_PORT) \
	STORAGE_ACCESS_KEY=$(MINIO_ROOT_USER) \
	STORAGE_SECRET_KEY=$(MINIO_ROOT_PASSWORD) \
	./mvnw spring-boot:run -Dspring-boot.run.jvmArguments="-Dserver.port=$(BACKEND_PORT)"
```

```makefile
# backend/django-drf/Makefile
dev:
	DATABASE_URL=postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@localhost:$(POSTGRES_PORT)/$(POSTGRES_DB) \
	REDIS_URL=redis://localhost:$(REDIS_PORT) \
	SMTP_HOST=localhost \
	STORAGE_ENDPOINT=http://localhost:$(MINIO_PORT) \
	STORAGE_ACCESS_KEY=$(MINIO_ROOT_USER) \
	STORAGE_SECRET_KEY=$(MINIO_ROOT_PASSWORD) \
	python manage.py runserver 0.0.0.0:$(BACKEND_PORT)
```

### Frontend

| Variable | Source | Description |
|---|---|---|
| `API_URL` | derived from `backend/stack.env` | Full base URL for REST calls, e.g. `http://localhost:8080/api/v1` |
| `WS_URL` | derived from `backend/stack.env` | WebSocket endpoint, e.g. `ws://localhost:8080/ws` |
| `FRONTEND_PORT` | from `frontend/stack.env` | The port to bind to |
| `PAYMENT_PUBLISHABLE_KEY` | root `.env` | Client-side Stripe key |

Each frontend framework has its own convention for reading env vars at build/dev time. The stack's `Makefile` is responsible for the mapping:

```makefile
# frontend/angular/Makefile  (uses NG_APP_* prefix, Angular 14+)
dev:
	NG_APP_API_URL=$(API_URL) \
	NG_APP_WS_URL=$(WS_URL) \
	NG_APP_STRIPE_KEY=$(PAYMENT_PUBLISHABLE_KEY) \
	ng serve --port $(FRONTEND_PORT) --host 0.0.0.0
```

```makefile
# frontend/react/Makefile  (Vite — uses VITE_ prefix)
dev:
	VITE_API_URL=$(API_URL) \
	VITE_WS_URL=$(WS_URL) \
	VITE_STRIPE_KEY=$(PAYMENT_PUBLISHABLE_KEY) \
	vite --port $(FRONTEND_PORT)
```

```makefile
# frontend/vue/Makefile  (also Vite)
dev:
	VITE_API_URL=$(API_URL) \
	VITE_WS_URL=$(WS_URL) \
	VITE_STRIPE_KEY=$(PAYMENT_PUBLISHABLE_KEY) \
	vite --port $(FRONTEND_PORT)
```

```makefile
# frontend/react-cra/Makefile  (Create React App — uses REACT_APP_ prefix)
dev:
	REACT_APP_API_URL=$(API_URL) \
	REACT_APP_WS_URL=$(WS_URL) \
	REACT_APP_STRIPE_KEY=$(PAYMENT_PUBLISHABLE_KEY) \
	PORT=$(FRONTEND_PORT) react-scripts start
```

### Fullstack

Receives all backend variables plus:

| Variable | Source | Description |
|---|---|---|
| `FRONTEND_URL` | set to `http://localhost:FULLSTACK_PORT` | Used as the OAuth `redirect_uri` allowlist origin |
| `FULLSTACK_PORT` | from `fullstack/stack.env` | The port to bind to |
| `PAYMENT_PUBLISHABLE_KEY` | root `.env` | Needed client-side |

```makefile
# fullstack/nextjs/Makefile
dev:
	DATABASE_URL=postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@localhost:$(POSTGRES_PORT)/$(POSTGRES_DB) \
	REDIS_URL=redis://localhost:$(REDIS_PORT) \
	SMTP_HOST=localhost \
	STORAGE_ENDPOINT=http://localhost:$(MINIO_PORT) \
	STORAGE_ACCESS_KEY=$(MINIO_ROOT_USER) \
	STORAGE_SECRET_KEY=$(MINIO_ROOT_PASSWORD) \
	NEXT_PUBLIC_STRIPE_KEY=$(PAYMENT_PUBLISHABLE_KEY) \
	PORT=$(FULLSTACK_PORT) \
	next dev
```

---

## Adding a new stack

1. Create the folder: `backend/<stack>/`, `frontend/<stack>/`, or `fullstack/<stack>/`.
2. Create `stack.env` declaring the port.
3. Create a `Makefile` with `dev` and `test` targets that read from environment variables.
4. Run `make infra` once (if not already running).
5. Run `make pair FRONT=<x> BACK=<stack>` or `make fullstack STACK=<stack>`.

No changes to the root `Makefile`, `docker-compose.yml`, or `.env.example` are needed.

---

## Running multiple pairs simultaneously

Each implementation uses a different port (see the port table above), so multiple pairs can run at the same time in separate terminals:

```bash
# Terminal 1
make pair FRONT=react BACK=django-drf

# Terminal 2
make pair FRONT=angular BACK=spring
```

Both share the same Postgres and Redis instances. Use a separate database name per stack if you need data isolation:

```
# backend/spring/stack.env
BACKEND_PORT=8080
POSTGRES_DB_OVERRIDE=ecommerce_spring   # optional; the stack's Makefile uses this if set
```
