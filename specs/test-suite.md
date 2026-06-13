# Test Suite Specification

Stack-agnostic. These are behavioral contracts — write the tests in whatever framework your stack uses. Every implementation must pass all cases in this file.

---

## Conventions

- **Setup** describes the database/system state before the test.
- **Action** is the HTTP request, WebSocket event, or job invocation.
- **Expect** is what must be true afterward (response, DB state, side effects).
- Tests that share setup are grouped under a `Given` block.
- "User A" / "User B" refer to distinct authenticated users seeded in setup.
- All monetary values are integers (cents).

---

## 1. Authentication

### 1.1 Register

**TC-AUTH-01 — successful registration**
- Setup: email `new@example.com` does not exist.
- Action: `POST /auth/register` `{ email: "new@example.com", password: "Password1!", full_name: "Test User" }`
- Expect: `201`, response contains `user.id`, `user.email`, `token`, and `refresh_token`; `user.email_verified = false`; `password_hash` is NOT in response; `send_verification_email` job enqueued for the new user.

**TC-AUTH-02 — duplicate email returns conflict**
- Setup: user with `email@example.com` exists.
- Action: `POST /auth/register` with the same email.
- Expect: `409`, error code `CONFLICT`.

**TC-AUTH-03 — weak password rejected**
- Action: `POST /auth/register` with `password: "abc"`.
- Expect: `422`, error code `VALIDATION_ERROR`, details reference the `password` field.

### 1.2 Login

**TC-AUTH-04 — successful login**
- Setup: verified user exists.
- Action: `POST /auth/login` with correct credentials.
- Expect: `200`, `token` present, `user.email_verified = true`.

**TC-AUTH-05 — wrong password**
- Action: `POST /auth/login` with incorrect password.
- Expect: `401`, error code `UNAUTHORIZED`.

**TC-AUTH-06 — nonexistent email**
- Action: `POST /auth/login` with an email not in the database.
- Expect: `401`. Response must NOT distinguish "user not found" from "wrong password" (prevents email enumeration).

### 1.3 Token and session

**TC-AUTH-07 — protected endpoint without token**
- Action: `GET /auth/me` with no `Authorization` header.
- Expect: `401`.

**TC-AUTH-08 — logout invalidates token**
- Setup: User A is logged in with token T.
- Action: `POST /auth/logout` with token T; then `GET /auth/me` with token T.
- Expect: second request returns `401`.

**TC-AUTH-09 — refresh token rotation**
- Setup: User A has a valid refresh token R1.
- Action: `POST /auth/refresh` with R1.
- Expect: `200`, new `token` and new `refresh_token` R2 returned; R1 is invalidated (calling refresh with R1 again returns `401`).

### 1.4 OAuth / Social Login

> These tests stub the external provider. The stub returns a configurable profile (email, name, provider_user_id) without making a real network call.

**TC-OAUTH-01 — new user created via Google**
- Setup: no account exists for `oauth@example.com`.
- Action: simulate a successful Google OAuth callback with profile `{ email: "oauth@example.com", name: "OAuth User", sub: "google-uid-123", email_verified: true }`.
- Expect: a new User is created with `email = "oauth@example.com"`, `email_verified = true`, `password_hash = null`; a UserIdentity row exists with `provider = "google"`, `provider_user_id = "google-uid-123"`; response contains `token` and `refresh_token`; no `send_verification_email` job enqueued.

**TC-OAUTH-02 — returning Google user is logged in**
- Setup: User A exists with a linked Google UserIdentity (`provider_user_id = "google-uid-123"`).
- Action: simulate Google OAuth callback with `sub = "google-uid-123"`.
- Expect: no new User created; response token belongs to User A; UserIdentity `updated_at` is refreshed.

**TC-OAUTH-03 — Google email matches existing password account — auto-links**
- Setup: User A exists with `email = "existing@example.com"` and a password, no linked Google identity.
- Action: simulate Google callback with `{ email: "existing@example.com", email_verified: true, sub: "google-uid-456" }`.
- Expect: no new User created; a new UserIdentity row is created and linked to User A; response token belongs to User A.

**TC-OAUTH-04 — auto-link rejected if provider email is unverified**
- Setup: User A exists with `email = "existing@example.com"`.
- Action: simulate Google callback with `{ email: "existing@example.com", email_verified: false, sub: "google-uid-789" }`.
- Expect: no UserIdentity created; no auto-link performed; response is an error (not a valid session token).

**TC-OAUTH-05 — state mismatch on callback is rejected**
- Setup: server generated state `"valid-state-abc"` for an in-progress OAuth flow.
- Action: call the callback endpoint with `state = "tampered-state-xyz"` and a valid `code`.
- Expect: `400`; no user created or logged in; provider token exchange is never attempted.

**TC-OAUTH-06 — missing state on callback is rejected**
- Action: call the callback endpoint with a valid `code` but no `state` parameter.
- Expect: `400`.

**TC-OAUTH-07 — user denies Google consent**
- Action: call the callback endpoint with `error=access_denied` (no `code`).
- Expect: redirect to `{redirect_uri}?error=oauth_denied`; no user created or modified.

**TC-OAUTH-08 — link Google to existing logged-in account**
- Setup: User A is authenticated (has a valid token); no Google identity linked.
- Action: complete the OAuth flow with `link=true` and a Google profile whose email differs from User A's email.
- Expect: UserIdentity created for User A with the new `provider_user_id`; existing account not changed; response `200` JSON (not a redirect).

**TC-OAUTH-09 — cannot link a Google identity already used by another account**
- Setup: User B has a UserIdentity with `provider_user_id = "google-uid-999"`. User A is authenticated.
- Action: User A attempts to link Google with `sub = "google-uid-999"`.
- Expect: `409 CONFLICT`; User A's account unchanged.

