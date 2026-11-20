---
layout: post
title: "The Classloader Nobody Checks"
date: 2026-11-20
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [apt, jandex, maven, spring-parity, classloader]
---

# The Classloader Nobody Checks

The authn module had three endpoint classes — `ConnectionEndpoint`, `WebAuthnEndpoint`, `SocialAuthEndpoint` — each `@ApplicationScoped` with CDI field injection and `@McpDomain` annotations. The graphql-generator APT found them in the `RoundEnvironment`, generated JAX-RS resources, and everything worked.

Spring parity meant running the graphql-spring-generator on the same domain types to produce Spring MVC controllers. But the Spring generator is a Maven plugin that scans Jandex indexes from explicit `<quarkusModules>` directories. CDI endpoint classes with `@Inject` can't be Spring beans. The types needed to be framework-neutral.

The extraction itself was mechanical — three constructor-injected POJOs in `authn-core`, each carrying the `@McpDomain` and `@PlatformQuery`/`@PlatformMutation` annotations from the CDI originals. The CDI endpoints got deleted. `AuthnBeans` gained three `@Produces` methods for the core POJOs. Standard core-module pattern, same as `AclServiceCore` or `RegistrationServiceCore`.

Then the APT produced zero output. No warnings, no errors. Just nothing.

The `domainFilter=connections,webauthn,social-auth` warning said "matched zero domains." The core POJOs existed in `authn-core` with Jandex indexes. The `authn` module depended on `authn-core`. The compilation classpath had everything it needed.

The problem was in one line of the APT scanner:

```java
ClassLoader cl = getClass().getClassLoader();
Enumeration<URL> resources = cl.getResources("META-INF/jandex.idx");
```

`getClass().getClassLoader()` returns the annotation processor's classloader — the one populated from `<annotationProcessorPaths>` in the Maven compiler plugin config. Not the compilation classpath. Not the module's dependency tree. The processor classpath.

The `authn/pom.xml` had:

```xml
<annotationProcessorPaths>
    <path>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-graphql-generator</artifactId>
        <version>${project.version}</version>
    </path>
</annotationProcessorPaths>
```

Only the generator JAR (and its transitive dependencies) was visible. `authn-core` — with the `@McpDomain` POJOs and their Jandex index — sat on the compilation classpath where the APT couldn't see it.

The fix:

```xml
<annotationProcessorPaths>
    <path>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-graphql-generator</artifactId>
        <version>${project.version}</version>
    </path>
    <path>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-authn-core</artifactId>
        <version>${project.version}</version>
    </path>
</annotationProcessorPaths>
```

This had always been invisible because every other module with `@McpDomain` types kept those types in the same compilation unit — the `RoundEnvironment` scan found them directly. The Jandex path only matters when the domain types live in a dependency JAR, and no module had done that before.

The graphql-spring-generator never hit this problem because it's a Maven plugin with explicit `<quarkusModules>` configuration — it scans the target/classes directory of each named module directly. Different scanning mechanism, different classpath model, no silent failure.

The Spring side now generates six controllers — three REST, three GraphQL — from the same core POJOs that the Quarkus APT generates JAX-RS resources from. One set of `@McpDomain` types, two frameworks, two different scanning mechanisms, both producing the right output.

The lesson is specific to APT-based code generation: `getClass().getClassLoader()` in an annotation processor does not see the compilation classpath. If your APT scans for classpath resources (Jandex indexes, service loader files, anything under `META-INF/`), the module providing those resources must appear in `annotationProcessorPaths` — not just in `<dependencies>`. The compilation succeeds either way. The APT silently finds nothing.
