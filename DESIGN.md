# casehub-platform Design

## Capability Ownership

`GroupMembershipProvider.membersOf()` now returns `Set<GroupMember>` — a
breaking SPI change. `GroupMember` carries `actorId` (= OIDC `sub` = SCIM
`value` UUID, stable identity key) and `displayName` (human label, never used
as a routing key). The raw `Set<String>` return was insufficient for the
inverse-membership query: callers need a value that correlates with
`CurrentPrincipal.actorId()` and a plain string provided no such guarantee.

## Modules

New module `scim/` (`casehub-platform-scim`) provides the first real
`GroupMembershipProvider` implementation: a SCIM 2.0 REST client
(`@ApplicationScoped`, Tier 1 CDI priority — displaces `@DefaultBean` mock by
classpath presence). Two-step fetch: Step 1 lists the group with inline members;
Step 2 fetches by id when members are absent from the list response (common for
large groups on some servers). Cache via `@CacheResult` prevents
per-routing-decision SCIM calls. Auth: static bearer token wins; otherwise named
OIDC client `"scim"` via `quarkus.oidc-client.scim.*` handles token acquisition
and refresh.

## Persistence Modules

`persistence-mongodb/` implements `PreferenceProvider` via MongoDB Panache.
The CDI activation pattern follows the persistence-backend priority ladder
established in `casehub-work`: `@DefaultBean` (mock) < `@ApplicationScoped`
(JPA) < `@Alternative @Priority(1)` (MongoDB). Adding the module to the
classpath silently promotes MongoDB as the active backend with no consumer
changes. Scope hierarchy resolution is identical to the JPA module — a
`$in` ancestor query sorted root-first, child overrides parent. A startup
bean creates the `scope` index idempotently. `preferences-editor` (#8)
owns the write path; this module is read-only from the SPI perspective.
The persistence-backend CDI ladder is being formalised as a platform
protocol (casehubio/parent#44).
