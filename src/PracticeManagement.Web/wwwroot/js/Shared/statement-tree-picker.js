// =====================================================================
// window.gracStatementTreePicker -- two-list Source Statement picker
// (migration 534, 2026-11-13).
//
// Sir: "control select cheyyumbo framework --> release --> source
// structure --> source statement tree structure lu vannu selected and
// not selected 2 view aki >, >>, <, << buttons vachu angotum ingotum
// select and deselect cheyyan pattunna pole akkan patto?"
//
// Used by the Audit Scope Builder (org-assurance-scope-builder.cshtml)
// for the SOURCE_STATEMENT dimension, in both Simple and Advanced mode.
//
// LAYOUT
//   The Question Sets adoption dual list's own grid and buttons
//   (.oa-adopt-grid / .oa-adopt-label / .oa-adopt-actions, practice-
//   management.css) with the two <select> boxes replaced by trees
//   (.oa-stmt-tree). Move buttons are icon-only, as on every GRAC dual
//   list: > moves the marked items, >> everything shown, < and << back.
//
// INTERACTION
//   Click a framework, release, structure or statement to mark it
//   (click again to unmark); > then moves every statement under the
//   marked nodes. Double-click a statement to move it at once. The
//   caret opens and closes a level. Each side has its own search, which
//   filters statements (by code, title or structure) and opens the
//   matching branches; >> and << move what the search shows.
//
// DATA
//   GET /practice/api/org-assurance/scope-statement-tree?organizationId=
//   (sp_org_assurance_scope_statement_tree). One row per statement:
//   framework / release / structure keys and names, StatementId
//   (org_statement_id -- the value stored for the dimension) and
//   InstanceCount (practice instances it resolves to). Cached per
//   organisation, the promise held so two attaches share one request.
//   A selected statement that is no longer in the tree (retired, or its
//   subscription ended) is kept and shown under "No longer available",
//   so opening and saving a scope never drops a pick silently.
//
// CONTRACT
//   const p = window.gracStatementTreePicker.attach({
//       host,            // element
//       organizationId,  // required
//       selected,        // [{ entityId, entityCode, entityName }]
//       readOnly,        // bool
//       onChange,        // fn(selectedArray) -- same item shape
//       selectedInfo     // optional: the line under the selected list
//                        // (564: Control and Practice Mapping says what a
//                        // mapping means; default: the scope wording)
//   });
//   p.getSelected(); p.destroy();
// =====================================================================
(function () {
    'use strict';
    if (window.gracStatementTreePicker) return;

    const API = '/practice/api/org-assurance/scope-statement-tree';
    const U = function (p) { return String(window.appBasePath || window.pmPathBase || '').replace(/\/+$/, '') + p; };
    const esc = function (v) {
        return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
        });
    };
    const pick = function (o, a, b) { return o[a] != null ? o[a] : o[b]; };

    const cache = Object.create(null);   // orgId -> Promise<rows>

    function loadRows(orgId) {
        const key = String(orgId);
        if (cache[key]) return cache[key];
        cache[key] = fetch(U(API + '?organizationId=' + encodeURIComponent(orgId)), { credentials: 'same-origin' })
            .then(function (r) {
                if (!r.ok) throw new Error('HTTP ' + r.status);
                return r.json();
            })
            .then(function (b) {
                return ((b && (b.data || b.Data)) || []).map(function (r) {
                    return {
                        fwKey   : String(pick(r, 'frameworkKey', 'FrameworkKey') || ''),
                        fwName  : pick(r, 'frameworkName', 'FrameworkName') || '',
                        relKey  : String(pick(r, 'releaseKey', 'ReleaseKey') || ''),
                        relName : pick(r, 'releaseName', 'ReleaseName') || '',
                        stKey   : String(pick(r, 'structureKey', 'StructureKey') || ''),
                        stName  : pick(r, 'structureName', 'StructureName') || '',
                        id      : Number(pick(r, 'statementId', 'StatementId')),
                        code    : pick(r, 'statementCode', 'StatementCode') || '',
                        name    : pick(r, 'statementName', 'StatementName') || '',
                        count   : Number(pick(r, 'instanceCount', 'InstanceCount') || 0)
                    };
                });
            })
            .catch(function (err) { delete cache[key]; throw err; });
        return cache[key];
    }

    function attach(opts) {
        opts = opts || {};
        const host = opts.host;
        if (!host) return null;
        const readOnly = !!opts.readOnly;

        // Selected statements, by id, in the order they were picked.
        const selected = new Map();
        (opts.selected || []).forEach(function (v) {
            const id = Number(v.entityId);
            if (Number.isFinite(id)) selected.set(id, { entityId: id, entityCode: v.entityCode || null, entityName: v.entityName || null });
        });

        let rows = [];
        const byId = new Map();
        const side = {
            a: { marked: new Set(), open: new Set(), search: '', touched: false },
            s: { marked: new Set(), open: new Set(), search: '', touched: false }
        };

        host.innerHTML =
              '<div class="oa-adopt-grid oa-stmt-picker' + (readOnly ? ' is-readonly' : '') + '">'
            +   '<span class="oa-adopt-label oa-adopt-a-label">Available statements <span class="pm-badge" data-r="acount">0</span></span>'
            +   '<span class="oa-adopt-label oa-adopt-s-label">Selected for this audit <span class="pm-badge" data-r="scount">0</span></span>'
            +   '<div class="oa-adopt-a-box oa-stmt-side">'
            +     '<input class="pm-input" type="text" data-search="a" placeholder="Search statements..." aria-label="Search available statements" />'
            +     '<div class="oa-stmt-tree" data-tree="a" role="tree" aria-label="Available statements"><div class="oa-stmt-empty">Loading statements...</div></div>'
            +   '</div>'
            +   '<div class="oa-adopt-actions oa-adopt-move">'
            +     '<button type="button" class="pm-button" data-move="add" title="Add the marked statements" aria-label="Add the marked statements"><i class="fa-solid fa-angle-right" aria-hidden="true"></i></button>'
            +     '<button type="button" class="pm-button" data-move="addAll" title="Add every statement shown" aria-label="Add every statement shown"><i class="fa-solid fa-angles-right" aria-hidden="true"></i></button>'
            +     '<button type="button" class="pm-button" data-move="remove" title="Remove the marked statements" aria-label="Remove the marked statements"><i class="fa-solid fa-angle-left" aria-hidden="true"></i></button>'
            +     '<button type="button" class="pm-button" data-move="removeAll" title="Remove every statement shown" aria-label="Remove every statement shown"><i class="fa-solid fa-angles-left" aria-hidden="true"></i></button>'
            +   '</div>'
            +   '<div class="oa-adopt-s-box oa-stmt-side">'
            +     '<input class="pm-input" type="text" data-search="s" placeholder="Search selected..." aria-label="Search selected statements" />'
            +     '<div class="oa-stmt-tree" data-tree="s" role="tree" aria-label="Selected statements"></div>'
            +   '</div>'
            +   '<div class="oa-adopt-a-hint"><p class="oa-adopt-hint">Click a framework, release, structure or statement to mark it, then &gt;. &gt;&gt; adds everything shown. Double-click a statement to move it.</p></div>'
            +   '<div class="oa-adopt-s-hint"><p class="oa-adopt-hint" data-r="sinfo"></p></div>'
            + '</div>';

        const el = function (sel) { return host.querySelector(sel); };
        const trees = { a: el('[data-tree="a"]'), s: el('[data-tree="s"]') };

        // Read-only (version not Draft): browse and search, no moves.
        if (readOnly) host.querySelectorAll('[data-move]').forEach(function (b) { b.disabled = true; });

        // ---- events --------------------------------------------------
        host.querySelectorAll('[data-search]').forEach(function (inp) {
            inp.addEventListener('input', function () {
                const k = inp.getAttribute('data-search');
                side[k].search = inp.value;
                side[k].marked.clear();
                render(k);
            });
        });
        host.querySelectorAll('[data-move]').forEach(function (b) {
            b.addEventListener('click', function () { move(b.getAttribute('data-move')); });
        });
        ['a', 's'].forEach(function (k) {
            trees[k].addEventListener('click', function (e) {
                const node = e.target.closest('.oa-stmt-node');
                if (!node) return;
                const key = node.getAttribute('data-key');
                if (e.target.closest('[data-caret]')) {
                    side[k].touched = true;
                    if (side[k].open.has(key)) side[k].open.delete(key); else side[k].open.add(key);
                    render(k);
                    return;
                }
                if (readOnly) return;
                if (side[k].marked.has(key)) side[k].marked.delete(key); else side[k].marked.add(key);
                node.classList.toggle('is-marked');
                node.setAttribute('aria-selected', String(side[k].marked.has(key)));
            });
            trees[k].addEventListener('dblclick', function (e) {
                if (readOnly) return;
                const node = e.target.closest('.oa-stmt-node[data-stmt]');
                if (!node) return;
                const id = Number(node.getAttribute('data-stmt'));
                if (k === 'a') add([id]); else remove([id]);
            });
        });

        // ---- data ----------------------------------------------------
        loadRows(opts.organizationId)
            .then(function (r) {
                rows = r;
                rows.forEach(function (x) { byId.set(x.id, x); });
                // Fill in names for picks saved before the tree knew them.
                selected.forEach(function (v, id) {
                    const x = byId.get(id);
                    if (x) { v.entityCode = x.code || v.entityCode; v.entityName = x.name || v.entityName; }
                });
                renderAll();
            })
            .catch(function (err) {
                trees.a.innerHTML = '<div class="oa-stmt-empty">Statements could not be loaded: ' + esc(err.message || err) + '</div>';
                renderAll(true);
            });

        // ---- model -------------------------------------------------------
        // Rows on a side: the available side holds every statement not
        // selected; the selected side holds the selected ones, plus a
        // "No longer available" branch for picks the tree no longer has.
        function rowsFor(k) {
            if (k === 'a') return rows.filter(function (x) { return !selected.has(x.id); });
            const out = rows.filter(function (x) { return selected.has(x.id); });
            selected.forEach(function (v, id) {
                if (!byId.has(id)) out.push({
                    fwKey: 'X', fwName: 'No longer available', relKey: 'X', relName: 'Retired or unsubscribed',
                    stKey: 'X', stName: 'Statements', id: id, code: v.entityCode || '', name: v.entityName || ('#' + id), count: 0
                });
            });
            return out;
        }

        function matches(x, q) {
            if (!q) return true;
            return (x.code + ' ' + x.name + ' ' + x.stName).toLowerCase().indexOf(q) >= 0;
        }

        // Builds framework -> release -> structure -> statements from rows,
        // keeping the order rows arrive in (the procedure's order).
        function tree(list) {
            const fws = [], fwMap = new Map();
            list.forEach(function (x) {
                let fw = fwMap.get(x.fwKey);
                if (!fw) { fw = { key: 'F|' + x.fwKey, name: x.fwName, kids: [], map: new Map() }; fwMap.set(x.fwKey, fw); fws.push(fw); }
                let rel = fw.map.get(x.relKey);
                if (!rel) { rel = { key: 'R|' + x.relKey, name: x.relName, kids: [], map: new Map() }; fw.map.set(x.relKey, rel); fw.kids.push(rel); }
                let st = rel.map.get(x.stKey);
                if (!st) { st = { key: 'S|' + x.stKey, name: x.stName, stmts: [] }; rel.map.set(x.stKey, st); rel.kids.push(st); }
                st.stmts.push(x);
            });
            return fws;
        }

        // Statement ids under a node key, limited to what the side shows.
        function idsUnder(k, key) {
            const q = side[k].search.trim().toLowerCase();
            const prefix = key.charAt(0), val = key.slice(2);
            return rowsFor(k).filter(function (x) {
                if (!matches(x, q)) return false;
                if (prefix === 'F') return x.fwKey === val;
                if (prefix === 'R') return x.relKey === val;
                if (prefix === 'S') return x.stKey === val;
                return String(x.id) === val;
            }).map(function (x) { return x.id; });
        }

        // ---- moves -------------------------------------------------------
        function move(kind) {
            if (readOnly) return;
            const k = (kind === 'add' || kind === 'addAll') ? 'a' : 's';
            let ids = [];
            if (kind === 'addAll' || kind === 'removeAll') {
                const q = side[k].search.trim().toLowerCase();
                ids = rowsFor(k).filter(function (x) { return matches(x, q); }).map(function (x) { return x.id; });
            } else {
                side[k].marked.forEach(function (key) { ids = ids.concat(idsUnder(k, key)); });
            }
            if (!ids.length) return;
            if (k === 'a') add(ids); else remove(ids);
        }

        function add(ids) {
            ids.forEach(function (id) {
                if (selected.has(id)) return;
                const x = byId.get(id);
                selected.set(id, { entityId: id, entityCode: x ? x.code || null : null, entityName: x ? x.name || null : null });
            });
            side.a.marked.clear();
            changed();
        }

        function remove(ids) {
            ids.forEach(function (id) { selected.delete(id); });
            side.s.marked.clear();
            changed();
        }

        function changed() {
            renderAll();
            if (typeof opts.onChange === 'function') opts.onChange(getSelected());
        }

        function getSelected() { return Array.from(selected.values()).map(function (v) { return Object.assign({}, v); }); }

        // ---- render ------------------------------------------------------
        function renderAll(failed) {
            if (!failed) render('a');
            render('s');
        }

        function render(k) {
            const q = side[k].search.trim().toLowerCase();
            const all = rowsFor(k);
            const list = all.filter(function (x) { return matches(x, q); });
            const st = side[k];
            // First render: open frameworks and releases. A search opens
            // every branch it matches.
            const fws = tree(list);
            if (!st.touched) fws.forEach(function (fw) {
                st.open.add(fw.key);
                fw.kids.forEach(function (rel) { st.open.add(rel.key); if (k === 's') rel.kids.forEach(function (s) { st.open.add(s.key); }); });
            });
            const isOpen = function (key) { return !!q || st.open.has(key); };

            const html = [];
            const line = function (key, level, label, count, hasKids, extra) {
                const open = isOpen(key);
                html.push('<div class="oa-stmt-node' + (st.marked.has(key) ? ' is-marked' : '') + (extra && extra.empty ? ' is-empty' : '') + '"'
                    + ' role="treeitem" aria-level="' + (level + 1) + '" aria-selected="' + st.marked.has(key) + '"'
                    + (hasKids ? ' aria-expanded="' + open + '"' : '')
                    + ' data-key="' + esc(key) + '" data-level="' + level + '"'
                    + (extra && extra.stmt != null ? ' data-stmt="' + esc(extra.stmt) + '"' : '')
                    + (extra && extra.title ? ' title="' + esc(extra.title) + '"' : '')
                    + ' style="padding-left:' + (6 + level * 16) + 'px;">'
                    + (hasKids
                        ? '<button type="button" class="oa-stmt-caret" data-caret tabindex="-1" aria-label="' + (open ? 'Collapse' : 'Expand') + '"><i class="fa-solid fa-chevron-' + (open ? 'down' : 'right') + '" aria-hidden="true"></i></button>'
                        : '<span class="oa-stmt-caret" aria-hidden="true"></span>')
                    + '<span class="oa-stmt-label">' + label + '</span>'
                    + (count != null ? '<span class="oa-stmt-count">' + count + '</span>' : '')
                    + '</div>');
                return open;
            };

            fws.forEach(function (fw) {
                const fwCount = fw.kids.reduce(function (n, r) { return n + r.kids.reduce(function (m, s) { return m + s.stmts.length; }, 0); }, 0);
                if (!line(fw.key, 0, esc(fw.name), fwCount, true)) return;
                fw.kids.forEach(function (rel) {
                    const relCount = rel.kids.reduce(function (m, s) { return m + s.stmts.length; }, 0);
                    if (!line(rel.key, 1, esc(rel.name), relCount, true)) return;
                    rel.kids.forEach(function (s) {
                        if (!line(s.key, 2, esc(s.name), s.stmts.length, true)) return;
                        s.stmts.forEach(function (x) {
                            const label = (x.code ? '<strong>' + esc(x.code) + '</strong> ' : '') + esc(x.name);
                            line('T|' + x.id, 3, label, null, false, {
                                stmt: x.id,
                                empty: x.count === 0 && x.fwKey !== 'X',
                                title: x.fwKey === 'X' ? 'This statement is no longer in the organisation’s subscribed frameworks.'
                                     : x.count === 0 ? 'No practice instance is mapped to this statement yet.'
                                     : x.count + ' practice instance' + (x.count === 1 ? '' : 's')
                            });
                        });
                    });
                });
            });

            trees[k].innerHTML = html.length ? html.join('')
                : '<div class="oa-stmt-empty">' + (q ? 'No matches.'
                    : k === 'a' ? (rows.length ? 'Every statement is selected.' : 'No control statements in this organization’s subscribed frameworks.')
                    : 'No statement selected yet.') + '</div>';

            el('[data-r="' + k + 'count"]').textContent = String(all.length);
            if (k === 's') {
                const sel = rowsFor('s');
                const none = sel.filter(function (x) { return x.count === 0; }).length;
                el('[data-r="sinfo"]').textContent = sel.length
                    ? (opts.selectedInfo || 'The audit covers the practice instances of the practices mapped to these statements.')
                      + (none ? ' ' + none + ' of them ha' + (none === 1 ? 's' : 've') + ' no practice instance yet (shown faded).' : '')
                    : 'Pick statements on the left, then >.';
            }
        }

        return {
            getSelected: getSelected,
            destroy: function () { host.innerHTML = ''; }
        };
    }

    window.gracStatementTreePicker = {
        attach: attach,
        invalidateCache: function () { Object.keys(cache).forEach(function (k) { delete cache[k]; }); }
    };
})();
