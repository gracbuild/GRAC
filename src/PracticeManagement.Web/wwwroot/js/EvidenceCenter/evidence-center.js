// =====================================================================
// Evidence Center (migration 476, Phase 1).
// Loaded by evidence-center.cshtml. Backend: practice/api/evidence-center
//   GET  ?organizationId&search&evidenceTypeId&ownerEmployeeId&validity
//        &usage&status&pageNumber&pageSize          grid
//   GET  lookups?organizationId                      types + employees
//   GET  {id}?organizationId                         item, versions, used in
//   GET  files/{fileId}?organizationId               download one version
//   POST upload?organizationId (multipart)           new item / new version
//        409 = the identical file is already there (open it, or upload anyway)
//   POST {id}/save    { organizationId, ... }        metadata
//   POST {id}/status  { organizationId, action }     Retire / Restore / Delete
// What the caller may see and change is decided by the procedures; the
// buttons only mirror it (CanEdit per item + the screen permissions).
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/evidence-center";
  const root = document.getElementById("ecRoot");
  if (!root) return;
  const CAN_ADD    = root.dataset.canAdd === "1";
  const CAN_EDIT   = root.dataset.canEdit === "1";
  const CAN_DELETE = root.dataset.canDelete === "1";
  const CSRF = document.querySelector('meta[name="csrf-token"]')?.content || "";

  const VALIDITY = { Valid: ["Valid", "ec-valid-valid"], Expiring: ["Expiring", "ec-valid-expiring"],
                     Expired: ["Expired", "ec-valid-expired"], NoExpiry: ["No expiry", ""] };

  // The Api returns column-name rows (PascalCase keys); read either case.
  const F = (o, k) => o == null ? undefined : (o[k] !== undefined ? o[k] : o[k.charAt(0).toUpperCase() + k.slice(1)]);

  const state = { organizationId: null, pager: null, rows: [], lookups: { types: [], employees: [] },
                  detail: null, editMode: null, duplicateItemId: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "ecPager", onChange: refreshList }) : null;
    bind();
    await populateOrgs();
    const sel = document.getElementById("ecOrg");
    window.gracOrgPref?.apply(sel);   // last-picked org, else lowest id
    // Opened from a link ("?itemId=&organizationId=", e.g. an expiry notice
    // on My Notifications, 477): that item's organisation first.
    const params = new URLSearchParams(window.location.search);
    const linkOrg = params.get("organizationId");
    if (linkOrg && [...sel.options].some(o => o.value === linkOrg)) sel.value = linkOrg;
    // 508: opened from the Policies & Documents dashboard (?validity= /
    // ?usage=): the page's own Validity / Used-in filters, plus the banner.
    const drill = window.__pmDrill ? window.__pmDrill.read() : null;
    if (drill && drill.active) {
      window.__pmDrill.preselect("ecValidityFilter", drill.validity);
      window.__pmDrill.preselect("ecUsageFilter", drill.usage);
      window.__pmDrill.banner("ecDrillBanner", drill);
    }
    await changeOrg(Number(sel.value) || null);
    const itemId = Number(params.get("itemId"));
    if (itemId > 0 && state.organizationId) openItem(itemId);
  }

  async function populateOrgs() {
    const sel = document.getElementById("ecOrg");
    try {
      const r = await fetch(U("/practice/api/organizations/allowed"), { credentials: "same-origin" });
      const b = r.ok ? await r.json() : null;
      ((b && (b.data || b.Data)) || []).forEach(row => {
        const value = String(row.organizationId ?? row.OrganizationId ?? "");
        if (!value) return;
        const o = document.createElement("option");
        o.value = value; o.textContent = String(row.organizationName ?? row.OrganizationName ?? value);
        sel.appendChild(o);
      });
    } catch (_) { /* placeholder stays */ }
    if (sel.options.length === 2) sel.disabled = true;
  }

  function bind() {
    document.getElementById("ecOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.getElementById("ecRefresh").addEventListener("click", () => refreshList());
    let t = null;
    document.getElementById("ecSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => { state.pager?.reset(true); refreshList(); }, 300); });
    ["ecTypeFilter", "ecOwnerFilter", "ecValidityFilter", "ecUsageFilter", "ecStatusFilter"].forEach(id =>
      document.getElementById(id).addEventListener("change", () => { state.pager?.reset(true); refreshList(); }));
    document.getElementById("ecUploadNew")?.addEventListener("click", () => openEdit("NEW"));
    document.getElementById("ecListBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-ec-item]");
      if (tr) openItem(Number(tr.dataset.ecItem));
    });
    document.querySelectorAll("[data-close-ec]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeEc).hidden = true; }));
    document.querySelectorAll("[data-ec-tab]").forEach(b => b.addEventListener("click", () => selectTab(b.dataset.ecTab)));
    document.getElementById("ecDetailActions").addEventListener("click", ev => {
      const b = ev.target.closest("[data-ec-action]");
      if (b) itemAction(b.dataset.ecAction);
    });
    // 499: the upload/edit form is owned by Shared/evidence-upload.js now
    // (window.gracEvidenceUpload), which binds its submit and duplicate
    // buttons when it opens and unbinds them when it closes. Binding them
    // here as well would post twice.
  }

  async function changeOrg(id) {
    state.organizationId = id;
    hide("ecMessage");
    state.pager?.reset(true);
    await loadLookups();
    await refreshList();
  }

  async function loadLookups() {
    state.lookups = { types: [], employees: [] };
    const typeSel = document.getElementById("ecTypeFilter");
    const ownerSel = document.getElementById("ecOwnerFilter");
    typeSel.length = 1; ownerSel.length = 1;
    if (!state.organizationId) return;
    const res = await api("GET", `/lookups?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error); return; }
    state.lookups.types = res.data.evidenceTypes || [];
    state.lookups.employees = res.data.employees || [];
    state.lookups.types.forEach(x => typeSel.add(new Option(F(x, "evidenceType"), F(x, "evidenceTypeId"))));
    state.lookups.employees.forEach(x => ownerSel.add(new Option(F(x, "employeeName"), F(x, "employeeId"))));
  }

  // ------------------------------------------------------------------ grid
  async function refreshList() {
    const body = document.getElementById("ecListBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.pager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.pager ? state.pager.page() : 1, pageSize: state.pager ? state.pager.size() : 25,
      status: val("ecStatusFilter") || "Active" });
    if (val("ecSearch")) qs.set("search", val("ecSearch"));
    if (val("ecTypeFilter")) qs.set("evidenceTypeId", val("ecTypeFilter"));
    if (val("ecOwnerFilter")) qs.set("ownerEmployeeId", val("ecOwnerFilter"));
    if (val("ecValidityFilter")) qs.set("validity", val("ecValidityFilter"));
    if (val("ecUsageFilter")) qs.set("usage", val("ecUsageFilter"));
    const res = await api("GET", `?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.pager?.clear(); return; }
    state.rows = res.data.data || [];
    state.pager?.setTotal(res.data.totalRows, state.rows.length);
    body.innerHTML = state.rows.map(r => `<tr data-ec-item="${esc(F(r, "evidenceItemId"))}">
        <td>${esc(F(r, "evidenceTitle"))}<div class="ec-note">${esc(F(r, "fileName") || "")}${F(r, "tags") ? " - " + esc(F(r, "tags")) : ""}</div></td>
        <td>${esc(F(r, "evidenceType") || "--")}</td>
        <td>${esc(F(r, "ownerName") || "--")}</td>
        <td>${validityCell(F(r, "validityState"), F(r, "validTo"))}</td>
        <td>${F(r, "currentVersionNo") ? "v" + esc(F(r, "currentVersionNo")) : "--"}</td>
        <td>${esc(F(r, "usedInCount") ?? 0)}</td>
        <td>${esc(F(r, "classification"))}</td>
        <td>${esc(F(r, "status"))}</td>
      </tr>`).join("") || empty(8, "No evidence found.");
  }

  function validityCell(stateKey, validTo) {
    const [label, css] = VALIDITY[stateKey] || [stateKey || "", ""];
    if (stateKey === "NoExpiry") return `<span class="pm-badge">${esc(label)}</span>`;
    return `${esc(date(validTo))} <span class="pm-badge ${css}">${esc(label)}</span>`;
  }

  // ------------------------------------------------------------------ detail
  async function openItem(id) {
    const res = await api("GET", `/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error); return; }
    state.detail = res.data;
    renderDetail();
    hide("ecDetailMessage");
    document.getElementById("ecDetailModal").hidden = false;
    selectTab("USEDIN");
  }

  async function reloadDetail() {
    if (!state.detail) return;
    const res = await api("GET", `/${F(state.detail.item, "evidenceItemId")}?organizationId=${state.organizationId}`);
    if (res.ok) { state.detail = res.data; renderDetail(); }
  }

  function renderDetail() {
    const it = state.detail.item;
    document.getElementById("ecDetailTitle").textContent = F(it, "evidenceTitle") || "Evidence";
    const currentHref = F(it, "currentFileId")
      ? U(`${base}/files/${F(it, "currentFileId")}?organizationId=${state.organizationId}`) : null;
    document.getElementById("ecDetailInfo").innerHTML = info([
      ["Type", F(it, "evidenceType")],
      ["Owner", F(it, "ownerName")],
      ["Classification", F(it, "classification")],
      ["Status", F(it, "status")],
      ["Valid from", date(F(it, "validFrom")) || "--"],
      ["Valid to", validityCell(F(it, "validityState"), F(it, "validTo")), true],
      ["Current version", currentHref
        ? `<a href="${esc(currentHref)}" target="_blank" rel="noopener">v${esc(F(it, "currentVersionNo"))} - ${esc(F(it, "fileName"))}</a>` : "--", true],
      ["Size", kb(F(it, "fileSizeBytes"))],
      ["Uploaded by", F(it, "createdByName")],
      ["Created", dateTime(F(it, "enteredDt"))],
      ["Tags", F(it, "tags")],
      ["Description", F(it, "evidenceDescription")]
    ]);

    // Buttons: the screen permission AND the item's own edit right.
    const canChange = F(it, "canEdit") === true || F(it, "canEdit") === 1;
    const status = F(it, "status");
    const used = Number(F(it, "usedInCount") || 0);
    const buttons = [];
    if (canChange && CAN_EDIT && status === "Active") {
      buttons.push(`<button type="button" class="pm-button" data-ec-action="EDIT"><i class="fa-solid fa-pen"></i> Edit details</button>`);
      buttons.push(`<button type="button" class="pm-button" data-ec-action="VERSION"><i class="fa-solid fa-code-branch"></i> New version</button>`);
      buttons.push(`<button type="button" class="pm-button" data-ec-action="RETIRE"><i class="fa-solid fa-box-archive"></i> Retire</button>`);
    }
    if (canChange && CAN_EDIT && status === "Retired")
      buttons.push(`<button type="button" class="pm-button" data-ec-action="RESTORE"><i class="fa-solid fa-rotate-left"></i> Restore</button>`);
    if (canChange && CAN_DELETE && used === 0)
      buttons.push(`<button type="button" class="pm-button danger" data-ec-action="DELETE"><i class="fa-solid fa-trash"></i> Delete</button>`);
    document.getElementById("ecDetailActions").innerHTML = buttons.join("");

    const hidden = Number(F(it, "hiddenUsageCount") || 0);
    const hiddenEl = document.getElementById("ecHiddenUsage");
    hiddenEl.hidden = hidden === 0;
    hiddenEl.textContent = hidden ? `Also used in ${hidden} place${hidden === 1 ? "" : "s"} outside your view.` : "";

    // 477: a row is an Operationalize evidence row or a task (TargetType).
    // A task keeps the version it was completed with, so "older" there is
    // information, not something to update.
    document.getElementById("ecUsedInBody").innerHTML = (state.detail.usedIn || []).map(u => {
      const isTask = F(u, "targetType") === "Task";
      const instanceText = [F(u, "instanceCode"), F(u, "instanceName")].filter(Boolean).join(" - ");
      const instanceCell = F(u, "practiceInstanceId")
        ? `<a href="${esc(U(`/Practice/Index/resolve-workspace?instanceId=${encodeURIComponent(F(u, "practiceInstanceId"))}&organizationId=${encodeURIComponent(state.organizationId)}`))}" target="_blank" rel="noopener">${esc(instanceText)}</a>`
        : "--";
      const usedCell = isTask
        ? `<a href="${esc(U(`/Practice/Index/task-view?taskId=${encodeURIComponent(F(u, "taskId"))}`))}">Task ${esc(F(u, "taskNumber") || F(u, "taskId"))}</a>`
          + `<div class="ec-note">${esc(F(u, "taskTitle") || "")}${F(u, "periodDate") ? " - for " + esc(date(F(u, "periodDate"))) : ""}</div>`
        : esc(F(u, "evidenceName") || "--");
      const latest = F(u, "isLatest") === true || F(u, "isLatest") === 1;
      const olderTitle = isTask
        ? "A newer version exists. The task keeps the version it was completed with."
        : "A newer version exists; it can be updated on Operationalize.";
      return `<tr>
        <td>${esc(F(u, "obligationName") || [F(u, "practiceCode"), F(u, "practiceName")].filter(Boolean).join(" - ") || "--")}</td>
        <td>${instanceCell}</td>
        <td>${usedCell}</td>
        <td>v${esc(F(u, "pinnedVersionNo"))}${latest ? "" : ` <span class="pm-badge ec-valid-expiring" title="${esc(olderTitle)}">older</span>`}</td>
        <td>${esc(F(u, "linkedByName") || "--")}</td>
        <td>${esc(dateTime(F(u, "linkedDt")))}</td>
      </tr>`;
    }).join("") || empty(6, "Not used anywhere yet.");

    document.getElementById("ecVersionsBody").innerHTML = (state.detail.versions || []).map(v => {
      const href = U(`${base}/files/${F(v, "evidenceFileId")}?organizationId=${state.organizationId}`);
      const current = F(v, "isCurrent") === true || F(v, "isCurrent") === 1;
      return `<tr>
        <td>v${esc(F(v, "versionNo"))}${current ? ' <span class="pm-badge">Current</span>' : ""}</td>
        <td><a href="${esc(href)}" target="_blank" rel="noopener">${esc(F(v, "fileName"))}</a></td>
        <td>${esc(kb(F(v, "fileSizeBytes")))}</td>
        <td>${esc(F(v, "versionNote") || "--")}</td>
        <td>${esc(F(v, "uploadedByName") || "--")}</td>
        <td>${esc(dateTime(F(v, "uploadedDt")))}</td>
        <td>${esc(F(v, "pinnedLinkCount") ?? 0)}</td>
      </tr>`;
    }).join("") || empty(7, "No versions.");
  }

  function selectTab(name) {
    document.querySelectorAll("[data-ec-tab]").forEach(x => { const on = x.dataset.ecTab === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-ec-panel]").forEach(p => { p.hidden = p.dataset.ecPanel !== name; });
  }

  async function itemAction(action) {
    const it = state.detail?.item;
    if (!it) return;
    const id = F(it, "evidenceItemId");
    if (action === "EDIT") { openEdit("EDIT"); return; }
    if (action === "VERSION") { openEdit("VERSION"); return; }
    const prompts = {
      RETIRE:  ["Retire this evidence? It stays where it is already linked, but cannot be linked anywhere new.", "Retire evidence", "Retire", "Retire"],
      RESTORE: ["Restore this evidence so it can be linked again?", "Restore evidence", "Restore", "Restore"],
      DELETE:  ["Delete this evidence? It is not used anywhere. This cannot be undone from the screen.", "Delete evidence", "Delete", "Delete"]
    };
    const p = prompts[action];
    if (!p) return;
    if (!await window.gracUi.confirm(p[0], { type: "warning", title: p[1], confirmText: p[2] })) return;
    const res = await api("POST", `/${id}/status`, { organizationId: state.organizationId, action: p[3] });
    if (!res.ok) { show("ecDetailMessage", res.error); return; }
    if (action === "DELETE") {
      document.getElementById("ecDetailModal").hidden = true;
      showMessage(res.data.message || "Evidence deleted.", "success");
    } else {
      await reloadDetail();
      show("ecDetailMessage", res.data.message, "success");
    }
    await refreshList();
  }

  // ------------------------------------------------------------------ upload / edit
  // NEW = upload a new item; VERSION = upload the next version of the open
  // item; EDIT = metadata only.
  // 499: one Evidence Center item form in the product. The markup moved to
  // Partials/_evidence-upload-dialog.cshtml and the behaviour to
  // Shared/evidence-upload.js, so Operationalize and Complete Task open
  // the SAME dialog with the same fields and the same validation. This
  // screen now only says WHAT to do with what the dialog collected.
  async function openEdit(mode) {
    const it = mode === "NEW" ? null : state.detail?.item;

    const outcome = await window.gracEvidenceUpload.open({
      mode,
      item: it,
      lookups: { types: state.lookups.types, employees: state.lookups.employees },
      onOpenDuplicate: id => openItem(id),
      submit: async ({ mode: m, file, metadata, versionNote, allowDuplicate }) => {
        // Editing an existing item changes metadata only -- no file.
        if (m === "EDIT") {
          const id = F(state.detail.item, "evidenceItemId");
          const res = await api("POST", `/${id}/save`,
                                Object.assign({ organizationId: state.organizationId }, metadata));
          return res.ok
            ? { ok: true, message: res.data?.message || "Evidence item saved." }
            : { ok: false, error: res.error };
        }

        const fd = new FormData();
        fd.append("file", file);
        if (m === "VERSION") {
          fd.append("evidenceItemId", F(state.detail.item, "evidenceItemId"));
          if (versionNote) fd.append("versionNote", versionNote);
        } else {
          Object.keys(metadata).forEach(k => {
            if (metadata[k] !== null && metadata[k] !== "") fd.append(k, metadata[k]);
          });
          if (allowDuplicate) fd.append("allowDuplicate", "true");
        }

        let r, b;
        try {
          r = await fetch(U(`${base}/upload?organizationId=${state.organizationId}`), {
            method: "POST", credentials: "same-origin",
            headers: { "X-CSRF-TOKEN": CSRF }, body: fd
          });
          b = await r.json().catch(() => ({}));
        } catch (err) {
          console.error("evidence-center: upload failed", err);
          return { ok: false, error: "Could not upload the file." };
        }

        if (r.status === 409 && b.duplicate)
          return { ok: false, duplicate: true, duplicateItemId: b.duplicateItemId, duplicateText: b.error };
        if (!r.ok)
          return { ok: false, error: b.error || b.title || `Upload failed (HTTP ${r.status}).` };

        return { ok: true, message: b.message || null, itemId: b.evidenceItemId || null };
      }
    });

    if (!outcome.saved) return;

    await refreshList();
    if (mode === "EDIT")      { await reloadDetail(); show("ecDetailMessage", outcome.message || "Evidence item saved.", "success"); }
    else if (mode === "VERSION") { await reloadDetail(); show("ecDetailMessage", outcome.message || "New version uploaded.", "success"); }
    else {
      showMessage(outcome.message || "Evidence uploaded.", "success");
      if (outcome.itemId) openItem(outcome.itemId);
    }
  }

  // ------------------------------------------------------------------ helpers
  async function api(method, path, body) {
    try {
      const headers = body ? { "Content-Type": "application/json", "X-CSRF-TOKEN": CSRF } : undefined;
      const r = await fetch(U(base + path), {
        method, credentials: "same-origin", headers, body: body ? JSON.stringify(body) : undefined
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok || data.success === false) {
        const hint = r.status === 404 && !data.error ? " -- the Evidence Center API was not found; deploy the latest API and Web build" : "";
        return { ok: false, status: r.status, data, error: data.error || data.title || `Request failed (HTTP ${r.status})${hint}.` };
      }
      return { ok: true, status: r.status, data };
    } catch (err) { return { ok: false, status: 0, data: {}, error: err.message }; }
  }
  function fillSelect(id, rows, valueKey, textKey, blank) {
    const sel = document.getElementById(id);
    sel.length = 0;
    sel.add(new Option(blank, ""));
    rows.forEach(x => sel.add(new Option(F(x, textKey), F(x, valueKey))));
  }
  function info(items) {
    return items.map(([k, v, html]) => `<div><span>${esc(k)}</span>${html ? v : esc(v == null || v === "" ? "--" : v)}</div>`).join("");
  }
  function kb(bytes) { const n = Number(bytes || 0); return n ? `${Math.max(1, Math.round(n / 1024))} KB` : "--"; }
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function showMessage(text, kind) { show("ecMessage", text, kind); }
  function show(id, text, kind) {
    const el = document.getElementById(id);
    el.textContent = text || "";
    el.classList.toggle("success", kind === "success");
    el.classList.toggle("info", kind === "info");
    el.hidden = !text;
  }
  function hide(id) { const el = document.getElementById(id); el.hidden = true; el.textContent = ""; el.classList.remove("success", "info"); }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
  function setVal(id, v) { document.getElementById(id).value = v == null ? "" : String(v); }
  function date(v) { return v ? String(v).substring(0, 10) : ""; }   // SQL DATE values: yyyy-mm-dd
  function dateTime(v) {
    if (!v) return "";
    if (typeof window.gracFormatDisplayDate === "function") { const g = window.gracFormatDisplayDate(v); if (g && g !== v) return g; }
    const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString();
  }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
