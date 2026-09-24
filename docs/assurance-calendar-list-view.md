# Assurance Calendar -- List View

The Oversight → Assurance Calendar screen (`Views/Practice/Calendar.cshtml`,
`wwwroot/js/practice-calendar.js`, `wwwroot/css/practice-calendar.css`) gained
a second display mode alongside the existing Month/Week/Day grid: a
date-wise **List View**, toggled with a **Calendar | List** switch in the
toolbar (`#calModeToggle`).

## No API or database change

List View reuses the exact same data the grid already loads --
`POST {api}/assurance-calendar-events/query`, served by
`PracticeRepositoryService.QueryCalendarEventsAsync` (`PracticeManagement.Api`).
That endpoint's request/response contract, the underlying tables it reads
(`assurance_schedule_rule`, `assurance_schedule_override`, `practice_instance`,
`org_assurance_plan[_item]`, `org_assurance_execution`,
`org_assurance_observation`, `custom_gap`), and every filter it accepts
(`sourceModules`, `statuses`, `criticalities`, `ownerRoleId`,
`ownerEmployeeId`, `definitionIds`, `search`) are all unchanged.

Switching Calendar ↔ List never issues a second fetch. `currentMode`
("calendar" | "list") is orthogonal to `currentView` ("month" | "week" |
"day", which still drives what date range is loaded); `render()` always
reads from the one `events` array populated by `loadCalendarEvents()`. This
is why the two views can never show different data -- there is only one
in-memory event set, rendered two ways.

## "Task ID" column

The calendar events endpoint does not return a single universal task
identifier -- each of the six source modules (Practice Instance schedule
occurrence, Assurance Plan, Plan Item, Execution, Observation, Assurance-
sourced Gap) has its own primary key, already present on every event object
as `SourceRefId` (the five Assurance modules) or `RuleId` /
`PracticeInstanceId` (Practice Instance occurrences).

`eventRefCode(ev)` in `practice-calendar.js` formats that existing id as a
short reference code for the List View's Task ID column, e.g. `PLN-12`,
`ITM-45`, `EXE-77`, `OBS-9`, `GAP-31`, `PI-482`. It is a display-only
label computed from data the endpoint already returns -- nothing new is
stored, and no `task` table or task-numbering scheme was introduced.

## Linked Task Centre task id

`eventRefCode` (above) is a display-only reference synthesized from data the
endpoint already had. Separately, when a scheduled item has actually
**generated a real Task Centre task**, the List View now also shows that
task's real `task_number` and links straight to it -- this is what the
request meant by "if a task has been generated, its task id should be
displayed too."

Per `docs/task-centre-v2.md` ("Sources wired"), only two of the six source
modules ever reach Task Centre:

- **Assurance Gap** -- `sp_task_open`'s `source_type_code` derivation
  (`database/196_task_centre_v2_open.sql`) maps `subject_entity_type =
  'CustomGap'` to `source_type_code = 'Gap'`, with `source_record_id` equal
  to the same `custom_gap_id` already carried on the event as `SourceRefId`
  (confirmed against `sp_custom_gap_task_create`,
  `database/253_gap_task_direct_and_task_centre_visibility.sql`).
- **Assurance Observation** -- reaches Task Centre only through the
  candidate-approval stage: `sp_org_assurance_observation_accept`
  (`database/199_task_candidate_sources.sql`) raises a candidate with
  `source_type_code = 'ContinuousAssurance'` / `source_record_id =
  observation_id`, and `sp_task_candidate_approve`
  (`database/198_task_candidate_procs.sql`) passes both values straight
  through to `sp_task_open` once approved.

Plan / Plan Item / Execution / Practice Instance events have no Task Centre
source wired at all, so nothing is looked up for them -- the "Task" badge
and detail row simply don't appear.

