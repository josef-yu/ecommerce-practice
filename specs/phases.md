# Implementation Phases

A recommended build order. Each phase ends with a working, testable vertical slice. Later phases build on earlier ones — do not start a phase until the prior one's "done when" criteria pass.

---

## Dependency Map

```
0 (Setup)
└── 1 (Auth & Addresses)
    └── 2 (Product Catalog)
        └── 3 (Cart & Orders)
            ├── 4 (Notifications — DB layer)
            │   └── 5 (WebSocket & Real-time)
            │       ├── 6 (Merchant System)
            │       │   └── 7 (Logistics)
            │       │       └── 8 (Chat)
            │       └── 8 (Chat)
            └── 6 (Merchant System)
```

OAuth (Phase 9) and the Frontend (Phase 10) are largely independent and can be worked in parallel with phases 4–8 on the same codebase.

---

## Phase 0 — Project Setup

**Goal:** A running skeleton that can accept HTTP requests and connect to a database. Nothing user-facing yet.

### Scope
- Create the top-level folder layout. Each implementation gets a named subfolder:
  ```
  /frontend/<stack-name>   e.g. /frontend/angular
  /backend/<stack-name>    e.g. /backend/spring
  /fullstack/<stack-name>  e.g. /fullstack/nextjs
  ```
- Choose your stack and initialise the project inside the appropriate subfolder.
- Copy `.env.example` to `.env` at the repo root and fill in values.
- Create `stack.env` in your stack's folder declaring its port (e.g. `BACKEND_PORT=8080`). See [orchestration.md](orchestration.md) for the full contract.
- Create a `Makefile` in your stack's folder with `dev` and `test` targets that read config from environment variables — not from a local `.env` file.
- Start shared infrastructure: `make infra`.
- Wire up a health-check endpoint: `GET /health` → `200 { "ok": true }`.
- Set up a local email trap (already running via Mailpit in `make infra`) and confirm the app can send to it.
- Set up the test runner; confirm a trivial passing test executes.
- Basic CI: run `make test BACK=<stack>` (or `FRONT=` / `STACK=`) on every push.
- Smoke-test the pairing: `make pair FRONT=<x> BACK=<stack>` — the frontend should reach the backend's `/health` endpoint without any manual URL configuration.

### Done when
- `GET /health` returns 200.
- The test suite runs (even with zero tests).
- Email to the local trap is confirmed in a smoke test.

### Notes
- Lock your dependency versions now — upgrading mid-build is a distraction.
- The dev email trap must never send real mail. Enforce this with an environment check, not just documentation.
- CORS is handled automatically — the root Makefile injects `FRONTEND_URL` into the backend and `API_URL` into the frontend so they always match. Your backend only needs to read `FRONTEND_URL` from the environment and add it to the allowed origins list.
- Fullstack implementations skip the CORS concern entirely — they serve the API and UI from the same origin.
- See [orchestration.md](orchestration.md) for the full variable injection contract and example `Makefile` targets for common stacks.

---

## Phase 1 — Auth & Address Book

**Goal:** Users can register, verify their email, log in, manage their profile, and maintain a saved address book.

### Scope
- DB tables: `users`, `user_addresses`
- `POST /auth/register` — hashed password, enqueue `send_verification_email`
- `POST /auth/login`, `POST /auth/logout`, `GET /auth/me`
- `POST /auth/refresh` — rotating refresh tokens (register/login responses include the initial `refresh_token`)
- `POST /auth/change-password`
- `POST /auth/verify-email`
- Background job: `send_verification_email`
- Address book: `GET /addresses`, `POST /addresses`, `PATCH /addresses/:id`, `DELETE /addresses/:id`, `POST /addresses/:id/set-default`
- Rate limiting on auth endpoints

### Spec files
[domain-model.md](domain-model.md) (User, UserAddress) · [api.md](api.md) (Auth, Addresses) · [security.md](security.md) (Authentication, Address Book Rules)

### Done when
- TC-AUTH-01 through TC-AUTH-09 pass.
- TC-ADDR-01 through TC-ADDR-12 pass.
- `password_hash` never appears in any API response (TC-SEC-01).
- Rate limiting returns `429` on the 11th rapid login attempt (TC-SEC-06).

### Notes
- Implement bcrypt/Argon2 hashing before writing a single endpoint — retrofitting it breaks all stored hashes.
- Write the address snapshot logic (copy fields into `Order.shipping_address`) now. It is called in Phase 3, and it is easy to get wrong later when there are more moving parts.
- Refresh token rotation (TC-AUTH-09) is harder than it looks. Test it explicitly before moving on.

