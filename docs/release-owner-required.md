# Release owner first (2026-10-18)

## Rule
A subscribed release (repository or custom) must have an **owner** before
anything under it can be changed. The owner is set in:
- **Standards & Frameworks -> Update Owner** for a repository release.
- **Edit** on the release row for a custom release.

Until then the following writes are refused:

| Write | Entity type |
|---|---|
| Mark / Update statement applicability | `statement-applicability` |
| Bulk statement applicability | `statement-applicability-bulk` |
| Add / Edit / Inactivate custom statement (incl. its applicability) | `custom-statement` |
| Custom release source structure nodes | `custom-release-source-structure` |
| Custom statement classifications | `custom-statement-classification` |

Viewing is unaffected, including statement -> Practices.

**Why:** the Organization Practices grid already ignored statements of a
release without an owner (`#applicable` / `PracticeStatementScopeSetBasedSql`,
2026-09-28). A statement marked Applicable there never surfaced its practices,
and the screen gave no reason.

## API
- **Where:** `PracticeRepositoryService.ExecuteAsync` runs one guard ahead of
  all five handlers, after the permission, organization-access and
  employee-scope checks:
  `ReleaseOwnerGatedEntityTypes` + `ReleaseOwnerMissingAsync`.
- **Response:** `success = false` with this message (no field):
  "This release has no owner. Assign the release owner in Standards &
  Frameworks first; statements and their applicability can be updated only
  after that."
- **Bulk:** refused once up front. Statements are not reported as skipped one
  by one.
- **How the release is found:**
  - `subscriptionId` (custom), or `organizationId` + `releaseId` (repository).
  - "Has an owner" = any Active subscription row of the release has
    `owner_id`. This is the same reading as the subscribed-frameworks summary
    (`MAX(owner_id)`) and the practices scope gate.
  - A release that cannot be resolved is not refused here. Each handler's own
    validation (51042 / 51074 ...) reports it.
- **No database change.**

## UI (`practice.js`, `Manage.cshtml`)
- `mapReleaseSelection` carries `ownerId` (0 = none).
- `releaseOwnerMissing()` is true on the statements level of Standards &
  Frameworks / Control Statements while the open release has no owner. It then:
  - drops Mark / Update Applicability, Edit and Inactivate from the row menu
    (`RELEASE_OWNER_GATED_ACTIONS` in `allowedActions`);
  - turns bulk applicability off (`bulkEnabled`), so no checkboxes appear;
  - hides Add Control Statement and Manage Source Structure
    (`updateAddButtonLabel`);
  - shows `#releaseOwnerMessage`, an existing `.pm-message info` box above
    the grid, explaining that the owner must be assigned first
    (`renderReleaseOwnerNotice`).
- A release object built without `ownerId` (after saving a custom statement
  into another release) is treated as unknown and is not gated in the UI. The
  API still enforces the rule.

After deploying: restart the API and Ctrl+F5 (practice.js is cached).

## Diagnostics
`database/_diag_practices_statement_grouping.sql` step 1 reports a release
with no owner.
