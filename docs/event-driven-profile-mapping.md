# Event Profiles — attribute-based checklist applicability

**Migrations 329 (schema) / 330 (procs) / 331 (resolution) / 332 (menu) / 333 (optional converter) /
340–344 (custom obligations reach this flow, Checklists tab, View Mapped Profiles)**
**Screen key** `event-profiles` · **Feature flag** `screen.event-profiles` · **Menu** Organization → Event Profiles

---

## What changed, in one line

Event-driven obligations used to be mapped to **one organisation role**.
They can now be mapped to a **Profile** — a named population defined by any
combination of Location, Department and Role (and whatever else is seeded
later).

```
before   Role     -> Event Type -> Obligation
after    Profile  -> Event Type -> Obligation      (the role path still works)
```

## Why the role-only model had to go

`event_obligation_applicability` (migration 127) scopes a decision with
`scope_role_id`. That can express "System Administrator" and nothing else.
It cannot express either of the two populations the business actually
works with:

- **India – IT Operations** — Location India/Kerala **and** Department IT
  Operations **and** Role System Administrator or IT Manager.
- **All Finance Users** — Department Finance, every location, every role.

The first is inexpressible at all. The second needs one applicability row
per role in the organisation and silently goes wrong the moment a role is
added.

## What was NOT changed

Everything that worked before this change still works, unchanged:

- Role-scoped applicability rows still resolve. `sp_event_obligation_raise`
  consults role mappings and profile mappings, and takes the union.
- The **Role Master** form still configures role-scoped mappings.
- **Asset Category Assurance** is untouched. Assets keep category scoping;
  `event_profile.subject_entity` reserves `ASSET` so profiles can cover them
  later without a second table.
- The custom-question half of the scope editor is untouched for roles and
  asset categories. It is **hidden** on the Profile screen — see *Known
  boundary* below.

---

## Data model

### The extensibility hinge

`grac_practice.event_profile_dimension_master` is a seeded master, one row
per attribute a profile may be scoped on. Every consumer — the value
picker, the matcher, the screen — reads it rather than hard-coding a
dimension list.

| Column | Purpose |
| --- | --- |
| `dimension_code` / `dimension_name` | identity and label |
| `subject_entity` | `EMPLOYEE` / `ASSET` — which kind of profile may use it |
| `value_kind` | `ID` (values come from a master) or `TEXT` (free text, no master) |
| `source_table` / `source_id_column` / `source_name_column` / `source_org_column` | where the picker reads options from |
| `employee_match_column` | the `organization_employee` column a picked value is matched against |
| `is_multi_valued` | 1 = matched through a function, not a column (Role) |
| `is_active` | off = invisible to picker, screen and matcher alike |

Seeded:

| Code | Active | Kind | Notes |
| --- | --- | --- | --- |
| `LOCATION` | yes | ID | `organization_location` → `organization_employee.location_id` |
| `DEPARTMENT` | yes | ID | `organization_department` → `department_id` |
| `ORG_ROLE` | yes | ID | multi-valued, via `fn_pm_employee_role_ids` (131) |
| `DESIGNATION` | **no** | TEXT | `organization_employee.designation` is free text with no master; the row exists so enabling it is an `UPDATE`, not a migration |
| `BUSINESS_FUNCTION` | **no** | ID | present to show the shape a further dimension takes |

### Tables

```
event_profile                     one row per named population, per organisation
  event_profile_criteria          one row per dimension the profile constrains
    event_profile_criteria_value  the OR-ed values of one criterion
```

`value_label` on each value is a **save-time snapshot**, following
`org_assurance_scope_condition_value` (073): the profile must still read
correctly, on screen and in an audit export, after the department it names
has been renamed or inactivated. The matcher uses the id, never the label.

### Changes to existing tables

