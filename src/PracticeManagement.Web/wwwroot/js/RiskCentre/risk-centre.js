// =====================================================================
// Risk Centre — Risk Candidates + Risk Register.
// Loaded by Views/Practice/Partials/risk-centre.cshtml.
//
// BRD "Risk Candidate Analysis and Risk Register", migrations 204-207.
//
// TWO ROUTES, ONE ANALYSIS FORM
// -----------------------------
// BRD §12 says the custom route must use the same framework as the
// stream route. The server guarantees that (one proc writes every
// analysis, one proc writes every register row). This file honours the
// same rule in the UI by driving BOTH forms — the candidate analysis
// modal and the custom risk modal — from ONE scoring-options payload and
// ONE rating resolver. If the two forms ever disagree, it will be
// because someone gave them separate data, so they never get separate
// data.
//
// The server is the authority on validation. Client-side checks here are
// affordances (disable a button, show a message early); every write is
// still allowed to fail on a 560xx message from SQL, and that message is
// shown verbatim because it names the BRD clause that refused.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/risk-centre";

  const state = {
    organizationId: null,
    tab: "candidates",
    statusCode: "Pending",
    sourceTypeCode: null,
    activeCandidate: null,
    activeRisk: null,
    // Filled once per organisation from /scoring-options — the single
    // source of truth for both analysis forms (see the header note).
    options: null,
    employees: [],
    roles: [],
    // Phase B: the organisation's §19 / §22 switches. Loaded once per
    // organisation and consulted before the UI offers Accept or pre-ticks
    // the treatment checkbox — the server enforces both anyway, this only
    // stops the screen offering something that will be refused.
    config: null,
    // Threat / vulnerability / business-function picklists (216).
    // Separate from `options`, which is the org's SCALE — stage 1
    // does not use the scale at all.
    assess: null,
    // Set when the analyst asked to register straight from the analysis
    // form, so the duplicate-check step knows what to do on "continue".
    pendingRegisterCandidateId: null
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("riskListView")) return;
    bindEvents();
    showTab("candidates");
    await populateOrgFilter();
    const sel = document.getElementById("riskFilterOrganization");
    if (sel.options.length > 1 && !state.organizationId) {
      sel.selectedIndex = 1;
      state.organizationId = Number(sel.value) || null;
      if (state.organizationId) await onOrganizationChanged();
    }
  }

  // ---- events -------------------------------------------------------
  function bindEvents() {
    document.querySelectorAll("[data-risk-tab]").forEach(btn =>
      btn.addEventListener("click", () => showTab(btn.dataset.riskTab)));

    document.getElementById("riskFilterOrganization").addEventListener("change", e => {
      state.organizationId = e.target.value ? Number(e.target.value) : null;
      state.options = null; state.employees = [];
      onOrganizationChanged();
    });
    document.getElementById("riskFilterStatus").addEventListener("change", e => {
      state.statusCode = e.target.value || null; refresh();
    });
    document.getElementById("riskFilterSource").addEventListener("change", e => {
      state.sourceTypeCode = e.target.value || null; refresh();
    });
    document.getElementById("riskRefreshBtn").addEventListener("click", refresh);

    ["regFilterStatus", "regFilterSource", "regFilterCategory", "regFilterRating"]
      .forEach(id => document.getElementById(id).addEventListener("change", refreshRegister));
    document.getElementById("regFilterSearch").addEventListener("change", refreshRegister);
    document.getElementById("regFilterPending").addEventListener("change", refreshRegister);
    document.getElementById("regRefreshBtn").addEventListener("click", refreshRegister);
    document.getElementById("regCustomBtn").addEventListener("click", openCustomModal);

    document.getElementById("riskAnalysisForm").addEventListener("submit", ev => onAnalysisSubmit(ev, false));
    document.getElementById("anSaveRegisterBtn").addEventListener("click", () => onAnalysisSubmit(null, true));
    // BRD §8B — "not a risk". Hands off to the existing reject modal
    // rather than growing a second reason-capture form.
    document.getElementById("anRejectBtn").addEventListener("click", () => {
      const id = Number(document.getElementById("anCandidateId").value);
      hide("riskAnalysisModal");
      openRejectModal(id);
    });
    // "Others" (id 0) reveals the description box. One handler shape
    // for both forms and both fields, so they cannot drift.
    document.getElementById("anThreat").addEventListener("change", () => toggleOther("an", "Threat"));
    document.getElementById("anVulnerability").addEventListener("change", () => toggleOther("an", "Vuln"));

    document.getElementById("riskCustomForm").addEventListener("submit", onCustomSubmit);
    document.getElementById("cxThreat").addEventListener("change", () => toggleOther("cx", "Threat"));
    document.getElementById("cxVulnerability").addEventListener("change", () => toggleOther("cx", "Vuln"));
    document.getElementById("riskRegAnalysisForm").addEventListener("submit", onRegAnalysisSubmit);
    document.getElementById("raLikelihood").addEventListener("change", () => renderRating("ra"));
    document.getElementById("raImpact").addEventListener("change", () => renderRating("ra"));
    document.getElementById("riskRegApprovalForm").addEventListener("submit", ev => onRegApprovalDecision(ev, "Approve"));
    document.getElementById("rgaReturnBtn").addEventListener("click", () => onRegApprovalDecision(null, "Return"));
    closers("reg-analysis", "riskRegAnalysisModal");
    closers("reg-approval", "riskRegApprovalModal");

    document.getElementById("riskAcceptForm").addEventListener("submit", onAcceptSubmit);
    document.getElementById("riskRejectForm").addEventListener("submit", onRejectSubmit);
    document.getElementById("regStatusForm").addEventListener("submit", onRegStatusSubmit);
    document.getElementById("regOwnerForm").addEventListener("submit", onRegOwnerSubmit);
    document.getElementById("dupContinueBtn").addEventListener("click", onDuplicateContinue);

    // ---- Phase B ----
    document.getElementById("riskConfigBtn").addEventListener("click", openConfigModal);
    document.getElementById("riskConfigForm").addEventListener("submit", onConfigSubmit);
    document.getElementById("dashRefreshBtn").addEventListener("click", refreshDashboard);
    document.getElementById("dashTrendMonths").addEventListener("change", refreshDashboard);
    document.getElementById("riskApprovalForm").addEventListener("submit", ev => onApprovalDecision(ev, "Approve"));
    document.getElementById("apReturnBtn").addEventListener("click", () => onApprovalDecision(null, "Return"));
    document.getElementById("riskTreatmentForm").addEventListener("submit", onTreatmentSubmit);
    document.getElementById("notifSweepBtn").addEventListener("click", onNotificationSweep);
    document.getElementById("notifFilterStatus").addEventListener("change", refreshNotifications);
    closers("risk-config",    "riskConfigModal");
    closers("risk-approval",  "riskApprovalModal");
    closers("risk-treatment", "riskTreatmentModal");

    closers("risk-accept",   "riskAcceptModal");
    closers("risk-reject",   "riskRejectModal");
    closers("risk-analysis", "riskAnalysisModal");
    closers("risk-duplicate","riskDuplicateModal");
    closers("risk-custom",   "riskCustomModal");
    closers("reg-status",    "regStatusModal");
    closers("reg-owner",     "regOwnerModal");
    // Detail modals clear their Related Tasks host, so they close through
    // their own handler rather than hide().
    document.querySelectorAll("[data-close-risk-detail]").forEach(el =>
      el.addEventListener("click", () => closeDetailModal("riskDetailModal", "riskRelatedTasks")));
    document.querySelectorAll("[data-close-reg-detail]").forEach(el =>
      el.addEventListener("click", () => closeDetailModal("regDetailModal", "regRelatedTasks")));

    document.getElementById("riskAcceptMethod").addEventListener("change", renderAcceptMethodFields);
  }
  function closers(attr, modalId) {
    document.querySelectorAll(`[data-close-${attr}]`).forEach(el =>
      el.addEventListener("click", () => hide(modalId)));
  }

  function showTab(tab) {
    state.tab = tab;
    document.querySelectorAll("[data-risk-tab]").forEach(b => {
      const on = b.dataset.riskTab === tab;
      b.classList.toggle("is-active", on);
      b.setAttribute("aria-selected", on ? "true" : "false");
    });
    document.getElementById("riskListView").hidden      = (tab !== "candidates");
    document.getElementById("riskRegisterView").hidden  = (tab !== "register");
    document.getElementById("riskDashboardView").hidden = (tab !== "dashboard");
    if (tab === "register"  && state.organizationId) refreshRegister();
    if (tab === "dashboard" && state.organizationId) refreshDashboard();
  }

  async function onOrganizationChanged() {
    await loadOptions();
    await loadAssessOptions();
    await loadEmployees();
    await loadConfig();
    await refresh();
    if (state.tab === "register")  await refreshRegister();
    if (state.tab === "dashboard") await refreshDashboard();
  }

  // ---- lookups ------------------------------------------------------
  async function populateOrgFilter() {
    const sel = document.getElementById("riskFilterOrganization");
    let rows = [];
    try {
      const r = await fetch(U("/practice/api/organizations/allowed"), { credentials: "same-origin" });
      if (r.ok) { const b = await r.json(); rows = (b && (b.data || b.Data)) || []; }
    } catch (_) {}
    rows.forEach(row => {
      const value = String(row.organizationId ?? row.OrganizationId ?? "");
      const label = String(row.organizationName ?? row.OrganizationName ?? "");
      if (!value) return;
      const opt = document.createElement("option");
      opt.value = value; opt.textContent = label;
      sel.appendChild(opt);
    });
    if (sel.options.length === 2) sel.disabled = true;
  }

  // BRD §7 / §12 — the organisation's own framework, fetched once and
  // shared by both analysis forms.
  async function loadOptions() {
    state.options = null;
    if (!state.organizationId) return;
    const data = await apiGet(`/scoring-options?organizationId=${state.organizationId}`);
    state.options = data || { likelihood: [], impact: [], categories: [], sources: [], matrix: [] };

    fillSelect("riskFilterSource", state.options.sources, "sourceTypeCode", "sourceName", "All sources");
    fillSelect("regFilterSource",  state.options.sources, "sourceTypeCode", "sourceName", "All sources");
    fillSelect("regFilterCategory", state.options.categories, "categoryCode", "categoryName", "All categories");

    // The scale now belongs to stage 2 only — the candidate and custom
    // forms no longer carry category, likelihood or impact.
    fillSelect("raCategory",   state.options.categories, "categoryCode", "categoryName", "-- select --");
    fillSelect("raLikelihood", state.options.likelihood, "code", "name", "-- select --");
    fillSelect("raImpact",     state.options.impact,     "code", "name", "-- select --");
  }

  // Threat / vulnerability / business function (migration 216).
  async function loadAssessOptions() {
    state.assess = null;
    if (!state.organizationId) return;
    state.assess = await apiGet(`/assessment-options?organizationId=${state.organizationId}`)
                || { threats: [], vulnerabilities: [], businessFunctions: [] };

    ["anThreat", "cxThreat"].forEach(id =>
      fillSelect(id, state.assess.threats, "threatId", "threatName", "-- select --"));
    ["anVulnerability", "cxVulnerability"].forEach(id =>
      fillSelect(id, state.assess.vulnerabilities, "vulnerabilityId", "vulnerabilityName", "-- select --"));
    ["anBusinessFunction", "cxBusinessFunction"].forEach(id =>
      fillSelect(id, state.assess.businessFunctions, "businessFunctionId", "functionName", "-- select --"));
  }

  // "Others" is id 0 in both masters — that is the escape hatch, and it
  // is the only value that requires a description. The server enforces
  // the same rule, so this is an affordance, not the control.
  const OTHERS_ID = "0";
  function toggleOther(prefix, kind) {
    const sel  = document.getElementById(prefix + (kind === "Threat" ? "Threat" : "Vulnerability"));
    const wrap = document.getElementById(prefix + kind + "OtherWrap");
    if (!sel || !wrap) return;
    const isOther = String(sel.value) === OTHERS_ID;
    wrap.hidden = !isOther;
    if (!isOther) {
      const box = document.getElementById(
        prefix + (kind === "Threat" ? "ThreatDescription" : "VulnerabilityDescription"));
      if (box) box.value = "";
    }
  }

  async function loadEmployees() {
    state.employees = [];
    if (!state.organizationId) return;
    try {
      const r = await fetch(
        U(`/practice/api/document-uploads/lookups/employees?organizationId=${state.organizationId}`),
        { credentials: "same-origin" });
      state.employees = r.ok ? (await r.json()) || [] : [];
    } catch (_) { state.employees = []; }
    ["anOwner", "cxOwner", "roOwner"].forEach(id => {
      const sel = document.getElementById(id);
      if (!sel) return;
      sel.innerHTML = `<option value="">-- select --</option>`;
      state.employees.forEach(e => {
        const o = document.createElement("option");
        o.value = e.employeeId;
        o.textContent = e.employeeName + (e.employeeCode ? ` (${e.employeeCode})` : "");
        sel.appendChild(o);
      });
    });
  }

  function fillSelect(id, rows, valueKey, labelKey, emptyLabel) {
    const sel = document.getElementById(id);
    if (!sel) return;
    const previous = sel.value;
    sel.innerHTML = `<option value="">${escapeHtml(emptyLabel)}</option>`;
    (rows || []).forEach(row => {
      const o = document.createElement("option");
      o.value = row[valueKey] ?? "";
      o.textContent = row[labelKey] ?? o.value;
      sel.appendChild(o);
    });
    if (previous) sel.value = previous;
  }

  // BRD §7.1 — the rating is derived from the matrix, never typed. This
  // mirrors sp_risk_rating_resolve; the server still recomputes it on
  // save, so a stale client cannot persist a wrong rating.
  function renderRating(prefix) {
    const out = document.getElementById(prefix + "Rating");
    if (!out || !state.options) return;
    const lk = state.options.likelihood.find(x => x.code === document.getElementById(prefix + "Likelihood").value);
    const im = state.options.impact.find(x => x.code === document.getElementById(prefix + "Impact").value);
    if (!lk || !im) {
      out.textContent = "Select likelihood and impact";
      out.removeAttribute("data-rating");
      return;
    }
    const cell = state.options.matrix.find(c =>
      c.likelihoodValue === lk.levelValue && c.impactValue === im.levelValue);
    if (!cell) {
      out.textContent = "No matrix cell configured for this combination";
      out.removeAttribute("data-rating");
      return;
    }
    out.textContent = `${cell.ratingName}${cell.ratingScore != null ? ` (score ${cell.ratingScore})` : ""}`;
    out.setAttribute("data-rating", cell.ratingCode);
  }

  // ---- Candidates grid ----------------------------------------------
  async function refresh() {
    const tbody = document.getElementById("riskTableBody");
    if (!state.organizationId) {
      tbody.innerHTML = `<tr><td colspan="9" class="pm-empty-row">Select an organization.</td></tr>`;
      return;
    }
    tbody.innerHTML = `<tr><td colspan="9" class="pm-empty-row">Loading...</td></tr>`;
    const qs = new URLSearchParams({ organizationId: state.organizationId });
    if (state.statusCode)     qs.set("statusCode", state.statusCode);
    if (state.sourceTypeCode) qs.set("sourceTypeCode", state.sourceTypeCode);
    const data = await apiGet(`?${qs}`);
    const rows = data?.rows || [];
    if (!rows.length) {
      tbody.innerHTML = `<tr><td colspan="9" class="pm-empty-row">No matching risk candidates.</td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    rows.forEach(r => {
      const tr = document.createElement("tr");
      tr.innerHTML = `
        <td>${escapeHtml(r.candidateTitle)}<br>
            <span class="pm-hint">${escapeHtml(r.candidateNumber || "")}</span></td>
        <td>${sourceCell(r)}</td>
        <td>${r.inherentRatingCode ? severityChip(r.inherentRatingCode)
                                   : (r.severityCode ? severityChip(r.severityCode) + ' <span class="pm-hint">(intake)</span>' : "--")}</td>
        <td>${escapeHtml(r.assignedAnalystName || "--")}</td>
        <td>${r.identifiedOn ? new Date(r.identifiedOn).toLocaleDateString() : "--"}<br>
            <span class="pm-hint">${escapeHtml(r.requestedByName || "system")}</span></td>
        <td>${statusChip(r.statusCode)}</td>
        <td>${r.registeredRiskNumber
                ? `<a href="#" data-open-risk="${r.registeredRiskId}">${escapeHtml(r.registeredRiskNumber)}</a>`
                : escapeHtml(r.formalRiskRef || "--")}</td>
        <td>${r.attachmentCount || 0}</td>
        <td>
          <button type="button" class="pm-action-trigger" data-risk-menu="${r.riskCandidateId}"
                  data-risk-status="${escapeHtml(r.statusCode)}"
                  data-risk-analysis="${r.currentAnalysisId || ""}"
                  data-risk-gap="${r.customGapId || ""}"
                  aria-haspopup="menu" aria-expanded="false" title="Actions">
            <i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i>
          </button>
        </td>`;
      tbody.appendChild(tr);
    });
  }

  function sourceCell(r) {
    const chip = `<span class="risk-source-chip">${escapeHtml(r.sourceName || r.sourceTypeCode || "--")}</span>`;
    // BRD §10 — navigate back to the originating record where the Centre
    // has a screen we can reach. Gap is the only one wired today; the
    // rest show the reference until their Centre exposes a deep link.
    if (r.sourceTypeCode === "Gap" && r.customGapId) {
      return `${chip}<br><a href="${U("/Practice/Index/gap-detail")}?gapId=${r.customGapId}&orgId=${state.organizationId}">
                ${escapeHtml(r.sourceReference || `Gap #${r.customGapId}`)}</a>`;
    }
    return `${chip}${r.sourceReference ? `<br><span class="pm-hint">${escapeHtml(r.sourceReference)}</span>` : ""}`;
  }

  // Stored code -> [css class, label]. The stored codes stay as the BRD
  // and migration 205 define them; only the label is the business's word
  // for it ("Assessment" rather than the BRD's "Analysis"). One map, so a
  // chip and a disabled-menu tooltip can never disagree about what a
  // status is called.
  const STATUS_MAP = {
    Pending:               ["risk-pending",    "New"],
    UnderAnalysis:         ["risk-analysing",  "Under assessment"],
    ClarificationRequired: ["risk-clarify",    "Clarification required"],
    AnalysisCompleted:     ["risk-analysed",   "Assessment completed"],
    Registered:            ["risk-registered", "Registered"],
    Accepted:              ["risk-accepted",   "Accepted"],
    Rejected:              ["risk-rejected",   "Rejected"],
    ClosedAsDuplicate:     ["risk-duplicate",  "Duplicate"],
    Withdrawn:             ["risk-withdrawn",  "Withdrawn"],
    // Risk Register statuses (BRD §17)
    Active:                ["risk-registered", "Active"],
    UnderTreatment:        ["risk-analysing",  "Under treatment"],
    Monitoring:            ["risk-analysed",   "Monitoring"],
    Closed:                ["risk-withdrawn",  "Closed"],
    Retired:               ["risk-withdrawn",  "Retired"]
  };
  function statusLabel(code) { return (STATUS_MAP[code] || [null, code || ""])[1]; }
  function statusChip(code) {
    const [cls, label] = STATUS_MAP[code] || ["risk-pending", code || ""];
    return `<span class="risk-status-chip ${cls}">${escapeHtml(label)}</span>`;
  }
  function severityChip(code) {
    if (!code) return "--";
    const norm = String(code).toLowerCase();
    const cls = norm.includes("critical") ? "risk-sev-critical"
              : norm.includes("high")     ? "risk-sev-high"
              : norm.includes("medium")   ? "risk-sev-medium"
              : "risk-sev-low";
    return `<span class="risk-severity-chip ${cls}">${escapeHtml(code)}</span>`;
  }

  // ---- Register grid -------------------------------------------------
  async function refreshRegister() {
    const tbody = document.getElementById("regTableBody");
    if (!state.organizationId) {
      tbody.innerHTML = `<tr><td colspan="9" class="pm-empty-row">Select an organization.</td></tr>`;
      return;
    }
    tbody.innerHTML = `<tr><td colspan="9" class="pm-empty-row">Loading...</td></tr>`;
    const qs = new URLSearchParams({ organizationId: state.organizationId });
    const add = (id, key) => {
      const v = document.getElementById(id).value;
      if (v) qs.set(key, v);
    };
    add("regFilterStatus",   "statusCode");
    add("regFilterSource",   "sourceTypeCode");
    add("regFilterCategory", "categoryCode");
    add("regFilterRating",   "ratingCode");
    add("regFilterSearch",   "search");
    add("regFilterPending",  "analysisPending");

    const data = await apiGet(`/register?${qs}`);
    const rows = data?.rows || [];
    if (!rows.length) {
      tbody.innerHTML = `<tr><td colspan="9" class="pm-empty-row">No risks in the register match these filters.</td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    rows.forEach(r => {
      const tr = document.createElement("tr");
      tr.innerHTML = `
        <td><a href="#" data-open-risk="${r.riskRegisterId}">${escapeHtml(r.riskNumber)}</a></td>
        <td>${escapeHtml(r.riskTitle)}</td>
        <td>${escapeHtml(r.riskCategoryName || "--")}</td>
        <td><span class="risk-source-chip">${escapeHtml(r.sourceTypeCode)}</span>
            ${r.sourceReference ? `<br><span class="pm-hint">${escapeHtml(r.sourceReference)}</span>` : ""}</td>
        <td>${r.analysisPending
              ? `<span class="risk-status-chip risk-clarify">Analysis pending</span>`
              : severityChip(r.inherentRatingCode)}</td>
        <td>${escapeHtml(r.riskOwnerName || "--")}</td>
        <td>${statusChip(r.statusCode)}</td>
        <td>${new Date(r.registeredOn).toLocaleDateString()}<br>
            <span class="pm-hint">${escapeHtml(r.registeredByName || "system")}</span></td>
        <td>
          <button type="button" class="pm-action-trigger" data-reg-menu="${r.riskRegisterId}"
                  data-reg-status="${escapeHtml(r.statusCode)}"
                  data-reg-pending="${r.analysisPending ? 1 : 0}"
                  aria-haspopup="menu" aria-expanded="false" title="Actions">
            <i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i>
          </button>
        </td>`;
      tbody.appendChild(tr);
    });
  }

  // ---- 3-dot menu (PM standard, same shape as exception-centre) ------
  let openMenuEl = null, openMenuTrigger = null;
  function closeRowMenu() {
    if (openMenuEl) { openMenuEl.remove(); openMenuEl = null; }
    if (openMenuTrigger) { openMenuTrigger.setAttribute("aria-expanded", "false"); openMenuTrigger = null; }
  }
  function positionRowMenu(trigger) {
    if (!openMenuEl) return;
    const r = trigger.getBoundingClientRect(), mr = openMenuEl.getBoundingClientRect();
    let top = r.bottom + 6, left = r.right - mr.width;
    if (top + mr.height > window.innerHeight - 8) top = Math.max(8, r.top - mr.height - 6);
    if (left < 8) left = 8;
    if (left + mr.width > window.innerWidth - 8) left = window.innerWidth - mr.width - 8;
    openMenuEl.style.top = top + "px"; openMenuEl.style.left = left + "px";
  }
  function openRowMenu(trigger, items) {
    closeRowMenu();
    openMenuTrigger = trigger;
    trigger.setAttribute("aria-expanded", "true");
    openMenuEl = document.createElement("div");
    openMenuEl.className = "pm-action-menu";
    openMenuEl.setAttribute("role", "menu");
    items.forEach(it => {
      const b = document.createElement("button");
      b.type = "button"; b.setAttribute("role", "menuitem");
      b.innerHTML = `<i class="fa-solid ${escapeHtml(it.icon)}" aria-hidden="true"></i> ${escapeHtml(it.label)}`;
      if (it.disabled) { b.disabled = true; b.title = it.disabledReason || ""; }
      b.addEventListener("click", ev => {
        ev.preventDefault(); ev.stopPropagation(); closeRowMenu();
        try { it.action(); } catch (err) { console.error("[risk] menu action failed", err); }
      });
      openMenuEl.appendChild(b);
    });
    document.body.appendChild(openMenuEl);
    positionRowMenu(trigger);
  }

  // Statuses a candidate can still be worked in (BRD §16).
  const OPEN_STATUSES = ["Pending", "UnderAnalysis", "ClarificationRequired", "AnalysisCompleted"];

  // Delegated ONCE at module scope, for both grids and the register
  // links. The old per-refresh wiring guarded itself with a dataset
  // flag; a single document-level listener is simpler and survives the
  // grids being re-rendered, which they are on every filter change.
  (function wireDelegation() {
    document.addEventListener("click", ev => {
      const openRisk = ev.target.closest("[data-open-risk]");
      if (openRisk) {
        ev.preventDefault();
        openRegisterDetail(Number(openRisk.dataset.openRisk));
        return;
      }

      // ---- Phase B: dashboard drill-downs and inline actions --------
      const openCand = ev.target.closest("[data-open-candidate]");
      if (openCand) {
        ev.preventDefault();
        openDetailModal(Number(openCand.dataset.openCandidate));
        return;
      }

      const approveBtn = ev.target.closest("[data-approve]");
      if (approveBtn) {
        ev.preventDefault();
        openApprovalModal(Number(approveBtn.dataset.approve));
        return;
      }

      // A tile or bar click is a filter change on the grid the user
      // already knows, not a new screen.
      const drillTile = ev.target.closest("[data-drill-candidate-status]");
      if (drillTile) {
        ev.preventDefault();
        setVal("riskFilterStatus", drillTile.dataset.drillCandidateStatus);
        state.statusCode = drillTile.dataset.drillCandidateStatus;
        showTab("candidates");
        refresh();
        return;
      }

      const drillBar = ev.target.closest("[data-drill-tab]");
      if (drillBar) {
        ev.preventDefault();
        const { drillTab, drillField, drillValue } = drillBar.dataset;
        if (drillTab === "register") {
          const map = { sourceTypeCode: "regFilterSource",
                        categoryCode:   "regFilterCategory",
                        ratingCode:     "regFilterRating" };
          const target = map[drillField];
          if (target) setVal(target, drillValue);
          showTab("register");
          refreshRegister();
        } else if (drillTab === "candidates") {
          if (drillField === "sourceTypeCode") {
            setVal("riskFilterSource", drillValue);
            state.sourceTypeCode = drillValue;
          }
          showTab("candidates");
          refresh();
        }
        return;
      }

      const candTrigger = ev.target.closest(".pm-action-trigger[data-risk-menu]");
      if (candTrigger) {
        ev.preventDefault(); ev.stopPropagation();
        if (openMenuTrigger === candTrigger) { closeRowMenu(); return; }
        const id     = Number(candTrigger.dataset.riskMenu);
        const status = candTrigger.dataset.riskStatus;
        const isOpen = OPEN_STATUSES.includes(status);
        // TWO ACTIONS, DELIBERATELY.
        //
        // Everything a candidate needs is either reading it or assessing
        // it. Register, reject and the duplicate decision all follow FROM
        // an assessment — BRD §8 puts all three after it — so they live
        // in the assessment modal where the analyst can see what they are
        // deciding on. A row menu that offers "Register as risk" before
        // anyone has opened the assessment invites exactly the click the
        // server then refuses.
        //
        // Approval is not here either: the approver's job starts on the
        // Dashboard's "Awaiting approval" queue, which is a worklist, not
        // a per-row afterthought.
        openRowMenu(candTrigger, [
          { icon: "fa-eye", label: "View details", action: () => openDetailModal(id) },
          { icon: "fa-magnifying-glass-chart", label: "Assessment",
            disabled: !isOpen,
            disabledReason: `This candidate is closed and cannot be assessed (current: ${statusLabel(status)}).`,
            action: () => openAnalysisModal(id) }
        ]);
        return;
      }

      const regTrigger = ev.target.closest(".pm-action-trigger[data-reg-menu]");
      if (regTrigger) {
        ev.preventDefault(); ev.stopPropagation();
        if (openMenuTrigger === regTrigger) { closeRowMenu(); return; }
        const id = Number(regTrigger.dataset.regMenu);
        const regStatus = regTrigger.dataset.regStatus;
        const regClosed = regStatus === "Closed" || regStatus === "Retired";
        openRowMenu(regTrigger, [
          { icon: "fa-eye",        label: "View risk",     action: () => openRegisterDetail(id) },
          // Stage 2 (216) — the scoring work lives here, not on the
          // candidate. Labelled "Analysis" to match what it produces.
          { icon: "fa-magnifying-glass-chart",
            label: regTrigger.dataset.regPending === "1" ? "Analysis (pending)" : "Analysis",
            disabled: regClosed,
            disabledReason: `A ${regStatus?.toLowerCase()} risk cannot be re-analysed.`,
            action: () => openRegAnalysisModal(id) },
          // §19 — only meaningful once an analysis is waiting.
          { icon: "fa-gavel", label: "Review analysis",
            disabled: regClosed || !state.config?.approvalRequired,
            disabledReason: !state.config?.approvalRequired
              ? "Approval is not configured for this organisation."
              : `A ${regStatus?.toLowerCase()} risk has nothing to review.`,
            action: async () => { await openRegisterDetail(id); hide("regDetailModal"); openRegApprovalModal(id); } },
          { icon: "fa-flag",       label: "Change status", action: () => openRegStatusModal(id) },
          { icon: "fa-user-check", label: "Change owner",  action: () => openRegOwnerModal(id) },
          // BRD §22 — the treatment decision belongs here, on a risk that
          // is already registered, not on the registration form.
          { icon: "fa-list-check", label: "Raise treatment task",
            disabled: regStatus === "Closed" || regStatus === "Retired",
            disabledReason: `A ${regStatus?.toLowerCase()} risk does not need treatment work.`,
            action: () => openTreatmentModal(id) }
        ]);
        return;
      }

      if (!openMenuEl) return;
      if (ev.target.closest(".pm-action-menu")) return;
      if (ev.target.closest(".pm-action-trigger")) return;
      closeRowMenu();
    });
    document.addEventListener("keydown", ev => { if (ev.key === "Escape") closeRowMenu(); });
    window.addEventListener("resize", closeRowMenu);
    window.addEventListener("scroll", closeRowMenu, true);
  })();

  // ---- Candidate detail ---------------------------------------------
  async function openDetailModal(id) {
    const cand = await apiGet(`/${id}`);
    if (!cand) return;
    state.activeCandidate = cand;

    document.getElementById("riskDetailTitle").textContent =
      cand.candidateTitle || `Risk candidate #${id}`;
    document.getElementById("riskDetailMeta").innerHTML = metaOf(cand);

    // BRD §20 — every retained analysis version.
    const versions = await apiGet(`/${id}/analysis/history`) || [];
    document.getElementById("riskAnalysisHistory").innerHTML = versions.length
      ? `<table><thead><tr><th>Ver</th><th>Statement</th><th>Likelihood</th><th>Impact</th>
           <th>Rating</th><th>Decision</th><th>Assessed</th><th>By</th></tr></thead><tbody>` +
        versions.map(v => `<tr${v.isCurrent ? ' style="font-weight:600"' : ""}>
            <td>v${v.analysisVersion}</td>
            <td>${escapeHtml(v.riskStatement)}</td>
            <td>${escapeHtml(v.likelihoodName || "--")}</td>
            <td>${escapeHtml(v.impactName || "--")}</td>
            <td>${v.inherentRatingCode ? severityChip(v.inherentRatingCode) : "--"}</td>
            <td>${escapeHtml(v.decisionCode || "--")}</td>
            <td>${new Date(v.analysisOn).toLocaleString()}</td>
            <td>${escapeHtml(v.analysedByName || "--")}</td>
          </tr>`).join("") + `</tbody></table>`
      : `<p class="pm-hint">No assessment yet. This candidate cannot be registered until one exists.</p>`;

    mountRelatedTasks("riskRelatedTasks", "Risk", id);
    show("riskDetailModal");
  }

  function mountRelatedTasks(hostId, sourceTypeCode, sourceRecordId) {
    const host = document.getElementById(hostId);
    if (!host) return;
    if (window.__gracRelatedTasks) {
      window.__gracRelatedTasks.mount(host, {
        sourceTypeCode, sourceRecordId, organizationId: state.organizationId
      });
    } else {
      host.innerHTML = "";
    }
  }
  function closeDetailModal(modalId, hostId) {
    const host = document.getElementById(hostId);
    if (host && window.__gracRelatedTasks) window.__gracRelatedTasks.clear(host);
    hide(modalId);
  }

  // ---- Initial Risk Analysis (BRD §7) --------------------------------
  async function openAnalysisModal(id) {
    const cand = await apiGet(`/${id}`);
    if (!cand) { dlg.alert("Candidate not found.", { type: "error" }); return; }
    state.activeCandidate = cand;

    document.getElementById("anCandidateId").value = id;
    document.getElementById("anMeta").innerHTML = metaOf(cand);
    document.getElementById("anMessage").textContent = "";

    if (!state.assess) await loadAssessOptions();
    if (!state.employees.length) await loadEmployees();

    // Pre-fill from the current version if there is one, so a revision
    // starts from what was last recorded rather than blank.
    const a = await apiGet(`/${id}/analysis`);
    setVal("anStatement",   a?.riskStatement || cand.candidateSummary || "");
    setVal("anThreat",      a?.threatId ?? "");
    setVal("anVulnerability", a?.vulnerabilityId ?? "");
    setVal("anThreatDescription", a?.threatDescription || "");
    setVal("anVulnerabilityDescription", a?.vulnerabilityDescription || "");
    setVal("anOwner",       a?.riskOwnerEmployeeId || "");
    setVal("anBusinessFunction", a?.businessFunctionId || "");
    toggleOther("an", "Threat");
    toggleOther("an", "Vuln");
    show("riskAnalysisModal");
  }

  async function onAnalysisSubmit(ev, thenRegister) {
    if (ev) ev.preventDefault();
    const msg = document.getElementById("anMessage");
    msg.textContent = "";
    const id = Number(document.getElementById("anCandidateId").value);
    const statement = val("anStatement");
    if (!statement) { msg.textContent = "Risk statement is required."; return; }

    const gate = assessmentPayload("an", msg);
    if (!gate) return;

    const result = await apiPost(`/${id}/analysis`, { riskStatement: statement, ...gate });
    if (!result || result.success === false) {
      msg.textContent = (result && result.error) || "Save failed.";
      return;
    }
    hide("riskAnalysisModal");
    await refresh();
    if (thenRegister) startRegister(id);
    else dlg.alert(`Assessment v${result.analysisVersion} saved.`, { title: "Assessment saved", type: "success" });
  }

  // The four shared assessment fields, validated and shaped once for
  // both forms. Returning null means "already told the user why not" —
  // §12's one-methodology rule applies to the client too: if the two
  // forms validated separately they would eventually disagree.
  function assessmentPayload(prefix, msgEl) {
    const threat = val(prefix + "Threat");
    const vuln   = val(prefix + "Vulnerability");
    const owner  = val(prefix + "Owner");
    const bf     = val(prefix + "BusinessFunction");
    const threatDesc = val(prefix + "ThreatDescription");
    const vulnDesc   = val(prefix + "VulnerabilityDescription");

    const fail = m => { if (msgEl) msgEl.textContent = m; return null; };
    if (!threat) return fail("Threat is required.");
    if (!vuln)   return fail("Vulnerability is required.");
    if (!owner)  return fail("Risk owner is required.");
    if (!bf)     return fail("Business function is required.");
    if (threat === OTHERS_ID && !threatDesc) return fail("Describe the threat when “Others” is selected.");
    if (vuln   === OTHERS_ID && !vulnDesc)   return fail("Describe the vulnerability when “Others” is selected.");

    return {
      threatId:                 Number(threat),
      threatDescription:        threatDesc || null,
      vulnerabilityId:          Number(vuln),
      vulnerabilityDescription: vulnDesc || null,
      riskOwnerEmployeeId:      Number(owner),
      businessFunctionId:       Number(bf)
    };
  }

  // ---- Registration (BRD §8A) with §15 duplicate detection first -----
  async function startRegister(id) {
    state.pendingRegisterCandidateId = id;
    const cand = await apiGet(`/${id}`);
    const analysis = await apiGet(`/${id}/analysis`);
    if (!analysis) {
      dlg.alert("Complete the risk assessment before registering. No risk enters the register without one.",
                { title: "Assessment required", type: "warning" });
      return;
    }
    state.activeCandidate = cand;

    // §15 — advisory. Empty result means we go straight through.
    const matches = await apiPost("/duplicate-check", {
      organizationId:   state.organizationId,
      riskTitle:        cand?.candidateTitle,
      riskStatement:    analysis.riskStatement,
      riskCategoryCode: analysis.riskCategoryCode,
      sourceTypeCode:   cand?.sourceTypeCode,
      sourceRecordId:   cand?.sourceRecordId,
      businessUnit:     analysis.businessUnit
    });
    const rows = Array.isArray(matches) ? matches : [];
    if (!rows.length) { await doRegister(id); return; }
    renderDuplicates(rows, id);
    show("riskDuplicateModal");
  }

  function renderDuplicates(rows, candidateId) {
    document.getElementById("dupMessage").textContent = "";
    const tbody = document.getElementById("dupTableBody");
    tbody.innerHTML = "";
    rows.forEach(m => {
      const tr = document.createElement("tr");
      tr.innerHTML = `
        <td>${escapeHtml(m.riskNumber)}</td>
        <td>${escapeHtml(m.riskTitle)}<br><span class="pm-hint">${escapeHtml(m.matchReason || "")}</span></td>
        <td>${escapeHtml(m.sourceTypeCode || "--")}</td>
        <td>${severityChip(m.inherentRatingCode)}</td>
        <td>${statusChip(m.statusCode)}</td>
        <td>${m.matchScore}</td>
        <td><button type="button" class="pm-button" data-dup-link="${m.riskRegisterId}">
              <i class="fa-solid fa-clone"></i> Close as duplicate</button></td>`;
      tr.querySelector("[data-dup-link]").addEventListener("click", async () => {
        const remark = await dlg.prompt("This candidate will be closed against the risk above.", {
          title: "Close as duplicate", type: "warning",
          inputLabel: "Remark", confirmText: "Close as duplicate" });
        if (remark === null) return;
        const res = await apiPost(`/${candidateId}/close-duplicate`, {
          duplicateOfRiskId: m.riskRegisterId, remark: remark || null
        });
        if (!res || res.success === false) {
          document.getElementById("dupMessage").textContent = (res && res.error) || "Failed.";
          return;
        }
        hide("riskDuplicateModal");
        dlg.alert("Candidate closed as duplicate.", { type: "success" });
        await refresh();
      });
      tbody.appendChild(tr);
    });
  }

  async function onDuplicateContinue() {
    const id = state.pendingRegisterCandidateId;
    hide("riskDuplicateModal");
    if (id) await doRegister(id);
  }

  async function doRegister(id) {
    const note = await dlg.prompt("Recorded on the risk and on its assessment. Optional.", {
      title: "Register this risk", inputLabel: "Registration note", confirmText: "Register" });
    if (note === null) return;
    const result = await apiPost(`/${id}/register`, { registrationNote: note || null });
    if (!result || result.success === false) {
      const err = (result && result.error) || "Registration failed.";
      // BRD §19 — the gate is threshold-based and resolved server-side
      // against the organisation's own matrix, so the client cannot
      // predict it. Rather than duplicate that rule in JS and risk the
      // two disagreeing, we let the register attempt fail and offer the
      // step it asked for. Error 56270 carries the reason in words.
      if (/approval is required/i.test(err)) {
        if (await dlg.confirm(`${err} Submit this assessment for approval now?`,
                              { title: "Approval required", type: "warning", confirmText: "Submit" }))
          await submitForApproval(id);
        return;
      }
      dlg.alert(err, { title: "Registration failed", type: "error" });
      return;
    }
    dlg.alert(`Registered as ${result.riskNumber}.`, { title: "Risk registered", type: "success" });
    await refresh();
    if (state.tab === "register") await refreshRegister();
  }

  // ---- Custom risk, Route B (BRD §4B, §11) ---------------------------
  async function openCustomModal() {
    if (!state.organizationId) { dlg.alert("Select an organization first.", { type: "warning" }); return; }
    if (!state.assess) await loadAssessOptions();
    if (!state.employees.length) await loadEmployees();
    ["cxTitle","cxStatement","cxThreatDescription","cxVulnerabilityDescription"]
      .forEach(id => setVal(id, ""));
    ["cxThreat","cxVulnerability","cxOwner","cxBusinessFunction"].forEach(id => setVal(id, ""));
    document.getElementById("cxMessage").textContent = "";
    toggleOther("cx", "Threat");
    toggleOther("cx", "Vuln");
    show("riskCustomModal");
  }

  async function onCustomSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("cxMessage");
    msg.textContent = "";

    const statement = val("cxStatement");
    if (!val("cxTitle"))  { msg.textContent = "Risk title is required."; return; }
    if (!statement)       { msg.textContent = "Risk statement is required."; return; }
    const gate = assessmentPayload("cx", msg);
    if (!gate) return;

    const body = {
      organizationId: state.organizationId,
      riskTitle:      val("cxTitle"),
      riskStatement:  statement,
      ...gate
    };

    // §15 applies to custom risks too — "before registering a Risk
    // Candidate OR Custom Risk".
    const matches = await apiPost("/duplicate-check", {
      organizationId:   state.organizationId,
      riskTitle:        body.riskTitle,
      riskStatement:    body.riskStatement,
      sourceTypeCode:   "Custom",
      businessUnit:     body.businessUnit
    });
    const rows = Array.isArray(matches) ? matches : [];
    if (rows.length && !(await dlg.confirm(
        `${rows.length} similar risk(s) are already in the register, for example `
        + `${rows[0].riskNumber} — ${rows[0].riskTitle}. Create this as a separate risk anyway?`,
        { title: "Possible duplicate", type: "warning", confirmText: "Create anyway" }))) {
      msg.textContent = "Cancelled — review the existing risks first.";
      return;
    }

    const result = await apiPost("/custom", body);
    if (!result || result.success === false) {
      msg.textContent = (result && result.error) || "Create failed.";
      return;
    }
    hide("riskCustomModal");
    dlg.alert(`Custom risk registered as ${result.riskNumber}.`, { title: "Risk registered", type: "success" });
    showTab("register");
    await refreshRegister();
  }

  // ---- Registered risk detail (BRD §9.1, §10) ------------------------
  async function openRegisterDetail(riskId) {
    const risk = await apiGet(`/register/${riskId}`);
    if (!risk) { dlg.alert("Risk not found.", { type: "error" }); return; }
    state.activeRisk = risk;

    document.getElementById("regDetailTitle").textContent = `${risk.riskNumber} — ${risk.riskTitle}`;
    document.getElementById("regDetailMeta").innerHTML =
      dd("Statement",   risk.riskStatement) +
      dd("Threat", risk.threatId === 0 ? risk.threatDescription : risk.threatName) +
      dd("Vulnerability", risk.vulnerabilityId === 0 ? risk.vulnerabilityDescription : risk.vulnerabilityName) +
      dd("Business function", risk.businessFunctionName) +
      dd("Category",    risk.riskCategoryName) +
      dd("Status",      statusChip(risk.statusCode), true) +
      dd("Rating", risk.analysisPending
            ? `<span class="risk-status-chip risk-clarify">Analysis pending</span>
               <span class="pm-hint">score this risk from the Analysis action</span>`
            : severityChip(risk.inherentRatingCode) +
              ` <span class="pm-hint">${escapeHtml(risk.likelihoodName || "?")} x ${escapeHtml(risk.impactName || "?")}</span>`
              + (risk.analysisApprovalStatusCode === "Pending"
                   ? ` <span class="risk-status-chip risk-clarify">new rating awaiting approval</span>` : ""), true) +
      dd("Owner",       risk.riskOwnerName) +
      dd("Business unit", risk.businessUnit) +
      dd("Process",     risk.processName) +
      dd("Cause",       risk.riskCause) +
      dd("Consequence", risk.potentialConsequence) +
      dd("Existing controls", risk.existingControls) +
      dd("Description", risk.riskDescription) +
      dd("Registered",  `${new Date(risk.registeredOn).toLocaleString()} by ${escapeHtml(risk.registeredByName || "system")}`, true) +
      (risk.closedOn ? dd("Closed", `${new Date(risk.closedOn).toLocaleString()} — ${escapeHtml(risk.closureReason || "")}`, true) : "");

    // BRD §10 — Risk Register -> Analysis -> Candidate -> Source.
    const steps = [`<span class="risk-trace-step"><strong>${escapeHtml(risk.riskNumber)}</strong></span>`];
    steps.push(`<span class="risk-trace-step">Assessment v${risk.analysisVersion || "?"}${
      risk.analysedByName ? ` — ${escapeHtml(risk.analysedByName)}` : ""}</span>`);
    if (risk.riskCandidateId) {
      steps.push(`<span class="risk-trace-step">${escapeHtml(risk.candidateNumber || `Candidate #${risk.riskCandidateId}`)}</span>`);
    }
    if (risk.sourceTypeCode === "Custom") {
      steps.push(`<span class="risk-trace-step">Custom risk creation</span>`);
    } else if (risk.sourceTypeCode === "Gap" && risk.customGapId) {
      steps.push(`<span class="risk-trace-step">
        <a href="${U("/Practice/Index/gap-detail")}?gapId=${risk.customGapId}&orgId=${risk.organizationId}">
          ${escapeHtml(risk.sourceReference || `Gap #${risk.customGapId}`)}</a></span>`);
    } else {
      steps.push(`<span class="risk-trace-step">${escapeHtml(risk.sourceName || risk.sourceTypeCode)}${
        risk.sourceReference ? ` — ${escapeHtml(risk.sourceReference)}` : ""}</span>`);
    }
    document.getElementById("regTrace").innerHTML =
      steps.join(`<span class="risk-trace-arrow"><i class="fa-solid fa-arrow-right"></i></span>`);

    // BRD §22 — treatment work, if the organisation chose to raise any.
    mountRelatedTasks("regRelatedTasks", "Risk", risk.riskCandidateId || riskId);
    show("regDetailModal");
  }

  // ---- Stage 2: the scored analysis on a registered risk (216) -------
  async function openRegAnalysisModal(riskId) {
    const risk = await apiGet(`/register/${riskId}`);
    if (!risk) { dlg.alert("Risk not found.", { type: "error" }); return; }
    if (!state.options) await loadOptions();
    state.activeRisk = risk;

    document.getElementById("raRiskId").value = riskId;
    document.getElementById("raMessage").textContent = "";
    document.getElementById("raMeta").innerHTML =
      dd("Risk", `${escapeHtml(risk.riskNumber)} — ${escapeHtml(risk.riskTitle)}`, true) +
      dd("Statement", risk.riskStatement) +
      dd("Threat", risk.threatId === 0 ? risk.threatDescription : risk.threatName) +
      dd("Vulnerability", risk.vulnerabilityId === 0 ? risk.vulnerabilityDescription : risk.vulnerabilityName) +
      dd("Owner", risk.riskOwnerName) +
      dd("Business function", risk.businessFunctionName) +
      (risk.analysisApprovalStatusCode === "Pending"
        ? dd("Note", `<span class="risk-status-chip risk-clarify">Awaiting approval</span>
             <span class="pm-hint">saving again replaces the version waiting for review</span>`, true)
        : "");

    setVal("raCategory",    risk.riskCategoryCode || "");
    setVal("raLikelihood",  risk.likelihoodCode || "");
    setVal("raImpact",      risk.impactCode || "");
    setVal("raCause",       risk.riskCause || "");
    setVal("raConsequence", risk.potentialConsequence || "");
    setVal("raControls",    risk.existingControls || "");
    setVal("raDescription", risk.riskDescription || "");
    setVal("raProcess",     risk.processName || "");
    setVal("raRemarks",     "");
    renderRating("ra");
    show("riskRegAnalysisModal");
  }

  async function onRegAnalysisSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("raMessage");
    msg.textContent = "";
    const riskId = Number(document.getElementById("raRiskId").value);
    if (!val("raCategory"))   { msg.textContent = "Risk category is required."; return; }
    if (!val("raLikelihood")) { msg.textContent = "Likelihood is required."; return; }
    if (!val("raImpact"))     { msg.textContent = "Impact is required."; return; }

    const res = await apiPost(`/register/${riskId}/assess`, {
      riskCategoryCode:     val("raCategory"),
      likelihoodCode:       val("raLikelihood"),
      impactCode:           val("raImpact"),
      riskCause:            val("raCause") || null,
      potentialConsequence: val("raConsequence") || null,
      existingControls:     val("raControls") || null,
      riskDescription:      val("raDescription") || null,
      processName:          val("raProcess") || null,
      analystRemarks:       val("raRemarks") || null
    });
    if (!res || res.success === false) { msg.textContent = (res && res.error) || "Failed."; return; }

    hide("riskRegAnalysisModal");
    // §19 — "saved and live" and "saved and waiting for an approver" are
    // different outcomes, so they get different messages.
    if (res.approvalRequired)
      dlg.alert(`Rated ${res.inherentRatingCode}. It needs approval before it becomes `
                + `the register's rating. ${res.approvalReason || ""}`,
                { title: `Analysis v${res.analysisVersion} submitted`, type: "warning" });
    else
      dlg.alert(`Inherent rating: ${res.inherentRatingCode}.`,
                { title: `Analysis v${res.analysisVersion} saved`, type: "success" });
    await refreshRegister();
  }

  function openRegApprovalModal(riskId) {
    const r = state.activeRisk && state.activeRisk.riskRegisterId === riskId ? state.activeRisk : null;
    document.getElementById("rgaRiskId").value = riskId;
    document.getElementById("rgaRemark").value = "";
    document.getElementById("rgaMessage").textContent = "";
    document.getElementById("rgaMeta").innerHTML = r
      ? dd("Risk", `${escapeHtml(r.riskNumber)} — ${escapeHtml(r.riskTitle)}`, true) +
        dd("Proposed rating", severityChip(r.inherentRatingCode), true) +
        dd("Category", r.riskCategoryName) +
        dd("Owner", r.riskOwnerName)
      : dd("Risk", `#${riskId}`, true);
    show("riskRegApprovalModal");
  }

  async function onRegApprovalDecision(ev, decision) {
    if (ev) ev.preventDefault();
    const msg = document.getElementById("rgaMessage");
    msg.textContent = "";
    const riskId = Number(document.getElementById("rgaRiskId").value);
    const remark = val("rgaRemark");
    if (decision === "Return" && !remark) {
      msg.textContent = "A reason is required when returning an analysis.";
      return;
    }
    const res = await apiPost(`/register/${riskId}/assess/approve`, { decision, remark: remark || null });
    if (!res || res.success === false) { msg.textContent = (res && res.error) || "Failed."; return; }
    hide("riskRegApprovalModal");
    await refreshRegister();
  }

  // ---- Register status / owner (BRD §17, §18) ------------------------
  function openRegStatusModal(riskId) {
    const r = state.activeRisk && state.activeRisk.riskRegisterId === riskId ? state.activeRisk : null;
    document.getElementById("rsRiskId").value = riskId;
    document.getElementById("rsRemark").value = "";
    document.getElementById("rsMessage").textContent = "";
    document.getElementById("rsMeta").innerHTML = r
      ? dd("Risk", `${escapeHtml(r.riskNumber)} — ${escapeHtml(r.riskTitle)}`, true)
      : dd("Risk", `#${riskId}`, true);
    show("regStatusModal");
  }

  async function onRegStatusSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("rsMessage");
    msg.textContent = "";
    const riskId = Number(document.getElementById("rsRiskId").value);
    const status = val("rsStatus");
    const remark = val("rsRemark");
    if ((status === "Closed" || status === "Retired") && !remark) {
      msg.textContent = "A reason is required to close or retire a risk.";
      return;
    }
    const res = await apiPost(`/register/${riskId}/status`, { statusCode: status, remark: remark || null });
    if (!res || res.success === false) { msg.textContent = (res && res.error) || "Failed."; return; }
    hide("regStatusModal");
    await refreshRegister();
  }

  async function openRegOwnerModal(riskId) {
    if (!state.employees.length) await loadEmployees();
    const r = state.activeRisk && state.activeRisk.riskRegisterId === riskId ? state.activeRisk : null;
    document.getElementById("roRiskId").value = riskId;
    document.getElementById("roRemark").value = "";
    document.getElementById("roMessage").textContent = "";
    setVal("roOwner", r?.riskOwnerEmployeeId || "");
    document.getElementById("roMeta").innerHTML = r
      ? dd("Risk", `${escapeHtml(r.riskNumber)} — ${escapeHtml(r.riskTitle)}`, true)
      : dd("Risk", `#${riskId}`, true);
    show("regOwnerModal");
  }

  async function onRegOwnerSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("roMessage");
    msg.textContent = "";
    const riskId = Number(document.getElementById("roRiskId").value);
    const owner  = val("roOwner");
    if (!owner) { msg.textContent = "Risk owner is required."; return; }
    const res = await apiPost(`/register/${riskId}/owner`, {
      ownerEmployeeId: Number(owner), remark: val("roRemark") || null
    });
    if (!res || res.success === false) { msg.textContent = (res && res.error) || "Failed."; return; }
    hide("regOwnerModal");
    await refreshRegister();
  }

  // REMOVED FROM THE UI — the two-action candidate menu
  // --------------------------------------------------
  //   Clarify  (BRD §8C)  the analyst's "return for more information"
  //   Withdraw            the raiser cancelling their own candidate
  //   Duplicate search    the manual "find similar risks" entry point
  //
  // The API endpoints and stored procedures are untouched and still
  // enforce their rules — only the screen no longer offers them.
  //
  // §8C is not lost entirely: an approver returning a risk for further
  // assessment writes the same ClarificationRequired status through
  // sp_risk_analysis_approve, so the state is still reachable and still
  // renders.
  //
  // §15 duplicate detection is not lost either: it runs automatically
  // before every registration (see startRegister) and offers the same
  // "close as duplicate" action on each match. Only the manual search was
  // an extra door to the same room.

  // ---- Legacy accept -------------------------------------------------
  function renderAcceptMethodFields() {
    const m = document.getElementById("riskAcceptMethod").value;
    document.getElementById("riskAcceptFileWrap").hidden     = (m !== "Manual");
    document.getElementById("riskAcceptLocationWrap").hidden = (m !== "Automated");
    document.getElementById("riskAcceptLocatorWrap").hidden  = (m !== "Automated");
  }

  async function openAcceptModal(id) {
    const cand = await apiGet(`/${id}`);
    if (!cand) { dlg.alert("Candidate not found.", { type: "error" }); return; }
    state.activeCandidate = cand;
    document.getElementById("riskAcceptId").value = id;
    ["riskAcceptNote","riskAcceptFormalRef","riskAcceptFile","riskAcceptMethod",
     "riskAcceptLocation","riskAcceptLocator"].forEach(x => setVal(x, ""));
    document.getElementById("riskAcceptMessage").textContent = "";
    document.getElementById("riskAcceptMeta").innerHTML = metaOf(cand);
    renderAcceptMethodFields();
    show("riskAcceptModal");
  }

  async function onAcceptSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("riskAcceptMessage");
    msg.textContent = "";
    const id = Number(document.getElementById("riskAcceptId").value);
    const note = val("riskAcceptNote");
    if (!note) { msg.textContent = "Acceptance note is required."; return; }

    const result = await apiPost(`/${id}/accept`, {
      acceptanceNote: note,
      formalRiskRef:  val("riskAcceptFormalRef") || null
    });
    if (!result || result.success === false) {
      const err = (result && result.error) || "Accept failed.";
      msg.textContent = err; dlg.alert(err, { title: "Accept failed", type: "error" });
      return;
    }

    // Optional evidence-style attachment after accept succeeded.
    const method = document.getElementById("riskAcceptMethod").value;
    if (method) {
      const fd = new FormData();
      fd.append("CollectionMethodCode", method);
      if (method === "Manual") {
        const file = document.getElementById("riskAcceptFile").files?.[0];
        if (!file) { dlg.alert("Accepted, but a manual attachment needs a file. Upload skipped.", { type: "warning" }); }
        else       { fd.append("File", file, file.name); }
      } else if (method === "Automated") {
        const loc = val("riskAcceptLocation");
        const lct = val("riskAcceptLocator");
        if (!loc || !lct) {
          dlg.alert("Accepted, but an automated attachment needs Location and Locator. Upload skipped.", { type: "warning" });
        } else {
          fd.append("EvidenceLocation", loc);
          fd.append("EvidenceLocator",  lct);
        }
      }
      if ((method === "Manual" && fd.has("File")) ||
          (method === "Automated" && fd.has("EvidenceLocation"))) {
        try {
          const r = await fetch(U(`${base}/${id}/attachments`), {
            method: "POST", body: fd, credentials: "same-origin"
          });
          const b = await r.json().catch(() => ({}));
          if (!r.ok || b.success === false) {
            dlg.alert("Accepted, but the attachment upload failed: " + (b.error || `HTTP ${r.status}`), { type: "warning" });
          }
        } catch (err) {
          dlg.alert("Accepted, but the attachment upload failed: " + err.message, { type: "warning" });
        }
      }
    }
    hide("riskAcceptModal");
    dlg.alert("Risk candidate accepted.", { type: "success" });
    await refresh();
  }

  // ---- Reject / Withdraw ---------------------------------------------
  async function openRejectModal(id) {
    const cand = await apiGet(`/${id}`);
    if (!cand) { dlg.alert("Candidate not found.", { type: "error" }); return; }
    state.activeCandidate = cand;
    document.getElementById("riskRejectId").value = id;
    document.getElementById("riskRejectReason").value = "";
    document.getElementById("riskRejectMessage").textContent = "";
    document.getElementById("riskRejectMeta").innerHTML = metaOf(cand);
    show("riskRejectModal");
  }

  async function onRejectSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("riskRejectMessage");
    msg.textContent = "";
    const id = Number(document.getElementById("riskRejectId").value);
    const reason = val("riskRejectReason");
    if (!reason) { msg.textContent = "Rejection reason is required."; return; }
    const result = await apiPost(`/${id}/reject`, { rejectionReason: reason });
    if (!result || result.success === false) {
      msg.textContent = (result && result.error) || "Reject failed.";
      return;
    }
    hide("riskRejectModal");
    await refresh();
  }

  // ===================================================================
  // Phase B — migrations 212-215
  // ===================================================================

  // ---- 208: configuration (§19, §22) --------------------------------
  async function loadConfig() {
    state.config = null;
    if (!state.organizationId) return;
    state.config = await apiGet(`/config?organizationId=${state.organizationId}`);
  }

  async function openConfigModal() {
    if (!state.organizationId) { dlg.alert("Select an organization first.", { type: "warning" }); return; }
    if (!state.options) await loadOptions();
    await loadConfig();
    const c = state.config;
    if (!c) { dlg.alert("Settings unavailable.", { type: "error" }); return; }

    // Threshold options come from the org's OWN matrix, deduplicated and
    // ordered by score, so a framework using colour bands or 1-4 offers
    // its own words rather than a hardcoded Low/Medium/High/Critical.
    const ratings = [];
    (state.options?.matrix || []).forEach(cell => {
      if (!ratings.some(x => x.code === cell.ratingCode))
        ratings.push({ code: cell.ratingCode, name: cell.ratingName, score: cell.ratingScore ?? 0 });
    });
    ratings.sort((a, b) => a.score - b.score);
    const minSel = document.getElementById("cfgMinRating");
    minSel.innerHTML = `<option value="">Every risk</option>`;
    ratings.forEach(x => {
      const o = document.createElement("option");
      o.value = x.code; o.textContent = x.name;
      minSel.appendChild(o);
    });
    minSel.value = c.approvalMinRatingCode || "";

    await loadRoles();
    const roleSel = document.getElementById("cfgApproverRole");
    roleSel.innerHTML = `<option value="">Any authorised user</option>`;
    state.roles.forEach(r => {
      const o = document.createElement("option");
      o.value = r.roleId; o.textContent = r.roleName;
      roleSel.appendChild(o);
    });
    roleSel.value = c.approverRoleId || "";

    check("cfgApprovalRequired",   c.approvalRequired);
    check("cfgDefaultTreatment",   c.defaultRaiseTreatmentTask);
    check("cfgNotifications",      c.notificationsEnabled);
    check("cfgAllowLegacyAccept",  c.allowLegacyAccept);
    setVal("cfgNotes", c.notes || "");
    document.getElementById("cfgMessage").textContent = "";

    // §21 matrix, read-only here: adding a role to an event is an admin
    // action against org_risk_config_notify_role, and inventing a second
    // editing surface for it would be a second source of truth.
    const events = [
      ["CANDIDATE_ASSIGNED",      "New candidate assigned for assessment"],
      ["CLARIFICATION_REQUESTED", "Clarification requested"],
      ["ANALYSIS_COMPLETED",      "Assessment completed"],
      ["APPROVAL_REQUIRED",       "Approval required"],
      ["RISK_APPROVED",           "Risk approved for registration"],
      ["CANDIDATE_REJECTED",      "Candidate rejected"],
      ["RISK_OWNER_ASSIGNED",     "Risk owner assignment"],
      ["RISK_REGISTERED",         "Risk registered"]
    ];
    document.getElementById("cfgNotifyBody").innerHTML = events.map(([code, label]) => {
      const roles = (c.notifyRoles || []).filter(r => r.notifyEventCode === code);
      return `<tr><td>${escapeHtml(label)}</td><td>${
        roles.length
          ? roles.map(r => `<span class="risk-source-chip">${escapeHtml(r.roleName || `#${r.roleId}`)}</span>`).join(" ")
          : `<span class="pm-hint">participants only</span>`}</td></tr>`;
    }).join("");

    show("riskConfigModal");
  }

  async function loadRoles() {
    if (state.roles.length || !state.organizationId) return;
    try {
      const r = await fetch(U(`/practice/api/roles?organizationId=${state.organizationId}`),
        { credentials: "same-origin" });
      if (r.ok) {
        const b = await r.json();
        const rows = Array.isArray(b) ? b : (b?.data || b?.Data || []);
        state.roles = rows.map(x => ({
          roleId:   x.roleId   ?? x.RoleId,
          roleName: x.roleName ?? x.RoleName
        })).filter(x => x.roleId);
      }
    } catch (_) { state.roles = []; }
  }

  async function onConfigSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("cfgMessage");
    msg.textContent = "";
    const minRating = val("cfgMinRating");
    const roleId    = val("cfgApproverRole");
    const result = await apiPost(`/config?organizationId=${state.organizationId}`, {
      approvalRequired:         isChecked("cfgApprovalRequired"),
      approvalMinRatingCode:    minRating || null,
      approverRoleId:           roleId ? Number(roleId) : null,
      defaultRaiseTreatmentTask: isChecked("cfgDefaultTreatment"),
      allowLegacyAccept:        isChecked("cfgAllowLegacyAccept"),
      notificationsEnabled:     isChecked("cfgNotifications"),
      notes:                    val("cfgNotes") || null,
      // Empty select = "un-set it", which is a different instruction from
      // "leave it alone" — see sp_risk_config_save.
      clearMinRating:           !minRating,
      clearApproverRole:        !roleId
    });
    if (!result || result.success === false) {
      msg.textContent = (result && result.error) || "Save failed.";
      return;
    }
    await loadConfig();
    hide("riskConfigModal");
    await refresh();
  }

  // ---- 208: approval workflow (§19) ---------------------------------
  async function submitForApproval(id) {
    const remark = await dlg.prompt("The approver will see this alongside the assessment. Optional.", {
      title: "Submit for approval", inputLabel: "Remark", confirmText: "Submit" });
    if (remark === null) return;
    const res = await apiPost(`/${id}/submit-approval`, { remark: remark || null });
    if (!res || res.success === false) {
      dlg.alert((res && res.error) || "Submit failed.", { title: "Submit failed", type: "error" });
      return;
    }
    await refresh();
    if (state.tab === "dashboard") await refreshDashboard();
  }

  async function openApprovalModal(id) {
    const cand     = await apiGet(`/${id}`);
    const analysis = await apiGet(`/${id}/analysis`);
    if (!cand || !analysis) { dlg.alert("Candidate or assessment not found.", { type: "error" }); return; }
    document.getElementById("apCandidateId").value = id;
    document.getElementById("apRemark").value = "";
    document.getElementById("apMessage").textContent = "";
    document.getElementById("apMeta").innerHTML =
      dd("Candidate", `${escapeHtml(cand.candidateTitle)}
          <span class="pm-hint">${escapeHtml(cand.candidateNumber || "")}</span>`, true) +
      dd("Statement", analysis.riskStatement) +
      dd("Category",  analysis.riskCategoryName) +
      dd("Rating", severityChip(analysis.inherentRatingCode) +
          ` <span class="pm-hint">${escapeHtml(analysis.likelihoodName || "?")} x ${escapeHtml(analysis.impactName || "?")}</span>`, true) +
      dd("Owner",     analysis.riskOwnerName) +
      dd("Assessed",  `v${analysis.analysisVersion} on ${new Date(analysis.analysisOn).toLocaleString()} by ${escapeHtml(analysis.analysedByName || "—")}`, true) +
      dd("Controls",  analysis.existingControls) +
      dd("Remarks",   analysis.analystRemarks);
    show("riskApprovalModal");
  }

  async function onApprovalDecision(ev, decision) {
    if (ev) ev.preventDefault();
    const msg = document.getElementById("apMessage");
    msg.textContent = "";
    const id = Number(document.getElementById("apCandidateId").value);
    const remark = val("apRemark");
    if (decision === "Return" && !remark) {
      msg.textContent = "A reason is required when returning a risk for further assessment.";
      return;
    }
    const res = await apiPost(`/${id}/approve`, { decision, remark: remark || null });
    if (!res || res.success === false) {
      msg.textContent = (res && res.error) || "Failed.";
      return;
    }
    hide("riskApprovalModal");
    await refresh();
    if (state.tab === "dashboard") await refreshDashboard();
  }

  // ---- 210: dashboard (§23) -----------------------------------------
  async function refreshDashboard() {
    if (!state.organizationId) return;
    const months = Number(val("dashTrendMonths")) || 12;
    const d = await apiGet(`/dashboard?organizationId=${state.organizationId}&trendMonths=${months}`);
    if (!d) return;

    const c = d.candidates || {};
    document.getElementById("dashCandidateTiles").innerHTML =
      tile(c.totalCandidates, "Total candidates") +
      tile(c.openCandidates, "Open", null, "Pending") +
      tile(c.newCandidates, "New", null, "Pending") +
      tile(c.underAnalysisCount, "Under assessment", null, "UnderAnalysis") +
      tile(c.awaitingClarificationCount, "Awaiting clarification", null, "ClarificationRequired") +
      tile(c.awaitingApprovalCount, "Awaiting approval", c.awaitingApprovalCount > 0) +
      tile(c.convertedToRiskCount, "Converted to risks", null, "Registered") +
      tile(c.rejectedCount, "Rejected", null, "Rejected") +
      tile(c.closedAsDuplicateCount, "Closed as duplicate", null, "ClosedAsDuplicate") +
      tile(fmtDays(c.avgOpenAgeDays), "Avg open age") +
      tile(fmtDays(c.maxOpenAgeDays), "Oldest open", (c.maxOpenAgeDays || 0) > 90) +
      (c.legacyAcceptedCount ? tile(c.legacyAcceptedCount, "Legacy accepted", true, "Accepted") : "");

    const r = d.register || {};
    document.getElementById("dashRegisterTiles").innerHTML =
      tile(r.totalRisks, "Total risks") +
      tile(r.activeCount, "Active") +
      tile(r.underTreatmentCount, "Under treatment") +
      tile(r.acceptedCount, "Accepted") +
      tile(r.monitoringCount, "Monitoring") +
      tile(r.closedCount, "Closed") +
      tile(r.retiredCount, "Retired") +
      tile(r.elevatedRatingCount, "Elevated rating", (r.elevatedRatingCount || 0) > 0) +
      tile(r.customRiskCount, "Custom risks") +
      tile(r.unownedCount, "No owner", (r.unownedCount || 0) > 0) +
      tile(r.avgInherentScore != null ? r.avgInherentScore.toFixed(1) : "—", "Avg inherent score");

    bars("dashByRating",     d.risksByRating,        "register", "ratingCode");
    bars("dashByCategory",   d.risksByCategory,      "register", "categoryCode");
    bars("dashBySource",     d.risksBySource,        "register", "sourceTypeCode");
    bars("dashByUnit",       d.risksByBusinessUnit,  null, null);
    bars("dashByOwner",      d.risksByOwner,         null, null);
    bars("dashCandBySource", d.candidatesBySource,   "candidates", "sourceTypeCode");

    const maxBand = Math.max(1, ...(d.candidateAgeing || []).map(b => b.candidateCount));
    document.getElementById("dashAgeing").innerHTML = (d.candidateAgeing || []).map(b =>
      `<div class="risk-bar-row"><span class="lbl">${escapeHtml(b.bandName)}</span>
         <span class="trk"><span class="fil" style="width:${Math.round(b.candidateCount / maxBand * 100)}%"></span></span>
         <span class="num">${b.candidateCount}</span></div>`).join("");

    document.getElementById("trendTableBody").innerHTML = (d.trend || []).map(t => {
      const net = (t.registeredCount || 0) - (t.closedCount || 0);
      return `<tr>
        <td>${new Date(t.monthStart).toLocaleDateString(undefined, { year: "numeric", month: "short" })}</td>
        <td>${t.candidatesRaisedCount || 0}</td>
        <td>${t.registeredCount || 0}</td>
        <td>${t.closedCount || 0}</td>
        <td style="color:${net > 0 ? "#c53030" : net < 0 ? "#2f855a" : "#4a5568"}">${net > 0 ? "+" : ""}${net}</td>
      </tr>`;
    }).join("") || `<tr><td colspan="5" class="pm-empty-row">No activity.</td></tr>`;

    const overdue = d.overdueActions || [];
    document.getElementById("overdueTableBody").innerHTML = overdue.length
      ? overdue.map(t => `<tr>
          <td>${escapeHtml(t.taskNumber || `#${t.taskId}`)}</td>
          <td>${escapeHtml(t.taskTitle || "")}</td>
          <td>${escapeHtml(t.ownerName || "—")}</td>
          <td>${escapeHtml(t.priority || "—")}</td>
          <td>${t.dueAt ? new Date(t.dueAt).toLocaleDateString() : "—"}</td>
          <td>${statusChip(t.slaStatusCode)}</td>
        </tr>`).join("")
      : `<tr><td colspan="6" class="pm-empty-row">No overdue risk actions.</td></tr>`;

    await Promise.all([refreshApprovalQueue(), refreshAgeing(), refreshNotifications()]);
  }

  function tile(value, label, alert, drillStatus) {
    const cls = `risk-tile${alert ? " is-alert" : ""}${drillStatus ? " is-clickable" : ""}`;
    const attr = drillStatus ? ` data-drill-candidate-status="${escapeHtml(drillStatus)}"` : "";
    return `<div class="${cls}"${attr}>
      <div class="v">${escapeHtml(String(value ?? 0))}</div>
      <div class="k">${escapeHtml(label)}</div></div>`;
  }
  function fmtDays(n) { return n == null ? "—" : `${Math.round(n)}d`; }

  // Drill-down is a filter change on a grid the user already understands,
  // not a second screen — see 210's header note.
  function bars(hostId, rows, drillTab, drillField) {
    const host = document.getElementById(hostId);
    if (!host) return;
    const list = rows || [];
    if (!list.length) { host.innerHTML = `<p class="pm-hint">No data.</p>`; return; }
    const max = Math.max(1, ...list.map(x => x.totalCount));
    host.innerHTML = list.slice(0, 10).map(x => {
      const clickable = drillTab && drillField && x.key;
      return `<div class="risk-bar-row${clickable ? " is-clickable" : ""}"${
        clickable ? ` data-drill-tab="${drillTab}" data-drill-field="${escapeHtml(drillField)}" data-drill-value="${escapeHtml(x.key)}"` : ""}>
        <span class="lbl" title="${escapeHtml(x.label)}">${escapeHtml(x.label)}</span>
        <span class="trk"><span class="fil" style="width:${Math.round(x.totalCount / max * 100)}%${
          x.colourHex ? `;background:${escapeHtml(x.colourHex)}` : ""}"></span></span>
        <span class="num">${x.totalCount}</span></div>`;
    }).join("");
  }

  async function refreshApprovalQueue() {
    const tbody = document.getElementById("approvalTableBody");
    const data = await apiGet(`/approval-queue?organizationId=${state.organizationId}`);
    const rows = data?.rows || [];
    if (!rows.length) {
      tbody.innerHTML = `<tr><td colspan="8" class="pm-empty-row">Nothing awaiting approval.</td></tr>`;
      return;
    }
    tbody.innerHTML = rows.map(a => `<tr>
      <td>${escapeHtml(a.candidateTitle)}<br><span class="pm-hint">${escapeHtml(a.candidateNumber || "")}</span></td>
      <td>${escapeHtml(a.riskStatement)}</td>
      <td>${escapeHtml(a.riskCategoryName || "—")}</td>
      <td>${severityChip(a.inherentRatingCode)}</td>
      <td>${escapeHtml(a.riskOwnerName || "—")}</td>
      <td>${new Date(a.analysisOn).toLocaleDateString()}<br>
          <span class="pm-hint">${escapeHtml(a.analysedByName || "—")}</span></td>
      <td>${a.daysWaiting}d</td>
      <td><button type="button" class="pm-button" data-approve="${a.riskCandidateId}">
            <i class="fa-solid fa-gavel"></i> Review</button></td>
    </tr>`).join("");
  }

  async function refreshAgeing() {
    const tbody = document.getElementById("ageingTableBody");
    const data = await apiGet(`/ageing?organizationId=${state.organizationId}&pageSize=10`);
    const rows = data?.rows || [];
    tbody.innerHTML = rows.length
      ? rows.map(a => `<tr>
          <td><a href="#" data-open-candidate="${a.riskCandidateId}">${escapeHtml(a.candidateNumber || a.candidateTitle)}</a><br>
              <span class="pm-hint">${escapeHtml(a.candidateTitle)}</span></td>
          <td><span class="risk-source-chip">${escapeHtml(a.sourceTypeCode || "—")}</span></td>
          <td>${statusChip(a.statusCode)}</td>
          <td>${escapeHtml(a.assignedAnalystName || "—")}</td>
          <td${a.ageDays > 90 ? ' style="color:#c53030;font-weight:600"' : ""}>${a.ageDays}d</td>
        </tr>`).join("")
      : `<tr><td colspan="5" class="pm-empty-row">No open candidates.</td></tr>`;
  }

  // ---- 209: notifications (§21) -------------------------------------
  async function refreshNotifications() {
    if (!state.organizationId) return;
    const counts = await apiGet(`/notifications/counts?organizationId=${state.organizationId}`);
    document.getElementById("notifCounts").textContent = counts
      ? `${counts.pendingCount} pending · ${counts.sentCount} sent · ${counts.failedCount} failed · ${counts.suppressedCount} suppressed`
      : "";

    const status = val("notifFilterStatus");
    const qs = new URLSearchParams({ organizationId: state.organizationId, pageSize: 25 });
    if (status) qs.set("statusCode", status);
    const data = await apiGet(`/notifications?${qs}`);
    const rows = data?.rows || [];
    document.getElementById("notifTableBody").innerHTML = rows.length
      ? rows.map(n => `<tr>
          <td>${escapeHtml(eventLabel(n.notifyEventCode))}</td>
          <td>${escapeHtml(n.subjectNumber || `#${n.subjectRecordId}`)}<br>
              <span class="pm-hint">${escapeHtml(n.subjectTitle || "")}</span></td>
          <td>${escapeHtml(n.recipientName || "—")}<br>
              <span class="pm-hint">${escapeHtml(n.recipientEmail || "no email on file")}</span></td>
          <td>${escapeHtml(n.roleName || n.recipientReasonCode)}</td>
          <td>${statusChip(n.statusCode)}${
            n.failureReason ? `<br><span class="pm-hint">${escapeHtml(n.failureReason)}</span>` : ""}</td>
          <td>${new Date(n.eventOn).toLocaleString()}</td>
        </tr>`).join("")
      : `<tr><td colspan="6" class="pm-empty-row">No notifications recorded.</td></tr>`;
  }

  function eventLabel(code) {
    return ({
      CANDIDATE_ASSIGNED:      "Candidate assigned",
      CLARIFICATION_REQUESTED: "Clarification requested",
      ANALYSIS_COMPLETED:      "Assessment completed",
      APPROVAL_REQUIRED:       "Approval required",
      RISK_APPROVED:           "Risk approved",
      CANDIDATE_REJECTED:      "Candidate rejected",
      RISK_OWNER_ASSIGNED:     "Risk owner assigned",
      RISK_REGISTERED:         "Risk registered"
    })[code] || code;
  }

  async function onNotificationSweep() {
    const btn = document.getElementById("notifSweepBtn");
    btn.disabled = true;
    try {
      const res = await apiPost(`/notifications/sweep?organizationId=${state.organizationId}`, {});
      if (!res || res.success === false) {
        dlg.alert((res && res.error) || "Sweep failed.", { title: "Sweep failed", type: "error" });
        return;
      }
      await refreshNotifications();
    } finally { btn.disabled = false; }
  }

  // ---- 211: treatment task (§22) ------------------------------------
  async function openTreatmentModal(riskId) {
    const risk = await apiGet(`/register/${riskId}`);
    if (!risk) { dlg.alert("Risk not found.", { type: "error" }); return; }
    if (!state.employees.length) await loadEmployees();
    if (!state.config) await loadConfig();

    document.getElementById("trRiskId").value = riskId;
    document.getElementById("trMeta").innerHTML =
      dd("Risk", `${escapeHtml(risk.riskNumber)} — ${escapeHtml(risk.riskTitle)}`, true) +
      dd("Rating", severityChip(risk.inherentRatingCode), true) +
      dd("Owner", risk.riskOwnerName) +
      dd("Status", statusChip(risk.statusCode), true);
    ["trTitle", "trDescription"].forEach(id => setVal(id, ""));
    setVal("trPriority", "");
    setVal("trOwner", risk.riskOwnerEmployeeId || "");
    check("trAllowAdditional", false);
    document.getElementById("trMessage").textContent = "";

    const owner = document.getElementById("trOwner");
    owner.innerHTML = `<option value="">Task Centre's owner ladder</option>`;
    state.employees.forEach(e => {
      const o = document.createElement("option");
      o.value = e.employeeId;
      o.textContent = e.employeeName + (e.employeeCode ? ` (${e.employeeCode})` : "");
      owner.appendChild(o);
    });
    owner.value = risk.riskOwnerEmployeeId || "";

    await refreshTreatmentWork(riskId);
    show("riskTreatmentModal");
  }

  async function refreshTreatmentWork(riskId) {
    const rows = await apiGet(`/register/${riskId}/treatment-tasks`) || [];
    document.getElementById("trWorkBody").innerHTML = rows.length
      ? rows.map(w => `<tr>
          <td>${escapeHtml(w.itemKind || "")}</td>
          <td>${escapeHtml(w.itemNumber || "")}</td>
          <td>${escapeHtml(w.title || "")}</td>
          <td>${escapeHtml(w.ownerName || "—")}</td>
          <td>${escapeHtml(w.statusName || w.statusCode || "—")}</td>
          <td>${w.dueAt ? new Date(w.dueAt).toLocaleDateString() : "—"}</td>
        </tr>`).join("")
      : `<tr><td colspan="6" class="pm-empty-row">No treatment work raised yet.</td></tr>`;
    // Ticking "additional" is only meaningful once something exists.
    check("trAllowAdditional", rows.length > 0 && !!state.config?.defaultRaiseTreatmentTask);
  }

  async function onTreatmentSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("trMessage");
    msg.textContent = "";
    const riskId = Number(document.getElementById("trRiskId").value);
    const ownerId = val("trOwner");
    const res = await apiPost(`/register/${riskId}/treatment-task`, {
      taskTitle:       val("trTitle") || null,
      taskDescription: val("trDescription") || null,
      proposedPriority: val("trPriority") || null,
      ownerEmployeeId: ownerId ? Number(ownerId) : null,
      allowAdditional: isChecked("trAllowAdditional")
    });
    if (!res || res.success === false) {
      msg.textContent = (res && res.error) || "Failed.";
      return;
    }
    msg.textContent = res.created
      ? `Task candidate raised at priority ${res.proposedPriority}.`
      : "A treatment task candidate already exists for this risk — tick “additional action” to raise another.";
    await refreshTreatmentWork(riskId);
  }

  // ---- dialogs -------------------------------------------------------
  // The app has its own dialog component (grac-dialog.js, loaded in
  // _Layout) and it is what every other screen uses. The native
  // prompt()/confirm() boxes cannot be styled at all, so anything that
  // used them looked like a different application.
  //
  // grac-dialog overrides window.alert but CANNOT override confirm() or
  // prompt() — those are synchronous and the styled versions return
  // promises. So the calls have to be awaited, which is why these
  // wrappers exist rather than a global shim.
  //
  // Each falls back to the native dialog if the global is missing, the
  // same guard exception-centre.js uses: a missing script should degrade
  // the look, never break the screen.
  const dlg = {
    alert: (message, opts = {}) =>
      (window.gracAlert || (m => window.alert(m.message ?? m)))({
        type: opts.type || "info", title: opts.title, message
      }),
    confirm: (message, opts = {}) =>
      (window.gracConfirm || (m => Promise.resolve(window.confirm(m.message ?? m))))({
        type: opts.type || "confirm", title: opts.title, message,
        confirmText: opts.confirmText, cancelText: opts.cancelText
      }),
    // Resolves to the typed string, or null when cancelled — same
    // contract as window.prompt, so call sites read unchanged.
    prompt: (message, opts = {}) =>
      (window.gracPrompt || (m => Promise.resolve(window.prompt(m.message ?? m, m.defaultValue || ""))))({
        type: opts.type || "info", title: opts.title, message,
        defaultValue: opts.defaultValue || "",
        inputLabel: opts.inputLabel, confirmText: opts.confirmText
      })
  };

  // ---- helpers -------------------------------------------------------
  function check(id, on) { const el = document.getElementById(id); if (el) el.checked = !!on; }
  function isChecked(id) { const el = document.getElementById(id); return !!(el && el.checked); }

  function metaOf(c) {
    return dd("Candidate", `${escapeHtml(c.candidateTitle || "")}
              <span class="pm-hint">${escapeHtml(c.candidateNumber || "")}</span>`, true) +
           dd("Source", `<span class="risk-source-chip">${escapeHtml(c.sourceName || c.sourceTypeCode || "--")}</span>
              ${c.sourceReference ? ` ${escapeHtml(c.sourceReference)}` : ""}`, true) +
           dd("Status", statusChip(c.statusCode), true) +
           dd("Summary", c.candidateSummary) +
           dd("Source observation", c.sourceDescription) +
           dd("Intake severity", c.severityCode) +
           dd("Analyst", c.assignedAnalystName) +
           dd("Business unit", c.businessUnit) +
           dd("Clarification", c.clarificationNote) +
           dd("Registered risk", c.registeredRiskNumber) +
           dd("Duplicate of", c.duplicateOfRiskNumber) +
           dd("Identified", c.identifiedOn
                ? `${new Date(c.identifiedOn).toLocaleString()} by ${escapeHtml(c.requestedByName || "system")}`
                : null, true);
  }
  // Renders one <dt>/<dd> pair, or nothing when the value is empty —
  // so a candidate from a source with little context does not display a
  // wall of "--".
  function dd(label, value, isHtml) {
    if (value == null || value === "") return "";
    return `<dt>${escapeHtml(label)}</dt><dd>${isHtml ? value : escapeHtml(value)}</dd>`;
  }

  function val(id)          { const el = document.getElementById(id); return el ? String(el.value || "").trim() : ""; }
  function setVal(id, v)    { const el = document.getElementById(id); if (el) el.value = v ?? ""; }
  function show(id) { document.getElementById(id).hidden = false; }
  function hide(id) { document.getElementById(id).hidden = true; }
  function escapeHtml(s) {
    if (s == null) return "";
    return String(s).replace(/[&<>"']/g, ch => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[ch]));
  }

  async function apiGet(path) {
    const url = U(`${base}${path.startsWith("/") || path.startsWith("?") ? path : "/" + path}`);
    try {
      const r = await fetch(url, { credentials: "same-origin" });
      if (r.status === 404) return null;
      if (!r.ok) { console.warn("risk GET", url, r.status); return null; }
      return await r.json();
    } catch (err) { console.error("risk GET failed", url, err); return null; }
  }
  async function apiPost(path, body) {
    const url = U(`${base}${path.startsWith("/") ? path : "/" + path}`);
    try {
      const r = await fetch(url, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) return { success: false, error: data.error || `HTTP ${r.status}` };
      // Array responses (duplicate-check) are returned as-is; object
      // responses get the success flag the callers expect.
      if (Array.isArray(data)) return data;
      return { success: data.success !== false, ...data };
    } catch (err) { return { success: false, error: err.message }; }
  }
})();
