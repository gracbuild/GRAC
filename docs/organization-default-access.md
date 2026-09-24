# Organization default access provisioning — developer notes

**Migrations:** `217_organization_default_access.sql`, `217_organization_default_access_rollback.sql`
**Depends on:** `022` (menu_master + role permissions), `027` (role_code, multi-role map), `034` (`pm_create_organization_admin`), `041` (feature_flag)
**Backend:** `Api/Services/PracticeAuthenticationService.cs` (`LoadPermissionsAsync`), `Api/Services/FeatureFlagService.cs`, `Web/Controllers/PracticeManagementGatewayController.cs`
**Frontend:** `Web/wwwroot/js/practice.js` (`describeAccessProvisioning`)

---

## The bug this fixes

An organisation created through Organization Setup got:

- an `organization_role` row named `Admin` (scope `ORGANIZATION`),
- an `organization_employee` row for the Organisation GRAC Admin,
- **zero** `organization_role_menu_permission` rows,
- **zero** `feature_flag` rows.

Both gates read those tables:

| Gate | Source | Behaviour with no row |
| --- | --- | --- |
| Menu / screen permission | `organization_role_menu_permission` → `LoadPermissionsAsync` → session roles → `PermissionPolicy.IsAllowed` | `403 Forbid` — "you do not have permission" |
| Screen feature flag | `fn_pm_feature_enabled`: per-org row → `feature_flag_master.default_enabled` (0) → 0 | screen renders its "not available" banner |

Gap Center (`gaps`, `screen.gaps`), Task Center (`tasks`, `screen.tasks`) and
Exception Centre (`exception-centre`, no flag probe) were the visible
casualties because they were added *after* the last org was onboarded.
Their menu seeds — `042`, `050`, `163` — each granted only the
organisations that existed when the seed ran.

## The contract

```sql
EXEC grac_practice.pm_grant_organization_default_access
     @organization_id = <id or NULL>,   -- NULL = every active organisation
     @entered_by      = N'system',
     @menus_granted   = @m OUTPUT,
     @flags_enabled   = @f OUTPUT;
```

What it grants, for every **active** organisation in scope:

1. **Menus** — the org's Admin role (`role_name = 'Admin'` **or**
   `role_code = 'ORG_ADMIN'`) gets `can_view/add/edit/delete/approve = 1`
   on every **active** `menu_master` row it has no row for.
2. **Feature flags** — every active `feature_flag_master` row whose
   `feature_code` starts with `screen.` is inserted with `is_enabled = 1`
   for organisations that have no row for it.

Two properties worth remembering:

- **It returns no result set.** Counts come back through `OUTPUT`
  parameters. `pm_create_organization_admin` calls it inline, and an
  extra result set would shift the row
  `PracticeManagementGatewayController.ExtractProvisionResult` reads.
- **It is insert-only.** Existing rows are never updated. A
  `can_view = 0` grant or an `is_enabled = 0` flag is an operator
  decision and is left alone. This is a deliberate departure from the
  `042` / `050` / `163` seeds, which force every Admin bit to 1 — those
  touch one menu each, this one touches all of them, so the blast radius
  of an overwrite would be much larger.

## Call sites

| Caller | `@organization_id` | `@entered_by` |
| --- | --- | --- |
| `pm_create_organization_admin` step 3d | the new org | the signed-in operator |
| Section 3 of migration 217 (backfill) | `NULL` | `seed-217` |

The rollback deletes only rows stamped `seed-217`, so it removes the
backfill without stripping access from organisations that were
provisioned normally.

## API surface

`POST /practice/api/practice-management/organization-admin/provision-and-notify`
now returns two extra fields:

```json
{
  "success": true,
  "employeeId": 42,
  "alreadyExisted": false,
  "menusGranted": 58,
  "flagsEnabled": 41,
  "credentialsEmailed": true,
  "emailCorrelationId": "…",
  "emailFailureReason": null
}
```

Both are read defensively from the SP result (`?? 0`), so the Web tier
keeps working against a database where 217 has not been applied or has
been rolled back. `0 / 0` means nothing was missing — the UI stays quiet
in that case rather than reporting "0 permissions granted".

## Adding a new module

Migration 217 does **not** remove the need for a per-module menu seed.
Keep shipping the `042` / `050` / `163` pattern:

1. `MERGE` the row into `feature_flag_master` (default OFF, charter §7).
2. `MERGE` the row into `menu_master`.
3. Grant existing orgs' Admin roles on the new menu.
4. Enable the flag per-org for existing orgs.

Steps 3 and 4 cover the organisations that already exist. What you no
longer have to think about is organisations created *after* your
migration — `pm_grant_organization_default_access` picks the new menu and
flag up automatically because it reads `menu_master` and
`feature_flag_master` live.

## Verifying

The forward script ends with four checks:

- `pm_grant_organization_default_access created` → PASS
- `Active orgs missing gaps/tasks/exception-centre grants` → 0 / PASS
- `Active orgs with screen.gaps / screen.tasks resolved OFF` → 0 / PASS
  (REVIEW if an operator has deliberately switched one off)
- a per-organisation `GrantedMenus` count for eyeballing

Manual spot-check after onboarding a new org:

```sql
SELECT m.menu_key, p.can_view
FROM grac_practice.organization_role_menu_permission p
JOIN grac_practice.organization_role r ON r.role_id = p.role_id
JOIN grac_practice.menu_master m       ON m.menu_id = p.menu_id
WHERE r.organization_id = <new org id>
  AND m.menu_key IN (N'gaps', N'tasks', N'exception-centre');

SELECT grac_practice.fn_pm_feature_enabled(<new org id>, N'screen.gaps');
SELECT grac_practice.fn_pm_feature_enabled(<new org id>, N'screen.tasks');
```

## Forcing the three centres ON — `305`

**Migrations:** `305_enable_centres.sql`, `305_enable_centres_rollback.sql`

`pm_grant_organization_default_access` is **insert-only** by design: a
`feature_flag` row already sitting at `is_enabled = 0`, or a permission
row already sitting at `can_view = 0`, is an operator decision and is
left alone. So `217` fixes "no row at all" but never "row present and
switched off" — and a database restored from an older backup, or one
where a flag was toggled during testing, lands in exactly that state.

`305` is the explicit operator decision to the contrary, scoped to the
three centres only:

| Section | What it does |
| --- | --- |
| 1 | Ensures `screen.gaps`, `screen.tasks`, `screen.exception-centre` exist in `feature_flag_master` and are `is_active = 1`. `default_enabled` stays `0` — enabling is a per-org call. |
| 2 | `MERGE` on `feature_flag` — **raises** an existing `0` to `1`, inserts where absent. |
| 3 | Re-raises `menu_master.status` to `Active` for `gaps`, `tasks`, `exception-centre` and their parent `nav-oversight`. Never inserts — `274` owns the snapshot. |
| 4 | `MERGE` on `organization_role_menu_permission` — full rights on those four rows for `Admin` / `ORG_ADMIN` / `GRAC_ADMIN`, raising `can_view = 0` rows. |
| 5 | BEFORE/AFTER report + three PASS/FAIL checks. |

Scope switch at the top of each batch:

```sql
DECLARE @OrganizationId BIGINT = NULL;   -- NULL = all active orgs; <id> = one org
```

Change it in **every** batch that declares it (the forward script has two,
the rollback two) — a table variable and a local do not survive `GO`.

No API or UI change: both gates already read these tables at sign-in.
Which is also the gotcha — **sign out and back in** after running it, or
the session keeps the old permission set and the sidebar looks unchanged.

Rollback keys on `entered_by` / `updated_by = 'seed-305'`:

- rows `305` **created** (flags and grants alike) are deleted;
- `feature_flag` rows it only **raised** go back to `is_enabled = 0`;
- `organization_role_menu_permission` rows it only **raised** are
  *listed for review*, not reset — `305` tops up five flags at once and
  the pre-run combination is not recorded anywhere, so zeroing `can_view`
  would invent a state the row never had;
- `menu_master.status` is deliberately **not** reverted, because `Active`
  is what `274` declares for all four keys — switch a menu off with its
  own migration instead (the `288` / `289` pattern).

## Known limitation

Only the **Admin** role is granted. The other roles seeded by `022`
(Compliance Owner, Evidence Owner, Reviewer, Viewer) are created for
organisations onboarded before `034`; `pm_create_organization_admin`
creates only `Admin`. Non-admin roles are still configured through the
Role Menu Permission screen, which is the intended behaviour — least
privilege by default, with the org admin deciding who else sees what.
