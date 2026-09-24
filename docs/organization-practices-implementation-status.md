# Organization Practices — Implementation Status column, and search

The Practices grid (`Practice/Index/organization-requirements`) shows an
**Implementation Status** per Practice, rolled up from that Practice's Practice
Instances. It is the Source Statement column one level down, and deliberately uses
the same rule and the same four labels so the two screens cannot disagree. This
file also covers the grid's text search box, added later and unrelated to the
Implementation Status rule beyond sharing the same query.

**Backend:** `PracticeRepositoryService.QueryOrganizationRequirementFallbackAsync`
**Frontend:** `practice.js` — `practiceImplementationStatus`,
`renderRequirementControlGroups`, `renderStatementPracticeRows`,
`resetOrganizationRequirementFilters`
**Sibling:** `docs/repository-subscriptions-grid.md`, "Implementation Status is
derived, never stored"

---

## Search box

The toolbar's `#search` input (placeholder **"Search practices..."** on this
screen only — every other screen keeps the generic **"Search..."**) was unhidden
for `organization-requirements`. Nothing else needed to change:

* **The backend predicate already existed.** `QueryOrganizationRequirementFallbackAsync`
  has always taken a `search` parameter and applied it —
  `@p_search='' OR ISNULL(q.requirement_code,'') LIKE '%'+@p_search+'%' OR
  ISNULL(q.requirement_name,'') LIKE '%'+@p_search+'%' OR ...` — against
  `requirement_code`/`requirement_name` (the grid's Practice Code / Practice Name,
  `Code`/`Name` in the response), plus, for good measure, the mapped Control's
  code/name and the mapped Statement's reference/title. `LIKE '%...%'` is
  case-insensitive under the database's default collation, matches substrings
  anywhere in the field, and combines with every other predicate (organization,
  release, applicability status, origin, date range) with `AND` — search narrows
  whatever the other filters already narrowed, it does not replace them.
* **The client-side wiring already existed too.** `practice.js` reads `#search`
  into `payload.search` in the one `loadRows()` used by every screen (line ~1794),
  and a single generic listener already debounces it into `resetToFirstPage()`
  250ms after the user stops typing — `search?.addEventListener("input", ...)` —
  which resets `pm-grid`'s pager to page 1 and reloads. Organization Practices was
  simply the one screen where the already-built input was hidden.
* **Clear Filter.** `organization-requirements` takes its own branch of the
  `clearFilters` handler (`resetOrganizationRequirementFilters`, because it also
  has to reload the subscribed-framework dropdown) rather than the generic branch
  that already cleared `search.value`. That function now clears `search.value`
  too, alongside `status` and `subscribedFrameworkFilter`.
* **Pagination and the total-row count.** `TotalRows` is `COUNT(*) OVER ()` inside
  the same query, evaluated after the `WHERE` (so after `@p_search`) and before
  `OFFSET`/`FETCH` — a search narrows it exactly like any other filter, and
  `pm-grid`'s "Page N of M" already reads it off the first row. No change needed.
* **Grouping under Controls.** `renderRequirementControlGroups` groups whatever
  rows are already on the fetched page, by `OrganizationControlId` — it has no
  idea a search ran and does not need one. A search narrows which rows arrive;
  which Control each surviving row groups under is unaffected.
* **No API or database change.** This was a UI-only change: one Razor conditional
  in `Manage.cshtml` (the `hidden` attribute became a placeholder switch) and one
  line in `resetOrganizationRequirementFilters`.

## The rule

| Result | When |
| --- | --- |
| `Implemented` | Practice is `Applicable`, has **at least one** instance, and **every** instance is `Implemented`. One unfinished instance holds the whole Practice back. |
| `Partially Implemented` | Applicable, at least one instance `Implemented`, but not all. |
| `Not Applicable` | Practice applicability is `Not Applicable`, `Deferred`, `Accepted Risk`, `Not Implemented` or `Retired`. |
| `Not Implemented` | Everything else — including `Not Updated` practices and Applicable practices with **no instances at all**. |

