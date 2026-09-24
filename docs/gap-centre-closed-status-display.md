# Gap status display — Closed gaps must show Closed, not Analysed

**Sir's instruction:** gaps that are actually Closed were being displayed
with the status Analysed. When a gap is closed, the Gap Center grid, the
Gap View page and the Gap Detail page must all display its status as
Closed — trace the complete flow from database to frontend, correct the
underlying mapping/logic (not a frontend-only workaround), and leave every
other status (Candidate, Analysed, Invalid, Duplicate, etc.) and the
existing status workflow exactly as they are.

**Migration:** `379_gap_centre_closed_status_display.sql` (+
`_rollback.sql`)
**UI:** `wwwroot/js/GapLifecycle/gap-view.js` (`renderHeader`,
`renderFacts`), `wwwroot/js/GapLifecycle/gap-detail.js`
(`renderCompactStepper`)
**API:** no change — see "Why no API/model change" below.

---

## Root cause

A gap carries two independent fields:

- `custom_gap.status` — `Open` / `InProgress` / `Closed` / `Cancelled`,
  the record's own bookkeeping flag. The **only** thing that changes it
  when the Close Gap action is used is `sp_custom_gap_close` (055) —
  confirmed the only proc that action calls: `gaps.cshtml`'s 3-dot menu
  and `gap-view.js`'s Actions menu both call the shared
  `window.gracGapActions.closeGap` helper, which posts to
  `CustomGapController.Close` → `CustomGapService.CloseAsync` →
  `sp_custom_gap_close`.
- `custom_gap.lifecycle_state_id` → `gap_lifecycle_state_master.state_name`
  — where the gap sits in its *analysis* process. Migrations 174/175
  collapsed the active workflow down to `New` / `Delegated` ("Analysed")
  / `Invalid` / `Duplicate`; `ResolutionPlanning` / `Execution` /
  `Verification` / `Closed` remain seeded in the master table (272) but no
  code path in the current, simplified workflow ever moves a gap into
  them.

