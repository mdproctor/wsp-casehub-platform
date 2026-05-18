# casehub-platform-api SPIs and Platform Mocks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement all platform-api SPIs (Path, Preferences, Identity) and @DefaultBean Quarkus mock implementations, with full test coverage.

**Architecture:** Two-module structure. `platform-api/` is Tier 1 pure Java (zero dependencies) — interfaces, records, and one utility class. `platform/` is Tier 3 Quarkus — three @ApplicationScoped @DefaultBean mocks configurable via @ConfigProperty. Every commit references issue #1.

**Tech Stack:** Java 21 records and interfaces (platform-api), Quarkus Arc 3.32.2 with @DefaultBean/@ConfigProperty (platform), JUnit 5 (both modules), @QuarkusTest (platform/ only).

**Note:** casehub-parent BOM already includes both artifacts and the CI workflow already builds platform before ledger — no changes needed to those files.

---

## File Structure

```
platform-api/src/main/java/io/casehub/platform/api/
  path/
    Path.java                         record: value, segments; of(String), of(String...), parent(), isAncestorOf(), depth()
  preferences/
    Preference.java                   marker interface
    SingleValuePreference.java        extends Preference
    MultiValuePreference.java         extends Preference
    PreferenceKey.java                final class<T extends Preference>: namespace, name, qualifiedName()
    SettingsScope.java                record: scope(Path), effectiveAt(Instant); of(Path), of(String...)
    Preferences.java                  interface: get(key), get(key,subKey), asMap()
    PreferenceProvider.java           SPI interface: resolve(SettingsScope)
    MapPreferences.java               utility impl backed by Map<String,Object>
  identity/
    CurrentPrincipal.java             interface with default methods
    GroupMembershipProvider.java      interface

platform-api/src/test/java/io/casehub/platform/api/
  path/
    PathTest.java
  preferences/
    PreferenceKeyTest.java
    MapPreferencesTest.java
  identity/
    CurrentPrincipalSpiTest.java      anonymous-impl contract test per spi-default-method-contract-test protocol

platform/pom.xml                      add quarkus-maven-plugin + quarkus-junit5 test dep
platform/src/main/java/io/casehub/platform/mock/
  MockCurrentPrincipal.java           @ApplicationScoped @DefaultBean
  MockGroupMembershipProvider.java    @ApplicationScoped @DefaultBean
  MockPreferenceProvider.java         @ApplicationScoped @DefaultBean
platform/src/test/java/io/casehub/platform/mock/
  MockBeansTest.java                  @QuarkusTest
platform/src/test/resources/
  application.properties              test config defaults
```

---

### Task 1: Path — TDD

**Files:**
- Create: `platform-api/src/test/java/io/casehub/platform/api/path/PathTest.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/path/Path.java`

- [ ] **Step 1: Write the failing test**

Create `platform-api/src/test/java/io/casehub/platform/api/path/PathTest.java`:

```java
package io.casehub.platform.api.path;

import org.junit.jupiter.api.Test;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class PathTest {

    @Test
    void of_string_splits_on_slash() {
        Path p = Path.of("acme/backend/pr-review");
        assertEquals("acme/backend/pr-review", p.value());
        assertEquals(List.of("acme", "backend", "pr-review"), p.segments());
    }

    @Test
    void of_string_strips_outer_whitespace() {
        Path p = Path.of("  acme/backend  ");
        assertEquals("acme/backend", p.value());
    }

    @Test
    void of_string_single_segment() {
        Path p = Path.of("root");
        assertEquals("root", p.value());
        assertEquals(List.of("root"), p.segments());
    }

    @Test
    void of_string_throws_on_blank() {
        assertThrows(IllegalArgumentException.class, () -> Path.of(""));
        assertThrows(IllegalArgumentException.class, () -> Path.of("   "));
    }

    @Test
    void of_string_throws_on_leading_slash() {
        assertThrows(IllegalArgumentException.class, () -> Path.of("/acme/backend"));
    }

    @Test
    void of_string_throws_on_trailing_slash() {
        assertThrows(IllegalArgumentException.class, () -> Path.of("acme/backend/"));
    }

    @Test
    void of_string_throws_on_consecutive_slashes() {
        assertThrows(IllegalArgumentException.class, () -> Path.of("acme//backend"));
    }

    @Test
    void of_varargs_joins_with_slash() {
        Path p = Path.of("acme", "backend", "pr-review");
        assertEquals("acme/backend/pr-review", p.value());
        assertEquals(List.of("acme", "backend", "pr-review"), p.segments());
    }

    @Test
    void of_varargs_throws_on_empty_segment() {
        assertThrows(IllegalArgumentException.class, () -> Path.of("acme", "", "backend"));
    }

    @Test
    void of_varargs_throws_on_blank_segment() {
        assertThrows(IllegalArgumentException.class, () -> Path.of("acme", "  ", "backend"));
    }

    @Test
    void parent_returns_all_but_last_segment() {
        Path p = Path.of("acme/backend/pr-review");
        Path parent = p.parent();
        assertEquals("acme/backend", parent.value());
        assertEquals(List.of("acme", "backend"), parent.segments());
    }

    @Test
    void parent_returns_null_at_root() {
        assertNull(Path.of("root").parent());
    }

    @Test
    void depth_equals_segment_count() {
        assertEquals(3, Path.of("a/b/c").depth());
        assertEquals(1, Path.of("root").depth());
    }

    @Test
    void isAncestorOf_returns_true_for_prefix() {
        assertTrue(Path.of("acme/backend").isAncestorOf(Path.of("acme/backend/pr-review")));
    }

    @Test
    void isAncestorOf_returns_false_for_same_path() {
        Path p = Path.of("acme/backend");
        assertFalse(p.isAncestorOf(p));
    }

    @Test
    void isAncestorOf_returns_false_for_non_prefix() {
        assertFalse(Path.of("acme/backend").isAncestorOf(Path.of("acme/frontend")));
    }

    @Test
    void isAncestorOf_returns_false_when_other_is_shorter() {
        assertFalse(Path.of("acme/backend/pr-review").isAncestorOf(Path.of("acme/backend")));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mvn --batch-mode test -pl platform-api -Dtest=PathTest
```
Expected: compilation error — `Path` does not exist.

- [ ] **Step 3: Implement Path.java**

Create `platform-api/src/main/java/io/casehub/platform/api/path/Path.java`:

```java
package io.casehub.platform.api.path;

import java.util.List;
import java.util.Objects;

public record Path(String value, List<String> segments) {

    public static Path of(String value) {
        Objects.requireNonNull(value, "Path must not be null");
        String trimmed = value.strip();
        if (trimmed.isEmpty()) {
            throw new IllegalArgumentException("Path must not be blank");
        }
        String[] parts = trimmed.split("/", -1);
        for (String part : parts) {
            if (part.isBlank()) {
                throw new IllegalArgumentException(
                    "Path segments must not be empty — check for leading, trailing, or consecutive slashes: \"" + value + "\"");
            }
        }
        return new Path(trimmed, List.of(parts));
    }

    public static Path of(String... segments) {
        Objects.requireNonNull(segments, "segments must not be null");
        if (segments.length == 0) {
            throw new IllegalArgumentException("Path must have at least one segment");
        }
        for (String segment : segments) {
            Objects.requireNonNull(segment, "segment must not be null");
            if (segment.isBlank()) {
                throw new IllegalArgumentException(
                    "Path segments must not be blank: \"" + segment + "\"");
            }
        }
        String joined = String.join("/", segments);
        return new Path(joined, List.of(segments));
    }

    public Path parent() {
        if (segments.size() == 1) return null;
        List<String> parentSegments = segments.subList(0, segments.size() - 1);
        return new Path(String.join("/", parentSegments), List.copyOf(parentSegments));
    }

    public boolean isAncestorOf(Path other) {
        if (other.segments.size() <= this.segments.size()) return false;
        return other.segments.subList(0, this.segments.size()).equals(this.segments);
    }

    public int depth() {
        return segments.size();
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mvn --batch-mode test -pl platform-api -Dtest=PathTest
```
Expected: BUILD SUCCESS, all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/path/Path.java platform-api/src/test/java/io/casehub/platform/api/path/PathTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(path): implement Path record with strict validation — #1"
```

---

### Task 2: Preferences value types

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/Preference.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/SingleValuePreference.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/MultiValuePreference.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/PreferenceKey.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/SettingsScope.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/preferences/PreferenceKeyTest.java`

- [ ] **Step 1: Write failing test for PreferenceKey**

Create `platform-api/src/test/java/io/casehub/platform/api/preferences/PreferenceKeyTest.java`:

```java
package io.casehub.platform.api.preferences;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class PreferenceKeyTest {

    @Test
    void qualifiedName_joins_namespace_and_name_with_dot() {
        PreferenceKey<SingleValuePreference> key = new PreferenceKey<>("devtown", "humanApprovalThreshold");
        assertEquals("devtown", key.namespace());
        assertEquals("humanApprovalThreshold", key.name());
        assertEquals("devtown.humanApprovalThreshold", key.qualifiedName());
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
mvn --batch-mode test -pl platform-api -Dtest=PreferenceKeyTest
```
Expected: compilation error — types do not exist.

- [ ] **Step 3: Implement marker interfaces**

Create `platform-api/src/main/java/io/casehub/platform/api/preferences/Preference.java`:

```java
package io.casehub.platform.api.preferences;

public interface Preference {}
```

Create `platform-api/src/main/java/io/casehub/platform/api/preferences/SingleValuePreference.java`:

```java
package io.casehub.platform.api.preferences;

public interface SingleValuePreference extends Preference {}
```

Create `platform-api/src/main/java/io/casehub/platform/api/preferences/MultiValuePreference.java`:

```java
package io.casehub.platform.api.preferences;

public interface MultiValuePreference extends Preference {}
```

- [ ] **Step 4: Implement PreferenceKey**

Create `platform-api/src/main/java/io/casehub/platform/api/preferences/PreferenceKey.java`:

```java
package io.casehub.platform.api.preferences;

import java.util.Objects;

public final class PreferenceKey<T extends Preference> {
    private final String namespace;
    private final String name;

    public PreferenceKey(String namespace, String name) {
        this.namespace = Objects.requireNonNull(namespace, "namespace must not be null");
        this.name = Objects.requireNonNull(name, "name must not be null");
    }

    public String namespace() { return namespace; }
    public String name() { return name; }
    public String qualifiedName() { return namespace + "." + name; }
}
```

- [ ] **Step 5: Implement SettingsScope**

Create `platform-api/src/main/java/io/casehub/platform/api/preferences/SettingsScope.java`:

```java
package io.casehub.platform.api.preferences;

import io.casehub.platform.api.path.Path;
import java.time.Instant;
import java.util.Objects;

public record SettingsScope(Path scope, Instant effectiveAt) {

    public static SettingsScope of(Path scope) {
        Objects.requireNonNull(scope, "scope must not be null");
        return new SettingsScope(scope, Instant.now());
    }

    public static SettingsScope of(String... segments) {
        return new SettingsScope(Path.of(segments), Instant.now());
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

```bash
mvn --batch-mode test -pl platform-api -Dtest=PreferenceKeyTest
```
Expected: BUILD SUCCESS.

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/preferences/Preference.java platform-api/src/main/java/io/casehub/platform/api/preferences/SingleValuePreference.java platform-api/src/main/java/io/casehub/platform/api/preferences/MultiValuePreference.java platform-api/src/main/java/io/casehub/platform/api/preferences/PreferenceKey.java platform-api/src/main/java/io/casehub/platform/api/preferences/SettingsScope.java platform-api/src/test/java/io/casehub/platform/api/preferences/PreferenceKeyTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(preferences): implement Preference type hierarchy, PreferenceKey, SettingsScope — #1"
```

---

### Task 3: Preferences and PreferenceProvider SPI interfaces

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/Preferences.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/PreferenceProvider.java`

These are pure interfaces — compile-verified in Tasks 4 and 6.

- [ ] **Step 1: Implement Preferences interface**

Create `platform-api/src/main/java/io/casehub/platform/api/preferences/Preferences.java`:

```java
package io.casehub.platform.api.preferences;

import java.util.Map;

public interface Preferences {

    /**
     * Returns the preference for the given key, or {@code null} if not set.
     * Callers must fall back to the Preference record's {@code DEFAULT} constant:
     * <pre>
     *   HumanApprovalThreshold t = prefs.get(HumanApprovalThreshold.KEY);
     *   int value = t != null ? t.value() : HumanApprovalThreshold.DEFAULT.value();
     * </pre>
     */
    <T extends SingleValuePreference> T get(PreferenceKey<T> key);

    /**
     * Returns the multi-value preference for the given key and sub-key, or {@code null} if not set.
     */
    <T extends MultiValuePreference> T get(PreferenceKey<T> key, String subKey);

    /** Returns all values as a flat map, suitable for CaseContext/JQ injection. */
    Map<String, Object> asMap();
}
```

- [ ] **Step 2: Implement PreferenceProvider SPI**

Create `platform-api/src/main/java/io/casehub/platform/api/preferences/PreferenceProvider.java`:

```java
package io.casehub.platform.api.preferences;