**TC-OAUTH-10 — disconnect Google when password exists**
- Setup: User A has a password and a linked Google UserIdentity.
- Action: `DELETE /auth/oauth/google` as User A.
- Expect: `204`; UserIdentity row deleted; User A can still log in with password.

**TC-OAUTH-11 — disconnect Google blocked when it is the only login method**
- Setup: User A has `password_hash = null` and only one UserIdentity (Google).
- Action: `DELETE /auth/oauth/google` as User A.
- Expect: `409 CONFLICT`; UserIdentity NOT deleted.

**TC-OAUTH-12 — OAuth-only user can add a password**
- Setup: User A has `password_hash = null`.
- Action: `POST /auth/set-password` `{ password: "NewPass1!" }` as User A.
- Expect: `204`; User A now has a `password_hash`; can log in with email + new password.

**TC-OAUTH-13 — set-password blocked if password already set**
- Setup: User A already has a `password_hash`.
- Action: `POST /auth/set-password` `{ password: "AnotherPass1!" }`.
- Expect: `409 CONFLICT`.

**TC-OAUTH-14 — one-time callback code expires after 60 seconds**
- Setup: server issued a one-time OAuth callback code C with TTL 60s.
- Action: call `POST /auth/token-exchange` with C after 61 seconds.
- Expect: `401`; no token issued.

**TC-OAUTH-15 — one-time callback code is single-use**
- Setup: valid one-time code C.
- Action: call `POST /auth/token-exchange` with C twice in quick succession.
- Expect: first call returns `200`; second call returns `401`.

---

## 2. Products

**TC-PROD-01 — list products is public**
- Action: `GET /products` with no auth header.
- Expect: `200`, paginated list; archived products are excluded.

**TC-PROD-02 — filter by category**
- Setup: products P1 (category "shoes"), P2 (category "bags").
- Action: `GET /products?category=shoes`
- Expect: `200`, only P1 in results.

**TC-PROD-03 — search by name**
- Setup: products "Red Sneakers", "Blue Hat".
- Action: `GET /products?search=sneaker`
- Expect: "Red Sneakers" in results; "Blue Hat" not in results.

**TC-PROD-04 — price range filter**
- Setup: products at 500, 1500, 3000 cents.
- Action: `GET /products?min_price=1000&max_price=2000`
- Expect: only the 1500-cent product returned.

**TC-PROD-05 — customer cannot create product**
- Setup: User A with role `customer`.
- Action: `POST /products` with valid body.
- Expect: `403`.

**TC-PROD-06 — admin creates product**
- Setup: admin user, valid category exists.
- Action: `POST /products` with all required fields.
- Expect: `201`, product returned with a new UUID, `status: "draft"` if not specified.

**TC-PROD-07 — delete sets status to archived**
- Setup: admin user, product P exists.
- Action: `DELETE /products/{P.id}`
- Expect: `204`; `GET /products/{P.id}` returns `404`; record in DB has `status = "archived"`.

---

## 3. Cart

**TC-CART-01 — GET cart creates one if none exists**
- Setup: User A has no cart.
- Action: `GET /cart`
- Expect: `200`, cart returned with empty `items`.

**TC-CART-02 — add item**
- Setup: User A has empty cart; product P with `stock_quantity = 5`.
- Action: `POST /cart/items` `{ product_id: P.id, quantity: 2 }`
- Expect: `200`, cart contains one item with `quantity = 2`, `unit_price` matches P.price.

**TC-CART-03 — add same item twice merges quantity**
- Setup: User A cart has P with `quantity = 2`.
- Action: `POST /cart/items` `{ product_id: P.id, quantity: 1 }`
- Expect: cart has P with `quantity = 3`.

**TC-CART-04 — add item exceeding stock**
- Setup: product P with `stock_quantity = 3`.
- Action: `POST /cart/items` `{ product_id: P.id, quantity: 5 }`
- Expect: `409`, error code `CONFLICT`.

**TC-CART-05 — set quantity to 0 removes item**
- Setup: User A cart has product P.
- Action: `PATCH /cart/items/{P.id}` `{ quantity: 0 }`
- Expect: `200`, P is removed from cart items.

**TC-CART-06 — clear cart**
- Setup: User A cart has 3 items.
- Action: `DELETE /cart`
- Expect: `204`; `GET /cart` returns empty `items`.

**TC-CART-07 — carts are per-user**
- Setup: User A and User B each have carts with different items.
- Action: `GET /cart` as User A.
- Expect: only User A's items returned.

---

## 4. Orders

**TC-ORDER-01 — create order from cart**
- Setup: User A cart has product P (`stock_quantity = 10`, `price = 500`, quantity 1 in cart), valid address.
- Action: `POST /orders` with shipping address.
- Expect: `201`; order has `status = "pending"`; `total > 0`; `payment_client_secret` present in response; `P.stock_quantity = 9`; a `held` StockReservation exists for the order with `quantity = 1`.

**TC-ORDER-02 — cannot order with empty cart**
- Setup: User A has empty cart.
- Action: `POST /orders` with valid address.
- Expect: `409`.

**TC-ORDER-03 — order history is scoped to user**
- Setup: User A and User B each have one order.
- Action: `GET /orders` as User A.
- Expect: only User A's order in results.

**TC-ORDER-04 — customer cannot access another user's order**
- Setup: User B has order O.
- Action: `GET /orders/{O.id}` as User A.
- Expect: `404` (not `403` — do not reveal existence).

**TC-ORDER-05 — admin can access any order**
- Setup: User B has order O.
- Action: `GET /orders/{O.id}` as admin.
- Expect: `200`.

**TC-ORDER-06 — cancel pending order restores stock**
- Setup: User A has order O with `status = "pending"` containing product P (quantity 2, reserved at checkout; `P.stock_quantity` currently 8).
- Action: `POST /orders/{O.id}/cancel` as User A.
- Expect: `200`, `order.status = "cancelled"`; O's reservations are `released`; `P.stock_quantity = 10`.

