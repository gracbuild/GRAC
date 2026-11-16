# docs567.py -- 567 docs. Run from the repo root.
import sys
def rp(p, o, n):
    s = open(p, encoding='utf-8').read()
    if s.count(o) != 1: sys.exit('%s: %r' % (p, o[:80]))
    open(p, 'w', encoding='utf-8', newline='').write(s.replace(o, n))

SECTION = """### Test Working Papers, question conclusions, execution score, findings with the spec 4.7 fields (567, 2026-11-16, sir)
Audit Change spec 4.6 / 4.7, P0 phase G. Working papers replace the 558 answer grid; a question's conclusion comes from its working papers; the auditor raises findings from a working paper, and nothing raises one automatically (gaps and exceptions in scope never become findings on their own).
- **Decisions (sir, 2026-11-16):**
  - A **Workpapers** page (menu): pick an execution, its questions, each question's working papers in a child row with an inline form. My Audits' "Answer Questions" / "View Answers" became **Working Papers**, which opens this page on the execution.
  - **Test result:** Satisfactory / Partially Satisfactory / Unsatisfactory / Not Applicable. The question's conclusion defaults to the worst **approved** paper; the auditor may conclude otherwise with a reason.
  - **Review:** the engagement's Reviewer (566), or the Lead Auditor when there is none. Nobody reviews their own paper. The lead or the reviewer reopens an approved paper, with a reason.
  - **Score:** question weight x conclusion (Satisfactory 100, Partial 50, Unsatisfactory 0; Not Applicable left out), mapped to the audit version's scoring bands. The lead writes the overall audit conclusion.
- **Working paper lifecycle:** Draft (being prepared) -> Pending (submitted; needs the procedure performed, the result and the conclusion) -> Reviewed (optional) -> Approved, or Returned (reason) back to the preparer. Reopen: Approved -> Returned (reason), which clears the question's conclusion and re-scores. Draft papers can be deleted. "Draft" is the preparing state before the spec's Pending.
- **Who does what:** the team is the engagement's lead, members and subject matter experts (566). The lead assigns questions. A question is prepared by its auditor, or by anyone on the team when unassigned (the lead always). A paper is edited / submitted / deleted by its preparer or the lead. The lead or the question's auditor concludes it, once every paper is approved. Everything happens while the execution is In Progress.
- **What the user sees (Workpapers):**
  - List: organization / "My engagements | All executions" / status filters, search. Execution, Audit, Engagement, Status, Lead / Reviewer, My Role, Concluded (n / total), Awaiting Review, Score. 3-dot: Working Papers, Activity.
  - The execution's child row: a facts line (score and band, lead, reviewer, your role), the Audit Conclusion (the lead edits it), and the questions (code, question, assigned to, papers by state, conclusion from the papers, conclusion). 3-dot: Working Papers, Add Working Paper, Assign, Conclude, Activity.
  - A question's child row: the testing guidance, expected evidence and weight; its working papers (paper, method, result, review status, prepared by, reviewed / approved, finding; 3-dot View, Edit, Submit for Review, Mark Reviewed, Approve, Return, Reopen, Raise Finding, Delete); the inline form (working paper, assign, conclude or raise finding); the activity.
  - Working paper form: testing method (Inspection, Inquiry, Observation, Reperformance, Reconciliation, Analytical Review, Configuration Testing, System Testing, Sampling and Transaction Testing), sampling method, sample size, test result, testing guidance (prefilled from the question; editing it here never changes the question set), procedure performed, population, sample details, evidence references, deviations, auditor comments, conclusion; reviewer comments are read-only and kept with who / when.
  - Raise Finding (from a Partially Satisfactory / Unsatisfactory paper): title, severity, target closure date, responsible owner, description, audit criteria, condition, root cause, risk and impact, recommendation, supporting evidence. Code `<paper code>-F` (-F2 ...).
- **Observations:** a **Finding** tab (with Details / Evidence / History): origin (failed or partially satisfactory testing, control deficiency, practice deficiency, existing gap, exception, risk-related concern, manual), the working paper, criteria, condition, root cause, risk and impact, recommendation, management response, corrective action, supporting evidence. Saved on their own; read-only once Closed.
- **Executions:** Submit needs every question concluded, every paper approved and the audit conclusion written (54064).
- **Data:**
  - New `org_assurance_testing_method_master` (9), `org_assurance_observation_origin_master` (7), `org_assurance_execution_question` (an execution's questions from its frozen snapshot: testing guidance = the question's help_text, weight; assignee; conclusion, reason, who / when), `org_assurance_working_paper`, `org_assurance_execution_activity` (the history).
  - `org_assurance_execution`: score_pct, score_band_code / _name, score_refreshed_dt, audit_conclusion, conclusion_by / _dt. `org_assurance_observation`: observation_origin_code, org_assurance_working_paper_id, audit_criteria, condition_text, root_cause, risk_impact, recommendation, management_response, corrective_action, supporting_evidence.
  - Functions `fn_org_assurance_wp_roles` (lead / team / reviewer of an execution for a person), `fn_org_assurance_wp_question_state` (papers by state, the suggested conclusion).
  - Procedures `sp_org_assurance_testing_method_list`, `_observation_origin_list`, `_wp_log` (internal), `_wp_question_sync` (internal), `_execution_score_refresh` (internal), `_wp_execution_list`, `_wp_overview`, `_wp_activity_list`, `_wp_question_assign`, `_working_paper_save`, `_working_paper_action`, `_wp_question_conclude`, `_execution_conclusion_save`, `_wp_raise_finding` (through `sp_org_assurance_observation_save`, 116a), `_observation_finding_get / _save`.
  - Re-issued `sp_org_assurance_execution_transition` (099 body) with the Submit gate.
  - The 558 answers became working papers: one Approved paper per answered question (Compliant -> Satisfactory, Not compliant -> Unsatisfactory, Not applicable -> Not Applicable; the description as conclusion / deviations), the question concluded the same, the finding the answer raised linked to the paper (origin Testing); scores worked out. The 558 table and procedures are kept (old data readable); the page no longer calls them.
  - Errors 54051 (not on the team), 54052 (not In Progress), 54053 (not found), 54054 (not editable in its state), 54055 (submit incomplete), 54056 (reviewer only / own paper), 54057 (reason needed), 54058 (lead only), 54059 (assignee not on the team), 54060 (papers not all approved), 54061 (conclusion reason), 54062 (invalid value), 54063 (finding from a satisfactory paper), 54064 (execution submit incomplete), 54065 (observation closed).
  - Menu `org-workpapers` (470, file-pen) under nav-assurance, every active role (as My Audits); Observations moved to 471. Both written back into 274.
- **API** (new `OrgAssuranceWorkpaperController` + `OrgAssuranceWorkpaperService`, registered in Program.cs): `GET testing-methods`, `GET observation-origins`, `GET workpapers/executions`, `GET executions/{id}/workpapers`, `GET executions/{id}/workpaper-activity`, `POST execution-questions/{id}/assign | conclude | working-papers`, `POST working-papers/{id}/action | finding`, `POST executions/{id}/audit-conclusion`, `GET / POST observations/{id}/finding`. Reads return the procedures' rows (EvidenceCenterService's pattern). The caller is the session employee (X-PM-Caller-Employee-Id). Execution reason code WORKPAPERS_INCOMPLETE (54064).
- **Web:** new `Partials/org-workpapers.cshtml` (registered in PracticeScreen.cs and Manage.cshtml; gated by the Audit Plans feature); `org-my-audits.cshtml` (the answer pane, its Save and its code removed; Working Papers via `gracSecureNav`, filter `AssuranceExecution`, allowed in `PracticeManagementGatewayController`); `org-assurance-observations.cshtml` (Finding tab); `practice-management.css` (the `#oaMyRoot .qs-grid` rules removed with the grid). Generated edits: `Claude outputs/s567/web567.py`, `web567b.py`.
- **Not in this phase:** evidence files attached to a working paper (evidence references are text; evidence stays per question, 536); the Executions page showing the score (it is on Workpapers); configurable severities / observation workflows beyond the existing ones.
- Generated by `Claude outputs/s567/gen567.py`. Rollback: `567_audit_working_papers_rollback.sql` (the transition back to 099; the new procedures and functions dropped; the menu Inactive and Observations back to 470; tables and columns kept).

"""

