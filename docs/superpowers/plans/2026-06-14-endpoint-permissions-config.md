# EndpointPermissions + endpoints-config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver platform#89 (`EndpointPermissions.assertTenant()`) and platform#88 (`casehub-platform-endpoints-config` YAML-backed endpoint registrar) as designed in the approved spec.

**Architecture:** Two deliverables on one branch. `EndpointPermissions` is a static utility in `platform-api`. `endpoints-config` is a new Quarkus module — `YamlEndpointLoader` (pure YAML extractor) + `EndpointConfigLoader` (@Startup @ApplicationScoped CDI populator) + three test classes. Spec: `docs/superpowers/specs/2026-06-12-endpoint-permissions-config-design.md`.

**Tech Stack:** Java 21, Quarkus 3.32.2, SnakeYAML, Quarkus ARC CDI, JUnit 5, AssertJ, MicroProfile Config

---

## File Map

**platform-api** (modified):
- Create: `platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointPermissions.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/endpoints/EndpointPermissionsTest.java`

**Parent pom** (modified):
- `pom.xml` — add `<module>endpoints-config</module>` after `endpoints-memory`

**endpoints-config** (new module):
- Create: `endpoints-config/pom.xml`
- Create: `endpoints-config/src/main/java/io/casehub/platform/endpoints/config/YamlEndpointLoader.java`
- Create: `endpoints-config/src/main/java/io/casehub/platform/endpoints/config/EndpointConfigLoader.java`
- Create: `endpoints-config/src/test/java/io/casehub/platform/endpoints/config/YamlEndpointLoaderTest.java`
- Create: `endpoints-config/src/test/java/io/casehub/platform/endpoints/config/EndpointDescriptorParserTest.java`
- Create: `endpoints-config/src/test/java/io/casehub/platform/endpoints/config/EndpointConfigLoaderTest.java`
- Create: `endpoints-config/src/test/resources/application.properties`
- Create: `endpoints-config/src/test/resources/test-endpoints.yaml`
- Create: `endpoints-config/src/test/resources/test-endpoints-global.yaml`
- Create: `endpoints-config/src/test/resources/test-endpoints-override.yaml`

**Docs** (modified):
- `CLAUDE.md` — add endpoints-config module table entry
- `ARC42STORIES.MD` — add C18 chapter entry, update L4 layer row, update C17 deferred list

---

### Task 1: EndpointPermissions (platform#89)

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointPermissions.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/endpoints/EndpointPermissionsTest.java`

- [ ] **Step 1: Write the failing tests**

```java
// platform-api/src/test/java/io/casehub/platform/api/endpoints/EndpointPermissionsTest.java
package io.casehub.platform.api.endpoints;

import io.casehub.platform.api.identity.CurrentPrincipal;
import org.junit.jupiter.api.Test;
import java.util.Set;
import static org.junit.jupiter.api.Assertions.*;

class EndpointPermissionsTest {

    private static CurrentPrincipal principal(String tenancyId) {
        return new CurrentPrincipal() {
            @Override public String actorId()             { return "actor"; }
            @Override public Set<String> groups()         { return Set.of(); }
            @Override public String tenancyId()           { return tenancyId; }
            @Override public boolean isCrossTenantAdmin() { return false; }
        };
    }

    @Test
    void matching_tenant_does_not_throw() {
        assertDoesNotThrow(() ->
            EndpointPermissions.assertTenant("tenant-a", principal("tenant-a")));
    }

    @Test
    void mismatched_tenant_throws_security_exception_with_both_ids() {
        SecurityException ex = assertThrows(SecurityException.class, () ->
            EndpointPermissions.assertTenant("tenant-b", principal("tenant-a")));
        assertTrue(ex.getMessage().contains("tenant-b"));
        assertTrue(ex.getMessage().contains("tenant-a"));
    }
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
mvn --batch-mode test -pl platform-api -Dtest=EndpointPermissionsTest 2>&1 | tail -5
```
Expected: `BUILD FAILURE` — class does not exist yet.

- [ ] **Step 3: Implement EndpointPermissions**

```java
// platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointPermissions.java
package io.casehub.platform.api.endpoints;

import io.casehub.platform.api.identity.CurrentPrincipal;

public final class EndpointPermissions {
    private EndpointPermissions() {}

    public static void assertTenant(String tenancyId, CurrentPrincipal principal) {
        if (!principal.tenancyId().equals(tenancyId))
            throw new SecurityException(
                "Tenant ID mismatch: claimed=" + tenancyId
                + ", authenticated=" + principal.tenancyId());
    }
}
```

- [ ] **Step 4: Run to confirm pass**

```bash
mvn --batch-mode test -pl platform-api -Dtest=EndpointPermissionsTest 2>&1 | tail -5
```
Expected: `BUILD SUCCESS`, `Tests run: 2, Failures: 0, Errors: 0`

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  platform-api/src/main/java/io/casehub/platform/api/endpoints/EndpointPermissions.java \
  platform-api/src/test/java/io/casehub/platform/api/endpoints/EndpointPermissionsTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#89): add EndpointPermissions.assertTenant() write-auth utility"
```

---

### Task 2: endpoints-config Module Skeleton

**Files:**
- Create: `endpoints-config/pom.xml`
- Modify: `pom.xml`
- Create skeleton Java files

**CDI augmentation note:** `EndpointConfigLoader` injects `@Inject EndpointRegistry registry`. The `quarkus-maven-plugin` with `build` goal runs CDI augmentation during `mvn install` (package phase). Without `NoOpEndpointRegistry @DefaultBean` on the compile/runtime classpath at that point, augmentation fails with `UnsatisfiedResolutionException`. The `casehub-platform` runtime dependency satisfies this. At test execution time, `InMemoryEndpointRegistry @Alternative @Priority(100)` (test scope) beats the no-op.

- [ ] **Step 1: Create pom.xml**

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

