# Design Journal — issue-22-actor-type

### 2026-05-22 · §Identity API

`ActorType` (HUMAN / AGENT / SYSTEM) and `ActorTypeResolver` are now owned by `casehub-platform-api`, not `casehub-ledger-api`. The resolver applies a priority-ordered seven-rule chain: null/blank and `system:*` patterns resolve to SYSTEM; `agent:*` prefix and the versioned persona format (`word:word@version`, e.g. `claude:analyst@v1`) resolve to AGENT; A2A protocol roles `"user"` and `"agent"` are handled explicitly before the catch-all; everything else is HUMAN. `CurrentPrincipal.actorType()` is a new default method delegating to the resolver. `isSystem()` is widened to `actorType() == SYSTEM` so that `system:*` scoped actors (e.g. `system:scheduler`) are consistent with the type resolution rather than returning false from an exact-match check.
