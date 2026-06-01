# HANDOFF — casehub-platform

**Date:** 2026-06-01
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Three fixes on main: (1) Jandex index added to `casehub-platform-api` (#54) — pure-SPI jar was shipping without `META-INF/jandex.idx`, breaking ARC type resolution in consuming modules when the SNAPSHOT cache refreshed. (2) Keycloak DevServices disabled in SCIM tests (#54) — `quarkus-oidc-client` on classpath was starting a full Keycloak container even though tests use static token auth; disabling DevServices surfaced a hidden `SRCFG00050` config mapping gap (`member-page-size` not declared in `ScimConfig`). Both fixed; SCIM tests now run in 5s with no containers. (3) `ScimActorDIDProvider` test constructor and `validateEndpoint` widened to public (#53 prep). Full `mvn install` green.

## Immediate Next Step

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## Cross-Module

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Left

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## What's Next

*Unchanged — `git show HEAD~1:HANDOFF.md`*

## References

- Blog: `blog/2026-06-01-mdp02-oom-hiding-config-bug.md`
- Prior blog: `blog/2026-06-01-mdp01-five-closes-one-gotcha.md`
- Garden: GE-20260601-08a351 (quarkus-oidc-client triggers Keycloak DevServices even with static token auth), revise GE-20260529-5a8158 (OOMKill masks SRCFG00050)
- Protocols: PP-20260601-b600ee (configmapping-prefix-ownership), revised library-jars-require-jandex to include SPI supertypes