---

## Phase 2 — Product Catalog

**Goal:** An admin can manage products and categories. Any visitor can browse, search, and filter the catalogue.

### Scope
- DB tables: `merchant_profiles` (platform merchant only), `products`, `categories`
- **Seed:** insert the platform MerchantProfile (`is_platform = true`, `store_slug = "platform"`) on first run. Block startup if this row is missing.
- Category CRUD (`/categories`) — admin only for writes, public for reads
- Product CRUD — admin creates under the platform merchant, no approval required
- `GET /products` — public, `active` only, with category/search/price/sort filters and pagination
- `GET /products/:id` — public

### Spec files
[domain-model.md](domain-model.md) (MerchantProfile, Product, Category) · [api.md](api.md) (Products, Categories)

### Done when
- Platform merchant is seeded automatically; starting without it is an error, not a silent gap.
- TC-PROD-01 through TC-PROD-07 pass.
- Archived products are invisible to unauthenticated clients.
- `product.merchant_id` is never null in the database.

### Notes
- The platform merchant seed is the most important invariant in the whole system — every admin-created product depends on it. Add a startup assertion.
- Full-text search can be a simple `ILIKE` / `CONTAINS` at this stage. Upgrade to a proper search index later if needed.
- Do not implement the merchant product approval flow here. That comes in Phase 6.

---

## Phase 3 — Cart & Orders

**Goal:** A customer can add products to a cart, place an order using a saved or inline address, pay, and have the order processed.

### Scope
- DB tables: `carts`, `cart_items`, `orders`, `order_items`, `stock_reservations`
- Full cart CRUD (`/cart`, `/cart/items`)
- `POST /orders` — accepts `address_id` or inline `shipping_address`, snapshots the address, **atomically reserves stock** (decrement + StockReservation, TTL 30 min), creates the order in `pending` status
- Payment provider integration in test/sandbox mode
- `POST /webhooks/payment` — HMAC verification, enqueue `handle_payment_webhook`
- Background jobs: `handle_payment_webhook`, `process_order`, `send_order_confirmation_email`
- Background job: `release_expired_reservations` (scheduled, every 5 min)
- `GET /orders`, `GET /orders/:id`, `POST /orders/:id/cancel` (releases reservations / restores stock)
- Admin order status management: `PATCH /orders/:id/status`
- Background job: `send_order_status_email`
- Background job: `cleanup_abandoned_carts` (scheduled)

### Spec files
[domain-model.md](domain-model.md) (Cart, Order, OrderItem, StockReservation) · [api.md](api.md) (Cart, Orders, Webhooks) · [background-processing.md](background-processing.md)

### Done when
- TC-CART-01 through TC-CART-07 pass.
- TC-ORDER-01 through TC-ORDER-10 pass.
- TC-JOB-01 through TC-JOB-07 pass.
- **TC-CONC-01 (stock atomicity) passes.** Do not advance to Phase 4 until this test is green.
- Webhook signature validation rejects tampered requests (TC-SEC-03, TC-SEC-04).

### Notes
- Stock atomicity (TC-CONC-01) is the hardest correctness problem in the entire application. The atomic decrement lives in the `POST /orders` transaction — use a database-level constraint or atomic decrement plus a row lock. Test it with real concurrent HTTP clients, not mocked calls.
- Every stock-restoration path (expiry, payment failure, cancellation) must release a reservation exactly once. Gate every release on the reservation's current status.
- There are no ShippingMethods until Phase 7: `shipping_cost` is `0` and `shipping_selections` is omitted. The `POST /orders` API shape does not change in Phase 7 — it just starts accepting selections.
- Use the payment provider's CLI tool to replay webhooks locally. This eliminates the need to mock the entire async payment flow in development.
- `process_order` must be idempotent (TC-JOB-03). A payment webhook can be delivered more than once.

---

## Phase 4 — Notifications (Database Layer)

**Goal:** All order lifecycle events create persistent notifications. Customers can read and dismiss them via REST.

### Scope
- DB table: `notifications`
- `GET /notifications`, `GET /notifications/count`
- `POST /notifications/:id/read`, `POST /notifications/read-all`
- Notification creation inside background jobs (`process_order`, `handle_payment_webhook`, `send_order_status_email`)
- Admin broadcast: `POST /notifications/broadcast`

