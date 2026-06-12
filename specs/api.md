# REST API Contracts

Base path: `/api/v1`

All requests and responses use `Content-Type: application/json`. Authenticated endpoints require `Authorization: Bearer <token>`.

---

## Common Conventions

### Error Envelope

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Human-readable description",
    "details": {}
  }
}
```

| Code | HTTP Status |
|---|---|
| `BAD_REQUEST` | 400 |
| `UNAUTHORIZED` | 401 |
| `FORBIDDEN` | 403 |
| `NOT_FOUND` | 404 |
| `VALIDATION_ERROR` | 422 |
| `CONFLICT` | 409 |
| `INTERNAL_ERROR` | 500 |

### Pagination

All list endpoints accept `?page=1&per_page=20` and respond with:

```json
{
  "data": [],
  "meta": {
    "page": 1,
    "per_page": 20,
    "total": 100,
    "total_pages": 5
  }
}
```

---

## Auth

### `POST /auth/register`
**Body:**
```json
{ "email": "string", "password": "string", "full_name": "string" }
```
**Response 201:**
```json
{ "user": { ...User }, "token": "jwt_string", "refresh_token": "string" }
```
Side effect: enqueues `send_verification_email`.

### `POST /auth/login`
**Body:**
```json
{ "email": "string", "password": "string" }
```
**Response 200:**
```json
{ "user": { ...User }, "token": "jwt_string", "refresh_token": "string" }
```
**Errors:** `401` if credentials invalid. The response must not distinguish "user not found" from "wrong password".

### `POST /auth/logout`
Auth required. Invalidates current token server-side. **Response 204.**

### `GET /auth/me`
Auth required. **Response 200:** `{ "user": { ...User } }`

### `POST /auth/verify-email`
**Body:** `{ "token": "string" }`
**Response 200:** `{ "message": "Email verified" }`
**Errors:** `422` if token is invalid or expired.

### `POST /auth/refresh`
**Body:** `{ "refresh_token": "string" }`
**Response 200:** `{ "token": "jwt_string", "refresh_token": "string" }`

### `POST /auth/set-password`
Auth required. Allows an OAuth-only user (no `password_hash`) to add a password to their account.
**Body:** `{ "password": "string" }`
**Response 204.**
**Errors:** `409 CONFLICT` if the user already has a password set (use `POST /auth/change-password` instead).

### `POST /auth/change-password`
Auth required. Changes the password for an account that already has one.
**Body:** `{ "current_password": "string", "new_password": "string" }`
**Response 204.**
Side effect: invalidates all of the user's refresh tokens.
**Errors:** `401 UNAUTHORIZED` if `current_password` is wrong. `409 CONFLICT` if the user has no password yet (use `POST /auth/set-password`). `422` if `new_password` fails validation.

---

## OAuth / Social Login

OAuth uses the **Authorization Code flow with PKCE**. The server is the OAuth client — it holds the client secret and exchanges the authorization code server-side. The frontend never sees the provider's tokens.

Supported providers: `google`

### `GET /auth/oauth/:provider`
Initiates the OAuth flow. Generates a `state` token and PKCE `code_challenge`, stores them server-side (session or database, TTL 10 minutes), then redirects the browser to the provider's authorization URL.

Query params:
- `redirect_uri` (required): the frontend URL to return to after login (must match an allowlist).
- `link` (optional): if `"true"` and a valid Bearer token is present, the callback will link the provider to the existing account instead of logging in.

**Response:** `302 Redirect` to provider authorization URL.

### `GET /auth/oauth/:provider/callback`
Handles the provider's redirect after user consent.

Query params: `code`, `state` (from provider); `error` (if user denied).

**On success:**
1. Validate `state` matches the stored value. Reject with `400` if missing or mismatched.
2. Exchange `code` for provider tokens using the stored PKCE `code_verifier`.
3. Fetch the user's profile (email, name, avatar) from the provider.
4. **New user** (no account with that email): create a User (`email_verified = true`, `password_hash = null`) and a UserIdentity row. Enqueue no verification email.
5. **Existing user, same provider already linked**: update stored tokens, log the user in.
6. **Existing user, provider not yet linked** (matching by email): link the provider by creating a UserIdentity row, then log the user in.
7. **`link=true` flow**: skip login logic; attach the new UserIdentity to the authenticated user. Return `200` JSON instead of redirecting.

Redirect the browser to `{redirect_uri}?token={jwt}&refresh_token={refresh_token}` (tokens are short-lived one-time codes if passing via URL is undesirable — exchange immediately for real tokens via `POST /auth/token-exchange`).

**On denied/error:** Redirect to `{redirect_uri}?error=oauth_denied`.

**Response:** `302 Redirect` (or `200` JSON for the `link=true` flow).

### `POST /auth/token-exchange`
Exchanges a one-time OAuth callback code (from the redirect URL) for a real JWT + refresh token pair. Invalidated after first use or after 60 seconds.
**Body:** `{ "code": "string" }`
**Response 200:** `{ "user": { ...User }, "token": "jwt_string", "refresh_token": "string" }`

### `GET /auth/oauth/connections`
Auth required. Returns all OAuth providers linked to the current user.
**Response 200:**
```json
{
  "data": [
    {
      "provider": "google",
      "provider_email": "user@gmail.com",
      "created_at": "timestamp"
    }
  ]
}
```

### `DELETE /auth/oauth/:provider`
Auth required. Disconnects a provider from the current user's account.
**Response 204.**
**Errors:** `409 CONFLICT` if this is the user's only login method (no password and no other provider) — disconnecting would lock them out.

---

## Products

### `GET /products`
Public. Returns only `active` products to the public.
Query params: `?category=slug&search=string&min_price=int&max_price=int&sort=price_asc|price_desc|newest&merchant_id=uuid`

**Response 200:** paginated Product list. Each product includes a `merchant` object `{ id, store_name, store_slug }` (`merchant_id` is always set; platform products return the platform merchant).

### `GET /products/:id`
Public. **Response 200:** `{ "product": { ...Product } }`
**Errors:** `404` if not found or `archived`. Merchants can see their own non-active products; admins can see any.

### `POST /products` *(admin or approved merchant)*
Auth required, role `admin` or `merchant` (status `approved`).
**Body:**
```json
{
  "name": "string",
  "description": "string",
  "price": 1999,
  "stock_quantity": 50,
  "weight_grams": 400,
  "category_id": "uuid",
  "images": ["url1", "url2"]
}
```
**Response 201:** `{ "product": { ...Product } }`

Behavior by role:
- **Admin**: product is created with whatever `status` is supplied (default `draft`). `merchant_id` is automatically set to the platform MerchantProfile (`is_platform = true`). Platform products skip the approval flow and may be set directly to `active`.
- **Merchant**: product is created with `status = "draft"` and `merchant_id` set to the caller's MerchantProfile. `status` field in the request body is ignored.

### `POST /products/:id/submit` *(merchant)*
Auth required, role `merchant`. Submits a `draft` or `rejected` product for admin review.
**Response 200:** `{ "product": { ...Product } }` with `status = "pending_approval"`.
**Errors:** `403` if the product does not belong to this merchant. `409` if status is not `draft` or `rejected`.

### `PATCH /products/:id` *(admin or owning merchant)*
Auth required. Admin can update any product. Merchant can update only their own products and only when `status` is `draft` or `rejected` (not after submission).
All fields optional (partial update).
**Response 200:** `{ "product": { ...Product } }`
**Errors:** `403` if merchant tries to edit another merchant's product or a product not in an editable state.

### `PATCH /products/:id/review` *(admin)*
Auth required, role `admin`. Approves or rejects a `pending_approval` product.
**Body:** `{ "action": "approve" | "reject", "rejection_reason": "optional string" }`
**Response 200:** `{ "product": { ...Product } }`
Side effect: creates a `merchant_product` notification for the owning merchant.

### `DELETE /products/:id` *(admin or owning merchant)*
Auth required. Sets `status` to `archived`. Admin can archive any product; merchant can only archive their own, and only when `status` is `draft`, `rejected`, or `active`.
**Response 204.**
**Errors:** `409 CONFLICT` if a merchant tries to archive a `pending_approval` product.

---

## Merchants

### `POST /merchants/apply`
Auth required, role `customer`. Creates a MerchantProfile with `status = "pending"`. The caller's role stays `customer` until an admin approves the application.

If the caller has a previously **rejected** MerchantProfile, applying again updates that profile with the new values and resets it to `pending`.
**Body:**
```json
{
  "store_name": "string",
  "store_slug": "string",
  "description": "optional string"
}
```
**Response 201:** `{ "merchant": { ...MerchantProfile } }`
**Errors:** `409 CONFLICT` if the caller already has a MerchantProfile with status `pending`, `approved`, or `suspended`. `422` if `store_slug` is taken.
Side effect: creates a `merchant_account` notification for the applicant with title "Application received".

### `GET /merchants`
Public. Returns approved merchants only. Admins see all statuses. The platform merchant (`is_platform = true`) is never included.
Query: `?status=pending|approved|rejected|suspended`
**Response 200:** paginated MerchantProfile list.

### `GET /merchants/:id`
Public. Returns the merchant's profile if `status = "approved"`. Admins see any status.
**Response 200:** `{ "merchant": { ...MerchantProfile } }`
**Errors:** `404` if the merchant does not exist, is not `approved` (non-admin callers), or is the platform merchant.

### `GET /merchants/me`
Auth required. Returns the caller's own MerchantProfile regardless of status — accessible to any user who owns one (pending and rejected applicants included, since their role is still `customer`).
**Response 200:** `{ "merchant": { ...MerchantProfile } }`
**Errors:** `404` if the caller has no MerchantProfile.

### `PATCH /merchants/me`
Auth required. Updates the caller's own store profile (any user who owns a MerchantProfile). Cannot change `status`.
**Body:** `{ "store_name": "string", "description": "string", "logo_url": "string" }`
**Response 200:** `{ "merchant": { ...MerchantProfile } }`

### `PATCH /merchants/:id/status` *(admin)*
Auth required, role `admin`. Approves, rejects, or suspends a merchant.
**Body:** `{ "status": "approved" | "rejected" | "suspended", "rejection_reason": "optional string" }`
**Response 200:** `{ "merchant": { ...MerchantProfile } }`
Side effects:
- On `approved`: set user's role to `merchant`, create `merchant_account` notification "Your store is approved".
- On `rejected`: store `rejection_reason` on the profile, create `merchant_account` notification "Application not approved".
- On `suspended`: set all merchant's `active` products to `archived`, create `merchant_account` notification "Store suspended".

### `GET /merchants/me/orders`
Auth required, role `merchant`. Returns a paginated list of orders that contain at least one of the merchant's products. Customer PII is omitted — only `order_id`, `created_at`, line items for this merchant's products, and per-item revenue are returned.
**Response 200:** paginated list of merchant order summaries.

### `GET /merchants/me/stats`
Auth required, role `merchant`. Aggregates for the merchant dashboard.
Query: `?from=date&to=date` (default: the last 30 days).
**Response 200:**
```json
{
  "stats": {
    "revenue": 125000,
    "order_count": 42,
    "units_sold": 117,
    "top_products": [
      { "product_id": "uuid", "name": "string", "units_sold": 30 }
    ]
  }
}
```
Revenue counts the merchant's own line items in `paid`-or-later orders, excluding `cancelled` and `payment_failed`.

---

## Categories

### `GET /categories`
Public. Returns flat list; clients build tree from `parent_id`.
**Response 200:** `{ "data": [ ...Category ] }`

### `POST /categories` *(admin)*
**Body:** `{ "name": "string", "parent_id": "uuid|null" }`
**Response 201:** `{ "category": { ...Category } }`

### `PATCH /categories/:id` *(admin)*
**Body:** `{ "name": "string" }`
**Response 200:** `{ "category": { ...Category } }`

### `DELETE /categories/:id` *(admin)*
Only allowed if no products reference this category. **Response 204.**
**Errors:** `409 CONFLICT` if products exist in this category.

---

## Cart

### `GET /cart`
Auth required. Returns or creates the current user's cart.
**Response 200:** `{ "cart": { ...Cart } }`

### `POST /cart/items`
Auth required.
**Body:** `{ "product_id": "uuid", "quantity": 1 }`
**Response 200:** `{ "cart": { ...Cart } }`
**Errors:** `409 CONFLICT` if `quantity` exceeds `stock_quantity`. `404` if product not found or archived.

### `PATCH /cart/items/:product_id`
Auth required.
**Body:** `{ "quantity": 2 }`
**Response 200:** `{ "cart": { ...Cart } }`
Setting `quantity` to `0` removes the item.

### `DELETE /cart/items/:product_id`
Auth required. Removes item. **Response 200:** `{ "cart": { ...Cart } }`

### `DELETE /cart`
Auth required. Clears all items. **Response 204.**

### `GET /cart/shipping-options`
Auth required. Returns the cart's items grouped by merchant, with each group's available shipping methods and computed cost — powers the checkout shipping step.
**Response 200:**
```json
{
  "data": [
    {
      "merchant": { "id": "uuid", "store_name": "string" },
      "items": [ { "product_id": "uuid", "quantity": 2 } ],
      "options": [
        {
          "shipping_method_id": "uuid",
          "name": "Standard",
          "carrier": "FedEx",
          "cost": 599,
          "min_days": 3,
          "max_days": 7
        }
      ]
    }
  ]
}
```
Cost per method type: `flat` → `flat_rate_cents`; `free` → `0`; `weight_based` → `per_kg_cents × ceil(total group weight in kg)` using each product's `weight_grams`. If a merchant has no active methods, the platform merchant's methods are offered as the fallback; if no methods exist at all, a single `cost: 0` option is returned.
**Errors:** `409 CONFLICT` if the cart is empty.

---

## Addresses

### `GET /addresses`
Auth required. Returns the current user's saved addresses.
**Response 200:** `{ "data": [ ...UserAddress ] }`

### `POST /addresses`
Auth required.
**Body:**
```json
{
  "label": "Home",
  "name": "Jane Doe",
  "line1": "string",
  "line2": "string|null",
  "city": "string",
  "state": "string",
  "postal_code": "string",
  "country": "US",
  "is_default": true
}
```
**Response 201:** `{ "address": { ...UserAddress } }`
**Errors:** `409 CONFLICT` if the user already has 10 saved addresses.
If `is_default: true`, the previously-default address (if any) is automatically unset.

### `PATCH /addresses/:id`
Auth required. All fields optional (partial update).
**Response 200:** `{ "address": { ...UserAddress } }`
**Errors:** `404` if address does not belong to the caller.

### `DELETE /addresses/:id`
Auth required. **Response 204.**
**Errors:** `404` if address does not belong to the caller.
If the deleted address was the default, no other address is automatically promoted — the user has no default until they set one.

### `POST /addresses/:id/set-default`
Auth required. Sets this address as the user's default, clearing `is_default` on any previous default.
**Response 200:** `{ "address": { ...UserAddress } }`

---

## Orders

### `POST /orders`
Auth required. Creates an order from the current cart. Cart must have at least one item.

**Stock is reserved at checkout.** Within a single transaction, each line item's `product.stock_quantity` is atomically decremented and a `StockReservation` row (`held`, TTL **30 minutes**) is created. If any item has insufficient stock, the whole transaction rolls back and the request fails — this is what guarantees the last unit goes to exactly one buyer. If payment does not complete before the reservations expire, `release_expired_reservations` restores the stock and cancels the order.

Supply **either** a saved address ID **or** a one-time inline address — not both.

**Body (saved address):**
```json
{
  "address_id": "uuid",
  "shipping_selections": [
    { "merchant_id": "uuid", "shipping_method_id": "uuid" }
  ]
}
```

**Body (inline address):**
```json
{
  "shipping_address": {
    "name": "Jane Doe",
    "line1": "string",
    "line2": "string|null",
    "city": "string",
    "state": "string",
    "postal_code": "string",
    "country": "US"
  },
  "shipping_selections": [
    { "merchant_id": "uuid", "shipping_method_id": "uuid" }
  ]
}
```

The server copies the address fields into `Order.shipping_address` as an immutable snapshot regardless of which form is used.

`shipping_selections` is optional, with at most one entry per merchant group in the cart. For any group without an entry, the merchant's **cheapest active** shipping method is selected automatically (falling back to the platform merchant's methods, or cost `0` if none exist). The selections are snapshotted onto `Order.shipping_selections` with their computed costs; `subtotal`, `shipping_cost`, `tax`, and `total` are all computed here, so **the total is final before payment starts**.

**Response 201:**
```json
{ "order": { ...Order }, "payment_client_secret": "string" }
```
Order starts in `pending` status. `payment_client_secret` is returned to the client for use with the payment provider SDK.

**Errors:** `409 CONFLICT` if the cart is empty or any item has insufficient stock. `404` if `address_id` does not belong to the caller. `422` if neither `address_id` nor `shipping_address` is supplied, or if a `shipping_selections` entry references a method that is inactive or does not belong to that merchant.

### `GET /orders`
Auth required. Returns current user's orders (paginated). Admins see all orders.
**Response 200:** paginated Order list.

### `GET /orders/:id`
Auth required. Customers can only access their own orders; admins can access any.
**Response 200:** `{ "order": { ...Order } }`

### `POST /orders/:id/cancel`
Auth required. Allowed while `status` is `pending`, `paid`, or `preparing` **and** no fulfillment is `shipped` or `delivered`.

Effects:
- Stock is restored: `held` reservations are released; `converted` reservations are re-incremented onto `product.stock_quantity` and marked `released`.
- All of the order's fulfillments transition to `cancelled`.
- If the order was paid, a refund is initiated with the payment provider.
- Side effects: `order_update` notification and `send_order_status_email` (`cancelled`).

**Response 200:** `{ "order": { ...Order } }`
**Errors:** `409 CONFLICT` if the status or fulfillment state does not allow cancellation.

### `PATCH /orders/:id/status` *(admin)*
Auth required, role `admin`. Manual override — the same state-machine rules apply. Cancelling via this endpoint has the same stock/refund/fulfillment effects as `POST /orders/:id/cancel`.
**Body:** `{ "status": "preparing" | "shipped" | "delivered" | "cancelled" }`
**Response 200:** `{ "order": { ...Order } }`
**Errors:** `409 CONFLICT` if the transition is invalid per the state machine.

Note: tracking numbers live on `Shipment` records created by merchants via `POST /orders/:id/fulfillments/:fid/ship`. This endpoint manages the top-level order status only. `shipped` and `delivered` are normally set automatically when all fulfillments reach those states — this endpoint exists for manual correction and platform-merchant orders.

---

## Notifications

### `GET /notifications`
Auth required. Returns current user's notifications (paginated).
Query: `?unread_only=true`
**Response 200:** paginated Notification list.

### `GET /notifications/count`
Auth required. **Response 200:** `{ "unread": 4 }`

### `POST /notifications/:id/read`
Auth required. **Response 200:** `{ "notification": { ...Notification } }`

### `POST /notifications/read-all`
Auth required. Marks all as read. **Response 204.**

### `POST /notifications/broadcast` *(admin)*
Auth required, role `admin`. Sends a `promo` notification to all users or a subset. See [notifications.md](notifications.md) for the full contract.
**Body:** `{ "title": "string", "body": "string", "target": "all" | "customers", "metadata": {} }`
**Response 202.** Notification creation is handled asynchronously.

---

## Logistics

### Shipping Methods (merchant)

#### `GET /merchants/me/shipping-methods`
Auth required, role `merchant`. **Response 200:** `{ "data": [ ...ShippingMethod ] }`

#### `POST /merchants/me/shipping-methods`
Auth required, role `merchant`.
**Body:**
```json
{
  "name": "Standard Shipping",
  "carrier": "FedEx",
  "type": "flat",
  "flat_rate_cents": 599,
  "min_days": 3,
  "max_days": 7
}
```
**Response 201:** `{ "shipping_method": { ...ShippingMethod } }`
**Errors:** `422` if required fields for the chosen `type` are missing.

#### `PATCH /merchants/me/shipping-methods/:id`
Auth required, role `merchant`. **Response 200:** `{ "shipping_method": { ...ShippingMethod } }`

#### `DELETE /merchants/me/shipping-methods/:id`
Auth required, role `merchant`. Sets `is_active = false`. **Response 204.**
**Errors:** `409 CONFLICT` if this is the merchant's only active shipping method.

### Fulfillments

#### `GET /orders/:id/fulfillments`
Auth required. Customer sees their own order's fulfillments; merchant sees only their own; admin sees all.
**Response 200:** `{ "data": [ ...Fulfillment ] }`

#### `POST /orders/:id/fulfillments/:fid/ship`
Auth required, role `merchant` (must own the fulfillment) or `admin`.
Transitions fulfillment from `processing` to `shipped` and creates a Shipment record.
**Body:**
```json
{
  "tracking_number": "string",
  "carrier": "string",
  "carrier_tracking_url": "optional_string",
  "estimated_delivery": "optional_timestamp"
}
```
**Response 200:** `{ "fulfillment": { ...Fulfillment }, "shipment": { ...Shipment } }`
**Errors:** `409` if fulfillment is not in `processing` status.

Side effects:
- Creates a `logistics` notification for the customer ("Your items are on the way").
- Pushes `FULFILLMENT_STATUS_CHANGED` to the customer and the owning merchant.
- If **all** of the order's fulfillments are now `shipped` (or further along), transitions the Order to `shipped`, pushes `ORDER_STATUS_CHANGED`, and enqueues `send_order_status_email` with `new_status: "shipped"`.

### Shipments

#### `GET /shipments/:id`
Public. Returns shipment status and event history.
**Response 200:** `{ "shipment": { ...Shipment } }`

#### `POST /webhooks/shipment`
Unsigned requests rejected (verify HMAC). Carrier delivers tracking updates.
**Body:** `{ "tracking_number": "string", "status": "string", "event": { ...ShipmentEvent } }`
**Response 200:** `{ "received": true }`
Enqueues `sync_shipment_tracking` to update the Shipment record and notify the customer.

---

## Admin

### `GET /admin/stats`
Auth required, role `admin`. Platform-wide dashboard aggregates.
Query: `?from=date&to=date` (default: the last 30 days).
**Response 200:**
```json
{
  "stats": {
    "revenue": 1250000,
    "order_counts": { "pending": 2, "paid": 5, "preparing": 3, "shipped": 8, "delivered": 120, "cancelled": 4, "payment_failed": 1 },
    "low_stock_count": 3
  }
}
```
`low_stock_count` is the number of `active` products with `stock_quantity < 10`.

### `GET /admin/sales-reports`
Auth required, role `admin`. Paginated daily summaries persisted by `generate_daily_sales_report`, newest first.
**Response 200:** paginated SalesReport list.

---

## Chat

### `GET /conversations`
Auth required.
- Customers see their own conversations (both `support` and `merchant` types).
- Support/admin see all conversations of any type.
- Merchants see `merchant` conversations where they are the merchant party, plus any conversations they opened as a customer.

Each conversation in the response includes `unread_count` — the number of messages in it not yet read by the caller.

Query: `?type=support|merchant&status=open|pending|resolved|closed`
**Response 200:** paginated Conversation list.

### `GET /conversations/unread-count`
Auth required. Total unread messages for the caller across all their conversations — powers the chat widget badge.
**Response 200:** `{ "unread": 3 }`

### `POST /conversations`
Auth required. Opens a new conversation; **the caller becomes the conversation's customer party**, whatever their role — a merchant buying from another store opens conversations like any customer. A merchant may not open a conversation with their own store.
**Body:**
```json
{
  "type": "support",
  "subject": "optional_string",
  "initial_message": "string"
}
```
OR for a merchant conversation:
```json
{
  "type": "merchant",
  "merchant_id": "uuid",
  "subject": "optional_string",
  "initial_message": "string"
}
```
**Response 201:** `{ "conversation": { ...Conversation }, "message": { ...Message } }`
**Errors:** `409 CONFLICT` if an `open` or `pending` merchant conversation already exists between this customer and merchant (return the existing conversation in the error body). `422` if a merchant targets their own store's `merchant_id`.

### `GET /conversations/:id`
Auth required. Customers access their own only; merchants access their own merchant conversations; support/admin access any. **Response 200:** `{ "conversation": { ...Conversation } }`

### `GET /conversations/:id/messages`
Auth required. Paginated, newest-first by default.
Query: `?order=asc|desc` (default: `desc`)
**Response 200:** paginated Message list.

### `POST /conversations/:id/messages`
Auth required. Send a message in an existing conversation.
**Body:** `{ "body": "string", "attachment_ids": ["uuid"] }` — `attachment_ids` is optional (max 3), containing IDs returned by `POST /upload`.
**Response 201:** `{ "message": { ...Message } }`
Side effect: a reply from the support agent or merchant sets the conversation status to `pending`; a reply from the customer sets it back to `open`.
**Errors:** `409 CONFLICT` if conversation is `closed`. `422` if more than 3 attachments or an `attachment_id` is unknown or belongs to another user.

### `PATCH /conversations/:id/messages/:message_id`
Auth required. Sender may edit their own message within 5 minutes of creation; admins may edit any message at any time.
**Body:** `{ "body": "string" }`
**Response 200:** `{ "message": { ...Message } }`
**Errors:** `403 FORBIDDEN` if caller is neither the sender nor an admin, or the edit window has passed.

### `DELETE /conversations/:id/messages/:message_id`
Auth required. Sender or admin may soft-delete. Body becomes `[deleted]`.
**Response 200:** `{ "message": { ...Message } }`

### `PATCH /conversations/:id/status` *(support/admin/merchant)*
Auth required, role `support`, `admin`, or `merchant` (for their own merchant conversations).
**Body:** `{ "status": "resolved" | "closed" }` — the only values accepted here; `open` and `pending` are set automatically by reply activity.
**Response 200:** `{ "conversation": { ...Conversation } }`
**Errors:** `422` for any other status value.

### `POST /conversations/:id/messages/:message_id/read`
Auth required. Marks the given message (and all earlier ones) as read by the caller.
**Response 204.**

---

## Uploads

### `POST /upload`
Auth required. Issues a pre-signed upload URL for a chat attachment. See [chat.md](chat.md) for accepted MIME types and size limits.
**Body:** `{ "filename": "string", "mime_type": "string", "size_bytes": 12345 }`
**Response 200:**
```json
{
  "upload_url": "https://...",
  "attachment_id": "uuid",
  "expires_at": "timestamp"
}
```
**Errors:** `422` if file type or size is out of range.

---

## Webhooks

### `POST /webhooks/payment`
No auth header; verified by HMAC signature in `X-Signature` header.
Handles events: `payment_intent.succeeded`, `payment_intent.payment_failed`.
**Response 200:** `{ "received": true }`
Requests with invalid or missing signatures must receive `400`.
