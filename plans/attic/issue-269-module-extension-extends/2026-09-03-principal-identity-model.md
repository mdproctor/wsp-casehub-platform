# Principal Identity Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #271 — feat: Principal identity model — unified human + agent identity hierarchy
**Issue group:** #271

**Goal:** Introduce PrincipalId, ActorId, and ParticipantId value types in platform-api that give casehub consumers a typed identity hierarchy for ownership (Principal), execution (Actor), and interaction membership (Participant).

**Architecture:** Sealed interface `Identity` with three record permits — PrincipalId (foundational, wraps type:id string), ActorId (delegates to PrincipalId), ParticipantId (delegates to ActorId). All live in `io.casehub.platform.api.identity`. Reuses existing `ActorType` enum with two new methods. No SPI migration — types only.

**Tech Stack:** Java 21 records, sealed interfaces, JUnit 5

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only.
- Reuse `ActorType` enum — do not create `PrincipalType` (tracked in #272).
- Any new serialized form uses `principalType` as the field name (D8).
- `ActorTypeResolver` stays unchanged — backwards compatibility for legacy untyped strings.

---

## Batch 1: Identity type foundation

### Task 1: Add prefix() and fromPrefix() to ActorType

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/identity/ActorType.java`
- Modify: `platform-api/src/test/java/io/casehub/platform/api/identity/ActorTypeResolverTest.java` (add new tests at end)
- Create: `platform-api/src/test/java/io/casehub/platform/api/identity/ActorTypeTest.java`

**Interfaces:**
- Produces: `ActorType.prefix()` returning `String` (lowercase: "human", "agent", "system"), `ActorType.fromPrefix(String)` returning `ActorType` (case-insensitive, throws `IllegalArgumentException` for unknown prefix). Used by `PrincipalId.parse()` and `PrincipalId.value()` in Task 2.

- [ ] **Step 1: Write failing tests for prefix() and fromPrefix()**

```java
package io.casehub.platform.api.identity;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import static org.junit.jupiter.api.Assertions.*;

class ActorTypeTest {

    @Test
    void human_prefix_is_human() {
        assertEquals("human", ActorType.HUMAN.prefix());
    }

    @Test
    void agent_prefix_is_agent() {
        assertEquals("agent", ActorType.AGENT.prefix());
    }

    @Test
    void system_prefix_is_system() {
        assertEquals("system", ActorType.SYSTEM.prefix());
    }

    @Test
    void fromPrefix_resolves_lowercase() {
        assertEquals(ActorType.HUMAN, ActorType.fromPrefix("human"));
        assertEquals(ActorType.AGENT, ActorType.fromPrefix("agent"));
        assertEquals(ActorType.SYSTEM, ActorType.fromPrefix("system"));
    }

    @Test
    void fromPrefix_is_case_insensitive() {
        assertEquals(ActorType.HUMAN, ActorType.fromPrefix("HUMAN"));
        assertEquals(ActorType.AGENT, ActorType.fromPrefix("Agent"));
    }

    @Test
    void fromPrefix_rejects_unknown() {
        assertThrows(IllegalArgumentException.class, () -> ActorType.fromPrefix("robot"));
    }

    @ParameterizedTest
    @EnumSource(ActorType.class)
    void prefix_roundtrips_through_fromPrefix(ActorType type) {
        assertEquals(type, ActorType.fromPrefix(type.prefix()));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ActorTypeTest`
Expected: Compilation failure — `prefix()` and `fromPrefix()` do not exist.

- [ ] **Step 3: Implement prefix() and fromPrefix() on ActorType**

Replace the enum body with:

```java
package io.casehub.platform.api.identity;

import java.util.Locale;

/**
 * Classifies identities as human, agent, or system.
 *
 * <p>Planned rename to {@code PrincipalType} — see
 * <a href="https://github.com/casehubio/platform/issues/272">#272</a>.
 */
public enum ActorType {
    HUMAN,
    AGENT,
    SYSTEM;

    public String prefix() {
        return name().toLowerCase(Locale.ROOT);
    }

    public static ActorType fromPrefix(String prefix) {
        for (ActorType t : values()) {
            if (t.name().equalsIgnoreCase(prefix)) return t;
        }
        throw new IllegalArgumentException("Unknown principal type: " + prefix);
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ActorTypeTest`
Expected: All 7 tests PASS.

- [ ] **Step 5: Run full platform-api test suite for regressions**

Run: `mvn --batch-mode test -pl platform-api`
Expected: All tests PASS — existing ActorTypeResolverTest unchanged.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/identity/ActorType.java platform-api/src/test/java/io/casehub/platform/api/identity/ActorTypeTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#271): add prefix() and fromPrefix() to ActorType — identity type foundation"
```

---

### Task 2: Create Identity sealed interface and PrincipalId record

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/identity/Identity.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/identity/PrincipalId.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/identity/ActorId.java` (stub — permits needed for sealed interface)
- Create: `platform-api/src/main/java/io/casehub/platform/api/identity/ParticipantId.java` (stub — permits needed for sealed interface)
- Create: `platform-api/src/test/java/io/casehub/platform/api/identity/PrincipalIdTest.java`

**Interfaces:**
- Consumes: `ActorType.prefix()`, `ActorType.fromPrefix(String)` from Task 1
- Produces: `Identity` (sealed interface: `type()`, `id()`, `value()`), `PrincipalId` record (parse, human, agent, system factory methods, value(), toString()). Used by ActorId in Task 3.

- [ ] **Step 1: Write failing tests for PrincipalId**

```java
package io.casehub.platform.api.identity;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class PrincipalIdTest {

    @Test
    void parse_human_id() {
        PrincipalId p = PrincipalId.parse("human:john.smith");
        assertEquals(ActorType.HUMAN, p.type());
        assertEquals("john.smith", p.id());
        assertEquals("human:john.smith", p.value());
    }

    @Test
    void parse_agent_id_with_nested_colons() {
        PrincipalId p = PrincipalId.parse("agent:claude:analyst@v1");
        assertEquals(ActorType.AGENT, p.type());
        assertEquals("claude:analyst@v1", p.id());
        assertEquals("agent:claude:analyst@v1", p.value());
    }

    @Test
    void parse_system_id() {
        PrincipalId p = PrincipalId.parse("system:scheduler");
        assertEquals(ActorType.SYSTEM, p.type());
        assertEquals("scheduler", p.id());
    }

    @Test
    void parse_is_case_insensitive_on_type() {
        PrincipalId p = PrincipalId.parse("AGENT:worker");
        assertEquals(ActorType.AGENT, p.type());
        assertEquals("worker", p.id());
    }

    @Test
    void parse_rejects_missing_colon() {
        assertThrows(IllegalArgumentException.class, () -> PrincipalId.parse("nocolon"));
    }

    @Test
    void parse_rejects_unknown_type() {
        assertThrows(IllegalArgumentException.class, () -> PrincipalId.parse("robot:x"));
    }

    @Test
    void parse_rejects_blank_id() {
        assertThrows(IllegalArgumentException.class, () -> PrincipalId.parse("human:"));
    }

    @Test
    void parse_rejects_whitespace_id() {
        assertThrows(IllegalArgumentException.class, () -> PrincipalId.parse("human:   "));
    }

    @Test
    void constructor_rejects_null_type() {
        assertThrows(NullPointerException.class, () -> new PrincipalId(null, "id"));
    }

    @Test
    void constructor_rejects_null_id() {
        assertThrows(IllegalArgumentException.class, () -> new PrincipalId(ActorType.HUMAN, null));
    }

    @Test
    void factory_human() {
        PrincipalId p = PrincipalId.human("alice");
        assertEquals(ActorType.HUMAN, p.type());
        assertEquals("alice", p.id());
    }

    @Test
    void factory_agent() {
        PrincipalId p = PrincipalId.agent("claude");
        assertEquals(ActorType.AGENT, p.type());
        assertEquals("claude", p.id());
    }

    @Test
    void factory_system() {
        PrincipalId p = PrincipalId.system("scheduler");
        assertEquals(ActorType.SYSTEM, p.type());
        assertEquals("scheduler", p.id());
    }

    @Test
    void value_roundtrips_through_parse() {
        PrincipalId original = PrincipalId.agent("claude:analyst@v1");
        PrincipalId parsed = PrincipalId.parse(original.value());
        assertEquals(original, parsed);
    }

    @Test
    void toString_returns_value() {
        PrincipalId p = PrincipalId.human("alice");
        assertEquals("human:alice", p.toString());
    }

    @Test
    void equals_and_hashCode_from_record() {
        PrincipalId a = PrincipalId.human("alice");
        PrincipalId b = PrincipalId.human("alice");
        assertEquals(a, b);
        assertEquals(a.hashCode(), b.hashCode());
    }

    @Test
    void not_equal_different_type() {
        assertNotEquals(PrincipalId.human("x"), PrincipalId.agent("x"));
    }

    @Test
    void not_equal_different_id() {
        assertNotEquals(PrincipalId.human("alice"), PrincipalId.human("bob"));
    }

    @Test
    void implements_identity() {
        PrincipalId p = PrincipalId.human("alice");
        assertInstanceOf(Identity.class, p);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform-api -Dtest=PrincipalIdTest`
Expected: Compilation failure — `Identity`, `PrincipalId` do not exist.

- [ ] **Step 3: Create Identity sealed interface**

```java
package io.casehub.platform.api.identity;

/**
 * Sealed identity hierarchy — three levels of increasing context.
 *
 * <ul>
 *   <li>{@link PrincipalId} — stable identity for ownership, permissions, and accountability</li>
 *   <li>{@link ActorId} — a principal performing an action in a specific context</li>
 *   <li>{@link ParticipantId} — an actor involved in a multi-party interaction</li>
 * </ul>
 *
 * <p>All three share the {@code type:id} string format and are convertible
 * between levels via factory methods and accessors.
 */
public sealed interface Identity permits PrincipalId, ActorId, ParticipantId {

    ActorType type();

    String id();

    String value();
}
```

- [ ] **Step 4: Create PrincipalId record**

```java
package io.casehub.platform.api.identity;

import java.util.Objects;

public record PrincipalId(ActorType type, String id) implements Identity {

    public PrincipalId {
        Objects.requireNonNull(type, "type");
        if (id == null || id.isBlank()) {
            throw new IllegalArgumentException("id must not be blank");
        }
    }

    public static PrincipalId parse(String value) {
        Objects.requireNonNull(value, "value");
        int colon = value.indexOf(':');
        if (colon < 0) {
            throw new IllegalArgumentException(
                    "Invalid principal format — expected 'type:id', got: " + value);
        }
        ActorType type = ActorType.fromPrefix(value.substring(0, colon));
        String id = value.substring(colon + 1);
        return new PrincipalId(type, id);
    }

    public static PrincipalId human(String id) {
        return new PrincipalId(ActorType.HUMAN, id);
    }

    public static PrincipalId agent(String id) {
        return new PrincipalId(ActorType.AGENT, id);
    }

    public static PrincipalId system(String id) {
        return new PrincipalId(ActorType.SYSTEM, id);
    }

    @Override
    public String value() {
        return type.prefix() + ":" + id;
    }

    @Override
    public String toString() {
        return value();
    }
}
```

- [ ] **Step 5: Create ActorId stub (required for sealed permits)**

```java
package io.casehub.platform.api.identity;

import java.util.Objects;

public record ActorId(PrincipalId principalId) implements Identity {

    public ActorId {
        Objects.requireNonNull(principalId, "principalId");
    }

    @Override
    public ActorType type() { return principalId.type(); }

    @Override
    public String id() { return principalId.id(); }

    @Override
    public String value() { return principalId.value(); }

    @Override
    public String toString() { return value(); }
}
```

- [ ] **Step 6: Create ParticipantId stub (required for sealed permits)**

```java
package io.casehub.platform.api.identity;

import java.util.Objects;

public record ParticipantId(ActorId actorId) implements Identity {

    public ParticipantId {
        Objects.requireNonNull(actorId, "actorId");
    }

    @Override
    public ActorType type() { return actorId.type(); }

    @Override
    public String id() { return actorId.id(); }

    @Override
    public String value() { return actorId.value(); }

    @Override
    public String toString() { return value(); }
}
```

- [ ] **Step 7: Run PrincipalIdTest to verify all pass**

Run: `mvn --batch-mode test -pl platform-api -Dtest=PrincipalIdTest`
Expected: All 18 tests PASS.

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/identity/Identity.java platform-api/src/main/java/io/casehub/platform/api/identity/PrincipalId.java platform-api/src/main/java/io/casehub/platform/api/identity/ActorId.java platform-api/src/main/java/io/casehub/platform/api/identity/ParticipantId.java platform-api/src/test/java/io/casehub/platform/api/identity/PrincipalIdTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#271): add Identity sealed interface, PrincipalId record, ActorId and ParticipantId stubs"
```

---

### Task 3: Complete ActorId and ParticipantId with factory methods and tests

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/identity/ActorId.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/identity/ParticipantId.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/identity/ActorIdTest.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/identity/ParticipantIdTest.java`
- Create: `platform-api/src/test/java/io/casehub/platform/api/identity/IdentitySealedTest.java`

**Interfaces:**
- Consumes: `PrincipalId` record from Task 2
- Produces: `ActorId.of(PrincipalId)`, `ActorId.parse(String)`, `ParticipantId.of(ActorId)`, `ParticipantId.parse(String)`, `ParticipantId.principalId()` shorthand

- [ ] **Step 1: Write failing tests for ActorId**

```java
package io.casehub.platform.api.identity;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ActorIdTest {

    @Test
    void of_wraps_principal() {
        PrincipalId p = PrincipalId.human("alice");
        ActorId a = ActorId.of(p);
        assertSame(p, a.principalId());
    }

    @Test
    void parse_delegates_to_principalId() {
        ActorId a = ActorId.parse("agent:claude");
        assertEquals(ActorType.AGENT, a.type());
        assertEquals("claude", a.id());
        assertEquals("agent:claude", a.value());
    }

    @Test
    void type_delegates() {
        ActorId a = ActorId.of(PrincipalId.system("cron"));
        assertEquals(ActorType.SYSTEM, a.type());
    }

    @Test
    void id_delegates() {
        ActorId a = ActorId.of(PrincipalId.human("bob"));
        assertEquals("bob", a.id());
    }

    @Test
    void value_delegates() {
        ActorId a = ActorId.of(PrincipalId.agent("claude:analyst@v1"));
        assertEquals("agent:claude:analyst@v1", a.value());
    }

    @Test
    void toString_returns_value() {
        ActorId a = ActorId.of(PrincipalId.human("alice"));
        assertEquals("human:alice", a.toString());
    }

    @Test
    void constructor_rejects_null() {
        assertThrows(NullPointerException.class, () -> new ActorId(null));
    }

    @Test
    void implements_identity() {
        assertInstanceOf(Identity.class, ActorId.of(PrincipalId.human("x")));
    }

    @Test
    void equals_based_on_principal() {
        ActorId a = ActorId.of(PrincipalId.human("alice"));
        ActorId b = ActorId.of(PrincipalId.human("alice"));
        assertEquals(a, b);
        assertEquals(a.hashCode(), b.hashCode());
    }

    @Test
    void not_equal_to_different_principal() {
        assertNotEquals(
            ActorId.of(PrincipalId.human("alice")),
            ActorId.of(PrincipalId.human("bob")));
    }
}
```

- [ ] **Step 2: Write failing tests for ParticipantId**

```java
package io.casehub.platform.api.identity;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class ParticipantIdTest {

    @Test
    void of_wraps_actor() {
        ActorId a = ActorId.of(PrincipalId.human("alice"));
        ParticipantId p = ParticipantId.of(a);
        assertSame(a, p.actorId());
    }

    @Test
    void parse_delegates_through_chain() {
        ParticipantId p = ParticipantId.parse("agent:claude");
        assertEquals(ActorType.AGENT, p.type());
        assertEquals("claude", p.id());
        assertEquals("agent:claude", p.value());
    }

    @Test
    void principalId_shorthand() {
        PrincipalId principal = PrincipalId.human("alice");
        ParticipantId p = ParticipantId.of(ActorId.of(principal));
        assertSame(principal, p.principalId());
    }

    @Test
    void type_delegates() {
        ParticipantId p = ParticipantId.of(ActorId.of(PrincipalId.system("bot")));
        assertEquals(ActorType.SYSTEM, p.type());
    }

    @Test
    void value_delegates() {
        ParticipantId p = ParticipantId.of(ActorId.of(PrincipalId.agent("claude:analyst@v1")));
        assertEquals("agent:claude:analyst@v1", p.value());
    }

    @Test
    void toString_returns_value() {
        ParticipantId p = ParticipantId.of(ActorId.of(PrincipalId.human("alice")));
        assertEquals("human:alice", p.toString());
    }

    @Test
    void constructor_rejects_null() {
        assertThrows(NullPointerException.class, () -> new ParticipantId(null));
    }

    @Test
    void implements_identity() {
        assertInstanceOf(Identity.class,
            ParticipantId.of(ActorId.of(PrincipalId.human("x"))));
    }

    @Test
    void equals_based_on_actor() {
        ParticipantId a = ParticipantId.of(ActorId.of(PrincipalId.human("alice")));
        ParticipantId b = ParticipantId.of(ActorId.of(PrincipalId.human("alice")));
        assertEquals(a, b);
        assertEquals(a.hashCode(), b.hashCode());
    }
}
```

- [ ] **Step 3: Write exhaustive sealed switch test**

```java
package io.casehub.platform.api.identity;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class IdentitySealedTest {

    private String describe(Identity identity) {
        return switch (identity) {
            case PrincipalId p -> "principal:" + p.value();
            case ActorId a -> "actor:" + a.value();
            case ParticipantId p -> "participant:" + p.value();
        };
    }

    @Test
    void exhaustive_switch_covers_all_permits() {
        assertEquals("principal:human:alice",
            describe(PrincipalId.human("alice")));
        assertEquals("actor:agent:claude",
            describe(ActorId.of(PrincipalId.agent("claude"))));
        assertEquals("participant:system:bot",
            describe(ParticipantId.of(ActorId.of(PrincipalId.system("bot")))));
    }
}
```

- [ ] **Step 4: Add factory methods to ActorId**

Add `of()` and `parse()` static methods to the existing `ActorId.java`:

```java
    public static ActorId of(PrincipalId principal) {
        return new ActorId(principal);
    }

    public static ActorId parse(String value) {
        return new ActorId(PrincipalId.parse(value));
    }
```

- [ ] **Step 5: Add factory methods and principalId() shorthand to ParticipantId**

Add to the existing `ParticipantId.java`:

```java
    public static ParticipantId of(ActorId actor) {
        return new ParticipantId(actor);
    }

    public static ParticipantId parse(String value) {
        return new ParticipantId(ActorId.parse(value));
    }

    public PrincipalId principalId() {
        return actorId.principalId();
    }
```

- [ ] **Step 6: Run all new tests**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ActorIdTest,ParticipantIdTest,IdentitySealedTest`
Expected: All tests PASS.

- [ ] **Step 7: Run full platform-api test suite**

Run: `mvn --batch-mode test -pl platform-api`
Expected: All tests PASS — no regressions.

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/identity/ActorId.java platform-api/src/main/java/io/casehub/platform/api/identity/ParticipantId.java platform-api/src/test/java/io/casehub/platform/api/identity/ActorIdTest.java platform-api/src/test/java/io/casehub/platform/api/identity/ParticipantIdTest.java platform-api/src/test/java/io/casehub/platform/api/identity/IdentitySealedTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(#271): complete ActorId and ParticipantId with factory methods and tests"
```

---

## Batch 2: Documentation

### Task 4: Consumer guide identity section and glossary updates

**Files:**
- Modify: `docs/guides/consumer-guide.md` (add Identity Hierarchy section)
- Modify: `ARC42STORIES.MD` (add glossary entries in §13)

**Interfaces:**
- Consumes: All types from Tasks 1-3

- [ ] **Step 1: Read current consumer guide structure**

Use `ide_file_structure` on `docs/guides/consumer-guide.md` to find the right insertion point. The identity section should go near the top — after any overview/quickstart, before module-specific content.

- [ ] **Step 2: Add Identity Hierarchy section to consumer guide**

Insert after the overview/quickstart section:

```markdown
## Identity Hierarchy

casehub uses a three-level identity hierarchy. All levels share the `type:id`
string format (e.g., `human:john.smith`, `agent:claude:analyst@v1`, `system:scheduler`).

| Level | Type | Use when |
|-------|------|----------|
| **Principal** | `PrincipalId` | Ownership, permissions, ACLs, preferences, memory |
| **Actor** | `ActorId` | Execution context, audit logs, delegation, tool calls |
| **Participant** | `ParticipantId` | Multi-party interaction membership (sessions, conversations) |

**Rules of thumb:**

- Whose memory/preference/permission is this? → `PrincipalId`
- Who performed this action? Who is delegating? → `ActorId`
- Who is in this conversation/session? → `ParticipantId`
- Which tenant's data? → `tenancyId` (not an identity type — see below)

### Conversions

```java
// Down — adding context
ActorId actor = ActorId.of(principal);
ParticipantId participant = ParticipantId.of(actor);

// Up — extracting stable identity
PrincipalId principal = actorId.principalId();
PrincipalId principal = participantId.principalId(); // shorthand
```

### Creating identities

```java
PrincipalId alice = PrincipalId.human("alice");
PrincipalId claude = PrincipalId.agent("claude:analyst@v1");
PrincipalId cron = PrincipalId.system("scheduler");

// Or parse from a stored string
PrincipalId parsed = PrincipalId.parse("agent:claude");
```

### Tenancy is not identity

`tenancyId` answers "where" (which organisational boundary), not "who."
They are orthogonal:

- A `PrincipalId` exists within a tenant but is not scoped by it
- Never use `tenancyId` as an ownership key
- Never use `PrincipalId` as a tenant filter

### Migration from raw strings

Existing SPIs use `String actorId`, `String userId`, `String ownerId` — these
are all `PrincipalId` semantically. New code should use the typed identity
types. Existing SPI signatures will migrate in future issues.
```

- [ ] **Step 3: Read ARC42STORIES.MD §13 Glossary**

Use `ide_file_structure` on `ARC42STORIES.MD` to find the glossary section, then read it to determine insertion format and alphabetical position.

- [ ] **Step 4: Add glossary entries to §13**

Add in alphabetical order within the glossary:

```markdown
| **Actor** | A principal performing an action in a specific context. Use for execution attribution, audit, and delegation. Represented by `ActorId`. See §8 Identity Hierarchy. |
| **Identity** | Sealed interface unifying `PrincipalId`, `ActorId`, and `ParticipantId`. Use when the specific identity level doesn't matter. See §8 Identity Hierarchy. |
| **Participant** | An actor involved in a multi-party interaction (conversation, session, collaboration). Represented by `ParticipantId`. See §8 Identity Hierarchy. |
| **Principal** | A stable, long-lived identity (human, agent, or system). The universal foundation for ownership, authorization, and accountability. Represented by `PrincipalId`. See §8 Identity Hierarchy. |
```

- [ ] **Step 5: Run full build to verify no doc formatting issues**

Run: `mvn --batch-mode install -pl platform-api`
Expected: BUILD SUCCESS.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add docs/guides/consumer-guide.md ARC42STORIES.MD
git -C /Users/mdproctor/claude/casehub/platform commit -m "docs(#271): add identity hierarchy to consumer guide and glossary"
```

## References

- [2026-09-03-principal-identity-model-design.md] — design spec this plan implements
- [platform-api/.../identity/ActorType.java] — enum being extended
- [platform-api/.../identity/ActorTypeResolver.java] — legacy parser, unchanged
- [platform-api/.../identity/CurrentPrincipal.java] — existing identity SPI, not modified
- [docs/guides/consumer-guide.md] — consumer documentation being updated
- [ARC42STORIES.MD §13] — glossary being updated
- [GitHub #271] — focal issue
- [GitHub #272] — ActorType → PrincipalType rename (future)
- [GitHub #273] — CurrentPrincipal → CurrentActor rename (future)
