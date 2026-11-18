# Audit Intelligence (CR2 - AA)

Source: *CR2 - AA.docx*. Title: "GRAC – Audit Assurance: Audit Intelligence, Audit Universe & Risk-Based Internal Audit (RBIA)". The full document was received 2026-11-17.

The change **extends** Audit Assurance. These keep working as they are:
- Audit Definition and Audit Configuration.
- Plan, Programme and Engagement.
- Scope Builder.
- Working Papers, Observations and Reports.

Ownership stays where it is:
- **Organization Registry** (569-575) is the source of organizational identity.
- **Risk Management** remains the single Enterprise Risk Register.
- Audit Assurance owns the Audit Universe and the RBIA methodology.

## Phases (CR2 section 12)

| Phase | Migration | CR2 part | Status |
|---|---|---|---|
| 1 Audit Universe | 577 | A (3.x) | **Built** |
| 2 Framework & Practice Mapping | 580 | B (4.x) | **Built** |
| 3 Enterprise Risk Intelligence | 581 | C (5.x) | **Built** (Part G intake -> phase 6) |
| 4 RBIA | 582 | D (6.x) | **Built** |
| 5 Audit Plan Recommendations | 583 | E (7.x) | **Built** |
| 6 Gap and Risk candidates | 584 | F (8.x), G (9.2) | **Built** |

## Phase 1: Audit Universe (577)

The full description is in `docs/audit-management-module.md`, section "Audit Intelligence -- Audit Universe (577)".

**Acceptance criteria covered**
- **AU01: discover registry records.** Covered by *Discover from Registry*.
- **AU02: select, exclude and validate.** Covered by Include, Exclude (with a reason) and Release, followed by Submit and Approve.
- **AU03: create additional auditable subjects.** Covered by "+ Add Subject" (source Manually Created or Other) and by Add Sub-subject.
- **AU04: configure categories and classifications.** Covered by Universe Configuration.
- **AU05: hierarchical and many-to-many relationships.** Covered by Parent Subject, the typed relationships, and many registry records per subject.
- **AU06: source references and approval history.** Covered by `_source`, which keeps the registry record's own id, and by `_history`.
- **AU07: Assets and Third Parties are not Universe masters.** They are not discovery sources.

**Choices made from the document**
- **Approval.** A subject is approved by the person holding the new **Head of Internal Audit** responsibility. A delegate is any role that is given this responsibility in Role Master. Segregation of duties applies: nobody approves their own submission.
- **Statuses.** The five lifecycle statuses are fixed codes; only their names can be changed. CR2 3.5 asks for configurable statuses, but the lifecycle depends on these codes.
- **Seeded values.**
  - Categories come from CR2 3.3 and 3.6, plus v1's list.
  - Regulatory Significance is High / Medium / Low / Not Applicable.
  - Business Criticality is Critical / High / Medium / Low, the same list as GRAC's Business Function criticality.
  - Relationship types come from the examples in CR2 3.6.
  - Audit Classifications and Subcategories are left empty for the organization to set up.
- **Fields left for later phases.** Last Audit Date, Next Audit Due and audit priority belong to phases 4-5.

## Phase 2: Framework & Practice Mapping (580)

The full description is in `docs/audit-management-module.md`, section "Audit Intelligence -- Framework & Practice Mapping (580)".

**Acceptance criteria covered**
- **AU08: map to multiple frameworks, controls and requirements.** Every level can be mapped, many-to-many.
- **AU09: map to practices and practice instances.** Covered.
- **AU10: existing mappings suggest relationships.** "Refresh Suggestions" uses the Operationalize dependencies and the statement-to-practice mappings.
- **AU11: confirm, reject and deactivate mappings.** Covered, one row at a time or in bulk.

**Readings taken (sir: proceed)**
- **Levels.** GRAC has no Control record, so:
  - a **Source Structure** node is the Control;
  - a **Source Statement** is the Requirement;
  - an obligation of a practice instance is the Obligation.
- **Suggestion sources.**
  - Used: the subject's registry records -> the practice instances that depend on them in Operationalize -> their practices -> those practices' statements -> those statements' controls, releases and frameworks; plus the instances' obligations.
  - An Organization Unit subject also takes in its unit's locations, departments and processes.
  - Not used: a Legal Entity subject is not expanded, because it would suggest everything.
  - Not used: practice ownership, because GRAC stores instance owners as names, not people.

## Phase 3: Enterprise Risk Intelligence (581)

The full description is in `docs/audit-management-module.md`, section "Audit Intelligence -- Enterprise Risk Intelligence (581)".

**Acceptance criteria covered**
- **AU12: view the enterprise risks of a subject.** Covered by the Risk Intelligence screen.
- **AU13: ratings and treatment come from Risk Management.** Read live from `risk_register`, the published methodology and the treatment tasks.
- **AU14: no separate risk register.** Nothing is copied; risks are only referenced, by id.
- **AU15: one risk on many subjects.** Covered by the mapping level RISK, which is many-to-many.
- **AU16: snapshot at RBIA approval.** Done in Phase 4 (582).

**Readings taken**
- **Inspected first and reused (CR2 9.7):**
  - Impact Details (`risk_dependency_map`).
  - Risk-to-practice-instance links.
  - Treatment roots.
  - The methodology's appetite and trend. This rule was moved into `fn_risk_register_methodology_status`, so the Risk Centre and Audit read one definition instead of a copy.
- **Risk suggestions:** risks whose Impact Details name the subject's registry records, risks whose Business Function is the subject's function, and risks mapped to the subject's practice instances.
- **Not matched to a practice instance:** findings raised from a working paper that have no execution entity.

