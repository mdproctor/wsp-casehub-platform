# MCP Resource Subscription Infrastructure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #241 — MCP resource subscription and notification infrastructure for EndpointRegistry
**Issue group:** #241

**Goal:** Add a platform SPI for MCP resource contribution so domain repos can register resources, serve content, and push notifications — without depending on quarkus-mcp-server types.

**Architecture:** Sealed `McpResourceDescriptor` hierarchy + `McpResourceRegistry` SPI in `platform-api` (pure Java). `McpResourceRegistryBridge` in `mcp/` adapts to quarkus `ResourceManager`/`ResourceTemplateManager`/`CompletionManager`. `DomainResourceRegistrar` in `mcp/` is the first consumer, exposing domain metadata as MCP resources.

**Tech Stack:** Java 22, Quarkus 3.x, quarkus-mcp-server-core 1.11.1, JUnit 5, AssertJ

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports
- Every SPI in `platform-api` gets a `@DefaultBean` implementation in `platform/`
- `McpResourceHandler.read()` declares `throws Exception` — bridge catches all
- Template resources with `subscribable=true` are rejected by the bridge (quarkus-mcp-server 1.11.1 limitation)
- All quarkus-mcp-server resource handlers run on virtual threads (`setHandler(fn, true)`)
- Server name defaults to `casehub` via `casehub.mcp.server-name` config
- Package: `io.casehub.platform.api.mcp` for SPI types, `io.casehub.platform.mcp` for bridge

---

## Batch 1: SPI Types and NoOp Default

