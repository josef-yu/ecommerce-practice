# Security Requirements

---

## Authentication

- Passwords hashed with **bcrypt** (cost factor ≥ 12) or **Argon2id** (memory ≥ 64 MB, iterations ≥ 3).
- Access tokens are **JWT**, expire after **24 hours**, signed with HS256 or RS256.
- Refresh tokens are opaque random strings (≥ 32 bytes), stored hashed in the database, valid for **30 days**. Rotate on every use.
- On `POST /auth/logout`, invalidate the refresh token and add the access token to a blocklist until expiry.
- Email verification tokens: signed JWT with `exp = now + 24h`. Invalidated on use.

---

## OAuth / Social Login

- Use **Authorization Code flow with PKCE** (`code_challenge_method=S256`). Never use the implicit flow.
- The `state` parameter must be a cryptographically random string (≥ 16 bytes), stored server-side, verified on callback, and deleted immediately after use (one-time-use). A mismatched or missing `state` must result in `400` — this prevents CSRF on the callback.
- The `redirect_uri` sent to the provider must be validated against a hard-coded server-side allowlist. Reject any callback that presents a `redirect_uri` not on that list.
- Provider OAuth tokens (`access_token`, `refresh_token`) must be **encrypted at rest** in the database. Store only what is needed — do not log them.
- The server-side `code_verifier` (PKCE) must be stored per-session with a short TTL (≤ 10 minutes) and deleted after use. Never expose it to the client.
- One-time callback codes (used to pass tokens from the server redirect to the SPA) expire after **60 seconds** and are invalidated on first use.
- Account linking by email (attaching a new provider to an existing password account) must only be allowed if the provider-returned email is verified (`email_verified: true` in the ID token). Never auto-link on an unverified provider email.
- Disconnecting a provider is blocked when it would leave the user with no login method (no password, no other provider).
- Rate-limit the OAuth initiation endpoint: **20 req / min / IP** to prevent state-table flooding.

---

## Authorization

- Role claims (`customer`, `merchant`, `support`, `admin`) are stored in the database; the JWT encodes them at login. Re-validate role on sensitive operations — do not trust stale JWT claims alone if roles can change.
- Admin-only and support-only endpoints enforce role checks server-side. Never rely on client-supplied role fields.
- Customers may only access their own orders, cart, and conversations. Enforce `user_id == authenticated_user_id` in all queries, not just route guards.

### Merchant Authorization Rules

- A merchant may only create, edit, submit, or archive **their own products** — always filter by `merchant_id = caller.merchant_profile_id`. Never rely solely on the product ID from the URL.
- The `merchant` role is granted only on approval, so role checks alone block pending and rejected applicants. Suspended merchants **keep** the role — product creation and submission must therefore also check `merchant_profile.status = "approved"` and return `403` otherwise.
- Merchants may not set `product.status` directly. The only transitions they can trigger are `draft/rejected → pending_approval` (via `POST /products/:id/submit`) and `draft/rejected/active → archived` (via `DELETE`).
- `GET /merchants/me/orders` must never return customer PII (account name, email, shipping address). Only return order-level IDs, timestamps, and line items for that merchant's products. In the merchant view of `GET /orders/:id/fulfillments`, the **only** customer data exposed is the `Fulfillment.shipping_address` snapshot — which includes the recipient name, since a shipping label is undeliverable without one. The customer's account email, other addresses, and other orders must never be exposed.
- The `rejection_reason` field on a product is readable by the owning merchant and admins only — exclude it from public product responses.
- Merchants may only create or update Shipments for Fulfillments where `fulfillment.merchant_id = caller.merchant_profile_id`.

### Address Book Rules

