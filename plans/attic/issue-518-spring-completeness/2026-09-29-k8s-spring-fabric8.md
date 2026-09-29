# K8s Spring Fabric8 Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #473 — K8s Spring completion — fabric8 Spring integration
**Issue group:** #473

**Goal:** Provide Spring Boot parity for Kubernetes ConfigMap/Secret
reading by extracting expression-layer config/secret logic to
framework-neutral core POJOs, then wiring Spring auto-configuration.

**Architecture:** Standard dual-framework extraction. `PropertySource`
interface in expression-core provides the framework-neutral property
lookup abstraction. `ConfigManagerCore` and `SecretManagerCore` implement
the SPIs using `PropertySource`. Quarkus wraps with SmallRye Config;
Spring wraps with `Environment`. `JQEvaluatorCore` extracted for
`$secret`/`$config` scope injection parity.

**Tech Stack:** Java 21+, Spring Boot 4.1.1, spring-cloud-kubernetes-fabric8-config (optional), jackson-jq 1.6.0

## Global Constraints

- expression-core must remain framework-neutral — no CDI, no Spring imports
- expression-core already depends on jackson-databind and jackson-jq (for ValidationResult and JQ engines)
- All new Spring auto-config beans use `@ConditionalOnMissingBean` — consumers can override
- Spring Boot version: 4.1.1
- Optional dep version: verify spring-cloud-kubernetes-fabric8-config compatibility with Spring Boot 4.1.1 before adding

---

## Batch 1: Core extraction — PropertySource + ConfigManagerCore + SecretManagerCore

### Task 1: PropertySource, PropertyMapBuilder, ConfigManagerCore, SecretManagerCore

**Files:**
- Create: `expression-core/src/main/java/io/casehub/platform/expression/PropertySource.java`
- Create: `expression-core/src/main/java/io/casehub/platform/expression/PropertyMapBuilder.java`
- Create: `expression-core/src/main/java/io/casehub/platform/expression/ConfigManagerCore.java`
- Create: `expression-core/src/main/java/io/casehub/platform/expression/SecretManagerCore.java`
- Test: `expression-core/src/test/java/io/casehub/platform/expression/ConfigManagerCoreTest.java`
- Test: `expression-core/src/test/java/io/casehub/platform/expression/SecretManagerCoreTest.java`

**Interfaces:**
- Consumes: `ConfigManager` SPI from `platform-api` (`io.casehub.platform.api.expression.ConfigManager`)
- Consumes: `SecretManager` SPI from `platform-api` (`io.casehub.platform.api.expression.SecretManager`)
- Produces: `PropertySource` interface — used by Task 3 (Quarkus) and Task 4 (Spring)
- Produces: `ConfigManagerCore implements ConfigManager` — used by Tasks 3, 4
- Produces: `SecretManagerCore implements SecretManager` — used by Tasks 3, 4
- Produces: `PropertyMapBuilder.put(Map, String, String)` — used internally by both core classes

- [ ] **Step 1: Write PropertySource interface**

Create `expression-core/src/main/java/io/casehub/platform/expression/PropertySource.java`:

```java
package io.casehub.platform.expression;

import java.util.Optional;

public interface PropertySource {
    Optional<String> getProperty(String name);
    Iterable<String> getPropertyNames();
}
```

- [ ] **Step 2: Write PropertyMapBuilder**

Create `expression-core/src/main/java/io/casehub/platform/expression/PropertyMapBuilder.java`:

```java
package io.casehub.platform.expression;

import java.util.HashMap;
import java.util.Map;

public final class PropertyMapBuilder {
    private PropertyMapBuilder() {}

    @SuppressWarnings("unchecked")
    public static void put(Map<String, Object> map, String key, String value) {
        int dot = key.indexOf('.');
        if (dot == -1) { map.put(key, value); return; }
        String head = key.substring(0, dot);
        String tail = key.substring(dot + 1);
        Map<String, Object> nested = (Map<String, Object>)
                map.computeIfAbsent(head, k -> new HashMap<>());
        put(nested, tail, value);
    }
}
```

- [ ] **Step 3: Write ConfigManagerCore tests**

Create `expression-core/src/test/java/io/casehub/platform/expression/ConfigManagerCoreTest.java`:

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.ConfigMapNotFoundException;
import org.junit.jupiter.api.Test;

import java.util.*;

import static org.assertj.core.api.Assertions.*;

class ConfigManagerCoreTest {

    private ConfigManagerCore managerWith(Map<String, String> props) {
        return new ConfigManagerCore(new MapPropertySource(props));
    }

    @Test
    void config_returns_string_value() {
        var mgr = managerWith(Map.of("app.name", "test"));
        assertThat(mgr.config("app.name", String.class)).hasValue("test");
    }

    @Test
    void config_returns_empty_when_missing() {
        var mgr = managerWith(Map.of());
        assertThat(mgr.config("missing", String.class)).isEmpty();
    }

