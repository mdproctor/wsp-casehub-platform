---
layout: post
title: "The Resolver That Couldn't See the Issuer"
date: 2026-06-30
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [identity, did, scim, cdi, composite-pattern]
---

The issue was straightforward: add a `ScimDIDResolver` that constructs synthetic DID documents from SCIM certificate data, so enterprises don't need to host DID documents externally. SCIM already has the certificates. Just read them.

I started where I always start — at the SPI. `DIDResolver.resolve(String did)` takes a DID URI and returns a document. Clean, modular, exactly what a resolver should be. Except for one problem: the ScimDIDResolver needs to query SCIM, and SCIM's lookup key is the actorId, not the DID. The resolver receives the DID but has no way to identify which SCIM record to fetch.

The obvious fix is to add actorId to the method signature. Before doing that, I checked the rest of the identity SPI family. `ActorDIDProvider.didFor(String actorId)` — takes actorId. `AgentCredentialValidator.validate(String actorId, String did)` — takes both. `DIDResolver.resolve(String did)` — drops the actorId. The resolver was the odd one out.

That would have been enough to justify the change. Then we found the bigger problem.

## Three callers, three different contexts

We traced every production caller of `DIDResolver.resolve()`. Two of them resolve an actor's DID — the actorId is right there in scope. The third is `JwtVCValidator`, which resolves the credential *issuer's* DID. Different entity entirely. No actorId available.

This matters because all the existing resolvers use `@Alternative` — meaning only one can be active at a time. In a SCIM-only deployment where `ScimDIDResolver` replaces `WebDIDResolver`, issuer DID resolution silently fails. `JwtVCValidator` gets back empty for every external issuer. VC validation returns `ISSUER_UNKNOWN` across the board.

The `@Alternative` pattern was the wrong abstraction. SCIM introduces a resolver that handles a *subset* of DIDs — those belonging to known actors. External issuer DIDs still need `did:web` resolution. Both must coexist.

## The composite

The SPI Javadoc had always promised "Multiple resolvers may be registered; the resolution pipeline selects the first non-empty result." That pipeline never existed. We built it.

`CompositeDIDResolver` injects all `@DIDMethod`-qualified resolvers, sorts them by `@Priority`, and iterates until one returns a document. `WebDIDResolver` and `KeyDIDResolver` at `@Priority(100)` handle their respective DID methods authoritatively. `ScimDIDResolver` at `@Priority(1000)` is the fallback for actors whose DIDs aren't externally hosted. When `JwtVCValidator` resolves an issuer DID with `actorId=null`, the SCIM resolver returns empty and `WebDIDResolver` handles it.

The old `@Alternative` annotation becomes `@DIDMethod @Priority(N)`. No more `quarkus.arc.selected-alternatives`. All resolvers active by classpath presence.

## The annotation that isn't inherited

The design review caught something I would have missed. `CompositeDIDResolver` sorted resolvers by reading `@Priority` via reflection — `resolver.getClass().getAnnotation(Priority.class)`. Looked correct. Compiled. Tests passed.

But `@jakarta.annotation.Priority` is not annotated with `@Inherited`. CDI proxy classes are subclasses of the real bean. The proxy doesn't carry the annotation. Every resolver silently gets `Integer.MAX_VALUE`, and ordering becomes undefined.

The fix uses Quarkus Arc's `InjectableBean.getPriority()` through the `Instance.Handle` API — reading bean metadata from the container rather than from reflection on the proxy class. It's one of those bugs where the natural Java approach (`getClass().getAnnotation()`) works everywhere except CDI containers, and the failure is completely silent.
