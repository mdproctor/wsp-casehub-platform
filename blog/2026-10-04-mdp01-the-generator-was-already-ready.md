---
layout: post
title: "The Generator Was Already Ready"
date: 2026-10-04
entry_type: note
subtype: diary
projects: [casehubio/engine]
tags: [spring, codegen, cdi-bridging]
series: issue-1206-spring-completeness
---

# The Generator Was Already Ready

The spring-generator had been producing 68 beans for the engine's runtime-spring module. The ManualConfig file had 35 more — hand-written @Bean methods that someone had decided the generator couldn't handle. Most of them, it turned out, it already could.

The generator works by following POJO constructors. When a Quarkus @Produces method takes `Instance<T>`, the generator looks at the POJO class itself and sees `Optional<T>` — which it maps to Spring's `ObjectProvider<T>` with an `Optional.ofNullable(getIfAvailable())` wrapper. When it sees `Consumer<T>`, it generates `event -> publisher.publishEvent(event)`. When it sees `List<T>`, Spring's native multi-bean injection handles it directly.

That's three patterns. They cover twenty of the thirty-five manual beans. The remaining fifteen genuinely need manual wiring — `@ConfigProperty` values that map to primitive constructor params (the generator follows the POJO constructor, which just sees `boolean enabled`, not the `@Value("${casehub.goal-revision.enabled:false}")` annotation it needs), qualified injection like `@WorkerBackend` that selects a subset of beans, setter injection for optional subsystems, and factory methods that switch on config values.

Removing those twenty beans from RuntimeManualConfig was the entire change. On the next build, the generator's ManualBeanScanner — which skips anything already defined in `*ManualConfig.java` — stopped skipping them and produced the Spring wiring automatically. The generated output went from 68 to 93 beans.

One thing I found along the way: the AutoConfiguration.imports file had been pointing at the wrong package — `io.casehub.engine.internal.spring` instead of `io.casehub.engine.runtime.spring`. Spring Boot silently ignores missing classes in that file. Every bean in ManualConfig had been invisible to auto-configuration discovery. The generated RuntimeAutoConfiguration, which did have the right package, was the only config actually loading. This means the module was partially working by accident — the generated beans were active, the manual ones were not.

The other piece was filling a gap nobody had noticed: `SwarmProvisioner` existed in the Quarkus RuntimeBeans but had no Spring equivalent in either the generated or manual config. In Quarkus, if a bean's dependencies don't exist, the bean simply isn't created. In Spring, the equivalent is `@ConditionalOnBean` — it guards the bean definition so it's only instantiated when its prerequisites are present.

The engine's Spring story is now substantially generated. What remains — SSE bridging from Mutiny `BroadcastProcessor` to Spring `SseEmitter`, and extracting service POJOs into a `rest-core` module — is a different kind of work. The generator can't help there; those are framework-specific adapters that need to be written once and left alone.