    <artifactId>casehub-platform-endpoints-config</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Endpoints Config</name>
    <description>@Startup @ApplicationScoped YAML-backed endpoint populator — reads
        casehub.platform.endpoints.files at startup, parses into EndpointDescriptor records,
        calls EndpointRegistry.register(). Populator, not a registry implementation.
        Multi-file: later files replace earlier files for same (path, tenancyId).
        No lifecycle reconciliation. Path separator read directly from
        casehub.platform.path.separator.</description>

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
        <!--
            runtime scope: NoOpEndpointRegistry @DefaultBean satisfies EndpointRegistry injection
            during quarkus:build augmentation (package phase). Without this, mvn install fails
            with UnsatisfiedResolutionException. At test time, InMemoryEndpointRegistry
            @Alternative @Priority(100) wins over the no-op.
        -->
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform</artifactId>
            <version>${project.version}</version>
            <scope>runtime</scope>
        </dependency>
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-junit5</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-endpoints-memory</artifactId>
            <version>${project.version}</version>
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

- [ ] **Step 2: Add module to parent pom.xml**

In `pom.xml`, find `<module>endpoints-memory</module>` and add immediately after:
```xml
        <module>endpoints-memory</module>
        <module>endpoints-config</module>
```

- [ ] **Step 3: Create YamlEndpointLoader skeleton**

```java
// endpoints-config/src/main/java/io/casehub/platform/endpoints/config/YamlEndpointLoader.java
package io.casehub.platform.endpoints.config;

import org.yaml.snakeyaml.Yaml;
import java.io.InputStream;
import java.util.List;
import java.util.Map;

public final class YamlEndpointLoader {
    private YamlEndpointLoader() {}

    @SuppressWarnings("unchecked")
    public static List<Map<String, Object>> load(InputStream is) {
        throw new UnsupportedOperationException("not yet implemented");
    }
}
```

- [ ] **Step 4: Create EndpointConfigLoader skeleton**

`endpointFiles` and `load()` have no `private` modifier — package-visible, required for test 11.

```java
// endpoints-config/src/main/java/io/casehub/platform/endpoints/config/EndpointConfigLoader.java
package io.casehub.platform.endpoints.config;

import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.path.PathParser;
import io.quarkus.runtime.Startup;
import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.io.InputStream;
import java.util.List;
import java.util.Map;
import java.util.Optional;

@Startup
@ApplicationScoped
public class EndpointConfigLoader {

    private static final Logger LOG = Logger.getLogger(EndpointConfigLoader.class);

    @Inject
    EndpointRegistry registry;

    @ConfigProperty(name = "casehub.platform.endpoints.files")
    Optional<List<String>> endpointFiles;

    @ConfigProperty(name = "casehub.platform.path.separator", defaultValue = "/")
    String pathSeparator;

    @PostConstruct
    void load() { throw new UnsupportedOperationException("not yet implemented"); }

    static EndpointDescriptor parseDescriptor(Map<String, Object> entry, PathParser parser) {
        throw new UnsupportedOperationException("not yet implemented");
    }

    static String interpolate(String value) {
        throw new UnsupportedOperationException("not yet implemented");
    }

    static InputStream openStream(String fileSpec) throws Exception {
        throw new UnsupportedOperationException("not yet implemented");
    }
}
```

- [ ] **Step 5: Create placeholder test resource (required for openStream classpath test in Task 4)**

```yaml
# endpoints-config/src/test/resources/test-endpoints.yaml
# placeholder — replaced with real content in Task 7
endpoints: []
```

- [ ] **Step 6: Verify compile**

```bash
mvn --batch-mode compile -pl endpoints-config -am 2>&1 | tail -5
```
Expected: `BUILD SUCCESS`

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  pom.xml \
  endpoints-config/pom.xml \
  endpoints-config/src/main/java/io/casehub/platform/endpoints/config/YamlEndpointLoader.java \
  endpoints-config/src/main/java/io/casehub/platform/endpoints/config/EndpointConfigLoader.java \
  endpoints-config/src/test/resources/test-endpoints.yaml
git -C /Users/mdproctor/claude/casehub/platform commit -m "chore(platform#88): scaffold endpoints-config module skeleton"
```

---

### Task 3: YamlEndpointLoader

**Files:**
- Modify: `endpoints-config/src/main/java/io/casehub/platform/endpoints/config/YamlEndpointLoader.java`
- Create: `endpoints-config/src/test/java/io/casehub/platform/endpoints/config/YamlEndpointLoaderTest.java`

- [ ] **Step 1: Write the failing tests**

```java
// endpoints-config/src/test/java/io/casehub/platform/endpoints/config/YamlEndpointLoaderTest.java
package io.casehub.platform.endpoints.config;

import org.junit.jupiter.api.Test;
import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import static org.assertj.core.api.Assertions.assertThat;

class YamlEndpointLoaderTest {

    private static InputStream yaml(String content) {
        return new ByteArrayInputStream(content.getBytes(StandardCharsets.UTF_8));
    }