"Every instance is Implemented" means
`practice_instance.implementation_status_id` resolving to
`implementation_status_master.status_code = N'Implemented'`. There is no `Closed`
status on a Practice Instance — the master holds only `Not Implemented`,
`Partially Implemented`, `Implemented` and `Not Applicable` (migration 045), and
`Implemented` is the terminal one. This is the same column and the same test the
`statement_implementation` CTE in `QueryReleaseStatementsAsync` applies.

Only Active instances count (`pi.status='Active'`), matching `PracticeInstanceCount`
in the same row.

## Why the column is not called `ImplementationStatus`

Because that name was already taken, by a **different** value:

```sql
COALESCE(ims.status_name,q.implementation_status) ImplementationStatus,   -- STORED on the requirement
CASE ... END                                      PracticeImplementationStatus, -- DERIVED from instances
```

`organization_requirement` stores an implementation status of its own, and the
Practices edit form carries it as a hidden field:

```js
hidden("implementationStatus")        // practice.js, "organization-requirements" form
```

which posts back on save. Renaming the derived value over the stored one would write
the roll-up into `q.implementation_status` the first time anyone edited a Practice —
a silent data change with no UI for it. A Source Statement has no stored
implementation status at all, which is why that page's derived column *can* be called
`ImplementationStatus`.

The grid therefore reads `PracticeImplementationStatus`, through one helper so both
renderers stay in step:

```js
function practiceImplementationStatus(record) {
  return valueOf(record, "practiceImplementationStatus") || "Not Implemented";
}
```

The `|| "Not Implemented"` fallback mirrors `renderStatementPracticeRows`' treatment
of the statement column: a row from an API build without the column renders a badge
rather than an empty cell.

## It is computed per request

There is no stored roll-up and no cache. The `CASE` runs inside the grid query, over
`pic.PracticeInstanceCount` / `pic.ImplementedInstanceCount` — one `OUTER APPLY`
serving both, since the roll-up walks the same two joins the count already needed.

So the column follows the data as soon as it changes. An instance's status is written
by `sp_practice_instance_update_implementation_status` (migration 045, reached through
`PracticeInstanceController.UpdateImplementationStatus`) and seeded by
`sp_practice_instance_configure` (145). Migration 242 moved status to the *obligation*
level but explicitly kept `practice_instance.implementation_status` populated for
exactly this kind of roll-up. Change an instance to `Implemented`, reload Practices,
and the Practice flips to `Implemented` once it was the last one outstanding.

## Which query serves this grid

`QueryOrganizationRequirementFallbackAsync`, always — not the
`organization-requirements` branch of `pm_get_practice_repository`.

`ExecuteAsync` routes to the fallback whenever `CanUseOrganizationFallback(payload)`
holds, and returns before the procedure is ever opened. Both entry paths into this
screen carry an organization: the direct menu route blocks the load until one is
selected, and a drill-down gets one injected server-side from the encrypted
navigation context (`ApplyNavigationContext`: `if (context.OrganizationId.HasValue)
organizationId = context.OrganizationId`).

The procedure's branch was **not** changed to match. It is unreachable for this
screen — it is reached only with no organization and no system-admin scope, where the
procedure then forces `@organization_id = -1` and returns nothing, and it `THROW`s
outright (51024) without a control context. Re-emitting the 1,600-line monolith for a
dead path was not worth the risk. If that branch is ever revived, the roll-up has to
be added there too, in migration 300, not in the 002 baseline.

## Column-count invariant

Three places must stay in step, or the loading / empty row will not span the grid:

1. `PracticeScreen.cs` — `organization-requirements` `Columns` (six entries;
   `Manage.cshtml` appends *Actions*). This is the pre-hydration header and the source
   of `listColumnCount()`.
2. `renderRequirementControlGroups` — its `<th>` row **and** the
   `colspan` on the `pm-control-group-row` band.
3. `renderStatementPracticeRows` — its `<th>` row.

All three are now seven cells. The `Columns` array and the rendered headers still use
different labels (`PracticeInstanceCount` vs *Origin Type*) — a pre-existing mismatch,
harmless because the renderers overwrite the header, and left alone here.
