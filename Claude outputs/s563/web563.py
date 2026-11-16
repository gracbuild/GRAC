# web563.py -- My Audits: Step 3 Review and Confirm in the Review & Freeze
# Scope / View Scope frame. Run from src/PracticeManagement.Web.
import sys
F = 'Views/Practice/Partials/org-my-audits.cshtml'
s = open(F, encoding='utf-8').read()

def rep(a, b, n=1):
    global s
    c = s.count(a)
    if c != n:
        sys.exit('count %d != %d: %r' % (c, n, a[:90]))
    s = s.replace(a, b)

# ---------------------------------------------------------------- header comment
rep("""        POST /practice/api/org-assurance/executions/{id}/freeze-scope
    The caller""",
"""        POST /practice/api/org-assurance/executions/{id}/freeze-scope
        GET  /practice/api/org-assurance/executions/{id}/scope-review?organizationId=   (563)
    The caller""")
rep("""      * View Scope: a frozen scope and its exclusions, read-only.""",
"""      * View Scope: a frozen scope and its exclusions, read-only.
      * 563 (2026-11-15, sir) -- Scope Builder Step 3, Review and Confirm
        (Audit Change spec 4.2.1, phase C2), in the same frame under the
        scope list: "Related GRAC Intelligence" -- Step 2's discovery over
        THIS engagement's practice instances (the scope list's "Why in
        scope" column comes from it too). Per category an Include tick
        (Practice Instances are the scope list itself); open a category
        (child row, as Step 2) to untick a record -- with a reason -- or
        add a manual item; Search filters the records. Freeze sends the
        review with the exclusions and keeps it as the approved scope
        snapshot (version 1); View Scope shows that snapshot read-only.""")

# ---------------------------------------------------------------- markup
rep("""                            <th>Name</th>
                            <th id="oaMyScopeReasonHead">Reason for excluding</th>""",
"""                            <th>Name</th>
                            <th>Why in scope</th>
                            <th id="oaMyScopeReasonHead">Reason for excluding</th>""")
rep("""                    <tbody id="oaMyScopeBody"></tbody>
                </table>
            </div>
        </div>""",
"""                    <tbody id="oaMyScopeBody"></tbody>
                </table>
            </div>
            @* 563: Step 3 Review and Confirm -- the related records, the
               Step 2 category list (Include, child row per category). *@
            <div id="oaMyReview" hidden style="margin-top:16px;">
                <div class="oa-ws-section-head"><h2>Related GRAC Intelligence</h2></div>
                <p class="oa-ws-section-hint" id="oaMyReviewHint"></p>
                <div class="pm-toolbar" style="flex-wrap:wrap; gap:8px;">
                    <input id="oaMyReviewSearch" type="text" placeholder="Search related records..." />
                </div>
                <div class="pm-table-wrap oa-pl-wrap" style="margin-top:8px;">
                    <table>
                        <thead>
                            <tr>
                                <th style="width:90px;">Include</th>
                                <th>Category</th>
                                <th style="text-align:right; width:110px;">Records</th>
                                <th style="width:60px;"></th>
                            </tr>
                        </thead>
                        <tbody id="oaMyReviewBody"></tbody>
                    </table>
                </div>
            </div>
        </div>""")

# ---------------------------------------------------------------- boot wiring
rep("""        document.getElementById('oaMyScopeBody').addEventListener('change', onKeepChange);
""",
"""        document.getElementById('oaMyScopeBody').addEventListener('change', onKeepChange);
        wireReview();   // 563
""")

# ---------------------------------------------------------------- openScope: load the review too
rep("""        document.getElementById('oaMyScopeBody').innerHTML = '<tr><td colspan="5" class="pm-empty">'
            + (frozen ? 'Loading the scope...' : 'Resolving the scope...') + '</td></tr>';""",
"""        document.getElementById('oaMyScopeBody').innerHTML = '<tr><td colspan="6" class="pm-empty">'
            + (frozen ? 'Loading the scope...' : 'Resolving the scope...') + '</td></tr>';
        document.getElementById('oaMyReview').hidden = true;   // 563: shown once loaded""")