**TC-ORDER-07 — cannot cancel shipped order**
- Setup: User A has order O with `status = "shipped"`.
- Action: `POST /orders/{O.id}/cancel`.
- Expect: `409`.

**TC-ORDER-10 — cancel paid order refunds and restores stock**
- Setup: User A has order O with `status = "preparing"` (reservations `converted`, fulfillments in `processing`), product P at `stock_quantity = 7` after a quantity-3 purchase.
- Action: `POST /orders/{O.id}/cancel` as User A.
- Expect: `200`, `order.status = "cancelled"`; `P.stock_quantity = 10`; all fulfillments have `status = "cancelled"`; a refund is initiated with the (stubbed) payment provider.

**TC-ORDER-08 — admin status update valid transition**
- Setup: order O with `status = "paid"`.
- Action: `PATCH /orders/{O.id}/status` `{ status: "preparing" }` as admin.
- Expect: `200`, `order.status = "preparing"`.

**TC-ORDER-09 — admin status update invalid transition**
- Setup: order O with `status = "delivered"`.
- Action: `PATCH /orders/{O.id}/status` `{ status: "pending" }` as admin.
- Expect: `409`.

---

## 5. Background Jobs

**TC-JOB-01 — process_order converts reservations and creates fulfillments**
- Setup: order O (`status = "paid"`) contains product P with `quantity = 3`, reserved at checkout (`P.stock_quantity` already decremented to 7; reservations `held`).
- Action: run `process_order` with `{ order_id: O.id }`.
- Expect: O's reservations are `converted`; `P.stock_quantity` still 7 (no double-decrement); fulfillments created in `processing`; cart cleared; `order_update` notification created; `send_order_confirmation_email` job enqueued; `O.status = "preparing"`.

**TC-JOB-02 — release_expired_reservations restores stock and cancels the order**
- Setup: order O (`status = "pending"`) with `held` reservations for product P (`quantity = 3`, `expires_at` in the past); `P.stock_quantity = 7`.
- Action: run `release_expired_reservations`.
- Expect: reservations are `released`; `P.stock_quantity = 10`; `O.status = "cancelled"`; `order_update` notification created.

**TC-JOB-03 — process_order is idempotent**
- Setup: order O successfully processed once (reservations converted, fulfillments created, cart already cleared).
- Action: run `process_order` again with the same `order_id`.
- Expect: no stock change; no duplicate fulfillments or notifications; exits cleanly.

**TC-JOB-04 — handle_payment_webhook on succeeded**
- Setup: order O with `status = "pending"`, `payment_intent_id = "pi_test"`.
- Action: run `handle_payment_webhook` with `{ event_type: "payment_intent.succeeded", payment_intent_id: "pi_test" }`.
- Expect: `O.status = "paid"`; `process_order` enqueued.

**TC-JOB-05 — handle_payment_webhook on failed**
- Setup: order O with `status = "pending"`.
- Action: run `handle_payment_webhook` with `{ event_type: "payment_intent.payment_failed", ... }`.
- Expect: `O.status = "payment_failed"`; `order_update` notification created; `send_order_status_email` enqueued.

**TC-JOB-06 — cleanup_abandoned_carts**
- Setup: Cart C1 updated 31 days ago; Cart C2 updated 1 day ago.
- Action: run `cleanup_abandoned_carts`.
- Expect: C1 deleted from DB; C2 still exists.

**TC-JOB-07 — late payment on an expired (cancelled) order is refunded**
- Setup: order O with `status = "cancelled"` (payment window expired; reservations already `released`), `payment_intent_id = "pi_late"`.
- Action: run `handle_payment_webhook` with `{ event_type: "payment_intent.succeeded", payment_intent_id: "pi_late" }`.
- Expect: a refund is initiated with the (stubbed) payment provider; `O.status` remains `"cancelled"`; `process_order` is NOT enqueued; stock unchanged.

---

## 6. Notifications

**TC-NOTIF-01 — notifications are scoped to user**
- Setup: User A and User B each have one notification.
- Action: `GET /notifications` as User A.
- Expect: only User A's notification returned.

**TC-NOTIF-02 — unread_only filter**
- Setup: User A has 2 read notifications and 1 unread.
- Action: `GET /notifications?unread_only=true`
- Expect: only the 1 unread notification returned.

**TC-NOTIF-03 — mark one as read**
- Setup: User A has unread notification N.
- Action: `POST /notifications/{N.id}/read`
- Expect: `200`, `notification.read = true`; `GET /notifications/count` returns `{ unread: 0 }`.

**TC-NOTIF-04 — mark all as read**
- Setup: User A has 5 unread notifications.
- Action: `POST /notifications/read-all`
- Expect: `204`; `GET /notifications/count` returns `{ unread: 0 }`.

**TC-NOTIF-05 — notification created on order placed**
- Setup: order O transitions to `paid` via `handle_payment_webhook`.
- Action: run `process_order`.
- Expect: one `order_update` notification exists for `O.user_id` with title matching "Order #{O.id} confirmed".

---

## 7. Chat

**TC-CHAT-01 — customer can open conversation**
- Setup: User A with role `customer`.
- Action: `POST /conversations` `{ type: "support", subject: "Where is my order?", initial_message: "Hi, I need help." }`
- Expect: `201`, conversation with `status = "open"`, one message with `body = "Hi, I need help."`, `sender_role = "customer"`.

**TC-CHAT-02 — customer cannot view another customer's conversation**
- Setup: User B has conversation C.
- Action: `GET /conversations/{C.id}` as User A (customer).
- Expect: `404`.

