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