    @Test
    void load_returns_raw_maps_for_valid_yaml() {
        InputStream is = yaml(
            "endpoints:\n" +
            "  - path: external/salesforce/prod\n" +
            "    tenancyId: tenant-a\n" +
            "    type: WORKER\n" +
            "    protocol: HTTP\n" +
            "    capabilities:\n" +
            "      - SEND\n");

        List<Map<String, Object>> result = YamlEndpointLoader.load(is);

        assertThat(result).hasSize(1);
        assertThat(result.get(0)).containsEntry("path", "external/salesforce/prod")
            .containsEntry("tenancyId", "tenant-a")
            .containsEntry("type", "WORKER")
            .containsEntry("capabilities", List.of("SEND"));
    }

    @Test
    void load_returns_empty_when_endpoints_key_absent() {
        assertThat(YamlEndpointLoader.load(yaml("other: value\n"))).isEmpty();
    }

    @Test
    void load_returns_empty_for_null_stream() {
        assertThat(YamlEndpointLoader.load(null)).isEmpty();
    }

    @Test
    void load_returns_empty_for_empty_endpoints_list() {
        // doc.get("endpoints") returns empty List, not null — distinct code path from absent key
        assertThat(YamlEndpointLoader.load(yaml("endpoints: []\n"))).isEmpty();
    }
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
mvn --batch-mode test -pl endpoints-config -am -Dtest=YamlEndpointLoaderTest 2>&1 | tail -5
```
Expected: `BUILD FAILURE` — `UnsupportedOperationException`

- [ ] **Step 3: Implement YamlEndpointLoader**

```java
// endpoints-config/src/main/java/io/casehub/platform/endpoints/config/YamlEndpointLoader.java
package io.casehub.platform.endpoints.config;

import org.yaml.snakeyaml.Yaml;
import java.io.InputStream;
import java.util.List;
import java.util.Map;

public final class YamlEndpointLoader {
    private YamlEndpointLoader() {}

    @SuppressWarnings("unchecked")
    public static List<Map<String, Object>> load(InputStream is) {
        if (is == null) return List.of();
        Yaml yaml = new Yaml();
        Map<String, Object> doc = yaml.load(is);
        if (doc == null) return List.of();
        List<Map<String, Object>> entries = (List<Map<String, Object>>) doc.get("endpoints");
        return entries != null ? entries : List.of();
    }
}
```

- [ ] **Step 4: Run to confirm pass**

```bash
mvn --batch-mode test -pl endpoints-config -am -Dtest=YamlEndpointLoaderTest 2>&1 | tail -5
```
Expected: `BUILD SUCCESS`, `Tests run: 4, Failures: 0, Errors: 0`

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  endpoints-config/src/main/java/io/casehub/platform/endpoints/config/YamlEndpointLoader.java \
  endpoints-config/src/test/java/io/casehub/platform/endpoints/config/YamlEndpointLoaderTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#88): implement YamlEndpointLoader"
```

---

### Task 4: EndpointConfigLoader — interpolate() and openStream()

**Files:**
- Modify: `endpoints-config/src/main/java/io/casehub/platform/endpoints/config/EndpointConfigLoader.java`
- Create: `endpoints-config/src/test/java/io/casehub/platform/endpoints/config/EndpointDescriptorParserTest.java`

- [ ] **Step 1: Write openStream tests (tests 1–3)**

```java
// endpoints-config/src/test/java/io/casehub/platform/endpoints/config/EndpointDescriptorParserTest.java
package io.casehub.platform.endpoints.config;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointType;
import io.casehub.platform.api.path.PathParser;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;

class EndpointDescriptorParserTest {

    @TempDir
    Path tempDir;

    // ── openStream (tests 1–3) ──────────────────────────────────────────────

    @Test
    void openStream_classpath_loads_existing_resource() throws Exception {
        // test-endpoints.yaml exists in src/test/resources (placeholder from Task 2)
        try (InputStream is = EndpointConfigLoader.openStream("classpath:test-endpoints.yaml")) {
            assertThat(is).isNotNull();
        }
    }

    @Test
    void openStream_filesystem_loads_temp_file() throws Exception {
        Path file = Files.writeString(tempDir.resolve("ep.yaml"), "endpoints: []\n");
        try (InputStream is = EndpointConfigLoader.openStream(file.toString())) {
            assertThat(is).isNotNull();
        }
    }

    @Test
    void openStream_missing_classpath_resource_throws_illegal_argument() {
        assertThatThrownBy(() -> EndpointConfigLoader.openStream("classpath:no-such-file.yaml"))
            .isInstanceOf(IllegalArgumentException.class)
            .hasMessageContaining("Classpath resource not found");
    }
}
```

- [ ] **Step 2: Run to confirm failure**

```bash
mvn --batch-mode test -pl endpoints-config -am -Dtest=EndpointDescriptorParserTest 2>&1 | tail -5
```
Expected: `BUILD FAILURE` — `UnsupportedOperationException` from `openStream()` skeleton.

- [ ] **Step 3: Implement interpolate() and openStream() in EndpointConfigLoader**

Replace the file entirely:

```java
// endpoints-config/src/main/java/io/casehub/platform/endpoints/config/EndpointConfigLoader.java
package io.casehub.platform.endpoints.config;

import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.path.PathParser;
import io.quarkus.runtime.Startup;
import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.io.FileInputStream;
import java.io.InputStream;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

@Startup
@ApplicationScoped
public class EndpointConfigLoader {

    private static final Logger LOG = Logger.getLogger(EndpointConfigLoader.class);
    private static final Pattern VAR_PATTERN   = Pattern.compile("\\$\\{([^}]+)}");
    private static final Pattern UNRESOLVED_VAR = Pattern.compile("\\$\\{[^}]+}");

    @Inject
    EndpointRegistry registry;

    @ConfigProperty(name = "casehub.platform.endpoints.files")
    Optional<List<String>> endpointFiles;

    @ConfigProperty(name = "casehub.platform.path.separator", defaultValue = "/")
    String pathSeparator;

    @PostConstruct
    void load() { throw new UnsupportedOperationException("not yet implemented"); }

    static EndpointDescriptor parseDescriptor(Map<String, Object> entry, PathParser parser) {
        throw new UnsupportedOperationException("not yet implemented");
    }

    static String interpolate(String value) {
        if (value == null || !value.contains("${")) return value;
        Matcher m = VAR_PATTERN.matcher(value);
        StringBuilder sb = new StringBuilder();
        while (m.find()) {
            String key = m.group(1);
            String replacement = System.getProperty(key);
            if (replacement == null) replacement = System.getenv(key);
            if (replacement == null) replacement = m.group(0);
            m.appendReplacement(sb, Matcher.quoteReplacement(replacement));
        }
        m.appendTail(sb);
        return sb.toString();
    }

    static InputStream openStream(String fileSpec) throws Exception {
        if (fileSpec.startsWith("classpath:")) {
            String resource = fileSpec.substring("classpath:".length());
            InputStream is = Thread.currentThread().getContextClassLoader()
                .getResourceAsStream(resource);
            if (is == null)
                throw new IllegalArgumentException("Classpath resource not found: " + resource);
            return is;
        }
        return new FileInputStream(fileSpec);
    }
}
```

- [ ] **Step 4: Run to confirm pass**

```bash
mvn --batch-mode test -pl endpoints-config -am -Dtest=EndpointDescriptorParserTest 2>&1 | tail -5
```
Expected: `Tests run: 3, Failures: 0, Errors: 0`, `BUILD SUCCESS`

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  endpoints-config/src/main/java/io/casehub/platform/endpoints/config/EndpointConfigLoader.java \
  endpoints-config/src/test/java/io/casehub/platform/endpoints/config/EndpointDescriptorParserTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#88): implement interpolate() and openStream()"
```

---

### Task 5: EndpointConfigLoader.parseDescriptor()

**Files:**
- Modify: `endpoints-config/src/main/java/io/casehub/platform/endpoints/config/EndpointConfigLoader.java`
- Modify: `endpoints-config/src/test/java/io/casehub/platform/endpoints/config/EndpointDescriptorParserTest.java`

- [ ] **Step 1: Add parseDescriptor tests (tests 4–10) to EndpointDescriptorParserTest**

Add these after the existing `openStream` tests (keep the class declaration intact):

```java
    // ── parseDescriptor (tests 4–10) ────────────────────────────────────────

