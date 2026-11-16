# Audit Change -- P0 build plan

Source: *GRAC Audit Assurance Module -- Consolidated Functional Change Specification* (Audit_Change.docx, 2026-11-15).
This plan follows that document's P0 list. P1 items come after: RBIA assessment, Audit Reports, Follow-up, Audit Committee dashboards, and Quality & Review.

## Decisions (sir, 2026-11-15)

| Question | Decision |
|---|---|
| Scope of the build | P0, in phases. Each phase ships as one migration and one Api/Web release, like 551-558 |
| Evidence Config (536), Trigger (548), Audit Configuration menu (549) | **Keep our decisions.** Evidence stays per question, there is no Trigger step, and Audit Configuration opens from Audit Definition only. Spec 4.2.4, 4.2.7 and §5 item 3 do not apply |
| Programme layer | **Mandatory.** Annual Audit Plan -> Programme -> Engagement. Existing engagements move into one default programme per plan |
| Execution answers | **Working papers replace the answer grid.** The question's conclusion comes from its working papers. The auditor raises findings from a working paper, and nothing raises them automatically (spec 4.6, 4.7) |
| Look and feel | Unchanged. Same pages, list grids, 3-dot menus, filter combos and child rows. No popups for working views |

## Phases

| Phase | Migration | Spec | What |
|---|---|---|---|
| A (built) | 560 | 4.1 | Audit Definition: **Assurance Approach** master (Risk-Based, Periodic, Continuous, Event-Driven, Thematic, Ad-hoc), **Audit Mandate** (multi-select of 14 mandates: REG, STAT, BOARD, AC, RC, CHARTER, POLICY, MGMT, CONTRACT, FRAMEWORK, INCIDENT, INVEST, EXTERNAL, OTHER), **Applicable Frameworks** (subscribed frameworks plus typed ones), all versioned with the definition. Category list done in 559 |
| B (built) | 561 | 4.2.3 | Question Sets: the guidance field becomes **Testing Guidance**, a long text for detailed procedures. Each question gets an Active / Inactive **Status**. Inactive questions are not adopted into new executions |
| C1 / C2 (built) | 562 / 563 | 4.2.1 | Scope Builder in three steps: **Subjects** (business units, branches, processes, controls/practices, applications, assets, vendors, manual subjects) -> **Discover** (controls, practices, practice instances, risks, gaps, exceptions, assets, vendors, each with the reason it is linked) -> **Review and confirm** (include or exclude a category, untick records, search, add manual items). Advanced Mode is removed. Discovery is optional |
| D (built) | 564 | 4.2.2 | Control and Practice Mapping step in Audit Configuration: controls, practices and selected practice instances, many-to-many, plus manual mappings |
| E (built) | 565 | 4.3 | Annual Audit Plan fields (period, owner, objectives, methodology, planned coverage, budget and resources, revisions, planned vs actual) plus a **Programmes** layer: a list under each plan, each programme with its engagements as child rows. Planning Methodology master (Risk-Based, Regulatory/Mandatory, Periodic, Event-Driven, Thematic, Management-Directed, Ad-hoc). Existing engagements are moved into a default programme |
| F (built) | 566 | 4.5 | **Audit Engagements** become a distinct record with its own menu and list: number, definitions, programme and plan references, subject, objective, auditee, lead auditor plus **team**, planned and actual dates, status, instructions, and scope approval as a versioned, immutable snapshot (it replaces the current freeze) |
| G (built) | 567 | 4.6, 4.7 | **Test Working Papers**, several per question: testing guidance prefilled, procedure performed, testing method, population, sampling method, sample size and details, evidence, result, deviations, comments, conclusion, reviewer comments, and review status (Pending / Reviewed / Returned / Approved). Questions can be assigned to auditors, and tests can be reopened. Execution-level scoring and conclusion come from the working papers. Findings are raised from a working paper with the spec 4.7 fields (criteria, condition, root cause, risk/impact, recommendation, management response, corrective action). Gaps and exceptions in scope never become findings on their own. Menu items: **Workpapers**, and **Audit Engagements** (from F) |

Every phase keeps old records readable (spec 9.14). An approved definition, configuration, question set or scope is never changed silently (spec 6). It is copied to a new version instead.

## Menu (spec 5, as decided)
Dashboard, Audit Definition, Audit Programmes (E), Audit Plans, Audit Engagements (F), My Audits, Executions, Workpapers (G), Observations, Question Sets. Audit Configuration stays off the menu (549). P1 adds Audit Reports, Audit Follow-up, and Audit Quality & Review.

