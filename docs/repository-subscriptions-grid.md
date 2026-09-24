# Repository Subscriptions grid (Level 1) — developer notes

**Screen:** `organization-controls` (menu *Governance → Repository Subscriptions*), alias `source-statements`
**Endpoint:** `POST /practice/api/practice-management/subscribed-frameworks/query`
**Backend:** `Api/Services/PracticeRepositoryService.QuerySubscribedFrameworksAsync`
**Frontend:** `Web/wwwroot/js/practice.js` — `releaseSummaryColumns`, `releaseSummaryMetricColumns`, `renderReleaseSummaryHeader`, `loadReleaseSummary`
**Header fallback:** `Web/Models/PracticeScreen.cs` (`organization-controls` columns)

---

## Columns

The header is two rows. *Framework / Release*, *Owner* and *Actions* carry
`rowspan="2"`; the five counts sit in the second row under a single
**Governance Overview** group cell (`th.pm-th-group`) — renamed from
*Statement Overview* per sir's request; text only, `th.pm-th-group` and the
five `<th class="pm-th-metric">` cells underneath are unchanged. The counts
are labelled with one word each so the count columns stay only as wide as
the two-digit number inside them, not as wide as "Not Applicable Statements".

The five counts display in this order — Total, Not Applicable, Applicable,
Implemented, Not Updated (sir's requested order; display only, the underlying
fields/calculations below are unchanged):

| Header (group / column) | Field | Notes |
| --- | --- | --- |
| Framework / Release | `FrameworkRelease` | `artifact_code + ' ' + version_no`; falls back to `artifact_name + ' ' + version_no`, then `version_no` alone. Custom releases read `Organization / <custom_release_name>`. |
| Owner | `OwnerName` | `employee_code - employee_name`; renders *Unassigned* when the subscription has no owner. |
| Governance Overview / Total | `TotalStatementsCount` | Active `grac_new.framework_statement` rows on an Active structure node of the release. |
| Governance Overview / Not Applicable | `NotApplicableStatementsCount` | `Not Applicable`, `Deferred`, `Accepted Risk`, `Not Implemented`, `Retired`. Named *Not Applicable*, not *Not Implemented* — `Not Implemented` is only one of the statuses rolled into it. |
| Governance Overview / Applicable | `ApplicableStatementsCount` | `applicability_status_master.status_name = 'Applicable'`. |
| Governance Overview / Implemented | `ImplementedStatementsCount` | See below. |
| Governance Overview / Not Updated | `NotUpdatedStatementsCount` | No org applicability row, or status `Not Updated`. |

## Column widths — `data-grid-level`

Level 1 and Level 2 share the `organization-controls` screen key, but the CSS rule
that gives columns 2 and 3 a 220px minimum exists for Level 2's statement *names*.
Applied to Level 1 it stretched Owner and Total to the same width. `renderReleaseSummaryHeader`
therefore sets `data-grid-level="releases"` on `.pm-table-wrap` (the statement
renderers set `"statements"`), and the width rules in `practice-management.css`
are scoped with `:not([data-grid-level="releases"])`. Count headers and cells are
centred and sized `width: 1%` so the browser shrink-wraps them.

**Authority / Artifact / Version are not displayed.** `FrameworkRelease` already spells
out artifact + version, so three extra columns only repeat the first one. The fields are
still returned by the API and are still used by:

- the client-side search filter (`practice.js`, `loadReleaseSummary`),
- `ORDER BY Authority, ArtifactName, ReleaseVersion` in the SQL,
- `mapReleaseSelection` for the Level 2 breadcrumb.

Do not drop them from the query.

## How "Implemented Statements" is derived

A statement has **no implementation field of its own**. `applicability_status_master`
contains `Not Updated / Applicable / Not Applicable / Deferred / Accepted Risk /
Not Implemented / Retired` — there is no `Implemented` value. Implementation lives one
level down, on `practice_instance.implementation_status_id`
(`Not Implemented / Partially Implemented / Implemented / Not Applicable`, migration 045).

The roll-up path:

```
grac_new.framework_statement
  -> grac_practice.organization_statement_practice_mapping   (framework_statement_id, org_practice_id)
  -> grac_practice.organization_requirement                  (the org practice)
  -> grac_practice.practice                                  (practice.organization_requirement_id)
  -> grac_practice.practice_instance                         (implementation_status_id)
  -> grac_practice.implementation_status_master
```

The `statement_implementation` CTE counts **instances, not practices**, per
`(organization_id, framework_statement_id)`:

- `InstanceCount` — every Active instance reachable from the statement
- `ImplementedInstanceCount` — those whose `status_code = 'Implemented'`

