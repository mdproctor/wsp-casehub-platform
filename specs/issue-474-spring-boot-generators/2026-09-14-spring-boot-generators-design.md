# Spring Boot Code Generators — Design Spec

**Issue:** casehubio/parent#474
**Branch:** issue-474-spring-boot-generators
**Date:** 2026-09-14

## Goal

Build code generators that produce Spring integration layers from Quarkus source code. Quarkus is the single source of truth; Spring artifacts are generated, never hand-written. This epic completes the Spring Boot deployment story started by parent#469 (dual-framework core extraction).

## Revised Scope

The original epic specified 5 generators. Codebase validation reduced this to **3 generators + 1 porting task**:

| Component | Type | Files affected | Why |
|-----------|------|---------------|-----|
| **rest-spring-generator** | Maven plugin | 97 JAX-RS files across all repos | JAX-RS is framework-specific — no neutral equivalent |
| **graphql-spring-generator** | Maven plugin | 16 SmallRye GraphQL + 21 @McpDomain | SmallRye GraphQL → Spring GraphQL; produces both resolvers and REST controllers from @McpDomain |
| **mcp-spring-generator** | Maven plugin | 11 @Tool files (connectors) | Quarkus MCP Server @Tool → Spring MCP SDK |
| **Panache → plain JPA porting** | Refactoring | 45 files (work: 21, qhorus: 22, ledger: 2) | Panache APIs don't exist on Spring classpath |

**Dropped:**
- **persistence-spring-generator** — 86/131 persistence files already use plain JPA; remaining 45 are cheaper to port than generate adapters for
- **security-spring-generator** — `@RolesAllowed` has 0 occurrences in consumer repos; already Jakarta-standard

**Deferred:**
- **callback-spring-generator** — CDI `@Decorator` → `@Bean @Primary` is the most complex CDI pattern mapping; Spring runs without callback interception (default SPI implementations work directly)

**Dependency note:** Spring deployment also requires Spring Data JPA modules for the platform's 11 Panache entity files (acl-jpa, notification-settings-jpa, platform-view-jpa, persistence-jpa, memory-jpa, digest-jpa). These are tracked in the core extraction epic (parent#469), not this epic.

## Architecture

### Module Structure

```
platform/
├── generator-common/              ← shared: AbstractGeneratorMojo, AbstractVerifyMojo, JandexUtils
├── spring-generator/              ← retrofitted: @Produces → @AutoConfiguration
├── rest-spring-generator/         ← new: @Path → @RestController
├── graphql-spring-generator/      ← new: @McpDomain → @SchemaMapping + @RestController
└── mcp-spring-generator/          ← new: @Tool → Spring MCP SDK
```

All generators are Maven plugins (`maven-plugin` packaging) that read Jandex indexes from a sibling Quarkus module's `target/classes/META-INF/jandex.idx`. Each has dual goals: `generate` (produce source) and `verify` (drift detection).

The existing APT generators (graphql-generator, callback-generator) use a different execution model (`AbstractProcessor`, classpath-based Jandex) and are **not** in scope for generator-common.

### generator-common

Shared infrastructure extracted from the existing spring-generator and enhanced with JavaPoet:

| Class | Purpose |
|-------|---------|
| `AbstractGeneratorMojo` | `quarkusModule` parameter, Jandex index loading, output directory setup, `project.addCompileSourceRoot()` |
| `AbstractVerifyMojo` | Drift detection framework: scan Quarkus Jandex for source types, scan generated + hand-written sources for target types, fail on gaps |
| `JandexUtils` | Annotation scanning helpers, `valueWithDefault()` for defaulted attributes, type resolution |
| `JandexTypeConverter` | Jandex `Type` → JavaPoet `TypeName` conversion, handles parameterized types, arrays, wildcards |

