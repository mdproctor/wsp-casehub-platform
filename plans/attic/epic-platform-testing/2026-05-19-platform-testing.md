# casehub-platform-testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Also required:** superpowers:test-driven-development before writing any implementation code. java-dev for all Java. superpowers:requesting-code-review before committing.

**Goal:** Add a `testing/` module (`casehub-platform-testing`) providing `@Alternative @Priority(1)` test fixtures for identity SPIs — `FixedCurrentPrincipal` and `InMemoryGroupMembershipProvider`. Preference testing uses `MockPreferenceProvider` with `key.parse()` — no in-memory fixture needed.

**Architecture:** Single `testing/` module, pure Java with CDI API (provided). No Quarkus runtime dependency. Jandex index enables CDI bean discovery when consumed as a JAR. Each fixture is `@ApplicationScoped @Alternative @Priority(1)` with a `clear()` / `reset()` method for `@BeforeEach` isolation.

**Note:** `InMemoryPreferenceProvider` was removed during implementation — see spec for rationale.

**Tech Stack:** Java 21, CDI API (jakarta.enterprise.cdi-api provided), JUnit Jupiter, jandex-maven-plugin 3.3.1.

---

## File Structure

```
platform/testing/
  pom.xml
  src/main/java/io/casehub/platform/testing/
    FixedCurrentPrincipal.java
    InMemoryGroupMembershipProvider.java
  src/test/java/io/casehub/platform/testing/
    FixedCurrentPrincipalTest.java
    InMemoryGroupMembershipProviderTest.java

platform/pom.xml                           ← add <module>testing</module>
~/claude/casehub/parent/pom.xml            ← add casehub-platform-testing to BOM
```

---

### Task 1: Scaffold testing/ module

**Files:**
- Create: `platform/testing/pom.xml`
- Modify: `platform/pom.xml` (add module)
- Modify: `~/claude/casehub/parent/pom.xml` (add BOM entry)

- [ ] **Step 1: Create `platform/testing/pom.xml`**

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

    <artifactId>casehub-platform-testing</artifactId>
    <packaging>jar</packaging>
    <name>CaseHub Platform Testing</name>
    <description>In-memory @Alternative implementations of all platform SPIs for use in @QuarkusTest
        suites. No quarkus-arc dependency — activate by adding to test classpath; CDI selects
        automatically via @Alternative @Priority(1).</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
            <version>${project.version}</version>
        </dependency>
        <dependency>
            <groupId>jakarta.enterprise</groupId>
            <artifactId>jakarta.enterprise.cdi-api</artifactId>
            <scope>provided</scope>
        </dependency>
        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>io.smallrye</groupId>
                <artifactId>jandex-maven-plugin</artifactId>
                <version>3.3.1</version>
                <executions>
                    <execution>
                        <id>make-index</id>
                        <goals>
                            <goal>jandex</goal>
                        </goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
```

- [ ] **Step 2: Add `testing` module to `platform/pom.xml`**

In `platform/pom.xml`, change:
```xml
    <modules>
        <module>platform-api</module>
        <module>platform</module>
    </modules>
```
to:
```xml
    <modules>
        <module>platform-api</module>
        <module>platform</module>
        <module>testing</module>
    </modules>
```

- [ ] **Step 3: Add `casehub-platform-testing` to the BOM in `~/claude/casehub/parent/pom.xml`**

Find the existing `casehub-platform` entry (around line 60):
```xml
      <!-- casehub-platform — zero-dep foundational SPIs (publishes first) -->
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-api</artifactId>
        <version>${casehub.version}</version>
        ...
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform</artifactId>
        <version>${casehub.version}</version>
```

Add immediately after the `casehub-platform` entry:
```xml
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-testing</artifactId>
            <version>${casehub.version}</version>
        </dependency>
