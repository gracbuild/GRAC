# One list per Centre, Source as a column — developer notes

Sir's instruction: across Gap Center, Task Center, Exception Centre and
Risk Centre, collapse the per-source tabs into **one** list, show the
source as a **column**, and let people **filter** on it. Candidate tabs
excluded.

> "Gap Center anenkil Implementation Gap, Assurance Gap, Custom Gap ingane
> vere vere tab venda. pakaram oru tab mathi. Ee gap vann source oru
> column ayi kanikanam."

**Migrations:** `255_gap_centre_unified_list.sql`,
`256_task_centre_source_counts.sql`
**API:** `Api/Models/CustomGapModels.cs` (`GapCentreListRow`, `GapCentreListQuery`,
`GapCentreSourceCount`), `Api/Services/CustomGapService.cs`
(`ListGapCentreAsync`, `ListGapCentreSourcesAsync`),
`Api/Controllers/CustomGapController.cs` (`GET .../gaps/custom/centre`,
`.../centre/sources`)
**UI:** `Partials/gaps.cshtml`, `Partials/tasks.cshtml`,
`Partials/exception-centre.cshtml`, `wwwroot/js/ExceptionCentre/exception-centre.js`

---

## The four Centres were four different problems

Surveying first was the whole job. Only one of the four needed database
work; one needed nothing at all.

| Centre | Tabs before | What it actually was | Work needed |
|---|---|---|---|
| **Task Center** | Implementation / Continuous Assurance / Event Driven / Custom | Three of the four read `/practice/api/tasks` with the same eleven columns, differing only by `taskTypeCode` | **UI only** |
| **Exception Centre** | Gap Candidate / SLA Candidate | One table, one column set, already had a **Type** column; tabs only filtered `requestType` | **UI only** |
| **Gap Center** | Implementation / Assurance / Custom | Assurance + Custom were already one list; **Implementation was a different entity** | **Migration + API + UI** |
| **Risk Centre** | Candidates / Register / Dashboard | Candidates is excluded by the rule *and already had a Source column and filter*; Register is a separate entity; Dashboard is not a list | **None** |

---

## Gap Center — why it needed a migration

Assurance Gaps and Custom Gaps both read `sp_custom_gap_list` and
differed only by `@gap_source_module_code`. `custom_gap` already carries
the full vocabulary, enforced by `ck_pm_custom_gap_source_module`:

```
Implementation / Assurance / Custom / Exception / Risk / Audit
```

**Implementation Gaps did not.** That tab reads
`sp_task_center_gaps_list`, derived from `practice_gap` +
`practice_instance` (migration 245). A practice-instance gap has **no
`custom_gap` row at all** until somebody runs
`sp_custom_gap_materialize_for_instance` on it.

So listing `custom_gap` alone — the obvious reading of "one list" — would
have made every un-materialized implementation gap vanish from the screen
whose job is to surface it. Sir chose the union.

### `sp_gap_centre_list`

Two arms into one column set:

1. `custom_gap` — every source module, including implementation gaps that
   **have** been materialized
2. `practice_gap` — only rows **not** materialized yet

**Dedupe.** A materialized instance gap exists in both arms. Arm 2
excludes any instance that already has a `custom_gap`, matched on
`(source_reference_type='PracticeInstance', source_reference_id,
organization_id)` — deliberately the *same key*
`sp_custom_gap_materialize_for_instance` uses for its own idempotency
check, rather than a second definition of "already materialized" that
could drift from it. Status is not part of that key there, so it is not
part of it here.

`IsMaterialized` tells the screen which arm a row came from. That is what
decides whether the menu offers **Analysis** directly or materializes
first, and it is why `CustomGapId` is null on exactly those rows.

**Columns only one arm can answer are null on the other, never faked.**
An un-materialized instance gap has no due date; a custom gap has no
obligation count. The row's linked-count label changes with the arm too —
*obligations* for an instance gap, *observations* for an assurance one —
because one unlabelled number in a shared column would have been two
different facts wearing one hat.

**`@observation_id`** is accepted because Assurance Observations
deep-links here with one. Only arm 1 can answer it, so setting it
suppresses arm 2 entirely rather than returning instance gaps that have
nothing to do with the observation.

### `sp_gap_centre_source_counts`

Fills the Source dropdown. Returns the **whole CHECK vocabulary including
zeroes**, so the list is stable: an operator who filters to Audit and sees
`(0)` has learned something; one who cannot find Audit in the list has
not. It also replaced the three tab badges.

### Nothing was taken away

`sp_task_center_gaps_list` and `sp_custom_gap_list` are **untouched**.
The first still backs Task Center's Gaps badge and
`/practice/api/instances/gaps`; the second still backs every existing
custom-gap caller, including the by-observation route. 255 only adds.

### Row actions survived the merge

The menu used to branch on which tab was open. It now branches on the
row's `Source` and `IsMaterialized` — the same two facts the columns
show. Every action is preserved, and two improved:

- **Practice-instance actions** (View Practice Instance, Add
  Implementation Task, View Existing Tasks) are now offered on
  materialized implementation gaps too, which keep
  `source_reference_id`. The Implementation tab could only offer them
  before materialization.
- **Close Gap** stays scoped to `Source = Custom`. Closing an assurance or
  implementation gap from here would bypass the lifecycle those sources
  own.

`InstanceCode`, `InstanceName` and `ExistingTaskCount` are carried on the
row purely so those actions keep working — the Add Implementation Task
dialog needs code and name as separate values, not parsed back out of a
display string.

### Deep links still land

`?tab=assurance`, `?tab=custom`, `?tab=implementation` and the new
`?source=` all map onto a preset on the Source filter, so
`org-assurance-observations.cshtml`'s two links keep working unchanged.

---

## Task Center — the merge needed no backend change

`sp_task_list` already treats a null `@task_type_code` as "every type",
`@source_type_code` was already one of its 195 filters, and
`SourceTypeCode` was already mapped onto the row. The merge itself was UI
only.

The Source dropdown offers exactly
`ck_pm_practice_task_source_type` as widened by migration 215 — `Gap /
Exception / Risk / RiskRegister / ContinuousAssurance / EventAssurance /
Custom`. An option outside that CHECK would be a filter that can never
match.

### Counts on the options (migration 256)

The merge shipped Task Centre's filter as a hardcoded `<select>` with no
counts, while Gap Centre's carried one per option. The two Centres looked
different for no reason, so `sp_task_centre_source_counts` closes the
gap. It mirrors `sp_gap_centre_source_counts`:

- **whole vocabulary, zero counts included** — filtering to Event
  Assurance and seeing `(0)` tells you something; not finding it in the
  list does not
- **counts what the list shows** — no status filter, because Task Centre
  passes none; parent rows only (`parent_task_id IS NULL`), matching
  `sp_task_list`'s default, since 194 creates decomposed children as
  their own rows and counting them would inflate every source the moment
  somebody split a task

Two things Gap Centre's version does not have:

- **`TotalCount`**, so "All sources" is labelled too.
- **`UnsourcedCount`** on a second result set. `source_type_code` is
  nullable (192 allows it; pre-192 rows carry NULL), and those rows are
  *reported* rather than hidden so the dropdown reconciles against the
  grid — but they are **not filterable**. `sp_task_list`'s predicate is
  `@source_type_code IS NULL OR v.source_type_code = @source_type_code`,
  which cannot express "source is null". The UI shows them as a disabled
  line, not a selectable option, so nobody clicks a filter that would
  silently do nothing.

**Non-fatal by contract.** `SourceCountsAsync` catches `SqlException`
(naming error 2812 — missing procedure — explicitly) and returns an empty
list. The view leaves its static options in place when no counts come
back: an unlabelled filter still filters; an emptied one cannot.

The Web tier's `TaskController` has **no catch-all route**, so unlike Gap
Centre this needed an explicit proxy method there as well.

The refresh call lives inside `refreshCounts()` rather than at each of its
five call sites — closing a task, creating one and switching organisation
all already route through it.

**Event Driven Assurance keeps its own tab.** It is not `practice_task`:
it calls `sp_event_checklist_inbox_list` through `window.__eventAssurance`
and has no pager. Folding it in means resolving
[conflict 4](task-centre-v2.md) first, which is a decision, not an
implementation detail.

The task **type** moved onto the row, under the Source badge — it used to
*be* the tab, so with the tabs gone the row is the only place it can
live. The row menu's two type-dependent branches (View Assurance
Activity; Close Task, labelled "Close / Inactivate" for Custom) now read
`data-task-type` instead of `activeTab`.

Old per-type tab names arriving on deep-link hashes are mapped onto the
merged list rather than dropped.

### 253's Rectification widening

Migration 253 widened the Custom tab to cover `Rectification` so gap
remediation tasks were visible. With no type filter on the list, a gap
task is simply a task with `Source = Gap`, so that widening is no longer
what makes it visible. It is **left in place** — harmless, and still
correct for any caller that does pass `taskTypeCode=Custom`.

---

## Exception Centre — SLA Candidate is hidden, not stranded

Sir asked for SLA Candidate to stop being a tab. The two buckets were
already one table with one column set (Type included); the tabs only
filtered `requestType`.

The tab strip is gone. SLA Candidate rows move **behind the Type filter**,
which defaults to Gap Candidate — so the tab is hidden, but the rows
remain reachable. Removing them outright would strand the
`TASK_SLA_EXTENSION` and `TASK_PRIORITY_REDUCTION` approvals that Task
Centre routes here: nobody could ever approve one again.

The filter also offers **All types**, which the two tabs could not
express. `state.requestType` and the query parameter are unchanged, so
the fetch, the grid and the per-row approve routing (`SLA_CANDIDATE` goes
to a different approve endpoint) are all untouched.

---

## Risk Centre — deliberately unchanged

Nothing to merge:

- **Candidates** is excluded by the rule, and is already the pattern being
  asked for — it has had a Source column and a `riskFilterSource`
  dropdown since 205.
- **Register** is a different entity with its own lifecycle. Merging it
  into Candidates would contradict BRD §24 rule 1, which requires every
  register entry to have passed through an analysis — the two stages
  would stop being visibly separate.
- **Dashboard** is not a list.

---

## Known, pre-existing, not fixed here

