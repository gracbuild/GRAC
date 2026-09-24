# Accept Risk list + bulk accept — implementation brief

Parts 1 and 2 of the Risk Acceptance work. Part 3 (Review Frequency) is
partly done: **migration 293 is written and verified**; its API and UI
are still outstanding. Do 293's API/UI first — bulk accept collects the
same frequency field and should reuse it, not duplicate it.

Everything below was established by reading the code, not assumed.

---

## Order to build

1. **293's API + UI** (frequency select on the acceptance page).
2. **Part 1** — the Accept Risk list page.
3. **Part 2** — bulk accept, which sits on part 1's selection.

## Part 1 — Accept Risk list page

### Template to copy
`sp_risk_review_due_list` (Review Risk's queue) and the Review Risk tab.
Do not invent a new shape; the requirement is explicitly "Review Risk
pole thanne".

### New procedure — `sp_risk_acceptance_due_list`
Model the signature on `sp_risk_review_due_list`. **Eligibility is
already defined** — do not re-derive it. `sp_risk_acceptance_save`
refuses in exactly three cases, and `sp_risk_acceptance_get` already
computes the same thing as `CanAccept` / `AcceptGuidance`:

```sql
status_code NOT IN (N'Closed', N'Retired')   -- else 56604
AND ISNULL(analysis_pending, 1) = 0          -- else 56605
AND treatment_option_code IS NOT NULL        -- else 56606
```

Reuse that CASE verbatim so the list can never offer a row the save
would reject. Note it does **not** require a residual score — 56606 is
the only treatment gate — so a Treat risk with no residual is eligible;
surface that as a badge, not an exclusion.

Must page: `@page_number` / `@page_size` plus
`COUNT(*) OVER () AS TotalRows` last in the projection
(`docs/grid-and-pagination-standard.md`). Include `AcceptedByRoleNames`
via `grac_practice.fn_employee_role_names` (291) if the list shows an
acceptor.

### API
`RiskCentreController` + `RiskCentreService`, mirroring the review-due
endpoint. **Check the query-parameter spelling** — Risk Centre's
register uses `pageNumber`, exception-centre and document-acks use
`page`. A grid sending the wrong one is silently ignored and looks like
a working pager.

### UI
A tab beside Review Risk, not a full page: it is a queue, and Review
Risk's queue is a tab. Mount `pm-grid` (`__pmGrid.attach`), send the
page, `setTotal(total, rows.length)`, `reset(true)` on every filter
change but **not** on Refresh. Row action opens the **existing**
acceptance flow — `openAcceptanceModal(riskId)` — unchanged.

## Part 2 — Bulk accept

### Template to copy
`sp_risk_bulk_review` (migration 270) and `openBulkReviewModal` /
`onBulkReviewSubmit` in `risk-centre.js`. Bulk review already solves the
same problem — many ids, one set of shared fields, per-row failures
reported without losing the successes — so follow it rather than
designing a second bulk mechanism.

### New procedure — `sp_risk_bulk_accept`
Takes an id list (270's delimited-string + `STRING_SPLIT` pattern) plus
the shared fields: `@next_review_date`, `@review_frequency_id` (293),
`@accepted_by_employee_id`, `@acceptance_note`.

**It must delegate to `sp_risk_acceptance_save` per risk, not
reimplement it.** That procedure owns every rule — the future-date check
(56601/56602), the closed/retired refusal, the analysis and
treatment-option gates, the employee-organisation check (56607/56608),
the history row and the status transition. A second writer would drift
from it, and 270's own header makes the same argument for review.

Per-row outcome, not all-or-nothing: report which succeeded and which
refused, with the refusal text. A bulk action that rolls the whole set
back because one risk was closed is worse than one that says so.

### UI
Checkbox column on the part 1 grid (bulk review's `selectedReviewIds()`
is the pattern), a bulk button enabled only on a non-empty selection,
and a modal collecting the shared fields — **including the frequency
select from 293**, same derive-the-date behaviour.

Validation: show the per-row refusals from the procedure rather than a
generic "Failed". Permissions are unchanged — the same grant that gates
single acceptance gates the bulk action.

## Gotchas already paid for

* **`data-object-name` is persisted.** Irrelevant here, but the same
  rule applies anywhere a label is composed for display: compose in the
  UI, never in the stored value.
* **Razor**: no bare `@` in a `.cshtml` comment — `@page_size` in a JS
  comment compiles as C# (CS0103), and `@` followed by a space is
  RZ1003. Say "the page-size parameter" instead.
* **Re-issuing a procedure**: extract it programmatically and diff the
  result against its source; never retype it. And check which migration
  holds the *current* definition — `sp_risk_acceptance_get` now lives in
  293, having passed through 264, 291 and 293.
* `database/293.tmp` is scratch left by a failed cleanup — safe to
  delete.
