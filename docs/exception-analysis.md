# Exception Analysis — developer notes

**Migration:** `257_exception_analysis_stage.sql`
**API:** `Api/Models/ExceptionCentreModels.cs`, `Api/Services/ExceptionCentreService.cs`,
`Api/Controllers/ExceptionCentreController.cs`
**Web:** `Web/Controllers/ExceptionCentreController.cs` (explicit proxies — no catch-all),
`Partials/exception-analysis.cshtml`, `wwwroot/js/ExceptionCentre/exception-analysis.js`,
`Partials/exception-centre.cshtml`, `wwwroot/js/ExceptionCentre/exception-centre.js`
**Screen:** `exception-analysis`, a `route` screen (no menu entry — it is always about one request)

---

## What changed, and why

An exception request used to go straight from raised to decided. The
Approve modal carried a **"Request details"** block — exception type,
owner, justification, risk/impact, linked practice, linked requirement
ref — which meant the *approver* was being asked to write the requester's
case and then judge it. That is backwards.

Sir's instruction: a Pending request offers **Analysis**, not Approve or
Reject. Analysis happens on its own page, carries the request detail,
lets remediation work be attached, and ends in **Submit for approval**.
Only then does an approver see Approve and Reject — with the effective
dates theirs to change.

## The lifecycle

```
Pending ──Analysis (saved any number of times, status unchanged)──┐
   │                                                              │
   └──────────────── Submit for approval ─────────────────────────┘
                              │
                    SubmittedForApproval
                       │            │
                   Approve       Reject
```

**One new status**, not two. Saving analysis leaves the request
`Pending`; only `sp_exception_request_submit_for_approval` moves it. A
half-finished analysis is not a state anybody needs explained.

`SubmittedForApproval` joins the `ck_pm_exception_request_status` CHECK.
Existing Pending requests are **not migrated** — Pending is the correct
starting point for the new flow, and 257's verification block reports how
many there are.

### The gate is conditional, deliberately

Approve and Reject now require `SubmittedForApproval` — **for
`GAP_CANDIDATE` only**. `TASK_SLA_EXTENSION` and
`TASK_PRIORITY_REDUCTION`, raised from Task Centre (192/193), have no
analysis stage and are still decided straight from `Pending`. Gating them
the same way would have stranded every SLA extension approval in the
product. The procedures enforce this, and the row menu mirrors it.

## Remediation tasks

`exception_request_task` — a link table, because one exception can need
several actions and one task can legitimately serve two exceptions.

**`exception_request.task_id` was NOT reused.** It already exists (192)
and already means something else: the task whose SLA extension or
priority reduction is being requested, with a filtered unique index
(`ux_pm_exception_request_task_sla_pending`) enforcing one open request
per task. Hanging remediation tasks off it would have collided with both
that rule and its meaning.

| Column | Why |
| --- | --- |
| `link_source_code` | `Created` or `Mapped`. "We raised this to fix it" and "this already existed and also covers it" are different claims |
| `status` | Soft unlink. The row survives so an audit can see the task *was* once put forward |

Uniqueness is on the **pair**, filtered to `status = 'Active'`, so a
re-link after an unlink is allowed where a plain unique constraint would
refuse.

**Both buttons open a popup.** New task opens a form; Map existing opens
a **checkbox grid**.

### The linked practice has to be derived (migration 258)

257 scoped the picker to `exception_request.linked_practice_id` — as
specified — but **nothing ever set that column**:

- `sp_exception_request_create` has accepted `@linked_practice_id` since
  166, but `sp_custom_gap_analysis_save`, the only thing that raises a gap
  exception, never passes it.
- The one place a value could be entered was the Approve modal's *Linked
  practice* picker, and 257 removed that block on the instruction that
  linked practice should be **displayed**, not chosen.

So every auto-raised exception carried NULL, the candidates procedure took
its `@practice_id IS NOT NULL` branch, and the grid came up empty — and a
task created from the page inherited the same NULL, so it could not appear
in the list it was created from.