**TC-CHAT-03 — support agent can view all conversations**
- Setup: User B (customer) has conversation C.
- Action: `GET /conversations/{C.id}` as support agent.
- Expect: `200`.

**TC-CHAT-04 — send message in open conversation**
- Setup: conversation C with `status = "open"`.
- Action: `POST /conversations/{C.id}/messages` `{ body: "Hello!" }` as participant.
- Expect: `201`, message returned with sender's `user_id`, `created_at`.

**TC-CHAT-05 — cannot send message in closed conversation**
- Setup: conversation C with `status = "closed"`.
- Action: `POST /conversations/{C.id}/messages` `{ body: "Hello?" }`.
- Expect: `409`.

**TC-CHAT-06 — edit message within 5 minutes**
- Setup: Message M created by User A 2 minutes ago.
- Action: `PATCH /conversations/{C.id}/messages/{M.id}` `{ body: "Edited" }` as User A.
- Expect: `200`, `message.body = "Edited"`, `edited_at` is set.

**TC-CHAT-07 — edit message after 5 minutes rejected**
- Setup: Message M created by User A 6 minutes ago.
- Action: `PATCH /conversations/{C.id}/messages/{M.id}` as User A.
- Expect: `403`.

**TC-CHAT-08 — another user cannot edit your message**
- Setup: Message M created by User A.
- Action: `PATCH .../messages/{M.id}` as User B (non-admin).
- Expect: `403`.

**TC-CHAT-09 — soft delete replaces body**
- Setup: Message M with `body = "Some text"`.
- Action: `DELETE /conversations/{C.id}/messages/{M.id}` as sender.
- Expect: `200`, `message.body = "[deleted]"`, `deleted_at` is set; message still appears in history.

**TC-CHAT-10 — support agent changes status**
- Setup: conversation C with `status = "open"`.
- Action: `PATCH /conversations/{C.id}/status` `{ status: "resolved" }` as support agent.
- Expect: `200`, `conversation.status = "resolved"`.

**TC-CHAT-11 — customer cannot change conversation status**
- Action: `PATCH /conversations/{C.id}/status` `{ status: "resolved" }` as customer.
- Expect: `403`.

**TC-CHAT-12 — paginated message history newest-first**
- Setup: 25 messages in conversation C.
- Action: `GET /conversations/{C.id}/messages?per_page=10`
- Expect: 10 messages, ordered newest-first, `meta.total = 25`.

**TC-CHAT-13 — unread count reflects unread messages**
- Setup: User A participates in conversation C with 3 messages from the agent that A has not read.
- Action: `GET /conversations/unread-count` as User A; then `CHAT_MARK_READ` (or REST read endpoint) up to the latest message; then `GET /conversations/unread-count` again.
- Expect: first call returns `{ unread: 3 }`; second call returns `{ unread: 0 }`.

---

## 8. WebSocket

For WebSocket tests, establish an authenticated connection (token in query param), then interact via the message protocol defined in [websocket.md](websocket.md).

**TC-WS-01 — invalid token rejected**
- Action: Connect with `?token=invalid_token`.
- Expect: connection closed with code `4001`.

**TC-WS-02 — order status update pushed**
- Setup: User A connected via WebSocket; User A has order O.
- Action: admin updates O status to `shipped` via `PATCH /orders/{O.id}/status`.
- Expect: User A receives `ORDER_STATUS_CHANGED` with `{ order_id: O.id, status: "shipped" }`.

**TC-WS-03 — notification pushed on creation**
- Setup: User A connected.
- Action: `process_order` runs for User A's order and creates a notification.
- Expect: User A receives `NOTIFICATION_CREATED` with notification data.

**TC-WS-04 — notification not pushed to other users**
- Setup: User A and User B both connected.
- Action: notification created for User A.
- Expect: User A receives `NOTIFICATION_CREATED`; User B receives nothing.

**TC-WS-05 — PING / PONG keepalive**
- Setup: User A connected.
- Action: Wait for server to send `PING` (within 35s).
- Expect: server sends `PING`; after client replies with `PONG`, connection remains open.

**TC-WS-06 — chat message pushed to participants**
- Setup: User A (customer) and Agent B are participants in conversation C; both connected.
- Action: User A sends a message via `POST /conversations/{C.id}/messages`.
- Expect: Agent B receives `CHAT_MESSAGE_CREATED` with the message payload.

**TC-WS-07 — typing indicator broadcast**
- Setup: User A and Agent B both connected; both in conversation C.
- Action: User A sends `CHAT_TYPING_START` `{ conversation_id: C.id }`.
- Expect: Agent B receives `CHAT_TYPING_START` with `{ conversation_id: C.id, user_id: A.id }`.

**TC-WS-08 — typing indicator auto-cancels after 5s**
- Setup: Same as TC-WS-07. User A sent `CHAT_TYPING_START` but never sends `CHAT_TYPING_STOP` or a message.
- Expect: Agent B receives `CHAT_TYPING_STOP` within 6 seconds.

**TC-WS-09 — user does not receive own typing indicator**
- Setup: User A connected and in conversation C.
- Action: User A sends `CHAT_TYPING_START`.
- Expect: User A does NOT receive `CHAT_TYPING_START` back.

**TC-WS-10 — cart sync across tabs**
- Setup: User A connected in two separate WebSocket connections (two tabs).
- Action: User A adds an item to cart from tab 1 (via REST).
- Expect: tab 2 connection receives `CART_UPDATED` with updated `item_count`.

**TC-WS-11 — INVENTORY_LOW only sent to admins**
- Setup: admin user A and customer user B both connected. Product P had `stock_quantity = 11` before a quantity-2 checkout reserved stock (now 9).
- Action: `process_order` runs for that order (it checks post-sale stock levels).
- Expect: User A (admin) receives `INVENTORY_LOW` with `{ product_id: P.id, stock_quantity: 9 }`; User B does NOT.

