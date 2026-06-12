# Ecommerce Platform Spec Index

Stack-agnostic contracts shared by every implementation in this repo. Any frontend can be paired with any backend: both sides implement the contracts below, and a compliant backend passes the test suite regardless of which frontend talks to it.

Repository layout, implementation status, and run instructions live in the [root README](../README.md). The pairing and variable-injection mechanics are in [orchestration.md](orchestration.md).

## Files

| File | Contents |
|---|---|
| [domain-model.md](domain-model.md) | All entities, fields, types, and state machines |
| [api.md](api.md) | REST API contracts: endpoints, request/response shapes, error codes |
| [websocket.md](websocket.md) | WebSocket connection protocol and all event types |
| [chat.md](chat.md) | Customer support chat feature: domain model, REST, WebSocket, UX |
| [background-processing.md](background-processing.md) | Durable background jobs and scheduled tasks |
| [notifications.md](notifications.md) | Notification system: channels, triggers, templates |
| [frontend.md](frontend.md) | Pages, routing, responsive breakpoints, real-time UX |
| [security.md](security.md) | Auth, hashing, rate limiting, webhook verification, atomicity |
| [test-suite.md](test-suite.md) | Stack-agnostic test cases every implementation must pass |
| [phases.md](phases.md) | Recommended build order: 10 phases with scope, done-when criteria, and notes |
| [orchestration.md](orchestration.md) | How to run pairs and fullstack implementations: variable injection, `stack.env` and `Makefile` contracts |

## Quick Reference

- Base API path: `/api/v1`
- WebSocket endpoint: `ws://host/ws?token=<jwt>`
- All monetary values are integers in the smallest currency unit (cents)
- All IDs are UUIDs
- All timestamps are ISO 8601 UTC