Removing the picker was right. The mistake was assuming a column a form
used to fill would still be filled once the form was gone.

258 derives it instead of asking:

```
exception_request.custom_gap_id
  -> custom_gap.source_reference_type = 'PracticeInstance', .source_reference_id
  -> practice_instance.practice_id
```

1. **Backfill** every existing request whose practice resolves. A practice
   chosen by hand before 257 is left alone.
2. **`sp_exception_request_create` derives** when the caller supplies
   nothing — one place, so no caller has to remember.
3. **The candidates procedure derives at read time too** when the stored
   value is still NULL. A screen should not go blank because a
   denormalised column was never written.

An `OrgAssuranceGap`-sourced exception has no practice instance behind it
and stays NULL. The procedure returns a **second result set** naming the
practice it scoped to, so an empty grid says *which* — a practice with no
tasks, or no practice at all — instead of leaving the operator to guess.

258 also adds `SubmittedForApproval` to the create procedure's
"already open" duplicate guard. 257 introduced the status without
revisiting that check, which would have let a second request be raised for
a gap whose first one was sitting with the approver.

**The create procedure was re-emitted from 166 verbatim.** A first draft
written from memory silently dropped `record_status_id`, the
unknown-`exception_type_code` validation (55202), and the transaction, and
renamed the history action from `Create` to `Raise` — the same failure
mode as 249. Diffing against the real body caught it.

### The picker

`sp_exception_practice_task_candidates` offers every task
under the exception's `linked_practice_id`, as specified. Already-linked
tasks come back with `IsLinked = 1` rather than filtered out — they open
**ticked**, so the grid shows the current link state instead of asking the
operator to remember it. With no linked practice it returns nothing rather
than falling back to every task in the organisation; that would answer a
different question.

The ticks *are* the link set, so **Save applies the difference in both
directions**: newly ticked rows are attached, and a row that was ticked
on open and is now clear is detached. Three things follow from that, and
each is deliberate:

- The footer shows what Save would do (`2 to attach · 1 to detach`)
  **before** it is pressed, and detaching asks for confirmation. A
  checkbox grid that silently removes links is a trap.
- Only rows **currently on screen** can be detached. A search that hides
  an attached task must not detach it as a side effect of filtering.
- Saving with nothing changed sends no requests at all — it just closes.

Detaching is a soft unlink (`status = 'Removed'`), so the row survives for
audit and a re-tick revives it rather than creating a duplicate.

**New task creation does not reuse `_add-implementation-task-modal`.**
That partial opens `window.__openAddImplTask(instanceId, …)` and raises an
Implementation task against a practice *instance*. An exception carries a
practice, not an instance. The analysis page posts to the same
`/practice/api/tasks` endpoint Task Centre's own New Task uses, with the
exception's practice as `LinkedPracticeId` and `Exception` as the source,
then links the result.

## What left the forms

| Field | Where it went |
| --- | --- |
| Exception type, owner, justification, risk/impact | Analysis page |
| Linked practice | **Displayed** on the analysis page, not selected — it belongs to the request. A picker would let an analyst point the exception at a different practice than the one that raised it |
| Linked requirement ref | Removed |
| Compensating control | Removed |
| Approval note | **Stays on the approver's form**, still required — a decision with no recorded rationale is not reviewable |

The columns are untouched in every case. `sp_exception_request_approve`
keeps all its parameters and its COALESCE preservation, so omitting them
from the UI leaves whatever the analysis recorded; an older caller still
binds.

The approver's modal now renders the analysis **read-only** into
`#excApproveMeta`, so the decision is made with the case in view.

`sp_exception_request_get` returns `linked_practice_id` but not its name.
The page resolves the name from the module's existing practices lookup
rather than re-emitting that forty-column procedure to add a join — the
kind of rebuild that dropped half of 174's work when 249 did it.

## Submit is a real gate

