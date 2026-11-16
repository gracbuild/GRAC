// =====================================================================
// tprm-common.js  (migrations 486-490, Third-Party Management; 521)
//
// window.gracTprm -- what the four TPRM screens share, written once:
//   api(method, path, body)   practice/api/tprm + path (TprmController);
//                             { ok, status, data, error }
//   orgs(selectId)            fills an organization picker (allowed orgs,
//                             last-picked org -- gracOrgPref)
//   lookups(orgId)            sp_tprm_lookups for the organization, cached:
//                             .values(list) .label(list, code)
//                             .badge(list, code) .employees ...
//   form({ title, intro, fields, submitText, wide, validate, page, onOpen, onClose })
//                             the shared form dialog
//                             (Partials/_tprm-form-dialog.cshtml), or a full
//                             page of the screen (page: element id); resolves
//                             with the values, or null on Cancel
//   customFields(lk, entity, current) / customJson(values)
//                             organization custom fields (486) as form
//                             fields, and the @custom_json they save as
//   F esc date dateTime show hide empty info badge band stageLabel
//   button(action, icon, text, data, kind, title)  524: a [data-act] button
//   duplicatesHtml(data)      521: the possible duplicates of a vendor
//                             registration (409), each with a rationale box
//   duplicateReviews()        521: those boxes as @match_reviews_json
//   navigate(source, target, filterType, id, orgId, displayCode)
//                             524: opens another TPRM screen on one record;
//                             the record travels in the encrypted
//                             navigation code (?code=), never in the URL
//                             (525: Shared/secure-nav.js does the work)
//   navigationContext(target) 524: the record of such a link
//                             ({ filterType, filterId, organizationId,
//                             displayCode } | { error } | null)
//   navAttrs(source, target, filterType, id, orgId, displayCode)
//                             525: attributes for a link that does the same
//
// The procedures decide every rule; these helpers only render and post.
// The API answers rows as PascalCase column names; F() reads either case.
// =====================================================================
(() => {
  "use strict";

  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const BASE = "/practice/api/tprm";
  const CSRF = () => document.querySelector('meta[name="csrf-token"]')?.content
                  || document.querySelector("input[name='__RequestVerificationToken']")?.value || "";

  const F = (o, k) => o == null ? undefined : (o[k] !== undefined ? o[k] : o[k.charAt(0).toUpperCase() + k.slice(1)]);
  const esc = v => String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const date = v => v ? String(v).substring(0, 10) : "";   // SQL DATE values: yyyy-mm-dd
  const yes = v => v === true || v === 1 || v === "1" || v === "true";
  function dateTime(v) {
    if (!v) return "";
    if (typeof window.gracFormatDisplayDate === "function") { const g = window.gracFormatDisplayDate(v); if (g && g !== v) return g; }
    const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString();
  }

  // Engagement stages (488 CHECK constraint) -- display names.
  const STAGES = {
    SCOPING: "Scoping", RISK_ASSESSED: "Risk assessed", DUE_DILIGENCE: "Due diligence",
    PENDING_DECISION: "Pending decision", APPROVED: "Approved", ONBOARDING: "Onboarding", ACTIVE: "Active",
    SUSPENDED: "Suspended", EXITING: "Exiting", EXITED: "Exited", REJECTED: "Rejected", CANCELLED: "Cancelled"
  };
  const stageLabel = code => STAGES[code] || code || "";

  // ------------------------------------------------------------------ api
  async function api(method, path, body) {
    try {
      const headers = body ? { "Content-Type": "application/json", "X-CSRF-TOKEN": CSRF() } : undefined;
      const r = await fetch(U(BASE + path), {
        method, credentials: "same-origin", headers, body: body ? JSON.stringify(body) : undefined
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok || data.success === false) {
        const hint = r.status === 404 && !data.error ? " -- the TPRM API was not found; deploy the latest API and Web build" : "";
        return { ok: false, status: r.status, data, error: data.error || data.title || `Request failed (HTTP ${r.status})${hint}.` };
      }
      return { ok: true, status: r.status, data };
    } catch (err) { return { ok: false, status: 0, data: {}, error: err.message }; }
  }
  const qs = obj => {
    const q = new URLSearchParams();
    Object.entries(obj || {}).forEach(([k, v]) => { if (v !== null && v !== undefined && v !== "") q.set(k, String(v)); });
    return q.toString();
  };

  // ------------------------------------------------------------------ organizations
  // preferred (524): the organization of a navigation code, when the
  // session may act on it.
  async function orgs(selectId, preferred) {
    const sel = document.getElementById(selectId);
    try {
      const r = await fetch(U("/practice/api/organizations/allowed"), { credentials: "same-origin" });
      const b = r.ok ? await r.json() : null;
      ((b && (b.data || b.Data)) || []).forEach(row => {
        const value = String(F(row, "organizationId") ?? "");
        if (!value) return;
        sel.add(new Option(String(F(row, "organizationName") ?? value), value));
      });
    } catch (_) { /* the placeholder stays; the page says what is missing */ }
    const wanted = preferred ? String(preferred) : new URLSearchParams(window.location.search).get("organizationId");
    if (wanted && [...sel.options].some(o => o.value === wanted)) sel.value = wanted;
    else window.gracOrgPref?.apply(sel);   // last-picked org, else lowest id
    return Number(sel.value) || null;
  }

  // ------------------------------------------------------------------ navigation (524; 525: shared)
  // Page-to-page links carry the record in the encrypted navigation code
  // (?code=) -- Shared/secure-nav.js, loaded before this file.
  const SN = () => window.gracSecureNav;
  const navigate = (sourceArea, targetArea, filterType, filterId, organizationId, displayCode) =>
    SN() ? SN().open(sourceArea, targetArea, filterType, filterId, organizationId, displayCode)
         : Promise.resolve("The page is missing Shared/secure-nav.js.");
  const navigationContext = targetArea => SN() ? SN().context(targetArea) : Promise.resolve(null);
  // data-secure-nav attributes: the shared click handler opens the record.
  const navAttrs = (...a) => SN() ? SN().attrs(...a) : "";

  // ------------------------------------------------------------------ lookups
  const cache = new Map();
  async function lookups(orgId, refresh) {
    if (!orgId) return emptyLookups();
    if (!refresh && cache.has(orgId)) return cache.get(orgId);
    const res = await api("GET", `/lookups?${qs({ organizationId: orgId })}`);
    const lk = res.ok ? wrapLookups(res.data) : emptyLookups(res.error);
    if (res.ok) cache.set(orgId, lk);
    return lk;
  }
  function emptyLookups(error) { return wrapLookups({}, error); }
  function wrapLookups(d, error) {
    const set = k => d[k] || d[k.charAt(0).toUpperCase() + k.slice(1)] || [];
    const values = set("values");
    const lk = {
      error,
      raw: d,
      employees: set("employees"), businessFunctions: set("businessFunctions"), processes: set("processes"),
      // 521: thirdParties = the Vendor Registry (the legacy GRAC vendor set is gone)
      applications: set("applications"), thirdParties: set("thirdParties"), contracts: set("contracts"), library: set("library"),
      customFieldDefs: set("customFields"), riskModel: set("riskModel")[0] || null, dimensions: set("dimensions"),
      bands: set("bands"), evidenceTypes: set("evidenceTypes"), roles: set("roles"),
      values: list => values.filter(v => F(v, "listCode") === list),
      value: (list, code) => values.find(v => F(v, "listCode") === list && F(v, "valueCode") === code),
      label: (list, code) => { const v = lk.value(list, code); return v ? F(v, "label") : (code || ""); },
      options: list => lk.values(list).map(v => ({ value: F(v, "valueCode"), label: F(v, "label") })),
      employeeOptions: () => lk.employees.map(e => ({ value: F(e, "employeeId"), label: F(e, "employeeName") })),
      employeeName: id => { const e = lk.employees.find(x => String(F(x, "employeeId")) === String(id)); return e ? F(e, "employeeName") : ""; },
      libraryItems: code => lk.library.filter(x => F(x, "libraryCode") === code),
      badge: (list, code) => {
        if (!code) return "";
        const v = lk.value(list, code);
        return badge(v ? F(v, "label") : code, v ? F(v, "colorHex") : null);
      }
    };
    return lk;
  }

  // ------------------------------------------------------------------ rendering
  function badge(text, color) {
    if (!text) return "";
    const style = color ? ` style="background:${esc(color)}1f;color:${esc(color)};border:1px solid ${esc(color)}66"` : "";
    return `<span class="pm-badge"${style}>${esc(text)}</span>`;
  }
  // A risk band: label, colour, score.
  function band(label, color, score) {
    if (!label && (score === null || score === undefined)) return `<span class="tprm-muted">Not assessed</span>`;
    return `${badge(label || "", color)}${score !== null && score !== undefined ? ` <span class="tprm-muted">${esc(Number(score).toFixed(1))}</span>` : ""}`;
  }
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  // A small action button for a screen's delegated [data-act] handler (524).
  function button(action, icon, text, data, kind, title) {
    const attrs = Object.entries(data || {}).map(([k, v]) => ` data-${k}="${esc(v)}"`).join("");
    return `<button type="button" class="pm-button small${kind ? " " + kind : ""}" data-act="${esc(action)}"${attrs}${title ? ` title="${esc(title)}" aria-label="${esc(title)}"` : ""}>`
      + `<i class="fa-solid ${esc(icon)}" aria-hidden="true"></i>${text ? " " + esc(text) : ""}</button>`;
  }
  function info(items) {
    return items.filter(Boolean).map(([k, v, html]) =>
      `<div><span>${esc(k)}</span>${html ? (v || "--") : esc(v == null || v === "" ? "--" : v)}</div>`).join("");
  }
  function show(id, text, kind) {
    const el = typeof id === "string" ? document.getElementById(id) : id;
    if (!el) return;
    el.textContent = text || "";
    el.classList.toggle("success", kind === "success");
    el.classList.toggle("info", kind === "info");
    el.hidden = !text;
  }
  function hide(id) { show(id, ""); }

  // ------------------------------------------------------------------ form dialog
  // Field: { name, label, type, value, required, full, help, options,
  //          blank, rows, maxLength, min, max, step, readonly, showWhen }
  //   type: text | textarea | number | date | select | multi | checkbox |
  //         rows (repeating rows) | section (a heading) | note (read-only text)
  //   options: [{ value, label }]  (select / multi)
  //   showWhen: { field, values } or a list of them (any one is enough) --
  //         progressive disclosure (522, CR 2 5.3): the field (or section /
  //         note) shows only while the named field holds one of the values;
  //         a hidden field is not required and reads as empty (null, or []
  //         for multi / rows).
  //   rows: { columns: [{ name, label, type: text | select | radio,
  //           options, maxLength, required }], keyName, addText } -- one
  //         table row per item, Add / Remove buttons; reads as
  //         [{ <keyName>: id or null, <column>: value }] (blank rows are
  //         dropped; a radio column is true on one row only).
  //
  // A form opens on a SURFACE: the shared modal (Partials/_tprm-form-dialog,
  // the default) or a full page a screen carries for its large editors
  // (def.page = the id of an element holding the same [data-tf-part] parts --
  // e.g. the Vendor Registry's register / edit page). Both run the same
  // fields, validation and onSubmit; def.onOpen / def.onClose let a page
  // screen hide and show its list.
  //   parts: form, title, intro, fields, message, extra, submit, cancel, close (modal only)
  let formResolver = null, formDef = null, active = null;
  const wired = new WeakSet();
  function surface(def) {
    const host = document.getElementById(def && def.page ? def.page : "tprmFormModal");
    const part = name => host.querySelector(`[data-tf-part="${name}"]`);
    return { host, part, isPage: !!(def && def.page) };
  }
  function wireSurface(sf) {
    if (wired.has(sf.host)) return;
    wired.add(sf.host);
    const close = () => finishForm(null);
    sf.part("close")?.addEventListener("click", close);
    sf.part("cancel").addEventListener("click", close);
    wireCombos(sf.part("fields"));
    sf.part("fields").addEventListener("change", () => applyWhen());
    sf.part("fields").addEventListener("click", ev => {
      const add = ev.target.closest("[data-tf-row-add]");
      if (add && !add.disabled) {
        const f = formDef.fields.find(x => x.name === add.dataset.tfRowAdd);
        const body = sf.part("fields").querySelector(`[data-tf-rows="${CSS.escape(add.dataset.tfRowAdd)}"] tbody`);
        if (f && body) {
          body.insertAdjacentHTML("beforeend", rowHtml(f, {}));
          // the first row of a radio column is the chosen one
          if (body.rows.length === 1) body.rows[0].querySelectorAll("input[type=radio]").forEach(r => { r.checked = true; });
          body.rows[body.rows.length - 1].querySelector("input, select")?.focus();
        }
        return;
      }
      const remove = ev.target.closest("[data-tf-row-remove]");
      if (remove && !remove.disabled) remove.closest("tr").remove();
    });
    sf.part("form").addEventListener("submit", async ev => {
      ev.preventDefault();
      const msg = sf.part("message");
      const hidden = hiddenFields(readRaw());
      const values = readForm();
      const missing = formDef.fields.filter(f => f.required && f.type !== "section" && f.type !== "note" && !hidden.has(f.name)
        && (values[f.name] === null || values[f.name] === "" || (Array.isArray(values[f.name]) && !values[f.name].length)));
      if (missing.length) { show(msg, `${missing[0].label} is required.`); return; }
      for (const f of formDef.fields.filter(x => x.type === "rows" && !hidden.has(x.name))) {
        const col = (f.columns || []).find(c => c.required && (values[f.name] || []).some(r => r[c.name] === null || r[c.name] === ""));
        if (col) { show(msg, `${f.label}: ${col.label} is required on every row.`); return; }
      }
      if (formDef.validate) {
        const problem = formDef.validate(values);
        if (problem) { show(msg, problem); return; }
      }
      if (formDef.onSubmit) {
        // The form stays open on a refusal so the user can correct it.
        const btn = sf.part("submit");
        btn.disabled = true;
        show(msg, "Saving...", "info");
        const res = await formDef.onSubmit(values).catch(err => ({ ok: false, error: err.message }));
        btn.disabled = false;
        if (!res || !res.ok) {
          if (res && res.extraHtml) { showExtra(res.extraHtml); hide(msg); }
          else show(msg, (res && res.error) || "Could not save.");
          return;
        }
        finishForm({ values, result: res });
        return;
      }
      finishForm(values);
    });
  }
  function showExtra(html) {
    const el = (active || surface(null)).part("extra");
    el.innerHTML = html || "";
    el.hidden = !html;
  }
  function finishForm(result) {
    const sf = active, def = formDef;
    if (sf) {
      sf.host.hidden = true;
      // A page keeps no stale fields (their ids would repeat in the next form).
      if (sf.isPage) { sf.part("fields").innerHTML = ""; showExtra(""); }
    }
    active = null;
    if (def && def.onClose) def.onClose(result);
    if (formResolver) { const r = formResolver; formResolver = null; r(result); }
  }
  function fieldHtml(f, i) {
    const id = `tprmF${i}`;
    // A multi-select is a one-column combo (.pm-checkcombo) like any select;
    // it spans the row only when the field asks for full.
    const full = f.full || ["textarea", "section", "note"].includes(f.type) ? " full" : "";
    const req = f.required ? " *" : "";
    const help = f.help ? `<small class="tprm-help">${esc(f.help)}</small>` : "";
    const ro = f.readonly ? " disabled" : "";
    const v = f.value === null || f.value === undefined ? "" : f.value;
    switch (f.type) {
      case "section": return `<div class="tprm-section">${esc(f.label)}</div>`;
      case "note": return `<div class="full tprm-note">${f.html ? f.label : esc(f.label)}</div>`;
      case "textarea":
        return `<label class="full"><span>${esc(f.label)}${req}</span><textarea id="${id}" data-tf="${esc(f.name)}" rows="${f.rows || 3}"${f.maxLength ? ` maxlength="${f.maxLength}"` : ""}${ro}>${esc(v)}</textarea>${help}</label>`;
      case "select": {
        const opts = (f.blank !== false ? `<option value="">${esc(f.blank || "--")}</option>` : "")
          + (f.options || []).map(o => `<option value="${esc(o.value)}"${String(o.value) === String(v) ? " selected" : ""}>${esc(o.label)}</option>`).join("");
        return `<label class="${full.trim()}"><span>${esc(f.label)}${req}</span><select id="${id}" data-tf="${esc(f.name)}"${ro}>${opts}</select>${help}</label>`;
      }
      case "multi": {
        // The project's multi-select combo (.pm-checkcombo, practice-management.css
        // "14b"): a trigger showing the chosen values as chips, a menu with a
        // search box and the options. readForm() reads [data-tf-multi] as before.
        const chosen = new Set((Array.isArray(v) ? v : String(v).split(",")).map(x => String(x).trim()).filter(Boolean));
        const options = (f.options || []).map(o => `<label data-checkcombo-option><input type="checkbox" value="${esc(o.value)}"${chosen.has(String(o.value)) ? " checked" : ""}${ro} /> <span>${esc(o.label)}</span></label>`).join("")
          || '<div class="pm-empty compact">Nothing to choose from.</div>';
        return `<div class="${full.trim()}"><span>${esc(f.label)}${req}</span>
          <div class="pm-checkcombo" data-checkcombo data-tf-multi="${esc(f.name)}">
            <button class="pm-checkcombo-trigger" type="button" data-checkcombo-trigger aria-expanded="false"${ro}>
              <span data-checkcombo-text>${comboText(f.options || [], chosen)}</span><span class="pm-checkcombo-caret" aria-hidden="true">&#9662;</span>
            </button>
            <div class="pm-checkcombo-menu" data-checkcombo-menu hidden>
              <input class="pm-checkcombo-search" type="search" placeholder="Search..." data-checkcombo-search aria-label="Search ${esc(f.label)}" />
              <div class="pm-checkcombo-options">${options}</div>
            </div>
          </div>${help}</div>`;
      }
      case "rows":
        return `<div class="full tprm-rows-field"><span>${esc(f.label)}${req}</span>
          <div class="pm-table-wrap"><table class="tprm-rows" data-tf-rows="${esc(f.name)}">
            <thead><tr>${(f.columns || []).map(c => `<th>${esc(c.label)}${c.required ? " *" : ""}</th>`).join("")}<th></th></tr></thead>
            <tbody>${(Array.isArray(v) ? v : []).map(r => rowHtml(f, r)).join("")}</tbody></table></div>
          <button type="button" class="pm-button small" data-tf-row-add="${esc(f.name)}"${ro}><i class="fa-solid fa-plus"></i> ${esc(f.addText || "Add")}</button>${help}</div>`;
      case "checkbox":
        return `<label class="tprm-check${full}"><input type="checkbox" id="${id}" data-tf="${esc(f.name)}"${yes(v) ? " checked" : ""}${ro} /> <span>${esc(f.label)}</span>${help}</label>`;
      default: {
        const type = f.type === "number" || f.type === "date" ? f.type : "text";
        const extra = (f.maxLength ? ` maxlength="${f.maxLength}"` : "") + (f.min !== undefined ? ` min="${f.min}"` : "")
          + (f.max !== undefined ? ` max="${f.max}"` : "") + (f.step ? ` step="${f.step}"` : "") + (f.placeholder ? ` placeholder="${esc(f.placeholder)}"` : "");
        return `<label class="${full.trim()}"><span>${esc(f.label)}${req}</span><input type="${type}" id="${id}" data-tf="${esc(f.name)}" value="${esc(type === "date" ? date(v) : v)}"${extra}${ro} />${help}</label>`;
      }
    }
  }
  // Chips of the chosen options, or the placeholder (.pm-checkcombo-chip /
  // .pm-checkcombo-placeholder are what the stylesheet expects).
  function comboText(options, chosen) {
    const picked = options.filter(o => chosen.has(String(o.value)));
    return picked.length ? picked.map(o => `<span class="pm-checkcombo-chip">${esc(o.label)}</span>`).join("")
      : '<span class="pm-checkcombo-placeholder">Select...</span>';
  }
  // Open / close, search and chip repaint for every combo in the dialog --
  // bound once on the dialog (delegation), since its fields are re-rendered
  // for each form.
  function wireCombos(host) {
    const closeAll = except => host.querySelectorAll("[data-checkcombo]").forEach(c => {
      if (c === except) return;
      c.querySelector("[data-checkcombo-menu]").hidden = true;
      c.querySelector("[data-checkcombo-trigger]").setAttribute("aria-expanded", "false");
    });
    host.addEventListener("click", ev => {
      const trigger = ev.target.closest("[data-checkcombo-trigger]");
      if (!trigger) return;
      ev.preventDefault();
      const combo = trigger.closest("[data-checkcombo]");
      const menu = combo.querySelector("[data-checkcombo-menu]");
      closeAll(combo);
      menu.hidden = !menu.hidden;
      trigger.setAttribute("aria-expanded", menu.hidden ? "false" : "true");
      if (!menu.hidden) menu.querySelector("[data-checkcombo-search]")?.focus();
    });
    host.addEventListener("input", ev => {
      const search = ev.target.closest("[data-checkcombo-search]");
      if (!search) return;
      const q = search.value.trim().toLowerCase();
      search.closest("[data-checkcombo-menu]").querySelectorAll("[data-checkcombo-option]").forEach(o => {
        o.hidden = !!q && !o.textContent.toLowerCase().includes(q);
      });
    });
    host.addEventListener("change", ev => {
      const combo = ev.target.closest("[data-checkcombo]");
      if (!combo || ev.target.type !== "checkbox") return;
      const labels = [...combo.querySelectorAll("[data-checkcombo-option] input:checked")]
        .map(cb => cb.closest("label").querySelector("span").textContent.trim());
      combo.querySelector("[data-checkcombo-text]").innerHTML = labels.length
        ? labels.map(l => `<span class="pm-checkcombo-chip">${esc(l)}</span>`).join("")
        : '<span class="pm-checkcombo-placeholder">Select...</span>';
    });
    // mousedown, not click: a click fires after the checkbox has toggled.
    document.addEventListener("mousedown", ev => {
      if (!host.contains(ev.target) || !ev.target.closest("[data-checkcombo]")) closeAll(null);
    });
  }
  // Every field's value as entered, shown or not.
  function readRaw() {
    const out = {};
    const host = active.part("fields");
    host.querySelectorAll("[data-tf]").forEach(el => {
      const f = formDef.fields.find(x => x.name === el.dataset.tf);
      if (el.type === "checkbox") out[el.dataset.tf] = el.checked;
      else if (f && f.type === "number") out[el.dataset.tf] = el.value === "" ? null : Number(el.value);
      else out[el.dataset.tf] = el.value.trim() === "" ? null : el.value.trim();
    });
    host.querySelectorAll("[data-tf-multi]").forEach(el => {
      out[el.dataset.tfMulti] = [...el.querySelectorAll("[data-checkcombo-option] input:checked")].map(x => x.value);
    });
    host.querySelectorAll("[data-tf-rows]").forEach(table => {
      const f = formDef.fields.find(x => x.name === table.dataset.tfRows);
      out[table.dataset.tfRows] = [...table.tBodies[0].rows].map(tr => {
        const row = {};
        if (f && f.keyName) row[f.keyName] = tr.dataset.rowKey ? Number(tr.dataset.rowKey) : null;
        tr.querySelectorAll("[data-col]").forEach(el => {
          row[el.dataset.col] = el.type === "radio" || el.type === "checkbox" ? el.checked
            : (el.value.trim() === "" ? null : el.value.trim());
        });
        return row;
      }).filter(row => (f?.columns || []).some(c => c.type !== "radio" && row[c.name] !== null && row[c.name] !== ""));
    });
    return out;
  }
  // The names of the fields hidden by showWhen (a field is hidden when its
  // controlling field is hidden or holds another value).
  function hiddenFields(raw) {
    const hidden = new Set();
    formDef.fields.forEach(f => {
      if (!f.showWhen) return;
      const ok = [].concat(f.showWhen).some(c => !hidden.has(c.field)
        && (c.values || []).map(String).includes(String(raw[c.field] ?? "")));
      if (!ok && f.name) hidden.add(f.name);
    });
    return hidden;
  }
  function readForm() {
    const raw = readRaw();
    const hidden = hiddenFields(raw);
    hidden.forEach(name => { raw[name] = Array.isArray(raw[name]) ? [] : null; });
    return raw;
  }
  // Shows / hides the showWhen fields for the current values.
  function applyWhen() {
    if (!active || !formDef || !formDef.fields.some(f => f.showWhen)) return;
    const hidden = hiddenFields(readRaw());
    formDef.fields.forEach((f, i) => {
      if (!f.showWhen) return;
      const el = active.part("fields").querySelector(`[data-tf-index="${i}"]`);
      if (el) el.hidden = hidden.has(f.name);
    });
  }
  // One row of a rows field.
  function rowHtml(f, r) {
    const key = f.keyName && r[f.keyName] != null ? ` data-row-key="${esc(r[f.keyName])}"` : "";
    const cell = c => {
      const v = r[c.name] === null || r[c.name] === undefined ? "" : r[c.name];
      const aria = ` aria-label="${esc(c.label)}"`;
      if (c.type === "radio")
        return `<input type="radio" name="tf-row-${esc(f.name)}" data-col="${esc(c.name)}"${yes(v) ? " checked" : ""}${aria} />`;
      if (c.type === "select")
        return `<select data-col="${esc(c.name)}"${aria}><option value="">${esc(c.blank || "--")}</option>${(c.options || []).map(o =>
          `<option value="${esc(o.value)}"${String(o.value) === String(v) ? " selected" : ""}>${esc(o.label)}</option>`).join("")}</select>`;
      return `<input type="text" data-col="${esc(c.name)}" value="${esc(v)}"${c.maxLength ? ` maxlength="${c.maxLength}"` : ""}${aria} />`;
    };
    return `<tr${key}>${(f.columns || []).map(c => `<td${c.type === "radio" ? ' class="tprm-rows-radio"' : ""}>${cell(c)}</td>`).join("")}
      <td class="tprm-rows-remove"><button type="button" class="pm-button icon small" data-tf-row-remove title="Remove" aria-label="Remove"><i class="fa-solid fa-trash"></i></button></td></tr>`;
  }
  // Resolves with the values (or { values, result } when onSubmit is
  // given and succeeded), or null on Cancel.
  function form(def) {
    const sf = surface(def);
    wireSurface(sf);
    formDef = def;
    active = sf;
    sf.part("title").textContent = def.title || "Edit";
    const intro = sf.part("intro");
    intro.textContent = def.intro || "";
    intro.hidden = !def.intro;
    if (!sf.isPage) sf.host.querySelector(".tprm-form-panel").classList.toggle("wide", !!def.wide);
    // data-tf-index ties each rendered field to its definition (showWhen).
    sf.part("fields").innerHTML = def.fields.map((f, i) =>
      fieldHtml(f, i).replace(/^\s*<(\w+)/, `<$1 data-tf-index="${i}"`)).join("");
    applyWhen();
    sf.part("submit").innerHTML =
      `<i class="fa-solid ${esc(def.submitIcon || "fa-floppy-disk")}"></i> ${esc(def.submitText || "Save")}`;
    hide(sf.part("message"));
    showExtra(def.extraHtml || "");
    if (def.onOpen) def.onOpen();
    sf.host.hidden = false;
    if (sf.isPage) window.scrollTo({ top: 0, behavior: "smooth" });
    return new Promise(resolve => { formResolver = resolve; });
  }

  // ------------------------------------------------------------------ custom fields (486)
  // Active custom fields of an entity as form fields named "cf:<code>".
  function customFields(lk, entity, current) {
    const defs = lk.customFieldDefs.filter(d => F(d, "entityCode") === entity);
    if (!defs.length) return [];
    const cur = code => { const c = (current || []).find(x => F(x, "fieldCode") === code); return c ? F(c, "value") : F(defs.find(d => F(d, "fieldCode") === code), "defaultValue"); };
    const fields = [{ type: "section", label: "Additional fields", name: "_cf" }];
    defs.forEach(d => {
      const code = F(d, "fieldCode"), type = F(d, "dataType");
      let options = [];
      try { options = JSON.parse(F(d, "optionsJson") || "[]").map(o => ({ value: o.code, label: o.label || o.code })); } catch (_) { options = []; }
      const ref = String(F(d, "referenceKind") || "");
      if (type === "REFERENCE") {
        options = ref === "EMPLOYEE" ? lk.employeeOptions()
          : ref === "THIRD_PARTY" ? lk.thirdParties.map(v => ({ value: F(v, "thirdPartyId"), label: `${F(v, "thirdPartyCode")} - ${F(v, "legalName")}` }))
          : ref === "BUSINESS_FUNCTION" ? lk.businessFunctions.map(b => ({ value: F(b, "id"), label: F(b, "name") }))
          : ref.startsWith("LIST:") ? lk.options(ref.substring(5)) : [];
      }
      const base = { name: `cf:${code}`, label: F(d, "label"), required: yes(F(d, "isMandatory")), help: F(d, "description"), value: cur(code) };
      if (type === "BOOLEAN") fields.push({ ...base, type: "checkbox", required: false });
      else if (type === "NUMBER") fields.push({ ...base, type: "number", min: F(d, "minValue") ?? undefined, max: F(d, "maxValue") ?? undefined, step: "any" });
      else if (type === "DATE") fields.push({ ...base, type: "date" });
      else if (type === "SINGLE_SELECT" || type === "REFERENCE") fields.push({ ...base, type: "select", options });
      else if (type === "MULTI_SELECT") fields.push({ ...base, type: "multi", options });
      else fields.push({ ...base, type: "text", maxLength: F(d, "maxLength") || 1000 });
    });
    return fields;
  }
  // The values of "cf:" fields as @custom_json ([{ fieldCode, value }]),
  // or null when the entity has none.
  function customJson(values) {
    const items = Object.entries(values).filter(([k]) => k.startsWith("cf:")).map(([k, v]) => ({
      fieldCode: k.substring(3),
      value: Array.isArray(v) ? (v.length ? v.join(",") : null) : (typeof v === "boolean" ? String(v) : v)
    }));
    return items.length ? JSON.stringify(items) : null;
  }

  // A note required for an action (gracUi.promptRequired); null = cancelled.
  async function note(message, title, confirmText) {
    if (window.gracUi?.promptRequired)
      return window.gracUi.promptRequired(message, { title, confirmText, multiline: true, rows: 3, wide: true });
    const v = window.prompt(message);
    return v && v.trim() ? v.trim() : null;
  }
  async function confirm(message, title, confirmText) {
    return window.gracUi ? window.gracUi.confirm(message, { type: "warning", title, confirmText }) : window.confirm(message);
  }

  // Possible duplicates (409) as HTML for the form's extra area (521).
  // Nothing was saved: each match gets a rationale box -- why it is a
  // different vendor -- and duplicateReviews() reads them for the next save
  // (@match_reviews_json). A real duplicate is not registered: cancel and
  // open the existing vendor instead.
  const MATCH_KINDS = { STRONG: "Same identifier", POSSIBLE: "Possible match" };
  // filled: { matchId: rationale } typed before, kept when the list is shown again.
  function duplicatesHtml(data, againLabel, filled) {
    const rows = data.duplicates || data.Duplicates || [];
    const prior = filled || {};
    return `<div class="pm-message info">${esc(data.error || "Possible duplicates found. Nothing was saved.")}
      <div class="pm-table-wrap" style="margin-top:6px"><table><thead><tr><th>Match</th><th>Vendor</th><th>Status</th><th>Why it matched</th><th>Why it is a different vendor</th></tr></thead><tbody>${
        rows.map(r => `<tr><td>${esc(MATCH_KINDS[F(r, "matchKind")] || F(r, "matchKind"))}</td>
          <td>${esc([F(r, "matchCode"), F(r, "matchName")].filter(Boolean).join(" - "))}</td>
          <td>${esc(F(r, "matchStatus") || F(r, "matchStatusCode") || "")}</td><td>${esc(F(r, "matchReason"))}</td>
          <td><textarea rows="2" maxlength="1000" data-dup-rationale="${esc(F(r, "matchId"))}" aria-label="Why it is a different vendor">${esc(prior[F(r, "matchId")] || "")}</textarea></td></tr>`).join("")
      }</tbody></table></div>
      <p class="tprm-note" style="margin-top:6px">${esc(againLabel || "Give the reason for each match and save again. If one of them is the same vendor, cancel and open that vendor instead.")}</p></div>`;
  }
  // The rationale boxes of duplicatesHtml as [{ matchId, rationale }], or
  // null when none is shown.
  function duplicateReviews() {
    const boxes = active ? [...active.part("extra").querySelectorAll("[data-dup-rationale]")] : [];
    if (!boxes.length) return null;
    return JSON.stringify(boxes.map(b => ({ matchId: Number(b.dataset.dupRationale), rationale: b.value.trim() || null })));
  }

  window.gracTprm = {
    U, F, esc, date, dateTime, yes, qs, api, orgs, lookups, form, customFields, customJson, note, confirm,
    badge, band, empty, info, show, hide, stageLabel, STAGES, duplicatesHtml, duplicateReviews, showFormExtra: showExtra,
    navigate, navigationContext, navAttrs, button
  };
})();
