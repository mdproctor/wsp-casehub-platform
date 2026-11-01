# HANDOFF — casehub-platform

## Last Session (2026-11-01)

Closed **#663** (security annotation propagation in graphql-generator). Also advanced the plan queue past #543, #593–#596 which had been completed in prior sessions but not marked done in the plan.

**#663 — Security annotation propagation (S/Med):**
- `GraphQLResolverProcessor` now scans class-level `@RolesAllowed`, `@PermitAll`, and `@Authenticated` from `@McpDomain` SPIs and emits them on generated REST resource classes
- `@Authenticated` scanned by DotName string (`io.quarkus.security.Authenticated`) — no compile dependency on Quarkus security
- Multi-class domain conflict detection: conflicting class-level annotations across contributing classes produce a WARNING and omit class-level security (method-level still propagates)
- Also fixed: stream and streaming-mutation REST methods previously had no security annotation emission at all — now consistent with regular and webhook methods
- Landed as `0fb9cc04` on main, branch stamped

## Immediate Next Step

#682 — Wire unused EngagementType values (REPLIED, CONVERTED) or remove. Different domain (notification delivery) — fresh session recommended.

## References

- Plan queue: `wsp-casehub-platform/.plan` — position 8/10, #682 active
- Design spec: `wsp-casehub-platform/specs/issue-663-security-annotations/`
- Blog entry: `wsp-casehub-platform/blog/2026-11-01-mdp01-generated-code-security-gap.md`
