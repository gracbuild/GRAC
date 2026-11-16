# Third-Party Management -- lifecycle redesign (target design and phase plan)

Sources:

* "GRAC Third-Party Management Lifecycle Redesign -- Functional &
  Technical Change Document v1.4" (2026-11-07). Phase 1 was built from
  it (migration 521, section 15.1).
* **"Change Document -- GRAC Third-Party Management (TPM) Redesign"
  (CR 2, 2026-11-08).** CR 2 replaces the v1.4 target from the
  qualification stage onwards. Where the two differ, CR 2 wins. This
  document is the CR 2 design. "CR 2 x.y" below refers to a section of
  that change document.

Status: **for review.** Round A (sections 4-5 of CR 2) is built in
migration 522 (section 15.2); Round B (sections 6-7) in migration 523
(section 15.3); Round C (section 8) in migration 524 (section 15.4); Phase D (dashboard, encrypted links, Defer task, profile review) in 525 (section 15.5).

Decisions taken with the product owner:

| # | Date | Question | Answer |
|---|---|---|---|
| Q1 | 2026-11-07 | What happens to the TPRM module already built (486-490, 507)? | **Restructure it.** Pieces that already fit (configuration layers, versioned templates, questionnaires, evidence linking, audit, the dashboard frame) are kept. |
| Q2 | 2026-11-07 | What was delivered in the first round? | The v1.4 design plus Phase 1 (521). |
| Q3 | 2026-11-07 | Is there TPRM data in UAT that must be kept? | No, test data only. Tables may be reshaped, with no data migration. |
| Q4 | 2026-11-07 | What happens to the vendor function under Settings -> Dependencies? | It stays untouched (CR 2 10-18 confirms it is out of scope). Section 17 is the data-disposition plan. |
| Q5 | 2026-11-08 | What does the CR 2 round deliver? | **This design, plus Round A**: lightweight registration with automatic activation, progressive vendor information, the engagement initial form and progressive exposure capture (CR 2 sections 4 and 5). Screening, the applicability decision, admission and the TP Risk Register follow in Rounds B and C. |
| Q6 | 2026-11-08 | Which menus does the module show? | **Only the three CR 2 menus**: Vendor Registry, Engagement Management, TP Risk Register (CR 2 section 3). The dashboard and Reviews & Monitoring stay reachable but leave the sidebar; Configuration moves to Settings. |
| Q7 | 2026-11-08 | Which approval does formal admission follow? | **The TPRM approval rules** (`tprm_approval_rule`, 486) with their delegations and segregation of duties (Round B). |
| Q10 | 2026-11-09 | Next phase after Round C? | **All four**: TPRM dashboard rework to the CR 2 views; every remaining TPRM link carries record ids encrypted; a Defer decision creates a Task Board task (open point 3a); a periodic review cycle for the vendor profile (open point 7). Built in 525 (section 15.5). |
| Q9 | 2026-11-08 | Round C: how is the vendor-level profile assessed, and how is the overall vendor risk status calculated? | **A rating per area** on the bands of the risk model in force, with rationale, evidence, assessor and date, versioned; **highest wins**: the highest of those ratings and the admitted engagements' bands, showing what set it. Built in 524. |
| Q8 | 2026-11-08 | Next phase? | **Round B** (screening, applicability decision, admission) -- built in 523 with the defaults of open points 1-3 (section 18). |

## Contents

1. Principles
2. Where the module stands against CR 2
3. Menu structure
4. Vendor Registry -- progressive vendor onboarding (Round A)
5. Engagement Management -- engagement scoping (Round A)
6. Initial Exposure Screening (Round B)
7. Client TPRM applicability decision and admission (Round B)
8. TP Risk Register -- vendor-level record (Round C -- built in 524)
9. End-to-end lifecycle and state models
10. Logical entities -> physical objects
11. Authorization and segregation of duties
12. API surface
13. Phase plan
14. Acceptance scenarios (CR 2 section 11)
15. As built (521, 522)
16. What happens to each current TPRM object
17. Legacy vendor (Settings -> Dependencies): data-disposition plan
18. Open points for review

---

## 1. Principles

CR 2 section 2, and how the design keeps each one:

| CR 2 principle | Where the design keeps it |
|---|---|
| Registration is lightweight and needs no TPRM approval | Eight fields; no approval step; the vendor is Active on save (section 4) |
| Activation does not imply TPRM applicability or admission | Vendor status and TP Risk Register membership are separate records; nothing in the vendor lifecycle reads or writes the register (sections 4, 8) |
| Information is captured progressively | Vendor: extra identity data on the Edit vendor page, never at registration. Engagement: the initial form, then Scope & Exposure with gating questions (section 5) |
| Each engagement is screened independently | One screening report series per engagement (section 6) |
| GRAC correlates proposed exposure with what it already holds | Discovery from the engagement's applications, processes and business functions; kept apart from the proposed exposure (section 6.3) |
| GRAC identifies potential cases, the client decides | The screening classification is informational; the decision is a separate record by a person with the permission (sections 6.5, 7) |
| The client explicitly decides; admission follows the configured workflow | Include / Exclude / Defer with rationale; Include starts the TPRM approval rules (section 7) |
| One active vendor-level register record per vendor; engagements link to it | Filtered unique index on the register; admission links, never duplicates (section 8) |
| History stays traceable | Versioned screening reports, decisions kept after revision, audit trail on every step (sections 6-8) |

Unchanged house rules: procedures own every rule (`grac_practice`
schema). The API binds parameters and shapes results. The Web tier checks
the session, the organization and the menu grant, then proxies. Every
change writes an audit row. Nothing in TPM reads or writes the legacy
vendor objects (CR 2 10-18).

## 2. Where the module stands against CR 2

