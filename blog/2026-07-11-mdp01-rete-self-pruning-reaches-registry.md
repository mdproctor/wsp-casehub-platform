---
layout: post
title: "Rete Self-Pruning Reaches the Registry"
date: 2026-07-11
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [datasource, rete, alpha-network, cdi, concurrency]
---

The DataSource system was add-only. You could register a DataSource, subscribe to it, push events through the alpha network — but you couldn't remove one. No CDI event for removal, no cleanup in the router, and `register()` silently replaced the `AlphaDataSource` instance every time, orphaning any active subscribers on the previous one.

The fix borrows from Rete's own playbook. In a Rete network, nodes track their child count. When the last child detaches, the node removes itself from its parent, cascading upward. The alpha network we built for DataSources already did this — `TypeNode` removed empty `FilterNode`s, `AlphaDataSource` removed empty `TypeNode`s. The missing piece was extending that self-pruning to the registry itself.

`AlphaDataSource` now carries a share count — an `AtomicInteger` tracking active subscribers across all subscribe variants. `markForRemoval(Runnable onEmpty)` sets a pending-removal flag and stores a callback. When the last subscriber unsubscribes and the count hits zero, the callback fires and the registry cleans its maps. If nobody's subscribed at deregister time, cleanup is immediate. If subscribers exist, the DataSource stays resolvable while they drain out.

The interesting design problem was CDI event ordering. `@ObservesAsync` doesn't guarantee delivery order. When `deregister()` fires `DataSourceDeregistered` and a subsequent `register()` fires `DataSourceRegistered` for the same key, the `DataSourceRouter` might process them in either order. Key-based matching would break — the deregistration handler would remove the freshly-wired replacement entry.

The fix: `DataSourceDeregistered` carries the actual `DataSource<?>` instance, not just the descriptor. Both `wireRoute` and `unwireRoute` use identity comparison (`==`) against the instance. `unwireRoute` only removes a wired entry if the instance matches the one being deregistered. `wireRoute` resolves the current DataSource from the registry and replaces stale entries where the instance differs. Both handlers converge to the correct state regardless of processing order.

`register()` itself changed from upsert to idempotent — calling it twice for the same `(path, tenancyId)` returns the existing `DataSource`. No replacement, no orphaned subscribers. The old upsert behaviour was never intentional; it was just `ConcurrentHashMap.put()` doing what `put()` does. `compute()` with an `isPendingRemoval()` check handles the drain-aware re-registration case: if the existing DataSource is draining, a new one is created and the old one's cleanup callback is guarded with `sources.remove(key, oldSource)` — conditional removal using identity equality, so a draining DataSource can't accidentally evict its replacement.

The thread safety model is minimal. `markForRemoval` and the unsubscribe decrement-and-check share a `synchronized(this)` monitor on the `AlphaDataSource`. `subscribe()` uses an unsynchronized `AtomicInteger.incrementAndGet()` — the worst case (subscribe races with markForRemoval) is safe because markForRemoval will see the incremented count and defer cleanup.

The design review caught the CDI ordering race, the conditional removal gating, and the need for eventual-language in the SPI javadoc — `deregister()` previously promised "stops further deliveries" synchronously, which is no longer true when cleanup is async.
