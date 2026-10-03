# Grids and pagination — the standard

**Applies to every new list in Practice Management.** A grid does not
write its own paging. It mounts `pm-grid`, sends the page it is given,
and hands back the total its procedure already returns.

**Component:** `Web/wwwroot/js/pm-grid.js` (`window.__pmGrid`)
**Styling:** `.pm-pager` in `practice-management.css`, plus four
`.pm-grid-pager` rules
**Reference implementation:** Risk Centre — Risk Register, Candidates,
Review Risk, Approval Queue; and Operationalize (`resolve.cshtml`),
which additionally shows the `busy()` and degrade paths in use

---

## The rule

1. Wrap the table in `.pm-table-wrap`.
2. Put an empty `<div id="…Pager"></div>` after it.
3. Mount a pager, refetching on change.
4. Send `pageNumber` / `pageSize` on every request.
5. Call `setTotal(totalRows, rows.length)` after every load.
6. Call `reset(true)` before refetching when a **filter** changes.

```js
const pager = window.__pmGrid.attach({
  hostId:   "regPager",
  onChange: () => refreshRegister()      // refetch — never slice locally
});

async function refreshRegister() {
  const qs = new URLSearchParams({
    organizationId: state.organizationId,
    pageNumber: pager.page(),
    pageSize:   pager.size()
  });
  const res = await apiGetChecked(`/register?${qs}`);
  if (!res.ok) { pager.clear(); return; }

  const rows = res.data?.rows || [];
  pager.setTotal(res.data?.totalRows, rows.length);
  // …render rows…
}
```

## Check the parameter name first: `page` or `pageNumber`

Both spellings exist in this API and neither is wrong:

| Endpoint | Parameter |
|---|---|
| `workflow/resolve/instances` (Operationalize) | `pageNumber` |
| `exception-centre` | `page` |
| `document-acknowledgements` | `page` |

A grid that sends the wrong one is **silently ignored** — the binder
leaves the default, the procedure returns page 1 every time, and the
pager looks like it is working while Next does nothing. Read the
controller's `[FromQuery]` signature before wiring a screen; it costs
one grep and it is invisible in testing if the data set is smaller than
one page.

## Server-side, always

`onChange` **refetches**. It must never slice an array the page already
holds. Every paged procedure here uses `OFFSET … FETCH NEXT` precisely so
a long register is never all in the browser; a grid that pages
client-side has thrown that away and will fall over on the first
organisation with ten thousand risks.

If an endpoint does not page yet, add `@page_number` / `@page_size` and
`COUNT(*) OVER () AS TotalRows` to its procedure — that is the shape
every existing one uses — rather than fetching everything and paging in
JavaScript.

## Why the total matters

Every paged procedure already returns `TotalRows` as
`COUNT(*) OVER ()`, last in the projection, and every paged API model
already carries `TotalRows, Page, PageSize`. Before `pm-grid` the UI
discarded all of it, so the generic grid had to guess whether a next
page existed:

```js
nextPage.disabled = state.records.length < state.pageSize;
```

That is wrong on the exact boundary where the last page is full — 50
rows at 25 per page leaves Next enabled on page 2, and clicking it lands
on an empty grid. Reading the total removes the guess, and lets the label
say `26–50 of 50` instead of `Page 2`.

`setTotal` takes the **row count** as well as the total. That is what
lets a short last page read `26–40 of 40` rather than assuming every page
is full.

## Filters go back to page 1

`reset(true)` then refetch. Staying on page 4 of a filter that now
matches six rows shows an empty grid, and that reads as a fault rather
than as a filter.

`reset(true)` is *silent* — it moves the pager without firing
`onChange` — so the refresh happens once. `reset()` without the flag
fires `onChange` itself, which is what you want when nothing else is
about to refetch.

**Refresh is not a filter change.** A Refresh button re-reads the page
the user is on; it must not reset.

**Changing organisation resets everything.** It is a different data set,
so every pager on the screen goes back to page 1.

## Degrading

`attach` returns `null` if its host is missing, and every call site uses
`pagers.x?.method()`. If `pm-grid.js` fails to load, the lists fetch
their first page and render — no pager, no exception. `pageParams()`
returns `{}` in that case, so the request simply omits the page keys and
the procedure's own defaults apply.

An endpoint that returns no `totalRows` is handled too: the label falls
back to `Page N` and Next reverts to the row-count guess, rather than
showing a wrong count.

## Load order

`pm-grid.js` before the screen's own script — the screen mounts its
pagers during init.

