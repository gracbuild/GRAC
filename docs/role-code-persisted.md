# Role Master — Role Code is saved and shown (migration 465)

**Screen:** `roles` (Administration → Role Master; also reachable as a child
grid of Organization Setup / Organization Administration)
**Backend routing:** `PracticeRepositoryService.cs` — `entityType == "roles"`
now routes GET to `grac_practice.sp_org_role_repository_get` and SAVE to
`grac_practice.sp_org_role_repository_manage` (both 465), instead of the
monolith `pm_get_practice_repository` / `pm_manage_practice_repository`
(002, current body 404).
**Frontend:** unchanged — `practice.js` already posted `roleCode` and already
listed `RoleCode` as a grid column.

## The fault

Role Master → Add Role: the Role Code typed in was never stored, and the
field was blank on the grid and on the Edit form.

Two independent gaps, both in the monolith, both in the body 404 carries:

1. **SAVE.** The `@p_entity_type='roles'` branch reads `organizationId`,
   `roleName`, `description` and `status` out of `@p_payload`. It never reads
   `'$.roleCode'`, and `role_code` appears in neither its `INSERT` column
   list nor its `UPDATE SET` list. The posted code was silently dropped.
2. **READ.** The `'roles'` branch projects `Id`, `OrganizationId`,
   `Organization`, `RoleName`, `Description`, `StatusId`, `Status`,
   `TotalRows` — no `RoleCode`. So even a stored code could not have reached
   the grid, and because the Edit form seeds from this same branch
   (`WHERE @p_id=0 OR r.role_id=@p_id`), Edit showed it blank too.

Nothing was wrong in the browser or the Api: `practice.js` has always sent
`roleCode` (`text("roleCode", "Role Code")` in the `roles` schema) and has
always had `RoleCode` in the grid's column list.

This is the same pair of gaps migration **419** fixed for assets, recorded
there as: *"The monolith's projection never returned asset_subcategory_id /
asset_type_id, so the Edit form opened with both blank and Save wrote NULL
over them."*

### The column was never the problem

`organization_role.role_code NVARCHAR(60)` has existed since **027**, along
with a UNIQUE filtered index
`ux_pm_org_role_code ON (organization_id, role_code) WHERE role_code IS NOT
NULL AND role_code <> ''`. Migrations **034** and **217** populate
`role_code` for the roles they seed — so seeded roles do carry a code and
only screen-created roles lost it, which is what made the column look broken
rather than unused.

The Api had also already mapped SQL error **51150** to the `roleCode` field
(`PracticeRepositoryService.FieldForSqlError`) — for a duplicate-code `THROW`
that had never been written.

## Objects (465)

| Object | Role |
| --- | --- |
| `sp_org_role_save` | SAVE logic: the monolith's roles branch verbatim, plus `role_code` and the 51150 duplicate check |
| `sp_org_role_list` | The read/grid query: the monolith's roles branch verbatim, plus `RoleCode`, and `role_code` added to the search predicate |
| `sp_org_role_repository_manage` | Gateway shim: SAVE → `sp_org_role_save`; everything else (RETIRE, anything future) → the monolith |
| `sp_org_role_repository_get` | Gateway shim: unpacks the payload and calls `sp_org_role_list` |

Why a shim rather than re-issuing the monolith: see
`location-time-zone-and-address.md`, "Why a separate gateway shim, not the
monolith". Same reasoning, same shape — 134 for `users`/`teams`, 361 for
`locations`, 419 for assets, 465 for roles.

## Behaviour preserved

Deliberately identical to the monolith's own roles branch, so nothing moves
except the code field:

- the same `51140` / `51141` / `51142` validations, in the same order;
- `status` written from `'$.status'` as a string, with `record_status_id`
  resolved from `'$.statusId'` first and `'$.status'` second — the monolith's
  own `@payload_record_status_id` derivation, copied;
- RETIRE handed back to the monolith, so its generic organization-access
  check still runs;
- the same `practice_audit_trace` SAVE row, so the trace stays continuous
  across the boundary;
- the same `Success / Message / Id` result shape — Role Master's Add flow
  takes the new role id off that row and switches the open dialog to Edit so
  the menu-permission matrix can be written.

## New behaviour

- `role_code` is stored on insert and update.
- A duplicate code within the same organization throws **51150**, *"Role Code
  already exists for this organization."* — the number the Api already maps
  to the `roleCode` input. Without it the filtered unique index would surface
  as a raw 2601 with no field to attach the message to.
- A blank code is stored as **NULL, not `''`**, matching the index's own
  filter, so any number of roles may carry no code.
- `role_code` is searchable from the grid's search box. A column you can see
  but not search reads as broken.

## Deployment

`ResolveProcedureAsync` probes with `ShimExistsAsync` and falls back to the
monolith when the procedures are absent, so the script and the Api can be
deployed **in either order**. `ShimExistsAsync` caches per process, so if the
Api probed before the script ran, it picks the shims up on its next restart.

No schema change and no data migration. Roles created through the screen
before 465 have no code and have to be re-entered — the value was never
written anywhere, so there is nothing to recover it from. The script ends
with a per-organization count of roles still missing a code.

Rollback: `database/465_role_code_persisted_rollback.sql` drops the four
procedures; the Api falls back to the monolith on its next restart and Role
Code goes blank again. Stored codes are left untouched.
