# Trust Model for Playbook Authoring — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #830 — WS-3: Trust model for playbook authoring
**Issue group:** #830

**Goal:** Extend the playbook capability taxonomy with risk-bearing
constants, add an `assisted` built-in schema, and reclassify dangerous
steps so the validator MCP tool (WS-6b) can serve a filtered catalogue.

**Architecture:** Four new capability constants in `PlaybookCapabilities`
classify dangerous steps (`process-execution`, `raw-http`,
`expression-mvel`, `env-access`). The existing `server` and `client`
schemas gain these capabilities (preserving current behaviour). A new
`assisted` schema excludes them. `ProcessPlugin` and `RestCallPlugin`
change their `@Plugin(capability=...)` from the default `"steps"` to
their risk-bearing capability. `SchemaFilteredRegistry` already handles
the filtering — no new abstractions.

**Tech Stack:** Java 21, yaml-core, yaml-plugin-api, yaml-step-runtime,
JUnit 5, AssertJ

## Global Constraints

- `yaml-plugin-api/` must remain zero-dependency — changes there are
  constants only (no new imports)
- `yaml-core/` depends only on `yaml-plugin-api` — remains zero-dep
- All new constants go in `PlaybookCapabilities` (yaml-core)
- The `@Plugin` annotation's `capability` attribute controls step
  classification — no need to modify `Definition` or `PluginRegistry`

---

## Batch 1: Capability taxonomy and assisted schema

### Task 1: Add risk-bearing capability constants and `assisted` schema

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookCapabilities.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookSchemas.java`
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/playbook/MapPlaybookSchemaRegistry.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/playbook/PlaybookSchemasTest.java`
- Test: `yaml-core/src/test/java/io/casehub/yaml/core/playbook/SchemaFilteredRegistryTest.java`

**Interfaces:**
- Produces: `PlaybookCapabilities.PROCESS_EXECUTION` = `"process-execution"`,
  `PlaybookCapabilities.RAW_HTTP` = `"raw-http"`,
  `PlaybookCapabilities.EXPRESSION_MVEL` = `"expression-mvel"`,
  `PlaybookCapabilities.ENV_ACCESS` = `"env-access"`,
  `PlaybookSchemas.ASSISTED` = `"assisted"`

- [ ] **Step 1: Write failing tests for the assisted schema**

Add tests to `PlaybookSchemasTest`:

```java
@Test
void assistedIsBuiltIn() {
    assertThat(PlaybookSchemas.isBuiltIn("assisted")).isTrue();
}

@Test
void assistedIsNotDomainSchema() {
    assertThat(PlaybookSchemas.isDomainSchema("assisted")).isFalse();
}
```

Add tests to `SchemaFilteredRegistryTest` — a new test method that
verifies the `assisted` schema filters risk-bearing capabilities:

```java
@Test
void assisted_excludesRiskCapabilities() {
    delegate.register(Definition.of("process")
            .capability("process-execution").execute(NOOP).build());
    delegate.register(Definition.of("rest-call")
            .capability("raw-http").execute(NOOP).build());
    delegate.register(Definition.of("safe-step")
            .capability("steps").execute(NOOP).build());

    var assistedFiltered = SchemaFilteredRegistry.forSchema(
            delegate, schemas, "assisted");

    assertThat(assistedFiltered.resolve("process")).isEmpty();
    assertThat(assistedFiltered.resolve("rest-call")).isEmpty();
    assertThat(assistedFiltered.resolve("safe-step")).isPresent();
}

@Test
void server_includesRiskCapabilities() {
    delegate.register(Definition.of("process")
            .capability("process-execution").execute(NOOP).build());
    delegate.register(Definition.of("rest-call")
            .capability("raw-http").execute(NOOP).build());

    var serverFiltered = SchemaFilteredRegistry.forSchema(
            delegate, schemas, "server");

    assertThat(serverFiltered.resolve("process")).isPresent();
    assertThat(serverFiltered.resolve("rest-call")).isPresent();
}
```

