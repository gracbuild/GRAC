# Gap Center — auto-reopen on a new Obligation failure

Sir's instruction: after a Gap Center gap is analysed and its status
shows **Analysed**, the status should automatically go back to **New**
if any new Obligation is marked Not Implemented under the Practice.

**Migration:** `356_gap_reopens_on_new_obligation_failure.sql` (+
`_rollback.sql`)
**API:** unchanged — `ResolveWorkspaceService.SyncGapForInstanceAsync`
already calls `sp_practice_gap_sync_for_instance` with the same two
parameters and just drains the result set; nothing in the C# tier reads
or needs to react to the reopen, so **no rebuild is required for this
change**.
**UI:** `wwwroot/js/GapLifecycle/gap-detail.js` (`AUTO_ONLY` set)

---

## Where the gap goes stale

An Implementation gap is materialized once per Practice Instance
(`sp_custom_gap_materialize_for_instance`, migrations 160/320) the first
time any of its Obligations logs Not Implemented / Partially
Implemented. Once an analyst analyses it, `sp_custom_gap_analysis_save`
auto-transitions it to the lifecycle state `Delegated` — displayed as
**Analysed** since migration 175 — and migration 324 deliberately
*blocks* analysing that same gap a second time (`THROW 55143`), because
nothing about the Obligations the analysis already covered has changed.

That guard is correct for the case it was written for. It is wrong for
a different case it was never asked to cover: a **different** Obligation
on the **same** Practice Instance failing *after* the analysis. Every
Obligation save — bulk adopt and single local save alike — already
calls `sp_practice_gap_sync_for_instance` (migration 245), which keeps
`practice_gap` / `practice_gap_obligation` (the Task Center-facing
rollup) in step with whichever Obligations are currently failing. But
that proc has never looked at the Gap Centre lifecycle state at all — so
a fresh Obligation failure shows up correctly in Task Center's numbers
while the Gap Centre screen for the very same instance keeps showing
Analysed, silently stale, with 324's own guard now standing in the way
of anyone trying to re-analyse it.

## The fix — one hook, the place every save already goes through

`sp_practice_gap_sync_for_instance` is re-issued with two additions:

1. Its existing "add active children" `INSERT` (step 3b — one row per
   Obligation newly entering gap territory) now also `OUTPUT`s which
   `practice_instance_obligation_id` values it actually inserted. An
   Obligation that was *already* an active child — still failing,
   unchanged, or moved between Not Implemented and Partially
   Implemented — produces no new row here, so it triggers nothing. Only
   a Obligation that is entering gap territory for the first time, or
   re-entering after having been resolved and failing again, counts.

2. After the existing transaction commits, if that OUTPUT captured at
   least one row, the proc looks up whether this instance already has a
   materialized `custom_gap` currently sitting in `Delegated`. If so, it
   fires the existing lifecycle engine
   (`sp_custom_gap_lifecycle_transition`, migration 157) with a new
   action code, `ReopenObligation`, moving the gap back to `New` — the
   same engine every other transition in this codebase (`Delegate`,
   `MarkInvalid`, `MarkDuplicate`, …) already goes through, so this
   reopen gets the exact same `custom_gap_history` audit row for free
   (`action_code='ReopenObligation'`, `from='Delegated'`, `to='New'`)
   with no duplicated UPDATE/history logic to maintain separately.

The whole reopen step is best-effort, wrapped in `TRY`/`CATCH` — an
Obligation save must never fail because this step could not run, the
same tolerance `SyncGapForInstanceAsync` already applies to the entire
proc call.

## Scope — only Delegated, only a genuinely new failure

A gap sitting in `New` / `Validation` / `Analysis` is untouched — it is
already open, nothing to reopen. A gap in `Invalid` / `Duplicate` is
*deliberately* untouched too: those states are a human's terminal
verdict on the gap itself ("not real" / "a duplicate"), not a statement
about its Obligations, and a fresh Obligation failure does not undo
that verdict. Only `Delegated` ("Analysed") is in scope, matching the
report exactly.

## Why a new transition row instead of a direct `UPDATE`

`sp_custom_gap_lifecycle_transition` is already the single place that
mutates `custom_gap.lifecycle_state_id` + the legacy `status` column and
writes the `custom_gap_history` row. Every other transition in this
codebase goes through it rather than a bespoke `UPDATE`; this reopen
does the same rather than becoming the one exception.

The new `(Delegated → New, 'ReopenObligation')` row is seeded **Active**,
not Inactive. `sp_custom_gap_lifecycle_transition`'s own validation
requires an Active transition row to allow the action at all — an
Inactive row would be invisible to the *engine*, not only the UI, since
both currently share the same `record_status_id` filter. Deactivating
it (the way migration 175 deactivated `Validate`) would have silently
broken this migration's own reopen call.

## Why this doesn't put a new button in front of anyone

`gap-detail.js` already has the exact mechanism this needs: an
`AUTO_ONLY` client-side set that hides a fully-Active, fully-valid
transition from the manual actions strip because it is meant to fire
only from server-side logic. `Delegate` is hidden this exact way today
— its transition rows have been Active since migration 174; only the
button is hidden. `ReopenObligation` is added to that same set rather
than touching the transition row's active state, which — as above —
would also block the engine. Gap Centre's list screen (`gaps.cshtml`)
never calls the actions-list endpoint at all, so it needed no change.

## What did NOT change

`sp_custom_gap_analysis_save` and its 55143 re-analysis guard are
untouched — once reopened to `New`, the next analysis save is simply a
normal first analysis of a gap in the `New` state, already fully
supported without any special-casing. The prior `custom_gap_analysis`
row is not cleared; the next save `MERGE`s onto it exactly as any second
save already would. `practice_gap` / `practice_gap_obligation`'s own
open/close bookkeeping (steps 3a/3c) is byte-for-byte unchanged. A gap
that was never materialized (a Task Center-only `practice_gap` row with
no `custom_gap`) has nothing for the lookup to find, so the proc is a
no-op past the existing sync — exactly as before this migration.

## One thing this migration deliberately does not do

It does not retroactively reopen a gap that was **already** stale — sitting
Delegated with a failing Obligation underneath it — from *before* this
migration ran, since nothing here re-runs the sync for every instance on
deploy. The verification block in `356_....sql` reports exactly which
currently-Delegated gaps have Active failed-obligation rows right now,
if any; the next Obligation save on that instance reopens it, or an
operator can re-run `sp_practice_gap_sync_for_instance` by hand for a
specific `practice_instance_id` if an immediate reopen is wanted.
