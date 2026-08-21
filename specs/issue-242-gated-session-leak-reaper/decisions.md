## D1: Module placement

**Choice:** Reaper lives inside agent-gate module
**Alternatives:**
- Separate module with CDI event observation — unnecessary decoupling; would require exposing GatedAgentSession internals that are currently package-private
**Rationale:** The reaper is tightly coupled to GatedAgentSession internals (creation timestamps, open state, force-close). Package-private access avoids new public API surface.
**Trade-offs:** Cannot be deployed independently of agent-gate (acceptable — it's a safety net for agent-gate's own sessions)
**Sources:** GatedAgentSession.java (package-private), GatedAgentProvider.java (@Decorator)
**Exploration:** quick
**Status:** captured

## D2: Force-close semantics

**Choice:** Graceful close with short timeout (5s) on the delegate session
**Alternatives:**
- Slot-only release (release semaphore, ignore delegate) — recovers capacity immediately but orphans subprocesses
- No force-close at all — WARN only, rely on caller to fix
**Rationale:** AgentSession.close(maxWait) already handles async subprocess teardown. A short timeout avoids blocking the reaper while still attempting cleanup.
**Trade-offs:** Reaper thread blocks for up to 5s per force-closed session. Acceptable — force-close is rare (disabled by default) and sessions are closed sequentially.
**Sources:** AgentSession.java (close contract, async teardown), PP-20260617-609995 (resource ownership)
**Exploration:** quick
**Status:** captured

## D3: Session tracking mechanism

**Choice:** ConcurrentHashMap registry in GatedAgentProvider
**Alternatives:**
- WeakReference + ReferenceQueue — GC-timed detection is unpredictable; cannot force-close GC'd sessions; cannot warn at configurable threshold
- CDI event-based tracking with external observer — unnecessary decoupling; requires new public event types; CDI async overhead; observer still needs access to close() for force-close
**Rationale:** GatedAgentProvider already creates every GatedAgentSession. A ConcurrentHashMap<GatedAgentSession, Instant> is the simplest registry — zero allocation overhead beyond one entry per session, package-private, no new public API.
**Trade-offs:** Couples the reaper scan to GatedAgentProvider (but the reaper is inherently coupled to gate internals)
**Sources:** GatedAgentProvider.java (openSession creates all gated sessions), ConcurrencyStrategy.java (Semaphore leak target)
**Exploration:** quick
**Status:** captured
