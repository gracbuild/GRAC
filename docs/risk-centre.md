# Risk Centre — developer notes

Implements the BRD **"Risk Candidate Analysis and Risk Register"**
(Product: GRAC – Risk Management, Module: Risk Centre).

Migrations **204–207, 212–215**, on top of the placeholder Risk Centre shipped in
**169–172** and extended by **176** and **199**.

- **Phase A — 204–207**: the source model, the Initial Risk Analysis, the
  Risk Register, and both entry routes.
- **Phase B — 212–215**: the §19 approval gate, the §21 notification
  outbox, the §23 dashboard, and the §22 treatment-task opt-in.

---

## The two-stage assessment (migration 216)

The BRD's §7.1 treats the "Initial Risk Analysis" as one block of work
done **before** registration. In practice that gate was too heavy at the
front door: a candidate arriving from a Gap rarely carries enough to pick
a likelihood and an impact honestly, so demanding them produces invented
scores, not safer ones.

Migration 216 splits it:

| | Asks for | Where |
| --- | --- | --- |
| **Stage 1 — Assessment** | risk statement · threat · vulnerability · risk owner · business function | Risk Candidate |
| **Stage 2 — Analysis** | category · likelihood · impact → rating · cause · consequence · controls | Risk Register |

**§24 rule 1 still holds.** `risk_register.risk_analysis_id` is still NOT
NULL and `sp_risk_register_insert` still refuses an assessment it
considers incomplete. What changed is the *definition* of incomplete —
edited in the one procedure that owns it. Errors 56116–56119 (category,
likelihood, impact, rating) are **retired**, not reused, so an old log
line still means what it said. 56410 and 56411 replace them with threat
and vulnerability.

**Threat and vulnerability** come from `grac_practice.threat_master` and
`vulnerability_master`, copied from `dbo.tbl_threat_mst` /
`dbo.tbl_vulnerability_mst`. The copy **detects** the source column names
from the catalogue rather than assuming them: the live database spells
one of them `vulnarebility_id`, and a migration that only works on some
deployments is not a migration. The typo stops at the boundary — our
tables use the correct spelling. Id `0` is "Others" and requires a
free-text description, enforced by a CHECK *and* by the procedure.

**The §19 approval gate moved with the rating.** A rating threshold has
nothing to judge at registration time, and 212's fail-safe would have
demanded approval for every single registration. The gate now sits on
stage 2: when approval is required the new rating is held at `Pending`
and **the register keeps its previous rating** until
`sp_risk_register_analysis_approve` releases it. An approver who cannot
stop an unvalidated rating reaching the authoritative register is not
approving anything.

`risk_register.analysis_pending` marks a risk whose stage-2 work is
outstanding. It is filterable, not hidden — a registered risk with no
rating is work to do, not a data error.

---

## The second score — residual risk (migration 258)

Until 258 the register carried exactly one number: the **inherent**
rating from stage 2, the score a risk had *before* anyone treated it.
§22 lets an organisation raise treatment work and §17 gives it an
`UnderTreatment` / `Monitoring` lifecycle — but nothing could record what
the risk looked like **afterwards**. A register that only shows the
before-score cannot answer the question a board actually asks: *so where
are we now?*

| | Means | Produced by |
| --- | --- | --- |
| **Inherent** | likelihood × impact **before** treatment | `sp_risk_register_assess` (216) |
| **Residual** | likelihood × impact **after** treatment | `sp_risk_residual_analysis_save` (258) |

### One matrix, one resolver

Both scores go through **`sp_risk_rating_resolve`**, against the same
`risk_likelihood_master` / `risk_impact_master` / `risk_matrix_cell`
rows. No second scale, no second resolver, no hand-typed score — the
rating is not a parameter of the save proc and is not in the API request
body.

This is the load-bearing decision. Two scores produced by two methods are
not comparable, and a grid whose two rating columns are not comparable is
worse than a grid with one.

### Why a separate table, not more `risk_analysis` versions

`grac_practice.risk_residual_analysis` has the same shape as
`risk_analysis` — `residual_version` + `is_current` + a filtered unique
index — so §20 holds by construction and both audit trails read alike.

It is a **separate** table because the two are re-assessed on different
clocks. Re-scoring the inherent risk (new information about the threat)
and re-scoring the residual risk (new treatment landed) are different
events. Folding them into one version chain would mean every residual
save also bumped the inherent version — and walked straight into the §19
approval gate, which exists to guard the *inherent* rating.

**§19 does not apply to residual assessments.** The gate's threshold is
written against the rating a risk is judged by; a residual score is a
measurement of treatment, not a reclassification of the risk.

### The gate: treatment must have happened

`sp_risk_residual_analysis_save` refuses unless **both** hold:

- the inherent rating exists (`analysis_pending = 0`) — otherwise there
  is nothing to be residual *to* (**56454**); and
- `status_code IN (UnderTreatment, Monitoring, Accepted)` — treatment is
  under way, has been done, or the organisation formally accepted the
  risk instead of treating it.

`Active` is refused separately (**56456**) because it means the treatment
decision has not been taken yet; `Closed` / `Retired` are refused as
terminal (**56455**). Three refusals, three messages, because each needs
a different action from the operator. The row menu mirrors all three as
`disabledReason` text — an affordance; SQL is the rule.

### Denormalised onto the register too

Same argument 205 made for the inherent block: §9 makes the register
authoritative, and an authoritative record that renders by joining to a
mutable child is not authoritative. The grid also filters and sorts on
it, and a join to a versioned child table on every list page is fine at
50 risks and not at 5,000.

`residual_pending` mirrors `analysis_pending` exactly — same `DEFAULT 1`,
same filtered index — so the two "still to do" flags behave identically
and the grid badges them the same way. Every pre-258 row starts at 1,
which is a statement of fact rather than a backfill: no risk has ever had
a residual assessment.

Each version freezes the inherent rating **as it stood at the time**
(`inherent_rating_code/name/score` on the residual row) and the
`inherent_analysis_id` it was measured against. Without that, a residual
of "Medium" is unreadable a year later — was the inherent High at the
time, or Critical? — and a later re-score of the inherent risk would
silently rewrite what the assessment claimed to have reduced.

### Error range

**56450–56462.** Reserved for 258 alone; 216 ended at 56446.

---

## The one rule

> BRD §1 — *"Every risk entering the Risk Register must pass through an
> initial Risk Analysis, irrespective of its source."*

Everything below exists to make that true by construction rather than by
convention:

| Where | How |
| --- | --- |
| Schema | `risk_register.risk_analysis_id` is **NOT NULL**. There is no INSERT that does not name the analysis that justified it. |
| Procedures | Exactly one writer, `sp_risk_register_insert`, and it holds the mandatory-field gate. Both entry routes call it. |
| API | No endpoint writes `risk_register` directly. |
| UI | "Register as risk" is disabled until a current analysis exists — and the server refuses anyway if it is incomplete. |

---

## Migration order

Run in order. Each one aborts with a `PRINT` explaining what is missing
if its prerequisite has not run.

| # | File | What it adds |
| --- | --- | --- |
| 204 | `204_risk_scoring_masters.sql` | `risk_source_master`, `risk_category_master`, `risk_likelihood_master`, `risk_impact_master`, `risk_matrix_cell`, `sp_risk_scoring_seed_default`. Seeds a 5×5 default per active organisation. |
| 205 | `205_risk_register_schema.sql` | Generalises `risk_candidate` (source model, BRD §16 statuses, nullable `custom_gap_id`); adds `risk_analysis`, `risk_register`, `risk_register_history`. |
| 206 | `206_risk_register_procs.sql` | 15 new procedures + 4 strict-superset rewrites of 170's. |
| 207 | `207_risk_centre_source_wiring.sql` | `sp_risk_candidate_create` superset: any Centre can raise a candidate. |
| 212 | `212_risk_org_config_and_approval.sql` | `org_risk_config`, `org_risk_config_notify_role`, the §19 approval gate, and the deprecation of legacy Accept. Rewrites `sp_risk_candidate_register` and `sp_risk_candidate_accept`. |
| 213 | `213_risk_notification_outbox.sql` | `risk_notification_outbox` + a history sweep. Modifies nothing. |
| 214 | `214_risk_dashboard_procs.sql` | `sp_risk_dashboard_counts` (11 result sets) and `sp_risk_candidate_ageing`. Read-only. |
| 215 | `215_risk_treatment_task_optin.sql` | `sp_risk_treatment_task_raise` / `_list`, and one new `source_type_code` value. |
| 216 | `216_risk_threat_vulnerability_assessment.sql` | `threat_master`, `vulnerability_master`, the two-stage split, `sp_risk_register_assess` / `_apply_analysis` / `_analysis_approve`, and strict-superset rewrites of `sp_risk_register_list` / `_get`. |
| 258 | `258_risk_residual_analysis.sql` | `risk_residual_analysis`, the `residual_*` block on `risk_register`, `sp_risk_residual_analysis_save` / `_get` / `_history`, and strict-superset rewrites of `sp_risk_register_list` / `_get`. |
| 261 | `261_risk_treatment_mapping_schema.sql` | `risk_practice_map`, `risk_asset_map`, `risk_asset_map_source`; the treatment / acceptance / review columns on `risk_register`; `treatment_option_code` + `analysis_purpose_code` on `risk_analysis` and `risk_residual_analysis`; a backfill of `linked_practice_id` from the gap chain. Schema only. |
| 262 | `262_risk_mapping_procs.sql` | `fn_risk_practice_assets` (inline TVF) and six mapping procedures. Creates only new objects. |
| 263 | `263_risk_treatment_option.sql` | `sp_risk_treatment_option_set` / `_task_ensure` / `_state` / `_sync`, and a strict-superset rewrite of `sp_risk_residual_analysis_save`. |
| 264 | `264_risk_acceptance_review_procs.sql` | `vw_pm_risk_workflow_stage`, acceptance / review / calendar procedures, and strict-superset rewrites of `sp_risk_register_list` / `_get`. |
| 265 | `265_risk_dependency_mapping_schema.sql` | `risk_dependency_map` / `_source` replacing the asset-only pair (rows carried across), and `sp_risk_register_list` / `_get` rewritten again for `MappedDependencyCount`. |
| 266 | `266_risk_dependency_procs.sql` | `fn_risk_practice_dependencies` and the category-aware mapping procedures; retires 262's asset-only objects. |
| 267 | `267_dependency_mappable_flag.sql` | `dependency_type_master.is_dependency_mappable`, seeded to the five Operationalize offers; rewrites `fn_risk_practice_dependencies` and `sp_risk_mapping_get` to filter on it. |
| 293 | `293_risk_review_frequency.sql` | `risk_register.review_frequency_id` (FK to `frequency_master`), `sp_risk_review_frequency_list`, and re-issues of `sp_risk_acceptance_save` (new `@review_frequency_id`) and `sp_risk_acceptance_get` (two frequency columns) — the latter extracted from **291**, not 264, so `AcceptedByRoleNames` survives. |
| 294 | `294_risk_bulk_review_frequency.sql` | Re-issues `sp_risk_bulk_review` from 270 with `@review_frequency_id`, passed to `sp_risk_acceptance_save` on the Accepted path and COALESCEd into the review stamp otherwise. New refusal 56726 (unknown/inactive cadence), new `review_frequency_id` field-change audit row. No schema change; result shape unchanged. **Also fixes 270's leaked inner result sets** — see below. |
| 299 | `299_status_drives_acceptance.sql` | **`status_code = 'Monitoring'` now routes a risk to the Accept tab**, replacing 296/297's null-date rule. Review always sets Monitoring and records the proposed cadence; bulk review keeps the reviewer's date again. View + 2 procedures. |
| 298 | `298_suppress_result_on_composed_procs.sql` | Adds `@suppress_result` to `sp_risk_acceptance_save` and `sp_risk_register_status_set`, and rewrites both bulk procedures to call them plainly instead of via `INSERT ... EXEC`. **Fixes a defect 294/295 introduced** — see below. Four procedures re-issued; no schema change. |
| 297 | `297_bulk_review_returns_to_acceptance.sql` | Re-issues `sp_risk_bulk_review` so `next_review_date` is **assigned, not COALESCEd** — a blank date clears the schedule and 296 routes the risk to `AcceptanceDue`. Also makes the `@applied` test and the date audit row NULL-safe, and stops the report claiming a cleared date survived. |
| 296 | `296_reviewed_risk_returns_to_acceptance.sql` | Re-issues `vw_pm_risk_workflow_stage`. A ready risk with no `next_review_date` is now `AcceptanceDue`, and `Tolerate` is decided entirely inside its own branch. Fixes two stranding defects — see below. View only; no data written. |
| 295 | `295_risk_bulk_accept.sql` | `sp_risk_bulk_accept` — composes `sp_risk_acceptance_save` over a selection with **no review stamp**. Creates one new procedure and modifies nothing. Error range 56750–56769. Backs the Accept Risk tab. |

Rollbacks exist for all seventeen, in reverse order:
`267 → 266 → 265 → 264 → 263 → 262 → 261 → 258 → 216 → 215 → 214 → 213 → 212 → 207 → 206 → 205 → 204`.

**Three rollbacks need an earlier file re-run afterwards**, and they all
have the same shape: the migration *rewrote* a procedure that existed
before it, so dropping its own objects is not enough — the rewritten
procedure would still hold the newer body, referencing objects the
rollback has dropped. Every one of those files is `CREATE OR ALTER` and
idempotent, so re-running it is safe, and each rollback's own `PRINT`
says so.

| Rolling back | Re-run afterwards | Because it rewrote |
| --- | --- | --- |
| 258 | 216 | `sp_risk_register_list` / `_get` |
| 263 | 258 | `sp_risk_residual_analysis_save` |
| 264 | 258 | `sp_risk_register_list` / `_get` |
| 265 | 262 **and** 264 | it drops the asset tables 262's procs use, and rewrites 264's list/get |
| 266 | — | drops only its own and 262's objects |
| 267 | 266 | it rewrites `fn_risk_practice_dependencies` and `sp_risk_mapping_get` |

**265's rollback loses data it cannot carry back.** `risk_asset_map` holds
assets only, so every dependency mapped in any *other* category is
dropped. The rollback prints a per-category count of what is about to go
before it goes, and proceeds — a rollback that silently discarded most of
the mappings would be worse than one that says so.

**264's rollback refuses to drop `vw_pm_risk_workflow_stage`** while
`sp_risk_register_list` / `_get` still hold 264 bodies that JOIN it.
Dropping the view first would leave every Risk Register read failing with
"Invalid object name" — a symptom whose cause is in a different file. The
guard reads `sys.sql_modules` and aborts with the remedy.

**261's rollback refuses while 262/263/264 procedures are installed.**
They reference the tables and columns it drops, and dropping underneath
them turns a drop-time error into a run-time one.

Two rollbacks **refuse** rather than destroy:

- **204** refuses while 205's tables exist — dropping the scale under
  stored ratings would leave ratings nobody can interpret.
- **212** refuses while 213 exists — the sweep reads
  `org_risk_config.notifications_enabled`.

**215's rollback refuses step 2 only.** Narrowing a CHECK is not the
harmless inverse of widening one: if any treatment task was raised with
`source_type_code = 'RiskRegister'`, restoring the original constraint
would orphan real remediation work. The script leaves the wider CHECK in
place and prints what to inspect. A permanently slightly-wide CHECK is a
trivial cost; deleting somebody's remediation tasks to tidy a constraint
is not.

### The 205 → 207 window

205 makes `risk_candidate.source_type_code` NOT NULL, but 172 and 176
call the *170* version of `sp_risk_candidate_create`, which knows nothing
about it. 205 therefore adds `DEFAULT N'Gap'` on that column, so gap
analysis saves keep working if a deployment lands 205 without 207. 207's
backfill then repairs the `source_record_id` those rows are missing, and
is idempotent — safe to re-run.

---

## Data model

### `risk_candidate` — generalised (205)

169 built this with `custom_gap_id BIGINT **NOT NULL**`, which made the
Gap Centre the only possible source. BRD §4A and §13 both contradict
that, so 205 replaces the invariant rather than the table:

```
custom_gap_id      NOT NULL  ->  NULL          (kept, still FK'd, still used by Gap)
source_type_code   (new)     ->  NOT NULL, FK risk_source_master
source_record_id   (new)         the Centre's own record id
source_reference   (new)         display label, e.g. 'GAP-101'
source_description (new)         §10 "original observation / trigger", frozen
source_centre_code (new)         denormalised for the §10 navigation link
```

Plus `identified_dt` (§6.2 "Date Identified" — deliberately *not*
`requested_dt`, so candidate ageing in §23 measures from discovery, not
triage), `business_unit`, `assigned_analyst_employee_id`,
`clarification_note` / `clarification_requested_dt`,
`duplicate_of_risk_id`, `registered_risk_id`, and
`candidate_number` -- `RC-001`, sequential per organisation, a regular
column generated by `sp_risk_candidate_create` (was a computed
`RC-<org>-<id>` until 378 -- see "Risk Candidate ID / Risk ID reformat"
near the end of this document).

### Status vocabulary — mapped, not replaced

| BRD §16 | Stored code | Note |
| --- | --- | --- |
| New | `Pending` | 169's word kept; 172, 176 and 199 write it today. The UI labels it "New". |
| Under Analysis | `UnderAnalysis` | new |
| Clarification Required | `ClarificationRequired` | new |
| Analysis Completed | `AnalysisCompleted` | new |
| Registered | `Registered` | new |
| Rejected | `Rejected` | existing |
| Closed as Duplicate | `ClosedAsDuplicate` | new |
| — | `Withdrawn` | pre-BRD, retained |
| — | `Accepted` | **legacy**, see below |

Renaming `Pending` would have broken three live migrations for a cosmetic
gain. Mapping cost one comment.

### `risk_analysis` (205) — BRD §7.1, versioned

A table, not columns on the candidate, for three reasons:

1. **§20** — *"Previous risk ratings and analysis values shall not be
   overwritten without retaining historical versions."* Columns hold one
   value; rows hold every one.
2. **§4B / §11** — a Custom Risk has no candidate. Columns on the
   candidate would force a second copy of every §7.1 field for the custom
   route, which **§12** explicitly forbids.
3. **§10** — the traceability chain
   `Register → Analysis → Candidate → Source` has four nodes, so the
   third one needs an identity.

`analysis_scope_code` is `Candidate` (Route A) or `Custom` (Route B).
Every save writes a **new row** with `analysis_version = previous + 1`
and flips `is_current`; a filtered unique index
(`ux_pm_risk_analysis_current`) permits exactly one current version per
candidate.

Scale values are stored as **code + name + level**. The level keys the
matrix; the name is frozen so renaming "Possible" to "Occasional" next
year does not silently rewrite history.

### `risk_register` (205) — BRD §9.1

Every §9.1 field is a column here **even where the analysis holds the
same value**. That duplication is deliberate: §9 makes the register
authoritative, and an authoritative record that renders by joining to a
mutable analysis is not authoritative.

- `risk_analysis_id` **NOT NULL** — the §1 invariant.
- `source_type_code` **NOT NULL** — §24 rule 7, *"Every registered risk
  shall have a defined source."*
- `risk_number` -- `R-001`, sequential per organisation, a regular
  column generated by `sp_risk_register_insert` (was a computed
  `RSK-<org>-<id>` until 378).
- `linked_asset_id` / `vendor` / `practice` / `obligation` / `control` are
  **soft references**. A hard FK per Centre would make Risk Centre depend
  on every module that can name a risk — the coupling §13 asks us to
  avoid.
- §17 statuses: `Active | UnderTreatment | Accepted | Monitoring | Closed | Retired`,
  with a CHECK that `Closed`/`Retired` must carry a `closure_reason`.

### The FK cycle

`risk_candidate.registered_risk_id → risk_register` and
`risk_register.risk_candidate_id → risk_candidate` point at each other.
Both are nullable, so the cycle is inert. Both directions are stored
rather than one derived because the Candidates grid and the Register grid
each need their own direction on a hot path — the same reasoning as
`practice_task.task_candidate_id` (197 §3).

---

## Scoring is data, not code

BRD §7: *"The actual scoring methodology shall be configurable based on
the organisation's risk framework."*
BRD §12: both routes reuse *"the same risk categories, scoring
methodology, likelihood scale, impact scale, risk matrix"*.

Both sentences point at one thing: the scale must be **per-organisation
data**, and there must be exactly **one copy**.

`risk_matrix_cell` stores the whole grid rather than a formula, because
real GRC matrices are not symmetric and are rarely a simple product — an
organisation routinely promotes (rare × catastrophic) to High. The seeded
default does exactly that: `likelihood × impact` banding, with two
overrides — a Severe impact is never Low however rare, and an Almost
Certain likelihood is never Low however mild.

