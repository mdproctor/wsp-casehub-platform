## D1: Generator module structure

**Choice:** Separate plugins + generator-common (Maven plugin execution model)
**Alternatives:**
- Unified multi-goal plugin — cleaner consumer pom (one plugin block) but requires migrating all 8 consumer repos from `casehub-platform-spring-generator` to a new artifact name, and bundles unrelated dependency trees
**Rationale:** Matches established convention (spring-generator, graphql-generator, callback-generator are already separate). Doesn't break existing consumers. generator-common eliminates duplication while keeping each plugin's dependency tree minimal. All new generators are Maven plugins — they generate Spring code from Quarkus Jandex indexes at build time. generator-common targets this execution model (filesystem-based Jandex loading via `target/classes/META-INF/jandex.idx`, File I/O output). The existing APT generators (graphql-generator, callback-generator) use a different execution model (AbstractProcessor, classpath-based Jandex loading, Filer output) and are not in scope for generator-common.
**Trade-offs:** Consumer `-spring` modules need 2-4 plugin declarations instead of one. More modules in the platform repo (5 vs 2). The platform has two generator execution models (Maven plugin for Spring generators, APT for Quarkus generators) — these serve different purposes and their shared surface (utility methods like `typeToJava`, `capitalize`) doesn't justify a common abstraction across execution models.
**Sources:** spring-generator/SpringGeneratorMojo.java (Maven plugin: AbstractMojo, Jandex from filesystem, FileWriter output), graphql-generator/GraphQLResolverProcessor.java (APT: AbstractProcessor, classpath Jandex, Filer output), platform-spring/pom.xml (consumer plugin usage)
**Exploration:** quick
**Status:** revised — clarified Maven plugin execution model for generator-common; APT generators excluded from scope

## D2: Epic scope revision

**Choice:** 3 generators (rest, graphql, mcp) + Panache→JPA porting (45 files across work/qhorus/ledger) + spring-generator retrofit to generator-common. Security and persistence generators dropped.
**Alternatives:**
- All 5 generators as original epic — persistence-spring-generator would map Panache→Spring Data JPA, security-spring-generator would map @RolesAllowed→@PreAuthorize. Both produce minimal or no-op output given codebase reality.
- 3 generators only, defer Panache porting — Spring deployment blocked until porting happens separately
**Rationale:** Codebase survey showed: (a) persistence already uses plain JPA in 86/131 files; remaining 45 Panache files are cheaper to port than to generate adapters for; (b) @RolesAllowed has 0 occurrences in consumer repos — security is already Jakarta-standard. Porting Panache is included because Spring can't run with Panache API calls in the classpath.
**Trade-offs:** Panache porting touches 45 files across 3 repos (work: 21, qhorus: 22, ledger: 2) — refactoring work, not generation. Increases epic scope in one dimension while reducing it in another.
**Dependency note:** Spring deployment also requires Spring Data JPA modules for the platform's own 11 Panache entity files (acl-jpa: 3, notification-settings-jpa: 3, platform-view-jpa: 2, persistence-jpa: 1, memory-jpa: 1, digest-jpa: 1). These "stay as-is" per core extraction spec D2, with parallel Spring Data JPA modules tracked as separate issues in the core extraction epic — not in this generators epic. The epic is complete when generators + consumer Panache porting are done; Spring deployment readiness additionally requires the core extraction epic's Spring Data JPA work.
**Sources:** Consumer repo survey (JAX-RS: 97 files, Panache: 45 files, @RolesAllowed: 0 in consumers), garden entries GE-20260420-7d28fa and GE-0138 (Panache SPI conflicts), core extraction spec D2 (JPA entities stay in persistence modules)
**Exploration:** deep-analysis
**Depends on:** D1 (module structure determines where generators live)
**Status:** revised — added dependency note for platform JPA modules requiring Spring Data JPA equivalents (tracked in core extraction epic)

## D3: Source generation library