`sp_exception_request_submit_for_approval` refuses an analysis with no
justification, no risk/impact, or no proposed effective window
(errors 55268 / 55269 / 55286 / 55287). Anything softer and Submit
becomes a button that forwards blank forms. The page checks the same four
before the round trip, so the operator is told immediately; the procedure
is what actually enforces it.

## The effective window (migration 260)

The analyst proposes it; the approver may overrule it; the overrule is
recorded.

| Column | Written by | Means |
| --- | --- | --- |
| `proposed_effective_from` / `proposed_effective_until` | `sp_exception_request_analysis_save` | what the analyst is **asking for** |
| `effective_from` / `effective_until` | `sp_exception_request_approve` | what was **granted** |

They are separate columns on purpose. The approved pair drives the
days-left badge, the Expire-due sweep and the gap's own extension;
writing a proposal into it would make an un-approved request look
approved to every one of those readers.

Optional on **save**, required on **submit** — a draft analysis can be
parked before the window is settled, and the gate is where the
requirement bites. `sp_exception_request_analysis_save` COALESCE-preserves
both, and validates the order against the values the row *will* hold, not
against what one partial save happened to send (error 55285).

`sp_exception_request_approve` pre-fills nothing itself — the modal does
that from `sp_exception_request_get` — but it does two things:

* a blank `@effective_from` now falls back to the **proposal** before it
  falls back to today. 257 defaulted straight to `SYSUTCDATETIME()`,
  which silently overrode a start date the analyst had justified;
* when the granted window differs from the proposed one, it writes a
  second history row, `action_code = 'EffectiveDatesChanged'`, carrying
  both windows and the approver. It is a **separate row** from `Approve`:
  the approval is one fact, overruling the analyst is another, and
  "who shortened this" should not have to be parsed out of an approval
  note.

### Traceability is only real if it is visible

`exception_request_history` had been written since 161 and read by
nobody. 260 adds `sp_exception_request_history_list` and surfaces the
whole trail — every `action_code`, not just the date change — in two
places: a **History** section on the analysis page, and inside the
approve modal so the decision is made with the record in view. A new
action code needs no new UI; unknown codes fall through to their raw
value.

| Method | Route | Returns |
| --- | --- | --- |
| `GET` | `/practice/api/exception-centre/{id}/history` | bare array of history rows, newest first |

A bare array, like the `tasks` and `attachments` listings — one shape for
every collection this controller returns. The service swallows a
`SqlException` here (logged, empty list) for the same reason it does on
the task panel: a database without 260 should not blank the screen.

`ExceptionAnalysisSaveRequest` gains `ProposedEffectiveFrom` /
`ProposedEffectiveUntil`, and `ExceptionRequestDetail` gains the same two
alongside the approved pair. Both are nullable — every request that
existed before 260 has no proposal, and a fabricated exception window is
exactly the thing the approver is supposed to judge.

## Re-emitted bodies

Both decision procedures were re-emitted, each from its **live**
ancestor — not from whichever version was easiest to find:

| Procedure | Ancestor | What that preserves |
| --- | --- | --- |
| `sp_exception_request_approve` | **166** | request-level fields, evidence capture, history row |
| `sp_exception_request_reject` | **193** | 176's risk auto-create **and** 192/193's task-side release; 193 is a strict superset of both |

