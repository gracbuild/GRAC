# Organization Practices - grouped by Source Statement, one release at a time (2026-10-18)

## Why
The Control concept is gone: an organization's practices are linked to
**source statements** only. A practice is unique (one `organization_requirement`
per repository requirement, `sp_repository_practice_import`, 392). It carries
its first statement in `organization_requirement.org_statement_id`. Every
statement it belongs to, including statements of other frameworks, is in
`organization_statement_practice_mapping`.

Before this change the grid's group heading was the practice's primary
**Control** (`ControlCode - ControlName`, e.g. `AC-001 - User Access
Provisioning`). The framework filter only narrowed the rows and never changed
the heading.

Grouping by source statement is ambiguous under "All subscribed frameworks":
a practice mapped to statements of several frameworks has no single heading.
So that option is removed.

## Behaviour
- **Framework filter** (`#subscribedFrameworkFilter`) on Organization Practices
  always holds one release, and it has no "All subscribed frameworks" option.
  - Default is the first row of the list. `subscribed-frameworks/query`
    orders it Authority -> Artifact -> Release, with Custom releases
    (`Organization / <name>`, `ReleaseId = -subscription_id`) after the
    repository ones.
  - A choice that is still offered survives a reload.
  - **Clear Filter** returns to the first row.
- **Organization change** reloads the list and keeps the selected release if
  the new organization subscribes it too. Otherwise the filter takes the first
  row.
- **No subscribed release:** the filter shows "No subscribed frameworks" and
  the grid says so. No query is sent. If the list fails to load, the grid says
  that instead.
- **Group heading** = `<statement reference> - <statement title>` of a
  statement of the selected release.
  - A practice is listed under **every** statement of that release it is
    linked to, through its own statement or a mapping row. This is the rule the
    Control Statements drill already follows.
  - A **Repository** practice appears only under statements that pass the
    grid's existing scope gate (`#applicable`: Applicable, under a release
    with an owner). So it never sits under a Not Applicable statement.
  - Organization / Hybrid practices are not gated, as before.
- **Custom practices** appear under their Custom release's statements. A
  practice linked to no statement of any release is not listed. Select its
  Custom release once it is mapped to a custom statement.
- **Bug fixed on the way:** the old release filter matched only the release of
  the practice's *own* statement (or its Control). A practice whose first
  statement sits in framework A was missing from framework B, even when it was
  mapped to B's statements. It now appears under B's statements.
- **Search** also matches the group heading's statement reference and title.
- **Bulk applicability:** a practice listed under two statements has two
  checkboxes. Ticking one ticks the other. The selection is still one id per
  practice.
- **Control Statement drill** (Source Statement -> Practices, filter type
  `FrameworkStatement` / `OrgStatement`) is unchanged: a flat list with no
  headings.
  - The framework filter shows the context's release, locked.
  - A custom statement's context carries no release. There the filter shows
    the locked "All subscribed frameworks" placeholder and sends no
    `releaseId`.

## API change
`QueryOrganizationRequirementFallbackAsync` (`PracticeRepositoryService.cs`) is
the only query serving this grid (see
`organization-practices-implementation-status.md`, "Which query serves this
grid"). Endpoint, request and procedure are unchanged.

- **New response columns:** `GroupOrgStatementId`, `GroupFrameworkStatementId`
  (NULL for custom statements), `GroupStatementReference`,
  `GroupStatementTitle`.
- **Rows:** with `releaseId` in the payload, the query returns one row per
  (practice, linked statement of that release) through an `OUTER APPLY grp`.
  - Repository release: `organization_framework_statements` rows of the
    release with `source_type = 'Repository'`, `copied_dt` set and an Active
    structure node.
  - Custom release: that subscription's `source_type = 'Custom'` statements.
  - Narrowed to the drilled statement when `frameworkStatementId` /
    `orgStatementId` is present (and not re-gated, so the drill lists what it
    did before).
- **Release filter:** `@release_id IS NULL OR @p_id <> 0 OR
  grp.GroupOrgStatementId IS NOT NULL`. This replaces the old
  `COALESCE(ofs.release_id, filter_oc.release_id, oc.release_id) = @release_id`
  test and the separate custom branch.
- **Unchanged cases:** without `releaseId`, or on a single-record read (`id`),
  `grp` is empty and the query returns one row per practice, exactly as before.
- **`TotalRows`** counts the expanded rows, so the pager matches what is drawn.
- **Order:** statement node display order -> statement display order ->
  statement reference -> statement -> practice code. One statement's rows are
  contiguous.
- **Legacy columns:** `ControlCode` / `ControlName` / `MappedControl` /
  `OrganizationControlId` are still returned but no longer drive the grid.

No database migration. The query reads existing tables only.

## Files
- `src/PracticeManagement.Api/Services/PracticeRepositoryService.cs`:
  `QueryOrganizationRequirementFallbackAsync`. Adds `grp` and the group
  columns, plus the release filter, search and order changes.
- `src/PracticeManagement.Web/wwwroot/js/practice.js`:
  - `loadSubscribedFrameworks`: single-release mode on this screen only.
    Standards & Frameworks and Control Statements still get "All".
  - `loadRows`: release-required guard.
  - `isPracticeStatementDrill`: shared drill test.
  - `renderRequirementStatementGroups`: replaces `renderRequirementControlGroups`.
    It keeps the `pm-control-group-row` / `pm-control-group-head` classes, so
    there is no CSS change.
  - Bulk checkbox sync.
- `src/PracticeManagement.Web/Views/Practice/Manage.cshtml`: the server-rendered
  placeholder reads "Loading frameworks..." on this screen.

After deploying: Ctrl+F5 (practice.js is cached).

## Not changed (still Control-based)
- **Practice Picker** (`practice-picker.js`; Gap / Exception / Risk Centre):
  Framework -> Structure -> **Control / Statement** -> Practice -> Instance.
- **`organization_control` rows** are still created on subscription
  (`pm_manage_practice_repository`). The `ORG-PRACTICES` container is still
  created for Add Practice.
