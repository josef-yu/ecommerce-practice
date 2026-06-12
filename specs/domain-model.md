# Domain Model

All IDs are UUIDs. All timestamps are ISO 8601 UTC strings. Monetary values are integers in the smallest currency unit (e.g. cents).

---

## User

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| email | string | unique |
| password_hash | string? | nullable — OAuth-only users have no password |
| full_name | string | |
| role | enum | `customer`, `merchant`, `support`, `admin` |
| email_verified | bool | always `true` for OAuth-created accounts |
| online_status | enum | `online`, `offline` — updated via WebSocket presence |
| created_at | timestamp | |

---

## UserIdentity

Stores each external OAuth provider connection for a user. A user may have multiple rows (one per provider).

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| user_id | uuid | references User |
| provider | enum | `google` (extensible to `github`, `facebook`, etc.) |
| provider_user_id | string | the user's ID in the external provider's system |
| provider_email | string | email from provider at time of connection |
| access_token | string | encrypted at rest |
| refresh_token | string? | encrypted at rest; nullable if provider doesn't issue one |
| token_expires_at | timestamp? | |
| created_at | timestamp | |
| updated_at | timestamp | |

Unique constraint: `(provider, provider_user_id)` — one account per provider identity.

---

## MerchantProfile

One row per merchant user plus one special **platform merchant** row seeded at startup.

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| user_id | uuid? | references User (role = `merchant`); **null for the platform merchant** |
| store_name | string | unique, public-facing name |
| store_slug | string | unique, URL-safe (e.g. `acme-store`) |
| description | text? | |
| logo_url | string? | |
| status | enum | `pending`, `approved`, `rejected`, `suspended` |
| is_platform | bool | `true` only for the single platform-owned merchant; `false` for all others |
| rejection_reason | string? | set by admin when application is rejected |
| created_at | timestamp | |
| updated_at | timestamp | |

**Platform merchant:** exactly one MerchantProfile row has `is_platform = true`. It is seeded on first run with a well-known `store_slug = "platform"`. It has no associated User and skips the application/approval flow. All admin-created products belong to this profile. It is never returned in public merchant listings.

---

## Product

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| name | string | |
| description | text | |
| price | int | cents |
| stock_quantity | int | must be ≥ 0 |
| weight_grams | int | shipping weight; default `0`; used by `weight_based` shipping methods |
| category_id | uuid | |
| images | string[] | ordered list of URLs |
| merchant_id | uuid | always set; references MerchantProfile — use the platform merchant for admin-created products |
| status | enum | `draft`, `pending_approval`, `active`, `rejected`, `archived` |
| rejection_reason | string? | set by admin when rejecting a merchant's product |
| created_at | timestamp | |

### Product Status State Machine

```
Platform merchant products (is_platform = true):
  draft → active → archived

Third-party merchant products:
  draft → pending_approval → active → archived
                          ↘ rejected → pending_approval (merchant edits and re-submits)
```

Rejected products remain editable by the owning merchant and are resubmitted directly to `pending_approval` via `POST /products/:id/submit`. Merchants may archive (`DELETE`) their own `draft`, `rejected`, or `active` products; admins may archive any product.

---

## Category

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| name | string | |
| slug | string | unique, URL-safe |
| parent_id | uuid? | null = top-level category |

---

## Cart

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| user_id | uuid | |
| items | CartItem[] | |
| updated_at | timestamp | |

## CartItem

| Field | Type | Notes |
|---|---|---|
| product_id | uuid | |
| quantity | int | |
| unit_price | int | snapshot at time of add |

---

## Order

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| user_id | uuid | |
| items | OrderItem[] | |
| status | enum | see state machine below |
| subtotal | int | cents |
| shipping_cost | int | cents; sum of the per-merchant shipping selections, computed at checkout |
| tax | int | cents |
| total | int | cents; final at creation — this is the amount sent to the payment provider |
| shipping_address | Address | snapshot copied from the selected UserAddress at checkout — immutable after creation |
| shipping_selections | ShippingSelection[] | per-merchant shipping choices snapshotted at checkout |
| payment_intent_id | string | from payment provider |
| created_at | timestamp | |
| updated_at | timestamp | |

## ShippingSelection

Embedded value object on Order — one entry per merchant group in the order.