Both keep their original result-set shapes (`ExceptionRequestId` +
`StatusCode`, and the reject's `RequestTypeCode`) because
`ExceptionCentreService` binds those names. 257's verification includes
explicit regression guards for the risk auto-create and the task-side
release — the two behaviours a careless re-emit drops.


## Approve dialog -- Review frequency select (2026-09-24)

**Sir's instruction:** the Approve Exception dialog's "Review frequency
(if applicable)" select was not loading -- it should be bound to the
existing Frequency Master, reusing the existing data source rather than
a new or hard-coded list.

**Root cause.** `Shared/exception-actions.js`'s `loadFrequencies()` was a
placeholder from when this dialog was still inside `exception-centre.js`:
it never called an endpoint at all, and populated the select with a
single hard-coded fake option, `{ frequencyId: -1, frequencyName:
"(free-text later)" }` -- its own comment said as much ("the frequency
master doesn't yet have a shared endpoint"). `excApproveReviewFrequency`
itself, and the save/read of `ReviewFrequencyId`/`ReviewFrequencyName`
through `sp_exception_request_approve`/`_get` (166), were already
correct and untouched by this.

**What the Frequency Master actually is.** `grac_practice.frequency_master`
(001) -- the same table `organization_committee.review_frequency_id`
(002) and `risk_register.review_frequency_id` (293) already reference.
293 added `grac_practice.sp_risk_review_frequency_list`, a thin read of
that table (`is_active = 1`, ordered by `display_order`) that Risk
Centre's Acceptance screen already binds its own "Review frequency"
selects to, via its own `GET .../risk-centre/review-frequencies`.

**Fix.** Exception Centre now has the equivalent endpoint, reusing that
exact procedure -- no new procedure, no new table, no changes to
`sp_risk_review_frequency_list` or `frequency_master` itself:

| Layer | What was added |
| --- | --- |
| `Api/Models/ExceptionCentreModels.cs` | `ExceptionReviewFrequencyRow` -- same shape as Risk Centre's `RiskReviewFrequencyRow`, kept as its own record rather than shared across modules, matching every other lookup row already in this file (`EvidenceTypeRow`, `ExceptionTypeRow`) |
| `Api/Services/ExceptionCentreService.cs` | `ListReviewFrequenciesAsync()` -- calls `grac_practice.sp_risk_review_frequency_list`, no parameters, same pattern as `ListEvidenceTypesAsync()` |
| `Api/Controllers/ExceptionCentreController.cs` | `GET lookups/review-frequencies` |
| `Web/Controllers/ExceptionCentreController.cs` | `GET lookups/review-frequencies` -- session-gated proxy, mirrors `lookups/evidence-types` |
| `Shared/exception-actions.js` | `loadFrequencies()` now fetches `lookups/review-frequencies` (cached once, same as `loadEvidenceTypes()`) instead of the hard-coded stub |

No database script -- `sp_risk_review_frequency_list` and
`frequency_master` were reused exactly as they already stood, and
`sp_exception_request_approve`/`_get` already carried `review_frequency_id`
end to end since 166. No `.cshtml` change -- `_exception-action-dialogs.cshtml`'s
`excApproveReviewFrequency` select already existed with the right id and
label; only the script that fills it was fixed.


## Add Custom Exception -- Related Obligation/Requirement and Related Gap ID removed (2026-09-24)

**Sir's instruction:** remove the "Related Obligation / Requirement" and
"Related Gap ID" fields from the Add Custom Exception form.

**What changed.** Both `<label>` fields (`newExcRequirementRef`,
`newExcGapId`) removed from `_exception-centre.cshtml`'s
`#excAddCustomModal`. In `exception-centre.js`: both ids dropped from
`openAddCustomDialog()`'s field-reset list, the Gap ID numeric-validation
block removed from `onAddCustomSubmit()`, and the create payload now sends
`linkedRequirementRef: null, customGapId: null` unconditionally instead of
reading them from the (now removed) inputs.

**What deliberately did not change.** Neither field was dropped from the
data model -- `LinkedRequirementRef` and `CustomGapId` stay exactly as
they are on `ExceptionRequestDetail`/the create, update and approve
request records, on `sp_exception_request_create`/`_update`/`_approve`,
and on the `exception_request` table itself. A Custom Exception created
from this form simply always supplies both as null now, the same as
every other optional field on this form the analyst leaves blank.
`exception-view.js` still shows "Related Obligation / Requirement" as a
fact row whenever a request has one -- unaffected, since a
GAP_CANDIDATE-sourced request still gets its `customGapId` assigned
automatically (not through this form), and `LinkedRequirementRef` can
still be set later during Analysis if that screen also captures it. This
form is the only thing that changed.


## Add Custom Exception -- layout/alignment and background scroll (2026-09-24)

**Sir's instruction:** fix this page's alignment, remove the scrolling, and
put Exception Description and Reason / Justification in the same row.

**Root cause of the misalignment.** `_exception-centre.cshtml` styled Title,
Description, Reason and the Related Control/Practice block with
`pm-form-grid-full`, meant to span the form's full width. That class is not
defined anywhere in `practice-management.css` (or any other stylesheet in
this project) -- the only rule that spans a `.pm-form-grid` cell full width
is a bare `.full` (`.pm-form-grid .form-field.full, .pm-form-grid label.full
{ grid-column: 1 / -1; }`). Because the class never matched, every field
above fell back to the grid's ordinary 2-column auto-flow, which is what
produced the odd, unbalanced-looking row pairing (Title's one-line input
next to Description's 3-row textarea, then Reason's textarea next to
Exception Type's short select). This is a pre-existing typo, not something
this change request introduced -- `risk-centre.cshtml`, `gap-detail.cshtml`
and `exception-analysis.cshtml` all carry the same `pm-form-grid-full`
non-class in places; only this form's own instances were in scope here and
were fixed.

**Fix.**

| Field | Before | After |
| --- | --- | --- |
| Exception Title / Subject | `label.pm-form-grid-full` (broken, paired with Description) | `label.full` -- genuinely full width, its own row |
| Exception Description | `label.pm-form-grid-full` (broken) | plain `label` -- paired with Reason |
| Reason / Justification | `label.pm-form-grid-full` (broken, paired with Exception Type) | plain `label` -- paired with Description (sir's request) |
| Related Control / Practice(s) | `div.pm-form-grid-full` (broken -- and missing `form-field`, so even a corrected class alone would not have matched `.pm-form-grid .form-field.full`) | `div.form-field.full` -- genuinely full width, matching the working pattern already used at `risk-centre.cshtml:1231` |

Exception Type/Owner and Valid From/Valid Until were already correctly
paired (neither ever carried the broken class) and are unchanged. Final
row order: Title (full) / Description + Reason (paired) / Exception Type +
Owner (paired) / Related Control/Practice (full) / Valid From + Valid Until
(paired).

**Background scroll.** `.pm-modal` is a fixed, full-viewport overlay
(`inset: 0`), but nothing locked the page behind it, so the Exception
Centre grid page could still scroll while this dialog was open -- the
scrollbar sir was seeing. `exception-centre.js`'s local `show()`/`hide()`
helpers (used for both `#excAddCustomModal` and the nested
`#newExcPracticeModal` practice picker) now set/clear
`document.body.style.overflow`, with an `anyOpen()` check so closing the
picker while Add Custom Exception is still open behind it does not
prematurely unlock the page. Scoped to this file's own two modals --
`.pm-modal` itself is shared with `risk-centre.cshtml` and
`gap-detail.cshtml`, which were not touched.

**What deliberately did not change.** No CSS file was edited -- `.full`
already exists and is already used correctly elsewhere (`risk-centre.cshtml`
alone has dozens of correct `label.full`/`div.form-field.full` instances);
this was a matter of using the class that already works, not adding a new
one. The same `pm-form-grid-full` typo also appears in
`_exception-action-dialogs.cshtml` (the Approve/Reject dialogs, 6
instances), `exception-analysis.cshtml` (5), `risk-centre.cshtml` (37),
`gap-detail.cshtml` (6) and `document-uploads.cshtml` (4) -- all left
alone here, out of scope for a request specifically about the Add Custom
Exception form. Worth a follow-up change request if sir wants those
cleaned up too.


## Exception View -- "Justification (analyst)" heading shortened to "Justification" (2026-10-15)

Note: this one is about `exception-view.js` / `exception-view.cshtml`
(migration 326's read-only full page, documented in the Practice
Management project memory as `task_view_and_exception_view`), not the
Analysis workflow this file otherwise covers -- there is no standalone
doc for that page yet, so the note lives here since it is the closest
Exception Centre changelog.

Change request: in the View page's **Reason / Justification** section,
the label read "Justification (analyst)" -- sir asked for only the
"(analyst)" part of the HEADING to go, not the field or its content.

First pass got this wrong -- dropped the whole field, reading the request
as "remove Justification". Corrected: `renderReason(d)` in
`exception-view.js` still reads `d.justification` and still renders it
exactly as before (same "nothing to show" guard, same position in the
section); only the label text changed, from `Justification (analyst)` to
`Justification`. Reason / Justification (requester) and Risk / Impact are
unaffected either way.

UI only, label text alone. No API or database change.

## 498 on production: "Invalid column name 'exception_number'" (2026-11-02)

Running `498_exception_designated_approver.sql` against production printed

```
Msg 207, Level 16, State 1, Procedure sp_exception_request_list, Line 23 [Batch Start Line 153]
Invalid column name 'exception_number'.
498 complete: designated approver added; submit/list/get re-issued; candidates proc ready.
```

— an error **and** a success line, which is the tell.

### What actually happened
`exception_request.exception_number` is owned by migration **470**, which had never been
applied to production. 498 re-issues `sp_exception_request_list` from the 472 body, and that
body projects `r.exception_number`. A re-issued procedure body is validated against the live
columns at CREATE time, so the missing column failed **that one** `CREATE OR ALTER` with
Msg 207 — which does not stop the script, only its own batch. Everything after it ran,
including the final `PRINT '498 complete...'`.

So production was left half-applied:

| 498 step | Outcome |
|---|---|
| `designated_approver_employee_id` column + FK | applied |
| `sp_exception_approver_candidates` | created |
| `sp_exception_request_submit_for_approval` | re-issued |
| `sp_exception_request_list` | **failed — still the 472 body** |
| `sp_exception_request_get` | re-issued |

The consequence that matters: the list procedure kept its old body, so it returns no
`DesignatedApproverEmployeeId` / `DesignatedApproverName` — the two fields the Exception Centre
grid needs to show Approve only to the designated approver. Submit would store an approver that
the list could not surface.

### The defect was in 498, not in production
This is the second time this exact trap has been hit (the first was 306 against a database
without 254). The house rule from that one — *when a migration re-issues an earlier proc body,
guard on every COLUMN that body reads, not just on the proc existing* — was not applied here:
498's only guard checked `designated_approver_employee_id`, the column it adds itself.

A sweep of 498's four procedure bodies against the `ALTER TABLE ... ADD` history shows they read
**20** columns owned by other migrations: nine from 166, three from 184, five from 192, two from
260 and one from 470. 498 now checks all twenty against `sys.columns` before writing anything,
and on a miss prints

```
ABORT (498): exception_request is missing column(s) that this migration's procedure bodies
read: exception_number (migration 470). Run the migration named beside each, in number order,
then re-run 498. Nothing was changed.
```

and sets `NOEXEC ON`, so the body of the migration is skipped and the "498 complete" line can
no longer appear. It names the owning migration rather than adding the column inline, because
470 also backfills `E-nnn` numbers and installs the per-organization sequence trigger —
half-applying that would leave numbering broken.

498 now ends with `SET NOEXEC OFF`, so an aborted run does not leave the operator's session
silently swallowing the next script.

### What the diagnostic found on production (2026-11-02)
- Of the 20 prerequisite columns, **19 present, 1 missing**: `exception_number` (470). So 166,
  184, 192 and 260 are all applied there; only 470 is not.
- `designated_approver_employee_id` and its FK: present.
- `sp_exception_request_submit_for_approval`, `sp_exception_request_get`: the 498 body.
- `sp_exception_request_list`: the old body, as predicted.
- `sp_exception_approver_candidates`: reported "OLD BODY" — a **false negative in the first
  version of the diagnostic**, not a real failure. Section 2 matched every body against
  `designated_approver_employee_id`, but that procedure is new in 498 and never mentions the
  column; it lists eligible approvers by menu permission. It now matches per procedure, on
  `55295` (its own error number) for the candidates proc and `DesignatedApproverName` for the
  two list/get procs.
- Gap side: `custom_gap.gap_number` **missing** (469) and `sp_gap_centre_list` does not project
  `GapNumber` (471). So production is behind on that pair too.

### Fix for production
Run in this order. The order is not cosmetic: **the last migration to re-issue a procedure
wins**, so a predecessor run after its successor silently reverts it.

| # | Script | Why, and why here |
|---|---|---|
| 1 | `469_gap_number_per_org_sequential.sql` | adds `custom_gap.gap_number`, backfills `G-nnn`, installs the per-organization trigger. Re-issues no procedure, so it cannot hit Msg 207. |
| 2 | `471_gap_centre_list_gap_number_column.sql` | re-issues `sp_gap_centre_list` to project `GapNumber`. Its only late dependency is `gap_number` itself, so step 1 must precede it. **471 is the newest owner of that procedure** — nothing after it re-issues `sp_gap_centre_list` — so running it now is safe. |
| 3 | `470_exception_number_per_org_sequential.sql` | adds `exception_request.exception_number`, backfills `E-nnn`, installs the trigger. Re-issues no procedure. |
| 4 | `498_exception_designated_approver.sql` | re-run. Idempotent, and its prerequisite guard now passes. |

`472_exception_list_exception_number_column.sql` is **optional and must not be run after 498**.
498's `sp_exception_request_list` body is a strict superset of 472's — same `ExceptionNumber`
plus the two designated-approver fields — so 472 adds nothing, and running it *after* 498 would
overwrite the 498 body and take the approver fields away again. Skip it, or run it between
steps 3 and 4.

Then re-run the diagnostic: section 1 all `present`, section 2 "has the 498 body" four times,
section 3 yes to both, section 5 `present` / yes, section 6 READY. Finally restart the Api and
Web tiers, as 498 already required.

## Exception Centre list: Owner column showed the requester (migration 527, 2026-11-10)

> "exception center le list lum athil click cheythu pokumbo kanunna page lum oru exception
> nte owner ne different ayi kanikunnundu."

**Cause.** The list's **Owner** column printed `requestedByName`, the person who raised the
request (`requested_by_employee_id`). Exception View and Exception Analysis show the exception's
**owner** (`owner_employee_id`, `sp_exception_request_get`.`OwnerName`). New Exception and
Analysis set the owner separately from the requester, so the two pages disagreed whenever the
owner was not the requester. The column change of 2026-09-22 used the requester because
`sp_exception_request_list` returned no owner. The Issues & Actions dashboard's **No owner** drill
(414) already filters on `owner_employee_id`, so it opened a list whose Owner cells were all
filled in.

**Change**

| Layer | File | What |
|---|---|---|
| SQL | `527_exception_list_owner.sql` (+ rollback = 498 body) | `sp_exception_request_list` also returns `OwnerEmployeeId` and `OwnerName`. Otherwise it is the 498 body verbatim: same rows, filters, order and paging. |
| Api | `ExceptionCentreModels.cs`, `ExceptionCentreService.ListAsync` | `ExceptionRequestRow` gains trailing optional `OwnerEmployeeId` and `OwnerName`, read tolerantly, so an Api deployed before 527 still lists. |
| API contract | `GET /api/practice/exception-centre` (list) | Each row now also carries `ownerEmployeeId` and `ownerName`. `requestedByName` is unchanged. |
| Web | `exception-centre.js`, `exception-centre.cshtml` | The Owner cell shows `ownerName`. An unassigned owner reads `--`, like Approved By. |

The Gap View exception card is unchanged: it labels the requester **Requested By**, which is correct.

**Deploy:** run 527, then deploy the Api and Web, then hard-refresh the browser. No Api restart is needed.