rep("""        try {
            const r = await fetch(U(API + '/executions/' + encodeURIComponent(id) + '/live-scope?organizationId=' + encodeURIComponent(org)),
                                  { credentials: 'same-origin' });
            const j = await safeJson(r);
            if (!r.ok) throw new Error((j && (j.error || j.Error)) || ('HTTP ' + r.status));
            state.scope.items = (j && (j.data || j.Data)) || [];""",
"""        try {
            // 563: the review (discovery / snapshot) loads beside the scope.
            const reviewP = loadReview(org, id);
            const r = await fetch(U(API + '/executions/' + encodeURIComponent(id) + '/live-scope?organizationId=' + encodeURIComponent(org)),
                                  { credentials: 'same-origin' });
            const j = await safeJson(r);
            if (!r.ok) throw new Error((j && (j.error || j.Error)) || ('HTTP ' + r.status));
            state.scope.items = (j && (j.data || j.Data)) || [];
            state.scope.review = await reviewP;
            if (state.scope.row !== row) return;   // closed or switched meanwhile""")
rep("""            renderScope(excl);
        } catch (err) {""",
"""            renderScope(excl);
            renderReview();
        } catch (err) {""")

# ---------------------------------------------------------------- renderScope: Why in scope column
rep("""                 + '<td>' + wf.escape(v(it, 'entityName', 'EntityName') || '') + '</td>'
                 + '<td>' + (frozen ? '' : '<input class="pm-input" type="text" maxlength="1000" data-reason="' + i""",
"""                 + '<td>' + wf.escape(v(it, 'entityName', 'EntityName') || '') + '</td>'
                 + '<td class="qs-cell-text">' + wf.escape(whyInScope(it)) + '</td>'
                 + '<td>' + (frozen ? '' : '<input class="pm-input" type="text" maxlength="1000" data-reason="' + i""")
rep("""                 + '<td>' + wf.escape(v(x, 'entityName', 'EntityName') || '') + '</td>'
                 + '<td>' + wf.escape(v(x, 'reason', 'Reason') || '') + '</td>'""",
"""                 + '<td>' + wf.escape(v(x, 'entityName', 'EntityName') || '') + '</td>'
                 + '<td></td>'
                 + '<td>' + wf.escape(v(x, 'reason', 'Reason') || '') + '</td>'""")
rep("""            : '<tr><td colspan="5" class="pm-empty">' + (frozen ? 'Nothing in scope.'""",
"""            : '<tr><td colspan="6" class="pm-empty">' + (frozen ? 'Nothing in scope.'""")

# ---------------------------------------------------------------- freeze: send the review
rep("""        const keep = state.scope.items.length - excl.length;
        if (keep <= 0) { wf.setMessage('oaMyScopeMessage', 'Keep at least one item in scope.', 'error'); return; }""",
"""        const keep = state.scope.items.length - excl.length;
        if (keep <= 0) { wf.setMessage('oaMyScopeMessage', 'Keep at least one item in scope.', 'error'); return; }
        // 563: Step 3 -- the review goes with the exclusions.
        const review = reviewPayload();
        if (review && review.missing) {
            wf.setMessage('oaMyScopeMessage', 'Give the reason for every related record you untick.', 'error'); return;
        }""")
rep("""                body: JSON.stringify({ organizationId: Number(v(row, 'organizationId', 'OrganizationId')), exclusions: excl, actor: null })""",
"""                body: JSON.stringify({ organizationId: Number(v(row, 'organizationId', 'OrganizationId')), exclusions: excl, actor: null,
                                       review: review ? review.body : null })""")
rep("""            wf.setMessage('oaMyMessage', 'Scope frozen: ' + (j.executionCode || j.ExecutionCode || '') + ', '
                + (j.totalEntityCount ?? j.TotalEntityCount ?? keep) + ' item(s). The audit is in progress.', 'ok');""",
"""            const rvNo = j.reviewVersionNo ?? j.ReviewVersionNo;
            wf.setMessage('oaMyMessage', 'Scope frozen: ' + (j.executionCode || j.ExecutionCode || '') + ', '
                + (j.totalEntityCount ?? j.TotalEntityCount ?? keep) + ' item(s)'
                + (rvNo != null ? '; approved scope version ' + rvNo : '') + '. The audit is in progress.', 'ok');""")

