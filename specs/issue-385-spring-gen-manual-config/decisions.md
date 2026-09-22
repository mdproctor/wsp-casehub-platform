## D1: Manual config exclusion — scan consuming module's source

**Choice:** Add `sourceDir` parameter to `SpringGeneratorMojo`, scan for `@Bean` return types in hand-written source files, filter matching descriptors before passing to writer. Extract shared scan utility from `SpringVerifyMojo.collectBeanReturnTypes()`.
**Alternatives:**
- Mojo `<excludeTypes>` config list — requires manual maintenance per consumer, breaks on renames
- Marker annotation on `@Produces` methods — pollutes Quarkus code with Spring generation concerns
**Rationale:** Automatic, zero-config, follows existing pattern from `SpringVerifyMojo`
**Trade-offs:** Simple name matching (not FQN) — extremely unlikely to false-positive on two beans with same simple name but different packages
**Sources:** `SpringVerifyMojo.java:71-89` (existing `collectBeanReturnTypes` pattern), `SpringGeneratorMojo.java:32-69`
**Exploration:** quick
**Status:** captured

## D2: Generic wildcards — carry TypeName through ConstructorParam

**Choice:** Add `TypeName resolvedType` field to `ConstructorParam`. Use `JandexTypeConverter.toTypeName()` in scanner for all param kinds. Writer uses `resolvedType` for code generation instead of `toClassName(type)`.
**Alternatives:**
- Change `ConstructorParam.type` from String to TypeName — cleaner but more invasive, breaks simpleType() and all test construction sites
- Store full generic string and parse in writer — fragile string parsing
**Rationale:** Minimal disruption, leverages existing `JandexTypeConverter`, preserves `String type` for logging/simple-name use
**Trade-offs:** Slight redundancy between `type` (String) and `resolvedType` (TypeName) — acceptable for backward compat
**Sources:** `JandexTypeConverter.java:18-47` (full type conversion), `JandexProducerScanner.java:222-252` (resolveParamKind), `AutoConfigurationWriter.java:138-175` (buildEnhancedBeanMethod)
**Exploration:** quick
**Status:** captured

## D3: Optional wrapping — always emit Optional.ofNullable()

**Choice:** Remove the `hasFactoryMethod()` conditional in the OPTIONAL case. Always wrap with `Optional.ofNullable(provider.getIfAvailable())`.
**Alternatives:**
- None — the conditional was simply wrong
**Rationale:** `ParamKind.OPTIONAL` means the target takes `Optional<T>`. The wrapping is always needed.
**Trade-offs:** None
**Sources:** `AutoConfigurationWriter.java:148-154`
**Exploration:** quick
**Status:** captured
