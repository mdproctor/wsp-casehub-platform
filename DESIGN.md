# casehub-platform Design

## Persistence Modules

`persistence-mongodb/` implements `PreferenceProvider` via MongoDB Panache.
The CDI activation pattern follows the persistence-backend priority ladder
established in `casehub-work`: `@DefaultBean` (mock) < `@ApplicationScoped`
(JPA) < `@Alternative @Priority(1)` (MongoDB). Adding the module to the
classpath silently promotes MongoDB as the active backend with no consumer
changes. Scope hierarchy resolution is identical to the JPA module — a
`$in` ancestor query sorted root-first, child overrides parent. A startup
bean creates the `scope` index idempotently. `preferences-editor` (#8)
owns the write path; this module is read-only from the SPI perspective.
The persistence-backend CDI ladder is being formalised as a platform
protocol (casehubio/parent#44).
