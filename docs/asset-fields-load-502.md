# Asset field dictionary, taxonomy and form templates loaded from the mapping workbook (502)

**Request:** load `AssetFields_Mapping_v1.0.xlsx` into the asset tables — delete what is there
first; the field-dictionary sheet into the field dictionary with its identity reset; the
`Asset Types` sheet's category / subcategory / asset type into their masters; and its
`required_display_labels` / `conditional_display_labels` / `system_managed_display_labels`
columns mapped as asset form templates against each category, subcategory and asset type.
Any form templates an organization already has may be deleted.

**Script:** `database/502_asset_fields_taxonomy_templates_load.sql` (+ `_rollback.sql`).
A **data load**, not a schema change: it creates, alters and drops nothing. Every table and
function it touches already exists (420 dictionary + templates, 239/002 taxonomy, 035 state
machine).

## What the workbook holds, and what was checked before the script was written

| Sheet | Rows | Goes to |
|---|---|---|
| `Sheet1` | 270 field definitions | `asset_field_definition` |
| `Asset Types` | 318 rows — 11 categories, 52 subcategories | the three taxonomy masters, and `asset_form_template(+ _section, _field)` |
| `Mapping Rules` | notes | not loaded |

Verified against the workbook first, so the load cannot drop anything silently:

- 270 `display_label` values, **all unique** → the label-to-field join is unambiguous.
- `field_definition_id` is **contiguous 1–270**, every `status_code` ACTIVE, every `is_custom` 0.
- 318 `(category, subcategory, asset type)` triples with **no duplicates**, and all 318 asset
  type names are **globally unique**, so a code generated from the name is safe as the table's
  UNIQUE key.
- **All 47,249** label references in the three label columns resolve to a dictionary label.
  **Zero** unmatched.
- No label appears under two kinds for the same asset type → `UNIQUE (template_id,
  field_definition_id)` cannot be violated.
- All 29 `data_type_code` values are exactly the 29 that 420 seeds; `field_group_id` 1–14
  matches 420's 14 groups in its seed order, confirmed field by field (group 8 is the
  biomedical fields, 9 the vehicle fields, and so on).
- Generated codes: 11 + 52 + 318, all distinct, within the 60 / 80 / 80 character limits, and
  **no collision** with the five codes the 240 seed uses.
- Every value is ASCII and inside its column's length.

The 318 asset types share only **34 distinct label sets**, so the workbook travels in the
script as 34 profiles (5,050 already-split `(profile, label, kind)` rows) plus a 318-row
asset-type-to-profile map — not 47,249 literal rows. The file is 348 KB.

## The four decisions behind it

| | Chosen |
|---|---|
| Which organizations | **Every ACTIVE organization.** `@organization_id` at the top of the script narrows it to one. |
| Template status | **ACTIVE**, version 1 (`is_active_version = 1`). `@template_status = N'DRAFT'` instead if the designer should own them first. |
| Field dictionary | Delete + identity reset, but **abort when `asset_field_value` has rows** — that table is registered asset data and the cascade behind re-seeding the dictionary. `@force_delete_asset_values = 1` overrides and destroys those values. |
| Taxonomy | **Deactivate the old, insert the new.** Nothing is deleted. |

### Why the taxonomy is deactivated, not deleted
The workbook's 11 categories replace the 240 seed's five (TECHNOLOGY, INFORMATION_DATA,
PHYSICAL_OPERATIONAL, FACILITIES_UTILITY, VEHICLES) outright. Those ids are referenced by
`organization_dependency_asset`, the event scope mapping (123/127/136) and the technology /
firmware / OS catalogs (425/426/427). `is_active = 0` takes the old values out of every picker
while leaving all of those rows valid; a `DELETE` would either fail on a foreign key or orphan
real asset records. The masters are then MERGEd on their codes, so a re-run updates instead of
duplicating.

## What the templates come out as

Per organization: **318 templates, 3,935 sections** (3,617 group sections + one AUDIT_HISTORY
each), **47,249 template fields** — 11,349 mandatory and 5,562 read-only.

- One template per organization per asset type, `version_no` 1, status as chosen,
  `template_name` = the asset type name.
- **Sections** are one per dictionary group that actually has a field in that template, keyed
  by `group_code` and labelled with `group_name`, plus `AUDIT_HISTORY` exactly as
  `sp_asset_form_template_create` adds it. A single GENERAL tab holding ~150 fields, which is
  what that procedure creates, would be unusable at this size; the 14 BRD groups are what the
  Form Designer's sections are for (5.2.5).
