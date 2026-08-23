# Cross-organisation admin accounts — developer notes

How a database account is given the reach that `admin@grac.local` has,
and why that takes two independent grants rather than one.

**Migrations:** `220_grac_admin_users.sql` / `220_..._rollback.sql`, on top
of `027` (role_code, `organization_employee_role`), `032`/`034`
(`data_scope`, `force_password_change`), `133`+`208` (`sp_org_user_save`),
`217` (`pm_grant_organization_default_access`).
**Backend:** `Api/Services/PracticeAuthenticationService.cs`
(`LoadPermissionsAsync`, `LoadAllowedOrganizationsAsync`,
`LoadEffectiveDataScopeAsync`), `Web/Controllers/LoginController.cs`
(`SignIn`), `Web/Security/OrganizationAccessContext.cs`,
`Web/Controllers/PracticeManagementGatewayController.cs`
(`IsSystemAdmin`, `AllowedOrganizationIds`).

---

## `admin@grac.local` is not a database account

It is the Web tier's **ReviewLogin**, configured in
`Web/appsettings.Development.json` and handled by its own branch in
`LoginController.Index`:

```jsonc
"ReviewLogin": {
  "Email": "admin@grac.local",
  "PasswordHash": "210000....",
  "Roles": [ "PM_ADMIN" ]
}
```

That branch does three things no database sign-in does:

| | ReviewLogin | Database sign-in |
| --- | --- | --- |
| Permission tokens | `Security:RolePermissions["PM_ADMIN"]` = `*:*` | `menu_key:ACTION` rows from `organization_role_menu_permission` |
| `DataScopeKey` | hard-coded `"GLOBAL"` | `organization_role.data_scope` |
| `OrganizationIdKey` | deliberately **not set** — picks an org from the dropdown | the employee's home organisation |

Nothing in `grac_practice` backs it, so no employee row can *be* that
account. What a database account can have is the equivalent, and the
equivalent is two separate grants.

## Two gates, and neither implies the other

This is the part that costs an afternoon if it is missed.

**Gate 1 — `data_scope = 'GLOBAL'` on the role.**
`LoadEffectiveDataScopeAsync` picks the broadest scope across the
employee's roles, `SignIn` stores it as `DataScopeKey`, and
`OrganizationAccessContext.IsGlobalScope` / `IsOrganizationAllowed`
short-circuit to "any organisation" on it. This is what makes the
organisation dropdown list every active organisation.

**Gate 2 — a `user_organization_map` row per organisation.**
`PracticeManagementGatewayController` does **not** go through
`IsOrganizationAllowed`. It tests
`AllowedOrganizationIds().Contains(...)` directly (the org-provision
route and `EnsureOrganizationAccess`), and that list comes from
`LoadAllowedOrganizationsAsync`, which reads `user_organization_map`
plus the home organisation and nothing else. Its own admin escape hatch,
`IsSystemAdmin()`, matches the literal role token `PM_ADMIN` — which a
database session never carries, because its tokens are menu permissions.

So a GLOBAL-scoped user with no map rows sees every organisation in the
dropdown and gets **403** on every gateway call against any of them but
their own. Grant both.

## Why a separate role

`pm_create_organization_admin` (migration 034, re-issued by 217) hunts
for `role_name = 'Admin'` and forces `data_scope` back to
`'ORGANIZATION'` — migration 034 §1 exists precisely to demote the
GLOBAL scope that 032 handed out. A GLOBAL scope parked on a role named
`Admin` is therefore reverted the next time an organisation admin is
provisioned or credentials are resent. It would also widen the existing
Organisation GRAC Admin's access as a side effect, since that account
holds the same role.

Migration 220 creates `GRAC Admin` / `role_code = 'GRAC_ADMIN'` instead.
The name is outside 034's filter, so the GLOBAL scope survives.

### The cost of that choice

`pm_grant_organization_default_access` tops up roles matching
`role_name = 'Admin' OR role_code = 'ORG_ADMIN'`. `GRAC_ADMIN` is
outside that filter, so **a menu added by a future module does not reach
this role on its own**. Re-run section 2 of `220_grac_admin_users.sql`
(idempotent) after any migration that seeds new menus, or widen the
proc's filter if these roles become a permanent fixture.

`role_code = 'ORG_ADMIN'` could not simply be reused: index
`ux_pm_org_role_code` is `UNIQUE(organization_id, role_code)` and the
organisation's own admin role already holds it.

## Why the accounts go through `sp_org_user_save`

Not a direct `INSERT`. The procedure is what the Users screen calls, so
routing through it means the rows carry the same validation, the same
`party_type` handling, the same department denormalisation and the same
`user_organization_map` side effect a hand-created user gets. A direct
insert is a second definition of "what a user row looks like", and the
two drift.

