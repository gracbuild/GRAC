# web567.py -- 567 Web: My Audits' answer grid -> Working Papers (the
# Workpapers page), the gateway navigation pair, the screen registration.
# Run from the repo root.
import sys, os, re
WEB = 'src/PracticeManagement.Web'

def load(rel):
    return open(os.path.join(WEB, rel), encoding='utf-8').read()
def save(rel, s):
    open(os.path.join(WEB, rel), 'w', encoding='utf-8', newline='').write(s)
def rep(s, old, new):
    n = s.count(old)
    if n != 1: sys.exit('count %d for %r' % (n, old[:90]))
    return s.replace(old, new)
def cut(s, start, end, new):
    if s.count(start) != 1: sys.exit('start %r' % start[:80])
    i = s.index(start); j = s.index(end, i)
    return s[:i] + new + s[j:]

# ------------------------------------------------------------------ My Audits
P = 'Views/Practice/Partials/org-my-audits.cshtml'
s = load(P)
s = rep(s, """        GET  /practice/api/org-assurance/executions/{id}/responses?organizationId=
        POST /practice/api/org-assurance/executions/{id}/responses
        POST /practice-management-gateway/owners/query   (finding owner list)
""", """        (567: the 558 responses endpoints are no longer called here --
        Working Papers opens the Workpapers page)
""")
s = rep(s, """      * Answer Questions (558, Phase 5): the execution's questions, one
        answer each (Compliant / Not compliant / Not applicable). Not
        compliant needs a description and an owner and raises an Audit
        Finding automatically; changing it back withdraws an Open finding.
        In Progress: the assigned auditor answers; Done: View Answers,
        read-only. Same frame; one Save writes the changed answers.
""", """      * Working Papers (567, replaces 558's Answer Questions): opens the
        Workpapers page on the execution (the id in the navigation code,
        gracSecureNav) -- working papers per question, review, conclusion,
        findings raised by the auditor (nothing automatic).
""")
s = cut(s, "        @* 558: the questions -- same frame. *@",
           "        <div class=\"oa-flow-nav oa-cfg-savebar\">", "")
s = rep(s, """                <button type="button" id="oaMyQaSave" class="pm-button primary" hidden>
                    <i class="fa-solid fa-floppy-disk" aria-hidden="true"></i> Save Answers
                </button>
""", "")
s = rep(s, """        document.getElementById('oaMyQaSave').addEventListener('click', saveAnswers);
        document.getElementById('oaMyQaBody').addEventListener('change', onAnswerChange);
        document.getElementById('oaMyQaBody').addEventListener('input', onAnswerChange);
""", "")
s = rep(s, """        document.getElementById('oaMyQaPane').hidden    = which !== 'qa';
        document.getElementById('oaMyQaSave').hidden    = true;   // openAnswers shows it
""", "")
s = cut(s, """    // -----------------------------------------------------------------
    // 558: Answer Questions -- the same frame.""", "    async function openCa(row) {",
"""    // -----------------------------------------------------------------
    // 567: Working Papers -- the Workpapers page on this execution; the
    // execution travels in the navigation code (never in the address).
    // -----------------------------------------------------------------
    async function openWorkpapers(row) {
        const err = await window.gracSecureNav.open('org-my-audits', 'org-workpapers', 'AssuranceExecution',
            v(row, 'executionId', 'ExecutionId'), v(row, 'organizationId', 'OrganizationId'),
            v(row, 'executionCode', 'ExecutionCode'));
        if (err) wf.setMessage('oaMyMessage', err, 'error');
    }

""")
s = rep(s, """        // 558: the questions -- answered while In Progress, read-only when Done.
        if (st === 'InProgress' && hasExec)
            items.push({ icon: 'fa-list-check', label: 'Answer Questions', action: function () { openAnswers(row, false); } });
        if (st === 'Done' && hasExec)
            items.push({ icon: 'fa-list-check', label: 'View Answers', action: function () { openAnswers(row, true); } });
""", """        // 567: the questions are tested in Workpapers (working papers
        // replace the 558 answers) -- In Progress to work, Done to read.
        if ((st === 'InProgress' || st === 'Done') && hasExec)
            items.push({ icon: 'fa-file-pen', label: 'Working Papers', action: function () { openWorkpapers(row); } });
""")
s = rep(s, "\n<script>\n(function () {", "\n<script src=\"~/js/Shared/secure-nav.js\" asp-append-version=\"true\"></script>\n<script>\n(function () {")
left = re.findall(r"oaMyQa\w*|openAnswers|saveAnswers|onAnswerChange|loadOwners|renderAnswers", s)
if left: sys.exit('left over in My Audits: %s' % sorted(set(left)))
save(P, s)
print('my audits ok')

# ------------------------------------------------------------------ gateway
G = 'Controllers/PracticeManagementGatewayController.cs'
s = load(G)
s = rep(s, """            { FilterType: "AuditDefinition", TargetArea: "org-assurance-plans" } => true,
            _ => false""", """            { FilterType: "AuditDefinition", TargetArea: "org-assurance-plans" } => true,
            // My Audits -> Workpapers (567, 2026-11-16): an audit's "Working
            // Papers" opens the Workpapers page on its execution; the
            // execution id travels in the code.
            { FilterType: "AssuranceExecution", TargetArea: "org-workpapers" } => true,
            _ => false""")
save(G, s)
print('gateway ok')

# ------------------------------------------------------------------ registration
M = 'Models/PracticeScreen.cs'
s = load(M)
s = rep(s, """        new("org-assurance-executions","Executions",""", """        // Workpapers (migration 567, spec 4.6 / 4.7): Test Working Papers per
        // question, review and approval, question conclusions, the execution
        // score and audit conclusion, findings raised from a paper.
        new("org-workpapers","Workpapers","Test working papers per question: procedure performed, sampling, results, review and approval, conclusions and findings.","file-pen",["Execution","Audit","Engagement","Status","Lead / Reviewer","My Role","Concluded","Awaiting Review","Score"], AuditManagementGroup),
        new("org-assurance-executions","Executions",""")
save(M, s)
V = 'Views/Practice/Manage.cshtml'
s = load(V)
s = rep(s, """        "org-assurance-executions",
        "org-assurance-observations",""", """        "org-assurance-executions",
        "org-workpapers",                     // 567
        "org-assurance-observations",""")
save(V, s)
print('registration ok')