| Table | Change |
| --- | --- |
| `event_obligation_applicability` | `+ profile_id`; `ck_pm_event_obl_app_scope` gains a third shape; `uq_pm_event_obl_app_natural` gains `profile_id` |
| `event_instance` | `+ scope_profile_id`, `+ scope_profile_name` (snapshot, same reasoning as 123's `scope_role_name`) |
| `event_mapping_resolution` | `+ profile_id`, `+ profile_name` |

The natural key **had** to be widened: two profiles deciding the same
obligation both carry NULL in the two scope columns, and SQL Server treats
NULLs as equal in a unique index, so they would have collided.

---

## Match semantics

```
OR  within a dimension        Role is System Administrator OR IT Manager
AND across dimensions         ...AND Department is IT Operations
absent dimension              unconstrained
match_all = 1                 unconstrained, recorded as a deliberate choice
```

Absent and `match_all` are treated **identically**. They mean the same
thing, and if they did not, the meaning of a profile would depend on which
screen created it. `match_all` exists so the UI can show "All" as a choice
the admin made rather than a field nobody filled in.

A profile whose every criterion is `match_all` matches every employee. That
is legitimate ("All Employees") and the preview count makes it obvious. A
profile with **no criteria rows at all** is rejected — it cannot be told
apart from a half-finished save.

### Two profiles matching one person

The obligation set served is the **union**. This is not a new rule: the
resolver already faced it for an employee holding three roles, and answered
with a `ROW_NUMBER` over `obligation_id` preferring `Included` over
`Excluded`, then the shortest `due_days`. Profile rows fall into the same
window, so a disagreement between two profiles — or between a profile and a
legacy role mapping — resolves the way this module has always resolved
conflicts.

**Consequence worth knowing:** because `Included` wins, an obligation
un-ticked on a profile still fires if a role mapping still includes it.
That is why migration 333 deactivates the role rows it converts.

### The matcher

```
vw_pm_event_profile_subject_attribute        one row per attribute a subject holds
fn_pm_event_profile_matches(org, entity, id) every Active profile the subject satisfies
```

Reads as: *no criterion of this profile is unsatisfied.*

The view is the **only** place that knows dimension codes map to employee
columns — T-SQL cannot read a column name out of a data row inside a
set-based predicate, and a function may not use dynamic SQL. Isolating that
in one view keeps `fn_pm_event_profile_matches` entirely generic.

### Adding a criterion later

1. Seed a row in `event_profile_dimension_master` (or set `is_active = 1`
   on `DESIGNATION` / `BUSINESS_FUNCTION`).
2. Add one `UNION ALL` arm to `vw_pm_event_profile_subject_attribute`
   (a `CREATE OR ALTER`, no schema change).

Nothing else. No table change, no save-proc change, no resolver change, no
screen change, no API change — `sp_event_profile_dimension_values` builds
its query from the master row, and the form renders its rows from the
dimension list.

---

## API

All under the existing workflow route, so the Web tier's catch-all
`WorkflowController` proxy forwards them with **no Web-tier registration**.
Browser paths are `/practice/api/workflow/...`.

### New — `EventProfileController`

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `scope/profiles` | Grid. `organizationId`, `subjectEntity`, `status`, `search`, `pageNumber`, `pageSize`. Returns `rows`, `totalRows`, `page`, `pageSize` |
| GET | `scope/profiles/dimensions` | Criterion dimensions for a subject entity |
| GET | `scope/profiles/dimension-values` | Pickable values for one dimension |
| GET | `scope/profiles/preview` | `matchedCount`, `totalActiveEmployees`, `sample` |
| GET | `scope/profiles/{id}` | One profile with its criteria tree |
| POST | `scope/profiles` | Create (`profileId` 0/absent) or update |
| POST | `scope/profiles/{id}/status` | Activate / Deactivate |
| POST | `scope/profiles/{id}/delete` | Delete — refused once the profile has been used |

Paging follows `docs/grid-and-pagination-standard.md`: the parameter is
**`pageNumber`**, not `page`.

Save payload:

```json
{
  "profileId": 0,
  "organizationId": 1,
  "profileName": "India - IT Operations",
  "description": "...",
  "subjectEntity": "EMPLOYEE",
  "status": "Active",
  "criteria": [
    { "dimensionCode": "LOCATION",   "matchAll": false,
      "values": [ { "valueId": 3, "valueLabel": "India" },
                  { "valueId": 7, "valueLabel": "Kerala" } ] },
    { "dimensionCode": "DEPARTMENT", "matchAll": false,
      "values": [ { "valueId": 11, "valueLabel": "IT Operations" } ] },
    { "dimensionCode": "ORG_ROLE",   "matchAll": true, "values": [] }
  ]
}
```

`profileCode` is optional — derived from the name and de-duplicated when
omitted.

### Extended — `EventScopeController`

`scopeDimension` now accepts a third value, `PROFILE`, with `profileId`
alongside `scopeRoleId` / `scopeAssetCategoryId`:

- `GET  scope/obligation-mappings` — `&scopeDimension=PROFILE&profileId=…`
- `POST scope/obligation-mappings` — `{ "scopeDimension": "PROFILE", "profileId": … }`
- `GET  scope/obligation-coverage`  — `&scopeDimension=PROFILE`

`scope/questions` deliberately does **not** accept `PROFILE` — see below.

Obligation mapping stays on these endpoints rather than moving under
`/profiles` so there is **one** write path to
`event_obligation_applicability`, not two.

---

## UI

| File | Role |
| --- | --- |
| `Views/Practice/Partials/event-profiles.cshtml` | markup only |
| `wwwroot/js/EventProfiles/event-profiles.js` | all behaviour |
| `wwwroot/js/scope-checklist-editor.js` | gains a `PROFILE` branch — not a second copy |
| `Models/PracticeScreen.cs` | screen registration |
| `Views/Practice/Manage.cshtml` | `workflowScreens` registration |

**Both registrations are required.** A `PracticeScreen.cs` entry alone does
not dispatch a route screen; without the `Manage.cshtml` line the request
falls through to the generic entity-grid layout and 400s against the API's
entity whitelist.

Markup and behaviour are split because Razor parses the at-sigil inside
`<script>` blocks in `.cshtml` files and compiles what follows as C# — a
build error `node --check` cannot catch.

### The preview count is not decoration

A profile that matches nobody looks exactly like a profile that works,
until an onboarding produces no checklist weeks later. The count is shown
while the criteria are being edited, and the View dialog repeats it.

---

## Custom obligations reach the event-driven flow (migrations 340–344)

### What changed, in one line

An organisation-authored ("Custom") obligation — either the practice-level
definition (`practice_obligation`, migration 307) or the instance-only kind
(`practice_instance_obligation` with no `obligation_id` and no
`source_practice_obligation_id`, migration 227) — can now be declared
event-driven, configured in Configure Checklists, and raised into a real
checklist item exactly like a catalog obligation. Before 340–344 it could do
none of those things: it was invisible to the whole event-driven engine.

### Root cause

`vw_pm_event_driven_obligation` (127) sourced obligations only from
`GRAC_New.requirement_obligation` — `event_obligation_applicability.
obligation_id` is a **soft** reference (no cross-database FK is possible),
and the view had no branch at all for a `practice_obligation` /
`practice_instance_obligation` row. A custom obligation could therefore
never get an applicability row, never appear in the Configure Checklists
panel, and never be seen by `sp_event_obligation_raise`. This was universal
across `ORG_ROLE` / `ASSET_CATEGORY` / `PROFILE` scope — not a
Profile-specific gap, and unrelated to the custom-**questions** boundary
documented below (that one is about a different engine entirely).

### The composite obligation identity

A catalog obligation has a `GRAC_New` id; a custom one never does (per
307's own three-way split, a custom row's `obligation_id` is always NULL).
So "which obligation is this" became **one of three** nullable columns,
never `obligation_id` alone:

| Column | Set when |
| --- | --- |
| `obligation_id` | catalog obligation (adopted, published) |
| `local_practice_obligation_id` | authored at practice level (307), covers every fanned-out instance the same way a catalog decision already does |
| `local_instance_obligation_id` | authored at instance level only (227), no practice-level parent — there is no broader identity available for this kind |

Every table and procedure that used to key on `obligation_id` alone now
carries all three columns, guarded by a CHECK that **exactly one** is set
(`event_obligation_applicability`, `event_instance_obligation`) or **at
most one** (`event_mapping_resolution`, which may legitimately name no
obligation at all — an early-exit trace row). Two idioms carry this
through every join, `GROUP BY`, `PARTITION BY` and `COUNT(DISTINCT)`:

```sql
-- matching two rows' identity (join / GROUP BY / PARTITION BY) --
-- NULL used deliberately, so two different kinds never match by accident
ISNULL(a.obligation_id,-1)                = ISNULL(b.obligation_id,-1)
AND ISNULL(a.local_practice_obligation_id,-1) = ISNULL(b.local_practice_obligation_id,-1)
AND ISNULL(a.local_instance_obligation_id,-1) = ISNULL(b.local_instance_obligation_id,-1)

-- COUNT(DISTINCT expr) takes one expression, not three columns --
COALESCE('C' + CAST(obligation_id AS NVARCHAR(20)),
         'P' + CAST(local_practice_obligation_id AS NVARCHAR(20)),
         'I' + CAST(local_instance_obligation_id AS NVARCHAR(20)))
```

The client (both `scope-checklist-editor.js` and `event-profiles.js`) uses
the same letter-prefixed string as a JS-side dictionary key
(`obligationKey`), so a catalog id, a practice-level id and an
instance-level id that happen to share a number are never confused there
either.

### The five migrations

| # | What |
| --- | --- |
| 340 | `practice_obligation.event_type_id` added (soft ref). `sp_resolve_local_obligation_save` (227) and `sp_practice_obligation_save` / `_fan_out` / `_list` (307) learn to accept, persist and fan out an event type — until this migration there was no way to even *declare* a locally-authored obligation as event-driven. |
| 341 | `event_obligation_applicability` schema: `obligation_id` relaxed to NULL, the two `local_*_obligation_id` FKs added, exactly-one CHECK, three filtered unique indexes replacing the single natural key. |
| 342 | `vw_pm_event_driven_obligation` (`CREATE OR ALTER`, same view name) gains two `UNION ALL` branches: practice-level custom rows (`event_type_id IS NOT NULL`, one row per definition, not per fanned-out copy) and instance-only custom rows (`obligation_id IS NULL AND source_practice_obligation_id IS NULL`). Both project `is_subscribed = 1` (a custom obligation is authored directly, so it is always in scope) and `trigger_mode = 'EventDriven'` literal. |
| 343 | `sp_event_obligation_mapping_list`, `sp_event_obligation_applicability_save`, `sp_event_obligation_coverage_list` and `sp_event_obligation_raise` (all four re-issued by 331 for the Profile branch — that is the body each is extended from) widened to the composite identity. Also: `event_instance_obligation` and `event_mapping_resolution` gain the same two local-identity columns, and `sp_event_obligation_raise`'s `@cand` table variable's primary key changes from `obligation_id` to a surrogate `cand_id` (a table variable's key column cannot hold NULL, and a custom obligation's `obligation_id` always is). |
| 344 | Two new pure-read procedures: `sp_event_driven_checklist_list` (the Checklists tab) and `sp_event_checklist_mapped_profiles_list` (View Mapped Profiles). |

### Configure Checklists shows custom obligations too

`scope-checklist-editor.js`'s obligation-mappings panel (the "Inherited
obligations" list inside Configure Checklists, for every scope dimension —
`ORG_ROLE`, `ASSET_CATEGORY`, `PROFILE`) now renders whatever
`sp_event_obligation_mapping_list` returns, catalog or custom alike, ticked
and staged and saved through the same `postObligation` call — the
`obligationId` sent to `POST scope/obligation-mappings` is simply `null`
for a custom row, with `localPracticeObligationId` or
`localInstanceObligationId` carrying the real identity instead. A small
**Custom** badge next to the obligation's label is the only visible
difference; ticking, un-ticking (with its required not-applicable reason),
staging and the Save bar all behave identically to a catalog obligation.
This directly satisfies the requirement that custom obligations be
"treated exactly like applicable catalog obligations" — there is no
parallel checklist mechanism, only the existing event-driven structure
extended to a second source of obligations.

