# docs566.py -- 566 docs. Run from the repo root.
import sys
def rp(p, o, n):
    s = open(p, encoding='utf-8').read()
    if s.count(o) != 1: sys.exit('%s: %r' % (p, o[:80]))
    open(p, 'w', encoding='utf-8', newline='').write(s.replace(o, n))

SECTION = """### Audit Engagements as a record -- planned and independent, with the audit team (566, 2026-11-16, sir)
Audit Change spec 4.5, P0 phase F. An engagement is now a record of its own, with its own menu (**Audit Engagements**, under Audit Assurance after Audit Plans).
- **Decisions (sir, 2026-11-16):**
  - **Two kinds, one lifecycle.** PLANNED: in a programme of an approved plan (plan and programme mandatory; approved with the plan). INDEPENDENT: outside the annual plan; plan and programme optional (a reference only), approved by its authority. Both run the same execution lifecycle.
  - Mandatory for both: Audit Definition(s), Audit Subject, Scope, Audit Team (the lead).
  - An independent engagement needs its **Initiation Source** (Board / Audit Committee, Regulator / RBI, Chief Audit Executive, Management Request, Fraud / Vigilance, Incident / Event, Follow-up Audit, Other), the **reason for initiation** and, to be approved, an **approval reference**.
  - **Audit Team:** Lead Auditor (mandatory, one), Team Members (several), Subject Matter Experts (optional), Engagement Reviewer (optional, one), External Auditors (optional), Team Remarks. Eligible auditors are the people whose role carries the Auditor responsibility (553); no separate auditor master. The same person may be on several engagements. Engagement responsibility is not the person's designation.
  - The team is stored against the engagement. Changes are trailed: a removed member stays as a row with who removed them and when; each row keeps the name, designation and role as they were when added.
- **Assumed (not answered; to confirm):**
  - Status is derived: **Draft** (independent, not approved) / **Planned** / **In Progress** / **Completed** (from its executions), plus **Cancelled** with a reason (only while no execution is live).
  - The engagement form is a full view like the plan form.
  - Subject matter experts may be any active employee (not only auditors).
  - An independent engagement's executions are created with origin MANUAL and no plan (planned ones stay PLAN).
- **What the user sees:**
  - **Audit Engagements** list: organization / status / type / plan filters (selects), search, Code, Engagement, Type (with the initiation source), Plan / Programme, Audit Subject, Lead Auditor, Planned, Audits (done / total), Status. The chevron or a row click opens the details in a child row: the record, its audits and its team with the trail.
  - 3-dot: View, Edit (independent Draft; planned while the plan is Draft / Submitted and nothing started), Audit Team (until completed), Approve (independent Draft; asks for the approval reference), Start Execution, View Scope, Cancel Engagement (reason; nothing started), Delete (independent Draft).
  - "+ Add Independent Engagement".
  - The engagement form (Audit Plans and Audit Engagements, the same form) opens in full view: type, plan, programme, order; name, audit subject; for an independent one initiation source, approval reference and reason; the audits (dual list) and View Scope; planned start / end, branch; auditee (role -> person) and department; lead auditor, team members, reviewer, subject matter experts, external auditors (one per line, "Name - Organisation"), team remarks; objective, scope, instructions, notes. "Audit Team" opens the same form with only the team editable.
  - Audit Plans keeps its flow; its engagement dialog is now this shared form (the old "Assigned Team" text box is replaced by the team; existing text is kept on the record).
- **Data:**
  - `org_assurance_plan_item.org_assurance_plan_id` becomes NULLable (its index rebuilt). New columns: `engagement_origin` (PLANNED default), `audit_subject`, `engagement_objective`, `scope_summary`, `auditee_role_id / _role_name / _employee_id / _name`, `engagement_instructions`, `team_remarks`, `initiation_source_code`, `initiation_reason`, `approval_status`, `approval_reference`, `approved_by / _dt`, `cancelled_dt / _by`, `cancel_reason`.
  - New `org_assurance_engagement_initiation_master` (the eight sources) and `org_assurance_engagement_team` (LEAD / MEMBER / SME / REVIEWER / EXTERNAL, snapshots, removed_by / removed_dt). Existing engagements get a LEAD row from their assigned auditor.
  - New `fn_org_responsibility_holder` (553's rule in one place; `sp_org_responsibility_holder_list` re-issued over it), `fn_org_assurance_engagement_status` (progress and actual dates), `fn_org_assurance_engagement_rows` (the list and detail row); `fn_org_assurance_engagement_progress` re-issued over the status function (+ Cancelled).
  - New procedures `sp_org_assurance_engagement_initiation_list`, `_list`, `_get`, `_team_list`, `_team_apply` (internal), `_team_save`, `_approve`, `_cancel`, `_delete`.
  - Re-issued `sp_org_assurance_plan_item_save / _list` (565 bodies: independent engagements, the record fields, the team, code ENG-yyyy-nnnn when there is no plan), `sp_org_assurance_plan_item_start_execution`, `sp_org_assurance_my_audits_prepare`, `sp_org_assurance_my_audit_list` (555 bodies: an approved independent engagement starts and shows in My Audits).
  - Errors 53950 (subject), 53951 (scope), 53952 (lead), 53953 (initiation source / reason), 53954 (not an auditor), 53955 (lead changed after start), 53956 (approval state), 53957 (cancelled / completed), 53958 (cancel reason / live executions), 53959 (team list).
  - Menu `org-audit-engagements` (467, briefcase) under nav-assurance, given to every role that has Audit Plans with the same rights; written back into 274.
- **API** (`OrgAssurancePlanController`):
  - `GET engagement-initiation-sources`.
  - `GET engagements?organizationId=&status=&origin=&planId=&search=&page=&pageSize=`, `GET engagements/{id}` (`{ engagement, audits, team }`), `GET engagements/{id}/team?includeHistory=`.
  - `POST engagements/{id}/team { organizationId, team: [{ teamRole, employeeId?, name?, organisation? }], teamRemarks }`, `POST engagements/{id}/approve { approvalReference }`, `POST engagements/{id}/cancel { reason }`, `DELETE engagements/{id}`, `POST engagements/{id}/start-execution { organizationId, planId? }`.
  - `POST plan-items`: `planId` optional for `engagementOrigin: INDEPENDENT`; gains `auditSubject`, `engagementObjective`, `scopeSummary`, `auditee...`, `engagementInstructions`, `teamRemarks`, `team[]`, `initiationSourceCode`, `initiationReason`, `approvalReference`. Item rows gain `engagementOrigin`, `auditSubject`, `approvalStatus`, `cancelledDt`.
  - My Audits rows: `planId` may be null.
  - Reason codes AUDIT_SUBJECT_REQUIRED, SCOPE_REQUIRED, LEAD_AUDITOR_REQUIRED, INITIATION_REQUIRED, NOT_AN_AUDITOR, LEAD_LOCKED, APPROVAL_STATE, ENGAGEMENT_CLOSED, CANCEL_NOT_ALLOWED, TEAM_INVALID.
- **Web:**
  - New shared form `Partials/_audit-engagement-form.cshtml` + `js/Shared/audit-engagement-form.js` (`window.gracEngagementForm`: `open`, `openScope`, `startExecution`). The 552-565 engagement dialog code (dual list, programme, auditor and branch lists, View Scope, Start Execution) moved here from `org-assurance-plans.cshtml` (generated edit `Claude outputs/s566/web566.py`).
  - New `Partials/org-audit-engagements.cshtml`; `PracticeScreen.cs` and `Manage.cshtml` register it. Reuses the Audit Plans list / child-row styles, `pm-view-field`, `gracCheckCombo`, `gracPageActions` and `__roleHolderPicker`; no new CSS.
  - Gated by the Audit Plans feature (`screen.org-assurance-plans`).
- **Scope approval** (the spec's "versioned, immutable snapshot that replaces the freeze") was built in 563 and is unchanged.
- **Not in this phase:** an approval workflow for independent engagements beyond one Approve with a reference; changing the lead after an execution started (53955); team-based visibility in My Audits (it still lists the lead's audits).
- Generated by `Claude outputs/s566/gen566.py`. Rollback: `566_audit_engagements_record_rollback.sql` (procedures back to 553 / 555 / 565; the new procedures and functions dropped; the menu set Inactive; tables and columns kept, and the plan column stays NULLable).

"""

