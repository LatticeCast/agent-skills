---
name: developing/svelte
description: Svelte/SvelteKit development — enforce pure TS logic in src/lib/, .svelte files handle UI/UX only, FE stores are cache of BE SSOT, render via $derived. Use when writing Svelte components or SvelteKit routes.
version: 0.12.1
---

# Svelte Architecture: Logic/UI Separation

**Pure TS in `src/lib/`. Svelte handles UI/UX only.**

## Top-Level Rule: Response → Store → Derived GUI

Treat this shared-data flow as an invariant for every Svelte feature:

```text
Svelte UI event → lib/backend controller → BE/PG → backend response
→ controller updates store cache → $derived state updates the GUI
```

- Let `.svelte` files call controllers, then react to the store. Never call `fetch` or mutate a shared domain store from a component or route.
- Let `lib/backend/*` controllers own API calls and cache updates. Write the backend response into the store; if the mutation response is incomplete, perform an authoritative refetch in the controller first.
- Derive shared GUI state from store cache with `$derived`. Use local `$state` only for UI-only state such as form input, modal visibility, selection, and pending flags.
- Never duplicate, invent, or optimistically patch shared domain data in `.svelte`. The backend response is the only mutation result that may enter the cache.

## Testing: E2E First

**The best way to test FE changes is to write an e2e test and run it.**

Load `Skill(developing/e2e)` for the full guide. Quick summary:

1. Write a test at `e2e/{domain}/test_<topic>.py` — one topic per file, use conftest fixtures
2. Bring up test containers: `docker compose --profile test up -d browser e2e`
3. Run the specific test file:

```bash
docker compose exec -T e2e pytest <domain>/test_<topic>.py -v
docker compose exec -T e2e pytest <domain>/test_<topic>.py -v --snapshot
```

Every e2e test must verify **three pillars**: Playwright UI state, BE API response, and (optionally) screenshots. Don't unit-test UI logic in isolation — if it renders in a browser and talks to the real backend, test it end-to-end.


## Core Rule

```
src/lib/           → Pure TypeScript (logic, state, types, utils)
src/routes/        → .svelte files (UI/UX, layout, routing)
src/lib/components/ → .svelte files (reusable UI components)
```

## src/lib/ — Pure TypeScript Layer

- **State** → `src/lib/stores/` — Svelte stores or runes as `.ts` files
- **Types** → `src/lib/types/` — interfaces, type guards, Zod schemas
- **Utils** → `src/lib/utils/` — pure functions, helpers, transformations
- **API** → `src/lib/backend/` — data fetching, server logic

Rules:
- No Svelte imports in `.ts` files (except `svelte/store` or `$state` runes)
- All business logic must be testable without Svelte runtime
- Export clean interfaces — components consume, never define logic

## Data Flow Details

BE/PG is the single source of truth. FE stores are a cache populated only by `lib/backend/` controllers. Minimize `$effect` and local `$state`.


### Rules

1. **BE is SSOT.** PG holds the truth. FE stores are a cache. Never invent data in FE that didn't come from BE.

2. **`.svelte` files MUST NOT call BE API directly.** No `fetch()`, no `BACKEND_URL`, no HTTP calls in `<script>` blocks. All BE communication goes through `lib/backend/*.ts` controller functions.

3. **Controller functions own the cache update.** `lib/backend/tables.ts::createTable()` calls the BE API, caches the response (or performs an authoritative refetch), and returns. The `.svelte` caller only `await`s; the store reactively updates the UI.

4. **Maximize `$derived`, minimize `$effect` and local `$state`.** Column order, filtered rows, grouped rows, render items, active view — all `$derived` from store cache. Only use `$effect` for genuine side effects (data fetch on route change, localStorage write, URL rewrite).

5. **No duplicate local state.** If sidebar and home page both show workspaces/tables, they both read from the same store — not each maintaining their own copy. One store, many readers.

6. **Mutations: call controller → controller updates cache → UI reacts.** Never manually patch local `$state` arrays after a mutation. The controller calls BE, gets the real response, refreshes the cache.