| CR 2 capability | After 521 | Gap | Round |
|---|---|---|---|
| 4.1-4.2 lightweight registration, immediate activation | Full identity form; vendor starts as DRAFT and is activated by hand | Eight-field registration page; vendor Active on save; DRAFT state retired | **A** |
| 4.3 progressive vendor information | All fields on one form | Separate Edit vendor page holding the progressive fields; none mandatory | **A** |
| 4.2-1 duplicate detection before registration | Configurable attributes, reviewed matches (521) | Kept | -- |
| 5.1 initial engagement form | One large form; criticality mandatory | Eleven-field initial form, CR 2 mandatory set; service category defaulted from the vendor | **A** |
| 5.2-5.3 progressive exposure capture | Exposure fields on the same form, scope items added one by one | Scope & Exposure page: gating questions open only the dimensions that apply; one save | **A** |
| 6 Initial Exposure Screening | Discovery exists (manual, from applications) | Automatic, versioned screening report with classification and observations | **B** (523) |
| 7 Client applicability decision, admission approval | None | Include / Exclude / Defer; admission through the TPRM approval rules | **B** (523) |
| 8 TP Risk Register | None (risk is per engagement) | Vendor-level register record, linked engagements, consolidated profile, impact review, exit | C |
| 3 menus | Dashboard, Vendor Registry, Engagements, Reviews & Monitoring, Configuration | Vendor Registry, Engagement Management, TP Risk Register (C); Configuration under Settings | **A** (C adds the register) |

The v1.4 design moved inherent risk, due diligence and the decision from
the engagement to a consolidated record. **CR 2 8.3 keeps them on the
engagement**: each admitted engagement keeps its own inherent assessment,
due diligence, safeguards, residual risk and findings. The vendor-level
record consolidates (section 8). So the engagement risk workflow of
488 / 489 stays where it is, behind the applicability decision.

## 3. Menu structure

Root `nav-tprm` "Third-Party Management". Menu keys do not change, so
grants and drill links keep working.

| CR 2 menu | Key | Sidebar | Screen |
|---|---|---|---|
| 3.1 Vendor Registry | `tprm-third-parties` | Yes | Registry, Register vendor page, Edit vendor page, profile, engagements, status and duplicate history |
| 3.2 Engagement Management | `tprm-engagements` | Yes (renamed from "Engagements") | Register, New engagement page, Scope & Exposure page, workspace with the Screening & decision tab (523) |
| 3.3 TP Risk Register | `tprm-risk-register` | Yes (524) | Admitted vendors, consolidated profile, linked engagements, history |
| -- | `tprm-dashboard` | No (`show_in_sidebar = 0`) | Still on Home (management dashboard card) |
| -- | `tprm-reviews` | No (`show_in_sidebar = 0`) | Still opened from an engagement and from the dashboard |
| -- | `tprm-configuration` | Moves to **Settings** as "Third-Party Settings" (beside Risk Settings) | Lists, library, templates, rules, custom fields |

`show_in_sidebar = 0` (migration 390) removes a row from navigation only;
the screen, its grants and its links stay. Every screen keeps the
existing layout: compact page heading, organization picker, `pm-panel` +
`pm-toolbar`, `pm-table-wrap` grid with the `pm-grid` pager, and the
shared `_tprm-form-dialog` form engine for both dialogs and full pages.

## 4. Vendor Registry -- progressive vendor onboarding (Round A)

### 4.1 Registration (CR 2 4.1, 4.2)

The **Register vendor** page has exactly the CR 2 fields:

| Field | Mandatory | Stored in |
|---|---|---|
| Legal name | Yes | `tprm_third_party.legal_name` |
| Trading name | No | `trading_name` |
| Primary service category | Yes | `primary_service_category_code` |
| Relationship owner | Yes | `relationship_owner_employee_id` |
| Country | Yes | `country` |
| Primary contact name | Yes | `tprm_third_party_contact` (`is_primary = 1`) |
| Contact email | Yes | the primary contact's `email` |
| Contact phone | No | the primary contact's `phone` |

On **Register** (`sp_tprm_third_party_save`, re-issued by 522):

1. Duplicate detection runs on the configured attributes (521,
   `VENDOR_MATCH_ATTRIBUTE`). Matches are listed and nothing is saved
   until each has a "different vendor" rationale; a real duplicate is
   not registered.
2. With no unreviewed match, the vendor is registered **and activated in
   the same transaction**: status = the organization's ACTIVE value,
   `first_activated_dt` = now.
3. No approval workflow starts.
4. The vendor is offered at once for a new engagement.
5. Status history: one row "registered and activated" (none -> Active).
   Audit trail: two rows, `CREATE` and `ACTIVATE`.

Activation means "available for engagement management". It never means
assessed, approved or admitted (the page says so).

### 4.2 Progressive vendor information (CR 2 4.3)