public interface PreferenceProvider {

    /**
     * Resolves preferences for the given scope.
     * Implementations must apply parent-scope inheritance before returning —
     * if a key is not set at the exact scope, walk up {@code scope.scope().parent()}
     * until a value is found or the root is exhausted.
     */
    Preferences resolve(SettingsScope scope);
}
```

- [ ] **Step 3: Verify compilation**

```bash
mvn --batch-mode compile -pl platform-api
```
Expected: BUILD SUCCESS.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/preferences/Preferences.java platform-api/src/main/java/io/casehub/platform/api/preferences/PreferenceProvider.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(preferences): add Preferences interface and PreferenceProvider SPI — #1"
```

---

### Task 4: MapPreferences — TDD

**Files:**
- Create: `platform-api/src/test/java/io/casehub/platform/api/preferences/MapPreferencesTest.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/preferences/MapPreferences.java`

- [ ] **Step 1: Write the failing test**

Create `platform-api/src/test/java/io/casehub/platform/api/preferences/MapPreferencesTest.java`:

```java
package io.casehub.platform.api.preferences;

import org.junit.jupiter.api.Test;
import java.util.HashMap;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class MapPreferencesTest {

    record TestSinglePref(String value) implements SingleValuePreference {
        static final PreferenceKey<TestSinglePref> KEY = new PreferenceKey<>("test", "single");
    }

    record TestMultiPref(String subKey, String value) implements MultiValuePreference {
        static final PreferenceKey<TestMultiPref> KEY = new PreferenceKey<>("test", "multi");
    }

    @Test
    void get_returns_null_for_missing_key() {
        assertNull(new MapPreferences(Map.of()).get(TestSinglePref.KEY));
    }

    @Test
    void get_returns_typed_value_for_present_key() {
        TestSinglePref pref = new TestSinglePref("hello");
        MapPreferences prefs = new MapPreferences(Map.of("test.single", pref));
        assertEquals(pref, prefs.get(TestSinglePref.KEY));
    }

    @Test
    void get_with_subkey_returns_null_for_missing_key() {
        assertNull(new MapPreferences(Map.of()).get(TestMultiPref.KEY, "sub1"));
    }

    @Test
    void get_with_subkey_returns_typed_value() {
        TestMultiPref pref = new TestMultiPref("sub1", "val");
        MapPreferences prefs = new MapPreferences(Map.of("test.multi.sub1", pref));
        assertEquals(pref, prefs.get(TestMultiPref.KEY, "sub1"));
    }

    @Test
    void asMap_returns_all_values() {
        Map<String, Object> values = Map.of("test.single", "strVal");
        assertEquals(values, new MapPreferences(values).asMap());
    }

    @Test
    void asMap_is_unmodifiable() {
        MapPreferences prefs = new MapPreferences(new HashMap<>(Map.of("k", "v")));
        assertThrows(UnsupportedOperationException.class, () -> prefs.asMap().put("new", "value"));
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
mvn --batch-mode test -pl platform-api -Dtest=MapPreferencesTest
```
Expected: compilation error — `MapPreferences` does not exist.

- [ ] **Step 3: Implement MapPreferences**

Create `platform-api/src/main/java/io/casehub/platform/api/preferences/MapPreferences.java`:

```java
package io.casehub.platform.api.preferences;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.Objects;

public final class MapPreferences implements Preferences {

    private final Map<String, Object> values;

    public MapPreferences(Map<String, Object> values) {
        Objects.requireNonNull(values, "values must not be null");
        this.values = Collections.unmodifiableMap(new HashMap<>(values));
    }

    @Override
    @SuppressWarnings("unchecked")
    public <T extends SingleValuePreference> T get(PreferenceKey<T> key) {
        return (T) values.get(key.qualifiedName());
    }

    @Override
    @SuppressWarnings("unchecked")
    public <T extends MultiValuePreference> T get(PreferenceKey<T> key, String subKey) {
        return (T) values.get(key.qualifiedName() + "." + subKey);
    }

    @Override
    public Map<String, Object> asMap() {
        return values;
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mvn --batch-mode test -pl platform-api -Dtest=MapPreferencesTest
```
Expected: BUILD SUCCESS, all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/preferences/MapPreferences.java platform-api/src/test/java/io/casehub/platform/api/preferences/MapPreferencesTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(preferences): implement MapPreferences utility — #1"
```

---

### Task 5: CurrentPrincipal and GroupMembershipProvider — SPI contract tests

**Files:**
- Create: `platform-api/src/test/java/io/casehub/platform/api/identity/CurrentPrincipalSpiTest.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/identity/CurrentPrincipal.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/identity/GroupMembershipProvider.java`

- [ ] **Step 1: Write the failing test**

Per `spi-default-method-contract-test.md`: use an anonymous implementation providing only the two abstract methods. This proves the contract lives on the interface — if a default method were accidentally abstract, the anonymous class would fail to compile, which is the RED state.

Create `platform-api/src/test/java/io/casehub/platform/api/identity/CurrentPrincipalSpiTest.java`:

```java
package io.casehub.platform.api.identity;