**TC-WS-12 — presence: connect sets online**
- Setup: User A (support agent) is offline.
- Action: User A connects via WebSocket.
- Expect: admin/support users connected receive `PRESENCE_CHANGED` `{ user_id: A.id, status: "online" }`.

**TC-WS-13 — presence: disconnect sets offline after grace period**
- Setup: User A is connected.
- Action: User A disconnects.
- Expect: after 10s, admin/support users receive `PRESENCE_CHANGED` `{ user_id: A.id, status: "offline" }`.

---

## 9. Security

**TC-SEC-01 — password hash not in API response**
- Action: `POST /auth/register` or `GET /auth/me`.
- Expect: response body does not contain a field named `password`, `password_hash`, or any string that looks like a bcrypt/argon hash.

**TC-SEC-02 — customer cannot access admin endpoint**
- Setup: User A with role `customer`.
- Action: `POST /products` with a valid body.
- Expect: `403`.

**TC-SEC-03 — invalid webhook signature rejected**
- Action: `POST /webhooks/payment` with a valid-looking body but incorrect `X-Signature` header.
- Expect: `400`.

**TC-SEC-04 — webhook without signature rejected**
- Action: `POST /webhooks/payment` with no `X-Signature` header.
- Expect: `400`.

**TC-SEC-05 — SQL injection in search parameter**
- Action: `GET /products?search='; DROP TABLE products; --`
- Expect: `200` with empty or normal results; no server error; database intact.

**TC-SEC-06 — rate limit on login**
- Action: `POST /auth/login` with wrong credentials 11 times in quick succession from the same IP.
- Expect: at least one response with status `429` and a `Retry-After` header.

---

## 10. Merchants

### 10.1 Application

**TC-MERCH-01 — customer can apply to become a merchant**
- Setup: User A with role `customer`, `store_slug = "my-store"` not taken.
- Action: `POST /merchants/apply` `{ store_name: "My Store", store_slug: "my-store" }` as User A.
- Expect: `201`; MerchantProfile created with `status = "pending"`; `merchant_account` notification created with title "Application received".

**TC-MERCH-02 — cannot apply twice**
- Setup: User A already has a MerchantProfile.
- Action: `POST /merchants/apply` again.
- Expect: `409`.

**TC-MERCH-03 — duplicate store slug rejected**
- Setup: store slug `"taken-slug"` already exists.
- Action: `POST /merchants/apply` `{ store_slug: "taken-slug" }`.
- Expect: `422`, details reference `store_slug`.

**TC-MERCH-04 — admin approves merchant**
- Setup: MerchantProfile M with `status = "pending"`.
- Action: `PATCH /merchants/{M.id}/status` `{ status: "approved" }` as admin.
- Expect: `200`; `M.status = "approved"`; User's role in DB is `merchant`; `merchant_account` notification created with title "Your store is approved".

**TC-MERCH-05 — admin rejects merchant application**
- Setup: MerchantProfile M with `status = "pending"`.
- Action: `PATCH /merchants/{M.id}/status` `{ status: "rejected", rejection_reason: "Insufficient info" }` as admin.
- Expect: `200`; `M.status = "rejected"`; `M.rejection_reason = "Insufficient info"`; `merchant_account` notification created with title "Application not approved".

**TC-MERCH-06 — suspended merchant's active products are archived**
- Setup: Merchant M (approved) has two `active` products P1 and P2.
- Action: `PATCH /merchants/{M.id}/status` `{ status: "suspended" }` as admin.
- Expect: P1 and P2 both have `status = "archived"`; they no longer appear in `GET /products`.

### 10.2 Product Lifecycle

**TC-MERCH-07 — approved merchant creates product as draft**
- Setup: User A is an approved merchant.
- Action: `POST /products` with valid body.
- Expect: `201`; `product.status = "draft"`; `product.merchant_id = A.merchant_profile_id`; `product.merchant_id` is NOT null; product does NOT appear in `GET /products` (public listing).

**TC-MERCH-08 — pending merchant cannot create product**
- Setup: User A has MerchantProfile with `status = "pending"`.
- Action: `POST /products`.
- Expect: `403`.

**TC-MERCH-09 — merchant submits product for review**
- Setup: Merchant A owns draft product P.
- Action: `POST /products/{P.id}/submit` as Merchant A.
- Expect: `200`; `product.status = "pending_approval"`; product still not visible in public listing.

**TC-MERCH-10 — merchant cannot submit another merchant's product**
- Setup: Merchant B owns product P.
- Action: `POST /products/{P.id}/submit` as Merchant A.
- Expect: `403`.

**TC-MERCH-11 — admin approves product**
- Setup: product P with `status = "pending_approval"`, owned by Merchant A.
- Action: `PATCH /products/{P.id}/review` `{ action: "approve" }` as admin.
- Expect: `200`; `product.status = "active"`; product appears in `GET /products`; `merchant_product` notification created for Merchant A with title ""{P.name}" is now live".

**TC-MERCH-12 — admin rejects product**
- Setup: product P with `status = "pending_approval"`.
- Action: `PATCH /products/{P.id}/review` `{ action: "reject", rejection_reason: "Images are too low resolution" }` as admin.
- Expect: `200`; `product.status = "rejected"`; `rejection_reason` stored; `merchant_product` notification created for Merchant A.

**TC-MERCH-13 — merchant can edit rejected product and resubmit**
- Setup: product P with `status = "rejected"`, owned by Merchant A.
- Action: `PATCH /products/{P.id}` `{ name: "Better Name" }` as Merchant A; then `POST /products/{P.id}/submit`.
- Expect: first call `200`, `product.name = "Better Name"`; second call `200`, `product.status = "pending_approval"`.

