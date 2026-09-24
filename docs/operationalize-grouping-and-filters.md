# Operationalize — Practice grouping, Owner/Status filters (migration 315)

The Operationalize grid (`Practice/Index/resolve`, screen key `resolve`) presents
one row per Practice Instance the caller can see, nested under the Practice it
belongs to, with an Owner filter and a Status filter alongside Search and Show
retired.

**Backend:** `ResolveWorkspaceController.ListInstances`, `ResolveWorkspaceService.ListInstancesAsync`,
`grac_practice.sp_resolve_instance_list`
**Frontend:** `Views/Practice/Partials/resolve.cshtml` — `load()`, `populateFilterOptions()`,
`groupRows()`, `render()`, `rowHtml()`
**Sibling:** `docs/grid-and-pagination-standard.md` (Operationalize is its paging
reference implementation), `docs/organization-practices-implementation-status.md`
(why `ImplementationStatus` is free text, not a fixed master list)

---

## What changed

1. **Hierarchical presentation.** The grid still fetches one flat, paged list of
   instances (nothing about paging changed — see "What did NOT change" below).
   `resolve.cshtml` groups the rows *already on the page* by `practiceId`
   (falling back to `practiceCode`/`practiceName` if a row somehow carries
   neither), sorts the groups by Practice code, and renders one Practice header
   row per group with its instances nested beneath it. A Practice column no
   longer exists on the instance rows — the group header carries that
   information once instead of on every row.
2. **Expand / collapse.** Each Practice group has a chevron toggle. Collapsed
   state lives in a client-side `Set` (`collapsedGroups`) keyed by the same
   group key, for the lifetime of the page — it is not persisted and is not
   sent to the server.
3. **Owner filter and Status filter**, added to the toolbar next to Search.
   Both are server-side filters, not client-side: the grid is paged, so a
   value that only appears on page 3 has to be selectable while the caller is
   looking at page 1. New query parameters on
   `GET /practice/api/workflow/resolve/instances`:

   | Parameter | Type | Meaning |
   |---|---|---|
   | `ownerEmployeeId` | `long?` | Narrows to one owner. `null`/absent = no opinion. |
   | `status` | `string?` | Exact match against the same value the Status badge renders (`ImplementationStatus`). `null`/absent = no opinion. |

   Both are ANDed into the existing `WHERE` clause in
   `sp_resolve_instance_list` exactly like `@practice_id` was in migration 287
   — narrows rows, never widens who can see what. The ownership test
   (`@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id`) still runs
   first and independently, so a non-admin cannot use `ownerEmployeeId` to
   reach someone else's instances.
4. **Two new result sets** on `sp_resolve_instance_list`, appended after the
   row set, in the same round trip:
   - Result set 2 — distinct owners in scope: `OwnerEmployeeId`, `OwnerName`.
   - Result set 3 — distinct `ImplementationStatus` values in scope.

   Both use the row set's scope predicates (organisation, retired visibility,
   ownership, Practice/Organization-Requirement drill-down) but deliberately
   **exclude** `@search`, `@owner_employee_id` and `@implementation_status`
   themselves, so the dropdowns always offer every value the caller could
   pick, not just the ones that survive whatever is currently selected. This
   is the same shape `sp_risk_mapping_get` (266) uses for its category result
   set — an option list is a rule, computed once in the procedure, not
   re-derived (and risking drift) in the browser.

   The response from `GET .../resolve/instances` gained two keys:
   `owners: [{ ownerEmployeeId, ownerName }]` and
   `statuses: [{ implementationStatus }]`.
5. **Obligations / Dependencies display.** The grid showed `3 / 3 adopted` and
   `2 / 2 resolved`. It now shows `3 adopted` and `2 resolved` — the total is
   dropped from the text, but the underlying done-vs-total calculation is
   unchanged and still decides the colour (`done` vs `pending` vs `none`), so
   `0 adopted` still reads as outstanding (amber) and `3 adopted` (of 3) still
   reads as complete (green). Nothing about how `AdoptedObligations` /
   `TotalObligations` / `ResolvedDependencies` / `TotalDependencies` are
   computed changed — see 290's `OUTER APPLY` blocks, untouched.
6. **Show retired checkbox.** Was an unstyled native checkbox rendering at the
   browser's default size next to a 13px label. Sized to 14x14 with
   `accent-color` matching every other checkbox in the module (see
   `.pm-subscription-tree input[type="checkbox"]` in `practice-management.css`).

## What did NOT change

- Paging is unchanged: the server still pages by `pageNumber`/`pageSize` and
  orders by `pi.instance_code`; `resolve.cshtml` groups and sorts *within* the
  page it already fetched. A Practice whose instances straddle two pages
  still appears (in reduced form) on both pages, exactly as an ungrouped grid
  would have.
- `Search`, `Show retired`, the Practice/Organization-Requirement drill-down,
  Retire/Restore, and View/Operationalize navigation are all unchanged code
  paths -- Owner/Status are additional predicates alongside them, not a
  replacement.
- `AdoptedObligations`, `TotalObligations`, `ResolvedDependencies`,
  `TotalDependencies` are computed exactly as they were in migration 290 --
  only their presentation in `resolve.cshtml` changed.
- A caller that never passes `ownerEmployeeId`/`status`, or a database that
  has not yet run migration 315, is unaffected: both parameters default to
  "no opinion", and the two new result sets are read defensively
  (`reader.NextResultAsync()` returning `false` degrades to empty option
  lists rather than throwing), the same pattern `TotalRows` (290) already
  established for a UI ahead of its migration.

## Practices with no instances

This list has always been instance-first: the procedure walks
`practice_instance`, not `practice`, so a Practice that owns no instances in
the selected organisation was never representable as a row before this change
and still is not. Grouping does not introduce an "empty Practice" case to
handle -- there is nothing to group when there is no instance row to carry a
`practiceId`.

## Rollback

`database/315_operationalize_owner_status_filters_rollback.sql` restores
`sp_resolve_instance_list` to its migration-290 shape (single result set, no
owner/status parameters). Rolling back the database without also reverting
`resolve.cshtml` leaves the Owner/Status `<select>`s with nothing to offer
(empty option lists, same degrade path described above) and any
`ownerEmployeeId`/`status` the UI still sends will produce a SQL 8144 error
"too many arguments specified" against the older procedure shape -- the same
failure any parameter drift between tiers already produces elsewhere in this
schema.
