---
layout: post
title: "MongoDB preferences and the missing rung"
date: 2026-05-22
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
---

The `persistence-jpa` module backs `PreferenceProvider` with Postgres. The platform needed a second option: MongoDB, same SPI, no Flyway.

The CDI activation pattern is the interesting part. JPA uses plain `@ApplicationScoped` — it displaces the `@DefaultBean` mock automatically. MongoDB needs to beat both the mock and JPA when co-deployed. In CDI, a selected `@Alternative @Priority(1)` bean wins over a non-alternative `@ApplicationScoped` bean. The priority ladder ends up as:

    @DefaultBean (mock) < @ApplicationScoped (JPA) < @Alternative @Priority(1) (MongoDB)

`casehub-work` uses exactly this pattern for `MongoWorkItemStore` — I spotted it while reading the reference module. But it's not written down as a platform protocol anywhere. That gap is now tracked; the implementation follows the established practice regardless.

The document model has one choice that earns its explanation: `_id`. The default is `ObjectId` — auto-generated, plus a separate compound unique index to enforce business-key uniqueness, plus explicit filter logic for upserts. The alternative: encode the composite key as a string and use it directly as `_id`:

```java
public static String compoundId(String scope, String namespace,
                                String name, String subKey) {
    return scope + "|" + namespace + "|" + name + "|" + subKey;
}
```

The `|` delimiter is safe — scope uses `/`, namespace and name are alphanumeric. With the natural key as `_id`, MongoDB enforces uniqueness at the BSON level and `persistOrUpdate()` becomes a free upsert by identity. No extra index, no filter logic. When `preferences-editor` arrives it'll use this directly.

Scope resolution mirrors the JPA module: walk the path hierarchy root-first, query `{scope: {$in: ancestors}}`, sort by depth, fold into a map with child overrides parent. The first version of the query used Panache's string syntax — `list("scope in ?1", scopes)`. Claude flagged this: Panache MongoDB and Panache ORM share the same surface API but different query parsers. The ORM form is JPQL; there's no guarantee the MongoDB parser handles it the same way. We switched to:

```java
return list(Filters.in("scope", scopes));
```

`Filters` is part of the MongoDB Java driver, a transitive dependency of `quarkus-mongodb-panache`. The overload `list(Bson filter)` is always unambiguous.

Claude also caught the missing scope index. There's no Flyway for MongoDB — no migration step to create indexes automatically. A note in the Javadoc doesn't create the index. We added a startup bean:

```java
@Startup
@ApplicationScoped
class MongoPreferenceIndexes {
    @PostConstruct
    void ensureIndexes() {
        MongoPreferenceDocument.mongoCollection()
            .createIndex(Indexes.ascending("scope"));
    }
}
```

`createIndex` is idempotent — MongoDB ignores it if the index already exists. `@Startup` forces eager initialization so the index exists before any query reaches the collection.

Seven tests cover the full contract: exact scope, inherited from parent, child overrides, deeper child overrides grandparent, empty result returns key default, sibling scope ignored, multi-value subKey. Tests need Docker to run — same constraint as `casehub-work/persistence-mongodb`.