    private static Map<String, Object> fullEntry() {
        Map<String, Object> entry = new LinkedHashMap<>();
        entry.put("path",         "external/salesforce/prod");
        entry.put("tenancyId",    "tenant-a");
        entry.put("type",         "WORKER");
        entry.put("protocol",     "HTTP");
        Map<String, Object> props = new LinkedHashMap<>();
        props.put("url", "https://salesforce.example.com/api");
        entry.put("properties",   props);
        entry.put("credentialRef","sf-bearer-token");
        entry.put("capabilities", List.of("SEND", "QUERY"));
        return entry;
    }

    @Test
    void parseDescriptor_all_fields_returns_correct_descriptor() {
        EndpointDescriptor d = EndpointConfigLoader.parseDescriptor(fullEntry(), PathParser.of("/"));

        assertThat(d.path().value()).isEqualTo("external/salesforce/prod");
        assertThat(d.tenancyId()).isEqualTo("tenant-a");
        assertThat(d.type()).isEqualTo(EndpointType.WORKER);
        assertThat(d.protocol()).isEqualTo(EndpointProtocol.HTTP);
        assertThat(d.properties()).isEqualTo(Map.of("url", "https://salesforce.example.com/api"));
        assertThat(d.credentialRef()).isEqualTo("sf-bearer-token");
        assertThat(d.capabilities()).containsExactlyInAnyOrder(
            EndpointCapability.SEND, EndpointCapability.QUERY);
    }

    @Test
    @SuppressWarnings("unchecked")
    void parseDescriptor_interpolates_system_property_in_properties_value() {
        System.setProperty("SALESFORCE_URL", "salesforce.example.com");
        try {
            Map<String, Object> entry = fullEntry();
            ((Map<String, Object>) entry.get("properties")).put("url", "https://${SALESFORCE_URL}/api");
            EndpointDescriptor d = EndpointConfigLoader.parseDescriptor(entry, PathParser.of("/"));
            assertThat(d.properties().get("url")).isEqualTo("https://salesforce.example.com/api");
        } finally {
            System.clearProperty("SALESFORCE_URL");
        }
    }

    @Test
    void parseDescriptor_unresolved_var_in_tenancyId_throws() {
        Map<String, Object> entry = fullEntry();
        entry.put("tenancyId", "${MISSING_TENANT}");
        assertThatThrownBy(() -> EndpointConfigLoader.parseDescriptor(entry, PathParser.of("/")))
            .isInstanceOf(RuntimeException.class)
            .hasMessageContaining("Unresolved variable in field 'tenancyId'");
    }

    @Test
    void parseDescriptor_missing_path_throws() {
        Map<String, Object> entry = fullEntry();
        entry.remove("path");
        assertThatThrownBy(() -> EndpointConfigLoader.parseDescriptor(entry, PathParser.of("/")))
            .isInstanceOf(RuntimeException.class)
            .hasMessageContaining("missing field: path");
    }