### Spec files
[domain-model.md](domain-model.md) (Notification) · [api.md](api.md) (Notifications) · [notifications.md](notifications.md)

### Done when
- TC-NOTIF-01 through TC-NOTIF-05 pass.
- Notification titles and bodies match the templates in notifications.md.
- The REST layer works standalone — no WebSocket dependency.

### Notes
- Keep this phase deliberately REST-only. The WebSocket push is added in Phase 5 as a layer on top — the DB record is the source of truth either way.
- `POST /notifications/broadcast` writes to the database; the real-time push to connected clients is wired up in Phase 5.

---

## Phase 5 — WebSocket & Real-time

**Goal:** Order status changes, new notifications, and cart updates are pushed to connected clients without polling.

### Scope
- WebSocket server — JWT authentication on connect, close `4001` on invalid token
- PING/PONG keepalive (30-second interval)
- Per-user room subscriptions on connect
- Push `ORDER_STATUS_CHANGED` when admin updates order status
- Push `NOTIFICATION_CREATED` when any notification is created (replaces polling for the bell badge)
- Push `CART_UPDATED` when the cart changes from another session
- Push `INVENTORY_LOW` to admin connections when stock drops below 10
- If the WebSocket and HTTP servers are separate processes, wire up a pub/sub layer (e.g. Redis Pub/Sub)

### Spec files
[websocket.md](websocket.md) · [security.md](security.md) (Rate Limiting — WebSocket auth counts against login limits)

### Done when
- TC-WS-01 through TC-WS-05 pass (connection, order update, notification push, isolation, keepalive).
- TC-WS-10 (cart sync across tabs) passes.
- TC-WS-11 (INVENTORY_LOW admin-only) passes.

### Notes
- Build on top of the REST layer. The REST endpoints must remain fully functional independently of whether the WebSocket server is up.
- Reconnect with exponential backoff on the client side — the first reconnect after 500 ms, doubling up to a 30-second cap.
- If running a single-process server, pub/sub is not needed yet. Add it only when you scale to multiple processes.

---

## Phase 6 — Merchant System

**Goal:** Third-party merchants can apply to sell, go through an approval workflow, manage their own products, and view their sales.

### Scope
- DB tables: extend `merchant_profiles` for third-party merchants
- `POST /merchants/apply` — creates a pending application; role stays `customer` until approval; rejected applicants may re-apply
- `GET /merchants`, `GET /merchants/:id`, `GET /merchants/me`, `PATCH /merchants/me`
- Admin approval: `PATCH /merchants/:id/status` (approve — flips role to `merchant`; suspend — archives products on suspend)
- Merchant product lifecycle: `POST /products` (draft), `POST /products/:id/submit` (draft/rejected → pending_approval), `PATCH /products/:id/review` (admin), merchant-scoped `PATCH /products/:id` and `DELETE /products/:id`
- `GET /merchants/me/orders` (no customer PII), `GET /merchants/me/stats` (dashboard aggregates)
- Public merchant storefront: `GET /products?merchant_id=`
- Merchant notifications: product approved/rejected, account status changes, new orders

### Spec files
[domain-model.md](domain-model.md) (MerchantProfile expanded) · [api.md](api.md) (Merchants, Products updated) · [notifications.md](notifications.md) (merchant notifications) · [security.md](security.md) (Merchant Authorization Rules)

### Done when
- TC-MERCH-01 through TC-MERCH-22 pass.
- `rejection_reason` never appears in a public product response (TC-MERCH-16).
- Suspending a merchant archives all their active products (TC-MERCH-06).
- `product.merchant_id` is never null (TC-MERCH-07, TC-MERCH-21).

### Notes
- The platform merchant from Phase 2 must exist before any code in this phase runs.
- The `merchant` role is granted on approval, so role checks alone block pending and rejected applicants. Suspended merchants keep the role — also gate product creation/submission on `merchant_profile.status = "approved"`. A suspended merchant getting a 403 is a security requirement, not just a UX nicety.
- The `INVENTORY_LOW` WebSocket event wired in Phase 5 now also fires for third-party merchant products — no new code needed if the threshold check is in `process_order`.

---

## Phase 7 — Logistics

**Goal:** Merchants define shipping rates, orders generate per-merchant fulfillments, merchants mark items as shipped, and customers can track packages.

