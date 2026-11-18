---
title: "The Parse You Already Paid For"
date: 2026-11-18
entry_type: note
subtype: diary
author: mdp
projects: [casehub-platform]
tags: [jackson, yaml, parser, source-location, deserializer, extension-point, language-tooling]
series: casehub-platform
---

# The Parse You Already Paid For

Jackson's YAML module wraps SnakeYAML. When you call `mapper.readValue(yaml, YamlModuleFile.class)`, SnakeYAML parses the YAML stream into tokens. Jackson reads those tokens. Jackson creates your maps and lists. SnakeYAML had the source positions the whole time — line 3, column 5, right there on the token — and Jackson's deserialiser threw them away while building exactly the objects you wanted to annotate.

The earlier approach was to parse twice: once with Jackson for the typed structure, once with SnakeYAML's compose API for position tracking, then bridge the positions from SnakeYAML-created objects to Jackson-created objects via an identity-walking `transferFrom` method. It worked. It was also doing twice the work for information that was available during the first pass.

## Intercepting object creation

Jackson's `BeanDeserializerModifier` lets you wrap the deserialiser that creates maps and lists. The wrapper is three lines of meaningful code:

```java
public Object deserialize(JsonParser p, DeserializationContext ctxt)
        throws IOException {
    JsonLocation loc = p.currentTokenLocation();
    Object result = super.deserialize(p, ctxt);
    LocationTrackingHelper.recordLocation(ctxt, result, loc);
    return result;
}
```

Capture the parser's current location before delegating. After delegation creates the map or list, record the object's identity and position in a `LocationIndex`. The index travels through the parse via `DeserializationContext.setAttribute` — set it on an `ObjectReader` before parsing, and every map and list created during that parse gets its position recorded.

The key insight is that Jackson's `UntypedObjectDeserializer` — the one that handles `readValue(yaml, Object.class)` — delegates to custom map and collection deserialisers when they're registered through the modifier. It doesn't bypass the extension point. This means a single module handles both typed deserialisation (where you get a `YamlModuleFile` with positioned internal maps) and untyped deserialisation (where you get raw `LinkedHashMap`/`ArrayList` trees for playbook parsing).

## What goes away

The module file path was the worst case. Before:

```
Jackson parse → YamlModuleFile
SnakeYAML parse → raw maps with positions
transferFrom(snakeMap, jacksonMap) → walk parallel trees, copy positions
```

After:

```
Jackson parse → YamlModuleFile (positions recorded during creation)
```

One parse. No bridge. The positions belong to the actual map instances that downstream code will touch — not copies that were walked into alignment.

The main playbook path was simpler — it was already a single SnakeYAML parse. But it was also the only reason `PlaybookParser` imported SnakeYAML's compose API directly. Switching it to Jackson's `MappingIterator` for multi-document parsing removes the last direct SnakeYAML usage from the runtime.

## Scalar resolution

The one thing that could have gone wrong: YAML's scalar resolution. SnakeYAML treats `yes`, `no`, `on`, `off` as booleans (YAML 1.1). The old `resolveScalar` method handled this explicitly. Jackson's YAML parser also uses SnakeYAML internally — the same resolution happens at the token level before Jackson sees it. `yes` arrives as `VALUE_TRUE`, not as the string `"yes"`. Quoted `"yes"` arrives as `VALUE_STRING`. The types match without any compatibility shim.

## The pattern as a reusable tool

