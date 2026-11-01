# View Data Scope (migration 415)

Role add/edit -> **Menu Permissions** section -> **Advanced Settings ->
View Data Scope**. A role-level setting, separate from the menu matrix:
the matrix decides which menus a role may View / Add / Edit / Delete /
Approve; View Data Scope decides which *records* a View shows.

| Option | Stored | A reader sees |
| --- | --- | --- |
| All records | `ALL` | every record (the behaviour before 415; default for every existing and new role) |
| Location | `LOCATION` | records of the reader's location |
| Team | `TEAM` | records assigned to the reader's teams |
| Assigned Owner | `OWNER` | only records the reader owns |

`organization_role.view_data_scope` (NOT NULL DEFAULT 'ALL', CHECK). The
existing `organization_role.data_scope` (GLOBAL / ORGANIZATION / RELEASE
/ ...) is a different setting and is unchanged.

The reader's location, teams and identity are read live at query time;
nothing about a person is stored on the role. Several roles: the reader
sees the union (any role on All records = unrestricted), the same rule
sign-in uses to merge menu permissions.

## Relationships (existing)

* reader -> location: `organization_employee.location_id`
* reader -> teams: `organization_team_member` (active by `record_status_id`)
* record -> owner: the table's own owner column
* record -> team: the owner shares a team with the reader, or the
  record's practice instance was configured for one of the reader's
  teams (`practice_dependency_resolution`, TEAM)
* record -> location: the owner's location, or the instance's resolved
  LOCATION dependency

| Table | Owner column | Instance link |
| --- | --- | --- |
| practice_instance | primary_owner_id | itself |
| practice_task | assigned_to_employee_id | linked_instance_id |
| custom_gap | owner_employee_id | source_reference (PracticeInstance) |
| exception_request | owner_employee_id | -- |
| risk_register | risk_owner_employee_id | -- |
| risk_candidate | assigned_analyst_employee_id | -- |
| org_assurance_plan | owner_employee_id | -- |
| org_assurance_execution | owner_employee_id | -- |
| org_assurance_observation | assigned_owner_employee_id | -- |

A record with no owner (and no instance link) is visible only to
unrestricted readers.

## Enforcement (backend, one mechanism)

1. **Web**: `Security/CallerIdentityHandler` stamps the session employee
   (`X-PM-Caller-Employee-Id`) on every call through the
   `PracticeManagementApi` HttpClient, overwriting anything else -- the
   browser cannot set it. The gateway's signed envelope already carries
   `callerEmployeeId`.
2. **API**: a request middleware marks every GET as a read by that
   employee (`Infrastructure/CallerViewScope`); the gateway's
   `secure/query` does the same from the envelope.
   `Infrastructure/ViewScopeSession.ApplyAsync` runs after every
   connection open in every service and, for a read, calls
   `sp_pm_view_scope_session_set`.
3. **SQL**: that procedure resolves the reader's roles and, unless one is
   All records, writes the scope into `SESSION_CONTEXT`. The row-level
   security policy `grac_practice.pm_view_data_scope_policy` (predicate
   `fn_pm_view_scope_core`) then filters every query of the nine tables on
   that connection -- lists, get-by-id, dashboards, views, any procedure.
   A changed URL, record id, or another page's API cannot return a row
   outside the scope.

Writes are never scoped, so write procedures keep their cross-record
syncs and checks, and the Edit / Delete model is unchanged; an
out-of-scope record cannot be loaded, so it cannot be opened for edit.
`SESSION_CONTEXT` is reset when a pooled connection is reused. Workers,
scripts and a sign-in without an employee record are unrestricted.

Unrestricted readers are cached by the API for 60 seconds, so a role
changed from All records to a restricted scope applies within a minute;
any other change applies on the next read.

The API trusts the caller header from the Web tier, as the existing
`X-PM-Caller-*` design does -- it must not be exposed directly to users.

## API

| Tier | Route |
| --- | --- |
| Web | `GET/POST /practice/api/roles/{roleId}/view-data-scope` (VIEW / ADD or EDIT on role-menu-permissions, organization allowed) |
| API | `GET /api/practice/roles/{roleId}/view-data-scope?organizationId=` -> `{ roleId, organizationId, viewDataScope }` |
| API | `POST /api/practice/roles/{roleId}/view-data-scope` `{ organizationId, viewDataScope }` (ALL / LOCATION / TEAM / OWNER; 57320 bad value, 57321 role not in org) |

The Advanced Settings value is staged with the matrix and written by
the Role dialog's Save (`flushPending`).

Rollback: `415_role_view_data_scope_rollback.sql` (drops the policy first).

## Diagnostic (2026-10-09)

`database/_diag_view_data_scope_user.sql` (read-only): for one login it lists
the roles the scope procedure considers with their View Data Scope (one role on
All records makes the user unrestricted), the policy state, and, table by
table, the rows visible under the user's scope vs all rows. Remember the scope
covers only the nine tables above -- Organization Practices, Control
Statements, Standards & Frameworks, assets and other lists are not filtered by
it.

## Organization Practices and Control Statements (migration 460, 2026-10-09)

Reported: a role on Assigned Owner still saw every row on Organization
Practices and Control Statements. The diagnostic showed the nine 415 tables
correctly filtered (0 rows visible) -- those two lists read tables outside the
policy (organization_requirement / practice / organization_framework_statements
/ custom_release_statement).

460 adds two predicates on top of 415's `fn_pm_view_scope_owner` (so Owner /
Team / Location keep one definition), and the API applies them in the two list
queries only:

| List | Predicate | Visible to a restricted reader when |
| --- | --- | --- |
| Organization Practices (`QueryOrganizationRequirementFallbackAsync`, incl. get-by-id) | `fn_pm_view_scope_requirement(organization_requirement_id)` | the practice owner (`practice.practice_owner_id`) is in scope, OR one of its practice instances is visible (practice_instance is already RLS-filtered) |
| Control Statements, repository (`QueryReleaseStatementsAsync`) and custom (`QueryCustomReleaseStatementsAsync`) | `fn_pm_view_scope_statement(owner, org, framework_statement_id, org_statement_id)` | the statement owner is in scope, OR a mapped practice (`organization_statement_practice_mapping`) is visible by the rule above |

A statement with no owner and no visible mapped practice is hidden. Structure
node rows are not filtered (they are a lookup for the tree; the grid shows
statement rows only).

Not added to the security policy on purpose: practice / requirement /
statement tables are joined by most other lists (instances, tasks, gaps,
risks), and filtering them for every read would drop a reader's own instances
and tasks whenever the practice above them is owned by someone else.

Unrestricted readers are unaffected. Rollback:
`460_view_scope_practices_statements_rollback.sql` (roll back the Api first).
