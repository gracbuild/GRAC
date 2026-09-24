# Gap Center → Analysis — Failed Obligation(s)

> **Update (migration 372):** the `FailedObligations` result set below
> gained one additive column, `CurrentStatusCode` (a fresh, live-joined
> status, unlike the `LoggedStatusCode` snapshot already here) — added so
> `sp_custom_gap_analysis_save`'s blocking guard could narrow to Not Set
> Obligations only, without relying on a snapshot that can go stale. See
> `gap-analysis-block-narrowed-to-not-set.md`.

Sir's instruction: for every **automatically generated** Practice Instance
gap, the Gap Center → Analysis screen should also show which
Obligation(s)' implementation failure caused it — reusing the existing
relationship, no parallel flow, and manually created gaps must never be
mis-associated with an Obligation.

> "Practice Instance: Password Management, Gap: Password policy not
> implemented, Failed Obligation: OBL-003 – Password must be changed
> every 90 days."

**Migration:** `317_gap_analysis_failed_obligations.sql` (+
`_rollback.sql`)
**API:** `Api/Models/GapLifecycleModels.cs` (`GapFailedObligationRow`,
`GapLinkedArtefactsResult.FailedObligations`),
`Api/Services/GapLifecycleService.cs` (`ListLinkedArtefactsAsync`) —
`GapLifecycleController` and the route `GET
.../practice/gap-lifecycle/gaps/{id}/linked-artefacts` are unchanged.
**UI:** `Partials/gap-detail.cshtml`, `wwwroot/js/GapLifecycle/gap-detail.js`

---

## The relationship already existed — this is exposure, not invention

Tracing end-to-end (Practice Instance → Obligation → Implementation Status
→ Automatic Gap Creation → Gap Center → Analysis) before writing anything
found that migration 245 already keeps the exact fact the requirement
asks for:

* `practice_gap` — one row per `practice_instance_id` (UNIQUE), created
  the moment any of its Obligations logs `Not Implemented` or `Partially
  Implemented`.
* `practice_gap_obligation` — one child row per offending Obligation,
  snapshotting `obligation_name` / `obligation_type_code` /
  `logged_status_code` at the moment it entered the gap, `status`
  `Active`/`Retired`.
* `sp_practice_gap_sync_for_instance` — called from the API after every
  Obligation save, keeps both tables current (idempotent: re-running it
  for an instance with no change is a no-op).

So "which Obligation caused this gap" was already recorded, and
`practice_gap`'s UNIQUE-per-instance constraint already guarantees one
gap per instance regardless of how many Obligations are failing — the
"don't create duplicate gaps" requirement was already satisfied by
construction. The only gap (no pun intended) was that nothing on the
**Analysis** screen read `practice_gap_obligation` back out.

`sp_task_center_gaps_list` already projects the same snapshot as
`GapObligationsJson`, but it is unrendered — `practice.js` never reads
that field. Out of scope here: Sir's requirement names Gap Center →
Analysis (`gap-detail.cshtml`), not Task Center.

## Why `sp_custom_gap_linked_artefacts`, not a new proc

That proc already exists (migration 174), already returns Task /
Exception / Risk as the "Analysis-tab chip strip" data, and is already
called by `gap-detail.js` on every page load and after every Analysis
save. Adding a fourth result set to it reuses the identical round-trip
instead of adding a second network call and a second integration point —
directly the "reuse existing relationship/data… do not create a
separate parallel flow" instruction.

### The new result set

```sql
SELECT pgo.practice_instance_obligation_id AS ObligationId,
       pgo.obligation_name                 AS ObligationName,
       pgo.obligation_type_code            AS ObligationTypeCode,
       pgo.logged_status_code              AS LoggedStatusCode,
       pgo.added_dt                        AS AddedDt
  FROM grac_practice.custom_gap cg
  JOIN grac_practice.practice_gap pg
       ON pg.practice_instance_id = cg.source_reference_id
  JOIN grac_practice.practice_gap_obligation pgo
       ON pgo.practice_gap_id = pg.practice_gap_id
      AND pgo.status         = N'Active'
 WHERE cg.custom_gap_id          = @custom_gap_id
   AND cg.gap_source_module_code = N'Implementation'
   AND cg.source_reference_type  = N'PracticeInstance'
   AND cg.source_reference_id   IS NOT NULL
 ORDER BY CASE pgo.logged_status_code
               WHEN N'Not Implemented'       THEN 1
               WHEN N'Partially Implemented' THEN 2
               ELSE 3 END,
          pgo.obligation_name;
```

**Why manual gaps can never be mis-associated — by construction, not by
a flag.** The predicate is the same three-column key
`sp_custom_gap_materialize_for_instance` (160) already writes when it
promotes a `practice_gap` into a lifecycle-managed `custom_gap`:
`gap_source_module_code='Implementation'`,
`source_reference_type='PracticeInstance'`, `source_reference_id`
matching the instance. Those columns are NULLable (migration 109) and
are only ever set by the materialize proc's own automatic path — a
manually created Custom/Assurance/Exception/Risk/Audit gap never has
`source_reference_type='PracticeInstance'`, so the `JOIN` simply returns
zero rows for it. There is no separate "is this automatic?" flag to get
out of sync; the join itself is the guard.

**Multiple failing Obligations** on one instance already produce
multiple `practice_gap_obligation` rows against the *same* `practice_gap`
(the UNIQUE-per-instance constraint), so this result set naturally
returns every one of them against the one gap — no duplicate gaps, no
extra handling needed.

**Backward compatibility.** `ListLinkedArtefactsAsync` reads the proc's
result sets in order (Task, Exception, Risk, then FailedObligations) via
the codebase's usual `NextResultAsync` loop. Against a pre-317 database,
the proc still ends after Risk, so the loop's `NextResultAsync` returns
`false` before the fourth branch is reached and `FailedObligations` is
simply an empty list — no version check, no `HasColumn` guard needed.

## UI

The Analysis tab gets a new **"Implementation Failure – Failed
Obligation(s)"** strip, placed **above** the Analysis form (not beside
the Task/Exception/Risk strip below it) because it names the *upstream
cause* of the gap, not a *downstream artefact* the gap produced. It
reuses the existing `.gap-linked-chip` styling for visual consistency,
with its own heading and a warm-red status color to read as "this is the
problem" rather than the neutral grey used for Task/Exception/Risk
status badges. The strip and its chip container start `hidden` and are
shown/populated only when `linked-artefacts` returns at least one row —
so it is invisible on every manual gap and on Implementation gaps whose
Obligations have since been resolved.

Obligation chips are plain `<div>`s, not the clickable `<a>` chips used
for Task/Exception/Risk: an Obligation has no dedicated detail screen to
deep-link to, and the API response carries no practice-instance id to
route to its workspace with.

No new API call was added — `renderFailedObligations()` is driven by the
same `refreshLinkedArtefacts()` fetch that already populates the
Task/Exception/Risk chips, called on load and after every Analysis save.

## What did NOT change

No new table, no new column, no new stored procedure, no new API route.
`sp_custom_gap_linked_artefacts`'s first three result sets (Task,
Exception, Risk) are byte-for-byte unchanged; `317_..._rollback.sql`
restores the pre-317 body exactly if ever needed.
