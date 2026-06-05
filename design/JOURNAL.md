# Design Journal — issue-56-arc42stories

### 2026-05-30 · §CapabilityOwnership · §Modules

`GroupMembershipProvider.membersOf()` now returns `Set<GroupMember>` — a
breaking SPI change. `GroupMember` carries `actorId` (= OIDC `sub` = SCIM
`value` UUID, stable identity key) and `displayName` (human label, never used
as a routing key). The raw `Set<String>` return was insufficient for the
inverse-membership query: callers need a value that correlates with
`CurrentPrincipal.actorId()` and a plain string provided no such guarantee.

New module `scim/` (`casehub-platform-scim`) provides the first real
implementation: a SCIM 2.0 REST client (`@ApplicationScoped`, Tier 1 CDI
priority — displaces `@DefaultBean` mock by classpath presence). Two-step
fetch: Step 1 lists the group with inline members; Step 2 fetches by id when
members are absent from the list response (common for large groups on some
servers). Cache via `@CacheResult` prevents per-routing-decision SCIM calls.
Auth: static bearer token wins; otherwise named OIDC client `"scim"` via
`quarkus.oidc-client.scim.*` handles token acquisition and refresh.
