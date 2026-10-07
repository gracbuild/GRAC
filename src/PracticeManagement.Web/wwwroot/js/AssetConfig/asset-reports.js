// =====================================================================
// Asset Reports (migration 452) -- BRD 13.4 Standard Reporting Catalog and
// 13.4.1 Reporting Controls. Loaded by asset-reports.cshtml. Services:
// reports (catalogue of the screens the caller may view, asset statuses,
// asset types), reports/{code}/run (one page), reports/{code}/export (the
// export is recorded first, then every row is returned with the recorded
// heading), reports/exports (history), reports/settings (EDIT).
// 453: reports/schedules (list; POST create / change and .../run EDIT),
// reports/deliveries (+ /{id}/recipients: distribution results),
// reports/deliveries/mine and reports/deliveries/recipients/{id}/download
// (the caller delivered files; the download is recorded as an export).
// Every row, total and permission comes from the procedures; this screen
// lays them out and writes the CSV file (heading lines as the watermark,
// then the columns shown on screen). An asset ID opens the asset on the
// Asset Register.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/reports";
  const root = document.getElementById("arpRoot");
  if (!root) return;
  const CAN_EDIT = root.dataset.canEdit === "1";

  const CLS = { PUBLIC: "arp-cls-public", INTERNAL: "arp-cls-internal", CONFIDENTIAL: "arp-cls-confidential", RESTRICTED: "arp-cls-restricted" };
  const CLS_ORDER = ["PUBLIC", "INTERNAL", "CONFIDENTIAL", "RESTRICTED"];
  const POLICY = { ALLOWED: "Anyone who may run it", APPROVER: "Asset Reports approvers", DISABLED: "No export" };
  const FILTERS = ["SEARCH", "STATUS", "ASSET_TYPE", "DATE_RANGE", "DAYS"];
  const LABEL = { search: "Search", status: "Status", assetTypeId: "Asset type", dateFrom: "From", dateTo: "To", days: "Days" };

  const state = { organizationId: null, mainTab: "CATALOGUE", catalogue: null, reportCode: null, result: null,
                  pager: null, exportPager: null,
                  minePager: null, runPager: null, schedules: null, editing: null, recipients: [], runScheduleId: null };   // 453
  const FREQ = { DAILY: "Daily", WEEKLY: "Weekly", MONTHLY: "Monthly" };
  const WEEKDAY = ["", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    const g = window.__pmGrid;
    state.pager = g ? g.attach({ hostId: "arpPager", onChange: runReport }) : null;
    state.exportPager = g ? g.attach({ hostId: "arpExportPager", onChange: refreshExports }) : null;
    state.minePager = g ? g.attach({ hostId: "arpMinePager", onChange: refreshMine }) : null;   // 453
    state.runPager = g ? g.attach({ hostId: "arpRunPager", onChange: refreshRuns }) : null;
    bind();
    await populateOrgs();
    const params = new URLSearchParams(window.location.search);
    const sel = document.getElementById("arpOrg");
    const orgParam = params.get("organizationId");
    if (orgParam && [...sel.options].some(o => o.value === orgParam)) sel.value = orgParam;
    else window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    state.reportCode = (params.get("report") || "").toUpperCase() || null;
    await changeOrg(Number(sel.value) || null, state.reportCode ? "REPORT" : null);
  }

  async function populateOrgs() {
    const sel = document.getElementById("arpOrg");
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
    document.getElementById("arpOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.querySelectorAll("[data-arp-main]").forEach(b => b.addEventListener("click", () => selectMainTab(b.dataset.arpMain)));
    document.getElementById("arpRefresh").addEventListener("click", () => changeOrg(state.organizationId, state.mainTab));
    document.getElementById("arpCatalogue").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-arp-open]");
      if (b) openReport(b.dataset.arpOpen);
    });
    document.getElementById("arpReport").addEventListener("change", e => openReport(e.target.value));
    document.getElementById("arpRun").addEventListener("click", () => { state.pager?.reset(true); runReport(); });
    document.getElementById("arpSearch").addEventListener("keydown", e => { if (e.key === "Enter") { state.pager?.reset(true); runReport(); } });
    document.getElementById("arpExport").addEventListener("click", exportReport);
    document.getElementById("arpExportReport").addEventListener("change", () => { state.exportPager?.reset(true); refreshExports(); });
    // 453: my deliveries and schedules
    document.getElementById("arpMine").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-arp-download]");
      if (b) downloadDelivery(Number(b.dataset.arpDownload), b);
    });
    document.getElementById("arpSchedules").addEventListener("click", ev => {
      const e = ev.target.closest("button[data-arp-sch-edit]");
      if (e) { openScheduleForm(Number(e.dataset.arpSchEdit)); return; }
      const r = ev.target.closest("button[data-arp-sch-run]");
      if (r) { runScheduleNow(Number(r.dataset.arpSchRun), r); return; }
      const h = ev.target.closest("button[data-arp-sch-history]");
      if (h) { state.runScheduleId = Number(h.dataset.arpSchHistory); state.runPager?.reset(true); refreshRuns(); }
    });
    document.getElementById("arpRuns").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-arp-run]");
      if (b) showRunRecipients(Number(b.dataset.arpRun));
    });
    document.getElementById("arpSchNew")?.addEventListener("click", () => openScheduleForm(null));
    document.getElementById("arpSchCancel")?.addEventListener("click", closeScheduleForm);
    document.getElementById("arpSchSave")?.addEventListener("click", saveSchedule);
    document.getElementById("arpSchReport")?.addEventListener("change", () => renderScheduleFilters(null));
    document.getElementById("arpSchFrequency")?.addEventListener("change", renderScheduleDays);
    document.getElementById("arpSchAddEmp")?.addEventListener("click", () => addRecipient("EMPLOYEE", "arpSchEmp"));
    document.getElementById("arpSchAddRole")?.addEventListener("click", () => addRecipient("ROLE", "arpSchRole"));
    document.getElementById("arpSchRecipients")?.addEventListener("click", ev => {
      const b = ev.target.closest("button[data-arp-rcp-remove]");
      if (b) { state.recipients.splice(Number(b.dataset.arpRcpRemove), 1); renderRecipients(); }
    });
    document.getElementById("arpSettings")?.addEventListener("click", ev => {
      const b = ev.target.closest("button[data-arp-save]");
      if (b) saveSetting(b.dataset.arpSave);
    });
  }

  async function changeOrg(id, tab) {
    state.organizationId = id;
    state.catalogue = null; state.result = null;
    state.schedules = null; state.runScheduleId = null;   // 453
    hideMessage();
    [state.pager, state.exportPager, state.minePager, state.runPager].forEach(p => p?.reset(true));
    await loadCatalogue();
    await selectMainTab(tab || state.mainTab);
  }

  async function selectMainTab(name) {
    state.mainTab = name;
    document.querySelectorAll("[data-arp-main]").forEach(x => { const on = x.dataset.arpMain === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-arp-mainpanel]").forEach(p => { p.hidden = p.dataset.arpMainpanel !== name; });
    if (name === "CATALOGUE") renderCatalogue();
    else if (name === "REPORT") { renderReportPicker(); renderFilters(); await runReport(); }
    else if (name === "EXPORTS") await refreshExports();
    else if (name === "SETTINGS") renderSettings();
    else if (name === "MINE") await refreshMine();          // 453
    else if (name === "SCHEDULES") await loadSchedules();   // 453
  }

  // ------------------------------------------------------------------ catalogue
  async function loadCatalogue() {
    if (!state.organizationId) return;
    const res = await api("GET", `?${new URLSearchParams({ organizationId: state.organizationId })}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.catalogue = res.data.data || { reports: [], assetStatuses: [], assetTypes: [] };
    const reports = state.catalogue.reports || [];
    if (!state.reportCode || !reports.some(r => r.reportCode === state.reportCode))
      state.reportCode = (reports.find(r => r.isAvailable && r.isEnabled) || {}).reportCode || null;
  }

  function reports() { return (state.catalogue && state.catalogue.reports) || []; }
  function report(code) { return reports().find(r => r.reportCode === code) || null; }

  function renderCatalogue() {
    const body = document.getElementById("arpCatalogue");
    if (!state.organizationId) { body.innerHTML = empty(5, "Select an organization."); return; }
    if (!state.catalogue) { body.innerHTML = empty(5, "The catalogue could not be loaded."); return; }
    let family = null, html = "";
    reports().forEach(r => {
      if (r.familyCode !== family) { family = r.familyCode; html += `<tr class="arp-family"><td colspan="5">${esc(r.familyName)}</td></tr>`; }
      const name = r.isAvailable && r.isEnabled
        ? `<button class="pm-link-button" type="button" data-arp-open="${esc(r.reportCode)}">${esc(r.reportName)}</button>`
        : `${esc(r.reportName)}<div class="arp-note">${esc(r.isAvailable ? "Disabled for this organization." : "Not available: " + (r.unavailableReason || ""))}</div>`;
      const exp = !r.isAvailable || !r.isEnabled ? "--" : r.canExport ? "CSV" : r.exportPolicy === "DISABLED" ? "Not allowed" : "Approver only";
      html += `<tr><td>${name}</td><td>${esc(r.description)}</td><td>${clsChip(r.classification)}</td><td>${esc(r.versionNo)}</td><td>${esc(exp)}</td></tr>`;
    });
    body.innerHTML = html || empty(5, "No report is based on a screen you may view.");
  }

  function openReport(code) {
    state.reportCode = code || null;
    state.result = null;
    state.pager?.reset(true);
    ["arpSearch", "arpDateFrom", "arpDateTo", "arpDays"].forEach(id => { document.getElementById(id).value = ""; });
    if (state.mainTab !== "REPORT") selectMainTab("REPORT");
    else { renderReportPicker(); renderFilters(); runReport(); }
  }

  // ------------------------------------------------------------------ report
  function renderReportPicker() {
    const sel = document.getElementById("arpReport");
    let family = null, group = null;
    sel.innerHTML = "";
    reports().filter(r => r.isAvailable && r.isEnabled).forEach(r => {
      if (r.familyCode !== family) { family = r.familyCode; group = document.createElement("optgroup"); group.label = r.familyName; sel.appendChild(group); }
      const o = document.createElement("option");
      o.value = r.reportCode; o.textContent = r.reportName;
      group.appendChild(o);
    });
    if (state.reportCode) sel.value = state.reportCode;
    if (sel.value !== state.reportCode) state.reportCode = sel.value || null;
  }

  function renderFilters() {
    const r = report(state.reportCode);
    const keys = r ? String(r.filterKeys || "").split(",") : [];
    document.querySelectorAll("[data-arp-filter]").forEach(el => { el.hidden = !keys.includes(el.dataset.arpFilter); });
    const info = document.getElementById("arpReportInfo");
    info.innerHTML = r
      ? `${clsChip(r.classification)} Version ${esc(r.versionNo)} &middot; ${esc(r.brdReference)} &middot; ${esc(r.description)}`
      : (state.organizationId ? "No report available." : "Select an organization.");
    document.getElementById("arpExport").hidden = !(r && r.canExport);
    if (!r) return;
    fillStatus(document.getElementById("arpStatus"), r);
    const types = document.getElementById("arpAssetType");
    if (!types.options.length || types.dataset.org !== String(state.organizationId)) fillAssetTypes(types);
    document.getElementById("arpDateLabel").textContent = `${r.dateLabel || "Date"} from`;
    const days = document.getElementById("arpDays");
    if (keys.includes("DAYS") && !days.value && r.defaultDays) days.value = r.defaultDays;
  }

  // The status options of a report (its own list, or the asset lifecycle statuses) -- report filter and schedule form.
  function fillStatus(sel, r) {
    const options = r.statusOptions === "@ASSET_STATUS"
      ? ((state.catalogue && state.catalogue.assetStatuses) || []).map(s => [s.code, s.name])
      : String(r.statusOptions || "").split("|").filter(Boolean).map(x => x.split("="));
    sel.innerHTML = `<option value="">${esc((r.statusLabel || "Status") + ": all")}</option>`
      + options.map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join("");
  }
  function fillAssetTypes(sel) {
    sel.innerHTML = `<option value="">All asset types</option>` + ((state.catalogue && state.catalogue.assetTypes) || [])
      .map(t => `<option value="${esc(t.assetTypeId)}">${esc(t.assetTypeName)}</option>`).join("");
    sel.dataset.org = String(state.organizationId);
  }

  // The filters the report takes, as sent to the API and recorded with an export.
  function filters() {
    const r = report(state.reportCode);
    const keys = r ? String(r.filterKeys || "").split(",") : [];
    const f = {};
    if (keys.includes("SEARCH") && val("arpSearch")) f.search = val("arpSearch");
    if (keys.includes("STATUS") && val("arpStatus")) f.status = val("arpStatus");
    if (keys.includes("ASSET_TYPE") && val("arpAssetType")) f.assetTypeId = Number(val("arpAssetType"));
    if (keys.includes("DATE_RANGE") && val("arpDateFrom")) f.dateFrom = val("arpDateFrom");
    if (keys.includes("DATE_RANGE") && val("arpDateTo")) f.dateTo = val("arpDateTo");
    if (keys.includes("DAYS") && val("arpDays")) f.days = Number(val("arpDays"));
    return f;
  }

  async function runReport() {
    const head = document.getElementById("arpHead"), body = document.getElementById("arpRows");
    if (!state.organizationId || !state.reportCode) {
      head.innerHTML = ""; body.innerHTML = empty(1, state.organizationId ? "Choose a report." : "Select an organization."); state.pager?.clear(); return;
    }
    hideMessage();
    body.innerHTML = empty(1, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.pager ? state.pager.page() : 1, pageSize: state.pager ? state.pager.size() : 25 });
    Object.entries(filters()).forEach(([k, v]) => qs.set(k, v));
    const res = await api("GET", `/${encodeURIComponent(state.reportCode)}/run?${qs}`);
    if (!res.ok) { head.innerHTML = ""; body.innerHTML = empty(1, res.error); state.pager?.clear(); return; }
    const d = res.data.data || {}, cols = d.columns || [], rows = d.rows || [];
    state.result = d;
    state.pager?.setTotal(d.totalRows, rows.length);
    head.innerHTML = `<tr>${cols.map(c => `<th>${esc(label(c))}</th>`).join("")}</tr>`;
    body.innerHTML = rows.map(row => `<tr>${cols.map(c => `<td>${cell(c, row[c])}</td>`).join("")}</tr>`).join("")
      || empty(Math.max(cols.length, 1), "No record matches the filters.");
  }

  // 13.4.1: the API records the export before it returns the rows; the file
  // starts with the recorded heading (watermark), then the columns shown on screen.
  async function exportReport() {
    const r = report(state.reportCode);
    if (!r || !state.organizationId) return;
    const btn = document.getElementById("arpExport");
    btn.disabled = true;
    hideMessage();
    try {
      const res = await api("POST", `/${encodeURIComponent(r.reportCode)}/export`, { organizationId: state.organizationId, ...filters() });
      if (!res.ok) { showMessage(res.error, "error"); return; }
      const d = res.data.data || {}, h = d.export || {}, rows = d.rows || [];
      writeCsv(h, d.columns || [], rows);
      showMessage(`Exported ${rows.length} rows (export ${h.exportId}, ${h.classification}).`, "success");
    } finally { btn.disabled = false; }
  }

  // The file: the recorded export heading (watermark), then the columns. A delivered file also states when it was
  // generated. Text starting with = + - @ is prefixed with ' so a spreadsheet does not run it as a formula.
  function writeCsv(h, cols, rows) {
    const q = v => { let s = String(v ?? ""); if (typeof v === "string" && /^[=+\-@\t\r]/.test(s)) s = "'" + s; return `"${s.replace(/"/g, '""')}"`; };
    const lines = [
      [`Classification: ${h.classification}`, "Handle and share this file according to its classification."].map(q).join(","),
      ["Report", `${h.reportName} (${h.reportCode})`].map(q).join(","), ["Report version", h.reportVersion].map(q).join(","),
      ["Organization", h.organizationName].map(q).join(",")
    ];
    if (h.generatedDt) lines.push(["Generated at (UTC)", h.generatedDt].map(q).join(","));
    lines.push(["Exported by", h.exportedBy].map(q).join(","), ["Exported at (UTC)", h.exportedDt].map(q).join(","),
      ["Export ID", h.exportId].map(q).join(","), ["Filters", filterText(h.filtersJson)].map(q).join(","),
      ["Rows", h.rowCount].map(q).join(","), "", cols.map(c => q(label(c))).join(","));
    rows.forEach(row => lines.push(cols.map(c => q(csvValue(row[c]))).join(",")));
    const blob = new Blob([lines.join("\r\n")], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `${String(h.reportCode || "report").toLowerCase()}-${state.organizationId}-${String(h.exportedDt || "").substring(0, 10)}-${String(h.classification || "").toLowerCase()}.csv`;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  // ------------------------------------------------------------------ export history
  async function refreshExports() {
    const body = document.getElementById("arpExports"), sel = document.getElementById("arpExportReport");
    if (sel.options.length <= 1 || sel.dataset.org !== String(state.organizationId)) {
      sel.innerHTML = `<option value="">All reports</option>` + reports().filter(r => r.isAvailable)
        .map(r => `<option value="${esc(r.reportCode)}">${esc(r.familyName)} - ${esc(r.reportName)}</option>`).join("");
      sel.dataset.org = String(state.organizationId);
    }
    if (!state.organizationId) { body.innerHTML = empty(7, "Select an organization."); state.exportPager?.clear(); return; }
    body.innerHTML = empty(7, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.exportPager ? state.exportPager.page() : 1, pageSize: state.exportPager ? state.exportPager.size() : 25 });
    if (sel.value) qs.set("reportCode", sel.value);
    const res = await api("GET", `/exports?${qs}`);
    if (!res.ok) { body.innerHTML = empty(7, res.error); state.exportPager?.clear(); return; }
    const d = res.data.data || {}, rows = d.rows || [];
    state.exportPager?.setTotal(d.totalRows, rows.length);
    body.innerHTML = rows.map(x => `
      <tr><td>${esc(dateTime(x.exportedDt))}</td><td>${esc(x.reportName)}<div class="arp-note">${esc(x.familyName)}</div></td>
          <td>${esc(x.reportVersion)}</td><td>${clsChip(x.classification)}</td><td>${esc(x.rowCount)}</td>
          <td>${esc(x.exportedBy)}</td><td>${esc(filterText(x.filtersJson))}</td></tr>`).join("")
      || empty(7, "No export recorded.");
  }

  // ------------------------------------------------------------------ my deliveries (453)
  async function refreshMine() {
    const body = document.getElementById("arpMine");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.minePager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.minePager ? state.minePager.page() : 1, pageSize: state.minePager ? state.minePager.size() : 25 });
    const res = await api("GET", `/deliveries/mine?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.minePager?.clear(); return; }
    const d = res.data.data || {}, rows = d.rows || [];
    state.minePager?.setTotal(d.totalRows, rows.length);
    body.innerHTML = rows.map(x => `
      <tr><td>${esc(dateTime(x.deliveredDt))}</td><td>${esc(x.reportName)}<div class="arp-note">${esc(x.scheduleName)} &middot; version ${esc(x.reportVersion)}</div></td>
          <td>${clsChip(x.classification)}</td><td>${esc(x.rowCount)}</td>
          <td>${x.isAvailable ? esc(dateTime(x.availableUntilDt)) : "Removed (retention)"}</td><td>${esc(x.downloadCount)}</td>
          <td>${esc(filterText(x.filtersJson))}</td>
          <td>${x.isAvailable ? `<button class="pm-button" type="button" data-arp-download="${esc(x.deliveryRecipientId)}"><i class="fa-solid fa-file-csv"></i> Download</button>` : ""}</td></tr>`).join("")
      || empty(8, "No report has been delivered to you in this organization.");
  }

  async function downloadDelivery(id, btn) {
    btn.disabled = true;
    hideMessage();
    try {
      const res = await api("POST", `/deliveries/recipients/${id}/download`, { organizationId: state.organizationId });
      if (!res.ok) { showMessage(res.error, "error"); return; }
      const d = res.data.data || {}, h = d.export || {}, rows = d.rows || [];
      writeCsv(h, d.columns || [], rows);
      showMessage(`Downloaded ${rows.length} rows (export ${h.exportId}, ${h.classification}).`, "success");
      await refreshMine();
    } finally { btn.disabled = false; }
  }

  // ------------------------------------------------------------------ schedules (453)
  async function loadSchedules() {
    const body = document.getElementById("arpSchedules");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); return; }
    body.innerHTML = empty(8, "Loading...");
    const res = await api("GET", `/schedules?${new URLSearchParams({ organizationId: state.organizationId })}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); return; }
    state.schedules = res.data.data || { schedules: [], recipients: [], employees: [], roles: [] };
    renderSchedules();
    if (state.runScheduleId) await refreshRuns();
  }

  function frequencyText(s) {
    return s.frequency === "WEEKLY" ? `Weekly, ${WEEKDAY[s.dayOfWeek] || ""}` : s.frequency === "MONTHLY" ? `Monthly, day ${s.dayOfMonth}` : FREQ[s.frequency] || s.frequency;
  }

  function renderSchedules() {
    const body = document.getElementById("arpSchedules");
    const list = (state.schedules && state.schedules.schedules) || [];
    body.innerHTML = list.map(s => `
      <tr><td>${esc(s.scheduleName)}<div class="arp-note">Files kept ${esc(s.retentionDays)} days</div></td>
          <td>${esc(s.reportName)}<div class="arp-note">${esc(s.familyName)}</div></td><td>${esc(frequencyText(s))}</td>
          <td>${esc(s.recipients || "")}</td><td>${esc(s.isActive ? date(s.nextRunDate) : "--")}</td>
          <td>${s.lastStatus ? `${stChip(s.lastStatus)}<div class="arp-note">${esc(dateTime(s.lastRunDt))}: ${esc(s.lastDelivered)} delivered, ${esc(s.lastSkipped)} skipped, ${esc(s.lastFailed)} failed</div>` : "--"}</td>
          <td>${s.isActive ? "Yes" : "No"}</td>
          <td>${CAN_EDIT ? `<button class="pm-button" type="button" data-arp-sch-edit="${esc(s.scheduleId)}">Edit</button>
                            <button class="pm-button" type="button" data-arp-sch-run="${esc(s.scheduleId)}"><i class="fa-solid fa-play"></i> Run now</button>` : ""}
              <button class="pm-button" type="button" data-arp-sch-history="${esc(s.scheduleId)}">Deliveries</button></td></tr>`).join("")
      || empty(8, "No schedule for the reports you may view.");
  }

  function openScheduleForm(id) {
    const form = document.getElementById("arpSchForm");
    if (!form || !state.schedules) return;
    const s = id ? (state.schedules.schedules || []).find(x => x.scheduleId === id) : null;
    state.editing = s;
    document.getElementById("arpSchFormTitle").textContent = s ? `Edit schedule: ${s.scheduleName}` : "New schedule";
    const sel = document.getElementById("arpSchReport");
    sel.innerHTML = reports().filter(r => r.isAvailable && r.isEnabled)
      .map(r => `<option value="${esc(r.reportCode)}">${esc(r.familyName)} - ${esc(r.reportName)}</option>`).join("");
    if (s) sel.value = s.reportCode;
    sel.disabled = !!s;   // the report of a schedule is fixed
    document.getElementById("arpSchName").value = s ? s.scheduleName : "";
    document.getElementById("arpSchFrequency").value = s ? s.frequency : "WEEKLY";
    document.getElementById("arpSchDow").value = String(s && s.dayOfWeek ? s.dayOfWeek : 1);
    document.getElementById("arpSchDom").value = s && s.dayOfMonth ? s.dayOfMonth : 1;
    document.getElementById("arpSchRetention").value = s ? s.retentionDays : 90;
    document.getElementById("arpSchActive").checked = s ? !!s.isActive : true;
    document.getElementById("arpSchEmp").innerHTML = (state.schedules.employees || [])
      .map(e => `<option value="${esc(e.employeeId)}">${esc(e.employeeName)}${e.email ? " (" + esc(e.email) + ")" : ""}</option>`).join("");
    document.getElementById("arpSchRole").innerHTML = (state.schedules.roles || [])
      .map(r => `<option value="${esc(r.roleId)}">${esc(r.roleName)}</option>`).join("");
    state.recipients = s ? (state.schedules.recipients || []).filter(r => r.scheduleId === s.scheduleId)
      .map(r => ({ kind: r.recipientKind, id: r.recipientKind === "ROLE" ? r.roleId : r.employeeId, name: r.name })) : [];
    renderScheduleFilters(s);
    renderScheduleDays();
    renderRecipients();
    form.hidden = false;
    form.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function closeScheduleForm() {
    const form = document.getElementById("arpSchForm");
    if (form) form.hidden = true;
    state.editing = null;
  }

  // The filters of the chosen report; a date-range report takes a window of the last N days instead of fixed dates.
  function renderScheduleFilters(s) {
    const r = report(val("arpSchReport"));
    const keys = r ? String(r.filterKeys || "").split(",") : [];
    document.querySelectorAll("[data-arp-sch-filter]").forEach(el => { el.hidden = !keys.includes(el.dataset.arpSchFilter); });
    if (!r) return;
    fillStatus(document.getElementById("arpSchStatus"), r);
    fillAssetTypes(document.getElementById("arpSchAssetType"));
    document.getElementById("arpSchStatusLabel").textContent = r.statusLabel || "Status";
    document.getElementById("arpSchWindowLabel").textContent = `${r.dateLabel || "Date"}: last days`;
    document.getElementById("arpSchSearch").value = s && s.searchText ? s.searchText : "";
    document.getElementById("arpSchStatus").value = s && s.statusCode ? s.statusCode : "";
    document.getElementById("arpSchAssetType").value = s && s.assetTypeId ? String(s.assetTypeId) : "";
    document.getElementById("arpSchDays").value = s && s.days ? s.days : (r.defaultDays || "");
    document.getElementById("arpSchWindow").value = s && s.dateWindowDays ? s.dateWindowDays : "";
  }

  function renderScheduleDays() {
    const f = val("arpSchFrequency");
    document.getElementById("arpSchDowField").hidden = f !== "WEEKLY";
    document.getElementById("arpSchDomField").hidden = f !== "MONTHLY";
  }

  function addRecipient(kind, selectId) {
    const sel = document.getElementById(selectId);
    const id = Number(sel.value);
    if (!id || state.recipients.some(r => r.kind === kind && r.id === id)) return;
    state.recipients.push({ kind, id, name: sel.options[sel.selectedIndex].textContent });
    renderRecipients();
  }

  function renderRecipients() {
    const host = document.getElementById("arpSchRecipients");
    host.innerHTML = state.recipients.map((r, i) => `<span class="arp-recipient">${esc(r.name)}${r.kind === "ROLE" ? " (role)" : ""}
        <button class="pm-link-button" type="button" data-arp-rcp-remove="${i}" aria-label="Remove">&times;</button></span>`).join("")
      || `<span class="arp-note">No recipient yet.</span>`;
  }

  async function saveSchedule() {
    const r = report(val("arpSchReport"));
    if (!r) return;
    const keys = String(r.filterKeys || "").split(",");
    const num = id => (val(id) === "" ? null : Number(val(id)));
    const s = state.editing;
    const res = await api("POST", "/schedules", {
      organizationId: state.organizationId, scheduleId: s ? s.scheduleId : null, reportCode: r.reportCode,
      scheduleName: val("arpSchName"), frequency: val("arpSchFrequency"),
      dayOfWeek: val("arpSchFrequency") === "WEEKLY" ? num("arpSchDow") : null,
      dayOfMonth: val("arpSchFrequency") === "MONTHLY" ? num("arpSchDom") : null,
      retentionDays: num("arpSchRetention"), isActive: document.getElementById("arpSchActive").checked,
      search: keys.includes("SEARCH") ? val("arpSchSearch") || null : null,
      status: keys.includes("STATUS") ? val("arpSchStatus") || null : null,
      assetTypeId: keys.includes("ASSET_TYPE") ? num("arpSchAssetType") : null,
      days: keys.includes("DAYS") ? num("arpSchDays") : null,
      dateWindowDays: keys.includes("DATE_RANGE") ? num("arpSchWindow") : null,
      recipients: state.recipients.map(x => ({ kind: x.kind, id: x.id })),
      expectedRecordVersion: s ? s.recordVersion : null
    });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    showMessage("Schedule saved.", "success");
    closeScheduleForm();
    await loadSchedules();
  }

  async function runScheduleNow(id, btn) {
    btn.disabled = true;
    hideMessage();
    try {
      const res = await api("POST", `/schedules/${id}/run`, { organizationId: state.organizationId });
      if (!res.ok) { showMessage(res.error, "error"); return; }
      const p = res.data.data || {};
      showMessage(`Delivered ${p.delivered || 0} file(s); ${p.skipped || 0} recipient(s) skipped, ${p.failed || 0} failed.`, "success");
      state.runScheduleId = id;
      state.runPager?.reset(true);
      await loadSchedules();
    } finally { btn.disabled = false; }
  }

  async function refreshRuns() {
    const panel = document.getElementById("arpRunPanel"), body = document.getElementById("arpRuns");
    if (!state.organizationId || !state.runScheduleId) { panel.hidden = true; return; }
    panel.hidden = false;
    ["arpRunRecipientsTitle", "arpRunRecipientsWrap"].forEach(x => { document.getElementById(x).hidden = true; });
    const s = ((state.schedules && state.schedules.schedules) || []).find(x => x.scheduleId === state.runScheduleId);
    document.getElementById("arpRunTitle").textContent = `Deliveries${s ? ": " + s.scheduleName : ""}`;
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId, scheduleId: state.runScheduleId,
      pageNumber: state.runPager ? state.runPager.page() : 1, pageSize: state.runPager ? state.runPager.size() : 25 });
    const res = await api("GET", `/deliveries?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.runPager?.clear(); return; }
    const d = res.data.data || {}, rows = d.rows || [];
    state.runPager?.setTotal(d.totalRows, rows.length);
    body.innerHTML = rows.map(x => `
      <tr><td>${esc(dateTime(x.startedDt))}</td><td>${esc(x.triggerCode === "MANUAL" ? "Run now" : "Scheduled")}<div class="arp-note">${esc(x.startedBy)} &middot; version ${esc(x.reportVersion)}</div></td>
          <td>${stChip(x.status)}</td><td>${esc(x.deliveredCount)}</td><td>${esc(x.skippedCount)}</td><td>${esc(x.failedCount)}</td>
          <td>${esc(filterText(x.filtersJson))}</td>
          <td><button class="pm-button" type="button" data-arp-run="${esc(x.deliveryId)}">Recipients</button></td></tr>`).join("")
      || empty(8, "Not delivered yet.");
  }

  async function showRunRecipients(deliveryId) {
    const title = document.getElementById("arpRunRecipientsTitle"), wrap = document.getElementById("arpRunRecipientsWrap");
    const body = document.getElementById("arpRunRecipients");
    title.hidden = false; wrap.hidden = false;
    body.innerHTML = empty(7, "Loading...");
    const res = await api("GET", `/deliveries/${deliveryId}/recipients?${new URLSearchParams({ organizationId: state.organizationId })}`);
    if (!res.ok) { body.innerHTML = empty(7, res.error); return; }
    body.innerHTML = ((res.data.data || {}).rows || []).map(x => `
      <tr><td>${esc(x.recipientName)}${x.viaRoleName ? `<div class="arp-note">via ${esc(x.viaRoleName)}</div>` : ""}</td>
          <td>${stChip(x.status)}</td><td>${esc(x.reason || "")}</td><td>${esc(x.rowCount ?? "")}</td>
          <td>${esc(dateTime(x.deliveredDt))}</td><td>${esc(x.downloadCount)}</td>
          <td>${x.purgedDt ? `Removed ${esc(dateTime(x.purgedDt))}` : x.status === "DELIVERED" ? "Kept" : ""}</td></tr>`).join("")
      || empty(7, "No recipient.");
  }

  // ------------------------------------------------------------------ settings
  function renderSettings() {
    const body = document.getElementById("arpSettings");
    if (!body) return;
    if (!state.organizationId) { body.innerHTML = empty(5, "Select an organization."); return; }
    body.innerHTML = reports().filter(r => r.isAvailable).map(r => {
      const from = CLS_ORDER.indexOf(r.defaultClassification);
      const cls = `<option value="">Default (${esc(r.defaultClassification)})</option>`
        + CLS_ORDER.slice(from + 1).map(c => `<option value="${c}"${r.classificationOverride === c ? " selected" : ""}>${c}</option>`).join("");
      const pol = `<option value="">Default (${esc(POLICY[r.classification === "RESTRICTED" ? "APPROVER" : "ALLOWED"])})</option>`
        + Object.entries(POLICY).map(([k, l]) => `<option value="${k}"${r.exportPolicyOverride === k ? " selected" : ""}>${esc(l)}</option>`).join("");
      return `<tr><td>${esc(r.reportName)}<div class="arp-note">${esc(r.familyName)}</div></td>
        <td><input type="checkbox" data-arp-enabled="${esc(r.reportCode)}"${r.isEnabled ? " checked" : ""} /></td>
        <td><select data-arp-cls="${esc(r.reportCode)}">${cls}</select></td>
        <td><select data-arp-policy="${esc(r.reportCode)}">${pol}</select></td>
        <td><button class="pm-button" type="button" data-arp-save="${esc(r.reportCode)}"><i class="fa-solid fa-floppy-disk"></i> Save</button></td></tr>`;
    }).join("") || empty(5, "No report.");
  }

  async function saveSetting(code) {
    if (!CAN_EDIT) return;
    const pick = attr => document.querySelector(`[${attr}="${CSS.escape(code)}"]`);
    const res = await api("POST", "/settings", {
      organizationId: state.organizationId, reportCode: code, isEnabled: pick("data-arp-enabled").checked,
      classification: pick("data-arp-cls").value || null, exportPolicy: pick("data-arp-policy").value || null
    });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    showMessage("Report setting saved.", "success");
    await loadCatalogue();
    renderSettings();
  }

  // ------------------------------------------------------------------ helpers
  async function api(method, path, body) {
    try {
      const r = await fetch(U(base + path), {
        method, credentials: "same-origin",
        headers: body ? { "Content-Type": "application/json" } : undefined,
        body: body ? JSON.stringify(body) : undefined
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok || data.success === false) {
        const hint = r.status === 404 && !data.error ? " -- the Asset Configuration API was not found; deploy the latest API and Web build" : "";
        return { ok: false, status: r.status, data, errorNumber: data.errorNumber, error: data.error || `Request failed (HTTP ${r.status})${hint}.` };
      }
      return { ok: true, status: r.status, data };
    } catch (err) { return { ok: false, status: 0, data: {}, error: err.message }; }
  }
  // Column label from the result-set alias: assetTypeName -> Asset type name, ...Id -> ID, ...Dt -> (UTC), ...Pct -> %.
  function label(c) {
    let s = String(c).replace(/Dt$/, " (UTC)").replace(/Pct$/, " %").replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/\bId\b/g, "ID");
    s = s.replace(/\bsku\b/gi, "SKU").replace(/\bdpia\b/gi, "DPIA").replace(/\bkpi\b/gi, "KPI");
    return s.charAt(0).toUpperCase() + s.slice(1).replace(/ ([A-Z])(?=[a-z])/g, (m, x) => " " + x.toLowerCase());
  }
  function cell(c, v) {
    if (v == null || v === "") return "";
    if (c === "assetId") {
      const q = new URLSearchParams({ organizationId: state.organizationId, assetId: v });
      return `<a href="${esc(U(`/Practice/Index/asset-register?${q}`))}">${esc(v)}</a>`;
    }
    if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}T00:00:00$/.test(v) && !/Dt$/.test(c)) return esc(v.substring(0, 10));
    if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(v)) return esc(dateTime(v));
    return esc(v);
  }
  // CSV keeps ISO values: dates as yyyy-mm-dd, date-times as stored (UTC).
  function csvValue(v) {
    if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}T00:00:00$/.test(v)) return v.substring(0, 10);
    return v;
  }
  function filterText(json) {
    let f = {};
    try { f = JSON.parse(json || "{}") || {}; } catch (_) { return json || ""; }
    const parts = Object.entries(f).filter(([, v]) => v != null && v !== "").map(([k, v]) => `${LABEL[k] || k}: ${v}`);
    return parts.length ? parts.join("; ") : "None";
  }
  function clsChip(c) { return c ? `<span class="arp-chip ${CLS[c] || ""}">${esc(c)}</span>` : ""; }
  function stChip(s) { return s ? `<span class="arp-chip arp-st-${esc(String(s).toLowerCase())}">${esc(s)}</span>` : ""; }   // 453
  function date(v) { return v ? String(v).substring(0, 10) : ""; }   // SQL DATE values: yyyy-mm-dd
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function showMessage(text, kind) {
    const el = document.getElementById("arpMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.classList.toggle("info", kind === "info"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("arpMessage"); el.hidden = true; el.textContent = ""; }
  function val(id) { const el = document.getElementById(id); return el ? (el.value || "").trim() : ""; }
  function dateTime(v) { if (!v) return ""; const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString(); }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
