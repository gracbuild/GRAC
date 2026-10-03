# Governance drill-down and applicability scope (change request 2026-09-28)

## What the user sees

| Screen | Before | Now |
|---|---|---|
| **Standards & Frameworks** (`organization-controls`) | A framework row click drilled **in place**. The URL, heading and menu selection stayed on Standards & Frameworks. | The row click or the row's **View** action opens the **Control Statements page** for that release (`/Practice/Index/source-statements?organizationId=&releaseId=`). Heading, URL and menu selection follow. |
| **Control Statements** (`source-statements`, Governance menu) | Auto-drilled into the organization's *first* release, with no way to switch. | The same page as the drill-down. It shows one release's statement tree at a time. A **Framework** filter lists only the releases that are *ready* (see below). |
| **Organization Practices** (`organization-requirements`) | Listed every practice, so a practice under a non-applicable statement could be marked Applicable. | Lists only practices in *statement scope* (see below). The save refuses the rest. |
| Page heading / eyebrow | Came from the static `PracticeScreen.cs` title (for example "Practices"). | Follows the sidebar label (for example "Organization Practices"). |

## Rules

**Release ready for Control Statements.** Both conditions must hold:

- The release owner is assigned (`repository_subscription.owner_id`).
- At least one of the release's statements has its applicability marked. The check is `TotalStatementsCount - NotUpdatedStatementsCount > 0`, using the same subscribed-frameworks summary Standards & Frameworks shows.

All statements of a ready release are listed, so the remaining ones can still be marked.

**Exceptions:**

- A release opened explicitly from Standards & Frameworks is offered if it has an owner, even when nothing has been marked yet. Otherwise its first statement could never be marked.
- If that release has no owner, the page says to assign one first.

**Practice in statement scope.** A practice is in scope when any of these is true:

- It is **not** Repository-origin. Custom and organization practices always show.
- It has **no statement link at all**. Legacy control-only practices keep showing.
- One of its statements is **Applicable** under a release that has an owner. The statement link can be its primary `org_statement_id` or any `organization_statement_practice_mapping` row. A custom release is judged on applicability alone.

The predicate is `PracticeStatementScopeSql` in `PracticeRepositoryService`. It is defined once and used by both:

1. The Practices grid query (`QueryOrganizationRequirementFallbackAsync`). A single-record read (`id > 0`) is not filtered, so an open form still loads.
2. The applicability guard. Marking a practice **Applicable**, singly (`organization-requirements` EDIT) or in bulk (`requirement-applicability-bulk`, per row), is refused with:

   > This practice cannot be marked Applicable: none of its control statements is Applicable under a release with an owner.

## Navigation details

- **Back** on Control Statements returns to `organization-controls?list=1`.
- **Employee scope with a single release** now opens that release's Control Statements page (it used to drill in place). `?list=1` stops the Back link from bouncing straight back.
- **Organization in the URL.** On `source-statements`, an `organizationId` in the URL takes precedence over the first-organization pick.

## API

- No new endpoint or parameter.
- `organization-requirements` query results are narrowed as described above.
- `organization-requirements` saves and `requirement-applicability-bulk` can now return:
  - `Success=false`
  - `Field=applicabilityStatus`
  - the message above.

## Files

- `src/PracticeManagement.Web/wwwroot/js/practice.js`:
  - `releaseReadyForStatements`, `openControlStatementsPage`, `openControlStatementsRelease`
  - the row-click and View action changes
  - the Back behaviour
  - the organization pick
- `src/PracticeManagement.Web/Views/Practice/Manage.cshtml`: Framework filter on `source-statements`.
- `src/PracticeManagement.Web/Controllers/PracticeController.cs`: `WithSidebarLabel`.
- `src/PracticeManagement.Api/Services/PracticeRepositoryService.cs`:
  - `PracticeStatementScopeSql` and `PracticeStatementsAllowApplicableAsync`
  - the grid filter
  - the single and bulk guards
- No database script. Everything reads existing columns.
