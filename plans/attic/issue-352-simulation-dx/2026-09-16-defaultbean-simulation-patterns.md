# DefaultBean Simulation Patterns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #321 — DefaultBean simulation patterns
**Issue group:** #294 (simulation service epic)

**Goal:** Remove the abstract/default method distinction from the
simulation generator and create a platform-simulation-core module that
generates decorators for 11 platform-api SPIs.

**Architecture:** Enhance `SimulationDecoratorProcessor` to intercept
all interface methods (not just abstract ones), then add a new module
with a `META-INF/simulation-eligible.txt` listing 11 platform-api SPIs.
One integration test proves CDI ordering works for `@Decorator` wrapping
`@DefaultBean`. Guide update documents the available platform SPIs.

**Tech Stack:** Java 21, CDI (Quarkus), Jandex, Maven, JUnit 5, AssertJ

## Global Constraints

- `platform-api/` must remain zero-dependency — no simulation-api import
- Generated decorators use `@Priority(APPLICATION + 200)`
- No changes to NoOp implementations — decorators wrap, NoOps stay clean
- Simulation is config-driven: unconfigured methods passthrough

---

## Batch 1: Generator enhancement — intercept all methods

### Task 1: Remove abstract/default distinction from SimulationDecoratorProcessor

**Files:**
- Modify: `simulation-generator/src/main/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessor.java:159-166`
- Modify: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java:172-181`
- Test: `simulation-generator/src/test/java/io/casehub/platform/simulation/generator/SimulationDecoratorProcessorTest.java`

**Interfaces:**
- Consumes: `TestSpiWithDefaults` test interface (has 2 abstract + 2 default methods)
- Produces: all interface methods now get simulation logic (no behavioral change for unconfigured methods)

- [ ] **Step 1: Update the test to expect simulation logic on default methods**

The existing test `defaultMethodsDelegateWithoutSimulation` asserts that
default methods do NOT get simulation logic. Reverse this — default
methods should now get simulation logic.

```java
@Test
void allMethodsGetSimulationLogic() {
    final var processor = new SimulationDecoratorProcessor();
    final List<SimulationDecoratorProcessor.GeneratedSource> sources = processor.generateFromIndex(index);
    final String code = findSource(sources, "TestSpiWithDefaults");

    assertThat(code).contains("\"spi-with-defaults.queryAll\"");
    assertThat(code).contains("\"spi-with-defaults.count\"");
    assertThat(occurrences(code, "simulation.strategyFor")).isGreaterThanOrEqualTo(4);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl simulation-generator -Dtest=SimulationDecoratorProcessorTest#allMethodsGetSimulationLogic`
Expected: FAIL — default methods currently generate delegation, not simulation logic.

- [ ] **Step 3: Remove the abstract/default branch in generateDecoratorSource**

In `SimulationDecoratorProcessor.generateDecoratorSource()`, replace the
conditional at lines 159-166:

```java
// Before:
if (java.lang.reflect.Modifier.isAbstract(method.flags())) {
    generateSimulatedMethod(sb, method, spiName);
} else {
    generateDelegatingMethod(sb, method);
}

// After:
generateSimulatedMethod(sb, method, spiName);
```

- [ ] **Step 4: Remove the now-unused generateDelegatingMethod**

Delete the `generateDelegatingMethod` method (lines 232-258) from
`SimulationDecoratorProcessor` — it is no longer called.

- [ ] **Step 5: Remove the old test and rename the new one**

Delete the `abstractMethodsGetSimulationLogic` test (lines 161-169) —
redundant since all methods now get simulation logic. The new
`allMethodsGetSimulationLogic` test covers both abstract and default.

- [ ] **Step 6: Run all simulation-generator tests**

Run: `mvn --batch-mode test -pl simulation-generator`
Expected: all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add simulation-generator/
git commit -m "feat(#321): intercept all interface methods in SimulationDecoratorProcessor

Remove abstract/default distinction — all methods get simulation logic.
Config layer controls activation; unconfigured methods passthrough.

Refs #321

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Apply same change to RestClientSimulationProcessor

**Files:**
- Modify: `rest-client-simulation-generator/src/main/java/io/casehub/platform/simulation/restclient/generator/RestClientSimulationProcessor.java:146-153`
- Test: `rest-client-simulation-generator/src/test/java/.../RestClientSimulationProcessorTest.java`

**Interfaces:**
- Consumes: same pattern as Task 1
- Produces: REST client decorators intercept all methods

- [ ] **Step 1: Check if RestClientSimulationProcessorTest has a default method test**

Use `ide_file_structure` on the test file. If a test asserts default
methods delegate without simulation, update it like Task 1.

- [ ] **Step 2: Remove the abstract/default branch**

In `RestClientSimulationProcessor.generateDecoratorSource()`, replace
lines 146-153:

```java
// Before:
if (java.lang.reflect.Modifier.isAbstract(method.flags())) {
    generateSimulatedMethod(sb, method, spiName, classPath);
} else {
    generateDelegatingMethod(sb, method);
}

// After:
generateSimulatedMethod(sb, method, spiName, classPath);
```

- [ ] **Step 3: Remove the now-unused generateDelegatingMethod**

Delete the `generateDelegatingMethod` method (lines 248-274) from
`RestClientSimulationProcessor`.

- [ ] **Step 4: Run all rest-client-simulation-generator tests**

Run: `mvn --batch-mode test -pl rest-client-simulation-generator`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add rest-client-simulation-generator/
git commit -m "feat(#321): intercept all methods in RestClientSimulationProcessor

Consistent with SimulationDecoratorProcessor change.

Refs #321

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 2: platform-simulation-core module

### Task 3: Create platform-simulation-core module

**Files:**
- Create: `platform-simulation-core/pom.xml`
- Create: `platform-simulation-core/src/main/resources/META-INF/simulation-eligible.txt`
- Modify: `pom.xml` (parent — add `<module>`)

**Interfaces:**
- Consumes: `SimulationDecoratorProcessor` APT (from simulation-generator via annotationProcessorPaths)
- Produces: 11 generated `@Decorator` classes in `io.casehub.platform.simulation.generated`

- [ ] **Step 1: Create the listing file**

Create `platform-simulation-core/src/main/resources/META-INF/simulation-eligible.txt`:

```
io.casehub.platform.api.acl.AccessControlProvider=access-control-provider
io.casehub.platform.api.datasource.DataSourceRegistry=data-source-registry
io.casehub.platform.api.subscription.SubscriptionStore=subscription-store
io.casehub.platform.api.notification.NotificationStore=notification-store
io.casehub.platform.api.endpoints.EndpointRegistry=endpoint-registry
io.casehub.platform.api.expression.ExpressionEngineRegistry=expression-engine-registry
io.casehub.platform.api.signing.document.DocumentSigningService=document-signing-service
io.casehub.platform.api.credentials.CredentialResolver=credential-resolver
io.casehub.platform.api.model.ModelRegistry=model-registry
io.casehub.platform.api.preferences.PreferenceProvider=preference-provider
io.casehub.platform.api.identity.CurrentPrincipal=current-principal
```

- [ ] **Step 2: Create the pom.xml**

Model after `memory-simulation-core/pom.xml`. Key differences:
- artifactId: `casehub-platform-simulation-core-platform` (or
  `casehub-platform-platform-simulation-core` — follow module naming)
- Depends on `casehub-platform-api` instead of
  `casehub-neocortex-memory-api`
- annotationProcessorPaths: simulation-generator + simulation-api +
  platform-api (for Jandex index of SPI interfaces)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-platform-platform-simulation-core</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Platform Simulation Core</name>
    <description>Generated @Decorators for platform-api SPI simulation.
        Path A consumer — decorators generated by simulation-generator from
        META-INF/simulation-eligible.txt listing. Add to classpath to enable
        simulation/capture for platform SPIs (ACL, notifications, endpoints,
        etc.).</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-core</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>jakarta.enterprise</groupId>
            <artifactId>jakarta.enterprise.cdi-api</artifactId>
        </dependency>
        <dependency>
            <groupId>jakarta.interceptor</groupId>
            <artifactId>jakarta.interceptor-api</artifactId>
        </dependency>

        <!-- Test -->
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-inmem</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-simulation-config</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-testing</artifactId>
            <version>${project.version}</version>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit5</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <artifactId>maven-compiler-plugin</artifactId>
                <configuration>
                    <annotationProcessorPaths>
                        <path>
                            <groupId>io.casehub</groupId>
                            <artifactId>casehub-platform-simulation-generator</artifactId>
                            <version>${project.version}</version>
                        </path>
                        <path>
                            <groupId>io.casehub</groupId>
                            <artifactId>casehub-platform-simulation-api</artifactId>
                            <version>${project.version}</version>
                        </path>
                        <path>
                            <groupId>io.casehub</groupId>
                            <artifactId>casehub-platform-api</artifactId>
                            <version>${project.version}</version>
                        </path>
                    </annotationProcessorPaths>
                </configuration>
            </plugin>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>${jandex-maven-plugin.version}</version>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals><goal>jandex</goal></goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>

</project>
```

- [ ] **Step 3: Add module to parent pom.xml**

Add `<module>platform-simulation-core</module>` after
`<module>memory-simulation-core</module>` (line 22) in the parent
`pom.xml`.

- [ ] **Step 4: Create a placeholder source file for compilation**

The module needs at least a `package-info.java` for the APT to run:

Create `platform-simulation-core/src/main/java/io/casehub/platform/simulation/platform/package-info.java`:

```java
/**
 * Platform SPI simulation adapters — generated @Decorators for 11
 * platform-api SPIs. Decorators are generated at compile time by
 * SimulationDecoratorProcessor from META-INF/simulation-eligible.txt.
 */
package io.casehub.platform.simulation.platform;
```

- [ ] **Step 5: Compile to verify decorators are generated**

Run: `mvn --batch-mode compile -pl platform-simulation-core`
Expected: BUILD SUCCESS with NOTE messages:
`Simulation generator: generated io.casehub.platform.simulation.generated.SimulatedAccessControlProvider`
(and 10 more)

- [ ] **Step 6: Commit**

```bash
git add platform-simulation-core/ pom.xml
git commit -m "feat(#321): platform-simulation-core module — 11 platform-api SPI decorators

Listing file generates decorators for AccessControlProvider,
DataSourceRegistry, SubscriptionStore, NotificationStore,
EndpointRegistry, ExpressionEngineRegistry, DocumentSigningService,
CredentialResolver, ModelRegistry, PreferenceProvider, CurrentPrincipal.

Refs #321

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4: Integration test — decorator wraps @DefaultBean

**Files:**
- Create: `platform-simulation-core/src/test/java/io/casehub/platform/simulation/platform/PlatformSimulationCdiTest.java`
- Create: `platform-simulation-core/src/test/resources/application.properties`

**Interfaces:**
- Consumes: Generated `SimulatedAccessControlProvider` decorator,
  `NoOpAccessControlProvider` from platform, `SimulationRuntime`,
  `InMemorySimulationCorpus`
- Produces: proof that `@Decorator` wraps `@DefaultBean` correctly

- [ ] **Step 1: Create test application.properties**

Create `platform-simulation-core/src/test/resources/application.properties`:

```properties
# Enable simulation for AccessControlProvider.canAccess
casehub.simulation.access-control-provider.canAccess.strategy=sequential
```

- [ ] **Step 2: Write the integration test**

Create `PlatformSimulationCdiTest.java`:

```java
package io.casehub.platform.simulation.platform;

import io.casehub.platform.api.acl.AccessControlProvider;
import io.casehub.platform.api.acl.AclAction;
import io.casehub.platform.api.acl.ResourceId;
import io.casehub.platform.simulation.InvocationRecord;
import io.casehub.platform.simulation.SimulationCorpus;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

@QuarkusTest
class PlatformSimulationCdiTest {

    @Inject AccessControlProvider acp;
    @Inject SimulationCorpus<Object, Object> corpus;

    @BeforeEach
    void seedCorpus() {
        corpus.clear("access-control-provider.canAccess");
        corpus.seed("access-control-provider.canAccess", List.of(
                new InvocationRecord<>("default-tenant", null,
                        null, true, Instant.now())));
    }

    @Test
    void decoratorInterceptsDefaultBeanWithSimulatedResponse() {
        boolean result = acp.canAccess("actor-1",
                ResourceId.parse("case:case-1"), AclAction.READ);
        assertThat(result).isTrue();
    }

    @Test
    void unconfiguredMethodDelegatesToNoOp() {
        // grant is not configured for simulation — should delegate to NoOp
        // NoOp's default grant() is a no-op (void, no exception)
        acp.grant("actor-1", ResourceId.parse("case:case-1"), AclAction.WRITE);
        // If we reach here without exception, passthrough works
    }
}
```

- [ ] **Step 3: Run the integration test**

Run: `mvn --batch-mode test -pl platform-simulation-core`
Expected: both tests PASS — decorator intercepts the seeded response for
`canAccess`, and `grant` passes through to the NoOp.

If the test fails because of missing Quarkus beans or wiring issues,
debug the CDI resolution chain. The decorator should wrap the
`@DefaultBean` NoOp produced by `DefaultBeans.java`.

- [ ] **Step 4: Commit**

```bash
git add platform-simulation-core/
git commit -m "test(#321): integration test — decorator wraps @DefaultBean

Verifies CDI ordering: @Decorator(APPLICATION+200) intercepts NoOp for
configured methods, passes through for unconfigured methods.

Refs #321

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## Batch 3: Documentation

### Task 5: Add Platform SPIs section to simulation guide

**Files:**
- Modify: `docs/guides/simulation-guide.md`

**Interfaces:**
- Consumes: SPI listing from the spec
- Produces: user-facing documentation

- [ ] **Step 1: Read the current guide to find insertion point**

Read the end of `docs/guides/simulation-guide.md` to find the right
place for the new section. Insert after the last existing section,
before any references or appendix.

- [ ] **Step 2: Add the Platform SPIs section**

```markdown
---

## Platform SPIs

The `platform-simulation-core` module generates simulation decorators for
11 platform-api SPIs. Add it to your classpath to enable simulation and
capture for any of these SPIs.

### Dependency

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-platform-platform-simulation-core</artifactId>
</dependency>
```

### Available SPIs

| SPI | Qualified name prefix | Methods |
|-----|-----------------------|---------|
| AccessControlProvider | access-control-provider | canAccess, grant, revoke, deny, accessibleResources, ... |
| DataSourceRegistry | data-source-registry | register, resolve, resolveSource, discover, deregister, update |
| SubscriptionStore | subscription-store | store, findById, find, update, delete, findAllEnabled |
| NotificationStore | notification-store | store, storeAll, find, unreadCount, markRead, dismiss, markAllRead |
| EndpointRegistry | endpoint-registry | register, resolve, discover, deregister |
| ExpressionEngineRegistry | expression-engine-registry | register, resolve, compile, validate |
| DocumentSigningService | document-signing-service | signPdf, signDetached |
| CredentialResolver | credential-resolver | resolve |
| ModelRegistry | model-registry | resolveById, query, all |
| PreferenceProvider | preference-provider | resolve |
| CurrentPrincipal | current-principal | actorId, groups, tenancyId, isCrossTenantAdmin |

### Example: simulate AccessControlProvider

```properties
# application.properties
casehub.simulation.access-control-provider.canAccess.strategy=sequential
```

```java
@Inject SimulationCorpus<Object, Object> corpus;

corpus.seed("access-control-provider.canAccess", List.of(
    new InvocationRecord<>("tenant-1", null,
        null, true, Instant.now()),   // first call → allow
    new InvocationRecord<>("tenant-1", null,
        null, false, Instant.now()))); // second call → deny
```

The decorator wraps whatever bean CDI resolves — a @DefaultBean NoOp or
a real implementation. When a strategy is configured, it intercepts. When
not, it passes through. No changes to the SPI, the NoOp, or
production code.
```

- [ ] **Step 3: Commit**

```bash
git add docs/guides/simulation-guide.md
git commit -m "docs(#321): add Platform SPIs section to simulation guide

Documents 11 platform-api SPIs available for simulation, with
dependency, qualified names, and example config.

Refs #321

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 6: Update CLAUDE.md module entry

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: module details from Task 3
- Produces: CLAUDE.md entry for platform-simulation-core

- [ ] **Step 1: Add module entry to the Modules table in CLAUDE.md**

Add after the `memory-simulation-core` entry:

```markdown
| `platform-simulation-core/` | `casehub-platform-platform-simulation-core` | Generated @Decorators for 11 platform-api SPIs (AccessControlProvider, DataSourceRegistry, SubscriptionStore, NotificationStore, EndpointRegistry, ExpressionEngineRegistry, DocumentSigningService, CredentialResolver, ModelRegistry, PreferenceProvider, CurrentPrincipal). Path A consumer — decorators generated by simulation-generator from META-INF/simulation-eligible.txt listing. Add to classpath to enable simulation/capture for platform SPIs. No quarkus:build goal |
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(#321): add platform-simulation-core to CLAUDE.md

Refs #321

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- [2026-09-16-defaultbean-simulation-patterns-design.md] — design spec
- [SimulationDecoratorProcessor.java:159-166] — abstract/default branch to remove
- [RestClientSimulationProcessor.java:146-153] — same branch in REST client processor
- [SimulationDecoratorProcessorTest.java:172-181] — test to update
- [TestSpiWithDefaults.java] — test interface with abstract + default methods
- [memory-simulation-core/pom.xml] — module template
- [memory-simulation-core/simulation-eligible.txt] — listing file precedent
- [DefaultBeans.java] — 35 @DefaultBean NoOps
- [AccessControlProvider.java] — pure-default interface (14 methods)
- [GitHub #321] — focal issue
- [GitHub #332] — verification API (testing ergonomics, follow-up)
