# Design Journal — issue-23-jq-expression-module

### 2026-05-22 · §Module Structure

New optional module `expression/` (artifact `casehub-platform-expression`) added following the same Jandex library module pattern as `config/` and `oidc/`. Provides canonical Foundation-tier JQ expression evaluation: `JQEvaluator` (`@ApplicationScoped`, expression caching via `ConcurrentHashMap<String, JsonQuery>`), `ValidationResult` record, and `@DefaultBean` mocks for `SecretManager` and `ConfigManager` (the mocks ship in `expression/` not `platform/` — they are only needed when using the evaluator, so the module is self-contained). `SecretManager`, `ConfigManager`, `SecretNotFoundException`, `ConfigMapNotFoundException` are pure Java SPIs added to `platform-api/` under `io.casehub.platform.api.expression`. Consumer migration tracked in casehubio/engine#320 and casehubio/work#207.
