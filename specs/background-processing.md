# Background Processing

All jobs must be:
- **Durable** — survive process restarts (persisted to a queue or database).
- **Idempotent** — safe to run more than once with the same input.
- **Observable** — job status (pending, running, succeeded, failed) must be inspectable.

Use any queue implementation: Redis + worker, database-backed queue, SQS, Celery, Sidekiq, BullMQ, etc.

---

## Retry Policy (default)

Unless stated otherwise, all jobs retry **3 times** with exponential backoff:

| Attempt | Delay |
|---|---|
| 1st retry | 30s |
| 2nd retry | 5m |
| 3rd retry | 30m |

After exhausting retries, the job moves to a dead-letter queue and an alert is logged.

---

## Jobs

### `send_verification_email`
**Trigger:** `POST /auth/register`
**Input:** `{ user_id: uuid }`
**Actions:**
1. Generate a signed, time-limited (24h) email verification token.
2. Send an email to the user's address with a verification link.

---

### `handle_payment_webhook`
**Trigger:** `POST /webhooks/payment` after signature verification
**Input:** `{ event_type: string, payment_intent_id: string }`

**On `payment_intent.succeeded`:**
1. Find the order by `payment_intent_id`.
2. If the order is `cancelled` (the payment window expired and `release_expired_reservations` already cancelled it), initiate a refund via the payment provider and stop.
3. Transition order status to `paid`.
4. Enqueue `process_order`.

**On `payment_intent.payment_failed`:**
1. Find the order by `payment_intent_id`.
2. Transition order status to `payment_failed`.
3. Release the order's `held` StockReservations: atomically increment each product's `stock_quantity` back and mark the reservations `released`.
4. Create an `order_update` notification for the customer.
5. Enqueue `send_order_status_email` with `{ order_id, new_status: "payment_failed" }`.

Idempotency: check current order status before transitioning; skip if already at target. Only `held` reservations are released — never release twice.

---

### `process_order`
**Trigger:** `handle_payment_webhook` (on succeeded)
**Input:** `{ order_id: uuid }`
**Actions:**
1. Mark all of the order's StockReservations `converted`. Stock was already decremented atomically at checkout — **do not decrement again.**
2. Group the order's items by `merchant_id`. For each group, create one Fulfillment record with `status = "pending"`, copying `Order.shipping_address` into `Fulfillment.shipping_address` and the method + cost from the order's ShippingSelection for that merchant. Then transition all of the order's fulfillments to `processing`.
3. Clear the user's cart.
4. Create `order_update` notification: "Order #`{id}` confirmed."
5. Enqueue `send_order_confirmation_email`.
6. Check if any of the order's products has `stock_quantity` below 10; if so, push `INVENTORY_LOW` via WebSocket to all admin connections.
7. For each merchant whose products appear in the order, create a `merchant_product` notification: "You have a new order."
8. Transition the order to `preparing`.

Idempotency: check whether reservations are already converted, fulfillments already created, and the cart already cleared before acting.

---

### `send_order_confirmation_email`
**Trigger:** `process_order` (step 5)
**Input:** `{ order_id: uuid }`
**Actions:**
1. Render an order summary (items, totals, shipping address).
2. Send to the customer's email address.

---

### `send_order_status_email`
**Trigger:** `PATCH /orders/:id/status` by admin, `POST /orders/:id/cancel`, `handle_payment_webhook` on failure, or automatic order transitions (all fulfillments `shipped` / `delivered`)
**Input:** `{ order_id: uuid, new_status: string }`
**Actions:**
- `shipped`: create `order_update` notification "Your order has shipped"; send shipping confirmation email with tracking number if available.
- `delivered`: create `order_update` notification "Order #{id} delivered"; send delivery confirmation email with a link to leave a review.
- `cancelled`: create `order_update` notification "Order #{id} cancelled"; send cancellation notice email with refund timeline.
- `payment_failed`: (handled by `handle_payment_webhook`; no duplicate notification here).
- Other statuses: no action.

---

### `send_missed_message_notification`
**Trigger:** New chat message created; see [chat.md](chat.md)
**Input:** `{ message_id: uuid }`
**Actions:**
1. Identify participants who were not online when the message was sent.
2. For each offline participant:
   a. Create a `chat` notification.
   b. Send an email: "New message from [sender name]" with conversation link.

---

### `sync_shipment_tracking`
**Trigger:** `POST /webhooks/shipment` (carrier webhook) OR scheduled poll for carriers that do not push
**Input:** `{ shipment_id: uuid }`
**Actions:**
1. Fetch the latest tracking events for the shipment from the carrier API (or use the inbound webhook payload).
2. Append any new ShipmentEvent rows to the Shipment's `events` array.
3. Update `shipment.status` to match the latest event.
4. If status changed to `delivered`, transition the parent Fulfillment to `delivered`; if all Fulfillments in the Order are `delivered`, transition Order to `delivered`.
5. Create a `logistics` notification for the customer.
6. Push `SHIPMENT_STATUS_CHANGED` via WebSocket to the customer's connection.

Idempotency: skip events already present (deduplicate by `occurred_at + description`).
**Retry:** 3 times with exponential backoff.

---

### `release_expired_reservations`
**Trigger:** Scheduled — every 5 minutes
**Input:** none
**Actions:**
1. Find all `held` StockReservations with `expires_at < now` whose order is still `pending`.
2. For each affected order (in a transaction): atomically increment each product's `stock_quantity` back by the reserved quantity, mark the reservations `released`, and transition the order to `cancelled`.
3. Create an `order_update` notification: "Order #`{id}` cancelled" / "Payment was not completed in time."

Idempotency: only `held` reservations are released; orders already `paid` or `cancelled` are skipped. If a payment webhook races this job, `handle_payment_webhook` handles the already-cancelled order by refunding.

---

### `cleanup_abandoned_carts`
**Trigger:** Scheduled — daily at 02:00 UTC
**Input:** none
**Actions:**
1. Delete carts with `updated_at` older than 30 days.
2. Log the count of deleted carts.

No retry needed — safe to skip a failed run; the next scheduled run will catch it.

---

### `generate_daily_sales_report`
**Trigger:** Scheduled — daily at 00:05 UTC (5-minute offset avoids midnight contention)
**Input:** none
**Actions:**
1. Aggregate all orders with status `delivered` or `shipped` from the previous calendar day.
2. Compute: total revenue, order count, average order value, top 5 products by units sold.
3. Persist the summary to a `sales_reports` table.
4. Optionally email the report to all users with role `admin`.

---

### `poll_shipment_tracking`
**Trigger:** Scheduled — every 4 hours
**Input:** none
**Actions:**
1. Find all Shipments with `status` not in (`delivered`, `failed`).
2. For each, enqueue `sync_shipment_tracking`.

Handles carriers that do not provide push webhooks.

---

## Scheduled Tasks Summary

| Job | Schedule (UTC) |
|---|---|
| `release_expired_reservations` | Every 5 minutes |
| `cleanup_abandoned_carts` | Daily 02:00 |
| `generate_daily_sales_report` | Daily 00:05 |
| `poll_shipment_tracking` | Every 4 hours |