Both cases key on exactly the id already used as `SourceRefId`, so no new
identifier scheme was needed. `QueryCalendarEventsAsync`
(`PracticeManagement.Api/Services/PracticeRepositoryService.cs`) collects
the distinct Gap and Observation ids present in the merged event list and
runs one batched query against `grac_practice.vw_pm_practice_task` -- the
same read view `sp_task_list` / `sp_task_get` / `sp_task_source_tasks`
already use -- filtered to `parent_task_id IS NULL` (top-level tasks only;
child/sub-activity tasks inherit their parent's source stamp and would
otherwise collide with it in the lookup) and matched on
`(source_type_code, source_record_id)`. Matching events are stamped with
four additional fields:

| Field                | Meaning                                              |
|-----------------------|------------------------------------------------------|
| `LinkedTaskId`        | `practice_task.task_id` (numeric)                    |
| `LinkedTaskNumber`     | `practice_task.task_number` (human-readable code)     |
| `LinkedTaskStatus`     | current task status name                              |
| `LinkedTaskDeepLink`   | `/Practice/Index/tasks#taskId={LinkedTaskId}`         |

This lookup is wrapped in the same graceful-degradation `try/catch` pattern
the other five source-module queries in this method already use: if it
fails (e.g. an out-of-date environment missing the view), the calendar
still renders, just without the linked-task badge.

On the frontend, `renderList()` shows a small "Task &lt;number&gt;" pill
under the title (`.cal-list-item-task-link`) only when `LinkedTaskNumber` is
present, opening `LinkedTaskDeepLink` in a new tab -- the same deep-link
convention already used by `Views/Practice/Partials/tasks.cshtml` for
Gap View → Task Center hand-off. `showSidePanel()` mirrors the same
information as a "Task" detail row plus an "Open Task" action, next to the
existing "Open in &lt;module&gt;" link.

No database or API contract change was needed for this either -- it is an
additional read (existing view, existing ids), not a new endpoint.

## Why not `pm-grid.js` / the standard DataTables grid

Every other Practice Management list screen (Task Center, Gap Center, ...)
renders through the shared `pm-grid.js` component, which does its own
server-side paged fetch. The Calendar page does not use it, and List View
does not either: `pm-grid.js` would issue an independent query, which is
exactly the "separate scheduling mechanism" the feature request asked to
avoid, and would risk Calendar and List drifting apart if their two
underlying fetches ever returned different rows (different filters, a race
between refreshes, etc.). Rendering List View from the same in-memory
`events` array the grid uses guarantees they always agree.

## What did change

**Round 1 (initial List View):**

- `Views/Practice/Calendar.cshtml` -- added the Calendar/List toggle
  (`#calModeToggle`) and a new `#calListView` container beside `#calGrid`,
  inside the existing `pm-panel pm-calendar-container` section so the
  toolbar, unified filters and legend stay shared between both modes.
- `wwwroot/js/practice-calendar.js` -- added `currentMode` state,
  `setMode()`, `updateTitle()` (title logic pulled out of
  `renderMonth`/`renderWeek`/`renderDay` so List View doesn't duplicate
  it), `renderList()`, and small shared helpers (`sourceModuleOf`,
  `sourceLabelOf`, `ownerLabelOf`, `eventRefCode`, `formatListDate`).
  `showSidePanel()` was refactored to call the same `sourceModuleOf` /
  `sourceLabelOf` / `ownerLabelOf` helpers instead of its own inline
  copies, so List View's Type/Owner columns and the side panel's Type/
  Owner rows can never disagree. Clicking a List row opens the same side
  panel Month/Week/Day already use (same Edit Schedule / Open-in-module
  actions -- nothing new there either).
- `wwwroot/css/practice-calendar.css` -- extended the existing
  `.cal-view-toggle` button-group selectors to also style
  `.cal-mode-toggle` (one visual definition, two toggle groups), and added
  a `List View` rule block that reuses the existing `.pm-empty` empty
  state and `.cal-side-source-badge source-*` module-color pill rather
  than introducing new ones.