The `LocationTrackingModule` sits in `yaml-jackson` alongside the existing Jackson mixins. Any consumer that wants position tracking registers the module on their `ObjectMapper` and passes a `LocationIndex` via `ObjectReader.withAttribute`. Consumers that don't want tracking don't register the module — zero overhead, no code change.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 320">
  <defs>
    <marker id="arrowhead" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#555"/>
    </marker>
  </defs>

  <!-- Background -->
  <rect width="720" height="320" fill="#fafafa" rx="4"/>

  <!-- YAML Source -->
  <rect x="20" y="40" width="140" height="60" rx="6" fill="#e8f5e9" stroke="#66bb6a" stroke-width="1.5"/>
  <text x="90" y="65" text-anchor="middle" font-family="system-ui" font-size="12" font-weight="bold" fill="#2e7d32">YAML Source</text>
  <text x="90" y="82" text-anchor="middle" font-family="monospace" font-size="10" fill="#555">steps:</text>

  <!-- YAMLParser (SnakeYAML inside) -->
  <rect x="200" y="30" width="160" height="80" rx="6" fill="#fff3e0" stroke="#ff9800" stroke-width="1.5"/>
  <text x="280" y="55" text-anchor="middle" font-family="system-ui" font-size="12" font-weight="bold" fill="#e65100">YAMLParser</text>
  <text x="280" y="72" text-anchor="middle" font-family="system-ui" font-size="10" fill="#888">(SnakeYAML inside)</text>
  <text x="280" y="92" text-anchor="middle" font-family="monospace" font-size="10" fill="#555">JsonLocation: L3 C5</text>

  <!-- Arrow: source → parser -->
  <line x1="160" y1="70" x2="195" y2="70" stroke="#555" stroke-width="1.5" marker-end="url(#arrowhead)"/>

  <!-- LocationTracking Wrapper -->
  <rect x="400" y="20" width="180" height="100" rx="6" fill="#e3f2fd" stroke="#42a5f5" stroke-width="1.5"/>
  <text x="490" y="45" text-anchor="middle" font-family="system-ui" font-size="12" font-weight="bold" fill="#1565c0">LocationTracking</text>
  <text x="490" y="62" text-anchor="middle" font-family="system-ui" font-size="12" font-weight="bold" fill="#1565c0">Deserializer</text>
  <text x="490" y="82" text-anchor="middle" font-family="system-ui" font-size="10" fill="#555">1. capture location</text>
  <text x="490" y="96" text-anchor="middle" font-family="system-ui" font-size="10" fill="#555">2. delegate → map</text>
  <text x="490" y="110" text-anchor="middle" font-family="system-ui" font-size="10" fill="#555">3. record identity</text>

  <!-- Arrow: parser → wrapper -->
  <line x1="360" y1="70" x2="395" y2="70" stroke="#555" stroke-width="1.5" marker-end="url(#arrowhead)"/>

  <!-- LocationIndex -->
  <rect x="420" y="160" width="140" height="60" rx="6" fill="#fce4ec" stroke="#ef5350" stroke-width="1.5"/>
  <text x="490" y="185" text-anchor="middle" font-family="system-ui" font-size="12" font-weight="bold" fill="#c62828">LocationIndex</text>
  <text x="490" y="202" text-anchor="middle" font-family="monospace" font-size="10" fill="#555">map₁ → L3:C5</text>

  <!-- Arrow: wrapper → index -->
  <line x1="490" y1="120" x2="490" y2="155" stroke="#42a5f5" stroke-width="1.5" stroke-dasharray="4 2" marker-end="url(#arrowhead)"/>

  <!-- Result object -->
  <rect x="620" y="40" width="80" height="60" rx="6" fill="#f3e5f5" stroke="#ab47bc" stroke-width="1.5"/>
  <text x="660" y="65" text-anchor="middle" font-family="system-ui" font-size="12" font-weight="bold" fill="#6a1b9a">Result</text>
  <text x="660" y="82" text-anchor="middle" font-family="monospace" font-size="10" fill="#555">Map₁</text>

  <!-- Arrow: wrapper → result -->
  <line x1="580" y1="70" x2="615" y2="70" stroke="#555" stroke-width="1.5" marker-end="url(#arrowhead)"/>

  <!-- Consumer -->
  <rect x="560" y="160" width="140" height="60" rx="6" fill="#e8eaf6" stroke="#5c6bc0" stroke-width="1.5"/>
  <text x="630" y="185" text-anchor="middle" font-family="system-ui" font-size="12" font-weight="bold" fill="#283593">Validator</text>
  <text x="630" y="202" text-anchor="middle" font-family="monospace" font-size="10" fill="#555">locationOf(map₁)</text>

  <!-- Arrow: index → consumer -->
  <line x1="560" y1="190" x2="556" y2="190" stroke="#ef5350" stroke-width="1.5" stroke-dasharray="4 2" marker-end="url(#arrowhead)"/>

  <!-- Arrow: result → consumer -->
  <line x1="660" y1="100" x2="660" y2="120" stroke="#555" stroke-width="1" stroke-dasharray="3 2"/>
  <line x1="660" y1="120" x2="660" y2="155" stroke="#555" stroke-width="1.5" marker-end="url(#arrowhead)"/>

  <!-- Label -->
  <text x="360" y="280" text-anchor="middle" font-family="system-ui" font-size="11" fill="#888">Single parse: Jackson deserialises the structure, the wrapper captures positions, the validator looks them up</text>

  <!-- Before label -->
  <text x="360" y="305" text-anchor="middle" font-family="system-ui" font-size="10" fill="#aaa">No second parse. No bridge. Positions belong to the objects the consumer already holds.</text>
</svg>

The practical takeaway for anyone building YAML tooling on Jackson: you don't need a second parser to get source positions. Jackson's extension points let you intercept at the right moment — after the token has been read (position available) and after the object has been created (identity available). The information was always there. You just had to ask at the right time.
