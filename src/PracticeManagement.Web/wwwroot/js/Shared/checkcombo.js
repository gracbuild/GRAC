// =====================================================================
// js/Shared/checkcombo.js  --  window.gracCheckCombo
//
// The project's multi-select combo (.pm-checkcombo), as a shared piece.
// Markup and behaviour are the ones practice.js, tprm-common.js and
// event-profiles.js already emit for a "comboChecks" field: a trigger
// showing the picked options as chips, a menu with a search box and one
// checkbox per option. practice-management.css styles all of it; nothing
// here sets a colour or a border.
//
// Added by 560 (Audit Definition -> Applicable Frameworks). The screens
// above keep their own copies for now.
//
//   gracCheckCombo.html(options, selectedValues, { ariaLabel, disabled })
//       options        [{ value, label }]
//       selectedValues array / Set of values (compared as strings)
//       -> the combo's HTML (a <div class="pm-checkcombo" data-checkcombo>)
//   gracCheckCombo.wire(host)
//       binds open / close, search and chip repaint for every combo inside
//       host (event delegation -- call once per host; combos re-rendered
//       inside it keep working)
//   gracCheckCombo.values(combo)
//       -> the checked values, in option order
// =====================================================================
(function () {
    'use strict';

    function esc(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    // Chips of the picked options, or the placeholder (.pm-checkcombo-chip /
    // .pm-checkcombo-placeholder are what the stylesheet expects).
    function chips(labels) {
        return labels.length
            ? labels.map(function (l) { return '<span class="pm-checkcombo-chip">' + esc(l) + '</span>'; }).join('')
            : '<span class="pm-checkcombo-placeholder">Select...</span>';
    }

    function html(options, selectedValues, opts) {
        opts = opts || {};
        const chosen = new Set(Array.from(selectedValues || []).map(String));
        const dis = opts.disabled ? ' disabled' : '';
        const list = (options || []).map(function (o) {
            return '<label data-checkcombo-option><input type="checkbox" value="' + esc(o.value) + '"'
                 + (chosen.has(String(o.value)) ? ' checked' : '') + dis + ' /> <span>' + esc(o.label) + '</span></label>';
        }).join('');
        const picked = (options || []).filter(function (o) { return chosen.has(String(o.value)); })
                                      .map(function (o) { return o.label; });
        return '<div class="pm-checkcombo" data-checkcombo>'
             +   '<button class="pm-checkcombo-trigger" type="button" data-checkcombo-trigger aria-expanded="false"'
             +     (opts.ariaLabel ? ' aria-label="' + esc(opts.ariaLabel) + '"' : '') + dis + '>'
             +     '<span data-checkcombo-text>' + chips(picked) + '</span>'
             +     '<span class="pm-checkcombo-caret" aria-hidden="true">&#9662;</span>'
             +   '</button>'
             +   '<div class="pm-checkcombo-menu" data-checkcombo-menu hidden>'
             +     '<input class="pm-checkcombo-search" type="search" placeholder="Search..." data-checkcombo-search'
             +       (opts.ariaLabel ? ' aria-label="Search ' + esc(opts.ariaLabel) + '"' : '') + ' />'
             +     '<div class="pm-checkcombo-options">'
             +       (list || '<div class="pm-empty compact">No options found.</div>')
             +     '</div>'
             +   '</div>'
             + '</div>';
    }

    function wire(host) {
        if (!host || host.__gracCheckComboWired) return;
        host.__gracCheckComboWired = true;

        const closeAll = function (except) {
            host.querySelectorAll('[data-checkcombo]').forEach(function (c) {
                if (c === except) return;
                const m = c.querySelector('[data-checkcombo-menu]');
                const t = c.querySelector('[data-checkcombo-trigger]');
                if (m) m.hidden = true;
                if (t) t.setAttribute('aria-expanded', 'false');
            });
        };
        host.addEventListener('click', function (ev) {
            const trigger = ev.target.closest('[data-checkcombo-trigger]');
            if (!trigger || !host.contains(trigger)) return;
            ev.preventDefault();
            const combo = trigger.closest('[data-checkcombo]');
            const menu = combo.querySelector('[data-checkcombo-menu]');
            closeAll(combo);
            menu.hidden = !menu.hidden;
            trigger.setAttribute('aria-expanded', menu.hidden ? 'false' : 'true');
            if (!menu.hidden) { const s = menu.querySelector('[data-checkcombo-search]'); if (s) s.focus(); }
        });
        host.addEventListener('input', function (ev) {
            const search = ev.target.closest('[data-checkcombo-search]');
            if (!search) return;
            const q = search.value.trim().toLowerCase();
            search.closest('[data-checkcombo-menu]').querySelectorAll('[data-checkcombo-option]').forEach(function (o) {
                o.hidden = !!q && o.textContent.toLowerCase().indexOf(q) < 0;
            });
        });
        host.addEventListener('change', function (ev) {
            const combo = ev.target.closest('[data-checkcombo]');
            if (!combo || ev.target.type !== 'checkbox') return;
            const labels = Array.prototype.map.call(
                combo.querySelectorAll('[data-checkcombo-option] input:checked'),
                function (cb) { return cb.closest('label').querySelector('span').textContent.trim(); });
            combo.querySelector('[data-checkcombo-text]').innerHTML = chips(labels);
        });
        // mousedown, not click: a click fires after the checkbox has toggled.
        document.addEventListener('mousedown', function (ev) {
            if (!host.contains(ev.target) || !ev.target.closest('[data-checkcombo]')) closeAll(null);
        });
    }

    function values(combo) {
        if (!combo) return [];
        return Array.prototype.map.call(
            combo.querySelectorAll('[data-checkcombo-option] input:checked'),
            function (cb) { return cb.value; });
    }

    window.gracCheckCombo = { html: html, wire: wire, values: values };
})();
