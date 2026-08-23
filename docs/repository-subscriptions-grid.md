# Repository Subscriptions grid (Level 1) — developer notes

**Screen:** `organization-controls` (menu *Governance → Repository Subscriptions*), alias `source-statements`
**Endpoint:** `POST /practice/api/practice-management/subscribed-frameworks/query`
**Backend:** `Api/Services/PracticeRepositoryService.QuerySubscribedFrameworksAsync`
**Frontend:** `Web/wwwroot/js/practice.js` — `releaseSummaryColumns`, `loadReleaseSummary`
**Header fallback:** `Web/Models/PracticeScreen.cs` (`organization-controls` columns)

---

## Columns

| Column | Field | Notes |
| --- | --- | --- |
| Framework / Release | `FrameworkRelease` | `artifact_code + ' ' + version_no`; falls back to `artifact_name + ' ' + version_no`, then `version_no` alone. Custom releases read `Organization / <custom_release_name>`. |
| Owner | `OwnerName` | `employee_code - employee_name`; renders *Unassigned* when the subscription has no owner. |
| Total Statements | `TotalStatementsCount` | Active `grac_new.framework_statement` rows on an Active structure node of the release. |
| Applicable Statements | `ApplicableStatementsCount` | `applicability_status_master.status_name = 'Applicable'`. |
| Implemented Statements | `ImplementedStatementsCount` | See below. |
| Not Updated Statements | `NotUpdatedStatementsCount` | No org applicability row, or status `Not Updated`. |
| Not Applicable Statements | `NotApplicableStatementsCount` | `Not Applicable`, `Deferred`, `Accepted Risk`, `Not Implemented`, `Retired`. |

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

## Custom (organization-defined) releases

They are appended by a second query in the same method, wrapped in `try/catch` so a
database without `repository_subscription.custom_release_name` still returns the central
releases. Custom rows report all statement counts — including
`ImplementedStatementsCount` — as `0`; they have no `grac_new` statement tree to roll up.

## Column-count invariant

Three places must stay in step, or the empty-state row will not span the grid:

1. `releaseSummaryColumns` in `practice.js` — includes `"Actions"`.
2. The `<td>` list in `loadReleaseSummary`'s row template — same count.
3. `PracticeScreen.All` → `organization-controls` columns — **excludes** `Actions`,
   because `Manage.cshtml` appends `<th>Actions</th>` itself.
