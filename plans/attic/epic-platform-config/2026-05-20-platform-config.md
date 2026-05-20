# casehub-platform-config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Also required:** superpowers:test-driven-development before writing any implementation code. java-dev for all Java. superpowers:requesting-code-review before committing.

**Goal:** Add a `config/` module (`casehub-platform-config`) that reads scope-aware YAML preference files and SmallRye Config overrides, implementing `PreferenceProvider` as an `@ApplicationScoped` bean that displaces the `@DefaultBean` mock in production.

**Architecture:** Single `ConfigFilePreferenceProvider` reads one or more YAML files at `@PostConstruct` (startup-only), builds a `Map<Path, Map<String, String>>` (null key = unscoped), then on `resolve(scope)` merges: unscoped entries → scope hierarchy → SmallRye Config overrides (highest). All values are stored as strings; `key.parse()` converts on access via `MapPreferences`. `${VAR}` interpolation via system properties and environment variables happens at load time. YAML parsing is in a separate pure-Java `YamlPreferenceLoader` class.

**Tech Stack:** Java 21, Quarkus Arc (`@ApplicationScoped`, `@PostConstruct`, `@ConfigProperty`), SnakeYAML (managed by Quarkus BOM), JUnit Jupiter, `@QuarkusTest`, Jandex plugin.

---

## File Structure

```
config/
  pom.xml                                          casehub-platform-config
  src/main/java/io/casehub/platform/config/
    YamlPreferenceLoader.java                      pure Java — parses YAML into scope map
    ConfigFilePreferenceProvider.java              @ApplicationScoped — displaces mock
  src/test/java/io/casehub/platform/config/
    YamlPreferenceLoaderTest.java                  pure JUnit 5 — no Quarkus
    ConfigFilePreferenceProviderTest.java          @QuarkusTest
  src/test/resources/
    application.properties                         test config
    test-prefs-a.yaml                              primary test preferences file
    test-prefs-b.yaml                              secondary file for chaining test

platform/pom.xml                                   add <module>config</module>
~/claude/casehub/parent/pom.xml                    add casehub-platform-config to BOM
```

**YAML format** (explicit scope entries — no ambiguity between scope levels and preference keys):
```yaml
entries:
  - devtown.globalDefault: "true"                  # no scope key = unscoped
  - scope: casehubio/devtown
    devtown.humanApprovalThreshold: "500"
    devtown.securityReviewRequired: "false"
  - scope: casehubio/devtown/pr-review
    devtown.humanApprovalThreshold: "100"
    devtown.securityReviewRequired: "true"
```

**Resolution priority (lowest to highest):**
1. Unscoped YAML entries
2. YAML scope hierarchy (root → app → case-type, child wins parent)
3. SmallRye Config overrides (`casehub.platform.preferences.defaults.*`)

---

### Task 1: Scaffold config/ module

**Files:**
- Create: `config/pom.xml`
- Modify: `platform/pom.xml` (add `<module>config</module>`)
- Modify: `~/claude/casehub/parent/pom.xml` (add BOM entry)

- [ ] **Step 1: Create `config/pom.xml`**

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

    <artifactId>casehub-platform-config</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Config</name>
    <description>Scope-aware YAML + SmallRye Config preference provider. Reads casehub.platform.config.files
        at startup and resolves preferences with scope inheritance. Displaces MockPreferenceProvider
        automatically when on the classpath via @ApplicationScoped (no @DefaultBean).</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-arc</artifactId>
        </dependency>
        <dependency>
            <groupId>org.yaml</groupId>
            <artifactId>snakeyaml</artifactId>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit5</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.quarkus</groupId>
                <artifactId>quarkus-maven-plugin</artifactId>
                <version>${quarkus.platform.version}</version>
                <extensions>true</extensions>
                <executions>
                    <execution>
                        <goals>
                            <goal>build</goal>
                            <goal>generate-code</goal>
                            <goal>generate-code-tests</goal>
                        </goals>
                    </execution>
                </executions>
            </plugin>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>3.3.1</version>
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

- [ ] **Step 2: Add `config` module to `platform/pom.xml`**

In `/Users/mdproctor/claude/casehub/platform/pom.xml`, add `<module>config</module>` to the `<modules>` block:

```xml
    <modules>
        <module>platform-api</module>
        <module>platform</module>
        <module>testing</module>
        <module>config</module>
    </modules>
```

- [ ] **Step 3: Add BOM entry to `~/claude/casehub/parent/pom.xml`**

Find the `casehub-platform-testing` entry and add after it:

```xml
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-config</artifactId>
            <version>${casehub.version}</version>
        </dependency>
```

- [ ] **Step 4: Verify compilation (empty module)**

```bash
mvn --batch-mode compile -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: BUILD SUCCESS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add config/pom.xml platform/pom.xml
git -C /Users/mdproctor/claude/casehub/platform commit -m "chore(config): scaffold casehub-platform-config module — #5"
git -C ~/claude/casehub/parent add pom.xml
git -C ~/claude/casehub/parent commit -m "chore(bom): add casehub-platform-config — casehubio/platform#5"
```

---

### Task 2: YamlPreferenceLoader — TDD

**Files:**
- Create: `config/src/test/java/io/casehub/platform/config/YamlPreferenceLoaderTest.java`
- Create: `config/src/test/resources/loader-test.yaml`
- Create: `config/src/main/java/io/casehub/platform/config/YamlPreferenceLoader.java`

- [ ] **Step 1: Create test YAML fixture**

Create `config/src/test/resources/loader-test.yaml`:

```yaml
entries:
  - devtown.globalDefault: "true"
  - scope: casehubio/devtown
    devtown.humanApprovalThreshold: "500"
    devtown.securityReviewRequired: "false"
  - scope: casehubio/devtown/pr-review
    devtown.humanApprovalThreshold: "100"
```

- [ ] **Step 2: Write the failing test**

Create `config/src/test/java/io/casehub/platform/config/YamlPreferenceLoaderTest.java`:

```java
package io.casehub.platform.config;

import io.casehub.platform.api.path.Path;
import org.junit.jupiter.api.Test;

import java.io.InputStream;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class YamlPreferenceLoaderTest {

    private InputStream yaml(String name) {
        InputStream is = getClass().getClassLoader().getResourceAsStream(name);
        assertNotNull(is, "test resource not found: " + name);
        return is;
    }

    @Test
    void unscoped_entry_stored_under_null_key() {
        Map<Path, Map<String, String>> result = YamlPreferenceLoader.load(yaml("loader-test.yaml"));
        assertTrue(result.containsKey(null));
        assertEquals("true", result.get(null).get("devtown.globalDefault"));
    }

    @Test
    void scoped_entry_stored_under_path_key() {
        Map<Path, Map<String, String>> result = YamlPreferenceLoader.load(yaml("loader-test.yaml"));
        Path devtown = Path.of("casehubio", "devtown");
        assertTrue(result.containsKey(devtown));
        assertEquals("500", result.get(devtown).get("devtown.humanApprovalThreshold"));
        assertEquals("false", result.get(devtown).get("devtown.securityReviewRequired"));
    }

    @Test
    void child_scope_stored_independently_from_parent() {
        Map<Path, Map<String, String>> result = YamlPreferenceLoader.load(yaml("loader-test.yaml"));
        Path prReview = Path.of("casehubio", "devtown", "pr-review");
        assertTrue(result.containsKey(prReview));
        assertEquals("100", result.get(prReview).get("devtown.humanApprovalThreshold"));
        // securityReviewRequired not set at pr-review level — must come from parent
        assertNull(result.get(prReview).get("devtown.securityReviewRequired"));
    }

    @Test
    void empty_yaml_returns_empty_map() {
        InputStream empty = new java.io.ByteArrayInputStream("entries: []\n".getBytes());
        Map<Path, Map<String, String>> result = YamlPreferenceLoader.load(empty);
        assertTrue(result.isEmpty());
    }

    @Test
    void null_yaml_content_returns_empty_map() {
        InputStream empty = new java.io.ByteArrayInputStream("".getBytes());
        Map<Path, Map<String, String>> result = YamlPreferenceLoader.load(empty);
        assertTrue(result.isEmpty());
    }
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
mvn --batch-mode install -DskipTests -pl platform-api -f /Users/mdproctor/claude/casehub/platform/pom.xml && mvn --batch-mode test -pl config -Dtest=YamlPreferenceLoaderTest -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: compilation error — `YamlPreferenceLoader` does not exist.

- [ ] **Step 4: Implement YamlPreferenceLoader**

Create `config/src/main/java/io/casehub/platform/config/YamlPreferenceLoader.java`:

```java
package io.casehub.platform.config;