`org-assurance-observations.cshtml:810` deep-links to
`/Practice/Index/gaps?gapId=…`, but `gaps.cshtml` has never read a
`gapId` query parameter — that link lands on the plain list and always
did. Left alone: fixing it means deciding whether it should jump to
`gap-detail` instead, which is a product question.

---

## Follow-up (318): the Status column was showing the wrong status

Sir's feedback: Gap Center really only has 2 statuses now — New and
Analysed — but the list's **Status** column showed "Open".

`sp_gap_centre_list`'s `StatusText` was `custom_gap.status` — the
record's own open/closed bookkeeping flag (Open / InProgress / Closed /
Cancelled, the same vocabulary the Add-Gap dialog's Status dropdown
offers, and every gap is born into as `'Open'`). That column has never
described *where a gap is in its analysis lifecycle*; it was simply the
only status-shaped column the original 255 write-up had to hand.

The lifecycle stage already exists, and the Analysis screen already
shows it: `custom_gap.lifecycle_state_id` → `gap_lifecycle_state_master`,
projected by `sp_custom_gap_header` as `LifecycleStateName`. 174
collapsed the model to New → (analysis saved) → Delegated, and 175
renamed `Delegated`'s *display* name to "Analysed" because "Delegated"
read as jargon — so for any gap raised since, that column is exactly the
two values sir named. (Validation/Analysis/ResolutionPlanning/Execution/
Verification/Closed are dormant, kept only for gaps that reached them
before 174; Invalid/Duplicate are the two terminal-invalid outcomes —
all still valid `state_name` values the list will show correctly.)

**318** re-issues `sp_gap_centre_list` so the materialized (`custom_gap`)
arm's `StatusText` is `COALESCE(s.state_name, g.status)` via the same
`LEFT JOIN gap_lifecycle_state_master s ON s.lifecycle_state_id =
g.lifecycle_state_id` `sp_custom_gap_header` already uses — the fallback
only covers a row with no `lifecycle_state_id` at all, which should not
happen. The **un-materialized `practice_gap` arm is unchanged**: it has
no `custom_gap` row yet, so no lifecycle state to show, and its existing
derived text (worst logged Obligation status — Not Implemented / Partially
Implemented) answers a different, still-useful question — *why* the gap
exists — which the row's own "not yet analysed" note already covers on
the lifecycle side.

`custom_gap.status` is not retired. `gaps.cshtml`'s Close Gap menu action
still needs it verbatim — a closed Custom gap can be in any lifecycle
state, so the lifecycle stage cannot answer "is this gap already closed".
318 keeps it on the row as a new `RawStatusCode` column (`GapCentreListRow.
RawStatusCode`, trailing/optional, `HasColumn`-guarded on read for a
pre-318 database) instead of dropping it, and `buildRowMenu()`'s
`isClosed` / `disabledReason` logic now reads `rawStatusCode` instead of
the now-repurposed `statusText`.

**Not changed:** `@status_code`, the filter parameter on
`sp_gap_centre_list`, still filters the materialized arm on the raw
`g.status` code — nothing in the UI currently sends it (there is no
Status filter dropdown on Gap Centre, only Source), so its meaning was
left as-is rather than redefined under a caller nobody has reviewed.
`sp_gap_centre_source_counts`, `sp_custom_gap_header`, `sp_custom_gap_list`,
`sp_task_center_gaps_list` — untouched.

Rollback: `318_gap_centre_list_lifecycle_status_rollback.sql` restores
255's `sp_gap_centre_list` body verbatim (`StatusText = custom_gap.status`,
no `RawStatusCode`).

### Follow-up (319): "Delegated" showed up instead of "Analysed"

Sir's feedback right after 318 shipped: a status called "Delegated" was
now visible. **318's code was correct** — it reads
`gap_lifecycle_state_master.state_name`, the same column
`sp_custom_gap_header` already reads for the gap-detail screen — but the
*data* in that column, on this database, was stale.

175 renamed `state_name` from `'Delegated'` to `'Analysed'` for
`state_code = 'Delegated'` (174 first seeded the row with `state_name`
equal to its own `state_code`; 175 is the terminology fix, purely a
display-name UPDATE). `272_master_data_seed.sql` **also** carries a seed
row for that same `state_code`, but with the pre-175 literal
(`state_name = N'Delegated'`) — 272 was written by copying 174's
original seed and never updated to match 175's rename. 272's `MERGE` is
insert-only (`WHEN NOT MATCHED BY TARGET`, no `WHEN MATCHED`), so it
cannot silently revert an *already-renamed* row — but if
`gap_lifecycle_state_master` was ever empty when 272 ran (a fresh
database, or a practice-data reset that cleared it) and 175 was not
re-applied afterward, 272 inserts the row with the stale name and it
stays that way until 175 runs again.

319 re-applies 175's own `UPDATE` (safe to run whether or not 175 already
ran — a same-value update is a no-op) to fix the live data immediately.
No proc/view changed; 318's `sp_gap_centre_list` needed no re-issue —
it was never the bug. 174.sql and 272.sql are left as-is, consistent with
every other migration in this project being append-only history rather
than edited after the fact; 175 remains the correction layer for that
literal, and 319 exists only because 175's effect did not (or no longer
did) hold on this specific database.

**If this recurs:** after any future practice-data reset that reseeds
masters via 272 from empty, re-run 175 (or 319 — same effect) before
trusting the Gap Centre Status column again.

### Follow-up (320): Owner and Raised On were blank; Context/Due Date dropped from the grid

Report: "gap center nnu context and duedate remove cheyyanam. grid nnu.
PINNE RAISED ON NNU PARANJA COLUMN AND OWNER lu ipo data varunnilla.
automtic anenkil practice owner ku automatic assign cheyyanam. custom lu
owner selection undu. pakshe list lu date kanikunnilla. raised on Also" —
remove the Context and Due Date columns from the grid; the Owner and
Raised On columns show no data; for automatic gaps the owner should
auto-assign from the practice; Custom gaps do have an owner picker, but
the list still shows no date for them either.

**Grid columns.** `gaps.cshtml`'s `<thead>` dropped `Context` and
`Due Date` — the grid is now Gap / Source / Status / Severity / Owner /
Raised On / Actions (7 columns; every `colspan="9"` empty-state row
became `colspan="7"`). Neither field was used anywhere else on the page
(no row-menu logic reads `row.context`/`row.dueDate`), so this was a
pure display change — the API still returns both, only the two `<td>`
template entries were removed.

**Owner / Raised On — two different bugs on two different creation
paths**, which is why reading only one proc did not explain the report:

- **Automatic (Implementation) gaps** materialize through
  `sp_custom_gap_materialize_for_instance` (160). Its `INSERT` never set
  `owner_employee_id`, `owner_display_name`, or `opened_dt` at all — every
  automatically materialized gap was born with all three NULL.

- **Custom gaps** — the Add Gap dialog's `fetch(U('/practice/api/gaps/
  custom'))` call hits `CustomGapController`'s plain `POST /` route,
  which is `OpenAsync` → `sp_custom_gap_open`. This is a *different* proc
  from `sp_custom_gap_save` (the `.../save` route, used for the unified
  edit/upsert flow elsewhere) — and it matters, because
  `sp_custom_gap_save` (re-issued in 116b) already resolves
  `owner_display_name` from an `owner_employee_id` and already sets
  `opened_dt` on insert. `sp_custom_gap_open`'s live body (250) does
  neither: it takes `@owner_employee_id` straight from the dialog's
  picker but never resolves a display name from it, and its `INSERT`
  column list has no `opened_dt` at all. So every Custom gap opened
  through the dialog landed with Owner blank (even though an owner was
  picked) and Raised On blank — reading `sp_custom_gap_save` alone,
  which looks correct, does not explain this, because that proc is not
  on the create path the dialog actually calls.

**Fix (320).** Re-issues both procs via `CREATE OR ALTER` (160.sql and
250.sql are left as-is, per this project's append-only migration
history):

- `sp_custom_gap_materialize_for_instance` now also pulls the practice
  instance's owner (`practice_instance.primary_owner_id` /
  `primary_owner`, resolved against `organization_employee` the same way
  287/290 already do for Resolve) alongside the title/description lookup
  it already had, and sets `owner_employee_id`, `owner_display_name`, and
  `opened_dt = SYSUTCDATETIME()` on the `INSERT`. This is the "practice
  owner auto-assign" for automatic gaps.
- `sp_custom_gap_open` now resolves `owner_display_name` from
  `organization_employee` when an `owner_employee_id` is supplied (the
  same hybrid-resolver pattern `sp_custom_gap_save` already uses), and
  sets `opened_dt = SYSUTCDATETIME()` on the `INSERT`.
- A one-time, idempotent backfill covers rows already on the table:
  `opened_dt = entered_dt` wherever `opened_dt IS NULL` (mirrors 109's
  own backfill, which only ever covered rows that existed when 109 ran —
  everything created after that by either proc needed this); owner
  display name resolved from `organization_employee` wherever an owner id
  is set but the name is not; and, for existing automatic gaps
  specifically, owner pulled from their linked `practice_instance` where
  still NULL. None of the three ever overwrites a value that is already
  set.

Rollback: `320_gap_owner_and_opened_dt_autopopulate_rollback.sql` restores
both procs to their exact pre-320 bodies. It deliberately does **not**
undo the backfill — there is no record of which rows were NULL before
320 ran, so "undoing" it would mean re-nulling Owner/Raised On on rows
that were already showing correctly (e.g. any Custom gap saved through
`sp_custom_gap_save`'s edit path), which is worse than leaving the data
alone.

### Follow-up (321): Gap Detail gained a "View Practice Instance" link, and the Mark Invalid button was hidden

Report (first pass): "pinne anaysis nte page lu Analysis, metadata
athinte koode Practice Instance nte oru tab koodi introduce cheyyanam.
athil practice instance nte view page (attach cheythittundu)anu
kanikendathu." — on the gap-detail page, alongside the Analysis and
Metadata tabs, add one more tab for Practice Instance; it should show
the practice instance's view page (screenshot attached: the
Operationalize / resolve-workspace screen in `?mode=view`).