import org.junit.jupiter.api.Test;
import java.util.Set;
import static org.junit.jupiter.api.Assertions.*;

class CurrentPrincipalSpiTest {

    private static CurrentPrincipal principal(String actorId, Set<String> groups) {
        return new CurrentPrincipal() {
            @Override public String actorId() { return actorId; }
            @Override public Set<String> groups() { return groups; }
        };
    }

    @Test
    void roles_delegates_to_groups() {
        assertEquals(Set.of("admin", "reviewer"),
            principal("alice", Set.of("admin", "reviewer")).roles());
    }

    @Test
    void hasGroup_returns_true_when_present() {
        assertTrue(principal("alice", Set.of("admin")).hasGroup("admin"));
    }

    @Test
    void hasGroup_returns_false_when_absent() {
        assertFalse(principal("alice", Set.of("admin")).hasGroup("reviewer"));
    }

    @Test
    void isSystem_returns_true_for_system_actorId() {
        assertTrue(principal("system", Set.of()).isSystem());
    }

    @Test
    void isSystem_returns_false_for_other_actorId() {
        assertFalse(principal("alice", Set.of()).isSystem());
    }

    @Test
    void isAuthenticated_returns_false_for_anonymous() {
        assertFalse(principal("anonymous", Set.of()).isAuthenticated());
    }

    @Test
    void isAuthenticated_returns_true_for_system() {
        assertTrue(principal("system", Set.of()).isAuthenticated());
    }

