# Gap Center / Gap Analysis — a gap shows every unresolved Obligation, and Analysis is blocked until they (and the Practice) are ready

> **Update (migration 372):** the Analysis *block* described below was
> later narrowed to Not Set Obligations only — Not Implemented and
> Partially Implemented no longer hold Analysis back, though they still
> appear on the Obligations strip exactly as this document describes.
> See `gap-analysis-block-narrowed-to-not-set.md`.

Sir's instruction: for a gap generated from a Practice's Obligations,
only the one Obligation that triggered it was ever shown, and the gap
could be analysed immediately — even while other Obligations on the same
Practice were still Not Set, and even before the Practice had been
Operationalized. Required behaviour:

1. A gap is still created when any Obligation under a Practice is Not
   Implemented (unchanged).
2. Once created, the gap displays **every** Obligation under that
   Practice except those already Implemented — Not Implemented,
   Partially Implemented, **and Not Set (Not Started)**.
3. Gap Analysis is blocked while any Obligation displayed under the gap
   is unresolved, Not Set included.
4. Gap Analysis is allowed only once the related Practice has been
   Operationalized.

**Migration:** `367_gap_analysis_blocked_until_obligations_resolved.sql`
(+ `_rollback.sql`)
**API:** `GapLifecycleModels.cs` (`GapHeader.IsPracticeOperationalized`),
`GapLifecycleService.cs` (`GetHeaderAsync` tolerant read) — **rebuild
required**.
**UI:** `wwwroot/js/GapLifecycle/gap-detail.js`
(`isBlockedByUnresolvedObligations`, extended `applyTerminalInvalidMode`),
`Views/Practice/Partials/gap-detail.cshtml` (new amber banner + renamed
Obligations strip copy), `Views/Practice/Partials/gap-view.cshtml`
(renamed Obligations strip hint, read-only page).

---

## Why only the one triggering Obligation ever showed

`sp_practice_gap_sync_for_instance` (migration 245, re-issued unchanged
in shape by 356) is the single place every Obligation save — bulk adopt
and single local save alike, via
`ResolveWorkspaceService.SyncGapForInstanceAsync` — already funnels
through. Its `@current` set becomes both "does a gap exist" (the
creation gate) and "which Obligations are Active children under it" —
the exact set `gap-detail.cshtml`'s Obligations strip and Task Center's
`LinkedCount` both read. That set has always been populated with an
**INNER JOIN** to `implementation_status_master`, filtered
`status_code IN ('Not Implemented','Partially Implemented')`. An INNER
JOIN structurally drops any Obligation whose `implementation_status_id`
is `NULL` — the user's "Not Set", the database's "Not Started" per
migration 243's rank vocabulary — no matter how the surrounding gap
logic changes, because that Obligation can never produce a row to join
against in the first place. That is the entire reason a gap only ever
showed the one Obligation that triggered it: every *other* Obligation on
the same instance that happened to be Not Started was invisible to this
proc by construction, and nothing anywhere checked Obligation
completeness or Practice Operationalization before allowing analysis.

## The fix — two sets, not one

`sp_practice_gap_sync_for_instance` is re-issued from 356's exact body
with `@current` split in two:

* **`@current` (broadened).** `LEFT JOIN` +
  `COALESCE(status_code, 'Not Started')`, filtered
  `NOT IN ('Implemented', 'N/A')` — every Obligation that is not yet
  Implemented and not N/A (N/A is excluded from all rollups system-wide
  per migration 243). This is requirement #2's "every Obligation
  displayed under the gap", and it drives the existing 3a/3b/3c
  retire/add/recompute logic completely unchanged in shape — so
  `gap-detail.cshtml`'s Obligations strip and Task Center's counts
  broaden automatically. Neither `sp_custom_gap_linked_artefacts`
  (migration 317) nor `sp_task_center_gaps_list`'s own display logic
  needed to change to pick this up.
* **`@gap_trigger` (unchanged scope).** Exactly `@current`'s *old*,
  narrower filter — Not Implemented / Partially Implemented only. This
  alone gates the parent `practice_gap` `INSERT`, so requirement #1 is
  preserved exactly as it works today: a Practice whose only unresolved
  Obligations are Not Set still creates no gap at all — consistent with
  `sp_task_center_gaps_list` (243) and
  `sp_custom_gap_materialize_for_instance` (160), neither of which this
  migration touches, and both of which stay scoped to that same narrow
  trigger.

