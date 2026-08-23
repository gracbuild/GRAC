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

Rollbacks exist for all eight, in reverse order:
`215 → 214 → 213 → 212 → 207 → 206 → 205 → 204`.

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
`duplicate_of_risk_id`, `registered_risk_id`, and a computed
`candidate_number` (`RC-<org>-<id>`).

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
- `risk_number` computed: `RSK-<org>-<id>`.
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

The ones worth recognising on sight:

| Code | Means |
| --- | --- |
| 56133 | No analysis exists — BRD §24 rule 1 refused the registration. |
| 56115–56120 | The analysis exists but is incomplete; the message names the missing field. |
| 56270 | Approval is required and has not been given; the message explains *why* it was required. |
| 56280 | Legacy Accept is disabled for this organisation — use Register. |

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
| §9.1 | Residual risk / treatment effectiveness | Not in the BRD's minimum field list; inherent rating only. |
| §23 | Charting library | The dashboard renders proportional bars from divs, deliberately: it must paint with no charting dependency. |
| §19 | Bulk approve | The queue is sorted by rating score then age; approval is one at a time. |

---

## UI

`Views/Practice/Partials/risk-centre.cshtml` + `wwwroot/js/RiskCentre/risk-centre.js`,
one menu entry (`risk-centre`, seeded by 171 — unchanged), two tabs:

- **Risk Candidates** — grid with source, rating, analyst, status;
  row menu: View details · Analyse · Register as risk · Return for
  clarification · Reject · Close as duplicate · Withdraw · Accept (legacy).
- **Risk Register** — grid with §23 filters; row menu: View risk · Change
  status · Change owner; and the **Create custom risk** button (Route B
  lives here, not on the Candidates tab, because §4B says a custom risk
  has no candidate).

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
`RSK-n → Analysis vN → Candidate → Source` with a live link back to the
Gap Centre where the source is a gap. Other Centres show the reference
until they expose a deep link.
