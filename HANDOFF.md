# HANDOFF — casehub-platform

**Date:** 2026-05-22
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Major foundation sprint. Shipped: ActorType migration (#22, unblocks ledger#88),
casehub-platform-expression JQ evaluator (#23, with MockSecretManager Optional<Map>
bug caught in review), casehub-platform-persistence-jpa (#6, JPA PreferenceProvider
current-only per ADR-0006). Platform#24 (apps-api) was evaluated and closed —
SlaBreachPolicy belongs in casehub-work-api (ADR-0007, work#213 filed with full
type API design).

## Immediate Next Step

Resume `#7 persistence-mongodb/` — same pattern as persistence-jpa, no Flyway.
Stack is empty; start fresh with `work-start`.

## Cross-Module

**We're blocking:**
- `casehub-ledger` — ledger#88 (actorType() on CurrentPrincipal) · XS · Low
  ✅ Unblocked — casehub-platform-api 0.2-SNAPSHOT in .m2 with ActorType
- `casehub-engine` — engine#320 (consume JQEvaluator from platform-expression) · M · Low
- `casehub-work` — work#207 (replace JqConditionEvaluator) · S · Low
- `casehub-work` — work#213 (SlaBreachPolicy API in casehub-work-api) · M · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #7 | `persistence-mongodb/` — MongoDB PreferenceProvider | M | Low | Mirrors persistence-jpa; no Flyway |
| #8 | `preferences-editor/` — REST write path | L | Med | Needs write model design; low priority |
| work#212 | Wire SlaBreachPolicy in casehub-work expiry service | M | Low | Blocks on work#213 first |
| work#213 | Add SlaBreachPolicy types to casehub-work-api | M | Low | Full API in issue; ready to implement |
| devtown#38 | Layer 2: SLA-bounded human review gate | L | Med | Blocks on work#213 |

## References

- ADRs: `adr/0005` (ActorType), `adr/0006` (JPA current-only), `adr/0007` (SlaBreachPolicy in work-api)
- Blog: `blog/2026-05-22-mdp04-closing-platform24.md` (latest)
- Garden: GE-20260522-a69fa1 (String.matches anchor), REVISE GE-20260519-b9719e (Optional<Map> nested prefix)
- Protocol: PP-20260522-359dfc (CurrentPrincipal booleans delegate to actorType())
- casehub-work: work#212 (wiring), work#213 (SlaBreachPolicy API — full type design in issue)