p = 'docs/audit-management-module.md'
rp(p, '### Deploy\nRun **543**', SECTION + '### Deploy\nRun **543**')
rp(p, '**563**, **564**, **565** and **566** -> restart the Api -> publish Web. Users sign out and back in to see the sidebar changes (549, 555 My Audits, 566 Audit Engagements).',
      '**563**, **564**, **565**, **566** and **567** -> restart the Api -> publish Web. Users sign out and back in to see the sidebar changes (549, 555 My Audits, 566 Audit Engagements, 567 Workpapers).')

p = 'docs/audit-change-p0-plan.md'
rp(p, '| G | 567 | 4.6, 4.7 |', '| G (built) | 567 | 4.6, 4.7 |')
rp(p, '## Phase F (566, built, 2026-11-16)', '''## Phase G (567, built, 2026-11-16)
- Decisions (sir): a Workpapers page (My Audits opens it); Satisfactory / Partially Satisfactory / Unsatisfactory / Not Applicable, the question concluded from its approved papers (worst) unless a reason is given; the engagement Reviewer (else the Lead) reviews, never their own paper, and lead or reviewer reopens; score = question weight x conclusion in the audit's bands, the lead writes the audit conclusion.
- Built: working papers (several per question, Draft -> Pending -> Reviewed -> Approved / Returned, reopen), question assignment and conclusions, activity history, the execution score and audit conclusion, the Submit gate, Raise Finding with the spec 4.7 fields, the Observations Finding tab, the Workpapers menu; the 558 answers converted to approved papers.
- P0 is complete with this phase. P1 next: RBIA assessment, Audit Reports, Follow-up, Audit Committee dashboards, Quality & Review.

## Phase F (566, built, 2026-11-16)''')
print('docs ok')
