# Frontend Requirements

---

## API Type Compliance

**Every frontend MUST derive its API layer from the canonical contract — it MUST NOT hand-write request/response or event types.** The contract is the committed, backend-neutral artifact set described in [contract.md](contract.md): `specs/openapi.yaml` (REST) and `specs/schemas/*.json` (payloads, including WebSocket events). Because both the frontend and every backend answer to the same artifacts, they cannot silently drift.

### Requirements

1. **Generate, don't hand-write.**
   - REST types — generated from `specs/openapi.yaml` (e.g. `openapi-typescript`, `orval`).
   - WebSocket payload types — generated from `specs/schemas/*.json` (e.g. `json-schema-to-typescript`, `quicktype`). The `type → payload` mapping follows [`ws-events.yaml`](contract/ws-events.yaml).
2. **Generate from the committed artifacts, not a live backend.** The source is the canonical `specs/` files — deterministic and backend-independent. (A running backend serves the same `openapi.yaml`, but CI/codegen reads the committed file.)
3. **Commit the generated output**, so reviewers and CI see it.
4. **Expose a regeneration command** (e.g. an npm script).
5. **Use the generated types at the boundary.** Casting API payloads to `any`/`unknown` or re-declaring their shapes by hand to bypass the generated types is non-compliant.
6. **No drift.** The committed generated types must match the contract: regenerating produces no diff.

### Enforcement (the frontend's `lint` target)

The stack's `make lint` (see [orchestration.md](orchestration.md)) MUST fail if the frontend is not type-compliant. It must:

- **Type-check** the app (e.g. `tsc --noEmit`) against the generated types — a contract change that breaks a call site fails the build.
- **Drift-check** the generated types: regenerate from `specs/openapi.yaml` + `specs/schemas/` and assert no diff against the committed output (`git diff --exit-code`, or the generator's `--check` mode).

Because CI runs each frontend's `make lint`, this is enforced per-frontend automatically.

---

## Pages & Routing

| Route | Description | Auth |
|---|---|---|
| `/` | Homepage: featured products, category nav | Public |
| `/products` | Product listing with filters and search | Public |
| `/products/:id` | Product detail with add-to-cart | Public |
| `/cart` | Cart review and item management | Auth |
| `/checkout` | Shipping address + shipping method + payment | Auth |
| `/orders` | Order history | Auth |
| `/orders/:id` | Order detail with live status tracker | Auth |
| `/account` | Profile settings, password change, address book | Auth |
| `/support` | Customer's chat conversation list | Auth |
| `/support/:conversation_id` | Chat thread | Auth |
| `/merchant/apply` | Merchant application form | Customer |
| `/merchant` | Merchant dashboard: sales, revenue, product stats, new orders (data from `GET /merchants/me/stats`) | Merchant |
| `/merchant/products` | Manage own products (create, edit, submit, archive) | Merchant |
| `/merchant/products/new` | Create a new product | Merchant |
| `/merchant/products/:id/edit` | Edit a draft or rejected product | Merchant |
| `/merchant/orders` | Sales history for own products, fulfillment actions | Merchant |
| `/merchant/orders/:fulfillment_id` | Fulfillment detail — ship action form | Merchant |
| `/merchant/messages` | Merchant chat inbox — customer conversations | Merchant |
| `/merchant/messages/:conversation_id` | Merchant chat thread | Merchant |
| `/stores/:slug` | Public merchant storefront | Public |
| `/track/:shipment_id` | Public shipment tracking page | Public |
| `/admin` | Dashboard: revenue, order counts, low stock (data from `GET /admin/stats`) | Admin |
| `/admin/products` | All products including pending approval | Admin |
| `/admin/merchants` | Merchant application queue and account management | Admin |
| `/admin/orders` | Order management with status updates | Admin |
| `/admin/support` | Support inbox — all conversations | Support/Admin |
| `/admin/support/:conversation_id` | Chat thread + customer order sidebar | Support/Admin |

---

## Responsive Breakpoints

| Breakpoint | Width | Layout |
|---|---|---|
| Mobile | < 768px | Single column; bottom nav bar (Home, Search, Cart, Orders, Account) |
| Tablet | 768px – 1024px | Two-column product grid; side drawer nav |
| Desktop | > 1024px | Three-column product grid; top nav with mega-menu |

No horizontal scrolling allowed at any breakpoint.

---

## Real-time Features (WebSocket)

All real-time features use the shared WebSocket connection described in [websocket.md](websocket.md). The client must maintain a single connection per tab and reconnect with exponential backoff on disconnect.

### Order Status Tracker (`/orders/:id`)
- Displays a step-by-step progress bar: Placed → Paid → Preparing → Shipped → Delivered.
- Advances in real time via `ORDER_STATUS_CHANGED` without page reload.
- Tracking numbers are shown per fulfillment card (an order can have one shipment per merchant), not on the top-level tracker.

### Notification Bell (all pages)
- Badge counter increments on `NOTIFICATION_CREATED`.
- Clicking the bell loads notifications from the REST API (not WebSocket) to avoid inconsistency.
- Badge resets to 0 after `POST /notifications/read-all`.

### Cart Icon Sync (all pages)
- Item count in the header cart icon updates via `CART_UPDATED` when the cart changes in another tab or session.

### Product Detail Page (`/products/:id`)
- "Message Seller" button visible when the product's merchant is not the platform merchant.
- Clicking calls `POST /conversations` `{ type: "merchant", merchant_id: "..." }`. On `409`, navigate to the existing open conversation instead of creating a new one.

### Order Detail Page (`/orders/:id`)
- Fulfillments section shows each merchant's items as a card with its own status badge.
- Each card links to `/track/:shipment_id` once a shipment exists.
- `SHIPMENT_STATUS_CHANGED` and `FULFILLMENT_STATUS_CHANGED` update statuses in real time.

### Public Tracking Page (`/track/:shipment_id`)
- No auth required.
- Shows a timeline of ShipmentEvents (newest on top), current status, and estimated delivery.
- Polls every 5 minutes OR updates live if the customer is authenticated and connected via WebSocket.

### Chat Widget (all pages)
- Floating button in the bottom-right corner.
- Red badge shows total unread messages across all conversations (both `support` and `merchant` types) — initial value from `GET /conversations/unread-count`.
- Badge count updates via `CHAT_MESSAGE_CREATED` events.
- Opens a full-screen overlay on mobile; a slide-over panel on desktop.
- Conversations are grouped in the widget: "Support" and "Sellers."

### Support Inbox (`/admin/support`)
- New conversations appear at the top of the list in real time via `CHAT_MESSAGE_CREATED`.
- Unread count per conversation updates live.

### Merchant Chat Inbox (`/merchant/messages`)
- Lists only `merchant` conversations for the logged-in merchant's store.
- Sorted by `last_message_at` descending; unread conversations highlighted.
- Real-time: new messages bump conversation to top via `CHAT_MESSAGE_CREATED`.

### Chat Thread (`/support/:id`, `/admin/support/:id`, `/merchant/messages/:id`)
- New messages appear at the bottom instantly via `CHAT_MESSAGE_CREATED`.
- Typing indicators appear/disappear via `CHAT_TYPING_START` / `CHAT_TYPING_STOP`.
- Read receipts update live via `CHAT_READ_RECEIPT`.
- Conversation status banner updates via `CHAT_CONVERSATION_STATUS_CHANGED`.
- Merchant thread sidebar: shows the customer's recent orders containing the merchant's products.

---

## UX Requirements

### General
- Skeleton loaders on: product listing, order history, notification list, conversation list.
- Toast notifications for: errors, successful actions (add to cart, order placed, message sent).
- All forms show inline validation errors from the API's `details` field.
- 404 and 500 error pages with a link back to home.

### Login / Register Pages
- Both pages show a "Continue with Google" button above the email/password form, separated by a divider ("— or —").
- Clicking "Continue with Google" navigates to `GET /auth/oauth/google?redirect_uri=...`. Do not open a popup — use a full redirect.
- On return from OAuth, exchange the one-time code for tokens via `POST /auth/token-exchange`, store tokens, and redirect to the originally intended page.
- If `?error=oauth_denied` is present in the URL, show a toast: "Google sign-in was cancelled."

### Account Settings (`/account`)
- "Connected accounts" section lists linked OAuth providers with the provider email and a "Disconnect" button.
- "Connect Google" button appears for providers not yet linked; initiates the `link=true` OAuth flow.
- "Disconnect" is disabled (greyed out with a tooltip) when it is the user's only login method.
- "Set a password" section is shown only when `password_hash` is null (OAuth-only accounts), allowing the user to add a password via `POST /auth/set-password`.
- "Change password" section (current password + new password fields) is shown when a password exists, calling `POST /auth/change-password`. On success, show a toast noting other sessions were signed out.

### Cart
- Optimistic UI: cart count in the header updates immediately on add/remove; rolls back on API error.
- Quantity selector on cart page is a stepper (–/+) with a direct input fallback.

### Checkout (`/checkout`)
- **Address step:** shows saved addresses as a radio-button list; default address pre-selected. "Use a new address" option expands an inline form. Submitting a new address gives the option to save it to the address book before placing the order.
- On mobile, the address list collapses to a single-line summary with a "Change" link.
- **Shipping step:** loads `GET /cart/shipping-options` and shows one card per merchant group, each with a radio list of methods (name, carrier, cost, estimated delivery range from `min_days`–`max_days`). The cheapest method is pre-selected per group. Changing a selection updates the order total summary immediately. The chosen selections are sent as `shipping_selections` on `POST /orders`.
- **Payment step:** uses the provider's embeddable UI component (e.g. Stripe Elements). A visible note states the reservation window ("Your items are reserved for 30 minutes").
- Submit button shows a spinner and is disabled while the request is in flight.
- On payment failure, show the provider's error message inline — do not navigate away.

### Account — Address Book (`/account`)
- "Saved addresses" section lists all `UserAddress` records as cards.
- Each card shows label, address summary, and actions: Edit, Delete, "Set as default."
- Default address is visually flagged (e.g. a "Default" chip).
- "Add address" opens an inline form. Capped at 10 addresses — show an error message and hide the button when the limit is reached.
- Deleting the default address shows a confirmation dialog noting no new default will be set automatically.

### Chat
- Multi-line input: Enter sends, Shift+Enter inserts a newline.
- Optimistic message rendering with a "sending" clock icon; replace on confirmation.
- Failed messages show a red "!" with a retry button; original draft stays in the input.
- File attachments show an inline preview (image thumbnail or filename+size for other types).
- Character counter appears at 3500 characters.
- Input is disabled with a notice when the conversation is `closed`.
- Infinite scroll: load older messages when scrolled to the top; preserve scroll position.
- Date separators between messages sent on different days.

### Merchant
- `/merchant/apply`: a single-page form (store name, slug, description). Submit button enqueues the application and redirects to a "pending review" holding page. The holding page listens via WebSocket for a `merchant_account` notification signalling approval.
- `/merchant/orders`: each row shows fulfillment status. Rows with `status = "processing"` have a "Ship items" CTA that navigates to the fulfillment detail page.
- `/merchant/orders/:fulfillment_id`: ship form — tracking number (required), carrier (required), tracking URL and estimated delivery (optional). Submitting calls `POST /orders/:id/fulfillments/:fid/ship`.
- `/merchant/messages`: merchant chat inbox. Badge in the merchant nav shows unread count.
- `/merchant/products`: table with columns for name, status (with colour-coded badge), price, stock, and actions. Status badge colours: `draft` = grey, `pending_approval` = yellow, `active` = green, `rejected` = red, `archived` = dark grey.
- Rejected products show an expandable rejection reason inline. A "Revise & resubmit" button navigates to the edit form; after saving, "Submit for review" sends the product back to `pending_approval` via `POST /products/:id/submit` (rejected products resubmit directly — no intermediate draft state).
- Product form has a "Save as draft" button and a separate "Submit for review" button. Submitting a draft transitions it to `pending_approval` via `POST /products/:id/submit`.
- `/merchant/orders` revenue table shows no customer PII — only order ID (truncated), date, product name, quantity, subtotal, and fulfillment status. Filterable by date range and product.
- Public storefront (`/stores/:slug`): merchant logo, description, and their `active` products in a grid. Matches the same responsive layout as `/products`.

### Admin (merchant management)
- `/admin/merchants`: tabbed list — Pending / Approved / Suspended. Each row shows store name, applicant email, applied date, and Approve / Reject buttons.
- Approve/Reject opens a confirmation dialog; Reject requires a `rejection_reason` field.
- `/admin/products` shows a "Pending Review" tab as default when there are products awaiting review. Each pending product row has Approve / Reject inline actions.
- Approving or rejecting a product shows a confirmation dialog; Reject requires a reason.

### Admin (general)
- Order status update is a dropdown on the order detail page; shows a confirmation dialog before submit.
- Low-stock products are highlighted (yellow) in the product list when `stock_quantity < 10`.
- `INVENTORY_LOW` WebSocket event shows an in-app alert banner linking to the product.