The **Edit vendor** page (from the vendor's profile) holds the
registration fields plus everything else, none of it mandatory:
registration number, Tax ID, LEI, vendor type, reporting and other
service categories, full address, state / region, city, website, parent
company, year established, employee and revenue bands, certifications,
notes, all contacts (one row each: name, role, email, phone, primary)
and the organization's custom fields. The registration mandatory set
still applies on every save, so a vendor never loses it.

CR 2 4.3 says these fields "may become mandatory when required by a
configured due-diligence questionnaire, risk assessment or client
policy". The existing mechanism for client policy is the custom field
with `is_mandatory` (486). Questionnaire-driven requirements are part of
due diligence (unchanged, 489).

### 4.3 Vendor states

`TP_STATUS` meanings after 522: **ACTIVE, INACTIVE, SUSPENDED,
ARCHIVED** (DRAFT is retired; DRAFT vendors become ACTIVE).

```
  register ---> ACTIVE <---- reinstate ---- SUSPENDED
                 |   ^ \---- suspend ----------^   |
      inactivate |   | reactivate                  | inactivate
                 v   |                             v
               INACTIVE <--------------------------+
                 |   ^
         archive |   | restore
                 v   |
               ARCHIVED
```

| Action | From -> To | Gate (`fn_tprm_vendor_transitions`) | Permission |
|---|---|---|---|
| SUSPEND | ACTIVE -> SUSPENDED | Reason | Vendor Registry APPROVE |
| REINSTATE | SUSPENDED -> ACTIVE | Reason | APPROVE |
| INACTIVATE | ACTIVE / SUSPENDED -> INACTIVE | No open engagement | APPROVE |
| REACTIVATE | INACTIVE -> ACTIVE | Registration fields complete | APPROVE |
| ARCHIVE | INACTIVE -> ARCHIVED | No open engagement | APPROVE |
| RESTORE | ARCHIVED -> INACTIVE | -- | APPROVE |

Every transition keeps a mandatory reason and an optional evidence
reference (521). **Mark as duplicate** (521) is allowed from any
non-archived state when the vendor has no open engagement; the vendor is
archived with `duplicate_of_third_party_id`, nothing is merged. A new
engagement needs an **ACTIVE** vendor.

## 5. Engagement Management -- engagement scoping (Round A)

### 5.1 Initial engagement (CR 2 5.1)

The **New engagement** page:

| Field | Mandatory | Column |
|---|---|---|
| Vendor | Yes (Active vendors) | `third_party_id` |
| Engagement name | Yes | `engagement_title` |
| Service category | Yes -- defaults from the vendor's primary category, editable | `service_category_code` |
| Service description | Yes | `service_description` |
| Business purpose | Yes | `business_purpose` |
| Service recipient | Yes | `service_recipient` |
| Engagement type | Yes | `engagement_type_code` |
| Service model | Yes | `service_model_code` |
| Delivery location | Yes | `delivery_locations` |
| Proposed start date | Yes | `proposed_start_dt` |
| Proposed end date | No | `proposed_end_dt` |
| Relationship owner | Yes | `relationship_owner_employee_id` |

Service criticality is **no longer asked at creation** (521 required
it); it is part of Business continuity in Scope & Exposure. Editing the
engagement opens the same page with the administrative fields that are
not exposure: scope description, existing relationship, business owner,
due-diligence assessor, actual term, notes, custom fields.

After **Create**, the Scope & Exposure page opens.

### 5.2 Progressive exposure capture (CR 2 5.2, 5.3)

The **Scope & Exposure** page starts with gating questions. Each is
answered Yes / No / Not sure; the details of a dimension are asked only
after a Yes, so a routine supplier answers a few No's and saves.

| Gating question (column) | A Yes asks for (CR 2 5.2 dimension) |
|---|---|
| Will the vendor access or support our applications or systems? (`app_access_answer`) | **Applications and systems** (GRAC applications + others not in GRAC) and **Access privileges** |
| Will the vendor have physical access to our premises? (`premises_access_answer`) | **Access privileges** |
| Will the vendor access, process, store or transmit organization or customer data? (`data_processing_answer`) | **Data exposure**: data categories and processing details (`data_processing_details`) |
| Will the vendor use subcontractors or other third parties for this service? (`subcontracting_answer`) | **Fourth parties**: name, category, country |
| Does the service support an important business process or function? (`important_process_answer`) | **Business processes**: business functions, processes (GRAC + others) |
| Could a disruption of the service affect business operations? (`disruption_impact_answer`) | **Business continuity**: customer impact, substitutability, exit dependencies |
| Are service commitments (SLA, recovery objectives) part of the service? (`service_commitment_answer`) | **Service commitments**: SLA summary, RTO, RPO |
| Is there a contract for this engagement? (`contract_answer`) | **Contractual information**: Asset & Contract record, reference, value, currency, validity (start / end), renewal date, related documents |

Always shown: **Delivery locations** (sites / countries where the service
is delivered or data is processed, as LOCATION scope items) and **Service
criticality**.

Rules (`sp_tprm_engagement_exposure_save`, new in 522):

* **Only applicable fields are kept.** When a question is not Yes, the
  fields and proposed scope items of its dimension are cleared on save
  (the page warns before it). Not sure is recorded as such: it is the
  information gap that screening reports in Round B.
* The proposed scope items are saved **as one set** with the page
  (`@scope_json`): items no longer listed are removed, new ones added,
  unchanged ones keep their criticality and notes. An item whose GRAC
  record was deactivated, or whose list value was retired, stays offered
  (marked as no longer active) and is kept unless it is unticked. A
  location or fourth party is identified by name and country. Proposed items are no
  longer added one at a time (`sp_tprm_scope_item_save` now refuses
  PROPOSED); ACTUAL items (onboarding) work as before.
* **Data exposure** (`data_exposure_code`, read by the risk-model
  prefill and questionnaire applicability) is derived: the highest-rank
  data category when data is in scope, the lowest (rank 0, "No
  organization data") when it is not, empty when not known.
* Access privileges are one dimension opened by either access question
  (applications or premises); its access categories are kept while either
  is Yes.
* `exposure_saved_dt` / `_by` record the save. In Round B this save
  triggers the Initial Exposure Screening (CR 2 6.1).
* On an approved or live engagement a change of criticality, data
  exposure, customer impact or substitutability is a **material
  change** (logged, reassessment flagged), as since 488 / 521; the
  core save keeps the same rule for service model and delivery
  locations. Both share `sp_tprm_engagement_flag_material`.

## 6. Initial Exposure Screening (Round B -- built in 523)

### 6.1 Trigger

Saving Scope & Exposure runs `sp_tprm_screening_run` in the same
request. It is intelligence generation: it never changes the engagement
stage, the vendor status or the register. A report can also be
regenerated on demand ("Refresh screening"); every Scope & Exposure save
regenerates it, so a deferred engagement gets a new report when the
requested information is added (CR 2 7.3). An engagement not yet
screened becomes SCREENED (awaiting decision); any other applicability
status is left as it is.

### 6.2 Report and observations

`tprm_screening_report` (one row per run, `version_no` per engagement,
never updated): classification, trigger (EXPOSURE_SAVED / REFRESH /
MIGRATION), counts, generated by / at, and `summary_json` -- engagement
overview, the exposure answers, proposed item counts per kind and
discovered record counts per kind. `tprm_screening_observation` (rows of
a report):

| Column | Content |
|---|---|
| `section_code` | CR 2 6.4 sections 4-9: BUSINESS_OPERATIONAL, DATA_TECHNOLOGY, REGULATORY_OUTSOURCING, FOURTH_PARTY, RELATED_RECORDS, INFORMATION_GAP (section 10, observations and references, is every row with its source) |
| `dimension_code` | CR 2 6.2 input: CRITICALITY, OPERATIONAL_DEPENDENCY, DATA, SYSTEM_ACCESS, PRIVILEGED_ACCESS, REGULATORY, OUTSOURCING, LOCATION, FOURTH_PARTY, CONTINUITY, CONTRACT; discovered kinds ASSURANCE, GAP, RISK, THIRD_PARTY |
| `indicator_code` | the SCREENING_INDICATOR that made the observation HIGH |
| `origin` | **PROPOSED** (declared by the business) or **DISCOVERED** (GRAC correlation) -- CR 2 6.3 keeps them apart |
| `significance` | HIGH / MEDIUM / LOW / INFO |
| `source_kind`, `source_id`, `source_label` | ENGAGEMENT (a field or answer), SCOPE_ITEM, PRACTICE_INSTANCE, OBLIGATION, FINDING, GAP, RISK, ENGAGEMENT_OF_VENDOR |
| `verification_status` | DECLARED / DISCOVERED_UNVALIDATED / VALIDATED |
| `evidence_reference` | supporting reference |
| `observation_text` | the observation |

### 6.3 Discovery correlation (CR 2 6.3)

`sp_tprm_engagement_discover` (re-issued by 523) finds practice
instances through the engagement's applications (resolved Application
dependencies), processes (resolved dependencies whose type reads
`organization_dependency_process` in `dependency_type_source_config`) and
business functions (`practice_instance.business_function_id`), and hands
its records to the screening through `#tprm_discovery` with
`@suppress_result = 1`. The vendor's other engagements are read directly:

| GRAC module | Discovered |
|---|---|
| Practice Management | practice instances depending on the engagement's applications / processes / functions, their criticality and dependencies |
| Risk Management | enterprise risks of those practices (`risk_register`) |
| Gap Register | open gaps of those instances |
| Obligation Management | obligations of those instances and practices |
| Audit Assurance | open assurance findings on those instances |
| Asset Management | the applications and the contract (434) |
| Third-Party Management | the vendor's other engagements, their stages, risk bands, screening classifications and decisions; register membership |

Discovered records stay DISCOVERED_UNVALIDATED until a user validates
them (existing `tprm_engagement_link` validation). They are never added
to the proposed scope by themselves.

### 6.4 Classification (CR 2 6.5)

Rules, evaluated in order; the result and every rule that fired are kept
on the report:

1. **FURTHER_INFORMATION_REQUIRED** -- any gating question unanswered or
   Not sure; or an inconsistency: a Yes with nothing recorded under it
   (data with no category, application access with no application,
   subcontracting with no fourth party, a contract with no reference);
   a No contradicted by discovery (for example no application access,
   but discovery finds the vendor's applications in practice
   dependencies); a proposed end date before the start.
2. **POTENTIAL_TPRM_CASE** -- any indicator of significance HIGH:
   data category rank >= 3 (personal or above), privileged / system /
   hosting access, criticality rank >= 3, an important business process
   with disruption impact, customer impact or substitutability rank at
   the top of its list, a fourth party handling data, a discovered
   critical practice instance or regulatory obligation, an open high
   finding on a discovered instance.
3. **NO_SIGNIFICANT_INDICATORS** -- otherwise.

The thresholds are organization configuration: list
`SCREENING_INDICATOR` (MEANING list; value = indicator, rank = threshold,
hide = switch off -- the observation is still reported at MEDIUM). Baseline:
CRITICALITY 3, DATA 3, ACCESS 3, CUSTOMER_IMPACT 3, SUBSTITUTABILITY 3,
IMPORTANT_PROCESS, FOURTH_PARTY_DATA, DISCOVERED_CRITICAL_INSTANCE
(instance criticality High / Critical / Very High), DISCOVERED_OPEN_FINDING
(open finding whose severity names High or Critical). The classification
is shown as GRAC's view, never as a decision (CR 2 10-9).

## 7. Client TPRM applicability decision and admission (Round B -- built in 523)

### 7.1 Decision (CR 2 7)

`tprm_applicability_decision`: engagement, the screening report it was
made on, decision **INCLUDE / EXCLUDE / DEFER**, rationale (mandatory),
decision-maker (employee), decision date, supporting evidence / references
(text), approval reference, status (CURRENT / SUPERSEDED). A revised
decision supersedes the previous row; nothing is deleted (CR 2 10-16).
The decision is recorded on the CURRENT report; the page sends the report
it showed and a newer one refuses the save (58103).

Engagement **applicability status** (`tprm_engagement.applicability_status`,
independent of the risk stage):

```
NOT_SCREENED --screening--> SCREENED --decide--> EXCLUDED | DEFERRED | ADMISSION_PENDING
EXCLUDED / DEFERRED / ADMISSION_REJECTED --revised decision--> ...
ADMISSION_PENDING --approve (last level)--> ADMITTED
                  --reject--> ADMISSION_REJECTED
                  --return / withdraw--> SCREENED (the INCLUDE decision is superseded)
```

* **Exclude** (CR 2 7.2): rationale kept with the report; the engagement
  stays in Engagement Management; the vendor stays Active; no register
  record. The engagement's risk workflow (inherent, due diligence) is
  not offered.
* **Defer** (CR 2 7.3): pending; the decision records the information
  requested and from whom; the next Scope & Exposure save regenerates the
  screening; a revised decision can be recorded. (A Task Board task for
  the request is not created in this round.)
* **Include** (CR 2 7.1): starts the admission approval (7.2 below).

### 7.2 Admission approval (Q7)

Reuses the TPRM approval rules of 486 / 489: the rule matched by
`fn_tprm_match_approval_rule` on the service criticality (no risk band
exists yet) gives the levels, level roles and SoD flag, kept as a
snapshot. The approvals are recorded in their own tables,
`tprm_admission` + `tprm_admission_approval` -- not in `tprm_decision`,
whose rows are tied to a risk assessment and a due-diligence round and
drive the engagement stage. Approver rules are the same as the risk
decision: the level's role (or an active delegation from someone who
holds it), the decision-maker cannot approve, one person per level.
Approve at the last level sets ADMITTED and `admitted_dt`; the
engagement then enters the formal TPRM lifecycle (inherent risk, due
diligence, risk decision, onboarding -- unchanged; the inherent
assessment refuses a non-admitted engagement, 58125). Reject leaves
ADMISSION_REJECTED; return or withdraw sends it back for a new decision.
**Round C** creates or links the vendor-level TP Risk Register record at
this point.

