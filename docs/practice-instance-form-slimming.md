# Practice Instance form slimming — developer notes

Removing from the Practice Instance edit form the inputs whose value is
owned somewhere else now. **Stage 1 of three — all three are now done.**

| Stage | What moved | Migration |
| --- | --- | --- |
| 1 | Frequency, implementation status and evidence types off the edit form | none (frontend only) |
| 2 | Profile (practice type, criticality, business function, owner), retire, dependency categories → Operationalize | **222** |
| 3 | Restore, retired-instance visibility, practice/requirement drill-down → Operationalize; **the screen itself retired** | **287**, **288** |

**Frontend:** `Web/wwwroot/js/practice.js` (`schemaFor`, `entitySchema`,
`collectEvidence`)
**No database change.** See [Why no migration](#why-no-migration).
**Depends on:** `139` (Configure), `140`/`141` (Resolve workspace),
`145` (`vw_pm_practice_default_frequency`), `043` (implementation status)

---

## The duplication

The Practice Instance form captured sixteen fields. Four of them now
have a real owner elsewhere, and typing them again here only produced a
second answer that could disagree with the first:

| Field | Who owns it now |
| --- | --- |
| Execution Frequency | Migration **145** derives it from the parent practice's obligations (`vw_pm_practice_default_frequency`); Resolve records the real per-obligation cadence in `practice_instance_obligation` |
| Assurance Frequency | Same |
| Implementation Status | The implementation task flow (migration **043**) |
| Evidence Types | Captured per obligation on the Resolve screen |

Migration 145's own header names the symptom this creates: *"every new
instance had to be opened on the Practice Instance form and filled in by
hand before anything downstream could use it."*

## What stage 1 changes

`schemaFor` gains a branch for `practice-instances` + `mode === "edit"`
that derives the edit schema from the single shared field list rather
than restating it — a field added to `schemas["practice-instances"]`
still reaches the edit form, and only the named exceptions differ:

```js
const practiceInstanceHiddenOnEdit  = new Set(["executionFrequencyId", "assuranceFrequencyId"]);
const practiceInstanceDroppedOnEdit = new Set(["implementationStatus", "evidenceTypeIds"]);
```

### Two treatments, on purpose

**Dropped** — `implementationStatus`, `evidenceTypeIds`. The save path
already tolerates their absence: `pm_manage_practice_repository`
`COALESCE`s `implementation_status` (and `implementation_status_id`) to
the stored value, and evidence rows are child records written by
separate calls that simply do not happen.

**Hidden, not dropped** — `executionFrequencyId`, `assuranceFrequencyId`.
The procedure will not tolerate their absence:

```sql
IF @instance_execution_frequency_id IS NULL THROW 51038,'Execution Frequency is required.',1;
IF @instance_assurance_frequency_id IS NULL THROW 51039,'Assurance Frequency is required.',1;
```

and its `UPDATE` assigns `execution_frequency_id`,
`assurance_frequency_id`, `frequency_id`, `frequency_type`,
`frequency_value` and `frequency_unit` **unconditionally** — those six
are the only columns in that statement not wrapped in `COALESCE`. An
absent key would therefore blank the cadence migration 145 derived.

Round-tripping the loaded value through a hidden input takes the control
off the screen while leaving the saved row byte-identical to today's.
`normalizeFrequency` still finds `data.executionFrequencyId` and derives
`frequencyValue` / `frequencyUnit` exactly as before.

### Add is unchanged

The branch is scoped to `mode === "edit"`, not "not add". Creating an
instance from this form still has to state a frequency: there is no
stored value to fall back on, and `THROW 51038` is the only thing
standing between an empty box and an instance with no cadence.

Migration 139's **Configure** remains the normal way to create instances
— it fills the code, name, owner, team dependency and (via 145) both
frequencies without anyone opening this form.

### View is unchanged

Also scoped away from `mode === "view"`. In view mode these are not
inputs, they are read-only facts about the instance; hiding them there
would remove information rather than remove data entry. The grid
(`PracticeScreen.cs`) shows `ExecutionFrequency`, `AssuranceFrequency`
and `ImplementationStatus` as columns for the same reason — the
obligation-derived values stay visible.

## The guard in collectEvidence

Dropping the `evidenceTypeIds` control exposed a latent defect worth
stating plainly, because it destroys data rather than failing loudly.

`collectEvidence` has two branches — the combo-check control, and a
per-row evidence grid. Neither can distinguish "the user cleared every
evidence row" from "this form does not mention evidence at all". With
the control gone and no `[data-evidence-row]` markup present, the row
branch finds nothing, so every id in `state.activeEvidence` lands in
`removedIds` and the save **retires the instance's entire evidence
configuration**.

```js
const hasEvidenceInput = Boolean(fieldsHost.querySelector("[name='evidenceTypeIds'], [data-evidence-row]"));
if (!hasEvidenceInput) return { rows: [], removedIds: [] };
```

A form with no evidence input at all now means "leave evidence alone".

`collectDependencies` has the same shape and the same latent flaw, but
`dependencyTypeIds` stays on the edit form in stage 1, so it is not
reachable yet. Stage 2 moves that control and must add the same guard.

## Why no migration

Stage 1 deliberately touches no stored procedure. `THROW 51038` / `51039`
and the unconditional frequency assignment stay exactly as they are, and
the hidden inputs keep feeding them. Relaxing them means editing
`dbo.pm_manage_practice_repository` — a single procedure of roughly two
thousand lines defined only in `002_practice_management_procedures.sql`.
Re-issuing it wholesale to change six assignments would freeze a copy
that then has to be kept in step with 002 forever.

The established alternative is the shim: migrations 133/134 peeled
`users` and `teams` out into
`grac_practice.sp_org_<entity>_repository_manage`, which
`PracticeRepositoryService.ResolveProcedureAsync` prefers when it exists
and falls back to the monolith when it does not. Peeling
`practice-instances` out the same way is the right vehicle for the
frequency change — and it belongs with stage 2, not on its own.

---

# Stage 2 — the rest of the instance moves to Resolve

**Migration:** `222_resolve_instance_profile.sql` / `222_..._rollback.sql`
**API:** `Api/Models/ResolveWorkspaceModels.cs`,
`Api/Services/ResolveWorkspaceService.cs`,
`Api/Controllers/ResolveWorkspaceController.cs`
**UI:** `Web/Views/Practice/Partials/resolve-workspace.cshtml`
**Web tier:** no change — `WorkflowController` is a catch-all proxy, so a
new `api/practice/workflow/resolve/...` route is reachable at
`/practice/api/workflow/resolve/...` with its session and organization
guards already applied.

## What blocked the page's removal, and what now unblocks it

| Blocker | Where it lives now |
| --- | --- |
| **Retire.** Migration 139: *"Retiring an instance stays an explicit act on the Practice Instances screen."* Configure is add-only and un-ticking a team does not retire its instance | `sp_resolve_instance_retire` → `POST /resolve/retire` → **Retire instance** in the workspace page actions |
| **Owner.** A team with no manager yields an ownerless instance, which `pm_get_practice_repository` treats as not assurance-eligible | `sp_resolve_instance_profile_save`, admin-only — see below |
| **Practice Type, Criticality, Business Function.** Column defaults are `'Manual'`, `'Medium'`, `'Active'`, so dropping the inputs without a new home makes every instance silently take the default | The same procedure → the **profile** box on the workspace header |
| **Dependency type.** Declaring a category was the last thing the form's Dependencies combo did; resolving each one already happened on Resolve | `sp_resolve_dependency_type_list` / `_save` → **Declared categories** inside the Dependencies panel |

## Owner change is admin-only

Every Resolve procedure scopes a non-admin caller to instances where
`primary_owner_id = @caller_employee_id` — `sp_resolve_instance_detail`
throws 52619 otherwise, and the workspace is reachable by URL, so that
check is the gate. An owner who reassigned their own instance would
therefore lose access to it the moment they saved, with no way back
short of an administrator.

So `@primary_owner_id` is honoured only when `@is_admin = 1`. A non-admin
who sends a different owner is **refused (52673), not ignored** — a
silently dropped change reads as a save that worked. The service repeats
the check before the round trip, and the workspace hides the control
entirely; `isAdmin` rides along on the detail response for that, the same
way the instance list already sends it.

## Null means "no opinion"

Every profile parameter `COALESCE`s to the stored value, the rule
`sp_org_user_save` follows for `force_password_change`. The screen sends
the whole profile, but a caller that sends one field must not blank the
other three.

The procedure also rewrites `primary_owner` and `department` — the
denormalised copies the list and the grid read — whenever the owner
changes. Leaving those behind is how one person ends up with two
different names on two screens.

## Undeclaring a category that has resolutions is refused

`sp_resolve_dependency_type_save` takes the **complete desired set** as a
JSON array, not a delta: the picker is a full-set control, so it does
carry the "these are now the only ones" intention that migration 142
warned a partial payload does not.

But a category holding active resolutions is not just a tick — it is rows
in `practice_dependency_resolution`. Those are kept and returned in a
second result set as `blocked`, and the screen disables their checkboxes
and shows the count, so the user never reaches the refusal. The objects
have to be removed on the dependency card first.

One consequence worth knowing when reading `saveCategories`: a disabled
checkbox is not in the DOM query, so the locked ids are read back from
the model and merged into the payload. Sending only the enabled ticks
would ask the server to undeclare every locked category, which it would
then refuse one by one.

Declaring and undeclaring commit in one transaction — it is one edit of
one set, and `XACT_ABORT` is on, so a failure rolls the whole picker back
rather than leaving half of it applied.

## Degrading when 222 is not applied

The app and the database deploy separately, so the workspace must not
break on a database that has not run 222. Two mechanisms:

* `ResolveWorkspaceService` reads the three new detail columns through
  `OptionalInt64` / `OptionalString`, which check `HasColumn` first —
  `reader["Missing"]` throws `IndexOutOfRangeException` and would take
  down the whole workspace header rather than one editor.
* `ResolveInstanceDetail.ProfileEditable` reports whether the column was
  **present**, and the profile box and Retire button hide unless it is
  true. The nullable values cannot answer this: `BusinessFunctionId` is
  null both when 222 is missing and when the instance simply has no
  business function. An editor whose Save can only fail is worse than no
  editor.

The dependency-category box degrades on its own: a non-OK response from
the list endpoint leaves `dependencyTypes` empty and the box hidden.

## The Practice Instances screen is still there

**No longer true — see [Stage 3](#stage-3--the-screen-goes) below.** It
was true through stage 2: everything up to that point was additive, so
nothing was lost while the new surface was exercised.

The entity is not going anywhere either: `practice_instance_id` is a
foreign key in roughly twenty tables — assurance, calendar, evidence,
tasks, the Resolve workspace. "Remove the page" only ever meant remove
the data-entry surface.

## Still outstanding after stage 2

**The frequency hidden fields from stage 1.** They exist because
`dbo.pm_manage_practice_repository` throws 51038 / 51039 on an absent
frequency and assigns the six frequency columns unconditionally. That
only matters while the Practice Instances edit form still posts to it —
when the screen goes, its practice-instances branch has no caller and the
problem goes with it. If the screen is kept, the fix is the
`sp_practice_instance_repository_manage` shim described in
[Why no migration](#why-no-migration), defaulting from
`vw_pm_practice_default_frequency` on create and `COALESCE`ing to the
stored value on edit.

**`collectDependencies` has the same latent flaw as `collectEvidence`.**
`dependencyTypeIds` is still on the Practice Instance edit form, so it is
not reachable — but whoever removes that control must add the same guard,
or the save will retire every declared category.

## Stage 2 verification

Open an instance from **Resolve** (`/Practice/Index/resolve` → a row):

* The header carries a **profile** box — Practice type, Criticality,
  Business function — under the frequency strip. **Owner** appears only
  for an admin session.
* Change Practice type, Save profile, reload: the header facts strip and
  the Practice Instances grid both show the new value.
* As a non-admin, confirm the Owner control is absent. Posting
  `primaryOwnerId` directly to `/practice/api/workflow/resolve/profile`
  must answer 400 with the "Only an administrator…" message.
* In **Dependencies**, open **Declared categories**: every active
  category is listed, the declared ones ticked, and any with resolved
  objects disabled with a count. Tick a new one, Save, and its card
  appears below.
* Un-tick a category that has resolved objects — it cannot be un-ticked;
  remove its objects on the card first, then it can.
* **Retire instance** in the page actions confirms, then returns to the
  Resolve list. The instance leaves the active list and its row on the
  Practice Instances grid reads Inactive. On an already-retired instance
  the button is hidden.
* On a database without 222: the profile box, the Retire button and the
  category picker are all absent, and everything else on the workspace
  works unchanged.

---

## Stage 1 verification

Open an existing instance in **Edit**:

* Execution Frequency, Assurance Frequency, Implementation Status and
  Evidence Types are absent from the dialog.
* Save with no other change, then re-open in **View** — all four still
  hold their previous values, and the grid columns are unchanged.
* The instance's evidence configuration is still intact (Resolve, or
  `SELECT * FROM grac_practice.practice_instance_evidence WHERE practice_instance_id = <id>`).

Then open **Add New Instance**: all four inputs are present and
required, exactly as before.

---

# Stage 3 — the screen goes

Migrations **287** (procedures) and **288** (the menu row).

## What stage 2 left blocking it

Two things, and both were found by reading the code rather than the
plan — the earlier assumption that stage 2 had finished the job was
wrong twice over.

**Retirement was a one-way door.** `sp_resolve_instance_retire` (222)
sets `status` to `Inactive` and nothing could set it back.
`sp_resolve_instance_list` carries `AND pi.status = N'Active'`, and that
procedure is what `Views/Practice/Partials/resolve.cshtml` fetches — so a
retired instance vanished from the only list that shows instances. The
Practice Instances grid could still find it through its status filter,
which is precisely why the screen could not go.

**Two row actions navigated into it.** Practices and Organization
Requirements both carry a *Practice Instances* action that drills in
filtered by `@practice_id` / `@organization_requirement_id`.
Operationalize's list took only organization, search and paging, so those
two menu items had nowhere else to point.

## What 287 adds

* `sp_resolve_instance_restore` — retire's inverse, guard for guard: same
  ownership test, same "already in that state" refusal, plus a refusal
  when the parent practice is itself inactive (52814), which would
  otherwise put an orphan back into circulation.
* `sp_resolve_instance_list` gains `@include_retired`, `@practice_id` and
  `@organization_requirement_id`. All three default to "no opinion", so
  every pre-287 caller behaves identically.
* Restore in the workspace *and* on the row menu; a **Show retired**
  toggle; retired rows rendered muted with a chip.

`organization_requirement_id` filters through `practice`, not
`practice_instance` — the column lives on the parent, the same join
002's `practice-instances` branch uses.

## What 290 adds — the grid can reach page two

287 gave the list drill-down filters. It did not give it a **pager**, and
that turned out to matter more than it looked.

`sp_resolve_instance_list` has paged since 141 (`OFFSET … FETCH NEXT`,
`@page_size` clamped to 200). `resolve.cshtml` had no pager, so it asked
for one big page:

```js
+ '&pageSize=200',
```

Both sides therefore stopped at 200. **An organisation with 201 practice
instances had one that no filter, sort or scroll would reveal** — and
since Operationalize is a work queue, an instance nobody can see is an
instance nobody actions. The grid could not simply be given a pager,
either, because the procedure returned no total: without one the UI
cannot draw a row range, and cannot tell a full last page from a page
with more behind it.

**Migration 290** adds `COUNT(*) OVER () AS TotalRows`, last in the
projection, matching every other paged procedure in the schema. Nothing
else in the procedure changes — same parameters, predicates, joins,
ordering and paging.

### API contract

`GET /practice/api/workflow/resolve/instances` already accepted
`pageNumber` and `pageSize`; the Web tier forwards the query string
verbatim through `WorkflowController`'s `{**path}` catch-all, so no Web
change was needed. The **response** gains three keys alongside the
existing ones:

```jsonc
{
  "data":      [ /* unchanged */ ],
  "isAdmin":   true,          // unchanged
  "totalRows": 137,           // NEW (290) - matches the filter, not the page
  "page":      2,             // NEW (290)
  "pageSize":  25             // NEW (290)
}
```

Additive on purpose: anything already reading `data` or `isAdmin` is
untouched.

### Degrading when the migration has not run

`ResolveWorkspaceService` locates `TotalRows` **by ordinal, once**,
rather than reading it by name per row. An API deployed ahead of its
migration would otherwise throw on every load and take the whole screen
down over a column that only drives a label. Absent, the total stays 0,
`setTotal` receives `undefined`, and pm-grid falls back to a `Page N`
label — the documented degrade path in
`docs/grid-and-pagination-standard.md`.

The UI reset rules are the standard ones: organisation, search and
**Show retired** all return to page 1; **Refresh** does not, because it
re-reads the page the user is on. The count badge now reports the total
the filter matched rather than the rows on screen — before paging those
were the same number, and afterwards "25 instances" on a 137-instance
organisation would simply be wrong.

## The owner-scoping change, stated plainly

`002`'s `practice-instances` branch has **no owner predicate** — it is
organisation-scoped only. `sp_resolve_instance_list` has one:

```sql
AND (@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id)
```

and `@is_admin` is stamped by `WorkflowController` from the session's
**data scope**: `GLOBAL` or `ORGANIZATION` → 1, `EMPLOYEE` → 0. It has
never meant "system administrator".

So after 288 an **employee-scoped** user no longer sees instances they do
not own. Everyone with organisation-wide scope is unaffected — they
already saw everything through Operationalize. The retired grid was
handing employee-scoped users a view their data scope does not grant, so
this closes an inconsistency rather than removing a capability. If a
particular employee-scoped role genuinely needs the organisation-wide
list, the fix is a permission, not restoring the screen.

## Hidden, not deleted

288 sets the menu row `Inactive`, following 279. Deleting it would
cascade into `organization_role_menu_permission` and destroy every
per-screen grant. Only `Active` passes the sidebar and permission
filters, so Inactive *is* "not shown" while the row, its `menu_id` and
its grants survive.

The route stays alive: `PracticeController.ShowArea` resolves screens
from `PracticeScreen.All`, not `menu_master`, so
`/Practice/Index/practice-instances` still opens. The registry entry is
therefore **kept on purpose** and re-described — deleting it would 404
every bookmark the day 288 ships.

**`274_menu_master_seed.sql` carries the same change.** It is a
MERGE-with-UPDATE snapshot that compares and overwrites `status`, so
without the matching edit its next run would set the row back to Active
and silently un-retire the screen. That line in 274 is the authority.

## Ordering

287 → rebuild both tiers → verify → 288. 288 refuses to run otherwise:
it aborts unless `sp_resolve_instance_restore` exists, unless
`sp_resolve_instance_list` has `@practice_id`, and unless the
Operationalize menu row is Active.

## Stage 3 verification

* **Practices → 3-dots → Practice Instances** opens Operationalize
  filtered to that practice, on that practice's organization, with a
  banner naming the filter and a *Show all instances* link. Same from
  **Organization Requirements**.
* Retire an instance from the Operationalize row menu; it disappears.
  Tick **Show retired**; it returns, muted, with a *Retired* chip and a
  *Restore instance* action.
* Restore it; it returns to the active list.
* As an employee-scoped user, confirm only your own instances appear —
  this is the behaviour change above, not a fault.
* After running 274 again, confirm `practice-instances` is still
  `Inactive`.

---

# Stage 4 — Retire and Restore ask why

**Migration:** `355_resolve_instance_retire_restore_reason.sql` /
`355_..._rollback.sql`
**API:** `Api/Models/ResolveWorkspaceModels.cs`,
`Api/Services/ResolveWorkspaceService.cs`
**UI:** `Web/wwwroot/js/grac-dialog.js` (new `gracUi.promptRequired`),
`Web/Views/Practice/Partials/resolve-workspace.cshtml`,
`Web/Views/Practice/Partials/resolve.cshtml`
**Depends on:** `222` (`sp_resolve_instance_retire`), `287`
(`sp_resolve_instance_restore`)

## What was missing

Both surfaces that can retire or restore an instance — the dedicated
buttons on the instance's own Operationalize page, and the 3-dot row
menu on the Operationalize list (Stage 3, above) — took nothing but a
click-through confirm. `sp_resolve_instance_retire` and `sp_resolve_
instance_restore` update `status` and `updated_by`/`updated_dt` and
stop there; nothing anywhere recorded *why* an instance was taken out
of service or brought back, and the next status change overwrites even
that much.

## The fix

Both procedures are re-issued with a new required `@remark
NVARCHAR(1000)` parameter — `THROW 52815` (retire) / `52816` (restore)
when it is `NULL` or blank, checked **after** every existing guard
(ownership, already-in-that-state, parent-practice-active), so a caller
who was never going to be allowed to act sees that refusal first, not a
confusing "reason required" for something they can't do anyway. Each
successful call now also inserts one row into a new table,
`practice_instance_status_history` — `action_code` / `from_status_code`
/ `to_status_code` / `remark` / actor / timestamp, the same shape this
schema already uses for `risk_register_history` (205) and `exception_
request_history` (161). Nothing reads this table yet; it exists so the
reason typed on the UI has somewhere durable to land, the way §19's
approval trail and the registration-note addendum in `docs/risk-centre.md`
do for their own screens.

On the UI side, the same "ask on the same page, before the click, not
as a follow-up popup" rule already applied to the Risk Centre's
registration note (see `docs/risk-centre.md`) applies here: the old
`window.gracUi.confirm(...)` at both call sites became `window.gracUi.
promptRequired(...)` — a new helper on the shared dialog module that
behaves exactly like `gracUi.prompt()` (resolves to the typed string,
or `null` on Cancel/Escape) except a blank submission re-asks instead of
resolving. Typing a reason and clicking Retire/Restore *is* the
confirmation now; there is no separate step. Both call sites forward the
typed value as `remark` in the POST body they already sent.

## Why the reason isn't a column on `practice_instance`

Retirement and restoration are events, not properties of the instance's
current state — an instance that has been retired and restored three
times has three reasons, not one. A single `retire_remark` column would
only ever hold the most recent, which is exactly the "next status
change overwrites the last one" problem this fix exists to close. A
history table is additive and keeps all of them.

## Why the reason is enforced in the procedure, not only the UI

The row menu (`resolve.cshtml`) and the workspace buttons
(`resolve-workspace.cshtml`) already share these two endpoints by
design — Stage 3's own comment: *"so the row menu and the workspace
cannot diverge in what they enforce."* A UI-only requirement would hold
for both of today's callers but not for a future one, and would not
stop a direct API call from skipping it. The procedure is the one point
every caller must pass through, so it is also the one place this rule
cannot be bypassed.

## Stage 4 verification

* Click **Retire instance** on the workspace page with the reason field
  left blank; the dialog re-asks rather than submitting.
* Retire with a reason typed; the instance leaves the active list, and
  `practice_instance_status_history` has a new `Retire` row carrying it.
* Retire the same instance from the Operationalize list's 3-dot menu
  instead; same required-reason behaviour, same endpoint.
* Tick **Show retired**, use the row menu's **Restore**; same
  required-reason prompt, a new `Restore` row is logged.
* Try to retire an instance you do not own (non-admin); the ownership
  refusal (52682) still fires before any reason is asked for.
* Try to restore an instance whose parent practice is inactive; the
  52814 refusal still fires before any reason is asked for.
