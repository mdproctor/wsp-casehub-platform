---
layout: post
title: "Moving ActorType Upstream"
date: 2026-05-22
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [identity, platform-api, actor-type]
---

The ActorType migration was straightforward until review caught something I'd missed.

`ActorType` — HUMAN, AGENT, SYSTEM — has lived in `casehub-ledger-api` since early on. That made sense at the time: the ledger records who did what, so actor classification ended up next to the audit entries. But `CurrentPrincipal` in `platform-api` needed `actorType()`, and `platform-api` is zero-dependency — no Quarkus, no JPA, nothing. Adding a ledger dependency to get at an enum would break the tier model entirely. The right answer was to move `ActorType` where it belongs: with the identity primitives.

The interesting design question was `ActorTypeResolver` — the static utility that maps an actorId string to an ActorType. Seven rules in priority order: null or blank maps to SYSTEM; `"system"` and `"system:*"` map to SYSTEM; `"agent:*"` (prefix, not the bare word) maps to AGENT; the versioned persona format `word:word@version` — `claude:analyst@v1`, `gpt:coder@v2` — maps to AGENT; A2A roles `"user"` and `"agent"` are handled explicitly before the catch-all; everything else maps to HUMAN. The A2A `"agent"` case matters: without it, the bare word would fall through to HUMAN, which is wrong.

We added `actorType()` to `CurrentPrincipal` as a default method delegating to the resolver. Existing mocks didn't need touching.

Then I sent the diff to a separate reviewer. It came back with one Important finding and it was right. `isSystem()` used `"system".equals(actorId())` — an exact match. `actorType()` uses the resolver, which matches the entire `system:*` namespace. For `system:scheduler`, `actorType()` returns SYSTEM, but `isSystem()` returned false. Two methods on the same interface giving contradictory answers for the same actor. We fixed it: `isSystem()` now delegates to `actorType() == ActorType.SYSTEM`.

The reviewer also checked whether the versioned persona regex would accidentally match plain email addresses. It wouldn't — `String.matches()` in Java anchors the full string implicitly, so `alice@example.com` doesn't match `[\w-]+:[\w-]+@[\w.]+` because there's no colon before the `@`. That's in the Javadoc if you know to look, but it surprises anyone used to Python's `re.search()`.

ledger#88 can pick this up from `.m2` now.