## 8. TP Risk Register -- vendor-level record (Round C -- built in 524)

* `tprm_risk_register` -- one row per admission lifetime: organization,
  vendor, status OPEN / EXIT_IN_PROGRESS / CLOSED, admitted date,
  overall vendor risk status, vendor-level profile assessments (CR 2
  8.2: corporate profile, ownership and group, financial stability,
  governance, legal and regulatory standing, enterprise information
  security, business continuity capability, certifications and
  assurance), review dates. **Filtered unique index (organization,
  vendor) WHERE status <> CLOSED** -- one active record per vendor
  (CR 2 10-12).
* `tprm_register_engagement` -- the admitted engagements (CR 2 10-13):
  register record, engagement, admitted date, admission decision,
  status LINKED / ENDED.
* `tprm_register_impact_review` -- raised when a further engagement of
  an admitted vendor is admitted (CR 2 8.4): the new engagement's
  exposure against the record's current profile, outcome NO_CHANGE /
  PROFILE_UPDATED, rationale, reviewer. The new engagement still
  undergoes its own assessment.
* **Consolidated profile** (CR 2 8.3): never an average. The vendor-level
  areas are rated separately (Q9: a band of the risk model in force per
  area, `tprm_register_profile_rating`, versioned); the record shows the
  highest engagement exposure per risk dimension with the engagement that
  set it; the overall vendor risk status is the highest of the area
  ratings and the admitted engagements' residual (else inherent) bands,
  with its source. As built: section 15.4.