**Round 2 (alignment / wasted space + linked Task Centre id):**

- `wwwroot/css/practice-calendar.css` -- `.cal-list-view` was
  `max-width: 900px; margin: 0 auto`, a constraint copied from `.cal-grid`
  where it exists only to keep the month grid's day cells square. List
  View is a list, not a grid of cells, so that cap just left empty space
  down both sides. Changed to `width: 100%` so the list uses the same
  width as the toolbar/filters/legend above it, giving the Task/Description
  column the extra room. Also added `.cal-list-item-task-link` (the small
  "Task &lt;number&gt;" pill described above), styled from the same
  blue/pill language as the existing `.cal-side-deep-link` action button,
  scaled down to sit under a row's title.
- `PracticeManagement.Api/Services/PracticeRepositoryService.cs` --
  `QueryCalendarEventsAsync` gained the "Linked Task Centre tasks" block
  described above: one extra batched `SELECT` against
  `grac_practice.vw_pm_practice_task`, run after the merged-list filters
  and before the calendar-config fetch, stamping `LinkedTaskId` /
  `LinkedTaskNumber` / `LinkedTaskStatus` / `LinkedTaskDeepLink` onto
  matching Gap/Observation events. Wrapped in the same per-source-module
  `try/catch` graceful-degradation pattern already used by the rest of the
  method.
- `wwwroot/js/practice-calendar.js` -- `renderList()` now renders the
  `.cal-list-item-task-link` pill under an item's title when
  `LinkedTaskNumber` is present (with its own click handler calling
  `stopPropagation()` so opening the task doesn't also pop the row's side
  panel), and `showSidePanel()` gained a "Task" detail row plus an
  "Open Task" action reusing the existing `.cal-side-deep-link` pattern.

No files under `database/` changed in either round -- there was no schema
or stored procedure to touch. Round 2's backend change is a new read
against an existing view (`vw_pm_practice_task`), not a new table, column,
or procedure.

## Update (migrations 336-339): per-obligation schedule rules

This round changes the model behind the "Practice Instance" side of the
calendar, so a few statements above are now superseded -- read this section
as the current behaviour.

### The model

The calendar's non-Assurance-module occurrences used to be one instance-wide
"Practice Instance" stream, driven by a single instance cadence (the
Assurance-only `vw_pm_instance_effective_assurance_frequency`, migration
237). The cadence now belongs to each **obligation**: only **Execution** and
**Assurance** (Scheduled-trigger) obligations carry a recurring frequency,
so each such obligation on an instance gets its own schedule stream. State,
Evidence, Event Response, Constraint and Retention obligations never
schedule; an Event-Driven Assurance obligation has no cadence and is
excluded too.

### Schema and procedures

- **336** -- `assurance_schedule_rule` becomes per-obligation: adds
  `practice_instance_obligation_id` (FK) and `schedule_kind`
  (`Execution` | `Assurance`); drops `UNIQUE(practice_instance_id)` for a
  filtered `UNIQUE(practice_instance_obligation_id)` so one instance can own
  several active streams. Legacy instance-wide rows keep working (NULL
  obligation id, stamped `schedule_kind = 'Assurance'`).
