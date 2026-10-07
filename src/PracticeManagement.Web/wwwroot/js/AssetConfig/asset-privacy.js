// =====================================================================
// Asset Privacy (migration 448) -- BRD 5.1.10, 5.1.16, 5.1.17, 5.2.15,
// 9.1.7. Loaded by asset-privacy.cshtml. Services: privacy/requirements
// (settings, overrides, asset types, employees), privacy/assets,
// privacy/assets/{id}, privacy/exceptions (list, request),
// privacy/exceptions/{id}/action, privacy/reviews,
// privacy/reviews/{id}/complete, privacy/run. Opened with
// ?organizationId=&assetId= (Asset Register, Privacy tab) it shows that
// asset. The procedures hold every rule (gaps, status, approval,
// segregation of duties, review outcomes); this screen shows them.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/privacy";
  const root = document.getElementById("apvRoot");
  if (!root) return;
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";

  const STATUS = { NON_COMPLIANT: ["Non-compliant", "apv-st-bad"], INCOMPLETE: ["Incomplete", "apv-st-wait"], UNDETERMINED: ["Undetermined", "apv-st-wait"],
                   CONDITIONAL: ["Conditional", "apv-st-info"], COMPLIANT: ["Compliant", "apv-st-ok"], NOT_APPLICABLE: ["Not applicable", "apv-st-off"] };
  const GAP = { FAILED: ["Failed", "apv-st-bad"], MISSING: ["Missing", "apv-st-wait"], PARTIAL: ["Partial", "apv-st-info"] };
  const ENF = { OFF: "Off", WARN: "Warn", BLOCK: "Block" };
  const EXC = { PENDING_APPROVAL: ["Awaiting approval", "apv-st-wait"], APPROVED: ["Approved", "apv-st-ok"], REJECTED: ["Rejected", "apv-st-bad"],
                WITHDRAWN: ["Withdrawn", "apv-st-off"], REVOKED: ["Revoked", "apv-st-bad"], EXPIRED: ["Expired", "apv-st-off"] };
  const REV = { OPEN: ["Open", "apv-st-info"], COMPLETED: ["Completed", "apv-st-ok"], CANCELLED: ["Cancelled", "apv-st-off"] };
  const KIND = { PRIVACY: "Privacy / DPIA review", RETENTION: "Retention end" };
  const OUTCOME = { REVIEWED: "Reviewed", DELETE: "Data deleted", ARCHIVE: "Data archived", LEGAL_HOLD: "Legal hold verified", EXTEND: "Retention extended" };
  const ASSESS = { NOT_ASSESSED: "Not assessed", PENDING: "Pending", APPROVED: "Approved", CONDITIONAL: "Conditional", NON_COMPLIANT: "Non-compliant" };

  const state = { organizationId: null, config: null, aPager: null, xPager: null, rPager: null, mainTab: "ASSETS",
                  assetId: null, detail: null, exceptions: [], reviews: [], excGap: null, review: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    const g = window.__pmGrid;
    state.aPager = g ? g.attach({ hostId: "apvAPager", onChange: refreshAssets }) : null;
    state.xPager = g ? g.attach({ hostId: "apvXPager", onChange: refreshExceptions }) : null;
    state.rPager = g ? g.attach({ hostId: "apvRPager", onChange: refreshReviews }) : null;
    bind();
    await populateOrgs();
    const params = new URLSearchParams(window.location.search);
    const sel = document.getElementById("apvOrg");
    const orgParam = params.get("organizationId");
    if (orgParam && [...sel.options].some(o => o.value === orgParam)) sel.value = orgParam;
    else window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    // 451: opened from the Asset & Contract dashboard -- organization, tab and filter (Shared/dashboard-drill.js).
    const dashDrill = window.__pmDrill ? window.__pmDrill.read() : null;
    window.__pmDrill?.preselectFor(dashDrill, sel, { "": { status: "apvAStatus" }, ASSETS: { status: "apvAStatus" } });
    await changeOrg(Number(sel.value) || null);
    window.__pmDrill?.showOnPage("apvRoot", "data-apv-main", dashDrill);
    const assetParam = Number(params.get("assetId"));
    if (assetParam && state.organizationId) await openDetail(assetParam);
  }

  async function populateOrgs() {
    const sel = document.getElementById("apvOrg");
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
    document.getElementById("apvOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.querySelectorAll("[data-apv-main]").forEach(b => b.addEventListener("click", () => selectMainTab(b.dataset.apvMain)));
    document.querySelectorAll("[data-close-apv]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeApv).hidden = true; }));
    document.getElementById("apvRun")?.addEventListener("click", runSync);
    // assets
    document.getElementById("apvAStatus").addEventListener("change", () => { state.aPager?.reset(true); refreshAssets(); });
    let t = null;
    document.getElementById("apvASearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => { state.aPager?.reset(true); refreshAssets(); }, 300); });
    document.getElementById("apvABody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-apv-asset]");
      if (b) openDetail(Number(b.dataset.apvAsset));
    });
    document.getElementById("apvDClose").addEventListener("click", () => { document.getElementById("apvDetail").hidden = true; state.assetId = null; });
    document.getElementById("apvDGaps").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-apv-exc-req]");
      if (b) openExceptionRequest(b.dataset.apvExcReq);
    });
    document.getElementById("apvDExceptions").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-apv-x]");
      if (b) exceptionAction(Number(b.dataset.apvX), b.dataset.apvXAct, "detail");
    });
    document.getElementById("apvDReviews").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-apv-rev]");
      if (b) openReview(Number(b.dataset.apvRev), "detail");
    });
    document.getElementById("apvExcForm").addEventListener("submit", ev => { ev.preventDefault(); submitExceptionRequest(); });
    // exceptions
    document.getElementById("apvXStatus").addEventListener("change", () => { state.xPager?.reset(true); refreshExceptions(); });
    document.getElementById("apvXBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-apv-x]");
      if (b) { exceptionAction(Number(b.dataset.apvX), b.dataset.apvXAct, "list"); return; }
      const a = ev.target.closest("button[data-apv-asset]");
      if (a) openAssetFromList(Number(a.dataset.apvAsset));
    });
    // reviews
    ["apvRStatus", "apvRKind"].forEach(id => document.getElementById(id).addEventListener("change", () => { state.rPager?.reset(true); refreshReviews(); }));
    document.getElementById("apvRBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-apv-rev]");
      if (b) { openReview(Number(b.dataset.apvRev), "list"); return; }
      const a = ev.target.closest("button[data-apv-asset]");
      if (a) openAssetFromList(Number(a.dataset.apvAsset));
    });
    document.getElementById("apvRevOutcome").addEventListener("change", reviewOutcomeHints);
    document.getElementById("apvRevForm").addEventListener("submit", ev => { ev.preventDefault(); submitReview(); });
    // requirements
    document.getElementById("apvQBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-apv-q-save]");
      if (b) saveOrgSetting(b.dataset.apvQSave);
    });
    document.getElementById("apvOAdd")?.addEventListener("click", saveOverride);
    document.getElementById("apvOBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-apv-o-remove]");
      if (b) removeOverride(Number(b.dataset.apvOType), b.dataset.apvORemove);
    });
  }

  async function changeOrg(id) {
    state.organizationId = id;
    state.config = null;
    state.assetId = null;
    document.getElementById("apvDetail").hidden = true;
    hideMessage();
    [state.aPager, state.xPager, state.rPager].forEach(p => p?.reset(true));
    if (id) await loadConfig();
    await selectMainTab(state.mainTab);
  }

  async function loadConfig() {
    const res = await api("GET", `/requirements?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.config = res.data.data || { requirements: [], overrides: [], assetTypes: [], employees: [] };
  }

  async function selectMainTab(name) {
    state.mainTab = name;
    document.querySelectorAll("[data-apv-main]").forEach(x => { const on = x.dataset.apvMain === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-apv-mainpanel]").forEach(p => { p.hidden = p.dataset.apvMainpanel !== name; });
    if (name === "ASSETS") await refreshAssets();
    else if (name === "EXCEPTIONS") await refreshExceptions();
    else if (name === "REVIEWS") await refreshReviews();
    else renderRequirements();
  }

  async function runSync() {
    if (!state.organizationId) return;
    const res = await api("POST", "/run", { organizationId: state.organizationId, assetId: null });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await selectMainTab(state.mainTab);
    showMessage(`Refreshed: ${res.data.result}.`, "success");
  }

  // ------------------------------------------------------------------ assets
  async function refreshAssets() {
    const body = document.getElementById("apvABody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.aPager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.aPager ? state.aPager.page() : 1, pageSize: state.aPager ? state.aPager.size() : 25 });
    if (val("apvAStatus")) qs.set("status", val("apvAStatus"));
    if (val("apvASearch")) qs.set("search", val("apvASearch"));
    const res = await api("GET", `/assets?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.aPager?.clear(); return; }
    const d = res.data.data || {}, rows = d.rows || [];
    state.aPager?.setTotal(d.totalRows, rows.length);
    const count = code => ((d.counts || []).find(c => c.privacyStatus === code) || {}).assetCount || 0;
    document.getElementById("apvACounts").textContent = Object.keys(STATUS).map(k => `${STATUS[k][0]} ${count(k)}`).join(" - ");
    body.innerHTML = rows.map(a => `
      <tr><td><button class="pm-link-button" type="button" data-apv-asset="${esc(a.assetId)}">${esc(a.assetName)}</button>
              <div class="apv-note">#${esc(a.assetId)} ${esc(label(a.statusCode))}</div></td>
          <td>${chip(STATUS, a.privacyStatus)}</td>
          <td>${gapsText(a)}</td>
          <td>${esc(a.privacyOwnerName || "--")}</td><td>${esc(ASSESS[a.assessmentStatus] || a.assessmentStatus || "--")}</td>
          <td>${esc(date(a.privacyReviewDate) || "--")}</td>
          <td>${esc(date(a.retentionDueDate) || "--")}${a.legalHold && String(a.legalHold).toUpperCase() === "YES" ? `<div class="apv-note">legal hold</div>` : ""}</td>
          <td>${esc(a.openReviews)} review(s)${Number(a.pendingExceptions) ? `<div class="apv-note">${esc(a.pendingExceptions)} exception(s) awaiting approval</div>` : ""}</td></tr>`).join("")
      || empty(8, "No asset in this view.");
  }

  function gapsText(a) {
    const parts = [];
    if (Number(a.failed)) parts.push(`${a.failed} failed`);
    if (Number(a.missing)) parts.push(`${a.missing} missing`);
    if (Number(a.partial)) parts.push(`${a.partial} partial`);
    if (Number(a.excepted)) parts.push(`${a.excepted} excepted`);
    return esc(parts.join(", ") || "--") + (Number(a.blocking) ? `<div class="apv-note">${esc(a.blocking)} blocking</div>` : "");
  }

  async function openAssetFromList(assetId) {
    await selectMainTab("ASSETS");
    await openDetail(assetId);
  }

  async function openDetail(assetId) {
    const res = await api("GET", `/assets/${assetId}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.assetId = assetId;
    state.detail = res.data.data || {};
    renderDetail();
    const panel = document.getElementById("apvDetail");
    panel.hidden = false;
    panel.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function renderDetail() {
    const d = state.detail || {}, s = d.status || {};
    document.getElementById("apvDTitle").textContent = `${s.assetName || ""} (#${s.assetId || ""})`;
    document.getElementById("apvDInfo").innerHTML = `
      <div><span>Privacy status</span>${chip(STATUS, s.privacyStatus)}</div>
      <div><span>Personal data processed</span>${esc(label(s.personalDataProcessed) || "Not recorded")}</div>
      <div><span>Privacy owner</span>${esc(s.privacyOwnerName || "--")}</div>
      <div><span>Assessment</span>${esc(ASSESS[s.assessmentStatus] || s.assessmentStatus || "--")}</div>
      <div><span>Privacy review date</span>${esc(date(s.privacyReviewDate) || "--")}</div>
      <div><span>Retention end</span>${esc(date(s.retentionDueDate) || "--")}</div>
      <div><span>Lifecycle status</span>${esc(label(s.statusCode) || "--")}</div>
      <div><span>Gaps</span>${gapsText(s)}</div>`;
    const live = new Set((d.exceptions || []).filter(x => x.status === "PENDING_APPROVAL" || x.status === "APPROVED").map(x => x.requirementCode));
    document.getElementById("apvDGaps").innerHTML = (d.gaps || []).map(g => `
      <tr><td>${esc(g.requirementName)}</td><td>${chip(GAP, g.gapKind)} ${esc(g.message)}</td>
          <td>${esc(ENF[g.enforcement] || g.enforcement)}${g.enforcement === "BLOCK" ? `<div class="apv-note">blocks ${g.blockTarget === "ACTIVE" ? "a move to Active" : "Disposed / Archived"}</div>` : ""}</td>
          <td>${Number(g.isExcepted) ? `Excepted until ${esc(date(g.exceptionExpiry))}` : (live.has(g.requirementCode) ? "Requested" : "--")}</td>
          <td>${CAN_EDIT && !Number(g.isExcepted) && g.exceptionAllowed && !live.has(g.requirementCode)
                ? `<button class="pm-button" type="button" data-apv-exc-req="${esc(g.requirementCode)}">Request exception</button>` : ""}</td></tr>`).join("")
      || empty(5, s.privacyStatus === "NOT_APPLICABLE" ? "Personal data is not processed." : "No gap.");
    state.exceptions = d.exceptions || [];
    document.getElementById("apvDExceptions").innerHTML = state.exceptions.map(x => exceptionRow(x, false)).join("") || empty(7, "No exception.");
    state.reviews = d.reviews || [];
    document.getElementById("apvDReviews").innerHTML = state.reviews.map(r => `
      <tr><td>${esc(KIND[r.reviewKind] || r.reviewKind)}</td><td>${esc(date(r.dueDate))}</td><td>${chip(REV, r.status)}</td>
          <td>${esc(OUTCOME[r.outcome] || "--")}${r.extendedUntil ? `<div class="apv-note">until ${esc(date(r.extendedUntil))}</div>` : ""}${r.note ? `<div class="apv-note">${esc(r.note)}</div>` : ""}${r.cancelReason ? `<div class="apv-note">${esc(r.cancelReason)}</div>` : ""}</td>
          <td>${esc(r.completedBy || "")}${r.completedDt ? `<div class="apv-note">${esc(dateTime(r.completedDt))}</div>` : ""}</td>
          <td>${r.status === "OPEN" && (CAN_EDIT || CAN_APPROVE) ? `<button class="pm-button" type="button" data-apv-rev="${esc(r.reviewId)}">Complete</button>` : ""}</td></tr>`).join("")
      || empty(6, "No review.");
  }

  function exceptionRow(x, withAsset) {
    const acts = [];
    if (x.status === "PENDING_APPROVAL" && CAN_APPROVE) acts.push(["APPROVE", "Approve"], ["REJECT", "Reject"]);
    if (x.status === "PENDING_APPROVAL" && CAN_EDIT) acts.push(["WITHDRAW", "Withdraw"]);
    if (x.status === "APPROVED" && CAN_APPROVE) acts.push(["REVOKE", "Revoke"]);
    return `<tr>${withAsset ? `<td><button class="pm-link-button" type="button" data-apv-asset="${esc(x.assetId)}">${esc(x.assetName)}</button></td>` : ""}
      <td>${esc(x.requirementName)}</td><td>${chip(EXC, x.status)}</td>
      <td>${esc(x.reason)}<div class="apv-note">${esc(x.compensatingControls)}</div></td>
      <td>${esc(x.ownerName || "--")}</td><td>${esc(date(x.expiryDate))}</td>
      <td>${withAsset ? `${esc(x.requestedBy)}<div class="apv-note">${esc(dateTime(x.requestedDt))}</div>` : ""}${x.decidedBy ? `<div class="apv-note">${esc(x.decidedBy)} ${esc(dateTime(x.decidedDt))}</div>` : (withAsset ? "" : "--")}${x.decisionNote ? `<div class="apv-note">${esc(x.decisionNote)}</div>` : ""}</td>
      <td>${acts.map(([a, l]) => `<button class="pm-button" type="button" data-apv-x="${esc(x.exceptionId)}" data-apv-x-act="${a}">${esc(l)}</button>`).join(" ")}</td></tr>`;
  }

  // ------------------------------------------------------------------ exceptions
  function openExceptionRequest(code) {
    const g = ((state.detail || {}).gaps || []).find(x => x.requirementCode === code);
    if (!g) return;
    state.excGap = g;
    document.getElementById("apvExcNote").textContent = `${g.requirementName}: ${g.message}`
      + (g.maxExceptionDays ? ` The expiry date must be within ${g.maxExceptionDays} days.` : "")
      + " Another person with approval rights decides the request.";
    document.getElementById("apvExcOwner").innerHTML = `<option value="">Select</option>`
      + (((state.config || {}).employees) || []).map(e => `<option value="${esc(e.employeeId)}">${esc(e.employeeName)}</option>`).join("");
    ["apvExcReason", "apvExcControls", "apvExcExpiry"].forEach(id => { document.getElementById(id).value = ""; });
    hide("apvExcMessage");
    document.getElementById("apvExcModal").hidden = false;
  }

  async function submitExceptionRequest() {
    const g = state.excGap;
    const res = await api("POST", "/exceptions", {
      organizationId: state.organizationId, assetId: state.assetId, requirementCode: g.requirementCode,
      reason: val("apvExcReason") || null, compensatingControls: val("apvExcControls") || null,
      ownerEmployeeId: Number(val("apvExcOwner")) || null, expiryDate: val("apvExcExpiry") || null
    });
    if (!res.ok) { show("apvExcMessage", res.error); return; }
    document.getElementById("apvExcModal").hidden = true;
    await openDetail(state.assetId);
    showMessage("Exception requested; it applies once another person approves it.", "success");
  }

  async function refreshExceptions() {
    const body = document.getElementById("apvXBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.xPager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.xPager ? state.xPager.page() : 1, pageSize: state.xPager ? state.xPager.size() : 25 });
    if (val("apvXStatus")) qs.set("status", val("apvXStatus"));
    const res = await api("GET", `/exceptions?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.xPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.xPager?.setTotal(res.data.data.totalRows, rows.length);
    state.exceptions = rows;
    body.innerHTML = rows.map(x => exceptionRow(x, true)).join("") || empty(8, "No exception in this view.");
  }

  async function exceptionAction(id, action, from) {
    const x = state.exceptions.find(e => e.exceptionId === id);
    if (!x) return;
    let note = null;
    if (action === "REJECT" || action === "REVOKE") {
      note = await window.gracUi.promptRequired(action === "REJECT" ? "Why is the exception rejected?" : "Why is the exception revoked? The gap applies again.",
        { title: action === "REJECT" ? "Reject exception" : "Revoke exception", inputLabel: "Reason" });
      if (!note) return;
    } else if (!await window.gracUi.confirm(action === "APPROVE" ? `Approve the exception until ${date(x.expiryDate)}?` : "Withdraw the exception request?")) return;
    const res = await api("POST", `/exceptions/${id}/action`, {
      organizationId: state.organizationId, action, note, expectedRecordVersion: x.recordVersion ?? null
    });
    if (!res.ok) { showMessage(res.error, "error"); if (res.status !== 409) return; }
    if (from === "detail") await openDetail(state.assetId); else await refreshExceptions();
    if (res.ok) showMessage({ APPROVED: "Exception approved.", REJECTED: "Exception rejected.", WITHDRAWN: "Request withdrawn.", REVOKED: "Exception revoked." }[res.data.result] || "Done.", "success");
  }

  // ------------------------------------------------------------------ reviews
  async function refreshReviews() {
    const body = document.getElementById("apvRBody");
    if (!state.organizationId) { body.innerHTML = empty(7, "Select an organization."); state.rPager?.clear(); return; }
    body.innerHTML = empty(7, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.rPager ? state.rPager.page() : 1, pageSize: state.rPager ? state.rPager.size() : 25 });
    if (val("apvRStatus")) qs.set("status", val("apvRStatus"));
    if (val("apvRKind")) qs.set("kind", val("apvRKind"));
    const res = await api("GET", `/reviews?${qs}`);
    if (!res.ok) { body.innerHTML = empty(7, res.error); state.rPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.rPager?.setTotal(res.data.data.totalRows, rows.length);
    state.reviews = rows;
    body.innerHTML = rows.map(r => `
      <tr><td><button class="pm-link-button" type="button" data-apv-asset="${esc(r.assetId)}">${esc(r.assetName)}</button></td>
          <td>${esc(KIND[r.reviewKind] || r.reviewKind)}${r.legalHold && String(r.legalHold).toUpperCase() === "YES" ? `<div class="apv-note">legal hold</div>` : ""}</td>
          <td>${esc(date(r.dueDate))}${Number(r.isOverdue) ? ` <span class="apv-chip apv-st-bad">Overdue</span>` : ""}</td>
          <td>${chip(REV, r.status)}</td><td>${esc(r.privacyOwnerName || "--")}</td>
          <td>${esc(OUTCOME[r.outcome] || "--")}${r.note ? `<div class="apv-note">${esc(r.note)}</div>` : ""}</td>
          <td>${r.status === "OPEN" && (CAN_EDIT || CAN_APPROVE) ? `<button class="pm-button" type="button" data-apv-rev="${esc(r.reviewId)}">Complete</button>` : ""}</td></tr>`).join("")
      || empty(7, "No review in this view.");
  }

  function openReview(id, from) {
    const r = state.reviews.find(x => x.reviewId === id);
    if (!r) return;
    state.review = { ...r, from };
    const outcomes = r.reviewKind === "PRIVACY" ? ["REVIEWED"]
      : ["DELETE", "ARCHIVE", "LEGAL_HOLD"].filter(() => CAN_EDIT).concat(CAN_APPROVE ? ["EXTEND"] : []);
    document.getElementById("apvRevTitle").textContent = `${KIND[r.reviewKind] || r.reviewKind} due ${date(r.dueDate)}`;
    document.getElementById("apvRevOutcome").innerHTML = outcomes.map(o => `<option value="${o}">${esc(OUTCOME[o])}</option>`).join("");
    ["apvRevNext", "apvRevText", "apvRevEvidence"].forEach(x => { document.getElementById(x).value = ""; });
    hide("apvRevMessage");
    reviewOutcomeHints();
    document.getElementById("apvRevModal").hidden = false;
  }

  function reviewOutcomeHints() {
    const o = val("apvRevOutcome");
    const hint = {
      REVIEWED: "Records the review and sets the next privacy review date of the asset.",
      DELETE: "Records that the personal data was deleted at the end of retention; evidence is required.",
      ARCHIVE: "Records that the personal data was archived at the end of retention; evidence is required.",
      LEGAL_HOLD: "Legal hold status of the asset must be Yes; enter the date of the next verification.",
      EXTEND: "An approved extension: a reason and the date until which the data is kept are required."
    }[o] || "";
    document.getElementById("apvRevNote").textContent = hint;
    document.getElementById("apvRevNextLabel").textContent = o === "REVIEWED" ? "Next privacy review date *"
      : o === "LEGAL_HOLD" ? "Next verification date *" : o === "EXTEND" ? "Keep until *" : "Next date";
    document.getElementById("apvRevNext").closest("label").hidden = o === "DELETE" || o === "ARCHIVE";
    document.getElementById("apvRevNoteLabel").textContent = o === "EXTEND" ? "Reason *" : "Note";
    document.getElementById("apvRevEvidenceLabel").textContent = o === "DELETE" || o === "ARCHIVE" ? "Evidence *" : "Evidence";
  }

  async function submitReview() {
    const r = state.review, o = val("apvRevOutcome");
    const res = await api("POST", `/reviews/${r.reviewId}/complete`, {
      organizationId: state.organizationId, outcome: o, note: val("apvRevText") || null, evidence: val("apvRevEvidence") || null,
      nextDate: o === "DELETE" || o === "ARCHIVE" ? null : (val("apvRevNext") || null), expectedRecordVersion: r.recordVersion ?? null
    });
    if (!res.ok) { show("apvRevMessage", res.error); return; }
    document.getElementById("apvRevModal").hidden = true;
    if (r.from === "detail") await openDetail(state.assetId); else await refreshReviews();
    showMessage(`Review completed: ${OUTCOME[o] || o}.`, "success");
  }

  // ------------------------------------------------------------------ requirements
  function renderRequirements() {
    const c = state.config, body = document.getElementById("apvQBody");
    if (!state.organizationId || !c) { body.innerHTML = empty(6, "Select an organization."); document.getElementById("apvOBody").innerHTML = ""; return; }
    const dis = CAN_EDIT ? "" : " disabled";
    body.innerHTML = (c.requirements || []).map(q => `
      <tr><td>${esc(q.requirementName)}<div class="apv-note">${esc(q.description)} (BRD ${esc(q.brdReference)})</div></td>
          <td>${esc(ENF[q.defaultEnforcement])}</td>
          <td><select data-apv-q-enf="${esc(q.requirementCode)}"${dis}><option value="">Default (${esc(ENF[q.defaultEnforcement])})</option>
              ${Object.entries(ENF).map(([k, l]) => `<option value="${k}"${q.orgEnforcement === k ? " selected" : ""}>${esc(l)}</option>`).join("")}</select></td>
          <td><input type="checkbox" data-apv-q-exc="${esc(q.requirementCode)}"${q.exceptionAllowed ? " checked" : ""}${dis} /></td>
          <td><input type="number" min="1" max="1095" step="1" data-apv-q-days="${esc(q.requirementCode)}" value="${esc(q.maxExceptionDays ?? "")}"${dis} /></td>
          <td>${CAN_EDIT ? `<button class="pm-button" type="button" data-apv-q-save="${esc(q.requirementCode)}">Save</button>` : ""}</td></tr>`).join("");
    const typeSel = document.getElementById("apvOType"), reqSel = document.getElementById("apvOReq");
    if (typeSel) typeSel.innerHTML = (c.assetTypes || []).map(t => `<option value="${esc(t.assetTypeId)}">${esc(t.assetTypeName)}</option>`).join("");
    if (reqSel) reqSel.innerHTML = (c.requirements || []).map(q => `<option value="${esc(q.requirementCode)}">${esc(q.requirementName)}</option>`).join("");
    document.getElementById("apvOBody").innerHTML = (c.overrides || []).map(o => `
      <tr><td>${esc(o.assetTypeName)}</td><td>${esc(o.requirementName)}</td><td>${esc(ENF[o.enforcement])}</td>
          <td>${o.exceptionAllowed ? "Yes" : "No"}</td><td>${esc(o.maxExceptionDays ?? "--")}</td>
          <td>${CAN_EDIT ? `<button class="pm-button" type="button" data-apv-o-remove="${esc(o.requirementCode)}" data-apv-o-type="${esc(o.assetTypeId)}">Remove</button>` : ""}</td></tr>`).join("")
      || empty(6, "No asset-type setting; the organization settings apply to every type.");
  }

  async function saveSetting(body, okText) {
    const res = await api("POST", "/requirements", { organizationId: state.organizationId, ...body });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    await loadConfig();
    renderRequirements();
    showMessage(okText, "success");
  }

  function saveOrgSetting(code) {
    const q = `[data-apv-q-enf="${code}"]`;
    const enf = document.querySelector(`select${q}`).value || null;
    saveSetting({
      assetTypeId: null, requirementCode: code, enforcement: enf,
      exceptionAllowed: document.querySelector(`input[data-apv-q-exc="${code}"]`).checked,
      maxExceptionDays: Number(document.querySelector(`input[data-apv-q-days="${code}"]`).value) || null
    }, enf ? "Requirement setting saved." : "Requirement back to its default.");
  }

  function saveOverride() {
    saveSetting({
      assetTypeId: Number(val("apvOType")) || null, requirementCode: val("apvOReq"), enforcement: val("apvOEnf"),
      exceptionAllowed: document.getElementById("apvOExc").checked, maxExceptionDays: Number(val("apvODays")) || null
    }, "Asset-type setting saved.");
  }

  async function removeOverride(typeId, code) {
    if (!await window.gracUi.confirm("Remove this asset-type setting? The organization setting applies again.")) return;
    saveSetting({ assetTypeId: typeId, requirementCode: code, enforcement: null, exceptionAllowed: true, maxExceptionDays: null },
      "Asset-type setting removed.");
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
  function chip(map, code) { const [l, c] = map[code] || [label(code) || "--", "apv-st-off"]; return `<span class="apv-chip ${c}">${esc(l)}</span>`; }
  function label(code) { return code ? String(code).replace(/_/g, " ").toLowerCase().replace(/^./, c => c.toUpperCase()) : ""; }
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function showMessage(text, kind) {
    const el = document.getElementById("apvMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.classList.toggle("info", kind === "info"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("apvMessage"); el.hidden = true; el.textContent = ""; }
  function show(id, text) { const el = document.getElementById(id); el.textContent = text || ""; el.hidden = !text; }
  function hide(id) { const el = document.getElementById(id); el.hidden = true; el.textContent = ""; }
  function val(id) { const el = document.getElementById(id); return el ? (el.value || "").trim() : ""; }
  function date(v) { return v ? String(v).substring(0, 10) : ""; }   // SQL DATE values: yyyy-mm-dd
  function dateTime(v) { if (!v) return ""; const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString(); }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
