import "@typespec/http";
import "@typespec/openapi";
import "@typespec/json-schema";

// Contract modules — each reopens `namespace Ecommerce`.
import "./common.tsp";
import "./products.tsp";
import "./notifications.tsp";
import "./websocket.tsp";

using TypeSpec.Http;
using TypeSpec.OpenAPI;
using TypeSpec.JsonSchema;

/**
 * Canonical contract for the ecommerce platform — the single source of truth.
 *
 * `make contract` (tsp compile) emits:
 *   - OpenAPI 3.1  -> specs/openapi.yaml      (REST surface)
 *   - JSON Schema  -> specs/schemas/*.json     (shared payloads, reused by WS events)
 *
 * `@jsonSchema` on the namespace emits every model it contains (across all
 * module files) as a JSON Schema. Models are split by domain into the imported
 * *.tsp files; this file only wires them together and carries the service-level
 * decorators.
 *
 * NOTE: a representative slice (envelopes, products, notifications, two WS
 * events) that establishes the conventions. The full surface is modelled
 * incrementally alongside the build phases.
 */
@service(#{ title: "Ecommerce Platform API" })
@info(#{ version: "1.0.0" })
@jsonSchema
namespace Ecommerce;