* **Exit** (CR 2 8.5): ending one engagement (exit, rejection or
  cancellation) ends its link only. When the last linked engagement has
  ended, the record moves to EXIT_IN_PROGRESS (the engagement exit checks,
  `EXIT_CHECK`, are the exit process); closure, by someone other than the
  person whose action started the exit, sets CLOSED. Closed records stay
  readable.
* **Screen** `tprm-risk-register` (menu 3.3): admitted vendors only,
  search and filters, the vendor profile with its engagements and their
  risk, due diligence, contracts, monitoring, admission / approval /
  acceptance history, and the exit status.

## 9. End-to-end lifecycle and state models

CR 2 section 9, with where each step lives:

| # | Step | Where | Round |
|---|---|---|---|
| 1-2 | Register vendor, activated | Vendor Registry -> Register vendor | A |
| 3-4 | Create engagement, initial information | Engagement Management -> New engagement | A |
| 5-6 | Progressive exposure, save | Scope & Exposure page | A |
| 7-9 | Screening report, discovery, classification | Engagement -> Screening tab | B |
| 10-11 | Client review and decision | Engagement -> Applicability tab | B |
| 12 | Admission approval | TPRM approval rules (`tprm_admission`) | B |
| 13 | Create or link the register record | TP Risk Register | C (B records the admission; C links the record) |
| 14-15 | Risk assessment, due diligence, monitoring, exit | Engagement tabs (existing) + register | existing / C |

Engagement **stage** (488) is unchanged in Rounds A-C: SCOPING ->
RISK_ASSESSED -> DUE_DILIGENCE -> PENDING_DECISION -> APPROVED ->
ONBOARDING -> ACTIVE -> SUSPENDED / EXITING -> EXITED, plus REJECTED and
CANCELLED. Round B places the applicability status in front of it: the
risk steps are offered only to an ADMITTED engagement (engagements
already past SCOPING before Round B are treated as admitted).

## 10. Logical entities -> physical objects

| CR 2 entity | Physical object | Round |
|---|---|---|
| Vendor | `tprm_third_party` (+ `_contact`, `_category`, `_status_history`), `tprm_vendor_match_review` | 521 / A |
| Engagement | `tprm_engagement` (+ gating answers and exposure columns of 522), `_scope`, `_link`, `_history`, `tprm_exposure_snapshot` | A |
| Screening report | `tprm_screening_report`, `tprm_screening_observation` | B |
| Applicability decision | `tprm_applicability_decision`; `tprm_engagement.applicability_status` | B |
| Admission approval | `tprm_admission` + `tprm_admission_approval`, with `tprm_approval_rule` and `tprm_approval_delegation` | B |
| TP Risk Register record | `tprm_risk_register`, `tprm_register_engagement`, `tprm_register_impact_review` | C |
| Engagement-level risk | `tprm_risk_assessment*`, `tprm_dd_*`, `tprm_safeguard_assessment`, `tprm_finding`, `tprm_decision` (kind RISK) -- unchanged, on the engagement | existing |

## 11. Authorization and segregation of duties

| Action | Screen grant | SoD in SQL |
|---|---|---|
| Register vendor | Vendor Registry ADD | -- |
| Edit vendor | Vendor Registry EDIT | -- |
| Suspend, reinstate, inactivate, reactivate, archive, restore, mark duplicate | Vendor Registry APPROVE | -- |
| Create engagement | Engagement Management ADD | -- |
| Edit engagement, Scope & Exposure | Engagement Management EDIT | -- |
| Refresh screening (B) | Engagement Management EDIT | -- |
| Record applicability decision (B) | Engagement Management APPROVE | -- |
| Admission approval (B) | the approval rule's role at each level | decision-maker <> approver; one person per level (existing D11) |
| Impact review, register exit (C) | TP Risk Register APPROVE | reviewer <> requester |
| Configuration | Third-Party Settings ADD / EDIT / APPROVE | -- |

## 12. API surface

Same pattern: Web `practice/api/tprm/...` proxies to API
`api/practice/tprm/...`; the API tier is generated from the procedure
signatures (`tools/tprm/gen_csharp.py`).