| Field | Type | Notes |
|---|---|---|
| merchant_id | uuid | references MerchantProfile |
| shipping_method_id | uuid | the method chosen (or auto-selected) at checkout |
| shipping_cost | int | cents; computed at checkout from the method's type |

## OrderItem

| Field | Type | Notes |
|---|---|---|
| product_id | uuid | |
| merchant_id | uuid | snapshot — references MerchantProfile at time of order |
| product_name | string | snapshot at time of order |
| quantity | int | |
| unit_price | int | snapshot at time of order |

### Order Status State Machine

```
pending → paid → preparing → shipped → delivered
       ↘ payment_failed
pending | paid | preparing → cancelled
```

Transitions:
- `paid` — set by `handle_payment_webhook` on payment success.
- `preparing` — set automatically at the end of `process_order`.
- `shipped` — set automatically when **all** of the order's fulfillments are `shipped` (or further along).
- `delivered` — set automatically when **all** of the order's fulfillments are `delivered`.
- `cancelled` — allowed from `pending`, `paid`, or `preparing`, and only while no fulfillment is `shipped` or `delivered`. Also set automatically when the payment window expires (see StockReservation).
- Admins may drive transitions manually via `PATCH /orders/:id/status`; the same state-machine rules apply.

When an order contains items from multiple merchants, the top-level Order status reflects the slowest fulfillment (the "all fulfillments" rules above). Each merchant's items have an independent Fulfillment with its own status.

---

## StockReservation

Created at checkout (`POST /orders`) — one row per order line item. Reserving **decrements `product.stock_quantity` immediately** (atomically, within the order-creation transaction); the reservation row records what to restore if payment never completes. `stock_quantity` therefore always reflects currently available units.

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| order_id | uuid | the `pending` order holding the reservation |
| product_id | uuid | |
| quantity | int | units reserved (and already decremented from stock) |
| status | enum | `held`, `converted`, `released` |
| expires_at | timestamp | `created_at + 30 minutes` |
| created_at | timestamp | |

### Reservation Lifecycle

```
held → converted (payment succeeded — process_order; stock stays decremented)
     → released  (payment window expired, payment failed, or order cancelled — stock is incremented back)
```

`release_expired_reservations` (scheduled job) releases `held` reservations past `expires_at` whose order is still `pending`, restores the stock, and cancels the order.

---

## ShippingMethod

Defines how a merchant ships goods. Each merchant can have multiple methods active at once. The platform merchant's shipping methods are the default fallback, used when a merchant has no active methods of their own.

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| merchant_id | uuid | references MerchantProfile |
| name | string | e.g. "Standard", "Express" |
| carrier | string? | e.g. "FedEx", "UPS", "DHL" |
| type | enum | `flat`, `free`, `weight_based` |
| flat_rate_cents | int? | required when `type = flat` |
| per_kg_cents | int? | required when `type = weight_based` |
| min_days | int | estimated min delivery days |
| max_days | int | estimated max delivery days |
| is_active | bool | |
| created_at | timestamp | |

---

## Fulfillment

Groups the subset of an order's items that belong to a single merchant. Each fulfillment is shipped independently.

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| order_id | uuid | |
| merchant_id | uuid | references MerchantProfile |
| items | OrderItem[] | the merchant's items from this order |
| shipping_method_id | uuid | copied from the order's ShippingSelection for this merchant |
| shipping_cost | int | cents; copied from the order's ShippingSelection for this merchant |
| shipping_address | Address | copied from `Order.shipping_address` at fulfillment creation — exposed to the merchant for label generation |
| status | enum | `pending`, `processing`, `shipped`, `delivered`, `cancelled`, `failed` |
| created_at | timestamp | |
| updated_at | timestamp | |

### Fulfillment Status State Machine

```
pending → processing → shipped → delivered
                    ↘ failed
pending | processing → cancelled (order cancelled before shipping)
```

