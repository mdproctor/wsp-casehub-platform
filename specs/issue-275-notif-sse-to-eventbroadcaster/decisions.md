## D1: Serialization path

**Choice:** Use generic `EventBroadcaster.broadcast(topic, T)` — delegate serialization to pages-push `JsonWriter`
**Alternatives:**
- Explicit `broadcast(topic, objectMapper.writeValueAsString(obj))` — manual JSON string, keeps ObjectMapper control but adds try/catch boilerplate and diverges from the established pattern (SocTrustPushService, TicketPushObserver both use the generic form)
**Rationale:** Cleaner API, consistent with reference implementations, eliminates JsonProcessingException handling. ObjectMapper injection and manual serialization become unnecessary.
**Trade-offs:** Lose explicit control over Jackson ObjectMapper configuration — JsonWriter may serialize differently. Low risk since pages-push JsonWriter uses the CDI-provided ObjectMapper internally.
**Sources:** EventBroadcaster.class (decompiled), issue #275 reference implementations
**Exploration:** quick
**Status:** captured

## D2: Class identity after migration

**Choice:** Rename to `NotificationPushService`, keep `@ApplicationScoped`, remove `@Path` — no longer a JAX-RS resource
**Alternatives:**
- Keep class name `NotificationPushService` — avoids rename churn but leaves misleading name referencing a removed transport
- Rename to `NotificationPushObserver` — emphasises the CDI observer role but "observer" is a CDI concept that could confuse with `@Observes` annotation semantics
**Rationale:** "PushService" accurately describes the role (bridges CDI events to push delivery), follows the reference naming pattern (SocTrustPushService, SocIncidentPushService), and "Service" is the established suffix for `@ApplicationScoped` beans that do work.
**Trade-offs:** Rename touches references in docs and plans (consumer-guide.md, notification-store plan). IntelliJ refactoring handles code references; doc references are stale descriptions of the old pattern and should be updated.
**Sources:** SocTrustPushService, SocIncidentPushService naming in engine/soc, issue #275
**Exploration:** quick
**Status:** captured

## D3: Dependency scope for casehub-pages-push

**Choice:** Compile scope in notifications module POM
**Alternatives:**
- Provided scope — would require the deploying app to supply it, adding friction for no benefit since this module directly calls EventBroadcaster
**Rationale:** The notifications module directly injects and calls EventBroadcaster. Compile scope is the correct choice for a direct API dependency.
**Trade-offs:** Adds a new compile dependency to the notifications module. casehub-pages-push is lightweight (EventBroadcaster, TopicRegistry, SessionSender, EventStore, JsonWriter) and already on the platform classpath per issue #275.
**Sources:** notifications/pom.xml, issue #275 body
**Exploration:** quick
**Status:** captured
