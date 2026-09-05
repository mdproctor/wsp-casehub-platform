---
layout: post
title: "Feedback Loops That Converge"
date: 2026-09-03
entry_type: note
subtype: diary
projects: [casehubio/qhorus, casehubio/platform]
tags: [capacity, redistribution, eventual-consistency, feedback-loop, handoff, qhorus]
series: issue-268-capacity-redistribution
---

# Feedback Loops That Converge

*Continues from [Shared Vocabulary for Overload](2026-09-02-mdp01-shared-vocabulary-for-overload.md), which delivered the platform SPI. This entry covers the qhorus signal source and redistribution executor — where the vocabulary meets reality.*

The previous entry ended with a promise: "Next is the signal source that reads existing CONTEXT_PRESSURE watchdog data and the redistribution executor that does the actual HANDOFF delegation." That turned out to be the easy part. The hard part was proving the system converges.

## The before picture

Three systems detect overload. None of them talk to each other. None of them can do anything about it after the assignment is made.

<svg viewBox="0 0 700 200" xmlns="http://www.w3.org/2000/svg">
  <rect x="20" y="30" width="180" height="80" fill="#f5f5f5" stroke="#999" stroke-width="1.5" rx="6"/>
  <text x="110" y="55" text-anchor="middle" font-family="system-ui, sans-serif" font-size="14" font-weight="bold" fill="#333">Qhorus</text>
  <text x="110" y="75" text-anchor="middle" font-family="system-ui, sans-serif" font-size="11" fill="#666" font-style="italic">context_window_pct: 92</text>
  <text x="110" y="90" text-anchor="middle" font-family="system-ui, sans-serif" font-size="11" fill="#666" font-style="italic">fires alert, can't act</text>
  <rect x="260" y="30" width="180" height="80" fill="#f5f5f5" stroke="#999" stroke-width="1.5" rx="6"/>
  <text x="350" y="55" text-anchor="middle" font-family="system-ui, sans-serif" font-size="14" font-weight="bold" fill="#333">Engine</text>
  <text x="350" y="75" text-anchor="middle" font-family="system-ui, sans-serif" font-size="11" fill="#666" font-style="italic">tasks: 8/10</text>
  <text x="350" y="90" text-anchor="middle" font-family="system-ui, sans-serif" font-size="11" fill="#666" font-style="italic">blocks new, can't move</text>
  <rect x="500" y="30" width="180" height="80" fill="#f5f5f5" stroke="#999" stroke-width="1.5" rx="6"/>
  <text x="590" y="55" text-anchor="middle" font-family="system-ui, sans-serif" font-size="14" font-weight="bold" fill="#333">Agent Gate</text>
  <text x="590" y="75" text-anchor="middle" font-family="system-ui, sans-serif" font-size="11" fill="#666" font-style="italic">sessions: 5/5</text>
  <text x="590" y="90" text-anchor="middle" font-family="system-ui, sans-serif" font-size="11" fill="#666" font-style="italic">throws, can't shed</text>
  <rect x="50" y="140" width="600" height="40" fill="#fff3e0" stroke="#e65100" stroke-width="2" rx="8"/>
  <text x="350" y="165" text-anchor="middle" font-family="system-ui, sans-serif" font-size="14" font-weight="bold" fill="#333">Agent (overloaded)</text>
  <line x1="110" y1="110" x2="110" y2="140" stroke="#d32f2f" stroke-width="2" stroke-dasharray="6,4"/>
  <line x1="350" y1="110" x2="350" y2="140" stroke="#d32f2f" stroke-width="2" stroke-dasharray="6,4"/>
  <line x1="590" y1="110" x2="590" y2="140" stroke="#d32f2f" stroke-width="2" stroke-dasharray="6,4"/>
</svg>

The dashed lines are the problem. Each system can observe overload in its own metric. None can reach across and redistribute the agent's actual obligations.

## The feedback loop

The redistribution executor closes the loop. The platform's `CapacityPressureMonitor` sweeps every 60 seconds, aggregates all signal sources into a single pressure value per actor, and fires a CDI event for each actor above the threshold. The qhorus executor observes those events, queries the actor's open commitments, and decides what to do.