p = 'docs/audit-management-module.md'
rp(p, '### Deploy\nRun **543**', SECTION + '### Deploy\nRun **543**')
rp(p, '**563**, **564** and **565** -> restart the Api -> publish Web. Users sign out and back in to see the sidebar changes (549, 555 My Audits).',
      '**563**, **564**, **565** and **566** -> restart the Api -> publish Web. Users sign out and back in to see the sidebar changes (549, 555 My Audits, 566 Audit Engagements).')

p = 'docs/audit-change-p0-plan.md'
rp(p, '| F | 566 | 4.5 |', '| F (built) | 566 | 4.5 |')
rp(p, '## Phase E (565, built, 2026-11-16)', '''## Phase F (566, built, 2026-11-16)
- Decisions (sir): independent engagements are supported (plan and programme optional; initiation source, reason and the authority's approval reference mandatory) beside planned ones, one lifecycle for both; Audit Team = lead (mandatory), members, subject matter experts, reviewer, external auditors and remarks, auditors from the Auditor responsibility (553), stored against the engagement with a trail.
- Built: the engagement record (subject, objective, scope, auditee, instructions, actual dates, derived status, cancel with a reason), the team table and its trail, the Audit Engagements menu and list (child-row details), the shared engagement form (Audit Plans uses it too). Assumed and to confirm: derived status + Cancelled; full-view form; SMEs any active employee; independent executions have origin MANUAL.
- The spec's scope-approval snapshot came with 563 (C2).

## Phase E (565, built, 2026-11-16)''')
print('docs ok')