Steps 3a (retire), 3b (add, with the 356 `OUTPUT` capture), 3c (recompute
`gap_status`), and the post-commit auto-reopen step from 356 are all
byte-for-byte unchanged in shape — they simply now operate over the
broadened `@current`. A newly-Not-Started Obligation appearing on an
already-Delegated ("Analysed") gap's Practice now reopens it via the
exact same 356 mechanism a newly-Not-Implemented one always did — see
"Important Gap Lifecycle Behaviour" below for why this is still *one*
gap, not a new analysis cycle.

## Blocking Analysis — two new, narrowly scoped guards

`sp_custom_gap_analysis_save` is re-issued from 324's exact body with two
new guards, inserted immediately after the existing terminal-invalid
(173/`55142`) and re-analysis (324/`55143`) guards, and scoped **only**
to a gap materialized from a Practice Instance
(`gap_source_module_code = 'Implementation' AND source_reference_type =
'PracticeInstance'`) — a Custom, Assurance, Exception, or Risk-sourced
gap is never subject to either:

* **`THROW 55144`** — at least one Active `practice_gap_obligation`
  child remains under this instance's `practice_gap` (an Obligation
  currently displayed under the gap is still Not Implemented / Partially
  Implemented / Not Set). Reads `practice_gap_obligation` rather than
  recomputing from `practice_instance_obligation` directly, because that
  table **is** "what is currently displayed under the gap" — kept in
  step by `sp_practice_gap_sync_for_instance` on every Obligation save,
  the same source `gap-detail`'s Obligations strip already reads from
  (317).
* **`THROW 55145`** — the Practice Instance is not yet Operationalized.

## Which "Operationalised" rule — live dependency resolution, not the dormant table

Two candidates existed in the codebase; the live dependency-resolution
computation was confirmed as the one to use (Cowork asked; sir chose it
explicitly):

```sql
TotalDependencyCategories = COUNT(DISTINCT dependency_type_id)
    FROM practice_instance_dependency WHERE status='Active' AND dependency_type_id IS NOT NULL

ResolvedDependenciesCount = COUNT(*)
    FROM practice_dependency_resolution WHERE is_active=1

Operationalized = NOT Retired
               AND TotalDependencyCategories > 0
               AND ResolvedDependenciesCount >= TotalDependencyCategories
```

This is the exact computation duplicated in
`dbo.pm_get_practice_repository` and
`PracticeRepositoryService.QueryResolveFallbackAsync` — the same rule
already shown as **Operationalized** on the Repository/Register screens
and the Practice page. The 55145 guard and the new
`IsPracticeOperationalized` header column (below) both replicate it
inline, scoped to the one `practice_instance_id` in question.

The **rejected** candidate was the `practice_operationalization` table:
seeded with a `Configured / Partially Operationalized / Operationalized
/ Retired` vocabulary, but every reference to it joins on
`status = 'Resolved'` — a value that never appears in that seed — and no
`INSERT`/`UPDATE` writing to the table exists anywhere in this codebase.
It is dead scaffolding that can never match; using it would have either
permanently blocked every Gap Analysis or (if the join predicate were
"fixed" first) silently enforced nothing until someone separately built
out a whole unused subsystem.

## `sp_custom_gap_header` — one new additive column