## Phase C split (2026-11-15, sir)
- **Subjects:** Step 1's subject types are the Operationalize dependency types only. Control Statements is not a subject.
- **C1 (562, built):** Step 1 Select Audit Subjects and Step 2 Discover, both in Audit Configuration.
- **C2 (563, built):** Step 3 Review and Confirm, on the engagement's live scope in My Audits. Freeze Scope gains the discovered categories (over the engagement's instances), Include per category, search, unticking records with a reason, manual items, and the approved scope snapshot (version 1, immutable). Later phases moved up one number (D 564 ... G 567).

## Phase D (564, built, 2026-11-15)
- Control and Practice Mapping is an **optional** Audit Configuration step between Scope Builder and Question Sets (spec order). Controls are source statements (statement tree picker); practices and instances are multi-selects, picking practices narrows the instances; manual mappings for records not in GRAC. Optional until something is mapped; it never blocks Submit for Review.

## P1 (2026-11-16, sir)
| Phase | Migration | Spec | What |
|---|---|---|---|
| H (built) | 568 | 4.9 | **Audit Reports**: one per engagement, in-app from section templates (sections, order, headings, standard text), Draft -> In Review -> Approved -> Issued (frozen per version), revisions |
| I | 569 | 4.9, 4.8 | **Audit Follow-up**: corrective actions per observation as a separate audit list (not Task Board tasks -- sir), owner, target date, progress, remediation evidence, auditor validation, closure approval, overdue escalation, repeat observations; with Risk / Gap / Exception integration |
| J | 570 | 4.4 | **RBIA**: independent audit risk assessment, configurable parameters / weights / bands / frequency rules with an RBI RBIA preset |
| K | 571 | 4.10 | **Audit Committee dashboards**: plan vs actual, programme progress, coverage, findings, overdue actions, repeat findings, turnaround |
| L | 572 | 4.11 | **Audit Quality & Review**: working paper / engagement / report review, reviewer observations, independence declarations, documentation completeness, quality assessment |

Decisions (sir, 2026-11-16): report per engagement; in-app with section templates; follow-up actions as a separate audit list; RBIA configurable with an RBI preset.

## Phase G (567, built, 2026-11-16)
- Decisions (sir): a Workpapers page (My Audits opens it); Satisfactory / Partially Satisfactory / Unsatisfactory / Not Applicable, the question concluded from its approved papers (worst) unless a reason is given; the engagement Reviewer (else the Lead) reviews, never their own paper, and lead or reviewer reopens; score = question weight x conclusion in the audit's bands, the lead writes the audit conclusion.
- Built: working papers (several per question, Draft -> Pending -> Reviewed -> Approved / Returned, reopen), question assignment and conclusions, activity history, the execution score and audit conclusion, the Submit gate, Raise Finding with the spec 4.7 fields, the Observations Finding tab, the Workpapers menu; the 558 answers converted to approved papers.
- P0 is complete with this phase. P1 next: RBIA assessment, Audit Reports, Follow-up, Audit Committee dashboards, Quality & Review.

## Phase F (566, built, 2026-11-16)
- Decisions (sir): independent engagements are supported (plan and programme optional; initiation source, reason and the authority's approval reference mandatory) beside planned ones, one lifecycle for both; Audit Team = lead (mandatory), members, subject matter experts, reviewer, external auditors and remarks, auditors from the Auditor responsibility (553), stored against the engagement with a trail.
- Built: the engagement record (subject, objective, scope, auditee, instructions, actual dates, derived status, cancel with a reason), the team table and its trail, the Audit Engagements menu and list (child-row details), the shared engagement form (Audit Plans uses it too). Assumed and to confirm: derived status + Cancelled; full-view form; SMEs any active employee; independent executions have origin MANUAL.
- The spec's scope-approval snapshot came with 563 (C2).

## Phase E (565, built, 2026-11-16)
- Decisions (sir): revise sends an Approved / Active plan back to Draft (version + 1, reason, history); planning methodology per programme (the plan lists all); programmes added / edited inline in the plan's child row.
- Annual plan fields (financial year, objectives, planned coverage, budget, effort, resources), the Programme layer (mandatory, existing engagements moved into a General Programme), the Planning Methodology master, planned vs actual, plan revisions.
