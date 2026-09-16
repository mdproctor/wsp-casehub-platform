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

## D3: Scanner gate removal strategy

**Choice:** Remove the `isInterface` check in all four scanner locations. Method-level `@PlatformQuery`/`@PlatformMutation` annotation filtering naturally excludes non-annotated class methods — no additional filtering needed.
**Alternatives:**
- Add a separate class-scanning path alongside the interface path — duplicates logic, harder to maintain
**Rationale:** The annotation filter is already the real discriminator. The interface check was a redundant guard that can be lifted without introducing noise.
**Trade-offs:** None — backward compatible. Classes without `@PlatformQuery`/`@PlatformMutation` methods produce zero operations and are silently skipped.
**Sources:** McpDomainJandexScanner.java:42, GraphQLResolverProcessor.java:264,470
**Exploration:** quick
**Status:** captured

## D4: GraphQLModelScanner class-based domain handling

**Choice:** Modify the first pass: when `@McpDomain` is found on a bean class without `@GraphQLApi`, read `@PlatformQuery`/`@PlatformMutation` directly from the class methods. Remove the existing warning log for this case.
**Alternatives:**
- Add a third pass dedicated to class-based domains — unnecessary complexity, same data
- Merge into the second pass (interface scan) — wrong abstraction; the second pass iterates bean interfaces, not the bean class itself
**Rationale:** The first pass already handles `@McpDomain` on classes — it just currently requires `@GraphQLApi`. Relaxing that condition is the smallest change.
**Trade-offs:** The warning `"@McpDomain on %s without @GraphQLApi — skipping"` is removed. This was a diagnostic for misconfigured generated resolvers, but class-based domains make `@McpDomain` without `@GraphQLApi` a valid pattern.
**Depends on:** D3 (scanner gate removal — runtime scanner mirrors compile-time behaviour)
**Sources:** GraphQLModelScanner.java:56-86
**Exploration:** quick
**Status:** captured

## D5: Generated code injection pattern

**Choice:** No change to generated code shape. `@Inject SourceType fieldName;` works whether `SourceType` is an interface or a concrete class. CDI resolves both.
**Alternatives:**
- Differentiate injection by source kind (e.g., use `Instance<T>` for classes) — unnecessary; CDI handles both uniformly
**Rationale:** CDI injection of `@ApplicationScoped` classes is standard. The delegation pattern is identical.
**Trade-offs:** None.
**Sources:** GraphQLResolverProcessor.java:generateResolverSource, generateRestResourceSource
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

## D3: Scanner gate removal strategy

**Choice:** Remove the `isInterface` check in all four scanner locations. Method-level `@PlatformQuery`/`@PlatformMutation` annotation filtering naturally excludes non-annotated class methods — no additional filtering needed.
**Alternatives:**
- Add a separate class-scanning path alongside the interface path — duplicates logic, harder to maintain
**Rationale:** The annotation filter is already the real discriminator. The interface check was a redundant guard that can be lifted without introducing noise.
**Trade-offs:** None — backward compatible. Classes without `@PlatformQuery`/`@PlatformMutation` methods produce zero operations and are silently skipped.
**Sources:** McpDomainJandexScanner.java:42, GraphQLResolverProcessor.java:264,470
**Exploration:** quick
**Status:** captured

## D4: GraphQLModelScanner class-based domain handling

**Choice:** Modify the first pass: when `@McpDomain` is found on a bean class without `@GraphQLApi`, read `@PlatformQuery`/`@PlatformMutation` directly from the class methods. Remove the existing warning log for this case.
**Alternatives:**
- Add a third pass dedicated to class-based domains — unnecessary complexity, same data
- Merge into the second pass (interface scan) — wrong abstraction; the second pass iterates bean interfaces, not the bean class itself
**Rationale:** The first pass already handles `@McpDomain` on classes — it just currently requires `@GraphQLApi`. Relaxing that condition is the smallest change.
**Trade-offs:** The warning `"@McpDomain on %s without @GraphQLApi — skipping"` is removed. This was a diagnostic for misconfigured generated resolvers, but class-based domains make `@McpDomain` without `@GraphQLApi` a valid pattern.
**Depends on:** D3 (scanner gate removal — runtime scanner mirrors compile-time behaviour)
**Sources:** GraphQLModelScanner.java:56-86
**Exploration:** quick
**Status:** captured

## D5: Generated code injection pattern

**Choice:** No change to generated code shape. `@Inject SourceType fieldName;` works whether `SourceType` is an interface or a concrete class. CDI resolves both.
**Alternatives:**
- Differentiate injection by source kind (e.g., use `Instance<T>` for classes) — unnecessary; CDI handles both uniformly
**Rationale:** CDI injection of `@ApplicationScoped` classes is standard. The delegation pattern is identical.
**Trade-offs:** None.
**Sources:** GraphQLResolverProcessor.java:generateResolverSource, generateRestResourceSource
**Exploration:** quick
**Status:** captured
