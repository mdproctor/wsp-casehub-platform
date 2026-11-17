---
layout: post
title: "The Attribute Nobody Read"
date: 2026-11-17
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [apt, code-generation, plugins, annotation-processing]
---

# The Attribute Nobody Read

Six days ago I wrote about teaching the graphql-generator's APT to infer call chains from method bodies — reading the code so the developer didn't have to annotate it. That worked for most connector methods. But some patterns can't be inferred.

Voice connectors route through a `RoutingVoicePlatformService`. The method calls a private helper, which returns a resolved platform, which exposes the SPI:

```java
ResolvedVoice resolved = resolveVoice(voice, language);
VoicePlatform platform = resolved.platform();
platform.textToSpeech().synthesise(text, options);
```

The scanner tracks field types and direct `.platform()` calls. It doesn't follow private method return types. So when it hits `resolveVoice()`, it loses the chain and reports a fallback.

The annotation already had an escape hatch for this. `@GeneratePlugin(spi = VoicePlatform.class)` has existed since the annotation was first designed. The `exclude` attribute too — for legacy connector patterns not worth teaching the scanner. Both were declared, both were extracted from annotation metadata during processing, and neither was ever consumed. The generator read the annotation, stored the values, and then ignored them.

The `exclude` attribute happened to work by accident — a `if (meta.exclude) continue;` guard existed in the right place. But `spi` was genuinely dead. Its value was parsed into a `PluginMeta` record and never referenced again. Zero usages across the entire generation logic.

The fix is three lines of production code. When `meta.spiFqcn` is non-empty, skip inference entirely and count the method as resolved:

```java
boolean annotationGuided = !meta.spiFqcn.isEmpty();
if (!ops.isInterface && treesAvailable && !annotationGuided) {
    // inference runs only when spi is not explicitly declared
```

The generated plugin is identical either way — it delegates to the resolver class method, which handles routing internally. What changes is the diagnostic: annotation-guided methods are no longer reported as fallbacks, and the generated comment reflects how resolution happened.

This is a pattern worth watching for in annotation processors. The temptation is to design a rich annotation surface up front, planning to support it "when needed." Then the first implementation path that works (AST inference, in this case) becomes the only one that gets wired. Attributes that exist for the fallback path sit in the schema, get extracted, get serialised into internal records — and nobody notices they're never consumed because the primary path handles most methods. The annotation surface looks complete from the outside. The processing logic isn't.

The diagnostic summary now distinguishes three resolution states: AST inference, `@GeneratePlugin(spi)` annotation, and delegation (neither inferred nor annotated). Previously, everything that wasn't inferred showed as `@GeneratePlugin annotation` — misleading, since most of those methods had no `@GeneratePlugin` annotation at all.