    @Test
    void config_converts_integer() {
        var mgr = managerWith(Map.of("app.port", "8080"));
        assertThat(mgr.config("app.port", Integer.class)).hasValue(8080);
    }

    @Test
    void config_converts_boolean() {
        var mgr = managerWith(Map.of("app.debug", "true"));
        assertThat(mgr.config("app.debug", Boolean.class)).hasValue(true);
    }

    @Test
    void multiConfig_splits_comma_separated() {
        var mgr = managerWith(Map.of("app.tags", "a, b, c"));
        assertThat(mgr.multiConfig("app.tags", String.class))
                .containsExactly("a", "b", "c");
    }

    @Test
    void multiConfig_returns_empty_when_missing() {
        var mgr = managerWith(Map.of());
        assertThat(mgr.multiConfig("missing", String.class)).isEmpty();
    }

    @Test
    void names_returns_all_property_names() {
        var mgr = managerWith(Map.of("a", "1", "b", "2"));
        assertThat(mgr.names()).containsExactlyInAnyOrder("a", "b");
    }

    @Test
    void configMap_builds_nested_map() {
        var mgr = managerWith(Map.of(
                "myapp.timeout", "5000",
                "myapp.database.host", "localhost",
                "myapp.database.port", "5432",
                "other.key", "ignored"));
        Map<String, Object> result = mgr.configMap("myapp");
        assertThat(result).containsEntry("timeout", "5000");
        @SuppressWarnings("unchecked")
        Map<String, Object> db = (Map<String, Object>) result.get("database");
        assertThat(db).containsEntry("host", "localhost").containsEntry("port", "5432");
    }

    @Test
    void configMap_throws_when_no_properties_match() {
        var mgr = managerWith(Map.of("other.key", "value"));
        assertThatThrownBy(() -> mgr.configMap("missing"))
                .isInstanceOf(ConfigMapNotFoundException.class);
    }

    static class MapPropertySource implements PropertySource {
        private final Map<String, String> props;
        MapPropertySource(Map<String, String> props) { this.props = props; }
        @Override public Optional<String> getProperty(String name) {
            return Optional.ofNullable(props.get(name));
        }
        @Override public Iterable<String> getPropertyNames() { return props.keySet(); }
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl expression-core -Dtest=ConfigManagerCoreTest`
Expected: compilation failure — `ConfigManagerCore` does not exist yet.

- [ ] **Step 5: Write ConfigManagerCore**

Create `expression-core/src/main/java/io/casehub/platform/expression/ConfigManagerCore.java`:

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.ConfigManager;
import io.casehub.platform.api.expression.ConfigMapNotFoundException;

import java.util.*;

public class ConfigManagerCore implements ConfigManager {

    private final PropertySource source;

    public ConfigManagerCore(PropertySource source) {
        this.source = Objects.requireNonNull(source);
    }

    @Override
    public <T> Optional<T> config(String propName, Class<T> propClass) {
        return source.getProperty(propName).map(v -> convert(v, propClass));
    }

    @Override
    public <T> Collection<T> multiConfig(String propName, Class<T> propClass) {
        return source.getProperty(propName)
                .map(v -> Arrays.stream(v.split(","))
                        .map(String::trim)
                        .filter(s -> !s.isEmpty())
                        .map(s -> convert(s, propClass))
                        .toList())
                .map(list -> (Collection<T>) list)
                .orElse(List.of());
    }

    @Override
    public Iterable<String> names() {
        return source.getPropertyNames();
    }

    @Override
    public Map<String, Object> configMap(String configMapName) {
        String prefix = configMapName + ".";
        Map<String, Object> result = new HashMap<>();
        for (String name : source.getPropertyNames()) {
            if (name.startsWith(prefix)) {
                source.getProperty(name)
                        .ifPresent(v -> PropertyMapBuilder.put(
                                result, name.substring(prefix.length()), v));
            }
        }
        if (result.isEmpty()) throw new ConfigMapNotFoundException(configMapName);
        return result;
    }

    @SuppressWarnings("unchecked")
    static <T> T convert(String value, Class<T> type) {
        if (type == String.class) return (T) value;
        if (type == Integer.class || type == int.class) return (T) Integer.valueOf(value);
        if (type == Long.class || type == long.class) return (T) Long.valueOf(value);
        if (type == Boolean.class || type == boolean.class) return (T) Boolean.valueOf(value);
        if (type == Double.class || type == double.class) return (T) Double.valueOf(value);
        if (type == Float.class || type == float.class) return (T) Float.valueOf(value);
        throw new IllegalArgumentException("Unsupported type: " + type.getName());
    }
}
```

- [ ] **Step 6: Run ConfigManagerCore tests to verify they pass**

Run: `mvn --batch-mode test -pl expression-core -Dtest=ConfigManagerCoreTest`
Expected: all pass.

- [ ] **Step 7: Write SecretManagerCore tests**

Create `expression-core/src/test/java/io/casehub/platform/expression/SecretManagerCoreTest.java`:

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.SecretNotFoundException;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.*;

class SecretManagerCoreTest {