    @Test
    void isAuthenticated_returns_true_for_named_user() {
        assertTrue(principal("alice", Set.of()).isAuthenticated());
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
mvn --batch-mode test -pl platform-api -Dtest=CurrentPrincipalSpiTest
```
Expected: compilation error — `CurrentPrincipal` does not exist.

- [ ] **Step 3: Implement CurrentPrincipal**

Create `platform-api/src/main/java/io/casehub/platform/api/identity/CurrentPrincipal.java`:

```java
package io.casehub.platform.api.identity;

import java.util.Set;

/**
 * Identity of the currently active principal.
 *
 * <p>Real implementations must be {@code @RequestScoped}, backed by the active security
 * context (e.g. Quarkus {@code SecurityIdentity}). Injecting a {@code @RequestScoped}
 * implementation into an {@code @ApplicationScoped} REST resource is safe — CDI client
 * proxies delegate to the correct contextual instance per request.
 *
 * <p>The {@code @DefaultBean} mock ({@code MockCurrentPrincipal}) is intentionally
 * {@code @ApplicationScoped}: no request context exists in dev/test mode, and the mock
 * reads from {@code @ConfigProperty}. {@code @DefaultBean} yields to any non-default
 * bean regardless of scope.
 *
 * <p>⚠ Do not access {@code CurrentPrincipal} inside reactive pipelines ({@code Uni}/
 * {@code Multi}) without {@code @ActivateRequestContext} — {@code @RequestScoped}
 * implementations will throw {@code ContextNotActiveException} when the request context
 * is not active on the executing thread.
 *
 * <p>TODO: add {@code ActorType actorType()} once ActorType migrates from
 * casehub-ledger-api to casehub-platform-api (see casehubio/ledger migration issue).
 */
public interface CurrentPrincipal {

    String actorId();

    Set<String> groups();

    /**
     * Groups serve as roles by convention — wires directly to {@code @RolesAllowed}
     * without an interface change. Override to separate roles from group membership
     * once RBAC matures.
     */
    default Set<String> roles() { return groups(); }

    /**
     * Override in directory-backed implementations — iterating the full group set on
     * every call is wasteful in production.
     */
    default boolean hasGroup(String group) { return groups().contains(group); }

    default boolean isSystem() { return "system".equals(actorId()); }

    default boolean isAuthenticated() { return !"anonymous".equals(actorId()); }
}
```

- [ ] **Step 4: Implement GroupMembershipProvider**

Create `platform-api/src/main/java/io/casehub/platform/api/identity/GroupMembershipProvider.java`:

```java
package io.casehub.platform.api.identity;

import java.util.Set;

public interface GroupMembershipProvider {
    /** Returns member actor IDs for the given group. Empty set = unknown group. */
    Set<String> membersOf(String groupName);
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mvn --batch-mode test -pl platform-api -Dtest=CurrentPrincipalSpiTest
```
Expected: BUILD SUCCESS, all tests pass.

- [ ] **Step 6: Run all platform-api tests**

```bash
mvn --batch-mode test -pl platform-api
```
Expected: BUILD SUCCESS — PathTest, PreferenceKeyTest, MapPreferencesTest, CurrentPrincipalSpiTest all pass.

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/identity/ platform-api/src/test/java/io/casehub/platform/api/identity/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(identity): implement CurrentPrincipal SPI and GroupMembershipProvider — #1"
```

---

### Task 6: Platform module setup + mock implementations + @QuarkusTest

**Files:**
- Modify: `platform/pom.xml`
- Create: `platform/src/test/resources/application.properties`
- Create: `platform/src/test/java/io/casehub/platform/mock/MockBeansTest.java`
- Create: `platform/src/main/java/io/casehub/platform/mock/MockCurrentPrincipal.java`
- Create: `platform/src/main/java/io/casehub/platform/mock/MockGroupMembershipProvider.java`
- Create: `platform/src/main/java/io/casehub/platform/mock/MockPreferenceProvider.java`

- [ ] **Step 1: Add quarkus-maven-plugin and quarkus-junit5 to platform/pom.xml**

Replace `platform/pom.xml` with:

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

    <artifactId>casehub-platform</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform</name>
    <description>@DefaultBean mock implementations for casehub-platform-api SPIs.
        Quarkus CDI, configurable via @ConfigProperty. Displaced by real implementations in deployments.</description>

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
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Create test application.properties**

Create `platform/src/test/resources/application.properties`:

```properties
casehub.platform.principal.actorId=system
casehub.platform.principal.groups=
casehub.platform.preferences.defaults.test.greeting=hello
```

- [ ] **Step 3: Write the failing @QuarkusTest**

Create `platform/src/test/java/io/casehub/platform/mock/MockBeansTest.java`:

```java
package io.casehub.platform.mock;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.casehub.platform.api.identity.GroupMembershipProvider;
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
class MockBeansTest {

    @Inject CurrentPrincipal principal;
    @Inject GroupMembershipProvider groupMembership;
    @Inject PreferenceProvider preferenceProvider;

    @Test
    void currentPrincipal_defaults_to_system() {
        assertEquals("system", principal.actorId());
    }

    @Test
    void currentPrincipal_isSystem_true_by_default() {
        assertTrue(principal.isSystem());
    }

    @Test
    void currentPrincipal_isAuthenticated_true_by_default() {
        assertTrue(principal.isAuthenticated());
    }

    @Test
    void currentPrincipal_groups_empty_by_default() {
        assertTrue(principal.groups().isEmpty());
    }

    @Test
    void groupMembership_always_returns_empty_set() {
        assertTrue(groupMembership.membersOf("any-group").isEmpty());
        assertTrue(groupMembership.membersOf("admin").isEmpty());
    }

    @Test
    void preferenceProvider_resolve_returns_preferences() {
        assertNotNull(preferenceProvider.resolve(SettingsScope.of("acme/backend")));
    }

    @Test
    void preferenceProvider_asMap_contains_configured_value() {
        Preferences prefs = preferenceProvider.resolve(SettingsScope.of("acme/backend"));
        assertEquals("hello", prefs.asMap().get("test.greeting"));
    }

    @Test
    void preferenceProvider_typed_get_returns_null() {
        // Typed get() always returns null from MockPreferenceProvider.
        // Callers must fall back to the Preference record's DEFAULT constant.
        Preferences prefs = preferenceProvider.resolve(SettingsScope.of("acme/backend"));
        PreferenceKey<SingleValuePreference> key = new PreferenceKey<>("test", "greeting");
        assertNull(prefs.get(key));
    }
}
```

- [ ] **Step 4: Run to verify it fails**

```bash
mvn --batch-mode test -pl platform
```
Expected: compilation error — mock classes do not exist yet.

- [ ] **Step 5: Implement MockCurrentPrincipal**

Create `platform/src/main/java/io/casehub/platform/mock/MockCurrentPrincipal.java`:

```java
package io.casehub.platform.mock;

import io.casehub.platform.api.identity.CurrentPrincipal;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.util.List;
import java.util.Set;
import java.util.function.Predicate;
import java.util.stream.Collectors;

/**
 * @DefaultBean mock for dev/test. Reads actor identity from config.
 *
 * Note: intentionally @ApplicationScoped (not @RequestScoped). No request context
 * exists in dev/test mode. Real implementations must be @RequestScoped, backed by
 * the active Quarkus SecurityIdentity.
 *
 * To simulate unauthenticated: casehub.platform.principal.actorId=anonymous
 */
@ApplicationScoped
@DefaultBean
public class MockCurrentPrincipal implements CurrentPrincipal {

    @ConfigProperty(name = "casehub.platform.principal.actorId", defaultValue = "system")
    String actorId;

    @ConfigProperty(name = "casehub.platform.principal.groups", defaultValue = "")
    List<String> groups;

    @Override
    public String actorId() { return actorId; }

    @Override
    public Set<String> groups() {
        return groups.stream()
            .filter(Predicate.not(String::isBlank))
            .collect(Collectors.toUnmodifiableSet());
    }
}
```

- [ ] **Step 6: Implement MockGroupMembershipProvider**

Create `platform/src/main/java/io/casehub/platform/mock/MockGroupMembershipProvider.java`:

```java
package io.casehub.platform.mock;

import io.casehub.platform.api.identity.GroupMembershipProvider;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;

import java.util.Set;

/** @DefaultBean mock — always returns empty set. Tasks route to any available worker. */
@ApplicationScoped
@DefaultBean
public class MockGroupMembershipProvider implements GroupMembershipProvider {

    @Override
    public Set<String> membersOf(String groupName) {
        return Set.of();
    }
}
```

- [ ] **Step 7: Implement MockPreferenceProvider**

Create `platform/src/main/java/io/casehub/platform/mock/MockPreferenceProvider.java`:

```java
package io.casehub.platform.mock;

import io.casehub.platform.api.preferences.MapPreferences;
import io.casehub.platform.api.preferences.PreferenceProvider;
import io.casehub.platform.api.preferences.Preferences;
import io.casehub.platform.api.preferences.SettingsScope;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.util.HashMap;
import java.util.Map;

/**
 * @DefaultBean mock for dev/test.
 *
 * Typed {@code get()} always returns {@code null} — callers must fall back to the
 * Preference record's {@code DEFAULT} constant. This is by design: typed Preference
 * instances cannot be injected via SmallRye config.
 *
 * {@code asMap()} returns {@code String} values suitable for CaseContext/JQ injection.
 * Config keys match {@code PreferenceKey.qualifiedName()} (namespace.name), e.g.:
 *   casehub.platform.preferences.defaults.devtown.humanApprovalThreshold=500
 *
 * Ignores scope hierarchy — returns the same flat map for every {@code SettingsScope}.
 * Real implementations walk {@code scope.scope().segments()} applying inheritance per level.
 */
@ApplicationScoped
@DefaultBean
public class MockPreferenceProvider implements PreferenceProvider {

    @ConfigProperty(name = "casehub.platform.preferences.defaults")
    Map<String, String> defaults;

    @Override
    public Preferences resolve(SettingsScope scope) {
        Map<String, Object> objectMap = new HashMap<>();
        objectMap.putAll(defaults);
        return new MapPreferences(objectMap);
    }
}
```

- [ ] **Step 8: Run @QuarkusTest to verify it passes**

```bash
mvn --batch-mode test -pl platform
```
Expected: BUILD SUCCESS, all 8 @QuarkusTest tests pass.

- [ ] **Step 9: Run full build to verify both modules**

```bash
mvn --batch-mode install
```
Expected: BUILD SUCCESS for casehub-platform-parent, casehub-platform-api, casehub-platform.

- [ ] **Step 10: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/pom.xml platform/src/
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform): implement @DefaultBean mocks — MockCurrentPrincipal, MockGroupMembershipProvider, MockPreferenceProvider — #1"
```

---

### Task 7: Raise migration issues

Per issue #1 section 6 — raise issues only, do not modify the target repos.

- [ ] **Step 1: Raise issues in casehubio/work**

```bash
gh issue create --repo casehubio/work --title "migrate: LabelDefinition.path String -> casehub-platform-api Path" --body "casehubio/platform#1 ships io.casehub.platform.api.path.Path. LabelDefinition.path is currently a bare String — migrate to Path for type safety, hierarchy operations (isAncestorOf, parent, depth), and round-trip equality guarantees. Depends on casehub-platform-api being published."
```

```bash
gh issue create --repo casehubio/work --title "migrate: VocabularyScope enum — evaluate alignment with casehub-platform-api SettingsScope" --body "casehubio/platform#1 ships SettingsScope backed by Path for hierarchical scope resolution with parent-scope inheritance. Evaluate whether VocabularyScope can be unified with this model. Depends on casehub-platform-api being published."
```

- [ ] **Step 2: Raise issues in casehubio/ledger**

```bash
gh issue create --repo casehubio/ledger --title "migrate: ActorType enum to casehub-platform-api" --body "ActorType (HUMAN/AGENT/SYSTEM) is a cross-cutting identity concept. casehubio/platform#1 establishes casehub-platform-api as the home for foundational identity types. Migrating ActorType here unblocks adding ActorType actorType() to CurrentPrincipal (see TODO comment in casehubio/platform CurrentPrincipal interface). Depends on casehub-platform-api being published."
```

```bash
gh issue create --repo casehubio/ledger --title "migrate: ActorTypeResolver to casehub-platform-api" --body "Dependent on ActorType migration (raise that issue first). Move ActorTypeResolver alongside ActorType to casehub-platform-api once ActorType migrates."
```

```bash
gh issue create --repo casehubio/ledger --title "migrate: LedgerTraceIdProvider SPI — evaluate move to casehub-platform-api" --body "casehubio/platform#1 establishes platform-api as the home for cross-cutting domain-agnostic SPIs. Evaluate whether LedgerTraceIdProvider belongs in casehub-platform-api as a shared tracing integration SPI. Depends on casehub-platform-api being published."
```

- [ ] **Step 3: Raise issue in casehubio/engine**

```bash
gh issue create --repo casehubio/engine --title "migrate: PropagationContext to casehub-platform-api" --body "casehubio/platform#1 establishes casehub-platform-api as the home for cross-cutting domain-agnostic types. Evaluate whether PropagationContext belongs here for sharing across foundation repos without forcing an engine dependency. Depends on casehub-platform-api being published."
```

- [ ] **Step 4: Post migration issue links as comment on platform#1**

```bash
gh issue comment 1 --repo casehubio/platform --body "Migration issues raised per spec:
- casehubio/work: LabelDefinition.path migration, VocabularyScope review
- casehubio/ledger: ActorType migration, ActorTypeResolver migration, LedgerTraceIdProvider evaluation
- casehubio/engine: PropagationContext evaluation"
```

---

## Self-Review

**Spec coverage:**
- [x] Path with of(), parent(), isAncestorOf(), depth() — Task 1
- [x] SettingsScope record — Task 2
- [x] Preference, SingleValuePreference, MultiValuePreference — Task 2
- [x] PreferenceKey<T> with qualifiedName() — Task 2
- [x] Preferences — typed single + multi value get() — Task 3
- [x] PreferenceProvider SPI — Task 3
- [x] MapPreferences utility impl — Task 4
- [x] CurrentPrincipal with roles(), hasGroup(), isSystem(), isAuthenticated(), TODO comment — Task 5
- [x] GroupMembershipProvider — Task 5
- [x] MockCurrentPrincipal @DefaultBean — Task 6
- [x] MockGroupMembershipProvider @DefaultBean — Task 6
- [x] MockPreferenceProvider @DefaultBean — Task 6
- [x] BOM updated — already done (verified in parent pom.xml)
- [x] CI workflows updated — already done (verified in full-stack-build.yml)
- [x] Migration issues raised — Task 7

**Type consistency check:**
- `PreferenceKey.qualifiedName()` = `namespace + "." + name` → used in `MapPreferences.get()` as `key.qualifiedName()` ✅
- `MapPreferences` constructor takes `Map<String, Object>` → `MockPreferenceProvider` widens `Map<String, String>` via `putAll()` ✅
- `MockCurrentPrincipal.groups()` filters blank strings from List<String> → avoids SmallRye empty-string-as-list-element issue ✅
- `CurrentPrincipal` default methods tested via anonymous impl in `CurrentPrincipalSpiTest` ✅