    @Test
    void parseDescriptor_unknown_type_throws_illegal_argument_directly() {
        // No outer catch here — IllegalArgumentException propagates from Enum.valueOf() uncaught
        Map<String, Object> entry = fullEntry();
        entry.put("type", "UNKNOWN_TYPE");
        assertThatThrownBy(() -> EndpointConfigLoader.parseDescriptor(entry, PathParser.of("/")))
            .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void parseDescriptor_missing_capabilities_key_throws() {
        Map<String, Object> entry = fullEntry();
        entry.remove("capabilities");
        assertThatThrownBy(() -> EndpointConfigLoader.parseDescriptor(entry, PathParser.of("/")))
            .isInstanceOf(RuntimeException.class)
            .hasMessageContaining("missing field: capabilities");
    }

    @Test
    void parseDescriptor_empty_capabilities_list_returns_empty_set() {
        Map<String, Object> entry = fullEntry();
        entry.put("capabilities", List.of());
        EndpointDescriptor d = EndpointConfigLoader.parseDescriptor(entry, PathParser.of("/"));
        assertThat(d.capabilities()).isEmpty();
    }
```

- [ ] **Step 2: Run to confirm failure**

```bash
mvn --batch-mode test -pl endpoints-config -am -Dtest=EndpointDescriptorParserTest 2>&1 | tail -5
```
Expected: `BUILD FAILURE` — `UnsupportedOperationException` from `parseDescriptor()` stub.

- [ ] **Step 3: Implement parseDescriptor() — replace EndpointConfigLoader.java entirely**

```java
// endpoints-config/src/main/java/io/casehub/platform/endpoints/config/EndpointConfigLoader.java
package io.casehub.platform.endpoints.config;

import io.casehub.platform.api.endpoints.EndpointCapability;
import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.endpoints.EndpointType;
import io.casehub.platform.api.path.Path;
import io.casehub.platform.api.path.PathParser;
import io.quarkus.runtime.Startup;
import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.io.FileInputStream;
import java.io.InputStream;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

@Startup
@ApplicationScoped
public class EndpointConfigLoader {

    private static final Logger LOG = Logger.getLogger(EndpointConfigLoader.class);
    private static final Pattern VAR_PATTERN    = Pattern.compile("\\$\\{([^}]+)}");
    private static final Pattern UNRESOLVED_VAR = Pattern.compile("\\$\\{[^}]+}");

    @Inject
    EndpointRegistry registry;

    @ConfigProperty(name = "casehub.platform.endpoints.files")
    Optional<List<String>> endpointFiles;

    @ConfigProperty(name = "casehub.platform.path.separator", defaultValue = "/")
    String pathSeparator;

    @PostConstruct
    void load() { throw new UnsupportedOperationException("not yet implemented"); }

    static EndpointDescriptor parseDescriptor(Map<String, Object> entry, PathParser parser) {
        String rawPath      = required(entry, "path");
        String rawTenancyId = required(entry, "tenancyId");
        String rawType      = required(entry, "type");
        String rawProtocol  = required(entry, "protocol");

        String path      = validateNoUnresolved(interpolate(rawPath),      "path");
        String tenancyId = validateNoUnresolved(interpolate(rawTenancyId), "tenancyId");

        String rawCredRef    = optionalStr(entry, "credentialRef");
        String credentialRef = rawCredRef != null
            ? validateNoUnresolved(interpolate(rawCredRef), "credentialRef")
            : null;

        Map<String, String> properties = Map.of();
        if (entry.containsKey("properties")) {
            @SuppressWarnings("unchecked")
            Map<String, Object> rawProps = (Map<String, Object>) entry.get("properties");
            if (rawProps != null) {
                Map<String, String> interpolated = new LinkedHashMap<>();
                for (Map.Entry<String, Object> prop : rawProps.entrySet()) {
                    String v = validateNoUnresolved(
                        interpolate(String.valueOf(prop.getValue())),
                        "properties." + prop.getKey());
                    interpolated.put(prop.getKey(), v);
                }
                properties = Map.copyOf(interpolated);
            }
        }

        if (!entry.containsKey("capabilities"))
            throw new RuntimeException("missing field: capabilities");
        @SuppressWarnings("unchecked")
        List<String> capStrings = (List<String>) entry.get("capabilities");
        Set<EndpointCapability> capabilities = capStrings == null ? Set.of() : capStrings.stream()
            .map(EndpointCapability::valueOf)
            .collect(Collectors.toUnmodifiableSet());

        return new EndpointDescriptor(
            Path.parse(path, parser),
            tenancyId,
            EndpointType.valueOf(rawType),
            EndpointProtocol.valueOf(rawProtocol),
            properties,
            credentialRef,
            capabilities);
    }

    static String interpolate(String value) {
        if (value == null || !value.contains("${")) return value;
        Matcher m = VAR_PATTERN.matcher(value);
        StringBuilder sb = new StringBuilder();
        while (m.find()) {
            String key = m.group(1);
            String replacement = System.getProperty(key);
            if (replacement == null) replacement = System.getenv(key);
            if (replacement == null) replacement = m.group(0);
            m.appendReplacement(sb, Matcher.quoteReplacement(replacement));
        }
        m.appendTail(sb);
        return sb.toString();
    }

    static InputStream openStream(String fileSpec) throws Exception {
        if (fileSpec.startsWith("classpath:")) {
            String resource = fileSpec.substring("classpath:".length());
            InputStream is = Thread.currentThread().getContextClassLoader()
                .getResourceAsStream(resource);
            if (is == null)
                throw new IllegalArgumentException("Classpath resource not found: " + resource);
            return is;
        }
        return new FileInputStream(fileSpec);
    }

    private static String required(Map<String, Object> entry, String field) {
        Object val = entry.get(field);
        if (val == null) throw new RuntimeException("missing field: " + field);
        return String.valueOf(val);
    }

    private static String optionalStr(Map<String, Object> entry, String field) {
        Object val = entry.get(field);
        return val != null ? String.valueOf(val) : null;
    }

    private static String validateNoUnresolved(String value, String field) {
        if (value != null && UNRESOLVED_VAR.matcher(value).find())
            throw new RuntimeException(
                "Unresolved variable in field '" + field + "': " + value);
        return value;
    }
}
```

- [ ] **Step 4: Run all EndpointDescriptorParserTest tests**

```bash
mvn --batch-mode test -pl endpoints-config -am -Dtest=EndpointDescriptorParserTest 2>&1 | tail -5
```
Expected: `Tests run: 10, Failures: 0, Errors: 0`, `BUILD SUCCESS`

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  endpoints-config/src/main/java/io/casehub/platform/endpoints/config/EndpointConfigLoader.java \
  endpoints-config/src/test/java/io/casehub/platform/endpoints/config/EndpointDescriptorParserTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#88): implement EndpointConfigLoader.parseDescriptor()"
```

---

### Task 6: EndpointConfigLoader.load() — no-op path and full implementation

**Files:**
- Modify: `endpoints-config/src/main/java/io/casehub/platform/endpoints/config/EndpointConfigLoader.java`
- Modify: `endpoints-config/src/test/java/io/casehub/platform/endpoints/config/EndpointDescriptorParserTest.java`

- [ ] **Step 1: Add no-op load test (test 11) to EndpointDescriptorParserTest**

Add after the `parseDescriptor` tests:

```java
    // ── load() no-op path (test 11) ─────────────────────────────────────────
    // Cannot test via @QuarkusTest: a failing @PostConstruct aborts the Quarkus
    // context before any test method runs. Tested here via direct invocation.
    // endpointFiles is package-visible (no private) — set directly after new().
    // load() is package-visible (no private) — called directly.

    @Test
    void load_noop_when_endpointFiles_absent() {
        EndpointConfigLoader loader = new EndpointConfigLoader();
        loader.endpointFiles = Optional.empty();
        // registry and pathSeparator remain null — ifPresent guard returns before touching them
        assertDoesNotThrow(loader::load);
    }
```

- [ ] **Step 2: Run to confirm failure**

```bash
mvn --batch-mode test -pl endpoints-config -am \
  -Dtest="EndpointDescriptorParserTest#load_noop_when_endpointFiles_absent" 2>&1 | tail -5
```
Expected: `BUILD FAILURE` — `UnsupportedOperationException` from `load()` stub.

- [ ] **Step 3: Implement load() — replace the stub body only**

In `EndpointConfigLoader.java`, replace `void load()` with:

```java
    @PostConstruct
    void load() {
        endpointFiles.ifPresent(files -> {
            PathParser parser = PathParser.of(pathSeparator);
            int count = 0;
            for (String fileSpec : files) {
                try (InputStream is = openStream(fileSpec)) {
                    List<Map<String, Object>> raw = YamlEndpointLoader.load(is);
                    for (Map<String, Object> entry : raw) {
                        registry.register(parseDescriptor(entry, parser));
                        count++;
                    }
                } catch (Exception e) {
                    throw new RuntimeException("Failed to load endpoints from: " + fileSpec, e);
                }
            }
            LOG.infof("Loaded %d endpoints into %s",
                count, registry.getClass().getSuperclass().getSimpleName());
        });
    }
```

- [ ] **Step 4: Run all EndpointDescriptorParserTest tests**

```bash
mvn --batch-mode test -pl endpoints-config -am -Dtest=EndpointDescriptorParserTest 2>&1 | tail -5
```
Expected: `Tests run: 11, Failures: 0, Errors: 0`, `BUILD SUCCESS`

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  endpoints-config/src/main/java/io/casehub/platform/endpoints/config/EndpointConfigLoader.java \
  endpoints-config/src/test/java/io/casehub/platform/endpoints/config/EndpointDescriptorParserTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#88): implement EndpointConfigLoader.load() with ifPresent guard"
```

---

### Task 7: EndpointConfigLoader CDI Integration Tests

**Files:**
- Replace: `endpoints-config/src/test/resources/test-endpoints.yaml`
- Create: `endpoints-config/src/test/resources/test-endpoints-global.yaml`
- Create: `endpoints-config/src/test/resources/test-endpoints-override.yaml`
- Create: `endpoints-config/src/test/resources/application.properties`
- Create: `endpoints-config/src/test/java/io/casehub/platform/endpoints/config/EndpointConfigLoaderTest.java`

**Test design:** All three YAML files load at context startup via `application.properties`. `test-endpoints-override.yaml` (loaded last) re-registers `(external/salesforce/prod, tenant-a)` with a different URL. Tests 1–3 use paths that are NOT in the override file. Test 4 verifies the override wins.

`assertInstanceOf(InMemoryEndpointRegistry.class, registry)` works because the CDI proxy IS-A `InMemoryEndpointRegistry` (proxy subclasses the bean). `registry.getClass()` would return the proxy class — do not use `getSimpleName()` equality for the CDI wiring assertion.

- [ ] **Step 1: Write test YAML resources**

```yaml
# endpoints-config/src/test/resources/test-endpoints.yaml
endpoints:
  - path: external/salesforce/prod
    tenancyId: tenant-a
    type: WORKER
    protocol: HTTP
    properties:
      url: https://salesforce-v1.example.com/api
    credentialRef: sf-bearer-token
    capabilities:
      - SEND
      - QUERY
  - path: casehubio/workers/crm
    tenancyId: tenant-b
    type: AGENT
    protocol: HTTP
    properties:
      url: https://crm.example.com
    capabilities:
      - SEND
```

```yaml
# endpoints-config/src/test/resources/test-endpoints-global.yaml
endpoints:
  - path: casehubio/platform/health
    tenancyId: platform
    type: SYSTEM
    protocol: HTTP
    properties:
      url: https://health.casehub.io/check
    capabilities:
      - QUERY
```

```yaml
# endpoints-config/src/test/resources/test-endpoints-override.yaml
endpoints:
  - path: external/salesforce/prod
    tenancyId: tenant-a
    type: WORKER
    protocol: HTTP
    properties:
      url: https://salesforce-v2.example.com/api
    capabilities:
      - SEND
```

- [ ] **Step 2: Write application.properties**

All YAML files must use only literal values — no `${VAR}` references. The Quarkus context starts before `@BeforeAll`, so unresolved variables would abort startup.

```properties
# endpoints-config/src/test/resources/application.properties
casehub.platform.endpoints.files=classpath:test-endpoints.yaml,classpath:test-endpoints-global.yaml,classpath:test-endpoints-override.yaml
```

- [ ] **Step 3: Write EndpointConfigLoaderTest**

```java
// endpoints-config/src/test/java/io/casehub/platform/endpoints/config/EndpointConfigLoaderTest.java
package io.casehub.platform.endpoints.config;

import io.casehub.platform.api.endpoints.EndpointDescriptor;
import io.casehub.platform.api.endpoints.EndpointProtocol;
import io.casehub.platform.api.endpoints.EndpointRegistry;
import io.casehub.platform.api.identity.TenancyConstants;
import io.casehub.platform.api.path.Path;
import io.casehub.platform.endpoints.memory.InMemoryEndpointRegistry;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;

@QuarkusTest
class EndpointConfigLoaderTest {

    @Inject
    EndpointRegistry registry;

    @Test
    void test1_yaml_endpoints_registered_and_cdi_wired() {
        // assertInstanceOf works because the CDI proxy IS-A InMemoryEndpointRegistry (subclass)
        // registry.getClass() returns the proxy — do NOT use getSimpleName() equality
        assertInstanceOf(InMemoryEndpointRegistry.class, registry);

        Optional<EndpointDescriptor> result = registry.resolve(
            Path.of("casehubio", "workers", "crm"), "tenant-b");
        assertThat(result).isPresent();
        assertThat(result.get().protocol()).isEqualTo(EndpointProtocol.HTTP);
        assertThat(result.get().properties().get("url")).isEqualTo("https://crm.example.com");
    }

    @Test
    void test2_platform_global_endpoint_visible_to_any_tenant() {
        Optional<EndpointDescriptor> result = registry.resolve(
            Path.of("casehubio", "platform", "health"), "tenant-a");
        assertThat(result).isPresent();
        assertThat(result.get().tenancyId()).isEqualTo(TenancyConstants.PLATFORM_TENANT_ID);
        assertThat(result.get().properties().get("url"))
            .isEqualTo("https://health.casehub.io/check");
    }

    @Test
    void test3_tenant_b_endpoint_invisible_to_tenant_a() {
        Optional<EndpointDescriptor> result = registry.resolve(
            Path.of("casehubio", "workers", "crm"), "tenant-a");
        assertThat(result).isEmpty();
    }

    @Test
    void test4_later_file_replaces_earlier_for_same_path_and_tenancy() {
        // external/salesforce/prod, tenant-a: in test-endpoints.yaml (v1) and
        // test-endpoints-override.yaml (v2, loaded last) — v2 must win
        Optional<EndpointDescriptor> result = registry.resolve(
            Path.of("external", "salesforce", "prod"), "tenant-a");
        assertThat(result).isPresent();
        assertThat(result.get().properties().get("url"))
            .isEqualTo("https://salesforce-v2.example.com/api");
    }
}
```

- [ ] **Step 4: Run EndpointConfigLoaderTest**

```bash
mvn --batch-mode test -pl endpoints-config -am -Dtest=EndpointConfigLoaderTest 2>&1 | tail -8
```
Expected: `Tests run: 4, Failures: 0, Errors: 0`, `BUILD SUCCESS`

- [ ] **Step 5: Run all endpoints-config tests**

```bash
mvn --batch-mode test -pl endpoints-config -am 2>&1 | tail -10
```
Expected: All three test classes pass — total 19 tests: `YamlEndpointLoaderTest` (4) + `EndpointDescriptorParserTest` (11) + `EndpointConfigLoaderTest` (4).

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add \
  endpoints-config/src/test/resources/test-endpoints.yaml \
  endpoints-config/src/test/resources/test-endpoints-global.yaml \
  endpoints-config/src/test/resources/test-endpoints-override.yaml \
  endpoints-config/src/test/resources/application.properties \
  endpoints-config/src/test/java/io/casehub/platform/endpoints/config/EndpointConfigLoaderTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "test(platform#88): add EndpointConfigLoaderTest @QuarkusTest CDI integration"
```

---

### Task 8: Documentation Updates

**Files:**
- Modify: `CLAUDE.md`
- Modify: `ARC42STORIES.MD`

- [ ] **Step 1: Update CLAUDE.md module table**

Find the `| \`endpoints-memory/\`` row in the Modules table and add immediately after:

```
| `endpoints-config/` | `casehub-platform-endpoints-config` | @Startup @ApplicationScoped YAML-backed endpoint populator — reads `casehub.platform.endpoints.files` at startup, parses into EndpointDescriptor records, calls EndpointRegistry.register(). Populator, not a registry implementation — populates whichever EndpointRegistry CDI selects. Requires a working registry backend (e.g. endpoints-memory) to be meaningful; silently registers into NoOpEndpointRegistry @DefaultBean otherwise (startup log reveals this). Multi-file: later files replace earlier files for same (path, tenancyId). No lifecycle reconciliation. Path separator read directly from casehub.platform.path.separator — no dependency on PathParserConfigurator. |
```

- [ ] **Step 2: Update ARC42STORIES.MD — L4 layer row**

Find:
```
| L4: Platform Extensions | `config/`, `oidc/`, `expression/` |
```
Replace with:
```
| L4: Platform Extensions | `config/`, `oidc/`, `expression/`, `endpoints-config/` |
```

- [ ] **Step 3: Update ARC42STORIES.MD — chapter index**

Find the chapter index row for C17 and add C18 immediately after:
```
| 17 | Endpoint Registry | J4 | L1, L2, L9 | ✅ |
| 18 | EndpointPermissions + endpoints-config | J4 | L1, L4 | ✅ |
```

- [ ] **Step 4: Update ARC42STORIES.MD — C17 deferred list**

Find in C17's text:
```
**Deferred:** JPA backend (`endpoints-jpa/`), config-backed multi-tenant registrar (`endpoints-config/` — platform#88), write authorization utility for runtime registration (platform#89)
```
Replace with:
```
**Deferred:** JPA backend (`endpoints-jpa/`). C18 delivers: `endpoints-config/` (platform#88), `EndpointPermissions` (platform#89).
```

- [ ] **Step 5: Add C18 chapter section after C17 in ARC42STORIES.MD**

After the C17 section's closing content, add:

```markdown
#### C18 — EndpointPermissions + endpoints-config

**Delivered:** 2026-06-14 | **Issues:** casehubio/platform#89, casehubio/platform#88

**What it is:** `EndpointPermissions` (L1) is a static write-auth utility mirroring `MemoryPermissions` — `assertTenant(String, CurrentPrincipal)` throws `SecurityException` on tenant mismatch; no 3-arg overload (no async endpoint-registration flow exists). `casehub-platform-endpoints-config` (L4) is a YAML-backed startup populator: `YamlEndpointLoader` (pure SnakeYAML extractor) + `EndpointConfigLoader @Startup @ApplicationScoped` (reads `casehub.platform.endpoints.files`, parses descriptors, calls `EndpointRegistry.register()`). Multi-tenant YAML; `${VAR}` interpolation; fail-fast on unresolved vars; multi-file last-write-wins ordering.

**Layer impact:**

| Layer | Change | Significance |
|-------|--------|--------------|
| L1: API Tier | `EndpointPermissions` in `io.casehub.platform.api.endpoints` | Low |
| L4: Platform Extensions | `endpoints-config/` new module — 2 classes, 3 test classes | Medium |
```

- [ ] **Step 6: Full build to confirm everything passes**

```bash
mvn --batch-mode install 2>&1 | tail -15
```
Expected: `BUILD SUCCESS` — all modules including the full CDI augmentation of `endpoints-config`.

- [ ] **Step 7: Commit docs**

```bash
git -C /Users/mdproctor/claude/casehub/platform add CLAUDE.md ARC42STORIES.MD
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs: update CLAUDE.md and ARC42STORIES.MD for platform#88+#89 (C18)"
```

---

## Self-Review

**Spec coverage:**

| Requirement | Task |
|---|---|
| `EndpointPermissions.assertTenant(String, CurrentPrincipal)` 2-arg only; error message format | 1 |
| 2 tests: match passes, mismatch throws with both IDs | 1 |
| `endpoints-config/pom.xml` with quarkus:build + jandex + casehub-platform runtime scope | 2 |
| `YamlEndpointLoader.load(InputStream)` → `List<Map<String,Object>>`; 4 tests | 3 |
| `openStream()` static package-visible; 3 tests | 4 |
| `interpolate()` static package-visible | 4 |
| `parseDescriptor(entry, parser)` static package-visible; 7 tests (4–10) | 5 |
| `endpointFiles` and `load()` package-visible (no private) | 6 |
| load() no-op test (test 11) via direct invocation | 6 |
| `ifPresent` guard; `getSuperclass().getSimpleName()` in LOG | 6 |
| Test YAML resources (no `${VAR}`); application.properties loads all 3 files | 7 |
| `assertInstanceOf(InMemoryEndpointRegistry.class, registry)` in test 1 | 7 |
| @QuarkusTest tests 1–4: CDI wiring, platform-global, tenant isolation, multi-file ordering | 7 |
| CLAUDE.md module entry | 8 |
| ARC42STORIES.MD L4 update, C18 chapter, C17 deferred update | 8 |

**Placeholder scan:** None. All steps include concrete code or exact commands.

**Type consistency:** `parseDescriptor(Map<String, Object>, PathParser)` used identically in Tasks 5, 6, and 7 tests. `openStream(String)` throws `Exception` consistently. `interpolate(String)` returns `String` consistently. `EndpointDescriptor` record constructor arg order matches spec and source throughout.