The `setUp()` method must register the `assisted` schema. Update it to
use `MapPlaybookSchemaRegistry` (which registers built-ins including
the new `assisted` schema) instead of manually registering only
domain schemas. The domain schema registration for `clinical-server`
stays as-is.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-core -Dtest="PlaybookSchemasTest,SchemaFilteredRegistryTest" -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — `PlaybookSchemas.ASSISTED` doesn't exist, `assisted`
schema not registered.

- [ ] **Step 3: Add capability constants**

In `PlaybookCapabilities.java`, add after the server-only capabilities
block:

```java
// Risk-bearing capabilities (excluded from assisted authoring context)
public static final String PROCESS_EXECUTION = "process-execution";
public static final String RAW_HTTP = "raw-http";
public static final String EXPRESSION_MVEL = "expression-mvel";
public static final String ENV_ACCESS = "env-access";
```

- [ ] **Step 4: Add `ASSISTED` constant to `PlaybookSchemas`**

In `PlaybookSchemas.java`:

```java
public static final String ASSISTED = "assisted";
```

Update `isBuiltIn()`:

```java
public static boolean isBuiltIn(String schema) {
    return CLIENT.equals(schema) || SERVER.equals(schema) || ASSISTED.equals(schema);
}
```

- [ ] **Step 5: Register `assisted` schema and update existing schemas**

In `MapPlaybookSchemaRegistry.registerBuiltIns()`, add the four risk
capabilities to `server` and `client` schemas, then register `assisted`:

```java
private void registerBuiltIns() {
    var clientCaps = new java.util.HashSet<>(SHARED_CAPABILITIES);
    clientCaps.addAll(Set.of(CHAPTERS, SECTIONS, ARIA, SPOTLIGHT, TUTORIALS,
            PROCESS_EXECUTION, RAW_HTTP, EXPRESSION_MVEL, ENV_ACCESS));
    register(PlaybookSchemaDescriptor.builtIn(PlaybookSchemas.CLIENT, clientCaps));

    var serverCaps = new java.util.HashSet<>(SHARED_CAPABILITIES);
    serverCaps.addAll(Set.of(ORCHESTRATION, CORRELATION, MCP_INVOKE, GRAPHQL_INVOKE, CODEGEN,
            PROCESS_EXECUTION, RAW_HTTP, EXPRESSION_MVEL, ENV_ACCESS));
    register(PlaybookSchemaDescriptor.builtIn(PlaybookSchemas.SERVER, serverCaps));

    var assistedCaps = new java.util.HashSet<>(SHARED_CAPABILITIES);
    assistedCaps.addAll(Set.of(ORCHESTRATION, CORRELATION, MCP_INVOKE, GRAPHQL_INVOKE, CODEGEN));
    register(PlaybookSchemaDescriptor.builtIn(PlaybookSchemas.ASSISTED, assistedCaps));
}
```

The `assisted` schema gets the same functional capabilities as `server`
but without the four risk-bearing ones.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-core -Dtest="PlaybookSchemasTest,SchemaFilteredRegistryTest" -Dsurefire.failIfNoSpecifiedTests=false`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookCapabilities.java \
        yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookSchemas.java \
        yaml-core/src/main/java/io/casehub/yaml/core/playbook/MapPlaybookSchemaRegistry.java \
        yaml-core/src/test/java/io/casehub/yaml/core/playbook/PlaybookSchemasTest.java \
        yaml-core/src/test/java/io/casehub/yaml/core/playbook/SchemaFilteredRegistryTest.java
git commit -m "feat(#830): risk-bearing capability constants and assisted schema

Add PROCESS_EXECUTION, RAW_HTTP, EXPRESSION_MVEL, ENV_ACCESS capability
constants. Register assisted built-in schema that excludes them. Server
and client schemas gain all four (preserving developer-tier behaviour).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: Reclassify `process` and `rest-call` plugins

**Files:**
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/ProcessPlugin.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/RestCallPlugin.java`
- Test: `yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/PluginScannerTest.java`