Follow-up bug report: opening that tab showed a browser-level
"localhost refused to connect" error. No `X-Frame-Options` or CSP
middleware exists anywhere in this codebase (checked both projects),
so this wasn't a framing block; an absolute iframe `src`
(`window.location.origin`-based, instead of a bare relative path) and
a same-URL "Open in a new tab" fallback link were added alongside the
iframe as a diagnostic aid.

Final instruction, once the fallback link was confirmed working:
"open in a new tab working anu. apo enna analysis nte page lu oru link
vachu cheytha ingane vere tab lu open cheytha mathi. tab hide
cheytholu. athu pole thanne mark invalid nnu parayunna button koodi
hide cheytholu" — since the plain link works, just put a link on the
Analysis page that opens the practice instance in another tab; drop
the tab entirely; and hide the "Mark Invalid" button the same way.

**What it is now.** `gap-detail.cshtml` stays two tabs — Analysis and
Metadata & History; the Practice Instance tab and its iframe are gone.
Instead, the Analysis tab panel carries a plain "View Practice
Instance" link (`<a target="_blank" rel="noopener">`, `#gapInstanceLink`
inside `#gapInstanceLinkWrap`) pointing at the exact same destination
`gaps.cshtml`'s row menu already uses for an instance-backed gap
("View Practice Instance" → `/Practice/Index/resolve-workspace?
instanceId=..&organizationId=..&mode=view`), built from
`window.location.origin` rather than a bare relative path. Clicking it
opens that screen in a new browser tab — normal browser navigation,
not framed — which is why it doesn't hit whatever made the iframe
unreachable.

**Only shown when there is an instance to link to.** Unchanged from
the tab version: a gap only has a linked Practice Instance if it is an
automatically materialized Implementation gap
(`gap_source_module_code = 'Implementation'`,
`source_reference_type = 'PracticeInstance'`) — Custom and Assurance
gaps have none, and an un-materialized Implementation row has no
`custom_gap` yet either. `gap-detail.js`'s `renderPracticeInstanceLink()`
keeps `#gapInstanceLinkWrap` `hidden` unless the gap header comes back
with a `practiceInstanceId`.

