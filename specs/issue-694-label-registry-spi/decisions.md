# Decisions — LabelRegistry SPI (#694)

## D1: Label tree as a platform SPI vs per-consumer local stores

**Choice:** Platform SPI in platform-api — `LabelRegistry` follows the same pattern as `DataSourceRegistry`, `EndpointRegistry`, `ModelRegistry`
**Alternatives:**
- Pages-local SQLite `LabelTreeStore` — simpler for Pages but duplicates the need across engine, work, and other consumers
- Entity-scanning approach — derive label tree from entities that carry labels. O(entities), can't report empty branches, not authoritative
**Rationale:** Multiple consumers need label tree enumeration (Pages, engine, work). A shared SPI avoids duplication and keeps the vocabulary authoritative.
**Trade-offs:** Platform must build and maintain the SPI + implementations before any consumer can use it
**Sources:** platform-api Path.java, LabelPatternMatcher.java, SubjectViewSpec.java, DataSourceRegistry.java, EndpointRegistry.java
**Exploration:** quick
**Status:** captured

## D2: Global vs tenant-scoped labels — PLATFORM_TENANT_ID sentinel

**Choice:** Use existing `TenancyConstants.PLATFORM_TENANT_ID` ("platform") sentinel for app-defined global labels, with tenant-first resolution on query
**Alternatives:**
- Nullable tenancyId for global entries — breaks the codebase convention where tenancyId is always non-null
- Separate global registry + tenant registry — unnecessary complexity when the sentinel pattern already exists
**Rationale:** EndpointRegistry and DataSourceRegistry already use PLATFORM_TENANT_ID with tenant-first, platform-global fallback. Established pattern, no new concepts.
**Trade-offs:** Sentinel values are less type-safe than a dedicated scope enum, but consistency with existing SPIs outweighs this
**Sources:** TenancyConstants.java, EndpointRegistry (resolve priority lookup), DataSourceRegistry (Javadoc documents platform-global visibility)
**Exploration:** deep-analysis
**Status:** captured

## D3: app_id excluded from the SPI

**Choice:** app_id does not appear in the LabelRegistry SPI. Labels are tenant-scoped or platform-global. App-level scoping is a consumer concern via path prefixes.
**Alternatives:**
- app_id as a first-class dimension — would silo labels per app within a tenant, preventing shared vocabulary
- app_id as optional filter — adds complexity to every query for a concern only Pages has
**Rationale:** From first principles: labels are a tenant's domain vocabulary, not an app's. Multiple apps in the same tenant share the same tree. SubjectViewSpec.scope already provides path-based scoping for consumers that need it.
**Trade-offs:** Pages must manage its own scoping logic rather than getting it from the SPI
**Sources:** SubjectViewSpec.java (scope field), first-principles analysis in conversation
**Exploration:** deep-analysis
**Status:** captured
