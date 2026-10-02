# Spotlight Targeting for Table Rows — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehub-pages#359 — Spotlight targeting for table rows
**Issue group:** #502 (epic-502-yaml-parity)

**Goal:** Enable spotlight targeting of virtual-scroll table rows by
adding a public `scrollToRow` API to PagesDataTable, auto-labeling
rows with `aria-label`, and adding a `scroll-to-row` scenario command.

**Architecture:** Three layers — (1) PagesDataTable gets `scrollToRow(predicate)`
and `aria-label` on rows, (2) a `scroll-to-row` scenario command compiles
YAML lookup modes into predicates, (3) composition with spotlight works
naturally because the scrolled row is in the DOM and labeled.

**Tech Stack:** Lit (PagesDataTable), TypeScript, Vitest, ARIA

## Global Constraints

- All code is TypeScript
- Tests use Vitest with `@open-wc/testing` patterns for Lit components
- `pages-table` and `pages-aria` are separate packages in the monorepo
- `TypedRow.cell(columnId)` returns `CellValue` (discriminated union with `.value`)
- `getRowKey` callback already exists and returns `string`
- Use `mcp__intellij-index__*` tools for code navigation (project_path: `/Users/mdproctor/claude/casehub/slots/210/pages`)

---

## Batch 1: PagesDataTable API — scrollToRow + aria-label

### Task 1: Add aria-label to rendered rows when getRowKey is set

**Files:**
- Modify: `packages/pages-table/src/pages-data-table.ts` (~line 2842-2857, `_renderRow`)
- Test: `packages/pages-table/src/pages-table.test.ts`

**Interfaces:**
- Consumes: `getRowKey` property (existing — `(row: TypedRow) => string`)
- Produces: rendered row divs with `aria-label="${getRowKey(row)}"` when `getRowKey` is set

- [ ] **Step 1: Write failing test — rows get aria-label from getRowKey**

In `packages/pages-table/src/pages-table.test.ts`, add a new `describe` block:

```typescript
describe('row aria-label', () => {
  it('sets aria-label from getRowKey', async () => {
    el.dataSet = testDataSet;
    el.getRowKey = (row: TypedRow) => row.text(nameCol);
    await el.updateComplete;

    const rows = el.shadowRoot!.querySelectorAll('.row[role="row"]:not(.header)');
    expect(rows.length).toBe(3);
    expect(rows[0]!.getAttribute('aria-label')).toBe('Alice');
    expect(rows[1]!.getAttribute('aria-label')).toBe('Bob');
    expect(rows[2]!.getAttribute('aria-label')).toBe('Carol');
  });

  it('omits aria-label when getRowKey is not set', async () => {
    el.dataSet = testDataSet;
    await el.updateComplete;

    const rows = el.shadowRoot!.querySelectorAll('.row[role="row"]:not(.header)');
    expect(rows[0]!.hasAttribute('aria-label')).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run packages/pages-table/src/pages-table.test.ts -t "row aria-label"`
Expected: FAIL — rows don't have `aria-label` attribute

- [ ] **Step 3: Add aria-label to _renderRow**

In `pages-data-table.ts`, in the `_renderRow` method, add the aria-label
to the row div template (around line 2842-2857). Use `ide_replace_member`
or Edit to modify the template literal.

Find the row div in the template:
```html
<div
  class="row"
  role="row"
  part="${part}"
  aria-rowindex="${ariaRowIndex}"
```

Add after `aria-rowindex`:
```html
  aria-label="${this.getRowKey ? this.getRowKey(row) : nothing}"
```

