# Decisions — YAML Agent Interaction Steps (#681)

## D1: Scope — Full interaction matrix

**Choice:** Full matrix (64 valid patterns across all dimensions)
**Alternatives:**
- Practical subset (~12 patterns) — faster but doesn't prove YAML can express the full surface
- Core + extensible (~8 patterns) — flexible but less test coverage
**Rationale:** Push "pure YAML" to its limits and prove every interaction pattern works end-to-end, not just invoke
**Trade-offs:** More test playbooks and config fixtures to maintain
**Sources:** agent-api/ Java surface, agent-session-core/ pool API, wacky-manor example
**Exploration:** quick
**Status:** captured

## D2: Pool lifecycle config location

**Choice:** Manifest only — all pool config in agent-config.yaml or inline pool declaration. No step-level overrides.
**Alternatives:**
- Manifest + step overrides — more flexible but blurs infrastructure/logic boundary
- Manifest + session-open overrides — middle ground, session-level tuning
**Rationale:** Clean separation: ops controls infrastructure, app controls logic. Consistent with how model aliases work today.
**Trade-offs:** Less flexibility for per-step tuning; must declare a new pool for different lifecycle params
**Sources:** agent-config-core/ ManifestLoader, PoolDeclaration schema
**Exploration:** quick
**Status:** captured

## D3: Pool checkout mechanism

**Choice:** Implicit in agent-session-open — specifying `pool: name` on session-open handles checkout transparently
**Alternatives:**
- Explicit pool steps (agent-pool-checkout/release) — more control but exposes plumbing
- Both available — implicit default, explicit for advanced cases
**Rationale:** YAML author thinks in sessions, not pool mechanics. Pool is an implementation detail of where the session comes from.
**Trade-offs:** No fine-grained control over checkout/release timing
**Sources:** SessionPool.checkout(), SessionLifecycleManager.acquire()
**Exploration:** quick
**Status:** captured

## D4: Default pool behavior

**Choice:** Implicit default — if exactly one pool is declared, steps use it automatically without `pool:` attribute
**Alternatives:**
- Always explicit — every step must say `pool: name`
- Top-level default-pool + overrides
**Rationale:** Single-pool is the common case; explicit naming only needed when multiple pools exist
**Trade-offs:** Slightly less obvious which pool is used when reading the YAML
**Sources:** N/A — UX decision
**Exploration:** quick
**Status:** captured

## D5: Multiple pools and declaration locations

**Choice:** Multiple named pools supported, declarable both in manifest (agent-config.yaml) and inline in playbooks
**Alternatives:**
- Single pool only — simpler but can't express different lifecycle params per role
- Manifest only — no inline declaration
**Rationale:** Pools can be enabled/disabled or sit idle independently. Different roles (voice, email, WhatsApp) need different lifecycle params on the same backend. Inline declaration lets playbooks be self-contained.
**Trade-offs:** More config surface area to learn and test
**Sources:** SessionPoolRegistry (ConcurrentHashMap keyed by backendKey), PoolDeclaration schema
**Exploration:** quick
**Status:** captured

## D6: Step type design — session-centric

**Choice:** 6 custom step types: agent-invoke, agent-session-open, agent-query, agent-session-clear, agent-session-close. Batch via parallel/forEach composition.
**Alternatives:**
- Task-centric (7 steps with dedicated agent-batch) — more batteries-included but overlaps with parallel+forEach
- Session-centric + sugar — start with 6, add batch later if needed
**Rationale:** Composes cleanly with existing structural steps. The playbook language already has powerful parallel/forEach/concurrent/race. Adding batch duplicates existing capability.
**Trade-offs:** Parallel batch requires composing forEach + parallel + agent-query instead of one step
**Sources:** playbook-compiler step compilers (ParallelCompiler, ForEachCompiler, etc.)
**Exploration:** quick
**Status:** captured

## D7: Admission gate — global with salience-based scheduling

**Choice:** Global admission gate shared across all pools. Salience-based scheduling: default 0 (fair round-robin), elevated salience pools monopolize prompt capacity until idle.
**Alternatives:**
- Per-pool admission — each pool has independent concurrency control
- Priority tiers — higher priority gets first slot but doesn't monopolize
- FIFO — strict first-come-first-served, no priority
**Rationale:** Key innovation: capacity limited by active prompts, not open sessions. All pools share the same LLM executor underneath. Salience captures "this pool runs until idle, then yields" — useful for live voice calls vs async channels.
**Trade-offs:** Higher-salience pools can starve lower-salience pools under sustained load. Non-preemptive within a running prompt.
**Sources:** AimdAdmissionStrategy (normal + priority waiters), SessionPipeline.executeSingle()
**Exploration:** deep-analysis
**Status:** captured
**Depends on:** D5 (multiple pools)