- **337** -- `vw_pm_instance_schedulable_obligations`: one row per
  (instance, obligation) that is Execution/Assurance and resolves to a
  periodic frequency, with the resolved frequency (pio override → typed
  detail → published spec, mirroring 237's precedence, per type).
- **338** -- `sp_pm_sync_instance_schedule_rules(@practice_instance_id,
  @actor, @anchors_json)`: upserts one active rule per schedulable
  obligation for an instance, retires rules whose obligation is no longer
  schedulable, and stores per-obligation first-occurrence anchors on the
  new `practice_instance_obligation.first_occurrence_date`. Idempotent.
- **339** -- `sp_pm_reconcile_schedule_rules(@organization_id, @actor)`:
  bulk backfill that runs 338 for every instance with a schedulable
  obligation. Run once after deploy to bring in obligations adopted before
  this feature: `EXEC grac_practice.sp_pm_reconcile_schedule_rules;`

### API

- The schedule streams are created/updated **automatically after obligation
  adoption**, not by a manual action:
  `ResolveWorkspaceService.AdoptObligationsAsync` and
  `SaveLocalObligationAsync` call `SyncScheduleRulesForInstanceAsync`
  (→ 338) right after the existing gap sync, best-effort.
- `ResolveObligationDecision` gained an optional `FirstOccurrenceDate`
  (bound from the Operationalize card's "First occurrence" date input,
  shown under the frequency for Execution and Scheduled-Assurance
  obligations). It is carried to the sync proc as the stream anchor, not to
  `sp_resolve_obligation_adopt`. Blank = new stream starts today / existing
  stream keeps its anchor.
- `QueryCalendarEventsAsync` now joins the obligation, emits `ScheduleKind`
  / `ObligationId` on each occurrence, and types every schedule occurrence
  by its kind -- `SourceModule` is **`Execution`** or **`Assurance`**, never
  `PracticeInstance`. The old instance-level auto-generate block (which
  invented untyped PracticeInstance occurrences for instances without a
  rule) was **removed**: the calendar is purely rule-driven now.

### Frontend

- The Modules filter now offers **Execution** and **Assurance** (the
  obligation streams) in place of "Practice Instance"; the five
  Assurance-Management modules stay, with `AssuranceExecution` relabelled
  **"Audit Execution"** to avoid the name clash. Colours: Execution = GRAC
  blue, Assurance = green. The `pmCalFilters` localStorage key was bumped to
  `v2` so a stored v1 module list does not hide the new types.
- The manual **Generate Schedules** button and dialog were **retired**
  (they created instance-wide rules, the wrong shape now). Backfill is 339;
  new streams are automatic on obligation save.

### Supersedes above

The earlier "No API or database change" and "Task ID ... `PI-482` /
Practice Instance occurrences" notes describe the pre-336 model. Task IDs
for schedule occurrences now read `EXE-<ruleId>` / `ASR-<ruleId>`; the
`sourceModules` filter vocabulary is Execution / Assurance / AssurancePlan /
AssurancePlanItem / AssuranceExecution / AssuranceObservation /
AssuranceGap.

---

## Update (migration 336-340 follow-up): single-type scope + Scheduler List

### Scope narrowed to the two obligation streams

This screen is now purely the **audit-schedule** calendar. It shows only the
**Execution** and **Assurance** obligation schedules — the five
Assurance-Management modules (Plan / Plan Item / Audit Execution /
Observation / Gap) no longer appear here.

- The **Modules selector was removed** from the filter panel. The
  source-module scope is fixed in `practice-calendar.js`
  (`const CALENDAR_MODULES = ["Execution","Assurance"]`) and always sent on
  every query, so the API's five Assurance-Management blocks short-circuit
  (their `WantsModule` gate is false) — **no backend query change** was
  needed. Only Status / Criticality / Search remain as user filters.
- `sourceModules` was dropped from the persisted filter state; the
  `pmCalFilters` localStorage key was bumped to **`v3`** so a stored v2 set
  carrying the old module list is discarded.

### List view replaced by the **Scheduler List**

The date-wise "List View" (a re-presentation of the occurrence `events`) was
**replaced** by a **Scheduler List**: one distinct row per *configured
schedule rule*, not per occurrence.

- **Columns:** Obligation Name · Type (Execution / Assurance) · Frequency ·
  Owner · Next Schedule Date.
- **Source:** `rules` — the raw, org-scoped, date-range-independent
  `assurance_schedule_rule` rows already returned as `data[1]` by
  `QueryCalendarEventsAsync`. Every active scheduler appears exactly once,
  regardless of the Calendar view's month/week/day window. **No new
  endpoint, proc or data** — and **schedule generation is unchanged**; this
  is purely a presentation of existing scheduler data.
- **Next Schedule Date:** the first occurrence on/after today, computed in
  the browser from the rule's own `anchor_date` + frequency via
  `advanceByFrequency()`, a direct mirror of the C# occurrence stepping
  (including `AddMonths`/`AddYears` end-of-month clamping). Non-periodic
  rules (Event Driven / Continuous / Custom) or ended rules show `—`.
- **Owner precedence:** `schedule_owner` → obligation `responsibility` →
  instance `primary_owner`. (`pio.responsibility` was added to the rule
  query SELECT to supply this.)
- **Search + pagination:** client-side over the rule set — a search box
  (obligation / type / frequency / owner) and a Prev/Next pager
  (15 rows/page) — rendered with the app's standard `.pm-table` /
  `.pm-table-wrap` grid so it matches every other data grid.
- The event-oriented **Status / Criticality / Search filter panel is hidden
  in List mode** (it narrows occurrences, not scheduler config, and the
  rules query is org-scoped only), so it can't read as a dead control. The
  top-level **Calendar | List** switch and the org filter stay in both
  modes; **Month / Week / Day** stay hidden in List (they have no date grid
  to act on).

### Naming

The screen registry entry (`PracticeScreen.cs`) is titled **"Audit
Calendar"**, described as a calendar + per-schedule list, with summary
columns `Obligation / Type / Frequency / Owner / Next Schedule Date`.

---

## Update (2026-09-23): Edit Scheduler restricted to Execution Date only

### What changed

The Edit Schedule dialog (opened from the Calendar's side panel "Edit
Schedule" button, or the Scheduler List row menu's Edit action — both call
the same `openEditDialog()`) no longer offers **Skip This Occurrence**.
Move is the only action, so the Action select itself was removed; the
dialog now edits one field — **Execution Date** (the renamed "New Date").
Reason and "Apply to this and all future occurrences" are unchanged —
scoped out explicitly by the requester, not assumed.

**Backend enforcement, not just frontend hiding.** `sp_pm_schedule_override_repository_manage`
(migration 377) is a new gateway shim — same 7-parameter contract and
`ResolveProcedureAsync` routing mechanism 134/361/370 already established
for entity types whose SAVE logic needs to diverge from the
`dbo.pm_manage_practice_repository` monolith — that intercepts
`assurance-schedule-overrides` SAVE and hard-codes `override_type =
'Moved'`, ignoring whatever `overrideType` the request body claims. A
tampered or stale client posting `overrideType:'Skipped'` directly cannot
create a Skipped override; the restriction holds at the database, not only
in `practice-calendar.js`. The monolith's own `assurance-schedule-overrides`
branch (002) is untouched — an unapplied 377 just means the shim probe
finds nothing and saves fall back to the old, unrestricted behaviour.

**Daily-frequency occurrences lose the Edit Schedule action entirely.**
The dialog previously *forced* Skip for daily tasks ("tomorrow already has
its own daily occurrence, so moving today's slot forward would just
collide" — the code's own prior reasoning). With Skip gone, a daily
occurrence has no valid edit left, so `isDailyFrequency()` now gates the
button/menu-item at both entry points (side panel, Scheduler List row
menu) instead of forcing an action inside the dialog. This was not asked
for explicitly; it follows directly from the developer's own documented
reasoning for the pre-existing daily-task special case, rather than
leaving an Edit button open onto a dialog with nothing it can validly do.

### Obligation / Scheduler Details panel (new, read-only)

The dialog now shows, above the Execution Date field: **Obligation
Description, Action, Frequency, Owner, Execution Frequency, Evidence Type,
Evidence Details**. Sources, reusing existing data rather than teaching
the calendar query a new join:

- **Frequency** and **Owner** were already on every occurrence
  (`ev.FrequencyName`, `ev.Owner`) — no fetch needed.
- **Obligation Description, Action, Execution Frequency** come from a
  second, separate read: `GET .../resolve/instances/{practiceInstanceId}/obligations`
  (`ResolveWorkspaceController.ListObligations` → `sp_resolve_obligation_list`,
  the same endpoint `Shared/obligation-form.js` already reads for the
  Resolve Workspace / Practice View obligation cards), matched to this
  occurrence by `AdoptionId === ev.ObligationId` (`ev.ObligationId` is
  `practice_instance_obligation_id`, not the published `obligation_id` —
  same identity `QueryCalendarEventsAsync` has carried since migrations
  336-338). Action and Execution Frequency are parsed out of that row's
  `ExecutionSpecsJson[0]` with the same `normKey()` case/underscore-
  insensitive field match `obligation-form.js` itself uses, because **they
  only exist for Execution-kind occurrences** — an Assurance-kind
  obligation's typed detail is Verification Method / Assurance Frequency
  instead, and there is no "Action" field on it. Per the requester, those
  two rows are shown only when `ev.ScheduleKind === "Execution"`; an
  Assurance-kind occurrence shows Obligation Description / Frequency /
  Owner and omits the other two rather than mapping them onto a field that
  does not really mean the same thing.
- **Evidence Type / Evidence Details** come from the sibling
  `GET .../resolve/instances/{practiceInstanceId}/evidence` feed, filtered
  in the browser to rows whose `SourceObligationId` matches the obligation
  row's published `ObligationId`, or (for an organisation-defined
  obligation, which has no published id) whose
  `SourcePracticeInstanceObligationId` matches its `AdoptionId` —
  `ResolveWorkspaceModels.cs`'s own documented distinction between the two,
  not a new convention invented here.
- Both reads go through `WorkflowController`'s existing catch-all proxy
  (`practice/api/workflow/{**path}`), which forwards the request body
  verbatim — **no Web-tier controller change was needed** for this part
  (unlike Risk Centre's dedicated, non-wildcard proxy controller, this one
  is generic).
- **No new endpoint, procedure, or schema** for this panel — two existing
  reads, called a second time from a new caller. A daily double-click
  through the calendar is handled by comparing `dialog._eventData` after
  each `await`: a stale response for an occurrence the user has since
  clicked past is silently dropped, never rendered.

### View Practice (new)

A **View Practice** button in the dialog's action row (left-aligned via
`margin-right: auto`, separate from Cancel/Save) opens the same
`Practice/Index/practice-view` page every other "View Practice" link in
the app opens, reusing the existing `navigation-code` + encrypted
navigation-context flow (`PracticeManagementGatewayController.NavigationCode`
/ `.NavigationContext`, `IsAllowedNavigation`'s already-existing `{
FilterType: "Practice", TargetArea: "practice-view" }` rule — nothing
added there). `practice-calendar.js` runs in its own page and closure with
no access to `practice.js`'s `navigateWithContext`, so the same two calls
(POST `navigation-code`, then `window.location.assign`) are reproduced
locally — the existing precedent for this file, which already keeps its
own small copy of `buildAppUrl` rather than sharing one.

This needed one new, additive field: **`PracticeId`** was added to
`QueryCalendarEventsAsync`'s rule SELECT (`pi.practice_id`, alongside the
already-selected `practice_instance_id`) and carried onto every occurrence
dictionary as `PracticeId` / `PracticeInstanceId`, next to the existing
`PracticeInstance` label string. `schedulerRows()` and
`buildSchedulerRowMenu()` were extended the same way so a Scheduler-List-
opened dialog carries the same fields a Calendar-grid-opened one does
(`ObligationId`, `PracticeId`, `PracticeInstanceId`, `ScheduleKind`,
`Criticality`, `AssuranceMode` — all already present on the `rules` result
set's raw rows; nothing new was queried for these either). The button
hides itself when `PracticeId` is absent (an Assurance-Management deep
link occurrence never reaches this dialog in the first place, so this is
a defensive guard, not an expected path).

### Deliberately unchanged

- Reason, "Apply to this and all future occurrences", the save endpoint's
  URL and payload shape (`assurance-schedule-overrides`), `saveScheduleOverride()`,
  and the occurrence-computation logic in `QueryCalendarEventsAsync` are
  all untouched.
- The Calendar side panel's own "Skipped" status filter chip
  (`data-cal-chip-value="Skipped"`) is unrelated to this change — it
  filters the *display* of already-existing Skipped occurrences (which
  can still exist from before this change), not the Edit dialog's own
  capability, and was left alone.
- The `assurance-schedule-overrides` **QUERY** side (reading overrides
  into the calendar) is untouched — only SAVE is shimmed.


## Update (2026-09-23): Scheduler Edit Permission -- Practice Instance Owner only

**Request.** Only the Practice Instance Owner may edit a scheduler
(Execution Date change) from Task Calendar -- in both Calendar View (side
panel "Edit Schedule" button) and List View (row's 3-dot menu). A
non-owner must not see the Edit option at all, and the restriction must
hold at the backend/API level, not only by hiding it in the UI. The
existing Practice Instance Owner mapping (`practice_instance.primary_owner_id`)
must be reused -- no new owner field, no duplicated ownership logic.

### Which mapping was reused, and why

`practice_instance.primary_owner_id` already has one dominant, repeated
comparison pattern across this codebase: `@is_admin = 1 OR
pi.primary_owner_id = @caller_employee_id` (migrations 141, 145, 222, 236,
287, 290, 315 -- Resolve Workspace's own instance-ownership gate). That is
the pattern this change reuses, evaluated for one schedule rule's instance
instead of used as a list filter. It is a more direct comparison than
`QueryResolveFallbackAsync`'s older `@subject` (email/employee_code/
employee_name) text-matching form -- that form exists because `@subject`
was, at the time, the only reliably-available identity signal for that
particular fallback query. Here `_security.employeeId` (see below) is
already guaranteed present, so the newer, simpler, far more common
`primary_owner_id = @caller_employee_id` form is what was followed. A
system-admin bypass (`@is_admin = 1 OR ...`) was kept for the same reason
every one of those seven precedents keeps one -- consistency with "the
project's current... permission-handling pattern" -- even though the
request's own wording only names the Owner; this is disclosed here rather
than silently assumed.

### Backend enforcement (API tier, not just SQL)

`PracticeRepositoryController`'s `secure/query` and `secure/manage`
actions already inject a server-derived, non-spoofable `_security` object
into every payload before it reaches `PracticeRepositoryService`
(`AddServerSecurityContext` -- `isSystemAdmin`, `subject`, `employeeId`,
`dataScope`, `roleName`; `employeeId` is read from the session on the Web
tier, so a client cannot forge it). `PracticeRepositoryService.ExecuteAsync`
already runs several C#-level authorization gates ahead of the SQL
dispatch for other entity types -- most closely, Rule 5's employee-scope
guard for release/statement writes, keyed off `procedure` + `entityType`
and using this same `_security` data. The new gate follows that exact,
already-established shape rather than adding a second enforcement
mechanism inside the SQL shim:

- `ExecuteAsync` (`PracticeRepositoryService.cs`): a new block, gated on
  `procedure == "dbo.pm_manage_practice_repository"`,
  `entityType == "assurance-schedule-overrides"`, `action == "SAVE"`, and
  `!JsonSecurityIsSystemAdmin(payload)`. Resolves `scheduleRuleId` from
  the payload and `callerEmployeeId` from `_security.employeeId`
  (`JsonSecurityEmployeeId`), then calls the new `HasScheduleOwnershipAsync`
  helper; on a mismatch it returns `new(false, "Only the Practice Instance
  Owner can edit this scheduler.")` before `ResolveProcedureAsync`'s shim
  dispatch is ever reached -- so this holds regardless of what a client
  sends, exactly like the existing organization-access and Rule-5 checks
  it sits beside.
- `HasScheduleOwnershipAsync` (new, placed next to the existing
  `HasOrganizationAccessAsync` / `HasReleaseAccessAsync` /
  `HasStatementAccessAsync` family, same shape): one `EXISTS` query
  joining `assurance_schedule_rule` to `practice_instance` on
  `practice_instance_id`, testing `primary_owner_id = @employee_id` for
  the rule being saved.
- No SQL migration was needed -- no schema changed and no procedure was
  added or altered; `sp_pm_schedule_override_repository_manage` (377) is
  unchanged. This is a C#-level authorization gate reusing existing
  tables/columns, matching how Rule 5's equivalent checks already live in
  `ExecuteAsync` rather than inside a stored procedure.
- The **QUERY** side (`assurance-calendar-events`, i.e. what the Calendar
  and List views show) is untouched -- this restricts who may *save* a
  change, not who may *see* a scheduler. Visibility is unchanged.

### UI-side gating (Calendar View and List View)

`OwnerEmployeeId` is carried onto every Practice-Instance-sourced
occurrence the same additive way `PracticeInstanceId`/`PracticeId` were
added in the prior change -- it already existed as a field name on the
other five Assurance-module event blocks in the very same method
(`QueryCalendarEventsAsync`), so this reuses that existing convention
rather than inventing a new one. One new SELECT column,
`pi.primary_owner_id`, feeds it:

- `QueryCalendarEventsAsync`: `pi.primary_owner_id` added to the rule
  SELECT; a `ownerEmployeeId` local carries it onto all four occurrence
  shapes (Skipped / Moved / plain / Added) as `OwnerEmployeeId`. The raw
  `rules` result set (2nd table returned, `schedulerRows()`'s source)
  gets the column for free, since that loop copies every column generically.
- `PracticeController.cs`: a new `IsSystemAdmin()` helper (identical to
  `PracticeManagementGatewayController.IsSystemAdmin()` -- mirrored, not
  shared, matching how `Roles()` itself is already a small private
  per-controller helper here rather than a shared service method) plus
  `ViewBag.IsSystemAdmin = IsSystemAdmin();` next to the existing
  `ViewBag.EmployeeId` line, in both `ShowArea` and `ShowPracticeArea`
  (Calendar can be reached through either, depending on the screen's
  group).
- `Calendar.cshtml`: `window.pmEmployeeId` (the same convention
  `Manage.cshtml`/`practice.js` already use, just not previously emitted
  here since nothing on this screen needed it before) and
  `window.pmIsSystemAdmin`.
- `practice-calendar.js`: `isSchedulerOwner(ownerEmployeeId)` (system
  admin always passes; otherwise a string-normalized match against
  `window.pmEmployeeId`) gates, in addition to the existing screen-level
  `canEdit`:
  - the Calendar side panel's "Edit Schedule" button;
  - the Scheduler List row's Actions trigger cell (`renderList()`) --
    omitted from the row entirely for a non-owner, same as it is already
    omitted for a user without `canEdit`, so there is no empty menu to see;
  - `openEditDialog()` itself, as a defensive re-check (the same shape as
    its existing `isDailyFrequency` re-check) -- the dialog will not open
    for a non-owner regardless of which trigger point was reached.
  - `buildSchedulerRowMenu()`'s row-to-dialog object gained
    `OwnerEmployeeId: row.ownerEmployeeId` so that defensive re-check has
    what it needs when Edit is opened from the List.

### Deliberately unchanged

- Everything the prior change (Skip removed / Execution-Date-only /
  read-only Obligation & Scheduler Details / View Practice) put in place
  is untouched by this one -- the new checks are additive gates layered
  in front of an unmodified dialog and unmodified save shape.
- Calendar/List **visibility** of schedulers is unchanged for everyone;
  only the ability to reach and submit an edit is owner-gated.
