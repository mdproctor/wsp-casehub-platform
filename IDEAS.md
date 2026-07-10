# Idea Log

Undecided possibilities — things worth remembering but not yet decided.
Promote to an ADR when ready to decide; discard when no longer relevant.

---

## 2026-06-04 — preferences-editor: admin UI/API write path

**Priority:** low
**Status:** active

An admin-facing UI and write-path API for the preferences system. Would allow operators to manage scoped preferences without direct DB access. Scale XL, high complexity — too large to carry in What's Next without a concrete driver.

**Context:** Carried in What's Next since early sessions, never promoted. Parked to keep the backlog signal clean.

**Promoted to:**

---

## 2026-07-10 — Shared situation awareness: notification inbox as agent cognition surface

**Priority:** exploratory
**Status:** active

LLM agents as first-class notification subscribers, using the same inbox and delivery infrastructure humans use. The notification system already provides subscriptions (event-driven, content-addressable), delivery tracking, and read receipts. If an agent's awareness surface is a notification inbox visible to humans, you get agent observability for free — humans can see what events reached the agent, when it "read" them, and what it hasn't processed yet.

This is distinct from agent messaging (bidirectional communication) and work items (stateful tasks). The inbox becomes a window into agent cognition — making what-the-agent-knows legible through the same UI humans use for themselves.

**Open questions:**
- Is this awareness/observability, or does it shade into event-driven agent activation (engine#688)?
- How does it interact with messages (conversational, threaded) vs notifications (broadcast, no response expected)?
- Does the notification center UI (#146) need an "agent view" or is the same view sufficient?
- Relationship to CaseMemoryStore — is the inbox complementary to memory, or a different lens on the same thing?

**Promoted to:**