The role is then written in **both** places — `organization_employee.role_id`
and `organization_employee_role` — because they are read by different
code. Migration 131 documents the defect that comes from writing only
one: the Employee form writes `role_id`, `LoadPermissionsAsync` unions
over the M:N map, and the event resolver reads `role_id`.

## Passwords

T-SQL cannot produce a value `PasswordHasher.Verify` accepts, so 220
carries hashes generated offline with the parameters in
`Web/Security/PasswordHasher.cs` — PBKDF2-HMAC-SHA256, 210 000
iterations, 16-byte salt, 32-byte key, `"<iterations>.<salt>.<hash>"`,
one salt per account. They encode `Grac@123`, the standard
`UserProvisioning:DefaultPassword`.

`force_password_change = 1` is set alongside, so
`LoginController.Index` refuses to open a session and redirects to
`ChangePassword` on first sign-in. The password in the script is a
handover credential, not a stored secret — it stops working the moment
each user completes that screen. See [user-credentials](user-credentials.md)
for the provisioning model this follows.

## Feature flags

`fn_pm_feature_enabled` resolves per-org row → `feature_flag_master.default_enabled`
(0) → 0, so an organisation with no `feature_flag` rows renders the "not
available" banner regardless of role. Cross-organisation access is worth
little if switching organisation lands on that banner, so 220 calls
`pm_grant_organization_default_access @organization_id = NULL`.

**Side effect, stated rather than hidden:** that call also tops up every
organisation's *own* Admin role with any menu it is missing. It is
insert-only and it is 217's designed behaviour, but it is a change
beyond these three accounts. Drop section 6 if that is not wanted.

## What is not covered

An organisation created **after** 220 runs is covered by `data_scope`
GLOBAL for screen-level scope, but not by the gateway's
`AllowedOrganizationIds` check — there is no trigger keeping
`user_organization_map` in step with new organisations. Re-run section 5
when an organisation is onboarded, or add the row from the Users screen.

## Why a permission denial used to say "invalid response"

A user who could sign in but lacked a screen's grant saw

> The practice service returned an invalid response.

That message comes from `fetchJson` in `practice.js`, and it means one
thing only: `response.json()` threw, so the body was not JSON.

The cause was `ControllerBase.Forbid()`. It delegates to
`HttpContext.ForbidAsync()`, which needs an authentication scheme to
hand the challenge to — and this application registers none. `Program.cs`
has `AddSession` and `UseAuthorization` but deliberately no
`AddAuthentication` / `UseAuthentication`, because identity lives in the
session rather than in a `ClaimsPrincipal`. So every `Forbid()` threw

```
InvalidOperationException: No authenticationScheme was specified,
and there was no DefaultForbidScheme found.
```

and the route answered with HTML — the developer exception page in
Development, `/Home/Error` elsewhere — to a `fetch` expecting JSON.

`admin@grac.local` never met it: `PM_ADMIN` = `*:*` passes every check.
Any database user is one missing grant away from it.

**Fixed in:**

| File | Change |
| --- | --- |
| `PracticeManagementGatewayController.cs` | New `PermissionDenied(area, action)` returns `403` + JSON naming the missing grant. Replaces all seven `Forbid()` calls; matches the shape `ValidateRequestedOrganization` already used |
| `PracticeController.cs` | `ScreenAccessDenied(screen)` renders the new `Views/Practice/AccessDenied.cshtml` with status 403, instead of `Forbid()` on the two screen-render paths |
| `practice.js` | The 403 branch now shows the server's message; the non-JSON fallback names the HTTP status instead of hiding it |

The status code is unchanged in every case — only the body is.

## Entity types that are not screens

The first thing the fix above surfaced: `POST
practice-management-gateway/subscribed-frameworks/query` answered **500**
for a user who had been granted *every* active menu.

`subscribed-frameworks` is an entity type the gateway serves, but it is
**not a screen** — there is no `menu_master` row for it anywhere in
`database/`. `permissionPolicy.IsAllowed(Roles(), "subscribed-frameworks",
"VIEW")` therefore cannot be satisfied by any grant: no role can hold a
permission for a menu that does not exist. Granting all menus does not
help, and `Organization › Role Menu Permissions` cannot offer it.

`admin@grac.local` never met it — `PM_ADMIN` is `*:*`.

There are two correct homes for such an entity type, and the choice
depends on how many screens read it:

| | Where | Used for |
| --- | --- | --- |
| One owning screen | `PermissionArea()` in the gateway | `release-statements`, `custom-release`, `subscription-owner` → `organization-controls`; `assurance-calendar-events` → `assurance-calendar` |
| Read by several screens | `LoginController.SupportingReads` | `menu-master`, `lookups`, `dashboard-summary`, `subscribed-frameworks` |

`subscribed-frameworks` is the second kind: it backs both the "All
subscribed frameworks" filter (`loadSubscribedFrameworks`) and the
Repository Subscriptions release grid (`loadReleaseSummary`), so it has
no single parent to alias to. It is now in `SupportingReads`, which the
two sign-in paths previously duplicated as three inline `.Append(...)`
calls — that duplication is why a fourth entry could go missing from one
of them, so both now `Concat` the same array.

