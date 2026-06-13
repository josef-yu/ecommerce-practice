namespace Ecommerce;

// Shared envelopes — referenced by every endpoint.

enum ErrorCode {
  BAD_REQUEST,
  UNAUTHORIZED,
  FORBIDDEN,
  NOT_FOUND,
  VALIDATION_ERROR,
  CONFLICT,
  INTERNAL_ERROR,
}

/** Standard error envelope returned by every 4xx/5xx response. */
model ErrorEnvelope {
  error: {
    code: ErrorCode;
    message: string;
    details?: Record<unknown>;
  };
}

/** Pagination metadata attached to every list response. */
model PageMeta {
  page: int32;
  per_page: int32;
  total: int32;
  total_pages: int32;
}