**Dependency:** `com.palantir.javapoet` (actively maintained fork of Square's archived JavaPoet).

### Generation Pipeline

Single-stage — each generator reads from its authoritative source and produces Spring output directly. No generator processes another generator's output.

```
┌─────────────────────┐     ┌───────────────────────┐     ┌──────────────────────┐
│ Quarkus Module       │     │ Generator              │     │ -spring Module        │
│ (Jandex index)       │────▶│ (Scanner → Writer)     │────▶│ (generated sources)   │
│                      │     │                        │     │                       │
│ @Produces            │     │ spring-generator       │     │ @AutoConfiguration    │
│ @Path + @GET         │     │ rest-spring-generator  │     │ @RestController       │
│ @McpDomain           │     │ graphql-spring-gen     │     │ @QueryMapping + @REST │
│ @Tool                │     │ mcp-spring-generator   │     │ Spring MCP SDK        │
└─────────────────────┘     └───────────────────────┘     └──────────────────────┘
```

### Consumer Integration

Consumer repos add generator plugins to their `-spring` module's pom:

```xml
<plugin>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-rest-spring-generator</artifactId>
    <version>${platform.version}</version>
    <executions>
        <execution>
            <id>generate-rest</id>
            <goals><goal>generate</goal></goals>
            <configuration>
                <quarkusModule>${project.basedir}/../runtime</quarkusModule>
            </configuration>
        </execution>
        <execution>
            <id>verify-rest-drift</id>
            <goals><goal>verify</goal></goals>
            <phase>verify</phase>
            <configuration>
                <quarkusModule>${project.basedir}/../runtime</quarkusModule>
            </configuration>
        </execution>
    </executions>
</plugin>
```

## Generator Details

### rest-spring-generator

**Input:** Core-extracted JAX-RS resources (hand-written `@Path` classes) via Jandex.
**Output:** Spring MVC `@RestController` classes that delegate to core POJOs + `@Provider` equivalents.

**Scope:** Only hand-written JAX-RS resources. Resources generated by the graphql-generator (from `@McpDomain`) are handled by the graphql-spring-generator instead (D8).

**Delegation convention:** The generator reads the JAX-RS resource's Jandex entry to extract:
1. Class-level and method-level JAX-RS annotations
2. Injected fields/constructor params (identifies the delegation target — the core POJO)
3. Method signatures

Generated Spring controllers call the same-named method on the injected core POJO with matching parameters. Return values are wrapped in `ResponseEntity` based on the core POJO's return type:
- Non-void → `ResponseEntity.ok(result)`
- Void → `ResponseEntity.noContent().build()`

No method body analysis is performed.

**Annotation mapping:**

| JAX-RS | Spring MVC |
|--------|------------|
| `@Path("/foo")` | `@RestController @RequestMapping("/foo")` |
| `@GET` / `@POST` / `@PUT` / `@DELETE` / `@PATCH` | `@GetMapping` / `@PostMapping` / `@PutMapping` / `@DeleteMapping` / `@PatchMapping` |
| `@PathParam` | `@PathVariable` |
| `@QueryParam` | `@RequestParam` |
| `@HeaderParam` | `@RequestHeader` |
| `@Consumes` / `@Produces` | `consumes` / `produces` attributes |
| `@RunOnVirtualThread` | Documented config: `spring.threads.virtual.enabled=true` |
| `@Inject` field | Constructor injection (normalized) |

**@Provider mapping:**

| JAX-RS Provider | Spring Equivalent | Detection |
|----------------|-------------------|-----------|
| `ExceptionMapper<T>` | `@ControllerAdvice` + `@ExceptionHandler(T.class)` | Implements `ExceptionMapper` |
| `ContainerRequestFilter` (`@Priority` ≤ `AUTHENTICATION`) | Spring `Filter` with `@Order` | Security-tier filter |
| `ContainerRequestFilter` (`@Priority` > `AUTHENTICATION` or none) | `HandlerInterceptor.preHandle()` | Application-tier filter |
| `ContainerResponseFilter` | `ResponseBodyAdvice` | Response modification |
| `ParamConverterProvider` | `Converter<S,T>` + `@Configuration` | Type converter |

**Verify goal:** Every `@Path`-annotated class in the Quarkus Jandex must have a corresponding `@RestController` in generated + hand-written Spring sources. Unmatched `ContainerResponseFilter` → `ResponseBodyAdvice` mappings are flagged for manual review.

### graphql-spring-generator

**Input:** `@McpDomain` SPI interfaces with `@PlatformQuery` / `@PlatformMutation` methods via Jandex.
**Output:** Two file types per domain:
1. Spring GraphQL `@Controller` with `@QueryMapping` / `@MutationMapping` methods
2. Spring MVC `@RestController` with API endpoints (mirrors the existing graphql-generator's dual output)

This mirrors the existing graphql-generator architecture, which produces both `@GraphQLApi` resolvers and `@Path` REST resources from the same `@McpDomain` source.

**Annotation mapping (GraphQL):**

| Platform SPI | Spring GraphQL |
|-------------|----------------|
| `@McpDomain` interface | `@Controller` class |
| `@PlatformQuery` method | `@QueryMapping` method |
| `@PlatformMutation` method | `@MutationMapping` method |

**Annotation mapping (REST — same @McpDomain source):**

| Platform SPI | Spring MVC |
|-------------|------------|
| `@McpDomain` interface | `@RestController @RequestMapping("/api/{domain}")` |
| `@PlatformQuery` method | `@GetMapping("/{operation}")` |
| `@PlatformMutation` method | `@PostMapping("/{operation}")` |

Generated classes inject the `@McpDomain` SPI interface and delegate method calls — same delegation pattern as the existing graphql-generator.

**Verify goal:** Every `@McpDomain` interface with `@PlatformQuery` / `@PlatformMutation` methods must have corresponding Spring GraphQL and REST equivalents.

### mcp-spring-generator

**Input:** `@Tool`-annotated classes from `io.quarkiverse.mcp.server` via Jandex.
**Output:** Spring MCP SDK tool registration `@Configuration` classes.

**Scope:** `@Tool` annotations only (11 files, primarily in connectors). `@McpDomain` MCP tool registration is runtime infrastructure handled by a Spring equivalent of `GraphQLModelScanner` + `DynamicToolRegistrar` in the Spring MCP module — not compile-time generation.

**Mapping:**

| Quarkus MCP Server | Spring MCP SDK |
|-------------------|----------------|
| `@Tool` method | `@Tool` method (Spring AI MCP) or `ToolCallback` registration |
| `@ToolArg` parameter | `@ToolParam` or schema-based parameter |
| Tool description | Tool description annotation attribute |

**Verify goal:** Every `@Tool`-annotated method in the Quarkus Jandex must have a Spring MCP SDK equivalent.

## spring-generator Retrofit

The existing spring-generator is refactored to extend `generator-common`:

1. `SpringGeneratorMojo` extends `AbstractGeneratorMojo` (inherits Jandex loading, output dir setup)
2. `SpringVerifyMojo` extends `AbstractVerifyMojo` (inherits drift detection framework)
3. `AutoConfigurationWriter` migrates from `StringBuilder` to `JavaPoet`
4. `JandexProducerScanner` remains generator-specific (scans `@Produces`)
5. `ProducerDescriptor` remains generator-specific

The retrofit validates that generator-common works correctly against a known-good generator before the new generators are built.

## Panache → Plain JPA Porting

45 files across 3 consumer repos need porting from Panache APIs to plain `EntityManager` + JPQL:

| Repo | Files | Pattern |
|------|-------|---------|
| work | 21 | `PanacheRepository` / `PanacheEntityBase` → `EntityManager` + `@NamedQuery` |
| qhorus | 22 | Same pattern |
| ledger | 2 | Same pattern |

**Porting rules:**
- `PanacheRepository<E>` / `PanacheRepositoryBase<E, ID>` → inject `EntityManager`, use JPQL
- `entity.persist()` → `em.persist(entity)`
- `entity.find("field", value)` → `em.createQuery(...)` or `@NamedQuery`
- `PanacheEntityBase` superclass → remove; entity keeps `@Entity`
- `Panache.withTransaction(...)` → `@Transactional`

This is mechanical refactoring. The garden entries (GE-20260420-7d28fa, GE-0138) document why this codebase moved away from Panache — SPI interface conflicts and detached entity gotchas.

## Execution Order

1. **generator-common** — shared base (no external consumers until generators are built)
2. **spring-generator retrofit** — validates generator-common against a working generator
3. **rest-spring-generator** — highest value (97 JAX-RS files), most complex mapping rules
4. **graphql-spring-generator** — dual output (GraphQL + REST from @McpDomain)
5. **mcp-spring-generator** — narrowest scope (11 @Tool files)
6. **Panache porting** — independent of generators, can be parallelized

## Testing Strategy

Each generator is tested at two levels:

1. **Unit tests:** Scanner tests against sample Jandex indexes (built from test fixture classes). Writer tests asserting generated JavaPoet output matches expected source.
2. **Integration tests:** The verify goal runs against the platform's own modules. If a generator produces correct output for platform's own `-spring` module, it works for consumer repos too.

The existing spring-generator's test structure (Scanner unit tests + Writer string assertions) is the baseline. New generators follow the same pattern.

## References

- spring-generator/SpringGeneratorMojo.java — existing Maven plugin pattern (Scanner → Descriptor → Writer)
- graphql-generator/GraphQLResolverProcessor.java — @McpDomain scanning, dual output (resolver + REST), delegation pattern (lines 307-341)
- platform-spring/pom.xml — consumer plugin integration pattern
- platform-spring/PlatformDefaultsManualConfig.java — manual Spring config for beans generator can't handle
- GE-20260909-81809c — Jandex-based Spring auto-config generator technique
- GE-20260817-8b0648 — APT classloader isolation (validates Maven plugin over APT choice)
- GE-20260909-8fb2e4 — Jandex loses generic type params (JavaPoet TypeName handles this)
- GE-20260613-095ce5 — Jandex `value()` null for defaulted attributes (use `valueWithDefault()`)
- GE-20260817-bbfbf5 — Annotation TYPE must be indexed for Jandex scanning
- GE-20260416-f316e2 — Strip source-only annotations from generated output
- GE-20260420-7d28fa — Panache + plain @Entity runtime failure
- GE-0138 — Panache SPI return-type conflict
- Core extraction spec D2 — JPA entities stay in persistence modules
- Core extraction spec D3 — mcp module is "C" category (framework-specific with shared utility)
- Core extraction spec D5 — @Decorator → @Bean @Primary mapping (deferred)
