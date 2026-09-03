# Principal Identity Model — Design Spec

**Issue:** casehubio/platform#271
**Date:** 2026-09-03
**Status:** Draft

## Problem

casehub has no unified identity type. The concept of "who" is expressed as raw
`String` parameters with inconsistent names across SPIs:

| SPI | Parameter name | Semantic meaning |
|-----|---------------|-----------------|
| CurrentPrincipal | `actorId()` | Stable identity |
| AccessControlProvider | `actorId` | Permission ownership |
| NotificationStore | `userId` | Notification ownership |
| SubscriptionStore | `ownerId` | Subscription ownership |
| ActorStateContributor | `actorId` | State ownership |
| ActorDIDProvider | `actorId` | DID binding |

All are raw `String`. An `actorId` can be passed where a `tenancyId` is expected
and the compiler won't catch it. Consumer repos (qhorus, eidos, neocortex)
confuse identity ("who") with tenancy ("where") because there is no type-level
distinction.

Neocortex (casehubio/neocortex#269) is the immediate consumer — it needs to scope
memory, rules, and perspectives by identity, with a type that covers both humans
and agents.

## Identity Hierarchy

Three levels, each adding context. All share the `type:id` string format.

```
Principal (stable identity)
    │
    ├── owns: memory, preferences, permissions, cognitive profiles, rules
    │
    └── acts as → Actor (in execution context)
                      │
                      ├── audit, delegation, tool calls
                      │
                      └── participates in → Participant (in interaction)
                                                │
                                                └── session/conversation membership
```

**Rules of thumb:**

| Question | Use |
|----------|-----|
| Whose memory/preference/permission is this? | `PrincipalId` |
| Who performed this action? Who is delegating? | `ActorId` |
| Who is in this conversation/session? | `ParticipantId` |
| Which tenant's data? | `tenancyId` (not an identity type) |

## Tenancy Is Not Identity

`tenancyId` answers "where" — which organisational boundary the data belongs to.
Identity types answer "who." They are orthogonal:

- A `PrincipalId` exists within a tenant but is not scoped by it
- A principal can be cross-tenant admin (`CurrentPrincipal.isCrossTenantAdmin()`)
- Never use `tenancyId` as an ownership key
- Never use `PrincipalId` as a tenant filter

## Type Model

### Sealed hierarchy

All types live in `io.casehub.platform.api.identity`.

```java
public sealed interface Identity permits PrincipalId, ActorId, ParticipantId {
    ActorType type();     // HUMAN, AGENT, SYSTEM
    String id();          // identifier part after the colon
    String value();       // full "type:id" canonical string
}
```

`ActorType` is reused as-is (D6). Rename to `PrincipalType` tracked in #272.
Any new serialized form (YAML, JSON, config) uses `principalType` as the field
name from day one (D8).

### PrincipalId — stable identity

```java
public record PrincipalId(ActorType type, String id) implements Identity {

    public PrincipalId {
        Objects.requireNonNull(type, "type");
        if (id == null || id.isBlank()) {
            throw new IllegalArgumentException("id must not be blank");
        }
    }

    public static PrincipalId parse(String value) {
        // Split on first ':' — type prefix before, id after
        // Throws IllegalArgumentException if no ':' or unknown type
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

### ActorId — principal acting in context

```java
public record ActorId(PrincipalId principalId) implements Identity {

    public ActorId {
        Objects.requireNonNull(principalId, "principalId");
    }

    public static ActorId of(PrincipalId principal) {
        return new ActorId(principal);
    }

    public static ActorId parse(String value) {
        return new ActorId(PrincipalId.parse(value));
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

### ParticipantId — actor in an interaction

```java
public record ParticipantId(ActorId actorId) implements Identity {

    public ParticipantId {
        Objects.requireNonNull(actorId, "actorId");
    }

    public static ParticipantId of(ActorId actor) {
        return new ParticipantId(actor);
    }

    public static ParticipantId parse(String value) {
        return new ParticipantId(ActorId.parse(value));
    }

    public PrincipalId principalId() {
        return actorId.principalId();
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

### ActorType additions

Add `prefix()` and `fromPrefix()` to the existing `ActorType` enum:

```java
public enum ActorType {
    HUMAN,
    AGENT,
    SYSTEM;

    public String prefix() {
        return name().toLowerCase(Locale.ROOT);
    }

    public static ActorType fromPrefix(String prefix) {
        // Case-insensitive lookup
        for (ActorType t : values()) {
            if (t.name().equalsIgnoreCase(prefix)) return t;
        }
        throw new IllegalArgumentException("Unknown principal type: " + prefix);
    }
}
```

Add Javadoc noting the planned rename to `PrincipalType` in #272.

### ActorTypeResolver — backwards compatibility

`ActorTypeResolver` stays unchanged. It handles legacy untyped strings (bare
`userId` without prefix). New code uses `PrincipalId.parse()` which requires the
prefix. The two coexist:

- `PrincipalId.parse("agent:claude")` — new typed path, strict
- `ActorTypeResolver.resolve("some-legacy-id")` — legacy path, heuristic fallback

Migration from untyped to typed happens per SPI in future issues.

## String Format

**Canonical form:** `type:id` — lowercase type prefix, colon separator, id.

- `human:john.smith`
- `agent:claude:analyst@v1`
- `system:scheduler`

**Parsing rules:**

1. Split on first `:` — type prefix before, id after
2. No `:` present → `IllegalArgumentException` (no implicit defaults)
3. Type prefix must match a known `ActorType` (case-insensitive)
4. Id must be non-blank
5. Id may contain further colons — `agent:claude:analyst@v1` → type=AGENT, id=`claude:analyst@v1`

## Conversions

```
PrincipalId ──→ ActorId.of(principal) ──→ ParticipantId.of(actor)
PrincipalId ←── actorId.principalId() ←── participantId.actorId()
                                     └── participantId.principalId() (shorthand)
```

All three serialise to the same `type:id` string via `value()`. All three
parse from the same string format via their respective `parse()` methods.

## Scope Exclusions

The following are tracked as separate issues:

| Work | Issue | Rationale |
|------|-------|-----------|
| Rename `ActorType` → `PrincipalType` | #272 | Cross-repo IntelliJ refactor (slot) |
| Rename `CurrentPrincipal` → `CurrentActor` | #273 | Cross-repo refactor + tenancy separation |
| Migrate existing SPI signatures | TBD | Per-SPI, gradual — each SPI gets its own issue |

## Testing Strategy

- `PrincipalId`: parse valid formats, reject invalid (no colon, blank id, unknown type), factory methods, `value()` roundtrip, equals/hashCode (record)
- `ActorId`: construction from PrincipalId, parse, delegation of type/id/value
- `ParticipantId`: construction from ActorId, parse, delegation chain, `principalId()` shorthand
- `Identity` sealed: exhaustive switch over all three permits
- `ActorType.prefix()` and `fromPrefix()`: all three values, case insensitivity, unknown prefix rejection

## Documentation Updates

### Consumer guide (`docs/guides/consumer-guide.md`)

New section "Identity Hierarchy" covering:
- The three levels and when to use each
- String format
- Conversions
- Tenancy vs identity distinction
- Migration guidance for existing raw-string APIs

### ARC42STORIES.MD §13 Glossary

New entries: Principal, Actor, Participant, Identity (sealed interface).

## References

- casehubio/platform#271 — this issue
- casehubio/neocortex#269 — immediate consumer (rule scoping)
- casehubio/platform#272 — ActorType → PrincipalType rename (future)
- casehubio/platform#273 — CurrentPrincipal → CurrentActor rename (future)
- `platform-api/.../identity/CurrentPrincipal.java` — existing identity SPI
- `platform-api/.../identity/ActorType.java` — reused enum
- `platform-api/.../identity/ActorTypeResolver.java` — legacy parser, unchanged