**TC-MERCH-14 — merchant cannot edit active product**
- Setup: product P with `status = "active"`, owned by Merchant A.
- Action: `PATCH /products/{P.id}` as Merchant A.
- Expect: `403`.

**TC-MERCH-15 — merchant cannot edit another merchant's product**
- Setup: product P owned by Merchant B, `status = "draft"`.
- Action: `PATCH /products/{P.id}` as Merchant A.
- Expect: `403`.

**TC-MERCH-16 — rejection_reason not exposed in public product response**
- Setup: product P with `rejection_reason = "Bad images"`, `status = "active"`.
- Action: `GET /products/{P.id}` with no auth.
- Expect: `200`; response body does NOT contain `rejection_reason`.

### 10.3 Sales & Orders

**TC-MERCH-17 — merchant order list contains only own products**
- Setup: Merchant A owns product PA. Merchant B owns product PB. Customer places an order containing both PA and PB.
- Action: `GET /merchants/me/orders` as Merchant A.
- Expect: the order appears in results; line items include PA but NOT PB.

**TC-MERCH-18 — merchant order list omits customer PII**
- Setup: same as TC-MERCH-17.
- Action: `GET /merchants/me/orders` as Merchant A.
- Expect: response does not contain `email`, `full_name`, `shipping_address`, or `password_hash` of the customer.

### 10.4 Public Storefront

**TC-MERCH-19 — public storefront returns only active products**
- Setup: Merchant A has products: P1 (`active`), P2 (`draft`), P3 (`archived`).
- Action: `GET /products?merchant_id={A.merchant_profile_id}` with no auth.
- Expect: only P1 in results.

**TC-MERCH-20 — customer cannot access pending merchant's storefront**
- Setup: MerchantProfile M with `status = "pending"`.
- Action: `GET /merchants/{M.id}` with no auth.
- Expect: `404`.

**TC-MERCH-21 — admin product belongs to platform merchant**
- Setup: admin user; platform MerchantProfile P (`is_platform = true`) exists.
- Action: `POST /products` as admin with valid body.
- Expect: `201`; `product.merchant_id = P.id`; `product.merchant_id` is NOT null.

**TC-MERCH-22 — rejected applicant can re-apply**
- Setup: User A has a MerchantProfile with `status = "rejected"`. User A's role is `customer`.
- Action: `POST /merchants/apply` `{ store_name: "Better Store", store_slug: "better-store" }` as User A.
- Expect: `201`; the existing profile is updated with the new values and `status = "pending"`; no second MerchantProfile row is created.

---

## 11. Address Book

**TC-ADDR-01 — create a saved address**
- Setup: User A has no saved addresses.
- Action: `POST /addresses` `{ label: "Home", line1: "123 Main St", city: "Springfield", state: "IL", postal_code: "62701", country: "US", is_default: true }`.
- Expect: `201`; address returned with `user_id = A.id`, `is_default = true`.

**TC-ADDR-02 — address list is scoped to user**
- Setup: User A and User B each have one saved address.
- Action: `GET /addresses` as User A.
- Expect: only User A's address returned; User B's address not in response.

**TC-ADDR-03 — setting a new default clears the previous one**
- Setup: User A has address A1 (`is_default = true`) and address A2 (`is_default = false`).
- Action: `POST /addresses/{A2.id}/set-default`.
- Expect: `200`; `A2.is_default = true`; `A1.is_default = false` in the database.

**TC-ADDR-04 — enforce 10-address limit**
- Setup: User A has 10 saved addresses.
- Action: `POST /addresses` with a new address.
- Expect: `409 CONFLICT`.

**TC-ADDR-05 — checkout with saved address_id**
- Setup: User A has saved address A1. Cart has one item.
- Action: `POST /orders` `{ address_id: A1.id }`.
- Expect: `201`; `order.shipping_address` fields match A1's fields exactly.

**TC-ADDR-06 — checkout snapshots address — later edit does not affect order**
- Setup: User A places an order using address A1. Then `PATCH /addresses/{A1.id}` changes `city` to "Shelbyville".
- Action: `GET /orders/{order_id}`.
- Expect: `order.shipping_address.city` still equals the original city at time of checkout.

**TC-ADDR-07 — checkout with inline address (no address_id)**
- Setup: User A has no saved addresses. Cart has one item.
- Action: `POST /orders` with inline `shipping_address` object.
- Expect: `201`; address fields on order match the inline input. No new `UserAddress` row created.

**TC-ADDR-08 — checkout with address_id belonging to another user**
- Setup: User B has address B1. User A is placing an order.
- Action: `POST /orders` `{ address_id: B1.id }` as User A.
- Expect: `404`; no order created.

**TC-ADDR-09 — checkout with neither address_id nor shipping_address**
- Action: `POST /orders` `{}` with items in cart.
- Expect: `422`.

**TC-ADDR-10 — delete address does not affect past orders**
- Setup: User A placed order O using address A1. Then `DELETE /addresses/{A1.id}`.
- Action: `GET /orders/{O.id}`.
- Expect: `order.shipping_address` still contains the original address fields; no nulls.

**TC-ADDR-11 — merchant sees fulfillment shipping_address, not user's address book**
- Setup: Order O has Fulfillment F (Merchant A). Customer has 3 saved addresses.
- Action: `GET /orders/{O.id}/fulfillments` as Merchant A.
- Expect: `F.shipping_address` contains the snapshot; no `UserAddress` IDs or other addresses are in the response.

**TC-ADDR-12 — cannot access another user's address**
- Setup: User B has address B1.
- Action: `PATCH /addresses/{B1.id}` as User A.
- Expect: `404`.

---

## 12. Logistics

### 12.1 Shipping Methods