`sp_custom_gap_header` (re-issued from 325's exact body) now also
projects `IsPracticeOperationalized` (`BIT`, `NULL` when there is no
linked Practice Instance), computed with the identical rule as the 55145
guard above via two `OUTER APPLY`s. This lets `gap-detail.js` show an
"awaiting Operationalization" reason on its blocked-banner from the same
header call that already loads everything else — no second round trip,
and no risk of the guard and the banner ever computing the rule two
different ways.

## Client-side: a third banner, reusing the existing lock mechanism

`gap-detail.js` already had two banners and one lock function —
`isTerminalInvalid()` / `isAlreadyAnalysed()` feeding
`applyTerminalInvalidMode()`, which disables every control inside
`#gapAnalysisForm` when locked. This migration adds a third check,
`isBlockedByUnresolvedObligations()`:

```js
function isBlockedByUnresolvedObligations() {
  const h = state.gapHeader || {};
  if (!h.practiceInstanceId) return false;
  if ((state.failedObligations || []).length > 0) return true;
  return h.isPracticeOperationalized === false;
}
```

`state.failedObligations` is captured inside `renderFailedObligations()`
— the function `refreshLinkedArtefacts()` already calls with
`result.failedObligations` from the very same `/linked-artefacts`
response the Task/Exception/Risk chips use, so this adds no second
request. `applyTerminalInvalidMode()` now computes a third `obligationsLocked`
flag (only when neither the red nor the green banner already applies —
an Invalid/Duplicate/Delegated gap is locked for its own reason
regardless), folds it into the overall `locked` flag that disables the
form, and shows a new amber `#gapObligationsBlockedBanner` explaining
which of the two conditions (unresolved Obligations, not yet
Operationalized, or both) is blocking analysis. This is a courtesy,
exactly like the existing two banners — the server enforces the same
rule independently via 55144/55145 regardless of what the client shows.

## The "Obligations to Resolve" strip — same data, broader by construction

The existing strip (migration 317, `gapFailedObligationsStrip` /
`gvObligationsStrip` on the read-only Gap View page) needed **no query
change** — it already reads live from `practice_gap_obligation` filtered
`status = 'Active'`, which 367's broadened `sp_practice_gap_sync_for_instance`
keeps in step automatically. Only copy changed, since "Implementation
Failure – Failed Obligation(s)" no longer describes a strip that can now
include Not Set Obligations that never "failed" anything: it is now
headed **"Obligations to Resolve"**, with hint text describing "every
Obligation under this Practice that is not yet Implemented."

## Important Gap Lifecycle Behaviour — still one gap, not a new cycle each time

`practice_gap` is one row per `practice_instance_id` (`UNIQUE`, migration
245) — this migration does not change that. Broadening `@current` does
not create a second gap or start a new analysis cycle when a Not Started
Obligation appears; it adds one more Active child to the **same**
`practice_gap` row, exactly the way a newly-Not-Implemented Obligation
already did before this migration. Migration 356's reopen-on-new-failure
logic — keyed off the very same 3b `INSERT`'s `OUTPUT` — already treats
that as "the same gap, now with one more thing to resolve," not a new
gap: the example in the request (Obligation 1 Implemented, 2 Not
Implemented, 3 Not Set → gap shows 2 and 3 → both must be resolved before
Analysis is allowed → then Analysis proceeds) is exactly what this
migration produces, with no separate handling needed for it.

## What did NOT change

* Gap **creation** is still triggered only by an actual Not Implemented
  / Partially Implemented Obligation (`@gap_trigger`) — never by a
  Practice whose only unresolved Obligations are Not Set.
* `sp_custom_gap_materialize_for_instance` (160) and
  `sp_task_center_gaps_list` (243) are untouched — Task Center's
  "Analysis" affordance stays scoped to the same narrow trigger it
  always has been.
* The `practice_operationalization` table and its never-populated
  `'Resolved'` join predicate are untouched — this migration only reads
  the live dependency-resolution CTEs, exactly as the
  Repository/Register screens already do.
* No `THROW` is added for a Custom/Assurance/Exception/Risk gap — both
  new guards are scoped strictly to
  `gap_source_module_code = 'Implementation' AND
  source_reference_type = 'PracticeInstance'`.
* `gaps.cshtml`'s list-level "N obligation(s)" note reads `LinkedCount`
  from `sp_gap_centre_list` (unchanged by this migration) and simply
  grows to reflect the broadened Active child count — no code change
  needed there. Its own "Analysis" row action only navigates to
  `gap-detail.cshtml` (materializing first if needed); it never calls
  `sp_custom_gap_analysis_save` directly, so the new guards are enforced
  exactly where the Save action actually lives.

## One thing this migration deliberately does not do

It does not retroactively reopen a gap that was already Delegated with a
Not Started (now newly-visible) Obligation underneath it, since nothing
here re-runs the sync for every instance on deploy. The verification
block in `367_....sql` reports, for every currently-open `practice_gap`,
how many Active children now sit under it broken down by the status that
put them there (`NotStartedCount` highlights exactly this case) — the
next Obligation save on that instance picks it up via the existing 356
mechanism, or an operator can re-run
`sp_practice_gap_sync_for_instance` by hand for a specific
`practice_instance_id` if an immediate reopen is wanted.
