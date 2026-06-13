namespace Ecommerce;

enum NotificationType {
  order_update,
  merchant_product,
  merchant_account,
  logistics,
  promo,
  system,
  chat,
}

model Notification {
  id: string;
  user_id: string;
  type: NotificationType;
  title: string;
  body: string;
  read: boolean;
  metadata?: Record<unknown>;
  created_at: utcDateTime;
}