7. **Sequential fetch when dependent.** If fetch B needs a result from fetch A (e.g. workspace UUID from `resolveWorkspaceParam` before `fetchTable`), await sequentially. `Promise.all` causes race conditions (422 errors).

### Bad vs Good

```ts
// BAD: .svelte calls BE API directly
const res = await fetch(`${BACKEND_URL}/api/v1/tables`, { headers });
const tables = await res.json();

// GOOD: .svelte calls controller, controller handles BE + cache
import { createTable } from '$lib/backend/tables';
await createTable({ table_name: name, workspace_id: wsId }); // the response carries the numeric table_id
// store cache already updated by controller — UI reacts
```

```svelte
<!-- BAD: local state duplicating store data -->
<script>
  let tables = $state<Table[]>([]);
  let workspaces = $state<Workspace[]>([]);
  onMount(async () => {
    workspaces = await fetchWorkspaces();
    tables = await fetchTables();
  });
</script>

<!-- GOOD: read from store cache, one source -->
<script>
  import { workspaces, tables } from '$lib/stores/table_schemas.store';
  // $workspaces and $tables are cache, populated by layout's initSidebar()
  const activeTables = $derived(
    $tables.filter(t => t.workspace_id === activeWsId)
  );
</script>
```

```svelte
<!-- BAD: mutation patches local state -->
<script>
  async function handleCreate() {
    const table = await createTable({ ... });
    tables = [...tables, table];  // local copy, sidebar doesn't see it
  }
</script>

<!-- GOOD: controller updates cache, all readers see it -->
<script>
  async function handleCreate() {
    await createTable({ ... });  // controller calls BE + refreshes store cache
    // UI auto-updates because store changed
  }
</script>
```

```svelte
<!-- BAD: effect chain syncing derived state -->
<script>
  let filtered = $state([]);
  $effect(() => { filtered = rows.filter(r => r.status === status); });
  $effect(() => { sorted = filtered.sort(...); });
</script>

<!-- GOOD: derived chain, no effects -->
<script>
  const filtered = $derived(rows.filter(r => r.status === status));
  const sorted = $derived(filtered.sort(...));
</script>
```

## MUST: Verify with .browser Snapshot — INSPECT IT, DON'T JUST SAVE IT

**Every FE change MUST be verified with a Playwright screenshot before committing.** No exceptions. If you can't see it, it's not done.

But "took a snapshot" is not the same as "verified the render is right." A
saved PNG that you never opened proves nothing. The rule is:

1. Take the snapshot.
2. **OPEN it (Read tool on the .png) and visually inspect it.**
3. Confirm the layout, content, and styling are correct.
4. If anything looks off — clipped numbers, blocks crammed together,
   missing labels, blank space, wrong colors — fix before committing.

```bash
# Start browser
docker compose --profile browser up -d browser

# Use Skill(developing/debug-frontend) for Playwright snapshot
# or write inline:
docker compose exec browser python3 -c "
from playwright.sync_api import sync_playwright
# ... set up page, inject auth ...
page.goto('<your-page-url>')
page.wait_for_timeout(3000)
page.screenshot(path='/output/<feature_name>.png', full_page=True)
"

# View result — Read tool on the PNG, look at it
ls .browser/<feature_name>.png
```

**Why:** Typography bugs, broken grid layouts, and visual regressions
ship when nobody looks at the rendered output. A saved snapshot that's
never opened catches nothing. A 3-second look at the image catches the
class of bugs the type checker can never see.

Rules:
- After **any** visual change (CSS, layout, component, view), take AND
  inspect a snapshot.
- For grid/layout work, snapshot at realistic content volumes (5+ rows,
  4+ blocks). A single-block dashboard hides span/positioning bugs.
- Compare before/after if refactoring styling.
- Include snapshot path in commit message or ticket doc.
- If the snapshot looks wrong, fix before committing.

## Tailwind v4: Dynamic class names get purged

