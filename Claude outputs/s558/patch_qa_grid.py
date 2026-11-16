import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', newline='').read()
def rep(a, b):
    global s
    assert s.count(a) == 1, (a[:80], s.count(a))
    s = s.replace(a, b)

# header: spreadsheet grid, Description and Owner as their own columns, no Finding column
rep('''            <div class="pm-table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th>Question</th>
                            <th style="width:180px;">Answer</th>
                            <th>Description and owner</th>
                            <th style="width:170px;">Finding</th>
                        </tr>
                    </thead>
                    <tbody id="oaMyQaBody"></tbody>''', '''            @* The Question Sets grid's spreadsheet look (.qs-grid, shared CSS):
               cells carry the lines, inputs have no border. The finding a Not
               compliant answer raised shows under its description (sir: the
               description IS the finding -- no column of its own). *@
            <div class="pm-table-wrap">
                <table class="qs-grid">
                    <thead>
                        <tr>
                            <th>Question</th>
                            <th style="width:170px;">Answer</th>
                            <th style="width:32%;">Description</th>
                            <th style="width:200px;">Owner</th>
                        </tr>
                    </thead>
                    <tbody id="oaMyQaBody"></tbody>''')

# group heading row
rep('''                head = '<tr><td colspan="4"><strong>' + wf.escape(set) + '</strong></td></tr>';''',
    '''                head = '<tr><td colspan="4" class="qs-cell-text"><strong>' + wf.escape(set) + '</strong></td></tr>';''')

# the detail / finding cells
rep('''            const nc   = res === 'NotCompliant';
            const desc = v(q, 'description', 'Description') || '';
            const detail = qa.readOnly
                ? (nc ? wf.escape(desc) + '<div style="color:var(--fg-subtle); font-size:12px;">Owner: ' + wf.escape(v(q, 'ownerDisplayName', 'OwnerDisplayName') || '') + '</div>' : '')
                : '<div data-qa-nc="' + i + '"' + (nc ? '' : ' hidden') + '>'
                  + '<textarea class="pm-input" rows="2" maxlength="4000" data-qa-desc="' + i + '" placeholder="What is not compliant" style="width:100%; min-width:0;">' + wf.escape(desc) + '</textarea>'
                  + '<select class="pm-input" data-qa-owner="' + i + '" style="width:100%; min-width:0; margin-top:6px;">' + ownerOpts + '</select>'
                  + '</div>';
            const obsCode = v(q, 'observationCode', 'ObservationCode');
            const finding = obsCode
                ? wf.escape(obsCode) + ' ' + wf.badge(v(q, 'observationStatusName', 'ObservationStatusName') || '')
                : '';''', '''            const nc   = res === 'NotCompliant';
            const desc = v(q, 'description', 'Description') || '';
            // the finding the answer raised: its code and status, under the description
            const obsCode = v(q, 'observationCode', 'ObservationCode');
            const finding = obsCode
                ? '<div class="qs-cell-text" style="padding-top:0; color:var(--fg-subtle); font-size:12px;">Finding '
                  + wf.escape(obsCode) + ' ' + wf.badge(v(q, 'observationStatusName', 'ObservationStatusName') || '') + '</div>'
                : '';
            const descCell = qa.readOnly
                ? '<td class="qs-cell-text">' + (nc ? wf.escape(desc) : '') + (obsCode ? '<div style="color:var(--fg-subtle); font-size:12px; margin-top:4px;">Finding ' + wf.escape(obsCode) + ' ' + wf.badge(v(q, 'observationStatusName', 'ObservationStatusName') || '') + '</div>' : '') + '</td>'
                : '<td><div data-qa-nc="' + i + '"' + (nc ? '' : ' hidden') + '>'
                  + '<textarea class="pm-input" rows="2" maxlength="4000" data-qa-desc="' + i + '" placeholder="What is not compliant">' + wf.escape(desc) + '</textarea>'
                  + finding + '</div></td>';
            const ownerCell = qa.readOnly
                ? '<td class="qs-cell-text">' + (nc ? wf.escape(v(q, 'ownerDisplayName', 'OwnerDisplayName') || '') : '') + '</td>'
                : '<td><div data-qa-nc-owner="' + i + '"' + (nc ? '' : ' hidden') + '>'
                  + '<select class="pm-input" data-qa-owner="' + i + '" aria-label="Owner">' + ownerOpts + '</select></div></td>';''')

# the row
rep('''            return head + '<tr>'
                 + '<td>' + wf.escape(v(q, 'questionText', 'QuestionText') || '')''', '''            return head + '<tr>'
                 + '<td class="qs-cell-text">' + wf.escape(v(q, 'questionText', 'QuestionText') || '')''')
rep('''                 + '<td>' + (qa.readOnly ? wf.badge(res ? RESULT_LABEL[res] : 'Not answered')
                           : '<select class="pm-input" data-qa-result="' + i + '" style="width:100%; min-width:0;">' + opts + '</select>') + '</td>'
                 + '<td>' + detail + '</td>'
                 + '<td>' + finding + '</td>'
                 + '</tr>';''', '''                 + (qa.readOnly ? '<td class="qs-cell-text">' + wf.badge(res ? RESULT_LABEL[res] : 'Not answered') + '</td>'
                                : '<td><select class="pm-input" data-qa-result="' + i + '" aria-label="Answer">' + opts + '</select></td>')
                 + descCell
                 + ownerCell
                 + '</tr>';''')

# show / hide both Not compliant cells
rep('''            const box = document.querySelector('[data-qa-nc="' + i + '"]');
            if (box) box.hidden = sel.value !== 'NotCompliant';''', '''            const nc = sel.value !== 'NotCompliant';
            const box = document.querySelector('[data-qa-nc="' + i + '"]');
            const own = document.querySelector('[data-qa-nc-owner="' + i + '"]');
            if (box) box.hidden = nc;
            if (own) own.hidden = nc;''')

open(p, 'w', encoding='utf-8', newline='').write(s)
print('patched')