- **Fields** take their flags from the column the label came from:

| Column | is_visible | is_mandatory | is_read_only |
|---|---|---|---|
| `required_display_labels` | 1 | 1 | 0 |
| `conditional_display_labels` | 1 | 0 | 0 |
| `system_managed_display_labels` | 1 | 0 | 1 |

  plus 420's own rule — a field whose data type is not user-entered is read-only whichever
  column it came from.

- `display_order` comes from the dictionary, so a section keeps the BRD's own field order.

### The one override, and why
420 marks ten fields `is_system_mandatory` (the BRD 5.1.17 baseline) and states that a
template must carry them **visible and mandatory** and cannot weaken them (5.2.1 / 5.2.21);
`sp_asset_form_template_readiness` checks it. Eight of the ten are in the workbook's required
column. The other two — **Asset ID** (data type `AUTO`) and **Asset status** (storage
`SYSTEM`) — are in its system-managed column, which is correct in itself: the application
fills them. Taken literally, **all 318** templates would fail readiness.

So `is_mandatory` is forced on for any `is_system_mandatory` field. Those two then come out
mandatory **and** read-only — which is exactly what `sp_asset_form_template_create` produces
for them, because their data types are not user-entered. Nothing else in the workbook is
overridden. After the override, 0 templates fail the baseline.

## Safety

Guards run **before** anything is written, so a failure changes nothing:
required tables and the 420 seed present; the 14 groups present; the chosen template status in
`entity_status_master`; `@organization_id` real; at least one Active organization matched;
every staged `group_code` and `data_type_code` live; every referenced label in the dictionary;
and — read from `sys.foreign_keys` rather than assumed — **no other table referencing
`asset_field_definition`** beyond the four the script clears. A new dependant added by a later
migration is named in the abort message instead of surfacing as a foreign-key error mid-load.

The load itself is **one transaction** with `SET XACT_ABORT ON`: all of it lands or none does.
`entity_state_transition_log` is deliberately not touched — it is the framework's immutable
history, and `template_id` is an IDENTITY that keeps climbing, so old entries can never be
confused with the new ones. Each new template gets a transition log row (NULL → ACTIVE, reason
`BULK_LOAD`; the framework allows a NULL `from_status_id` and a NULL actor for a system actor)
and a `practice_audit_trace` row.

Every row the script writes carries `entered_by = 'load-502'`, which is what the rollback keys
on.

## No API or UI change
Nothing in the Api or Web tier is affected. The asset config screens read these tables through
the existing `sp_asset_field_*` / `sp_asset_form_template_*` procedures, and the Api and Web
layers hold no hardcoded category, subcategory or asset type codes (checked). The only visible
change is that the pickers now offer the workbook's taxonomy and each asset type opens with a
populated, active form template.

## Running it
1. Open the script, set the switches in section 0 if the defaults are not wanted.
2. Run it against the target database. Read the `PRINT` lines and then the verification block.
   Expected: `field_definitions` 270, `first_id` 1, `last_id` 270, `active_categories` 11,
   `active_subcategories` 52, `active_asset_types` 318, and 318 templates per organization.
   The three correctness checks at the end — asset types with no template, templates whose
   field count differs from the workbook, system-mandatory fields missing from a template —
   must all be **0**.
3. If it aborts on `asset_field_value`, that database has registered asset data. Decide
   deliberately before setting `@force_delete_asset_values = 1`.

## Verification done here
No dotnet or sqlcmd on this machine, so the script was swept statically and its result
predicted arithmetically:
- ASCII-only; no unterminated string literal; parentheses 5,884/5,884; `BEGIN` equals `END`
  minus `CASE` (11/11); one `BEGIN TRAN` and one `COMMIT`; `IDENTITY_INSERT` paired on/off;
  every `INSERT ... VALUES` chunk 900 rows (the T-SQL limit is 1,000).
- Staged row counts read back out of the written file: 270 / 11 / 52 / 318 / 5,050 — every
  workbook row present, none malformed.
- The joins the script performs were simulated against the workbook in full, which is where
  the expected 318 / 3,935 / 47,249 / 11,349 / 5,562 numbers in the verification block come
  from, and which is what surfaced the Asset ID / Asset status conflict above.

## Rollback
`502_asset_fields_taxonomy_templates_load_rollback.sql` removes the templates, deletes the
taxonomy rows 502 added where nothing references them (deactivating the rest rather than
failing on a foreign key), re-activates the pre-502 taxonomy, and deletes the 270 field
definitions 502 inserted.

