# WebSocket API

## Connection

Connect at: `ws://host/ws?token=<jwt>`

The server authenticates on connect. If the token is missing or invalid, close the connection immediately with code `4001`. While connected, the server sends a `TOKEN_EXPIRED` event 60 seconds before the JWT expires; when it actually expires, the server closes with `4001`. The client should refresh the token and reconnect.

A single WebSocket connection handles all real-time features: order updates, notifications, cart sync, and chat.

---

## Message Envelope

All messages in both directions use this JSON envelope:

```json
{ "type": "EVENT_TYPE", "payload": {} }
```

### Payload schemas (canonical)

Event payloads are part of the canonical contract, not prose. Each event's `payload` is a **JSON Schema** under `specs/schemas/` (emitted from the TypeSpec source — see [contract.md](contract.md)), reusing the same entity schemas as the REST API (`NOTIFICATION_CREATED` carries the same `Notification` as `GET /notifications`). The tables below are the human reference; the schemas are authoritative.

Protocol topology — which `type` flows which direction and which payload schema it carries — is the registry [`specs/contract/ws-events.yaml`](contract/ws-events.yaml). Compliance:

- **Backends** validate emitted payloads against `specs/schemas/` (e.g. ajv / python-jsonschema) — see [test-suite.md](test-suite.md) §OpenAPI.
- **Frontends** generate WS payload types from `specs/schemas/` — see [frontend.md](frontend.md#api-type-compliance).

---

## Server → Client Events

### General

| Type | Payload | Trigger |
|---|---|---|
| `ORDER_STATUS_CHANGED` | `{ order_id, status, updated_at }` | Order status transitions (tracking numbers arrive via `SHIPMENT_STATUS_CHANGED` per fulfillment) |
| `NOTIFICATION_CREATED` | `{ ...Notification }` | New notification for the authenticated user |
| `CART_UPDATED` | `{ cart_id, item_count }` | Cart changed from another session |
| `INVENTORY_LOW` | `{ product_id, stock_quantity }` | Admin only; stock drops below threshold (10 units) |
| `TOKEN_EXPIRED` | `{}` | JWT is about to expire (sent 60s before expiry) |
| `SHIPMENT_STATUS_CHANGED` | `{ shipment_id, fulfillment_id, order_id, status, event: { ...ShipmentEvent } }` | New tracking event for a shipment in the user's order |
| `FULFILLMENT_STATUS_CHANGED` | `{ fulfillment_id, order_id, merchant_id, status }` | Fulfillment transitions (e.g. `processing → shipped`) — sent to the customer and the owning merchant |
| `PING` | `{ timestamp }` | Keepalive; sent every 30s |

### Chat

| Type | Payload | Trigger |
|---|---|---|
| `CHAT_MESSAGE_CREATED` | `{ ...Message, conversation_id }` | New message in a conversation the user is a participant of |
| `CHAT_MESSAGE_EDITED` | `{ message_id, conversation_id, body, edited_at }` | Message edited |
| `CHAT_MESSAGE_DELETED` | `{ message_id, conversation_id, deleted_at }` | Message soft-deleted |
| `CHAT_TYPING_START` | `{ conversation_id, user_id, user_name }` | User started typing |
| `CHAT_TYPING_STOP` | `{ conversation_id, user_id }` | User stopped typing (or 5s timeout) |
| `CHAT_CONVERSATION_STATUS_CHANGED` | `{ conversation_id, status }` | Conversation opened, resolved, or closed |
| `CHAT_READ_RECEIPT` | `{ conversation_id, message_id, user_id, read_at }` | A participant marked messages as read |
| `PRESENCE_CHANGED` | `{ user_id, status }` | User comes online or goes offline (support/admin/merchant only) |

---

## Client → Server Events

### General

| Type | Payload | Description |
|---|---|---|
| `PONG` | `{ timestamp }` | Reply to `PING` keepalive |
| `MARK_NOTIFICATION_READ` | `{ notification_id }` | Alternative to REST `POST /notifications/:id/read` |

### Chat

| Type | Payload | Description |
|---|---|---|
| `CHAT_TYPING_START` | `{ conversation_id }` | Broadcast typing indicator to other participants |
| `CHAT_TYPING_STOP` | `{ conversation_id }` | Cancel typing indicator |
| `CHAT_MARK_READ` | `{ conversation_id, message_id }` | Mark all messages up to `message_id` as read |
| `CHAT_JOIN_CONVERSATION` | `{ conversation_id }` | Subscribe to real-time events for a conversation |
| `CHAT_LEAVE_CONVERSATION` | `{ conversation_id }` | Unsubscribe from a conversation's events |

---

## Rooms / Scoping

The server maintains logical rooms. On connect, the server automatically subscribes the user to:
- Their own user room (for notifications, cart sync, order updates)
- All conversations they participate in (for support/admin users: all `support` conversations)

Clients should send `CHAT_JOIN_CONVERSATION` only when navigating to a conversation that may have been created since the connection was established.

---

## Typing Indicator Behavior

- Client sends `CHAT_TYPING_START` when the user begins entering text.
- Client sends `CHAT_TYPING_STOP` when the field clears or focus is lost.
- Server automatically emits `CHAT_TYPING_STOP` to all participants if it has not received a `CHAT_TYPING_STOP` or a message from that user within **5 seconds**.
- Multiple users may be typing simultaneously; clients must track each `user_id` separately.

---

## Presence

- On connect: server sets the user's `online_status` to `online` and broadcasts `PRESENCE_CHANGED` to support/admin users and to any merchant who has an open or pending conversation with that customer.
- On disconnect: server sets `online_status` to `offline` after a **10-second grace period** (to handle brief reconnects) and broadcasts `PRESENCE_CHANGED` to the same audience.
- Clients may send `CHAT_TYPING_STOP` on disconnect to cancel any active typing indicators immediately.

---

## Error Handling

If the server cannot process a client-sent event, it responds with:

```json
{
  "type": "ERROR",
  "payload": {
    "original_type": "CHAT_TYPING_START",
    "code": "NOT_FOUND",
    "message": "Conversation not found"
  }
}
```

Clients must not retry on `FORBIDDEN` or `NOT_FOUND` errors.
