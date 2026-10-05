# HANDOFF — casehub-platform

## Status

**Branch:** main (work landed)
**Last session:** #515 + #516

## This Session

- Fixed #516: `JandexTypeConverter.classNameFromDotName()` now handles `$`-separated inner class names in Jandex, producing correct `ClassName.get(pkg, "Outer", "Inner")`. `typeToJava()` replaces `$` with `.`. All three generators benefit. Unblocks casehubio/engine#1095 (EvolutionApi @McpDomain SPI migration).
- Fixed #515: Extracted `acl-admin-core` with framework-neutral `AclServiceCore` POJO. `acl-admin` refactored to `@Produces` wrapper + exception mappers (SecurityExceptionMapper → 403, IllegalArgumentExceptionMapper → 400). Spring bean wired in `RestControllersAutoConfiguration`. Parity enforcer green.
- Updated CLAUDE.md with `acl-admin-core` module entry.

## Next

- #517: DataRealism E2E verification for CommercePlatform — test deterministic (unmarked), strategy-resolved (with level), and ref fallthrough (STRUCTURALLY_VALID) paths. Cross-repo dependency on casehubio/connectors#143 (seed data).

## Deferred (from prior sessions)

- EvolutionApi @McpDomain SPI — now unblocked by #516 inner class fix (casehubio/engine#1095)
