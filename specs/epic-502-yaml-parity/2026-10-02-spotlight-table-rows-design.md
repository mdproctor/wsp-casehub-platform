# Spotlight Targeting for Table Rows — Design Spec

**Issue:** casehub-pages#359
**Date:** 2026-10-02
**Branch:** epic-502-yaml-parity

## Problem

The scenario engine's spotlight action targets elements by ARIA role+name
via DOM tree-walking. For static tables with rows already in the DOM, this
works — rows have `role="row" aria-label="Bob"` and spotlight finds them.

PagesDataTable with virtual scroll only renders visible rows. Off-screen
rows are not in the DOM, so ARIA tree-walking fails. Spotlight cannot
target a row that doesn't exist yet.

## Solution

Three layers, bottom-up:

### Layer 1 — PagesDataTable API additions

**`aria-label` on rows:** When `getRowKey` is set, `_renderRow` adds
`aria-label="${getRowKey(row)}"` to the row div. Every rendered row
becomes targetable by ARIA role+name. No change when `getRowKey` is unset.

**`scrollToRow` public method:**

```typescript
async scrollToRow(predicate: (row: TypedRow) => boolean): Promise<boolean>
```

- Finds the first matching row in `_effectiveRows` via `findIndex`
- Calls the existing private `_scrollToRowIfNeeded(index)` to scroll
- Awaits `updateComplete` so the row renders into the DOM
- Returns `true` if a match was found, `false` otherwise
- Works for both virtual-scroll and non-virtual-scroll modes

The predicate form is the most general — callers can match on any row
property. The scenario command layer provides YAML-friendly sugar.

### Layer 2 — `scroll-to-row` scenario command

**Step definition** (definitions.ts + aria-actions.step.yaml):

```yaml
scroll-to-row:
  description: "Scroll a virtual-scroll table to bring a specific row into view"
  inputs:
    role: { type: string, required: true }
    name: { type: string, required: true }
    key: { type: string }
    column: { type: string }
    value: { type: string }
    index: { type: integer }
    within: { type: object }
  outputs: {}
  invoke:
    aria: scroll-to-row
```

Three lookup modes compile down to predicates:

| Mode | YAML fields | Predicate |
|------|-------------|-----------|
| By key | `key: "Bob"` | `getRowKey(row) === "Bob"` |
| By column value | `column: "status"`, `value: "Open"` | `row.cell("status").value === "Open"` |
| By index | `index: 3` | row at index 3 in effective rows |

Precedence when multiple fields set: `key` > `column`+`value` > `index`.

**Execution** (new `scrollToRowStep` in command-executor.ts):

1. `resolveTarget(step.target!)` finds the table element
2. Type-check for `scrollToRow` method — throw if absent
3. Build predicate from lookup fields
4. Call `table.scrollToRow(predicate)` — auto-waits internally
5. Throw if no matching row found

### Layer 3 — Composition

Scenario authors chain scroll-to-row → spotlight naturally:

```yaml
- scroll-to-row:
    role: grid
    name: Cases
    key: Bob

- spotlight:
    role: row
    name: Bob
    within: { role: grid, name: Cases }
    content: "This is Bob's open case — notice the priority flag"
```

Runtime flow:
1. `scroll-to-row` finds `<pages-data-table>` by ARIA grid+name
2. Calls `scrollToRow(row => getRowKey(row) === 'Bob')`
3. Table scrolls, Lit re-renders, row appears in DOM with `aria-label="Bob"`
4. `spotlight` resolves `role: row, name: Bob` within the grid — succeeds
5. Spotlight overlay renders with callout

Multi-row with `also[]`:

```yaml
- scroll-to-row:
    role: grid
    name: Cases
    key: Bob

- spotlight:
    role: row
    name: Bob
    within: { role: grid, name: Cases }
    content: "Compare Bob and Alice's cases"
    also:
      - role: row
        name: Alice
        within: { role: grid, name: Cases }
```

Works when both rows are in the visible window after scrolling. If they
aren't, the author chains two scroll-to-row steps.

## Files changed

| File | Change |
|------|--------|
| `packages/pages-table/src/pages-data-table.ts` | Add `aria-label` to row div, add public `scrollToRow` method |
| `packages/pages-aria/src/executor/command-executor.ts` | Add `scroll-to-row` case + `scrollToRowStep` function |
| `packages/pages-aria/src/scenario/invoke/definitions.ts` | Add `scroll-to-row` definition to `ARIA_ACTIONS` |
| `packages/pages-aria/src/scenario/step-definitions/aria-actions.step.yaml` | Add `scroll-to-row` step definition |

## Testing

- **PagesDataTable unit tests:** `scrollToRow` with predicate (match found,
  no match), `aria-label` rendering when `getRowKey` is set vs unset
- **Command executor tests:** `scroll-to-row` with key, column+value, and
  index modes; error on non-table target; error on no matching row
- **Integration:** scroll-to-row → spotlight composition in a scenario
  with virtual scroll enabled (>50 rows)

## Out of scope

- Generic scroll-into-view for non-table containers
- `getRowLabel` separate from `getRowKey`
- Composite scroll-and-spotlight single action

## References

- `pages-data-table.ts:2111` — existing private `_scrollToRowIfNeeded`
- `pages-data-table.ts:2128` — `_focusRow` pattern (await updateComplete)
- `pages-data-table.ts:2842-2857` — `_renderRow` row div (role="row", no aria-label)
- `pages-data-table.ts:33` — `getRowKey` callback property
- `command-executor.ts:8-32` — `resolveTarget` function
- `command-executor.ts:76-104` — `executeStep` switch dispatch
- `spotlight.ts:110-121` — `SpotlightConfig` with `also[]`
- `definitions.ts:14-32` — `ARIA_ACTIONS` array and `ariaDef` helper
- `aria-actions.step.yaml` — declarative step definitions
- Decisions D13–D17 in `decisions.md`