# ---------------------------------------------------------------- the review code (before mountFrame)
rep("""    // The frame in a row under the audit's row (Audit Configuration's""",
r"""    // -----------------------------------------------------------------
    // 563: Scope Builder Step 3 -- Review and Confirm. The related records
    // of the engagement's scope (Step 2's discovery over its instances),
    // in Step 2's category list. Live: Include per category, untick a
    // record with a reason, add manual items; Freeze sends it. Frozen: the
    // approved snapshot, read-only. Practice Instances are the scope list
    // above, so they are not repeated here -- they give its "Why in scope".
    // -----------------------------------------------------------------
    const SCOPE_CATEGORY = 'PRACTICE_INSTANCE';
    const MANUAL_CATEGORY = 'MANUAL';

    async function loadReview(org, id) {
        try {
            const r = await fetch(U(API + '/executions/' + encodeURIComponent(id) + '/scope-review?organizationId=' + encodeURIComponent(org)),
                                  { credentials: 'same-origin' });
            const j = await safeJson(r);
            if (!r.ok) throw new Error((j && (j.error || j.Error)) || ('HTTP ' + r.status));
            const header = (j && (j.header || j.Header)) || {};
            return {
                header     : header,
                categories : (j && (j.categories || j.Categories)) || [],
                items      : (j && (j.items || j.Items)) || [],
                open       : null,
                search     : '',
                unkept     : {},    // 'CAT|recordId' -> reason (live)
                manual     : []     // [{ categoryCode, name, note }] (live)
            };
        } catch (err) {
            // The review is an addition: without it (563 not deployed, or
            // discovery failed) the scope list still freezes as before.
            console.warn('[my-audits] scope review not available:', err);
            return null;
        }
    }

    function whyInScope(it) {
        const rv = state.scope.review;
        if (!rv || v(it, 'dimensionCode', 'DimensionCode') !== SCOPE_CATEGORY) return '';
        const id = v(it, 'entityId', 'EntityId');
        const hit = rv.items.find(function (x) {
            return v(x, 'categoryCode', 'CategoryCode') === SCOPE_CATEGORY && String(v(x, 'recordId', 'RecordId')) === String(id);
        });
        return hit ? (v(hit, 'reason', 'Reason') || '') : '';
    }

    function reviewLive() {
        const rv = state.scope.review;
        return !!rv && !state.scope.frozen && !v(rv.header, 'isFrozen', 'IsFrozen');
    }

    function reviewCategories() {
        const rv = state.scope.review;
        return rv ? rv.categories.filter(function (c) { return v(c, 'categoryCode', 'CategoryCode') !== SCOPE_CATEGORY; }) : [];
    }

    function reviewRecords(code) {
        const rv = state.scope.review;
        const q  = rv.search;
        const rows = rv.items.filter(function (x) { return v(x, 'categoryCode', 'CategoryCode') === code; })
            .map(function (x) {
                return { code: v(x, 'recordCode', 'RecordCode') || '', name: v(x, 'recordName', 'RecordName') || '',
                         status: v(x, 'status', 'Status') || '', reason: v(x, 'reason', 'Reason') || '',
                         id: v(x, 'recordId', 'RecordId'), kept: !!v(x, 'isKept', 'IsKept'),
                         exclusion: v(x, 'exclusionReason', 'ExclusionReason') || '',
                         manual: !!v(x, 'isManual', 'IsManual'), note: v(x, 'manualNote', 'ManualNote') || '' };
            })
            .concat(rv.manual.map(function (m, i) {
                return m.categoryCode === code
                    ? { code: '', name: m.name, status: '', reason: 'Added by the auditor', id: null, kept: true,
                        exclusion: '', manual: true, note: m.note, newIndex: i }
                    : null;
            }).filter(Boolean));
        if (!q) return rows;
        return rows.filter(function (r) {
            return [r.code, r.name, r.status, r.reason, r.note].join(' ').toLowerCase().indexOf(q) >= 0;
        });
    }

    function renderReview() {
        const rv   = state.scope.review;
        const host = document.getElementById('oaMyReview');
        if (!rv) { host.hidden = true; return; }
        host.hidden = false;
        const live = reviewLive();
        const h    = rv.header || {};
        const ver  = v(h, 'versionNo', 'VersionNo');
        const by   = v(h, 'approvedBy', 'ApprovedBy');
        const dt   = onlyDate(v(h, 'approvedDt', 'ApprovedDt'));
        document.getElementById('oaMyReviewHint').textContent = live
            ? 'What this engagement\'s scope leads to in GRAC, and why. Untick a category or a record that does not apply '
              + '(a record needs the reason), add manual items, then freeze: the result is kept as the approved scope.'
            : (ver != null
                ? 'The approved scope, version ' + ver + (by ? ', approved by ' + by : '') + (dt ? ' on ' + dt : '') + '. Read-only.'
                : 'No review was recorded for this scope: it was frozen before the review step.');
        document.getElementById('oaMyReviewSearch').value = rv.search;
        const cats = reviewCategories();
        const body = document.getElementById('oaMyReviewBody');
        if (!live && ver == null) {
            body.innerHTML = '<tr><td colspan="4" class="pm-empty">Nothing to show.</td></tr>';
            return;
        }
        body.innerHTML = cats.map(function (c) {
            const code  = v(c, 'categoryCode', 'CategoryCode');
            const name  = v(c, 'categoryName', 'CategoryName') || code;
            const inc   = !!v(c, 'isIncluded', 'IsIncluded');
            const all   = rv.items.filter(function (x) { return v(x, 'categoryCode', 'CategoryCode') === code; }).length
                        + rv.manual.filter(function (m) { return m.categoryCode === code; }).length;
            const shown = rv.search ? reviewRecords(code).length : all;
            const open  = rv.open === code;
            return '<tr data-rcat="' + wf.escape(code) + '"' + (open ? ' class="oa-pl-open is-selected"' : '') + ' style="cursor:pointer;">'
                 + '<td><input type="checkbox" data-rinclude="' + wf.escape(code) + '"' + (inc ? ' checked' : '')
                 +      (live ? '' : ' disabled') + ' aria-label="Include ' + wf.escape(name) + '" /></td>'
                 + '<td>' + wf.escape(name) + (inc ? '' : ' <span style="color:var(--fg-subtle);">(not included)</span>') + '</td>'
                 + '<td style="text-align:right;">' + (rv.search ? shown + ' of ' + all : all) + '</td>'
                 + '<td style="text-align:center;"><i class="fa-solid ' + (open ? 'fa-chevron-up' : 'fa-chevron-down') + '" aria-hidden="true"></i></td>'
                 + '</tr>'
                 + (open ? reviewChildRow(code, inc, live) : '');
        }).join('') || '<tr><td colspan="4" class="pm-empty">Nothing related was found.</td></tr>';
    }

    // The Audit Plans child row, as Step 2: tr.oa-pl-items-row > td > .oa-pl-items.
    function reviewChildRow(code, included, live) {
        const rv   = state.scope.review;
        const rows = reviewRecords(code);
        const editable = live && included;
        const head = '<tr>' + (live ? '<th style="width:60px;">Keep</th>' : '')
                   + '<th>Code</th><th>Name</th><th>Status</th><th>Why it is related</th>'
                   + '<th>' + (live ? 'Reason for excluding / note' : 'Excluded because / note') + '</th>'
                   + (live ? '<th style="width:50px;"></th>' : '') + '</tr>';
        const lines = rows.map(function (r) {
            const key = code + '|' + r.id;
            const unkept = !r.manual && Object.prototype.hasOwnProperty.call(rv.unkept, key);
            const kept = live ? !unkept : r.kept;
            const keepCell = live
                ? '<td>' + (r.manual ? '' : '<input type="checkbox" data-rkeep="' + wf.escape(key) + '"' + (kept ? ' checked' : '')
                       + (editable ? '' : ' disabled') + ' aria-label="Keep">') + '</td>'
                : '';
            const last = r.manual
                ? '<td class="qs-cell-text">' + wf.escape(r.note) + '</td>'
                : (live
                    ? '<td>' + (unkept ? '<input class="pm-input" type="text" maxlength="1000" data-rreason="' + wf.escape(key)
                        + '" value="' + wf.escape(rv.unkept[key]) + '" placeholder="Why it does not apply" style="min-width:0; width:100%;">' : '') + '</td>'
                    : '<td class="qs-cell-text">' + wf.escape(kept ? '' : r.exclusion) + '</td>');
            const del = live
                ? '<td>' + (r.manual && r.newIndex != null
                    ? '<button type="button" class="pm-button icon" data-rdel="' + r.newIndex + '" title="Remove"><i class="fa-solid fa-xmark" aria-hidden="true"></i></button>'
                    : '') + '</td>'
                : '';
            return '<tr' + (kept ? '' : ' style="color:var(--fg-subtle);"') + '>' + keepCell
                 + '<td>' + wf.escape(r.code) + '</td>'
                 + '<td>' + wf.escape(r.name) + (r.manual ? ' ' + wf.badge('Manual') : '') + '</td>'
                 + '<td>' + wf.escape(r.status) + '</td>'
                 + '<td class="qs-cell-text">' + wf.escape(r.reason) + '</td>'
                 + last + del + '</tr>';
        }).join('');
        const cols = live ? 7 : 5;
        const add = editable
            ? '<tr><td colspan="' + (cols - 4) + '"></td>'
              + '<td colspan="2"><input class="pm-input" type="text" maxlength="400" data-rnew-name="' + wf.escape(code)
              + '" placeholder="Manual item" style="min-width:0; width:100%;"></td>'
              + '<td><input class="pm-input" type="text" maxlength="1000" data-rnew-note="' + wf.escape(code)
              + '" placeholder="Note" style="min-width:0; width:100%;"></td>'
              + '<td><button type="button" class="pm-button" data-radd="' + wf.escape(code) + '">Add</button></td></tr>'
            : '';
        const inner = (rows.length || add)
            ? '<div class="pm-table-wrap"><table><thead>' + head + '</thead><tbody>'
              + (lines || '<tr><td colspan="' + cols + '" class="pm-empty">' + (rv.search ? 'No records match the search.' : 'No related records.') + '</td></tr>')
              + add + '</tbody></table></div>'
            : '<div class="pm-empty" style="padding:8px 0;">' + (rv.search ? 'No records match the search.' : 'No related records.') + '</div>';
        return '<tr class="oa-pl-items-row is-selected"><td colspan="4"><div class="oa-pl-items">' + inner + '</div></td></tr>';
    }

    function wireReview() {
        const body = document.getElementById('oaMyReviewBody');
        document.getElementById('oaMyReviewSearch').addEventListener('input', function (e) {
            if (!state.scope.review) return;
            state.scope.review.search = e.target.value.trim().toLowerCase();
            renderReview();
            const box = document.getElementById('oaMyReviewSearch');
            box.focus();
            box.setSelectionRange(box.value.length, box.value.length);
        });
        body.addEventListener('click', function (e) {
            const rv = state.scope.review;
            if (!rv) return;
            const add = e.target.closest('[data-radd]');
            if (add) {
                const code = add.getAttribute('data-radd');
                const nameEl = body.querySelector('[data-rnew-name="' + code + '"]');
                const noteEl = body.querySelector('[data-rnew-note="' + code + '"]');
                const name = (nameEl && nameEl.value || '').trim();
                if (!name) { wf.setMessage('oaMyScopeMessage', 'Give the manual item a name.', 'error'); if (nameEl) nameEl.focus(); return; }
                rv.manual.push({ categoryCode: code, name: name, note: (noteEl && noteEl.value || '').trim() });
                wf.setMessage('oaMyScopeMessage', '');
                renderReview();
                updateHint();
                return;
            }
            const del = e.target.closest('[data-rdel]');
            if (del) {
                rv.manual.splice(Number(del.getAttribute('data-rdel')), 1);
                renderReview();
                updateHint();
                return;
            }
            if (e.target.closest('input, button')) return;
            const tr = e.target.closest('tr[data-rcat]');
            if (!tr) return;
            const code = tr.getAttribute('data-rcat');
            rv.open = rv.open === code ? null : code;
            renderReview();
        });
        body.addEventListener('change', function (e) {
            const rv = state.scope.review;
            if (!rv || !reviewLive()) return;
            const inc = e.target.closest('[data-rinclude]');
            if (inc) {
                const code = inc.getAttribute('data-rinclude');
                rv.categories.forEach(function (c) {
                    if (v(c, 'categoryCode', 'CategoryCode') === code) { c.isIncluded = inc.checked; c.IsIncluded = inc.checked; }
                });
                renderReview();
                updateHint();
                return;
            }
            const keep = e.target.closest('[data-rkeep]');
            if (keep) {
                const key = keep.getAttribute('data-rkeep');
                if (keep.checked) delete rv.unkept[key]; else rv.unkept[key] = '';
                renderReview();
                if (!keep.checked) {
                    const box = body.querySelector('[data-rreason="' + key + '"]');
                    if (box) box.focus();
                }
                updateHint();
            }
        });
        body.addEventListener('input', function (e) {
            const rv = state.scope.review;
            const box = e.target.closest('[data-rreason]');
            if (rv && box) rv.unkept[box.getAttribute('data-rreason')] = box.value;
        });
    }

    // { body: { categories, excluded, manual }, missing } -- null without a review.
    function reviewPayload() {
        const rv = state.scope.review;
        if (!reviewLive()) return null;
        let missing = false;
        const excluded = Object.keys(rv.unkept).map(function (key) {
            const at = key.indexOf('|');
            const reason = (rv.unkept[key] || '').trim();
            if (!reason) missing = true;
            return { categoryCode: key.slice(0, at), recordId: Number(key.slice(at + 1)), reason: reason };
        });
        return {
            missing: missing,
            body: {
                categories: rv.categories.map(function (c) {
                    return { code: v(c, 'categoryCode', 'CategoryCode'), isIncluded: !!v(c, 'isIncluded', 'IsIncluded') };
                }),
                excluded: excluded,
                manual: rv.manual.map(function (m) { return { categoryCode: m.categoryCode, name: m.name, note: m.note || null }; })
            }
        };
    }

    // The frame in a row under the audit's row (Audit Configuration's""")

# ---------------------------------------------------------------- hint: review counts
rep("""        document.getElementById('oaMyFrameHint').textContent =
            (all - out) + ' of ' + all + ' item(s) kept' + (out ? ', ' + out + ' excluded' : '');""",
"""        const rv = reviewLive() ? state.scope.review : null;   // 563
        const rOut = rv ? Object.keys(rv.unkept).length : 0;
        const rMan = rv ? rv.manual.length : 0;
        document.getElementById('oaMyFrameHint').textContent =
            (all - out) + ' of ' + all + ' item(s) kept' + (out ? ', ' + out + ' excluded' : '')
            + (rOut ? '; ' + rOut + ' related record(s) unticked' : '')
            + (rMan ? '; ' + rMan + ' manual item(s)' : '');""")

# closeScope resets the review
rep("""        state.scope = { row: null, key: null, items: [], frozen: false };
        document.getElementById('oaMyScopeFreeze').disabled = false;""",
"""        state.scope = { row: null, key: null, items: [], frozen: false, review: null };
        document.getElementById('oaMyScopeFreeze').disabled = false;
        document.getElementById('oaMyReview').hidden = true;   // 563""")

open(F, 'w', encoding='utf-8').write(s)
print('web563 ok')