Fulfillments are created with `status = "pending"` inside `process_order` (after the order's reservations are converted), then all of the order's fulfillments move to `processing` as part of that same job step.

---

## Shipment

Tracking record for a Fulfillment. Created by the merchant when items are handed to the carrier.

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| fulfillment_id | uuid | |
| tracking_number | string | |
| carrier | string | e.g. "FedEx", "UPS" |
| carrier_tracking_url | string? | deep link to carrier's tracking page |
| status | enum | `created`, `picked_up`, `in_transit`, `out_for_delivery`, `delivered`, `failed` |
| events | ShipmentEvent[] | ordered history of tracking updates |
| shipped_at | timestamp | |
| estimated_delivery | timestamp? | |
| created_at | timestamp | |

## ShipmentEvent

| Field | Type | Notes |
|---|---|---|
| status | string | carrier-specific status label |
| description | string | human-readable update |
| location | string? | |
| occurred_at | timestamp | |

---

## Address

Embedded value object — not a standalone table. Used as the type of `Order.shipping_address` and anywhere else a point-in-time address snapshot is needed.

| Field | Type | Notes |
|---|---|---|
| name | string | recipient's full name — required for shipping labels |
| line1 | string | |
| line2 | string? | |
| city | string | |
| state | string | |
| postal_code | string | |
| country | string | ISO 3166-1 alpha-2 |

---

## UserAddress

A saved address in a user's address book. A user may have up to **10** saved addresses; exactly one may be flagged as default.

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| user_id | uuid | |
| label | string? | e.g. "Home", "Work" — user-supplied nickname |
| name | string | recipient's full name |
| line1 | string | |
| line2 | string? | |
| city | string | |
| state | string | |
| postal_code | string | |
| country | string | ISO 3166-1 alpha-2 |
| is_default | bool | at most one `true` per user; setting a new default clears the previous one |
| created_at | timestamp | |
| updated_at | timestamp | |

**Snapshot rule:** when used at checkout, all address fields are copied verbatim onto `Order.shipping_address`. Subsequent edits or deletion of the `UserAddress` record do not affect past orders.

---

## Notification

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| user_id | uuid | |
| type | enum | `order_update`, `merchant_product`, `merchant_account`, `logistics`, `promo`, `system`, `chat` |
| title | string | |
| body | string | |
| read | bool | |
| metadata | json | arbitrary payload (e.g. `{ order_id }`, `{ conversation_id }`) |
| created_at | timestamp | |

---

## Conversation

A chat thread between a customer and either the support team or a specific merchant.

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| type | enum | `support` — customer ↔ support agents; `merchant` — customer ↔ a specific merchant |
| customer_id | uuid | the User who opened the chat |
| merchant_id | uuid? | set only when `type = "merchant"`; references MerchantProfile |
| subject | string? | optional topic set by customer |
| status | enum | `open`, `pending`, `resolved`, `closed` |
| created_at | timestamp | |
| updated_at | timestamp | set on every new message |
| last_message_at | timestamp | for sorting conversation lists |

Unique constraint: `(customer_id, merchant_id)` where `type = "merchant"` — at most one open/pending thread per customer–merchant pair. Resolved or closed conversations do not block a new one from opening.

### Conversation Status State Machine

```
open → pending (automatic — a support agent or merchant replies; waiting on the customer)
pending → open (automatic — the customer replies)
open | pending → resolved → closed
open | pending → closed (ended without resolution)
```

`open` and `pending` are set automatically by reply activity. `resolved` and `closed` are set explicitly via `PATCH /conversations/:id/status` — they are the only values that endpoint accepts. Reopening is not supported; the customer starts a new conversation instead.

---

## Message

A single message within a Conversation.

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| conversation_id | uuid | |
| sender_id | uuid | references User |
| sender_role | enum | `customer`, `support`, `merchant`, `system` |
| body | string | max 4000 chars |
| attachments | Attachment[] | |
| read_by | uuid[] | user IDs who have read this message |
| created_at | timestamp | |
| edited_at | timestamp? | null if never edited |
| deleted_at | timestamp? | soft delete; body replaced with `[deleted]` |

## Attachment

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| url | string | |
| filename | string | |
| mime_type | string | |
| size_bytes | int | |

---

## SalesReport

One row per day, written by the `generate_daily_sales_report` scheduled job. Read via `GET /admin/sales-reports`.

| Field | Type | Notes |
|---|---|---|
| id | uuid | |
| date | date | unique — the calendar day the report covers (UTC) |
| total_revenue | int | cents |
| order_count | int | |
| average_order_value | int | cents |
| top_products | json | top 5 products by units sold: `[{ product_id, name, units_sold }]` |
| created_at | timestamp | |
