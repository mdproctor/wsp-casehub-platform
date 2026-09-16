---
layout: post
title: "Cutting the ceremony: @McpDomain on classes"
date: 2026-09-16
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [code-generation, annotation-processing, cdi, mcp]
---

Every `@McpDomain` SPI in the platform follows the same three-file pattern: an interface in `platform-api`, a default implementation in the runtime module, and generated REST + GraphQL endpoints from the APT. For domains with a single implementation and no alternative providers, the interface-and-default split is pure ceremony — files without value.

I wanted to let `@McpDomain` go directly on a concrete class. The annotation was already `@Target(TYPE)`, so it could be placed on classes today — the scanners just refused to look at them. Four independent scanners each had their own interface-only gate, all checking the same thing in slightly different ways.

The fix turned out to be satisfyingly mechanical. Remove the `isInterface` check in `McpDomainJandexScanner` (which feeds all three Spring generators), lift the same gate in both scan paths of `GraphQLResolverProcessor` (the Jandex path and the RoundEnvironment path), and teach `GraphQLModelScanner` to read `@PlatformQuery`/`@PlatformMutation` directly from class methods when it encounters a `@McpDomain` class without `@GraphQLApi`.

The one thing that wasn't obvious: the runtime scanner's `computeIfAbsent` ordering. I'd moved the domain initialization before the `hasGraphQLApi` check — seemed like a harmless scoping change to make the variable available in both branches. Claude caught it during review: `ModelEnricher` beans would now create empty domain entries in the first pass, and the second pass's `if (domainOps.containsKey(domain)) { continue; }` guard would skip registering the real operations from the interface. The fix was straightforward — call `computeIfAbsent` inside each branch that actually adds operations, not unconditionally at the top.

I also added a compile-time courtesy: the APT now emits a WARNING when `@McpDomain` is placed on a class without a visible CDI scope annotation. It can't see inherited scopes or stereotypes, so it's best-effort — CDI injection failure at runtime remains the real gate. But it catches the common case where someone simply forgot `@ApplicationScoped`.

The `DomainScanResult` record got a rename along the way — `spiInterfaceFqcn`/`spiInterfaceSimple` became `sourceFqcn`/`sourceSimple` with an `isInterface` flag. The old names were actively misleading when the source was a class.

What this opens up: every domain across the casehub ecosystem that has exactly one implementation — simple CRUD services, dashboard queries, utility endpoints like GDPR erasure — can drop the interface-and-default wrapper. The issue already lists the candidates; the migration is a separate pass.
