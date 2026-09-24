# Consolidated master data seed + the MSP tenant — developer notes

**Migrations:** `272_master_data_seed.sql`, `272_master_data_seed_rollback.sql`,
`273_msp_organization_setup.sql`, `273_msp_organization_setup_rollback.sql`,
`274_menu_master_seed.sql`, `274_menu_master_seed_rollback.sql`
**Depends on:** `001`/`002` (or `deployment/01`+`02`) for the schema and
`dbo.pm_manage_practice_repository`; `034` + `217` for
`pm_create_organization_admin`; `204` for `sp_risk_scoring_seed_default`;
the menu migration chain for `menu_master`.
**Backend / Frontend:** no API or UI change. These are data-only migrations —
nothing in `Api/` or `Web/` was touched, and no contract moved.

---

## Why 272 exists

`grac_practice` has **53** tables whose name ends in `_master`. Their rows were
spread across 21 files:

| Where | Masters seeded |
| --- | --- |
| `deployment/03_Insert_Master_Data.sql` | 17 |
| `026`, `028`, `035`, `037`, `040`, `041`, `048` | assurance status, schedule override, entity status, task type, origin type, feature flags, related entity type |
| `069`, `073`, `089`, `098`, `101`, `104` | the org-assurance lifecycle vocabularies |
| `148`, `158`, `174`, `166`, `178` | document masters, gap lifecycle, exception types, SLA process types |
| `204`, `216`, `240`, `244` | risk sources, threat/vulnerability, asset taxonomy, connection types |

Standing up a fresh database, or refilling one after
`192_practice_data_reset.sql` was run with the masters dropped, meant replaying
that whole chain in order. `272` is one script that fills every **global**
master.

It does **not** replace the owning migrations. They still own the DDL and remain
the source of truth for their rows; `272` is the consolidation of what those
rows finally are. When a module adds a master row, add it there **and** here.

### Insert-only, on purpose

Every block is a `MERGE ... WHEN NOT MATCHED BY TARGET THEN INSERT` on the
natural key. A row an operator renamed, reordered or deactivated survives
untouched. This is the same rule `217` follows, and it is what makes the script
safe to run against a live database.

The single deliberate `UPDATE` is the gap-transition deactivation in section H:
the nine actions `174` retired (`PlanResolution`, `SendBackToValidation`,
`SendBackToAnalysis`, `StartExecution`, `SendBackToPlanning`,
`SubmitForVerification`, `SendBackToExecution`, `Approve`, `Reopen`) are flipped
to the Inactive `record_status_id`. Without it a fresh database would show the
pre-collapse lifecycle. It is a no-op where `174` already ran.

### What 272 deliberately does not seed

| Not seeded | Why | Where it comes from instead |
| --- | --- | --- |
| `menu_master`, `organization_role_menu_permission` | The tree is the product of ~35 migrations that insert, rename, re-parent **and delete** menu rows. Its final state cannot be re-derived from the files without replaying that order, and a hand-written snapshot would silently regress the navigation. | **`274` (below)** — a snapshot read off the running database. Failing that, the menu chain (`022`, `042`, `050`, `051`, `052`, `056`, `058`–`063`, `068`, `071`–`106`, `113`, `125`, `135`, `138`, `149`–`155`, `163`, `171`, `180`, `203`, `251`), then `pm_grant_organization_default_access`. |
| `entity_type_master` (`066`) | `organization_id NOT NULL` — per-tenant despite the `_master` suffix. | Created per organisation through the Workflow Entity Types screen. |
| `risk_category_master`, `risk_likelihood_master`, `risk_impact_master`, `risk_matrix_cell` (`204`) | Org-scoped. | `sp_risk_scoring_seed_default @organization_id` — called by `273`. |
| `feature_flag` (per-org rows) | Org-scoped. | `pm_grant_organization_default_access` — called by `273` via `pm_create_organization_admin`. |
| `grac_practice.evidence_type_master` | Dead. `deployment/03` repointed `practice_instance_evidence.evidence_type_id` at `GRAC_New.evidence_type_master`. | Section L seeds the `GRAC_New` table; the `grac_practice` shell stays empty. |
| `security_role`, `security_permission`, `security_role_permission`, `rbac_rule`, `entity_state_transition_rule` | Global config, not masters. | `004`, `035`, `040`, `deployment/03`. |

### Guarding and verification

