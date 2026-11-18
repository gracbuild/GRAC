// =====================================================================
// js/Shared/dependency-picker.js  --  window.gracDependencyPicker
//
// 562 (2026-11-15, sir: the audit subjects shown "the same as
// Operationalize, with the same logic"). The Category | Objects table of
// Operationalize -> Dependencies (resolve-workspace.cshtml,
// renderDependencyTable / wireCheckcombo), without the Applicability
// column -- an audit picks subjects, it does not answer whether an
// instance depends on a category:
//   * the same rows, in the same order: Asset, Vendor, Department /
//     Person, Team, Committee, Location, Business Function
//     (resolve-workspace DEP_TABLE_CATEGORIES); a category the database
//     does not offer is left out;
//   * the same object lists -- POST /practice-management-gateway/
//     dependency-options/query, active objects of the organization;
//   * Asset: the Category -> Sub Category -> Type cascade
//     (asset-taxonomy/query); the asset list shows the picked assets until
//     a filter is picked, then the assets matching every filter;
//   * Department / Person: the departments narrow the persons; with no
//     person ticked the DEPARTMENTS are the selection, with any person
//     ticked the PERSONS are (and the departments are not);
//   * the same .pm-checkcombo markup and empty texts ("Select Assets",
//     "Select...", blank for Department / Person).
// resolve-workspace and the Risk Centre keep their own copies of this
// logic for now; they can move onto this module.
//
//   const p = await gracDependencyPicker.render(host, {
//       orgId,                                   // organization id
//       categories: [{ name, typeId, key }],     // dependency types; key is
//                                                // the caller's id (scope
//                                                // dimension code)
//       selected:   { key: [objectId, ...] },    // initial picks
//       readOnly:   false,
//       onChange:   function (selection) {}      // as p.read()
//   });
//   p.read() -> { key: [{ id, name }], ... }     // keys with picks only
// =====================================================================
(function () {
    'use strict';

    const ORDER = ['Asset', 'Vendor', 'Person', 'Team', 'Committee', 'Location', 'Business Function'];
    const DEPT  = 'Department';

    const U    = p => String(window.appBasePath || window.pmPathBase || '').replace(/\/+$/, '') + p;
    const CSRF = () => (document.querySelector('meta[name="csrf-token"]') || {}).content || '';
    const esc  = v => String(v == null ? '' : v)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    const withRole = (n, r) => (window.__wfCommon && window.__wfCommon.personWithRole)
        ? window.__wfCommon.personWithRole(n, r) : n;

    function unwrap(v) {
        if (typeof v === 'string') {
            const t = v.trim();
            if ((t.startsWith('{') && t.endsWith('}')) || (t.startsWith('[') && t.endsWith(']'))) {
                try { return unwrap(JSON.parse(t)); } catch (_) { return v; }
            }
        }
        if (v && typeof v === 'object' && Array.isArray(v.$values)) return v.$values.map(unwrap);
        if (Array.isArray(v)) return v.map(unwrap);
        return v;
    }
    function rowsOf(body) {
        const d = unwrap((body && (body.data ?? body.Data)) ?? body ?? []);
        if (!Array.isArray(d)) return [];
        return (d.length && Array.isArray(d[0])) ? d.flat() : d;
    }

    const objectCache = new Map();   // orgId:typeId -> [objects]
    let taxonomyPromise = null;

    async function loadObjects(orgId, typeId) {
        const key = orgId + ':' + typeId;
        if (objectCache.has(key)) return objectCache.get(key);
        let list = [];
        try {
            const r = await fetch(U('/practice-management-gateway/dependency-options/query'), {
                method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json', 'X-CSRF-TOKEN': CSRF() },
                body: JSON.stringify({ data: { organizationId: Number(orgId), dependencyTypeId: Number(typeId), pageNumber: 1, pageSize: 500 } })
            });
            if (r.ok) {
                list = rowsOf(await r.json()).map(x => ({
                    id:                 Number(x.Value ?? x.value ?? x.Id ?? x.id ?? 0),
                    name:               String(x.Label ?? x.label ?? x.Name ?? x.name ?? ''),
                    roleNames:          x.RoleNames ?? x.roleNames ?? null,
                    assetCategoryId:    x.AssetCategoryId ?? x.assetCategoryId ?? null,
                    assetSubcategoryId: x.AssetSubcategoryId ?? x.assetSubcategoryId ?? null,
                    assetTypeId:        x.AssetTypeId ?? x.assetTypeId ?? null,
                    departmentId:       x.DepartmentId ?? x.departmentId ?? null
                })).filter(x => x.id && x.name);
            } else {
                console.error('[dependency-picker] dependency-options HTTP', r.status, 'type', typeId);
            }
        } catch (err) { console.error('[dependency-picker] dependency-options failed', err); }
        objectCache.set(key, list);
        return list;
    }

    function loadTaxonomy() {
        if (taxonomyPromise) return taxonomyPromise;
        taxonomyPromise = (async function () {
            const bucket = { cats: [], subs: [], types: [] };
            try {
                const r = await fetch(U('/practice-management-gateway/asset-taxonomy/query'), {
                    method: 'POST', credentials: 'same-origin',
                    headers: { 'Content-Type': 'application/json', 'X-CSRF-TOKEN': CSRF() },
                    body: JSON.stringify({ data: { pageNumber: 1, pageSize: 1000 } })
                });
                if (!r.ok) throw new Error('HTTP ' + r.status);
                rowsOf(await r.json()).forEach(row => {
                    const kind = String(row.EntityType || row.entityType || '');
                    const item = { id: Number(row.Value ?? row.value), name: String(row.Label ?? row.label ?? ''),
                                   parent: row.Parent != null ? Number(row.Parent) : null };
                    if (!item.id) return;
                    if (kind === 'asset-categories')         bucket.cats.push(item);
                    else if (kind === 'asset-subcategories') bucket.subs.push(item);
                    else if (kind === 'asset-types')         bucket.types.push(item);
                });
            } catch (_) { /* no taxonomy: the flat asset picker */ }
            return bucket;
        })();
        return taxonomyPromise;
    }

    // One .pm-checkcombo, as Operationalize builds it.
    function combo(attrs, emptyText, title, optionsHtml, disabled, hintHtml) {
        return '<div class="pm-field pm-checkcombo" data-checkcombo ' + attrs
             +   ' data-checkcombo-empty="' + esc(emptyText) + '" style="width:100%">'
             + '<button class="pm-checkcombo-trigger" type="button" data-checkcombo-trigger'
             +   (title ? ' title="' + esc(title) + '"' : '') + (disabled ? ' disabled' : '') + '>'
             +   '<span data-checkcombo-text>' + esc(emptyText) + '</span>'
             +   '<span class="pm-checkcombo-caret" aria-hidden="true"></span>'
             + '</button>'
             + '<div class="pm-checkcombo-menu" data-checkcombo-menu hidden>'
             +   '<input class="pm-checkcombo-search" type="search" placeholder="Search..." data-checkcombo-search>'
             +   '<div class="pm-checkcombo-options">' + (hintHtml || '') + optionsHtml + '</div>'
             + '</div>'
             + '</div>';
    }

    function objectOptions(list, picked, personRole) {
        return list.map(o =>
            '<label data-checkcombo-option'
            + (o.assetCategoryId    != null ? ' data-asset-category="'    + esc(String(o.assetCategoryId))    + '"' : '')
            + (o.assetSubcategoryId != null ? ' data-asset-subcategory="' + esc(String(o.assetSubcategoryId)) + '"' : '')
            + (o.assetTypeId        != null ? ' data-asset-type="'        + esc(String(o.assetTypeId))        + '"' : '')
            + (o.departmentId       != null ? ' data-person-department="' + esc(String(o.departmentId))       + '"' : '')
            + '><input type="checkbox" value="' + esc(String(o.id)) + '" data-object-name="' + esc(o.name) + '"'
            + (picked.has(o.id) ? ' checked' : '') + '> '
            + '<span>' + esc(personRole ? withRole(o.name, o.roleNames) : o.name) + '</span></label>').join('');
    }

    function taxonomyOptions(items) {
        return items.map(o => '<label data-checkcombo-option'
            + (o.parent != null ? ' data-parent="' + esc(String(o.parent)) + '"' : '')
            + '><input type="checkbox" value="' + esc(String(o.id)) + '"> <span>' + esc(o.name) + '</span></label>').join('');
    }

    const emptyText = c => { const v = c ? c.getAttribute('data-checkcombo-empty') : null; return v === null ? 'Select...' : v; };
    const comboText = c => [...c.querySelectorAll('[data-checkcombo-option] input:checked')]
        .map(cb => cb.closest('label').querySelector('span').textContent.trim()).join(', ') || emptyText(c);
    const ticks     = c => new Set([...c.querySelectorAll('[data-checkcombo-option] input:checked')].map(cb => cb.value));

    // Open / close, search, trigger text; Asset cascade; Department narrows
    // Person -- resolve-workspace wireCheckcombo, row by row.
    function wireRow(row) {
        row.querySelectorAll('[data-checkcombo]').forEach(function (c) {
            const trigger = c.querySelector('[data-checkcombo-trigger]');
            const menu    = c.querySelector('[data-checkcombo-menu]');
            const search  = c.querySelector('[data-checkcombo-search]');
            c.querySelector('[data-checkcombo-text]').textContent = comboText(c);
            trigger.addEventListener('click', function (ev) {
                ev.preventDefault();
                document.querySelectorAll('[data-checkcombo-menu]').forEach(m => { if (m !== menu) m.hidden = true; });
                menu.hidden = !menu.hidden;
                if (!menu.hidden && search) search.focus();
            });
            c.addEventListener('change', function (ev) {
                if (ev.target.closest('input[type="checkbox"]')) c.querySelector('[data-checkcombo-text]').textContent = comboText(c);
            });
            if (search) search.addEventListener('input', function () {
                const q = this.value.toLowerCase().trim();
                c.querySelectorAll('[data-checkcombo-option]').forEach(function (opt) {
                    const text = opt.querySelector('span').textContent.toLowerCase();
                    opt.hidden = (opt.dataset.filteredOut === '1') || (!!q && !text.includes(q));
                });
            });
            document.addEventListener('mousedown', function (ev) { if (!c.contains(ev.target)) menu.hidden = true; });
        });

        const dept = row.querySelector('[data-person-dept-filter]');
        if (dept) {
            const person = row.querySelector('[data-dp-object] [data-checkcombo]');
            const apply = () => {
                if (!person) return;
                const depts = ticks(dept);
                person.querySelectorAll('[data-checkcombo-option]').forEach(function (opt) {
                    const box = opt.querySelector('input');
                    opt.hidden = !(!depts.size || depts.has(opt.dataset.personDepartment || '') || (box && box.checked));
                });
                const t = comboText(person);
                person.querySelector('[data-checkcombo-text]').textContent =
                    (t === emptyText(person) && depts.size) ? 'All Users (selected departments)' : t;
            };
            dept.addEventListener('change', apply);
            if (person) person.addEventListener('change', apply);
            apply();
            return;
        }

        const cat = row.querySelector('[data-asset-cat-filter]');
        const sub = row.querySelector('[data-asset-subcat-filter]');
        const typ = row.querySelector('[data-asset-type-filter]');
        const asset = row.querySelector('[data-dp-object] [data-checkcombo]');
        if (!cat && !sub && !typ) return;

        const narrow = (parent, child) => {
            if (!child) return;
            const ids = parent ? ticks(parent) : new Set();
            let changed = false, any = false;
            child.querySelectorAll('[data-checkcombo-option]').forEach(function (opt) {
                const box = opt.querySelector('input');
                const ok  = ids.size > 0 && ids.has(opt.dataset.parent || '');
                opt.dataset.filteredOut = ok ? '' : '1';
                opt.hidden = !ok;
                if (ok) any = true;
                if (!ok && box && box.checked) { box.checked = false; changed = true; }
            });
            const hint = child.querySelector('[data-taxonomy-parent-hint]');
            if (hint) hint.hidden = any;
            if (changed) child.querySelector('[data-checkcombo-text]').textContent = comboText(child);
        };
        const filter = () => {
            if (!asset) return;
            const cs = cat ? ticks(cat) : new Set(), ss = sub ? ticks(sub) : new Set(), ts = typ ? ticks(typ) : new Set();
            const none = !cs.size && !ss.size && !ts.size;
            asset.querySelectorAll('[data-checkcombo-option]').forEach(function (opt) {
                const box = opt.querySelector('input');
                const show = none ? !!(box && box.checked)
                    : (!cs.size || cs.has(opt.dataset.assetCategory || ''))
                   && (!ss.size || ss.has(opt.dataset.assetSubcategory || ''))
                   && (!ts.size || ts.has(opt.dataset.assetType || ''));
                opt.dataset.filteredOut = show ? '' : '1';
                opt.hidden = !show;
            });
            const hint = asset.querySelector('[data-asset-empty-hint]');
            if (hint) hint.hidden = [...asset.querySelectorAll('[data-checkcombo-option]')].some(o => !o.hidden);
        };
        // Seed the filters from the picked assets, so a saved pick shows
        // its Category / Sub Category / Type.
        if (asset) {
            const picked = [...asset.querySelectorAll('[data-checkcombo-option] input:checked')].map(cb => cb.closest('[data-checkcombo-option]'));
            [[cat, 'assetCategory'], [sub, 'assetSubcategory'], [typ, 'assetType']].forEach(function (p) {
                if (!p[0] || !picked.length) return;
                const want = new Set(picked.map(o => o.dataset[p[1]]).filter(Boolean));
                p[0].querySelectorAll('[data-checkcombo-option] input').forEach(cb => { if (want.has(cb.value)) cb.checked = true; });
                p[0].querySelector('[data-checkcombo-text]').textContent = comboText(p[0]);
            });
        }
        const all = () => { narrow(cat, sub); narrow(sub, typ); filter(); };
        [cat, sub, typ].forEach(c => { if (c) c.addEventListener('change', all); });
        all();
    }

    async function render(host, opts) {
        opts = opts || {};
        const byName = new Map((opts.categories || []).map(c => [String(c.name).trim().toLowerCase(), c]));
        const sel = {};
        Object.keys(opts.selected || {}).forEach(k => { sel[k] = new Set((opts.selected[k] || []).map(Number)); });
        const ro = !!opts.readOnly;
        const deptCat = byName.get(DEPT.toLowerCase()) || null;

        host.innerHTML = '<div class="pm-empty compact">Loading dependencies...</div>';
        const taxonomy = await loadTaxonomy();
        const rows = await Promise.all(ORDER.filter(n => byName.has(n.toLowerCase())).map(async function (name) {
            const c = byName.get(name.toLowerCase());
            const list = c.typeId != null ? await loadObjects(opts.orgId, c.typeId) : [];
            let dept = null;
            if (name === 'Person' && deptCat && deptCat.typeId != null)
                dept = { cat: deptCat, list: await loadObjects(opts.orgId, deptCat.typeId) };
            return { name: name, c: c, list: list, dept: dept };
        }));

        const html = rows.map(function (r) {
            const picked  = sel[r.c.key] || new Set();
            const isAsset = r.name === 'Asset';
            const showTax = isAsset && taxonomy.cats.length > 0;
            const objEmpty = isAsset ? 'Select Assets' : (r.name === 'Person' ? '' : 'Select...');
            const objectCombo = '<div data-dp-object style="flex:2 1 0;min-width:0">'
                + combo('', objEmpty, '', objectOptions(r.list, picked, r.name === 'Person'), ro,
                        showTax ? '<p class="pm-hint" data-asset-empty-hint style="margin:6px">Select an Asset Category, Sub Category or Type above to load assets.</p>' : '')
                + '</div>';
            let cell;
            if (!r.list.length && !(r.dept && r.dept.list.length)) {
                cell = '<div class="pm-field-empty">No active ' + esc(r.name.toLowerCase()) + ' records for this organization yet.</div>';
            } else if (showTax) {
                const f = (label, attr, items, hint) => '<div style="flex:1 1 0;min-width:0">'
                    + combo(attr, label, label, taxonomyOptions(items), ro,
                            hint ? '<p class="pm-hint" data-taxonomy-parent-hint style="margin:6px">' + esc(hint) + '</p>' : '') + '</div>';
                cell = '<div style="display:flex;gap:8px;align-items:center;width:100%">'
                     + f('Select Asset Category',     'data-asset-cat-filter',    taxonomy.cats,  null)
                     + f('Select Asset Sub Category', 'data-asset-subcat-filter', taxonomy.subs,  'Select an Asset Category above first.')
                     + f('Select Asset Type',         'data-asset-type-filter',   taxonomy.types, 'Select an Asset Sub Category above first.')
                     + objectCombo + '</div>';
            } else if (r.dept) {
                const dPicked = sel[r.dept.cat.key] || new Set();
                cell = '<div style="display:flex;gap:8px;align-items:center;width:100%">'
                     + '<div style="flex:1 1 0;min-width:0">'
                     +   combo('data-person-dept-filter', '', 'Department',
                               r.dept.list.length ? objectOptions(r.dept.list, dPicked, false)
                                                  : '<p class="pm-hint" style="margin:6px">No active departments.</p>', ro, '')
                     + '</div>'
                     + objectCombo + '</div>';
            } else {
                cell = objectCombo;
            }
            return '<tr data-dp-row data-key="' + esc(r.c.key) + '"'
                 + (r.dept ? ' data-dept-key="' + esc(r.dept.cat.key) + '"' : '') + '>'
                 + '<td style="vertical-align:middle">' + esc(r.dept ? DEPT + ' / ' + r.name : r.name) + '</td>'
                 + '<td style="vertical-align:middle">' + cell + '</td></tr>';
        }).join('');

        host.innerHTML = rows.length
            ? '<table class="pm-table gr-dep-picker" style="width:100%;table-layout:fixed">'
              + '<thead><tr><th style="width:180px">Category</th><th style="width:auto">Objects</th></tr></thead>'
              + '<tbody>' + html + '</tbody></table>'
            : '<div class="pm-empty compact">No dependency categories are set up on this database.</div>';

        host.querySelectorAll('tr[data-dp-row]').forEach(wireRow);

        function read() {
            const out = {};
            host.querySelectorAll('tr[data-dp-row]').forEach(function (tr) {
                const take = (key, c) => {
                    if (!key || !c) return;
                    const v = [...c.querySelectorAll('[data-checkcombo-option] input:checked')]
                        .map(cb => ({ id: Number(cb.value), name: cb.getAttribute('data-object-name') || cb.closest('label').textContent.trim() }));
                    if (v.length) out[key] = v;
                };
                const objectCombo = tr.querySelector('[data-dp-object] [data-checkcombo]');
                const deptKey = tr.getAttribute('data-dept-key');
                if (deptKey) {
                    // Operationalize's rule: persons if any, else the departments.
                    const persons = objectCombo ? objectCombo.querySelectorAll('[data-checkcombo-option] input:checked').length : 0;
                    if (persons) take(tr.getAttribute('data-key'), objectCombo);
                    else take(deptKey, tr.querySelector('[data-person-dept-filter]'));
                } else {
                    take(tr.getAttribute('data-key'), objectCombo);
                }
            });
            return out;
        }
        if (typeof opts.onChange === 'function')
            host.addEventListener('change', function () { opts.onChange(read()); });
        return { read: read };
    }

    window.gracDependencyPicker = { render: render, categoryOrder: ORDER.concat([DEPT]) };
})();
