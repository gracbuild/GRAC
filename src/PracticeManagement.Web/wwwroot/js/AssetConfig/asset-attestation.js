// =====================================================================
// Asset Attestation (migration 431) -- BRD 5.3.
// Loaded by asset-attestation.cshtml. Occurrences: attestation?scope=
// MINE | APPROVALS | ALL; respond: attestation/{id}/respond; manager
// approve / return and cancel: attestation/{id}/decide; runs / campaigns:
// attestation/generate + attestation/campaigns; profiles:
// attestation/profiles. Only the assignee may respond and only the
// manager may approve -- the procedures enforce it; this screen mirrors it.
// 432: verification exceptions -- attestation/exceptions (list, detail),
// attestation/exceptions/{id}/action, attestation/exception-settings and
// attestation/exception-rules.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/attestation";
  const root = document.getElementById("aatRoot");
  if (!root) return;
  const CAN_ADD = root.dataset.canAdd === "1";
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";

  const STATUS = {
    GENERATED: ["Generated", "aat-st-open"], PENDING: ["Pending", "aat-st-open"], IN_PROGRESS: ["In progress", "aat-st-open"],
    OVERDUE: ["Overdue", "aat-st-overdue"], ESCALATED: ["Escalated", "aat-st-overdue"], CONFIRMED: ["Awaiting approval", "aat-st-wait"],
    DISPUTED: ["Disputed", "aat-st-disputed"], EXCEPTION: ["Exception", "aat-st-disputed"], RESOLVED: ["Resolved", "aat-st-closed"],
    CLOSED: ["Closed", "aat-st-closed"], CANCELLED: ["Cancelled", "aat-st-cancel"]
  };
  const TYPE = { INITIAL: "Initial acknowledgement", PERIODIC: "Periodic", CAMPAIGN: "Campaign", TRANSFER: "Transfer", RETURN: "Return", EVENT: "Event" };
  const ROLE = { CUSTODIAN: "Custodian", OWNER: "Asset owner" };
  const FREQ = { MONTHLY: "Monthly", QUARTERLY: "Quarterly", HALF_YEARLY: "Half-yearly", ANNUAL: "Annual", CUSTOM: "Custom" };
  const OPEN = new Set(["GENERATED", "PENDING", "IN_PROGRESS", "OVERDUE", "CONFIRMED", "DISPUTED"]);

  const EXC_STATUS = {
    OPEN: ["Open", "aat-st-open"], ASSIGNED: ["Assigned", "aat-st-open"], UNDER_REVIEW: ["Under review", "aat-st-open"],
    AWAITING_EVIDENCE: ["Awaiting evidence", "aat-st-wait"], AWAITING_APPROVAL: ["Awaiting approval", "aat-st-wait"],
    RESOLVED: ["Resolved", "aat-st-closed"], CLOSED: ["Closed", "aat-st-closed"], CANCELLED: ["Cancelled", "aat-st-cancel"]
  };
  const CATEGORY = {
    ASSET_NOT_FOUND: "Asset not found", WRONG_CUSTODIAN: "Wrong custodian", ASSET_RETURNED: "Asset returned", ASSET_REPLACED: "Asset replaced",
    ASSET_DAMAGED: "Asset damaged", ASSET_LOST: "Asset lost", LOCATION_INCORRECT: "Location incorrect",
    INFORMATION_INCORRECT: "Asset information incorrect", DUPLICATE_RECORD: "Duplicate asset record", ASSET_RETIRED: "Asset retired", OTHER: "Other"
  };
  const PRIMARY = { ASSET_OWNER: "Asset owner", ASSET_ADMINISTRATOR: "Asset administrator", MAINTENANCE_TEAM: "Maintenance / support team",
                    SECURITY: "Security", FALLBACK_TEAM: "Fallback team", REASSIGNED: "Reassigned" };
  const OUTCOME = { NO_CHANGE: "No change", RECORD_CORRECTION: "Record corrected", LOST_CONFIRMED: "Loss confirmed", DAMAGE_CONFIRMED: "Damage confirmed",
                    RETIREMENT_CONFIRMED: "Retirement confirmed", DUPLICATE_CONFIRMED: "Duplicate confirmed", OTHER: "Other" };

  const state = { organizationId: null, tab: "MINE", pager: null, rows: [], current: null, profiles: [], scopes: [], profile: null,
                  excPager: null, excRows: [], exc: null, vs: null, rule: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "aatPager", onChange: refreshList }) : null;
    state.excPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "aatExcPager", onChange: refreshExceptions }) : null;
    bind();
    await populateOrgs();
    const sel = document.getElementById("aatOrg");
    window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    // 451: opened from the Asset & Contract dashboard -- organization, tab and filter (Shared/dashboard-drill.js).
    const dashDrill = window.__pmDrill ? window.__pmDrill.read() : null;
    window.__pmDrill?.preselectFor(dashDrill, sel, { ALL: { status: "aatStatus" }, EXCEPTIONS: { status: "aatExcStatus" } });
    await changeOrg(Number(sel.value) || null);
    window.__pmDrill?.showOnPage("aatRoot", "data-aat-tab", dashDrill);
  }

  async function populateOrgs() {
    const sel = document.getElementById("aatOrg");
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
    document.getElementById("aatOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.querySelectorAll("[data-aat-tab]").forEach(b => b.addEventListener("click", () => selectTab(b.dataset.aatTab)));
    document.getElementById("aatRefresh").addEventListener("click", () => refreshList());
    let t = null;
    document.getElementById("aatSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => { state.pager?.reset(true); refreshList(); }, 300); });
    document.getElementById("aatStatus").addEventListener("change", () => { state.pager?.reset(true); refreshList(); });
    document.getElementById("aatListBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aat-act]");
      if (b) act(Number(b.dataset.aatId), b.dataset.aatAct);
    });
    document.querySelectorAll("[data-close-aat]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeAat).hidden = true; }));
    document.getElementById("aatResponse").addEventListener("change", syncRespond);
    document.getElementById("aatCondition").addEventListener("change", syncRespond);
    document.getElementById("aatRespondForm").addEventListener("submit", ev => { ev.preventDefault(); submitRespond(); });
    document.getElementById("aatRunBtn")?.addEventListener("click", runPeriodic);
    document.getElementById("aatCampaignBtn")?.addEventListener("click", openCampaign);
    document.getElementById("aatCampaignForm").addEventListener("submit", ev => { ev.preventDefault(); submitCampaign(); });
    document.getElementById("aatProfileNew")?.addEventListener("click", () => openProfile(null));
    document.getElementById("aatProfilesBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-aat-profile]");
      if (tr && (CAN_EDIT || CAN_ADD)) openProfile(Number(tr.dataset.aatProfile));
    });
    document.getElementById("aatPfKind").addEventListener("change", () => fillScopes(null));
    document.getElementById("aatPfFrequency").addEventListener("change", () => {
      document.getElementById("aatPfCustomWrap").hidden = val("aatPfFrequency") !== "CUSTOM";
    });
    document.getElementById("aatProfileForm").addEventListener("submit", ev => { ev.preventDefault(); submitProfile(); });
    // 432
    ["aatExcScope", "aatExcStatus"].forEach(id => document.getElementById(id).addEventListener("change", () => { state.excPager?.reset(true); refreshExceptions(); }));
    let te = null;
    document.getElementById("aatExcSearch").addEventListener("input", () => { clearTimeout(te); te = setTimeout(() => { state.excPager?.reset(true); refreshExceptions(); }, 300); });
    document.getElementById("aatExcBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-aat-exc]");
      if (tr) openException(Number(tr.dataset.aatExc));
    });
    document.getElementById("aatExcModal").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-aat-exc-act]");
      if (b) excAction(b.dataset.aatExcAct);
    });
    document.getElementById("aatExcForm").addEventListener("submit", ev => ev.preventDefault());
    document.getElementById("aatVsSave")?.addEventListener("click", saveSettings);
    document.getElementById("aatVrBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-aat-rule]");
      if (tr && CAN_EDIT) openRule(tr.dataset.aatRule);
    });
    document.getElementById("aatRuleForm").addEventListener("submit", ev => { ev.preventDefault(); saveRule(false); });
    document.getElementById("aatVrReset").addEventListener("click", () => saveRule(true));
  }

  async function changeOrg(id) {
    state.organizationId = id;
    state.vs = null;
    hideMessage();
    state.pager?.reset(true);
    await selectTab(state.tab);
  }

  async function selectTab(name) {
    state.tab = name;
    document.querySelectorAll("[data-aat-tab]").forEach(x => { const on = x.dataset.aatTab === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    const panel = ["MINE", "APPROVALS", "ALL"].includes(name) ? "LIST" : name;
    document.querySelectorAll("[data-aat-panel]").forEach(p => { p.hidden = p.dataset.aatPanel !== panel; });
    if (panel === "LIST") { state.pager?.reset(true); await refreshList(); }
    else if (panel === "RUNS") await refreshRuns();
    else if (panel === "EXCEPTIONS") { state.excPager?.reset(true); await refreshExceptions(); }
    else if (panel === "EXCSETTINGS") await refreshSettings();
    else await refreshProfiles();
  }

  // ------------------------------------------------------------------ occurrences
  async function refreshList() {
    const body = document.getElementById("aatListBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.pager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId, scope: state.tab,
      pageNumber: state.pager ? state.pager.page() : 1, pageSize: state.pager ? state.pager.size() : 25 });
    if (val("aatSearch")) qs.set("search", val("aatSearch"));
    if (val("aatStatus")) qs.set("status", val("aatStatus"));
    const res = await api("GET", `?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.pager?.clear(); return; }
    state.rows = res.data.data.rows || [];
    state.pager?.setTotal(res.data.data.totalRows, state.rows.length);
    body.innerHTML = state.rows.map(r => {
      const [label, css] = STATUS[r.displayStatus] || [r.displayStatus, "aat-st-open"];
      const actions = [];
      if (r.canRespond) actions.push(["RESPOND", "Respond", true]);
      if (r.canApprove) actions.push(["APPROVE", "Approve", true], ["RETURN", "Return", false]);
      if (CAN_APPROVE && OPEN.has(r.status)) actions.push(["CANCEL", "Cancel", false]);
      return `<tr>
        <td>${esc(r.assetName)}<div class="aat-note">#${esc(r.assetId)} - ${esc(TYPE[r.attestationType] || r.attestationType)}</div></td>
        <td>${esc(r.assetTypeName || "--")}</td>
        <td>${esc(r.assigneeName || "--")}<div class="aat-note">${esc(ROLE[r.assigneeRole] || r.assigneeRole)}</div></td>
        <td>${esc(date(r.dueDate))}</td>
        <td><span class="aat-chip ${css}">${esc(label)}</span></td>
        <td>${r.response ? esc(r.response === "CONFIRM" ? "Confirmed" : "Disagreed") + `<div class="aat-note">${esc(r.attestedByName || r.attestedBy || "")} ${esc(dateTime(r.responseDt))}</div>` : "--"}
            ${r.disagreementCategory ? `<div class="aat-note">${esc(r.disagreementCategory.replace(/_/g, " ").toLowerCase())}</div>` : ""}
            ${r.decisionNote ? `<div class="aat-note">${esc(r.decisionNote)}</div>` : ""}</td>
        <td>${esc(r.campaignName || "--")}</td>
        <td><div class="aat-actions">${actions.map(([a, l, p]) => `<button class="pm-button${p ? " primary" : ""}" type="button" data-aat-act="${a}" data-aat-id="${r.attestationId}">${l}</button>`).join("")}</div></td>
      </tr>`;
    }).join("") || empty(8, state.tab === "MINE" ? "Nothing to attest." : state.tab === "APPROVALS" ? "Nothing waiting for your approval." : "No occurrences.");
  }

  async function act(id, action) {
    const r = state.rows.find(x => x.attestationId === id);
    if (!r) return;
    if (action === "RESPOND") { openRespond(r); return; }
    let note = null;
    if (action === "RETURN" || action === "CANCEL") {
      note = await window.gracUi.promptRequired(action === "RETURN" ? "Why is this attestation returned to the attester?" : "Why is this occurrence cancelled?",
        { title: action === "RETURN" ? "Return attestation" : "Cancel occurrence", inputLabel: "Reason" });
      if (!note) return;
    } else if (!await window.gracUi.confirm("Approve this attestation? The asset becomes Verified.")) return;
    const res = await api("POST", `/${id}/decide`, { organizationId: state.organizationId, decision: action, decisionNote: note, expectedRecordVersion: r.recordVersion });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    showMessage({ CLOSED: "Attestation approved; the asset is Verified.", IN_PROGRESS: "Returned to the attester.", CANCELLED: "Occurrence cancelled." }[res.data.result] || "Done.", "success");
    await refreshList();
  }

  function openRespond(r) {
    state.current = r;
    document.getElementById("aatRespondTitle").textContent = `Attest: ${r.assetName}`;
    document.getElementById("aatRespondInfo").textContent =
      `${TYPE[r.attestationType] || r.attestationType} as ${ROLE[r.assigneeRole] || r.assigneeRole}, due ${date(r.dueDate)}.`
      + (r.locationName ? ` Recorded location: ${r.locationName}.` : "") + (r.ownerName ? ` Asset owner: ${r.ownerName}.` : "")
      + (r.managerApprovalRequired ? " Your manager approves a confirmation." : "");
    document.querySelectorAll("[data-aat-check]").forEach(c => { c.checked = r.status === "IN_PROGRESS" ? !!r[c.dataset.aatCheck] : false; });
    document.getElementById("aatCondition").value = r.status === "IN_PROGRESS" ? (r.conditionCode || "") : "";
    document.getElementById("aatResponse").value = r.response || "CONFIRM";
    document.getElementById("aatCategory").value = r.disagreementCategory || "";
    document.getElementById("aatComments").value = r.status === "IN_PROGRESS" ? (r.comments || "") : "";
    document.getElementById("aatEvidence").value = r.status === "IN_PROGRESS" ? (r.evidenceText || "") : "";
    document.getElementById("aatEvidenceLabel").textContent = r.evidenceRequirement === "MANDATORY" ? "Evidence *" : r.evidenceRequirement === "NONE" ? "Evidence (not required)" : "Evidence (optional)";
    const msg = document.getElementById("aatRespondMessage"); msg.hidden = true; msg.textContent = "";
    syncRespond();
    document.getElementById("aatRespondModal").hidden = false;
  }

  function syncRespond() {
    const disagree = val("aatResponse") === "DISAGREE";
    document.getElementById("aatCategoryWrap").hidden = !disagree;
    document.getElementById("aatCommentsLabel").textContent = disagree ? "Comments *" : "Comments (required when a check is left open or the condition is not Good)";
  }

  async function submitRespond() {
    const r = state.current, msg = document.getElementById("aatRespondMessage");
    if (!r) return;
    const body = { organizationId: state.organizationId, response: val("aatResponse"), conditionCode: val("aatCondition") || null,
      disagreementCategory: val("aatResponse") === "DISAGREE" ? (val("aatCategory") || null) : null,
      comments: val("aatComments") || null, evidenceText: val("aatEvidence") || null, expectedRecordVersion: r.recordVersion };
    document.querySelectorAll("[data-aat-check]").forEach(c => { body[c.dataset.aatCheck] = c.checked; });
    const res = await api("POST", `/${r.attestationId}/respond`, body);
    if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
    document.getElementById("aatRespondModal").hidden = true;
    showMessage({ CLOSED: "Thank you -- the asset is Verified.", CONFIRMED: "Confirmed; waiting for your manager's approval.",
                  DISPUTED: "Disagreement recorded; the asset is marked Disputed for investigation.",
                  EXCEPTION: "Disagreement recorded; a verification exception was opened for investigation." }[res.data.result] || "Submitted.", "success");
    await refreshList();
  }

  // ------------------------------------------------------------------ runs and campaigns
  async function refreshRuns() {
    const body = document.getElementById("aatRunsBody");
    if (!state.organizationId) { body.innerHTML = empty(9, "Select an organization."); return; }
    const res = await api("GET", `/campaigns?organizationId=${state.organizationId}`);
    if (!res.ok) { body.innerHTML = empty(9, res.error); return; }
    body.innerHTML = (res.data.data || []).map(c => `
      <tr><td>${esc(c.campaignName)}</td><td>${esc(c.campaignType === "CAMPAIGN" ? "Campaign" : "Periodic")}</td><td>${esc(c.assetTypeName || "All")}</td>
          <td>${esc(date(c.dueDate) || "--")}</td><td>${esc(c.generatedCount)}</td><td>${esc(c.skippedCount)}</td><td>${esc(c.closedCount)}</td>
          <td>${esc(c.overdueMarked)}</td><td>${esc(c.enteredBy)}<div class="aat-note">${esc(dateTime(c.enteredDt))}</div></td></tr>`).join("")
      || empty(9, "No run yet.");
  }

  async function runPeriodic() {
    if (!state.organizationId) return;
    if (!await window.gracUi.confirm("Run periodic attestation now? Due occurrences are created and overdue ones are marked.")) return;
    const res = await api("POST", "/generate", { organizationId: state.organizationId, campaignType: "PERIODIC" });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    const d = res.data.data || {};
    showMessage(`Run complete: ${d.generated ?? 0} created, ${d.skipped ?? 0} skipped, ${d.overdueMarked ?? 0} marked overdue.`, "success");
    await refreshRuns();
  }

  async function openCampaign() {
    if (!state.organizationId) return;
    await loadProfiles();
    document.getElementById("aatCmpType").innerHTML = `<option value="">All asset types</option>`
      + state.scopes.filter(s => s.scopeKind === "ASSET_TYPE").map(s => `<option value="${esc(s.scopeId)}">${esc(s.scopeName)}</option>`).join("");
    document.getElementById("aatCmpName").value = "";
    document.getElementById("aatCmpDue").value = "";
    const msg = document.getElementById("aatCampaignMessage"); msg.hidden = true; msg.textContent = "";
    document.getElementById("aatCampaignModal").hidden = false;
  }

  async function submitCampaign() {
    const msg = document.getElementById("aatCampaignMessage");
    const res = await api("POST", "/generate", { organizationId: state.organizationId, campaignType: "CAMPAIGN",
      campaignName: val("aatCmpName") || null, assetTypeId: Number(val("aatCmpType")) || null, dueDate: val("aatCmpDue") || null });
    if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
    document.getElementById("aatCampaignModal").hidden = true;
    const d = res.data.data || {};
    showMessage(`Campaign created: ${d.generated ?? 0} occurrences, ${d.skipped ?? 0} skipped.`, "success");
    await refreshRuns();
  }

  // ------------------------------------------------------------------ profiles
  async function loadProfiles() {
    const res = await api("GET", `/profiles?organizationId=${state.organizationId}`);
    if (!res.ok) return res;
    state.profiles = res.data.data.profiles || [];
    state.scopes = res.data.data.scopes || [];
    return res;
  }

  async function refreshProfiles() {
    const body = document.getElementById("aatProfilesBody");
    if (!state.organizationId) { body.innerHTML = empty(9, "Select an organization."); return; }
    const res = await loadProfiles();
    if (!res.ok) { body.innerHTML = empty(9, res.error); return; }
    const kind = { CATEGORY: "Category", SUBCATEGORY: "Subcategory", ASSET_TYPE: "Asset type" };
    body.innerHTML = state.profiles.map(p => `
      <tr class="${CAN_EDIT || CAN_ADD ? "pm-row-clickable" : ""}" data-aat-profile="${p.profileId}">
        <td>${esc(p.scopeName)}<div class="aat-note">${esc(kind[p.scopeKind] || p.scopeKind)}</div></td>
        <td>${p.attestationRequired ? "Yes" : "No"}</td><td>${esc(p.participant === "BOTH" ? "Custodian and owner" : ROLE[p.participant] || p.participant)}</td>
        <td>${esc(FREQ[p.frequency] || p.frequency)}${p.frequency === "CUSTOM" ? ` (${esc(p.customIntervalDays)} days)` : ""}</td>
        <td>${esc(p.dueWindowDays)} days</td><td>${esc(p.evidenceRequirement.charAt(0) + p.evidenceRequirement.slice(1).toLowerCase())}</td>
        <td>${p.managerApprovalRequired ? "Yes" : "No"}</td><td>${p.isActive ? "Yes" : "No"}</td><td>v${esc(p.versionNo)}</td></tr>`).join("")
      || empty(9, "No profile yet -- no asset is attested until one applies.");
  }

  function fillScopes(selected) {
    const kind = val("aatPfKind");
    document.getElementById("aatPfScope").innerHTML = `<option value="">Select</option>` + state.scopes.filter(s => s.scopeKind === kind)
      .map(s => `<option value="${esc(s.scopeId)}"${String(s.scopeId) === String(selected ?? "") ? " selected" : ""}>${esc(s.scopeName)}</option>`).join("");
  }

  function openProfile(id) {
    const p = id ? state.profiles.find(x => x.profileId === id) : null;
    state.profile = p;
    document.getElementById("aatProfileTitle").textContent = p ? `Attestation profile -- ${p.scopeName}` : "Add attestation profile";
    document.getElementById("aatPfKind").value = p?.scopeKind || "ASSET_TYPE";
    document.getElementById("aatPfKind").disabled = !!p;
    fillScopes(p?.scopeId);
    document.getElementById("aatPfScope").disabled = !!p;
    document.getElementById("aatPfParticipant").value = p?.participant || "CUSTODIAN";
    document.getElementById("aatPfFrequency").value = p?.frequency || "ANNUAL";
    document.getElementById("aatPfCustom").value = p?.customIntervalDays ?? "";
    document.getElementById("aatPfCustomWrap").hidden = (p?.frequency || "ANNUAL") !== "CUSTOM";
    document.getElementById("aatPfWindow").value = p?.dueWindowDays ?? 14;
    document.getElementById("aatPfEvidence").value = p?.evidenceRequirement || "OPTIONAL";
    document.getElementById("aatPfRequired").checked = p ? !!p.attestationRequired : true;
    document.getElementById("aatPfManager").checked = !!p?.managerApprovalRequired;
    document.getElementById("aatPfActive").checked = p ? !!p.isActive : true;
    const msg = document.getElementById("aatProfileMessage"); msg.hidden = true; msg.textContent = "";
    document.getElementById("aatProfileModal").hidden = false;
  }

  async function submitProfile() {
    const p = state.profile, msg = document.getElementById("aatProfileMessage");
    const res = await api("POST", "/profiles", {
      organizationId: state.organizationId, profileId: p ? p.profileId : null, scopeKind: val("aatPfKind"), scopeId: Number(val("aatPfScope")) || 0,
      attestationRequired: document.getElementById("aatPfRequired").checked, participant: val("aatPfParticipant"), frequency: val("aatPfFrequency"),
      customIntervalDays: val("aatPfFrequency") === "CUSTOM" ? (Number(val("aatPfCustom")) || null) : null,
      dueWindowDays: Number(val("aatPfWindow")) || 0, evidenceRequirement: val("aatPfEvidence"),
      managerApprovalRequired: document.getElementById("aatPfManager").checked, isActive: document.getElementById("aatPfActive").checked,
      expectedRecordVersion: p ? p.recordVersion : null
    });
    if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
    document.getElementById("aatProfileModal").hidden = true;
    showMessage("Profile saved.", "success");
    await refreshProfiles();
  }

  // ------------------------------------------------------------------ verification exceptions (432)
  async function refreshExceptions() {
    const body = document.getElementById("aatExcBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.excPager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId, scope: val("aatExcScope"),
      pageNumber: state.excPager ? state.excPager.page() : 1, pageSize: state.excPager ? state.excPager.size() : 25 });
    if (val("aatExcStatus")) qs.set("status", val("aatExcStatus"));
    if (val("aatExcSearch")) qs.set("search", val("aatExcSearch"));
    const res = await api("GET", `/exceptions?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.excPager?.clear(); return; }
    state.excRows = res.data.data.rows || [];
    state.excPager?.setTotal(res.data.data.totalRows, state.excRows.length);
    body.innerHTML = state.excRows.map(x => {
      const [label, css] = EXC_STATUS[x.statusCode] || [x.statusName, "aat-st-open"];
      return `<tr class="pm-row-clickable" data-aat-exc="${x.exceptionId}">
        <td>#${esc(x.exceptionId)}<div class="aat-note">${esc(dateTime(x.reportedDt))}</div></td>
        <td>${esc(x.assetName)}<div class="aat-note">#${esc(x.assetId)} ${esc(x.assetTypeName || "")}</div></td>
        <td>${esc(CATEGORY[x.category] || x.category)}</td>
        <td><span class="aat-chip ${x.severity === "CRITICAL" ? "aat-st-overdue" : "aat-st-cancel"}">${esc(x.severity === "CRITICAL" ? "Critical" : "Standard")}</span></td>
        <td>${esc(x.investigatorName || "Unassigned")}</td>
        <td><span class="aat-chip ${css}">${esc(label)}</span></td>
        <td>${esc(date(x.resolutionDue))}${x.resolutionDue !== x.originalResolutionDue ? `<div class="aat-note">original ${esc(date(x.originalResolutionDue))}</div>` : ""}</td>
        <td>${x.escalationLevel ? `<span class="aat-chip aat-esc-${x.escalationLevel}">Level ${esc(x.escalationLevel)}</span><div class="aat-note">${esc(x.overdueDays)} days overdue</div>` : (x.startOverdue ? `<span class="aat-chip aat-esc-1">Start overdue</span>` : "--")}</td>
      </tr>`;
    }).join("") || empty(8, val("aatExcScope") === "MINE" ? "No exception assigned to you." : "No exceptions.");
  }

  async function openException(id) {
    const res = await api("GET", `/exceptions/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.exc = res.data.data.exception;
    const x = state.exc, hist = res.data.data.history || [];
    document.getElementById("aatExcTitle").textContent = `Exception #${x.exceptionId} -- ${x.assetName}`;
    const sec = x.category === "ASSET_LOST" ? ["secRemoteLockWipe", "secCredentialReview", "secPrivacyAssessment", "secAccessRevocation", "secMonitoring"] : [];
    const info = [
      ["Category", CATEGORY[x.category] || x.category], ["Severity", (x.severity === "CRITICAL" ? "Critical" : "Standard") + (x.criticalityName ? ` (asset ${x.criticalityName})` : "")],
      ["Status", (EXC_STATUS[x.statusCode] || [x.statusName])[0]], ["Reported", `${x.reportedByName || x.reportedBy}, ${dateTime(x.reportedDt)}`],
      ["Investigator", `${x.investigatorName || "Unassigned"}${x.assignmentBasis ? ` (${PRIMARY[x.assignmentBasis] || x.assignmentBasis})` : ""}`],
      ["Supporting", x.supportingAssignment || "--"], ["Start due", date(x.startDueDate) + (x.startedDt ? ` -- started ${dateTime(x.startedDt)}` : "")],
      ["Resolution due", date(x.resolutionDue) + (x.pausedDays ? ` (original ${date(x.originalResolutionDue)}, paused ${x.pausedDays} days)` : "") + (x.pauseStartedDt ? " -- paused" : "")],
      ["Escalation", x.escalationLevel ? `Level ${x.escalationLevel} (${x.overdueDays} days overdue)` : "--"],
      ["Closure needs", [x.approvalRequired ? "approval" : null, x.evidenceRequired ? "evidence" : null].filter(Boolean).join(" and ") || "--"],
      ["Description", x.description], ["Outcome", x.outcome ? `${OUTCOME[x.outcome] || x.outcome}: ${x.resolutionNarrative || ""}` : "--"],
      ["Closure evidence", x.closureEvidence || "--"], ["Resolved / approved", [x.resolvedByName || x.resolvedBy, x.approvedByName || x.approvedBy].filter(Boolean).join(" / ") || "--"],
      ...sec.map(k => [k.replace(/^sec/, "Security: ").replace(/([a-z])([A-Z])/g, "$1 $2"), x[k] === "DONE" ? "Done" : x[k] === "NA" ? "Not applicable" : "--"])
    ];
    document.getElementById("aatExcInfo").innerHTML = info.map(([k, v]) => `<div><span>${esc(k)}</span>${esc(v)}</div>`).join("");
    document.getElementById("aatExcHistory").innerHTML = hist.map(h => `
      <tr><td>${esc(dateTime(h.transitionedAt))}</td><td>${esc(h.fromStatus || "--")}</td><td>${esc(h.toStatus)}</td>
          <td>${esc(h.actorName || (h.actorEmployeeId ? "Employee #" + h.actorEmployeeId : "System"))}</td>
          <td>${esc([h.reasonCode, h.reasonText].filter(Boolean).join(": "))}</td></tr>`).join("") || empty(5, "No history.");
    // Actions the caller may take (the procedure decides).
    const acts = [];
    if (x.isInvestigator) {
      if (x.statusCode === "ASSIGNED") acts.push(["START_REVIEW", "Start review", true]);
      if (x.statusCode === "UNDER_REVIEW") acts.push(["AWAIT_EVIDENCE", "Await evidence", false], ["RESOLVE", "Resolve", true]);
      if (x.statusCode === "AWAITING_EVIDENCE") acts.push(["RESUME", "Resume", true]);
      if (x.statusCode === "RESOLVED") acts.push(["CLOSE", "Close", true]);
    }
    if (CAN_APPROVE && x.canDecide) acts.push(["APPROVE", "Approve", true], ["REJECT", "Reject", false]);
    const open = !["CLOSED", "CANCELLED"].includes(x.statusCode);
    if (CAN_APPROVE && open) acts.push(["CANCEL", "Cancel exception", false]);
    document.getElementById("aatExcActions").innerHTML = acts.map(([a, l, p]) => `<button class="pm-button${p ? " primary" : ""}" type="button" data-aat-exc-act="${a}">${l}</button>`).join("")
      + `<button class="pm-button" type="button" data-close-aat="aatExcModal">Close window</button>`;
    document.querySelector('#aatExcActions [data-close-aat]').addEventListener("click", () => { document.getElementById("aatExcModal").hidden = true; });
    const resolving = x.isInvestigator && x.statusCode === "UNDER_REVIEW";
    document.getElementById("aatExcResolveWrap").hidden = !resolving;
    document.getElementById("aatExcSecWrap").hidden = x.category !== "ASSET_LOST";
    ["aatExcOutcome", "aatExcNarrative", "aatExcEvidence"].forEach(i => { document.getElementById(i).value = ""; });
    document.querySelectorAll("[data-aat-sec]").forEach(sel => { sel.value = x[sel.dataset.aatSec] || ""; });
    document.getElementById("aatExcEvidenceLabel").textContent = x.evidenceRequired ? "Closure evidence *" : "Closure evidence";
    const canReassign = CAN_APPROVE && ["OPEN", "ASSIGNED", "UNDER_REVIEW", "AWAITING_EVIDENCE"].includes(x.statusCode);
    document.getElementById("aatExcReassignWrap").hidden = !canReassign;
    if (canReassign) {
      await ensureSettings();
      document.getElementById("aatExcReassign").innerHTML = `<option value="">Select investigator</option>`
        + (state.vs.employees || []).map(e => `<option value="E:${esc(e.employeeId)}">${esc(e.employeeName)}</option>`).join("")
        + (state.vs.teams || []).map(t => `<option value="T:${esc(t.teamId)}">${esc(t.teamName)} (team)</option>`).join("");
    }
    const msg = document.getElementById("aatExcMessage"); msg.hidden = true; msg.textContent = "";
    document.getElementById("aatExcModal").hidden = false;
  }

  async function excAction(action) {
    const x = state.exc, msg = document.getElementById("aatExcMessage");
    if (!x) return;
    const body = { organizationId: state.organizationId, action, expectedRecordVersion: x.recordVersion };
    if (["AWAIT_EVIDENCE", "REJECT", "REASSIGN", "CANCEL"].includes(action)) {
      const q = { AWAIT_EVIDENCE: "What evidence is awaited, and from whom?", REJECT: "Why is the resolution rejected?",
                  REASSIGN: "Why is the exception reassigned?", CANCEL: "Why is the exception cancelled?" }[action];
      if (action === "REASSIGN" && !val("aatExcReassign")) { msg.textContent = "Select the new investigator."; msg.hidden = false; return; }
      body.note = await window.gracUi.promptRequired(q, { title: "Reason required", inputLabel: "Reason" });
      if (!body.note) return;
      if (action === "REASSIGN") body.investigator = val("aatExcReassign");
    } else if (action === "RESOLVE") {
      body.outcome = val("aatExcOutcome") || null;
      body.narrative = val("aatExcNarrative") || null;
      body.closureEvidence = val("aatExcEvidence") || null;
      document.querySelectorAll("[data-aat-sec]").forEach(sel => { body[sel.dataset.aatSec] = sel.value || null; });
    } else if (!await window.gracUi.confirm({ START_REVIEW: "Start the investigation?", RESUME: "Resume the investigation? The SLA restarts with the revised due date.",
                                               APPROVE: "Approve this resolution?", CLOSE: "Close this exception?" }[action] || "Continue?")) return;
    const res = await api("POST", `/exceptions/${x.exceptionId}/action`, body);
    if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
    showMessage(`Exception #${x.exceptionId}: ${(EXC_STATUS[res.data.result] || [res.data.result])[0]}.`, "success");
    await refreshExceptions();
    await openException(x.exceptionId);
  }

  async function ensureSettings() {
    if (state.vs) return true;
    const res = await api("GET", `/exception-settings?organizationId=${state.organizationId}`);
    if (!res.ok) return false;
    state.vs = res.data.data;
    return true;
  }

  async function refreshSettings() {
    const body = document.getElementById("aatVrBody");
    state.vs = null;
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); return; }
    if (!await ensureSettings()) { body.innerHTML = empty(8, "Could not load the settings."); return; }
    const v = state.vs, st = v.settings || {};
    document.getElementById("aatVsAdmin").innerHTML = `<option value="">Not set</option>` + (v.employees || [])
      .map(e => `<option value="${esc(e.employeeId)}"${e.employeeId === st.assetAdministratorEmployeeId ? " selected" : ""}>${esc(e.employeeName)}</option>`).join("");
    document.getElementById("aatVsTeam").innerHTML = `<option value="">Not set</option>` + (v.teams || [])
      .map(t => `<option value="${esc(t.teamId)}"${t.teamId === st.fallbackTeamId ? " selected" : ""}>${esc(t.teamName)}</option>`).join("");
    document.getElementById("aatVsL1").value = st.escalationLevel1Days ?? 7;
    document.getElementById("aatVsL2").value = st.escalationLevel2Days ?? 15;
    document.getElementById("aatVsL3").value = st.escalationLevel3Days ?? 30;
    ["aatVsAdmin", "aatVsTeam", "aatVsL1", "aatVsL2", "aatVsL3"].forEach(id => { document.getElementById(id).disabled = !CAN_EDIT; });
    body.innerHTML = (v.rules || []).map(r => `
      <tr class="${CAN_EDIT ? "pm-row-clickable" : ""}" data-aat-rule="${esc(r.category)}">
        <td>${esc(CATEGORY[r.category] || r.category)}</td><td>${esc(PRIMARY[r.primaryAssignment] || r.primaryAssignment)}</td>
        <td>${esc(r.supportingAssignment || "--")}</td><td>${r.startImmediate ? "Immediate" : esc(r.startSlaDays) + " days"}</td>
        <td>${esc(r.resolutionSlaDays)} days</td><td>${r.closureApprovalRequired ? "Yes" : "No"}</td><td>${r.closureEvidenceRequired ? "Yes" : "No"}</td>
        <td>${r.isOverride ? "Organization" : "BRD default"}</td></tr>`).join("") || empty(8, "No rules.");
  }

  async function saveSettings() {
    const st = (state.vs || {}).settings || {};
    const res = await api("POST", "/exception-settings", {
      organizationId: state.organizationId, assetAdministratorEmployeeId: Number(val("aatVsAdmin")) || null,
      fallbackTeamId: Number(val("aatVsTeam")) || null, escalationLevel1Days: Number(val("aatVsL1")) || 0,
      escalationLevel2Days: Number(val("aatVsL2")) || 0, escalationLevel3Days: Number(val("aatVsL3")) || 0,
      expectedRecordVersion: st.recordVersion ?? null
    });
    if (!res.ok) { showMessage(res.error, "error"); return; }
    showMessage("Exception settings saved.", "success");
    await refreshSettings();
  }

  function openRule(category) {
    const r = ((state.vs || {}).rules || []).find(x => x.category === category);
    if (!r) return;
    state.rule = r;
    document.getElementById("aatRuleTitle").textContent = `Assignment and SLA -- ${CATEGORY[category] || category}`;
    document.getElementById("aatVrPrimary").value = r.primaryAssignment;
    document.getElementById("aatVrSupporting").value = r.supportingAssignment || "";
    document.getElementById("aatVrStart").value = r.startSlaDays;
    document.getElementById("aatVrResolution").value = r.resolutionSlaDays;
    document.getElementById("aatVrImmediate").checked = !!r.startImmediate;
    document.getElementById("aatVrApproval").checked = !!r.closureApprovalRequired;
    document.getElementById("aatVrEvidence").checked = !!r.closureEvidenceRequired;
    document.getElementById("aatVrReset").hidden = !r.isOverride;
    const msg = document.getElementById("aatRuleMessage"); msg.hidden = true; msg.textContent = "";
    document.getElementById("aatRuleModal").hidden = false;
  }

  async function saveRule(reset) {
    const r = state.rule, msg = document.getElementById("aatRuleMessage");
    if (!r) return;
    if (reset && !await window.gracUi.confirm("Return this category to the BRD default rule?")) return;
    const res = await api("POST", "/exception-rules", {
      organizationId: state.organizationId, category: r.category, reset,
      primaryAssignment: val("aatVrPrimary"), supportingAssignment: val("aatVrSupporting") || null,
      startSlaDays: Number(val("aatVrStart")), resolutionSlaDays: Number(val("aatVrResolution")) || 0,
      startImmediate: document.getElementById("aatVrImmediate").checked,
      closureApprovalRequired: document.getElementById("aatVrApproval").checked,
      closureEvidenceRequired: document.getElementById("aatVrEvidence").checked
    });
    if (!res.ok) { msg.textContent = res.error; msg.hidden = false; return; }
    document.getElementById("aatRuleModal").hidden = true;
    showMessage(reset ? "Rule returned to the BRD default." : "Rule saved for this organization.", "success");
    await refreshSettings();
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
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function showMessage(text, kind) {
    const el = document.getElementById("aatMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.classList.toggle("info", kind === "info"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("aatMessage"); el.hidden = true; el.textContent = ""; }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
  function date(v) { return v ? String(v).substring(0, 10) : ""; }   // SQL DATE values: yyyy-mm-dd
  function dateTime(v) { if (!v) return ""; const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString(); }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