* Round A (522): `POST third-parties` (registration rules),
  `POST engagements` (core fields only), **`POST engagements/{id}/exposure`**
  (new), `GET engagements/{id}` (new columns). Details: section 15.2.
* Round B (523): `GET engagements/{id}/applicability` (reports, report,
  observations, decisions, admissions, approvals; `reportId` picks a
  version), `POST engagements/{id}/screening` (refresh),
  `POST engagements/{id}/applicability` (decision),
  `POST admissions/{id}/act`, `POST admissions/{id}/withdraw`;
  `GET engagements` gains `applicabilityStatus`. Details: section 15.3.
* Round C (524): `GET risk-register`, `GET risk-register/{id}`,
  `POST risk-register/{id}/ratings`,
  `POST risk-register/impact-reviews/{id}/decide`,
  `POST risk-register/{id}/close`; `GET engagements/{id}` gains the
  register link. Details: section 15.4.

## 13. Phase plan

| Round | Migration | Content | Depends on |
|---|---|---|---|
| Phase 1 (v1.4) | **521** (built) | Vendor Registry restructure, duplicate reviews, vendor states, legacy decoupling, engagement exposure attributes | 486-490, 507 |
| **A** | **522** (built) | Lightweight registration with automatic activation, progressive vendor information, engagement initial form, progressive exposure, CR 2 menus | 521 |
| **B** | **523** (built) | Screening (automatic, versioned, discovery correlation, classification), applicability decision, admission approval | A |
| **C** | **524** (built) | TP Risk Register record, links, consolidated profile, impact review, exit, register screen and menu | B |
| **D** | **525** (built) | TPRM dashboard to the CR 2 views, encrypted TPRM links, Defer -> Task Board task, vendor profile review cycle | C |
| later | 526+ | v1.4 items still wanted after review: TPM-owned contracts and SLAs, subcontractor records, exit plans, reporting rework (section 18) | C |

Each round has its own migration and rollback, its own API regeneration
and UI change, and a section in `docs/tprm.md`.

## 14. Acceptance scenarios (CR 2 section 11)

| Scenario | Demonstrated by |
|---|---|
| 1 Routine vendor | A: register (Active), engagement with every gating question No. B: report NO_SIGNIFICANT_INDICATORS, client Excludes. Vendor stays Active, no register record |
| 2 Potential TPRM case | A: data Yes (personal / customer data), application access Yes. B: POTENTIAL_TPRM_CASE, Include, admission approved. C: vendor in the register |
| 3 Multiple engagements | A: several engagements per vendor. B: a report series and decision per engagement. C: all admitted ones linked to one record |
| 4 New material engagement | B: new engagement screened, included, approved. C: linked to the existing record, impact review raised |
| 5 Insufficient information | A: Not sure answers / a Yes without details. B: FURTHER_INFORMATION_REQUIRED with the gaps listed; no decision is made by GRAC |
| 6 Excluded engagement of a registered vendor | B: Exclude. C: the record and its other engagements unaffected |

## 15. As built

### 15.1 Phase 1 -- migration 521

Unchanged from the first round; see `docs/tprm.md` section 521. Summary:

| Change | Detail |
|---|---|
| Vendor states | `TP_STATUS` meanings DRAFT, ACTIVE, INACTIVE, SUSPENDED, ARCHIVED; controlled transitions (`fn_tprm_vendor_transitions`); mandatory reason, evidence reference |
| Duplicate detection | `VENDOR_MATCH_ATTRIBUTE`; `tprm_vendor_match_review`; registration saves nothing until each match is reviewed; mark duplicate archives (no merge) |
| Legacy decoupling | `vendor_id`, vendor discovery / import, VENDOR link kind and VENDOR custom-field reference removed; discovery from applications |
| Engagement attributes | service recipient, substitutability, customer impact, exit dependencies |
| Navigation | "Third-Party Management", Vendor Registry, Engagements, Reviews & Monitoring, Configuration |

### 15.2 Round A -- migration 522 `522_tpm_cr2_registration_exposure.sql`

