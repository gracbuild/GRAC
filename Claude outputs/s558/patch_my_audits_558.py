import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
def rep(a, b):
    global s
    assert s.count(a) == 1, (a[:70], s.count(a))
    s = s.replace(a, b)

rep('''        Summary counts each obligation once. Read-only, same frame.
''', '''        Summary counts each obligation once. Read-only, same frame.
      * Answer Questions (558, Phase 5): the execution's questions, one
        answer each (Compliant / Not compliant / Not applicable). Not
        compliant needs a description and an owner and raises an Audit
        Finding automatically; changing it back withdraws an Open finding.
        In Progress: the assigned auditor answers; Done: View Answers,
        read-only. Same frame; one Save writes the changed answers.
''')
rep('''        GET  /practice/api/org-assurance/executions/{id}/continuous-assurance?organizationId=
''', '''        GET  /practice/api/org-assurance/executions/{id}/continuous-assurance?organizationId=
        GET  /practice/api/org-assurance/executions/{id}/responses?organizationId=
        POST /practice/api/org-assurance/executions/{id}/responses
        POST /practice-management-gateway/owners/query   (finding owner list)
''')
rep('''                    <tbody id="oaMyCaBody"></tbody>
                </table>
            </div>
        </div>''', '''                    <tbody id="oaMyCaBody"></tbody>
                </table>
            </div>
        </div>
        @* 558: the questions -- same frame. *@
        <div id="oaMyQaPane" hidden>
            <div class="oa-pl-scope-summary" id="oaMyQaSummary"></div>
            <div class="pm-table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Question</th>
                            <th style="width:180px;">Answer</th>
                            <th>Description and owner</th>
                            <th style="width:170px;">Finding</th>
                        </tr>
                    </thead>
                    <tbody id="oaMyQaBody"></tbody>
                </table>
            </div>
        </div>''')
rep('''                <button type="button" id="oaMyScopeFreeze" class="pm-button primary">
                    <i class="fa-solid fa-lock" aria-hidden="true"></i> Freeze Scope
                </button>''', '''                <button type="button" id="oaMyScopeFreeze" class="pm-button primary">
                    <i class="fa-solid fa-lock" aria-hidden="true"></i> Freeze Scope
                </button>
                <button type="button" id="oaMyQaSave" class="pm-button primary" hidden>
                    <i class="fa-solid fa-floppy-disk" aria-hidden="true"></i> Save Answers
                </button>''')
rep('''        document.getElementById('oaMyScopeFreeze').addEventListener('click', freeze);
''', '''        document.getElementById('oaMyScopeFreeze').addEventListener('click', freeze);
        document.getElementById('oaMyQaSave').addEventListener('click', saveAnswers);
        document.getElementById('oaMyQaBody').addEventListener('change', onAnswerChange);
        document.getElementById('oaMyQaBody').addEventListener('input', onAnswerChange);
''')
rep('''        // 556: Continuous Assurance over the live or frozen scope.''', '''        // 558: the questions -- answered while In Progress, read-only when Done.
        if (st === 'InProgress' && hasExec)
            items.push({ icon: 'fa-list-check', label: 'Answer Questions', action: function () { openAnswers(row, false); } });
        if (st === 'Done' && hasExec)
            items.push({ icon: 'fa-list-check', label: 'View Answers', action: function () { openAnswers(row, true); } });
        // 556: Continuous Assurance over the live or frozen scope.''')
rep('''    function showPane(which) {
        document.getElementById('oaMyScopePane').hidden = which !== 'scope';
        document.getElementById('oaMyCaPane').hidden    = which !== 'ca';
    }''', open(sys.argv[2], encoding='utf-8').read().rstrip('\n'))
open(p, 'w', encoding='utf-8', newline='').write(s)
print('patched')
