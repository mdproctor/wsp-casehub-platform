---
layout: post
title: "The bugs that weren't"
date: 2026-09-15
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [annotation-processing, graphql-generator, root-cause-analysis, consumer-modules]
---

Four bugs were filed against the graphql-generator APT. Hyphens producing illegal class names. Slashes breaking class name generation. The `generateGraphQL=false` flag being ignored. The domain filter letting everything through. The consumer tried to wire the APT in their module, got a wall of compilation errors, and reverted.

The obvious read: the generator is broken in four independent ways.

The actual read: `toPascalCase("notification-suppression")` returns `"NotificationSuppression"`. The test proves it. The flag check (`!"false".equals(...)`) is logically correct. The filter (`allowedDomains.contains(entry.getKey())`) is exact-match and works fine. Every reported bug is something the code already handles.

So what's actually happening when a consumer wires this APT?

The processor scans Jandex indexes from the classpath. Platform-api's index is there — it's a transitive dependency. So the APT finds all eleven platform domains: `acl`, `notifications`, `delivery-channels`, the lot. The consumer's own SPI? Invisible. It's source code being compiled, not a JAR with an index. The APT never sees it.

Without a working domain filter — and the `@SupportedSourceVersion(RELEASE_21)` annotation may be interfering with option delivery on Java 26 — the processor generates GraphQL resolvers for all eleven domains. Those resolvers import `@Query`, `@Description`, `@GraphQLApi`. A REST-only consumer doesn't have `microprofile-graphql-api` on the classpath. Compilation fails. The error messages mention class names and missing modules, which the reporter interpreted as illegal identifiers. Reasonable inference from the symptoms. Wrong diagnosis.

The fix has two parts. First, we refactored `OperationInfo` — which held raw Jandex `MethodInfo` and `ClassInfo` — into a `ResolvedOperation` record carrying pre-extracted strings. This follows the `DomainDescriptor` pattern from the spring generators, where scanning and code generation are already decoupled. With the intermediate record in place, both Jandex and TypeMirror scanning paths produce the same type, and every code gen method works with record accessors instead of reaching into framework types.

Second, we added `scanRoundEnvironment()` — the standard APT approach that the processor was missing. Consumer SPIs in the current compilation unit are now discovered via the `javax.lang.model` API. The merge gives Jandex precedence on conflict (per #296 D7), which prevents double-generation when a dependency JAR contains a previously compiled version of the same SPI. In practice conflicts don't arise — consumer SPIs are only in RoundEnv, platform SPIs only in Jandex.

The design review caught two things I'd missed. The null-index early return (`if (index == null) return false`) would have blocked RoundEnv scanning entirely for a consumer with no Jandex-indexed dependencies — defeating the whole point of D3. And my isSimpleType limitation description had the verbs backwards: the `isBodyVerb` guard means GET/DELETE parameters are unaffected; the risk is on POST/PUT/PATCH. We added `isSimpleTypeMirror` with TypeMirror-based enum detection to handle consumer-defined enums — about five lines that eliminate the limitation completely.

Diagnostic logging at every decision point means a consumer can now see exactly what the APT received, what it found, and what it filtered. When `domainFilter` matches zero domains, they get a WARNING naming the filter value and the available domain names. When no filter is set and multiple domains are discovered, a NOTE suggests setting one. The failure mode that caused the original revert — silent generation of unwanted code — can't happen without the consumer seeing it in the build output.

The interesting pattern here: when static analysis says "this code is correct" and the bug report says "this code doesn't work," the gap is almost always in the integration boundary, not the logic. The `toPascalCase` method is fine. The filter is fine. The flag check is fine. But the code around them — the early return on null index, the missing RoundEnv scan, the stale `@SupportedSourceVersion` — creates a context where none of those correct methods get a chance to run.
