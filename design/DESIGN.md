# casehub-platform Design

Zero-dependency foundational SPIs and mock implementations shared across all casehubio modules.
Publishes before everything else in the build order.

---

## Module Structure

Two-module structure enforced strictly: platform-api (Tier 1, zero production
dependencies — pure Java interfaces, records, and final classes) and platform
(Tier 3, Quarkus @DefaultBean mocks). platform-api must never acquire a Quarkus,
JPA, or casehubio import — violations cause cascading datasource failures in all
consumers. platform/ owns @DefaultBean @ApplicationScoped beans for every SPI,
each configurable via @ConfigProperty and displaceable by any non-default
@ApplicationScoped implementation in consumer deployments.

A third module, testing/ (casehub-platform-testing), ships @Alternative @Priority(1)
fixtures for identity SPIs: FixedCurrentPrincipal and InMemoryGroupMembershipProvider.
Follows the casehub-work-testing pattern: fixtures live in src/main/java of the testing
artifact, consumers declare test-scoped dependency, CDI selects automatically. No
quarkus-arc dependency — CDI API (provided) and Jandex only. Preference testing does
not require an in-memory fixture — MockPreferenceProvider.get(key) now returns typed
values via key.parse().

## Path API

Path is a record with strict validation: segments must be non-blank, no leading,
trailing, or consecutive separators. Two construction paths are intentionally
distinct: Path.of(String...) takes explicit pre-validated segments (use for
programmatic construction), Path.parse(String) delegates to a PathParser strategy
whose separator is installation-wide config (casehub.platform.path.separator,
default /). This separation prevents round-trip mutation — Path.of("a/b") is
rejected; Path.parse("a/b") is the correct idiom for raw string input.
PathParserConfigurator (@Startup) wires the config-driven parser at application
start. Harness convention: Path.of("casehubio", "<app>", "<case-type>") for
SettingsScope construction — org segment, app segment, case-type segment — so the
inheritance chain resolves correctly up through devtown to casehubio.

## Preferences API

PreferenceKey<T extends Preference> is a record carrying namespace, name, defaultValue,
and a Function<String, T> parser. key.parse(raw) converts a config string (already
interpolated) to a typed preference value — the Drools get(String) factory pattern
colocated with the key definition. This enables MockPreferenceProvider.get(key) to
return typed values via MapPreferences.get() calling key.parse() on String values,
eliminating the need for a separate InMemoryPreferenceProvider test fixture. get(key)
returns null when no override is configured; getOrDefault(key) applies key.defaultValue()
automatically. Real business defaults live in the harness properties file (future config/
module); key.defaultValue() is a type-safe null guard only. The Function component breaks
record value equality — keys must be compared via key.qualifiedName(), not equals().
MapPreferences uses an instanceof guard before casting: a wrong-type map entry returns null
rather than ClassCastException. asMap() returns typed Java values (Integer, Long, Boolean,
Double, List, String) — not raw strings — so any pluggable ExpressionEvaluator receives
the correct type.

## Identity API

CurrentPrincipal is intentionally minimal: actorId(), groups(), and four defaults
(roles(), hasGroup(), isSystem(), isAuthenticated()). roles() delegates to groups()
by convention — this documents the groups-as-roles contract and wires directly to
@RolesAllowed without an interface change when RBAC is implemented. isAuthenticated()
uses "anonymous" as the unauthenticated sentinel; "system" is the default actorId
in dev/test. Real implementations must be @RequestScoped backed by SecurityIdentity;
@RequestScoped beans injected into @ApplicationScoped REST resources are handled
safely by CDI client proxies. The mock is intentionally @ApplicationScoped — it has
no request context to read from. @ActivateRequestContext is required before accessing
CurrentPrincipal in reactive pipelines.

## Mock Implementation Pattern

Every SPI in platform-api gets a @DefaultBean @ApplicationScoped mock in platform/.
Mocks read all configuration via @ConfigProperty — no hardcoded values. Optional<T>
is used for fields where the config key may be absent (e.g. Optional<List<String>>
for groups, Optional<Map<String,String>> for preference defaults) because SmallRye
Config throws NoSuchElementException for absent keys on non-Optional types. @DefaultBean
yields to any non-default @ApplicationScoped bean, so consumer deployments displace
the mock by providing their own implementation — no exclusion config required.

PreferenceProvider is permanently read-only — no save() or update() will ever be added.
The write path is a separate preferences-editor module (future) that writes directly to
the backend; provider and editor never call each other. This separation holds across all
provider variants: config/ (YAML + env vars, read-only by nature), persistence-jpa/,
persistence-mongodb/. The config/ module is the Drools ChainedProperties equivalent —
each harness ships its own preferences YAML file using the platform's key/value types,
following the Drools pattern where any domain has its own properties file while sharing
the OptionKey<T> infrastructure.
