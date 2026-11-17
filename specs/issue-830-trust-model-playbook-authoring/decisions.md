# Decisions — #830 Trust model for playbook authoring

## D1: Two authoring contexts, not three

**Choice:** Two tiers — `developer` (unrestricted) and `assisted` (LLM-generated, restricted catalogue). No tenant-admin tier.
**Alternatives:**
- Three tiers (developer / tenant-admin / LLM) — tenant-admin is a persona that doesn't exist in CaseHub yet; name it when it exists
- Single tier with per-step opt-in — no concept of authoring context; each step individually allowed/denied
**Rationale:** "Tenant-admin" is not a CaseHub term. Two tiers match the two real authoring contexts today. The architecture supports adding tiers later via schema inheritance.
**Trade-offs:** If a customer-facing authoring context emerges, we add a third tier then — but the design won't need restructuring.
**Sources:** Issue #830, playbook-direction.md (LD-9, TN-2), ConsentTier enum in platform-api
**Exploration:** quick
**Status:** captured

## D2: Unified tier scope

**Choice:** Steps, variable sources, expression engines, and egress all controlled by the same tier assignment. One knob per authoring context.
**Alternatives:**
- Steps + sources only — expression engines stay unfiltered (MVEL restriction deferred)
- Layered — separate orthogonal dimensions for steps, sources, and expressions. More granular but more complex to configure.
**Rationale:** MVEL has full Java interop (effectively code execution). Leaving it unfiltered contradicts the purpose of restricting `process`. One tier controls all risk surfaces.
**Trade-offs:** Less granularity — can't allow MVEL but block `process`. Acceptable because both are equivalent-risk.
**Sources:** PrimitiveVariableSource.java, VariableSource.java (env/systemProperty factories)
**Exploration:** quick
**Status:** captured

## D3: Caller context determines tier

**Choice:** The calling tool passes the authoring context. The validator MCP tool passes `assisted` automatically. CLI/IDE defaults to `developer`. No header in the playbook itself.
**Alternatives:**
- Playbook header (`trust: assisted`) — author declares intent, validation rejects violations
- Both — header declares intent, calling context enforces a ceiling
**Rationale:** The tier is a property of who is authoring, not of the playbook. An LLM should not be able to declare itself a developer. The calling tool knows the authoring context; the playbook doesn't need to.
**Trade-offs:** A developer cannot voluntarily restrict a playbook to the assisted catalogue for safety. Acceptable — they can use the validator tool directly if they want that check.
**Sources:** Issue #830 (WS-6b dependency), playbook-direction.md (LD-2, TN-2)
**Exploration:** quick
**Status:** captured

## D4: Extend capability taxonomy, not a separate trust registry

**Choice:** Introduce risk-bearing capability constants in `PlaybookCapabilities` and reclassify dangerous steps. Add `assisted` as a new built-in schema in `MapPlaybookSchemaRegistry` that excludes those capabilities. Use existing `SchemaFilteredRegistry` for filtering.
**Alternatives:**
- Separate `TrustTier` enum + `TrustFilteredRegistry` wrapping `PluginRegistry`, with `minimumTrust` on each `Definition` — duplicates filtering that SchemaFilteredRegistry already does, adds a second orthogonal filter dimension
**Rationale:** Zero new abstractions. The capability taxonomy is already the filtering mechanism — it just needs finer-grained constants for dangerous steps. `SchemaFilteredRegistry.forSchema(registry, schemas, "assisted")` is the entire WS-6b integration point.
**Trade-offs:** Capability constants are stringly-typed — a typo in a capability name silently excludes a step. Acceptable because all constants are in `PlaybookCapabilities` and the schema test suite catches mismatches.
**Sources:** SchemaFilteredRegistry.java, PlaybookCapabilities.java, MapPlaybookSchemaRegistry.java, PlaybookSchemaDescriptor.java
**Exploration:** quick
**Status:** captured

## D5: Assisted tier includes managed connectors

**Choice:** The `assisted` schema includes connector plugin capabilities. LLM-authored playbooks can use managed connectors (bank, voice, email, etc.) — not just structural steps.
**Alternatives:**
- Structural only — assisted playbooks limited to flow control, coordination, and data manipulation. Very restrictive but maximally safe.
**Rationale:** Connectors call managed SPIs with known inputs/outputs — no arbitrary network access. Restricting them to developer-only makes the LLM authoring surface too narrow to be useful. The useful boundary is "everything except raw code execution, raw HTTP, and raw env/system access."
**Trade-offs:** A connector plugin could have side effects (e.g. bank transfer). Mitigated by the existing confirmation/consent infrastructure (ConsentTier, WorkerAction) which is orthogonal to the trust model.
**Sources:** Definition.java (capability field), ~90 generated connector plugins in connectors repo
**Exploration:** quick
**Status:** captured