`rating_code` is free text on purpose. Some frameworks use
Low/Medium/High/Critical, others 1–4 or colour bands. `sp_risk_rating_resolve`
never interprets the code; it copies it.

**Source master is global, the rest are org-scoped.** A source is a GRAC
structural fact (there *is* a Gap Centre), not an organisational
preference. Categories and scales are preference.

---

## The two routes

```
Route A   Source ──▶ Risk Candidate ──▶ Initial Risk Analysis ──▶ Risk Register
Route B                   Custom Risk Creation + Analysis ──────▶ Risk Register
```

Route B has **no candidate stage** (§4B: *"no unnecessary intermediate
Risk Candidate stage"*; §11: *"the user shall not have to first create a
separate candidate and then reopen it for analysis"*).
`sp_risk_candidate_create` throws **56203** if anyone tries to raise a
candidate with `source_type_code = 'Custom'` — a second, unanalysed path
into the register is exactly what §1 forbids.

### How §12 is enforced

Not by writing two careful procedures. By having **one**:

```
sp_risk_analysis_save     writes the analysis for BOTH routes
sp_risk_register_insert   writes the register row for BOTH routes,
                          and owns the mandatory-field gate

Route A   sp_risk_analysis_save → sp_risk_candidate_register → sp_risk_register_insert
Route B   sp_risk_custom_create → sp_risk_analysis_save
                                → sp_risk_register_insert
```

Neither route can score differently, use a different scale, or skip a
mandatory field, because neither route *contains the code* that would let
it.

### Mandatory fields

§7.1 lists what the analysis "shall support"; §25 says mandatory
information "must be completed before registration" without enumerating
it. `sp_risk_register_insert` enumerates the smallest set that makes a
register entry meaningful under §9.1:

`risk_statement`, `risk_category_code`, `likelihood`, `impact`,
`inherent_rating` (derived, so really a matrix-coverage check),
`risk_owner_employee_id`.

Errors **56115–56120**. If an organisation needs a different set, this is
the **one** place to change it — which is the point of routing both
routes through one procedure.

---

## Duplicate detection (§15)

`sp_risk_duplicate_check` is **advisory and never blocks**. §15 gives the
analyst three outcomes — continue with justification, link, or close as
duplicate — so the proc reports and the human decides.

Weighted score over the attributes §15 lists:

| Signal | Score |
| --- | --- |
| Same `(source_type_code, source_record_id)` | 50 |
| Similar title (first 40 chars) | 30 |
| Similar statement (first 60 chars) | 25 |
| Same category | 10 |
| Same business unit | 5 |

Default threshold 30. `Closed` and `Retired` risks are excluded —
re-raising a risk that was deliberately closed is a legitimate act, not a
duplicate.

Leading-fragment `LIKE` is a poor similarity metric, but it is
index-friendly and, more importantly, **explainable to an auditor**,
which a fuzzy score is not. The UI runs it before registration on both
routes.

---

### The registration note used to be asked for twice, effectively

**The complaint:** clicking **Save & register** on the assessment form
saved the assessment, closed that form, and *then* opened a second small
dialog asking for an optional "Registration note" -- so registering felt
like two separate, disconnected asks: fill in the assessment, save it,
and only afterwards discover there was one more thing to answer.

**What it was.** The note was always optional and always went to the
same two places (`risk_register_history` and `risk_analysis.
decision_note`, via `sp_risk_candidate_register` / `sp_risk_register_
insert`), but it was collected with a `dlg.prompt()` inside `doRegister`,
fired only after `onAnalysisSubmit`'s Save & register path had already
saved the assessment and closed its modal. Nothing was wrong with the
data path -- this was purely a sequencing problem in the front end.

**The fix (JS + Razor only, no API or database change).** The note is
now a field on the assessment form itself (`riskAnalysisModal`, id
`anRegistrationNote`), read the same way owner and business function
are, so it is answered on the same page, before Save. `startRegister`
now takes that value as a parameter and carries it through the §15
duplicate-check step (`state.pendingRegisterNote`); `doRegister` no
longer prompts at all -- clicking **Save & register** is itself the
confirmation, and if §15 finds a likely duplicate, that dialog is a
distinct, substantive warning about a possible double-entry, not a
second ask about the note. `POST /{id}/register`'s payload shape is
unchanged (`{ registrationNote }`), so this needed no procedure and no
API change -- see `risk-centre.js`, `startRegister` / `doRegister`.

---

## API

Base: `/api/practice/risk-centre` (API tier)
Proxy: `/practice/api/risk-centre` (Web tier, session-gated, org-guarded,
caller stamped from session)

### Candidates (169–172, unchanged routes)

| Method | Route | Notes |
| --- | --- | --- |
| GET | `/?organizationId=&statusCode=&sourceTypeCode=&page=&pageSize=` | `sourceTypeCode` is new |
| GET | `/{id}` | now returns the source + analysis fields |
| POST | `/{id}/accept` | **legacy**, see below |
| POST | `/{id}/reject` | §8B |
| POST | `/{id}/withdraw` | |
| GET/POST | `/{id}/attachments`, `/attachments/{attachmentId}` | unchanged |

### Risk Register (204–207)

| Method | Route | BRD |
| --- | --- | --- |
| GET | `/scoring-options?organizationId=` | §7, §12, §13 |
| GET | `/{id}/analysis` | §7.1 current version |
| GET | `/{id}/analysis/history` | §20 |
| POST | `/{id}/analysis` | §7 — writes a **new version** each call |
| POST | `/{id}/assign` | §6.2, §18 |
| POST | `/{id}/clarify` | §8C |
| POST | `/{id}/close-duplicate` | §15 |
| POST | `/{id}/register` | §8A — Route A |
| POST | `/duplicate-check` | §15 |
| POST | `/custom` | §4B, §11 — Route B |
| GET | `/register?organizationId=&statusCode=&sourceTypeCode=&categoryCode=&ratingCode=&ownerEmployeeId=&search=&page=&pageSize=` | §9, §23 |
| GET | `/register/{riskId}` | §9.1 + §10 chain in one row |
| POST | `/register/{riskId}/status` | §17 |
| POST | `/register/{riskId}/owner` | §18 |

### Residual risk (258)

| Verb | Route | BRD |
| --- | --- | --- |
| POST | `/register/{riskId}/residual` — body `{ residualLikelihoodCode, residualImpactCode, treatmentSummary, residualControls, analystRemarks }` | §9.1, §22 — writes a **new version** each call |
| GET | `/register/{riskId}/residual` | current version; **204** when none exists |
| GET | `/register/{riskId}/residual/history` | §20 — every version, newest first |

`/register` gains two filters — `residualRatingCode` and `residualPending`
— alongside the existing `ratingCode` / `analysisPending` pair, and its
rows gain `residualRatingCode`, `residualRatingName`,
`residualRatingScore`, `residualLikelihoodName`, `residualImpactName`,
`residualAssessedOn` and `residualPending`.

**No rating in the request body.** The residual score is resolved
server-side by `sp_risk_rating_resolve` — the same procedure the inherent
rating uses, against the same matrix. A client cannot supply a score, and
the two rating columns on the grid are therefore comparable. That is the
whole reason it is safe to put them side by side.

`GET /register/{riskId}/residual` answers **204, not 404**, when nothing
has been assessed. A newly registered risk having no residual assessment
is its normal state, and answering `NotFound` would make the screen
report a missing risk when the risk is fine.

The POST body gains `treatmentOptionCode` in **263** — the residual
analysis is a full analysis and may conclude with a different decision.
It is sent only when the probe confirms the procedure declares it, so a
database still on 258 degrades rather than failing with "too many
arguments".

### Scope, treatment, acceptance and review (261–264)

| Verb | Route | Notes |
| --- | --- | --- |
| GET | `/register/{riskId}/mapping` | practices + assets, each asset already carrying `sourceLabel` |
| GET | `/register/{riskId}/mapping/options` | only what is still mappable, with `assetsFromPractice` per practice. **No live caller** — it fed the flat practice `<select>` that migration 282 replaced with the cascading Practice Picker; `riskMapping.refresh()` fetched it and discarded the result until that was dropped. Route kept, unused. |
| POST | `/register/{riskId}/practices` | maps a practice **and inherits its assets**; mapping twice is a no-op, not an error |
| DELETE | `/register/{riskId}/practices/{practiceId}` | returns `assetsRemoved` **and** `assetsKept` |
| POST | `/register/{riskId}/assets` | direct mapping; no practice asked for or inferred |
| DELETE | `/register/{riskId}/assets/{assetId}` | removes the *direct reason*; `assetRemoved: false` + `remainingSources` when a practice still reaches it |
| POST | `/register/{riskId}/treatment-option` | the decision **and** its dispatch; `taskCreated` and `nextStep` say what happened |
| GET | `/register/{riskId}/treatment-state` | counts, task list, `residualAvailable` **and `reason`** |
| POST | `/register/treatment-sync` | idempotent sweep; `riskRegisterId` **or** `organizationId` |
| GET | `/register/{riskId}/acceptance` | current acceptance + `canAccept` and `acceptGuidance`; `reviewFrequencyId` / `reviewFrequencyName` since 293 |
| POST | `/register/{riskId}/acceptance` | `nextReviewDate` **required**, must be future; optional `reviewFrequencyId` (293) |
| GET | `/review-frequencies` | 293 — the Review Frequency options, each with `frequencyValue`, `frequencyUnit`, `isCustom` |
| POST | `/register/bulk-accept` | 295 — accept a selection; `nextReviewDate` **required**. 200 with `skippedCount`, not "all accepted" |
| GET | `/register?workflowStageCode=AcceptanceDue` | the Accept tab's list — no endpoint of its own |
| POST | `/register/{riskId}/review` | delegates to `sp_risk_register_assess` |
| GET | `/review-due` | `next_review_date <= today`; `includeFutureDays` widens the horizon |
| GET | `/review-calendar` | one row per risk in a date window, shaped for a month grid |

`/register` gains three more filters — `treatmentOptionCode`,
`workflowStageCode` and `reviewDue` — and its rows gain the treatment,
acceptance, review, stage and scope-count fields.

**Every gate returns its reason, not just a boolean.** `residualAvailable`
comes with `reason`; `canAccept` comes with `acceptGuidance`. A disabled
button that cannot say why is a dead end, and the row menu's
`disabledReason` entries are fed from the same wording.

**The DELETE routes stamp the actor from the session, not the client.**
A DELETE has no body to stamp into, so the Web tier appends
`actorEmployeeId` and `caller` to the query string from session identity
and drops anything the client sent — otherwise an unmapping could be
attributed to somebody else.

**`treatment-sync` guards on shape.** With `organizationId` it takes the
full org guard; with only `riskRegisterId` it takes the session guard,
because there is no organisation in the URL to check —
`TryGuardOrganization` would 400 the single-risk form the register screen
actually calls.

### Impact Details -- withdrawn (309)

There are no impact-detail routes. An earlier revision added
`impact-areas`, `impact-details` and `dependency-obligations` (plus a
derived `/register/{riskId}/obligations`) over migration 309, and all of
it was withdrawn: "Impact Details" on the risk pages is the existing
by-category table of impacted assets, vendors and people, saved through
the dependency routes above over `risk_dependency_map` (265).

The leftovers, their banners and migration 309's abort are catalogued in
[risk-obligation-structure.md](risk-obligation-structure.md#what-was-withdrawn).
Do not re-add these routes without reading it.

### Phase B (212–215)

| Method | Route | BRD |
| --- | --- | --- |
| GET | `/config?organizationId=` | §19, §22 |
| POST | `/config?organizationId=` | §19, §22 |
| POST | `/{id}/submit-approval` | §19 |
| POST | `/{id}/approve` — body `{ decision: "Approve" \| "Return", remark }` | §19 |
| GET | `/approval-queue?organizationId=&page=&pageSize=` | §19, §23 |
| POST | `/notifications/sweep?organizationId=&sinceHours=&maxEvents=` | §21 |
| GET | `/notifications?organizationId=&statusCode=&notifyEventCode=&subjectTypeCode=&subjectRecordId=&recipientEmployeeId=` | §21 |
| GET | `/notifications/counts?organizationId=` | §21 |
| POST | `/notifications/{notificationId}/mark` | §21 |
| GET | `/dashboard?organizationId=&trendMonths=` | §23 |
| GET | `/ageing?organizationId=&minAgeDays=&page=&pageSize=` | §23 |
| POST | `/register/{riskId}/treatment-task` | §22 |
| GET | `/register/{riskId}/treatment-tasks` | §22 |

The API accepts an `organizationId`-less sweep so a scheduled job can
cover every tenant. **The Web proxy never offers it** — a
session-authenticated caller must not be able to sweep tenants it cannot
see.

### Positional result sets

Two procs return multiple result sets read **by position**, not by name:

| Proc | Sets | Reader |
| --- | --- | --- |
| `sp_risk_scoring_options_get` | 5 — Likelihood, Impact, Categories, Sources, Matrix | `GetScoringOptionsAsync` |
| `sp_risk_dashboard_counts` | 11 — see 214's header | `GetDashboardAsync` |

Changing the order in either proc breaks the service **silently**. Add at
the end instead.

`sp_risk_config_get` and `sp_risk_config_save` both return the same two
sets (config, notify roles) and share one reader, so the save path cannot
drift from the get path.

### Error mapping

Validation lives in SQL. A `SqlException` carrying a `560xx` message is
surfaced **verbatim** as `{ success: false, error: "<proc message>" }`
with HTTP 400, because those messages name the BRD clause that refused —
e.g. *"analysis is incomplete — risk owner is required"* or *"no risk
analysis exists for this candidate … (BRD 24.1)"*. Re-wording them would
make a rejected registration hard to explain to the person who triggered
it.

| Range | Owner |
| --- | --- |
| 55400–55499 | 169/170 candidate procs (unchanged) |
| 56000–56019 | 204 scoring masters |
| 56020–56039 | 205 schema-time |
| 56040–56199 | 206 analysis + register |
| 56200–56219 | 207 source wiring |
| 56220–56299 | 212 config + approval gate |
| 56300–56349 | 213 notification outbox |
| 56350–56379 | 214 dashboard |
| 56380–56399 | 215 treatment task |
| 56420–56446 | 216 two-stage assessment |
| 56450–56479 | 258 residual analysis |
| 56480–56519 | 261 mapping schema (reserved; the file is schema-only) |
| 56520–56559 | 262 practice/asset mapping |
| 56560–56599 | 263 treatment option + the residual treatment gate |
| 56600–56639 | 264 acceptance, review, calendar |
| 56720–56739 | 270 bulk review — 56726 added into the range by 294 |
| 56740–56749 | 271 acceptance approval authority |
| 56750–56769 | 295 bulk accept |

Codes belong to the **procedure that raises them**, not to the migration
that added the line: 294 extends `sp_risk_bulk_review`, so its refusal
takes the next free number in 270's range rather than opening one of its
own.

The ones worth recognising on sight:

| Code | Means |
| --- | --- |
| 56133 | No analysis exists — BRD §24 rule 1 refused the registration. |
| 56115–56120 | The analysis exists but is incomplete; the message names the missing field. |
| 56270 | Approval is required and has not been given; the message explains *why* it was required. |
| 56280 | Legacy Accept is disabled for this organisation — use Register. |
| 56454–56457 | Residual assessment refused: no inherent rating, or the risk is still `Active` / already closed. |
| 56532 | The **primary** practice cannot be un-mapped — change the risk's linked practice instead. |
| 56569 | A treatment option was chosen before the analysis was complete. |
| 56574 | Residual assessment refused — treatment tasks are still open (validation case 8). |
| 56601 / 56602 | Acceptance refused: the next review date is missing, or is not in the future. |
| 56606 | Acceptance refused — no treatment option has been chosen. |
| 56724 | Bulk close/retire refused — each needs its own reason (§20). |
| 56726 | Bulk review refused — the review frequency is unknown or inactive. Refused once for the batch, not per risk. |
| 56751 / 56752 | Bulk accept refused: no next review date, or one not in the future. The batch-level twin of 56601/56602. |

### Body-scoped organisation guard

`POST /custom` and `POST /duplicate-check` carry `organizationId` in the
JSON body, not the query string, so `TryGuardOrganization` cannot see it.
The Web proxy passes `guardBodyOrganization: true`, which parses the body
and applies `HttpContext.IsOrganizationAllowed` before forwarding. Without
it a caller could read or write another tenant's register.

---

## Backward compatibility

Four of 170's procedures are **rewritten as strict supersets** in 206 —
same names, same parameters in the same order, every original result-set
column still present:

| Proc | What changed | Why |
| --- | --- | --- |
| `sp_risk_candidate_list` | `JOIN custom_gap` → `LEFT JOIN`; new columns appended; optional `@source_type_code` | The INNER JOIN silently **hid** every candidate whose source was not a gap. This is the single most damaging line in the old proc. |
| `sp_risk_candidate_get` | same JOIN fix + §6.2/§10 fields | as above |
| `sp_risk_candidate_reject` | accepts `UnderAnalysis`, `ClarificationRequired`, `AnalysisCompleted`, `Accepted` | §8B places rejection **after** analysis. Allowing it only from `Pending` meant the only way to reject an analysed candidate was not to analyse it. |
| `sp_risk_candidate_withdraw` | same widening | as above |

`sp_risk_candidate_create` (207) drops the NOT NULL on `@custom_gap_id`
and adds nine optional parameters. Relaxing a requirement cannot break an
existing caller.

**No caller is touched.** Six migrations call it today, all with **named**
parameters drawn only from 170's list:

| Migration | Calling proc | Status |
| --- | --- | --- |
| 172, 173, **174** | `sp_custom_gap_analysis_save` | 174 is the live version |
| 176, 184, **193** | `sp_exception_request_reject` | 193 is the live version |

Each passes `@custom_gap_id` plus a subset of the intake fields, so the
new proc *derives* `Gap` / `GAP-<id>` / `GapCentre` when no source is
supplied. All six gain full §10 traceability without a line changing in
any of them.

### Idempotency, generalised

170 allowed one open candidate per **gap**. 207 keys the same rule on
`(source_type_code, source_record_id)` and treats `Registered` the way
`Accepted` was treated. `Rejected` / `Withdrawn` / `ClosedAsDuplicate` do
**not** block — if a dismissed condition recurs, that is new information
and deserves a fresh candidate. Dedupe is skipped entirely when
`source_record_id` is NULL: a candidate with no source record has nothing
to be a duplicate *of*, and §15's register-side detection is the right
tool there.

---

## Conflict register

Following the same practice as `docs/task-centre-v2.md`: where this BRD
disagrees with shipped behaviour, the conflict is **documented for
sign-off**, not silently resolved.

### 1. `Accepted` vs `Registered` — **deprecated in 212** ✅ *resolved*

169 and 199 give the candidate an `Accepted` state meaning "we will track
this as a formal risk", with `formal_risk_ref` as a free-text placeholder
for a register that did not exist yet. That register now exists.

`sp_risk_candidate_register` (§8A) is the BRD path: it creates the
register row and stamps `formal_risk_ref` with the real `risk_number`.

**Resolution (signed off, Phase B, 212):** deprecate, do not delete.
`org_risk_config.allow_legacy_accept` defaults to **0**, and
`sp_risk_candidate_accept` throws **56280** naming its replacement.
199's body — including the Task Centre raise — is otherwise preserved
byte-for-byte, so an organisation mid-migration can set the flag to 1 and
keep working. Existing `'Accepted'` rows are untouched and stay readable;
deleting history to tidy a vocabulary would be the worse trade.

The UI hides the Accept action entirely unless the flag is on — an action
the server will refuse should not be on the menu.

Refusing rather than silently redirecting to `sp_risk_candidate_register`
is deliberate. Accept and Register are not the same act (Register creates
a register entry and may need approval), so quietly doing the other one
would be the worst kind of helpfulness.

### 2. Treatment tasks on registration — **opt-in, after the fact** ✅ *resolved*

199's `sp_risk_candidate_accept` raises a Task Candidate on acceptance.
This BRD §22 says the opposite:

> *"Risk registration itself shall not automatically imply that a
> treatment task exists ... Once a risk has been registered, the
> organisation **may** decide that treatment actions are required."*

**Resolution (signed off, Phase B):** `sp_risk_candidate_register` still
raises **nothing** — 215's sanity check asserts that its body contains no
call to `sp_task_candidate_create`, so a future edit that reintroduces one
fails the migration. Instead, 215 adds `sp_risk_treatment_task_raise`,
called from the **Risk Register** row menu.

It is a separate procedure rather than a `@raise_task_candidate` flag on
register for two reasons:

1. A flag would mean re-emitting the whole register procedure a **third**
   time (206 wrote it, 212 rewrote it for the approval gate). Three copies
   of one body across three migrations is how a schema stops being
   reviewable.
2. It reads the requirement backwards. §22 puts the decision *after*
   registration. A checkbox on the registration form makes it part of
   registration; a separate action on the registered risk is what the BRD
   describes — and it works for risks registered last year, which a
   checkbox never can.

`org_risk_config.default_raise_treatment_task` only pre-ticks the form.
It never raises anything on its own.

#### The source-collision problem, and why `RiskRegister` exists

199 raises Task Candidates with
`(source_type_code = 'Risk', source_record_id = risk_candidate_id)`.
If register-raised treatment tasks reused `'Risk'` with a
`risk_register_id`, candidate #5 and registered risk #5 would be the same
key — the Related Tasks panel on either screen would show the other one's
work.

215 widens the vocabulary by one value instead:

| Value | `source_record_id` is | Raised by |
| --- | --- | --- |
| `Risk` | a `risk_candidate_id` | 199's legacy Accept (unchanged) |
| `RiskRegister` | a `risk_register_id` | 215's treatment raise |

The CHECKs on `practice_task` (192) and `task_candidate` (197) are widened
**additively** — a CHECK that admits more values cannot invalidate a row
that already satisfied the narrower one. `sp_risk_treatment_task_list`
queries both keys, because a stream-originated risk can legitimately have
work from both eras.

### 3. Exception rejection raises a **Gap**-sourced candidate, not an Exception one

`sp_exception_request_reject` (176 → 184 → 193) auto-raises a risk
candidate when an exception request is rejected, passing
`@custom_gap_id`. Under §13 the "correct" source looks like `Exception`.

It is deliberately left as `Gap`. 176's own header requires idempotency
*per gap*: if the analyst already flagged the gap as a business risk
during analysis (`sp_custom_gap_analysis_save`), the existing candidate
must be returned, not duplicated. Switching the exception path to
`Exception` would key the dedupe on a different pair and produce **two
candidates for the same underlying condition** — exactly what 176 was
written to prevent.

**Open question for sign-off:** if Exception-sourced risks must be
distinguishable in §23 reporting, the fix is a `source_dedupe_key`-style
column on `risk_candidate` (the pattern 197 uses for tasks), not a change
to 176.

### 4. Source record is never written back — **§14**

> *"Risk Centre shall not replace Gap Centre or Exception Centre ... The
> source record shall remain independently managed by its originating
> Centre."*

Nothing in 204–207 writes to `custom_gap`, `exception_request` or any
other source table. The candidate points at the source; the source is
never told what to do about it.

---

## Phase B — 212–215

### §19 — the approval gate (212)

> *"The organisation shall be able to configure whether formal approval is
> required before registration ... The approval mechanism shall not alter
> the fundamental requirement that initial analysis precedes
> registration."*

Two things follow, and the second is the one that is easy to get wrong:
whether approval is required is **data**, and approval sits **between**
analysis and registration — a second gate, never a substitute for the
first. So the check lives inside `sp_risk_candidate_register`, **after**
the analysis lookup that already throws 56133. §24 rule 1 still holds
unconditionally.

**Why a rating threshold, not a flat switch.** A flat switch forces an
organisation to choose between "approve nothing" and "approve every Low
risk anyone ever logs". Neither is how risk committees work.
`approval_min_rating_code` names the lowest rating that needs approval,
and `sp_risk_approval_required` compares by **score** resolved through the
organisation's own `risk_matrix_cell` — so a framework using colour bands
or 1–4 works unchanged, which is what §7's "configurable methodology"
requires.

Two fail-safe behaviours worth knowing:

- A threshold naming a rating the matrix no longer produces (someone
  re-graded the grid after configuring the gate) **requires approval**
  rather than quietly waving everything through.
- An analysis with no rating score likewise requires approval — it cannot
  be *shown* to fall below the threshold.

**Workflow.** `sp_risk_analysis_submit_approval` → status `Pending`;
`sp_risk_analysis_approve` with `Approve` or `Return`. Approving does
**not** register: §19's diagram is Analysis → Approval → Register, three
steps. Keeping them separate also lets an approver work in bulk while
registration stays deliberate. A `Return` reuses §8C's
`clarification_note` — "the approver wants more work done" and "the
analyst wants more information" are the same state to everyone
downstream, so it is one status and one place to look.

**Who may approve.** `approver_role_id`, enforced only when set. Role
membership is checked **both** ways — `organization_employee.role_id`
(the primary role, which `sp_org_role_holders_list` reads) and the
`organization_employee_role` map. 213 notifies approvers through the
former, so checking only the latter would let a person be *told* to
approve and then refused permission to.

### §21 — the notification outbox (213)

An **outbox, not a sender** — the same decision 201 made for SLA
thresholds, for the same reasons: there is no dispatcher in this
codebase, and *"GRAC determined that these people should have been told,
at this time, for this reason"* is the evidentiary claim, not an SMTP
transcript.

**Why a sweep and not a trigger or proc rewrites.** Three options:

| | |
| --- | --- |
| Rewrite every workflow proc to enqueue | Correct, but 206's and 212's procs would be re-emitted a *third* time in a third file. |
| `AFTER INSERT` trigger on the history tables | No rewrites, but it runs **inside** the workflow transaction — a notification problem could roll back a governance decision. 199 and 206 both went out of their way to avoid exactly that. |
| **A sweep over the history tables** ✅ | No rewrites, outside every workflow transaction, and idempotent by construction. |

History rows are immutable and each has an id, so the dedupe key is
`(source history row, notify event, recipient)` — "notify twice" is
impossible without any date-keying gymnastics. The honest cost:
notifications are generated when the sweep runs, not at the instant of the
event. For a system with no dispatcher at all, that is not a real
difference.

**Action → event map** is documented in the proc header. `AnalysisSave`
maps to nothing on purpose: an analyst saving a draft five times is not
five events.

**Recipients** are the people the workflow itself named (assigned analyst,
risk owner, approver role) plus roles configured in
`org_risk_config_notify_role`. The **actor is excluded** — telling
somebody what they just did is noise, and noise is how notification
systems get switched off. A configured role with **no active holder**
still records the obligation: that a role was empty when it mattered is
itself an audit finding. A recipient with no email is recorded
`Suppressed` rather than `Pending`, so a dispatcher does not retry
something that can never succeed.

Schedule `sp_risk_notification_sweep` and point a dispatcher at
`status_code = 'Pending'`.

### §23 — dashboard and reporting (214)

`sp_risk_dashboard_counts` returns **11 result sets in a fixed order**
(see the proc header). One call, one connection, one point in time —
every tile agrees with every other, which for a governance dashboard is
not a nicety. Append new sets at the **end**; inserting one in the middle
silently re-points every reader after it.

Three judgement calls worth recording:

- **"Awaiting approval" counts analyses, not candidate statuses.** A
  candidate sits in `AnalysisCompleted` whether or not anyone submitted
  it; counting the status would overstate the approver's queue.
- **Only open candidates age.** A rejected candidate from last March is
  not "180 days old and getting older" — including it makes the backlog
  look permanently terrible.
- **"Overdue risk actions" is read from `vw_pm_practice_task`**, not
  recomputed. Two definitions of "overdue" in one product is how
  dashboards start disagreeing with the screens they link to. If Task
  Centre is absent the tile returns empty rather than failing the
  dashboard.

**Elevated-rating count** uses the midpoint of the organisation's own
matrix scores rather than string-matching `'High'`/`'Critical'`, so the
number stays meaningful under any framework.

#### Msg 130 — no subquery inside an aggregate

Two things in this proc are shared definitions that a naive reading would
express as a subquery inside `SUM()`: the set of "open" candidate
statuses, and the elevated-rating threshold. SQL Server rejects both
(*"Cannot perform an aggregate function on an expression containing an
aggregate or a subquery"*), and the proc will not compile.

Inlining the four status literals at every call site would compile, and
is exactly how the dashboard and the grids drift apart. So:

- **openness** is resolved once in a `LEFT JOIN @open` inside a CTE;
  every aggregate then works on a plain 0/1 column;
- **the threshold** is computed into `@elevated_threshold` before the
  `SELECT`.

`@open` is still used directly in *`WHERE`* clauses further down (the
approval subquery, the ageing CTE) — that form is legal. The restriction
is aggregate-of-subquery, not subquery-anywhere. If you add a tile here,
check which of the two you are writing.

## T-SQL traps these migrations hit

Both cost a failed migration run. Worth knowing before editing any of
204–207 and 212–215.

**Msg 130 — no subquery inside an aggregate.** See the §23 note above.
`SUM(CASE WHEN x IN (SELECT ... FROM @t) ...)` does not compile. Resolve
the test in a JOIN or a variable first.

**Msg 156 — `EXEC` parameter values may not be expressions.** Only a
variable, a literal or `NULL`. `@owner = COALESCE(@a, @b)` fails; assign
to a variable and pass the variable. Migration 176 already carries this
warning in a comment ("EXEC parameters cannot take expressions") — it is
the single most repeated mistake in this schema.

A static sweep for both, plus missing `OUTPUT` keywords at call sites and
nested `INSERT ... EXEC`, is worth running over any new migration before
handing it to sqlcmd.

Drill-down is a filter change on a grid the user already understands: every
grouped row carries the value the existing grids accept, so a click becomes
a query-string change rather than a second API.

### Still not built

| BRD | Item | Note |
| --- | --- | --- |
| §21 | Actual delivery | The outbox records obligations. Choosing and wiring a dispatcher is a platform decision, not a Risk Centre one. |
| §23 | Charting library | The dashboard renders proportional bars from divs, deliberately: it must paint with no charting dependency. |
| §19 | Bulk approve | The queue is sorted by rating score then age; approval is one at a time. |
| — | Review notifications | `next_review_date` drives the list and the calendar. Nobody is *told* a review is due; that needs the §21 dispatcher above. |

---

## The full lifecycle (migrations 261–264)

258 gave the register a second score. 261–264 give it the flow between
the scores — what the risk touches, what was decided about it, who
accepted it, and when to look again.

```
Risk Candidate → Assessment → Risk Register → Risk Analysis
                                                    │
                        ┌───────────────────────────┼───────────────────────┐
                        │                           │                       │
                  Terminate/Avoid             Treat/Reduce            Transfer/Share
                        └───────────────────────────┼───────────────────────┘
                                                    ↓
                                      Risk Treatment Task (Task Centre)
                                                    ↓
                                          Sub tasks (§11 children)
                                                    ↓
                                         all tasks closed → Monitoring
                                                    ↓
                                        Residual Risk Analysis
                                                    ↓
                                             "Accept risk"
                                                    ↓
Tolerate/Accept ──────────────────────────→ Risk Acceptance
                                                    ↓
                                            Next Review Date
                                            ↓             ↓
                                     Risk Calendar   Review Risk
                                                          ↓
                                                    Risk Review
                                                          ↓
                                            (back to Risk Analysis)
```

### The stage is derived, not stored

`vw_pm_risk_workflow_stage` (264) computes `workflow_stage_code` from
columns that already exist: `analysis_pending`, `treatment_option_code`,
the open/closed counts of the risk's treatment tasks, `residual_pending`,
`accepted_dt` and `next_review_date`.

A stored stage column was considered and rejected. `status_code` already
owns a §17 lifecycle vocabulary with a CHECK behind it; a second stored
status is a second thing every writer must remember to update, and 258
had to ship a repair pass for exactly one such flag drifting
(`residual_pending`). A derived stage cannot drift, and it is correct for
risks created before these migrations because it reads their actual state
rather than a flag nobody set.

`Status` and `Stage` are both shown in the grid, deliberately. They are
not the same thing: Status is the lifecycle an operator **sets**, Stage
is where the risk **has got to**. A risk can be `Monitoring` and
`ResidualDue` at the same moment.

The stage ladder is ordered by urgency, not chronology — `ReviewDue`
outranks everything below `Closed`, because a risk due for review needs
looking at whatever else is true of it.

### Scope mirrors the Operationalize dependency table (265, 266, 267)

261/262 mapped **assets only** — `risk_asset_map` keyed on an `asset_id`,
and `fn_risk_practice_assets` filtering `dependency_type_code = 'Asset'`.
265/266 generalised that to a category-keyed model.

265/266 then over-corrected: they read `dependency_type_master` as the
source of truth for what the mapping table *offers*, and rendered all
**nine** rows in it. It is not. It is the source of truth for what
*exists*. The Operationalize page has offered a fixed **five** since
migration 238:

```js
// resolve-workspace.cshtml
const DEP_TABLE_CATEGORIES = ['Asset','Vendor','Person','Team','Committee'];
// "Tool and Application still exist in dependency_type_master (older
//  instances may still carry resolutions) but are not offered here"
```

**267 makes that distinction a property of the category** rather than a
literal in one screen: `dependency_type_master.is_dependency_mappable`,
seeded to exactly those five. Risk Analysis then asks the database
instead of holding an opinion.

| Concern | Where it comes from |
| --- | --- |
| Which categories exist | `dependency_type_master` |
| Which are **offered** for mapping | `dependency_type_master.is_dependency_mappable` (267) |
| What a practice depends on | `practice_dependency_resolution`, filtered to the offered set |
| What objects can be picked | `dependency-options/query` — **the endpoint the Operationalize picker calls** |
| Category order | `dependency_type_master.display_order` |

Copying the five names into `risk-centre.js` would have made the screens
agree today and guaranteed they disagree later: the next person to change
the list would find it in `resolve-workspace.cshtml` and never learn a
second copy existed. 267's sanity check asserts the column and that
literal still match, so an edit to one without the other fails loudly.

**Inheritance is filtered too, not just the display.** Legacy instances
still carry Application and Tool resolutions. Inheriting those while no
Application section renders would put dependencies on a risk that nobody
can see or remove, still counted in the Scope column. 267 also clears any
such rows that 265/266 already created — but only the purely inherited
ones; anything with a `Direct` contribution was a human decision and is
counted and reported instead of deleted.

**Operationalize is unchanged.** Its JS keeps its own literal and behaves
exactly as before. Pointing it at the column is a one-line follow-up that
would remove the last duplicate, deliberately not taken here.

`dependency_object_id` has **no FK**: the object lives in whichever
source table the category names, and one column cannot reference five.
That is the same soft-reference decision
`practice_dependency_resolution.resolved_dependency_id` already makes;
the frozen `dependency_object_name` keeps a mapping readable after the
object is renamed or retired.

There is deliberately **no** Risk Centre procedure listing selectable
objects — that would be a second implementation of "what objects exist
for a category", drifting from the gateway's the first time a
source-config column changed. `sp_risk_mapping_options` returns practices
only; the category pickers load lazily on first focus from the
Operationalize endpoint.

The scope panel renders one card per offered category, **including empty
ones** — matching Operationalize, whose five rows always render whether
ticked or not.

### The flag itself can drift from its own seed (353)

**The complaint:** Risk Analysis -> Impact Details showed *"No
dependency categories are configured for this organisation"* while
Operationalize, on the same server, showed all five categories fine.
The message names the organisation, but neither screen's query is
organisation-scoped at all -- `dependency_type_master` has no
`organization_id` column on either side of this comparison.

**What it was.** A direct query
(`database/_diag_267_dependency_mappable_flag.sql`) showed all nine
`dependency_type_master` rows sitting at `is_dependency_mappable = 0`
on this environment -- including Asset, Vendor, Person, Team and
Committee, whose names match 267's seed literally, character for
character. 267's seed `UPDATE` is written to be idempotent and was
presumably correct when it ran, but something afterward -- most likely
a data refresh or restore of `dependency_type_master` that did not
carry a BIT column's seeded value forward -- left every row back at the
column's `DEFAULT 0`. Nothing about this is organisation-specific: an
empty seed empties the picker for every org on the server at once,
which is exactly what was observed.

**The fix (353).** Re-runs 267's own seed `UPDATE` verbatim -- no new
table, column or procedure, since 267 already built everything this
needed and the only thing missing was the data. Idempotent and safe to
re-run again if it is ever found reset a second time; if that happens,
it is worth asking what process last touched `dependency_type_master`
rather than just re-seeding again, since a BIT flag does not reset
itself.

No code change and no rebuild are required -- `sp_risk_mapping_get`
already reads this column live, exactly as it did before 353.

### Scope: one row per dependency, many reasons

The requirement is that a dependency reachable through several practices
still has **one** risk-level mapping. That is why the grain is split
across two tables:

| Table | Grain | Answers |
| --- | --- | --- |
| `risk_dependency_map` | one row per (risk, category, object) | *is this in scope?* |
| `risk_dependency_map_source` | one row per reason | *why?* |

A `UNIQUE(risk_register_id, dependency_type_id, dependency_object_id)`
makes the first true by construction — which is precisely "duplicate
dependencies are prevented when the same dependency comes through
multiple Practices", enforced by the engine rather than by every writer
remembering. Removal then becomes arithmetic rather than judgement:
un-mapping a practice deletes **its** contribution rows, and the asset row
goes only when no contribution of any kind survives. An asset another
practice still reaches, or one that was also mapped directly, is passed
over — no procedure has to reason about "is anything else using this?".

`risk_dependency_map_source` uses two `PERSISTED` computed columns
(`practice_key`, `instance_key`) so its UNIQUE constraint can key on
nullable columns; `ISNULL(...)` is not allowed in a constraint, and 205
used the same device for `risk_number` (until 378 converted it to a
regular column -- a per-organisation sequential value cannot be
expressed as a computed column, since aggregates are not allowed in
that expression).

Dependencies inherited from a practice are the union across that
practice's **active instances** — `linked_practice_id` is a catalogue
`practice_id`, but dependencies resolve per `practice_instance_id`.
`fn_risk_practice_dependencies` is the one definition of that chain, and
it is an *inline* TVF so it expands into the calling query rather than
forcing a temp table at every call site. 266's sanity check asserts it is
still `'IF'` and not `'TF'`.

### Treatment: a real task, and why that is not a reversal of §22

215 raises a task **candidate**, so a human confirms owner, SLA and
priority before work lands in a queue. 263 opens a **task** directly for
Terminate / Treat / Transfer. That is not §22 being overruled — it is the
precondition §22 protected no longer holding:

- §22 worried about work with no owner. A task raised from a chosen
  treatment option has one by construction: the Risk Owner, already on
  the register and already accountable.
- §22's candidate stage needed a screen to approve from, and 253 records
  that the Task Candidates tab was retired. Candidates raised here would
  sit in `task_candidate` reachable by nothing — the exact failure 253
  was written to fix for gaps.

253 made the same call for gap remediation in the same words, and
explicitly left the candidate model standing for other sources. This is
the second such seam, not a reversal of the model —
`sp_risk_treatment_task_raise` is untouched and still on the row menu as
*Raise additional task (via candidate)*.

**Idempotency is a column, not a query.** `risk_register.treatment_task_id`
holds the parent task, and it is trusted only while that task still
exists and is still open — a completed task must not block the next round
of treatment after a review reopens the risk.

### The residual gate, and the one procedure body that is duplicated

Validation case 8: residual analysis becomes available only when **all**
treatment tasks are closed. 258's gate is status-based, and raising a
task sets `UnderTreatment` — so under 258 alone residual would be
assessable the moment treatment *starts*.

A gate enforced only in the API is a convention the next caller does not
know about, so 263 re-emits `sp_risk_residual_analysis_save` as a strict
superset: same name, same parameters in the same order with two appended
and defaulted, same result set, all of 258's gates plus one more.

Re-emitting a procedure body is a real cost and 215's header argues
against doing it casually. It is paid here because the alternative is a
rule that holds only for callers who remember it. Diffing 263 against 258
should show exactly the new gate and the treatment-option column — and
nothing else.

`@skip_treatment_gate` exists for one caller (the review flow) and no
screen sends it.

### Review reuses the analysis procedure; it does not copy it

`sp_risk_review_perform` calls `sp_risk_register_assess` — the exact
procedure the Risk Analysis screen calls — and then stamps
`analysis_purpose_code = 'Review'`, advances `review_count` and
`last_reviewed_dt`, and clears `next_review_date`.

Requirement 8 asks for "the same analysis process". Not similar — the
same. Zero lines of analysis logic are duplicated, so a future change to
how risks are analysed changes reviews too, automatically. 264's sanity
check asserts the delegation is still there, because if somebody ever
copies the body the two paths will silently start to drift.

`next_review_date` is **cleared** by a review unless the caller supplies
a new one. After a review the risk is back in the flow and may need new
treatment; the date is set again when it is next accepted, by the one
procedure that requires it.

### Review Risk is a page, and it routes on the treatment option

Review was a `pm-modal-wide` and is now `#riskReviewPageView`, built on
the same shell as Residual analysis — `pm-page-heading` with the risk as
the h1, a `risk-flow` rail, `pm-panel` per section, `ra-actionbar` at the
foot. It carried the same load as the residual page (a full
reassessment, the scope panel, the treatment options, a next-review
date), and inside a modal the scope panel's `pm-checkcombo` menus were
clipped by the modal's own scroll box. The old modal markup and its
`data-close-risk-review` wiring are gone; **bulk** review stays a modal,
which is a different job.

The rail has **three** steps — last assessment, this review, next step —
because `.risk-page .risk-flow` is a five-track grid and 3 steps + 2
arrow items fills it exactly. This is the only rail still built that
way. Both **four**-step rails (Residual Analysis and View Risk) carry
`.risk-flow-4` instead: four equal tracks, no arrow items, and the
sequence drawn as a CSS chevron in each gap — four steps plus three
arrows is seven items in five tracks, and the overflow wrapped the last
step onto a second row with an orphaned arrow beside it. Add a step to
the Review rail and it needs that modifier too.

There is no history panel on Review: no review-history read exists in
the API, and a panel with nothing behind it would be worse than none.

#### The Justification card is gone — and why that is not just a deletion

Step 2 used to sit in a two-column `ra-row-split` with a **Justification**
card beside it asking for *Potential consequence / impact* and *Controls
now in place* as free text. Both are already on the page — the controls in
the Existing Controls panel, the treated tasks above — so retyping them
produced a second copy that could contradict the first.

Only **Analyst remark** survived, and it moved into the Reassessment card
beneath the score. The split row went with the card (a row holding one
panel is an empty level), and the panel reuses `ra-grid-score` — category,
likelihood, impact and the resolved rating are the same four fields in the
same order as Inherent scoring, so they get the same four-column row
rather than a second class to keep in step.

**The two removed fields are still sent.** This is the part that matters:
a review delegates to `sp_risk_register_assess` → `sp_risk_analysis_save`,
which **INSERTs a new analysis version** from the values it is handed and
marks it `is_current`. Sending `null` for `potentialConsequence` and
`existingControls` would therefore blank them on the risk's live
assessment — a silent data loss on every review. `onReviewSubmit` carries
both forward from `state.activeRisk`, the row the page was opened with, so
the record keeps them and nobody retypes them.

The Residual page's equivalent change *was* a plain deletion, because
those columns live on the residual version rather than on the risk's
current analysis. Same-looking edit, different consequence — worth
checking which is which before removing an input anywhere else.

### Map Practice: the actual cause was the Control level

**"1 already used" was never about practices.** `loadControls` hid any
control whose `practiceCount` was 0, and `loadLevel`'s hint then reported
`all.length + " already used"` — a message it applied to *every* level.
So a single control with no practices produced an **empty Control
dropdown** under the words *"1 already used"*, the practice level stayed
on "Select a control first", and no practice could be selected at all.

That wording sent two rounds of investigation into a risk-scoped
exclusion bug that did not exist. The generic fallback is gone: each
level supplies its own `blockedHintText`, and there is no default that
can invent a reason.

**Controls with no practices are now listed and disabled**, labelled
*"(no practices attached)"*. Hiding them was the cure becoming the
disease — they were hidden because picking one produced an empty practice
list "that looked like a failure", but hiding the only control left the
user stuck with nothing on screen to explain it. Disabled is strictly
better than both: the control is visible, unpickable, and self-
explaining. `fill()` gained a `disabledOf` hook for this.

`PracticeCount` comes from the same
`organization_control_requirement → organization_requirement → practice`
chain that `sp_practice_picker_practices` walks, so a count of 0 really
does mean the practice query would return nothing. **Which link is
broken** is what `database/_diag_practice_picker_cascade.sql` (read-only)
answers — it counts each link separately and prints a verdict per
control, the most common being *"practices exist but none are Active"*.

### Map Practice: the exclusion is decided in SQL, on org **and** risk (312)

**The complaint:** Map Practice showed "1 already used" for a practice
never mapped to the risk being worked on.

**What it was.** Half in SQL, half in the browser — and the SQL half did
not know about risks at all. `sp_practice_picker_practices` filtered by
`@organization_id` and excluded only the id *list* a caller handed it in
`@exclude_practice_ids`; the browser built that list from
`GET /register/{id}/mapping`. Both halves were per-risk *in effect*, but
nothing in the database ever compared a practice against a risk, so
"is this scoped to this risk?" could only be answered by reading
JavaScript — and the answer changed with whatever the page had in memory.
Worse, the picker's URL never actually sent `excludePracticeIds`, so the
only enforcement was a client-side `.filter()`.

**Two client-side causes were live**, both of which a per-risk SQL check
makes impossible:

- The picker is attached **once** and reused for every risk on the page.
  It kept the `organizationId` *and* the exclusion list from its first
  attach, so a second risk inherited the first one's answer.
- The practices cache was keyed `pr/{org}/{control}` with **no risk**, so
  the second risk read the first risk's cached list. This is the one
  cause a client-side filter could not have produced on its own, and it
  matches the report exactly.

**What it is now.** The procedure takes `@risk_register_id` and does the
exclusion itself:

```sql
NOT EXISTS (SELECT 1 FROM risk_practice_map pm
             WHERE pm.organization_id  = @organization_id
               AND pm.risk_register_id = @risk_register_id
               AND pm.practice_id      = p.practice_id)
```

Organisation **and** risk, both named, in one place, answerable with a
query. `@exclude_practice_ids` still applies on top. `@risk_register_id`
NULL excludes nothing, which is every non-Risk-Centre caller's behaviour,
unchanged. The cache key now carries the risk, and the picker gained
`setRiskRegisterId()` alongside `setOrganizationId()` so a reused
instance cannot keep pointing at the first risk.

**And it now says why.** `AlreadyMappedToRisk` and `MapSourceCode` come
back per row, and `@include_already_mapped = 1` returns those rows
instead of dropping them — so the practice appears **disabled, with the
reason**, rather than the dropdown going empty under a "1 already used"
hint. The hint counts what is *selectable* ("2 available, 1 already on
this risk"), because counting disabled rows as available is the same
half-truth this was reported for.

**Why the practice was legitimately there.**
`sp_risk_mapping_sync_primary` derives a Primary `risk_practice_map` row
from `risk_register.linked_practice_id` on the first `/mapping` read. A
risk raised *from* a practice therefore owns that practice without anyone
mapping it by hand — so "a practice I never used against this risk" can
genuinely be on the risk. `MapSourceCode = 'Primary'` is what lets the
option say *"already in this risk's scope — raised from this practice"*
instead of leaving the reader to guess.

`database/_diag_risk_practice_map_scope.sql` (read-only) settles any
remaining case against real data: set `@RiskId` and `@PracticeId` and
section 3 prints EXPECTED or BUG CONFIRMED.

### A gap-sourced risk stopped showing its own practice (354)

**The complaint:** a risk auto-created from a Practice Instance's
"Not Implemented" obligation -- Gap -> `business_risk_present='Y'` ->
candidate -> **Register as Risk** -- used to show the originating
practice in Risk Analysis's Existing Practice Map panel (the mechanism
described immediately above). For risks registered since 261, it no
longer did: the panel rendered "no existing practice mapped".

**What it was.** `risk_register.linked_practice_id` has existed since
205 and, as 261's own header already said, was never actually written
by anything live -- 261 ran a **one-time backfill** for rows that
existed on the day it was applied, and explicitly deferred a real
derivation mechanism ("the picker") that was never built for Risk. Every
risk registered after 261 ran therefore carries `linked_practice_id =
NULL`, so `sp_risk_mapping_sync_primary` (266) takes its "practice
unknown" branch on every `/mapping` read and the panel comes back empty
-- correctly reflecting the column, which is exactly the bug: the column
was never being set in the first place.

Exception Centre hit the identical problem and got the full fix in 258
(backfill, create-time derivation, read-time fallback). Risk had only
ever received the backfill.

**The fix (`354_risk_linked_practice_derivation.sql`).** The same
three-part treatment, reusing 261's own two-route join verbatim rather
than inventing a new one:

1. A defensive re-run of 261's backfill, guarded by `linked_practice_id
   IS NULL`, for anything registered in the gap between 261 and now.
2. `sp_risk_register_insert` derives `linked_practice_id` at create time
   when the caller does not supply one and the risk's own source is a
   Gap: `source_record_id` (the `custom_gap_id`) -> `custom_gap.
   source_reference_id` (a practice instance, when `source_reference_
   type = 'PracticeInstance'`) -> `practice_instance.practice_id`, org-
   scoped throughout. This lives in `sp_risk_register_insert` rather
   than `sp_risk_candidate_register` -- every registration passes
   through it regardless of route, so one check covers both the
   candidate route and any direct/custom caller that names a Gap source
   on the register itself.
3. `sp_risk_mapping_sync_primary` derives **and persists** at read time
   when the stored column is still NULL, using the risk's own
   `source_type_code` / `source_record_id` (there is no live candidate
   left to go through by that point). If a practice resolves, it
   `UPDATE`s `risk_register.linked_practice_id` before continuing, so
   the very next `/mapping` read for that risk needs no further
   derivation. This is what makes the fix retroactive without a second
   migration run: opening the Existing Practice Map panel on the
   specific risk originally reported as broken is enough to self-heal
   it.

A Custom risk, or a Gap risk whose gap traces to something other than a
`PracticeInstance` (an `OrgAssuranceGap`, for instance), has no practice
instance behind it and is left `NULL` by all three parts -- the panel
reports that honestly rather than guessing, the same choice 258 made for
Exception Centre.

No C#/JS change and no rebuild: this is entirely inside
`sp_risk_register_insert` and `sp_risk_mapping_sync_primary`, both
already called on every registration and every `/mapping` read
respectively.

### Map Practice: the Control level can show Statements too (351)

**The complaint (UAT):** ISO 27001 practices could not be mapped from
Risk Centre or Exception Centre at all — the picker's Source Structure
step said *"No source structures found"* even though Control
Management's own Source Statements screen showed 93 correctly-loaded
statements for the same release.

**What it was.** The repository model changed some time before this was
reported. The *original* design reduced every Source Statement to a
unique Control, mapped to the release's structure via
`grac_new.source_control_map`; the *current* design keeps Source
Statements as-is per release and maps a Requirement directly to its
statement instead (`organization_requirement.org_statement_id` →
`grac_practice.organization_framework_statements`, added by migration
011). ISO 27001 on UAT was loaded the new way — real statement content,
zero `source_control_map` rows, by design. `sp_practice_picker_structures`,
`_controls`, `_practices` and `_resolve` (282, extended by 312 and 349)
had never been taught the new path, so a release with only new-model
data walked a join that could never return a row. PCI-DSS on dev still
has real `source_control_map` rows, which is why it kept working and the
symptom looked release-specific rather than systemic.

**The fix.** 351 adds the Statement/Requirement path to all four
procedures as an **additional** branch (`UNION ALL`), not a replacement —
349's exact Control-path logic is unchanged, so PCI-DSS/dev behaves
exactly as before. A Statement item is identified by
`-framework_statement_id` (always negative; a real
`organization_control_id` is a positive IDENTITY, so the two spaces
cannot collide) — the same sentinel convention 282 already used for the
`-1` ORG-PRACTICES release. `PracticePickerService.cs` (the API service
layer) passes `organizationControlId` straight through as a plain
`BIGINT` with no sign handling of its own — but see the correction
below: the *controller* layer, one step further out, was not so
transparent.

**Correction — this DID need a code change (found during UAT testing).**
The first sentence of this write-up originally said the fix needed no
C#/JS changes at all. That held for the *service* layer, but
`PracticePickerController.cs` (API tier) guards every id parameter with
an inline `is null or <= 0` check, written back when every one of these
ids was assumed to be a positive IDENTITY value. Once a real user tried
mapping an ISO 27001 statement on UAT through the actual UI, selecting
one produced *"Could not load practice: HTTP 400"* — the negative
`organizationControlId` 351 now legitimately sends was being rejected
before it ever reached the database, even though the SQL layer had
already been proven correct end-to-end by direct `EXEC` calls.

Fixed by loosening three guard clauses from `is null or <= 0` to
`is null or 0` — `releaseId` (Structures), `structureNodeId` (Controls)
and `organizationControlId` (Practices) — so only a genuinely missing or
zero id is rejected, not a negative sentinel. `organizationId` and
`practiceId` keep the stricter `<= 0` check; neither ever carries a
sentinel value.

That same sweep turned up a second, unrelated latent bug in the same
three lines: the `-1` ORG-PRACTICES sentinel `releaseId`/`structureNodeId`
282 introduced would have hit this identical guard and 400'd too, for
anyone who ever tried to pick "Organization Defined Practices" from the
Framework dropdown through this component. That path is fixed by the
same edit, but it was never reported, so it is worth a quick smoke test
once this is redeployed rather than assumed fixed.

**This needs a rebuild.** Unlike 351 itself (a pure SQL change the
running API picks up with no restart), this is a C# controller edit —
`PracticeManagement.Api` needs to be rebuilt and restarted before the
fix takes effect. The Web tier is an unmodified blind proxy for these
routes and needs no changes.

**What did not change.** 351 does not create any
`organization_framework_statements` or `organization_requirement` rows.
An organization that has never had a statement marked applicable, or a
practice created against one, under a given release will correctly show
an empty picker for that release+org — same as it always has for an org
with no `organization_control` rows. That is Governance work, not
something a picker query can conjure.

**UI wording.** The Control level's default label changed from
*"Control"* to *"Control / Statement"* (`practice-picker.js`), along with
its placeholder, empty-state and disabled-item hint text, since the same
dropdown can now legitimately hold either kind of row — sometimes both at
once, if a release is ever mid-migration between the two models. Neither
caller (`risk-centre.js`, `exception-centre.js`) overrides that label, so
both picked up the change automatically.

### One common risk version (310)

A risk has **one** version, on `risk_register.risk_version`, and the only
thing that moves it is a completed acceptance:

```
registered          -> version 1
acceptance 1 saved  -> version 2
acceptance 2 saved  -> version 3
```

Analysis, residual analysis and review do **not** touch it.

**What was actually wrong.** There was no risk version at all. The
numbers the UI showed were `risk_analysis.analysis_version` and
`risk_residual_analysis.residual_version` — two independent per-table
sequences, each incremented by its own save, displayed side by side as
"Version". That is why one risk appeared to have two different versions
at once.

**Those two columns are untouched, and must stay that way.** They are
the §20 history sequences ("must not be overwritten without retaining
historical versions"): every save writes a new row and the number is
what identifies it. 310 does not re-issue `sp_risk_analysis_save`,
`sp_risk_residual_analysis_save` or `sp_risk_review_perform`, and the
Analysis and Residual **history tables keep their `Ver` column** —
without it, two saves on the same day are indistinguishable. What
changed is that nothing else calls them a version: the per-stage
`Version` rows, the trace chip, the "Analysed … v4" chips and the save
toasts all dropped the number.

**Back-fill derived from the audit trail, not guessed.**
`sp_risk_acceptance_save` has written a `RiskAccepted` row to
`risk_register_history` on every acceptance since 264, so:

```
risk_version = 1 + COUNT(history WHERE action_code = 'RiskAccepted')
```

Never accepted → 1. Accepted twice → 3. The column is new, the history
rows are only read, and no existing column is written. The back-fill is
guarded on "no risk is past version 1", so re-running 310 cannot
double-count.

**Two procedures re-issued, both from their current bodies.**
`sp_risk_acceptance_save` (from 298) gains the increment inside its
existing transaction, reads the new value back, names it in the history
remark and returns it; `sp_risk_register_get` (from 292) gains
`RiskVersion`. Both bodies were *extracted and injected into
programmatically*, never retyped — 292's own header sets out why: these
are 140-line procedures and a transcription slip silently drops a column
the UI reads by name.

**Bulk accept is covered for free.** `sp_risk_bulk_accept` and
`sp_risk_bulk_review` compose `sp_risk_acceptance_save` (295, 298), so
twelve risks accepted together each advance by exactly one version
through the one increment. No second implementation.

`sp_risk_register_list` was deliberately **not** widened — no grid shows
a version, so re-issuing it would be a risk taken for no reader.

#### The View Risk Risk Context section

- **Business unit removed.** Display only: `risk_register.business_unit`
  still stores it, `sp_risk_register_get` still returns it, the API model
  still carries it and the register detail drawer still shows it.
  Nothing was migrated away.
- **Linked practice shows the count** — "3 Practices", with the
  originating practice named beneath. It reads `LinkedPracticeCount`
  (311), not `MappedPracticeCount`; see below for why that distinction
  had to exist. Zero renders as "No practices linked" rather than
  "0 Practices", which reads as a data fault rather than a state (a
  Custom risk legitimately has none).
- **Risk version shown once**, as the bare number — `v2`. It first
  carried "after 1 acceptance" beside it; that is derivable from the
  number, and a version field that explains its own arithmetic reads as
  though the number needed defending. It falls back to v1 when the
  column is absent, because a database still on 309 returns no
  `RiskVersion` and every risk is at least version 1 by definition — the
  API's reader defaults it the same way, through the same `HasColumn`
  guard every other v2 column uses.

#### Why `LinkedPracticeCount` is not `MappedPracticeCount` (311)

The count came out empty on first view, and the reason is an ordering
one worth remembering.

`MappedPracticeCount` is `COUNT(*)` over `risk_practice_map` — and that
map's **Primary row is derived, not written at registration**.
`sp_risk_mapping_sync_primary` (262, rewritten in 266) turns
`risk_register.linked_practice_id` into a Primary map row, and its only
caller is `RiskCentreService.GetMappingAsync` — the read behind
`GET /register/{id}/mapping`, with a comment saying exactly that: *"Nobody
clicks anything to make that true, so it has to happen on the read that
first shows the scope."*

View Risk renders Risk Context from `GET /register/{id}` **first** and
mounts the scope panel **afterwards**. So on the first view of a risk
whose Primary row had never been derived, the mapped count really was 0
at the moment the section rendered — and Risk Context is not re-rendered
when the panel finishes. The number was honest and useless.

`LinkedPracticeCount` answers the question the section is actually
asking: the map, **plus** the risk's own linked practice when that
practice is not in the map yet. Correct before the derivation has ever
run, unchanged after it.

Fixed in SQL rather than in the page, so every reader gets the same
answer — the register drawer, View Risk, the residual page and the
acceptance page all read `sp_risk_register_get`. Having the page
re-render the cell once the mapping panel loaded would have put a second
definition of "how many practices" in JavaScript and made the answer
depend on whether a panel happened to be mounted.

`MappedPracticeCount` is unchanged and keeps its name's meaning: rows in
the map. The Existing Controls panel renders exactly those rows, so a
count that silently included a practice the panel does not list would be
wrong for that reader. `sp_risk_register_get` also stays **read-only** —
calling the derivation from a read procedure is how a read procedure
starts deadlocking under load.

### Accept risk is a full page (`#riskAcceptancePageView`)

It was `#riskAcceptanceModal`, an 820px popup. Acceptance is the one step
of the four that is a **judgement** rather than a measurement — somebody
signs that this level of residual risk is acceptable to the organisation
— and the modal could show five summary lines plus a collapsed block that
had to be opened. The decision was being made against a summary of a
summary.

**The same shell as Residual Analysis**, deliberately: `pm-page-heading`
with the risk as the h1, the four-step `risk-flow-4` rail, a `pm-panel`
per step, a sticky `ra-actionbar`. Every class is one the residual page
already defines; the page introduced **one** new CSS rule (below).

| # | Section | Source | Writable |
|---|---|---|---|
| **1** | Risk summary + Inherent risk | `GET /register/{id}` | no |
| | Impact Details | `riskMapping` → `acImpactScope` | no |
| **2** | Risk treatment (gate, tiles, task table) | `refreshTreatmentState` with `readOnly:true, sync:false` | no |
| **3** | Residual risk | `GET /register/{id}` | no |
| | Existing controls | `riskMapping` → `acMapping` | no |
| **4** | Acceptance decision | this page's form | **yes** |

Read-only here means **absent, not disabled** — no control to press,
because acceptance records a decision *about* what analysis and residual
assessment found and does not re-open the finding. Sections 2 and 3 carry
an *Open risk treatment* / *Open residual analysis* button instead: that
is navigation, page-to-page like `rrOpenTreatmentBtn`, clearing
`acMapping` by hand because it is the one path that leaves the page
without taking the normal exit.

**Two reads, not one.** The modal needed only `/acceptance` (the gate and
four defaults). The page also fetches the register row, so the residual
page's own renderers could be pointed at this page's hosts rather than a
second set being written.

**Every form id is unchanged from the modal** — `acRiskId`, `acGuidance`,
`acMessage`, `acAcceptedBy`, `acAcceptedDate`, `acReviewFrequency`,
`acNextReview`, `acNote`, `#riskAcceptanceForm`. `onAcceptanceSubmit`,
the 293 frequency→date rule and every validation message came across
untouched. This was a re-housing of the decision, not a rewrite of it.

What went with the modal: `closers("risk-acceptance", …)`, the
`[data-close-risk-acceptance]` handler, `clearAcceptanceScope()`, the
`#acScope` lazy-mount-on-expand (a page whose purpose is showing the
record loads the section with it), `#acMeta`, and the `.ac-scope`,
`.ac-scope-label` and `.risk-meta-2col` CSS blocks. Back, Cancel and a
successful accept all leave through `backFromFullPage()`, which now also
clears `acMapping` — and `clear()` empties the paired impact host from
stored state, so `acImpactScope` goes with it.

`renderAcceptanceFlow()` is `renderResidualFlow()`'s twin and deliberately
**not** shared with it: the two agree on steps 1 and 2 but disagree on the
two that matter. There, step 3 is the score *being chosen* and step 4 is
"next"; here, step 3 is the score *as recorded* — amber when there is
none, the one state that stops the page saving — and step 4 is current.

The one new rule: `.risk-page .pm-form-grid.ac-grid { max-width: 860px; }`.
`.ac-grid`'s 1 : 1.15 ratio was tuned for an 820px modal; on a full-width
page it stretched a date input to 700px. Scoped to `.risk-page`, so
`#riskBulkAcceptModal` — which keeps `.ac-grid` and `.risk-accept-panel`
— is untouched.

**Bulk accept is still a modal, and should be.** It asks for the four
values common to twelve risks and shows none of the per-risk record, so
there is nothing for a page to carry.

#### The bug this page exposed: two lists of tab panels

Opened from the Accept tab, the page appeared **below** that tab's list
instead of replacing it. `showFullPage()` held its own array of panel ids
to hide and `showTab()` its own six hand-written lines, and
`#riskAcceptView` was in the second but not the first — so the Accept
tab's list was the one panel no full page hid.

It had been latent since the Accept tab was added (295): every full page
opened from that tab had the same problem. It only became obvious when
acceptance itself became a page, because that is the page most often
opened from there.

Both now read one `TAB_PANELS` map — tab name → panel id — driven in
opposite directions: `showFullPage()` hides `Object.values`,
`showTab()` hides everything whose owner is not the current tab. Same
reasoning as the `FULL_PAGES` array in the other direction: a panel added
later cannot be missed by one of the two, because there is only one place
to add it.

#### The residual page's "Inherent risk before treatment" panel

`#rrInherent` shows **five** fields: Inherent rating, Likelihood, Impact,
Analysed, and **Impact analysis**.

*Cause*, *Controls at analysis* and *Score* were dropped from it.

- **Cause and Controls** — the Analysis page's *Analysis detail* section
  asks for one field now (see the `.ra-grid-single` comment in
  `risk-centre.cshtml`: the other five inputs are kept in the DOM,
  `hidden`, so a re-assessment round-trips whatever was stored instead of
  writing NULL). Nothing has been captured into them since, so on any
  risk analysed after that change they render empty for good.
- **Score** — the rating chip beside it names the level and
  Likelihood × Impact is what produced the number, so the row was the
  same fact a third time.

**Display-only.** `riskCause` and `existingControls` are still loaded
into the hidden inputs by `loadDetail()` and still sent by the assess
payload, so no column is blanked and an older risk keeps its values —
they are simply no longer shown on this panel.

**Impact analysis is not a new field.** It is `potentialConsequence`,
which is exactly what the Analysis page's *Impact Analysis* box
(`#raConsequence`) saves to. The panel previously showed the same column
under the pre-216 label *Potential consequence*, which no input on the
page uses any more. It is rendered with `pm-detail-span` (prose, so it
spans the grid) and **escaped** — `dd`'s third argument stays `false`,
because the value is analyst-typed text. `dd` gained an optional fourth
`cls` parameter for that; every existing three-argument call is
unaffected.

The same three fields still appear on **View Risk** (`Risk cause`,
`Existing controls`, `Score`, `Potential consequence`) and in the
register detail drawer (`Consequence`). Those were left alone
deliberately — this change was scoped to the residual panel — but the
reasoning above applies to them too.

**Where a saved review lands is decided by the treatment option**, by
`reviewNextStep()`:

| Option | Next screen | Why |
|---|---|---|
| `Tolerate` | Risk acceptance | Already true before the page existed. |
| `Terminate` / `Treat` / `Transfer` | Residual analysis | The next real step is the treatment work and the residual score that follows it. |
| none recorded | back to the register | Nothing to route on. |

Nobody navigates by hand. The rail's step 3 states the destination
*before* the reviewer commits, and it reads the same `reviewNextStep()`
the submit uses, so the page cannot promise one destination and go to
another.

Sending a treated risk to Acceptance instead would invite accepting a
risk whose residual has never been scored. `sp_risk_acceptance_save`
permits it — it requires only a completed analysis (56605) and a chosen
option (56606), not a residual — which is exactly why the *UI* has to
route sensibly rather than lean on a refusal that will not come.
`openResidualPage` has no entry gate of its own; if the treatment work
is still open it opens and shows its own warning banner, which is the
right landing rather than a block.

### People are shown as "Name - Role" (291, 292)

`grac_practice.fn_employee_role_names(@employee_id)` returns an
employee's active organisation roles, comma separated, or NULL. One
function, two callers: `sp_risk_register_get` (292) and the
dependency-object picker, whose SQL is built in C#
(`PracticeRepositoryService.QueryDependencyOptionsFallbackAsync`).

**All roles, not one.** `organization_employee_role` is a plain
many-to-many with no primary or priority flag, so nothing in the data
says which single role to show. Someone holding two reads
"Priya - Risk Owner, Approver".

**A function, not a correlated subquery**, because the picker's query is
config-driven and applies *no table alias*: an inner reference to
`employee_id` would bind to `organization_employee_role`'s own column
instead of the outer row. A scalar function takes the value as an
argument and cannot be captured that way.

**The role is never folded into the name.** It travels as its own
column, and `__wfCommon.personWithRole()` composes the label at render
time. This matters most in the dependency picker: the option's name is
sent as `data-object-name` and *persisted* on the mapping row, so a
role appended to the label would end up stored. The picker's checkbox
keeps the bare name; only the visible `<span>` and the collapsed
trigger text carry the role.

Where it shows: the dependency Person category on Operationalize, Risk
Analysis and Residual analysis (open list and collapsed trigger alike),
and the three acceptance displays — the register row, the read-only
Risk Details page, and the residual page's acceptance panel.

**Not yet covered:** the alert shown immediately after saving an
acceptance, and the approval-queue list. Both read their own payloads
(`RiskAcceptanceResult` and the queue row) rather than the register, so
each needs its own projection before it can show a role.

A note for whoever extends this: 291 put the column on
`sp_risk_acceptance_get` first, which is the obvious home for it and
turned out to feed *nothing that is displayed* — the acceptance form
picks the acceptor through a dropdown and never renders the name as
text. 292 added it where the UI actually reads from. Check which
procedure backs the pixels before adding a column for them.

### Acceptance requires a future review date

`sp_risk_acceptance_save` throws (56601 / 56602) without one, and this is
the single most important refusal in the flow. `next_review_date` is the
only thing that ever brings an accepted risk back — accepted with a NULL
date, a risk is invisible to Review Risk and to the calendar forever,
quietly retired without anybody deciding to retire it.

The column is `DATE`, not `DATETIME2`, so `current date >= next review
date` is exact rather than nearly right: a review dated today must appear
today, which a stray time component silently breaks for most of the day.
Both read procedures compute one `@today` per call, so every row is
judged against the same date and the predicate stays sargable against
`ix_pm_risk_register_next_review`.

#### Review frequency records what the date was derived from (293)

`risk_register.review_frequency_id` is nullable and points at
`frequency_master` — the same master the practice instance and
`organization_committee.review_frequency_id` already use, so "Quarterly"
means one thing across the product. **It is not a second authority.**
`next_review_date` remains what brings a risk back; the frequency is the
cadence that date came from, kept so the next acceptance can default the
same way and so a report can say "annually" without inferring it from two
dates. 56601 and 56602 are untouched, and a caller that sends only a date
behaves exactly as it did before.

**The arithmetic is data, not code.** `GET /review-frequencies` returns
`frequencyValue`, `frequencyUnit` and `isCustom` on every row, and the
client adds value × unit to today. A hard-coded `switch (name)` in
JavaScript would be a second place for Quarterly to mean something, free
to drift from the master the moment a row is edited.

**Three cases leave the date alone:** `isCustom` (Custom), and Event
Driven / Continuous, which are not custom but carry a null value and unit
— "every event" is not a date. All three are the same question to the
client (*can this cadence produce a date?*), and all three leave whatever
the user typed untouched rather than clearing it.

**Re-opening an acceptance does not recompute the date.** The select is
preselected from `reviewFrequencyName` (falling back through the id) by
assigning `select.value`, which fires no `change` event — so the form
shows the date that was *recorded*, not today + the cadence. The
frequency moves the date only when a person picks one.

Nullable on purpose in both directions: every acceptance recorded before
293 has a date and no frequency, and backfilling one would be inventing a
cadence out of a single date.

**294 carries the same cadence through bulk**, so accepting thirty risks
at once records what accepting one records. See *Bulk review* below —
including why that is the bulk-acceptance path rather than a feature of
its own.

#### The Accept risk form fits on one screen

Four fields and a five-line context list had a scrollbar, and the Accept
button sat below the fold on a laptop. The cause was width, not content:
the form was in the default 560px `pm-modal-panel` — the narrowest of the
three — where `pm-form-grid`'s two columns have room for one, so every
field became a full-width row and every context pair its own line.

It now uses `pm-modal-wide` (820px, this screen's existing wide token —
no new size), and the shape of the decision does the grouping:

| left column | right column |
|---|---|
| Accepted by | **Acceptance rationale** |
| Accepted date | *(spans all four rows)* |
| Review frequency *(293)* | |
| Next review date | |

Short answers — who, when, how often, when next — stacked beside the one
long one. The rationale is explicitly placed in column 2 across the rows
the left column occupies, with `align-self: stretch` so the textarea
takes its height from the column beside it rather than adding a row of
its own; the left fields are auto-placed and flow around it. **The span
tracks the number of left fields** — it was `span 3` and became `span 4`
when 293 added Review frequency, which sits immediately above the date it
drives so cause reads above effect. The
context list gains `.risk-meta-2col` (two pairs per row, the risk number
and title keeping a row of its own via `dd.span`) and drops from five
rows to three. Below 720px the grid returns to one column.

**Nothing was made smaller.** Font sizes, control heights and the
`.pm-form-grid` input styling are untouched; the height came out of empty
space. The compact padding is scoped to `.risk-accept-panel` rather than
applied to `.pm-modal-panel`, because tightening the shared rule would
reflow every modal in the product to fix one form. Validation (56601 /
56602 and their client-side affordances), the employee list, the
defaults, and the accepted-by / accepted-date / status / rationale
behaviour are unchanged — 293 added one optional field and changed
nothing else about this form.

### Task Centre is swept, not called back

Task Centre does not know Risk Centre exists and is not made to.
`sp_risk_treatment_sync` is an idempotent set operation that moves
`UnderTreatment → Monitoring` for risks whose treatment tasks have all
closed. It is called from the register load and from the treatment modal,
and calling it twice does nothing the second time — which is the property
that lets it be called liberally.

Parents only are counted (§11: the parent owns the commitment), so a
parent with three open children is **one** open treatment task. Task
Centre already refuses to close a parent while a mandatory child is open,
which is why "all treatment tasks closed" can be trusted to mean the work
is genuinely done.

---

## UI

`Views/Practice/Partials/risk-centre.cshtml` + `wwwroot/js/RiskCentre/risk-centre.js`,
one menu entry (`risk-centre`, seeded by 171 — **still unchanged**; 261–264
add tabs to the existing screen and no new menu row), five tabs:

- **Risk Candidates** — grid with source, rating, analyst, status;
  row menu: View details · Analyse · Register as risk · Return for
  clarification · Reject · Close as duplicate · Withdraw · Accept (legacy).
- **Risk Register** — grid with §23 filters and **two rating columns**,
  `Inherent` (before treatment) and `Residual` (after it, migration 258),
  plus `Stage` and `Next review` (264). Ten columns: `Risk ID`, `Risk`,
  `Category`, `Source`, `Inherent`, `Residual`, `Stage`, `Next review`,
  `Owner`, actions. `Treatment`, `Scope`, `Status` and `Registered` were
  removed on request; `Stage` subsumes most of what `Treatment` and
  `Status` carried, being derived from the treatment option and the open
  task count. **`REG_COLS` in `risk-centre.js` must match the `<thead>`**
  — it is the colspan of all four empty-state rows. The fields the
  dropped columns read are still in the payload and still drive the row
  menu, so restoring one is markup plus a renderer, not an API change.

  Row menu: View risk · Analysis · Residual risk analysis · Review
  analysis · Change status · Change owner · Practices & assets · Risk
  treatment · Accept risk · Review risk · Raise additional task (via
  candidate); and the **Create custom risk** button (Route B lives here,
  not on the Candidates tab, because §4B says a custom risk has no
  candidate). *View risk* opens the read-only **Risk Details** full page,
  *Analysis* and *Practices & assets* the full-page Risk Analysis view,
  *Residual risk analysis* the full-page Residual view; everything else
  is still a modal. `#regDetailModal` survives as what *Review analysis*
  loads — that path primes `state.activeRisk` and then hides it.
- **Review Risk** — the work queue: `next_review_date <= today`, not
  closed. A tab badge carries the count and is refreshed whichever tab is
  open. The **Horizon** control widens the window through the *same*
  procedure (`includeFutureDays`), so "due" cannot mean two things.
- **Risk Calendar** — a month grid over the same column. Deliberately
  **not** `Practice/Calendar`: that view is wired to
  `assurance_calendar_events`, a materialised schedule with rules and
  overrides, and a review date is one mutable column with no schedule
  behind it. Generalising it would mean maintaining schedule machinery
  for something that has none, and would put the assurance module at risk
  for a Risk Centre feature. The grid fetches the whole **rendered**
  range, not the calendar month, so reviews in leading/trailing days are
  not silently absent from cells that are on screen.

### Risk Analysis, Risk Treatment, Residual Risk and Risk Details are full pages, not modals

`#riskAnalysisPageView`, `#riskTreatmentPageView`, `#riskResidualPageView`
and `#riskDetailPageView` are siblings of the tab panels, shown by
`showFullPage(id)` and left by `backFromFullPage()`. None is a **new
screen key**: no menu row, no permission seed, no navigation round trip,
and all four inherit the organisation, scoring options and employee list
the partial has already loaded.

`FULL_PAGES` lists them, and `showTab()` hides every entry rather than a
named one — so a page added later cannot be forgotten and left visible
underneath a tab, which is a silent bug rather than a crash.
`backFromFullPage()` is the single exit for all four, and it clears
**every** mapping host a page can mount (`raMapping`, `rrMapping`,
`rdMapping`), so no page can be left with a stale risk id in
`riskMapping`'s host map.

### Stage vs Status — two fields, one badge

A risk carries **two** lifecycle-looking values. They are not duplicates,
and a review was run before any of this was changed.

| | `workflow_stage_code` | `status_code` |
|---|---|---|
| Where | derived in `vw_pm_risk_workflow_stage` (264) | stored column on `risk_register` (205), BRD §17 |
| Set by | nobody — computed | an operator, or a workflow step |
| Values | AnalysisDue · TreatmentDue · InTreatment · ResidualDue · AcceptanceDue · Accepted · ReviewDue · Closed | Active · UnderTreatment · Accepted · Monitoring · Closed · Retired |
| History | none possible | `risk_register_history.from_status_code` / `to_status_code` |

**`status_code` cannot be dropped.** It is load-bearing in six places:

1. **The stage view reads it.** `WHEN r.status_code IN ('Closed','Retired')
   THEN 'Closed'` is the first branch of the CASE, and `is_review_due`
   tests it too. Stage is a *function of* Status, not a replacement.
2. **Audit trail.** `sp_risk_register_status_set` writes a
   `risk_register_history` row per transition (`StatusChange` / `Close`).
   A derived value has no transitions to record.
3. **Closure facts hang off it** — `closure_reason`, `closed_dt`,
   `closed_by_employee_id`, and error 56174 refuses to close without a
   reason.
4. **It is the indexed filter.** `ix … (organization_id, status_code,
   registered_dt DESC)` (205) backs `sp_risk_register_list`'s
   `@status_code`. A per-row derived stage is not indexable.
5. **Gates.** `CanAccept` / `AcceptGuidance` (264), duplicate detection
   (206 — closed and retired risks are re-raisable, not duplicates), the
   review-due list and calendar, and the register row menu's `regClosed`.
6. **API contracts.** `StatusCode` is on `RiskRegisterDetail`,
   `RiskAcceptanceDetail`, `RiskTreatmentState` and the list rows.

So the rule is **display**, not schema:

- Every risk surface shows **one** badge, and it is the stage —
  `lifecycleChip()` in `risk-centre.js`, used by the register grid and by
  all four page headings (`raHeadStatus`, `rrHeadStatus`, `twHeadStatus`,
  `rdHeadStage`).
- `lifecycleChip()` makes one correction to the raw stage: the view
  collapses **Closed and Retired** into the stage `Closed`, so the chip
  takes the record status back for `Retired` — that value exists only in
  `status_code`, and telling a reader a retired risk was "closed" is
  wrong.
- Where the stored value genuinely has to appear it is labelled **Record
  status**, never "Status": the Risk Details context grid, the register
  detail modal, the treatment modal, and the register's own filter
  (which sits beside a Stage filter — two dropdowns both reading
  "status" was half the confusion).
- The Risk Details page previously carried both chips in its heading and
  both rows in its context grid. That was the duplication; the stage
  badge and the four-step rail carry the lifecycle now, and only Record
  status remains in the grid.

Left deliberately unlabelled: the **candidate** grids and the duplicate
match list use `risk_candidate.status_code`, a different vocabulary on a
different entity (Pending / UnderAnalysis / Registered / …). Renaming
those would be the same mistake in reverse.

#### Risk Details — the read-only one

`#riskDetailPageView` is what **View risk** on the register's 3-dot menu
opens. It is the whole life of one risk on one page: context and
traceability, inherent score, treatment decision and its tasks, mapped
practices and dependencies, residual score, acceptance.

Three things make it different from the other three pages.

**It reads only.** No input, select, textarea or save button, and no
write call. In particular it passes `sync: false` to
`refreshTreatmentState`, which otherwise POSTs `/register/treatment-sync`
before reading — right on Treatment and Residual, which act on the tasks,
but wrong here: opening a risk to look at it must not move it to
Monitoring as a side effect.

**It needed no endpoint.** `GET /register/{id}` already returns 96
fields covering context, inherent, treatment option, residual,
acceptance, review and workflow stage; `treatment-state` supplies the
gate, counts and task rows; `riskMapping` mounted read-only supplies the
mapped practices (each listing its own inherited dependencies) and the
risk's Impact Details from `/mapping` and `/practice-context` — see
[risk-obligation-structure.md](risk-obligation-structure.md#what-the-pages-show-now)
for what those two sections are. No new procedure, route, model or
column.

**Sections are gated on data, not hidden.** `riskReach(risk)` answers
five questions — analysed, treatment chosen, scope set, residual scored,
accepted — from the record itself rather than from `workflowStageCode`,
because the two can legitimately disagree (a risk can be `Monitoring` by
status with its residual unscored) and the data is what is being shown. A
section with nothing yet renders `rdNotYet(...)` naming what has to
happen first; it does not disappear, because a vanished section reads as
a missing feature while an explained one reads as a workflow.

Required fields use `ddReq()` rather than `dd()`: `dd()` drops an empty
value, which is right for optional extras but wrong for Owner or Score,
where a missing row is indistinguishable from a page that failed to
load. Those render **Not available**.

Treatment has **no target date of its own** in the schema — the date
belongs to each treatment task (`DueAt`). The page shows the earliest
still-open task's date and labels it as such rather than implying a
field that does not exist.

Risk Analysis was a modal until 261–264 gave it three more things to
carry — the scope panel, the treatment picker, and the analysis-detail
fields — at which point an 820px `pm-modal-wide` was a scrolling box
inside a scrolling page. Risk Treatment followed for the same reason: a
task grid that grows with the work, a sub-task form and a gate notice
lose the Due and Sub-task columns to wrapping at that width. Residual
Risk followed last, and most obviously: it carries the *same* scope
panel, the *same* treatment picker, three long-form fields and the §20
history table, inside a panel capped at `max-width: 900px` and
`calc(100vh - 80px)` — the content compressed into a narrow scrolling box
while the master layout's width sat unused on either side of it.
`practice-view.cshtml` (migration 139) made the same move
for the same reason, and these pages follow its conventions: `pm-panel`
per section, `pm-section-heading` on each, `pm-form-grid` for fields, and
the full `container-fluid` width the master layout already provides.

Layout (Analysis and Treatment): context beside scoring on row 1 (the
analyst reads one to choose the other), then detail at three columns,
then scope, then treatment. The Residual page follows the sequence
described under *The Residual page is the third step of a story* below.
All three collapse 3→2→1 columns at 1400px and 760px, and the
context/scoring split stacks at 1100px, so a 1200px laptop gets a middle
layout rather than jumping straight to one column. The action bar is
sticky — on a form this tall, a footer that scrolls away means scrolling
to the end to save and back to read the validation message that stopped
it. Inner scrollbars on the mapping lists are removed on these pages
(`max-height: none`): a scroller inside a section inside a scrolling page
hides rows the page has room to show.

**The shell is a class, not an id.** Every rule above is written against
`.risk-page`, which is why Residual Risk needed no new CSS at all — it
declares the same shell and inherits the same breakpoints, the same
sticky bar and the same detail-grid rhythm. Rules keyed to
`#riskAnalysisPageView` would have had to be copied a third time, and a
copy is what drifts.

Exactly one of {a tab, a full page} is visible; `showTab()` hides every
full page and `showFullPage()` hides the tab bar **and** the partial's
own `pm-page-heading`, because each page carries its own heading naming
the risk. `analysisReturnTab` remembers where it was opened from, so
opening it from Review returns to Review — and the Residual page sets it
too, so reaching it from the treatment page still returns to the tab the
user actually started on.

## Risk acceptance approval authority (migration 271)

**Organization → Risk Acceptance Approval Authority.** Who may approve
*accepting* a risk, per rating level, separately for the inherent score
and the residual one.

An **Organization** configuration screen, not a Risk one: it configures
the organisation, and the Risk Centre reads it. Menu row is a child of
`nav-organization` (the same shape migration 059 used), screen key joins
`Manage.cshtml`'s `workflowScreens`, and the page follows
`org-sla-config`'s conventions.

### It extends `org_risk_config`, it does not replace it

Migration 212 already carried `approval_required`,
`approval_min_rating_code` and **`approver_role_id`** — one role for
everything above a threshold. The gap was granularity, so 271 adds a
child table at the finer grain and **leaves 212 intact**:

> a configured `(rating, scope)` row wins; where none exists,
> `approver_role_id` still applies.

That is what makes 271 safe on a live system — an organisation that never
opens the page behaves exactly as it does today. Nothing is migrated,
nothing switched off. `sp_risk_acceptance_authority_resolve` reports
`ResolvedFrom` as `Configured` / `SameAsInherent` / `OrgFallback`, so a
screen can say *why* a role applies, and the page labels rows still
running on the organisation default.

### The levels are derived, not enumerated

The obvious build seeds five rows — Low, Moderate, High, Very High,
Critical — and renders them. That would have been wrong.

`rating_code` is free text **by design** (204) and `risk_matrix_cell` is
**per organisation**. The default matrix produces **four**: `Low`,
`Medium`, `High`, `Critical`. Hard-coding five would have created two
rows the matrix can never emit and omitted `Medium`, which it emits
constantly — leaving every Medium risk with no authority configured. It
would also have contradicted `sp_risk_config_save`'s 56222, *"not a
rating this organisation's risk matrix produces"*.

So the rows come from `SELECT DISTINCT rating_code FROM risk_matrix_cell`
for the organisation. Four today, five the day a matrix says five, with
no code change. There is deliberately **no rating vocabulary in the
JavaScript** either — a list there would be a second place for it to live
and the first place for it to drift.

### "Same as inherent" is a link, not a copy

The checkbox could copy the inherent role into the residual row. It does
not, because that loses the intent: an organisation saying "residual
follows inherent" means it should *keep* following. A copy freezes it at
the value it had the day the box was ticked and the two diverge silently
on the next edit. So `same_as_inherent` is a stored flag with `role_id`
NULL beside it, resolved at read time.

### Validation, all before anything is written

| Refused | Because |
| --- | --- |
| 56745 | a rating this organisation's matrix does not produce |
| 56746 | a role belonging to a different organisation |
| 56747 | "same as inherent" with no inherent approver to be the same as |

A rejected save leaves the configuration exactly as it was, and the save
procedure ends by re-running the get — so the page renders **what was
stored**, never what it hoped it sent.

### Auditability

`org_risk_acceptance_authority_history` records field-level changes —
`field_code` / `from_value` / `to_value`, written *before* the update
while the old values still exist, and only where something genuinely
differed. Re-saving an unchanged grid writes nothing.

Worth noting: **212's own `sp_risk_config_save` writes no history at
all.** That gap is not repeated here, but it is still open for the
settings 212 owns.

---

### Status decides acceptance (migration 299) — supersedes 296/297's rule

**`status_code = 'Monitoring'` is what puts a risk on the Accept tab.**
A review always sets it, so a reviewed risk always comes back for
acceptance, whatever its dates say.

296 inferred the same thing from the *absence* of a review date, and 297
made bulk review clear that date so the inference would fire. It worked
and it was the wrong shape, for two reasons that showed up in the first
hour of real use:

1. **It fought the UI.** The Review Frequency select (294) *fills in* the
   next review date when you choose a cadence — so picking "Annual", the
   obvious thing to do, silently guaranteed the risk would never reach
   the Accept tab. Twelve reviewed risks sat in stage `Accepted` with a
   date of exactly today + 12 months and nothing on screen said why.
2. **It destroyed the reviewer's input.** To route a risk onward, 297 had
   to throw away the date and cadence just entered — precisely what the
   person accepting it wants to see.

Reading intent out of a `NULL` is a guess; a status states it.

#### The date and the cadence are proposals now

The reviewer suggests "next review in a year, annually"; both are stored
on the risk; the Accept screen opens with them filled in; whoever accepts
may change either. No UI work was needed for the last part —
`sp_risk_acceptance_get` has returned `ReviewFrequencyId`/`Name` since
293 and the modal already prefills from them.

The single Review page gained a Review frequency select to match the bulk
form. It opens unset, because that page reads `/register/{id}` and
`RiskRegisterDetail` doesn't carry those two columns; adding them to
`sp_risk_register_get` is all that's needed to light it up.

#### Why `Monitoring` and not a new status

§17 already has it, 264 already moved a reviewed risk into it, and 264's
own header calls it "§17's existing word for that". A new status would
have to be added to the register filter, the dashboard tiles and every
report that enumerates statuses.

264 only set it **when the risk was already `Accepted`**. 299 sets it for
any risk that isn't Closed or Retired — otherwise a risk reviewed from
`Active` or `UnderTreatment` would keep its status and appear on no list
at all, which is the same class of silent gap this section exists to
describe.

`sp_risk_treatment_sync` (263) also sets `Monitoring`, when a treated
risk's tasks all close. Those are unaffected: the `InTreatment` and
`ResidualDue` branches sit above the acceptance branch, so such a risk
still goes to its residual assessment first and reaches `AcceptanceDue`
only once that's done.

**Bulk review defaults `@status_code` to `Monitoring`** when the caller
gives none — set *after* 56721's "supply at least one field" check, so
that rule still bites, and routed through `sp_risk_register_status_set`
like any other status. 270's DECISION 1 stands: the procedure still never
writes `status_code` itself.

#### The bulk review form has no Status picker

It was removed once the status became the routing rule. A bulk review
already says what it is, and the procedure says it in the status — so a
Status box let one action contradict itself, in both directions:

- choosing `Accepted` on an already-`Accepted` risk changed nothing at
  all, because `sp_risk_bulk_review` only acts when
  `@status_code <> @cur_status`. The risk was reviewed, the audit row
  read `Accepted -> Accepted`, and it never reached the Accept tab;
- choosing *anything* overrode the `Monitoring` default and so stopped
  the review routing onward.

The client now omits `statusCode` entirely. Nothing was lost: accepting
in bulk has its own place — the Accept tab's **Accept selected**, backed
by `sp_risk_bulk_accept` (295) — and forcing some other status is a
per-risk decision that belongs on the risk.

The form is three fields, and all three are the same kind of thing: what
happened (description) and what the reviewer *suggests* for next time
(frequency, date). Neither suggestion decides anything.

`sp_risk_bulk_review` still **accepts** `@status_code`, so the API
contract is unchanged and an integration that sends one still works. Only
the form stopped offering it.

> 296 and 297 stay applied — **296's Tolerate fix is still required** and
> 299 preserves it. Only their null-date routing is gone.

### A reviewed risk returns to Acceptance (migration 296)

**The symptom:** review three risks and they vanish — absent from the
Review tab, absent from the Accept tab, visible only under Accept →
*Already accepted*, the one place they do not belong.

`sp_risk_review_perform` clears `next_review_date` (the Review form
leaves that field blank by default), turns `Accepted` into `Monitoring`,
and **leaves `accepted_dt` exactly as it was**. 264's stage view then
ended `WHEN accepted_dt IS NULL THEN 'AcceptanceDue' ELSE 'Accepted'`, so
the stale timestamp sent every reviewed risk to `ELSE`. The stage said
settled, the status said `Monitoring`, and no list claimed it.

That contradicted 264's own header for the procedure, which says a
reviewed risk "may need new treatment, a new residual assessment, or a
fresh acceptance… the next review date is set again when the risk is next
**accepted**". The intent was always review → acceptance; the view never
expressed it. So the procedure is untouched and the view is corrected.

**The test is exact, not a heuristic.** `sp_risk_acceptance_save`
requires a next review date and throws 56601 without one, so every
accepted risk has one by construction. A risk that is otherwise ready and
has *no* date can therefore only be one a review cleared. Nothing else
produces that combination — bulk review `COALESCE`s the existing date
rather than clearing it, and so does 294.

Reviewing **with** a date still means "see me again then" and keeps the
risk scheduled, exactly as 264 describes for a caller that passes
`@next_review_date`. Only the blank-date review routes back to
acceptance.

#### Bulk review returns risks too (migration 297)

296 alone fixed only the *single* review, because the two procedures
disagreed about what "review" writes:

| | `next_review_date` after |
| --- | --- |
| single review | `= @next_review_date` — blank **clears** it |
| bulk review (270–294) | `COALESCE(@new, existing)` — **never** cleared |

So reviewing thirty risks at once did something different from reviewing
the same thirty one at a time: the single path returned them for
acceptance, the bulk path kept their old schedule and returned nothing.
297 makes bulk review assign the date, so **a blank date clears it and
the risks land on the Accept tab** — which is where the next review date
gets set, by the one procedure that requires it.

A reviewer who means "reviewed, no change, see me in a year" still types
that date into the bulk form and gets exactly that. Only blank — the
form's default — means "back to acceptance", and the field now says so.

**Status = Accepted is unaffected**: that path calls
`sp_risk_acceptance_save`, which refuses a NULL date (56601), so such a
call always carries one and assignment and `COALESCE` are identical
there.

**The cadence is deliberately not cleared with the date.**
`review_frequency_id` keeps its `COALESCE`, because it describes the last
*acceptance*, not the schedule — so the Accept page opens preselected
with the frequency the risk was last reviewed on, which is nearly always
the one it will be given again.

Three things had to move with it, each marked `CHANGED IN 297`: the
`@applied` test and the `next_review_date` audit row were both guarded by
*"the new value is not NULL"*, so clearing a date reported `Unchanged`
and wrote no history at all; and the report's `ToReviewDate` was
`COALESCE(@new, @old)`, which would have shown the old date as though it
had survived.

#### Tolerate is now decided inside its own branch

Proving the above surfaced a second, older defect on the same path.

The Tolerate branch sits **above** the residual check on purpose, so a
Tolerate risk never waits on an assessment it will never have. But 264
guarded it with `accepted_dt IS NULL` — so the moment such a risk was
accepted it fell *past* Tolerate, past both `InTreatment` tests (Tolerate
is in neither list), and landed on `ResidualDue`. Nothing ever clears
`residual_pending` for a Tolerate risk, because a Tolerate risk never has
a residual assessment. **Every accepted Tolerate risk was therefore
reading `ResidualDue`**, waiting forever on an assessment that will never
come — in the register grid, the dashboard, and the Accept tab's
*Already accepted* view.

Tolerate is now resolved entirely by a nested `CASE` inside its own
branch: `AcceptanceDue` or `Accepted`, never anything else. A Tolerate
risk can no longer reach a branch that does not apply to it.

| scenario | 264 | 296 |
| --- | --- | --- |
| Tolerate, never accepted | `AcceptanceDue` | `AcceptanceDue` |
| Tolerate, accepted + scheduled | **`ResidualDue`** | `Accepted` |
| Tolerate, reviewed (no date) | **`ResidualDue`** | `AcceptanceDue` |
| Treat, accepted + scheduled | `Accepted` | `Accepted` |
| Treat, reviewed (no date) | **`Accepted`** | `AcceptanceDue` |
| Treat, reviewed (future date) | `Accepted` | `Accepted` |
| Treat, tasks open / residual pending | `InTreatment` / `ResidualDue` | unchanged |
| review date arrived | `ReviewDue` | `ReviewDue` |

Only the bolded rows move. The view is joined by `sp_risk_register_list`,
`sp_risk_register_get`, `sp_risk_acceptance_get` and the calendar feed —
which is the point: one definition of "ready to accept", corrected once,
so every screen agrees.

### Accept Risk tab and bulk accept (migration 295)

**Accept Risk** sits between Register and Review, because that is the
order the work happens in: a risk is accepted once, then returns on a
cadence.

**The list is not a new query.** It is `GET /register` filtered to
`workflowStageCode=AcceptanceDue` — the stage
`vw_pm_risk_workflow_stage` (264) already computes as *Tolerate chosen,
or the residual assessment is done, and `accepted_dt IS NULL`*. A second
definition of "ready to accept" would let the tab, the register grid and
the dashboard disagree about the same risk. The **Show** toggle swaps
that one value to `Accepted`; same endpoint, same renderer, so the person
who just accepted twelve risks can see them without leaving the tab.
Already-accepted rows are not selectable — re-accepting is a review
decision and belongs to the Review tab.

**Single accept is the existing page.** The row button opens the same
`#riskAcceptancePageView` the register and residual pages open, with its
own `acceptGuidance` banner. The tab adds a way to *reach* acceptance,
not a second way to *do* it.

#### Bulk accept is not bulk review with status Accepted

Both exist, both are correct, and the difference is the review stamp:

| | `sp_risk_bulk_accept` (295) | `sp_risk_bulk_review` (270/294) |
| --- | --- | --- |
| Calls | `sp_risk_acceptance_save` | `sp_risk_acceptance_save` (Accepted) or `sp_risk_register_status_set` |
| `review_count` | **untouched** | incremented |
| `last_reviewed_dt` | **untouched** | stamped |
| History | `RiskAccepted`, from acceptance itself | `BulkReview` + field-change rows |
| Means | "these were accepted" | "these were looked at, and here is where they now stand" |

Stamping a review on a risk being accepted for the **first** time records
a review nobody performed — `review_count = 1` on a risk no one has
reviewed, and a `last_reviewed_dt` the Review queue and every ageing
report will believe. Re-accepting a risk *at its review date* genuinely
is a review, and that stays on the bulk review path.

They share the one thing that must not diverge: **both call
`sp_risk_acceptance_save`**, so analysis-complete (56605), treatment
option chosen (56606), not Closed/Retired (56604), accepter in the same
organisation (56608) and a future review date (56601/56602) are enforced
in exactly one place. 295 decides *which* risks to call it for and what
to report; it decides nothing about whether a risk may be accepted.

295 writes **no audit row of its own** — `sp_risk_acceptance_save`
already writes one `RiskAccepted` row per risk. A bulk acceptance of
thirty risks *is* thirty acceptances, and thirty identical rows is the
correct record of that; the shared `acceptanceNote` lands on each, which
is where "accepted at the Q3 risk committee" belongs.

`acceptedByEmployeeId` travels from the browser (who the acceptance is
recorded **for** — often a committee chair), while `actorEmployeeId` is
stamped from the session (who **performed** it). The same distinction the
single Accept page already makes. The picker defaults to the signed-in
employee, rendered into the form from session by the view, and only when
that employee is in the organisation's list — offering a default the
server would refuse with 56608 would be worse than offering none.

#### `@suppress_result`, not `INSERT ... EXEC` (migration 298)

294 and 295 silenced the leaked inner result sets (below) with
`INSERT ... EXEC`. **That was the wrong fix, and it broke the
skip-and-report path both procedures exist for.**

SQL Server forbids a procedure called inside `INSERT ... EXEC` from
issuing `ROLLBACK` — and both composed procedures do exactly that in
their `CATCH`:

```sql
BEGIN CATCH  IF @@TRANCOUNT > 0 ROLLBACK;  THROW;  END CATCH
```

So the moment a risk legitimately failed a rule — no treatment option
(56606), analysis incomplete (56605), accepter in another organisation
(56608) — the procedure entered its `CATCH`, hit its own `ROLLBACK`, and
SQL Server raised

> Cannot use the ROLLBACK statement within an INSERT-EXEC statement.

The real refusal was destroyed and replaced by that, leaving a doomed
transaction behind it. **The happy path worked**, which is precisely what
made it easy to miss: it fails only when a risk is skipped, which is the
one case the design is for.

**The fix already existed in the codebase.** `sp_risk_analysis_save`
(206) and `sp_risk_treatment_option_set` (263) both carry a
`@suppress_result` parameter for this exact problem, and 263's header
explains why. 298 adds the same parameter to the two procedures that
lacked it, and both bulk procedures now call them plainly with
`@suppress_result = 1`.

Sections 1 and 2 of 298 are strict supersets — the parameter defaults to
`0`, so the API, the single Accept page and the review page behave
exactly as before. `sp_risk_bulk_accept` now reads `AcceptedOn` and the
status back from `risk_register` instead of from the captured result set:
the same information, from the row acceptance just wrote.

**The lesson worth keeping:** when an inner procedure's result set is in
the way, add `@suppress_result` to it. `INSERT ... EXEC` looks like the
same thing and is not — it takes over the callee's transaction control.

#### The bulk procedures leaked a result set per risk (fixed in 294)

Both `sp_risk_acceptance_save` and `sp_risk_register_status_set` **end
with a `SELECT`**. 270 `EXEC`'d them bare inside its loop, so every risk
that changed status pushed a result set to the client *ahead of* the
report. `BulkReviewAsync` never called `NextResult`, so it read the first
one it was handed and threw `IndexOutOfRangeException` on `Outcome` —
which is not a `SqlException`, so it escaped the catch as a 500.

That is why bulk review worked with only a note or a date (no `EXEC`, so
the report *was* the first result set) and failed the moment a status was
chosen — **which is every bulk accept**. Both `EXEC`s are now
`INSERT ... EXEC` into a discard table, so the procedure returns exactly
one result set as its callers always assumed; 295 uses `INSERT ... EXEC`
from the start, and reads the captured row so the report states the
`AcceptedOn` that was actually written.

The C# in both bulk methods also skips forward to the result set carrying
an `Outcome` column. That is redundant against a fixed database and
rescues one still on unfixed 270 — a real deployment state, since the API
ships independently of the migrations.

> **If 294 was already applied, run it again.** It is `CREATE OR ALTER`
> and re-running is safe; the first version of the file carried the leak.

### Bulk review (migrations 270, 294)

Checkboxes on the **Review Risk** grid, a bar that appears once something
is selected, and a four-field form: **Description · Status · Review
frequency · Next review date**, applied to every selected risk.

**Bulk acceptance is this screen**, not a separate feature. Setting
Status to `Accepted` routes each risk through `sp_risk_acceptance_save`,
so accepting thirty risks obeys exactly the rules accepting one does. A
dedicated "bulk accept" was considered and rejected in 294: it would be a
second caller of the acceptance procedure, free to drift from this one.

#### It is not the single-risk Review over a list

`sp_risk_review_perform` is a **re-assessment**: `@risk_category_code`,
`@likelihood_code` and `@impact_code` are required, and it delegates to
`sp_risk_register_assess` to produce a new rating. Those are per-risk
judgements — one likelihood/impact pair applied to thirty risks would be
an assessment nobody made.

So `sp_risk_bulk_review` records a **review disposition** instead: it was
looked at, here is the note, here is where it stands, here is when to
look again. It stamps `last_reviewed_dt`, increments `review_count`,
moves `next_review_date` and optionally sets status. A risk that needs a
genuine re-score still goes through the single-risk Review, which is
untouched.

#### Why only these fields

| Field | Writes to |
| --- | --- |
| Description | the **review's** remark + the audit trail |
| Status | routed through the owning procedure (below) |
| Review frequency *(294)* | `review_frequency_id`, with an old → new audit row |
| Next review date | `next_review_date`, with an old → new audit row |

Description deliberately does **not** write `risk_register.risk_description`.
That column is what each risk *is*; applying one value to five risks
would erase five different descriptions.

**The test for admitting a field is whether one value across thirty risks
would be a fact or a fabrication.** A cadence passes it: "review these
quarterly" is a scheduling decision genuinely shared by a quarterly
sweep, exactly as the date beside it is. Likelihood and impact fail it,
which is why they are still absent.

#### Where the cadence is written (294)

The same two paths `next_review_date` already had, so the pair cannot
disagree:

| Status | `review_frequency_id` written by |
| --- | --- |
| `Accepted` | `sp_risk_acceptance_save`, which owns the column — passed through, not written twice |
| anything else, or unchanged | `COALESCE(@review_frequency_id, review_frequency_id)` in the review stamp |

Writing it on the non-accept path bypasses no rule: the column records a
*derivation*, not a gate. `next_review_date` remains the authority for
when a risk comes back, and 56601 / 56602 / 56722 are untouched.

**An unknown or inactive cadence is refused once, up front** (56726),
following 270's rule that input validation refuses outright while
per-risk conditions skip per risk. Left to the foreign key it would
surface as fifty identical constraint messages, each reported as a
per-risk skip — blaming the risks for a fault in the request.

A frequency alone does **not** satisfy 56721's "supply at least one of
remarks, status or next review date". With no date, status or note there
is nothing for a cadence to describe; and since picking one fills the
date, this never blocks real use.

#### Status still obeys every rule

Bulk tools usually go wrong by writing `status_code` directly and quietly
producing states the product believes are impossible. This composes:

| Target status | Goes through | Which enforces |
| --- | --- | --- |
| `Accepted` | `sp_risk_acceptance_save` | 56604/05/06/07/08 — analysis complete, treatment option chosen, not Closed/Retired, accepter in the same org |
| anything else | `sp_risk_register_status_set` | 56172/73/74 |
| `Closed` / `Retired` | **refused** (56724) | §20 — each needs its own reason, which one shared note cannot give |

**Bulk changes the number of risks, not the rules.**

#### Skip and report, never fail the batch

A risk failing a precondition is skipped with its own reason and the rest
proceed — one ineligible risk in fifty must not block forty-nine. Every
risk comes back with `Applied` / `Skipped` / `Unchanged`, and the UI
lists the skipped ones first, because those are the ones needing action.
The per-risk `EXEC`s run in their own `TRY/CATCH`: a `THROW` from the
composed procedures is *information* ("this risk has no treatment
option"), not a fault.

`success: true` therefore means **the batch ran**, not that every risk
was updated. A client reporting "saved" without reading `skippedCount` is
lying to the user.

#### The date rule is checked once

A next review date in the past fails identically for every risk
(56602/56616), so it is rejected up front (56722) rather than producing N
copies of one message. The UI checks it too, before the round trip.

#### `risk_register_history` gained three columns

The audit requirement was old → new for the review date.
`risk_register_history` had `from_status_code`/`to_status_code` and
nothing else — it could express a status change and no other kind. The
alternative was prose in `remark` that an auditor would have to parse.

So it now carries **`field_code` / `from_value` / `to_value`** — the same
three `task_activity` has had since 192. A field change is a queryable
row, not a sentence:

```
field_code = 'next_review_date'   from = '2026-06-01'   to = '2026-12-01'
```

All three are nullable and nothing existing writes them, so every
pre-270 row stays valid. **270's rollback deliberately keeps them** —
dropping them would destroy the very values the requirement asked to
capture.

### Row menus: three states, not two

Shared contract with Task Center (see `docs/task-centre-v2.md`):
`applicable: false` **hides**, `disabled` + `disabledReason` **greys**,
neither **enables**. A terminal or structural fact hides; an unmet
prerequisite disables.

Worked through for this module:

| Item | Hidden when | Greyed when | Server rule mirrored |
| --- | --- | --- | --- |
| Assessment (candidate) | candidate is closed | — | §16 open statuses |
| Analysis | risk Closed/Retired | — | — |
| Residual risk analysis | risk Closed/Retired | analysis pending · still `Active` · option is Tolerate · a treatment task is still open | 56455 / 56454 / 56456 / 56574 |
| Review analysis | closed, **or approval not configured for the org** | no analysis submitted yet | §19 |
| Practices & assets | risk Closed/Retired | — | — |
| Risk treatment | closed, **or the option is Tolerate** | no treatment option chosen yet | §21 |
| Accept risk | risk Closed/Retired | analysis pending · no treatment option | 56604 / 56605 / 56606 |
| Review risk | risk Closed/Retired | analysis pending | 56618 |
| Raise additional task | risk Closed/Retired | — | 56382 |
| Reassign (treatment task) | task closed | — | *(no server guard — see below)* |
| Complete task | task closed | mandatory sub tasks open | §12 / `sp_task_complete` |
| Add Sub Task | the row **is** a sub task, or is closed | — | §11 |

Cases worth their reasoning:

- **Tolerate hides Risk treatment but only greys Residual.** Choosing
  Tolerate *means* no treatment task is raised (§21), so there is
  literally no treatment page to open — hidden. Residual is different:
  `sp_risk_residual_analysis_save` would *accept* it, and the option can
  be changed, so it is greyed with the signpost
  `sp_risk_treatment_state` itself gives — accept the risk instead.
- **Approval not configured hides Review analysis; no analysis yet greys
  it.** The first is a configuration fact about the organisation, and
  nothing the reader does to this risk turns it on. The second clears the
  moment the risk is analysed, and the reason points at the Analysis item
  directly above it.
- **Reassign is hidden on a closed task although `sp_task_assign` has no
  terminal guard.** The refusal is the UI's, and it is a hide rather than
  a grey because there is no work left to reassign and no future state of
  that task in which there is. Noted here because it is the one gate on
  this screen with no SQL behind it.

**The menu mirrors what the save REFUSES, not what a readiness view
reports.** `sp_risk_treatment_state` also reports residual as unavailable
when no treatment option is recorded and when no task has been raised —
but `sp_risk_residual_analysis_save` permits both, deliberately: gate 3's
own comment (263, validation case 13) says tightening must not make
pre-263 rows, which have no option recorded, unassessable. Greying the
menu item on those would re-impose in the UI a rule the procedure went
out of its way not to impose, and would strand exactly the legacy rows
that case protects. `residualMenuGate()` therefore has one branch per
`THROW`, and says so.

One deliberate difference remains between the two entry points to
residual analysis: the **Risk Treatment page's** button follows the
server's `residualAvailable` (it has the task counts on screen and is
answering "is this work finished?"), while the **register row menu**
follows the save's refusals. They can differ in one case — an option
chosen with no task raised — where the page greys the button and the menu
does not. Closing that gap properly means returning `ResidualAvailable`
from `sp_risk_register_list` rather than re-deriving it client-side.

A Closed or Retired risk is left with **View risk**, plus *Change status*
and *Change owner* — those two are deliberately **not** gated, because no
server-side rule refuses them on a closed risk and inventing one in the
UI would be a rule that holds on one screen. If they should be refused,
that belongs in SQL first.

### The treatment task table: hierarchy and row actions

**Parent-child, disclosed.** Rendered flat, a parent and its sub tasks
read as unrelated rows and the §11/§12 relationship has to be inferred
from a `parent_task_id` nobody can see. So the parent is the row and its
sub tasks hang beneath it behind a chevron.

- **Collapsed on load.** A risk with four treatment tasks and a dozen sub
  tasks otherwise opens as sixteen undifferentiated rows; the reader came
  for the four.
- Child rows carry `data-tw-parent`, are indented, and are marked with a
  left border so they read as one group rather than four separately
  shifted rows.
- Children are **emitted hidden, not withheld** — expanding flips a
  `hidden` attribute on rows already in the DOM, so it costs no request
  and cannot fail.
- A childless parent gets a spacer, not a dead chevron, so the Task
  column stays aligned.
- **Expansion survives a re-render.** Every action on this page
  re-renders the table; a state that reset each time would swallow the
  sub task the user had just created. `state.twExpanded` holds the open
  parents and is cleared only when a *different risk* is opened — which
  is where "on load" actually begins. Both Add Sub Task paths add their
  parent to that set before refreshing, so the new row is visible.
- A child whose parent is **not** in this list (raised against a legacy
  candidate source) has no toggle to reveal it. It is never hidden, and
  says `sub task (parent not listed)` rather than appearing to be a
  top-level task.

**Row actions.** Open in Task Center · Add Sub Task · Reassign ·
Complete task · Close task.

Every one posts to an endpoint that **already existed** and is already
proxied by `Web/Controllers/TaskController.cs`:

| Action | Endpoint | Procedure |
| --- | --- | --- |
| Complete | `POST /practice/api/tasks/{id}/complete` | `sp_task_complete` |
| Reassign | `POST /practice/api/tasks/{id}/assign` | `sp_task_assign` |
| Close | `POST /practice/api/tasks/{id}/close` | `sp_task_close` |

**No API method, no procedure and no table changed for this.** Closing
and reassigning were always possible; this page had no way in to them, so
the work had to be finished in Task Center.

#### Complete and Close are both offered, and that is deliberate

`sp_task_complete` carries the BRD §12 mandatory-child gate and throws
55693 while a mandatory sub task is open. `sp_task_close` carries **no
child gate at all** — it sets `closed_at` and moves on.

`sp_risk_treatment_state` counts a task as done when
`ClosedAt IS NOT NULL OR IsTerminal = 1`, so **both** open the residual
gate. Which means Close on a parent with open mandatory sub tasks unlocks
residual analysis with the work underneath it unfinished — bypassing the
rule the panel above the table promises.

That is Task Center's existing behaviour (its own Close is disabled only
when the task is already terminal), and this page does not quietly
diverge from it. It does not hide it either: the confirm names the bypass
and counts the sub tasks it steps over, and *Complete* is offered first
and disabled with the §12 reason rather than being absent. **If that
bypass should not exist, the fix belongs in `sp_task_close` — a child
gate there closes it for Task Center too.** It is not closed here,
because a UI-only refusal would be a rule that holds on one screen.

`sp_task_assign` has no terminal guard either — it would happily move a
closed task to a new owner. Reassign is disabled on closed rows in the
UI, and the disabled reason says why rather than implying a server rule.

#### Reassign is a picker, not a `prompt()`

Task Center's own Reassign prints an employee list into a `prompt()` and
asks the operator to type an id back — the same interaction the common
Task/Sub Task form replaced for Add Child Task. `#riskTaskAssignModal`
uses `state.employees`, already loaded on this page for the owner and
acceptance selects, and pre-selects the current owner; submitting
unchanged is refused rather than writing an audit row recording no
change. The reason goes to `sp_task_assign`'s `@reason_text`, so the
`audit_trail` row says *why* the owner changed.

This modal is Risk Centre's for now. Promoting it to a shared component
would fix Task Center's prompt too, and is the obvious next step — but it
touches Task Center, so it is a deliberate separate change rather than a
side effect of this one.

**Risk Treatment page**: risk context beside a treatment-progress panel
(the gate notice plus four `risk-tile` counts — tasks, open, closed, open
sub tasks), then the Task Center grid, then the add-sub-task form at
three columns, then the sticky action bar carrying Close · Add sub task ·
Residual risk analysis. Every field the modal had is still there; the
counts moved from a sentence into tiles because a page has room to show
the shape of the work. Sub tasks still go through Task Centre's own
`practice/api/tasks/{id}/children`, and priority and SLA are still not
asked for — a child inherits both (BRD §11), and a field that would be
ignored should not be offered.

### The Residual page is the third step of a story, not a score box

A residual rating is *what is left after treatment*. Asked on its own it
is unanswerable: a reduction from what, achieved by what work? The page
was showing only the third term of `inherent → treatment → residual` and
expecting the analyst to hold the first two in their head — or to leave,
read the Treatment page, and come back.

So the page states the whole sequence and asks for one part of it:

| | Section | Source | Writable |
|---|---|---|---|
| **1** | Risk summary + Inherent risk | `sp_risk_register_get` | no |
| **2** | Risk treatment | `sp_risk_treatment_state` + the register row | **no** |
| **3** | Residual risk (score + analyst remark) | this page's form | yes |
| | Existing Controls (scope) | `riskMapping` | yes |
| | Acceptance & next review | `sp_risk_register_get` | no |
| | Residual history (§20) | `/residual/history` | no |

#### The page asks for a score and one remark — nothing else

Two things were removed from it.

**The Treatment option radios.** The page used to end by asking the
analyst to make a treatment decision *again*, after scoring the residual
risk. Assessing the residual risk **is** the conclusion; the only sensible
next step from there is acceptance, so asking for it was asking someone to
confirm the obvious with four ways to get it wrong — including re-raising
a treatment task nobody wanted.

Nothing replaced it, and no code decides the routing:
`sp_risk_residual_analysis_save` sets `residual_pending = 0`, and
`vw_pm_risk_workflow_stage` then reads the risk as `AcceptanceDue` on its
own — the treatment tasks are closed (56574 refuses the save otherwise),
the residual is assessed, and it has not been accepted. It appears on the
Accept Risk tab by itself.

The procedure still **accepts** `@treatment_option_code` and the API still
carries it, so an integration that genuinely needs to change the option
can; this page simply stops asking. A risk that really does need another
round of treatment is a different decision and belongs on the Risk
Treatment page, not tacked onto the end of a scoring form.

**The Justification card.** It asked for *Treatment carried out* and
*Controls now in place* as free text — both of which the page already
shows: the treated task details in step 2, read-only and straight from
the task records, and the controls in the Existing Controls panel. Asking
the analyst to retype them produced a second, hand-written copy that could
disagree with the first, and §20's version history then retained the
disagreement.

Only **Analyst remark** survived, and it moved into the Residual risk card
beside the score it explains — it was the one field on that card whose
content exists nowhere else. The client no longer sends `treatmentSummary`
or `residualControls`; both remain on the request model and in the
procedure, so older versions keep whatever they recorded.

Above them, `#rrFlow` — now a **four**-box rail carrying the *actual values*:
the inherent chip with its likelihood × impact, the treatment option with
its live task counts, the residual chip as it is being chosen, and **Risk
acceptance as the destination**. That fourth box is what replaced the
treatment radios: the analyst is *told* where the risk goes rather than
asked. It is a summary as much as a signpost, and step 3 redraws on every
change of the two selects. `renderResidualFlow()` fetches nothing; it renders what
the page already holds, which is what makes redrawing it per keystroke
free. A `#rrDelta` line under the rating preview states the difference in
words (`High → Medium — exposure reduced (12 → 6)`), because the point of
scoring twice is the movement between the two scores.

**Step 2 is a read-only lens, rendered by Treatment's own code.**
`refreshTreatmentState()` took the Treatment page's element ids as
constants; it now takes them as parameters (`TW_HOSTS` supplies the old
values as defaults, so that call site is unchanged) and `taskRow()` takes
`readOnly`, which omits the actions column rather than disabling it. The
Residual page therefore shows the same gate wording, the same tiles and
the same parent/sub-task grouping as the Treatment page, from the same
read — not a second rendering that drifts the day either changes. The
heading's *Open risk treatment* button navigates to the page that does
the editing; there are no treatment inputs here.

Two deliberate differences on that call:

- **`sync: false`.** The Treatment page runs the `UnderTreatment →
  Monitoring` sweep before it reads, because the user is acting on those
  tasks. A read-only section must not move a risk's status as a side
  effect of being looked at.
- **`readOnly` does not write `state.treatmentTasks`.** That cache feeds
  the Treatment page's row menu; letting a page that only looks fill the
  cache a page that acts reads from is a coupling with no upside.

**Incomplete treatment is stated twice, and stated carefully.** The gate
banner sits beside the tasks in step 2; a second banner sits beside the
score in step 3, because by the time the analyst is choosing a likelihood
the first one is three panels up. Both come from `sp_risk_treatment_state`'s
own `reason`. The second one names a refusal **only** when a treatment
task is open — that case is guaranteed by 56574, while the gate also
closes for reasons that do not block a save (Tolerate, no task raised),
and a banner that promises a refusal which then does not happen is a
banner nobody reads twice.

**No business logic moved, and no new endpoint exists.** Every value in
steps 1, 2 and the acceptance panel already came back from
`sp_risk_register_get` or `sp_risk_treatment_state`; this is presentation
of two reads the screen was already entitled to make.
`POST /register/{riskId}/residual`, its two GETs, the validations, the
derived-rating preview, the pre-fill, the `treatmentOptionCode`
re-dispatch and the save-then-accept ordering are exactly as they were.

**One field the page cannot show yet.** *Treatment description* lives on
the Task Center task (`sp_risk_treatment_task_ensure`'s
`@task_description`) and `sp_risk_treatment_state` does not return it —
the section shows each task's title, owner, target date and status
instead. Surfacing the description means adding a column to that
procedure's `#tt` select in a new migration, which is a treatment-side
change and deliberately not made here.

**Five inputs were added, not removed.** `sp_risk_register_assess` has
accepted `riskDescription`, `riskCause`, `existingControls`, `processName`
and `analystRemarks` since 216, but the modal had room to ask for only
`potentialConsequence` — so the other five were written NULL on every
re-assessment. The page asks for all six and pre-fills them from the
register, so a re-save preserves what is there instead of blanking it.

### `pm-form-grid-full` was never a real class

This partial used `.pm-form-grid-full` 40+ times to mean "span both
columns", and so do `exception-centre`, `exception-analysis`,
`gap-detail` and `document-uploads`. It is **not defined** in
`practice-management.css` or anywhere else — the real class is `.full`
(`.pm-form-grid label.full { grid-column: 1 / -1; }`).

Every field marked full-width in those screens has therefore been
rendering at **half** width, which is a large part of why the forms felt
cramped; the long textareas were worst affected. A scoped alias
(`.pm-form-grid > .pm-form-grid-full { grid-column: 1 / -1; }`) fixes all
occurrences in this partial with no markup churn. It is deliberately
**scoped to this partial** — the other four screens have the same latent
bug, but reflowing screens this task did not cover should be a decision,
not a side effect. The new page uses the correct `.full`.

The scope panel is **one component mounted in four places** (analysis,
residual analysis, review, and the row menu's *Practices & assets*, which
is an alias of the analysis page rather than a fifth surface — it takes
`showHeading: false` there because the page's own panel supplies the
heading). It follows
the `__gracRelatedTasks` pattern already in the file — empty host div,
`mount()`, `clear()` — because four copies of a panel with add/remove
semantics is four places for the removal rules to drift.

It does **not** decide the badge on an asset: `sp_risk_mapping_get`
returns `SourceLabel` already resolved into `Primary` / `Additional` /
`Direct` / `DirectAndInherited`. Four values, not three, because an asset
can legitimately be both direct and inherited — and that combination is
exactly the one that survives un-mapping a practice, so collapsing it into
one of the others would hide the case that matters.

Removal affordances mirror the server: the Primary practice's X is
disabled (56532 refuses it anyway), and only a **directly** mapped asset
has an enabled X — offering one on a purely inherited asset would promise
a removal the model will not perform. When a direct mapping is removed
from an asset a practice also reaches, the panel says the asset *stayed*
and why, rather than appearing to ignore the click.

Sub tasks are created through **Task Centre's own** endpoint
(`practice/api/tasks/{id}/children`). The form asks for title, owner,
target date and mandatory-or-not, and **not** priority or SLA — the child
inherits those from its parent (§11), and a field that would be ignored
should not be offered.

The Residual cell has three states, because each calls for a different
action: `awaiting inherent rating` (nothing to be residual to),
`Not assessed` (outstanding work, badged the way 216 badges an unscored
risk), and the rating chip with the likelihood × impact that produced it.
It is painted by the **same** `severityChip` as the Inherent column — two
columns meant to be read with one eye are painted by one function — and
its likelihood/impact selects are filled from the **same**
`/scoring-options` payload and previewed by the **same** `renderRating`
resolver as the inherent form.

Both analysis forms — the candidate one and the custom one — are driven
by **one** `/scoring-options` payload and **one** rating resolver. If they
ever disagree it will be because someone gave them separate data, so they
never get separate data. The rating preview mirrors
`sp_risk_rating_resolve`; the server recomputes it on save, so a stale
client cannot persist a wrong rating.

"Register as risk" is disabled until `currentAnalysisId` is present. That
is an affordance, not the rule — the rule is error 56133 in SQL.

The candidate detail modal shows the full §20 analysis version table, and
the register detail modal renders the §10 chain
`R-n → Analysis vN → Candidate → Source` (`RSK-n` before 378) with a live link back to the
Gap Centre where the source is a gap. Other Centres show the reference
until they expose a deep link.

---

## "No risks in the register match these filters" — when there *are* risks

Reported after the Centre-merge work, and worth writing down because the
message was the problem, not the data.

### The message was lying

`risk-centre.js`'s `apiGet` returns `null` for **every** non-OK response,
and `refreshRegister` rendered `data?.rows || []` — so a 500 from
`/register` and an genuinely empty register produced the *same* sentence.
Anyone reading it goes looking for missing rows instead of a broken
endpoint.

Fixed with `apiGetChecked`, which keeps the distinction. A failed read now
says **"Could not load the register: &lt;reason&gt;"**. `apiGet` itself is
untouched, so its other call sites behave as before. The Candidates grid
had the identical flaw and got the same treatment.

**Whatever the underlying cause, it is now visible on screen.**

### Two real faults found underneath it

**1. The register row map assumed migration 216 had been applied.**
`ListRegisterAsync` read `AnalysisPending`, `ThreatName`,
`VulnerabilityName` and `BusinessFunctionName` unguarded. Those four
columns are only projected by 216's `sp_risk_register_list`; against
206's version the reads throw `IndexOutOfRangeException`, the endpoint
500s, and — per above — the screen calls it an empty register. Now read
through `HasColumn`, the same defensive pattern `ResolveWorkspaceService`
and `GapLifecycleService` already use. `RiskAnalysisId` is guarded against
`DBNull` for the same reason: NOT NULL by schema, but a violation should
cost one row, not the whole list.

**2. The "Analysis pending" filter never did anything.**
The toolbar has sent `analysisPending` since 216 and
`sp_risk_register_list` has always declared `@analysis_pending`, but
neither `RiskCentreController.ListRegister` nor `ListRegisterAsync`
carried it — the value was dropped between the query string and the
procedure. Now threaded through.

Two details on that wiring:

- The controller binds it as **`string?`, not `bool?`**. The screen sends
  `"1"` / `"0"`, and .NET's bool binder accepts only `"true"` / `"false"`
  — declaring `bool?` would make every filtered request an automatic 400
  under `[ApiController]`, i.e. it would have *recreated* the reported
  symptom. Unrecognised values mean "no opinion" rather than an error.
- The parameter is sent only when the procedure declares it, via
  `ProcParameterProbe`, so a database still on 206 gets a filter that
  does nothing instead of *"has too many arguments specified"*.

### ProcParameterProbe

`TaskService` had carried a private `ProcHasParameterAsync` since Task
Centre v2. Rather than copy it into `RiskCentreService`, it moved to
`Api/Infrastructure/ProcParameterProbe.cs`; `TaskService` keeps a
one-line wrapper so its call sites read unchanged. One rule, one
implementation.

It buys an ordered rollout without a hard outage — it does **not**
substitute for running the migration.

### The actual cause: the Register tab had no organisation control

Once the error path was honest, the screen kept showing the *filter*
message — meaning HTTP 200 with zero rows. The query is only:

```sql
WHERE r.organization_id = @organization_id
  AND (@status_code IS NULL OR r.status_code = @status_code)
```

so only two inputs can empty it. And one of them was **unreachable**.

`riskFilterOrganization` lived in the Candidates toolbar, inside
`#riskListView` — which `showTab()` hides whenever you move to Register or
Dashboard. On those two tabs the picker was not merely awkward to reach,
it **was not on the page**. `init()` auto-selects `selectedIndex = 1`
(the first allowed organisation) without announcing it, so a register
holding rows for any other organisation reads as "No risks in the
register match these filters", with no control on screen to correct it
and nothing saying which organisation was being shown.

**First attempt — a bar above the tabs — was wrong.** It made the control
reachable, but took it out of the filter row, which is where operators
look for it: the Register then read as a filter row containing only an
organisation, with its own Status / Source / Category / Rating / pending /
search controls apparently gone. Reachability was not the whole
requirement; *being where the other filters are* was.

**What shipped:** every tab toolbar carries its own organisation control,
all marked `.risk-org-filter` — `riskFilterOrganization`,
`regFilterOrganization`, `dashFilterOrganization`. Distinct ids because
duplicate ids are invalid HTML; the **class** is what the JS binds to.

They are three views of one value:

- `populateOrgFilter()` fills all of them from a single fetch, so they can
  never offer different lists.
- One change handler on the class sets `state.organizationId`, calls
  `syncOrgSelects()` to push the value onto the others, then
  `onOrganizationChanged()` — which already refreshed whichever tab was
  open.
- `init()` also calls `syncOrgSelects()` after its auto-select, so a tab
  the operator has not opened yet still shows the organisation being
  displayed instead of an unset "Select organization".

The empty-state message now names the filters actually in force
("No risks in the register for organization Acme · status Active") rather
than the useless "these filters", and points at the two that are set
without the operator choosing them: Status is pre-selected to `Active` in
the markup, and Organization is auto-selected at load.

**Still open for a decision:** whether the Register's Status filter should
keep defaulting to `Active`. Anything moved to `UnderTreatment`,
`Monitoring`, `Accepted`, `Closed` or `Retired` is invisible on first
paint. Defaulting to "All statuses" would show everything and let the
operator narrow — but that is a product call, so the default is unchanged
and the message now explains itself instead.

`database/deployment/15_UAT_Diagnostics_RiskRegister.sql` reports rows by
organisation × status, reproduces the screen's exact default query, and
checks whether 216 is applied.

## Risk Category becomes multi-select (migrations 375, 376)

**Request.** The Risk Analysis form's Risk Category field allowed only
one category per risk. A risk that is genuinely both Operational and
Compliance had to be forced into one. Change it to a multi-select,
following the existing GRAC many-to-many pattern rather than a
comma-separated string, and show every assigned category — comma
separated — on the Risk List/Grid.

**Numbering note.** These were originally written as 373/374. Before
they shipped, `373_risk_centre_menu_becomes_risk_management_root.sql`
appeared in `database/` from unrelated, concurrent work on this same
checkout — a menu restructuring migration, nothing to do with Risk
Category. Renumbered to 375/376 (the next genuinely free pair) rather
than overwrite or renumber someone else's migration; every internal
cross-reference (verification-block labels, header comments, the
`backfill-` marker string) was updated to match.

### The pattern, and why it is the Risk Type one, not Threat/Vulnerability's

Two existing multi-select precedents were already on this exact form:
Threat/Vulnerability (285, 286) and Risk Type (313, 314). Risk Category
follows Risk Type's shape — a dedicated `sp_risk_category_selection_set`
/ `_get` pair, called as a **second, independent API call** right after
`/assess` succeeds, never touching `sp_risk_register_assess` itself (the
"no wrapper" rule both precedents already establish) — because Risk
Category, like Risk Type, is converting a field that already has one
value into a set, not adding a brand-new one.

Two link tables, at the two grains every risk-level many-to-many here
already uses (285, 313/314):

- `risk_analysis_risk_category` — the versioned audit record (BRD §20),
  keyed `(risk_analysis_id, risk_category_id)`.
- `risk_register_risk_category` — the current/authoritative answer the
  grid and detail pages read without joining to the newest analysis
  version, keyed `(risk_register_id, risk_category_id)`.

**Unlike Risk Type, this field had existing data to carry forward.**
Risk Type was a blank slate; `risk_register.risk_category_code` /
`risk_analysis.risk_category_code` were not. 375 backfills both link
tables from the existing scalar columns, matched on
`(organization_id, category_code)` — `risk_category_master.category_code`
is unique per organisation, not globally — so a risk analysed before
this ships opens with its existing category already ticked, not blank.
`NOT EXISTS`-gated, so re-running the file never overwrites a selection
an analyst has since changed, and an org that has since renamed or
retired a category code simply leaves that one historical row
unbackfilled (there is nothing left in the master to point it at).

The legacy scalar columns (`risk_category_code` / `risk_category_name`
on both tables) are **not removed and not stopped being written** —
`sp_risk_register_assess` still sets them from the client's
`riskCategoryCode`, unchanged. The UI sends the **first** ticked
category's code there, so a database or a screen that has not caught up
to 375/376 still shows something rather than nothing.

### Procedures (376)

| Procedure | What |
| --- | --- |
| `sp_risk_category_selection_set` | Replaces the full set for an analysis id and/or a register id in one call (both link tables written together, same as Risk Type). `@risk_category_ids` is a CSV of `risk_category_master.risk_category_id`, validated against `@organization_id` and `status = 'Active'` — silently dropping any id that fails validation, exactly like 314. |
| `sp_risk_category_selection_get` | The current set for a register id — the register link table, falling back to the newest analysis version if the register link is empty. |
| `sp_risk_scoring_options_get` | RE-ISSUED (206) — the `Categories` result set gains `RiskCategoryId` alongside `CategoryCode`/`CategoryName`. Every existing reader is unaffected. |
| `sp_risk_register_list` | RE-ISSUED (265) — gains `RiskCategoryNames`, a `STRING_AGG` of every category currently mapped to the risk, ordered by `display_order, category_name`. Same pattern as the existing `MappedPracticeCount`/`MappedDependencyCount` correlated subqueries in the same proc. |
| `sp_risk_register_get` | RE-ISSUED (265) — same additive `RiskCategoryNames` column, for the Risk View detail page. |

**Error range:** 56755–56759 (56750–56754 and 56760–56799 were free;
56755–56759 keeps this migration's codes together). 56755 organisation
required, 56756 analysis-or-register id required, 56757 at least one
category required (the real guarantee behind the UI's own "select at
least one" check), 56758 register id required on the get proc.

**Required, not optional — same reasoning as Risk Type's 56731.**
`risk_category_code` has always been required by `sp_risk_register_assess`
(216); this is not a new constraint introduced on save, only the same
one now enforced on the full set as well.

### API (`RiskCentreController`)

| Verb | Route | Notes |
| --- | --- | --- |
| GET | `/register/{riskId}/risk-categories` | Current set — register link table, falling back to the newest analysis version. No list-all-categories endpoint: the options ride on `/scoring-options`'s `Categories`, which now carries `RiskCategoryId`. |
| POST | `/register/{riskId}/risk-categories` | Body `{ organizationId, riskCategoryIds, riskAnalysisId?, callerDisplayName? }`. Called right after `/register/{riskId}/assess` succeeds, carrying the `riskAnalysisId` that call just returned, so one save-sequence writes both link tables in step with the version `/assess` just inserted. |

`/register` (list) and `/register/{riskId}` (detail) both gain
`riskCategoryNames` on every row, for free — no extra round trip, unlike
Threat/Vulnerability's `threatSelectionText()` pattern, because the
`STRING_AGG` join was cheap enough to add directly to the two procedures
almost everything on this screen already calls through.

### UI: `pm-checkcombo`, not Risk Type's card grid — and why

Risk Type's multi-select (313, 314) renders as `.risk-treat-options`
checkbox cards — a good fit for a fixed 3-value set (Confidentiality /
Integrity / Availability) with nowhere else to go on the page but a
full-width band. Risk Category is different in a way that changes the
right widget:

- **It is organisation-defined and open-ended**, not a fixed triad. A
  card grid that reads fine at 3 options gets unwieldy at 10+, and has
  no search.
- **Its existing seat on the form is inside `raCategory`'s original
  4-column score row** (`.ra-grid-score` — Category, Likelihood, Impact,
  the resolved rating, deliberately laid out on one line per that row's
  own header comment). Dropping in a full-width card band, the way Risk
  Type's own field sits, would have broken that row's documented
  4-column intent.

`pm-checkcombo` — the same searchable multi-select combo already used
elsewhere on this exact page (the Impacted Assets / dependency object
pickers, 285) and on other screens entirely (Organization Setup
Attributes, event-profiles) — fits both constraints: it is a single
control that occupies one grid cell like the `<select>` it replaces, and
its built-in search scales to however many categories an organisation
defines.

Its markup is `<div class="pm-checkcombo risk-category-host" id="raCategoryCombo" data-checkcombo>`,
built fresh by `renderCategoryOptions()` in `risk-centre.js` (checked
state baked into the markup on every render, never toggled after the
fact — the same convention the dependency-object combo already uses).
The widget's delegated click/change/search wiring lives in
`comboInHost()`, previously scoped only to `.risk-map-host`; it now also
recognises `.risk-category-host`, and the outside-click menu-close
handler was widened the same way.

**One CSS fix was needed for the reused widget.** `.pm-checkcombo-trigger`
defaults to `min-height: 40px`, built for the multi-row dependency
pickers. `.ra-grid-score`'s three sibling controls (the two `<select>`s
and the rating chip) are all pinned to 34px, with that exact alignment
already called out in the existing CSS comment for the rating chip. A
scoped override (`.risk-page .ra-grid-score .pm-checkcombo-trigger`)
trims the combo trigger to match, the same way the rating chip was
trimmed.

### What was deliberately left unchanged

- **`sp_risk_register_assess` itself** — untouched, per the "no wrapper"
  rule.
- **Review Risk (`rvCategory`)** — Risk Type never reached this
  screen either (its own header comment: "the only screen this was asked
  for"), and the request was scoped to the Risk Analysis form. `rvCategory`
  stays a plain single `<select>`, and `onReviewSubmit` is untouched.
- **`regFilterCategory`** (the Register grid's category filter) — stays a
  single-select against the legacy scalar column, which is still written.
  The request did not ask for the filter to change, and the scalar column
  still answers it meaningfully (the first-ticked category).
- **Category-name display sites NOT sourced from `/register` or
  `/register/{id}`** — `refreshReviewDue` (`/review-due`, a different
  query), the candidate-stage analysis meta in `openApprovalModal`
  (`/{id}/analysis`, a different record), and `refreshApprovalQueue`
  (`/approval-queue`, a different record). None of these procedures
  gained `RiskCategoryNames`, so their display sites still read the
  legacy scalar `riskCategoryName` — correctly, not by oversight.

## Risk Candidate ID / Risk ID reformat (migration 378)

**Request.** `candidate_number` (`RC-<org>-<id>`, e.g. `RC-1-47`) and
`risk_number` (`RSK-<org>-<id>`, e.g. `RSK-1-12`) read as internal
identifiers, not the board-pack-ready reference sir asked for. New
format: `RC-001` for a Risk Candidate, `R-001` for a Risk (Risk
Register) -- a 3-digit, zero-padded, per-organisation sequential
number, restarting at `001` in every organisation, generated by the
backend rather than assembled on screen.

**Why a schema change, not a formatting tweak.** Both columns were
`PERSISTED COMPUTED` (205) -- `CONCAT('RC-', organization_id, '-',
risk_candidate_id)` and the `RSK-` equivalent. A `PERSISTED COMPUTED`
column's expression cannot contain an aggregate or a subquery, so it
cannot count "how many candidates has this organisation already had" --
there is no way to express a per-organisation sequential number as a
computed column. 378 converts both to regular `NVARCHAR(20) NOT NULL`
columns, generated explicitly at INSERT time.

**Where it is generated, traced before writing anything.** Both
columns are written in exactly one procedure each (confirmed by
grepping every migration for `INSERT INTO ... risk_candidate` /
`risk_register`, base tables only): `sp_risk_candidate_create` (207)
and `sp_risk_register_insert` (354). `sp_risk_candidate_register` and
`sp_risk_custom_create` (both 216) do not insert into `risk_register`
themselves -- they already delegate to `sp_risk_register_insert` via
`EXEC ... @risk_register_id = @new_risk_id OUTPUT` -- so registering a
candidate and creating a custom risk both pick up the new numbering
through that one procedure, with no separate change needed for either
route.

**Generation follows the codebase's own precedent for exactly this
shape** -- `practice_instance.instance_code` / `PR_nnn`
(139, 145) -- rather than inventing a new one: read the current max
under `UPDLOCK, HOLDLOCK` so two concurrent inserts for the same
organisation cannot read the same "next" number, `FORMAT(@next, '000')`
so the number overflows naturally past 999 (`RC-1000`) instead of
truncating, and a collision-guard `WHILE EXISTS` loop as a second line
of defence. `UNIQUE(organization_id, candidate_number)` /
`UNIQUE(organization_id, risk_number)` are added as the same
defense-in-depth `uq_pm_practice_instance` already provides for
`PR_nnn` codes -- belt-and-braces alongside the locked read, not a
replacement for it.

**Backfill.** Existing rows are renumbered per organisation, ordered by
each row's own identity column ascending -- an organisation's `RC-001`
is its oldest candidate and `R-001` its oldest risk, exactly as if the
new scheme had been in place from the start.

**No C# or JS change.** Every consumer of `CandidateNumber`/
`RiskNumber` in `RiskCentreModels.cs`, `RiskCentreService.cs` and
`risk-centre.js` only ever reads them as an opaque display string --
nothing parses, splits, regexes or reconstructs the old
`RC-<org>-<id>` / `RSK-<org>-<id>` shape anywhere in the API or the UI,
and neither field carries a `[StringLength]`/`[RegularExpression]`
attribute tied to the old shape. So the schema and procedure change is
the entire fix -- the shorter new format (`RC-001` vs. `RC-1-47`)
flows through every existing read path unchanged.

### What did NOT change

- `risk_candidate_id` / `risk_register_id` -- the real `IDENTITY`
  primary keys. Every FK, join and internal reference is unaffected;
  only the human-facing display code's shape changed.
- `task_candidate.candidate_number` (197/198) -- a different table,
  Task Centre's, that only happens to share the naming convention
  (205's own comment: "Mirrors task_candidate.candidate_number so
  every Centre's records read alike on screen"). Sir named Risk
  Candidate and Risk Register specifically.
- Any Risk Management workflow, status, approval, analysis, treatment,
  acceptance, dashboard, notification or bulk-action logic --
  `sp_risk_candidate_create` and `sp_risk_register_insert` are
  otherwise reproduced verbatim from 207 and 354; every existing
  parameter, `THROW`, validation and the `_history` rows are
  byte-for-byte unchanged.

## Risk list column order and set (change request, 2026-09-23)

**Request.** The Risk Register grid ("the Risk list") should show
exactly these columns, in this order: Risk ID, Risk, Owner, Stage,
Inherent Risk Score, Residual Risk Score, Next Review Date. Confirmed
with sir: Category and Source (the grid's previous 3rd and 4th
columns) are removed from this grid, not merely reordered.

**Scope: display only.** Nothing about the grid's data changed --
`sp_risk_register_list` (265) is untouched, `/register`'s response
still carries `riskCategoryNames`/`riskCategoryName` and
`sourceTypeCode`/`sourceReference` exactly as before, so no API or
database change was needed. `regFilterCategory` and `regFilterSource`
(the filter dropdowns above the grid) are untouched and still filter
by those fields; the dashboard's category/source drill-down (which
sets those same filters) is untouched too -- only the grid's own
`<thead>`/row markup lost the two columns and gained the new order.

**Where.** `risk-centre.cshtml`'s `#regTable` `<thead>` and
`risk-centre.js`'s `refreshRegister()` row template (the `rows.forEach`
block) -- the two must always match, same as every other register-grid
edit this document tracks (264's Stage column, the earlier Treatment/
Scope/Status/Registered removal). `REG_COLS` dropped from 10 to 8 (7
data columns + Actions), and its four `colspan` call sites picked up
the new value automatically since they all read the one constant; the
`<tbody>`'s own placeholder `colspan` in the markup was updated to
match by hand, the same as it always has been.

**What did NOT change:** the Accept (`#accTable`) and Review
(`#revTable`) bulk-action grids -- both already show Risk ID, Risk,
Owner, Inherent, Residual, Next review among their own columns, but
they are separate tables with their own `<thead>`/row templates, and
sir's request named "the Risk list" (the register grid) specifically;
the risk detail view, which still shows Category and Source; and
`sp_risk_register_list`, the API contract, and every filter.
