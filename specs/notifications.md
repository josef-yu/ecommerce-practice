# Notification System

Notifications are delivered through two channels simultaneously:

1. **Persistent (database):** Always written. Retrieved via `GET /notifications`.
2. **Real-time (WebSocket):** Pushed to connected clients via `NOTIFICATION_CREATED`.

If the user is offline when a notification is created, the database record is the source of truth — it will be retrieved on next load.

---

## Notification Types

| Type | Used for |
|---|---|
| `order_update` | Order lifecycle events (customers) |
| `merchant_product` | Product review decisions (merchants) |
| `merchant_account` | Merchant application and account status (merchants) |
| `logistics` | Shipment and fulfillment tracking updates (customers and merchants) |
| `promo` | Admin-broadcast promotions |
| `system` | Platform-level announcements |
| `chat` | Missed chat messages |

---

## Event → Notification Mapping

| Event | Type | Title | Body |
|---|---|---|---|
| Order placed (confirmed) | `order_update` | "Order #{id} confirmed" | "Your order has been placed and payment received." |
| Payment failed | `order_update` | "Payment failed for order #{id}" | "We couldn't process your payment. Please try again." |
| Payment window expired (auto-cancelled) | `order_update` | "Order #{id} cancelled" | "Payment was not completed in time." |
| Order cancelled (customer or admin) | `order_update` | "Order #{id} cancelled" | "Your order has been cancelled. Any payment will be refunded." |
| Order shipped | `order_update` | "Your order has shipped" | "Order #{id} is on its way. Tracking: {tracking_number}" |
| Order delivered | `order_update` | "Order #{id} delivered" | "Your order has arrived. Enjoy!" |
| Missed chat message | `chat` | "New message from {sender_name}" | Truncated to 100 chars |
| Admin promo broadcast | `promo` | Custom | Custom |

All `order_update` notifications include `metadata: { "order_id": "uuid" }`.
All `chat` notifications include `metadata: { "conversation_id": "uuid" }`.
All `merchant_product` notifications include `metadata: { "product_id": "uuid" }`.
All `merchant_account` notifications include `metadata: { "merchant_id": "uuid" }`.
All `logistics` notifications include `metadata: { "shipment_id": "uuid", "order_id": "uuid" }`.

### Logistics Notifications

| Event | Recipient | Type | Title | Body |
|---|---|---|---|---|
| Fulfillment shipped | Customer | `logistics` | "Your items are on the way" | "{merchant_store_name} has shipped {n} item(s). Tracking: {tracking_number}" |
| Shipment picked up | Customer | `logistics` | "Carrier picked up your package" | "Estimated delivery: {estimated_delivery}" |
| Shipment in transit | Customer | `logistics` | "Your package is moving" | Current location if available |
| Shipment out for delivery | Customer | `logistics` | "Out for delivery today" | "Expect delivery today." |
| Shipment delivered | Customer | `logistics` | "Package delivered" | "Your order from {merchant_store_name} has arrived." |
| Shipment failed | Customer | `logistics` | "Delivery issue" | "There was a problem delivering your package. Check tracking for details." |
| Order placed (has their product) | Merchant | `merchant_product` | "You have a new order" | "{n} item(s) to fulfill." |

### Merchant Notifications

| Event | Type | Title | Body |
|---|---|---|---|
| Application submitted | `merchant_account` | "Application received" | "We'll review your store application within 2 business days." |
| Application approved | `merchant_account` | "Your store is approved" | "You can now list products on the platform." |
| Application rejected | `merchant_account` | "Application not approved" | Includes `rejection_reason` |
| Account suspended | `merchant_account` | "Store suspended" | Includes reason |
| Product approved | `merchant_product` | ""{name}" is now live" | "Your product has been approved and is visible to shoppers." |
| Product rejected | `merchant_product` | ""{name}" needs changes" | Includes `rejection_reason` |

---

## Admin Broadcast

Admins may send a `promo` notification to all users or a subset via:

### `POST /notifications/broadcast` *(admin)*
**Body:**
```json
{
  "title": "string",
  "body": "string",
  "target": "all" | "customers",
  "metadata": {}
}
```
**Response 202.** Notification creation is handled asynchronously.

---

## Frontend Behavior

- **Notification bell** in the header shows a badge with unread count.
- Badge count updates in real time via `NOTIFICATION_CREATED` WebSocket event.
- Clicking the bell opens a dropdown listing the 10 most recent notifications.
- Each notification links to its relevant resource (order page, conversation, etc.) using `metadata`.
- "Mark all as read" button at the top of the dropdown calls `POST /notifications/read-all`.
- On mobile, notifications are accessible from the bottom nav.
