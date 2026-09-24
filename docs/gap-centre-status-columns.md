# Gap Center list — Practice Instance / Task / Risk / Exception Status columns

Requirement: reorder the Gap Center grid to **Gap, Status, Practice
Instance Status, Task Status, Risk Status, Exception Status, Owner,
Raised On, Actions**, adding the four status columns as live, current
data derived from each Gap's existing relationships — not
frontend-hardcoded, not a value frozen at Gap-creation time, and without
introducing N+1 calls. Source and Severity are dropped from the grid on
the same request (clarified with Sir: **keep Raised On, drop the other
two**); Status/business logic, pagination, search, sorting, the 3-dot
menu and permissions are all explicitly unchanged.

**Migration:** `371_gap_centre_list_status_columns.sql` (+
`_rollback.sql`)
**API:** `Api/Models/CustomGapModels.cs` (`GapCentreListRow` — four new
trailing optional fields), `Api/Services/CustomGapService.cs`
(`ListGapCentreAsync`, four new `HasColumn`-guarded reads) —
`CustomGapController.GapCentreList` is unchanged; it returns the whole
result object, so the new fields flow through with no controller edit.
**UI:** `Views/Practice/Partials/gaps.cshtml`

---

## Reusing what already existed, not deriving anything new

Per the requirement's own "first inspect… reuse existing status values,
relationships and business rules" instruction, each of the four columns
turned out to already have a live source of truth somewhere in the
existing schema — nothing here invents a new status vocabulary or a new
workflow.

**Practice Instance Status.** Migration 245's `practice_gap` /
`practice_gap_obligation` tables, kept in sync after every Obligation
save by `sp_practice_gap_sync_for_instance` (called from
`ResolveWorkspaceService.SyncGapForInstanceAsync`), already compute a
binary `practice_gap.gap_status` (`Open`/`Closed`) from exactly the rule
this requirement asks for. Migration 367 broadened the "still failing"
definition to every non-Implemented, non-N/A obligation state and
recomputes `gap_status` on every sync: `Closed` once no such obligation
remains, `Open` again the moment one reappears. So Practice Instance
Status is `practice_gap.gap_status` relabelled (`Closed → Implemented`,
`Open → Not Implemented`), not a second calculation running alongside
the first — if 367's sync logic ever changes, this column moves with it
automatically. A Gap with no linked Practice Instance gets `NULL` →
`—` on the grid.

**Task Status.** Aggregated from every `practice_task` row linked via
the same `subject_entity_type = 'CustomGap' AND subject_entity_id =
custom_gap_id` key `sp_custom_gap_linked_artefacts` (174) already uses
for the Analysis-tab Task chip, joined to
`entity_status_master.is_terminal` (035) rather than hardcoding which
status names count as "done" — `Completed` only when every linked task
has `is_terminal = 1` (Closed/Cancelled), `Pending` if any do not. A Gap
with no linked Task gets `NULL` → `—`, matching the requirement's "do
not invent a new status" instruction for that case.

**Risk Status.** The most recently linked `risk_candidate`
(`ORDER BY risk_candidate_id DESC`, the same "most recent" convention
174 already uses for Task/Exception), resolved through the same
precedence `gap-view.js`'s `buildRiskCard()` already applies in the UI:
`risk_register.status_code` once the candidate is registered
(`registered_risk_id` set), else the candidate's own `status_code`.
Nothing new — this SQL is the existing client-side precedence rule
moved to the query that now needs it too. No linked Risk → `—`.

**Exception Status.** The most recently linked `exception_request`'s
`status_code`, same `ORDER BY ... DESC` "most recent" convention. No
linked Exception → `—`.

## Why `sp_gap_centre_list`, not a second query per row

The four columns are correlated scalar subqueries added directly to
`sp_gap_centre_list`'s existing `@results` population (357's body,
re-issued in full since `CREATE OR ALTER` replaces the whole
definition), not a second API call the frontend makes per row. Each
subquery runs once per row returned by the proc — bounded by
`@page_size` (25 by default, capped at 200) — never once per underlying
Obligation/Task/Risk/Exception record, so there is no N+1 growth as
those grow independently of the page size. This mirrors the shape the
proc already used for `LinkedCount` and `ExistingTaskCount`; the four
new columns are the same pattern, not a new one.

**Two arms, two different sources.** `sp_gap_centre_list` UNIONs
`custom_gap` (Arm 1, every source module, the case above) with
un-materialized `practice_gap` rows (Arm 2, Implementation-only, no
`custom_gap` row yet). An Arm 2 row cannot structurally have a linked
Task/Risk/Exception — those all key off `custom_gap_id`, which does not
exist until materialization — so Task/Risk/Exception Status are `NULL`
on every Arm 2 row by construction, and Practice Instance Status is read
directly off `pg.gap_status` (no subquery needed — `pg` already *is*
that instance's row).

**Result set 2's column list** gained the four new columns appended at
the end (`... ExistingTaskCount, PracticeInstanceStatusText,
TaskStatusText, RiskStatusText, ExceptionStatusText`). `ORDER BY
SortBucket, UrgencyRank, OpenedDt DESC, RowKey` and the `OFFSET/FETCH`
paging are untouched.

**Backward compatibility.** `ListGapCentreAsync` reads each of the four
new columns through the same `HasColumn(reader, "...")`-guarded pattern
318/324 already established for `RawStatusCode`/`LifecycleStateCode` —
against a pre-371 database the columns are simply absent and the fields
come back `null`, no version check needed.

## UI

`gaps.cshtml`'s grid goes from 7 columns to 9: `Source` and `Severity`
are dropped, the four new `<th>`s are inserted between `Status` and
`Owner`, and every `colspan="7"` empty/loading/error placeholder becomes
`colspan="9"`.

Dropping the Source column also retired `sourceNote()`'s home — the
"not yet analysed" note for an un-materialized Arm 2 row used to render
in the Source cell; it now renders in the Gap title cell, next to the
existing `linkedNote`. `gapSourceDisplay()` (the Custom/System badge
function documented in `centre-source-column.md`) had no other caller
once the Source cell was removed, so it was deleted along with the
"Sir's request" comment describing it — `SOURCE_LABELS` and the Source
**filter** dropdown (`gapFilterSource`, `loadSourceFilter`) are
untouched, since the requirement only asked to drop the grid column, not
the filter.

Each new cell goes through a small `statusOrDash(v)` helper —
`escape(v)` when set, else the same `&mdash;`-on-`#94a3b8` empty-state
span `task-actions.js` already uses for an unset value — rather than a
bare empty string, so an absent status reads as "nothing linked" and
not as a loading gap.

Search, filtering, sorting, pagination, the 3-dot action menu and
permissions all read from the same `renderGaps(payload)` /
`currentRows` / `actionTrigger(i)` plumbing, none of which this change
touches.

## What did NOT change

No Gap, Task, Risk, Exception or Practice workflow was modified — every
new column reads an existing, already-live status value or relationship
rather than computing a new one. `sp_gap_centre_list`'s WHERE clauses,
paging, sort order and both arms' existing columns are byte-for-byte
unchanged from migration 357's body; `371_..._rollback.sql` restores
that body exactly if ever needed. No new table, no new stored
procedure, no new API route — `CustomGapController.GapCentreList` did
not need an edit.