## Phase 4: Risk-Based Internal Audit (582)

The full description is in `docs/audit-management-module.md`, section "Audit Intelligence -- Risk-Based Internal Audit (582)".

**Acceptance criteria covered**
- **Methodology configurable by the Head of Internal Audit, versioned (CR2 6.2):** RBIA Configuration; Draft -> Published -> Superseded.
- **Inherent, control effectiveness and residual scores (CR2 6.6 / 6.7):** recalculated on every save.
- **Risk band sets priority and frequency (CR2 6.8):** final band -> audit priority, frequency, next audit due.
- **Override with justification, approved (CR2 6.9):** proposed by the assessor, approved with the assessment.
- **Review and approval (CR2 6.10):** Audit Reviewer (optional step) and Head of Internal Audit; never the assessor.
- **AU16: snapshot at RBIA approval:** the subject's Risk Intelligence (581) is frozen on the assessment.

**Readings taken**
- **The RBI preset is a starting point:** its weights, bands and frequencies are starting values for the Head of Internal Audit to set; nothing is fixed in code.
- **Not applicable** answers are left out of the scores; a parameter with no scored answers is left out of the weighted-average and highest aggregations, and counts as 0 in the weighted sum.
- **One open assessment per subject;** Reassess starts the next one from an approved, current assessment.

## Phase 5: Audit Plan Recommendations (583)

The full description is in `docs/audit-management-module.md`, section "Audit Intelligence -- Audit Plan Recommendations (583)".

**Acceptance criteria covered**
- **AU23: approved RBIA results generate Audit Plan Recommendations.** Generate, per Annual Audit Plan.
- **AU24: recommendations show risk, frequency, previous audit and assurance intelligence.** Band, residual score, priority, frequency, last audit and result, due by, enterprise risks, open gaps, audit findings, relevant audit definition, suggested period.
- **AU25: explicit Internal Audit acceptance.** Only the Head of Internal Audit accepts, defers or rejects; Accept goes through the existing engagement form.
- **AU26: existing plan, programme, engagement and Scope Builder unaffected.** Engagements are created by the existing procedure; the engagement form only gained optional starting values.

**Decisions (sir, 2026-11-17)**
- Generated for a chosen Annual Audit Plan (Draft or Submitted).
- No approved RBIA: listed as Not assessed; can still be accepted.
- Accept opens the engagement form prefilled; the engagement is linked to the Universe subject.
- Configurable: bands to recommend, due window, always-include rules, ranking order.

**Readings taken**
- **Last audit** counts only engagements linked to the subject (accepted from a recommendation). Engagements created before 583 have no subject, so the first plans show "Never audited" until engagements are linked.
- **Due by** = last audit + RBIA frequency (the approved RBIA's own "next audit due" counts from its approval date).
- **Suggested period** = the month the subject falls due, inside the plan period.

## Phase 6: Gap and Risk candidates (584)

The full description is in `docs/audit-management-module.md`, section "Audit Intelligence -- Audit findings to Gap and Risk candidates (584)".

**Acceptance criteria covered**
- **AU27: audit findings can generate Gap Candidates.** Raise Gap Candidate on an Accepted, non-Informational finding.
- **AU28: findings stay owned by Audit Assurance.** The gap and the risk candidate reference the finding; nothing in Gap Center or Risk Centre changes it.
- **AU29: Risk Candidates from GRAC modules reach Risk Management.** Raise Risk Candidate on a finding; Gap, Exception and other modules already raised candidates (207).
- **AU30: duplicate candidates link to existing risks.** Risk Centre's duplicate check and Closed as Duplicate (existing); the linked risk is then mapped to the finding's Universe subjects.
- **AU31: one Enterprise Risk Register.** Candidates become risks only in Risk Centre; Audit keeps references.

**Decisions (sir, 2026-11-17)**
- Reuse the gap generator as Raise Gap Candidate; Informational findings excluded.
- Gap Analysis kept as it is; CR2's six dispositions map onto it.
- Raise Risk Candidate on Accepted, non-Informational findings.
- A registered or duplicate-linked risk is mapped to the finding's Universe subject(s) as Confirmed.

**Readings taken**
- "Regenerate Gap" on Observations called a route retired in 113; it now calls the Custom Gap API.
- The candidate's source is the seeded "Assurance" source (unused before); its reference is the finding code.

## Menu (578)

Audit Assurance is grouped by area, per sir's list, with the Dashboard first:
1. Audit Intelligence
2. Audit Definition
3. Audit Planning
4. Audit Execution
5. Audit Findings
6. Audit Reporting

Audit Governance comes with its first screen. Full table in `docs/audit-management-module.md`, section "Audit Assurance menu grouped by area (578)".

## Deploy (577, 578, 580, 581, 582, 583, 584)

1. Run `577_audit_universe.sql`, `578_audit_assurance_menu_groups.sql`, `580_audit_universe_mapping.sql`, `581_audit_risk_intelligence.sql`, `582_audit_rbia.sql`, `583_audit_plan_recommendations.sql`, then `584_audit_finding_candidates.sql`. Migration 579 is another session's (Risk Settings menu).
2. Restart the Api and publish Web.
3. In Role Master, give the **Head of Internal Audit** responsibility to the approving role(s), and Audit Reviewer / Auditor as used today. Then open RBIA Configuration, Start Draft from the RBI preset, adjust it and Publish before starting assessments.
4. Users sign out and back in to see the new menu.
