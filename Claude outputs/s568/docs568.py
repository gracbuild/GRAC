# docs568.py -- 568 docs. Run from the repo root (once).
import sys
def rp(p, o, n):
    s = open(p, encoding='utf-8').read()
    if s.count(o) != 1: sys.exit('%s: %r' % (p, o[:80]))
    open(p, 'w', encoding='utf-8', newline='').write(s.replace(o, n))

SECTION = """### Audit Reports (568, 2026-11-16, sir; P1 phase H)
Audit Change spec 4.9 (reports). One report per engagement, built in the app from the audit data.
- **Decisions (sir, 2026-11-16):** one report per **engagement** (all its executions); in-app with editable narrative sections, printed / saved as PDF from the browser; a **template** = which sections, their order, headings and standard text.
- **Assumed (to confirm):** Draft -> In Review (the lead submits; Executive Summary and Overall Conclusion written) -> Approved (the engagement Reviewer, else the lead; every execution Approved or Closed) or Returned (reason) -> Issued (the lead; data and sections frozen as that version). Revise: Issued -> Draft as version + 1 (reason); every issued version stays readable.
- **Sections (spec 4.9):** Audit Objective and Mandate (objective, subject, auditee, type, audits with their mandates); Scope and Methodology (scope, branch, department, audits with approach and items in scope, testing methods used, the team); Audit Period (planned, actual, plan, financial year, programme); Executive Summary (counts + the lead's text); Audit Coverage (per audit: questions concluded, partial, unsatisfactory, papers, score and band); Key Findings (risk rating = severity, condition, root cause, status); Management Responses (response, corrective action, owner, target date); Recommendations; Overall Audit Conclusion (each audit's conclusion + the lead's text); Approval and Issue History.
- **What the user sees (Audit Reports, menu after Observations):**
  - View **Reports**: the engagements with an execution -- Engagement, Name, Plan, Lead / Reviewer, Executions Approved, Findings, Report, Status, Issued; filters organization / view / report status, search. A row opens the report as a document in its child row; the lead edits each section's narrative and inclusion (Save Report) while Draft / Returned. 3-dot: Create Report (a template is picked, the default chosen), Open, Submit for Review, Approve, Return, Issue, Revise, Print / Save as PDF. An issued report shows its frozen data; a "Version shown" select reads earlier issued versions.
  - View **Report Templates**: Code, Template, Default, Sections, Reports, Active; a row opens the editor (name, default, active, description; per section order, heading, include, standard text). "+ Add Template". The organization's "Standard Audit Report" template (every section) is made the first time templates are read. Reports already made keep their own sections.
  - Print: the browser's print dialog with only the report (the Risk Centre's window.print() way; @media print rules on the page).
- **Data:** `org_assurance_report_section_master` (10), `org_assurance_report_template` / `_template_section`, `org_assurance_report` (one active per engagement), `_report_section`, `_report_issue` (data JSON + sections JSON per issued version), `_report_history`. `fn_org_assurance_engagement_roles` (lead / reviewer of an engagement). Procedures `sp_org_assurance_report_section_master_list`, `_report_template_list / _get / _save`, `_report_list`, `_report_create`, `_report_data_json` (the report data as one JSON document -- live, and frozen at issue), `_report_get`, `_report_section_save`, `_report_action`. Errors 54070-54079. Menu `org-audit-reports` (472, file-lines), the Audit Plans permissions copied; written back into 274.
- **API** (new `OrgAssuranceReportController` + `OrgAssuranceReportService`, registered in Program.cs): `GET report-sections`, `GET report-templates`, `GET report-templates/{id}`, `POST report-templates`, `GET reports`, `POST reports`, `GET reports/{id}?versionNo=`, `POST reports/{id}/sections`, `POST reports/{id}/action` (SUBMIT / RETURN / APPROVE / ISSUE / REVISE). Reason codes REPORT_*.
- **Web:** new `Partials/org-audit-reports.cshtml` (registered in PracticeScreen.cs and Manage.cshtml; gated by the Audit Plans feature). No shared CSS change (page-scoped report and print styles).
- **Not in this phase:** a Word / PDF file generated on the server (the browser's Save as PDF); distribution (email) of an issued report.
- Rollback: `568_audit_reports_rollback.sql` (procedures and the function dropped; menu Inactive; tables kept).

"""

p = 'docs/audit-management-module.md'
rp(p, '### Deploy\nRun **543**', SECTION + '### Deploy\nRun **543**')
rp(p, '**566** and **567** -> restart the Api -> publish Web. Users sign out and back in to see the sidebar changes (549, 555 My Audits, 566 Audit Engagements, 567 Workpapers).',
      '**566**, **567** and **568** -> restart the Api -> publish Web. Users sign out and back in to see the sidebar changes (549, 555 My Audits, 566 Audit Engagements, 567 Workpapers, 568 Audit Reports).')

p = 'docs/audit-change-p0-plan.md'
rp(p, '## Phase G (567, built, 2026-11-16)', '''## P1 (2026-11-16, sir)
| Phase | Migration | Spec | What |
|---|---|---|---|
| H (built) | 568 | 4.9 | **Audit Reports**: one per engagement, in-app from section templates (sections, order, headings, standard text), Draft -> In Review -> Approved -> Issued (frozen per version), revisions |
| I | 569 | 4.9, 4.8 | **Audit Follow-up**: corrective actions per observation as a separate audit list (not Task Board tasks -- sir), owner, target date, progress, remediation evidence, auditor validation, closure approval, overdue escalation, repeat observations; with Risk / Gap / Exception integration |
| J | 570 | 4.4 | **RBIA**: independent audit risk assessment, configurable parameters / weights / bands / frequency rules with an RBI RBIA preset |
| K | 571 | 4.10 | **Audit Committee dashboards**: plan vs actual, programme progress, coverage, findings, overdue actions, repeat findings, turnaround |
| L | 572 | 4.11 | **Audit Quality & Review**: working paper / engagement / report review, reviewer observations, independence declarations, documentation completeness, quality assessment |

Decisions (sir, 2026-11-16): report per engagement; in-app with section templates; follow-up actions as a separate audit list; RBIA configurable with an RBI preset.

## Phase G (567, built, 2026-11-16)''')
print('docs ok')
