# K8s Spring Fabric8 Integration — Design Spec

**Issue:** casehubio/platform#473
**Parent epic:** casehubio/parent#515
**Date:** 2026-09-29

## Goal

Provide Spring Boot parity for Kubernetes ConfigMap/Secret reading. The
Quarkus side reads K8s data via optional `quarkus-kubernetes-config` into
SmallRye Config, which `MockSecretManager` and `MockConfigManager` consume.
The Spring side has no equivalent — `$config` and `$secret` variables in
JQ expressions don't work on Spring Boot deployments.

## Scope

Expression layer parity only. No `KubernetesClient` auto-configuration,
no K8s starter. Platform's K8s role is config/secret reading via the
config abstraction — consumers needing a raw `KubernetesClient` add
`spring-cloud-kubernetes-fabric8-autoconfig` directly (same as Quarkus
consumers add `quarkus-kubernetes-client`).

## Architecture

Standard dual-framework extraction pattern:

```
platform-api        SecretManager, ConfigManager (SPIs — unchanged)
     │
expression-core     PropertySource (new interface)
     │              ConfigManagerCore implements ConfigManager
     │              SecretManagerCore implements SecretManager
     │              PropertyMapBuilder (shared nested-map helper)
     ├──────────────────────────────────┐
expression/         expression-spring/
(Quarkus CDI)       (Spring auto-config)
SmallRyePropertySource   EnvironmentPropertySource
@DefaultBean wrappers    @ConditionalOnMissingBean beans
quarkus-kubernetes-config (opt)  spring-cloud-kubernetes-fabric8-config (opt)
```

## Deliverables

### 1. PropertySource interface (expression-core)

```java
package io.casehub.platform.expression;

import java.util.Optional;

public interface PropertySource {
    Optional<String> getProperty(String name);
    Iterable<String> getPropertyNames();
}
```

Minimal contract — string-only lookup + name iteration. Type conversion
handled in `ConfigManagerCore` for framework independence.

### 2. PropertyMapBuilder (expression-core)

Extract the `put(Map, String, Object)` helper from `MockConfigManager` /
`MockSecretManager` into a shared utility:

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

### 3. ConfigManagerCore (expression-core)

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
    private static <T> T convert(String value, Class<T> type) {
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

### 4. SecretManagerCore (expression-core)

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

### 5. JQEvaluatorCore (expression-core)

`JQEvaluator` in expression/ is `@ApplicationScoped` with `@Inject`
SecretManager and ConfigManager. It provides `$secret`/`$config` scope
injection in JQ expressions. Without extraction, these variables won't
work on Spring.

Extract to constructor-injected POJO:

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
        // Same implementation as current JQEvaluator.eval()
    }
}
```

Quarkus `JQEvaluator` becomes a thin CDI wrapper delegating to
`JQEvaluatorCore`. Spring auto-config creates `JQEvaluatorCore` bean
directly.

### 6. Quarkus refactor (expression/)

Replace `MockConfigManager` body with delegation to `ConfigManagerCore`:

```java
@DefaultBean
@ApplicationScoped
public class MockConfigManager implements ConfigManager {

    private final ConfigManagerCore delegate;

    public MockConfigManager() {
        this.delegate = new ConfigManagerCore(new SmallRyePropertySource());
    }

    @Override public <T> Optional<T> config(String n, Class<T> c) { return delegate.config(n, c); }
    @Override public <T> Collection<T> multiConfig(String n, Class<T> c) { return delegate.multiConfig(n, c); }
    @Override public Iterable<String> names() { return delegate.names(); }
    @Override public Map<String, Object> configMap(String n) { return delegate.configMap(n); }
}
```

Same for `MockSecretManager`. `JQEvaluator` becomes a thin CDI wrapper
delegating to `JQEvaluatorCore`. `SmallRyePropertySource` is
package-private in expression/:

```java
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

### 7. expression-spring module (new)

**pom.xml:** depends on expression-core, platform-api, spring-boot-autoconfigure. Optional dep on spring-cloud-kubernetes-fabric8-config.

**EnvironmentPropertySource** (package-private):

```java
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

**ExpressionSpringAutoConfiguration:**

```java
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

    @Bean public MvelExpressionEngine mvelExpressionEngine() { return new MvelExpressionEngine(); }
    @Bean public JQExpressionEngine jqExpressionEngine() { return new JQExpressionEngine(); }
    @Bean public JexlExpressionEngine jexlExpressionEngine() { return new JexlExpressionEngine(); }
}
```

**Add to spring-boot-starter:** dependency on `casehub-platform-expression-spring`.

### 8. Consumer guide update

Add Spring Boot K8s section to `docs/guides/consumer-guide.md`:

```properties
# Spring Boot K8s configuration
spring.cloud.kubernetes.config.enabled=true
spring.cloud.kubernetes.config.sources[0].name=casehub-config
spring.cloud.kubernetes.secrets.enabled=true
spring.cloud.kubernetes.secrets.sources[0].name=casehub-secrets
```

Same ConfigMap/Secret YAML examples already documented for Quarkus.

## Testing Strategy

- **ConfigManagerCore / SecretManagerCore:** Unit tests in expression-core with a simple in-memory PropertySource. Test prefix scanning, nested map building, type conversion, empty/missing cases.
- **JQEvaluatorCore:** Unit tests in expression-core verifying $secret/$config scope injection with mock SecretManager/ConfigManager. Existing JQEvaluatorTest coverage migrates to core.
- **SmallRyePropertySource:** Existing MockConfigManager and MockSecretManager tests in expression/ continue to pass — behavioral parity.
- **EnvironmentPropertySource:** Unit test with MockEnvironment. Verify property lookup and name enumeration.
- **ExpressionSpringAutoConfiguration:** Verify beans are created, ConditionalOnMissingBean works, expression engines are registered.
- **spring-integration-test:** Add expression auto-config to the existing Spring Boot composition test.

## Modules Changed

| Module | Change |
|--------|--------|
| expression-core | Add PropertySource, PropertyMapBuilder, ConfigManagerCore, SecretManagerCore, JQEvaluatorCore |
| expression | Refactor MockConfigManager/MockSecretManager/JQEvaluator to delegate to core |
| expression-spring (new) | EnvironmentPropertySource + auto-config + optional spring-cloud-kubernetes-fabric8 |
| spring-boot-starter | Add expression-spring dependency |
| spring-integration-test | Verify expression auto-config composes |
| docs/guides/consumer-guide.md | Spring K8s config section |

## References

- expression-spring/target/ — orphan build output from prior generation attempt; clean up when creating real module
- expression/MockSecretManager.java — existing Quarkus implementation
- expression/MockConfigManager.java — existing Quarkus implementation
- expression/pom.xml:56 — quarkus-kubernetes-config optional dep
- credentials-spring/EnvironmentCredentialResolver.java — established Spring Environment pattern
- credentials-spring/CredentialsSpringAutoConfiguration.java — established auto-config pattern
- platform-api SecretManager.java — SPI interface
- platform-api ConfigManager.java — SPI interface
- specs/spring-deployment-completion/2026-09-15-spring-deployment-completion-design.md — parent design
- specs/issue-473-k8s-spring-fabric8/decisions.md — D1-D4
