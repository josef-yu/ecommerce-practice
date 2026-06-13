# Ecommerce Practice

![CodeRabbit Pull Request Reviews](https://img.shields.io/coderabbit/prs/github/josef-yu/ecommerce-practice?labelColor=171717&color=FF570A&link=https%3A%2F%2Fcoderabbit.ai&label=CodeRabbit+Reviews)

This repository contains implementation practice for an ecommerce project. Claude wrote the specs, excluding the OpenAPI specifications,and I implement it. This is to maintain my technical skills in the AI era of software development as it also helps in reviewing AI generated code.

## What gets built

A multi-merchant e-commerce platform, specified once in [`specs/`](specs/) and implementable in any stack:

- **Auth**: email/password and Google OAuth (Authorization Code + PKCE); JWT access tokens with rotating refresh tokens
- **Catalog**: categories, search/filter/sort; admin-curated platform products plus third-party merchant products behind an approval workflow
- **Cart & checkout**: saved address book, per-merchant shipping method selection, atomic stock reservations with a 30-minute TTL
- **Payments**: provider webhooks (Stripe-style) driving durable, idempotent background jobs
- **Marketplace**: merchant applications and approval, public storefronts, per-merchant fulfillments, shipment tracking via carrier webhooks
- **Real-time**: a single WebSocket connection per tab for order status, notifications, cart sync, presence, and chat
- **Chat**: customer-to-support and customer-to-merchant conversations with attachments, typing indicators, and read receipts
- **Notifications**: persistent and real-time delivery, admin broadcasts

The acceptance contract is [specs/test-suite.md](specs/test-suite.md): an implementation is done when it passes that suite. [specs/phases.md](specs/phases.md) gives the recommended build order: 10 phases, each ending in a working, testable vertical slice.

## Repository layout

Each implementation lives in its own named subfolder. Any frontend can be paired with any backend; fullstack implementations are self-contained and pair with nothing.

```
specs/               stack-agnostic contracts (start here)
backend/<stack>/     e.g. backend/django-drf
frontend/<stack>/    e.g. frontend/react
fullstack/<stack>/   e.g. fullstack/nextjs
Makefile             root orchestrator that pairs stacks and injects env vars
docker-compose.yml   shared infra: Postgres, Redis, Mailpit, MinIO
.env.example         shared secrets template (copy to .env)
```

### Implementations

| Stack                                    | Type                   | Port | Status                 |
| ---------------------------------------- | ---------------------- | ---- | ---------------------- |
| [backend/django-drf](backend/django-drf) | Backend (Django + DRF) | 8000 | Phase 0: project setup |

## Running

```bash
cp .env.example .env                     # then fill in values
make infra                               # start Postgres, Redis, Mailpit, MinIO
make pair FRONT=react BACK=django-drf    # run a frontend + backend pair
make fullstack STACK=nextjs              # or a self-contained fullstack impl
make lint BACK=django-drf                # lint a backend (or FRONT= / STACK=)
make test BACK=django-drf                # test a backend (or FRONT= / STACK=)
make help                                # everything else
```

The root Makefile reads each stack's `stack.env` for its port and injects the cross-references automatically: the backend receives `FRONTEND_URL` (for CORS), and the frontend receives `API_URL` and `WS_URL`. No manual URL wiring. Every stack exposes the same three Makefile targets — `dev`, `lint`, and `test` — configured entirely through environment variables.

The full variable-injection contract, including how to add a new stack (a folder, a `stack.env`, a `Makefile`), is in [specs/orchestration.md](specs/orchestration.md).

## Conventions at a glance

- Base API path `/api/v1`, WebSocket `ws://host/ws?token=<jwt>`
- All monetary values are integer cents; all IDs are UUIDs; all timestamps are ISO 8601 UTC

See the [spec index](specs/README.md) for the full set of contract documents.