```

- [ ] **Step 4: Verify the module compiles (no sources yet — just POM)**

```bash
mvn --batch-mode compile -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: BUILD SUCCESS (empty module compiles fine).

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/testing/pom.xml platform/pom.xml
git -C /Users/mdproctor/claude/casehub/platform commit -m "chore(testing): scaffold casehub-platform-testing module — #4"
git -C /Users/mdproctor/claude/casehub/parent add pom.xml
git -C /Users/mdproctor/claude/casehub/parent commit -m "chore(bom): add casehub-platform-testing to dependencyManagement — casehubio/platform#4"
```

---

### Task 2: FixedCurrentPrincipal — TDD

**Files:**
- Create: `platform/testing/src/test/java/io/casehub/platform/testing/FixedCurrentPrincipalTest.java`
- Create: `platform/testing/src/main/java/io/casehub/platform/testing/FixedCurrentPrincipal.java`

- [ ] **Step 1: Write the failing test**

Create `platform/testing/src/test/java/io/casehub/platform/testing/FixedCurrentPrincipalTest.java`:

```java
package io.casehub.platform.testing;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class FixedCurrentPrincipalTest {

    private FixedCurrentPrincipal principal;

    @BeforeEach
    void setUp() {
        principal = new FixedCurrentPrincipal();
    }

    @Test
    void default_actorId_is_system() {
        assertEquals("system", principal.actorId());
    }

    @Test
    void default_groups_are_empty() {
        assertTrue(principal.groups().isEmpty());
    }

    @Test
    void default_isSystem_is_true() {
        assertTrue(principal.isSystem());
    }

    @Test
    void default_isAuthenticated_is_true() {
        assertTrue(principal.isAuthenticated());
    }

    @Test
    void setActorId_changes_actorId() {
        principal.setActorId("alice");
        assertEquals("alice", principal.actorId());
    }

    @Test
    void setActorId_to_anonymous_makes_isAuthenticated_false() {
        principal.setActorId("anonymous");
        assertFalse(principal.isAuthenticated());
        assertFalse(principal.isSystem());
    }

    @Test
    void setGroups_replaces_groups() {
        principal.setGroups(Set.of("admin", "reviewer"));
        assertEquals(Set.of("admin", "reviewer"), principal.groups());
    }

    @Test
    void addGroup_appends_to_groups() {
        principal.addGroup("admin");
        principal.addGroup("reviewer");
        assertTrue(principal.groups().contains("admin"));
        assertTrue(principal.groups().contains("reviewer"));
    }

    @Test
    void roles_delegates_to_groups() {
        principal.setGroups(Set.of("admin"));
        assertEquals(principal.groups(), principal.roles());
    }

    @Test
    void hasGroup_returns_true_when_present() {
        principal.addGroup("admin");
        assertTrue(principal.hasGroup("admin"));
    }

    @Test
    void hasGroup_returns_false_when_absent() {
        assertFalse(principal.hasGroup("admin"));
    }

    @Test
    void reset_restores_defaults() {
        principal.setActorId("alice");
        principal.addGroup("admin");
        principal.reset();
        assertEquals("system", principal.actorId());
        assertTrue(principal.groups().isEmpty());
        assertTrue(principal.isSystem());
    }

    @Test
    void groups_returns_unmodifiable_copy() {
        principal.addGroup("admin");
        assertThrows(UnsupportedOperationException.class,
                () -> principal.groups().add("hacker"));
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
mvn --batch-mode test -pl platform/testing -Dtest=FixedCurrentPrincipalTest -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: compilation error — `FixedCurrentPrincipal` does not exist.

- [ ] **Step 3: Implement FixedCurrentPrincipal**

Create `platform/testing/src/main/java/io/casehub/platform/testing/FixedCurrentPrincipal.java`:

```java
package io.casehub.platform.testing;

import io.casehub.platform.api.identity.CurrentPrincipal;
import jakarta.annotation.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Alternative;

import java.util.HashSet;
import java.util.Set;

/**
 * Configurable test implementation of {@link CurrentPrincipal}.
 *
 * <p>Defaults to {@code actorId="system"} with empty groups, matching
 * {@code MockCurrentPrincipal} defaults so switching providers has no surprises.
 *
 * <p>All four default methods ({@code roles()}, {@code hasGroup()}, {@code isSystem()},
 * {@code isAuthenticated()}) are inherited from the interface — nothing to override.
 *
 * <p><strong>Not thread-safe</strong> — designed for single-threaded test use only.
 * Call {@link #reset()} in a {@code @BeforeEach} method to isolate tests.
 */
@ApplicationScoped
@Alternative
@Priority(1)
public class FixedCurrentPrincipal implements CurrentPrincipal {

    private String actorId = "system";
    private Set<String> groups = new HashSet<>();

    public void setActorId(String actorId) {
        this.actorId = actorId;
    }

    public void setGroups(Set<String> groups) {
        this.groups = new HashSet<>(groups);
    }

    public void addGroup(String group) {
        this.groups.add(group);
    }

    /**
     * Resets to defaults: {@code actorId="system"}, groups empty.
     * Call in {@code @BeforeEach} to isolate tests.
     */
    public void reset() {
        actorId = "system";
        groups = new HashSet<>();
    }

    @Override
    public String actorId() {
        return actorId;
    }

    @Override
    public Set<String> groups() {
        return Set.copyOf(groups);
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mvn --batch-mode test -pl platform/testing -Dtest=FixedCurrentPrincipalTest -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: BUILD SUCCESS, all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/testing/src/main/java/io/casehub/platform/testing/FixedCurrentPrincipal.java platform/testing/src/test/java/io/casehub/platform/testing/FixedCurrentPrincipalTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(testing): implement FixedCurrentPrincipal — #4"
```

---

### Task 3: InMemoryGroupMembershipProvider — TDD

**Files:**
- Create: `platform/testing/src/test/java/io/casehub/platform/testing/InMemoryGroupMembershipProviderTest.java`
- Create: `platform/testing/src/main/java/io/casehub/platform/testing/InMemoryGroupMembershipProvider.java`

- [ ] **Step 1: Write the failing test**

Create `platform/testing/src/test/java/io/casehub/platform/testing/InMemoryGroupMembershipProviderTest.java`:

```java
package io.casehub.platform.testing;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class InMemoryGroupMembershipProviderTest {

    private InMemoryGroupMembershipProvider provider;

    @BeforeEach
    void setUp() {
        provider = new InMemoryGroupMembershipProvider();
    }

    @Test
    void unknown_group_returns_empty_set() {
        assertTrue(provider.membersOf("admin").isEmpty());
    }

    @Test
    void addMember_creates_group_implicitly() {
        provider.addMember("admin", "alice");
        assertTrue(provider.membersOf("admin").contains("alice"));
    }

    @Test
    void addMember_multiple_actors_to_same_group() {
        provider.addMember("admin", "alice");
        provider.addMember("admin", "bob");
        assertEquals(2, provider.membersOf("admin").size());
        assertTrue(provider.membersOf("admin").contains("alice"));
        assertTrue(provider.membersOf("admin").contains("bob"));
    }

    @Test
    void addMember_different_groups_are_independent() {
        provider.addMember("admin", "alice");
        provider.addMember("reviewer", "bob");
        assertFalse(provider.membersOf("admin").contains("bob"));
        assertFalse(provider.membersOf("reviewer").contains("alice"));
    }

    @Test
    void removeMember_removes_actor_from_group() {
        provider.addMember("admin", "alice");
        provider.addMember("admin", "bob");
        provider.removeMember("admin", "alice");
        assertFalse(provider.membersOf("admin").contains("alice"));
        assertTrue(provider.membersOf("admin").contains("bob"));
    }

    @Test
    void removeMember_from_unknown_group_is_silent() {
        assertDoesNotThrow(() -> provider.removeMember("admin", "alice"));
    }

    @Test
    void clear_removes_all_groups() {
        provider.addMember("admin", "alice");
        provider.addMember("reviewer", "bob");
        provider.clear();
        assertTrue(provider.membersOf("admin").isEmpty());
        assertTrue(provider.membersOf("reviewer").isEmpty());
    }

    @Test
    void membersOf_returns_unmodifiable_set() {
        provider.addMember("admin", "alice");
        assertThrows(UnsupportedOperationException.class,
                () -> provider.membersOf("admin").add("hacker"));
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
mvn --batch-mode test -pl platform/testing -Dtest=InMemoryGroupMembershipProviderTest -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: compilation error — `InMemoryGroupMembershipProvider` does not exist.

- [ ] **Step 3: Implement InMemoryGroupMembershipProvider**

Create `platform/testing/src/main/java/io/casehub/platform/testing/InMemoryGroupMembershipProvider.java`:

```java
package io.casehub.platform.testing;

import io.casehub.platform.api.identity.GroupMembershipProvider;
import jakarta.annotation.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Alternative;

import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 * In-memory implementation of {@link GroupMembershipProvider} for use in tests.
 *
 * <p>Groups are created implicitly on first {@link #addMember(String, String)}.
 * Unknown groups return an empty set, consistent with the SPI contract.
 *
 * <p><strong>Not thread-safe</strong> — designed for single-threaded test use only.
 * Call {@link #clear()} in a {@code @BeforeEach} method to isolate tests.
 */
@ApplicationScoped
@Alternative
@Priority(1)
public class InMemoryGroupMembershipProvider implements GroupMembershipProvider {

    private final Map<String, Set<String>> members = new HashMap<>();

    public void addMember(String groupName, String actorId) {
        members.computeIfAbsent(groupName, k -> new HashSet<>()).add(actorId);
    }

    public void removeMember(String groupName, String actorId) {
        Set<String> group = members.get(groupName);
        if (group != null) group.remove(actorId);
    }

    /**
     * Clears all group memberships. Call in {@code @BeforeEach} to isolate tests.
     */
    public void clear() {
        members.clear();
    }

    @Override
    public Set<String> membersOf(String groupName) {
        return Set.copyOf(members.getOrDefault(groupName, Set.of()));
    }
}
```

- [ ] **Step 4: Run all tests to verify they pass**

```bash
mvn --batch-mode install -DskipTests -pl platform-api -f /Users/mdproctor/claude/casehub/platform/pom.xml && mvn --batch-mode test -pl platform/testing -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: BUILD SUCCESS, all tests pass (InMemoryPreferenceProviderTest, FixedCurrentPrincipalTest, InMemoryGroupMembershipProviderTest).

- [ ] **Step 5: Run full build**

```bash
mvn --batch-mode install -f /Users/mdproctor/claude/casehub/platform/pom.xml
```
Expected: BUILD SUCCESS for all four modules.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/testing/src/main/java/io/casehub/platform/testing/InMemoryGroupMembershipProvider.java platform/testing/src/test/java/io/casehub/platform/testing/InMemoryGroupMembershipProviderTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(testing): implement InMemoryGroupMembershipProvider — #4"
```

---

## Self-Review

**Spec coverage:**
- [x] `testing/` module with correct folder name and artifactId — Task 1
- [x] POM: `casehub-platform-api` + `jakarta.enterprise.cdi-api` (provided) + `junit-jupiter` (test) + Jandex — Task 1
- [x] Parent POM module entry — Task 1
- [x] BOM entry in casehub-parent — Task 1
- [x] `FixedCurrentPrincipal` — defaults "system"/empty, setActorId/setGroups/addGroup/reset — Task 2
- [x] `InMemoryGroupMembershipProvider` — addMember/removeMember/clear/membersOf — Task 3
- [x] All fixtures: `@ApplicationScoped @Alternative @Priority(1)` — all tasks
- [x] Unmodifiable returns from groups() and membersOf() — Tasks 2 and 3
- [x] No quarkus-arc dependency — Task 1 POM
- [x] InMemoryPreferenceProvider removed — superseded by `key.parse()`

**Type consistency:**
- `SettingsScope.of(String...)` — correct factory used in tests ✅
- Groups/membersOf return unmodifiable sets ✅
- Default principal state: actorId="system", groups empty ✅