Every block is wrapped in an `OBJECT_ID` check, so a table whose owning
migration has not been applied is skipped with a `PRINT` rather than failing the
run. The verification section at the end prints an expected-vs-actual row count
per master; `Actual >= Expected` is `PASS` (extra operator rows are normal),
`TABLE MISSING` means the DDL migration has not run, `SHORT` means a block was
skipped.

### Rolling 272 back

`272_master_data_seed_rollback.sql` deletes only rows carrying
`entered_by = 'seed-272'`, children before parents, `record_status_master` last.
On a database that had already run the migration chain, the rollback is a no-op
because those rows carry their owning migration's `entered_by`. The section H
`UPDATE` cannot be undone from here — use
`174_gap_lifecycle_collapse_rollback.sql`.

---

## What 273 provisions

An empty **MSP** tenant — "Managed Service Provider", industry `IT Services`,
entity type `Other`, country `India`:

| Object | Rows |
| --- | --- |
| `organization` | 1 (`organization_code = 'MSP'`) |
| `organization_metadata_value` | the 11 Organization Setup attributes |
| `organization_business_function` | `IT`, `OPS`, `COMP`, `RISK` |
| `organization_division` | `MSP-SVC` Managed Services |
| `organization_department` | `IT`, `INFOSEC`, `SVCDEL`, `COMP`, `HR` |
| `organization_location` | Head Office (`HO`), NOC (`DC`), DR site (`DR`) |
| `organization_role` | `Admin` (from the proc) + Compliance Owner, Evidence Owner, Reviewer, Viewer |
| `organization_employee` | `msp.admin@grac.in` — the Organisation GRAC Admin |
| `organization_employee_role`, `organization_role_menu_permission`, `feature_flag` | via `pm_create_organization_admin` → `pm_grant_organization_default_access` |
| `user_organization_map` | the admin's home-organisation row |
| risk framework | 5 likelihood × 5 impact + 25 matrix cells + default categories |

### Nothing is hand-rolled that a proc already does

- The organisation and its attributes are saved through
  `dbo.pm_manage_practice_repository @p_entity_type = 'organization-setup'` —
  the exact path the Organization Setup screen uses. The metadata typing
  (`Lookup` / `Boolean` / `Json`), the subscription handling and the
  `record_status` wiring are the product's, not the script's.
  `$._security.isSystemAdmin = true` in the payload is how the proc is told the
  caller may create an organisation; `$.organization.id = 0` inserts, a real id
  updates, which is what makes a re-run harmless.
- The admin, the `Admin` role, the multi-role map, the menu grants and the
  screen flags come from `grac_practice.pm_create_organization_admin`.
- The risk framework comes from `grac_practice.sp_risk_scoring_seed_default`.

### The admin password

`@AdminPasswordHash` is PBKDF2-HMAC-SHA256, 210 000 iterations, 16-byte salt,
32-byte key, in the `iterations.saltBase64.hashBase64` form that
`Web/Security/PasswordHasher.cs` writes and verifies. The plaintext is
`Grac@123` — the same `UserProvisioning:DefaultPassword` the Web tier
provisions with. `pm_create_organization_admin` sets
`force_password_change = 1`, so the first sign-in must change it, and
`LoginController` rejects the default as the new password. No plaintext
password appears in the file. Change the hash if this deployment uses a
different default.

### Two things to know before running it

1. **Run the menu migrations first.** `pm_grant_organization_default_access`
   grants whatever `menu_master` holds at the time. Because `272` does not seed
   `menu_master`, running `273` against a database with an empty menu table
   gives MSP's Admin an empty menu. Re-running `273`, or `217`'s backfill, tops
   the grants up afterwards.
2. **Re-running `273` does not reset the password.** Section 4 is skipped when
   the admin employee already exists, because `pm_create_organization_admin`
   resets `password_hash` and `force_password_change` on an existing account by
   design (its "resend credentials" behaviour). To reset deliberately, run that
   `EXEC` by hand.

### Rolling 273 back

`273_msp_organization_setup_rollback.sql` removes MSP and everything under it,
in one transaction, children first. It has a safety gate: it counts rows in the
"real work" tables (subscriptions, controls, requirements, practices,
instances, tasks, gaps, exceptions, documents, risks, dependencies) for MSP and
**aborts** if any is non-empty. `@ForceWhenInUse = 1` overrides that — only with
a backup. A foreign key this script does not know about will fail the
transaction rather than leave a half-deleted organisation; that is the intended
behaviour.