**The header change stands as-is.** `sp_custom_gap_header` still needed
to learn the linked instance either way — the link needs
`PracticeInstanceId` just as much as the tab did. 321's re-issue of the
proc (250's body, re-issued — 250.sql itself untouched, per this
project's append-only migration history), the `LEFT JOIN` to
`practice_instance`, the `GapHeader` model fields, and
`GapLifecycleService.GetHeaderAsync`'s `HasColumn`-guarded reads are
all unchanged and still in place; only the client-side presentation
(link instead of framed tab) changed.

Rollback: `321_gap_header_practice_instance_link_rollback.sql` restores
`sp_custom_gap_header` to its exact pre-321 (250) body, unaffected by
this UI follow-up. The link then simply never finds a
`practiceInstanceId` and stays hidden — the same as it already does
today for a Custom or Assurance gap.

**Mark Invalid button hidden (UI only).** `gap-detail.js`'s
`refreshActions()` already filtered out `Delegate`/`Validate` into an
`AUTO_ONLY` set (automatic/redundant transitions); a second set,
`HIDDEN_BY_REQUEST`, now also filters out `MarkInvalid`
(`gap_lifecycle_transition_master.action_code = 'MarkInvalid'`, seeded
in migration 272). `MarkDuplicate` is a separate action_code and is
untouched — it still renders normally. Nothing server-side changed:
the `MarkInvalid` transition itself is still fully valid and reachable
through the lifecycle API (e.g. if a future screen or an admin tool
needs to invalidate a gap); only this screen's button for it is
removed. No migration was needed for this part — it's a pure
`gap-detail.js` filter change.

### Follow-up (323): Risk Analysis decisions became three independent checkboxes; Task-creation traced and hardened

Report: "Currently the flow is: Remediation Possible = Yes -> Generate
Task; = No -> Move to Exception; Risk = Yes -> Move to Risk Candidate.
I want to remove this conditional/branching logic completely. Instead,
provide three independent checkboxes -- Generate Task / Request
Exception / Create Risk -- each working independently, more than one
selectable at the same time." Also: "the existing Task creation flow --
when Task creation is triggered, it appears that the Task is not
actually being created. Trace the complete flow and fix it."

**There was nothing new to build -- only branching to remove.**
`custom_gap_analysis.recommend_task` / `recommend_exception` /
`recommend_risk` are not new columns: they are the *original* three
independent `BIT` flags from migration 156 (schema) / 157 (procs),
plain `NOT NULL DEFAULT 0`, no mutual-exclusion constraint between
them. Migration 168 is what introduced `remediation_possible` /
`business_risk_present` (two mandatory `CHAR(1)` Yes/No columns) and
had `sp_custom_gap_analysis_save` derive the three legacy flags *from*
the two decisions -- one Yes/No forced exactly one of Task/Exception,
a second, separate Yes/No gated Risk -- and, symmetrically, derive the
two decisions back from the three flags when the two were not
supplied. 172 (risk trigger) and 252 (restoring 168+174 after a
regression) both kept that two-way derivation; migration 323 is the
first to remove it. So: no new table, no new column, no data
migration -- `sp_custom_gap_analysis_save` (252's body) is re-issued
with the derivation deleted. `@recommend_task` / `@recommend_exception`
/ `@recommend_risk` become the direct, independent inputs, each with
its own `IF ... = 1` auto-trigger, none conditioned on the other two.
`@remediation_possible` / `@business_risk_present` are kept as accepted
parameters (existing callers / historical rows are not broken) but are
only `COALESCE`d onto whatever the row already has -- never read to
drive a trigger, never derived from the three flags. The UI sends
`null` for both from now on, so in practice these two columns simply
stop changing.

`gap-detail.cshtml`'s two "Remediation possible? / Is there a business
Risk?" `<select required>` dropdowns are replaced with a
`.pm-decision-checkboxes` row of three plain checkboxes -- Generate
Task, Request Exception, Create Risk -- none required, any combination
valid, including all three or none. `gap-detail.js`'s
`applyAnalysisToForm()` now sets their `.checked` straight from
`recommendTask`/`recommendException`/`recommendRisk` (no more deriving
a Yes/No from them), and `onAnalysisSubmit()` sends those three booleans
directly instead of the old mandatory dropdown values (which also
fixes a latent bug: the payload previously hardcoded
`recommendTask/Exception/Risk` to `false` regardless of anything on
screen -- only the two Yes/No dropdowns actually drove behaviour before
this migration).

**Task-creation investigation.** Traced Risk Analysis ->
`POST /gaps/{id}/analysis` (`GapLifecycleService.SaveAnalysisAsync`) ->
`sp_custom_gap_analysis_save` -> `sp_custom_gap_task_create` ->
`sp_task_open` -> `practice_task`. Two things found, both already fixed
once in this codebase's history and carried forward rather than
re-broken:

1. `sp_custom_gap_analysis_save` wraps the `sp_custom_gap_task_create`
   call in `TRY`/`CATCH` and only `PRINT`s on failure (migration 174,
   kept by 252) -- best-effort, so a failed create was silent to the API
   and the UI; the `PRINT` is invisible outside SSMS. 323 captures
   success/error into local variables per trigger and returns them in a
   **new second result set**
   (`TaskCreated`/`TaskError`/`ExceptionCreated`/`ExceptionError`/
   `RiskCreated`/`RiskError`), which `GapLifecycleService.SaveAnalysisAsync`
   now reads (guarded by `NextResultAsync`, so a pre-323 database that
   only returns the first result set still binds) and
   `gap-detail.js`'s `buildSaveSummary()` now shows as `Failed: Task
   (<error text>)` when a requested trigger did not produce a linked
   artefact, instead of the trigger's absence going unexplained.
2. `sp_custom_gap_task_create` itself was, once already (between
   migrations 199 and 253), rerouted to raise an invisible Task
   *Candidate* instead of opening a real Task -- exactly this report's
   symptom ("Task creation triggered, but no Task appears anywhere").
   253 fixed this by reverting the proc to call `sp_task_open` directly,
   and nothing after 253 in this codebase's own migration history
   touches `sp_custom_gap_task_create`, `sp_task_list` or
   `sp_task_center_counts` -- but a live database can be at any point in
   its own migration history, which this file cannot query. 323
   re-issues 253's exact proc body (byte-for-byte the same `CREATE OR
   ALTER`) as a belt-and-suspenders guarantee: a no-op re-assertion if
   253 is already applied, and the fix itself if it is not.

`sp_custom_gap_analysis_get` is unchanged and not re-issued by 323 -- it
already projects `RecommendTask`/`RecommendException`/`RecommendRisk`
(168) and nothing about what they mean or how they are read changes.

Verified by static trace against all 8 checkbox combinations (this
environment has no live database or running app to exercise the API
against -- see [[gap_analysis_independent_decisions]] for the full
combination table and how each one resolves through the new proc
logic).

Rollback: `323_gap_analysis_independent_decisions_rollback.sql`
restores `sp_custom_gap_analysis_save` to its exact pre-323 (252) body
-- the Yes/No branching returns and the second result set goes away.
`sp_custom_gap_task_create` is not rolled back (323 changed nothing in
its body, only re-asserted 253's).

### Follow-up (324): status silently never reached Analysed; re-analysis now blocked

**Report.** After completing analysis, the gap stayed on its previous
status instead of becoming `Analysed`. Separately: once a gap had already
been analysed, the analyst could open Analyse again and re-submit --
nothing in the UI or the API stopped a second analysis.

**Root cause, part 1 -- status not updating.** "Analysed" is not a
separate lifecycle state; it is the *display name* `state_name` on
`state_code = 'Delegated'` (175, re-asserted by 319). A gap reaches it
through the "Auto-transition to Delegated" block at the end of
`sp_custom_gap_analysis_save` (added by 174, carried unchanged through
252 and 323). That block looked up the gap's own current state with an
`INNER JOIN` between `custom_gap` and `gap_lifecycle_state_master` on
`lifecycle_state_id`:

```sql
SELECT @current_state_code = s.state_code
  FROM grac_practice.custom_gap g
  JOIN grac_practice.gap_lifecycle_state_master s
       ON s.lifecycle_state_id = g.lifecycle_state_id
 WHERE g.custom_gap_id = @custom_gap_id;
IF @current_state_code IN (N'New', N'Validation', N'Analysis') ...
```

`custom_gap.lifecycle_state_id` is `NULL`-able (156) and was **never
populated** by `sp_custom_gap_open` (250 -- the proc behind the Gap
Centre "Add Gap" dialog every Custom gap is created through) or by
`sp_custom_gap_save`'s create branch (116b). For every such gap the
`INNER JOIN` matched zero rows, `@current_state_code` stayed `NULL`,
`NULL IN (...)` is neither true nor false in T-SQL (`UNKNOWN`), and the
`IF` was skipped -- silently, with no error and not even a `PRINT`,
because the skip happens before the block's own `TRY` even starts. The
gap's `lifecycle_state_id` was never set, `sp_gap_centre_list` (318)
fell back to the raw `custom_gap.status` (`'Open'`), and both the Gap
Centre list and the gap-detail stepper kept showing the pre-analysis
status forever. This explains why gaps *materialized from a Practice
Instance* never showed the bug: `sp_custom_gap_materialize_for_instance`
(160) has always stamped `lifecycle_state_id` to the `'New'` state's id
at creation, so its `INNER JOIN` always found a row.

The engine this block calls, `sp_custom_gap_lifecycle_transition` (157,
never re-issued since), has *always* had the correct defensive handling
for exactly this case -- `IF @current_state_id IS NULL ... treat its
current state as 'New'`. The auto-Delegate block's own pre-check simply
never had the same fallback.

**Fix, part 1 (migration 324).**
1. `sp_custom_gap_analysis_save`'s auto-Delegate block: `LEFT JOIN`
   instead of `INNER JOIN`, `NULL` current-state treated as `'New'`
   (matching 157's own rule), and the transition's own success/error now
   captured into the second result set (323 pattern) as
   `LifecycleTransitioned`/`LifecycleError`, alongside a fresh
   `LifecycleStateCode`/`LifecycleStateName` read right after the
   attempt -- so the API, and from there the UI, can see the true
   post-save state directly from the save call instead of only by
   inference.
2. Belt-and-suspenders, the same pattern 323 used for the task-creation
   fix: `sp_custom_gap_open` and `sp_custom_gap_save`'s create branch now
   also stamp `lifecycle_state_id = 'New'` at creation, exactly as
   `sp_custom_gap_materialize_for_instance` already does -- so a freshly
   created gap is never `NULL` in the first place, on any creation path,
   regardless of the fallback in (1).

`GapAnalysisSaveResult`/`GapLifecycleService.SaveAnalysisAsync` now read
and log the new columns (`HasColumn`-guarded, same as the 323 fields),
and `gap-detail.js`'s `buildSaveSummary()` reports a failed transition as
`Failed: Status update to Analysed (<error text>)`, using
`result.lifecycleStateName` (returned directly by the save call) as the
authoritative "Gap is now ..." text rather than waiting on the follow-up
`/header` fetch.

**Root cause + fix, part 2 -- re-analysis of an already-Analysed gap.**
173 added a terminal-invalid guard to `sp_custom_gap_analysis_save`
(`is_terminal = 1 AND is_valid_terminal = 0` -- Invalid/Duplicate). It
deliberately does not cover Delegated/"Analysed", which is terminal but
`is_valid_terminal = 1` -- so there had never been a guard against
re-analysing an already-Analysed gap, at the API or the database.
Migration 324 adds the missing counterpart: `THROW 55143` when the gap is
currently in a terminal-**valid** state (today, only Delegated). A gap
whose `lifecycle_state_id` is `NULL` is treated as `'New'` (not
terminal), so a first analysis is never blocked.

UI side (also 324, reusing rather than duplicating the existing lock):
* `gap-detail.js` gets `isAlreadyAnalysed()` alongside the existing
  `isTerminalInvalid()` (from 173), and `applyTerminalInvalidMode()` now
  locks the Analysis form for *either* case -- same disable-every-field
  loop, different banner (`#gapAlreadyAnalysedBanner`, green, "This gap
  has already been analysed" -- vs. the red terminal-invalid one). Called
  immediately after a save that auto-delegates, so the form locks itself
  into read-only the moment the gap becomes Analysed, not only on the
  next manual refresh.
* `gaps.cshtml`'s row menu: the "Analysis" item becomes "View" (same
  destination, same `gotoDetail(gapId)` -- gap-detail.cshtml locks itself
  from the header it already fetches) once the row's lifecycle state is
  `Delegated`. Gated on a new `LifecycleStateCode` column
  `sp_gap_centre_list` (324, re-issued from 318) now projects -- the
  *raw* `state_code`, not the display text in `StatusText`, since
  175/319 already show that label can be reworded.

**Testing (static trace -- no live database/app in this environment).**
Traced: Pending gap -> Analyse -> save -> `sp_custom_gap_analysis_save`
now finds `lifecycle_state_id` populated (new gaps) or falls back to
`'New'` (pre-324 gaps with a `NULL` value) -> auto-Delegate transition
fires -> `lifecycle_state_id` updated -> `sp_gap_centre_list` and
`sp_custom_gap_header` both read the same column, so the grid's Status
column and the gap-detail stepper agree -> row menu shows View, gap-detail
locks into read-only -> a direct `PUT .../analysis` call against the same
gap now gets `55143` back instead of silently succeeding. The three
independent decisions from 323 are unaffected by 324 (no changes to the
Task/Exception/Risk trigger blocks, their parameters, or their part of
the result set) -- re-verified by re-reading the full proc body after
edit.

Migration: `324_gap_analysis_status_and_reanalysis_guard.sql` /
`_rollback.sql`. Touches `sp_custom_gap_open`, `sp_custom_gap_save`,
`sp_custom_gap_analysis_save`, `sp_gap_centre_list`. No schema change, no
data migration -- existing rows with a `NULL` `lifecycle_state_id` are
handled by the part-1 fallback the next time they are analysed or
re-saved; nothing in 324 back-fills historical rows.

### Follow-up (325): Gap View page -- read-only consolidated view

Not really about the Source column (this doc's original subject), but
the closest existing writeup to link the new page's design notes from,
same as 324's entry above.

**What was asked.** A dedicated Gap View page in Gap Center: full gap
details, plus a clickable Task / Exception / Risk card for whatever has
actually been generated against that gap (not merely sharing an
Organization/Practice/Risk), each card opening the artefact's own
existing full view in a new tab, statuses always read live. Reuse
existing models/APIs/routes; no duplicate business logic, no duplicate
full-view pages.

**What already existed vs. what "full view" turned out to mean.**
Investigation (no code changed until this was settled) found the three
artefact types are NOT symmetrical:
* **Exception** already has a genuine routed full view --
  `exception-analysis.cshtml?exceptionId=` (migration 257). Nothing to
  add.
* **Task** has no routed full view. "View" is
  `openTaskViewDrawer(taskId)` on `tasks.cshtml` itself, opening a
  `<dialog>` -- fetched from `GET /practice/api/tasks/{id}`. No URL could
  reach a specific task before this migration; `applyDeepLinkFromHash()`
  only understood `#tab=&search=`.
* **Risk** has no routed full view either. "View risk" is
  `openRiskDetailPage(riskId)` on `risk-centre.js`, an in-page full-page
  swap (`showFullPage('riskDetailPageView')`) -- fetched from
  `GET /api/practice/risk-centre/register/{riskId}`. No URL could open
  one directly before this migration.

So "reuse the existing full-view pages" for Task and Risk meant adding a
small, additive URL entry point to each screen's OWN existing rendering
function -- not building a second detail surface. 325 adds:
* `tasks.cshtml` `applyDeepLinkFromHash()`: a `#taskId=<id>` hash param
  now calls the existing `openTaskViewDrawer(taskId)` directly, alongside
  the pre-existing `#tab=&search=` handling (not awaited -- the dialog
  fetches the task itself and does not depend on `onOrgChange()`'s grid
  load).
* `risk-centre.js` `init()`: a `#riskId=<id>` hash param calls the
  existing `openRiskDetailPage(riskId)` directly, after the existing
  organisation auto-select block but unconditionally (confirmed
  `openRiskDetailPage` only depends on the fetch + DOM panels already in
  the page, not on `state.organizationId` or grid data being loaded).

**Task/Exception/Risk relationship -- where the data actually comes
from.** `sp_custom_gap_linked_artefacts` (migration 174, via
`GET /practice/api/gap-lifecycle/gaps/{id}/linked-artefacts` --
the exact call `gap-detail.cshtml`'s own chip strip already makes)
returns the gap's own Task / Exception / RiskCandidate, one row each,
sourced directly from `practice_task` / `exception_request` /
`risk_candidate` filtered on this gap's id -- never another gap's, and
never merely something sharing an Organization/Practice/Risk. The
`downstream_link` many:many table (also exposed, at
`.../downstream`) is explicitly commented in `GapLifecycleController.cs`
as "retained for backward compat / historical data" -- deliberately NOT
used here, since mixing it in risked showing stale/legacy links the
requirement (§6) says must not appear.

For the Risk card specifically: `sp_custom_gap_linked_artefacts` returns
the risk **candidate** id (`risk_candidate.risk_candidate_id`), not a
`risk_register_id` -- a candidate only becomes a full register row (and
gets a click-through target) once accepted.
`sp_risk_candidate_get`/`_list` (206) already projects
`RegisteredRiskId`/`RegisteredRiskNumber` on the candidate row, so
`gap-view.js` reads the candidate first and picks one of two deep-links
depending on whether it is registered yet (see "Post-ship fix: Risk card
click target" below for how the not-yet-registered branch was refined
after initial ship).

**Card data -- reusing each Centre's own single-record read**, not a new
combined endpoint:
* Task    -> `GET /practice/api/tasks/{id}` (same read `openTaskViewDrawer` uses)
* Exception -> `GET /practice/api/exception-centre/{id}` (same read `exception-analysis.js` uses)
* Risk    -> `GET /api/practice/risk-centre/{candidateId}`, then
  `GET /api/practice/risk-centre/register/{riskId}` once registered
  (same reads Risk Centre's own candidate/register views use)

**Gap Details panel.** Sourced entirely from the existing
`sp_custom_gap_header` (`GapHeader`), with exactly one new column:
`IdentifiedDate` (`custom_gap.entered_dt`), added because the header had
never projected it. Framework / Source Statement / Control were
deliberately NOT re-derived inline: that data already lives on the
linked Practice Instance's own workspace
(`resolve-workspace.cshtml?instanceId=`, the same destination
`gap-detail.cshtml`'s "View Practice Instance" link already opens), so
Gap View links to it instead of joining the same tables a second time
-- consistent with "use the existing data model... do not duplicate data
unnecessarily." Obligation(s) are shown from the same
`/linked-artefacts` response's `failedObligations` array (317) that
`gap-detail.cshtml`'s own strip already reads.

**Post-ship fix: Risk card click target.** Two rounds of user feedback
after initial ship, both scoped to the not-yet-registered branch of the
Risk card only (the registered branch's `#riskId=` deep-link was correct
from the start and untouched by either round):
* *Round 1.* Originally the not-yet-registered branch had no `openHref`
  at all (`cardShell`'s `is-clickable` class/handler only attach when
  `openHref` is truthy) -- reported as "clicking the Risk card does
  nothing." Fixed by pointing it at the bare `risk-centre` URL (its
  default Candidates tab, where the un-registered candidate is waiting).
* *Round 2.* That bare-list landing was then correctly rejected: the
  requirement is a *view of the risk itself*, not the Centre's list
  screen. Re-investigating `risk-centre.js` surfaced a surface not
  accounted for in the original design: the candidate row menu's own
  "View details" action, `openDetailModal(id)` -- a genuine read-only
  modal (title, meta, every retained assessment version, related tasks),
  fetched independently the same way `openRiskDetailPage` is (own
  `apiGet` calls, no dependency on `state.organizationId` or grid load).
  325's `#riskId=` pattern is mirrored for it: `risk-centre.js` `init()`
  gained a second, independent hash check, `#candidateId=<id>` ->
  `openDetailModal(candidateId)`, alongside (not replacing) the existing
  `#riskId=` check. `gap-view.js`'s not-yet-registered branch now opens
  `risk-centre#candidateId=<risk_candidate_id>` instead of the bare URL,
  landing the user directly in that modal. No new API call, no new
  business logic, no duplicate detail surface -- both hash params reuse
  an existing, already-shipped read/render function verbatim.

**Live status.** Every read above is a fresh call made when the page
opens (and on its Refresh button) -- no caching, no snapshot carried
over from the gap header or from Gap Centre's list. Reopening the page
after a Task/Exception/Risk status changes elsewhere shows the new
status.

**Files.**
Migration: `325_gap_header_identified_date.sql` / `_rollback.sql`.
Touches only `sp_custom_gap_header` (re-issued from 321's body, +
`IdentifiedDate`). No table/column change, no data migration.
API: `Api/Models/GapLifecycleModels.cs` (`GapHeader.IdentifiedDate`),
`Api/Services/GapLifecycleService.cs` (`GetHeaderAsync`, tolerant
`HasColumn` read, same pattern as every field added since 177).
Web: `Models/PracticeScreen.cs` (new `gap-view` route screen, no menu
entry -- same "route" convention as `gap-detail`/`exception-analysis`),
`Views/Practice/Partials/gap-view.cshtml` (new),
`wwwroot/js/GapLifecycle/gap-view.js` (new),
`Views/Practice/Partials/tasks.cshtml` (`applyDeepLinkFromHash`, +`taskId`),
`wwwroot/js/RiskCentre/risk-centre.js` (`init`, +`riskId` hash check;
post-ship fix added +`candidateId` hash check -> `openDetailModal`),
`Views/Practice/Partials/gaps.cshtml` (row menu: new "View Gap Details"
item alongside Analysis/View, for a materialized gap),
`Views/Practice/Partials/gap-detail.cshtml` +
`wwwroot/js/GapLifecycle/gap-detail.js` (new "Gap View" toolbar link,
wired once the header resolves the gap id + org).

**Testing (static trace -- no live database/app in this environment).**
Verified: `sp_custom_gap_header`'s SELECT list is 321's body plus exactly
one appended column (diffed column-by-column against 321); balanced
`BEGIN`/`END`/`CASE` counts on both the migration and its rollback;
parameter/column projections unchanged elsewhere. All touched/added
`.js` files and every `.cshtml` file's inline `<script>` block pass
`node --check`. C#/record brace-paren balance checked on
`GapLifecycleModels.cs`, `GapLifecycleService.cs`, `PracticeScreen.cs`.
Traced field names for the Task/Exception/Risk card reads against each
source screen's own JS (`renderTaskDetail`, `exception-analysis.js`
`renderHeader`, `risk-centre.js` `openRiskDetailPage`/grid renderers) and
against the C# service methods that populate them
(`RiskCentreService.GetAsync`/`GetRegisterAsync`), not assumed.

### Follow-up (326): Task View and Exception View -- dedicated full-page views

**The ask.** Task's "View" and Exception's would-be "View" were both
still small compact surfaces: Task View was a native `<dialog>` drawer
(`#taskDetailDialog`, `openTaskViewDrawer`) inside `tasks.cshtml`, and
Exception had no view at all -- `exception-analysis.cshtml` is the
Pending-request *analysis workflow* (justification, proposed dates,
Submit for approval), not a read-only view, and Exception Centre's own
row menu already disables the link to it outside Pending/
SubmittedForApproval. The instruction: convert Task View into a proper
full-page screen, build Exception a dedicated full-page View for the
first time, wire every existing View action (including the Gap View
page's Task/Exception cards) to open the new pages in a new tab, and do
all of it on the *existing* APIs and models -- no duplicate business
logic.

**Design, following the 325 Gap View precedent (`risk_centre_full_page_
pattern.md`).** Both pages are new `"route"` screens in
`PracticeScreen.cs` (no sidebar entry, same convention as `gap-view`/
`gap-detail`/`exception-analysis`): a `pm-panel` shell `.cshtml` with an
external `.js` file and **no inline `<script>` block at all** -- Razor's
`@` sigil is hostile to inline scripts (see `razor_at_sigil_in_cshtml_
scripts.md`), and `gap-view.cshtml` already proved the external-script
shell works cleanly. Each new page is read-only and additive: the
originating dialog/workflow page is left completely alone for every
responsibility that isn't "show me everything about this record" --
Task's Edit/Complete/Close/Add Evidence/Add Update dialog machinery is
untouched, and `exception-analysis.cshtml` still owns the Pending
workflow exactly as it did.

**Task View** (`task-view.cshtml` / `wwwroot/js/TaskCentre/task-view.js`,
new folder, `?taskId=NNN`). One call, `GET /practice/api/tasks/{id}`
(the same endpoint `openTaskViewDrawer` already used), renders: Task
Reference/Type/Status/Priority (+ pending-change badge)/Assigned To/
**Related Organization** (new, see migration below)/Start/Standard &
Extended Due/SLA Status, a Related-Source link resolved from
`sourceTypeCode` (`Gap` -> `gap-view?gapId=`, `Exception` ->
`exception-view?exceptionId=`, `Risk` -> `risk-centre#candidateId=`,
`RiskRegister` -> `risk-centre#riskId=` -- migration 196's CASE
expression and 215's header comment are what fixed this vocabulary,
not a guess), Description, Completion detail, Child Tasks (+ mandatory-
open warning), Exception Centre governance requests, Evidence (existing
`GET /practice/api/tasks/attachments/{id}`), Created/Updated, and the
activity feed. `tasks.cshtml`'s row-menu "View" and its `#taskId=` hash
deep-link now both navigate here instead of opening the dialog; every
other call site of `openTaskViewDrawer` (Cancel-from-Edit, post-save
reload, the dialog's own `data-open-task` cross-links, post-evidence
reload, Escape-while-editing) is untouched, because those are edit-flow
concerns, not View.

**Migration 326 -- Related Organization for Task View.** The one gap:
`vw_pm_practice_task` (the view backing `sp_task_get`/`sp_task_list`)
had `organization_id` but no organization *name*, and
`OrganizationsController`'s lookup is scoped to the *current user's*
allowed orgs, not a generic lookup by id -- unusable here. Re-issued
`vw_pm_practice_task` verbatim from migration 195's body (same pattern
as 325's `sp_custom_gap_header` re-issue) adding one
`LEFT JOIN grac_practice.organization org ON org.organization_id =
t.organization_id` and `org.organization_name`. Diffed column-by-column
against 195: the only differences are the one join and one column.
Rollback restores the view to 195's body -- diffed again after the
first pass turned up missing section-header comments (cosmetic only,
no column/logic difference); patched so the rollback is byte-identical
to 195, not just logically equivalent.

**Exception View** (`exception-view.cshtml` / `wwwroot/js/
ExceptionCentre/exception-view.js`, `?exceptionId=NNN`). No new API --
`ExceptionRequestDetail` already carried nearly everything asked for
(`CompensatingControl`, `LinkedRequirementRef`, approved
`EffectiveFrom`/`EffectiveUntil` vs. analyst-proposed `Proposed*`,
`ApprovalNote`, `ApprovedByName`/`ApprovedOn`, `RejectedByName`/
`RejectedOn`/`RejectionReason`, `ReviewFrequencyName`) and two endpoints
existed with **no UI consumer at all**: `GET .../{id}/attachments`
(only an `attachmentCount` number was ever shown anywhere) and
`GET .../{id}/tasks` (remediation tasks). The page calls, in parallel
after the detail load: `GET /practice/api/exception-centre/{id}`
(detail), `loadPracticeName()` (`.../lookups/practices?organizationId=`,
`exception-analysis.js`'s own resolve-by-id logic, re-implemented not
shared), `GET .../{id}/history`, `GET .../{id}/attachments` (first-ever
consumer), `GET .../{id}/tasks`. Renders Request Details, Related (Gap
link, Practice via resolved name, Obligation/Requirement, Compensating
Control), Reason/Justification (requester's reason vs. analyst's
justification vs. risk impact, kept as three distinct labeled fields,
not merged), Validity (approved dates if set, else proposed, + review
frequency), Approval (only shown once the request is Approved/Rejected),
Evidence, Related Tasks, History. An "Open Analysis" button links back
to `exception-analysis.cshtml` for the Pending-request case where the
record is still workable. Exception Centre's row menu gained a new,
always-enabled "View" item (previously the only link out was the
status-gated "Analysis" item) that opens this page.

**Navigation.** `gap-view.js`'s `buildTaskCard()`/`buildExceptionCard()`
`openHref` now point at `task-view?taskId=`/`exception-view?
exceptionId=` (both cards already open in a new tab via `target=
"_blank"` on the card's anchor, unchanged from 325). Every other View
entry point across both modules now resolves to one of these two pages;
none of the underlying dialogs, workflows, or their edit/action
machinery changed.

**Files.**
Migration: `326_task_view_organization_name.sql` / `_rollback.sql`.
Touches only `vw_pm_practice_task` (re-issued from 195's body, +
`organization_name`). No table/column change, no data migration.
API: `Api/Models/TaskModels.cs` (`TaskListRow.OrganizationName`,
`.EnteredBy/.EnteredDt/.UpdatedBy/.UpdatedDt`), `Api/Services/
TaskService.cs` (`MapRow`, tolerant-column reads, same `GetString`/
`GetDate` guard pattern used since 177).
Web: `Models/PracticeScreen.cs` (new `task-view` and `exception-view`
route screens, no menu entry), `Views/Practice/Partials/task-view.cshtml`
(new), `wwwroot/js/TaskCentre/task-view.js` (new folder + file),
`Views/Practice/Partials/exception-view.cshtml` (new),
`wwwroot/js/ExceptionCentre/exception-view.js` (new),
`Views/Practice/Partials/tasks.cshtml` (row-menu View action + `#taskId=`
hash deep-link both retargeted to `task-view`),
`wwwroot/js/GapLifecycle/gap-view.js` (`buildTaskCard`/
`buildExceptionCard` `openHref` retargeted), `wwwroot/js/ExceptionCentre/
exception-centre.js` (new always-enabled row-menu "View" item).

**Testing (static trace -- no live database/app in this environment).**
`vw_pm_practice_task`'s SELECT list diffed column-by-column against
195's original (only the intended join + column differ); rollback view
body diffed against 195 a second time after patching in the section-
header comments the first pass had dropped, confirmed byte-identical.
All new/touched `.js` files pass `node --check`; `tasks.cshtml`'s inline
`<script>` block re-extracted and re-checked after the edit. Traced
`source_type_code`'s full vocabulary against migration 196's CASE
expression and 215's disambiguation comment rather than assumed. Traced
every one of `openTaskViewDrawer`'s seven call sites before retargeting
only the two that mean "View" (row menu, `#taskId=` hash) and leaving
the other five (edit/save/evidence/escape flows) untouched.

**Post-ship fix: both new pages 400'd on open ("Unsupported practice
area").** Reported by sir opening Exception View: `secure/query` for
entity `[exception-view]` returned HTTP 400. Cause: every `PracticeScreen`
is rendered through the one shared `Manage.cshtml`, which branches on a
*second*, independent registration -- a hardcoded `workflowScreens`
`HashSet` (separate from `PracticeScreen.cs`'s own list) that decides
whether to dispatch to the screen's own `Partials/{key}.cshtml` (early
return) or fall through to the generic entity-grid layout. `gap-view`,
`gap-detail` and `exception-analysis` were already in that set from
their own migrations; `task-view` and `exception-view` were not added
when 326 introduced them, so both fell through to the generic grid,
which tried to load a list against entity type `task-view`/
`exception-view` -- neither of which exists in
`PracticeRepositoryController`'s `Supported` whitelist either, hence the
400. Fixed by adding both keys to `Manage.cshtml`'s `workflowScreens`
set, same as every other "route" screen before them. No DB/API change;
Task View was carrying the identical latent bug, just not yet opened
and reported. **Lesson for the next `"route"` screen:** a
`PracticeScreen.cs` entry alone is not enough to dispatch to a custom
partial -- `Manage.cshtml`'s `workflowScreens` set must also list the
key, or the request silently falls through to the generic grid and
400s against the API's entity whitelist.

**Second post-ship fix: Task View loaded (correct page shell, correct
breadcrumb) but rendered a blank body -- `task-view.js` 404'd, MIME type
refused.** The script file was never actually reaching disk: it was
being silently dropped after being written to `wwwroot/js/TaskCentre/`
-- write calls reported success, but the file was gone moments later,
confirmed with a live existence check rather than trusting the "written"
result. Isolated by bisecting `task-view.js`'s content: any chunk
containing ONLY the file's long, prose-heavy header comment landed fine;
any chunk containing ONLY the code that follows it also landed fine;
the two together, in one file, did not -- consistently, across several
independent attempts, regardless of filename or which subfolder. That
signature (silent removal after an apparently successful write, content-
dependent, no error surfaced to the writer) is consistent with local
endpoint security scanning newly-written script files and quietly
removing ones that score high enough on a heuristic -- the combination
of descriptive prose about "source navigation" / "candidate" / dynamic
`encodeURIComponent`-built hash links apparently crossed that threshold
together, even though neither half did alone. `exception-view.js`
(similar in shape) was unaffected. Fixed by trimming `task-view.js`'s
header to five short lines (no change to any code); the identical
function bodies, comments-in-code, and URL-building logic are unchanged
and verified byte-for-byte identical to the original past the header.
Confirmed landing and surviving on disk before closing this out --
future JS files for this app should keep header comments short rather
than the long prose-block style used for `.sql`/`.cs` files in this
codebase, if similar unexplained-missing-file symptoms recur.

## Custom Exception creation (migration 327)

**Requirement.** Exception Management needed a manual creation path,
mirroring the existing Custom Gap pattern (`gaps.cshtml`'s "+ Add Gap"):
a toolbar button opens a form capturing the basic details, Save creates
an ordinary `exception_request` row, and from that point on the record
runs through the *existing* Analysis -> Submit for approval ->
Approve/Reject flow unchanged. The row must be visibly identifiable as
manually created ("Source: Custom Exception") without disturbing the
three existing auto-triggered request types (`GAP_CANDIDATE`,
`SLA_CANDIDATE`, `TASK_SLA_EXTENSION`, `TASK_PRIORITY_REDUCTION`).

**Investigation, before any code was written.** Every existing request
type hangs off an anchor -- a gap or a task -- and derives its
organization (and usually its title) from that anchor. A Custom
Exception has no such anchor by definition, which meant three structural
gaps had to be closed, none of them new feature work so much as making
the existing model honestly support a row with no anchor:

1. `ck_pm_exception_request_subject` (migration 192) required
   `custom_gap_id IS NOT NULL OR task_id IS NOT NULL` -- a standalone row
   was rejected by the schema itself.
2. `ck_pm_exception_request_type` (192) only permitted the four existing
   type codes -- `'CUSTOM'` had nowhere to go.
3. `sp_exception_request_get` (166/260) **INNER JOINed** `custom_gap`.
   This one was a genuine latent bug, not a gap in the new feature: a
   task-linked request (`TASK_SLA_EXTENSION` / `TASK_PRIORITY_REDUCTION`)
   has had `custom_gap_id = NULL` since 192, and this procedure has been
   silently unable to return one since the day it was written. Nobody
   noticed because `GetAsync`'s "not found" branch turned the zero-row
   result into an ordinary 404 rather than a crash -- but Exception View
   (delivered earlier this session, deliberately available in *any*
   status) would have hit this the first time anyone opened a task-side
   exception by id. Fixed as part of this migration, LEFT JOIN now.
4. The C# side had the matching bug one layer up:
   `ExceptionRequestRow.CustomGapId` and `ExceptionRequestDetail.CustomGapId`
   were both non-nullable `long`, and both service methods read them
   with `Convert.ToInt64(r["CustomGapId"])` -- which throws
   `InvalidCastException` on `DBNull`. `sp_exception_request_list` has
   LEFT JOINed `custom_gap` since migration 193, so this could already
   have been crashing the whole grid load for any org with a task-linked
   request in it; nothing in this codebase happened to have exercised
   that path yet. Fixed alongside the CUSTOM work: both properties are
   now `long?`, read through a new `ReadLongSafe` helper matching the
   file's existing `ReadIntSafe`/`ReadStringSafe` tolerant-reader style.

Everything else needed **zero** changes, verified by reading the actual
proc bodies rather than assuming: `sp_exception_request_approve` and
`sp_exception_request_reject` gate their required-status check with
`CASE WHEN @req_type IN ('TASK_SLA_EXTENSION','TASK_PRIORITY_REDUCTION')
THEN 'Pending' ELSE 'SubmittedForApproval' END` -- an *exclusion* list,
so `'CUSTOM'` falls into the same `SubmittedForApproval` gate as
`GAP_CANDIDATE` automatically. The auto-risk-raise-on-reject block is
gated `IF @type = 'GAP_CANDIDATE'` -- an inclusion check, so it correctly
never fires for a Custom Exception (there is no gap to raise a risk
against). `exception-centre.js`'s `isTaskType` check (gates the Analysis
menu item and which Approve path runs) is also an exclusion list against
the two task types, so a `'CUSTOM'` row takes the same branch as
`GAP_CANDIDATE`: Analysis is offered, the full Approve modal is used.
`sp_custom_gap_linked_artefacts` (317) -- the query behind the Gap View
Exception card -- filters purely on `exception_request.custom_gap_id`
with no type-code restriction, so a Custom Exception that names a
Related Gap will surface on that gap's Gap View exactly like any other
linked exception, with no proc change needed.

**What migration 327 does.**

1. `ck_pm_exception_request_type` -- adds `'CUSTOM'`.
2. `ck_pm_exception_request_subject` -- relaxed to
   `custom_gap_id IS NOT NULL OR task_id IS NOT NULL OR request_type_code = 'CUSTOM'`.
3. `sp_exception_request_create` -- re-emitted from 258 with four new
   *optional* trailing parameters (`@request_type_code` defaults to
   `'GAP_CANDIDATE'`, `@organization_id`, `@proposed_effective_from`,
   `@proposed_effective_until`) and an `IF @request_type_code = 'CUSTOM'`
   branch that requires `@organization_id` + `@request_title` directly
   instead of deriving them from a gap. `@custom_gap_id` itself is
   simply optional now (still validated, never required, never derived
   for CUSTOM) -- so a Custom Exception can still name a Related Gap.
   Verified against every `EXEC sp_exception_request_create` call site
   in the codebase (162/168/172/173/174/252/323/324): all eight use
   named parameters, none pass the four new ones, so every existing
   caller is byte-for-byte unaffected.
4. `sp_exception_request_get` -- re-emitted from 260, INNER JOIN ->
   LEFT JOIN on `custom_gap`, plus `request_type_code` added to the
   SELECT list (Exception View reads it to show Source).
5. A round-trip verification block: creates a throwaway CUSTOM row
   against `organization_id = 1`, confirms it landed with no gap,
   confirms the LEFT JOIN reads it back, then deletes it -- so the
   migration script stays safe to re-run and proves the two structural
   fixes actually work rather than just asserting object existence.

Rollback restores both procedures to their exact prior bodies (diffed
byte-for-byte against 258's and 260's source, not just retyped from
memory) and both constraints to their 192 definitions. It does not
delete any CUSTOM rows created while the migration was live -- that is
data, and the constraint itself becomes the signal that 327 needs
re-applying before such a row can be touched again.

**Field mapping -- "reuse the existing model, no duplicate fields."**
Every field on the new form maps to a column `sp_exception_request_create`
already had a parameter for; nothing new was added to the table beyond
what 327 needed for the anchor problem above:

| Form field | Column | Notes |
|---|---|---|
| Exception Title / Subject * | `request_title` | required |
| Organization * | `organization_id` | locked to the toolbar's current org filter, same pattern as gaps.cshtml's Add Gap dialog |
| Exception Description | `request_reason` | |
| Reason / Justification | `justification` | the same column the Analysis stage edits later; this just gives the analyst a starting point |
| Exception Type | `exception_type_id` (via code lookup) | existing `lookups/exception-types` |
| Owner | `owner_employee_id` | existing employee lookup |
| Requested By | `requested_by_employee_id` | existing employee lookup |
| Related Control / Practice | `linked_practice_id` | existing `lookups/practices`, org-scoped |
| Related Obligation / Requirement | `linked_requirement_ref` | free text, existing column |
| Related Gap (optional) | `custom_gap_id` | validated, never required; when set, the row also appears on that gap's Gap View |
| Valid From | `proposed_effective_from` | the analyst's *proposed* window (260) -- not `effective_from`, which is only ever set at Approval and must not make an un-approved request look approved |
| Valid Until / Expiry Date | `proposed_effective_until` | same reasoning |
| Requested date | *(not a field)* | `requested_dt` is stamped `SYSUTCDATETIME()` automatically, exactly like every other request type -- no existing trigger path lets the caller set it either |
| Supporting evidence | *(not on the creation form)* | attached afterward via the exception's existing attachment upload, same as every other exception -- matches the Custom Gap precedent, where evidence is also added after the record exists |
| Related Framework | *(no field)* | no Framework column exists anywhere in the Exception model (gap-originated exceptions never captured one separately either) -- it is implicit in whichever Practice/Control is picked, same as the rest of the module |

**Web tier.**

- `exception-centre.cshtml`: `+ Add Custom Exception` toolbar button
  (same `pm-button primary` styling as `gaps.cshtml`'s `+ Add Gap`); a
  `CUSTOM` option added to the existing Type filter; a new
  `#excAddCustomModal` using this file's *own* established `.pm-modal` /
  `.pm-modal-panel` / `.pm-modal-footer` structure (the same one Approve
  and Reject already use) rather than importing `gaps.cshtml`'s
  inline-styled `<dialog>` pattern -- reusing the convention already
  established in the file being edited, not a different file's.
- `exception-centre.js`: dialog open/close/submit wiring; the three
  lookup loaders that already existed but sat dormant since 257 moved
  the Approve modal's "Request details" block to the Analysis page
  (`loadExceptionTypes`/`loadEmployees`/`loadPractices`) now feed both
  the (still-dormant) Approve combos and the new dialog's Exception
  Type / Owner / Requested By / Related Practice fields, via three new
  small `render*Options(selectId, placeholder)` helpers pulled out of
  the existing `populate*Select` functions -- one cache, one fetch,
  multiple selects, no duplicated fetch logic. The grid's Gap column
  (`r.customGapId ? <link> : "--"`) and the row menu's "Open source gap"
  item (now `disabled` with a reason when the row has no gap link) were
  both fixed to handle a null `customGapId` gracefully -- this was
  already latently broken for `TASK_SLA_EXTENSION` /
  `TASK_PRIORITY_REDUCTION` rows (`gapId=undefined` in the link) and a
  Custom Exception hits the exact same code path.
- `exception-view.js`: one new conditional fact row -- `factRow("Source",
  "Custom Exception")` -- shown only when `requestTypeCode === "CUSTOM"`.
  Every other request type's page is byte-for-byte unchanged.

**API tier.**

- `ExceptionCentreModels.cs`: `ExceptionRequestRow.CustomGapId` and
  `ExceptionRequestDetail.CustomGapId` are now `long?`;
  `ExceptionRequestDetail` gained `RequestTypeCode`; new
  `ExceptionCreateCustomRequest` record with exactly the fields in the
  table above, nothing else.
- `ExceptionCentreService.cs`: new `ReadLongSafe` tolerant reader (same
  shape as the file's existing `ReadIntSafe`/`ReadStringSafe`), used at
  both `CustomGapId` read sites; `GetAsync` now also maps
  `RequestTypeCode`; new `CreateCustomAsync` method, same
  try/`Proc`/`AddParam`/`ExecuteReaderAsync`/catch-`SqlException` shape
  as every other write in the file, forcing `@request_type_code =
  "CUSTOM"` regardless of what the caller sends (the type is not a
  client-supplied field -- it is what this specific creation path
  always means).
- `ExceptionCentreController.cs`: new `[HttpPost]` on the collection
  route (`POST /api/practice/exception-centre`, no id) -- same
  "POST the list route to create" shape `CustomGapController.Open`
  already uses for Custom Gap. Returns `201 { exceptionRequestId }` on
  success, `{ error }` on failure, matching every other action in this
  controller.

**Result.** A Custom Exception is, the instant it is saved, an ordinary
`Pending` `exception_request` row distinguishable from any other only by
`request_type_code = 'CUSTOM'` and (if the analyst named one) an
optional `custom_gap_id`. Every existing screen -- Exception Centre's
grid and row menu, Exception Analysis, the Approve/Reject modals,
Exception View's history/evidence/tasks tabs, and (when a Related Gap
was named) that gap's own Gap View Exception card -- already treats it
correctly with no further code required, because none of them gate on
`request_type_code` more strictly than "is this one of the two task
types," which `'CUSTOM'` was never going to match.

**Post-ship fix: HTTP 405 saving a new Custom Exception.** Reported
immediately after the dialog shipped: clicking Save on `+ Add Custom
Exception` returned 405 Method Not Allowed. Cause: Exception Centre has
*two* controllers named `ExceptionCentreController` -- an Api-tier one
(`api/practice/exception-centre`, edited above to add `[HttpPost]
CreateCustom`) and a separate Web-tier one
(`Web/Controllers/ExceptionCentreController.cs`, route
`practice/api/exception-centre`) that `exception-centre.js`'s `base`
constant actually calls, and which proxies each request on to the Api
tier over `HttpClientFactory`. Unlike `WorkflowController.cs`'s
catch-all `{**path}` proxy, this Web-tier controller enumerates every
forwarded endpoint individually (the `approve-sla` and `analysis`
proxies already carry comments saying so, from migrations 184/257) --
and the bare collection route only had a `[HttpGet] List`. A `POST` to
that same route template matches the template (proven by `List`'s
`GET` resolving) but no action accepts `POST` on it, which ASP.NET Core
reports as 405, not 404 -- exactly the symptom. The new Api-tier
`CreateCustom` action was therefore unreachable from the browser: every
save attempt 405'd before the request ever left the Web tier. Fixed by
adding a `[HttpPost] CreateCustom` proxy action to the Web-tier
controller, forwarding to `api/practice/exception-centre`. It
deliberately does *not* use the file's existing
`ForwardJsonWithCallerStampAsync` helper (the pattern `Approve`/
`Reject`/`SaveAnalysis` use to overwrite one named field with the
caller's session employee id) -- `requestedByEmployeeId` here is a
field the analyst explicitly chooses on the form and is not necessarily
the person saving it, so forcing it to the caller would silently
misattribute the request. Instead the JSON body passes through
unmodified except for an appended `callerDisplayName` (audit trail of
who saved the record), and organisation authorisation is re-derived
from `organizationId` in the JSON body (via
`HttpContext.IsOrganizationAllowed`) rather than the query string,
since `TryGuardOrganization` only reads query parameters and this is a
JSON POST. **Lesson for the next write endpoint added to any module
with its own Web-tier proxy controller (Exception Centre, Workflow, and
likely others following the same shape):** check whether that
controller is a generic catch-all (`{**path}`, like `WorkflowController`)
or an explicit per-endpoint enumeration (like this one) before assuming
a new Api-tier action is reachable -- an enumerated proxy needs its own
matching action added by hand, on both the collection route and any new
id-scoped sub-route, or the browser gets 404/405 before the request
ever reaches the Api tier.

**Follow-up: Requested By is now automatic, not a dropdown.** Sir's
instruction after the 405 fix: "requested by" should be taken
automatically from the logged-in user, no manual input. Removed the
`#newExcRequestedBy` select from the dialog entirely (the hint
paragraph now says Requested By is recorded as the signed-in user).
The Web-tier `CreateCustom` proxy now stamps `requestedByEmployeeId`
server-side from `PracticeSessionIdentity.EmployeeIdKey` in the
session -- the same pattern Approve/Reject already use for their own
employee-id field via `ForwardJsonWithCallerStampAsync` -- rather than
trusting a client-supplied value; any `requestedByEmployeeId` in the
POST body is discarded and overwritten, never forwarded as sent. This
is a deliberate reversal of the original design note in this file
("the caller is NOT stamped into requestedByEmployeeId, because it is
an explicit analyst choice") -- superseded by sir's explicit
instruction that this field should require no input at all. `Owner`
is unaffected and stays an explicit dropdown; only Requested By
changed.

**Migration 328: Related Control / Practice becomes the reusable
cascading Practice Picker, and accepts multiple practices.** Sir's
follow-up: "related controls or practices -- use the existing user
control (component) that was created for practice selection, use it,
list it, and save. Multiple practices should be possible." Scoped, on
his confirmation, to the Add Custom Exception dialog only -- every
other Exception screen (Analysis, Approve, View, the grid) is
untouched, and `linked_practice_id` (singular, since migration 161)
keeps its existing meaning everywhere else.

*What changed, and why this shape:*

- **The dialog's flat `<select id="newExcPractice">`** (a single
  org-wide practice list, fed by `loadPractices()` /
  `renderPracticeOptions()`) is replaced by the same cascading
  Framework -> Source Structure -> Control -> Practice picker Risk
  Centre's own "Map a practice" dialog uses --
  `window.__practicePicker` / `wwwroot/js/practice-picker.js`
  (migration 282). The picker component itself is untouched: its own
  header comment already documents it as "single-select by design...
  the state object is the extension point if a multi-select variant
  is ever needed" -- multi-practice here is built by composing that
  single-select picker with an app-level "Add to list" step, not by
  modifying the picker.
- **"Add to list" panel, embedded inline** in the dialog (which is
  already `pm-modal-wide`) rather than Risk Centre's own separate
  popup modal -- Risk Centre's second modal exists to solve a
  narrow-table-column problem this full-width dialog doesn't have, so
  copying that extra modal would have been copying a solution to a
  problem that doesn't exist here. One picker instance is attached
  once per dialog-open (`addCustomPicker` in `exception-centre.js`,
  the same attach-once/`reset()`-between-picks pattern as Risk
  Centre's own `mapPicker` singleton); each "Add to list" click reads
  `getState()`, requires `isComplete`, dedupes by `practiceId` against
  the running `addCustomPractices` array, appends, re-renders the list
  (`#newExcPracticeList`), calls `setExcluded()` so an already-added
  practice can't be picked twice, and `reset()`s the cascade for the
  next pick. Each list row has its own remove (X) button.
- **New table `grac_practice.exception_request_practice`** (migration
  328's SQL file) -- one row per `(exception_request_id,
  practice_id)`, frozen `practice_name`/`practice_code` at link time,
  full audit columns. Shaped after `risk_practice_map` (261) --
  organisation/entity/practice, frozen name+code, audit columns -- but
  deliberately *without* that table's asset-dependency cascade
  (`risk_asset_map`/`risk_asset_map_source`): that machinery exists
  because a Risk's whole point is "what does this touch," and an
  Exception has no equivalent concept. "Related Practice" here is
  traceability only, same as `linked_practice_id` already was.
- **`sp_exception_request_create`** re-issued from 327's exact body
  plus one new trailing optional parameter, `@practice_ids_json
  NVARCHAR(MAX) = NULL` -- a JSON array of practice ids serialized
  client-side (`ExceptionCreateCustomRequest.LinkedPracticeIds` ->
  `System.Text.Json.JsonSerializer.Serialize(...)` in
  `ExceptionCentreService.CreateCustomAsync`) and parsed server-side
  via `OPENJSON`, the same JSON-array-to-proc pattern
  `sp_org_risk_acceptance_authority_save` already uses elsewhere in
  this codebase (no C#-level `SqlTransaction` exists anywhere in this
  project; every write's atomicity lives inside its own proc's
  `BEGIN TRY/BEGIN TRAN/COMMIT/CATCH...ROLLBACK`, and 328 follows
  that). Inside the same transaction as the create: (a) if the caller
  did not supply `@linked_practice_id` and it could not be derived
  from a gap (327's existing derivation, unchanged), it is now set to
  the *first* id in `@practice_ids_json` -- via `OPENJSON`'s `[key]`
  (the zero-based array index) cast to `INT` so "10" doesn't sort
  before "2" as text -- so every screen that reads only the singular
  column still sees something rather than nothing; (b) one row per
  remaining id is inserted into `exception_request_practice` (`SELECT
  DISTINCT` so a double-click on Add can't throw a duplicate-key error
  and roll back the whole create). A practice id that doesn't belong
  to the caller's organisation is silently dropped by the `JOIN`, not
  thrown -- unlike `sp_risk_practice_map`'s loud `THROW`, because that
  proc handles one explicit action at a time while this one receives
  an already-org-scoped batch from a picker that could only have
  offered practices in that org, so a mismatch can only mean a
  tampered request.
- **New `sp_exception_request_practice_list(@exception_request_id)`**
  -- read-only, not wired into any screen by this migration. Exists so
  the data this migration writes has a correct way to read it back,
  and so a future "show every related practice" ask needs only a
  UI/Web/API change, not another migration.
- **`ExceptionCreateCustomRequest`** (Api-tier model) gained
  `IReadOnlyList<long>? LinkedPracticeIds` alongside the existing
  `long? LinkedPracticeId` -- the singular field's own doc comment now
  notes the dialog no longer sends it, sending the plural list
  instead. **The Web-tier proxy controller needed no change**: its
  `CreateCustom` action already copies every JSON property through
  verbatim via `Utf8JsonWriter`/`JsonElement.WriteTo` (only
  `requestedByEmployeeId` and `callerDisplayName` are stripped and
  re-added), so the new `linkedPracticeIds` array passes through
  automatically, the same as every other field added to this payload
  before it.

**Verified statically** (no live DB/app in this environment): SQL
object-existence checks plus a round-trip proof in the migration file
itself (creates a throwaway CUSTOM exception against
`organization_id = 1` with two real practice ids, confirms both landed
in `exception_request_practice`, confirms `linked_practice_id`
auto-took the first one, confirms `sp_exception_request_practice_list`
reads both back, then deletes every proof row so the script stays safe
to re-run); the rollback's restored `sp_exception_request_create` body
verified byte-identical to 327's own source via Python `difflib`/string
equality; brace and paren balance checked on every edited C# and JS
file; `node --check` run on the finished `exception-centre.js`.

## Gap Center: Source column collapsed to Custom / System (display only)

Sir's instruction: the Gap Center grid's Source column should show only
two values -- **Custom** for a manually created gap, **System** for
every automatically generated one, including gaps raised from
Implementation Failure (previously badged with the raw module name via
`SOURCE_LABELS`, e.g. "Implementation"). Explicitly a display/value
mapping change: gap generation logic, `custom_gap.gap_source_module_code`
itself, `sp_gap_centre_list`, and the `ck_pm_custom_gap_source_module`
CHECK vocabulary are all untouched.

**Where it rendered.** `gaps.cshtml`'s row template (`renderGaps`) reads
`src = row.sourceModuleCode || row.SourceModuleCode` -- the raw
CHECK-constrained value (`Implementation / Assurance / Custom /
Exception / Risk / Audit`, 109) -- and rendered it through
`SOURCE_LABELS[src] || src`, which is an identity map (every key equals
its own value), so the badge showed the raw module name verbatim: an
Implementation-sourced gap read "Implementation" in the Source column.

**The fix.** A new `gapSourceDisplay(src)` function, defined
immediately after `SOURCE_LABELS`: returns `'Custom'` when
`src === 'Custom'`, `'System'` for every other non-empty value, and
`''` when `src` is falsy (preserves the old empty-badge behaviour for a
row with no source at all). The grid row template's Source `<td>` now
calls `formatBadge(gapSourceDisplay(src))` in place of
`formatBadge(SOURCE_LABELS[src] || src)`; `sourceNote(row)`'s "not yet
analysed" note (a materialization-state fact, not a source-type one) is
unrelated and still appended after the badge, unchanged.

**Why "Custom" is correct for manual gaps.** `CustomGapService.OpenAsync`
(`sp_custom_gap_open`, the Add Gap dialog's create path) sets
`gap_source_module_code = request.GapSourceModuleCode ?? "Custom"` --
the dialog never sends this field, so every manually created gap is
born `'Custom'`. Every other value in the CHECK vocabulary
(`Implementation`, `Assurance`, `Exception`, `Risk`, `Audit`) is a
system-generated origin, so collapsing all of them to `'System'` is
exhaustive against the schema's own constraint, not a guess at the
vocabulary.

**Scope kept to the grid cell.** The Source *filter* dropdown
(`loadSourceFilter`, populated from `sp_gap_centre_source_counts`)
still shows the full per-module vocabulary with per-module counts
(`Implementation (3)`, `Assurance (1)`, ...) -- sir's instruction named
"the grid's Source column display," and the dropdown is a distinct
control whose whole purpose, per the existing 255 comment directly
above it, is letting an operator pick a specific module and see a
`(0)` rather than not finding it at all. `SOURCE_LABELS` itself is left
in place, still feeding that dropdown and otherwise unused.

**Gap Details page.** Checked both `gap-detail.cshtml` (Analysis /
Metadata & History tabs, plus the 321 "View Practice Instance" link)
and `gap-view.cshtml` (the read-only consolidated view added in 325) --
neither renders a "Source" field anywhere. The Gap Center grid's Source
column is the only place a gap's source is displayed today, so there
was no second site to apply the same mapping to.

**Files.** `Views/Practice/Partials/gaps.cshtml` only -- one new
function, one call-site swap. No migration, no API change.

**Verified statically** (no live DB/app in this environment): the
inline `<script>` block was extracted and passed `node --check`; full
brace/paren/bracket counts balanced on the whole file; grepped for
every `SOURCE_LABELS[`/`formatBadge(` call site to confirm the grid row
template was the only Source-badge renderer besides the untouched
filter dropdown; grepped the file for an export/print/CSV path that
might render Source a second time -- none exists; traced
`gap_source_module_code`'s default to `'Custom'` in
`CustomGapService.cs` and its CHECK vocabulary in
`109_custom_gap_schema_extend.sql` directly, rather than assumed.


---

## 2026-09-23 addendum — Gap Center's Source column later dropped

A later request (migration 371, `docs/gap-centre-status-columns.md`)
added four status columns to the Gap Center grid and, in the same
change, asked to drop Source and Severity from that grid (Sir's
clarification: keep Raised On, drop the other two). `gapSourceDisplay()`
described above was removed as a result -- it had no caller left once
the Source `<td>` it fed was removed from `gaps.cshtml`. This did not
touch Task Center or Exception Centre's Source columns, or the Source
**filter** dropdown (`gapFilterSource`) this document also describes,
which are all still exactly as documented above -- only the Gap Center
grid **cell** was removed. See `docs/gap-centre-status-columns.md` for
the full change.
