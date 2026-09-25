# casehub-worker Spring Boot Deployment — Design

**Issue:** casehubio/casehub-worker#16
**Date:** 2026-09-25

## Context

casehub-worker is a foundation-tier repo providing automated task primitives
(Worker, WorkerFunction, Capability). It has 3 modules: `api/` (pure Java SPIs),
`runtime/` (Quarkus CDI beans), `testing/` (test fixtures). ~110K Java.

The Spring Boot deployment campaign has completed 6 repos. casehub-worker is
the 7th. The pattern is established: extract CDI-coupled beans to
framework-neutral core POJOs, create Spring auto-configuration.

## Audit

### Extraction targets (runtime/)

| Bean | CDI | Framework Coupling |
|------|-----|-------------------|
| `DefaultWorkerExecutor` | `@ApplicationScoped`, `@Inject` | Mutiny Uni, SmallRye Guard, MP TimeoutException |
| `SchemaValidator` | `@ApplicationScoped` | None beyond annotation |

### Already framework-neutral

- `api/` — Worker, WorkerFunction, Capability, WorkerResult, WorkerOutcome, Exchange
- `TestWorkerBuilder` — pure Java utility

### Key challenge

`WorkerExecutor` interface returns `Uni<WorkerResult>` (Mutiny). The core logic
(capability validation, type checking, schema validation, sync function dispatch)
is blocking. The Uni wrapping and SmallRye Guard are Quarkus-specific layers.

## Architecture

### New modules

**`runtime-core/`** (`casehub-worker-runtime-core`)

Framework-neutral POJOs extracted from `runtime/`:

- `WorkerExecutorCore` — blocking interface:
  ```java
  public interface WorkerExecutorCore {
      WorkerResult execute(Worker worker, Capability capability, Object input);
  }
  ```

- `DefaultWorkerExecutorCore` — core logic POJO:
  - Constructor-injected `SchemaValidator`
  - Capability validation (name in worker's capability set)
  - Input type checking
  - Schema validation (input before execution, output after success)
  - Sync function dispatch via `WorkerFunction.Sync`
  - Error handling (exceptions → `WorkerResult.failed()`)
  - No Uni, no Guard, no OTel, no reactive

- `SchemaValidator` — moved from `runtime/`, `@ApplicationScoped` removed.
  Jackson ObjectMapper + networknt json-schema-validator. Thread-safe
  (ConcurrentHashMap cache).

- `MockWorkerExecutorCore` — test fixture implementing `WorkerExecutorCore`.
  Tracks execution count, last worker/capability. Usable from both Spring
  and Quarkus tests.

Dependencies: `casehub-worker-api`, Jackson, networknt json-schema-validator.
Zero CDI, zero Spring imports.

**`worker-spring/`** (`casehub-worker-spring`)

Hand-written `@AutoConfiguration` (spring-generator is overkill for 2 beans):

```java
@AutoConfiguration
public class WorkerAutoConfiguration {
    @Bean
    @ConditionalOnMissingBean
    public SchemaValidator schemaValidator() {
        return new SchemaValidator();
    }

    @Bean
    @ConditionalOnMissingBean
    public WorkerExecutorCore workerExecutorCore(SchemaValidator validator) {
        return new DefaultWorkerExecutorCore(validator);
    }
}
```

Spring META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
registers the auto-config class.

**`spring-integration-test/`** (`casehub-worker-spring-integration-test`)

`@SpringBootTest` verifying:
- Auto-config composes (both beans created)
- `WorkerExecutorCore` executes a sync worker correctly
- H2 in-memory (no JPA in worker, but follows the campaign pattern for
  composition verification)

### Modified modules

**`runtime/`** — modified:

- `DefaultWorkerExecutor` retains `@ApplicationScoped`, adds constructor
  injection of `DefaultWorkerExecutorCore`
- Delegates core logic to `DefaultWorkerExecutorCore`
- Adds Uni wrapping, SmallRye Guard (timeout/retry/backoff), OTel tracing
- New dependency on `runtime-core`

- `WorkerExecutor` interface stays here — it returns `Uni<WorkerResult>` and
  is the Quarkus-specific SPI. Spring consumers use `WorkerExecutorCore`.

**`testing/`** — modified:

- `MockWorkerExecutor` wraps `MockWorkerExecutorCore` for Uni-based interface
- New dependency on `runtime-core`

## Data Flow

```
Spring path:  Input → WorkerExecutorCore.execute() → validate → dispatch → WorkerResult
Quarkus path: Input → WorkerExecutor.execute() → Uni(WorkerExecutorCore.execute()) → Guard → OTel → Uni<WorkerResult>
```

## Testing Strategy

- `runtime-core/` unit tests: all existing `WorkerExecutorTest` cases that don't
  test Guard/timeout (majority). These already construct via `new`.
- `runtime/` tests: Guard, timeout, and OTel-specific tests stay here.
- `spring-integration-test/`: composition verification.
- `testing/` tests: existing MockWorkerExecutor tests updated to use core mock.

## Module Dependency Graph

```
api (pure Java)
 └── runtime-core (POJO, Jackson, networknt)
      ├── runtime (Quarkus CDI, Mutiny, SmallRye FT, OTel)
      │    └── testing (Quarkus test fixtures)
      ├── worker-spring (@AutoConfiguration)
      └── spring-integration-test (@SpringBootTest)
```

## What's Not Changing

- `api/` — already framework-neutral, no changes
- `WorkerExecutor` interface stays Uni-based in `runtime/`
- OTel tracing stays in Quarkus module only (Spring uses Micrometer bridge)
- SmallRye Guard stays in Quarkus module (Spring uses Spring Retry if needed)

## Consumer Guide Update

Add a Spring Boot section to `docs/guides/consumer-guide.md`:
- Maven dependency for `casehub-worker-spring`
- `WorkerExecutorCore` injection and usage
- Note on fault tolerance being a separate concern in Spring

## References

- casehub-worker runtime sources (DefaultWorkerExecutor, SchemaValidator)
- platform spring-generator pattern (platform/spring-generator)
- ledger Spring deployment spec (wsp-casehub-platform/specs/issue-213-spring-boot-deployment)
- casehubio/casehub-worker#16 issue body
