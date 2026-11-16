// =====================================================================
// Workflow Settings (was Risk Settings) -- migration 458 (2026-10-08);
// renamed and moved to Risk Management -> Settings by 533 (2026-11-13).
// Loaded by Views/Practice/Partials/risk-settings.cshtml.
//
// 533: the page also hosts the Risk Acceptance Approval Authority section
// (risk-acceptance-authority.js). This file owns the org picker and
// Reload for both, and hands the organisation to that section through
// window.gracRiskAcceptanceAuthority.load(orgId) -- see loadAll().
//
// Settings -> Risk Settings. The Risk Centre settings (BRD §19, §22)
// moved here from the modal behind the gear icon on Risk Candidate /
// Risk Register. The load, the threshold/role pickers, the §21 notify
// matrix and the save payload are that modal's code (risk-centre.js
// openConfigModal / loadRoles / onConfigSubmit), moved -- not rewritten
// -- so the settings behave exactly as before. risk-centre.js keeps
// loadConfig: the risk pages still READ these settings.
//
// Auth: /practice/api/risk-centre/* enforces session + org isolation.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/risk-centre";
  const wf   = window.__wfCommon;
  const escapeHtml = v => wf.escape(v);

  const state = { orgId: null, config: null };

  // §21 events, in workflow order. Read-only here: adding a role to an
  // event is an admin action against org_risk_config_notify_role, and a
  // second editing surface would be a second source of truth.
  const NOTIFY_EVENTS = [
    ["CANDIDATE_ASSIGNED",      "New candidate assigned for assessment"],
    ["CLARIFICATION_REQUESTED", "Clarification requested"],
    ["ANALYSIS_COMPLETED",      "Assessment completed"],
    ["APPROVAL_REQUIRED",       "Approval required"],
    ["RISK_APPROVED",           "Risk approved for registration"],
    ["CANDIDATE_REJECTED",      "Candidate rejected"],
    ["RISK_OWNER_ASSIGNED",     "Risk owner assignment"],
    ["RISK_REGISTERED",         "Risk registered"]
  ];

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("rsRoot")) return;
    document.getElementById("rsPickOrg").addEventListener("change", ev => {
      state.orgId = Number(ev.target.value) || null;
      loadAll();
    });
    document.getElementById("rsReloadBtn").addEventListener("click", loadAll);
    document.getElementById("rsResetBtn").addEventListener("click", () => {
      fill();
      msg("Changes discarded.");
    });
    document.getElementById("riskConfigForm").addEventListener("submit", onSubmit);

    const orgs = await wf.loadOrgs();
    if (!orgs.length) {
      document.getElementById("rsPickOrg").innerHTML = `<option value="">No organization</option>`;
      msg("You are not mapped to any organization, so there is nothing to configure.");
      setEnabled(false);
      return;
    }
    wf.populateOrgSelect("rsPickOrg", orgs);   // last-picked org, else lowest id
    state.orgId = Number(document.getElementById("rsPickOrg").value) || null;
    await loadAll();
  }

  // Both sections, for the one organisation picked above.
  function loadAll() {
    return Promise.all([load(), loadAcceptance()]);
  }
  function loadAcceptance() {
    const raa = window.gracRiskAcceptanceAuthority;
    return raa ? raa.load(state.orgId) : Promise.resolve();
  }

  async function load() {
    msg("");
    state.config = null;
    if (!state.orgId) { setEnabled(false); return; }
    setEnabled(false);

    const [config, options, roles] = await Promise.all([
      apiGet(`/config?organizationId=${state.orgId}`),
      apiGet(`/scoring-options?organizationId=${state.orgId}`),
      loadRoles(state.orgId)
    ]);
    if (!config) {
      msg("Settings unavailable for this organization.", true);
      document.getElementById("cfgNotifyBody").innerHTML =
        `<tr><td colspan="2" class="pm-empty">Settings unavailable.</td></tr>`;
      return;
    }
    state.config = config;

    // Threshold options come from the org's OWN matrix, deduplicated and
    // ordered by score, so a framework using colour bands or 1-4 offers
    // its own words rather than a hardcoded Low/Medium/High/Critical.
    const ratings = [];
    (options?.matrix || []).forEach(cell => {
      if (!ratings.some(x => x.code === cell.ratingCode))
        ratings.push({ code: cell.ratingCode, name: cell.ratingName, score: cell.ratingScore ?? 0 });
    });
    ratings.sort((a, b) => a.score - b.score);
    fillOptions("cfgMinRating", "Every risk", ratings.map(x => [x.code, x.name]));
    fillOptions("cfgApproverRole", "Any authorised user", roles.map(r => [r.roleId, r.roleName]));

    fill();
    setEnabled(true);
  }

  // Puts the loaded settings into the form (also "Discard changes").
  function fill() {
    const c = state.config;
    if (!c) return;
    setVal("cfgMinRating",    c.approvalMinRatingCode || "");
    setVal("cfgApproverRole", c.approverRoleId || "");
    check("cfgApprovalRequired",  c.approvalRequired);
    check("cfgDefaultTreatment",  c.defaultRaiseTreatmentTask);
    check("cfgNotifications",     c.notificationsEnabled);
    check("cfgAllowLegacyAccept", c.allowLegacyAccept);
    check("cfgAllowOpenResidual", c.allowResidualWithOpenTasks);
    setVal("cfgNotes", c.notes || "");

    document.getElementById("cfgNotifyBody").innerHTML = NOTIFY_EVENTS.map(([code, label]) => {
      const roles = (c.notifyRoles || []).filter(r => r.notifyEventCode === code);
      return `<tr><td>${escapeHtml(label)}</td><td>${
        roles.length
          ? roles.map(r => `<span class="rs-chip">${escapeHtml(r.roleName || `#${r.roleId}`)}</span>`).join(" ")
          : `<span class="pm-hint">participants only</span>`}</td></tr>`;
    }).join("");
  }

  async function loadRoles(orgId) {
    try {
      const r = await fetch(U(`/practice/api/roles?organizationId=${orgId}`), { credentials: "same-origin" });
      if (!r.ok) return [];
      const b = await r.json();
      const rows = Array.isArray(b) ? b : (b?.data || b?.Data || []);
      return rows.map(x => ({
        roleId:   x.roleId   ?? x.RoleId,
        roleName: x.roleName ?? x.RoleName
      })).filter(x => x.roleId);
    } catch (_) { return []; }
  }

  async function onSubmit(ev) {
    ev.preventDefault();
    if (!state.orgId || !state.config) return;
    msg("");
    const minRating = val("cfgMinRating");
    const roleId    = val("cfgApproverRole");
    const result = await apiPost(`/config?organizationId=${state.orgId}`, {
      approvalRequired:           isChecked("cfgApprovalRequired"),
      approvalMinRatingCode:      minRating || null,
      approverRoleId:             roleId ? Number(roleId) : null,
      defaultRaiseTreatmentTask:  isChecked("cfgDefaultTreatment"),
      allowLegacyAccept:          isChecked("cfgAllowLegacyAccept"),
      allowResidualWithOpenTasks: isChecked("cfgAllowOpenResidual"),
      notificationsEnabled:       isChecked("cfgNotifications"),
      notes:                      val("cfgNotes") || null,
      // Empty select = "un-set it", which is a different instruction from
      // "leave it alone" — see sp_risk_config_save.
      clearMinRating:             !minRating,
      clearApproverRole:          !roleId
    });
    if (!result || result.success === false) {
      msg((result && result.error) || "Save failed.", true);
      return;
    }
    // The acceptance section's fallback note reads these settings (approval
    // on/off, the general approver role), so it is refreshed too -- unless
    // it has unsaved edits, which a reload would silently throw away.
    await load();
    if (!window.gracRiskAcceptanceAuthority?.isDirty()) await loadAcceptance();
    msg("Settings saved.");
  }

  // ---- small helpers ------------------------------------------------
  function fillOptions(id, blank, pairs) {
    const sel = document.getElementById(id);
    sel.innerHTML = `<option value="">${escapeHtml(blank)}</option>`
      + pairs.map(([v, l]) => `<option value="${escapeHtml(v)}">${escapeHtml(l)}</option>`).join("");
  }
  function setEnabled(on) {
    document.querySelectorAll("#riskConfigForm input, #riskConfigForm select, #riskConfigForm textarea, #riskConfigForm button")
      .forEach(el => { el.disabled = !on; });
  }
  function msg(text, isError) {
    const el = document.getElementById("cfgMessage");
    el.textContent = text || "";
    el.style.color = isError ? "var(--danger-700)" : "";
  }
  function check(id, on)    { const el = document.getElementById(id); if (el) el.checked = !!on; }
  function isChecked(id)    { const el = document.getElementById(id); return !!(el && el.checked); }
  function val(id)          { const el = document.getElementById(id); return el ? String(el.value || "").trim() : ""; }
  function setVal(id, v)    { const el = document.getElementById(id); if (el) el.value = v ?? ""; }

  async function apiGet(path) {
    try {
      const r = await fetch(U(base + path), { credentials: "same-origin" });
      if (!r.ok) return null;
      return await r.json();
    } catch (_) { return null; }
  }
  async function apiPost(path, body) {
    try {
      const r = await fetch(U(base + path), {
        method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) return { success: false, error: data.error || `HTTP ${r.status}` };
      return { success: data.success !== false, ...data };
    } catch (err) { return { success: false, error: err.message }; }
  }
})();