**Interfaces:**
- Consumes: `PlaybookCapabilities.PROCESS_EXECUTION`, `PlaybookCapabilities.RAW_HTTP` from Task 1

- [ ] **Step 1: Write failing test for plugin capability reclassification**

Add to `PluginScannerTest`:

```java
@Test
void processPlugin_hasProcessExecutionCapability() {
    PluginScanner scanner = new PluginScanner();
    var registry = new CompositePluginRegistry();
    scanner.scanAndRegister(ProcessPlugin.class, registry);

    var def = registry.resolve("process");
    assertThat(def).isPresent();
    assertThat(def.get().capability()).isEqualTo("process-execution");
}

@Test
void restCallPlugin_hasRawHttpCapability() {
    PluginScanner scanner = new PluginScanner();
    var registry = new CompositePluginRegistry();
    scanner.scanAndRegister(RestCallPlugin.class, registry);

    var def = registry.resolve("rest-call");
    assertThat(def).isPresent();
    assertThat(def.get().capability()).isEqualTo("raw-http");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="PluginScannerTest#processPlugin_hasProcessExecutionCapability+restCallPlugin_hasRawHttpCapability" -Dsurefire.failIfNoSpecifiedTests=false`
Expected: FAIL — both plugins currently have capability `"steps"`.

- [ ] **Step 3: Change `@Plugin` capability on `ProcessPlugin`**

In `ProcessPlugin.java`, change:

```java
@Plugin(value = "process", description = "Executes a system process via ProcessExecutor")
```

to:

```java
@Plugin(value = "process", description = "Executes a system process via ProcessExecutor",
        capability = "process-execution")
```

- [ ] **Step 4: Change `@Plugin` capability on `RestCallPlugin`**

In `RestCallPlugin.java`, change:

```java
@Plugin(value = "rest-call", description = "Makes an HTTP request")
```

to:

```java
@Plugin(value = "rest-call", description = "Makes an HTTP request",
        capability = "raw-http")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl yaml-step-runtime -Dtest="PluginScannerTest" -Dsurefire.failIfNoSpecifiedTests=false`
Expected: PASS

- [ ] **Step 6: Run full yaml-core + yaml-step-runtime test suite**

Run: `mvn --batch-mode test -pl yaml-core,yaml-step-runtime`
Expected: PASS — verify no existing tests broke from the capability
reclassification. If any playbook tests relied on `process` or
`rest-call` being resolved under a schema that only includes `"steps"`,
they will fail and need the schema's capabilities updated.

- [ ] **Step 7: Commit**

```bash
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/ProcessPlugin.java \
        yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/RestCallPlugin.java \
        yaml-step-runtime/src/test/java/io/casehub/yaml/step/catalog/PluginScannerTest.java
git commit -m "feat(#830): reclassify process and rest-call to risk capabilities

ProcessPlugin capability: steps → process-execution
RestCallPlugin capability: steps → raw-http

Both remain available in developer context (server/client schemas include
all risk capabilities). Excluded from assisted schema.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- `specs/issue-830-trust-model-playbook-authoring/2026-11-17-trust-model-design.md` — design spec
- `docs/adr/0013-trust-model-for-playbook-authoring.md` — ADR
- `yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookCapabilities.java` — capability constants
- `yaml-core/src/main/java/io/casehub/yaml/core/playbook/PlaybookSchemas.java` — schema name constants
- `yaml-core/src/main/java/io/casehub/yaml/core/playbook/MapPlaybookSchemaRegistry.java` — built-in schema registration
- `yaml-core/src/main/java/io/casehub/yaml/core/playbook/SchemaFilteredRegistry.java` — filtering decorator
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/ProcessPlugin.java:18` — `@Plugin` annotation
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/plugin/RestCallPlugin.java:16` — `@Plugin` annotation
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/Plugin.java:17` — `capability` attribute
- GitHub #830 — focal issue
- GitHub #836 — WS-6b (downstream: validator MCP tool uses `assisted` schema)