### Scope
- DB tables: `shipping_methods`, `fulfillments`, `shipments`, `shipment_events`; add `weight_grams` to `products`
- Merchant shipping method CRUD (`/merchants/me/shipping-methods`)
- Checkout shipping selection: `GET /cart/shipping-options`, `shipping_selections` on `POST /orders` (auto-cheapest fallback when omitted), shipping cost computed at order creation
- **Extend `process_order`** to auto-create one Fulfillment per merchant in the order (grouping OrderItems by `merchant_id`), copy `Order.shipping_address` into `Fulfillment.shipping_address` and the method + cost from `Order.shipping_selections`
- Merchant ship action: `POST /orders/:id/fulfillments/:fid/ship` — creates a Shipment record, transitions Fulfillment to `shipped`; when all fulfillments are shipped, the Order transitions to `shipped`
- `GET /orders/:id/fulfillments` — scoped by role
- `GET /shipments/:id` — public tracking
- `POST /webhooks/shipment` — carrier push, enqueue `sync_shipment_tracking`
- Background jobs: `sync_shipment_tracking`, `poll_shipment_tracking` (scheduled every 4 hours)
- Logistics notifications (per tracking states in notifications.md)
- WebSocket events: `SHIPMENT_STATUS_CHANGED`, `FULFILLMENT_STATUS_CHANGED`

### Spec files
[domain-model.md](domain-model.md) (ShippingMethod, Fulfillment, Shipment, ShipmentEvent) · [api.md](api.md) (Logistics) · [background-processing.md](background-processing.md) · [websocket.md](websocket.md) · [security.md](security.md) (Logistics Rules)

### Done when
- TC-LOG-01 through TC-LOG-15 pass.
- `GET /shipments/:id` returns no customer PII (TC-LOG-09).
- Order transitions to `delivered` only when all its Fulfillments are `delivered` (TC-LOG-11).
- Shipment webhook with bad signature is rejected (TC-LOG-12).

### Notes
- Fulfillment creation belongs inside `process_order` — it is part of the same transaction as stock decrement. Do not create Fulfillments in the HTTP handler.
- `Fulfillment.shipping_address` is the only address a merchant ever sees. `GET /orders/:id/fulfillments` must strip all other customer data from the response.
- Implement the webhook path (`sync_shipment_tracking`) first. The polling fallback (`poll_shipment_tracking`) is for carriers that don't push — add it second.
- A carrier stub that delivers a sequence of fake events on a timer is enough to test the full tracking pipeline without real API credentials.

---

## Phase 8 — Chat

**Goal:** Customers can chat with the support team and directly with individual merchants in real time.

### Scope
- DB tables: `conversations`, `messages`, `attachments`
- Support chat: `POST /conversations` (`type=support`), full message CRUD (including `attachment_ids`), conversation status management, `GET /conversations/unread-count`
- Merchant chat: `POST /conversations` (`type=merchant`), merchant inbox (`GET /conversations?type=merchant`), merchant replies
- WebSocket events: `CHAT_MESSAGE_CREATED`, `CHAT_MESSAGE_EDITED`, `CHAT_MESSAGE_DELETED`, `CHAT_TYPING_START/STOP`, `CHAT_READ_RECEIPT`, `CHAT_CONVERSATION_STATUS_CHANGED`, `PRESENCE_CHANGED`
- Client events: `CHAT_TYPING_START/STOP`, `CHAT_MARK_READ`, `CHAT_JOIN/LEAVE_CONVERSATION`
- Background job: `send_missed_message_notification`
- Chat notifications (`chat` type for missed messages)
- File upload endpoint (`POST /upload`) and attachment flow
- Typing indicator auto-cancel (5-second server timer per user+conversation)
- Presence tracking (online/offline on connect/disconnect with 10-second grace period)

### Spec files
[domain-model.md](domain-model.md) (Conversation, Message, Attachment) · [api.md](api.md) (Chat) · [chat.md](chat.md) · [websocket.md](websocket.md) (Chat events) · [security.md](security.md) (Chat Scoping Rules)

### Done when
- TC-CHAT-01 through TC-CHAT-12 pass (support chat).
- TC-CHAT-MERCH-01 through TC-CHAT-MERCH-10 pass (merchant chat).
- TC-WS-06 through TC-WS-09 pass (message push, typing indicators).
- TC-WS-12 and TC-WS-13 pass (presence).
- Unique constraint on `(customer_id, merchant_id)` for open/pending merchant conversations is enforced at the DB level (not just the API).

