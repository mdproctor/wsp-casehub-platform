---
layout: post
title: "The root that didn't cache"
date: 2026-05-22
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
---

A separate Claude session — running earlier today — added `Path.root()` for the
zero-segment root scope. The commit was solid: correct logic, clear motivation.
When I picked up the session I asked Claude to review it before we moved on.

Two things surfaced.

The first was missing tests. `Path.root()` introduces non-obvious edge cases:
does `root.isAncestorOf(root)` return true or false? What does `root.parent()`
return? What string does `root.value()` give back? These are the questions that
bite you when debugging a preferences resolution failure six months from now. We
added six tests pinning the contract: root is a strict ancestor of non-root paths
but not of itself, root's parent is null, depth is zero, value is the empty string.

The second was that `Path.root()` allocated a new instance on every call:

```java
public static Path root() {
    return new Path("", List.of());
}
```

Path is an immutable record. There's exactly one possible root. Every call was
creating a structurally identical object and throwing it away. The fix:

```java
private static final Path ROOT = new Path("", List.of());

public static Path root() {
    return ROOT;
}
```

One line added, one test to verify identity (`assertSame(Path.root(), Path.root())`),
done.

Neither finding was critical — the logic was correct throughout, and records use
structural equality so callers don't notice the difference. But `Path.root()` is
about to be called on every WorkItem that has no assigned scope. Caching it
costs nothing.

Built clean, installed to local m2, committed.
