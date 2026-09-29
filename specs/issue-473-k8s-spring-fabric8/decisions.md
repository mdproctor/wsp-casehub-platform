## D1: Scope — expression layer parity only

**Choice:** Spring Environment-backed SecretManager + ConfigManager, with spring-cloud-kubernetes-fabric8-config as optional backend. No KubernetesClient bean, no K8s starter.
**Alternatives:**
- Expression + KubernetesClient bean — adds platform-k8s-spring module. Out of scope: Quarkus doesn't wrap KubernetesClient either; consumers add quarkus-kubernetes-client directly.
- Expression + KubernetesClient + K8s starter — aggregation POM. Premature: no consumer demand yet.
**Rationale:** Mirrors Quarkus parity exactly. Platform's K8s role is limited to config/secret reading via the config abstraction layer.
**Trade-offs:** Consumers needing KubernetesClient must add spring-cloud-kubernetes-fabric8-autoconfig directly.
**Sources:** expression/MockSecretManager.java, expression/MockConfigManager.java, expression/pom.xml (quarkus-kubernetes-config optional dep)
**Exploration:** quick
**Status:** captured

## D2: Module structure — standard dual-framework extraction

**Choice:** Extract config/secret logic to expression-core POJOs, keep Quarkus expression/ as thin CDI wrapper, create expression-spring as Spring auto-config wrapper.
**Alternatives:**
- Hand-written expression-spring without core extraction — duplicates logic across frameworks, violates established pattern.
- Add to platform-spring — conflates expression SPIs with platform concerns.
**Rationale:** Consistent with every other module in the platform (credentials-spring, scim-spring, oidc-spring, etc.).
**Trade-offs:** Refactors the Quarkus side too (MockConfigManager/MockSecretManager become delegating wrappers). Low risk — no behavioral change.
**Sources:** credentials-spring/EnvironmentCredentialResolver.java, credentials-spring/CredentialsSpringAutoConfiguration.java, expression-core/ (existing engines)
**Exploration:** quick
**Status:** captured

## D3: Property lookup abstraction — thin PropertySource interface

**Choice:** New `PropertySource` interface in expression-core with `getProperty(String)` → `Optional<String>` and `getPropertyNames()` → `Iterable<String>`. Core POJOs take PropertySource in constructor.
**Alternatives:**
- Function<String, Optional<String>> + Supplier<Iterable<String>> — simpler but less self-documenting.
- MicroProfile Config API as compile dep — adds external dependency to expression-core, which should stay minimal.
**Rationale:** ConfigManager/SecretManager SPIs are the domain abstraction; PropertySource is the framework-neutral config-reading abstraction underneath. Both SmallRye Config and Spring Environment adapt to it trivially.
**Trade-offs:** Type conversion for multiConfig handled in core via comma-split + valueOf, not framework-native converters.
**Sources:** platform-api SecretManager SPI, platform-api ConfigManager SPI
**Exploration:** quick
**Status:** captured

## D4: K8s dependency — optional dep in expression-spring

**Choice:** Declare spring-cloud-kubernetes-fabric8-config as `<optional>true</optional>` in expression-spring pom.xml.
**Alternatives:**
- Documentation only — keeps module dependency-free but inconsistent with Quarkus side.
**Rationale:** Exact parity with Quarkus side, where expression/pom.xml has `<optional>true</optional>` on quarkus-kubernetes-config.
**Trade-offs:** None significant — optional deps don't propagate transitively.
**Sources:** expression/pom.xml line 56
**Exploration:** quick
**Status:** captured