    @Test
    void secret_returns_flat_properties() {
        var mgr = new SecretManagerCore(new ConfigManagerCoreTest.MapPropertySource(Map.of(
                "casehub.platform.secrets.openai.apiKey", "sk-test",
                "casehub.platform.secrets.openai.orgId", "org-123")));
        Map<String, Object> result = mgr.secret("openai");
        assertThat(result).containsEntry("apiKey", "sk-test").containsEntry("orgId", "org-123");
    }

    @Test
    void secret_returns_nested_map() {
        var mgr = new SecretManagerCore(new ConfigManagerCoreTest.MapPropertySource(Map.of(
                "casehub.platform.secrets.db.primary.host", "localhost",
                "casehub.platform.secrets.db.primary.port", "5432")));
        Map<String, Object> result = mgr.secret("db");
        @SuppressWarnings("unchecked")
        Map<String, Object> primary = (Map<String, Object>) result.get("primary");
        assertThat(primary).containsEntry("host", "localhost").containsEntry("port", "5432");
    }

    @Test
    void secret_throws_when_not_found() {
        var mgr = new SecretManagerCore(new ConfigManagerCoreTest.MapPropertySource(Map.of()));
        assertThatThrownBy(() -> mgr.secret("missing"))
                .isInstanceOf(SecretNotFoundException.class);
    }