A statement is then counted as Implemented only when **all three** hold:

1. its applicability status is `Applicable`,
2. `InstanceCount > 0` — at least one practice instance exists,
3. `InstanceCount = ImplementedInstanceCount` — *every* instance is `Implemented`.

Consequences worth knowing before someone files a bug:

- `ImplementedStatementsCount <= ApplicableStatementsCount`, always.
- One `Partially Implemented` instance anywhere under a statement drops it out of the
  count. This is intentional: the column is an assurance figure, not a progress bar.
- An Applicable statement with no mapped practice, or with practices that have no
  instances, counts as **not** implemented (it has nothing to evidence).
- A practice mapped to several statements lifts all of them together — an instance
  belongs to a practice, not to a statement, so that coupling is inherent to the model.

If a "progress" style number is ever wanted, add a **separate** column (e.g. counting
statements with at least one Implemented instance) rather than loosening this one.

## Level 2 — the Source Statements drill-down

Clicking a release row opens the statement tree in the same grid.

**Endpoint:** `POST /practice/api/practice-management/release-statements/query`
**Backend:** `PracticeRepositoryService.QueryReleaseStatementsAsync`
**Frontend:** `practice.js` — `statementTreeColumnDefs`, `renderStatementTreeHeader`, `renderStatementTree`

| Column | Field | Notes |
| --- | --- | --- |
| Statement Reference | node path + `StatementReference` | The hierarchy path and the statement's own reference in **one** column, joined by `/` (`statementReferencePath`). They used to be two columns — *Source Node / Hierarchy* and *Statement Reference* — which repeated each other, because a statement's node reference is usually its own reference. The reference is appended only when the path does not already end with it, so `REQ-7 / 7.2` never renders as `REQ-7 / 7.2 / 7.2`. |
| Statement Title | `StatementTitle` | Wraps; width comes from `.pm-cell-title`. |
| Applicability Status | `ApplicabilityStatus` | Organization decision, `Not Updated` when no org row exists. |
| Implementation Status | `ImplementationStatus` | Derived, see below. |
| Practice Count | `PracticeCount` | Distinct practices mapped to the statement. |

### Implementation Status is derived, never stored

`QueryReleaseStatementsAsync` carries the same `statement_implementation` roll-up the
Level 1 summary uses — instances, not practices — and turns it into one label:

| Result | When |
| --- | --- |
| `Implemented` | Applicable **and** at least one practice instance **and** every instance `Implemented`. Identical test to `ImplementedStatementsCount`, so the drill-down can never contradict the summary. |
| `Partially Implemented` | Applicable and at least one instance is `Implemented`, but not all of them. |
| `Not Applicable` | Applicability is `Not Applicable`, `Deferred`, `Accepted Risk`, `Not Implemented` or `Retired`. |
| `Not Implemented` | Everything else — including `Not Updated` statements and Applicable statements with no practice, no instance, or no implemented instance. |

Node rows in the `UNION ALL` select `CAST(NULL AS NVARCHAR(40)) ImplementationStatus`
in the same ordinal position; both branches must keep 21 columns in the same order.

The Organization Practices grid carries the same four labels under the same rule, one
level down — per Practice rather than per statement. Change the rule here and change
it there: see `docs/organization-practices-implementation-status.md`.

Column widths on this grid are keyed off `.pm-cell-ref` / `.pm-cell-title` classes and
`data-grid-level="statement-tree"`, not `nth-child`, because the column order differs
between this tree and the custom-release flat grid.

## Custom (organization-defined) releases

They are appended by a second query in the same method, wrapped in `try/catch` so a
database without `repository_subscription.custom_release_name` still returns the central
releases. Custom rows report all statement counts — including
`ImplementedStatementsCount` — as `0`; they have no `grac_new` statement tree to roll up.

## Column-count invariant

Three places must stay in step, or the empty-state row will not span the grid:

1. `releaseSummaryColumns` in `practice.js` — includes `"Actions"`. Only its first
   two entries and its length are used now: the length is the colspan of the
   loading / empty / error row, the first two entries are the `rowspan="2"` headers.
2. `releaseSummaryMetricColumns` — the five count headings, in `<td>` order.
   `2 + releaseSummaryMetricColumns.length + 1 (Actions)` must equal
   `releaseSummaryColumns.length`.
3. The `<td>` list in `loadReleaseSummary`'s row template — same count.
4. `PracticeScreen.All` → `organization-controls` columns — **excludes** `Actions`,
   because `Manage.cshtml` appends `<th>Actions</th>` itself, and uses the short
   count labels so the pre-hydration header matches the hydrated one.