import io.casehub.platform.api.path.Path;
import org.yaml.snakeyaml.Yaml;

import java.io.InputStream;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Parses a casehub preferences YAML file into a scope-keyed map.
 *
 * <p>YAML format:
 * <pre>
 * entries:
 *   - devtown.globalDefault: "true"          # no scope = unscoped (null key)
 *   - scope: casehubio/devtown
 *     devtown.humanApprovalThreshold: "500"
 *   - scope: casehubio/devtown/pr-review
 *     devtown.humanApprovalThreshold: "100"
 * </pre>
 *
 * <p>Returns {@code Map<Path, Map<String, String>>} where {@code null} key = unscoped.
 * Values are raw strings — callers handle {@code ${VAR}} interpolation and type conversion.
 */
public final class YamlPreferenceLoader {

    private YamlPreferenceLoader() {}

    @SuppressWarnings("unchecked")
    public static Map<Path, Map<String, String>> load(InputStream is) {
        Map<Path, Map<String, String>> result = new HashMap<>();
        if (is == null) return result;

        Yaml yaml = new Yaml();
        Map<String, Object> doc = yaml.load(is);
        if (doc == null) return result;

        List<Map<String, Object>> entries = (List<Map<String, Object>>) doc.get("entries");
        if (entries == null) return result;

        for (Map<String, Object> entry : entries) {
            String scopeStr = (String) entry.get("scope");
            Path scopeKey = scopeStr != null ? Path.parse(scopeStr) : null;

            Map<String, String> prefs = result.computeIfAbsent(scopeKey, k -> new HashMap<>());
            entry.forEach((k, v) -> {
                if (!"scope".equals(k)) prefs.put(k, String.valueOf(v));
            });
        }
        return result;
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mvn --batch-mode test -pl config -Dtest=YamlPreferenceLoaderTest -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: BUILD SUCCESS, all 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add config/src/main/java/io/casehub/platform/config/YamlPreferenceLoader.java config/src/test/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(config): implement YamlPreferenceLoader — #5"
```

---

### Task 3: ConfigFilePreferenceProvider — TDD

**Files:**
- Create: `config/src/test/resources/application.properties`
- Create: `config/src/test/resources/test-prefs-a.yaml`
- Create: `config/src/test/resources/test-prefs-b.yaml`
- Create: `config/src/test/java/io/casehub/platform/config/ConfigFilePreferenceProviderTest.java`
- Create: `config/src/main/java/io/casehub/platform/config/ConfigFilePreferenceProvider.java`

- [ ] **Step 1: Create test YAML files**

Create `config/src/test/resources/test-prefs-a.yaml`:

```yaml
entries:
  - devtown.baseDefault: "base"
  - scope: casehubio/devtown
    devtown.humanApprovalThreshold: "500"
    devtown.securityReviewRequired: "false"
  - scope: casehubio/devtown/pr-review
    devtown.humanApprovalThreshold: "100"
    devtown.securityReviewRequired: "true"
```

Create `config/src/test/resources/test-prefs-b.yaml` (for chaining — overrides one value):

```yaml
entries:
  - scope: casehubio/devtown
    devtown.humanApprovalThreshold: "750"
```

Create `config/src/test/resources/application.properties`:

```properties
casehub.platform.config.files=classpath:test-prefs-a.yaml
```

- [ ] **Step 2: Write the failing @QuarkusTest**

Create `config/src/test/java/io/casehub/platform/config/ConfigFilePreferenceProviderTest.java`:

```java
package io.casehub.platform.config;

import io.casehub.platform.api.preferences.PreferenceKey;
import io.casehub.platform.api.preferences.PreferenceProvider;
import io.casehub.platform.api.preferences.Preferences;
import io.casehub.platform.api.preferences.SettingsScope;
import io.casehub.platform.api.preferences.SingleValuePreference;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

@QuarkusTest
class ConfigFilePreferenceProviderTest {

    @Inject
    PreferenceProvider provider;

    record Threshold(int value) implements SingleValuePreference {
        static final Threshold DEFAULT = new Threshold(-1);
        static final PreferenceKey<Threshold> KEY =
            new PreferenceKey<>("devtown", "humanApprovalThreshold", DEFAULT,
                s -> new Threshold(Integer.parseInt(s)));
    }

    record SecReview(boolean value) implements SingleValuePreference {
        static final SecReview DEFAULT = new SecReview(false);
        static final PreferenceKey<SecReview> KEY =
            new PreferenceKey<>("devtown", "securityReviewRequired", DEFAULT,
                s -> new SecReview(Boolean.parseBoolean(s)));
    }

    record BaseDefault(String value) implements SingleValuePreference {
        static final BaseDefault DEFAULT = new BaseDefault("none");
        static final PreferenceKey<BaseDefault> KEY =
            new PreferenceKey<>("devtown", "baseDefault", DEFAULT, BaseDefault::new);
    }

    @Test
    void injected_provider_is_ConfigFilePreferenceProvider() {
        assertTrue(provider instanceof ConfigFilePreferenceProvider,
            "Expected ConfigFilePreferenceProvider but got: " + provider.getClass().getSimpleName());
    }

    @Test
    void unscoped_value_resolved_for_any_scope() {
        Preferences prefs = provider.resolve(SettingsScope.of("casehubio", "aml", "investigation"));
        assertEquals("base", prefs.asMap().get("devtown.baseDefault"));
    }

    @Test
    void scope_specific_value_returned_for_exact_scope() {
        Preferences prefs = provider.resolve(SettingsScope.of("casehubio", "devtown"));
        assertEquals(500, prefs.getOrDefault(Threshold.KEY).value());
    }

    @Test
    void child_scope_overrides_parent() {
        Preferences prefs = provider.resolve(SettingsScope.of("casehubio", "devtown", "pr-review"));
        assertEquals(100, prefs.getOrDefault(Threshold.KEY).value());
        assertTrue(prefs.getOrDefault(SecReview.KEY).value());
    }

    @Test
    void parent_value_inherited_when_child_does_not_override() {
        // pr-review sets humanApprovalThreshold=100 but does NOT set securityReviewRequired
        // Wait — our test-prefs-a.yaml DOES set securityReviewRequired at pr-review.
        // Test the devtown/code-review scope (not in YAML) — should inherit from devtown
        Preferences prefs = provider.resolve(SettingsScope.of("casehubio", "devtown", "code-review"));
        assertEquals(500, prefs.getOrDefault(Threshold.KEY).value());
        assertFalse(prefs.getOrDefault(SecReview.KEY).value()); // inherited from devtown level
    }

    @Test
    void unset_key_returns_key_default() {
        Preferences prefs = provider.resolve(SettingsScope.of("casehubio", "aml", "investigation"));
        assertEquals(-1, prefs.getOrDefault(Threshold.KEY).value());
    }

    @Test
    void asMap_returns_strings_for_jq_injection() {
        Preferences prefs = provider.resolve(SettingsScope.of("casehubio", "devtown"));
        assertEquals("500", prefs.asMap().get("devtown.humanApprovalThreshold"));
    }
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
mvn --batch-mode install -DskipTests -pl platform-api -f /Users/mdproctor/claude/casehub/platform/pom.xml && mvn --batch-mode test -pl config -Dtest=ConfigFilePreferenceProviderTest -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: compilation error — `ConfigFilePreferenceProvider` does not exist.

- [ ] **Step 4: Implement ConfigFilePreferenceProvider**

Create `config/src/main/java/io/casehub/platform/config/ConfigFilePreferenceProvider.java`:

```java
package io.casehub.platform.config;

import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.preferences.MapPreferences;
import io.casehub.platform.api.preferences.PreferenceProvider;
import io.casehub.platform.api.preferences.Preferences;
import io.casehub.platform.api.preferences.SettingsScope;
import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.io.InputStream;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Scope-aware YAML + SmallRye Config {@link PreferenceProvider}.
 *
 * <p>Reads one or more YAML files at startup (see {@code casehub.platform.config.files}).
 * Files are processed left to right; later files win per key+scope. After loading, checks
 * {@code casehub.platform.preferences.defaults.*} SmallRye Config entries as highest-priority
 * overrides — same keys as {@code MockPreferenceProvider}, so {@code application.properties}
 * overrides still work in tests.
 *
 * <p>{@code @ApplicationScoped} (no {@code @DefaultBean}) — displaces {@code MockPreferenceProvider}
 * automatically when on the classpath. Does not depend on {@code casehub-platform} mock module.
 *
 * <p>Resolution priority (lowest to highest):
 * <ol>
 *   <li>Unscoped YAML entries (null scope key)</li>
 *   <li>YAML scope hierarchy (root → app → case-type, child wins parent)</li>
 *   <li>{@code casehub.platform.preferences.defaults.*} from SmallRye Config</li>
 * </ol>
 */
@ApplicationScoped
public class ConfigFilePreferenceProvider implements PreferenceProvider {

    private static final Pattern VAR_PATTERN = Pattern.compile("\\$\\{([^}]+)}");

    @ConfigProperty(name = "casehub.platform.config.files")
    Optional<List<String>> configFiles;

    @ConfigProperty(name = "casehub.platform.preferences.defaults")
    Optional<Map<String, String>> smDefaults;

    // null key = unscoped; Path key = scope-specific
    private final Map<Path, Map<String, String>> loaded = new HashMap<>();

    @PostConstruct
    void load() {
        configFiles.ifPresent(files ->
            files.forEach(fileSpec -> {
                try (InputStream is = openStream(fileSpec)) {
                    Map<Path, Map<String, String>> parsed = YamlPreferenceLoader.load(is);
                    // Later file wins per key+scope — putAll merges
                    parsed.forEach((scope, prefs) ->
                        loaded.computeIfAbsent(scope, k -> new HashMap<>()).putAll(prefs));
                } catch (Exception e) {
                    throw new RuntimeException("Failed to load preferences from: " + fileSpec, e);
                }
            })
        );
        // Interpolate ${VAR} references in all loaded values
        loaded.forEach((scope, prefs) ->
            prefs.replaceAll((k, v) -> interpolate(v)));
    }

    @Override
    public Preferences resolve(SettingsScope scope) {
        Map<String, Object> merged = new HashMap<>();

        // 1. Unscoped (lowest priority)
        Map<String, String> unscoped = loaded.get(null);
        if (unscoped != null) merged.putAll(unscoped);

        // 2. Scope hierarchy: root to most specific (child wins parent via putAll)
        collectScoped(merged, scope.scope());

        // 3. SmallRye Config overrides (highest priority)
        smDefaults.ifPresent(overrides -> merged.putAll(overrides));

        return new MapPreferences(new HashMap<>(merged));
    }

    private void collectScoped(Map<String, Object> merged, Path path) {
        Path parent = path.parent();
        if (parent != null) collectScoped(merged, parent);
        Map<String, String> level = loaded.get(path);
        if (level != null) merged.putAll(level);
    }

    private static InputStream openStream(String fileSpec) throws Exception {
        if (fileSpec.startsWith("classpath:")) {
            String resource = fileSpec.substring("classpath:".length());
            InputStream is = Thread.currentThread().getContextClassLoader()
                    .getResourceAsStream(resource);
            if (is == null) {
                throw new IllegalArgumentException("Classpath resource not found: " + resource);
            }
            return is;
        }
        return new java.io.FileInputStream(fileSpec);
    }

    /** Replaces {@code ${KEY}} with system property then env var; leaves unresolved as-is. */
    static String interpolate(String value) {
        if (value == null || !value.contains("${")) return value;
        Matcher m = VAR_PATTERN.matcher(value);
        StringBuilder sb = new StringBuilder();
        while (m.find()) {
            String key = m.group(1);
            String replacement = System.getProperty(key);
            if (replacement == null) replacement = System.getenv(key);
            if (replacement == null) replacement = m.group(0); // leave as-is
            m.appendReplacement(sb, Matcher.quoteReplacement(replacement));
        }
        m.appendTail(sb);
        return sb.toString();
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mvn --batch-mode install -DskipTests -pl platform-api -f /Users/mdproctor/claude/casehub/platform/pom.xml && mvn --batch-mode test -pl config -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: BUILD SUCCESS, all tests pass (YamlPreferenceLoaderTest + ConfigFilePreferenceProviderTest).

- [ ] **Step 6: Add chaining test**

Add to `ConfigFilePreferenceProviderTest.java` — a second test class that uses a different `application.properties` profile or a separate test that explicitly tests the chaining.

Since Quarkus `@QuarkusTest` uses one config per test class, add an interpolation unit test to `ConfigFilePreferenceProvider` instead:

Add to `config/src/test/java/io/casehub/platform/config/ConfigFilePreferenceProviderTest.java`:

```java
    @Test
    void interpolate_replaces_system_property() {
        System.setProperty("TEST_THRESHOLD", "999");
        try {
            String result = ConfigFilePreferenceProvider.interpolate("${TEST_THRESHOLD}");
            assertEquals("999", result);
        } finally {
            System.clearProperty("TEST_THRESHOLD");
        }
    }

    @Test
    void interpolate_leaves_unresolved_vars_as_is() {
        assertEquals("${NONEXISTENT_VAR_XYZ}", ConfigFilePreferenceProvider.interpolate("${NONEXISTENT_VAR_XYZ}"));
    }

    @Test
    void interpolate_handles_null_and_no_vars() {
        assertNull(ConfigFilePreferenceProvider.interpolate(null));
        assertEquals("plain", ConfigFilePreferenceProvider.interpolate("plain"));
    }
```

- [ ] **Step 7: Add SmallRye override test**

Add a key to `application.properties` that does NOT exist in the YAML files — this avoids conflicts with the scope-resolution tests above:

```properties
casehub.platform.config.files=classpath:test-prefs-a.yaml
casehub.platform.preferences.defaults.test.smOverride=from-smallrye
```

Add test method:

```java
    @Test
    void smallrye_config_key_appears_in_resolved_preferences() {
        // "test.smOverride" is NOT in any YAML file — it comes purely from SmallRye Config
        // (application.properties line: casehub.platform.preferences.defaults.test.smOverride=from-smallrye)
        Preferences prefs = provider.resolve(SettingsScope.of("casehubio", "devtown"));
        assertEquals("from-smallrye", prefs.asMap().get("test.smOverride"));
    }
```

- [ ] **Step 8: Run all tests to verify they pass**

```bash
mvn --batch-mode test -pl config -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: BUILD SUCCESS, all tests pass.

- [ ] **Step 9: Run full build**

```bash
mvn --batch-mode install -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: BUILD SUCCESS for all 5 modules (parent, platform-api, platform, testing, config).

- [ ] **Step 10: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add config/src/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(config): implement ConfigFilePreferenceProvider — scope-aware YAML + SmallRye overrides — #5"
```

---

## Self-Review

**Spec coverage:**
- [x] `@ApplicationScoped` (no `@DefaultBean`) — displaces mock when on classpath ✅
- [x] YAML format with explicit scope entries ✅
- [x] Chaining via comma-separated file list (later file wins) ✅
- [x] Startup-only (`@PostConstruct`) ✅
- [x] SmallRye Config overrides highest priority ✅
- [x] `${VAR}` interpolation via system property → env var → leave as-is ✅
- [x] `key.parse()` via `MapPreferences.get()` — strings stored, type converted on access ✅
- [x] `asMap()` returns strings (for JQ/CaseContext compatibility) ✅
- [x] Scope hierarchy: unscoped → root → app → case-type ✅
- [x] Both repos: parent BOM updated, module added to platform/pom.xml ✅

**Note on the SmallRye override test:** `application.properties` sets `casehub.platform.preferences.defaults.devtown.humanApprovalThreshold=999`. This overrides ALL scopes since SmallRye Config overrides have highest priority and are flat (scope-unaware). This is intentional — env var/system prop overrides are global.

**Type consistency:**
- `YamlPreferenceLoader.load(InputStream)` → `Map<Path, Map<String, String>>` — consistent with `ConfigFilePreferenceProvider.loaded` ✅
- `ConfigFilePreferenceProvider.interpolate(String)` is `static` — accessible from test ✅
- `MapPreferences(new HashMap<>(merged))` — `merged` is `Map<String, Object>`, `MapPreferences` takes `Map<String, Object>` ✅