    @Test
    void secret_ignores_properties_without_matching_prefix() {
        var mgr = new SecretManagerCore(new ConfigManagerCoreTest.MapPropertySource(Map.of(
                "casehub.platform.secrets.openai.apiKey", "sk-test",
                "casehub.platform.other", "ignored")));
        Map<String, Object> result = mgr.secret("openai");
        assertThat(result).hasSize(1).containsEntry("apiKey", "sk-test");
    }
}
```

- [ ] **Step 8: Write SecretManagerCore**

Create `expression-core/src/main/java/io/casehub/platform/expression/SecretManagerCore.java`:

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.SecretManager;
import io.casehub.platform.api.expression.SecretNotFoundException;

import java.util.*;

public class SecretManagerCore implements SecretManager {

    private static final String PREFIX = "casehub.platform.secrets.";
    private final PropertySource source;

    public SecretManagerCore(PropertySource source) {
        this.source = Objects.requireNonNull(source);
    }

    @Override
    public Map<String, Object> secret(String secretName) {
        String prefix = PREFIX + secretName + ".";
        Map<String, Object> result = new HashMap<>();
        for (String name : source.getPropertyNames()) {
            if (name.startsWith(prefix)) {
                source.getProperty(name)
                        .ifPresent(v -> PropertyMapBuilder.put(
                                result, name.substring(prefix.length()), v));
            }
        }
        if (result.isEmpty()) throw new SecretNotFoundException(secretName);
        return result;
    }
}
```

- [ ] **Step 9: Run SecretManagerCore tests to verify they pass**

Run: `mvn --batch-mode test -pl expression-core -Dtest=SecretManagerCoreTest`
Expected: all pass.

- [ ] **Step 10: Run all expression-core tests**

Run: `mvn --batch-mode test -pl expression-core`
Expected: all tests pass (existing + new).

- [ ] **Step 11: Commit**

```bash
git add expression-core/src/main/java/io/casehub/platform/expression/PropertySource.java expression-core/src/main/java/io/casehub/platform/expression/PropertyMapBuilder.java expression-core/src/main/java/io/casehub/platform/expression/ConfigManagerCore.java expression-core/src/main/java/io/casehub/platform/expression/SecretManagerCore.java expression-core/src/test/java/io/casehub/platform/expression/ConfigManagerCoreTest.java expression-core/src/test/java/io/casehub/platform/expression/SecretManagerCoreTest.java
git commit -m "feat(#473): add PropertySource abstraction, ConfigManagerCore, SecretManagerCore to expression-core"
```

### Task 2: JQEvaluatorCore extraction

**Files:**
- Create: `expression-core/src/main/java/io/casehub/platform/expression/JQEvaluatorCore.java`
- Test: `expression-core/src/test/java/io/casehub/platform/expression/JQEvaluatorCoreTest.java`

**Interfaces:**
- Consumes: `SecretManager` SPI, `ConfigManager` SPI, `ValidationResult` (already in expression-core)
- Produces: `JQEvaluatorCore(SecretManager, ConfigManager)` — used by Tasks 3, 4

- [ ] **Step 1: Write JQEvaluatorCore test**

Create `expression-core/src/test/java/io/casehub/platform/expression/JQEvaluatorCoreTest.java`:

```java
package io.casehub.platform.expression;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.casehub.platform.api.expression.ConfigManager;
import io.casehub.platform.api.expression.SecretManager;
import io.casehub.platform.api.expression.SecretNotFoundException;
import io.casehub.platform.api.expression.ConfigMapNotFoundException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.*;

import static org.assertj.core.api.Assertions.*;

class JQEvaluatorCoreTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private JQEvaluatorCore evaluator;

    @BeforeEach
    void setUp() {
        SecretManager secretManager = name -> {
            if ("testservice".equals(name)) {
                return Map.of("apiKey", "sk-test-key", "endpoint", "https://api.test.com");
            }
            throw new SecretNotFoundException(name);
        };
        ConfigManager configManager = new ConfigManagerCore(
                new ConfigManagerCoreTest.MapPropertySource(Map.of(
                        "myapp.timeout", "5000",
                        "myapp.retries", "3")));
        evaluator = new JQEvaluatorCore(secretManager, configManager);
    }

    @Test
    void eval_identity_returns_input() {
        ObjectNode node = MAPPER.createObjectNode().put("value", 42);
        ValidationResult result = evaluator.eval(".", node);
        assertThat(result.ok()).isTrue();
        assertThat(result.output()).isNotEmpty();
    }

    @Test
    void eval_field_access() {
        ObjectNode node = MAPPER.createObjectNode().put("name", "alice");
        ValidationResult result = evaluator.eval(".name", node);
        assertThat(result.ok()).isTrue();
        assertThat(result.output().get(0).asText()).isEqualTo("alice");
    }

    @Test
    void eval_injects_secret_scope() {
        ObjectNode node = MAPPER.createObjectNode();
        ValidationResult result = evaluator.eval(
                "$secret.testservice.apiKey", node, Set.of("testservice"), Set.of());
        assertThat(result.ok()).as(() -> "eval failed: " + result.error()).isTrue();
        assertThat(result.output().get(0).asText()).isEqualTo("sk-test-key");
    }

    @Test
    void eval_injects_config_scope() {
        ObjectNode node = MAPPER.createObjectNode();
        ValidationResult result = evaluator.eval(
                "$config.myapp.timeout", node, Set.of(), Set.of("myapp"));
        assertThat(result.ok()).as(() -> "eval failed: " + result.error()).isTrue();
        assertThat(result.output().get(0).asText()).isEqualTo("5000");
    }

    @Test
    void eval_invalid_expression_returns_error() {
        ObjectNode node = MAPPER.createObjectNode();
        ValidationResult result = evaluator.eval("this is not jq !!!", node);
        assertThat(result.ok()).isFalse();
        assertThat(result.error()).isNotNull();
    }

    @Test
    void eval_without_scopes_works() {
        ObjectNode node = MAPPER.createObjectNode().put("x", 1);
        ValidationResult result = evaluator.eval(".x", node);
        assertThat(result.ok()).isTrue();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl expression-core -Dtest=JQEvaluatorCoreTest`
Expected: compilation failure — `JQEvaluatorCore` does not exist.

- [ ] **Step 3: Write JQEvaluatorCore**

Create `expression-core/src/main/java/io/casehub/platform/expression/JQEvaluatorCore.java`:

```java
package io.casehub.platform.expression;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.casehub.platform.api.expression.ConfigManager;
import io.casehub.platform.api.expression.SecretManager;
import net.thisptr.jackson.jq.BuiltinFunctionLoader;
import net.thisptr.jackson.jq.JsonQuery;
import net.thisptr.jackson.jq.Scope;
import net.thisptr.jackson.jq.Versions;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

public class JQEvaluatorCore {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final SecretManager secretManager;
    private final ConfigManager configManager;
    private final Scope rootScope;
    private final ConcurrentHashMap<String, JsonQuery> queryCache = new ConcurrentHashMap<>();

    public JQEvaluatorCore(SecretManager secretManager, ConfigManager configManager) {
        this.secretManager = Objects.requireNonNull(secretManager);
        this.configManager = Objects.requireNonNull(configManager);
        this.rootScope = Scope.newEmptyScope();
        BuiltinFunctionLoader.getInstance().loadFunctions(Versions.JQ_1_6, rootScope);
    }

    public ValidationResult eval(String jqExpr, JsonNode input) {
        return eval(jqExpr, input, Set.of(), Set.of());
    }

    public ValidationResult eval(String jqExpr, JsonNode input,
                                 Set<String> secretNames, Set<String> configMapNames) {
        try {
            Scope childScope = Scope.newChildScope(rootScope);

            if (!secretNames.isEmpty()) {
                Map<String, Object> secretsMap = new HashMap<>();
                for (String name : secretNames) {
                    secretsMap.put(name, secretManager.secret(name));
                }
                childScope.setValue("secret", MAPPER.valueToTree(secretsMap));
            }

            if (!configMapNames.isEmpty()) {
                Map<String, Object> configsMap = new HashMap<>();
                for (String name : configMapNames) {
                    configsMap.put(name, configManager.configMap(name));
                }
                childScope.setValue("config", MAPPER.valueToTree(configsMap));
            }

            JsonQuery query = queryCache.computeIfAbsent(jqExpr, expr -> {
                try { return JsonQuery.compile(expr, Versions.JQ_1_6); }
                catch (Exception e) { throw new RuntimeException(e); }
            });

            List<JsonNode> out = new ArrayList<>();
            query.apply(childScope, input, out::add);
            return ValidationResult.ok(out);
        } catch (Exception e) {
            Throwable cause = (e instanceof RuntimeException && e.getCause() != null)
                    ? e.getCause() : e;
            return ValidationResult.error(
                    cause.getClass().getSimpleName() + ": " + cause.getMessage());
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl expression-core -Dtest=JQEvaluatorCoreTest`
Expected: all pass.

- [ ] **Step 5: Run all expression-core tests**

Run: `mvn --batch-mode test -pl expression-core`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add expression-core/src/main/java/io/casehub/platform/expression/JQEvaluatorCore.java expression-core/src/test/java/io/casehub/platform/expression/JQEvaluatorCoreTest.java
git commit -m "feat(#473): extract JQEvaluatorCore to expression-core"
```

## Batch 2: Quarkus refactor — delegate to core

### Task 3: Refactor MockConfigManager, MockSecretManager, JQEvaluator to delegate

**Files:**
- Modify: `expression/src/main/java/io/casehub/platform/expression/MockConfigManager.java`
- Modify: `expression/src/main/java/io/casehub/platform/expression/MockSecretManager.java`
- Modify: `expression/src/main/java/io/casehub/platform/expression/JQEvaluator.java`
- Create: `expression/src/main/java/io/casehub/platform/expression/SmallRyePropertySource.java`
- Test: existing tests in `expression/src/test/` — all must continue to pass

**Interfaces:**
- Consumes: `PropertySource`, `ConfigManagerCore`, `SecretManagerCore`, `JQEvaluatorCore` from Task 1-2
- Produces: no new public API — same beans, same behavior, different internals

- [ ] **Step 1: Create SmallRyePropertySource**

Create `expression/src/main/java/io/casehub/platform/expression/SmallRyePropertySource.java`:

```java
package io.casehub.platform.expression;

import org.eclipse.microprofile.config.ConfigProvider;

import java.util.Optional;

class SmallRyePropertySource implements PropertySource {

