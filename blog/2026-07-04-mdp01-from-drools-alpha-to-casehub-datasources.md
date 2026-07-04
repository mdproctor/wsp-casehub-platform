# From Drools Alpha Networks to CaseHub DataSources

The platform needed event routing. Not the kind where a CDI observer catches everything and filters manually — the kind where you declare what you care about and the infrastructure does the rest.

I'd been building exactly this in Drools vol2. The alpha network — type discrimination first, then predicate filters, then fan-out to subscribers. It's the single-object half of Rete, and it's what turns a firehose of events into precisely routed notifications. The code was sitting in `droolsvol2/src/test/java/org/drools/core` — `DataSourceTest`, `MultiTypeDataStoreTest`, the works.

Claude and I spent a session pulling the design apart. The Drools model has `DataStore<T>` with add/update/remove and `ObjectHandle` lifecycle. CaseHub only needs add — events flow in, get typed, get filtered, get delivered. No working memory, no retractions, no handle management. The alpha network is the same; the data lifecycle is simpler.

## The boundary question

The interesting design decision was what a DataSource actually *is*. In the Sink/Source model it's a boundary concept — where data enters your system. An EndPoint is infrastructure (URL, protocol, credentials). A DataSource is the logical boundary you wire that EndPoint into.

I initially thought filtered views should themselves be DataSources — composable, elegant. Claude pushed back on that. A filter isn't a new boundary; it's a narrower lens on the same one. A DataSource is where data *enters*. A subscription with type and filter criteria is how you *consume* it. The Drools vol2 code actually agrees — `Filter1Type` and `Filter1AlphaProcessor` are processors in the network, not DataSources. Only `PropagatingDataStore` is the source.

This matters because the engine's `Binding` concept dovetails directly. A Binding connects a trigger to a case. Today there's `ContextChangeTrigger` and `ScheduleTrigger`. A DataSource-backed trigger would be the third — "a Binding binds a DataSource to a case." The naming lands naturally when the concepts are clean.

## Dynamic filters and the MVEL3 question

The notification routing use case needs dynamic filters — expressions defined at registration time, not compiled into the codebase. jq handles raw CloudEvent attribute filtering (no deserialisation needed), but POJO field filtering needs something that compiles to bytecode.

I considered CEL, but it's protobuf-native. Getting it to work on Java POJOs requires either a Nessie fork with Jackson bridging or Map conversion — both lossy. MVEL3 is the right answer: it transpiles MVEL expressions to Java source via JavaParser, compiles to bytecode via `KieMemoryCompiler`, and the resulting `Evaluator` instances run at native speed. The `LambdaCatalog` gives you content-based identity for free, which means the alpha network can share filter nodes for structurally identical expressions.

MVEL3 isn't on Maven Central yet — it depends on a forked JavaParser and `drools-compiler`. So the initial implementation mocks it. The pluggable `ExpressionEvaluator` interface means swapping in the real thing when it ships is a no-op at the SPI level.

## What shipped

The alpha network implementation follows Drools vol2's architecture — `TypeNode` for O(1) type discrimination, `FilterNode` for predicate chains, `FanOutProcessor` for subscriber delivery with per-subscriber error isolation. A `DataSourceRouter` in the platform module bridges CDI `CloudEvent` events into registered DataSources using tenancy-based routing.

The adversarial design review caught two real gaps: the router wasn't discovering pre-startup DataSources (silently dropping `@Startup` bean registrations), and the NoOp registry returned null from `register()` instead of a stub. Both would have been production bugs.

Three consumers will wire into this: RAS for detection routing, Qhorus for message routing, and the engine for external event triggers. RAS is first — it already does manual type discrimination on every CloudEvent. The alpha network makes that redundant.