**Choice:** JavaPoet (Palantir fork: `com.palantir.javapoet`)
**Alternatives:**
- JavaPoet (Square: `com.squareup:javapoet:1.13.0`) — stable and feature-complete final release, but archived (no ongoing maintenance)
- JavaParser — full AST read-write capability, more verbose for pure generation (~2MB). Parsing capability unused since verify goal already uses Jandex.
- JBoss Forge Roaster (`org.jboss.forge.roaster`) — read-write Java source manipulation, in the Quarkus ecosystem. Parsing capability unused; larger footprint than JavaPoet for write-only generation.
- StringBuilder (status quo) — zero dependencies but manual import management, error-prone for complex output with nested generics and annotations
**Rationale:** JavaPoet is purpose-built for Java source generation. Automatic import management prevents the most common class of generator bugs. Type-safe API (TypeName, ClassName) catches errors at compile time. ~50KB lightweight dependency. The Palantir fork (`com.palantir.javapoet`) is actively maintained; Square's original was archived after the stable 1.13.0 release.
**Scope of adoption:** generator-common and all new generators (rest-spring, graphql-spring, mcp-spring) use JavaPoet. The spring-generator retrofit (D6) migrates to JavaPoet. Existing APT generators (graphql-generator, callback-generator) continue using StringBuilder — they are not in scope for generator-common (D1) and work correctly today.
**Trade-offs:** Write-only — cannot parse existing Java source. Two code generation styles coexist in the platform (JavaPoet in Maven plugin generators, StringBuilder in APT generators). If source-level analysis is ever needed beyond Jandex, a second library would be required — but the verify goal's Jandex-based drift detection has no such need.
**Sources:** spring-generator AutoConfigurationWriter.java (StringBuilder pain points: manual import tracking, string concatenation for generics), GE-20260909-8fb2e4 (Jandex loses generic type params — JavaPoet's TypeName handles this correctly)
**Exploration:** quick
**Depends on:** D1 (generator-common houses the shared JavaPoet infrastructure)
**Status:** revised — specified Palantir fork artifact; added Roaster as considered alternative; clarified scope of adoption (new generators + retrofit only, not APT generators)

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

## D5: MCP generator scope

**Choice:** mcp-spring-generator handles @Tool annotations only (from `io.quarkiverse.mcp.server`), producing Spring MCP SDK tool registrations. @McpDomain MCP tool registration is runtime infrastructure in the Spring MCP module ("C" category per core extraction D3), not compile-time generation. @McpDomain REST and GraphQL generation is handled by the graphql-spring-generator (D8).
**Alternatives:**
- Single generator for both @Tool and @McpDomain — bundles two unrelated input sources (Quarkus MCP Server annotations vs platform SPI interfaces) with different versioning cadences. @McpDomain processing duplicates what the graphql-spring-generator already handles for REST/GraphQL, and what runtime scanning handles for MCP tools.
- No generator for @Tool, hand-port 11 files — reduces generator complexity but loses automation for a mechanical translation.
- @McpDomain compile-time generation — produces Spring @Configuration that registers MCP tools. Unnecessarily complex when the Quarkus equivalent (GraphQLModelScanner + DynamicToolRegistrar) is runtime scanning and @McpDomain is a platform-api annotation available on both classpaths.
**Rationale:** @Tool (from `io.quarkiverse.mcp.server`) is a Quarkus-specific annotation not available on the Spring classpath, so compile-time generation is necessary — the generator reads the Jandex index to produce Spring MCP SDK equivalents. @McpDomain is a platform-api annotation available on both classpaths. In Quarkus, @McpDomain→MCP tools happens at runtime via GraphQLModelScanner + DynamicToolRegistrar. The Spring equivalent is a Spring bean performing the same runtime scanning — this belongs in the Spring MCP module (framework-specific with shared utility, "C" category in core extraction D3).
**Trade-offs:** The mcp-spring-generator scope is narrower (@Tool only, ~11 files). @McpDomain MCP registration requires a runtime Spring equivalent of GraphQLModelScanner + DynamicToolRegistrar in the Spring MCP module.
**Sources:** mcp/GraphQLModelScanner.java (runtime @McpDomain scanning), mcp/DynamicToolRegistrar.java (runtime MCP tool registration), mcp/CaseHubMcpTools.java (@Tool usage), core extraction spec D3 ("C" classification for mcp module)
**Exploration:** quick
**Depends on:** D1, D2, D8 (generation pipeline)
**Status:** revised — narrowed from @Tool+@McpDomain to @Tool only; @McpDomain MCP registration moved to runtime; @McpDomain REST/GraphQL generation moved to graphql-spring-generator (D8)

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
**Delegation convention:** The generator reads the core-extracted JAX-RS resource via Jandex to extract: (1) class-level and method-level JAX-RS annotations, (2) injected fields/constructor params (to identify the delegation target — the core POJO), and (3) method signatures. It generates delegation method bodies by convention: the Spring controller method calls the same-named method on the injected core POJO with matching parameters. Return values are wrapped in ResponseEntity based on the core POJO's return type (non-void → `ResponseEntity.ok(result)`; void → `ResponseEntity.noContent().build()`). The generator does not parse or analyze existing JAX-RS method bodies — it infers delegation targets from injected bean types and matches by method name + parameter types.
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
| Core POJO return type (non-void) | `ResponseEntity.ok(result)` — wrapping based on return type, not method body analysis |
| Core POJO return type (void) | `ResponseEntity.noContent().build()` |
| `ExceptionMapper<T>` | `@ControllerAdvice` + `@ExceptionHandler(T.class)` |
| `ContainerRequestFilter` (`@Priority` ≤ `AUTHENTICATION`) | Spring `Filter` with `@Order` |
| `ContainerRequestFilter` (`@Priority` > `AUTHENTICATION` or no `@Priority`) | `HandlerInterceptor.preHandle()` |
| `ContainerResponseFilter` | `ResponseBodyAdvice` (response body modification) |
| `ParamConverterProvider` | Spring `Converter<S,T>` + `@Configuration` registration |
| `@Inject` constructor | Constructor injection (Spring default) |
| `@Inject` field | Constructor injection (generator normalizes to constructor) |
**Alternatives:**
- Typed returns from Response.ok(entity) analysis — requires method body parsing. Not needed: the delegation model returns the core POJO's typed result directly, wrapped by the generated controller.
- @Provider out of scope — only 3 platform files, hand-port. Simpler generator but incomplete parity and doesn't account for consumer repos that may have additional @Provider classes.
**Rationale:** The delegation convention (same method name + parameter types on injected core POJO) enables fully mechanical generation without method body analysis. The graphql-generator already demonstrates this pattern (lines 307-341: inject SPI, call `fieldName.methodName(args)`, return result). The core extraction (#469) ensures JAX-RS resources follow this exact convention. The `@Priority`-based heuristic for `Filter` vs `HandlerInterceptor` handles the platform's 3 @Provider files correctly: WorkerCredentialFilter (`AUTHENTICATION - 10` → Filter with @Order), MissingTenancyExceptionMapper (ExceptionMapper → @ExceptionHandler), PathParamConverterProvider (ParamConverterProvider → Converter). @Provider generation provides complete REST parity so Spring deployment works without manual intervention.
**Trade-offs:** Generator must handle 3 @Provider patterns (ExceptionMapper, Filter/Interceptor, ParamConverter) in addition to @Path resources. `ContainerResponseFilter` → `ResponseBodyAdvice` is the least mechanical mapping — the verify goal flags unmatched response filters for manual review. @RunOnVirtualThread is documented as a config property rather than generated — consumer responsible for enabling virtual threads.
**Sources:** Platform REST survey (12 resource classes, 3 @Provider classes, JAX-RS patterns inventory), GE-20260612-4f9a47 (class-level @Consumes edge case), graphql-generator/GraphQLResolverProcessor.java lines 307-341 (existing delegation pattern)
**Exploration:** quick
**Depends on:** D4 (delegation model), D8 (generation pipeline)
**Status:** revised — clarified delegation convention (no method body analysis); specified @Priority-based heuristic for Filter vs HandlerInterceptor; replaced Response.ok mapping with return-type-based wrapping; split ContainerResponseFilter to ResponseBodyAdvice

## D8: Generation pipeline

**Choice:** Single-stage generation — each generator reads from its authoritative source (core POJOs or SPI interfaces via Jandex) and produces Spring output directly. No generator processes another generator's output.
**Pipeline:**
| Generator | Input (Jandex source) | Output |
|---|---|---|
| spring-generator (existing) | Quarkus CDI wiring (@Produces, @DefaultBean) | Spring @AutoConfiguration (@Bean, @ConditionalOnMissingBean) |
| rest-spring-generator (new) | Core-extracted JAX-RS resources (@Path, @GET, @POST) | Spring @RestController (@RequestMapping, @GetMapping) |
| graphql-spring-generator (new) | @McpDomain SPI interfaces (@PlatformQuery, @PlatformMutation) | Spring GraphQL resolvers (@Controller, @QueryMapping, @MutationMapping) + Spring REST controllers (@RestController, @GetMapping, @PostMapping) |
| mcp-spring-generator (new) | @Tool-annotated classes (io.quarkiverse.mcp.server.Tool) | Spring MCP SDK tool registrations |
**Alternatives:**
- Two-stage pipeline for @McpDomain — graphql-generator produces JAX-RS resources, rest-spring-generator translates those to Spring controllers. Processes generated intermediary artifacts, creating unnecessary indirection and coupling between generators.
- Extend the existing graphql-generator to produce Spring output — couples Quarkus APT processor with Spring code generation, mixing execution models and framework concerns in one module.
**Rationale:** The graphql-generator already generates BOTH GraphQL resolvers AND JAX-RS REST resources from @McpDomain interfaces (GraphQLResolverProcessor.java: `generateResolverSource()` lines 146-225, `generateRestResourceSource()` lines 227-305). The graphql-spring-generator mirrors this architecture: it reads @McpDomain SPI interfaces directly and produces Spring equivalents for both GraphQL and REST. This avoids a two-stage pipeline where the rest-spring-generator would process the graphql-generator's JAX-RS output. The rest-spring-generator handles only hand-written (core-extracted) JAX-RS resources. Each generator has a single, authoritative input source — no generator reads another generator's output.
**Trade-offs:** The graphql-spring-generator produces both GraphQL resolvers AND REST controllers, making it the largest of the new generators. But this mirrors the existing Quarkus architecture and keeps @McpDomain knowledge in one place.
**Sources:** graphql-generator/GraphQLResolverProcessor.java (produces both resolvers and REST resources from @McpDomain), core extraction spec D3 (mcp module is "C" category)
**Exploration:** implicit decision surfaced by reviewer
**Depends on:** D1 (module structure), D2 (epic scope)
**Status:** captured

## D9: Callback Spring support deferred

**Choice:** Callback Spring support is intentionally out of scope for this epic. The callback-generator produces CDI @Decorator beans — a pattern that maps to @Bean @Primary wrapping in Spring (core extraction D5). This is deferred to a separate issue.
**Alternatives:**
- Include callback-spring-generator in this epic — generates Spring @Configuration with @Bean @Primary methods that wrap delegate SPI beans with callback interception. Increases epic scope with the most complex CDI pattern mapping.
- Callback support not needed for Spring — if Spring deployments don't require callback functionality, no generator needed. Depends on deployment requirements.
**Rationale:** The callback mechanism (CDI decorators intercepting SPI calls via CallbackRegistry + CallbackInvoker) is architecturally significant but not blocking for initial Spring deployment. Spring can run without callback support — default SPI implementations work directly without decorator interception. The CDI @Decorator → @Bean @Primary mapping (core extraction D5) is the most complex CDI pattern mapping and warrants its own design attention rather than being bundled into this epic.
**Trade-offs:** Spring deployments run without callback interception until this is addressed. Consumer callbacks registered via CallbackRegistry will not fire in Spring deployments.
**Sources:** callback-generator/CallbackDecoratorProcessor.java (CDI @Decorator generation), core extraction spec D5 (@Decorator → @Bean @Primary mapping)
**Exploration:** implicit decision surfaced by reviewer
**Status:** captured