    @Override
    public Optional<String> getProperty(String name) {
        return ConfigProvider.getConfig().getOptionalValue(name, String.class);
    }

    @Override
    public Iterable<String> getPropertyNames() {
        return ConfigProvider.getConfig().getPropertyNames();
    }
}
```

- [ ] **Step 2: Refactor MockConfigManager to delegate to ConfigManagerCore**

Replace the body of `expression/src/main/java/io/casehub/platform/expression/MockConfigManager.java` with:

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.ConfigManager;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;

import java.util.Collection;
import java.util.Map;
import java.util.Optional;

@DefaultBean
@ApplicationScoped
public class MockConfigManager implements ConfigManager {

    private final ConfigManagerCore delegate;

    public MockConfigManager() {
        this.delegate = new ConfigManagerCore(new SmallRyePropertySource());
    }

    @Override
    public <T> Optional<T> config(String propName, Class<T> propClass) {
        return delegate.config(propName, propClass);
    }

    @Override
    public <T> Collection<T> multiConfig(String propName, Class<T> propClass) {
        return delegate.multiConfig(propName, propClass);
    }

    @Override
    public Iterable<String> names() {
        return delegate.names();
    }

    @Override
    public Map<String, Object> configMap(String configMapName) {
        return delegate.configMap(configMapName);
    }
}
```

- [ ] **Step 3: Refactor MockSecretManager to delegate to SecretManagerCore**

Replace the body of `expression/src/main/java/io/casehub/platform/expression/MockSecretManager.java` with:

```java
package io.casehub.platform.expression;

import io.casehub.platform.api.expression.SecretManager;
import io.casehub.platform.api.expression.SecretNotFoundException;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;

import java.util.Map;

@DefaultBean
@ApplicationScoped
public class MockSecretManager implements SecretManager {

    private final SecretManagerCore delegate;

    public MockSecretManager() {
        this.delegate = new SecretManagerCore(new SmallRyePropertySource());
    }

    @Override
    public Map<String, Object> secret(String secretName) {
        return delegate.secret(secretName);
    }
}
```

- [ ] **Step 4: Refactor JQEvaluator to delegate to JQEvaluatorCore**

Replace the body of `expression/src/main/java/io/casehub/platform/expression/JQEvaluator.java` with:

```java
package io.casehub.platform.expression;

import com.fasterxml.jackson.databind.JsonNode;
import io.casehub.platform.api.expression.ConfigManager;
import io.casehub.platform.api.expression.SecretManager;
import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.util.Set;

@ApplicationScoped
public class JQEvaluator {

    @Inject SecretManager secretManager;
    @Inject ConfigManager configManager;

    private JQEvaluatorCore delegate;

    @PostConstruct
    void init() {
        delegate = new JQEvaluatorCore(secretManager, configManager);
    }

    public ValidationResult eval(String jqExpr, JsonNode input) {
        return delegate.eval(jqExpr, input);
    }

    public ValidationResult eval(String jqExpr, JsonNode input,
                                 Set<String> secretNames, Set<String> configMapNames) {
        return delegate.eval(jqExpr, input, secretNames, configMapNames);
    }
}
```

- [ ] **Step 5: Run all expression tests to verify behavioral parity**

Run: `mvn --batch-mode test -pl expression`
Expected: all 6 test classes pass — JQEvaluatorTest, JQExpressionEngineTest, MvelExpressionEngineTest, JexlExpressionEngineTest, DefaultExpressionEngineRegistryTest, and TestPerson compiles.

- [ ] **Step 6: Commit**

```bash
git add expression/src/main/java/io/casehub/platform/expression/SmallRyePropertySource.java expression/src/main/java/io/casehub/platform/expression/MockConfigManager.java expression/src/main/java/io/casehub/platform/expression/MockSecretManager.java expression/src/main/java/io/casehub/platform/expression/JQEvaluator.java
git commit -m "refactor(#473): delegate MockConfigManager/MockSecretManager/JQEvaluator to expression-core"
```

## Batch 3: Spring module + integration

### Task 4: Create expression-spring module

**Files:**
- Create: `expression-spring/pom.xml`
- Create: `expression-spring/src/main/java/io/casehub/platform/expression/spring/EnvironmentPropertySource.java`
- Create: `expression-spring/src/main/java/io/casehub/platform/expression/spring/ExpressionSpringAutoConfiguration.java`
- Create: `expression-spring/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`
- Test: `expression-spring/src/test/java/io/casehub/platform/expression/spring/EnvironmentPropertySourceTest.java`
- Test: `expression-spring/src/test/java/io/casehub/platform/expression/spring/ExpressionSpringAutoConfigurationTest.java`
- Modify: `pom.xml` (root) — add `<module>expression-spring</module>`

**Interfaces:**
- Consumes: `PropertySource`, `ConfigManagerCore`, `SecretManagerCore`, `JQEvaluatorCore` from expression-core
- Consumes: `DefaultExpressionEngineRegistry`, `MvelExpressionEngine`, `JQExpressionEngine`, `JexlExpressionEngine` from expression-core
- Produces: `ExpressionSpringAutoConfiguration` — auto-discovered by Spring Boot

- [ ] **Step 1: Delete orphan expression-spring/target/ directory**

```bash
rm -rf expression-spring/target
```

- [ ] **Step 2: Create expression-spring pom.xml**

Create `expression-spring/pom.xml`:

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