Level 2 has the same invariant across `statementTreeColumnDefs` (single source —
`statementTreeColumns` is derived from it for the colspans), the `<td>` list in
`renderStatementTree`, and `PracticeScreen.All` → `source-statements` columns
(again minus `Actions`).

## Update Release Owner — the Source field (migration 380)

**Sir's instruction:** the Source field under Release Owner was displaying
"Manual" for every record; it should display "Repository". Trace the actual
source of the value database -> API -> frontend, confirm whether "Manual" is
hard-coded, and fix it at the correct layer -- not with a frontend-only
relabel.

**Dialog:** `openReleaseOwnerForm` (`practice.js`), opened from this grid's
3-dot menu -> *Update Owner*. Its Source field:

```js
<input value="${escapeHtml(valueOf(release, "SubscriptionType") || (releaseIdRaw < 0 ? "Custom" : "Central"))}" disabled>
```

`SubscriptionType` is one of the columns this doc already covers --
`QuerySubscribedFrameworksAsync` returns `COALESCE(sub.subscription_type,
N'Central') SubscriptionType`, straight from `repository_subscription.
subscription_type`. The `N'Central'` fallback only fires on `NULL`, and the
column is `NOT NULL`, so in practice the dialog always shows whatever is
actually stored in that column.

**Root cause.** `subscription_type` was never actually the display label
"Central"/"Repository" the dialog's own fallback implies -- it was the
literal string `'Manual'`, hard-coded into the one INSERT that creates these
rows: `dbo.pm_manage_practice_repository`'s `organization-setup` branch,
which subscribes an organization to the Repository releases selected during
Organization Setup (`grac_new.release`/`grac_new.artifact`, the central
catalog this whole document is about):

```sql
INSERT grac_practice.repository_subscription(..., subscription_type, ...)
SELECT @new_id, a.authority_id, a.artifact_id, r.release_id,
       'Manual', 'Active', ...
```

That is the *only* INSERT into `repository_subscription` that supplies
`subscription_type` for a real (non-Custom) release -- confirmed by grepping
every INSERT into the table -- so every Repository-linked subscription an
organization holds was created with this literal, which is exactly the
reported symptom (Manual, for every record).

A second, generic `repository-subscriptions` admin entity screen also
writes `subscription_type` (defaulting to `'Manual'` when the payload omits
it, with a real Automatic/Manual dropdown otherwise) -- this is a different,
lower-level CRUD screen, not this grid, and its menu row is seeded
`Inactive` (`274_menu_master_seed.sql`) and unreachable from the live
navigation. It was not the source of the reported rows and migration 380
leaves it untouched.

**Fix (migration 380).** Re-issues `pm_manage_practice_repository` with the
one INSERT literal changed to `'Repository'`, and backfills every existing
row: `UPDATE repository_subscription SET subscription_type='Repository'
WHERE release_id IS NOT NULL AND subscription_type='Manual'`.
`release_id IS NOT NULL` is exactly how this document's own Custom-release
query already distinguishes a real Repository-linked subscription from a
Custom one (Custom rows always have `release_id NULL` and
`subscription_type='Custom'` -- see "Custom (organization-defined) releases"
above), so the backfill cannot touch a Custom row.

**No API or UI change.** `QuerySubscribedFrameworksAsync` already passes
`subscription_type` straight through, and `openReleaseOwnerForm`'s Source
field already displays whatever it's given -- both were correct all along.
Once the stored value is correct, the dialog is correct with no code change
to either layer. (`Central`, the dialog's dead fallback for a `NULL`
`subscription_type`, remains unreachable -- the column has never actually
been `NULL` in this grid's data, and migration 380 doesn't change that.)

**Script fix, 2026-09-24.** The first delivered copy of migration 380 failed
partway through on execution -- `Msg 156 ... Incorrect syntax near the
keyword 'RowCount'` -- because its closing diagnostic query aliased a column
`AS RowCount`, and `ROWCOUNT` is a SQL Server reserved keyword (the same
word `SET ROWCOUNT` uses), which SQL Server will not accept unquoted as an
identifier. This only affected the very last SELECT in the script, a
read-only reporting query with no effect on the actual fix: the two
statements that do the real work -- re-issuing `pm_manage_practice_repository`
and the backfill `UPDATE` -- both ran to completion first (confirmed by the
two PRINT messages that appeared before the error) and are unaffected by
this. The alias is renamed to `AS RecordCount` in the corrected script; no
other file in this project used the same alias. Anyone who ran the original
copy and hit this error should simply re-run the corrected script in full --
both `CREATE OR ALTER` and the backfill's `WHERE subscription_type = N'Manual'`
clause are idempotent, so re-running is safe.
