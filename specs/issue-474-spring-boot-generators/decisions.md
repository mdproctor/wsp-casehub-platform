## D1: Generator module structure

**Choice:** Separate plugins + generator-common
**Alternatives:**
- Unified multi-goal plugin — cleaner consumer pom (one plugin block) but requires migrating all 8 consumer repos from `casehub-platform-spring-generator` to a new artifact name, and bundles unrelated dependency trees
**Rationale:** Matches established convention (spring-generator, graphql-generator, callback-generator are already separate). Doesn't break existing consumers. generator-common eliminates duplication while keeping each plugin's dependency tree minimal.
**Trade-offs:** Consumer `-spring` modules need 2-4 plugin declarations instead of one. More modules in the platform repo (5 vs 2).
**Sources:** spring-generator/pom.xml (existing Maven plugin pattern), graphql-generator (existing APT pattern, confirms separate-module convention), platform-spring/pom.xml (consumer plugin usage)
**Exploration:** quick
**Status:** captured

## D2: Epic scope revision

**Choice:** 3 generators (rest, graphql, mcp) + Panache→JPA porting (45 files across work/qhorus/ledger) + spring-generator retrofit to generator-common. Security and persistence generators dropped.
**Alternatives:**
- All 5 generators as original epic — persistence-spring-generator would map Panache→Spring Data JPA, security-spring-generator would map @RolesAllowed→@PreAuthorize. Both produce minimal or no-op output given codebase reality.
- 3 generators only, defer Panache porting — Spring deployment blocked until porting happens separately
**Rationale:** Codebase survey showed: (a) persistence already uses plain JPA in 86/131 files; remaining 45 Panache files are cheaper to port than to generate adapters for; (b) @RolesAllowed has 0 occurrences in consumer repos — security is already Jakarta-standard. Porting Panache is included because Spring can't run with Panache API calls in the classpath.
**Trade-offs:** Panache porting touches 45 files across 3 repos (work: 21, qhorus: 22, ledger: 2) — refactoring work, not generation. Increases epic scope in one dimension while reducing it in another.
**Sources:** Consumer repo survey (JAX-RS: 97 files, Panache: 45 files, @RolesAllowed: 0 in consumers), garden entries GE-20260420-7d28fa and GE-0138 (Panache SPI conflicts)
**Exploration:** deep-analysis
**Depends on:** D1 (module structure determines where generators live)
**Status:** captured

## D3: Source generation library

**Choice:** JavaPoet (Square)
**Alternatives:**
- JavaParser — full AST read-write capability, more verbose for pure generation (~2MB). Parsing capability unused since verify goal already uses Jandex.
- StringBuilder (status quo) — zero dependencies but manual import management, error-prone for complex output with nested generics and annotations
**Rationale:** JavaPoet is purpose-built for Java source generation. Automatic import management prevents the most common class of generator bugs. Type-safe API (TypeName, ClassName) catches errors at compile time. ~50KB lightweight dependency.
**Trade-offs:** Write-only — cannot parse existing Java source. If verify goal ever needs source-level analysis (beyond Jandex), would need a second library. No round-trip capability.
**Sources:** spring-generator AutoConfigurationWriter.java (StringBuilder pain points: manual import tracking, string concatenation for generics), GE-20260909-8fb2e4 (Jandex loses generic type params — JavaPoet's TypeName handles this correctly)
**Exploration:** quick
**Depends on:** D1 (generator-common houses the shared JavaPoet infrastructure)
**Status:** captured