<svg viewBox="0 0 700 280" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <marker id="ah" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><path d="M0,0 L8,3 L0,6" fill="#555"/></marker>
    <marker id="ar" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><path d="M0,0 L8,3 L0,6" fill="#d32f2f"/></marker>
  </defs>
  <rect x="20" y="20" width="150" height="50" fill="#e3f2fd" stroke="#1565c0" stroke-width="1.5" rx="6"/>
  <text x="95" y="42" text-anchor="middle" font-family="system-ui, sans-serif" font-size="13" font-weight="bold" fill="#333">Sweep (60s)</text>
  <text x="95" y="56" text-anchor="middle" font-family="system-ui, sans-serif" font-size="10" fill="#666">getOverloaded(0.7)</text>
  <path d="M170,45 L230,45" stroke="#555" stroke-width="1.5" fill="none" marker-end="url(#ah)"/>
  <rect x="230" y="20" width="150" height="50" fill="#e3f2fd" stroke="#1565c0" stroke-width="1.5" rx="6"/>
  <text x="305" y="42" text-anchor="middle" font-family="system-ui, sans-serif" font-size="13" font-weight="bold" fill="#333">CDI Event</text>
  <text x="305" y="56" text-anchor="middle" font-family="system-ui, sans-serif" font-size="10" fill="#666">per overloaded actor</text>
  <path d="M380,45 L440,45" stroke="#555" stroke-width="1.5" fill="none" marker-end="url(#ah)"/>
  <rect x="440" y="20" width="160" height="50" fill="#fff8e1" stroke="#f57f17" stroke-width="1.5" rx="6"/>
  <text x="520" y="42" text-anchor="middle" font-family="system-ui, sans-serif" font-size="13" font-weight="bold" fill="#333">Policy</text>
  <text x="520" y="56" text-anchor="middle" font-family="system-ui, sans-serif" font-size="10" fill="#666">evaluate(context)</text>
  <path d="M520,70 L520,100" stroke="#555" stroke-width="1.5" fill="none" marker-end="url(#ah)"/>
  <rect x="30" y="100" width="130" height="45" fill="#e8f5e9" stroke="#2e7d32" stroke-width="1.5" rx="6"/>
  <text x="95" y="118" text-anchor="middle" font-family="system-ui, sans-serif" font-size="13" font-weight="bold" fill="#333">Hold</text>
  <text x="95" y="133" text-anchor="middle" font-family="system-ui, sans-serif" font-size="10" fill="#666">below threshold</text>
  <rect x="180" y="100" width="130" height="45" fill="#e8f5e9" stroke="#2e7d32" stroke-width="1.5" rx="6"/>
  <text x="245" y="118" text-anchor="middle" font-family="system-ui, sans-serif" font-size="13" font-weight="bold" fill="#333">Compress</text>
  <text x="245" y="133" text-anchor="middle" font-family="system-ui, sans-serif" font-size="10" fill="#666">0.7 – 0.85</text>
  <rect x="330" y="100" width="150" height="45" fill="#e8f5e9" stroke="#2e7d32" stroke-width="1.5" rx="6"/>
  <text x="405" y="118" text-anchor="middle" font-family="system-ui, sans-serif" font-size="13" font-weight="bold" fill="#333">Redistribute</text>
  <text x="405" y="133" text-anchor="middle" font-family="system-ui, sans-serif" font-size="10" fill="#666">≥ 0.85, HANDOFF</text>
  <rect x="500" y="100" width="130" height="45" fill="#e8f5e9" stroke="#2e7d32" stroke-width="1.5" rx="6"/>
  <text x="565" y="118" text-anchor="middle" font-family="system-ui, sans-serif" font-size="13" font-weight="bold" fill="#333">Escalate</text>
  <text x="565" y="133" text-anchor="middle" font-family="system-ui, sans-serif" font-size="10" fill="#666">stuck or inactive</text>
  <path d="M440,120 L480,120" stroke="#555" stroke-width="1.5" fill="none" marker-end="url(#ah)"/>
  <path d="M330,120 L310,120" stroke="#555" stroke-width="1.5" fill="none" marker-end="url(#ah)"/>
  <path d="M180,120 L160,120" stroke="#555" stroke-width="1.5" fill="none" marker-end="url(#ah)"/>
  <path d="M405,145 Q405,200 95,200 Q40,200 40,100 L40,70" stroke="#d32f2f" stroke-width="1.5" fill="none" stroke-dasharray="5,3" marker-end="url(#ar)"/>
  <text x="200" y="210" text-anchor="middle" font-family="system-ui, sans-serif" font-size="10" fill="#d32f2f">pressure drops → next sweep sees lower value</text>
  <text x="350" y="260" text-anchor="middle" font-family="system-ui, sans-serif" font-size="10" fill="#666">each HANDOFF reduces obligation count by 1</text>
  <text x="350" y="275" text-anchor="middle" font-family="system-ui, sans-serif" font-size="10" fill="#666">finite obligations → finite iterations → converges</text>
