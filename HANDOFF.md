# HANDOFF — casehub-platform

## Last Session

Implemented platform#268 — capacity signal SPI + redistribution policy framework. Nine types in `io.casehub.platform.api.capacity`, four implementations in platform. Design review (3 rounds, 13 issues fixed) caught CDI ambiguity, threshold boundary gap, and contract javadoc gaps before implementation. Queue advanced past closed #151 to qhorus#428. CLAUDE.md update deferred to work-end — must add `.capacity` package and platform module entries.

## Immediate Next Step

Brainstorm qhorus#428 — `ContextPressureCapacitySource` + redistribution executor. Requires understanding qhorus CONTEXT_PRESSURE watchdog, MessageLedgerEntry, RoutingBridge, and commitment lifecycle. Cross-platform spec at `wsp-casehub-qhorus/specs/cross-platform-capacity-redistribution/`.

## Cross-Module

- casehubio/eidos#151 — load-aware selection (Batch 2). Depends on platform#268 (done). Not blocking qhorus#428.
- Engine `ActorStateAccumulatorImpl.capacity()` override — needs an issue filed before branch merge.

## Garden Entries Consulted

GE-20260602-c4a68a (dual-constructor aggregator), GE-20260602-047ac4 (visitor/accumulator pattern)

## References

- Spec: `specs/issue-268-capacity-redistribution/2026-09-02-capacity-signal-spi-design.md`
- Decisions: `specs/issue-268-capacity-redistribution/decisions.md`
- Plan: `plans/2026-09-02-capacity-signal-spi.md`
- Blog: `blog/2026-09-02-mdp01-shared-vocabulary-for-overload.md`
- Cross-platform spec: `wsp-casehub-qhorus/specs/cross-platform-capacity-redistribution/`
- Garden: GE-20260903-d37d59 (Comparator tiebreak technique — captured this session)