Granting these to every signed-in user is bounded: each is in
`OrganizationScopedEntityTypes`, so `ValidateRequestedOrganization` still
holds the caller inside their own `AllowedOrganizationIds`. The grant is
"may ask", not "may see everything".

## The permission check runs twice, and the two tiers disagreed

Clicking a row on Organization Controls produced:

```
The practice API returned HTTP 403 from .../secure/query for entity [release-statements]
```

Every gateway call is authorised **twice** — once in the Web tier before
forwarding, once in the API before executing. That is deliberate: the API
is reachable independently of the Web tier, so it cannot trust a caller's
say-so. But the two were not asking the same question.

* Web: `permissionPolicy.IsAllowed(Roles(), PermissionArea(entityType), action)` — mapped `release-statements` → `organization-controls` and passed.
* API `secure/query`: `permissionPolicy.IsAllowed(principal.Roles, request.EntityType, action)` — asked for `release-statements:VIEW`, a permission no role can hold, and answered 403.

`secure/manage` had its own private copy of the mapping
(`ApiPermissionArea`) so saves worked; `secure/query` never called it. The
copy had also already drifted — `assurance-calendar-events` was added to
the gateway's version and never to the API's.

**Fixed by removing the duplication rather than adding a third copy.**
`Web/Security/PermissionAreaMap.cs` now holds the mapping and is
**linked** into `PracticeManagement.Api.csproj` — the same arrangement
`PasswordHasher` already uses, one source file compiled into both
assemblies:

```xml
<Compile Include="..\PracticeManagement.Web\Security\PermissionAreaMap.cs"
         Link="Security\PermissionAreaMap.cs" />
```

`PracticeManagementGatewayController.PermissionArea`,
`PracticeRepositoryController.ApiPermissionArea` and the `secure/query`
check are now all one-line calls to `PermissionAreaMap.For`. The API's
403 body also names the resolved area and the action instead of saying
"this area", and logs the roles it was given.

### Adding a new entity type

Three questions, in order:

1. Is it a screen? → seed a `menu_master` row. Nothing else needed.
2. Is it a helper with one owning screen? → add it to `PermissionAreaMap`.
3. Is it a helper read by several screens? → add it to `LoginController.SupportingReads`.

Skip all three and it works for `admin@grac.local` and fails for
everybody else — which is exactly how these three defects survived.

### Finding the rest

Diff the gateway's entity types against the seeded menu keys:

```sql
SELECT menu_key, menu_name, status FROM grac_practice.menu_master ORDER BY menu_key;
```

against `OrganizationScopedEntityTypes` in
`PracticeManagementGatewayController.cs`. Anything in the second list
that is neither in the first nor mapped by `PermissionArea()` is the next
500 waiting to happen.

At the time of writing that leaves `user-assignments` and
`owner-mappings` — both are full screens in `practice.js` (form
definitions, row actions) with **no `menu_master` row at all**, so they
are unreachable for any database user and invisible in the sidebar,
which is built from `menu_master`. Whether they should be seeded as
menus or removed is a product decision, so this change does not touch
them.

## Finding which grant is missing

`database/_diag_user_permissions.sql` — set `@login_id` (and optionally
`@menu_key`) and run it. It reports, in order: the identity, every role
the permission loader unions over, a per-menu verdict (`NONE — no
permission row`, `NONE — can_view = 0`, `menu_master row is not Active`,
`VIEW granted`), the organisations the **gateway** will accept, and the
`screen.*` feature flags for the home organisation.

Its four sections map onto the four independent things that can refuse a
screen: no role, no menu grant, no `user_organization_map` row, feature
flag off.

## Verification

Section 7 of the forward script reports:

* the accounts as the sign-in query sees them (a row must appear, status
  Active, record status Active, `password_hash_state = 'present'`);
* menu coverage — `Granted` must equal `ActiveMenus`;
* organisation coverage — `Orgs` must equal `ActiveOrgs`;
* the role assignment present in both places.

When a sign-in still fails, `database/_diag_user_login.sql` separates the
six causes that all render as "Invalid user ID/email or password".

## Rollback

`220_grac_admin_users_rollback.sql` matches on `entered_by = 'seed-220'`,
the stamp the forward script puts on every row it writes — an account
someone later re-saved through the Users screen carries that person's id
and is left alone. Employee rows that other tables reference cannot be
deleted (FK 547); the script catches that and deactivates them instead,
which is enough to stop sign-in since authentication requires
`status = 'Active'`.

It deliberately does **not** undo the
`pm_grant_organization_default_access` call. Those rows carry the same
stamp, but removing them would strip menus and screens from organisation
admins unrelated to these three users. Use 217's rollback if that is
genuinely intended.
