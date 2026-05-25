---
layout: post
title: "Already Fixed, Still Open"
date: 2026-05-25
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [jandex, quarkus, maven]
---

The first items off the small-issues queue: one already done, just never closed.

Issue #25 was to add a Jandex index to `casehub-platform`. Without one, Quarkus
doesn't discover CDI beans — including `@DefaultBean` mocks — when a module is
consumed as a JAR dependency rather than a first-party source tree. It's the kind
of thing that's obvious once you know it and invisible until a downstream
`@QuarkusTest` starts failing to wire beans.

The fix was already in. A commit three days ago had added the Jandex plugin to
`platform/pom.xml`, but the commit message used `#25` (a reference) rather than
`closes #25` (the auto-close trigger), so the issue stayed open.

The remaining gap: `platform/pom.xml` and `testing/pom.xml` used a hardcoded
`<version>3.3.1</version>` for the plugin, while the other five Quarkus modules
already used the parent property `${jandex-maven-plugin.version}`. The parent
defines it at the same value — nothing breaks — but a future version bump would
miss the stragglers. We fixed both, confirmed the JARs contain
`META-INF/jandex.idx`, and committed with `closes #25`.

Two lines. The issue is gone.
