# HANDOFF — casehub-platform

**Last closed:** #830 (WS-3: Trust model for playbook authoring)
**Landed:** `6f54b38d` on main, published to origin
**Queue:** 16 items remaining

## This session

Designed and implemented a trust model for playbook authoring — ADR 0013. The existing `SchemaFilteredRegistry` + capability taxonomy was the right extension point; the gap was that dangerous steps (`process`, `rest-call`) shared the `"steps"` capability with safe plugins.

**Code (1 squashed commit):**
- 4 risk-bearing capability constants in `PlaybookCapabilities`: `PROCESS_EXECUTION`, `RAW_HTTP`, `EXPRESSION_MVEL`, `ENV_ACCESS`
- `PlaybookSchemas.ASSISTED` constant and new `assisted` built-in schema in `MapPlaybookSchemaRegistry` — includes all functional capabilities (orchestration, correlation, etc.) but excludes the four risk capabilities
- `server` and `client` schemas gain all four risk capabilities (preserving existing developer behaviour)
- `ProcessPlugin` reclassified: `capability = "process-execution"` (was `"steps"`)
- `RestCallPlugin` reclassified: `capability = "raw-http"` (was `"steps"`)
- Tests: `SchemaFilteredRegistryTest` (3 new tests for assisted filtering), `PlaybookSchemasTest` (2 new tests), `PluginScannerTest` (2 new tests), `PlaybookSchemaRegistryTest` (count fix for 3rd built-in schema)

**ADR:** 0013 — Trust model for playbook authoring

**Blog:** "The Catalogue Is the Security Surface" — why the step catalogue is a security boundary when LLMs author playbooks, and how the existing schema infrastructure already had the right filtering mechanism

**Issues updated:**
- #836 (WS-6b): commented with integration guidance — `SchemaFilteredRegistry.forSchema(registry, schemas, "assisted")`, expression engine gating, variable source gating, config property
- casehubio/casehub-pages#669: commented with TypeScript parity needed (4 constants, 1 schema, `isBuiltIn` update)

**Pre-existing items:** #833 and #835 were already closed before this session. Queue still shows them unchecked — they were landed in a prior session.

## Next in queue

Epic #827 continues. Next candidates:
- #834 (WS-5: Rules headers and lint for playbook tests, S/Med) — topic change from trust model work
- #836 (WS-6b: Validator MCP tool + shaped schemas + metric, L/High) — now unblocked by this session's trust model work, design-heavy

Standalone candidates: #838, #839, #840, #841, #842, #843, #765, #848, #849.
