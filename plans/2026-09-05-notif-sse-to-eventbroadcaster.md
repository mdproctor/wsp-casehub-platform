# Notification SSE-to-EventBroadcaster Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #275 — Migrate NotificationSseResource from SseEventSink to EventBroadcaster
**Issue group:** #275

**Goal:** Replace SSE push with WebSocket push via EventBroadcaster in the notifications module.

**Architecture:** Rename `NotificationPushService` → `NotificationPushService`, strip all SSE
connection management, inject `EventBroadcaster` from `casehub-pages-push`, and call
`broadcast(topic, payload)` from the existing CDI event observers. Topic scheme:
`notifications:{userId}:new`, `notifications:{userId}:updated`, `notifications:{userId}:unread-count`.

**Tech Stack:** Quarkus CDI, casehub-pages-push (`EventBroadcaster`), platform-api CDI events

## Global Constraints

- `casehub-pages-push` is compile scope (direct API dependency)
- Topic names use colon-delimited scheme: `notifications:{userId}:<event-type>`
- Serialization via `EventBroadcaster.broadcast(topic, T)` — no manual ObjectMapper usage
- `SessionIsolator` still required for `NotificationStore.unreadCount()` calls (JPA on virtual threads)

---

## Batch 1: Migrate to EventBroadcaster

### Task 1: Add dependency and rename class

**Files:**
- Modify: `pom.xml` (root — add managed dependency)
- Modify: `notifications/pom.xml`
- Rename: `NotificationPushService` → `NotificationPushService` (use `ide_refactor_rename`)

**Interfaces:**
- Produces: `NotificationPushService` class at `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationPushService.java`

- [ ] **Step 1a: Add casehub-pages-push to root POM dependencyManagement**

`casehub-pages-push` is not managed in any parent BOM. Add it to the root `pom.xml`
`<dependencyManagement>` section, after the `openhtmltopdf-pdfbox` entry:

```xml
            <dependency>
                <groupId>io.casehub</groupId>
                <artifactId>casehub-pages-push</artifactId>
                <version>0.2-SNAPSHOT</version>
            </dependency>
```

- [ ] **Step 1b: Add casehub-pages-push compile dependency to notifications/pom.xml**

Add after the `quarkus-arc` dependency block (version inherited from root):

```xml
        <!-- Push delivery via EventBroadcaster -->
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-pages-push</artifactId>
        </dependency>
```

- [ ] **Step 2: Rename NotificationSseResource → NotificationPushService via IntelliJ**

```
ide_refactor_rename(
  file: "notifications/src/main/java/io/casehub/platform/notification/rest/NotificationSseResource.java",
  line: 32, column: 14,
  newName: "NotificationPushService"
)
```

This updates the class name, the Logger reference, the filename, and any imports.

- [ ] **Step 3: Verify rename succeeded**

```
ide_find_class(query: "NotificationPushService", scope: "project_files")
```

Confirm the class is found at the new name. Also verify no stale references:

```
ide_search_text(query: "NotificationSseResource", filePattern: "*.java")
```

Expected: zero matches in Java files (doc references in `.md` files are expected and updated in Task 3).

- [ ] **Step 4: Compile to verify rename is clean**

Run: `mvn --batch-mode compile -pl notifications -am`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add notifications/
git commit -m "feat(#275): add pages-push dependency and rename NotificationSseResource → NotificationPushService"
```

### Task 2: Write failing tests, then rewrite implementation

**Files:**
- Create: `notifications/src/test/java/io/casehub/platform/notification/rest/NotificationPushServiceTest.java`
- Modify: `notifications/src/main/java/io/casehub/platform/notification/rest/NotificationPushService.java` (full rewrite)

**Interfaces:**
- Consumes: `NotificationPushService` class (from Task 1)
- Consumes: `EventBroadcaster.broadcast(String topic, T event)` from `casehub-pages-push`
- Consumes: `NotificationStore.unreadCount(String userId, String tenancyId)` from platform-api
- Consumes: `SessionIsolator.runIsolated(Callable<T>)` from platform-api

- [ ] **Step 1: Write the test class**

Create `notifications/src/test/java/io/casehub/platform/notification/rest/NotificationPushServiceTest.java`:

```java
package io.casehub.platform.notification.rest;

