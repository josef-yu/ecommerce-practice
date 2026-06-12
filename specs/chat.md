# Chat Feature

Real-time customer support chat between customers and support agents. Built on top of the shared WebSocket connection described in [websocket.md](websocket.md).

---

## Overview

Two conversation types share the same infrastructure:

- **Support** (`type = "support"`): customer ↔ any support agent or admin. Opened via the chat widget.
- **Merchant** (`type = "merchant"`): customer ↔ a specific merchant. Opened via the "Message Seller" button on a product or storefront page.

Messages are persisted (full history available via REST) and delivered in real time via WebSocket. Typing indicators and read receipts are WebSocket-only (not persisted). Only the relevant party (support team or the specific merchant) can participate in each thread type.

---

## Domain Model

See [domain-model.md](domain-model.md) for full field definitions.

- **Conversation** — the thread. Has a `type` (`support` | `merchant`) and an optional `merchant_id`.
- **Message** — a single message with optional attachments and soft-delete support. `sender_role` is one of `customer`, `support`, `merchant`, `system`.
- **Attachment** — a file uploaded within a message.

### Who can do what

Any authenticated user may open a conversation — the opener becomes the conversation's **customer party**, whatever their role (a merchant buying from another store chats like any customer). A merchant may not open a conversation with their own store. In the table below, "Customer" means the conversation's customer party.

| Action | Customer | Merchant | Support | Admin |
|---|---|---|---|---|
| Open a support conversation | yes | yes (as customer party) | — | — |
| Open a merchant conversation | yes | yes (not with own store) | — | — |
| Send a message (support conv.) | in own | — | in any open | in any |
| Send a message (merchant conv.) | in own | in own store's | — | in any |
| Edit a message | own, within 5 min | own, within 5 min | own, within 5 min | any |
| Delete a message | own | own | own | any |
| Change conversation status (support) | — | — | yes | yes |
| Change conversation status (merchant) | — | yes (own) | — | yes |
| View all support conversations | — | — | yes | yes |
| View all merchant conversations | own only | own store's only | — | yes |

---

## REST Endpoints

All chat endpoints are under `/api/v1/conversations`. See [api.md](api.md) for full request/response shapes.

| Method | Path | Description |
|---|---|---|
| `GET` | `/conversations` | List conversations (filtered by role; includes `unread_count`) |
| `GET` | `/conversations/unread-count` | Total unread messages for the caller (widget badge) |
| `POST` | `/conversations` | Open a new conversation (caller becomes the customer party) |
| `GET` | `/conversations/:id` | Get conversation detail |
| `GET` | `/conversations/:id/messages` | Paginated message history |
| `POST` | `/conversations/:id/messages` | Send a message |
| `PATCH` | `/conversations/:id/messages/:msg_id` | Edit a message |
| `DELETE` | `/conversations/:id/messages/:msg_id` | Soft-delete a message |
| `PATCH` | `/conversations/:id/status` | Change conversation status (support/admin) |
| `POST` | `/conversations/:id/messages/:msg_id/read` | Mark messages as read |

---

## WebSocket Events

See [websocket.md](websocket.md) for the full event list. Summary of chat-specific events:

**Server → Client:** `CHAT_MESSAGE_CREATED`, `CHAT_MESSAGE_EDITED`, `CHAT_MESSAGE_DELETED`, `CHAT_TYPING_START`, `CHAT_TYPING_STOP`, `CHAT_CONVERSATION_STATUS_CHANGED`, `CHAT_READ_RECEIPT`, `PRESENCE_CHANGED`

**Client → Server:** `CHAT_TYPING_START`, `CHAT_TYPING_STOP`, `CHAT_MARK_READ`, `CHAT_JOIN_CONVERSATION`, `CHAT_LEAVE_CONVERSATION`

---

## Merchant Chat Flow

1. Customer visits a product page or merchant storefront.
2. Customer clicks "Message Seller." The frontend calls `POST /conversations` with `{ type: "merchant", merchant_id: "..." }`.
   - If an `open` or `pending` conversation already exists with that merchant, the API returns `409` with the existing conversation in the error body. The frontend navigates directly to it instead of creating a duplicate.
3. The new conversation appears in:
   - The customer's `/support` list (filtered by `type=merchant`).
   - The merchant's `/merchant/messages` inbox.
4. Replies from the merchant have `sender_role = "merchant"`.
5. The merchant (or an admin) can resolve or close the conversation. The customer cannot change conversation status — they simply stop replying, or open a new conversation later.

---

## Background Jobs

### `send_missed_message_notification`

**Trigger:** New message created in a conversation where the other participant(s) have been offline for > 2 minutes.
**Input:** `{ message_id }`
**Actions:**
1. For each offline participant, create a `chat` notification.
2. Send an email: "You have a new message from [sender_name]" with a link to the conversation.

**Retry:** 3 times with exponential backoff.

---

## Notifications

When a new chat message arrives for an offline user:
- A `chat` type Notification is persisted.
- Title: `"New message from {sender_name}"`
- Body: truncated to 100 characters.
- `metadata`: `{ "conversation_id": "uuid" }`

---

## File Attachments

- Accepted MIME types: `image/jpeg`, `image/png`, `image/gif`, `image/webp`, `application/pdf`, `text/plain`
- Maximum file size: 10 MB per file, 3 files per message.
- Upload flow:
  1. Client requests a pre-signed upload URL via `POST /upload` (see [api.md](api.md) — Uploads).
  2. Client uploads directly to storage.
  3. Client passes the returned attachment IDs as `attachment_ids` when sending the message via `POST /conversations/:id/messages`.

---

## Frontend UX Requirements

### Chat Widget (all pages)
- Floating button in the bottom-right corner on all pages.
- Badge showing count of unread messages across all open conversations — initial value from `GET /conversations/unread-count`, updated live via `CHAT_MESSAGE_CREATED`.
- Clicking opens the chat panel as a slide-over or modal (does not navigate away).
- On mobile, the widget opens a full-screen chat view.

### Conversation List (support inbox)
- Sortable by `last_message_at` (default) or status.
- Shows unread count per conversation.
- Live-updates when new messages arrive via `CHAT_MESSAGE_CREATED`.
- Filter tabs: All / Open / Pending / Resolved.

### Message Thread
- Infinite scroll — load older messages as the user scrolls up.
- Messages are grouped by date.
- Sender name and avatar (initials fallback) shown on each message.
- Timestamps shown on hover (desktop) or below the message (mobile).
- Typing indicators appear at the bottom of the thread.
- Read receipts shown as small avatars beneath the last message a participant has read.
- Support agents see customer's order history in a sidebar panel.

### Message Input
- Multi-line text area (Shift+Enter for newline, Enter to send).
- File attachment button with drag-and-drop support.
- Character counter at 3500 characters (max 4000).
- Disabled with a warning when the conversation is `closed`.

### Sending Behavior
- Optimistic: message appears immediately with a "sending" indicator.
- On failure: show error toast and keep the draft in the input field.
- On success: swap optimistic message with server-confirmed message (preserve scroll position).