### The Checklists tab

A second tab, **Profiles | Checklists**, on the same screen (`#epRoot` /
`#ecRoot`, both sharing the one `#epOrganization` selector in a toolbar
above them). One row per obligation+event "checklist" that **exists** —
catalog, practice-level custom or instance-only custom — not a per-scope
decision (that is what Configure Checklists shows, one profile/role/asset
category at a time). Columns:

| Column | Source | Notes |
| --- | --- | --- |
| Practice Instance | `PracticeInstanceDisplay` | **Means something different per row, on purpose** (confirmed design): a catalog or practice-level decision has no single instance behind it — it is practice/org-wide, same as a catalog obligation always was — so the cell shows the **Practice**. Only the instance-only custom kind has a genuine single `practice_instance` behind it, shown there instead. |
| Obligation Name | `ObligationName` | A **Custom** badge marks a practice-level or instance-only row. |
| Event | `EventTypeName` (+ `EventDomainName` for context) | Always the leaf name (`Onboarding` / `Offboarding`), so the two are never ambiguous — this is what requirement 2 asked for. |
| ⋮ | — | **View Mapped Profiles** |

**Fixed 2026-09-14 — blank Practice Instance cell.** `vw_pm_event_driven_obligation`
(342) `LEFT JOIN`s catalog rows (branch 1) to `grac_practice.practice` — a
join that has existed since the view's original 127 definition, unchanged
here — because an `organization_requirement` can be event-driven and
subscribed before the organisation's own `practice` row for it has been
created; `practice_name` is legitimately `NULL` for those rows. No other
screen that reads this view ever showed `practice_name` as more than an
optional secondary caption (`scope-checklist-editor.js` shows
`practiceCode` under the obligation label, nothing if absent), so the gap
was invisible until this tab made `PracticeInstanceDisplay` a mandatory
primary cell. `sp_event_driven_checklist_list` (344) now falls back one
step further — `COALESCE(pi.instance_name, p.practice_name,
p.requirement_name, N'(Practice not yet created)')` — to the owning
Requirement (always present; it is branch 1's own `FROM` table) before a
literal placeholder, so the column can never render blank.
`PracticeCode`'s secondary caption gets the same `requirement_code`
fallback. Search and sort were extended to match. This is a SQL-only fix;
no API or UI changes were needed since both already render whatever
`PracticeInstanceDisplay` contains.

### View Mapped Profiles

The 3-dot row action reads real `event_obligation_applicability` rows —
`scope_dimension = 'PROFILE'`, `status = 'Active'`, `is_applicable = 1` —
joined to `event_profile`, **never** a hardcoded or UI-only list. An
Excluded profile decision is deliberately not shown: the dialog answers
"which profiles **will receive** this checklist", and a profile that was
explicitly excluded will not. Reuses the `#epViewDialog` show/hide pattern
(its own dialog, `#ecMappedDialog`) rather than a new modal mechanism, and
shows Profile Name, Description, Criteria summary and Status — the same
criteria-summary sub-query `sp_event_profile_list` (330) uses, copied
verbatim so a profile's criteria read identically on both screens.

### API

Both new reads sit on the existing `EventScopeController`, under
`/scope/`, so the Web tier's catch-all proxy reaches them with no routing
change:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `scope/checklists` | The Checklists tab. `organizationId`, optional `eventTypeId`, `search`, `pageNumber`, `pageSize`. Returns `rows`, `totalRows`, `page`, `pageSize`. |
| GET | `scope/checklist-mapped-profiles` | View Mapped Profiles. `organizationId`, `eventTypeId`, and **exactly one** of `obligationId` / `localPracticeObligationId` / `localInstanceObligationId`. |

`POST scope/obligation-mappings` and the `EventObligationMappingRow` /
`EventObligationApplicabilitySaveRequest` DTOs are extended, not replaced:
`ObligationId` is now nullable, and `LocalPracticeObligationId` /
`LocalInstanceObligationId` / `ObligationKind` (`"Catalog"` /
`"PracticeLevel"` / `"InstanceOnly"`) travel alongside it.

### UI files touched

| File | Change |
| --- | --- |
| `Views/Practice/Partials/event-profiles.cshtml` | Profiles / Checklists tabs, the shared `#epOrganization` toolbar, the Checklists grid, the `#ecMappedDialog` modal |
| `wwwroot/js/EventProfiles/event-profiles.js` | tab switching, `loadChecklists` / `renderChecklistRows`, `openMappedProfiles`, a shared `showActionMenu` (both row-menus now use it) |
| `wwwroot/js/scope-checklist-editor.js` | the obligation-mappings panel keys on the composite identity (`obligationKey`) instead of `obligationId` alone, so custom obligations stage, save and re-render correctly |

No new screen registration was needed — the Checklists tab lives inside
the existing `event-profiles` screen key.

### Run order for 340–344

```
340_custom_obligation_event_type.sql
341_event_obligation_applicability_local_identity.sql
342_event_driven_obligation_view_local_kinds.sql
343_event_obligation_procs_local_identity.sql
344_event_driven_checklist_and_mapped_profiles.sql
```

Requires 127, 227, 307, 329–331 already applied. Rollback is the reverse,
**344 → 343 → 342 → 341 → 340**; 343's rollback refuses while any row uses
a local identity (the same refuse-and-report style as every other
migration in this set), and re-running 331 restores the four procedures'
pre-343 bodies.

---

## Known boundary — custom questions

The Profile screen shows the **inherited obligations** half of the scope
editor. The "your own checklists" half is hidden. (This is a different
engine from — and unrelated to — the custom **obligations** gap fixed by
340–344 above: "questions" are `grac_practice.checklist` rows raised
through the checklist path (124); "obligations" are what 340–344 wire in.)

Custom questions are stored as `grac_practice.checklist` rows keyed by
`scope_role_id` / `scope_asset_category_id` and served through the
**checklist** raise path (`sp_event_instance_raise_scoped`, migration 124),
which is a different engine from the obligation path profiles extend.
Supporting them per profile means:

1. `profile_id` on `checklist` and `event_checklist_mapping`
2. a `PROFILE` branch in `sp_org_scope_question_list` / `_save` (136)
3. a `PROFILE` branch in `sp_event_instance_raise_scoped` (124)

That is a change to the checklist engine, not to this scoping layer, and it
was left out deliberately rather than shipped half-working. The panel is
hidden rather than disabled: a greyed-out Add box invites a bug report, an
absent one matches an endpoint that genuinely does not accept this scope.

---

## Migrating existing role mappings (333, optional)

Not run automatically. For each role that has applicability rows it:

1. creates a Profile `Role: <role name>` with a single `ORG_ROLE` criterion,
2. copies every decision to it, and
3. **deactivates the source role rows**.

Step 3 is the important one. Leaving both copies Active is a trap: after an
un-tick on the profile copy the role copy would still say `Included` and the
obligation would go on firing — the change would appear to save and do
nothing. Set `@DeactivateSource = 0` only for a read-only comparison.

Safe to re-run; a pair already decided on the profile is not overwritten.
The rollback re-activates the role rows **first**, so the organisation is
never left with neither copy active.

---

## Run order

```
329_event_profile_schema.sql
330_event_profile_procs.sql
331_event_profile_resolution_procs.sql
332_event_profile_menu_seed.sql
333_event_profile_convert_role_mappings.sql        (optional)
```

Rollback is the reverse: **333 → 332 → 331 → 330 → 329**. 331's rollback
restores the 137 / 128 / 130 / 131 bodies verbatim and must run before
330's, which drops the matcher those bodies no longer call. 329's rollback
refuses while any applicability row or event instance still references a
profile.

`274_menu_master_seed.sql` carries the `event-profiles` row and its parent
link. It is a MERGE-with-UPDATE snapshot and is authoritative — a menu
change made only in 332 is reverted on 274's next run.

## Verification

Each migration ends with a PASS/FAIL sanity report. The ones worth reading:

- **331** — `raise still honours role mappings` and `raise still honours
  asset-category mappings`. A FAIL there means the legacy paths were lost,
  which is the one regression this change must not cause.
- **332** — effective `fn_pm_feature_enabled` per organisation (0 renders
  "not yet enabled"), and active Location / Department / Role counts per
  organisation, so an empty criteria picker is visible immediately rather
  than reported as a bug.

## Troubleshooting — "event definition not found for organization" (335)

**Symptom.** Pressing **Raise Event** fails with

```
sp_event_instance_raise_scoped: event definition not found for organization.
```

(SQL error 67223, surfaced verbatim in the dialog's message strip.)

**This is not a Profile problem.** It happens before any profile, role or
checklist is considered, and it happened the same way under the role-only
model. It is worth documenting here because this is the document people
reach for when a raise does not produce checklists.

**Cause.** Raise Event never sends an event code. The wrappers default it:

| Action | Code the wrapper uses |
|---|---|
| Onboard | `PEOPLE_ONBOARDING` |
| Offboard | `PEOPLE_OFFBOARDING` |
| Commission | `ASSET_COMMISSIONING` |
| Decommission | `ASSET_DECOMMISSIONING` |

`sp_event_instance_raise_scoped` then resolves that code against
`grac_practice.event_definition` for the organization, `status = 'Active'`.
No row, no raise.

Those four rows come from **migration 126**, whose own header calls the
codes *"a CONTRACT with 124"* — they are not an organizational choice, they
are what the wrappers hard-code. Two things empty the table, and neither
has anything that puts the rows back:

1. **126 is a one-shot seed** over the organizations that existed *when it
   ran*, and nothing re-runs it — so every organization created since has
   none of the four rows. 126 predicted this exactly: *"an undocumented
   setup step that will be missed."* It was missed because it was never
   anybody's step to take.
2. **`192_practice_data_reset.sql` clears `event_definition`, deliberately.**
   Its header explains why — the table is organization-scoped and FKs to
   `workflow` / `workflow_stage`, both of which the reset clears, so
   keeping it would leave orphans and fail the workflow DELETE. That
   reasoning is sound; what was missing is the other half. Under
   `@Scope = 'CATALOGUE'` the organizations survive and their events do
   not, which leaves every org in exactly this state.

An `event_definition` table that is **empty** for organizations that
plainly predate the problem is cause 2. Rows for the older organizations
and none for the newer is cause 1.

**Diagnose.** `_diag_event_definition_missing.sql` — read-only. Section 2
gives one row per active organization × the four codes with a verdict of
`OK` / `MISSING` / `INACTIVE`. Section 3 catches an organization whose
`organization.status` is not exactly `N'Active'`, which both the seed and
the resolver skip.

**Fix.** `335_event_definition_ensure_baseline.sql`:

1. **`sp_event_definition_ensure_baseline`** — new. Creates 126's two
   entity types and four events for one organization, **insert-only**.
2. Both lifecycle wrappers call it before raising, so an organization
   added after 126 provisions itself on first use and the error cannot
   recur. Only when the caller did not pass `@event_code` — a custom code
   is the organization's own vocabulary, and inventing a definition for it
   would create configuration nobody asked for.
3. An unresolvable code now throws a message naming the organization, the
   code, whether it is *inactive* or *not defined*, and what to do —
   instead of 67223's bare sentence. The check lives in the wrapper so the
   280-line resolver is not re-issued to change one string.
4. The subject mutation and the raise are now **one transaction**.
   Previously the employee was already marked Active/onboarded (or
   Inactive/offboarded) by the time 67223 fired, because the `UPDATE` ran
   outside any transaction and the `THROW` happened in the callee — the
   screen said the save failed while the record said it had succeeded.
5. A one-time gap fill runs the ensure for every active organization.
6. **`192_practice_data_reset.sql` is amended in the same change**: it now
   calls the ensure for every *surviving* active organization after the
   clear, guarded with `IF OBJECT_ID(...) IS NULL` so 192 still runs
   against a database without 335 (there it prints what to run instead).
   On an `ALL` reset the organizations are cleared too, so the loop finds
   nothing and does nothing. Rows land with `entered_by = 'reset-192'`.

**Insert-only is deliberate.** 126's MERGE sets `status = 'Active'` on a
matched row. That is right for a seed and wrong for something that runs on
every raise: an organization that deliberately deactivated
`PEOPLE_OFFBOARDING` would have it switched back on by the next
offboarding, silently. 335 never touches a row that exists — a deactivated
event still refuses to raise, and now says the deactivation is the reason.

**Checklists and mappings are still not seeded**, for 126's reason: what
belongs on an onboarding checklist is the compliance team's decision. A
raise with no mapping succeeds with `raisedCount = 0`, which the dialog
already reports as a configuration gap rather than a failure — so *"no
obligation is mapped for this scope"* after applying 335 means the event
now resolves and the **Profile → Event Type → Checklist** mapping is what
is missing.

**No API or UI change.** `RaisePeopleLifecycleAsync` returns `ex.Message`,
the controller returns it as `error`, and the dialog already renders
`b.error`. The improved sentence reaches the screen unchanged.

Run order: 335 is independent of 329–333 and can be applied before or
after them. Rollback: `335_..._rollback.sql` restores 128's wrapper bodies
and drops the helper; the event rows it created are deliberately kept,
since they are what the restored wrappers resolve against.