import io.casehub.pages.push.EventBroadcaster;
import io.casehub.platform.api.governance.SessionIsolator;
import io.casehub.platform.api.notification.AllNotificationsRead;
import io.casehub.platform.api.notification.Notification;
import io.casehub.platform.api.notification.NotificationCreated;
import io.casehub.platform.api.notification.NotificationSeverity;
import io.casehub.platform.api.notification.NotificationSource;
import io.casehub.platform.api.notification.NotificationStatus;
import io.casehub.platform.api.notification.NotificationStatusChanged;
import io.casehub.platform.api.notification.NotificationStore;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class NotificationPushServiceTest {

    private EventBroadcaster broadcaster;
    private NotificationStore store;
    private SessionIsolator sessionIsolator;
    private NotificationPushService service;

    @BeforeEach
    void setUp() {
        broadcaster = mock(EventBroadcaster.class);
        store = mock(NotificationStore.class);
        sessionIsolator = mock(SessionIsolator.class);
        when(sessionIsolator.runIsolated(any(java.util.function.Supplier.class))).thenAnswer(inv -> {
            var supplier = inv.getArgument(0, java.util.function.Supplier.class);
            return supplier.get();
        });
        service = new NotificationPushService(broadcaster, store, sessionIsolator);
    }

    private Notification testNotification(String userId, String tenancyId) {
        return new Notification(
                "notif-1", userId, tenancyId,
                "Test Title", "Test Body", "test-category",
                NotificationSeverity.INFO, null,
                new NotificationSource("evt-1", "case", "case-1", "actor-1"),
                NotificationStatus.UNREAD, Instant.now(), null, null);
    }

    @Test
    void onNotificationCreated_broadcastsToNewAndUnreadCount() {
        var notification = testNotification("user-1", "tenant-1");
        when(store.unreadCount("user-1", "tenant-1")).thenReturn(5L);

        service.onNotificationCreated(new NotificationCreated(notification));

        verify(broadcaster).broadcast(eq("notifications:user-1:new"), eq(notification));
        verify(broadcaster).broadcast(eq("notifications:user-1:unread-count"), any());
    }

    @Test
    void onNotificationStatusChanged_broadcastsToUpdatedAndUnreadCount() {
        var notification = testNotification("user-2", "tenant-1");
        when(store.unreadCount("user-2", "tenant-1")).thenReturn(3L);

        service.onNotificationStatusChanged(new NotificationStatusChanged(notification, NotificationStatus.UNREAD));

        verify(broadcaster).broadcast(eq("notifications:user-2:updated"), eq(notification));
        verify(broadcaster).broadcast(eq("notifications:user-2:unread-count"), any());
    }

    @Test
    void onAllNotificationsRead_broadcastsUnreadCountOnly() {
        when(store.unreadCount("user-3", "tenant-1")).thenReturn(0L);

        service.onAllNotificationsRead(new AllNotificationsRead("user-3", "tenant-1", 0));

        verify(broadcaster).broadcast(eq("notifications:user-3:unread-count"), any());
        verify(broadcaster, times(1)).broadcast(any(), any());
    }

    @Test
    void unreadCountFailure_logsAndDoesNotPropagate() {
        var notification = testNotification("user-4", "tenant-1");
        when(store.unreadCount("user-4", "tenant-1")).thenThrow(new RuntimeException("DB down"));

        service.onNotificationCreated(new NotificationCreated(notification));

        verify(broadcaster).broadcast(eq("notifications:user-4:new"), eq(notification));
        verify(broadcaster, times(1)).broadcast(any(), any());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl notifications -Dtest=NotificationPushServiceTest`
Expected: FAIL — `NotificationPushService` still has the old SSE constructor signature.

- [ ] **Step 3: Rewrite NotificationPushService**

Replace the entire class body. The new implementation:

```java
package io.casehub.platform.notification.rest;

import io.casehub.pages.push.EventBroadcaster;
import io.casehub.platform.api.governance.SessionIsolator;
import io.casehub.platform.api.notification.AllNotificationsRead;
import io.casehub.platform.api.notification.NotificationCreated;
import io.casehub.platform.api.notification.NotificationStatusChanged;
import io.casehub.platform.api.notification.NotificationStore;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.ObservesAsync;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

@ApplicationScoped
public class NotificationPushService {

    private static final Logger LOG = Logger.getLogger(NotificationPushService.class);

    private final EventBroadcaster broadcaster;
    private final NotificationStore store;
    private final SessionIsolator sessionIsolator;

    @Inject
    public NotificationPushService(
            EventBroadcaster broadcaster,
            NotificationStore store,
            SessionIsolator sessionIsolator) {
        this.broadcaster = broadcaster;
        this.store = store;
        this.sessionIsolator = sessionIsolator;
    }

    void onNotificationCreated(@ObservesAsync NotificationCreated event) {
        var notification = event.notification();
        String userId = notification.userId();

        broadcaster.broadcast("notifications:" + userId + ":new", notification);
        broadcastUnreadCount(userId, notification.tenancyId());
    }

    void onNotificationStatusChanged(@ObservesAsync NotificationStatusChanged event) {
        var notification = event.notification();
        String userId = notification.userId();

        broadcaster.broadcast("notifications:" + userId + ":updated", notification);
        broadcastUnreadCount(userId, notification.tenancyId());
    }

    void onAllNotificationsRead(@ObservesAsync AllNotificationsRead event) {
        broadcastUnreadCount(event.userId(), event.tenancyId());
    }

    private void broadcastUnreadCount(String userId, String tenancyId) {
        try {
            long count = sessionIsolator.runIsolated(
                    () -> store.unreadCount(userId, tenancyId));
            broadcaster.broadcast("notifications:" + userId + ":unread-count",
                    new UnreadCount(count));
        } catch (Exception e) {
            LOG.errorf(e, "Failed to broadcast unread count for user %s", userId);
        }
    }

    private record UnreadCount(long count) {}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl notifications -Dtest=NotificationPushServiceTest`
Expected: PASS — all 4 tests green.

- [ ] **Step 5: Run full module test suite**

Run: `mvn --batch-mode test -pl notifications`
Expected: BUILD SUCCESS — no regressions in existing tests.

- [ ] **Step 6: Commit**

```bash
git add notifications/
git commit -m "feat(#275): rewrite NotificationPushService to use EventBroadcaster

Replace SSE connection management with EventBroadcaster.broadcast() calls.
CDI observers unchanged — transport switches from SseEventSink to WebSocket
push via pages-push. Closes #275"
```

### Task 3: Remove quarkus-scheduler dependency and verify build

**Files:**
- Modify: `notifications/pom.xml` (remove `quarkus-scheduler` dependency)

**Interfaces:**
- Consumes: Verified that `@Scheduled` was only used by the removed `sweepStaleEmitters()` method

- [ ] **Step 1: Verify no other @Scheduled usage in module**

```
ide_search_text(query: "@Scheduled", filePattern: "*.java",
  paths: ["notifications/src/main/**"])
```

Expected: zero matches (the only usage was in the old SSE resource, now removed).

- [ ] **Step 2: Remove quarkus-scheduler dependency from notifications/pom.xml**

Remove this block from `notifications/pom.xml`:

```xml
        <!-- Quarkus Scheduler for SSE sweep -->
        <dependency>
            <groupId>io.quarkus</groupId>
            <artifactId>quarkus-scheduler</artifactId>
        </dependency>
```

- [ ] **Step 3: Full module build**

Run: `mvn --batch-mode install -pl notifications -am`
Expected: BUILD SUCCESS — compile + tests pass without scheduler.

- [ ] **Step 4: Commit**

```bash
git add notifications/pom.xml
git commit -m "chore(#275): remove quarkus-scheduler dependency — no longer needed after SSE removal"
```

## References

- [2026-09-05-notif-sse-to-eventbroadcaster-design.md] — design spec this plan implements
- [notifications/src/main/java/.../NotificationSseResource.java] — current implementation (pre-rename)
- [EventBroadcaster.class (casehub-pages-push)] — target API: `broadcast(String, T)`
- [GitHub #275] — focal issue
