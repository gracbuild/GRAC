# Custom framework: Control Statements grid parity + Organization Practices filter

Change request 2026-10-08. **Database:** no schema change. Every table and column used
already exists (347 overlay `organization_framework_statements.source_type/subscription_id/custom_statement_id`,
`organization_statement_practice_mapping.org_statement_id`, `custom_release_source_structure.parent_node_id`).

## 1. Control Statements on a Custom release looks and behaves like a repository release

Before: a Custom release rendered a separate flat grid
(Hierarchy / Source Structure Node / Statement Reference / Statement Title / Applicability / Practice Count),
**Practice Count was hard-coded 0**, there was no Implementation Status, and there was no way into Practices.

Now: the same grid as any repository release.

| Column | Custom release value |
| --- | --- |
| Statement Reference | Custom Source Structure path + statement reference (`statementReferencePath`, same as repository) |
| Statement Title | `custom_release_statement.statement_title` |
| Applicability Status | `custom_release_statement.applicability_status_id` (unchanged) |
| Implementation Status | Same CASE as `QueryReleaseStatementsAsync` (456 rules), over the practices mapped to the statement |
| Practice Count | Practices mapped through `organization_statement_practice_mapping.org_statement_id` |

- **Row click / "Practices" action** on an Applicable custom statement opens Organization Practices filtered
  to that statement, the same as on a repository release. Employee scope gets neither, as before.
- Custom statements keep **View / Edit / Inactive** (they are authored by the organization). Applicability is
  still set in the Edit form. Bulk Mark Applicability stays repository-only.

### API: `custom-release-statements/query` (`QueryCustomReleaseStatementsAsync`)
Added columns (all existing columns are unchanged, since the mapping picker and the custom View/Edit forms read them):
`ApplicabilityStatusCode`, `ApplicablePracticeCount`, `ImplementationStatus`, `StructureNodePath`. `PracticeCount` is now real.

## 2. Organization Practices: selecting a Custom framework said "not subscribed"

The Framework filter lists Custom releases with the synthetic `ReleaseId = -1 * subscription_id`
(`QuerySubscribedFrameworksAsync`). `QueryOrganizationRequirementFallbackAsync` checked
`repository_subscription.release_id = @release_id`, but a custom subscription stores `release_id` NULL, so every
custom release failed with 51042 *"The selected framework release is not subscribed for this organization."*
The release filter (`ofs.release_id = @release_id`) could never match a custom statement either.

### API: `organization-requirements/query`
- `releaseId < 0`: validated against the Custom subscription (`subscription_id = -releaseId`, type Custom, Active).
  A practice matches when its own statement, or any statement it is mapped to, is a custom statement of that subscription.
- `releaseId > 0`: unchanged.
- New optional payload field **`orgStatementId`**: practices whose `org_statement_id` is that statement, or that are
  mapped to it. Used by the custom-statement drill.

### Navigation
New navigation filter type **`OrgStatement`** (FilterId = `org_statement_id`), target `organization-requirements`.
Allowed in `PracticeManagementGatewayController.IsAllowedNavigation`. `practice.js` treats it like
`FrameworkStatement` (context banner, flat practice list, no control filter) and sends `orgStatementId`.

## Files
- `Api/Services/PracticeRepositoryService.cs`: `QueryCustomReleaseStatementsAsync`, `QueryOrganizationRequirementFallbackAsync`
- `Web/Controllers/PracticeManagementGatewayController.cs`: `IsAllowedNavigation`
- `Web/wwwroot/js/practice.js`: `loadCustomReleaseStatements`, `renderCustomStatementGrid`, `allowedActions`,
  `handleAction` (custom branch), Practices navigation-context handling. The unused `customStatementFlatColumns` was removed.

## Follow-up fixes (same day)

- **"The navigation context is invalid or has expired" on row click.** `PracticeManagementGatewayController.ApplyNavigationContext`
  throws for any filter type it does not list, and `OrgStatement` was not listed. It now is, and it is applied like
  `FrameworkStatement`: `orgStatementId` is set from the signed context (not trusted from the browser), and
  `organizationControlId` / `frameworkStatementId` are removed.
- **Wrong column headings while a Custom release loads.** `loadCustomReleaseStatements` drew the statement-tree
  header only after its two lookups (structure nodes, classifications), so the previous header stayed on screen until
  they returned. The header and the "Loading…" row are now drawn first, as `loadReleaseStatements` does.

## Second round of fixes

- **SQL error 8117 on the Practices page.** The release filter used unary minus on `@release_id` in SQL. When no release
  is passed, the parameter is an untyped NULL (nvarchar), and `-nvarchar` is error 8117. This failed every Practices
  query, not only custom ones. The custom subscription id is now computed in C# and passed as `@custom_subscription_id`.
- **Framework filter not selected after the drill.** The Practices screen never preselected the Framework filter from
  the navigation context, for repository or custom statements. `loadSubscribedFrameworks` now selects the context's
  `releaseId` and locks the filter, like the Organization filter. The custom drill now carries its release
  (`-subscription_id`), so the API also scopes the list to that release.
- **"Standards & Frameworks" header flashing on Control Statements (all frameworks).** `loadReleaseSummary` painted the
  release-summary header and "Loading subscribed framework releases..." before choosing the release to open. On the
  Control Statements screen it now keeps the statement-tree header ("Loading control statements..."), including the
  no-organization message.
