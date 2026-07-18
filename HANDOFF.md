# HANDOFF — casehub-platform

**Date:** 2026-07-18
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Delivered CloudEvent type dispatch (#174), MVEL POJO context + block expressions (#177, #178), and engine migration readiness (#176). PR #183 open against casehubio/platform. Discovered three MVEL3 transpiler bugs (pojo() NPE, block return, list declarations) — all captured in the garden. CDI `Event.select()` qualifier removal prevents double-processing without guards.

## Immediate Next Step

Engine migration: 4 issues filed against casehub-engine (engine#747, #748, #749, #750). These make engine-api expression types thin wrappers over platform SPI. Do them in order: #747 (ExpressionEvaluator extends), #748 (ExpressionEngine wraps), #749 (LambdaExpressionEvaluator → LambdaExpression), #750 (registry delegates).

## Cross-Module

**We're blocking:**
- `casehub-engine` — engine#747-750: expression type migration to platform SPI · M · Med (filed this session)
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-work` — work#302: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-work` — `WorkEventTypeTest` needs updating for SubscribableEvent + marshallerKeys · S · Low
- `casehub-neocortex` — neocortex#142: wire CbrOutcomeConsumer to @CloudEventType observer · S · Low (unblocked by #174)

## What's Left

- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #175 | Generic queue toolkit — AbstractQueueEntity, QueueSubject SPI | L | Med | New platform-queue module |
| #8 | Preferences-editor module — admin UI/API | XL | High | Write path for preferences; long-standing |

## References

| Type | Path |
|------|------|
| Spec | `docs/specs/2026-07-17-cloudevent-dispatch-expression-context-design.md` |
| Blog | `blog/2026-07-18-mdp01-cloudevent-dispatch-mvel-context.md` |
| PR | casehubio/platform#183 |
| Review | `~/adr/casehub-platform/cloudevent-dispatch-expression-context-*/` (spec review) |
| Engine issues | engine#747, #748, #749, #750 |
