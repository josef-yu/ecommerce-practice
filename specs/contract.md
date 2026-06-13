# API Contract (single source of truth)

The machine-readable contract is authored once in **TypeSpec** and compiled into standard artifacts that every stack consumes. It is **backend-neutral**: no stack generates it, and every stack is held against it.

```
specs/contract/*.tsp                    ← authored here (single source of truth)
        │  make contract  (tsp compile)
        ├── @typespec/openapi3   → specs/openapi.yaml      OpenAPI 3.1 — REST surface
        └── @typespec/json-schema → specs/schemas/*.json    JSON Schema 2020-12 — shared payloads
                                                            (domain entities + WebSocket event payloads)
```

OpenAPI 3.1's component schemas **are** JSON Schema 2020-12, so the REST bodies and the WebSocket payloads reference one shared set of schemas. A domain entity (e.g. `Notification`) is defined once and reused by both the REST response and the `NOTIFICATION_CREATED` event.

## Artifacts

| Path | What | Committed? |
|---|---|---|
| `specs/contract/` | TypeSpec source + emitter config | yes |
| `specs/openapi.yaml` | OpenAPI 3.1 document (REST) | yes — generated, do not hand-edit |
| `specs/schemas/*.json` | JSON Schema per type (payloads) | yes — generated, do not hand-edit |
| `specs/contract/ws-events.yaml` | WebSocket event registry: `type → direction → payload schema` | yes — hand-authored |

`specs/openapi.yaml` and `specs/schemas/` are **generated**. Never edit them by hand — change the `.tsp` and run `make contract`. CI enforces this (see Compliance below).

## Source layout

The TypeSpec source is split by domain; every module reopens `namespace Ecommerce`, and `main.tsp` wires them together and carries the service-level decorators (`@service`, `@info`, `@jsonSchema`).

```
specs/contract/
├── main.tsp            entry point: imports + decorated namespace
├── common.tsp          shared envelopes (ErrorEnvelope, PageMeta, ErrorCode)
├── products.tsp        Product entity + /products operations
├── notifications.tsp   Notification entity
├── websocket.tsp       WS envelope + event payloads (reuse the entities)
├── ws-events.yaml      WS topology registry (hand-authored)
├── tspconfig.yaml      emitter config
└── package.json        pinned TypeSpec deps
```

Add a domain by creating `<domain>.tsp` with `namespace Ecommerce;` and importing it from `main.tsp` — no other file changes.

## Building

```bash
make contract        # npm install + tsp compile --warn-as-error → regenerates openapi.yaml + schemas/
make contract-fmt    # format the .tsp source (writes)
```

Needs **Node 22+** (TypeSpec's `tsp format` uses `node:fs/promises` glob); no infra or `.env`. Compilation uses `--warn-as-error`, so any compiler warning fails the build. Output is deterministic, so re-running with an unchanged source produces no diff.

## Why TypeSpec

- One concise source emits both OpenAPI (REST) and JSON Schema (payloads); models are defined once.
- It is a neutral spec compiler, not a backend — the contract stays independent of every stack.
- The whole downstream ecosystem still applies (Swagger UI/Redoc, `openapi-typescript`, ajv, Schemathesis, …).
- WebSocket: JSON Schema carries the payload **shapes**; the protocol **topology** (which event flows which direction) lives in `ws-events.yaml`. If a formal async description is wanted later, a TypeSpec AsyncAPI emitter can be added against the same models with no rework.

## Compliance model

The contract is the source of truth; each side is tested for **conformance to it** — never against each other.

### Repo-level (the `contract` CI job)
- **Format** — `tsp format --check` (`make contract-fmt-check`); run `make contract-fmt` to fix.
- **Compile** — `tsp compile --warn-as-error` (`make contract-compile`); errors and warnings both fail. A successful compile guarantees the emitted OpenAPI/JSON Schema are structurally valid.
- **Drift** — `git status --porcelain specs/openapi.yaml specs/schemas` must be empty; the committed artifacts must match the `.tsp`. A drifted artifact (or a `.tsp` change without recompiling), or a new-but-uncommitted schema, fails CI.

### Backend (its `make test`)
1. **Serves the contract** — `GET /api/v1/openapi.json` returns a document equal to `specs/openapi.yaml` (serve the committed file; do not auto-generate a divergent one).
2. **Runtime conformance** — exercise every documented operation and validate live responses against `specs/openapi.yaml` (e.g. [Schemathesis](https://schemathesis.readthedocs.io/)). Validate emitted WebSocket payloads against `specs/schemas/` (e.g. ajv / python-jsonschema).

### Frontend (its `make lint`)
1. **Codegen** — generate REST types from `specs/openapi.yaml` (`openapi-typescript`) and WS payload types from `specs/schemas/` (`json-schema-to-typescript`). No hand-written API types; no `any` at the boundary.
2. **Drift-check** — regenerate and assert no diff against the committed output.
3. **Type-check** — `tsc --noEmit`; a contract change that breaks a call site fails the build.

See [api.md](api.md) (REST), [websocket.md](websocket.md) (events), [frontend.md](frontend.md) (consumer), and [test-suite.md](test-suite.md) §OpenAPI for the testable requirements.

## Status

`specs/contract/main.tsp` currently models a representative slice (envelopes, `Product`/`Notification`, two WS events, products endpoints) that establishes the conventions. The full surface is modelled incrementally alongside the [build phases](phases.md).