**TC-LOG-01 — merchant creates a flat-rate shipping method**
- Setup: Merchant A is approved.
- Action: `POST /merchants/me/shipping-methods` `{ name: "Standard", type: "flat", flat_rate_cents: 599, min_days: 3, max_days: 7 }`.
- Expect: `201`; method returned with `merchant_id = A.merchant_profile_id`, `is_active = true`.

**TC-LOG-02 — weight_based method requires per_kg_cents**
- Action: `POST /merchants/me/shipping-methods` `{ type: "weight_based" }` with no `per_kg_cents`.
- Expect: `422`, details reference `per_kg_cents`.

**TC-LOG-03 — cannot deactivate only active shipping method**
- Setup: Merchant A has exactly one active shipping method M.
- Action: `DELETE /merchants/me/shipping-methods/{M.id}`.
- Expect: `409`.

### 12.2 Fulfillments

**TC-LOG-04 — order creates fulfillments grouped by merchant**
- Setup: Customer cart has product PA (Merchant A) and product PB (Merchant B).
- Action: `POST /orders` to place the order; complete payment (run `handle_payment_webhook` on succeeded, then `process_order`).
- Expect: `GET /orders/{order_id}/fulfillments` returns 2 fulfillments — one with `merchant_id = A.id`, one with `merchant_id = B.id`. Each contains only its merchant's items, in `processing` status.

**TC-LOG-05 — merchant can only see own fulfillments**
- Setup: Order O has fulfillments FA (Merchant A) and FB (Merchant B).
- Action: `GET /orders/{O.id}/fulfillments` as Merchant A.
- Expect: only FA returned; FB not included.

**TC-LOG-06 — merchant marks fulfillment as shipped**
- Setup: Fulfillment F with `status = "processing"`, owned by Merchant A.
- Action: `POST /orders/{O.id}/fulfillments/{F.id}/ship` `{ tracking_number: "1Z999", carrier: "UPS" }` as Merchant A.
- Expect: `200`; `F.status = "shipped"`; a Shipment record is created; customer receives `logistics` notification.

**TC-LOG-07 — merchant cannot ship another merchant's fulfillment**
- Setup: Fulfillment F owned by Merchant B.
- Action: `POST /orders/{O.id}/fulfillments/{F.id}/ship` as Merchant A.
- Expect: `403`.

**TC-LOG-08 — cannot ship a fulfillment not in processing status**
- Setup: Fulfillment F with `status = "pending"`.
- Action: `POST /orders/{O.id}/fulfillments/{F.id}/ship`.
- Expect: `409`.

### 12.3 Shipment Tracking

**TC-LOG-09 — public tracking page returns events**
- Setup: Shipment S with 2 ShipmentEvents.
- Action: `GET /shipments/{S.id}` with no auth.
- Expect: `200`; response contains `events` array with 2 entries; response does NOT contain customer email, shipping address, or order total.

**TC-LOG-10 — sync_shipment_tracking updates status and notifies customer**
- Setup: Shipment S with `status = "in_transit"`; customer connected via WebSocket.
- Action: run `sync_shipment_tracking` with a new event `{ status: "delivered", ... }`.
- Expect: `S.status = "delivered"`; parent Fulfillment status = `"delivered"`; customer receives `logistics` notification AND `SHIPMENT_STATUS_CHANGED` WebSocket event.

**TC-LOG-11 — all fulfillments delivered transitions order to delivered**
- Setup: Order O has 2 fulfillments F1 and F2. F1 is already `delivered`. F2 is `shipped`.
- Action: run `sync_shipment_tracking` with a `delivered` event for F2's shipment.
- Expect: F2 status = `"delivered"`; O.status = `"delivered"`.

**TC-LOG-12 — shipment webhook with invalid signature rejected**
- Action: `POST /webhooks/shipment` with a tampered `X-Signature`.
- Expect: `400`; no Shipment records modified.

### 12.4 Checkout Shipping Selection

**TC-LOG-13 — explicit shipping selection is honored**
- Setup: Merchant A has methods M1 (flat, 599) and M2 (flat, 1299), both active. Customer cart contains Merchant A's product.
- Action: `POST /orders` with `shipping_selections: [{ merchant_id: A.id, shipping_method_id: M2.id }]`; complete payment; run `process_order`.
- Expect: `order.shipping_cost = 1299`; the fulfillment for Merchant A has `shipping_method_id = M2.id` and `shipping_cost = 1299`.

**TC-LOG-14 — selection omitted falls back to cheapest active method**
- Setup: same as TC-LOG-13.
- Action: `POST /orders` with no `shipping_selections`.
- Expect: `201`; `order.shipping_selections` contains M1 (the cheaper method) with `shipping_cost = 599`.

**TC-LOG-15 — selection referencing another merchant's method rejected**
- Setup: Merchant B has method MB. Customer cart contains only Merchant A's product.
- Action: `POST /orders` with `shipping_selections: [{ merchant_id: A.id, shipping_method_id: MB.id }]`.
- Expect: `422`; no order created; no stock reserved.

---

## 13. Merchant Chat

**TC-CHAT-MERCH-01 — customer opens merchant conversation**
- Setup: Customer A; Merchant B is approved.
- Action: `POST /conversations` `{ type: "merchant", merchant_id: B.merchant_profile_id, initial_message: "Is this in stock?" }`.
- Expect: `201`; conversation with `type = "merchant"` and `merchant_id = B.merchant_profile_id`; message with `sender_role = "customer"`.

**TC-CHAT-MERCH-02 — duplicate open merchant conversation returns 409**
- Setup: Customer A already has an `open` merchant conversation with Merchant B.
- Action: `POST /conversations` with same merchant_id again.
- Expect: `409`; existing conversation returned in error body.

**TC-CHAT-MERCH-03 — new conversation after previous one is resolved**
- Setup: Customer A has a `resolved` merchant conversation with Merchant B.
- Action: `POST /conversations` `{ type: "merchant", merchant_id: B.merchant_profile_id, initial_message: "New question" }`.
- Expect: `201`; a new conversation is created (resolved one does not block it).

