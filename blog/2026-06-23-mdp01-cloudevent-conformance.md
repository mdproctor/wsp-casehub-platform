---
layout: post
title: "When .exceptionally() Breaks Your Kafka Consumer"
date: 2026-06-23
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [cloudevents, streams, kafka, quarkus, reactive-messaging]
---

There's a GE rule that says always use `.exceptionally()` when calling `fireAsync()` for CloudEvent dispatch. It's right. Except in Kafka and AMQP stream processors, where following it would silently eat your messages.

This branch closed three XS/S issues — #107, #108, #109. #107 was genuinely trivial: remove three stale version pins from the root pom, verify the BOM inheritance still resolves to `4.0.1`. Done. #108 and #109 were more interesting.

## #108: GE rule 3, and its exception

The platform's canonical CloudEvent adapter pattern (GE-20260621-629712) says: use `.exceptionally(ex -> { LOG.warn...; return null; })` for `fireAsync()` dispatch. In a fire-and-forget CDI adapter, nothing awaits the returned `CompletionStage`, so `.exceptionally()` vs `.whenComplete()` produce identical outcomes. The GE rule prescribes `.exceptionally()` for clarity of intent.

Four stream processors were using `.whenComplete()`. Poll and Camel are fire-and-forget — switching them was a clean alignment. Kafka and AMQP are not.

Kafka and AMQP return the stage to SmallRye Reactive Messaging:

```java
return cloudEventBus.fireAsync(ce)
    .whenComplete((v, t) -> { if (t != null) LOG.warnf(t, "..."); })
    .thenCompose(ignored -> message.ack());
```

With `.whenComplete()`: if `fireAsync()` fails, the exception propagates. `.thenCompose()` sees an exceptional stage, skips its lambda, and lets the exception surface to SmallRye — message nacked, retried or dead-lettered.

With `.exceptionally()`: exception swallowed, `null` returned. `.thenCompose()` fires. `message.ack()` runs. The message is permanently consumed, silently, regardless of whether the CloudEvent got anywhere.

The GE rule is written for CDI adapters where there is no ack chain. It cannot be applied here. We updated GE-20260621-629712 with the exception and filed protocol `PP-20260623-a0fe15`.

## #109: what to declare when you don't know

`STREAM_DATA_CONTENT_TYPE` is a new property key that lets operators declare the content type of a stream's payload. Stream processors read it from the descriptor and call `withDataContentType()` when it's present.

The interesting question was the unregistered path: a Kafka message arrives from a topic with no registered `EndpointDescriptor`. We mark the event as unregistered via the type field. What about `datacontenttype`?

The only defensible non-null default would be `application/octet-stream`. But that would actively mislead consumers whose data is JSON or Avro — they'd treat opaque bytes rather than parsing structure. A registered descriptor without the property produces the same output as no descriptor: `datacontenttype` absent. Treating those two states differently creates asymmetric consumer behaviour for states the consumer can't distinguish. Omit — the consumer determines the format, or not. We can't declare what we don't know.

## The null guard that wasn't

The spec went through three review iterations. One finding pushed back on something I was confident about. The reviewer argued that for GE rule 2 conformance, Poll and Camel needed a null guard on `descriptor.tenancyId()` — and specifically that `EndpointDescriptor` should be relaxed to allow null tenancyId so the guard could be tested.

I pushed back: the design uses non-null sentinels everywhere. `PLATFORM_TENANT_ID = "platform"` marks platform-global endpoints; `DEFAULT_TENANT_ID` marks single-tenant deployments. Null means programming error, not "no specific tenant." Relaxing the record would introduce a second representation for platform ownership alongside `PLATFORM_TENANT_ID`. Claude had initially advocated for the guard and conceded once the sentinel pattern was on the table — it had been applying GE rule 2 to a registry type where null is structurally impossible, rather than to the domain event context the rule was written for. Dead code that looks like it might mean something is worse than no code.

The code review caught one residual rough edge: the `contentType` local variable in Kafka and AMQP was missing `final`, while Poll and Camel had it. One word. But the inconsistency reads as an oversight, not a decision.

Three issues, two findings worth the write-up. The ack chain distinction is the one that matters — it's not in the GE, and it would be easy to get wrong.
