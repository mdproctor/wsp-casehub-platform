---
layout: post
title: "Planting the tenancy ID before the fields exist"
date: 2026-05-21
type: phase-update
entry_type: note
subtype: log
projects: [casehub-platform]
tags: [multi-tenancy, java, design]
---

Every multi-tenant system I've seen retrofitted from single-tenant has scar tissue. Columns added after the fact, cache keys that leak data between customers, foreign keys that don't include tenant scope. The longer you wait, the more surface area there is.

We have no users yet. No data. No migrations. If I'm going to add `tenancyId` to every entity and `tenancyId()` to `CurrentPrincipal`, the cost is near-zero right now.

So we did it.

## The constants question

`TenancyConstants` is a new class in `platform-api` holding two sentinels: `DEFAULT_TENANT_ID` (a UUID for single-tenant deployments) and `PLATFORM_TENANT_ID` (reserved for super-admin). The alternative was static fields directly on `CurrentPrincipal`.

I went with the separate class. A data access class that needs `DEFAULT_TENANT_ID` to build a cache key should not have to import an identity SPI to get it. `TenancyConstants` has no behaviour, no CDI, no request context — importing it implies nothing about how the caller handles identity.

## Compile-time pressure

Both new methods on `CurrentPrincipal` — `tenancyId()` and `isCrossTenantAdmin()` — are abstract. No interface defaults.

The existing default methods like `isSystem()` and `isAuthenticated()` can be derived from `actorId()`. You can't derive `tenancyId()` from anything — it has to come from the security context, whether that's a JWT claim, a mock config property, or a test fixture. Abstract means every new implementor confronts this at compile time, not as a runtime null in production.

`isCrossTenantAdmin()` is the same logic. You do not want a future implementor silently inheriting `false` and never noticing.

## The conditional anti-pattern we're preventing

The failure mode with multi-tenancy is conditional filtering:

```java
if (multiTenantEnabled) {
    filterByTenancyId(currentPrincipal.tenancyId());
}
```

This is now a project protocol violation. Tenancy filtering is unconditional. In a single-tenant deployment, every principal returns `DEFAULT_TENANT_ID` and the filter is always satisfied — the filter runs, always, the conditional doesn't exist. The deployment model determines what `tenancyId()` returns, not whether the filtering code runs.

The same principle applies to `isCrossTenantAdmin()`. Rather than scattering checks at every call site, it's checked once at CDI injection time in any data access class that needs cross-tenant visibility. Unauthorised code can't get the cross-tenant repository injected — the CDI container enforces it, not developer discipline.

## The review catch

Claude caught something in the initial test draft:

```java
assertNotNull(principal.isCrossTenantAdmin());
```

This always passes. `isCrossTenantAdmin()` returns primitive `boolean`. Java autoboxes it to `Boolean` before the null check. `Boolean.FALSE` is never null. The assertion verifies nothing — no behaviour, no callability, no value. Fixed to `assertFalse(...)`. It's now in the knowledge garden since this isn't the last time someone will write it.

The multi-tenancy surface in `platform-api` is intentionally small. What matters is that it's there before any consumers build on top of it.