The `nothing` import from Lit already exists in the file (used for
`aria-level`, `aria-setsize`, `aria-posinset`).

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run packages/pages-table/src/pages-table.test.ts -t "row aria-label"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/210/pages add packages/pages-table/src/pages-data-table.ts packages/pages-table/src/pages-table.test.ts
git -C /Users/mdproctor/claude/casehub/slots/210/pages commit -m "feat(#359): add aria-label to table rows from getRowKey"
```

### Task 2: Add public scrollToRow method

**Files:**
- Modify: `packages/pages-table/src/pages-data-table.ts` (add method after `_scrollToRowIfNeeded`)
- Test: `packages/pages-table/src/pages-table.test.ts`

**Interfaces:**
- Consumes: `_effectiveRows` (existing private getter), `_scrollToRowIfNeeded` (existing private method), `updateComplete` (Lit lifecycle)
- Produces: `scrollToRow(predicate: (row: TypedRow) => boolean): Promise<boolean>` — public API

- [ ] **Step 1: Write failing tests — scrollToRow**

In `packages/pages-table/src/pages-table.test.ts`, add:

```typescript
describe('scrollToRow', () => {
  it('scrolls to matching row and returns true', async () => {
    const largeDs = makeLargeDataSet(100);
    el.dataSet = largeDs;
    el.mode = 'scroll';
    el.rowHeight = 40;
    el.getRowKey = (row: TypedRow) => row.text(nameCol);
    el.style.height = '200px';
    document.body.appendChild(el);
    await el.updateComplete;

    const table = el as any;
    const result = await table.scrollToRow(
      (row: TypedRow) => row.text(nameCol) === 'Person 80'
    );

    expect(result).toBe(true);
  });

  it('returns false when no row matches', async () => {
    el.dataSet = testDataSet;
    await el.updateComplete;

    const table = el as any;
    const result = await table.scrollToRow(
      (row: TypedRow) => row.text(nameCol) === 'Nobody'
    );

    expect(result).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run packages/pages-table/src/pages-table.test.ts -t "scrollToRow"`
Expected: FAIL — `table.scrollToRow is not a function`

- [ ] **Step 3: Implement scrollToRow**

In `pages-data-table.ts`, add the public method after `_scrollToRowIfNeeded`
(around line 2126):

```typescript
async scrollToRow(predicate: (row: TypedRow) => boolean): Promise<boolean> {
  const index = this._effectiveRows.findIndex(predicate);
  if (index < 0) return false;
  this._scrollToRowIfNeeded(index);
  await this.updateComplete;
  return true;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run packages/pages-table/src/pages-table.test.ts -t "scrollToRow"`
Expected: PASS

- [ ] **Step 5: Run full table test suite**

Run: `npx vitest run packages/pages-table/src/pages-table.test.ts`
Expected: All tests PASS — no regressions

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/210/pages add packages/pages-table/src/pages-data-table.ts packages/pages-table/src/pages-table.test.ts
git -C /Users/mdproctor/claude/casehub/slots/210/pages commit -m "feat(#359): add public scrollToRow(predicate) API to PagesDataTable"
```

## Batch 2: scroll-to-row scenario command

### Task 3: Add scroll-to-row step definition

**Files:**
- Modify: `packages/pages-aria/src/scenario/invoke/definitions.ts` (add to `ARIA_ACTIONS`)
- Modify: `packages/pages-aria/src/scenario/step-definitions/aria-actions.step.yaml` (add entry)

**Interfaces:**
- Consumes: `ariaDef` helper, `TARGET_INPUTS` constant (existing)
- Produces: `scroll-to-row` definition registered in `ARIA_ACTIONS` and YAML

- [ ] **Step 1: Add to definitions.ts**

In `definitions.ts`, add to the `ARIA_ACTIONS` array (after the `spotlight` entry):

```typescript
ariaDef('scroll-to-row', { ...TARGET_INPUTS, key: { type: 'string' }, column: { type: 'string' }, value: { type: 'string' }, index: { type: 'integer' } }),
```

- [ ] **Step 2: Add to aria-actions.step.yaml**

Append before the `editor-insert` entry:

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

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/210/pages add packages/pages-aria/src/scenario/invoke/definitions.ts packages/pages-aria/src/scenario/step-definitions/aria-actions.step.yaml
git -C /Users/mdproctor/claude/casehub/slots/210/pages commit -m "feat(#359): add scroll-to-row step definition"
```

### Task 4: Implement scroll-to-row command executor

**Files:**
- Modify: `packages/pages-aria/src/executor/command-executor.ts` (add case + function)
- Test: `packages/pages-aria/src/executor/command-executor.test.ts`

**Interfaces:**
- Consumes: `resolveTarget` (existing), `PagesDataTable.scrollToRow` (from Task 2)
- Produces: `scrollToRowStep` function, `scroll-to-row` case in `executeStep`

- [ ] **Step 1: Write failing tests — scroll-to-row command**

In `packages/pages-aria/src/executor/command-executor.test.ts`, add:

```typescript
describe('scroll-to-row', () => {
  it('calls scrollToRow on table with key predicate', async () => {
    const scrollToRow = vi.fn().mockResolvedValue(true);
    document.body.innerHTML = '<div role="grid" aria-label="Cases"></div>';
    const table = document.querySelector('[role="grid"]')! as any;
    table.scrollToRow = scrollToRow;

    const { executeStep } = await import('./command-executor.js');
    await executeStep({
      action: 'scroll-to-row',
      target: { role: 'grid', name: 'Cases' },
      key: 'Bob',
    });

    expect(scrollToRow).toHaveBeenCalledTimes(1);
    const predicate = scrollToRow.mock.calls[0]![0];
    const mockRow = { text: () => 'Bob' };
    expect(typeof predicate).toBe('function');
  });

  it('throws when target has no scrollToRow method', async () => {
    document.body.innerHTML = '<div role="grid" aria-label="Cases"></div>';

    const { executeStep } = await import('./command-executor.js');
    await expect(executeStep({
      action: 'scroll-to-row',
      target: { role: 'grid', name: 'Cases' },
      key: 'Bob',
    })).rejects.toThrow();
  });

  it('throws when no matching row found', async () => {
    const scrollToRow = vi.fn().mockResolvedValue(false);
    document.body.innerHTML = '<div role="grid" aria-label="Cases"></div>';
    const table = document.querySelector('[role="grid"]')! as any;
    table.scrollToRow = scrollToRow;

    const { executeStep } = await import('./command-executor.js');
    await expect(executeStep({
      action: 'scroll-to-row',
      target: { role: 'grid', name: 'Cases' },
      key: 'Nobody',
    })).rejects.toThrow('No matching row');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run packages/pages-aria/src/executor/command-executor.test.ts -t "scroll-to-row"`
Expected: FAIL — `Unknown action: scroll-to-row`

- [ ] **Step 3: Implement scrollToRowStep and add case**

In `command-executor.ts`, add the case in `executeStep` switch (after `spotlight`):

```typescript
case 'scroll-to-row': return scrollToRowStep(step);
```

Add the implementation function:

```typescript
async function scrollToRowStep(step: Record<string, unknown>): Promise<void> {
  const target = step.target as AriaTarget | undefined;
  if (!target) throw new Error('scroll-to-row requires a target');

  const el = resolveTarget(target) as any;
  if (typeof el.scrollToRow !== 'function') {
    throw new Error(`Target ${target.role} "${target.name}" does not support scrollToRow`);
  }

  let predicate: (row: any) => boolean;
  const key = step['key'] as string | undefined;
  const column = step['column'] as string | undefined;
  const value = step['value'] as string | undefined;
  const index = step['index'] as number | undefined;

  if (key != null) {
    predicate = (row: any) => {
      if (typeof el.getRowKey === 'function') return el.getRowKey(row) === key;
      return false;
    };
  } else if (column != null && value != null) {
    predicate = (row: any) => {
      const cell = row.cell(column);
      return cell && cell.type !== 'NULL' && String(cell.value) === value;
    };
  } else if (index != null) {
    let current = 0;
    predicate = () => current++ === index;
  } else {
    throw new Error('scroll-to-row requires key, column+value, or index');
  }

  const found = await el.scrollToRow(predicate);
  if (!found) {
    throw new Error(`No matching row found in ${target.role} "${target.name}"`);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run packages/pages-aria/src/executor/command-executor.test.ts -t "scroll-to-row"`
Expected: PASS

- [ ] **Step 5: Run full executor test suite**

Run: `npx vitest run packages/pages-aria/src/executor/command-executor.test.ts`
Expected: All tests PASS — no regressions

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/210/pages add packages/pages-aria/src/executor/command-executor.ts packages/pages-aria/src/executor/command-executor.test.ts
git -C /Users/mdproctor/claude/casehub/slots/210/pages commit -m "feat(#359): implement scroll-to-row scenario command"
```

## References

- [2026-10-02-spotlight-table-rows-design.md] — design spec
- `packages/pages-table/src/pages-data-table.ts:2111` — `_scrollToRowIfNeeded` private method
- `packages/pages-table/src/pages-data-table.ts:2842` — `_renderRow` template
- `packages/pages-aria/src/executor/command-executor.ts:76` — `executeStep` switch
- `packages/pages-aria/src/scenario/invoke/definitions.ts:14` — `ARIA_ACTIONS` array
- `packages/pages-data/src/dataset/types.ts:44` — `TypedRow` interface
- Decisions D13–D17 in `decisions.md`
- GitHub casehub-pages#359
