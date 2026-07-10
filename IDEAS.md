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

### Event vs notification vs message

Three distinct interaction patterns with different time expectations:

- **Event** — "act now." Flows through the alpha network, triggers immediate processing (DataSourceTrigger, subscription matching). Near-real-time.
- **Notification** — "be aware." Lands in an inbox for consumption at the recipient's pace. Asynchronous.
- **Message** — "respond." Conversational, threaded, expects a reply. Bidirectional.

For LLMs, the event/notification split maps differently than for humans. An agent doesn't have "busy" and "free" the way a human does — it either has session capacity or it doesn't. From the agent's perspective, a notification arriving in its inbox IS an event it can process immediately if capacity exists, or queue if it doesn't (delivery tracking + retry already handles this).

### Unification hypothesis

Collapse notifications and messages into a single agent inbox. The inbox becomes the agent's universal input channel — everything it needs to know or respond to arrives there. Messages are just notifications with a reply-to expectation. The human UI is a lens onto that same stream: a human looking at an agent's inbox sees both "case X changed status" (notification) and "user asked you to review this" (message) in one place.

The notification infrastructure already built — subscriptions, delivery channels, digests, tracking, retry — becomes the universal agent input bus.

### Gap: agent-facing eventing/messaging architecture

Platform has Kafka integration (streams-kafka), endpoints, and the notification delivery/tracking/retry pipeline. But these exist as separate capabilities with no unified agent-facing eventing architecture:

- **Kafka** provides at-least-once delivery and consumer group semantics out of the box, but no application-level tracking (did the agent process it? did it fail? should it retry with backoff?).
- **Notification delivery tracking** (delivery-tracking-inmem/jpa) provides exactly this — per-delivery attempt recording, retry with exponential backoff, claim semantics — but is currently wired only to the notification dispatch path, not to arbitrary agent event consumption.
- **No agent event guaranteed delivery** — if an agent receives an event via DataSource subscription and fails mid-processing, there's no retry. The event is lost from the agent's perspective.
- **No agent delivery receipts** — humans get read/delivery tracking; agents have no equivalent acknowledgement that an event was received and processed.

The delivery tracking infrastructure built for #154 (DeliveryAttemptStore, DeliveryRetryProcessor, claimRetryable with SELECT FOR UPDATE SKIP LOCKED) is generic enough to serve as the foundation for agent event delivery guarantees — it just isn't wired that way yet.

**Open questions:**
- Is this awareness/observability, or does it shade into event-driven agent activation (engine#688)?
- Does the notification center UI (#146) need an "agent view" or is the same view sufficient?
- Relationship to CaseMemoryStore — is the inbox complementary to memory, or a different lens on the same thing?
- Should DeliveryAttemptStore be generalised beyond notification dispatch to become a universal delivery tracking layer for all agent-bound events?
- What's the boundary between Kafka's delivery guarantees and application-level agent delivery tracking? (Kafka guarantees the message reached a consumer; the app needs to guarantee the agent actually processed it.)
- Does agent event processing need idempotency keys, or is at-least-once with retry sufficient?

**Promoted to:**