`sp_custom_gap_close` updates `status` only — it has never touched
`lifecycle_state_id`, and correctly so (see "What deliberately did not
change" below). So once a gap has been analysed
(`lifecycle_state_id` → Delegated) and is later closed (`status` →
Closed), `lifecycle_state_id` still says Delegated.

Four places combine the two fields into a single displayed value, and
all four had the identical precedence bug — each showed the lifecycle
name whenever one existed, falling back to the raw status only when there
was none:

1. **`sp_gap_centre_list`** (318/371) — `StatusText =
   COALESCE(s.state_name, g.status)` — the Gap Center grid's Status
   column.
2. **`gap-view.js` `renderHeader()`** — `chip.textContent =
   h.lifecycleStateName || h.statusCode` — the Gap View page's status
   chip.
3. **`gap-view.js` `renderFacts()`** — `dd("Gap Status",
   h.lifecycleStateName || h.statusCode)` — the same page's details/facts
   panel, labeled "Gap Status," a second and separate rendering of the
   identical value the chip shows.
4. **`gap-detail.js` `renderCompactStepper()`** — `current =
   state.currentStateCode`, which is only ever set from
   `header.lifecycleStateCode` — the Gap Detail page's stepper, which kept
   highlighting "Analysed" as the current step even after Closed.

All four are fixed together, with the same logic, in this change — one
root cause, four renderers, not four unrelated fixes.

## What changed

**`sp_gap_centre_list` (379).** Arm 1's `StatusText` computation becomes:

```sql
CASE WHEN g.status = N'Closed' THEN N'Closed'
     ELSE COALESCE(s.state_name, g.status) END
```

so a Closed gap's raw status now outranks its lifecycle label — exactly
the one case Sir named. Every other status is unaffected: the `ELSE`
branch is the same `COALESCE(s.state_name, g.status)` expression,
byte-for-byte, that every status already resolved through. Arm 2
(un-materialized `practice_gap` rows) is untouched — those rows have no
`custom_gap` row and so no `status` to be Closed.

**`gap-view.js` `renderHeader()`.** The status chip now checks
`h.statusCode === "Closed"` first; when true it shows `"Closed"` and uses
`state-closed` as the CSS state class (already defined in
`gap-detail.cshtml`'s shared stylesheet, just never reached), otherwise it
falls back to the exact `lifecycleStateName || statusCode` logic that was
already there.

**`gap-view.js` `renderFacts()`.** The same page's "Gap Status" row in the
details/facts panel gets the identical one-line fix: `h.statusCode ===
"Closed" ? "Closed" : (h.lifecycleStateName || h.statusCode)`. This is a
second, independent rendering of the same value the status chip shows —
found during the final full-solution verification pass, after the chip
fix was already applied, by re-sweeping every `lifecycleStateName`/
`statusCode` usage across the Gap UI files for the same unlabeled
precedence pattern.

**`gap-detail.js` `renderCompactStepper()`.** The stepper's `current` step
is now `"Closed"` whenever `state.gapHeader.statusCode === "Closed"`,
checked before the step path is built, and Closed gets its own explicit
path branch (checked ahead of the pre-existing generic `dormant`-array
branch, since `"Closed"` is also a member of that array and its generic
`["New", current, "Delegated"]` shape would otherwise place Closed
*before* Delegated — backwards for the one path that can actually happen
today): `["New", "Delegated", "Closed"]` when the gap's
`lifecycleStateCode` was `"Delegated"` before closing, else `["New",
"Closed"]`. Critically, this only changes the local `current` used to
pick the highlighted step — it does **not** reassign
`state.currentStateCode` itself, which `isAlreadyAnalysed()`, the
terminal-invalid banner checks, and the actions-fetch endpoint all still
read for its real, lifecycle-stage meaning, unchanged.

## What deliberately did not change

- **`lifecycle_state_id` is never written by this change**, on any gap,
  anywhere. `sp_custom_gap_close`, `sp_custom_gap_transition`, and every
  other lifecycle-transition proc are untouched. Moving a Closed gap's
  `lifecycle_state_id` to the dormant `'Closed'` row in
  `gap_lifecycle_state_master` would resurrect a state-machine path
  174/175 deliberately retired for Custom gaps — exactly the "existing
  status workflow" Sir asked not to change. The fix stays entirely in how
  the two already-correct fields are *combined for display*, never in
  what either field holds.
- **Every other status is unaffected**: New, Analysed/Delegated, Invalid,
  Duplicate, InProgress and Cancelled all resolve exactly as they did
  before, at all three sites — verified in the migration's own
  verification block (`379-c`/`379-d`) and by inspection of the two JS
  diffs, which only add a Closed-specific branch ahead of the existing
  logic and never change that existing logic itself.
- **`RawStatusCode` / `LifecycleStateCode`** (the two raw columns
  `sp_gap_centre_list` already returns) are unchanged — `gaps.cshtml`'s
  `buildRowMenu()` (Close Gap enablement, the "already analysed" → View
  menu swap) reads those two raw columns directly, already correctly, and
  needed no edit.
- **`sp_custom_gap_header`** already returns `StatusCode` and
  `LifecycleStateName`/`LifecycleStateCode` as separate, correctly-valued
  columns — it never combined them, so it never had this bug and needed
  no change. `gap-view.js` and `gap-detail.js` read those existing,
  correct API fields; the fix is entirely in how the *frontend* combines
  them, matching the same precedence rule now used in SQL.
- **No other Gap Center columns** — `PracticeInstanceStatusText`,
  `TaskStatusText`, `RiskStatusText`, `ExceptionStatusText` (371) are a
  different set of columns, unaffected by this bug and untouched here.
- **Every other `lifecycleStateName`/`lifecycleStateCode` usage across
  both JS files was checked and deliberately left alone** — a final sweep
  of every occurrence in `gap-view.js` and `gap-detail.js` confirmed none
  of the rest is the same bug: `gap-detail.js`'s metadata panel already
  shows "Lifecycle state" and "Legacy status" as two correctly separate,
  correctly labeled rows (not conflated); its terminal-invalid banner
  text and its post-analysis-save confirmation toast both describe the
  lifecycle transition that was just performed, not a persisted "current
  status" display; `state.currentStateCode`'s other reads
  (`isAlreadyAnalysed()`, the terminal-invalid checks, the actions-fetch
  endpoint) all correctly want the lifecycle stage, not the combined
  display value. `gaps.cshtml`'s `lifecycleCode`/`rawStatus` locals in
  `buildRowMenu()` are likewise already used separately and correctly.

## Why no API/model change

`CustomGapModels.cs`'s `GapCentreListRow.StatusText` and
`CustomGapService.ListGapCentreAsync`'s read of it
(`ReadStringOrNull(reader, "StatusText")`) are both **by column name**,
not positional — and `sp_gap_centre_list`'s column list, types and
nullability are unchanged; only the SQL expression that populates the
existing `StatusText` value changed. No model, controller or service edit
was needed, confirmed by inspection of both files.

## Verification

The migration's own verification block asserts, against the live
database: the proc still compiles (`379-a`); its body contains the new
Closed override (`379-b`); no `Closed` gap resolves to a non-`Closed`
`StatusText` (`379-c`); and every non-`Closed` gap's `StatusText` is
still byte-identical to the pre-379 `COALESCE` expression (`379-d`) — i.e.
nothing else moved. `node --check` was run against both edited JS files
after the change.

Rollback: `379_gap_centre_closed_status_display_rollback.sql` restores
`sp_gap_centre_list` to migration 371's exact body. The two JS files have
no SQL-governed rollback — reverting them is a manual code revert, the
same as any other UI-only change in this project.
