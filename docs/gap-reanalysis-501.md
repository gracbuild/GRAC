# Gap Analysis — Re-analyse an already-analysed gap (migration 501)

**Request:** "Gaps: once the analysis is complete, add an option to re-analyse. Right now it is
locked — after analysing once you cannot do it again."

## Why it was locked

Migration **324** locked it on purpose, and that was the right call at the time.

"Analysed" is not a lifecycle state of its own: it is the display label (175/319) on
`state_code = 'Delegated'`, which is **terminal-valid** — `is_terminal = 1`,
`is_valid_terminal = 1`. Migration 173 had guarded only the terminal-**invalid** states
(Invalid / Duplicate, `THROW 55142`), so nothing stopped an analysed gap from being analysed
again — in the UI or by a direct API call. 324 added the missing counterpart,
`THROW 55143`, and locked the Analysis form client-side (`isAlreadyAnalysed()` in
`gap-detail.js`), with Gap Centre's row menu replacing **Analysis** with **View** once
`LifecycleStateCode = 'Delegated'`.

That protects against the *accidental* second save: a stale tab, a double submit, a replayed
request. It also made a *deliberate* re-analysis impossible, which is what 501 fixes —
without reopening the accidental case.

## The change: one parameter, opt-out not removal

`501_gap_reanalysis.sql` re-issues `sp_custom_gap_analysis_save` from **372's body** (the
current one) with exactly three edits — the migration's own diff against 372 is three hunks:

1. One new parameter, last in the list:

   ```sql
   @reanalyse BIT = 0
   ```

2. The 324 guard becomes opt-out:

   ```sql
   IF ISNULL(@reanalyse, 0) = 0
      AND EXISTS ( ... is_terminal = 1 AND is_valid_terminal = 1 )
       THROW 55143, '... this gap has already been analysed. Use Re-analyse to change the saved analysis.', 1;
   ```

   `@reanalyse = 0` is the default and every existing caller, so an accidental second save is
   still refused exactly as before.

   Immediately after it, two derived flags:

   ```sql
   DECLARE @was_analysed  BIT = <the same terminal-valid EXISTS as the guard>;
   DECLARE @is_reanalysis BIT = CASE WHEN ISNULL(@reanalyse, 0) = 1 AND @was_analysed = 1 THEN 1 ELSE 0 END;
   ```

   `@is_reanalysis`, not the raw flag, drives the counter below. Without it a `reanalyse=1`
   that reached a gap which has **not** got to Analysed — a hand-made URL, a replayed
   request — would inflate `reanalysis_count`. (A true first analysis takes the MERGE's
   NOT MATCHED branch and never touches it either way.)

3. The MERGE's MATCHED branch records the re-analysis (see below), keyed on
   `@is_reanalysis`.

Nothing else in the body changes.

## Three additive columns on `custom_gap_analysis`

| Column | |
|---|---|
| `reanalysis_count` | `INT NOT NULL DEFAULT 0`, incremented only when `@is_reanalysis = 1` |
| `last_reanalysed_on` | `DATETIME2 NULL` |
| `last_reanalysed_by_employee_id` | `BIGINT NULL` |

`analysed_on` / `analysed_by_employee_id` are **left on the first analysis** —
Gap View renders `analysed_on` as "Analysed On", and overwriting it would destroy the original
record with nothing to hold it. A re-analysis is recorded in the three columns above instead,
so both facts survive. The re-issued procedure reads these columns, so the migration guards on
the **columns**, not just the table, before re-issuing it (Msg 207 would otherwise let the
script print a success it did not achieve).

Nothing displays them yet: `sp_custom_gap_analysis_get` is untouched. Surfacing
"Re-analysed on" on the Gap View page is a one-line addition to that projection when it is
wanted.

## What is deliberately NOT opt-out

| Guard | Still enforced during a re-analysis? |
|---|---|
| `55142` terminal-invalid (173) | **Yes.** An Invalid or Duplicate gap stays closed to analysis however it is asked for. |
| `55144` unassessed obligations (367, narrowed by 372) | **Yes.** A re-analysis is still an analysis and meets the same preconditions. |
| `55145` Practice not Operationalized (367) | **Yes.** |
| `55143` already analysed (324) | Only this one, and only on an explicit `@reanalyse = 1`. |

The client mirrors this: `applyTerminalInvalidMode()` now computes
`analysedLocked = isAlreadyAnalysed() && !state.reanalyse`, and the 367/372 lock is
re-evaluated once the analysed lock is released — so releasing one lock can reveal another,
matching the server.

## The lifecycle is untouched

A re-analysed gap is already in `Delegated`, and the auto-delegate block at the end of the
procedure only fires from `New` / `Validation` / `Analysis`. So the gap stays **Analysed**
throughout a re-analysis. No transition is invented and
`gap_lifecycle_transition_master` is not touched.

## Duplicate Task / Exception / Risk — already handled, nothing added

Re-analysing with the same boxes ticked does **not** raise duplicates, because all three
auto-trigger procedures were already idempotent per gap. They were read and verified, not
assumed:

| Procedure | Short-circuits when |
|---|---|
| `sp_custom_gap_task_create` (253/323) | an open `practice_task` exists for `subject_entity_type = 'CustomGap'` — reports `Created = 0` |
| `sp_exception_request_create` (328) | an `exception_request` for the gap is `Pending` / `SubmittedForApproval` / `Approved` |
| `sp_risk_candidate_create` (378) | a `risk_candidate` for the source is Pending / UnderAnalysis / ClarificationRequired / AnalysisCompleted / Accepted / Registered |