---

## What 274 does

`272` left `menu_master` out because the tree cannot be re-derived from the
migration files. `274` closes that gap the only way that is honest: it carries a
**98-row snapshot exported from the running database** (`Menu.xlsx`, 2026-09-03)
and replays it.

**Authoritative, not insert-only.** Unlike `272`, `274` is a `MERGE` with
`UPDATE`: a menu row already in the target is brought in line with the snapshot
(name, url, `display_order`, icon, `module_type`, `status`, parent). Rows in the
target that are *not* in the sheet are left alone — nothing is deleted.

**Identity is never assumed.** `menu_id` is `IDENTITY`, so the ids in the export
mean nothing elsewhere. Everything resolves by `menu_key` in two passes:

1. upsert the 98 rows with `parent_menu_id` untouched,
2. wire the 68 `child_key -> parent_key` links, then re-`NULL` the 30 roots.

That shape makes row order irrelevant and the self-referencing FK safe.

**Status spelling is preserved as found** — the export carries `Active` (54),
`Inactive` (37) and `InActive` (7). Only `Active` passes the status filters in
the menu and permission code, so the two misspellings behave identically;
normalising them would be a change to live data this migration has no mandate to
make.

### Section 3 is a real permission change

Every **active** role of every in-scope organisation gets
`can_view / can_add / can_edit / can_delete / can_approve = 1` on every active
menu. Existing rows are **raised** to full rights (the `220` pattern), not just
topped up.

That includes the read-only roles: `Viewer` is seeded by `deployment/03` and
`273` with `can_view` only, and after this script it can add, edit, delete and
approve everywhere. Three switches at the top of section 3:

| Switch | Default | Meaning |
| --- | --- | --- |
| `@OrganizationId` | `NULL` | `NULL` = every active organisation |
| `@RolesScope` | `'ALL'` | `'ADMIN'` grants only `Admin` / `ORG_ADMIN` and leaves the read-only roles as they are |
| `@IncludeInactiveMenus` | `0` | active menus only, matching `217` |

### Amending the snapshot after a menu move

Because `274` applies the sheet with `UPDATE`, any later migration that moves a
menu row has to be written back into `274` as well — otherwise the next run of
`274` silently undoes it. `275` is the first case: `assurance-calendar`
("Calendar") moved from `nav-assurance` to `nav-oversight`, so `274` now carries
`module_type = 'Oversight'`, `display_order = 290` and the
`assurance-calendar -> nav-oversight` link instead of the exported values. Both
lines are commented in the script. Treat this as the rule for every future
placement change, not a one-off.

### Rolling 274 back

`274_menu_master_seed_rollback.sql` deletes what `274` **created**
(`entered_by = 'seed-274'`), detaching children first so the self-FK holds. Two
effects have no "before" recorded anywhere and are listed, not restored: menu
rows that already existed and were updated to the snapshot, and permission rows
that already existed and were raised to full rights. If either matters, restore
from the backup taken before `274`.

---

## Run order

```text
001 / 002        (or deployment/01 + 02)
... the migration chain ...
217              organization default access
272              consolidated master data seed
274              menu_master snapshot + full menu permissions
275              Calendar menu moved from Assurance to Oversight
276              Assurance renamed to Audit Management + menu regrouped
277              Audit -> question-set link table
278              Audit setup procedures (adoption + setup status)
279              One audit list -- Scope + Question Sets become tabs
273              MSP organization
```

`276` is documented in `docs/audit-management-module.md`. Like `275` it changes
no `menu_key`, so no permission row is orphaned; the container menus it adds are
granted only to roles that can already view the screens beneath them.

`275` is a pure re-parent of one row: no menu is created or deleted, `menu_id`
never changes, so no `organization_role_menu_permission` grant is touched. On a
fresh database it is redundant (`274` already places Calendar under Oversight)
and simply reports 0 rows changed.

`274` goes **before** `273` on a fresh database:
`pm_grant_organization_default_access` grants whatever `menu_master` holds at the
moment it runs, so MSP's Admin gets an empty menu otherwise. On a database where
`273` already ran, re-run `274` (or `273`) afterwards to top the grants up.

`272` is safe to run at any point after the schema exists; running it before the
per-module DDL migrations simply skips the blocks whose tables are missing, and
re-running it later fills them in.
