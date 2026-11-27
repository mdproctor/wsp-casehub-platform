# Atomic Template Namespace Update with Version Safety

**Issue:** casehubio/platform#972
**Epic:** #943
**Scale:** S | **Complexity:** Med

## Problem

Updating a template corpus on a channel with active commitments can break resolution. When a COMMAND is dispatched under corpus v1 and the DONE arrives after corpus v2 is deployed, the DONE content may not match v2's templates — even though the agent fulfilled its obligation correctly under v1.

The specific scenario: a qhorus channel with `protocol:review` corpus v1 opens a commitment via template match. Hours or days later, the corpus is updated to v2 (templates renamed, variable constraints changed, patterns restructured). The DONE response arrives and is evaluated against v2, which doesn't recognise the response format that was valid under v1. In BLOCKING enforcement, this means a valid DONE gets rejected — an infrastructure failure, not an agent failure.

Playbooks and generic consumers are not affected — they match and act in one pass with no long-lived state between match calls.

## Design

### Version Metadata on TemplateNamespace

Add a `version` field (monotonic `long`) to `TemplateNamespace`:

```java
public record TemplateNamespace(
    String name,
    Map<String, TemplateDefinition> templates,
    String language,
    long version
)
```

The two-arg and three-arg constructors use `version = 0` (unversioned). The registry assigns the actual version on registration — callers don't set it. Version 0 means "unversioned / not yet registered".

### Version Assignment in the Registry

`InMemoryTemplateRegistry` maintains a per-namespace version counter inside the `Snapshot`. On `replaceOrRegister()`:

1. Look up the current version for the namespace (0 if first registration)
2. Increment to get the new version
3. Create a new `TemplateNamespace` with the assigned version
4. Push the outgoing namespace into a bounded version ring (max N previous versions, default 3)
5. CAS-swap the snapshot atomically

On `register()` (first-time): assign version 1, no history entry.

On `deregister()`: the history ring for that namespace is preserved. A subsequent `register()` of the same name continues the version sequence.

### Version Ring in the Snapshot

The `Snapshot` inner class gains a `Map<String, List<VersionedEntry>>` field:

```java
record VersionedEntry(long version, TemplateNamespace namespace,
                      Map<String, List<CompiledTemplate>> compiled) {}
```

Each `VersionedEntry` captures the full state needed to match against a historical version — the namespace definition and its pre-compiled templates. The ring is bounded: on insert, entries beyond `maxRetainedVersions` are dropped (oldest first).

The ring is part of the immutable snapshot, so CAS preserves history atomically with the namespace swap. No separate data structure to coordinate.

### Version-Pinned Matching

Add a new `match` overload to `UnifiedTemplateRegistry`:

```java
TemplateMatch match(String namespaceName, String input, long version);
```

Behaviour:
- If `version` matches the current namespace version → match against current (normal path)
- If `version` differs → search the version ring for a matching entry. If found, match against that historical snapshot. If not found (version too old, evicted from ring), throw `NamespaceVersionNotFoundException`

The existing `match(namespace, input)` always matches against current and is unchanged.

### Version in Match Results

`TemplateMatch.Matched` gains a `version` field:

```java
record Matched(
    String namespace,
    String templateName,
    int patternIndex,
    Map<String, String> fields,
    double score,
    long version          // ← new
) implements TemplateMatch
```

The version is the namespace version that was active when the match was performed. Callers (qhorus commitment opening) store this in commitment metadata. At resolution time, they pass it to `match(namespace, input, version)` to ensure matching against the same corpus.

In the playbook `_tmatch` scope, `${_tmatch.version}` is exposed alongside the existing `namespace`, `template`, and `score` variables.

### No-Op for Unversioned Consumers

Consumers that don't use version-pinned matching are unaffected:
- `match(namespace, input)` works exactly as before, always matching current
- The version field in `TemplateMatch.Matched` is informational — callers that don't store it simply don't use it
- `replaceOrRegister()` still does atomic swap — the version ring is an internal implementation detail

### NamespaceVersionNotFoundException

New unchecked exception in `template-registry-api`:

```java
public class NamespaceVersionNotFoundException extends RuntimeException {
    private final String namespace;
    private final long requestedVersion;
    private final long currentVersion;
}
```

Thrown by `match(namespace, input, version)` when the requested version has been evicted from the ring. This is an infrastructure error (the commitment outlived the version retention window), not a matching failure.

### Configuration

`maxRetainedVersions` defaults to 3. Configurable via constructor parameter on `InMemoryTemplateRegistry`. Subclasses (`NlpTemplateRegistry`, `AdaptiveTemplateRegistry`) inherit the setting.

## Scope Boundary

**In scope:**
- Version metadata on `TemplateNamespace`
- Version ring in the `Snapshot` with bounded retention
- Version-pinned `match()` overload
- Version field in `TemplateMatch.Matched`
- `_tmatch.version` in playbook scope
- `NamespaceVersionNotFoundException`

**Out of scope:**
- Qhorus commitment code that stores and passes the version — that's a qhorus change, not a platform change. This issue provides the registry primitives; qhorus wires them.
- Version-aware `matchWithTrace` — trace is diagnostic, not enforcement. Can be added later if needed.
- Automatic eviction notifications — the ring silently drops old versions. If a consumer needs to know, they catch `NamespaceVersionNotFoundException`.

## References

- [casehubio/platform#972] — focal issue
- [casehubio/platform#943] — epic
- [casehubio/qhorus#543] — adversarial review that identified the gap
- [InMemoryTemplateRegistry.java] — existing Snapshot CAS pattern, replaceOrRegister
- [TemplateNamespace.java] — current record (no version field)
- [TemplateMatch.java] — current Matched record (no version field)
- [StructuralStepEvaluator.java:376-419] — _tmatch scope in playbook match steps
- [UnifiedTemplateRegistry.java] — SPI interface to extend with version-pinned match
