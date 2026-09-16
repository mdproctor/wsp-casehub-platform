## D1: Compile-time scope validation

**Choice:** APT emits a WARNING (not error) when a class-based @McpDomain lacks a visible CDI scope annotation. CDI injection failure remains the hard runtime gate.
**Alternatives:**
- Compile-time error — too strict; APT can't see inherited scopes, stereotypes, or extension-added scopes
- Runtime only — misses the easy cases where the annotation is simply forgotten
**Rationale:** Best-effort early feedback without false-positive build failures. Javadoc documents the APT's visibility limitation.
**Trade-offs:** Users with scope annotations added by CDI extensions will see a spurious warning.
**Sources:** GraphQLResolverProcessor.java (current APT), issue #341 scope requirement
**Exploration:** quick
**Status:** captured

## D2: Rename DomainScanResult fields

**Choice:** Rename `spiInterfaceFqcn`/`spiInterfaceSimple` to `sourceFqcn`/`sourceSimple`. Add `boolean isInterface` flag for downstream code that needs to distinguish.
**Alternatives:**
- Leave names, add parallel fields — duplicates data, confusing
**Rationale:** Accurate for both interfaces and classes. Spring generators use McpDomainJandexScanner directly, so the rename propagates cleanly through all consumers.
**Trade-offs:** Breaking change for any external code using DomainScanResult directly (none known outside casehub).
**Sources:** DomainScanResult.java, McpDomainJandexScanner.java, SpringGraphqlControllerWriter.java
**Exploration:** quick
**Status:** captured
