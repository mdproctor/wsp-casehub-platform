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

## D4: REST generator delegation model

**Choice:** Generated @RestController methods delegate to core POJOs
**Alternatives:**
- Standalone replication — generated controllers contain full method signatures and delegate directly to injected SPIs/services. Doesn't depend on core extraction completeness but duplicates more logic.
**Rationale:** The core extraction (#469) moved business logic out of JAX-RS resources into framework-neutral POJOs. The generated Spring controllers should be thin wrappers — annotation mapping only, with method bodies that call through to the core.
**Trade-offs:** Depends on core extraction being complete for each consumer module. If a JAX-RS resource hasn't been core-extracted, the generator can't produce a working controller for it.
**Sources:** platform-spring/PlatformDefaultsManualConfig.java (demonstrates the existing pattern of Spring beans wrapping core POJOs)
**Exploration:** quick
**Depends on:** D1, D2
**Status:** captured

## D5: MCP generator scope — single generator for both patterns

**Choice:** Single mcp-spring-generator handles both @McpDomain+@PlatformQuery/@PlatformMutation (21 files) and @Tool from Quarkus MCP Server (11 files)
**Alternatives:**
- Separate generators — mcp-spring-generator for @McpDomain only, tool-spring-generator for @Tool. Cleaner separation but more moving parts.
- @McpDomain only, port @Tool manually — only 11 @Tool files in connectors, small enough to hand-port. Reduces generator complexity.
**Rationale:** Both produce the same output format (Spring MCP SDK tool registrations). The scanner has two modes but the writer is shared. One plugin is simpler for consumers than two.
**Trade-offs:** Single generator is slightly more complex internally (two scan paths). If @Tool scanning has issues, it could block @McpDomain generation.
**Sources:** connectors/mcp/ (8 @Tool files), consumer repo survey (@McpDomain: 21 files, @Tool: 11 files)
**Exploration:** quick
**Depends on:** D1, D2
**Status:** captured

## D6: Retrofit existing spring-generator

**Choice:** Refactor spring-generator to extend generator-common base classes
**Alternatives:**
- Leave spring-generator as-is — only new generators use generator-common. Some duplication with spring-generator but zero risk to existing builds.
**Rationale:** Validates the shared base against a working generator. Consistency across all 4 generators. One Jandex loading path, one verify framework. The retrofit also migrates spring-generator from StringBuilder to JavaPoet.
**Trade-offs:** Risk of introducing regressions in an already-working generator. Mitigated by existing tests and the verify goal's drift detection.
**Sources:** spring-generator/src/main/java/ (5 classes to retrofit), platform-spring/pom.xml (consumer that validates retrofit didn't break anything)
**Exploration:** quick
**Depends on:** D1, D3
**Status:** captured

## D7: REST mapping rules

**Choice:** Full REST parity — generate @RestController endpoints + @Provider equivalents, with ResponseEntity return types
**Mapping:**
| JAX-RS | Spring MVC |
|---|---|
| `@Path("/foo")` | `@RestController @RequestMapping("/foo")` |
| `@GET` / `@POST` / `@PUT` / `@DELETE` / `@PATCH` | `@GetMapping` / `@PostMapping` / `@PutMapping` / `@DeleteMapping` / `@PatchMapping` |
| `@PathParam` | `@PathVariable` |
| `@QueryParam` | `@RequestParam` |
| `@HeaderParam` | `@RequestHeader` |
| `@Consumes` / `@Produces` | `consumes` / `produces` attributes on mapping |
| `@RunOnVirtualThread` (class-level) | Config property `spring.threads.virtual.enabled=true` (documented, not generated) |
| `Response.ok(entity)` / `Response.noContent()` | `ResponseEntity.ok(entity)` / `ResponseEntity.noContent().build()` |
| `ExceptionMapper<T>` | `@ControllerAdvice` + `@ExceptionHandler(T.class)` |
| `ContainerRequestFilter` / `ContainerResponseFilter` | Spring `Filter` or `HandlerInterceptor` |
| `ParamConverterProvider` | Spring `Converter<S,T>` + `@Configuration` registration |
| `@Inject` constructor | Constructor injection (Spring default) |
| `@Inject` field | Constructor injection (generator normalizes to constructor) |
**Alternatives:**
- Typed returns where possible — infer entity type from Response.ok(entity) calls. More type-safe but requires method body analysis, not just annotation scanning.
- @Provider out of scope — only 3 files, hand-port. Simpler generator but incomplete parity.
**Rationale:** Mechanical 1:1 mapping keeps the generator simple — it translates annotations and method signatures without analyzing method bodies. The core POJO has the business logic; the controller is a thin delegation layer. @Provider generation provides complete REST parity so Spring deployment works without manual intervention.
**Trade-offs:** Generator must handle 3 @Provider patterns (ExceptionMapper, Filter, ParamConverter) in addition to @Path resources. @RunOnVirtualThread is documented as a config property rather than generated — consumer responsible for enabling virtual threads.
**Sources:** Platform REST survey (12 resource classes, 3 @Provider classes, JAX-RS patterns inventory), GE-20260612-4f9a47 (class-level @Consumes edge case)
**Exploration:** quick
**Depends on:** D4 (delegation model)
**Status:** captured