```html
<script src="~/js/pm-grid.js" asp-append-version="true"></script>
<script src="~/js/RiskCentre/risk-centre.js" asp-append-version="true"></script>
```

## The two sanctioned implementations

There is one *behaviour*, reached two ways. Both render the same
`.pm-pager` DOM, so they are indistinguishable on screen.

| | `__pmGrid` (`pm-grid.js`) | `__wfCommon.wirePager` / `updatePager` |
|---|---|---|
| Markup | renders its own into a host `<div>` | hand-written in the `.cshtml` |
| Page state | owned by the component (`page()`, `size()`) | owned by the screen (its own `page` variable) |
| Use for | **every new grid** | screens already on it |
| Where | Risk Centre | the workflow partials, `gaps`, `tasks` |

`__wfCommon` is the older of the two and is not deprecated — it suits a
screen that must own its page number for reasons of its own, such as
`tasks.cshtml`, where each tab remembers its own page across switches.
What it does *not* permit is a local copy: a screen calls the shared
helper or it mounts `pm-grid`. It does not write its own.

To use it, render the partial and delegate:

```html
<partial name="Partials/_workflow-common" />
```

```js
window.__wfCommon.wirePager('all', function (delta) {
    const target = page + delta;
    if (target < 1) return;                 // helper disables, this is belt-and-braces
    page = target;
    reload();
});

window.__wfCommon.updatePager('all', Object.assign({}, payload, {
    pageSize: PAGE_SIZE,                    // without it the label can only say "Page 3"
    rowCount: rows.length                   // lets a short last page read 41-52 of 52
}));
```

`pageSize` is the part that is easy to omit and quietly halves the value:
the helper needs it to compute the row range *and* to know where the
last page is. Without it Next never disables.

### What the local copies got wrong

`gaps.cshtml` and `tasks.cshtml` each carried their own pager until they
were folded onto the helper. Both had the same two defects, which is the
argument against copies in miniature:

```js
nextBtn.addEventListener('click', function () { page++; reloadCurrentTab(); });
```

Next had **no upper bound**, so it stayed clickable past the last page
and landed the user on an empty grid — which reads as a fault, not as
the end of the list. And with no page size to work from, the label could
only ever print `Page 3`, never `51-75 of 240`. Fixing the shared helper
once fixed thirteen screens; the two copies had to be deleted to benefit.

## The generic grid — migrated (migration 300)

The generic grid in `practice.js` had its own hand-wired pager in
`Manage.cshtml` (`previousPage` / `pageInfo` / `nextPage` / `pageSize`).
It is now on `pm-grid` like everything else. Four buttons became one
empty host div:

```html
<div id="practiceGridPager"></div>
```

`pm-grid` renders the same `.pm-pager` markup into it, so the ~30 screens
that share this grid look exactly as they did.

**It needed a migration first.** `dbo.pm_get_practice_repository` pages
thirty-seven branches with `OFFSET`/`FETCH` and returned a total for none
of them, so there was nothing for `setTotal` to read.
`300_generic_grid_total_rows.sql` re-emits the procedure with
`COUNT(*) OVER () AS TotalRows` last in each of those thirty-seven
projections, and the five C# fallback queries in
`PracticeRepositoryService` that shadow those branches gained the same
column so both paths report the same number.

CREATE OR ALTER replaces a procedure whole, so 300 carries the entire
body. **Change a branch in 300, not in 002** — an edit to the 002
baseline is reverted the next time 300 runs, the same trap
`menu_master` has with 274. A pointer comment above the procedure in 002
says so.

Two details worth keeping in mind when reading `practice.js`:

* `state.pageNumber` / `state.pageSize` still exist, because a dozen
  payload builders and trace lines read them. They are no longer the
  source of truth — `loadRows()` syncs them from `gridPager.page()` /
  `.size()` on entry, so every one of those call sites sees the page the
  request is actually fetching.
* `totalRowsOf()` returns **`undefined`**, not `0`, when a response
  carries no `TotalRows`. `setTotal(undefined)` leaves the total null and
  `pm-grid` falls back to `Page N`. Source Statements needs that: it
  fetches its releases in one page and filters them in the browser, so it
  has no server total to report and must not be told the list is empty.

### Still unpaged behind this grid

Two lists reached through the generic grid are **not** fixed by 300,
because their data does not come from `pm_get_practice_repository`:

| List | Served by | State |
|---|---|---|
| Source Statements — release summary | `QuerySubscribedFrameworksAsync` | fetches `pageSize: 500`, filters in JS, no `OFFSET` |
| Source Statements — statement tree | `QueryReleaseStatementsAsync` | no `OFFSET` |

