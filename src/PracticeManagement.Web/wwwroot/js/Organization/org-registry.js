// =====================================================================
// org-registry.js  (migrations 569-572) -- Organization Registry screen.
//
// Partials/org-registry.cshtml. Fields come from org-registry-fields.js
// (window.gracOrgRegistryFields, generated with the migrations); every rule
// is enforced by the sp_orgreg_<area>_save procedures -- this file renders,
// filters and posts.
//
//   Context     the toolbar's Organization and Legal Entity selects (the
//               hierarchy panel was removed 2026-11-16, sir).
//   Tabs        one per area; a row opens the record in a row under it
//               (no popups -- .oa-pl-wrap / .oa-pl-items), Edit turns that
//               row into the form, Add opens the form in a row on top.
//   References  shown as "code - name", linking to the record; picked with
//               a searchable single-select whose options follow the form's
//               Legal Entity (scope le) or Organization (scope org).
//   Controlled  plain selects of sheet 15 values; a value the workbook's
//   values      sample rows use but sheet 15 does not list is marked
//               "not approved" (570).
//
// Talks to /practice/api/org-registry (Controllers/OrgRegistryController).
// The API answers PascalCase column names; F() reads either case.
// =====================================================================
(() => {
  "use strict";

  const ALL_AREAS = window.gracOrgRegistryFields || [];
  const PAGE = window.gracOrgRegistryPage || {};
  const BY = Object.fromEntries(ALL_AREAS.map(a => [a.key, a]));

  // 574: the thirteen areas in three menus (one screen key each). A page
  // shows the tabs of its own menu; a link to an area of another menu goes
  // to that menu's page (the record travels in sessionStorage, never in
  // the URL -- standing rule: no record ids in the address bar).
  //
  // 575: Organization Management (org-registry) keeps Organizations and
  // Legal Entities; the rest is Practice Management -> Organization, where
  // an organization's own users maintain it and Organizations / Legal
  // Entities are read-only. Must match OrgRegistryController.ScreenAreas.
  const GROUPS = {
    "org-registry":            ["organizations", "legal-entities"],
    "org-registry-structure":  ["organizations", "legal-entities", "units", "locations", "departments"],
    "org-registry-people":     ["people", "teams", "committees", "committee-members"],
    "org-registry-operations": ["functions", "processes", "products", "channels"]
  };
  const SCREEN = GROUPS[PAGE.screen] ? PAGE.screen : "org-registry";
  const AREAS = GROUPS[SCREEN].map(k => BY[k]).filter(Boolean);
  // The screens of this module: a link never leaves the module.
  const MODULE = SCREEN === "org-registry" ? ["org-registry"]
    : ["org-registry-structure", "org-registry-people", "org-registry-operations"];
  const screenOf = area => MODULE.find(k => GROUPS[k].includes(area)) || null;
  const linkable = area => !!screenOf(area);
  const READ_ONLY = SCREEN === "org-registry" ? [] : ["organizations", "legal-entities"];
  const editable = area => !READ_ONLY.includes(area);
  const HANDOFF = "gracOrgRegistryGoto";
  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const API = p => U("/practice/api/org-registry" + p);
  const CSRF = () => document.querySelector('meta[name="csrf-token"]')?.content
                  || document.querySelector("input[name='__RequestVerificationToken']")?.value || "";
  const F = (o, k) => o == null ? undefined : (o[k] !== undefined ? o[k] : o[k.charAt(0).toLowerCase() + k.slice(1)]);
  const P = k => k.charAt(0).toUpperCase() + k.slice(1);
  const base = k => k.endsWith("Id") ? k.slice(0, -2) : k;
  const esc = v => String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const fmtDate = v => {
    if (!v) return "";
    const d = String(v).substring(0, 10);
    return typeof window.gracFormatDisplayDate === "function" ? (window.gracFormatDisplayDate(d) || d) : d;
  };
  const $ = id => document.getElementById(id);

  // Statuses offered by each area's status filter (the area's status list).
  const STATUS_GROUP = { products: "ProductStatus", channels: "ChannelStatus" };

  const state = {
    orgId: 0, leId: 0, tab: AREAS[0].key === "organizations" ? "legal-entities" : AREAS[0].key,
    masters: new Map(), records: new Map(),
    rows: [], open: null, mode: null, loadSeq: 0
  };

  // ------------------------------------------------------------------ api
  async function call(method, path, body) {
    const headers = body ? { "Content-Type": "application/json", "X-CSRF-TOKEN": CSRF() } : undefined;
    const url = API(path) + (path.includes("?") ? "&" : "?") + "screen=" + encodeURIComponent(SCREEN);
    const res = await fetch(url, { method, credentials: "same-origin", headers, body: body ? JSON.stringify(body) : undefined });
    let data = null;
    try { data = await res.json(); } catch (_) { /* non-JSON */ }
    if (!res.ok) {
      const err = new Error((data && (data.error || data.message)) || `Request failed (HTTP ${res.status})`);
      err.field = data && data.field;
      throw err;
    }
    return data || {};
  }
  const qs = o => new URLSearchParams(Object.entries(o).filter(([, v]) => v !== undefined && v !== null && v !== "")).toString();

  function setMsg(text, kind) {
    const el = $("orrMessage");
    el.hidden = !text;
    el.className = "pm-message" + (kind ? " " + kind : "");
    el.textContent = text || "";
  }

  // -------------------------------------------------------------- lookups
  async function loadLookups() {
    const body = await call("GET", "/lookups?" + qs({ registryOrganizationId: 0 }));
    const d = body.data || {};
    state.masters = new Map();
    (d.masters || []).forEach(m => {
      const g = F(m, "Group");
      if (!state.masters.has(g)) state.masters.set(g, []);
      state.masters.get(g).push({ value: F(m, "Value"), approved: !!F(m, "IsWorkbookValue") || F(m, "IsWorkbookValue") === 1,
                                  note: F(m, "Note"), le: F(m, "LegalEntityId") });
    });
    state.records = new Map();
    (d.records || []).forEach(r => {
      const k = F(r, "Kind");
      if (!state.records.has(k)) state.records.set(k, []);
      state.records.get(k).push({ id: Number(F(r, "Id")), code: F(r, "Code") || "", name: F(r, "Name") || "",
                                  le: F(r, "LegalEntityId") == null ? null : Number(F(r, "LegalEntityId")),
                                  org: F(r, "RegistryOrganizationId") == null ? null : Number(F(r, "RegistryOrganizationId")),
                                  parent: F(r, "ParentId") == null ? null : Number(F(r, "ParentId")),
                                  status: F(r, "Status") || "" });
    });
  }
  const recs = kind => state.records.get(kind) || [];
  const rec = (kind, id) => recs(kind).find(r => r.id === Number(id));
  const label = r => r ? [r.code, r.name].filter(Boolean).join(" - ") : "";
  const masterOf = (group, value) => (state.masters.get(group) || []).find(m => m.value === value);

  function renderOrgSelect() {
    const sel = $("orrOrg");
    const orgs = recs("organizations");
    sel.innerHTML = `<option value="0">All Organizations</option>`
      + orgs.map(o => `<option value="${o.id}"${o.id === state.orgId ? " selected" : ""}>${esc(label(o))}</option>`).join("");
  }

  // ------------------------------------------------------------- toolbar
  function renderTabs() {
    $("orrTabs").innerHTML = AREAS.map(a =>
      `<button type="button" role="tab" data-tab="${a.key}" class="${a.key === state.tab ? "active" : ""}" aria-selected="${a.key === state.tab}">${esc(a.title)}</button>`).join("");
  }
  function renderLeSelect() {
    const sel = $("orrLegalEntity");
    const les = recs("legal-entities").filter(l => state.orgId === 0 || l.org === state.orgId);
    if (state.leId && !les.some(l => l.id === state.leId)) state.leId = 0;
    sel.innerHTML = `<option value="0">All Legal Entities</option>`
      + les.map(l => `<option value="${l.id}"${l.id === state.leId ? " selected" : ""}>${esc(label(l))}</option>`).join("");
    sel.disabled = state.tab === "organizations";
  }
  function renderStatusSelect() {
    const area = BY[state.tab];
    const group = STATUS_GROUP[area.key] || "RecordStatus";
    const cur = $("orrStatus").dataset.area === area.key ? $("orrStatus").value : "All";
    $("orrStatus").dataset.area = area.key;
    $("orrStatus").innerHTML = `<option value="All">All statuses</option>`
      + (state.masters.get(group) || []).map(m => `<option value="${esc(m.value)}"${m.value === cur ? " selected" : ""}>${esc(m.value)}</option>`).join("");
  }
  function renderContext() {
    const add = $("orrAddText");
    if (add) add.textContent = `Add ${BY[state.tab].single}`;
    // Organizations / Legal Entities are read-only outside Organization Management.
    const btn = $("orrAdd");
    if (btn) btn.style.display = editable(state.tab) ? "" : "none";
  }

  // ----------------------------------------------------------------- list
  function cellHtml(area, f, row) {
    const v = F(row, P(f.key));
    switch (f.kind) {
      case "ref": {
        if (v == null) return "";
        const code = F(row, P(base(f.key)) + "Code"), name = F(row, P(base(f.key)) + "Name");
        const text = esc([code, name].filter(Boolean).join(" - "));
        return linkable(f.ref) ? `<a href="#" class="orr-cell-ref" data-goto-tab="${f.ref}" data-goto-id="${Number(v)}">${text}</a>` : text;
      }
      case "date": return esc(fmtDate(v));
      case "choice": return esc(choiceLabel(f, v));
      case "master": case "locationtype": case "designation": case "timezone": {
        if (v == null || v === "") return "";
        const m = masterOf(f.group, v);
        return esc(v) + (m && !m.approved ? ` <span class="pm-badge orr-flag" title="${esc(m.note || "")}">not approved</span>` : "");
      }
      case "multiref": case "multimaster": {
        const items = parseList(v);
        return items.map(i => `<span class="pm-badge">${esc(f.kind === "multiref" ? (i.code || i.name) : i.v)}</span>`).join(" ");
      }
      default: return esc(v ?? "");
    }
  }
  // A fixed code list (Criticality, Team Sourcing): the code is stored, the label shown.
  function choiceLabel(f, v) {
    if (v == null || v === "") return "";
    const c = (f.choices || []).find(x => x.value === v);
    return c ? c.label : String(v);
  }
  function parseList(v) {
    if (!v) return [];
    if (Array.isArray(v)) return v;
    try { const x = JSON.parse(v); return Array.isArray(x) ? x : []; } catch (_) { return []; }
  }

  function renderHead() {
    const area = BY[state.tab];
    $("orrHead").innerHTML = area.listColumns.map(k => `<th>${esc(area.fields.find(f => f.key === k).label)}</th>`).join("");
  }
  function renderRows() {
    const area = BY[state.tab];
    const cols = area.listColumns.length;
    const body = $("orrRows");
    if (!state.rows.length) {
      body.innerHTML = `<tr><td colspan="${cols}" class="pm-empty">No ${esc(area.title.toLowerCase())} found for this selection.</td></tr>`;
    } else {
      body.innerHTML = state.rows.map(r => {
        const id = Number(F(r, "Id"));
        return `<tr class="pm-row-clickable${state.open === id ? " oa-pl-open" : ""}" data-id="${id}">`
          + area.listColumns.map(k => `<td>${cellHtml(area, area.fields.find(f => f.key === k), r)}</td>`).join("") + `</tr>`;
      }).join("");
    }
    if (state.mode === "add") openRow(0, "add");
    else if (state.open != null) openRow(state.open, state.mode || "view");
  }

  async function loadRows() {
    const seq = ++state.loadSeq;
    const area = BY[state.tab];
    renderHead();
    $("orrRows").innerHTML = `<tr><td colspan="${area.listColumns.length}" class="pm-empty">Loading ${esc(area.title.toLowerCase())}...</td></tr>`;
    try {
      const body = await call("GET", `/${area.key}?` + qs({
        registryOrganizationId: area.key === "organizations" ? (state.orgId > 0 ? state.orgId : 0) : state.orgId,
        legalEntityId: area.key === "organizations" ? 0 : state.leId,
        status: $("orrStatus").value, search: $("orrSearch").value.trim()
      }));
      if (seq !== state.loadSeq) return;
      state.rows = body.data || [];
      renderRows();
    } catch (err) {
      if (seq !== state.loadSeq) return;
      state.rows = [];
      $("orrRows").innerHTML = `<tr><td colspan="${area.listColumns.length}" class="pm-empty">Could not load ${esc(area.title.toLowerCase())}.</td></tr>`;
      setMsg(err.message, "");
    }
  }

  // ---------------------------------------------------------- record row
  function closeRow() {
    document.querySelectorAll("#orrRows tr.oa-pl-items-row").forEach(tr => tr.remove());
    document.querySelectorAll("#orrRows tr.oa-pl-open").forEach(tr => tr.classList.remove("oa-pl-open"));
    state.open = null;
    state.mode = null;
  }
  function childRow(anchor) {
    const area = BY[state.tab];
    document.querySelectorAll("#orrRows tr.oa-pl-items-row").forEach(tr => tr.remove());
    const tr = document.createElement("tr");
    tr.className = "oa-pl-items-row is-selected";
    tr.innerHTML = `<td colspan="${area.listColumns.length}"><div class="oa-pl-items"></div></td>`;
    if (anchor) anchor.insertAdjacentElement("afterend", tr);
    else $("orrRows").insertAdjacentElement("afterbegin", tr);
    return tr.querySelector(".oa-pl-items");
  }
  function openRow(id, mode) {
    const area = BY[state.tab];
    document.querySelectorAll("#orrRows tr.oa-pl-open").forEach(tr => tr.classList.remove("oa-pl-open"));
    if (mode === "add") {
      state.open = null; state.mode = "add";
      renderForm(childRow(null), area, null);
      return;
    }
    const row = state.rows.find(r => Number(F(r, "Id")) === Number(id));
    const tr = document.querySelector(`#orrRows tr[data-id="${Number(id)}"]`);
    if (!row || !tr) { state.open = null; state.mode = null; return; }
    tr.classList.add("oa-pl-open");
    state.open = Number(id); state.mode = mode;
    const host = childRow(tr);
    if (mode === "edit") renderForm(host, area, row);
    else renderView(host, area, row);
  }

  function noteIcon(f) {
    return f.note ? `<i class="fa-solid fa-circle-info orr-note" title="${esc(f.note)}" aria-label="${esc(f.note)}"></i>` : "";
  }
  function renderView(host, area, row) {
    const facts = area.fields.map(f => {
      const html = cellHtml(area, f, row);
      const wide = f.full ? " orr-wide" : "";
      return `<div class="${wide.trim()}"><dt>${esc(f.label)}${noteIcon(f)}</dt><dd class="${html ? "" : "orr-empty"}">${html || "Not recorded"}</dd></div>`;
    }).join("");
    const by = F(row, "UpdatedBy"), at = F(row, "UpdatedDate");
    host.innerHTML = `<p class="orr-title"><span class="orr-code">${esc(F(row, "Code"))}</span>${esc(F(row, "Name") || "")}</p>
      <dl class="orr-facts">${facts}</dl>
      <div class="orr-actions">
        <span class="pm-cell-muted" style="margin-right:auto;">${by ? `Last saved by ${esc(by)}${at ? " on " + esc(fmtDate(at)) : ""}` : ""}</span>
        ${PAGE.canEdit && editable(area.key) ? `<button type="button" class="pm-button primary" data-row-edit><i class="fa-solid fa-pen" aria-hidden="true"></i> Edit</button>` : ""}
        <button type="button" class="pm-button" data-row-close>Close</button>
      </div>`;
  }

  // ----------------------------------------------------------------- form
  // Options of a reference field, following the form's Legal Entity
  // (scope le) or Organization (scope org).
  function formContext(host) {
    const v = k => host.querySelector(`[data-f="${k}"]`)?.value || "";
    const area = BY[state.tab];
    let le = Number(v("legalEntityId")) || null;
    if (area.key === "committee-members") le = rec("committees", v("committeeId"))?.le ?? null;
    if (area.key === "legal-entities") le = Number(host.dataset.recordId) || null;
    const org = area.key === "legal-entities" ? (Number(v("registryOrganizationId")) || null) : (le ? rec("legal-entities", le)?.org ?? null : null);
    return { le, org };
  }
  function refOptions(f, ctx, selfId) {
    let list = recs(f.ref);
    if (f.ref === "legal-entities" && f.key === "legalEntityId") {
      // The record's own Legal Entity: those of the current Organization context.
      if (state.orgId > 0) list = list.filter(l => l.org === state.orgId);
    } else if (f.scope === "le") {
      list = ctx.le ? list.filter(r => r.le === ctx.le) : [];
    } else if (f.scope === "org") {
      list = list.filter(r => (ctx.le && r.le === ctx.le) || (ctx.org && r.org === ctx.org));
    }
    if (f.ref === state.tab && selfId) list = list.filter(r => r.id !== selfId);
    return list;
  }
  function masterOptions(f, ctx, current) {
    let list = state.masters.get(f.group) || [];
    if (f.kind === "designation") list = list.filter(m => m.le == null || m.le === ctx.le);
    if (f.only) list = list.filter(m => f.only.includes(m.value));
    const opts = list.map(m => ({ value: m.value, label: m.value + (m.approved ? "" : " (not approved)") }));
    if (current && !opts.some(o => o.value === current)) opts.unshift({ value: current, label: current + " (not in the list)" });
    return opts;
  }

  function refHtml(f, options, current, disabled) {
    const cur = options.find(o => o.id === Number(current)) || (current ? { id: Number(current), code: "", name: "(not available in this context)" } : null);
    const opts = [`<label data-checkcombo-option><input type="radio" name="orr-${f.key}" value=""${cur ? "" : " checked"} /> <span>-- None --</span></label>`]
      .concat(options.map(o => `<label data-checkcombo-option><input type="radio" name="orr-${f.key}" value="${o.id}"${cur && cur.id === o.id ? " checked" : ""} /> <span>${esc(label(o))}</span></label>`));
    return `<div class="pm-checkcombo orr-ref" data-ref="${f.key}">
        <button class="pm-checkcombo-trigger" type="button" data-ref-trigger aria-expanded="false"${disabled ? " disabled" : ""}>
          <span data-ref-text>${cur ? esc(label(cur)) : '<span class="pm-checkcombo-placeholder">Select...</span>'}</span><span class="pm-checkcombo-caret" aria-hidden="true">&#9662;</span>
        </button>
        <div class="pm-checkcombo-menu" data-ref-menu hidden>
          <input class="pm-checkcombo-search" type="search" placeholder="Search code or name..." data-ref-search aria-label="Search ${esc(f.label)}" />
          <div class="pm-checkcombo-options">${opts.join("")}</div>
        </div>
        <input type="hidden" data-f="${f.key}" value="${cur ? cur.id : ""}" />
      </div>`;
  }

  function fieldHtml(f, value, ctx, selfId) {
    const req = f.required ? " *" : "";
    const lab = `<span>${esc(f.label)}${req}${noteIcon(f)}</span>`;
    const ro = f.readonly ? " disabled" : "";
    const full = f.full ? "full" : "";
    const v = value == null ? "" : value;
    switch (f.kind) {
      case "textarea":
        return `<label class="${full}">${lab}<textarea data-f="${f.key}" rows="3"${f.maxLength ? ` maxlength="${f.maxLength}"` : ""}${ro}>${esc(v)}</textarea></label>`;
      case "date":
        return `<label>${lab}<input type="date" data-f="${f.key}" value="${esc(String(v).substring(0, 10))}"${ro} /></label>`;
      case "number":
        return `<label>${lab}<input type="number" min="0" step="1" data-f="${f.key}" value="${esc(v)}"${ro} /></label>`;
      case "decimal":
        return `<label>${lab}<input type="number" step="0.000001" data-f="${f.key}" value="${esc(v)}"${ro} /></label>`;
      case "choice": {
        const opts = (f.choices || []).slice();
        if (v && !opts.some(o => o.value === v)) opts.unshift({ value: v, label: v + " (not in the list)" });
        return `<label>${lab}<select data-f="${f.key}"${ro}><option value="">--</option>${opts.map(o =>
          `<option value="${esc(o.value)}"${o.value === v ? " selected" : ""}>${esc(o.label)}</option>`).join("")}</select></label>`;
      }
      case "master": case "locationtype": case "designation": case "timezone": {
        const opts = masterOptions(f, ctx, v);
        return `<label>${lab}<select data-f="${f.key}"${ro}><option value="">--</option>${opts.map(o =>
          `<option value="${esc(o.value)}"${o.value === v ? " selected" : ""}>${esc(o.label)}</option>`).join("")}</select></label>`;
      }
      case "ref": {
        const opts = refOptions(f, ctx, selfId);
        // The record's current choice stays visible even outside the context.
        if (v && !opts.some(o => o.id === Number(v)) && rec(f.ref, v)) opts.unshift(rec(f.ref, v));
        return `<div class="orr-ref-field">${lab}${refHtml(f, opts, v, f.readonly)}</div>`;
      }
      case "multiref": {
        const chosen = parseList(v).map(i => String(i.id));
        const opts = refOptions(f, ctx, selfId).map(o => ({ value: String(o.id), label: label(o) }));
        return `<div class="full" data-multi="${f.key}">${lab}${window.gracCheckCombo.html(opts, chosen, { ariaLabel: f.label })}</div>`;
      }
      case "multimaster": {
        const chosen = parseList(v).map(i => i.v);
        const opts = masterOptions(f, ctx, null);
        chosen.filter(c => !opts.some(o => o.value === c)).forEach(c => opts.unshift({ value: c, label: c + " (not in the list)" }));
        return `<div class="full" data-multi="${f.key}">${lab}${window.gracCheckCombo.html(opts, chosen, { ariaLabel: f.label })}</div>`;
      }
      default: {
        const type = f.kind === "email" ? "email" : f.kind === "url" ? "url" : "text";
        const ph = f.kind === "ddmm" ? ' placeholder="DD-MM"' : f.kind === "code" ? ` placeholder="e.g. ${esc(BY[state.tab].prefix)}-0001"` : "";
        return `<label class="${full}">${lab}<input type="${type}" data-f="${f.key}" value="${esc(v)}"${f.maxLength ? ` maxlength="${f.maxLength}"` : ""}${ph}${ro} /></label>`;
      }
    }
  }

  // Raw values of the record as the form starts with them.
  function startValues(area, row) {
    const vals = {};
    area.fields.forEach(f => {
      if (!row) {
        if (f.key === "legalEntityId" && state.leId) vals[f.key] = String(state.leId);
        else if (f.key === "registryOrganizationId" && state.orgId > 0) vals[f.key] = String(state.orgId);
        else if (f.key === area.statusField || f.key === "recordStatus") vals[f.key] = "Active";
        else if (f.default) vals[f.key] = f.default;
        else vals[f.key] = "";
        return;
      }
      const v = F(row, P(f.key));
      vals[f.key] = v == null ? "" : (f.kind === "ref" ? String(v) : v);
    });
    return vals;
  }

  function renderForm(host, area, row, values) {
    const selfId = row ? Number(F(row, "Id")) : 0;
    host.dataset.recordId = selfId ? String(selfId) : "";
    const vals = values || startValues(area, row);
    // Context first (the fields that drive the others), from the values.
    host.innerHTML = Object.entries(vals).map(([k, v]) => `<input type="hidden" data-f="${k}" value="${esc(typeof v === "string" ? v : "")}" />`).join("");
    const ctx = formContext(host);
    const intro = area.key === "legal-entities" && !row
      ? `<p class="orr-form-note">Saving a new Legal Entity creates a GRAC organization. Its administrator, users and framework subscriptions are set up from Organization Setup.</p>`
      : area.key === "people" ? `<p class="orr-form-note">Official work details only -- no Aadhaar, PAN, date of birth, home address, salary or bank details (workbook guidance). A person cannot sign in to GRAC unless a password is set through Users.</p>` : "";
    host.innerHTML = `<p class="orr-title">${row ? `Edit <span class="orr-code">${esc(F(row, "Code"))}</span>${esc(F(row, "Name") || "")}` : `New ${esc(area.single)}`}</p>
      ${intro}
      <form class="pm-form-grid orr-form" novalidate>
        ${area.fields.map(f => fieldHtml(f, vals[f.key], ctx, selfId)).join("")}
        <p class="pm-message full" data-form-msg role="status" aria-live="polite" hidden></p>
        <div class="full orr-actions">
          <button type="button" class="pm-button" data-row-cancel>Cancel</button>
          <button type="submit" class="pm-button primary"><i class="fa-solid fa-floppy-disk" aria-hidden="true"></i> Save</button>
        </div>
      </form>`;
    const form = host.querySelector("form");
    window.gracCheckCombo.wire(form);
    wireRefs(form);
    form.addEventListener("submit", ev => { ev.preventDefault(); save(form, area, row); });
    // A change to the Legal Entity / Organization / Committee re-filters
    // the dependent pickers (keeping what is still valid).
    form.addEventListener("change", ev => {
      const k = ev.target.closest("[data-f]")?.dataset.f || ev.target.closest("[data-ref]")?.dataset.ref;
      if (!["legalEntityId", "registryOrganizationId", "committeeId"].includes(k)) return;
      const now = readForm(form, area);
      const raw = {};
      area.fields.forEach(f => {
        const v = now[f.key];
        raw[f.key] = f.kind === "multiref" ? JSON.stringify((v || []).map(id => ({ id: Number(id) })))
          : f.kind === "multimaster" ? JSON.stringify((v || []).map(x => ({ v: x }))) : (v == null ? "" : String(v));
      });
      renderForm(host, area, row, raw);
    });
  }

  // Single-select reference pickers: open / search / pick (delegated).
  function wireRefs(form) {
    const closeAll = except => form.querySelectorAll("[data-ref]").forEach(c => {
      if (c === except) return;
      c.querySelector("[data-ref-menu]").hidden = true;
      c.querySelector("[data-ref-trigger]").setAttribute("aria-expanded", "false");
    });
    form.addEventListener("click", ev => {
      const t = ev.target.closest("[data-ref-trigger]");
      if (!t) return;
      ev.preventDefault();
      const combo = t.closest("[data-ref]");
      const menu = combo.querySelector("[data-ref-menu]");
      closeAll(combo);
      menu.hidden = !menu.hidden;
      t.setAttribute("aria-expanded", menu.hidden ? "false" : "true");
      if (!menu.hidden) menu.querySelector("[data-ref-search]")?.focus();
    });
    form.addEventListener("input", ev => {
      const s = ev.target.closest("[data-ref-search]");
      if (!s) return;
      const q = s.value.trim().toLowerCase();
      s.closest("[data-ref-menu]").querySelectorAll("[data-checkcombo-option]").forEach(o => {
        o.hidden = !!q && !o.textContent.toLowerCase().includes(q);
      });
    });
    form.addEventListener("change", ev => {
      const combo = ev.target.closest("[data-ref]");
      if (!combo || ev.target.type !== "radio") return;
      combo.querySelector(`input[type="hidden"][data-f]`).value = ev.target.value;
      const text = ev.target.closest("label").querySelector("span").textContent.trim();
      combo.querySelector("[data-ref-text]").innerHTML = ev.target.value ? esc(text) : '<span class="pm-checkcombo-placeholder">Select...</span>';
      combo.querySelector("[data-ref-menu]").hidden = true;
      combo.querySelector("[data-ref-trigger]").setAttribute("aria-expanded", "false");
    });
    document.addEventListener("mousedown", ev => {
      if (!form.isConnected) return;
      if (!form.contains(ev.target) || !ev.target.closest("[data-ref]")) closeAll(null);
    });
  }

  function readForm(form, area) {
    const out = {};
    area.fields.forEach(f => {
      if (f.kind === "multiref" || f.kind === "multimaster") {
        const combo = form.querySelector(`[data-multi="${f.key}"] [data-checkcombo]`);
        out[f.key] = combo ? window.gracCheckCombo.values(combo) : [];
        return;
      }
      // the visible control, not the context hidden input added first
      const els = form.querySelectorAll(`[data-f="${f.key}"]`);
      const el = els[els.length - 1];
      const v = el ? String(el.value ?? "").trim() : "";
      out[f.key] = v === "" ? null : v;
    });
    return out;
  }

  async function save(form, area, row) {
    const msg = form.querySelector("[data-form-msg]");
    form.querySelectorAll("[aria-invalid]").forEach(el => el.removeAttribute("aria-invalid"));
    msg.hidden = true;
    const data = readForm(form, area);
    // Saved as entered; the procedure checks everything. Only the obvious
    // required-field gap is caught here, to save a round trip.
    const missing = area.fields.find(f => f.required && !f.readonly && (data[f.key] == null || data[f.key] === ""));
    if (missing) return fail(form, msg, missing.key, `${missing.label} is required.`);
    const btn = form.querySelector('button[type="submit"]');
    btn.disabled = true;
    try {
      const id = row ? Number(F(row, "Id")) : 0;
      const body = await call(id ? "PUT" : "POST", id ? `/${area.key}/${id}` : `/${area.key}`, { data });
      const savedId = Number(body.id || id);
      setMsg(body.message || `${area.single} saved.`, "success");
      await loadLookups();
      renderOrgSelect(); renderLeSelect();
      state.open = savedId || null; state.mode = savedId ? "view" : null;
      await loadRows();
    } catch (err) {
      fail(form, msg, err.field, err.message);
    } finally {
      btn.disabled = false;
    }
  }
  function fail(form, msg, field, text) {
    msg.hidden = false;
    msg.className = "pm-message full";
    msg.textContent = text;
    if (field) {
      const ref = form.querySelector(`[data-ref="${field}"]`);
      const el = ref || form.querySelector(`[data-multi="${field}"]`) || [...form.querySelectorAll(`[data-f="${field}"]`)].pop();
      if (el) {
        el.setAttribute("aria-invalid", "true");
        (el.querySelector?.("button") || el).focus?.();
      }
    }
  }

  // ----------------------------------------------------------- navigation
  async function selectTab(key, opts) {
    closeRow();
    state.tab = key;
    renderTabs(); renderLeSelect(); renderStatusSelect(); renderContext();
    if (opts && opts.openId) state.open = Number(opts.openId), state.mode = "view";
    await loadRows();
  }
  // A reference link: the target record's tab, in its Legal Entity, opened.
  async function goTo(tab, id, leId) {
    if (!GROUPS[SCREEN].includes(tab)) {
      if (!screenOf(tab)) return;
      // Another menu's area: hand the target over and open that page.
      try { sessionStorage.setItem(HANDOFF, JSON.stringify({ tab, id: Number(id) || 0, le: Number(leId) || 0, org: state.orgId })); } catch (_) { /* storage off: the page opens unfiltered */ }
      window.location.assign(U("/" + screenOf(tab)));
      return;
    }
    const r = rec(tab, id);
    if (tab === "organizations") { state.orgId = Number(id); state.leId = 0; }
    else {
      const le = leId ? Number(leId) : (tab === "legal-entities" ? null : (r ? r.le : null));
      const leRec = le ? rec("legal-entities", le) : (tab === "legal-entities" ? r : null);
      if (leRec) state.orgId = leRec.org == null || state.orgId === 0 ? 0 : leRec.org;
      state.leId = tab === "legal-entities" ? 0 : (le || 0);
    }
    $("orrSearch").value = "";
    renderOrgSelect();
    await selectTab(tab, id ? { openId: id } : null);
  }

  function wire() {
    $("orrTabs").addEventListener("click", ev => {
      const b = ev.target.closest("[data-tab]");
      if (b) selectTab(b.dataset.tab);
    });
    $("orrOrg").addEventListener("change", () => {
      state.orgId = Number($("orrOrg").value) || 0; state.leId = 0;
      selectTab(state.tab);
    });
    $("orrLegalEntity").addEventListener("change", () => {
      state.leId = Number($("orrLegalEntity").value) || 0;
      closeRow(); loadRows();
    });
    $("orrStatus").addEventListener("change", () => { closeRow(); loadRows(); });
    let timer = null;
    $("orrSearch").addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(() => { closeRow(); loadRows(); }, 300); });
    $("orrRefresh").addEventListener("click", () => init(true));
    $("orrAdd")?.addEventListener("click", () => { closeRow(); openRow(0, "add"); });
    $("orrRows").addEventListener("click", ev => {
      const link = ev.target.closest("[data-goto-tab]");
      if (link) { ev.preventDefault(); goTo(link.dataset.gotoTab, link.dataset.gotoId); return; }
      if (ev.target.closest("[data-row-close]") || ev.target.closest("[data-row-cancel]")) {
        const wasEdit = state.mode === "edit" ? state.open : null;
        closeRow();
        if (wasEdit) openRow(wasEdit, "view");
        return;
      }
      if (ev.target.closest("[data-row-edit]")) { openRow(state.open, "edit"); return; }
      if (ev.target.closest(".oa-pl-items")) return;
      const tr = ev.target.closest("tr[data-id]");
      if (!tr) return;
      const id = Number(tr.dataset.id);
      if (state.open === id) closeRow();
      else { closeRow(); openRow(id, "view"); }
    });
  }

  async function init(refresh) {
    if (!PAGE.mayUse) {
      $("orrRows").innerHTML = `<tr><td class="pm-empty">Organizations and Legal Entities are maintained by a platform (GLOBAL scope) administrator.</td></tr>`;
      return;
    }
    try {
      setMsg("");
      await loadLookups();
    } catch (err) {
      $("orrRows").innerHTML = `<tr><td class="pm-empty">Could not load the registry.</td></tr>`;
      setMsg(err.message, "");
      return;
    }
    renderOrgSelect();
    if (!refresh) { renderTabs(); }
    // Opened from a link on another registry menu (574).
    let handoff = null;
    if (!refresh) {
      try { handoff = JSON.parse(sessionStorage.getItem(HANDOFF) || "null"); sessionStorage.removeItem(HANDOFF); } catch (_) { handoff = null; }
    }
    if (handoff && GROUPS[SCREEN].includes(handoff.tab)) {
      state.orgId = Number(handoff.org) || 0;
      await goTo(handoff.tab, handoff.id, handoff.le);
      return;
    }
    await selectTab(state.tab);
  }

  function start() {
    if (!AREAS.length || !window.gracCheckCombo) {
      setMsg("The registry field definitions did not load. Hard-refresh the page.", "");
      return;
    }
    wire();
    init(false);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