| Change | Detail |
|---|---|
| DRAFT retired | DRAFT vendors -> ACTIVE (`first_activated_dt` set, history row); baseline DRAFT value deleted; organization values of meaning DRAFT retired; `TP_STATUS` allowed meanings ACTIVE, INACTIVE, SUSPENDED, ARCHIVED |
| Transitions | `fn_tprm_vendor_transitions` without DRAFT; REACTIVATE needs the registration fields; RESTORE -> INACTIVE |
| Registration | `sp_tprm_third_party_save`: relationship owner, country and a primary contact with an e-mail address are mandatory (58050-58053); a new vendor is ACTIVE at once; audit CREATE + ACTIVATE |
| Mark duplicate | `sp_tprm_vendor_match_review_save`: from any non-archived state with no open engagement (521's DRAFT / INACTIVE gate 58027 removed) |
| Engagement core | `sp_tprm_engagement_save` re-issued with the CR 2 5.1 fields and the administrative fields; CR 2 mandatory set (58060); vendor must be ACTIVE (58061); criticality no longer required |
| Exposure | 8 gating-answer columns, `data_processing_details`, `contract_start_dt`, `contract_end_dt`, `contract_documents`, `exposure_saved_dt`, `exposure_saved_by`; new `sp_tprm_engagement_exposure_save`; shared `sp_tprm_engagement_flag_material`; answers backfilled from existing data |
| Scope items | `sp_tprm_scope_item_save` / `_remove` refuse PROPOSED items (58062) -- the exposure page owns them |
| Engagement read | `sp_tprm_engagement_get` returns the new columns |
| Samples | `sp_tprm_sample_load` registers samples as ACTIVE (relationship owner = the person loading them; a primary contact is added on first edit) and answers their gating questions |
| Existing data | `sp_tprm_engagement_answers_derive`: gating answers from what each engagement records, the data category behind a data exposure added as a scope item, the data exposure aligned to the highest category (so the first save reports no false material change); Scope & Exposure counts as saved where a criticality exists |
| Navigation | `tprm-engagements` "Engagement Management"; `tprm-dashboard`, `tprm-reviews` hidden from the sidebar; `tprm-configuration` "Third-Party Settings" under Settings (module type Organization) |
| Guards | 521 refuses to run after 522 |

Error numbers: 58050-58099.

### 15.3 Round B -- migration 523 `523_tpm_cr2_screening_admission.sql`

| Change | Detail |
|---|---|
| Configuration | List `SCREENING_INDICATOR` (9 indicators, thresholds as ranks); also in the regenerated 487 |
| Screening | `tprm_screening_report`, `tprm_screening_observation`; `sp_tprm_screening_run` (rules of section 6.4); called by the re-issued `sp_tprm_engagement_exposure_save` in its transaction; refresh endpoint |
| Discovery | `sp_tprm_engagement_discover` re-issued: processes and business functions lead to practice instances; `@suppress_result` + `#tprm_discovery` hand-over |
| Decision | `tprm_applicability_decision`; `sp_tprm_applicability_decide` (INCLUDE / EXCLUDE / DEFER, 58101-58110); `sp_tprm_applicability_get` |
| Admission | `tprm_admission`, `tprm_admission_approval`; `sp_tprm_admission_act` (58115-58123), `sp_tprm_admission_withdraw` (58124; the decision-maker or an organization administrator -- the Withdraw button follows the same rule). Decide, approve and withdraw re-check the engagement and the admission under locks inside their transaction (a closed or re-decided engagement: 58126) |
| Engagement | `applicability_status`, `current_screening_report_id`, `admitted_dt`; `sp_tprm_engagement_get` and `sp_tprm_engagement_list` (+ filter) re-issued; `sp_tprm_risk_assessment_start` needs ADMITTED (58125) |
| Existing data | Engagements past scoping or with a risk assessment -> ADMITTED; scoping engagements with Scope & Exposure saved are screened (trigger MIGRATION); `sp_tprm_sample_load` re-issued so sample engagements are screened when loaded |
| Guards | 522 and its rollback refuse to run while 523 is installed; retired practice instances are listed by discovery but are not screening indicators |

Error numbers: 58100-58149.

### 15.4 Round C -- migration 524 `524_tpm_cr2_risk_register.sql`

| Change | Detail |
|---|---|
| Configuration | List `VENDOR_PROFILE_AREA` (the eight CR 2 8.2 areas, extensible); also in the regenerated 487 |
| Register | `tprm_risk_register` (TPRR-nnn, OPEN / EXIT_IN_PROGRESS / CLOSED; filtered unique index: one non-closed record per vendor), `tprm_register_engagement` (LINKED / ENDED with the stage that ended it), `tprm_register_history` |
| Creation and links | `sp_tprm_register_link` from the re-issued `sp_tprm_admission_act` at the final approval: creates the record, reopens one that was exiting, or joins it; the engagement history records the link. Engagements admitted before 524 are linked by the migration (no impact review) |
| Vendor profile | `tprm_register_profile_rating`: one CURRENT rating per area on the bands of the risk model in force (rationale, evidence reference, assessor); a new rating supersedes the old one. `sp_tprm_register_rating_save` (EDIT) |
| Overall status | `fn_tprm_register_overall`: highest band rank among the current area ratings and the linked engagements' residual (else inherent) band; ties go to the vendor-level rating; a rating of an area the organization has since hidden is shown but not counted. Ranks are compared as stored (each band's rank in its own risk model version) -- keep ranks comparable when a new model version changes its bands. Shown with its source on the list and the record. The record also shows the highest engagement score per risk dimension |
| Impact review | `tprm_register_impact_review`, raised when an engagement joins a record that already has a linked engagement; `sp_tprm_register_impact_review_decide` (APPROVE): NO_CHANGE / PROFILE_UPDATED (needs an area rating since it was raised); SoD: not the decision-maker who included it. Also raised when an exiting record is reopened by a new admission and holds earlier area ratings. Cancelled when that engagement ends |
| Exit | `sp_tprm_register_sync_engagement` from the re-issued `sp_tprm_engagement_lifecycle` (COMPLETE_EXIT, CANCEL) and `sp_tprm_decision_act` (REJECTED): the link ends; with no linked engagement left the record is EXIT_IN_PROGRESS; `sp_tprm_register_close` (APPROVE) closes it -- not by the person whose action started the exit (when that action had no employee sign-in, the starter is unknown and the check cannot apply). The engagement exit checks (EXIT_CHECK) remain the exit process; the register records its closure. A further admission while exiting reopens the record |
| Also | Cancelling an engagement withdraws its pending admission (Round B open item). `sp_tprm_decision_act`: a second approval of the same level at the same moment fails instead of overwriting the first |
| Screen | `tprm-risk-register` (CR 2 menu 3.3, under Third-Party Management, 374); grants copied from Engagement Management. Links between the register and Engagement Management use the encrypted navigation code |
| Guards | 523 and its rollback refuse to run while 524 is installed |

Error numbers: 58150-58199.

### 15.5 Phase D -- migration 525 `525_tpm_dashboard_tasks_profile_review.sql`

