---
layout: post
title: "The Cascade That Couldn't See Its Own Children"
date: 2026-10-12
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [registry, cascade, concurrency, inmemory]
---

# The Cascade That Couldn't See Its Own Children

The InMemory registry's cascade deregister had a stale data bug — when A owns B owns C and you deregister A, the cascade correctly removed B and C from the entries map, but left B→C sitting in the relationships list as a ghost. The JPA implementation cleaned these up; the InMemory one didn't.

The obvious fix was wrong. My first instinct was to add relationship cleanup inside the cascade mutator — the same place the JPA version does it. Remove the entry, remove its relationships. Symmetrical and clean.

It broke recursive cascading. The `CascadeEngine` calls `mutator.deregister(B)` and *then* recurses to discover B's outbound relationships. If the mutator already deleted B→C, the recursive call finds nothing and C survives the cascade. The existing InMemory code worked for recursive cascades precisely *because* the mutator didn't clean up relationships — an accidental dependency on the bug's absence.

The JPA implementation has the same ordering, but I suspect it hasn't been caught yet because there are no JPA registry tests for recursive cascading. Something to circle back to.

The fix was to collect all DEREGISTER'd target IDs from the cascade effects after traversal completes, then do a single `removeIf` pass on the `CopyOnWriteArrayList` using a `HashSet` lookup. One array copy instead of N+1, and the cascade engine gets to see every relationship it needs before anything is removed.

The broader pattern: when a traversal algorithm calls a mutator callback, the mutator shouldn't destroy state the algorithm still needs to read. The cascade engine's contract doesn't document this — the `EntryMutator` interface says `deregister(String id)` and nothing about what you shouldn't touch. The JPA implementation's working behaviour is coincidental (no recursive cascade tests), and the InMemory implementation's bug was masked by the same gap.