### Task 1: SPI types in platform-api

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/McpResourceDescriptor.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/StaticResourceDescriptor.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/TemplateResourceDescriptor.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/McpResourceReadRequest.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/McpResourceContent.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/McpResourceHandler.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/McpResourceHandle.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/McpResourceRegistry.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/McpResourceRegistration.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/McpResourceRegistered.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/mcp/McpResourceUpdated.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/mcp/McpResourceDescriptorTest.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/mcp/McpResourceReadRequestTest.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/mcp/McpResourceContentTest.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/mcp/McpResourceRegisteredTest.java`

**Interfaces:**
- Consumes: nothing (foundational types)
- Produces: `McpResourceDescriptor` sealed interface (factory methods `of()`, `template()`), `StaticResourceDescriptor` record (name, uri, mimeType, description, subscribable; `withSubscribable()`), `TemplateResourceDescriptor` record (name, uriTemplate, mimeType, description, subscribable; `withSubscribable()`), `McpResourceReadRequest` record (uri, templateArgs; factory `of(uri)`), `McpResourceContent` record (uri, text, mimeType; factories `of(uri, text)`, `of(uri, text, mimeType)`), `McpResourceHandler` functional interface (`read(McpResourceReadRequest) throws Exception → McpResourceContent`), `McpResourceHandle` interface (`notifyUpdate(uri)`, `deregister()`), `McpResourceRegistry` interface (`newResource(descriptor) → McpResourceRegistration`, `deregister(name)`, `resolve(name)`, `list()`), `McpResourceRegistration` interface (builder: `handler()`, `completion()`, `serverName()`, `register() → McpResourceHandle`), `McpResourceRegistered` record (descriptor), `McpResourceUpdated` record (uri)

- [ ] **Step 1: Write tests for McpResourceDescriptor**

```java
package io.casehub.platform.api.mcp;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class McpResourceDescriptorTest {

    @Test
    void staticFactoryCreatesStaticDescriptor() {
        var desc = McpResourceDescriptor.of("idx", "casehub://index", "application/json", "Index");
        assertThat(desc).isInstanceOf(StaticResourceDescriptor.class);
        assertThat(desc.name()).isEqualTo("idx");
        assertThat(desc.uri()).isEqualTo("casehub://index");
        assertThat(desc.mimeType()).isEqualTo("application/json");
        assertThat(desc.description()).isEqualTo("Index");
        assertThat(desc.subscribable()).isFalse();
    }

    @Test
    void templateFactoryCreatesTemplateDescriptor() {
        var desc = McpResourceDescriptor.template("tpl", "iot://devices/{id}", "application/json", "Device");
        assertThat(desc).isInstanceOf(TemplateResourceDescriptor.class);
        assertThat(desc.name()).isEqualTo("tpl");
        assertThat(((TemplateResourceDescriptor) desc).uriTemplate()).isEqualTo("iot://devices/{id}");
        assertThat(desc.subscribable()).isFalse();
    }

    @Test
    void staticWithSubscribableReturnsNewInstance() {
        var desc = McpResourceDescriptor.of("idx", "casehub://index", "application/json", "Index");
        var sub = desc.withSubscribable(true);
        assertThat(sub.subscribable()).isTrue();
        assertThat(desc.subscribable()).isFalse();
    }

    @Test
    void templateWithSubscribableReturnsNewInstance() {
        var desc = McpResourceDescriptor.template("tpl", "iot://d/{id}", null, "Device");
        var sub = desc.withSubscribable(true);
        assertThat(sub.subscribable()).isTrue();
    }

    @Test
    void staticNullNameThrows() {
        assertThatNullPointerException()
                .isThrownBy(() -> McpResourceDescriptor.of(null, "uri", "mime", "desc"));
    }

    @Test
    void staticNullUriThrows() {
        assertThatNullPointerException()
                .isThrownBy(() -> McpResourceDescriptor.of("n", null, "mime", "desc"));
    }

    @Test
    void templateNullUriTemplateThrows() {
        assertThatNullPointerException()
                .isThrownBy(() -> McpResourceDescriptor.template("n", null, "mime", "desc"));
    }

    @Test
    void nullMimeTypeIsAllowed() {
        var desc = McpResourceDescriptor.of("idx", "casehub://index", null, "Index");
        assertThat(desc.mimeType()).isNull();
    }

    @Test
    void sealedHierarchyExhaustive() {
        McpResourceDescriptor desc = McpResourceDescriptor.of("n", "u", null, "d");
        String result = switch (desc) {
            case StaticResourceDescriptor s -> s.uri();
            case TemplateResourceDescriptor t -> t.uriTemplate();
        };
        assertThat(result).isEqualTo("u");
    }
}
```

- [ ] **Step 2: Write tests for McpResourceReadRequest and McpResourceContent**

```java
// McpResourceReadRequestTest.java
package io.casehub.platform.api.mcp;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class McpResourceReadRequestTest {

    @Test
    void factoryCreatesEmptyTemplateArgs() {
        var req = McpResourceReadRequest.of("casehub://index");
        assertThat(req.uri()).isEqualTo("casehub://index");
        assertThat(req.templateArgs()).isEmpty();
    }

    @Test
    void constructorDefensivelyCopiesArgs() {
        var args = new java.util.HashMap<>(Map.of("k", "v"));
        var req = new McpResourceReadRequest("uri", args);
        args.put("extra", "val");
        assertThat(req.templateArgs()).doesNotContainKey("extra");
    }

    @Test
    void nullArgsBecomeEmptyMap() {
        var req = new McpResourceReadRequest("uri", null);
        assertThat(req.templateArgs()).isEmpty();
    }

    @Test
    void nullUriThrows() {
        assertThatNullPointerException()
                .isThrownBy(() -> McpResourceReadRequest.of(null));
    }
}
```

```java
// McpResourceContentTest.java
package io.casehub.platform.api.mcp;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class McpResourceContentTest {

    @Test
    void twoArgFactoryCreatesNullMimeType() {
        var c = McpResourceContent.of("uri", "hello");
        assertThat(c.uri()).isEqualTo("uri");
        assertThat(c.text()).isEqualTo("hello");
        assertThat(c.mimeType()).isNull();
    }

    @Test
    void threeArgFactorySetsMimeType() {
        var c = McpResourceContent.of("uri", "hello", "text/plain");
        assertThat(c.mimeType()).isEqualTo("text/plain");
    }

    @Test
    void nullUriThrows() {
        assertThatNullPointerException()
                .isThrownBy(() -> McpResourceContent.of(null, "text"));
    }

    @Test
    void nullTextThrows() {
        assertThatNullPointerException()
                .isThrownBy(() -> McpResourceContent.of("uri", null));
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-api -Dtest="McpResourceDescriptorTest,McpResourceReadRequestTest,McpResourceContentTest" -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — classes don't exist yet

- [ ] **Step 4: Implement all SPI types**

Create all 11 source files per the spec §3.1. Code is fully specified in the spec — sealed interface, two records, request/content records, handler functional interface, handle interface, registry SPI, registration builder, CDI event records.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform-api -Dtest="McpResourceDescriptorTest,McpResourceReadRequestTest,McpResourceContentTest"`
Expected: PASS

- [ ] **Step 6: Write and run McpResourceRegisteredTest**

```java
package io.casehub.platform.api.mcp;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class McpResourceRegisteredTest {

    @Test
    void carriesDescriptor() {
        var desc = McpResourceDescriptor.of("n", "u", null, "d");
        var event = new McpResourceRegistered(desc);
        assertThat(event.descriptor()).isSameAs(desc);
    }

    @Test
    void nullDescriptorThrows() {
        assertThatNullPointerException()
                .isThrownBy(() -> new McpResourceRegistered(null));
    }

    @Test
    void updatedCarriesUri() {
        var event = new McpResourceUpdated("casehub://index");
        assertThat(event.uri()).isEqualTo("casehub://index");
    }

    @Test
    void updatedNullUriThrows() {
        assertThatNullPointerException()
                .isThrownBy(() -> new McpResourceUpdated(null));
    }
}
```

Run: `mvn --batch-mode test -pl platform-api -Dtest="McpResourceRegisteredTest"`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#241): MCP resource SPI types in platform-api

Sealed McpResourceDescriptor hierarchy, handler, handle, registry,
registration builder, and CDI event records. Pure Java, zero deps.

Refs #241"
```

### Task 2: NoOp default in platform/

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/mock/NoOpMcpResourceRegistry.java`
- Modify: `platform/src/test/java/io/casehub/platform/mock/MockBeansTest.java` — add `@Inject McpResourceRegistry` and assert no-op
- Test: `platform-api/src/test/java/io/casehub/platform/api/mcp/NoOpMcpResourceRegistryTest.java`

**Interfaces:**
- Consumes: All SPI types from Task 1
- Produces: `NoOpMcpResourceRegistry @DefaultBean @ApplicationScoped` implementing `McpResourceRegistry`

- [ ] **Step 1: Write NoOp unit test**

```java
package io.casehub.platform.api.mcp;

import io.casehub.platform.mock.NoOpMcpResourceRegistry;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class NoOpMcpResourceRegistryTest {

    private final NoOpMcpResourceRegistry registry = new NoOpMcpResourceRegistry();

    @Test
    void registerReturnsNoOpHandle() {
        var desc = McpResourceDescriptor.of("n", "u", null, "d");
        var handle = registry.newResource(desc)
                .handler(req -> McpResourceContent.of(req.uri(), "text"))
                .register();
        assertThat(handle).isNotNull();
    }

    @Test
    void noOpHandleNotifyUpdateIsNoOp() {
        var handle = registry.newResource(McpResourceDescriptor.of("n", "u", null, "d"))
                .handler(req -> McpResourceContent.of(req.uri(), ""))
                .register();
        assertThatNoException().isThrownBy(() -> handle.notifyUpdate("u"));
    }

    @Test
    void noOpHandleDeregisterIsNoOp() {
        var handle = registry.newResource(McpResourceDescriptor.of("n", "u", null, "d"))
                .handler(req -> McpResourceContent.of(req.uri(), ""))
                .register();
        assertThatNoException().isThrownBy(handle::deregister);
    }

    @Test
    void resolveReturnsEmpty() {
        assertThat(registry.resolve("anything")).isEmpty();
    }

    @Test
    void listReturnsEmpty() {
        assertThat(registry.list()).isEmpty();
    }

    @Test
    void deregisterIsNoOp() {
        assertThatNoException().isThrownBy(() -> registry.deregister("anything"));
    }

    @Test
    void builderMethodsChainsReturnSelf() {
        var builder = registry.newResource(McpResourceDescriptor.template("n", "u/{x}", null, "d"));
        var result = builder
                .handler(req -> McpResourceContent.of(req.uri(), ""))
                .completion("x", () -> java.util.List.of("a"))
                .serverName("test");
        assertThat(result).isSameAs(builder);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest="NoOpMcpResourceRegistryTest" -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — `NoOpMcpResourceRegistry` doesn't exist

- [ ] **Step 3: Implement NoOpMcpResourceRegistry**

Create `NoOpMcpResourceRegistry.java` in `platform/src/main/java/io/casehub/platform/mock/` per spec §3.2.

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl platform-api -Dtest="NoOpMcpResourceRegistryTest"`
Expected: PASS (platform-api test classpath includes platform/ via test deps)

Note: If platform-api tests can't see platform/ classes, move this test to `platform/src/test/`. Follow existing `MockBeansTest` pattern.

- [ ] **Step 5: Add to MockBeansTest**

Add `@Inject McpResourceRegistry mcpResourceRegistry;` field and a test:
```java
@Test
void mcpResourceRegistry_noOp() {
    assertThat(mcpResourceRegistry.list()).isEmpty();
    assertThat(mcpResourceRegistry.resolve("any")).isEmpty();
}
```

- [ ] **Step 6: Run MockBeansTest**

Run: `mvn --batch-mode test -pl platform -Dtest="MockBeansTest"`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/ platform/src/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#241): NoOpMcpResourceRegistry @DefaultBean

Silent no-op for McpResourceRegistry — active when mcp/ is not on classpath.
Builder methods chain, handle operations are no-ops.

Refs #241"
```

---

## Batch 2: Bridge Implementation

### Task 3: McpResourceRegistryBridge

**Files:**
- Create: `mcp/src/main/java/io/casehub/platform/mcp/McpResourceRegistryBridge.java`
- Test: `mcp/src/test/java/io/casehub/platform/mcp/McpResourceRegistryBridgeTest.java`

**Interfaces:**
- Consumes: All SPI types from Task 1, `ResourceManager`, `ResourceTemplateManager`, `ResourceTemplateCompletionManager` (quarkus-mcp-server), `ModelScanComplete` CDI event
- Produces: `McpResourceRegistryBridge @ApplicationScoped` implementing `McpResourceRegistry` — bridges platform SPI to quarkus managers, fires `McpResourceRegistered` events, observes `McpResourceUpdated` events

- [ ] **Step 1: Write integration test for static resource registration**

```java
package io.casehub.platform.mcp;

import io.casehub.platform.api.mcp.*;
import io.quarkiverse.mcp.server.ResourceManager;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.*;

@QuarkusTest
class McpResourceRegistryBridgeTest {

    @Inject McpResourceRegistry registry;
    @Inject ResourceManager resourceManager;

    @Test
    void staticResourceRegisteredWithResourceManager() {
        var handle = registry.newResource(McpResourceDescriptor.of(
                "test-static", "test://static", "text/plain", "Test static"))
            .handler(req -> McpResourceContent.of(req.uri(), "hello"))
            .register();

        assertThat(handle).isNotNull();
        var resource = resourceManager.getResource("test://static");
        assertThat(resource).isNotNull();
        assertThat(resource.uri()).isEqualTo("test://static");

        handle.deregister();
    }

    @Test
    void registryResolveAndList() {
        var handle = registry.newResource(McpResourceDescriptor.of(
                "test-resolve", "test://resolve", null, "Resolve test"))
            .handler(req -> McpResourceContent.of(req.uri(), "data"))
            .register();

        assertThat(registry.resolve("test-resolve")).isPresent();
        assertThat(registry.list()).anyMatch(d -> d.name().equals("test-resolve"));

        handle.deregister();
        assertThat(registry.resolve("test-resolve")).isEmpty();
    }

    @Test
    void registerWithoutHandlerThrows() {
        assertThatIllegalStateException().isThrownBy(() ->
            registry.newResource(McpResourceDescriptor.of(
                    "no-handler", "test://no-handler", null, "Missing handler"))
                .register());
    }

    @Test
    void subscribableTemplateRejected() {
        assertThatIllegalArgumentException().isThrownBy(() ->
            registry.newResource(McpResourceDescriptor.template(
                    "bad-tpl", "test://t/{x}", null, "Bad").withSubscribable(true))
                .handler(req -> McpResourceContent.of(req.uri(), ""))
                .register());
    }

    @Test
    void deregisterByNameInvalidatesHandle() {
        var handle = registry.newResource(McpResourceDescriptor.of(
                "test-dereg", "test://dereg", null, "Deregister test"))
            .handler(req -> McpResourceContent.of(req.uri(), "data"))
            .register();

        registry.deregister("test-dereg");
        assertThat(registry.resolve("test-dereg")).isEmpty();
        // handle operations should be no-ops after deregistration
        assertThatNoException().isThrownBy(() -> handle.notifyUpdate("test://dereg"));
        assertThatNoException().isThrownBy(handle::deregister);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl mcp -Dtest="McpResourceRegistryBridgeTest" -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — `McpResourceRegistryBridge` doesn't exist

- [ ] **Step 3: Implement McpResourceRegistryBridge**

Create `McpResourceRegistryBridge.java` per spec §3.3:
- `@ApplicationScoped implements McpResourceRegistry`
- `newResource()` returns a `BridgeRegistration` builder (inner class)
- Builder stores handler, completions, serverName
- `register()` dispatches on `descriptor` sealed type:
  - `StaticResourceDescriptor` → `resourceManager.newResource(...)...register()`
  - `TemplateResourceDescriptor` → guard against subscribable, `resourceTemplateManager.newResourceTemplate(...)...register()`, then register completions
- `McpResourceUpdated` observer: `@ObservesAsync McpResourceUpdated` → look up registration by URI → `sendUpdateAndForget()`
- Handler adaptation with mimeType fallback and error wrapping
- `ConcurrentHashMap<String, Registration>` for tracking registrations
- Deregistration invalidates handles via `AtomicBoolean`

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl mcp -Dtest="McpResourceRegistryBridgeTest"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add mcp/src/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#241): McpResourceRegistryBridge — platform SPI to quarkus bridge

Adapts McpResourceRegistry to ResourceManager/ResourceTemplateManager.
Virtual-thread handlers, mimeType fallback, subscribable template guard,
CDI events, completion registration, deregistration with handle invalidation.

Refs #241"
```

---

## Batch 3: Domain Metadata Resources

### Task 4: DomainContentFormatter extraction and DomainResourceRegistrar

**Files:**
- Create: `mcp/src/main/java/io/casehub/platform/mcp/DomainContentFormatter.java`
- Create: `mcp/src/main/java/io/casehub/platform/mcp/DomainResourceRegistrar.java`
- Modify: `mcp/src/main/java/io/casehub/platform/mcp/CaseHubMcpTools.java` — delegate to `DomainContentFormatter`
- Test: `mcp/src/test/java/io/casehub/platform/mcp/DomainContentFormatterTest.java`
- Test: `mcp/src/test/java/io/casehub/platform/mcp/DomainResourceRegistrarTest.java`

**Interfaces:**
- Consumes: `McpResourceRegistry` (from Task 3), `ModelRegistry`, `ModelScanComplete`, `DomainModel`, `OperationDescriptor`, `EventDescriptor`, `ParameterDescriptor`
- Produces: `DomainContentFormatter` (package-private, static methods: `formatIndex(List<DomainModel>)`, `formatDomain(DomainModel)`), `DomainResourceRegistrar @ApplicationScoped` (observes `ModelScanComplete`, registers `casehub://domain-index` and `casehub://domains/{domain}`)

- [ ] **Step 1: Write DomainContentFormatter test**

```java
package io.casehub.platform.mcp;

import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.*;

class DomainContentFormatterTest {

    private static final DomainModel ENGINE = new DomainModel("engine", "Engine domain",
            List.of(
                    new OperationDescriptor("cases", OperationDescriptor.OperationType.QUERY,
                            "List cases", List.of(), "CaseList", null, null),
                    new OperationDescriptor("startCase", OperationDescriptor.OperationType.MUTATION,
                            "Start a case", List.of(new ParameterDescriptor("definitionId", "String", true)),
                            "Case", null, null)),
            List.of(), Map.of());

    @Test
    @SuppressWarnings("unchecked")
    void formatIndexListsDomains() {
        var result = DomainContentFormatter.formatIndex(List.of(ENGINE));
        assertThat(result).containsKey("domains");
        var domains = (List<Map<String, Object>>) result.get("domains");
        assertThat(domains).hasSize(1);
        assertThat(domains.get(0)).containsEntry("name", "engine");
        assertThat(domains.get(0)).containsEntry("operationCount", 2);
    }

    @Test
    @SuppressWarnings("unchecked")
    void formatDomainIncludesQueriesAndMutations() {
        var result = DomainContentFormatter.formatDomain(ENGINE);
        assertThat(result).containsEntry("domain", "engine");
        var queries = (List<Map<String, Object>>) result.get("queries");
        assertThat(queries).hasSize(1);
        assertThat(queries.get(0)).containsEntry("name", "cases");
        var mutations = (List<Map<String, Object>>) result.get("mutations");
        assertThat(mutations).hasSize(1);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl mcp -Dtest="DomainContentFormatterTest" -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL

- [ ] **Step 3: Implement DomainContentFormatter**

Extract `buildTier0()` and `buildTier1()` logic from `CaseHubMcpTools` into static methods in `DomainContentFormatter`. Also extract `operationToMap()`, `eventToMap()`, `paramToMap()` as private static helpers. The formatter takes `DomainModel` / `List<DomainModel>` and returns `Map<String, Object>`.

- [ ] **Step 4: Refactor CaseHubMcpTools to delegate**

Modify `CaseHubMcpTools.buildTier0()` to call `DomainContentFormatter.formatIndex(registry.getDomains())` and `buildTier1()` to call `DomainContentFormatter.formatDomain(domain)`. Remove the extracted helper methods from `CaseHubMcpTools`.

- [ ] **Step 5: Run existing MCP tests to verify no regression**

Run: `mvn --batch-mode test -pl mcp`
Expected: All existing tests PASS (CaseHubMcpToolsTest, McpSchemaBuilderTest, DynamicToolRegistrarTest, etc.)

- [ ] **Step 6: Write DomainResourceRegistrar test**

```java
package io.casehub.platform.mcp;

import io.casehub.platform.api.mcp.McpResourceRegistry;
import io.quarkiverse.mcp.server.ResourceManager;
import io.quarkiverse.mcp.server.ResourceTemplateManager;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.*;

@QuarkusTest
class DomainResourceRegistrarTest {

    @Inject ResourceManager resourceManager;
    @Inject ResourceTemplateManager resourceTemplateManager;
    @Inject McpResourceRegistry mcpResourceRegistry;

    @Test
    void domainIndexResourceRegistered() {
        var resource = resourceManager.getResource("casehub://domain-index");
        assertThat(resource).isNotNull();
        assertThat(resource.mimeType()).isEqualTo("application/json");
    }

    @Test
    void domainsTemplateRegistered() {
        var template = resourceTemplateManager.getResourceTemplate("casehub-domains");
        assertThat(template).isNotNull();
        assertThat(template.uriTemplate()).isEqualTo("casehub://domains/{domain}");
    }

    @Test
    void domainIndexInRegistryList() {
        assertThat(mcpResourceRegistry.list())
                .anyMatch(d -> d.name().equals("casehub-domain-index"));
    }

    @Test
    void domainsTemplateInRegistryList() {
        assertThat(mcpResourceRegistry.list())
                .anyMatch(d -> d.name().equals("casehub-domains"));
    }
}
```

- [ ] **Step 7: Implement DomainResourceRegistrar**

Create `DomainResourceRegistrar.java` per spec §3.4. Observes `ModelScanComplete`, registers:
1. `casehub://domain-index` (static) — handler calls `DomainContentFormatter.formatIndex()` + Jackson serialization
2. `casehub://domains/{domain}` (template) — handler calls `DomainContentFormatter.formatDomain()`, with `.completion("domain", ...)` supplier from `modelRegistry.getDomains()`

- [ ] **Step 8: Run all tests**

Run: `mvn --batch-mode test -pl mcp`
Expected: All PASS (existing + new)

- [ ] **Step 9: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add mcp/src/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#241): DomainResourceRegistrar — domain metadata as MCP resources

Extract DomainContentFormatter from CaseHubMcpTools. Register
casehub://domain-index (static) and casehub://domains/{domain} (template
with completions) on ModelScanComplete.

Refs #241"
```

### Task 5: Doc updates and full build verification

**Files:**
- Modify: `CLAUDE.md` — update `mcp/` module entry and `platform-api` package structure
- Modify: `ARC42STORIES.MD` — update §5 and §8

**Interfaces:**
- Consumes: All prior tasks
- Produces: Updated documentation, green full build

- [ ] **Step 1: Update CLAUDE.md**

Update the `mcp/` module table entry to add `McpResourceRegistryBridge`, `DomainResourceRegistrar`, `DomainContentFormatter`. Update the `platform-api` package structure to add all new MCP resource types.

- [ ] **Step 2: Update ARC42STORIES.MD**

Add `McpResourceRegistryBridge` and `DomainResourceRegistrar` to the MCP section in §5. Add handler adaptation pattern note in §8.

- [ ] **Step 3: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile and tests pass

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add CLAUDE.md ARC42STORIES.MD
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(#241): update CLAUDE.md and ARC42STORIES.MD for MCP resource infrastructure

Add McpResourceRegistryBridge, DomainResourceRegistrar, DomainContentFormatter
to module table. Update platform-api package structure with new MCP resource
SPI types. Update §5 building block view and §8 crosscutting concepts.

Refs #241"
```

---

## References

- [2026-08-20-mcp-resource-subscription-design.md] — design spec this plan implements
- [DynamicToolRegistrar.java:41-74] — existing ModelScanComplete observer pattern
- [CaseHubMcpTools.java:45-123] — code to extract into DomainContentFormatter
- [McpSchemaBuilderTest.java] — unit test pattern (plain JUnit, DomainModel fixtures)
- [DynamicToolRegistrarTest.java] — integration test pattern (@QuarkusTest, inject managers)
- [MockBeansTest.java] — @DefaultBean verification pattern
- [ResourceManager.java] — quarkus-mcp-server 1.11.1 resource registration API
- [ResourceTemplateManager.java] — quarkus-mcp-server 1.11.1 template API
- [CompletionManager.java] — quarkus-mcp-server 1.11.1 completion API
- [GitHub #241] — focal issue
