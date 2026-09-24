# Gap Analysis — the "unresolved Obligation" block now narrows to Not Set only

Sir's follow-up on 367, after testing: marking an Obligation Not
Implemented created a gap showing "Analysis is blocked until 1
obligation under this Practice is still unresolved"; resolving two more
Obligations to Implemented still showed the exact same message.

> "Not set mathram anu aa block nu pariganikendathu.
> implemented/note implemented/partially implemeted mark cheythal pinne
> ee message kanikenda avasyam illa. Onnum mark cheyyatha enthenkilum
> undenkil mathre kanikendu"
>
> — Only "Not Set" should count toward that block. Once an Obligation is
> marked Implemented / Not Implemented / Partially Implemented, this
> message no longer needs to show. It should show only if something is
> still completely unmarked (Not Set).

**Migration:** `372_gap_analysis_block_narrowed_to_not_set.sql` (+
`_rollback.sql`)
**API:** `Api/Models/GapLifecycleModels.cs`
(`GapFailedObligationRow.CurrentStatusCode`, new/additive),
`Api/Services/GapLifecycleService.cs` (`ListLinkedArtefactsAsync`,
`HasColumn` guard) — **rebuild required**.
**UI:** `wwwroot/js/GapLifecycle/gap-detail.js`
(`unassessedObligations()`, narrowed `isBlockedByUnresolvedObligations()`,
reworded blocked-banner text), `Views/Practice/Partials/gap-detail.cshtml`
(placeholder banner copy only — always overwritten by JS before shown).

---

## Why 367's block was too broad

367 deliberately broadened `practice_gap_obligation`'s Active set to
"every Obligation not yet Implemented/N/A" — Not Implemented, Partially
Implemented, **and** Not Set — so the "Obligations to Resolve" strip
would show the Practice's complete unresolved picture. Guard `55144` in
`sp_custom_gap_analysis_save` then blocked Analysis on **any** Active
child in that same set. That was correct for the strip, but too broad
for the block: this request narrows the block itself — Not Implemented
and Partially Implemented should no longer hold Analysis back — without
touching what the strip displays.

## Why filtering on `logged_status_code` would have been wrong

`practice_gap_obligation.logged_status_code` is a **snapshot**, written
only when `sp_practice_gap_sync_for_instance`'s step 3b (re)inserts the
child row. An Obligation that moves between two statuses that are both
still inside the broadened Active set — e.g. Not Started → Partially
Implemented — does not trigger a retire+reinsert; the same
`practice_gap_obligation` row stays Active and its `logged_status_code`
is never refreshed. A guard filtering on that column alone would keep
blocking Analysis on a stale "Not Started" snapshot even after the
Obligation had genuinely moved on. Both changed procs below instead join
fresh, every call, to `practice_instance_obligation` /
`implementation_status_master` — the Obligation's **live** status — the
same tables `sp_practice_gap_sync_for_instance` itself already reads
when it builds `@current`.

## The fix — one additive column, one narrowed guard

`sp_custom_gap_linked_artefacts` is re-issued from 317's exact body
(unchanged since; 367 never touched it). `FailedObligations` gains one
new, additive column:

```sql
LEFT JOIN grac_practice.practice_instance_obligation pio
     ON pio.practice_instance_obligation_id = pgo.practice_instance_obligation_id
LEFT JOIN grac_practice.implementation_status_master ims
     ON ims.implementation_status_id = pio.implementation_status_id
...
COALESCE(ims.status_code, N'Not Started') AS CurrentStatusCode
```

`LoggedStatusCode` (the snapshot) and the existing `ORDER BY` — still
worst `LoggedStatusCode` first — are untouched: the strip's own display
and ordering are explicitly out of scope for this change.

`sp_custom_gap_analysis_save` is re-issued from 367's exact body with
only guard `55144` changed — from "any Active `practice_gap_obligation`
child exists" to "any Active child whose live status is Not Set / Not
Started", via the identical `LEFT JOIN` shape:

```sql
IF EXISTS (
    SELECT 1
      FROM grac_practice.practice_gap pg
      JOIN grac_practice.practice_gap_obligation pgo
           ON pgo.practice_gap_id = pg.practice_gap_id
          AND pgo.status          = N'Active'
      LEFT JOIN grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = pgo.practice_instance_obligation_id
      LEFT JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pio.implementation_status_id
     WHERE pg.practice_instance_id = @src_instance_id
       AND COALESCE(ims.status_code, N'Not Started') = N'Not Started')
    THROW 55144, '...have not been assessed yet (Not Set); assess them before this gap can be analysed.', 1;
```

Guard `55145` (Practice Operationalized) and every other line of the
proc — terminal-invalid `55142`, re-analysis `55143`, the MERGE, the
auto-trigger blocks, the auto-delegate transition — are byte-for-byte
unchanged.

## Client-side: same lock mechanism, narrower input

`gap-detail.js` gets one new helper and one call-site swap — no new
banner, no new lock:

```js
function unassessedObligations() {
  return (state.failedObligations || [])
    .filter(o => (o.currentStatusCode || "Not Started") === "Not Started");
}

function isBlockedByUnresolvedObligations() {
  const h = state.gapHeader || {};
  if (!h.practiceInstanceId) return false;
  if (unassessedObligations().length > 0) return true;
  return h.isPracticeOperationalized === false;
}
```

A missing `currentStatusCode` (a database that hasn't run 372 yet, so
`/linked-artefacts` has no `CurrentStatusCode` column) falls back to
`"Not Started"` — the client then degrades to 367's older, broader lock,
matching what the still-unmigrated server-side guard would enforce
anyway. `applyTerminalInvalidMode()`'s amber banner now counts
`unassessedObligations().length` instead of the full
`state.failedObligations.length`, and its copy changed from "is/are
still unresolved" to "has/have not been assessed yet" to match.

## What did NOT change

* The "Obligations to Resolve" strip (317/367) — still lists every
  Not Implemented, Partially Implemented, and Not Set Obligation under
  the gap, in the same worst-first order. Only the *blocking* criterion
  narrowed, not what is shown.
* `sp_practice_gap_sync_for_instance` (245/356/367) — which Obligations
  become Active `practice_gap_obligation` children, and when the gap
  itself opens/closes/reopens, is untouched.
* Guard `55145` (Practice Operationalized) — untouched, still the exact
  live dependency-resolution computation from 367.
* `sp_custom_gap_header` / `IsPracticeOperationalized` (325/367) —
  unrelated to this change, untouched.
* Gap **creation** (`@gap_trigger`, unchanged since 367) is still
  triggered only by an actual Not Implemented / Partially Implemented
  Obligation.

## Example (the case sir reported)

A Practice with three Obligations: #1 Implemented, #2 marked Not
Implemented (creates the gap), #3 still Not Set.

* Before 372: gap shows Obligations #2 and #3; Analysis blocked
  ("1 obligation ... unresolved", counting only what happened to be
  unresolved at that instant — the count moved as the user marked
  more Obligations, but the block itself never lifted while *either*
  #2 or #3 stayed non-Implemented).
* User goes back and marks #2 and #3 both Implemented.
* After 372: the strip still lists #2 and #3 (still 317/367's full
  picture, now both showing `CurrentStatusCode = 'Implemented'`), but
  `unassessedObligations()` is now empty — neither is Not Set — so
  Analysis is unblocked immediately, no further Obligation save
  required, no page-reload timing dependency.
* If, instead, the user had left #3 untouched (still Not Set), Analysis
  would remain blocked — correctly, since #3 has genuinely never been
  assessed at all.
