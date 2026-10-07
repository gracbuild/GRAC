# Permission mapping: Organization Administration tabs and Practice View

**Files:** `Web/Security/PermissionAreaMap.cs` (also compiled into the API),
`Web/Controllers/PracticeController.cs` (`ScreenPermissionArea`),
`Web/Controllers/PracticeManagementGatewayController.cs` (navigation code/context)
**Database:** no change. **UI:** no change. The tab buttons already use Organization
Administration's actions (`ViewBag.Permissions = ActionsFor("organization-administration")`).

## Why "no permission" appeared even with every View ticked

A sign-in's permissions are built only from **Active** `menu_master` rows
(`PracticeAuthenticationService.LoadPermissionsAsync`: `m.status = 'Active'`), and
the Role Menu Permission matrix lists only Active rows (`menu-master` query).
A screen whose own menu row is Inactive, or missing, therefore needs a grant that no
role can ever hold. Only `PM_ADMIN` (`*:*`) gets through.

| What was refused | Area checked | Menu row |
| --- | --- | --- |
| Org Administration → Location, Department, Business Function, Teams, **Committees** tabs | `locations`, `departments`, `business-functions`, `teams`, `committees` | Inactive since **060** (taken out of the sidebar because they became tabs) |
| **Practice View** page ("View" on Organization Practices) | `practice-view` (page, navigation code, navigation context) | No row at all |
| Practice View → **Obligations** panel ("Could not load published obligations (HTTP 403)") and the Practice Instance form's obligation section | `evidence-obligations` (mapped from `evidence-obligations-typed`) | No row at all (the old *View Obligations* screen) |

## The mapping now

| Entity / screen | Governed by |
| --- | --- |
| `locations`, `departments`, `business-functions`, `teams`, `committees` | `organization-administration` (VIEW lists, ADD/EDIT/DELETE for Add/Edit/Inactive) |
| `committee-designations` (Add Designation quick-create) | `organization-administration` (was `committees`) |
| `practice-view` | `organization-requirements` (same rule as `practice-instances`) |
| `evidence-obligations-typed` (published obligations of a practice) | `organization-requirements` (was `evidence-obligations`) |

The navigation-code and navigation-context checks now resolve `SourceArea`/`TargetArea`
through `PermissionAreaMap`, the same way every entity check on the gateway does.

## What to grant

- **Organization Administration tabs:** *Administration* (`organization-administration`)
  → View, plus Add/Edit/Delete as needed.
- **Users / Employees tab:** unchanged. It is still governed by *User Management*
  (`users`, Active row) → View.
- **Practice View:** *Organization Practices* (`organization-requirements`) → View.
- Permissions are read **at sign-in**. After changing a role, the user must sign out and
  sign in again.

Note: the Organization Setup workspace (GRAC admin) shows the same five tabs, so a
non-PM_ADMIN role using it now also needs the Administration grant for them.

## 2026-10-03 — Issues & Actions route screens

Same cause, more screens. A new organisation's Admin (DB role, not
`PM_ADMIN`) opening **Gap Details** got "No permission ... ticking View for
the `gap-detail` menu" — but `gap-detail` has no `menu_master` row, so
`pm_grant_organization_default_access` (217, run at organisation creation)
had nothing to grant and the Role Menu Permissions matrix has no such
checkbox. Only `PM_ADMIN` (`*:*`, e.g. admin@grac.local) ever got through.

`PracticeController.ScreenPermissionArea` now maps (page access + the page's
`ViewBag.Permissions`):

| Screen | Governed by |
| --- | --- |
| `gap-detail`, `gap-view` | `gaps` (Gap Register) |
| `task-view` | `tasks` (Task Board) |
| `exception-analysis`, `exception-view` | `exception-centre` |

These pages are opened by plain URL (no navigation code), so
`PermissionAreaMap` needs no entry. No database change.

`AccessDenied.cshtml` now names the menu the check actually used
(`ScreenPermissionArea(Model.Key)`) instead of the screen key, so the hint
points at a checkbox that exists.

## 2026-10-06 — Organization screen: Users and Organization tabs

Symptom: on Organization (Organization Administration) the Location /
Department / Business Function / Teams / Committees tabs worked, but
**Users** answered "You do not have permission to view users" and the
**Organization** (details) tab failed too. `_diag_user_permissions.sql` for
the user: `users` -- 0 permission rows for any of the user's roles.

Cause: both tabs were governed by menus an organization admin cannot be
granted from Role Master's permission matrix:

| Tab | Area checked | Why it could not be granted |
| --- | --- | --- |
| Users | `users` (User Management) | menu row Active, but its parent `nav-administration` is InActive -- not in the sidebar, not in the matrix |
| Organization | `organization-setup` (via `organization-setup/query`) | the GRAC Admin's Organization Setup menu (parent `Organization` InActive); not an org-admin grant |

Fix (no database change):

| Entity | Governed by now |
| --- | --- |
| `users` | `organization-administration` (same rule as the other five tabs; ADD/EDIT/DELETE follow that screen) |
| `organization-profile` (new alias) | `organization-administration`; organization-scoped at the gateway |

- `practice.js`: the Organization tab of Organization Administration reads
  `organization-profile/query`; Organization Setup still reads
  `organization-setup`.
- API `PracticeRepositoryService.ExecuteAsync`: `organization-profile` is
  QUERY-only (any manage call is refused -- an `organization-setup` SAVE
  rewrites the organization's subscriptions from `releaseIds`), requires
  `organizationId` (then the normal organization-access check runs), and is
  resolved to `organization-setup` for the procedure. Added to the API's
  `Supported` list and the gateway's `OrganizationScopedEntityTypes`.
- Gateway `ProvisionAndNotifyOrganizationAdmin` (Resend from the Users tab)
  accepts `PermissionArea("users")` ADD, i.e. Organization Administration
  ADD, alongside `organization-setup` ADD.

Sign out and in again after deploying (permissions load at sign-in).

## 2026-10-06 — Risk Management submenus ("No permission ... risk-centre")

Symptom: Risk Candidate, Risk Register (and the other Risk Management
submenus) answered "Your role does not have View permission for Risk
Candidate ... ticking View for the `risk-centre` menu", although the role
had the submenus ticked.

Cause: every `risk-centre-*` screen is governed by `risk-centre`
(`PracticeController.ScreenPermissionArea`, 383; the Risk Centre API uses
the same area). Since 383/416 `risk-centre` is a CONTAINER (menu_url `#`),
and Role Master's matrix (`role-menu-permission-editor.js`, `isContainer`)
draws only a container's children -- so a role set up through the matrix
can never hold `risk-centre:*`. Older roles still had the row from before.

Fix (API sign-in, `PracticeAuthenticationService.LoadPermissionsAsync`): a
container menu (Active, `menu_url` NULL / '' / '#') now holds, per action,
the union of what its Active children hold (plus any row of its own). So a
role with View on any Risk Management submenu gets `risk-centre:VIEW`; ADD /
EDIT / APPROVE likewise. Applied only when `menu_master.parent_menu_id`
exists (052). No database change, no change to the matrix. Users must sign
out and in again.

Note: as designed in 383, all Risk Management submenus share `risk-centre`,
so View on one submenu opens the others by URL; the sidebar still lists
only the submenus the role was granted.
