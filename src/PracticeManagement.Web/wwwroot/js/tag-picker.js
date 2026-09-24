/* =====================================================================
   Tag Picker -- a reusable multi-select with chips and inline create
   Migrations 285 / 286.

   WHAT IT IS FOR
   --------------
   Selecting several items from an organisation's list, and adding one to
   that list without leaving the form. Built for Threat and Vulnerability
   on the Risk forms, but it knows nothing about either: it is handed two
   endpoints and two field names and does the rest.

   WHY IT EXISTS AT ALL
   --------------------
   The control it replaces was a single <select> with an "Others" option
   that revealed a textarea. Whatever was typed there was stored on the
   risk as loose text, so:

     * it never joined the list -- the next analyst typed it again,
       slightly differently;
     * the register showed "Others" until you opened the risk;
     * a risk facing three threats could record one.

   Adding here writes a real master row, so the next person picks it.

   THE PATTERN IS THE PROJECT'S OWN
   --------------------------------
   Same shape as wwwroot/js/practice-picker.js: one global with
   attach / readState / setState / invalidateCaches, no framework, and
   the host page owns the markup. Anything that can hold a list of ids
   can mount it.

   USAGE
     const picker = window.__tagPicker.attach({
       hostId:     "cxThreatPicker",
       listUrl:    "/Practice/RiskCentre/threats",
       createUrl:  "/Practice/RiskCentre/threats",
       idField:    "threatId",
       nameField:  "threatName",
       label:      "threat",          // used in "Add new threat: ..."
       organizationId: 4,
       required:   true
     });
     picker.setState([{ id: 12, name: "Phishing" }]);   // edit mode
     picker.readState();                                // -> [12, 15]
   ===================================================================== */
