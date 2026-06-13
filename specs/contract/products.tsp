using TypeSpec.Http;

namespace Ecommerce;

enum ProductStatus {
  draft,
  pending_approval,
  active,
  rejected,
  archived,
}

model Product {
  id: string;
  name: string;
  description: string;

  /** Cents. */
  price: int32;

  stock_quantity: int32;
  merchant_id: string;
  status: ProductStatus;
  created_at: utcDateTime;
}

@route("/api/v1/products")
namespace Products {
  /** Public. Active products only. */
  @get
  op list(@query page?: int32, @query per_page?: int32): {
    data: Product[];
    meta: PageMeta;
  };

  /** Public. */
  @get
  op read(@path id: string):
    | Product
    | {
        @statusCode statusCode: 404;
        @body error: ErrorEnvelope;
      };
}