    <artifactId>casehub-platform-expression-spring</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform :: Expression Spring</name>
    <description>Spring Boot auto-configuration for expression engines,
        ConfigManager and SecretManager. Kubernetes ConfigMap/Secret
        reading via optional spring-cloud-kubernetes-fabric8-config.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-expression-core</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-autoconfigure</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework</groupId>
            <artifactId>spring-core</artifactId>
        </dependency>

        <!-- Optional: enables K8s ConfigMap/Secret → Spring Environment -->
        <dependency>
            <groupId>org.springframework.cloud</groupId>
            <artifactId>spring-cloud-kubernetes-fabric8-config</artifactId>
            <optional>true</optional>
        </dependency>

        <!-- Test -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

Note: if `spring-cloud-kubernetes-fabric8-config` is not in the parent BOM
and no compatible version exists for Spring Boot 4.1.1, remove the optional
dependency and document it in the consumer guide instead. The auto-config
works without it — it's purely for Maven metadata visibility.

- [ ] **Step 3: Add expression-spring module to root pom.xml**

Add `<module>expression-spring</module>` after the `expression` module
entry in the root `pom.xml` modules list (around line 41).

- [ ] **Step 4: Write EnvironmentPropertySource test**

Create `expression-spring/src/test/java/io/casehub/platform/expression/spring/EnvironmentPropertySourceTest.java`:

```java
package io.casehub.platform.expression.spring;

import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;

import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.*;

class EnvironmentPropertySourceTest {

    @Test
    void getProperty_returns_value() {
        var env = new MockEnvironment().withProperty("app.name", "test");
        var source = new EnvironmentPropertySource(env);
        assertThat(source.getProperty("app.name")).hasValue("test");
    }

    @Test
    void getProperty_returns_empty_when_missing() {
        var env = new MockEnvironment();
        var source = new EnvironmentPropertySource(env);
        assertThat(source.getProperty("missing")).isEmpty();
    }

    @Test
    void getPropertyNames_returns_all_names() {
        var env = new MockEnvironment()
                .withProperty("a", "1")
                .withProperty("b", "2");
        var source = new EnvironmentPropertySource(env);
        List<String> names = new ArrayList<>();
        source.getPropertyNames().forEach(names::add);
        assertThat(names).contains("a", "b");
    }
}
```

- [ ] **Step 5: Run test to verify it fails**

Run: `mvn --batch-mode test -pl expression-spring -Dtest=EnvironmentPropertySourceTest`
Expected: compilation failure — `EnvironmentPropertySource` does not exist.

- [ ] **Step 6: Write EnvironmentPropertySource**

Create `expression-spring/src/main/java/io/casehub/platform/expression/spring/EnvironmentPropertySource.java`:

```java
package io.casehub.platform.expression.spring;

import io.casehub.platform.expression.PropertySource;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.EnumerablePropertySource;
import org.springframework.core.env.Environment;

import java.util.*;

class EnvironmentPropertySource implements PropertySource {

    private final Environment environment;
    private final ConfigurableEnvironment configurableEnv;

    EnvironmentPropertySource(Environment environment) {
        this.environment = environment;
        this.configurableEnv = (environment instanceof ConfigurableEnvironment ce) ? ce : null;
    }

    @Override
    public Optional<String> getProperty(String name) {
        return Optional.ofNullable(environment.getProperty(name));
    }

    @Override
    public Iterable<String> getPropertyNames() {
        if (configurableEnv == null) return List.of();
        Set<String> names = new LinkedHashSet<>();
        for (var ps : configurableEnv.getPropertySources()) {
            if (ps instanceof EnumerablePropertySource<?> eps) {
                Collections.addAll(names, eps.getPropertyNames());
            }
        }
        return names;
    }
}
```

- [ ] **Step 7: Run EnvironmentPropertySource tests**

Run: `mvn --batch-mode test -pl expression-spring -Dtest=EnvironmentPropertySourceTest`
Expected: all pass.

- [ ] **Step 8: Write ExpressionSpringAutoConfiguration test**

Create `expression-spring/src/test/java/io/casehub/platform/expression/spring/ExpressionSpringAutoConfigurationTest.java`:

```java
package io.casehub.platform.expression.spring;

import io.casehub.platform.api.expression.ConfigManager;
import io.casehub.platform.api.expression.ExpressionEngineRegistry;
import io.casehub.platform.api.expression.SecretManager;
import io.casehub.platform.expression.JQEvaluatorCore;
import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

import static org.assertj.core.api.Assertions.*;

class ExpressionSpringAutoConfigurationTest {

    private final ApplicationContextRunner runner = new ApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(ExpressionSpringAutoConfiguration.class));

    @Test
    void configManager_bean_registered() {
        runner.run(ctx -> assertThat(ctx).hasSingleBean(ConfigManager.class));
    }

    @Test
    void secretManager_bean_registered() {
        runner.run(ctx -> assertThat(ctx).hasSingleBean(SecretManager.class));
    }

    @Test
    void jqEvaluatorCore_bean_registered() {
        runner.run(ctx -> assertThat(ctx).hasSingleBean(JQEvaluatorCore.class));
    }

    @Test
    void expressionEngineRegistry_bean_registered() {
        runner.run(ctx -> assertThat(ctx).hasSingleBean(ExpressionEngineRegistry.class));
    }

    @Test
    void configManager_reads_from_environment() {
        runner.withPropertyValues("casehub.platform.secrets.test.key=secret-value")
                .run(ctx -> {
                    SecretManager sm = ctx.getBean(SecretManager.class);
                    assertThat(sm.secret("test")).containsEntry("key", "secret-value");
                });
    }

    @Test
    void custom_configManager_overrides_default() {
        runner.withBean("customConfigManager", ConfigManager.class,
                        () -> new io.casehub.platform.expression.ConfigManagerCore(
                                new io.casehub.platform.expression.PropertySource() {
                                    public java.util.Optional<String> getProperty(String n) {
                                        return java.util.Optional.of("custom");
                                    }
                                    public Iterable<String> getPropertyNames() {
                                        return java.util.List.of();
                                    }
                                }))
                .run(ctx -> {
                    ConfigManager cm = ctx.getBean(ConfigManager.class);
                    assertThat(cm.config("any", String.class)).hasValue("custom");
                });
    }
}
```

- [ ] **Step 9: Write ExpressionSpringAutoConfiguration**

Create `expression-spring/src/main/java/io/casehub/platform/expression/spring/ExpressionSpringAutoConfiguration.java`:

```java
package io.casehub.platform.expression.spring;

import io.casehub.platform.api.expression.ConfigManager;
import io.casehub.platform.api.expression.ExpressionEngine;
import io.casehub.platform.api.expression.SecretManager;
import io.casehub.platform.expression.*;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;
import org.springframework.core.env.Environment;

import java.util.List;

@AutoConfiguration
@ConditionalOnClass(ConfigManagerCore.class)
public class ExpressionSpringAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean(ConfigManager.class)
    public ConfigManagerCore configManager(Environment environment) {
        return new ConfigManagerCore(new EnvironmentPropertySource(environment));
    }

    @Bean
    @ConditionalOnMissingBean(SecretManager.class)
    public SecretManagerCore secretManager(Environment environment) {
        return new SecretManagerCore(new EnvironmentPropertySource(environment));
    }

    @Bean
    @ConditionalOnMissingBean(JQEvaluatorCore.class)
    public JQEvaluatorCore jqEvaluator(SecretManager secretManager, ConfigManager configManager) {
        return new JQEvaluatorCore(secretManager, configManager);
    }

    @Bean
    @ConditionalOnMissingBean
    public DefaultExpressionEngineRegistry defaultExpressionEngineRegistry(
            List<ExpressionEngine> engines) {
        return new DefaultExpressionEngineRegistry(engines);
    }

    @Bean
    public MvelExpressionEngine mvelExpressionEngine() {
        return new MvelExpressionEngine();
    }

    @Bean
    public JQExpressionEngine jqExpressionEngine() {
        return new JQExpressionEngine();
    }

    @Bean
    public JexlExpressionEngine jexlExpressionEngine() {
        return new JexlExpressionEngine();
    }
}
```

- [ ] **Step 10: Create AutoConfiguration.imports**

Create `expression-spring/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`:

```
io.casehub.platform.expression.spring.ExpressionSpringAutoConfiguration
```

- [ ] **Step 11: Run ExpressionSpringAutoConfiguration tests**

Run: `mvn --batch-mode test -pl expression-spring`
Expected: all pass.

- [ ] **Step 12: Commit**

```bash
git add expression-spring/ pom.xml
git commit -m "feat(#473): add expression-spring module with Spring Environment-backed ConfigManager/SecretManager"
```

### Task 5: Wire into starter + integration test + consumer guide

**Files:**
- Modify: `spring-boot-starter/pom.xml` — add expression-spring dependency
- Modify: `spring-integration-test/src/test/java/io/casehub/platform/spring/integration/SpringBootCompositionTest.java` — add expression bean assertions
- Modify: `docs/guides/consumer-guide.md` — add Spring K8s config section

**Interfaces:**
- Consumes: expression-spring module from Task 4
- Produces: none — integration wiring only

- [ ] **Step 1: Add expression-spring to spring-boot-starter pom.xml**

Add to `spring-boot-starter/pom.xml` dependencies section, after the
credentials-spring entry (around line 102):

```xml
        <!-- Expression engines + ConfigManager/SecretManager -->
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-expression-spring</artifactId>
            <version>${project.version}</version>
        </dependency>
```

- [ ] **Step 2: Add expression bean assertions to SpringBootCompositionTest**

Add to `noOpFallbackBeansRegistered()` method in `SpringBootCompositionTest.java`:

```java
        assertThat(context.getBean(io.casehub.platform.api.expression.ConfigManager.class)).isNotNull();
        assertThat(context.getBean(io.casehub.platform.api.expression.SecretManager.class)).isNotNull();
        assertThat(context.getBean(io.casehub.platform.expression.JQEvaluatorCore.class)).isNotNull();
```

- [ ] **Step 3: Run spring-integration-test**

Run: `mvn --batch-mode test -pl spring-integration-test`
Expected: all pass including new assertions.

- [ ] **Step 4: Add Spring K8s section to consumer guide**

In `docs/guides/consumer-guide.md`, find the existing Quarkus K8s
configuration section (around line 642) and add a Spring Boot equivalent
section after it. The section should document:

```markdown
#### Spring Boot Kubernetes Configuration

Add `spring-cloud-kubernetes-fabric8-config` to your application's classpath
to enable Kubernetes ConfigMap and Secret reading:

```properties
# application.properties (prod profile)
spring.cloud.kubernetes.config.enabled=true
spring.cloud.kubernetes.config.sources[0].name=casehub-config
spring.cloud.kubernetes.secrets.enabled=true
spring.cloud.kubernetes.secrets.sources[0].name=casehub-secrets
```

ConfigMap and Secret format is identical to the Quarkus examples above.
The `ConfigManager` and `SecretManager` SPIs read from Spring's
`Environment` — any property source that feeds into `Environment`
(including spring-cloud-kubernetes) is automatically available.
```

- [ ] **Step 5: Run full build to verify everything composes**

Run: `mvn --batch-mode install`
Expected: all modules compile and tests pass.

- [ ] **Step 6: Commit**

```bash
git add spring-boot-starter/pom.xml spring-integration-test/src/test/java/io/casehub/platform/spring/integration/SpringBootCompositionTest.java docs/guides/consumer-guide.md
git commit -m "feat(#473): wire expression-spring into starter, add integration tests and K8s consumer guide"
```

## References

- [2026-09-29-k8s-spring-fabric8-design.md] — design spec this plan implements
- [expression/MockSecretManager.java] — existing Quarkus SecretManager implementation
- [expression/MockConfigManager.java] — existing Quarkus ConfigManager implementation
- [expression/JQEvaluator.java] — existing Quarkus JQEvaluator (CDI-coupled)
- [expression-core/ValidationResult.java] — already extracted to core
- [expression/quarkus/ExpressionBeans.java] — Quarkus CDI bean producers
- [credentials-spring/EnvironmentCredentialResolver.java] — established Spring Environment pattern
- [credentials-spring/CredentialsSpringAutoConfiguration.java] — established auto-config pattern
- [spring-integration-test/SpringBootCompositionTest.java] — existing composition gate
- [drift-detection/spring-parity-exceptions.txt] — expression not excepted (parity expected)
- [GitHub #473] — focal issue
- [GitHub parent#515] — parent epic
