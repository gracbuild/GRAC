// =====================================================================
// tprm-common.js  (migrations 486-490, Third-Party Risk Management)
//
// window.gracTprm -- what the four TPRM screens share, written once:
//   api(method, path, body)   practice/api/tprm + path (TprmController);
//                             { ok, status, data, error }
//   orgs(selectId)            fills an organization picker (allowed orgs,
//                             last-picked org -- gracOrgPref)
//   lookups(orgId)            sp_tprm_lookups for the organization, cached:
//                             .values(list) .label(list, code)
//                             .badge(list, code) .employees ...
//   form({ title, intro, fields, submitText, wide, validate })
//                             the shared form dialog
//                             (Partials/_tprm-form-dialog.cshtml); resolves
//                             with the values, or null on Cancel
//   customFields(lk, entity, current) / customJson(values)
//                             organization custom fields (486) as form
//                             fields, and the @custom_json they save as
//   F esc date dateTime show hide empty info badge band stageLabel
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
  async function orgs(selectId) {
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
    const wanted = new URLSearchParams(window.location.search).get("organizationId");
    if (wanted && [...sel.options].some(o => o.value === wanted)) sel.value = wanted;
    else window.gracOrgPref?.apply(sel);   // last-picked org, else lowest id
    return Number(sel.value) || null;
  }

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
      applications: set("applications"), vendors: set("vendors"), contracts: set("contracts"), library: set("library"),
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
  //          blank, rows, maxLength, min, max, step, readonly }
  //   type: text | textarea | number | date | select | multi | checkbox |
  //         section (a heading) | note (read-only text)
  //   options: [{ value, label }]  (select / multi)
  let formResolver = null, formDef = null, formWired = false;
  function wireForm() {
    if (formWired) return;
    formWired = true;
    const close = () => finishForm(null);
    document.getElementById("tprmFormClose").addEventListener("click", close);
    document.getElementById("tprmFormCancel").addEventListener("click", close);
    document.getElementById("tprmForm").addEventListener("submit", async ev => {
      ev.preventDefault();
      const values = readForm();
      const missing = formDef.fields.filter(f => f.required && f.type !== "section" && f.type !== "note"
        && (values[f.name] === null || values[f.name] === "" || (Array.isArray(values[f.name]) && !values[f.name].length)));
      if (missing.length) { show("tprmFormMessage", `${missing[0].label} is required.`); return; }
      if (formDef.validate) {
        const problem = formDef.validate(values);
        if (problem) { show("tprmFormMessage", problem); return; }
      }
      if (formDef.onSubmit) {
        // The dialog stays open on a refusal so the user can correct it.
        const btn = document.getElementById("tprmFormSubmit");
        btn.disabled = true;
        show("tprmFormMessage", "Saving...", "info");
        const res = await formDef.onSubmit(values).catch(err => ({ ok: false, error: err.message }));
        btn.disabled = false;
        if (!res || !res.ok) {
          if (res && res.extraHtml) { showExtra(res.extraHtml); hide("tprmFormMessage"); }
          else show("tprmFormMessage", (res && res.error) || "Could not save.");
          return;
        }
        finishForm({ values, result: res });
        return;
      }
      finishForm(values);
    });
  }
  function showExtra(html) {
    const el = document.getElementById("tprmFormExtra");
    el.innerHTML = html || "";
    el.hidden = !html;
  }
  function finishForm(result) {
    document.getElementById("tprmFormModal").hidden = true;
    if (formResolver) { const r = formResolver; formResolver = null; r(result); }
  }
  function fieldHtml(f, i) {
    const id = `tprmF${i}`;
    const full = f.full || ["textarea", "multi", "section", "note"].includes(f.type) ? " full" : "";
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
        const chosen = new Set((Array.isArray(v) ? v : String(v).split(",")).map(x => String(x).trim()).filter(Boolean));
        return `<div class="full"><span>${esc(f.label)}${req}</span><div class="tprm-multi" data-tf-multi="${esc(f.name)}">${
          (f.options || []).map(o => `<label><input type="checkbox" value="${esc(o.value)}"${chosen.has(String(o.value)) ? " checked" : ""}${ro} /> ${esc(o.label)}</label>`).join("")
          || '<span class="tprm-muted">Nothing to choose from.</span>'}</div>${help}</div>`;
      }
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
  function readForm() {
    const out = {};
    const host = document.getElementById("tprmFormFields");
    host.querySelectorAll("[data-tf]").forEach(el => {
      const f = formDef.fields.find(x => x.name === el.dataset.tf);
      if (el.type === "checkbox") out[el.dataset.tf] = el.checked;
      else if (f && f.type === "number") out[el.dataset.tf] = el.value === "" ? null : Number(el.value);
      else out[el.dataset.tf] = el.value.trim() === "" ? null : el.value.trim();
    });
    host.querySelectorAll("[data-tf-multi]").forEach(el => {
      out[el.dataset.tfMulti] = [...el.querySelectorAll("input:checked")].map(x => x.value);
    });
    return out;
  }
  // Resolves with the values (or { values, result } when onSubmit is
  // given and succeeded), or null on Cancel.
  function form(def) {
    wireForm();
    formDef = def;
    document.getElementById("tprmFormTitle").textContent = def.title || "Edit";
    const intro = document.getElementById("tprmFormIntro");
    intro.textContent = def.intro || "";
    intro.hidden = !def.intro;
    document.querySelector("#tprmFormModal .tprm-form-panel").classList.toggle("wide", !!def.wide);
    document.getElementById("tprmFormFields").innerHTML = def.fields.map(fieldHtml).join("");
    document.getElementById("tprmFormSubmit").innerHTML =
      `<i class="fa-solid ${esc(def.submitIcon || "fa-floppy-disk")}"></i> ${esc(def.submitText || "Save")}`;
    hide("tprmFormMessage");
    showExtra(def.extraHtml || "");
    document.getElementById("tprmFormModal").hidden = false;
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
          : ref === "VENDOR" ? lk.vendors.map(v => ({ value: F(v, "vendorId"), label: F(v, "vendorName") }))
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

  // Possible duplicates (409) as HTML for the form's extra area.
  function duplicatesHtml(data, againLabel) {
    const rows = data.duplicates || data.Duplicates || [];
    return `<div class="pm-message info">${esc(data.error || "Possible duplicates found. Nothing was saved.")}
      <div class="pm-table-wrap" style="margin-top:6px"><table><thead><tr><th>Match</th><th>Record</th><th>Why</th></tr></thead><tbody>${
        rows.map(r => `<tr><td>${esc(F(r, "matchKind"))}</td><td>${esc([F(r, "matchCode"), F(r, "matchName")].filter(Boolean).join(" - "))}</td><td>${esc(F(r, "matchReason"))}</td></tr>`).join("")
      }</tbody></table></div>
      <p class="tprm-note" style="margin-top:6px">${esc(againLabel || "Save again with \"Register anyway\" ticked to continue.")}</p></div>`;
  }

  window.gracTprm = {
    U, F, esc, date, dateTime, yes, qs, api, orgs, lookups, form, customFields, customJson, note, confirm,
    badge, band, empty, info, show, hide, stageLabel, STAGES, duplicatesHtml, showFormExtra: showExtra
  };
})();
