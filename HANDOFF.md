# HANDOFF — casehub-platform

**Date:** 2026-06-18
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Shipped platform#98: CloudEvent foundation and five stream modules. Added `io.cloudevents.CloudEvent` as the platform CDI event type (compile dep in platform-api), `EndpointRegistered` CDI event record, `EndpointProtocol.AMQP`, and `EndpointPropertyKeys.STREAM_EVENT_TYPE`. Five classpath-activated `platform-streams-*` modules — kafka, amqp, webhook, poll, camel — each firing `Event<CloudEvent>.fireAsync()`. Squashed 26 commits to 11 clean commits and merged to main on both remotes.

## Immediate Next Step

Check `parent#276` (Add cloudevents-core:4.0.1 to casehub-parent BOM) — timing-wise, this should land once `iot#19`, `qhorus#279`, or `connectors#20` starts implementation. If any of those is in progress, it's time to file the BOM change.

## Cross-Module

**We're enabling (consumers of `@ObservesAsync CloudEvent`):**
- `casehub-ras` — can now receive events from external transports (all five stream modules ship)
- `casehub-iot` (iot#19), `casehub-qhorus` (qhorus#279), `casehub-connectors` (connectors#20) — can now add CloudEvent adapters

## What's Left

*Updated: parent#275 closed — removed from backlog.*

- `parent#285` — PLATFORM.md sync for platform#98 (StreamContext deferral, AMQP enum, STREAM_EVENT_TYPE, repo map entries) · S · Low
- `platform#101` — document session.close() Mutiny callback thread ordering · XS · Low
- `platform#102` — add SystemMessage silent-ignore note + test to AgentSessionChatModel · XS · Low

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| parent#276 | Add cloudevents-core:4.0.1 to casehub-parent BOM | XS | Low | Do when iot/qhorus/connectors adapters start |
| iot#19 | StateChangeEvent → CloudEvent adapter | S | Low | Now unblocked |
| qhorus#279 | MessageReceivedEvent → CloudEvent adapter | M | Med | Also covers channel creation SPI |
| connectors#20 | InboundMessage → CloudEvent adapter | S | Low | Now unblocked |

## References

- Diary: `blog/2026-06-18-mdp02-platform-gets-ears-cloudEvent-streams.md`
- Spec: `docs/superpowers/specs/2026-06-14-cloudEvent-streams-design.md`
- Epic: casehubio/parent#277
- Garden entries: GE-20260618-9b08e4 (quarkus-messaging-kafka rename), GE-20260618-2a7b8a (camel-bom jetty), GE-20260618-a677f1 (HttpClient 4xx/5xx), GE-20260618-220afe (InterruptedException), GE-20260618-11677d (quarkus-arc), GE-20260618-11251a (CloudEvents JAX-RS)
