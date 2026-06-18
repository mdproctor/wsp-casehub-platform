---
layout: post
title: "The platform gets ears — CloudEvent foundation and five stream modules"
date: 2026-06-18
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [cloudevents, streaming, quarkus, cdi]
series: issue-98-cloudEvent-streams
---

For three months the platform has been able to *produce* things — ledger entries, memory stores, WorkItems, channel messages, agent sessions. It couldn't receive anything from outside. That changes today.

The five `platform-streams-*` modules land on main: Kafka, AMQP, webhook, scheduled HTTP polling, and Camel. Each fires `Event<CloudEvent>.fireAsync()` onto the CDI bus. Each activates by classpath presence. Add one as a compile dep and events start flowing; remove it and nothing breaks.

That was the design I started with, anyway. The spec went through eleven review iterations before a line of implementation was written. Every iteration caught something real — bugs that would have hit at runtime, wrong HTTP status code semantics, a critical tenant-ID mismatch, a checked exception that the Java compiler would have rejected.

The tenant ID bug is worth calling out specifically. The first draft of all three `EndpointRegistry.discover()` calls in the stream modules used `PLATFORM_TENANT_ID`. That sounds right — "platform global, visible to all tenants" — until you read `matchesTenancy()`, which with `PLATFORM_TENANT_ID` simplifies to `d.tenancyId().equals("platform")`. It only returns descriptors registered under the literal string `"platform"`. Desiredstate registers stream endpoints under `DEFAULT_TENANT_ID` (a UUID). The result: empty discovery at startup, every Kafka message gets type `io.casehub.platform.streams.kafka.unregistered`, no errors, no indication anything is wrong. I'd call that a good catch.

The CloudEvents deserialization path for the webhook module taught me something I'll carry forward. My first instinct was to accept `CloudEvent` as a JAX-RS method parameter with `@Consumes("application/cloudevents+json")`. That's what you'd try. `cloudevents-json-jackson` is on the classpath, so Jackson has a deserializer registered, so it should just work. It doesn't — Quarkus REST's Jackson reader is registered for `application/json`, not `application/cloudevents+json`, and `CloudEvent` is an interface with no `@JsonDeserialize` annotation. The correct path is `byte[]` as the JAX-RS parameter plus `EventFormatProvider.getInstance().resolveFormat(JsonFormat.CONTENT_TYPE).deserialize(body)`. Explicit deserialization, no framework magic, fully predictable.

`StreamContext` — the async equivalent of `CurrentPrincipal` for stream processing chains — was in the original spec. I deferred it to P1.8. The argument: the `@DefaultBean @ApplicationScoped` implementation would always return `DEFAULT_TENANT_ID`. In a single-tenant deployment that's correct. In a multi-tenant deployment any observer that calls `streamContext.tenancyId()` instead of extracting from `event.getExtension("tenancyid")` directly gets silently wrong data. A SPI you're specifically told not to use is noise, not infrastructure. The SPI needs to arrive alongside the propagation mechanism — Mutiny context or a CDI scope backed by request-local storage — not before it.

One build surprise: adding `quarkus-camel-bom` to the root pom's `<dependencyManagement>` to version-manage `camel-quarkus-core` forced Jetty 12 across the entire reactor build. WireMock 3.x needs Jetty 11. The symptom was `FatalStartupException` in five unrelated modules that had nothing to do with Camel. Fixing it was one line — move the BOM import to `streams-camel/pom.xml`'s own `<dependencyManagement>`. But the symptom genuinely confused me for a moment. BOM-level Jetty version overrides have no diagnostic output.

casehub-ras can now consume `@ObservesAsync CloudEvent` from external transports. That's what this was always for.
