namespace Ecommerce;

// WebSocket events. One envelope, discriminated on `type`; payloads reuse the
// domain entities (Notification, etc.). The JSON Schema emitter renders these
// for WS codegen and runtime validation. Protocol topology (direction, channel)
// lives in ws-events.yaml.

/** Server -> client WebSocket message envelope (discriminated on `type`). */
@discriminator("type")
model WsServerEvent {
  type: string;
}

model WsNotificationCreated extends WsServerEvent {
  type: "NOTIFICATION_CREATED";
  payload: Notification;
}

model WsOrderStatusChanged extends WsServerEvent {
  type: "ORDER_STATUS_CHANGED";
  payload: {
    order_id: string;
    status: string;
    updated_at: utcDateTime;
  };
}