</svg>

The red dashed arrow is the convergence mechanism. Each HANDOFF moves one commitment to another agent — the overloaded actor's obligation count drops by one. The next sweep measures the new pressure. If it's still above threshold, another HANDOFF fires. Finite obligations, finite iterations, guaranteed termination.

## Why compression almost didn't make the cut

The first design had four decision levels. I nearly dropped compression entirely — it's indirect and unreliable. Channel summaries reduce context tokens, but only if the agent re-reads the channel. The context window is the agent's internal state; the summary is a qhorus-side artifact.

What saved it: multi-channel agents. An agent with open commitments across ten channels carries all ten histories in context. A single summary can replace hundreds of messages with a paragraph. For the common case — agents with many shallow channel interactions — compression is the cheapest effective intervention.

The executor treats it as fire-and-forget. Trigger channel summaries on stale channels, exit. The sweep cycle re-evaluates on the next tick. If compression worked, pressure dropped below threshold — done. If not, the policy escalates to redistribution naturally as pressure rises. No blocking, no state, no waiting for LLM-driven summary generation to complete.

## The guard that matters most

I enumerated ten failure modes. Nine are harmless or wasteful — the commitment state machine prevents double HANDOFFs, the watchdog catches circular delegation chains, crash recovery comes for free because the executor is stateless.

One was genuinely stuck: when the policy says Redistribute but no routing target exists for any commitment. The executor tries to HANDOFF, `RoutingBridge` rejects every candidate, obligation count stays the same, next sweep fires the same event, infinite loop.

The fix is two lines of code. After redistribution, check if any HANDOFFs succeeded. If zero succeeded and obligations exist, fire Escalate instead of waiting for the next sweep to try the same thing. The feedback loop needs an exit when the loop itself can't make progress.

## What shaped the executor

CDI shaped everything. `@ObservesAsync` runs on a managed executor thread — no request scope, no `CurrentPrincipal`, no `@Transactional`. Three garden entries saved real time here: the `@RequestScoped` constraint on async observers, the unreliable `@ObservesAsync` + `@Transactional` combination, and the separate delegate pattern that makes transactional work reachable from an async context.

The result is two classes. `QhorusRedistributionExecutor` is the observer — stateless, reads ground truth on each invocation, dispatches to the delegate. `RedistributionDelegate` is `@Transactional` with `@ActivateRequestContext` — it establishes a request scope, sets the tenant context per-commitment from the commitment's own `tenancyId`, and dispatches the HANDOFF through the full `MessageService.dispatch()` pipeline. The tenant context bridging was the subtlest part — each commitment may belong to a different tenant, and the HANDOFF dispatch needs the right tenant context for the downstream integrity checks.

The executor carries no state between sweeps. Obligations live in the commitment store. Pressure lives in the capacity view. Signal freshness lives in the ledger. Every invocation reads current state, acts, and exits. If the executor crashes mid-HANDOFF, the next sweep picks up exactly where things stand.

I added `capabilityTag` to the `Commitment` record — "what capability was this obligation assigned for?" — so the executor knows which `role:X` target to use when HANDOFFing. Pre-release, so the schema change costs nothing. But the data model was genuinely incomplete without it — commitments had who, where, and what type, but not for what capability. That's the redistribution target resolution, but it's also obligation analytics and routing diagnostics.

The vocabulary now meets reality. Platform defines the shared language. Qhorus reads the signals and acts on them. The loop converges because obligations are finite and each iteration makes measurable progress. When it can't make progress, it escalates instead of spinning.
