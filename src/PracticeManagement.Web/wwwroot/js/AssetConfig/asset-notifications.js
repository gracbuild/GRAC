// =====================================================================
// Asset Notifications (migration 437) -- BRD 9.1.
// Loaded by asset-notifications.cshtml. Occurrences:
// notifications/occurrences (list), notifications/occurrences/{id}
// (detail: stage schedule + notices), notifications/occurrences/{id}/snooze.
// Notification log: notifications/log. Profiles and escalation matrix:
// notifications/config, notifications/profiles, notifications/matrix.
// Scheduler: notifications/runs, notifications/run. The procedures enforce
// every rule (one active profile per activity and severity, stage shapes,
// recipients, reason + revised date for a snooze, segregation by menu
// grant: snooze needs APPROVE); this screen mirrors them.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/asset-config/notifications";
  const root = document.getElementById("antRoot");
  if (!root) return;
  const CAN_ADD = root.dataset.canAdd === "1";
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";

  const SEVERITY = { LOW: ["Low", "ant-st-ended"], MEDIUM: ["Medium", "ant-st-open"], HIGH: ["High", "ant-st-wait"], CRITICAL: ["Critical", "ant-st-bad"] };
  const CLASS = { INFORMATIONAL: ["Informational", "ant-st-ended"], REMINDER: ["Reminder", "ant-st-wait"],
                  ESCALATION: ["Escalation", "ant-st-bad"], CRITICAL: ["Critical", "ant-st-bad"] };
  const OCC_STATUS = { OPEN: ["Open", "ant-st-open"], COMPLETED: ["Completed", "ant-st-active"], SUPERSEDED: ["Superseded", "ant-st-ended"] };
  const DELIVERY = { Pending: "ant-st-wait", Sent: "ant-st-active", Failed: "ant-st-bad", Suppressed: "ant-st-ended" };
  const ACK = { NONE: "None", READ: "Read", ACTION: "Action", MANAGER: "Manager confirms" };
  const KIND = { REMINDER: "Reminder", DUE: "Due", ESCALATION: "Escalation" };
  const RUN_RESULT = { RUNNING: "ant-st-wait", COMPLETED: "ant-st-active", COMPLETED_WITH_ERRORS: "ant-st-wait", FAILED: "ant-st-bad", SKIPPED: "ant-st-ended" };

  const state = { organizationId: null, mainTab: "OCCURRENCES", config: null, occPager: null, logPager: null,
                  occurrence: null, profile: null, stages: [], matrixSeverity: null, matrixEntries: [] };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.occPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "antOccPager", onChange: refreshOccurrences }) : null;
    state.logPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "antLogPager", onChange: refreshLog }) : null;
    bind();
    await populateOrgs();
    const sel = document.getElementById("antOrg");
    window.gracOrgPref.apply(sel);   // 2026-10-06: last-picked org, else lowest id
    // 451: opened from the Asset & Contract dashboard -- organization, tab and filter (Shared/dashboard-drill.js).
    const dashDrill = window.__pmDrill ? window.__pmDrill.read() : null;
    window.__pmDrill?.preselectFor(dashDrill, sel, { OCCURRENCES: { status: "antOccStatus" }, LOG: { status: "antLogStatus" } });
    await changeOrg(Number(sel.value) || null);
    window.__pmDrill?.showOnPage("antRoot", "data-ant-main", dashDrill);
  }

  async function populateOrgs() {
    const sel = document.getElementById("antOrg");
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
    document.getElementById("antOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.querySelectorAll("[data-ant-main]").forEach(b => b.addEventListener("click", () => selectMainTab(b.dataset.antMain)));
    document.querySelectorAll("[data-close-ant]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeAnt).hidden = true; }));
    let t1 = null, t2 = null;
    document.getElementById("antOccSearch").addEventListener("input", () => { clearTimeout(t1); t1 = setTimeout(() => { state.occPager?.reset(true); refreshOccurrences(); }, 300); });
    ["antOccStatus", "antOccActivity"].forEach(id => document.getElementById(id).addEventListener("change", () => { state.occPager?.reset(true); refreshOccurrences(); }));
    document.getElementById("antOccRefresh").addEventListener("click", () => refreshOccurrences());
    document.getElementById("antOccBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-ant-occ]");
      if (tr) openOccurrence(Number(tr.dataset.antOcc));
    });
    document.getElementById("antLogSearch").addEventListener("input", () => { clearTimeout(t2); t2 = setTimeout(() => { state.logPager?.reset(true); refreshLog(); }, 300); });
    ["antLogStatus", "antLogActivity", "antLogClass"].forEach(id => document.getElementById(id).addEventListener("change", () => { state.logPager?.reset(true); refreshLog(); }));
    document.getElementById("antSnoozeForm").addEventListener("submit", ev => { ev.preventDefault(); snooze(false); });
    document.getElementById("antResume").addEventListener("click", () => snooze(true));
    document.getElementById("antNewProfile")?.addEventListener("click", () => openProfile(null));
    document.getElementById("antProfileBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-ant-profile]");
      if (tr) openProfile(Number(tr.dataset.antProfile));
    });
    document.getElementById("antPfActivity").addEventListener("change", () => {
      if (!state.profile) { copyDefaultStages(); renderStages(); }
      syncTrigger();
    });
    document.getElementById("antPfAddStage").addEventListener("click", () => {
      readStages();
      state.stages.push({ stageKind: "REMINDER", offsetDays: 7, escalationLevel: 0, notificationClass: "REMINDER", recipients: [] });
      renderStages();
    });
    document.getElementById("antPfStagesBody").addEventListener("click", ev => {
      const rm = ev.target.closest("button[data-ant-stage-remove]");
      const rr = ev.target.closest("button[data-ant-rcp-remove]");
      if (rm) { readStages(); state.stages.splice(Number(rm.dataset.antStageRemove), 1); renderStages(); }
      else if (rr) {
        readStages();
        const [s, r] = rr.dataset.antRcpRemove.split(":").map(Number);
        state.stages[s].recipients.splice(r, 1);
        renderStages();
      }
    });
    document.getElementById("antPfStagesBody").addEventListener("change", ev => {
      const add = ev.target.closest("select[data-ant-rcp-add]");
      if (add) {
        readStages();
        const s = state.stages[Number(add.dataset.antRcpAdd)], v = add.value;
        if (v) {
          const rcp = v.startsWith("ROLE:") ? { recipientCode: "ROLE", roleId: Number(v.substring(5)) } : { recipientCode: v, roleId: null };
          if (!s.recipients.some(x => x.recipientCode === rcp.recipientCode && (x.roleId || null) === (rcp.roleId || null))) s.recipients.push(rcp);
        }
        renderStages();
      } else if (ev.target.closest("select[data-ant-kind]")) { readStages(); renderStages(); }
    });
    document.getElementById("antProfileForm").addEventListener("submit", ev => { ev.preventDefault(); saveProfile(); });
    document.getElementById("antMatrixBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-ant-matrix]");
      if (b) openMatrix(b.dataset.antMatrix);
    });
    document.getElementById("antMxAdd").addEventListener("click", () => { readMatrix(); state.matrixEntries.push({ escalationLevel: 0, recipientCode: "ACTIVITY_OWNER", roleId: null }); renderMatrixEntries(); });
    document.getElementById("antMxBody").addEventListener("click", ev => {
      const b = ev.target.closest("button[data-ant-mx-remove]");
      if (b) { readMatrix(); state.matrixEntries.splice(Number(b.dataset.antMxRemove), 1); renderMatrixEntries(); }
    });
    document.getElementById("antMatrixForm").addEventListener("submit", ev => { ev.preventDefault(); saveMatrix(); });
    document.getElementById("antRunNow")?.addEventListener("click", runNow);
    document.getElementById("antRunRefresh").addEventListener("click", refreshRuns);
  }

  async function changeOrg(id) {
    state.organizationId = id;
    state.config = null;
    hideMessage();
    state.occPager?.reset(true);
    state.logPager?.reset(true);
    if (id) await loadConfig();
    await selectMainTab(state.mainTab);
  }

  async function selectMainTab(name) {
    state.mainTab = name;
    document.querySelectorAll("[data-ant-main]").forEach(x => { const on = x.dataset.antMain === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-ant-mainpanel]").forEach(p => { p.hidden = p.dataset.antMainpanel !== name; });
    if (name === "LOG") await refreshLog();
    else if (name === "PROFILES") { await loadConfig(); renderProfiles(); }
    else if (name === "MATRIX") { await loadConfig(); renderMatrix(); }
    else if (name === "SCHEDULER") await refreshRuns();
    else await refreshOccurrences();
  }

  async function loadConfig() {
    if (!state.organizationId) return;
    const res = await api("GET", `/config?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.config = res.data.data;
    const opts = `<option value="">All activities</option>` + state.config.activities.map(a => `<option value="${esc(a.activityCode)}">${esc(a.activityName)}</option>`).join("");
    ["antOccActivity", "antLogActivity"].forEach(id => {
      const el = document.getElementById(id), keep = el.value;
      el.innerHTML = opts; el.value = keep;
    });
  }

  // ------------------------------------------------------------------ occurrences
  async function refreshOccurrences() {
    const body = document.getElementById("antOccBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.occPager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId, status: val("antOccStatus"),
      pageNumber: state.occPager ? state.occPager.page() : 1, pageSize: state.occPager ? state.occPager.size() : 25 });
    if (val("antOccActivity")) qs.set("activityCode", val("antOccActivity"));
    if (val("antOccSearch")) qs.set("search", val("antOccSearch"));
    const res = await api("GET", `/occurrences?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.occPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.occPager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(o => {
      const [sl, sc] = SEVERITY[o.severityCode] || [o.severityCode, ""];
      const [ol, oc] = OCC_STATUS[o.status] || [o.status, ""];
      const days = o.daysToTrigger;
      return `<tr data-ant-occ="${o.occurrenceId}">
        <td>${esc(o.activityName)}${o.status !== "OPEN" ? `<div><span class="ant-chip ${oc}">${esc(ol)}</span></div>` : ""}</td>
        <td>${esc(o.objectRef || "--")}<div class="ant-note">${esc(o.objectTitle || "")}</div></td>
        <td>${esc(date(o.triggerDate))}<div class="ant-note">${days < 0 ? esc(-days) + " days ago" : days === 0 ? "today" : "in " + esc(days) + " days"}</div></td>
        <td><span class="ant-chip ${sc}">${esc(sl)}</span></td>
        <td>${o.lastStageDate ? esc(date(o.lastStageDate)) + `<div class="ant-note">${esc(stageText(o.lastStageKind, o.lastStageOffsetDays, o.escalationLevel))}</div>` : "--"}</td>
        <td>${esc(date(o.nextStageDate) || "--")}</td>
        <td>${o.snoozedUntil ? esc(date(o.snoozedUntil)) + `<div class="ant-note">${esc(o.snoozeReason || "")}</div>` : "--"}</td>
        <td>${esc(o.notificationCount)}</td></tr>`;
    }).join("") || empty(8, "No occurrences. The scheduler opens them as dates come into range.");
  }

  async function openOccurrence(id) {
    const res = await api("GET", `/occurrences/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error, "error"); return; }
    state.occurrence = res.data.data;
    renderOccurrence();
    document.getElementById("antOccModal").hidden = false;
  }

  function renderOccurrence() {
    const d = state.occurrence, o = d.occurrence;
    const [sl, sc] = SEVERITY[o.severityCode] || [o.severityCode, ""];
    const [ol, oc] = OCC_STATUS[o.status] || [o.status, ""];
    document.getElementById("antOccTitle").textContent = `${o.activityName} - ${o.objectRef || ""}`;
    document.getElementById("antOccInfo").innerHTML = info([
      ["Status", `<span class="ant-chip ${oc}">${esc(ol)}</span>`, true], ["Subject", o.objectTitle],
      ["Date", `${date(o.triggerDate)} (${(o.triggerBasis || "").replace(/_/g, " ").toLowerCase()})`], ["Trigger", o.triggerDescription],
      ["Severity", `<span class="ant-chip ${sc}">${esc(sl)}</span>`, true], ["Escalation level", o.escalationLevel],
      ["Profile", o.profileName ? `${o.profileName} (version ${o.profileVersion})` : "No active profile -- nothing is sent"],
      ["Acknowledgement", ACK[o.ackMode] || o.ackMode || "--"], ["Channels", o.channels || "--"],
      ["Opened", dateTime(o.openedDt)], ["Last notice", o.lastNotifiedDt ? dateTime(o.lastNotifiedDt) : "--"],
      ["Snoozed until", o.snoozedUntil ? `${date(o.snoozedUntil)} - ${o.snoozeReason || ""} (${o.snoozedByName || o.snoozedBy || ""})` : "--"],
      ["Closed", o.closedDt ? `${dateTime(o.closedDt)} - ${o.closeReason || ""}` : "--"],
      ["Occurrence key", o.occurrenceKey]
    ]);
    document.getElementById("antOccStagesBody").innerHTML = (d.stages || []).map(s => {
      const [cl, cc] = CLASS[s.notificationClass] || [s.notificationClass, ""];
      return `<tr><td>${esc(stageText(s.stageKind, s.offsetDays, s.escalationLevel))}</td><td><span class="ant-chip ${cc}">${esc(cl)}</span></td>
        <td>${esc(date(s.stageDate))}</td><td>${s.reached ? "Yes" : "No"}</td><td>${esc(s.sentCount)}</td></tr>`;
    }).join("") || empty(5, "No active profile for this activity.");
    document.getElementById("antOccNoticesBody").innerHTML = (d.notifications || []).map(n => `<tr>
        <td>${esc(dateTime(n.enteredDt))}</td><td>${esc(stageText(n.stageKind, n.stageOffsetDays, n.escalationLevel))}</td>
        <td>${esc(n.recipientName || "(nobody)")}<div class="ant-note">${esc(reason(n.recipientReasonCode, n.roleName))}</div></td>
        <td><span class="ant-chip ${DELIVERY[n.statusCode] || ""}">${esc(n.statusCode)}</span>${n.failureReason ? `<div class="ant-note">${esc(n.failureReason)}</div>` : ""}</td>
        <td>${esc(ackText(n))}</td><td>${esc(n.profileVersion)}</td></tr>`).join("") || empty(6, "No notice recorded yet.");
    const form = document.getElementById("antSnoozeForm");
    form.hidden = !(CAN_APPROVE && o.status === "OPEN");
    document.getElementById("antSnoozeDate").value = date(o.snoozedUntil);
    document.getElementById("antSnoozeReason").value = "";
    document.getElementById("antResume").hidden = !o.snoozedUntil;
    hide("antOccMessage");
  }

  async function snooze(resume) {
    const o = state.occurrence.occurrence;
    const reasonText = val("antSnoozeReason");
    if (!reasonText) { show("antOccMessage", "Enter the reason."); return; }
    const until = resume ? null : val("antSnoozeDate");
    if (!resume && !until) { show("antOccMessage", "Select the revised date."); return; }
    const res = await api("POST", `/occurrences/${o.occurrenceId}/snooze`, {
      organizationId: state.organizationId, snoozedUntil: until, reason: reasonText, expectedRecordVersion: o.recordVersion
    });
    if (!res.ok) { show("antOccMessage", res.error); return; }
    await openOccurrence(o.occurrenceId);
    show("antOccMessage", resume ? "Resumed." : "Snoozed.", "success");
    await refreshOccurrences();
  }

  // ------------------------------------------------------------------ notification log
  async function refreshLog() {
    const body = document.getElementById("antLogBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.logPager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.logPager ? state.logPager.page() : 1, pageSize: state.logPager ? state.logPager.size() : 25 });
    if (val("antLogStatus")) qs.set("statusCode", val("antLogStatus"));
    if (val("antLogActivity")) qs.set("activityCode", val("antLogActivity"));
    if (val("antLogClass")) qs.set("notificationClass", val("antLogClass"));
    if (val("antLogSearch")) qs.set("search", val("antLogSearch"));
    const res = await api("GET", `/log?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.logPager?.clear(); return; }
    const rows = res.data.data.rows || [];
    state.logPager?.setTotal(res.data.data.totalRows, rows.length);
    body.innerHTML = rows.map(n => {
      const [cl, cc] = CLASS[n.notificationClass] || [n.notificationClass, ""];
      return `<tr><td>${esc(dateTime(n.enteredDt))}</td><td><span class="ant-chip ${cc}">${esc(cl)}</span></td>
        <td>${esc(n.activityName)} - ${esc(n.objectRef || "")}<div class="ant-note">${esc(n.objectTitle || "")}</div></td>
        <td>${esc(n.recipientName || "(nobody)")}<div class="ant-note">${esc(reason(n.recipientReasonCode, n.roleName))}</div></td>
        <td>${esc(stageText(n.stageKind, n.stageOffsetDays, n.escalationLevel))}<div class="ant-note">${esc(date(n.stageDate))}</div></td>
        <td>${esc(n.channels)}</td>
        <td><span class="ant-chip ${DELIVERY[n.statusCode] || ""}">${esc(n.statusCode)}</span>
            ${n.attemptCount ? `<div class="ant-note">${esc(n.attemptCount)} attempt(s)</div>` : ""}${n.failureReason ? `<div class="ant-note">${esc(n.failureReason)}</div>` : ""}</td>
        <td>${esc(ackText(n))}</td></tr>`;
    }).join("") || empty(8, "No notices recorded.");
  }

  // ------------------------------------------------------------------ profiles
  function renderProfiles() {
    const body = document.getElementById("antProfileBody"), c = state.config;
    if (!c) { body.innerHTML = empty(8, state.organizationId ? "Could not load the configuration." : "Select an organization."); return; }
    body.innerHTML = c.profiles.map(p => {
      const stages = c.stages.filter(s => s.profileId === p.profileId);
      const [sl, sc] = p.severityCode ? (SEVERITY[p.severityCode] || [p.severityCode, ""]) : ["Default", "ant-st-open"];
      const channels = [p.channelInApp ? "In-app" : null, p.channelEmail ? "Email" : null, p.channelWebhook ? "Webhook" : null].filter(Boolean).join(", ");
      return `<tr data-ant-profile="${p.profileId}">
        <td>${esc(p.activityName)}${p.sourceAvailable ? "" : `<div class="ant-note">source later</div>`}</td>
        <td>${esc(p.profileName)}<div class="ant-note">${esc(p.ownerName || "")}</div></td>
        <td><span class="ant-chip ${sc}">${esc(sl)}</span></td>
        <td>${esc(stagesSummary(stages))}</td><td>${esc(ACK[p.ackMode] || p.ackMode)}</td><td>${esc(channels)}</td>
        <td><span class="ant-chip ${p.isActive ? "ant-st-active" : "ant-st-ended"}">${p.isActive ? "Active" : "Inactive"}</span>
            ${p.effectiveFrom || p.effectiveTo ? `<div class="ant-note">${esc(date(p.effectiveFrom) || "...")} to ${esc(date(p.effectiveTo) || "...")}</div>` : ""}</td>
        <td>${esc(p.versionNo)}</td></tr>`;
    }).join("") || empty(8, "No profiles.");
  }

  function stagesSummary(stages) {
    const r = stages.filter(s => s.stageKind === "REMINDER").map(s => s.offsetDays);
    const due = stages.some(s => s.stageKind === "DUE");
    const e = stages.filter(s => s.stageKind === "ESCALATION").map(s => `${s.offsetDays}(L${s.escalationLevel})`);
    return [r.length ? `Reminders ${r.join(", ")} days before` : null, due ? "due" : null,
            e.length ? `escalations ${e.join(", ")} days after` : null].filter(Boolean).join("; ") || "--";
  }

  function openProfile(id) {
    const c = state.config;
    if (!c) return;
    const p = id ? c.profiles.find(x => x.profileId === id) : null;
    const editable = p ? CAN_EDIT : CAN_ADD;
    state.profile = p;
    document.getElementById("antProfileTitle").textContent = p ? `Notification profile - ${p.profileName}` : "New notification profile";
    const act = document.getElementById("antPfActivity");
    act.innerHTML = c.activities.map(a => `<option value="${esc(a.activityCode)}">${esc(a.activityName)}</option>`).join("");
    act.value = p ? p.activityCode : c.activities[0]?.activityCode || "";
    act.disabled = !!p;
    document.getElementById("antPfOwner").innerHTML = `<option value="">--</option>` + c.employees.map(e => `<option value="${e.employeeId}">${esc(e.employeeName)}</option>`).join("");
    document.getElementById("antPfName").value = p ? p.profileName : "";
    document.getElementById("antPfSeverity").value = p ? (p.severityCode || "") : "HIGH";
    document.getElementById("antPfOwner").value = p && p.ownerEmployeeId ? String(p.ownerEmployeeId) : "";
    document.getElementById("antPfFrom").value = p ? date(p.effectiveFrom) : "";
    document.getElementById("antPfTo").value = p ? date(p.effectiveTo) : "";
    document.getElementById("antPfAck").value = p ? p.ackMode : "READ";
    document.getElementById("antPfInApp").checked = p ? !!p.channelInApp : true;
    document.getElementById("antPfEmail").checked = p ? !!p.channelEmail : false;
    document.getElementById("antPfWebhook").checked = p ? !!p.channelWebhook : false;
    document.getElementById("antPfActive").checked = p ? !!p.isActive : true;
    document.getElementById("antPfSnooze").checked = p ? !!p.snoozeAllowed : true;
    document.getElementById("antPfWorkdays").checked = p ? !!p.workingDaysOnly : false;
    copyDefaultStages();
    renderStages();
    syncTrigger();
    document.querySelectorAll("#antProfileForm input, #antProfileForm select, #antProfileForm textarea, #antPfAddStage").forEach(el => {
      if (el.id !== "antPfActivity") el.disabled = !editable;
    });
    document.getElementById("antPfSave").hidden = !editable;
    hide("antPfMessage");
    document.getElementById("antProfileModal").hidden = false;
  }

  // The stages of the profile; a new override starts as a copy of the
  // active default profile of the activity.
  function copyDefaultStages() {
    const c = state.config, p = state.profile;
    const src = p || c.profiles.find(x => x.activityCode === val("antPfActivity") && !x.severityCode && x.isActive);
    state.stages = src ? c.stages.filter(s => s.profileId === src.profileId).map(s => ({
      stageKind: s.stageKind, offsetDays: s.offsetDays, escalationLevel: s.escalationLevel, notificationClass: s.notificationClass,
      recipients: c.recipients.filter(r => r.stageId === s.stageId).map(r => ({ recipientCode: r.recipientCode, roleId: r.roleId || null }))
    })) : [];
  }

  function syncTrigger() {
    const a = (state.config?.activities || []).find(x => x.activityCode === val("antPfActivity"));
    document.getElementById("antPfTrigger").textContent = a
      ? `Date: ${a.triggerDescription} Typical recipients: ${a.typicalRecipients}.${a.sourceAvailable ? "" : " " + (a.sourceNote || "")}`
      : "";
  }

  function recipientOptions() {
    const c = state.config;
    return `<option value="">Add recipient...</option>` +
      c.recipientTypes.filter(t => t.recipientCode !== "ROLE").map(t => `<option value="${esc(t.recipientCode)}">${esc(t.recipientName)}</option>`).join("") +
      c.roles.map(r => `<option value="ROLE:${r.roleId}">Role: ${esc(r.roleName)}</option>`).join("");
  }

  function recipientLabel(r) {
    if (r.recipientCode === "ROLE") return `Role: ${(state.config.roles.find(x => x.roleId === r.roleId) || {}).roleName || r.roleId}`;
    return (state.config.recipientTypes.find(t => t.recipientCode === r.recipientCode) || {}).recipientName || r.recipientCode;
  }

  function renderStages() {
    const opts = recipientOptions();
    document.getElementById("antPfStagesBody").innerHTML = state.stages.map((s, i) => `<tr data-ant-stage="${i}">
        <td><select data-ant-kind>${Object.entries(KIND).map(([k, l]) => `<option value="${k}"${k === s.stageKind ? " selected" : ""}>${l}</option>`).join("")}</select></td>
        <td><input type="number" class="ant-stage-input" data-ant-days min="0" max="730" value="${s.stageKind === "DUE" ? 0 : esc(s.offsetDays)}"${s.stageKind === "DUE" ? " disabled" : ""} /></td>
        <td><select data-ant-level${s.stageKind === "ESCALATION" ? "" : " disabled"}>${[1, 2, 3].map(l => `<option value="${l}"${l === Number(s.escalationLevel) ? " selected" : ""}>${l}</option>`).join("")}</select></td>
        <td><select data-ant-class>${Object.entries(CLASS).map(([k, [l]]) => `<option value="${k}"${k === s.notificationClass ? " selected" : ""}>${l}</option>`).join("")}</select></td>
        <td>${s.recipients.map((r, j) => `<span class="ant-tag">${esc(recipientLabel(r))}<button type="button" data-ant-rcp-remove="${i}:${j}" aria-label="Remove">&times;</button></span>`).join("")}
            <select data-ant-rcp-add="${i}">${opts}</select></td>
        <td><button type="button" class="pm-button" data-ant-stage-remove="${i}">Remove</button></td></tr>`).join("")
      || empty(6, "No stages. Add at least one.");
  }

  // Reads the stage table back into state.stages (before any re-render).
  function readStages() {
    document.querySelectorAll("#antPfStagesBody tr[data-ant-stage]").forEach(tr => {
      const s = state.stages[Number(tr.dataset.antStage)];
      s.stageKind = tr.querySelector("[data-ant-kind]").value;
      s.offsetDays = s.stageKind === "DUE" ? 0 : Number(tr.querySelector("[data-ant-days]").value || 0);
      s.escalationLevel = s.stageKind === "ESCALATION" ? Number(tr.querySelector("[data-ant-level]").value || 1) : 0;
      s.notificationClass = tr.querySelector("[data-ant-class]").value;
    });
  }

  async function saveProfile() {
    readStages();
    const p = state.profile;
    const res = await api("POST", "/profiles", {
      organizationId: state.organizationId, profileId: p ? p.profileId : null, activityCode: val("antPfActivity"),
      profileName: val("antPfName"), severityCode: val("antPfSeverity") || null, ownerEmployeeId: Number(val("antPfOwner")) || null,
      effectiveFrom: val("antPfFrom") || null, effectiveTo: val("antPfTo") || null,
      isActive: document.getElementById("antPfActive").checked, ackMode: val("antPfAck"),
      channelInApp: document.getElementById("antPfInApp").checked, channelEmail: document.getElementById("antPfEmail").checked,
      channelWebhook: document.getElementById("antPfWebhook").checked, snoozeAllowed: document.getElementById("antPfSnooze").checked,
      workingDaysOnly: document.getElementById("antPfWorkdays").checked, stages: state.stages,
      expectedRecordVersion: p ? p.recordVersion : null
    });
    if (!res.ok) { show("antPfMessage", res.error); return; }
    document.getElementById("antProfileModal").hidden = true;
    await loadConfig();
    renderProfiles();
    showMessage("Profile saved. Later notices record the new profile version.", "success");
  }

  // ------------------------------------------------------------------ escalation matrix
  function renderMatrix() {
    const body = document.getElementById("antMatrixBody"), c = state.config;
    if (!c) { body.innerHTML = empty(6, state.organizationId ? "Could not load the configuration." : "Select an organization."); return; }
    body.innerHTML = Object.keys(SEVERITY).map(sev => {
      const [sl, sc] = SEVERITY[sev];
      const cell = lvl => c.matrix.filter(m => m.severityCode === sev && m.escalationLevel === lvl)
        .map(m => `<span class="ant-tag">${esc(recipientLabel(m))}</span>`).join("") || `<span class="ant-note">--</span>`;
      return `<tr><td><span class="ant-chip ${sc}">${esc(sl)}</span></td><td>${cell(0)}</td><td>${cell(1)}</td><td>${cell(2)}</td><td>${cell(3)}</td>
        <td>${CAN_EDIT ? `<button type="button" class="pm-button" data-ant-matrix="${sev}">Edit</button>` : ""}</td></tr>`;
    }).join("");
  }

  function openMatrix(sev) {
    state.matrixSeverity = sev;
    state.matrixEntries = state.config.matrix.filter(m => m.severityCode === sev)
      .map(m => ({ escalationLevel: m.escalationLevel, recipientCode: m.recipientCode, roleId: m.roleId || null }));
    document.getElementById("antMatrixTitle").textContent = `Escalation matrix - ${SEVERITY[sev][0]}`;
    renderMatrixEntries();
    hide("antMxMessage");
    document.getElementById("antMatrixModal").hidden = false;
  }

  function renderMatrixEntries() {
    const c = state.config;
    const rcpOpts = sel => c.recipientTypes.filter(t => t.recipientCode !== "ROLE")
        .map(t => `<option value="${esc(t.recipientCode)}"${sel === t.recipientCode ? " selected" : ""}>${esc(t.recipientName)}</option>`).join("") +
      c.roles.map(r => `<option value="ROLE:${r.roleId}"${sel === "ROLE:" + r.roleId ? " selected" : ""}>Role: ${esc(r.roleName)}</option>`).join("");
    document.getElementById("antMxBody").innerHTML = state.matrixEntries.map((m, i) => {
      const sel = m.recipientCode === "ROLE" ? "ROLE:" + m.roleId : m.recipientCode;
      return `<tr data-ant-mx="${i}">
        <td><select data-ant-mx-level>${[0, 1, 2, 3].map(l => `<option value="${l}"${l === Number(m.escalationLevel) ? " selected" : ""}>${l === 0 ? "Initial (0)" : "Escalation " + l}</option>`).join("")}</select></td>
        <td><select data-ant-mx-rcp>${rcpOpts(sel)}</select></td>
        <td><button type="button" class="pm-button" data-ant-mx-remove="${i}">Remove</button></td></tr>`;
    }).join("") || empty(3, "No entries for this severity.");
  }

  function readMatrix() {
    document.querySelectorAll("#antMxBody tr[data-ant-mx]").forEach(tr => {
      const m = state.matrixEntries[Number(tr.dataset.antMx)], v = tr.querySelector("[data-ant-mx-rcp]").value;
      m.escalationLevel = Number(tr.querySelector("[data-ant-mx-level]").value);
      if (v.startsWith("ROLE:")) { m.recipientCode = "ROLE"; m.roleId = Number(v.substring(5)); } else { m.recipientCode = v; m.roleId = null; }
    });
  }

  async function saveMatrix() {
    readMatrix();
    const res = await api("POST", "/matrix", { organizationId: state.organizationId, severityCode: state.matrixSeverity, entries: state.matrixEntries });
    if (!res.ok) { show("antMxMessage", res.error); return; }
    document.getElementById("antMatrixModal").hidden = true;
    await loadConfig();
    renderMatrix();
    showMessage("Escalation matrix saved.", "success");
  }

  // ------------------------------------------------------------------ scheduler
  async function refreshRuns() {
    const body = document.getElementById("antRunBody");
    if (!state.organizationId) { body.innerHTML = empty(10, "Select an organization."); return; }
    body.innerHTML = empty(10, "Loading...");
    const res = await api("GET", `/runs?organizationId=${state.organizationId}`);
    if (!res.ok) { body.innerHTML = empty(10, res.error); return; }
    body.innerHTML = (res.data.data || []).map(r => {
      const all = !!r.allOrganizations, n = v => all ? "--" : esc(v ?? 0);
      return `<tr><td>${esc(dateTime(r.startedDt))}</td><td>${esc(dateTime(r.finishedDt) || "--")}</td>
        <td>${esc(r.triggerCode === "MANUAL" ? "Run now" : "Scheduled")}${all ? `<div class="ant-note">every organization</div>` : ""}</td>
        <td><span class="ant-chip ${RUN_RESULT[r.result] || ""}">${esc(statusLabel(r.result))}</span></td>
        <td>${n(r.renewalsStarted)}</td><td>${n(r.attestationsGenerated)}</td>
        <td>${all ? "--" : esc(r.occurrencesOpened ?? 0) + " / " + esc(r.occurrencesClosed ?? 0)}</td><td>${n(r.tasksCreated)}</td><td>${n(r.notificationsQueued)}</td>
        <td>${n(r.errorCount)}${!all && r.errorText ? `<div class="ant-note" style="white-space:pre-wrap;">${esc(r.errorText)}</div>` : ""}</td></tr>`;
    }).join("") || empty(10, "The scheduler has not run yet.");
  }

  async function runNow() {
    if (!await window.gracUi.confirm("Run the scheduler now for this organization? Contract dates are applied, renewal occurrences and periodic attestations started when due, and the reminders and escalations reached are recorded.")) return;
    const btn = document.getElementById("antRunNow");
    btn.disabled = true;
    const res = await api("POST", "/run", { organizationId: state.organizationId });
    btn.disabled = false;
    if (!res.ok) { showMessage(res.error, "error"); return; }
    const r = res.data.data || {};
    showMessage(r.result === "SKIPPED" ? (r.errorText || "Another scheduler run is in progress.")
      : `Run ${statusLabel(r.result)}: ${r.notificationsQueued || 0} notice(s), ${r.renewalsStarted || 0} renewal(s) started, ${r.attestationsGenerated || 0} attestation(s), ${r.tasksCreated || 0} activity task(s), ${r.errorCount || 0} error(s).`,
      r.errorCount ? "error" : "success");
    await refreshRuns();
  }

  // ------------------------------------------------------------------ helpers
  function stageText(kind, days, level) {
    if (!kind) return "";
    if (kind === "REMINDER") return `Reminder, ${days} day(s) before`;
    if (kind === "DUE") return "Due date";
    return `Escalation ${level}, ${days ? days + " day(s) after" : "on the date"}`;
  }
  function reason(code, roleName) {
    if (code === "ROLE") return `Role: ${roleName || ""}`;
    if (code === "UNRESOLVED") return "No recipient resolved";
    const t = (state.config?.recipientTypes || []).find(x => x.recipientCode === code);
    return t ? t.recipientName : (code || "");
  }
  function ackText(n) {
    if (n.managerAckDt) return `Confirmed by ${n.managerAckByName || "manager"} ${dateTime(n.managerAckDt)}`;
    if (n.acknowledgedDt) return `Acknowledged ${dateTime(n.acknowledgedDt)}${n.ackMode === "MANAGER" ? ", awaiting manager" : ""}`;
    if (n.readDt) return `Read ${dateTime(n.readDt)}`;
    return n.ackMode === "NONE" ? "--" : "Not yet";
  }
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
  function info(items) {
    return items.map(([k, v, html]) => `<div><span>${esc(k)}</span>${html ? v : esc(v ?? "--")}</div>`).join("");
  }
  function statusLabel(code) { return code ? code.replace(/_/g, " ").toLowerCase().replace(/^./, c => c.toUpperCase()) : ""; }
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function showMessage(text, kind) {
    const el = document.getElementById("antMessage");
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.hidden = !text;
  }
  function hideMessage() { const el = document.getElementById("antMessage"); el.hidden = true; el.textContent = ""; }
  function show(id, text, kind) {
    const el = document.getElementById(id);
    el.textContent = text || ""; el.classList.toggle("success", kind === "success"); el.hidden = !text;
  }
  function hide(id) { const el = document.getElementById(id); el.hidden = true; el.textContent = ""; el.classList.remove("success"); }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
  function date(v) { return v ? String(v).substring(0, 10) : ""; }   // SQL DATE values: yyyy-mm-dd
  function dateTime(v) { if (!v) return ""; const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString(); }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