It **cannot** restore the dictionary 502 replaced — re-run
`database/420_asset_form_templates.sql` afterwards, whose dictionary seed is insert-only on
`field_key` and rebuilds 420's 270 definitions. Form templates that existed before 502 are
gone for good: 502 deleted them, as asked, and no copy was kept.

## Fixes after the first two runs

### Run 1 — Msg 1046, "Subqueries are not allowed in this context"
Four `PRINT CONCAT(...)` statements embedded `(SELECT COUNT(*) ...)`. `PRINT` takes a scalar
expression and rejects a subquery, and because the load is a single batch this was a **compile**
failure: not one statement executed, so nothing changed. Each count now goes into a variable
(`@c_fields`, `@c_cats`, `@c_subs`, `@c_types`, `@c_profiles`, `@c_orgs`) and only variables
reach `PRINT`.

### Run 2 — Msg 547, `fk_pm_org_asset_template`
`DELETE FROM asset_form_template` hit a foreign key I had not looked for:
`organization_dependency_asset.template_id` (added by **428**) records the form template version
an asset was registered with. With `SET XACT_ABORT ON` the transaction rolled back, so again
nothing persisted.

The miss was a gap in my own pre-flight: I wrote a `sys.foreign_keys` sweep for
`asset_field_definition` and did not apply the same check to the four template tables. Fixed in
two parts:

1. **The sweep now covers all four template tables**, excluding the known referrers (the
   template's own children, its self-reference, and `organization_dependency_asset`). Any other
   referrer a future migration adds is named in an abort message before the transaction opens.
2. **The asset link is cleared first**, inside the transaction and counted:
   ```sql
   UPDATE grac_practice.organization_dependency_asset
      SET template_id = NULL, updated_by = @actor, updated_dt = @now
    WHERE template_id IS NOT NULL;
   ```
   The column is nullable and nothing else on the asset row is touched. Deleting every template
   — which is what was asked for — leaves that link nowhere to point, so clearing it is implied
   by the instruction rather than an extra decision; `@clear_asset_template_links = 0` makes the
   script abort instead, with the count, for anyone who wants to reconsider.

### Added at the same time: a pre-flight impact report and `@dry_run`
Before anything is written the script now prints the existing template count, how many assets
will have their template link cleared, and the volume it is about to write
(`@c_types * @c_orgs` templates, `47,249 * @c_orgs` field rows). `@dry_run = 1` runs every
guard, prints that report and stops without writing — worth doing first on a database with many
live organizations.

**UAT has 12 active organizations**, so a full run there is 3,816 templates, ~47,220 sections and
**~566,988** template field rows in one transaction. Narrow it with `@organization_id` if only
some organizations need the templates.

### Run 3 — Msg 2714, "There is already an object named '#field_def'"
The staging temp tables are created **before** the transaction, so the rolled-back run 2 left
them in place, and a temp table lives as long as the connection. Re-running in the same SSMS
window then failed on `CREATE TABLE #field_def`.

The script now drops all eight temp tables conditionally at the top of section 2
(`IF OBJECT_ID('tempdb..#field_def') IS NOT NULL DROP TABLE #field_def;` and so on), so it is
re-runnable in one session whichever guard or error ended the previous attempt. One cleanup
point rather than cleanup in every abort path.

### What the three failures have in common
Each was a different class, and only the first was reachable by inspecting text:

| Run | Class | Would a parser have caught it? |
|---|---|---|
| 1 | `PRINT` with a subquery | **Yes** — a parse error. This is why `sqlfluff parse --dialect tsql` is now run on every revision. |
| 2 | Unchecked foreign key (`fk_pm_org_asset_template`) | No. Semantic, needs the catalogue. Prevented from recurring by sweeping `sys.foreign_keys` for **every** table the script deletes from, not just one. |
| 3 | Temp tables left by the previous run | No. An operator-script property: it has to be re-runnable in one session, which it now is. |

### Verification after the fixes
`sqlfluff parse --dialect tsql` on the skeleton (all statements, `VALUES` blocks trimmed):
**12,258-line parse tree, 0 unparsable segments**, exit 0; keyword counts identical to the full
file and all seven DELETE statements present. Static sweep: parens 5,902/5,902, `BEGIN` = `END`
− `CASE` (14/14), one TRAN / one COMMIT, 8 `CREATE TABLE #` with no name created twice, ASCII
only, staged rows 270 / 11 / 52 / 318 / 5,050 intact.
