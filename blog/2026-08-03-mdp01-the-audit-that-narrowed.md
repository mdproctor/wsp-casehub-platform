---
layout: post
title: "The Audit That Narrowed to Six Keys"
date: 2026-08-03
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [preferences, schema-registry, retention, config-migration]
---

The preference schema registry (#195) shipped with infrastructure but no content — `register()`, `resolve()`, `discover()`, and an `InMemoryPreferenceSchemaRegistry` backed by `ConcurrentHashMap`, all sitting empty. Issue #197 asked a deceptively simple question: what preference keys should the platform register?

The answer required an audit. Seventy-nine `@ConfigProperty` values across the platform modules, and the first thing the audit surfaced was that most of them are not preferences at all. File paths, pool sizes, Kafka channel names, webhook URLs — these are infrastructure config, set once at deploy time and never varying by tenant. `@ConfigProperty` is the right mechanism for them. `PreferenceKey<T>` solves a different problem: business settings that can vary per tenant and per scope, resolved at runtime through the preference provider chain, editable via REST without restarts.

Only retention settings crossed that line. Notification retention days, ACL audit log retention, delivery attempt retention — these are data governance settings that a compliance-conscious tenant might want to tune independently. Six keys, all `IntPreference`, all with the same shape: a day count with a sensible default and min/max constraints.

We defined them as `static final` constants in `PlatformPreferenceKeys` (in `platform-api`, zero dependency) and registered their `PreferenceSchemaDescriptor` entries via a `PlatformPreferenceRegistrar` `@Startup` bean in `platform/`. The registrar fires in every deployment — when `preferences-editor/` is on the classpath, `InMemoryPreferenceSchemaRegistry` captures the registrations for the schema endpoint. When it's not, the `NoOp` silently absorbs them.

The migration itself was straightforward. Three retention schedulers — notifications, ACL audit, and delivery tracking — swapped `@ConfigProperty` field injection for `PreferenceProvider.resolve().getOrDefault()` at call time. `getOrDefault()` falls back to the key's built-in default, so existing deployments get the same behaviour without any configuration migration. The delivery tracking store was slightly more interesting: it has per-source-type retention overrides via MicroProfile Config. We kept that mechanism on top — the `resolveRetentionConfig` method now takes a `PreferenceKey<IntPreference>` instead of an `int` default, resolves the preference, then checks the per-source-type config override.

The follow-up (#223) covers the remaining candidates — engagement tracking toggle, retry config, digest retention, view cache TTL. The pattern is established; each one is a straightforward application of it.

The open question is per-tenant resolution. All six keys currently resolve at platform-global scope via `SettingsScope.root(PLATFORM_TENANT_ID)`. The `PreferenceProvider` SPI already supports per-tenant scope — the schedulers just need to iterate tenants when that capability matters. For now, platform-global is correct and honest.