If the earlier artefact was closed, rejected or withdrawn, a fresh one **is** created — which
is the point of re-analysing. None of the three procedures is modified.

`sp_custom_gap_apply_sla` is re-run after every save and is already a no-op when
`sla_source_code = 'OVERRIDDEN'`, so an approved SLA override survives a re-analysis. That was
already true and is unchanged.

## API

`PUT /api/practice/gap-lifecycle/gaps/{customGapId}/analysis` — the body gains one optional
field:

| Field | Type | Meaning |
|---|---|---|
| `reanalyse` | `bool`, default `false` | `true` only when the analyst chose **Re-analyse** on a gap that is already Analysed. |

`GapAnalysisSaveRequest` gains `bool Reanalyse = false` as its last, optional member, so no
existing caller changes. `GapLifecycleService.SaveAnalysisAsync` binds `@reanalyse` **only
when the procedure declares it**, through the shared
`ProcParameterProbe.HasParameterAsync` — sending it unconditionally would fail with
"has too many arguments specified" on a database still on 372, the same break migration 463
had to repair. On such a database the Re-analyse option simply still hits 55143, which is the
honest answer until 501 is run.

The Web tier proxy forwards the JSON body unchanged, so `GapLifecycleController` (Web) needs
no edit.

## UI

**Gap Analysis page** (`gap-detail.cshtml` / `gap-detail.js`)
- The green "already analysed" banner gains a **Re-analyse** button. It sits outside
  `#gapAnalysisForm` on purpose: `applyTerminalInvalidMode()` disables every button inside
  that form while it is locked, and this is the one control that must stay clickable.
- The button asks for confirmation (`window.gracUi.confirm`, never native `confirm`), then
  sets `state.reanalyse` and re-applies the lock pass. Nothing is written at that point — the
  form simply becomes editable and the next save carries `reanalyse: true`.
- The banner stays up while re-analysing, with a second paragraph explaining the mode and the
  button hidden. Two paragraphs in the markup rather than one rewritten in JavaScript, so the
  copy stays with the rest of the page's text.
- `state.reanalyse` is cleared after a successful save, before `applyTerminalInvalidMode()`,
  so the form re-locks and the button returns: re-analysing twice takes two decisions.
- `?reanalyse=1` on the URL enters the mode on load.

**Gap Centre row menu** (`Shared/gap-actions.js` / `gaps.cshtml`)
- `buildMenu` offers **Re-analysis** (`fa-rotate`) when `fields.isAnalysed` and the caller
  passes `onReanalysis` — the counterpart to **Analysis**, which 324 hides once analysed.
  **View** is unchanged. An omitted handler drops the item, like every other item there, so a
  caller that does not offer re-analysis is unaffected.
- Gap Centre wires it to `gotoDetail(gapId, true)`, which appends `&reanalyse=1`, so the item
  lands on an editable form rather than a locked one the analyst has to unlock again.

**Gap View** (`gap-view.js`) needed no change: it already has an unconditional **Analysis**
item in its Actions menu (added 2026-09-22 for exactly this reason — "an already-analysed gap
still needs a way back into gap-detail.cshtml"), which now lands on the page where the
Re-analyse button lives.

## Verification

No dotnet or sqlcmd on the device, so:

- The procedure body in 501 was **generated** by extracting lines 216–536 of
  `372_gap_analysis_block_narrowed_to_not_set.sql` and applying the three edits
  programmatically, never retyped. `diff -u` of the extracted 372 body against the 501 body
  shows exactly three hunks, all intended. The rollback carries 372's body byte for byte
  (verified by substring match).
- Static sweep of both files with a tokenizer that skips string literals and comments:
  ASCII-only, no unterminated string, parentheses 95/95 and 78/78, `BEGIN` equals
  `END` minus `CASE` (11/11 and 9/9), `BEGIN TRY`/`END TRY` and `BEGIN CATCH`/`END CATCH`
  4/4 each, no transaction left open. `THROW` codes present: 55121, 55122, 55140, 55141,
  **55142, 55143, 55144, 55145** — every pre-existing guard still in the body.
- The file's own verification block asserts the three columns, the `@reanalyse` parameter, all
  four guards still present in `OBJECT_DEFINITION`, and that 55143 is the only one made
  conditional (`ISNULL(@reanalyse, 0) = 0`).
- `node --check` on `gap-detail.js`, `Shared/gap-actions.js` and `gaps.cshtml`'s extracted
  script. No `@` anywhere inside a `<script>` block in `gap-detail.cshtml`, so the Razor
  sigil trap (CS0103) does not apply.

## Deployment

1. Run `database/501_gap_reanalysis.sql` (requires 324, 367, 372; safe to re-run).
2. Restart the Api (the `@reanalyse` probe result is read per call, but the Api must be the
   build that sends it), then Web, and hard-refresh.

Order does not matter operationally: an Api with 501's code against a pre-501 database simply
does not bind `@reanalyse`, and the Re-analyse button then fails with 55143's message.

Rollback: `501_gap_reanalysis_rollback.sql` — restores 372's procedure body exactly and drops
the three columns.
