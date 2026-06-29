---
layout: post
title: "The Bridge That Wasn't Quite Pass-Through"
date: 2026-06-25
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [credentials, quarkus, cdi, bridge]
series: issue-116-credential-resolver-quarkus-bridge
---

*Part of a series on [#116 — CredentialResolver bridge to Quarkus CredentialsProvider](https://github.com/casehubio/platform/issues/116). Previous: [The Quarkus CredentialsProvider Shaped Everything](2026-06-25-mdp01-quarkus-credentialsprovider-shaped-everything.md).*

## The Bridge That Wasn't Quite Pass-Through

The previous entry ended with the CredentialResolver SPI designed for a clean handoff to Quarkus `CredentialsProvider` — same `Map<String, String>` return type, same key values. The bridge looked trivial: inject the Quarkus provider, delegate `resolve()` to `getCredentials()`, done.

It wasn't quite that simple.

## @Named Breaks @Inject

The first spec had `@Inject CredentialsProvider` — direct constructor injection. A review caught the problem: Quarkus credential provider extensions use `@Named` qualifiers to avoid collisions when multiple providers coexist. `@Named` beans don't carry `@Default` in CDI. Direct injection requires `@Default`. So `@Inject CredentialsProvider` fails with an unsatisfied dependency error the moment someone deploys with a `@Named("vault-credentials")` provider — which is exactly how the Quarkus Vault extension registers itself.

The fix came from `quarkus-flow`'s `CredentialsProviderSecretManager`, already on the project's classpath. It uses `@Any Instance<CredentialsProvider>` with `@PostConstruct` validation — handles named, unnamed, single, and multiple providers. We adapted the pattern but kept it simpler: exactly one provider or fail at startup. Multi-provider routing is a future concern.

## The Defensive Copy Question

`CredentialsProvider.getCredentials()` returns `Map<String, String>` with no immutability guarantee. Vault could return a mutable `HashMap`. The `DefaultCredentialResolver` already uses `Map.copyOf()` for its compound case — the SPI implicitly promises immutable maps (`Map.of()` for empty cases). Returning the provider's map directly would leak mutability to consumers and let consumer mutations corrupt provider-internal state.

`Map.copyOf(result)`. One line, consistent with the existing default, enforces a contract the SPI implies but doesn't declare.

## Why Sync, Not Async

The Quarkus `CredentialsProvider` javadoc says "Quarkus extensions MUST invoke the asynchronous variant." This bridge is not a Quarkus extension — it's a consumer-space CDI bean. The `CredentialResolver` SPI is blocking by design. Calling `getCredentialsAsync()` from a blocking context just double-schedules onto a worker thread for no benefit. Every mainstream provider implements the sync path; the async default wraps it automatically. If a future provider only implements async, that's a signal the SPI needs a reactive variant, not a hack in the bridge.

The whole module is 62 lines of production code. The interesting parts were in what it chose *not* to do.