Tailwind 4 only emits CSS for class names it can statically see in the
source. Interpolated class names from runtime values are **NOT** generated
and silently fall through to default styling. This is the #1 cause of
"the layout looks broken but the code looks right" bugs.

```svelte
<!-- BAD: col-span-1, col-span-2, ... col-span-12 do NOT all exist -->
<div class="col-span-{item.w} row-span-{item.h}">

<!-- BAD: same problem with pad/text/bg/grid -->
<div class="p-{spacing}">
<div class="text-{size}">
<div class="grid-cols-{cols}">
```

Three fixes, in order of preference:

1. **Inline `style` for layout values that come from data** — most reliable.
   ```svelte
   <div style="grid-column: {item.x + 1} / span {item.w};
               grid-row:    {item.y + 1} / span {item.h};">
   ```

2. **Pre-defined Tailwind class lookup** when the value range is small and known.
   ```ts
   const SPAN: Record<number, string> = {
     1: 'col-span-1', 2: 'col-span-2', 3: 'col-span-3',
     4: 'col-span-4', 6: 'col-span-6', 12: 'col-span-12',
   };
   ```

3. **Tailwind safelist** in `tailwind.config` for the exact classes you
   need at runtime. Heaviest hammer; use only when (1) and (2) won't fit.

**Always pair this with a snapshot check.** If a layout-data-driven class
is purged, the page renders but quietly collapses — you'll only catch it
visually.

## Theme: Use `$lib/UI/theme.svelte.ts` — Single Source of Truth

**All dark/light mode styling MUST go through the theme manager.**

```
src/lib/UI/theme.svelte.ts  → isDark, theme.light, theme.dark tokens
```

Rules:
- **`theme.svelte.ts` exports `T`** — a reactive derived object that auto-switches between `theme.light` and `theme.dark` based on `isDark`. Components never derive it themselves.
- **Components just `import { T } from '$lib/UI/theme.svelte'`** and use `{T.cardBg}`, `{T.body}` etc. No ternaries, no isDark checks.
- **NEVER derive dark mode in components.** No `isDark.value ? ... : ...` ternaries for styling. No `const T = $derived(...)` in components. The theme manager handles it.
- **NEVER read `localStorage('theme')`, `prefers-color-scheme`, or create local dark flags.**
- **New tokens?** Add them to `ThemeTokens` interface and both `theme.light` / `theme.dark` objects in `theme.svelte.ts`.
- **Tag colors** use `TAG_COLORS` / `getTagColor()` from the same file.

```svelte
<!-- BAD: component derives dark mode -->
<script>
  import { isDark, theme } from '$lib/UI/theme.svelte';
  const T = $derived(isDark.value ? theme.dark : theme.light);
</script>
<div class="{isDark.value ? 'bg-gray-800' : 'bg-white'}">

<!-- GOOD: theme.ts exports T, component just uses it -->
<script>
  import { T } from '$lib/UI/theme.svelte';
</script>
<div class="{T.cardBg} {T.body}">
```

**Why:** Derivation in one place means Playwright can toggle dark mode by setting `settingsStore.darkMode` once — all components follow automatically. No scattered ternaries to miss.

## $lib Alias

Always use `$lib/` imports in .svelte and route files — never relative paths to src/lib/.

## Clean Lint — No Unused Vars

**Before commit**, `docker compose exec frontend npm run lint` MUST pass. No exceptions.

Common eslint violations to clean up:
- **`no-unused-vars`** — remove dead imports, dead props, dead destructure targets. Don't mask with `_` prefix unless the var is deliberately ignored from a destructure where you need later fields (e.g. `const [_first, ...rest] = arr`).
- **`svelte/no-at-html-tags`** — `{@html x}` is XSS-prone. Sanitize first (e.g. `DOMPurify.sanitize(marked(md))`) or avoid.
- **a11y warnings** (click without keyboard, missing role) — add `role`, `tabindex`, or use `<button>`.

**Never add `// eslint-disable`** to silence a real issue. Fix it. If a warning is genuinely a false positive, discuss before suppressing.