| Change | Detail |
|---|---|
| Dashboard | `sp_dashboard_tprm` re-issued from 507 (every 507 row kept). KPIs: awaiting the applicability decision (not screened / screened / deferred / admission rejected), potential TPRM cases awaiting a decision, further information required, deferred, admissions pending, excluded; section `tprmregister`: vendors on the register, overall risk high or critical, impact reviews open, profile reviews overdue / due in 30 days, not fully rated, exiting, needing attention. Distributions: open engagements by applicability -- "awaiting decision" is exactly the UNDECIDED filter, deferred included (drill: Engagement Management `applicability` filter), register records by overall vendor risk (drill: register `band`). Ageing: pending admissions. Lists: admission approvals pending, register records needing attention. Page: two new KPI cards, seven attention rows, two charts, two watchlists; Home card: vendors on the register. `ManagementDashboards`: section `tprmregister` -> `tprm-risk-register` |
| Encrypted links | `Shared/secure-nav.js` (`gracSecureNav.open / context / attrs`, one delegated click handler), used by `tprm-common.js` and both dashboards. Gateway filter types: `TprmEngagement` -> Engagement Management or Reviews, `TprmRegister` -> TP Risk Register, `TprmThirdParty` -> Vendor Registry or Engagement Management (New engagement). Converted: dashboard and Home rows, Vendor Registry (engagement links, New engagement), Reviews <-> engagement (the review to complete travels as its number). The `?engagementId=`, `?thirdPartyId=`, `?newForThirdParty=`, `?reviewId=` readers are removed. Dashboard drill filters (`stage`, `applicability`, `attention` ...) and `organizationId` stay in the URL as for every other module |
| Defer task | Task type `TprmInformationRequest`, Task Board source `ThirdParty` (the 449 source list plus ThirdParty; `sp_task_centre_source_counts` re-issued; Task Board filter option and labels). `sp_tprm_applicability_decide` re-issued: a DEFER naming "requested from" opens a task for that person (`sp_task_open`, same transaction); `tprm_applicability_decision.information_task_id`; the decision shows the task number and status. The task is due in five days (given explicitly, so `sp_task_open` skips its post-commit SLA step). A later decision on the engagement cancels the previous decision's open task (Task state machine, reason TPRM_DECISION_REVISED), so a repeated deferral never leaves two tasks |
| Profile review | `tprm_risk_register.last_profile_review_dt / next_profile_review_dt / profile_review_rule_code`, `tprm_register_profile_review`; `sp_tprm_register_profile_review_save` (EDIT): every area in use rated; next date = today + the frequency of the review rule matched on the overall band rank and the linked engagements' highest criticality. A new record's first review is due within the rule's lead days (re-issued `sp_tprm_register_link`); existing records get theirs from the migration. Register list: attention PROFILE_REVIEW_DUE (due in 30 days or overdue) and PROFILE_REVIEW_OVERDUE, due / overdue in the profile column; record: dates in the header, Record profile review, review history |
| Guards | 524 and its rollback refuse to run while 525 is installed |

Error numbers: 58200-58249 (58151 and 58157 of 524 reused).

## 16. What happens to each current TPRM object

| Object | Fate | Round |
|---|---|---|
| Configuration (486), baseline seed (487) | Kept; 487 regenerated as lists change | each |
| `tprm_third_party` + contact / category / history / match review | Kept as the Vendor Registry; DRAFT retired | A |
| `tprm_engagement` | Kept; gating answers and exposure columns added (A); applicability status (B) | A, B |
| `tprm_engagement_scope` | PROPOSED items owned by Scope & Exposure; ACTUAL unchanged | A |
| `sp_tprm_engagement_discover`, `tprm_engagement_link` | Extended for screening correlation | B |
| `tprm_risk_assessment*`, `tprm_dd_*`, `tprm_safeguard_assessment`, `tprm_finding` | **Stay on the engagement** (CR 2 8.3); offered only after admission | B |
| `tprm_approval_rule`, `tprm_approval_delegation` | Reused for the admission approval (`tprm_admission`); `tprm_decision` stays the risk decision | B |
| `sp_tprm_third_party_sync_status` | No-op (521); removed when its 488 / 489 callers are next re-issued | later |
| `tprm_review`, monitoring sweep | Kept on the engagement; the register shows its engagements' open reviews (a register-level review cycle is open point 7) | C |
| `tprm_onboarding_item` (EXIT) | Stays the engagement exit process; the last exit puts the register record in exit, closure follows | C |
| `sp_dashboard_tprm` (507) | Kept (Home card); reworked to the CR 2 views later | later |

## 17. Legacy vendor (Settings -> Dependencies): data-disposition plan

Out of scope for CR 2 (CR 2 10-18). TPM reads and writes none of these
objects after 521.

| Area | Objects that hold or read legacy vendors | Records to decide on |
|---|---|---|
| Dependencies (core) | `organization_dependency_vendor` (002), `organization_dependency_application.vendor_id`, `practice_dependency_resolution` (dependency type Vendor), dependency category sync (238, 497), Settings -> Dependencies Vendor tab | vendor rows, application ownership, resolutions on practice instances |
| Risk Centre | `risk_register.linked_vendor_id` (205 / 378), risk dependency map (265) | risks linked to vendors |
| Assurance | `org_assurance_execution_entity` dimension VENDOR (074) | audit scope entities and their observations |
| Asset & Contract | `asset_contract.vendor_id` (434), coverage (435), renewals (436), relationships (440), business services (441), reports (452) | contracts and their links |
| Users / ownership | ownership management (345), user scope reads (341, 366, 467) | owner assignments |
| Dashboards / seeds | governance dashboard (503), master seeds (023, 272) | none (derived) |

Disposition options, per area, to be decided separately: (1) retain
read-only; (2) map each legacy vendor to a TPM vendor and re-point the
consumers; (3) export and archive. Recommended: (1) now; (2) for Risk
Centre and Assurance after Round C. Each step needs its own approval and
rollback.

## 18. Open points for review

1. **Screening thresholds** (section 6.4) -- built with the baseline
   above and FURTHER_INFORMATION_REQUIRED winning over POTENTIAL_TPRM_CASE;
   confirm, or adjust per organization in Third-Party Settings.
2. **Engagements already in assessment** before Round B -- built as
   admitted (section 15.3); confirm.
3. **Admission approval conditions** -- built on the service criticality
   only (the rule's criticality threshold; band thresholds do not apply
   before a risk assessment). Confirm whether classification or service
   category conditions are wanted.
3a. **Information requests on Defer** -- decided (Q10): a Task Board task
   for the person asked; built in 525.
4. **Consolidated vendor risk status** (section 8) -- decided (Q9):
   highest wins; built in 524.
7. **Register-level periodic review** -- decided (Q10): built in 525 on
   the TPRM review rules (section 15.5).
5. **Contracts** -- v1.4 proposed TPM-owned contracts; CR 2 asks only for
   contract information on the engagement (built in Round A). Confirm
   whether TPM-owned contracts are still wanted.
6. **Legacy vendor** -- choose the disposition option per area
   (section 17).