(function () {
    "use strict";

    // One cache per list endpoint per organisation. The lists are small
    // and change only when this control creates something, so a fetch
    // per keystroke would be waste -- and invalidateCaches() below is
    // what keeps a newly created item visible to the OTHER picker on the
    // same page without either of them re-fetching on every open.
    const cache = new Map();

    function cacheKey(url, orgId) { return url + "|" + orgId; }

    function esc(s) {
        return String(s ?? "").replace(/[&<>"']/g, c => ({
            "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
        }[c]));
    }

    async function fetchJson(url, opts) {
        const res = await fetch(url, Object.assign({
            headers: { "Accept": "application/json", "Content-Type": "application/json" },
            credentials: "same-origin"
        }, opts || {}));
        if (!res.ok) {
            // The API returns { error } on a 400; surface that rather
            // than "500", which tells the user nothing they can act on.
            let msg = "Request failed (" + res.status + ").";
            try { const j = await res.json(); if (j && j.error) msg = j.error; } catch (e) { /* body was not json */ }
            throw new Error(msg);
        }
        return res.status === 204 ? null : res.json();
    }

    function attach(opts) {
        const host = document.getElementById(opts.hostId);
        if (!host) return null;

        const st = {
            opts,
            selected: [],      // [{ id, name }]
            options: [],       // the full list for this org
            query: "",
            open: false,
            busy: false,
            error: "",
            loaded: false
        };

        host.classList.add("tag-picker");
        host.innerHTML = `
            <div class="tp-control" data-tp-control tabindex="0" role="combobox"
                 aria-expanded="false" aria-haspopup="listbox">
              <span class="tp-chips" data-tp-chips></span>
              <input type="text" class="tp-input" data-tp-input
                     autocomplete="off" spellcheck="false"
                     placeholder="${esc(opts.placeholder || ("Search or add a " + (opts.label || "item")))}" />
            </div>
            <div class="tp-menu" data-tp-menu hidden role="listbox"></div>
            <p class="tp-message" data-tp-message role="status" aria-live="polite"></p>`;

        const elControl = host.querySelector("[data-tp-control]");
        const elChips   = host.querySelector("[data-tp-chips]");
        const elInput   = host.querySelector("[data-tp-input]");
        const elMenu    = host.querySelector("[data-tp-menu]");
        const elMsg     = host.querySelector("[data-tp-message]");

        // ---- rendering --------------------------------------------------
        function renderChips() {
            elChips.innerHTML = st.selected.map(s => `
                <span class="tp-chip${s.pending ? " is-pending" : ""}"
                      title="${s.pending ? "Not in the list yet - saving this risk will add it" : esc(s.name)}">
                  ${esc(s.name)}
                  <button type="button" class="tp-chip-x" data-tp-remove="${esc(String(s.id))}"
                          aria-label="Remove ${esc(s.name)}">&times;</button>
                </span>`).join("");
            // The input keeps the placeholder only while nothing is
            // chosen; with chips present it would wrap to a second line
            // and push the control taller for no information.
            elInput.placeholder = st.selected.length
                ? "" : (opts.placeholder || ("Search or add a " + (opts.label || "item")));
        }

        function renderMenu() {
            if (!st.open) { elMenu.hidden = true; elControl.setAttribute("aria-expanded", "false"); return; }
            elMenu.hidden = false;
            elControl.setAttribute("aria-expanded", "true");

            const q = st.query.trim().toLowerCase();
            const chosen = new Set(st.selected.map(s => String(s.id)));
            const matches = st.options
                .filter(o => !chosen.has(String(o.id)))
                .filter(o => !q || o.name.toLowerCase().includes(q))
                .slice(0, 50);

            // "Add new" appears only when the typed text is not already
            // an EXACT (case-insensitive) name -- offering to add
            // something that exists is how duplicate lists get made.
            const exact = st.options.some(o => o.name.trim().toLowerCase() === q)
                       || st.selected.some(s => String(s.name).trim().toLowerCase() === q);
            const canCreate = q.length > 0 && !exact;

            let html = "";
            if (st.busy) {
                html += `<div class="tp-opt is-busy"><i class="fa-solid fa-circle-notch fa-spin"></i> Adding...</div>`;
            }
            if (canCreate && !st.busy) {
                html += `<button type="button" class="tp-opt tp-opt-create" data-tp-create>
                           <i class="fa-solid fa-plus"></i>
                           Add new ${esc(opts.label || "item")}: <strong>${esc(st.query.trim())}</strong>
                         </button>`;
            }
            if (!st.loaded) {
                html += `<div class="tp-opt is-muted">Loading...</div>`;
            } else if (!matches.length && !canCreate) {
                html += `<div class="tp-opt is-muted">${
                    q ? "No match. Keep typing to add it." : "Nothing left to choose."}</div>`;
            }
            html += matches.map(o => `
                <button type="button" class="tp-opt" data-tp-pick="${esc(String(o.id))}" role="option">
                  ${esc(o.name)}${o.isShared ? "" : ` <span class="tp-own">added here</span>`}
                </button>`).join("");

            elMenu.innerHTML = html;
        }

        function renderMessage() {
            elMsg.textContent = st.error || "";
            elMsg.className = "tp-message" + (st.error ? " is-error" : "");
        }

        function render() { renderChips(); renderMenu(); renderMessage(); }

        // ---- data -------------------------------------------------------
        async function loadOptions(force) {
            const key = cacheKey(opts.listUrl, st.opts.organizationId);
            if (!force && cache.has(key)) { st.options = cache.get(key); st.loaded = true; return; }
            try {
                const rows = await fetchJson(
                    `${opts.listUrl}?organizationId=${encodeURIComponent(st.opts.organizationId)}`);
                st.options = (rows || []).map(r => ({
                    id: r[opts.idField], name: r[opts.nameField] || "", isShared: !!r.isShared
                }));
                cache.set(key, st.options);
                st.loaded = true;
            } catch (e) {
                st.error = "Could not load the list: " + e.message;
                st.loaded = true;
            }
        }

        async function createFromQuery() {
            const name = st.query.trim();
            if (!name || st.busy) return;
            st.busy = true; st.error = ""; render();
            try {
                const created = await fetchJson(opts.createUrl, {
                    method: "POST",
                    body: JSON.stringify({ organizationId: st.opts.organizationId, name })
                });
                const id = created[opts.idField];
                const nm = created[opts.nameField] || name;

                // The create is idempotent by name, so an existing entry
                // comes back with wasCreated false. Either way the item
                // is now selectable, which is the only outcome the user
                // asked for -- so this does not branch on it beyond
                // keeping the cache honest.
                const key = cacheKey(opts.listUrl, st.opts.organizationId);
                const list = cache.get(key) || st.options;
                if (!list.some(o => String(o.id) === String(id)))
                    list.push({ id, name: nm, isShared: false });
                cache.set(key, list);
                st.options = list;

                // Drop any pending legacy chip with the same wording:
                // this IS that value, now real.
                st.selected = st.selected.filter(s =>
                    !(s.pending && String(s.name).trim().toLowerCase() === nm.trim().toLowerCase()));

                if (!st.selected.some(s => String(s.id) === String(id)))
                    st.selected.push({ id, name: nm });

                st.query = ""; elInput.value = "";
            } catch (e) {
                st.error = `Could not add that ${opts.label || "item"}: ` + e.message;
            } finally {
                st.busy = false;
                render();
                elInput.focus();
            }
        }

        // ---- events -----------------------------------------------------
        elInput.addEventListener("focus", async () => {
            st.open = true; render();
            if (!st.loaded) { await loadOptions(false); render(); }
        });

        elInput.addEventListener("input", () => { st.query = elInput.value; st.open = true; render(); });

        elInput.addEventListener("keydown", ev => {
            if (ev.key === "Enter") {
                // Enter inside a picker must never submit the form
                // around it -- that would save a half-typed threat.
                ev.preventDefault();
                const q = st.query.trim().toLowerCase();
                const hit = st.options.find(o => o.name.trim().toLowerCase() === q);
                if (hit) { pick(hit.id); return; }
                if (q) createFromQuery();
                return;
            }
            if (ev.key === "Escape") { st.open = false; render(); return; }
            // Backspace on an empty box removes the last chip, the
            // behaviour every tag input has.
            if (ev.key === "Backspace" && !elInput.value && st.selected.length) {
                st.selected.pop(); render();
            }
        });

        host.addEventListener("click", ev => {
            const rm = ev.target.closest("[data-tp-remove]");
            if (rm) {
                const id = rm.getAttribute("data-tp-remove");
                st.selected = st.selected.filter(s => String(s.id) !== id);
                render(); return;
            }
            const pickBtn = ev.target.closest("[data-tp-pick]");
            if (pickBtn) { pick(pickBtn.getAttribute("data-tp-pick")); return; }
            if (ev.target.closest("[data-tp-create]")) { createFromQuery(); return; }
            if (ev.target.closest("[data-tp-control]")) elInput.focus();
        });

        // Closing on outside click, not on blur: blur fires before the
        // menu's own click lands, so a blur-close would swallow every
        // selection.
        document.addEventListener("click", ev => {
            if (!host.contains(ev.target) && st.open) { st.open = false; render(); }
        });

        function pick(id) {
            const o = st.options.find(x => String(x.id) === String(id));
            if (o && !st.selected.some(s => String(s.id) === String(o.id)))
                st.selected.push({ id: o.id, name: o.name });
            st.query = ""; elInput.value = "";
            render(); elInput.focus();
        }

        // ---- public surface ---------------------------------------------
        const api = {
            // items: [{ id, name }] or [{ name, pending:true }] for a
            // legacy "Others" value that has no id yet.
            setState(items) {
                st.selected = (items || []).map(i => ({
                    id: i.id != null ? i.id : ("pending:" + i.name),
                    name: i.name,
                    pending: i.id == null
                }));
                render();
                return api;
            },
            // Real ids only. A pending legacy chip has no id yet and is
            // reported by pendingNames() so the caller can create it
            // first -- see convertPending().
            readState() {
                return st.selected.filter(s => !s.pending).map(s => s.id);
            },
            pendingNames() {
                return st.selected.filter(s => s.pending).map(s => s.name);
            },
            // Turns every pending legacy chip into a real master row.
            // This is the "convert Others on save" path: the user has
            // seen the wording on screen and chosen to save, so it
            // becomes a list entry now, not by a bulk sweep nobody
            // reviewed.
            async convertPending() {
                for (const name of api.pendingNames()) {
                    st.query = name;
                    await createFromQuery();
                    if (st.error) throw new Error(st.error);
                }
                return api.readState();
            },
            setOrganization(orgId) {
                st.opts.organizationId = orgId;
                st.loaded = false; st.options = [];
                return api;
            },
            clear() { st.selected = []; st.query = ""; elInput.value = ""; st.error = ""; render(); return api; },
            isEmpty() { return st.selected.length === 0; },
            error(msg) { st.error = msg || ""; renderMessage(); return api; },
            reload() { return loadOptions(true).then(render); }
        };

        render();
        return api;
    }

    // Called after anything outside this file changes a master list, so
    // two pickers on one page cannot disagree about what exists.
    function invalidateCaches() { cache.clear(); }

    window.__tagPicker = { attach, invalidateCaches };
})();