- `UserAddress` records are strictly scoped: all read and write operations enforce `user_id == authenticated_user_id` server-side. Never return another user's addresses.
- The `address_id` supplied at checkout must belong to the authenticated user — validate ownership before snapshotting. Return `404` (not `403`) to avoid confirming the ID exists.
- Merchants access the customer's address only via `Fulfillment.shipping_address` — a snapshot already copied at order time. They must never have access to the live `UserAddress` records or any other order's address.
- Deleting a `UserAddress` must never cascade to or modify `Order.shipping_address` — the snapshot is immutable.

### Logistics Rules

- `POST /webhooks/shipment` must verify the carrier's HMAC signature before updating any Shipment record.
- Shipment tracking data is public (`GET /shipments/:id` requires no auth) — do not include order, customer, or address data in the shipment response.
- Fulfillment status transitions are server-enforced: a merchant cannot skip from `pending` to `shipped` without going through `processing`.

### Chat Scoping Rules

- Merchant conversations (`type = "merchant"`) are only visible to: the customer who opened them, the merchant whose `merchant_id` matches, and admins.
- A merchant user must never be able to read another merchant's conversations, even by guessing IDs. Always enforce `conversation.merchant_id = caller.merchant_profile_id` server-side.
- The platform merchant (`is_platform = true`) has no associated user and cannot participate in conversations.

---

## Rate Limiting

| Endpoint | Limit |
|---|---|
| `POST /auth/register` | 5 req / 10 min / IP |
| `POST /auth/login` | 10 req / min / IP |
| `POST /auth/verify-email` | 10 req / min / IP |
| `POST /auth/refresh` | 20 req / min / IP |
| WebSocket connection attempts (`/ws`) | counts against the `POST /auth/login` limit |
| All other endpoints | 200 req / min / authenticated user |

Return `429 Too Many Requests` with a `Retry-After` header when the limit is exceeded.

---

## CSRF

- If auth is cookie-based (HttpOnly, Secure, SameSite=Strict/Lax), all state-mutating requests require a `X-CSRF-Token` header validated against a per-session token.
- If auth is header-based (`Authorization: Bearer`), CSRF protection is not required for API endpoints — but set `SameSite=Strict` on any non-auth cookies.

---

## Webhooks

- Validate the HMAC signature on every incoming `POST /webhooks/payment` request before processing.
- Compare signatures with a constant-time comparison to prevent timing attacks.
- Reject requests with missing or invalid signatures with `400 Bad Request` (not `401` — do not reveal auth details).
- Process webhook payloads idempotently: the same event delivered twice must not create duplicate orders or notifications.

---

## Input Validation

- Validate all input at the API boundary. Reject unknown fields.
- Monetary values (`price`, `quantity`) must be non-negative integers.
- Addresses: `country` must be a valid ISO 3166-1 alpha-2 code.
- Message body: max 4000 characters; strip or reject null bytes.
- File uploads: validate MIME type server-side from file content (not just extension or `Content-Type` header).

---

## Stock Atomicity

Stock is reserved (decremented) inside the `POST /orders` transaction — see StockReservation in [domain-model.md](domain-model.md). The decrement must be atomic to prevent overselling. Use one of:
- A database-level atomic decrement with a `CHECK (stock_quantity >= 0)` constraint.
- Optimistic locking: read version, decrement, compare-and-swap; retry on conflict.
- Pessimistic row-level lock (`SELECT FOR UPDATE`) held for the duration of the transaction.

Two concurrent checkouts for the last unit must result in exactly one success and one failure. Restoration paths (expiry, payment failure, cancellation) must increment atomically and exactly once — only `held` (or, for cancellation of paid orders, `converted`) reservations may be released, and a reservation is never released twice.

---

## General

- All HTTP responses must include:
  - `X-Content-Type-Options: nosniff`
  - `X-Frame-Options: DENY`
  - `Content-Security-Policy` (restrict `script-src` to known origins)
- Never return `password_hash` in any API response.
- Log authentication failures (but not passwords) for anomaly detection.
- Database queries must use parameterized statements — never string interpolation.
- Uploaded files must be served from a separate origin or with `Content-Disposition: attachment` to prevent XSS via stored HTML/SVG.