Both need paging added to the C# query before a pager means anything, so
they keep the `Page N` degrade path for now. They belong with the Group C
work in `docs/pagination-audit.md`.

Short fixed lists in Risk Centre — Candidate ageing, Treatment tasks,
the dashboard tiles — were deliberately left alone. They fetch a bounded
set by design, and a pager under a list that will never have a second
page is noise.

## Sticky column header (2026-10-01)

Every grid keeps its column header row visible while its rows scroll.
This is CSS only, in `wwwroot/css/practice-management.css` section 8. There
is no JS, no new grid component, and nothing for a screen to opt into.

**Where it applies**

- Every `.pm-table-wrap` grid. That is the shared grid container: about 95
  grids across the partials and JS renderers use it.
- Grids that have their own wrapper add the class `.pm-sticky-grid` to that
  wrapper. Today this is the Operationalize grid (`resolve.cshtml`,
  `<div class="rv-scroll pm-sticky-grid">`).

**How it works**

- The wrap is already `overflow:auto` for horizontal scroll. Because of
  that, a sticky header can only stick to the wrap, never to the page. So
  the wrap is capped with `max-height: var(--pm-grid-max-h)`:
  ```
  max(320px, calc(100vh - var(--pm-page-head-h) - 14px - 96px))
  ```
  This is the viewport left below the frozen page heading (see below),
  with room left for the pager.
  The rows scroll inside the wrap. A grid shorter than the cap looks and
  behaves exactly as before.
- `thead` is `position: sticky; top: 0; z-index: 2`. The whole `thead` is
  sticky, not each `th`, so two-row headers stay stacked correctly (for
  example Governance Overview above its metric row). Header and body are
  one `<table>`, so the columns stay aligned under horizontal scroll.
- With `border-collapse` the header's bottom border belongs to the table
  and would scroll away. It is redrawn as an inset 1px `var(--border)`
  line on the last header row, and the real border is set to transparent.
  At rest this looks the same as before.
- Wraps that already have their own cap keep it:
  - inline `max-height` (dialogs, the event inbox, the repository pickers);
  - `.pm-role-perms-table` at 60vh. Its own sticky `th` rule was removed
    as a duplicate.
- The 3-dot row menus portal to `<body>` and close on any scroll (the
  capture listener in `practice.js`), so the inner scroll never leaves a
  menu floating. Sorting, filters and the pager are untouched.
- In print, the cap and stickiness are switched off, so a printed grid
  shows every row.

**Not covered, by design**

These are editors or small fixed lists, not scrolling grids:

- inline editor tables: `.pm-dependency-grid`, `rw-dep-table`,
  `risk-dep-table`;
- small history tables in dialogs;
- the task list nested in a Risk card (`rmp-task-table`).

A new list grid gets the behaviour simply by using `.pm-table-wrap`.

## Frozen page heading (2026-10-01)

The page heading stays at the top of the window while the page scrolls.
The page heading is the shared `.pm-page-heading` (title, eyebrow,
description, actions), and every screen renders exactly one visible
heading.

**CSS** (`practice-management.css` section 1):

- `.pm-page-heading` is `position: sticky; top: 0; z-index: 50`.
  - The top bar is not fixed (`body` has no `layout-navbar-fixed`), so
    it scrolls away and the heading takes the top edge.
  - z-index 50 is above in-page content and in-page menus
    (`.pm-checkcombo-menu` and `.tp-menu` are 40, grid `thead` is 2), so
    they scroll under it.
  - It is below the body-level 3-dot menu (1000), the full-page dialog
    (1020), the AdminLTE sidebar and top bar (1037/1038), and
    `.pm-modal` (1100).
- The freeze is switched off:
  - at the existing `max-width: 720px` breakpoint, where the heading
    stacks into a column;
  - on windows shorter than 560px;
  - in print.

**Height** (`wwwroot/js/site.js`, loaded on every layout page):

- The script publishes the live height of the visible, sticky heading as
  `--pm-page-head-h` on `<html>`. It is `0px` when the freeze is off.
- It uses a ResizeObserver on the headings, plus a MutationObserver for
  headings rendered later and for Risk Centre's view swaps. Updates are
  batched to one per animation frame.

**With the grid header:**

- The grid cap above subtracts `--pm-page-head-h`. When the page is
  scrolled to a grid, the whole grid fits under the page heading, and its
  sticky column header sits directly below the page heading.
- The column header sticks inside the grid's own scroll box (top 0 of the
  wrap), not to the page. So it is never above or over the page heading.
  If the page is scrolled further, the heading (z 50) covers the grid
  like any other content.