### Notes
- Build support chat first — the scoping is simpler. Merchant chat is support chat with an extra `merchant_id` column and a different access rule; the message, event, and attachment code is identical.
- Typing indicators and presence are in-memory only. A server restart clears them — that is acceptable. Do not persist them.
- The 5-second typing auto-cancel requires a per-user-per-conversation timer. Use your framework's async task primitives or a lightweight in-memory scheduler — not the background job queue, which is for durable work.
- File uploads should be validated server-side by reading the file header, not by trusting the `Content-Type` request header.

---

## Phase 9 — OAuth / Social Login

**Goal:** Users can sign in or register with Google. Existing accounts can link and unlink providers.

### Scope
- DB table: `user_identities`
- `GET /auth/oauth/google` — generate state + PKCE, redirect to Google
- `GET /auth/oauth/google/callback` — validate state, exchange code, create/link/log-in
- `POST /auth/token-exchange` — one-time code → JWT + refresh token
- `GET /auth/oauth/connections`, `DELETE /auth/oauth/:provider`
- `POST /auth/set-password` — lets OAuth-only users add a password
- Rate-limit OAuth initiation endpoint (20 req / min / IP)

### Spec files
[api.md](api.md) (OAuth section) · [security.md](security.md) (OAuth section) · [domain-model.md](domain-model.md) (UserIdentity)

### Done when
- TC-OAUTH-01 through TC-OAUTH-15 pass (all using a stubbed Google provider).
- State mismatch and missing state both return `400` (TC-OAUTH-05, TC-OAUTH-06).
- Auto-link is blocked when the provider email is unverified (TC-OAUTH-04).
- Disconnect is blocked when it would leave the user with no login method (TC-OAUTH-11).

### Notes
- All TC-OAUTH-* tests must use a stub — no real network calls to Google in tests, ever.
- The state/PKCE validation is the security-critical piece. Implement and test it before any account-creation logic.
- This phase can be started in parallel with Phases 4–8 if a second developer is available, since it touches only the Auth subsystem.

---

## Phase 10 — Frontend

**Goal:** A complete, mobile-responsive web UI covering all features. Can be developed in parallel with backend phases or after.

### Recommended sub-phase order

| Sub-phase | Pages / components |
|---|---|
| **A — Public shell** | Homepage, product listing, product detail, category nav, merchant storefront (`/stores/:slug`), public tracking (`/track/:id`) |
| **B — Auth flows** | Login, register, email verification, "Continue with Google" button |
| **C — Customer core** | Cart, checkout (address selector + shipping method selector + payment form), order history, order detail with fulfillment cards |
| **D — Real-time wiring** | WebSocket singleton, notification bell, cart icon sync, order status tracker |
| **E — Account** | Profile settings, address book CRUD, connected OAuth providers, set-password form |
| **F — Merchant** | Apply form, dashboard, product management (draft/submit/review UX), fulfillment ship form, sales table, chat inbox |
| **G — Chat widget** | Floating button on all pages, support conversation, merchant conversation, typing indicators, read receipts, file attachments |
| **H — Admin** | Order management, merchant approval queue, product review queue, broadcast notifications |

### Done when
- All pages render without horizontal scroll at mobile (<768px), tablet (768–1024px), and desktop (>1024px).
- Golden path browser-tested: register → browse → add to cart → checkout → track order → receive delivery notification.
- Chat widget opens correctly on mobile (full-screen) and desktop (slide-over).
- WebSocket reconnects gracefully after a simulated disconnect (close the tab and reopen).

### Notes
- The WebSocket client must be a single connection per tab, shared across all components. Instantiate it once at the app root and pass events down — do not open a new connection per page.
- Implement optimistic UI for cart add/remove from the start. Retrofitting it after the fact is significantly harder.
- The "Continue with Google" button must trigger a full-page redirect, not a popup. Popups are blocked on mobile and many corporate networks.
- Do not ship the admin UI without verifying that admin role checks work server-side (TC-SEC-02). Frontend route guards are UX, not security.

---

## Effort Reference

Phases are listed roughly in ascending integration complexity. Phases 1–3 are the core foundation and should take the most calendar time for first-time implementations; Phases 6–8 add orthogonal surface area on top of a working base.

| Phase | Relative effort |
|---|---|
| 0 Setup | XS |
| 1 Auth & Addresses | S |
| 2 Product Catalog | S |
| 3 Cart & Orders | M |
| 4 Notifications (DB) | XS |
| 5 WebSocket | S |
| 6 Merchant System | M |
| 7 Logistics | M |
| 8 Chat | L |
| 9 OAuth | S |
| 10 Frontend | XL |
