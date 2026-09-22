## D1: Branch scope — platform generator only

**Choice:** #387 only (generator change in platform). #388 and #389 become unblocked follow-ups done per consumer repo.
**Alternatives:**
- All three on one branch — cross-repo consumer changes increase scope and risk
**Rationale:** #388/#389 affect 5+ consumer repos. The generator change is self-contained in platform. Consumer repos can adopt the new naming incrementally after #387 lands.
**Trade-offs:** Consumer repos continue using `Generated` prefix until they update their APT config and delete old resources.
**Sources:** Issue #387, #388, #389 bodies
**Exploration:** quick
**Status:** captured

## D2: Output package strategy — derive with override

**Choice:** Default to SPI-derived package (replace `.api` segment with `.rest`/`.graphql`), allow `-ArestPackage`/`-AgraphqlPackage` APT compiler args to override.
**Alternatives:**
- Derive-only — zero config but no escape hatch for unusual package structures
- APT args only — explicit but requires config in every consumer pom.xml
**Rationale:** Derivation handles the common case (SPI in `.api` package) without any config. The override handles edge cases where the derivation doesn't produce the desired package.
**Trade-offs:** Two code paths (derivation + override) to maintain. Derivation rule must be documented so consumers know what to expect.
**Sources:** GraphQLResolverProcessor.java:694-703 (current hardcoded package), issue #387 body
**Exploration:** quick
**Status:** captured

## D3: Package derivation rule — replace .api segment

**Choice:** Replace the first `.api.` segment (or trailing `.api`) in the SPI package with `.rest`/`.graphql`. When no `.api` segment exists, append `.rest`/`.graphql`.
**Alternatives:**
- Strip `.api`, append domain after `.rest` — different package structure, non-standard
- Use SPI's own package — clutters SPI package with generated code
**Rationale:** Matches existing consumer package conventions: `io.casehub.chat.api` → `io.casehub.chat.rest`. Preserves domain sub-packages: `io.casehub.platform.api.acl` → `io.casehub.platform.rest.acl`.
**Trade-offs:** SPIs without `.api` in their package get a `.rest`/`.graphql` suffix appended, which may not match the consumer's preferred structure — use the APT override in that case.
**Sources:** Consumer repo package structures (chat-app, claudony, devtown)
**Exploration:** quick
**Depends on:** D2 (derivation is the default path of the derive-with-override strategy)
**Status:** captured

## D4: Spring generator consistency — include graphql-spring-generator

**Choice:** Apply the same SPI-derived package rule to graphql-spring-generator's output, dropping its hardcoded `io.casehub.platform.graphql.spring.generated` package.
**Alternatives:**
- Separate issue — different generator lifecycle, can be deferred
**Rationale:** Same pattern, small scope addition. Keeping `.generated.` packages in one generator while removing them from another creates inconsistency.
**Trade-offs:** Slightly larger PR scope. graphql-spring-generator is a Maven plugin (not APT), so the derivation logic needs to work in both contexts.
**Sources:** graphql-spring-generator output package analysis
**Exploration:** quick
**Depends on:** D3 (uses the same derivation rule)
**Status:** captured
