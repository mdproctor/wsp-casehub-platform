---
layout: post
title: "The authorization gap beneath the spec"
date: 2026-06-04
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [acl, authorization, quarkus-flow, identity]
---

The quarkus-flow worker arrived in the engine. My working assumption was that it would answer the open questions in §6.5 of the ACL spec — what identity does a flow worker carry, how does provisioning write grants, what's the `expiresAt` value. I read the code expecting closure. What we found instead was that the spec was built on a wrong premise.

`FlowWorkerExecutor` doesn't go through `WorkerProvisioner` at all. It implements `WorkflowExecutor` and fires after provisioning. `CasehubDispatch` — the component that actually dispatches workers from within a running workflow — calls `orchestrator.submit(caseInstance, WorkRequest.of(capability, Map.of()))`. No token. No actorId. No roles. A `casehub:dispatch` step inside a workflow runs with no caller context whatsoever.

My first read: the flow worker runs inside the engine's trust boundary. It's not an external actor. ACL doesn't apply here.

That was wrong. The correct pushback: there is no safe "inside the engine." Everything executing in the engine needs a scoped identity. A buggy or compromised workflow step shouldn't be able to query every case in the tenant. ACL is exactly the mechanism that would prevent that.

Which forced the next question: what identity is there to scope it to?

We read `CaseInstance` — only `tenancyId`. We read `PropagationContext` — this was the interesting one. The Javadoc says "key-value pairs to carry through the hierarchy (e.g. tenantId, userId)". The `createChild()` method propagates everything to sub-cases. The infrastructure for identity propagation is already there. But every production `createRoot()` call site passes `Map.of()`. The `inheritedAttributes` map is always empty.

Someone designed this right and then didn't wire it. Or it was aspirational. Either way, the engine currently has no mechanism to know who initiated a case by the time any worker runs inside it.

This reframes the ACL problem substantially. The question isn't "how does a flow worker get an ACL grant" — the question is "what identity does any execution inside the engine carry, and where does it come from?"

The authorization model we landed on: `PropagationContext` should carry `userId` + `roles` from the initiating principal, set at case creation from `currentPrincipal` and propagated down through every sub-case and worker via `createChild()`. That's the base execution identity.

For worker-specific permissions: a case definition declares what roles a worker needs. Not limited to what the case creator holds — that was the other wrong assumption I had baked in. A developer writes a case YAML that says "this worker needs WRITE on memory:entityId". A separate authorization service reviews and approves the grant. The engine enforces the pre-approved grant at runtime and doesn't re-evaluate creator permissions. This is the IAM/Kubernetes RBAC model, applied to case execution.

Then the scope widened again. Workers don't just access cases — they call external services. Jira. Internal APIs. Whatever the workflow orchestrates. We read through quarkus-flow's existing patterns for this: JWT passed as workflow input and referenced in HTTP step headers via JQ (`${ "Bearer " + (.token) }`), and the `secret()` DSL for static credentials. Both proven in quarkus-flow's own integration tests. The gap in casehub is that `CasehubDispatch` doesn't thread any token through to the dispatched worker — nothing bridges the initiating user's identity to the external call.

The scope of the authorization problem is: `PropagationContext` identity propagation, cross-module ACL enforcement (not just engine — every module with state), external token delegation via quarkus-flow's token-as-data pattern, and a separate authorization service SPI. Filed as platform#68.

The flat grant model in the current ACL spec — `(actor_id, resource_id, action, expires_at)` — may need to become role-based bindings once cross-module and organizational scope come into play. That's one of six open decisions the next design session needs to resolve before implementation can start.

The spec is updated to reflect all of it. File paths, call sites, the corrected model, the six open questions, everything that surfaced today. The next session should be able to start designing without re-running this research.