**TC-CHAT-MERCH-04 — merchant can reply in their own conversation**
- Setup: Customer A and Merchant B have an open merchant conversation C.
- Action: `POST /conversations/{C.id}/messages` `{ body: "Yes, in stock!" }` as Merchant B's user.
- Expect: `201`; message with `sender_role = "merchant"`.

**TC-CHAT-MERCH-05 — merchant cannot send message in another merchant's conversation**
- Setup: Customer A and Merchant B have conversation C. Merchant C is a different merchant.
- Action: `POST /conversations/{C.id}/messages` as Merchant C's user.
- Expect: `403`.

**TC-CHAT-MERCH-06 — customer cannot see another customer's merchant conversation**
- Setup: Customer A has merchant conversation C with Merchant B.
- Action: `GET /conversations/{C.id}` as Customer Z (different customer).
- Expect: `404`.

**TC-CHAT-MERCH-07 — merchant conversation scoped to own store**
- Setup: Merchant A and Merchant B both have separate merchant conversations.
- Action: `GET /conversations?type=merchant` as Merchant A.
- Expect: only Merchant A's conversations returned; Merchant B's not included.

**TC-CHAT-MERCH-08 — merchant can change own conversation status to resolved**
- Setup: Customer A and Merchant B have open conversation C.
- Action: `PATCH /conversations/{C.id}/status` `{ status: "resolved" }` as Merchant B.
- Expect: `200`; `conversation.status = "resolved"`.

**TC-CHAT-MERCH-09 — support agent cannot send messages in merchant conversation**
- Setup: merchant conversation C.
- Action: `POST /conversations/{C.id}/messages` as a support agent.
- Expect: `403`.

**TC-CHAT-MERCH-10 — merchant chat message pushed via WebSocket**
- Setup: Customer A and Merchant B connected via WebSocket; open merchant conversation C.
- Action: Merchant B sends a message via REST `POST /conversations/{C.id}/messages`.
- Expect: Customer A receives `CHAT_MESSAGE_CREATED` with the message; Merchant B does NOT receive it back.

---

## 14. Concurrency (Stock Atomicity)



These tests require simulating simultaneous requests. Use parallel HTTP clients or threads.

**TC-CONC-01 — last unit goes to exactly one buyer**
- Setup: product P with `stock_quantity = 1`. Users A and B each have P in their cart.
- Action: `POST /orders` from User A and User B simultaneously.
- Expect: exactly one order succeeds (`201`) and holds a `held` StockReservation; the other fails (`409`). `P.stock_quantity` is 0 after both requests complete. No negative stock.

**TC-CONC-02 — concurrent process_order calls are idempotent**
- Setup: order O with `status = "paid"` and `held` reservations from checkout.
- Action: run `process_order` with `O.id` twice concurrently.
- Expect: reservations converted exactly once; stock unchanged by the job; exactly one set of fulfillments; exactly one confirmation notification created.

---

## 15. OpenAPI Compliance

See [api.md](api.md) §OpenAPI Compliance. These verify the document exists, validates, and matches reality.

**TC-OAS-01 — document is served and valid**
- Action: `GET /api/v1/openapi.json` with no auth.
- Expect: `200`; body is JSON with `openapi` starting `"3.1"`; the document passes a standard OpenAPI 3.1 validator with zero errors.

**TC-OAS-02 — docs UI is served**
- Action: `GET /api/v1/docs` with no auth.
- Expect: `200`, an HTML page (Swagger UI or Redoc).

**TC-OAS-03 — bearer security scheme declared**
- Action: parse the document from TC-OAS-01.
- Expect: `components.securitySchemes` contains an HTTP bearer scheme (`type: http`, `scheme: bearer`, `bearerFormat: JWT`); an authenticated route (e.g. `GET /auth/me`) lists it under `security`; a public route (e.g. `GET /products`) does not require it.

**TC-OAS-04 — every documented endpoint is real (no phantom paths)**
- Action: for each `path`+`method` in the document, issue a request (unauthenticated is fine; auth/validation errors are acceptable).
- Expect: no response is `404 NOT_FOUND` with code `NOT_FOUND` due to an undefined route — i.e. the route exists. The document describes only real endpoints.

**TC-OAS-05 — real endpoints are documented (no missing paths)**
- Setup: a curated list of core routes (`POST /auth/login`, `GET /products`, `GET /products/:id`, `POST /orders`, `GET /cart`, `GET /conversations`).
- Action: check each is present in the document's `paths`.
- Expect: all present, with the correct method.

**TC-OAS-06 — responses conform to declared schemas**
- Setup: authenticated User A with a known product and cart.
- Action: call `GET /products/{id}` and `GET /cart`; validate each response body against the response schema the document declares for that endpoint (resolve `$ref`s).
- Expect: both responses validate against their declared schemas (required fields present, types match).

**TC-OAS-07 — error envelope is modeled**
- Action: parse the document; trigger a `422` (e.g. `POST /auth/register` with a weak password) and a `404`.
- Expect: the document declares a reusable error schema (matching the error envelope) and references it for the `4xx`/`5xx` responses; the live `422` and `404` bodies validate against that schema.

---

## Test Environment Requirements

- Database must be in a known clean state at the start of each test (use transactions that roll back, or a fresh schema per test).
- Background jobs can be run synchronously in tests (inline execution, no queue needed) unless the test is specifically testing async behavior.
- Email delivery must write to a local trap or stub — never send real email.
- WebSocket tests require a running server; spin one up in the test process or use a shared test server with per-test user isolation.
- Payment provider calls must be intercepted with a stub or test mode — never hit a real payment API in tests.
- All tests must complete within **30 seconds** individually; the full suite within **5 minutes**.
