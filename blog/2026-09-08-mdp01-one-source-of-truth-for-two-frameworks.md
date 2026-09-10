---
title: One Source of Truth for Two Frameworks
author: Mark Proctor
date: 2026-09-08
tags: [architecture, quarkus, spring-boot, dual-framework, code-generation]
status: draft
entry_type: note
subtype: diary
series: dual-framework-extraction
---

The question that kicked this off was simple: can casehub run on Spring Boot as well as Quarkus? The answer turned out to be more interesting than I expected — not because it's technically hard, but because the right design eliminates the maintenance problem entirely.

## The root constraint

Every no-op default in the platform uses `@DefaultBean` — a Quarkus Arc annotation, not standard CDI. A module without `quarkus-arc` on the classpath silently ignores `@DefaultBean`. That's the root. You can't just strip annotations and call it framework-neutral — the displacement mechanism itself is framework-specific.

So the question becomes: where does framework wiring live, and how do you keep two framework layers in sync?

## The industry already solved this

BootUI (Julien Dubois) runs the same developer console on both Quarkus and Spring Boot. Their architecture is exactly what you'd expect from first principles: a pure-Java engine with thin per-framework adapters. Events use each framework's native system. No shared abstraction — each side is idiomatic.

The hexagonal architecture projects on GitHub tell the same story. Pure domain core, framework-specific ports. The pattern is well-established.

What none of them solved is the *maintenance* problem. Two thin adapter layers are still two things to maintain. Change a CDI producer, forget the Spring equivalent, discover the drift three weeks later in a consumer's CI.

## Quarkus as the source of truth

The insight that changed the design: Quarkus `@Produces` methods already contain everything a Spring `@Bean` method needs. Return type, parameter types, CDI annotations that map mechanically to Spring annotations. A generator can read the Quarkus Jandex index and emit the Spring auto-configuration.

So we built one. `spring-generator` is a Maven plugin — same pattern as the existing `graphql-generator` and `callback-generator`. Two goals: `generate` (produce `@AutoConfiguration` from `@Produces`) and `verify` (fail the build if Quarkus and Spring bean sets diverge).

The generator handles about 80% of the mapping mechanically. `@DefaultBean` → `@ConditionalOnMissingBean`. `@Alternative @Priority` → `@Primary`. `@ConfigProperty` → `@Value`. The remaining 20% — event observers, decorators, CDI qualifiers — needs manual Spring wiring. But the drift verifier catches it: add a `@Produces` method to the Quarkus module, forget the manual Spring equivalent, and CI fails.

## The extraction pattern

Each CDI-coupled module splits into three:

- `module-core/` — pure Java POJOs with constructor injection. Zero framework annotations.
- `module/` — existing artifact name preserved. CDI producers that instantiate core POJOs. Quarkus consumers see no change.
- `module-spring/` — generated auto-configuration. Drift-verified against the Quarkus module.

The naming asymmetry is deliberate. Quarkus is the established framework — its artifact names don't change. Spring is the new addition. The `-core` suffix goes on the extracted logic because that's what it is: the core without the wiring.

Five modules extracted so far: platform-view, platform defaults (32 NoOp POJOs), governance, expression. Each follows the same mechanical steps. The pattern is proven and scaling.

## What I didn't expect

The CDI coupling across the platform is lighter than it looks. Most "CDI-heavy" modules are really "annotation-heavy" — the business logic is already pure Java with CDI annotations stuck on top. SubjectViewEvaluator had one annotation. SubjectViewOrchestrator needed four field injections converted to a constructor. The expression engines were pure logic with `@ApplicationScoped` sprinkled on.

The modules that are genuinely framework-coupled — subscriptions (CDI event orchestration), mcp (BeanManager scanning), streams (Reactive Messaging) — are a small minority. Those get parallel framework implementations sharing utility classes, not forced core extraction.

No Quarkus goodness is lost. The framework modules use full Arc features — `@Produces`, `@DefaultBean`, CDI events, `@Scheduled`, build-time optimization. They just live in a separate JAR from the logic they wire.
