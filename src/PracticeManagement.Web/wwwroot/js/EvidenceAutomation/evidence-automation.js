// =====================================================================
// Evidence Automation (migration 530 -- plan Part A, Phase 1).
// Loaded by evidence-automation.cshtml. Backend: practice/api/evidence-automation
//   GET  lookups?organizationId                         types, employees, fileDropEnabled
//   GET  obligations?organizationId&search              obligations the caller may bind
//   GET  obligations/{id}/evidence?organizationId        evidence rows of one obligation
//   GET  bindings?organizationId&search&channel&health&status&pageNumber&pageSize
//   GET  bindings/{id}?organizationId                    source + latest events
//   POST bindings | bindings/{id}/save                   create / edit
//   POST bindings/{id}/status { organizationId, action } Pause / Resume / Retire
//   POST bindings/{id}/token  { organizationId }         token -- shown ONCE
//   GET  events?organizationId&bindingId&status&result&search&pageNumber&pageSize
//   GET  events/{id}/targets?organizationId              where it may be attached
//   POST events/{id}/accept { organizationId, targetType, targetId, note }
//   POST events/{id}/reject { organizationId, note }
// Files open through the Evidence Center (practice/api/evidence-center/files).
// What the caller may see and change is decided by the procedures; the
// buttons only mirror the screen permissions.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/evidence-automation";
  const root = document.getElementById("eaRoot");
  if (!root) return;
  const CAN_ADD    = root.dataset.canAdd === "1";
  const CAN_EDIT   = root.dataset.canEdit === "1";
  const CAN_DELETE = root.dataset.canDelete === "1";
  const CSRF = document.querySelector('meta[name="csrf-token"]')?.content || "";

  // The Api returns column-name rows (PascalCase keys); read either case.
  const F = (o, k) => o == null ? undefined : (o[k] !== undefined ? o[k] : o[k.charAt(0).toUpperCase() + k.slice(1)]);

  const HEALTH = {
    OnTrack: ["On track", "ea-ok"], Waiting: ["Waiting for first evidence", ""], Overdue: ["Overdue", "ea-bad"],
    Failing: ["Last result failed", "ea-warn"], Paused: ["Paused", ""], Retired: ["Retired", ""]
  };
  const RESULT = { Pass: ["Pass", "ea-ok"], Fail: ["Fail", "ea-bad"], Unknown: ["Unknown", ""] };
  const STATUS = { Proposed: ["Waiting for review", "ea-warn"], Accepted: ["Accepted", "ea-ok"], Rejected: ["Rejected", ""] };
  const CADENCE = { None: "Not scheduled", Daily: "Daily", Weekly: "Weekly", Monthly: "Monthly",
                    Quarterly: "Quarterly", HalfYearly: "Half-yearly", Yearly: "Yearly" };
  const CHANNEL = { Webhook: "Webhook", FileDrop: "File drop", Email: "Email" };

  const state = { organizationId: null, tab: "RECEIVED", evPager: null, bdPager: null,
                  lookups: { types: [], employees: [], fileDropEnabled: false, emailEnabled: false, emailAddress: null },
                  binding: null, editId: null, event: null, targets: [] };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.evPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "eaEvPager", onChange: loadEvents }) : null;
    state.bdPager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "eaBdPager", onChange: loadBindings }) : null;
    bind();
    await populateOrgs();
    const sel = document.getElementById("eaOrg");
    window.gracOrgPref?.apply(sel);   // last-picked org, else lowest id
    await changeOrg(Number(sel.value) || null);
  }

  async function populateOrgs() {
    const sel = document.getElementById("eaOrg");
    try {
      const r = await fetch(U("/practice/api/organizations/allowed"), { credentials: "same-origin" });
      const b = r.ok ? await r.json() : null;
      ((b && (b.data || b.Data)) || []).forEach(row => {
        const value = String(row.organizationId ?? row.OrganizationId ?? "");
        if (!value) return;
        sel.add(new Option(String(row.organizationName ?? row.OrganizationName ?? value), value));
      });
    } catch (_) { /* placeholder stays */ }
    if (sel.options.length === 2) sel.disabled = true;
  }

  function bind() {
    document.getElementById("eaOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.querySelectorAll("[data-ea-tab]").forEach(b => b.addEventListener("click", () => selectTab(b.dataset.eaTab)));
    document.querySelectorAll("[data-close-ea]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeEa).hidden = true; }));

    debounce("eaEvSearch", () => { state.evPager?.reset(true); loadEvents(); });
    ["eaEvStatus", "eaEvResult", "eaEvSource"].forEach(id =>
      document.getElementById(id).addEventListener("change", () => { state.evPager?.reset(true); loadEvents(); }));
    document.getElementById("eaEvRefresh").addEventListener("click", () => loadEvents());
    document.getElementById("eaEvBody").addEventListener("click", ev => {
      const b = ev.target.closest("[data-ea-review]");
      if (b) openReview(Number(b.dataset.eaReview));
    });

    debounce("eaBdSearch", () => { state.bdPager?.reset(true); loadBindings(); });
    ["eaBdChannel", "eaBdHealth", "eaBdStatus"].forEach(id =>
      document.getElementById(id).addEventListener("change", () => { state.bdPager?.reset(true); loadBindings(); }));
    document.getElementById("eaBdRefresh").addEventListener("click", () => loadBindings());
    document.getElementById("eaBdNew")?.addEventListener("click", () => openEdit(null));
    document.getElementById("eaBdBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-ea-binding]");
      if (tr) openBinding(Number(tr.dataset.eaBinding));
    });

    document.getElementById("eaDetailActions").addEventListener("click", ev => {
      const b = ev.target.closest("[data-ea-action]");
      if (b) bindingAction(b.dataset.eaAction);
    });
    document.getElementById("eaConnection").addEventListener("click", ev => {
      if (ev.target.closest("[data-ea-token]")) issueToken();
    });

    debounce("eaEdObSearch", searchObligations);
    document.getElementById("eaEdObligation").addEventListener("change", () => loadObligationEvidence(null));
    document.getElementById("eaEdChannel").addEventListener("change", syncChannel);
    document.getElementById("eaEditForm").addEventListener("submit", ev => { ev.preventDefault(); saveBinding(); });

    document.getElementById("eaTokenCopy").addEventListener("click", async () => {
      const input = document.getElementById("eaTokenValue");
      input.select();
      try { await navigator.clipboard.writeText(input.value); } catch (_) { document.execCommand("copy"); }
    });

    document.getElementById("eaReviewForm").addEventListener("submit", ev => { ev.preventDefault(); decide("accept"); });
    document.getElementById("eaReviewReject").addEventListener("click", () => decide("reject"));
  }

  function debounce(id, fn) {
    let t = null;
    document.getElementById(id).addEventListener("input", () => { clearTimeout(t); t = setTimeout(fn, 300); });
  }

  function selectTab(tab) {
    state.tab = tab;
    document.querySelectorAll("[data-ea-tab]").forEach(b => {
      const on = b.dataset.eaTab === tab;
      b.classList.toggle("active", on); b.setAttribute("aria-selected", on ? "true" : "false");
    });
    document.querySelectorAll("[data-ea-panel]").forEach(p => { p.hidden = p.dataset.eaPanel !== tab; });
    if (tab === "SOURCES") loadBindings(); else loadEvents();
  }

  async function changeOrg(id) {
    state.organizationId = id;
    hide("eaMessage");
    state.evPager?.reset(true); state.bdPager?.reset(true);
    await loadLookups();
    await loadSourceFilter();
    await (state.tab === "SOURCES" ? loadBindings() : loadEvents());
    refreshWaitingBadge();
  }

  async function loadLookups() {
    state.lookups = { types: [], employees: [], fileDropEnabled: false, emailEnabled: false, emailAddress: null };
    if (!state.organizationId) return;
    const res = await api("GET", `/lookups?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error); return; }
    state.lookups.types = res.data.evidenceTypes || [];
    state.lookups.employees = res.data.employees || [];
    state.lookups.fileDropEnabled = !!res.data.fileDropEnabled;
    state.lookups.emailEnabled = !!res.data.emailEnabled;          // 531
    state.lookups.emailAddress = res.data.emailAddress || null;
  }

  // The Received tab's Source filter lists the sources the caller manages.
  async function loadSourceFilter() {
    const sel = document.getElementById("eaEvSource");
    sel.length = 1;
    if (!state.organizationId) return;
    const res = await api("GET", `/bindings?organizationId=${state.organizationId}&status=All&pageSize=200`);
    if (!res.ok) return;
    (res.data.data || []).forEach(b => sel.add(new Option(F(b, "bindingName"), F(b, "bindingId"))));
  }

  async function refreshWaitingBadge() {
    const badge = document.getElementById("eaWaitingBadge");
    if (!state.organizationId) { badge.textContent = "0"; return; }
    const res = await api("GET", `/events?organizationId=${state.organizationId}&status=Proposed&pageSize=1`);
    badge.textContent = res.ok ? String(res.data.totalRows || 0) : "0";
  }

  // ------------------------------------------------------------------ Received
  async function loadEvents() {
    const body = document.getElementById("eaEvBody");
    if (!state.organizationId) { body.innerHTML = empty(7, "Select an organization."); state.evPager?.clear(); return; }
    body.innerHTML = empty(7, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId, status: val("eaEvStatus") || "Proposed",
      pageNumber: state.evPager ? state.evPager.page() : 1, pageSize: state.evPager ? state.evPager.size() : 25 });
    if (val("eaEvSearch")) qs.set("search", val("eaEvSearch"));
    if (val("eaEvResult")) qs.set("result", val("eaEvResult"));
    if (val("eaEvSource")) qs.set("bindingId", val("eaEvSource"));
    const res = await api("GET", `/events?${qs}`);
    if (!res.ok) { body.innerHTML = empty(7, res.error); state.evPager?.clear(); return; }
    const rows = res.data.data || [];
    state.evPager?.setTotal(res.data.totalRows, rows.length);
    body.innerHTML = rows.map(r => `<tr>
        <td>${esc(dateTime(F(r, "receivedDt")))}<div class="ea-note">${esc(CHANNEL[F(r, "channel")] || F(r, "channel"))}</div></td>
        <td>${esc(F(r, "bindingName"))}<div class="ea-note">${esc(F(r, "obligationName") || "")} - ${esc(F(r, "instanceName") || "")}</div></td>
        <td>${esc(period(r))}</td>
        <td>${badge(RESULT, F(r, "result"))}${F(r, "metricValue") ? `<div class="ea-note">${esc(F(r, "metricValue"))}</div>` : ""}</td>
        <td>${fileLink(r)}<div class="ea-note">${esc(F(r, "evidenceTitle") || "")}</div></td>
        <td>${badge(STATUS, F(r, "status"))}${F(r, "decidedBy") ? `<div class="ea-note">${esc(F(r, "decidedBy"))}</div>` : ""}</td>
        <td>${F(r, "canDecide") && CAN_EDIT
              ? `<button type="button" class="pm-button" data-ea-review="${esc(F(r, "eventId"))}"><i class="fa-solid fa-magnifying-glass"></i> Review</button>`
              : ""}</td>
      </tr>`).join("") || empty(7, val("eaEvStatus") === "Proposed" ? "Nothing is waiting for review." : "No evidence received.");
    state.evRows = rows;
  }

  function fileLink(r) {
    const fileId = F(r, "evidenceFileId");
    if (!fileId) return esc(F(r, "sourceFileName") || "");
    const href = U(`/practice/api/evidence-center/files/${encodeURIComponent(fileId)}?organizationId=${state.organizationId}`);
    return `<a href="${esc(href)}" target="_blank" rel="noopener">${esc(F(r, "sourceFileName") || "Download")}</a>${F(r, "versionNo") ? ` (v${esc(F(r, "versionNo"))})` : ""}`;
  }

  // ------------------------------------------------------------------ Review
  async function openReview(eventId) {
    const ev = (state.evRows || []).find(r => Number(F(r, "eventId")) === eventId);
    if (!ev) return;
    state.event = ev;
    document.getElementById("eaReviewTitle").textContent = `Review - ${F(ev, "bindingName")}`;
    document.getElementById("eaReviewNote").value = "";
    hide("eaReviewMessage");
    document.getElementById("eaReviewInfo").innerHTML = info([
      ["Obligation", F(ev, "obligationName")],
      ["Practice instance", F(ev, "instanceName")],
      ["Received", dateTime(F(ev, "receivedDt"))],
      ["Period", period(ev)],
      ["Result", badge(RESULT, F(ev, "result")) + (F(ev, "metricValue") ? " " + esc(F(ev, "metricValue")) : ""), true],
      ["Source", (F(ev, "sourceSystem") || "--") + (F(ev, "independence") === "Independent" ? " (independent)" : " (self-attested)")],
      ["File", fileLink(ev), true],
      ["Summary", F(ev, "summary")]
    ]);
    const host = document.getElementById("eaReviewTargets");
    host.innerHTML = `<p class="ea-note">Loading...</p>`;
    document.getElementById("eaReviewModal").hidden = false;

    const res = await api("GET", `/events/${eventId}/targets?organizationId=${state.organizationId}`);
    state.targets = res.ok ? (res.data.data || []) : [];
    const firstLinkable = state.targets.findIndex(t => !F(t, "notLinkableReason"));
    host.innerHTML = state.targets.map((t, i) => {
      const reason = F(t, "notLinkableReason");
      const checked = i === firstLinkable ? "checked" : "";
      return `<label class="ea-target"><input type="radio" name="eaTarget" value="${i}" ${reason ? "disabled" : checked} />
        <span>${esc(F(t, "targetLabel"))}${F(t, "periodDate") ? ` - period ${esc(date(F(t, "periodDate")))}` : ""}
        ${F(t, "suggested") ? ` <span class="pm-badge ea-ok">Matches the period</span>` : ""}
        ${reason ? `<small>${esc(reason)}</small>` : ""}</span></label>`;
    }).join("") + `<label class="ea-target"><input type="radio" name="eaTarget" value="none" ${firstLinkable < 0 ? "checked" : ""} />
        <span>Keep in the Evidence Center only<small>Accept the evidence without attaching it anywhere yet.</small></span></label>`
      + (res.ok ? "" : `<p class="pm-message">${esc(res.error)}</p>`);
  }

  async function decide(kind) {
    const ev = state.event;
    if (!ev) return;
    const note = document.getElementById("eaReviewNote").value.trim();
    let body;
    if (kind === "reject") {
      if (!note) { showIn("eaReviewMessage", "Write why this evidence is rejected."); return; }
      if (!await window.gracUi.confirm("Reject this evidence? The file is retired in the Evidence Center when nothing uses it.",
            { type: "warning", title: "Reject evidence", confirmText: "Reject" })) return;
      body = { organizationId: state.organizationId, note };
    } else {
      const choice = document.querySelector('input[name="eaTarget"]:checked')?.value;
      if (choice === undefined) { showIn("eaReviewMessage", "Choose where to attach the evidence."); return; }
      const target = choice === "none" ? null : state.targets[Number(choice)];
      body = { organizationId: state.organizationId, note: note || null,
               targetType: target ? F(target, "targetType") : "None",
               targetId: target ? F(target, "targetId") : null };
    }
    const res = await api("POST", `/events/${F(ev, "eventId")}/${kind}`, body);
    if (!res.ok) { showIn("eaReviewMessage", res.error); return; }
    document.getElementById("eaReviewModal").hidden = true;
    showMessage(F(res.data, "message") || "Done.", "success");
    await loadEvents();
    refreshWaitingBadge();
  }

  // ------------------------------------------------------------------ Sources
  async function loadBindings() {
    const body = document.getElementById("eaBdBody");
    if (!state.organizationId) { body.innerHTML = empty(8, "Select an organization."); state.bdPager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const qs = new URLSearchParams({ organizationId: state.organizationId,
      pageNumber: state.bdPager ? state.bdPager.page() : 1, pageSize: state.bdPager ? state.bdPager.size() : 25 });
    if (val("eaBdSearch")) qs.set("search", val("eaBdSearch"));
    if (val("eaBdChannel")) qs.set("channel", val("eaBdChannel"));
    if (val("eaBdHealth")) qs.set("health", val("eaBdHealth"));
    if (val("eaBdStatus")) qs.set("status", val("eaBdStatus"));
    const res = await api("GET", `/bindings?${qs}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.bdPager?.clear(); return; }
    const rows = res.data.data || [];
    state.bdPager?.setTotal(res.data.totalRows, rows.length);
    body.innerHTML = rows.map(r => `<tr data-ea-binding="${esc(F(r, "bindingId"))}">
        <td>${esc(F(r, "bindingName"))}<div class="ea-note">${esc(F(r, "sourceSystem") || "")}</div></td>
        <td>${esc(F(r, "obligationName") || "")}<div class="ea-note">${esc(F(r, "instanceName") || "")}</div></td>
        <td>${esc(CHANNEL[F(r, "channel")] || F(r, "channel"))}</td>
        <td>${esc(CADENCE[F(r, "expectedCadence")] || F(r, "expectedCadence"))}</td>
        <td>${badge(HEALTH, F(r, "health"))}${F(r, "missedPeriodEnd") ? `<div class="ea-note">Missing for ${esc(date(F(r, "missedPeriodEnd")))}</div>` : ""}${F(r, "lastError") ? `<div class="ea-note">Last refused: ${esc(F(r, "lastError"))}</div>` : ""}</td>
        <td>${esc(dateTime(F(r, "lastReceivedDt")) || "--")}</td>
        <td>${esc(F(r, "proposedCount") ?? 0)}</td>
        <td>${esc(F(r, "status"))}</td>
      </tr>`).join("") || empty(8, "No automated evidence sources yet.");
  }

  async function openBinding(id) {
    const res = await api("GET", `/bindings/${id}?organizationId=${state.organizationId}`);
    if (!res.ok) { showMessage(res.error); return; }
    state.binding = res.data.binding;
    renderBinding(res.data.recentEvents || []);
    hide("eaDetailMessage");
    document.getElementById("eaDetailModal").hidden = false;
  }

  async function reloadBinding() {
    if (!state.binding) return;
    const res = await api("GET", `/bindings/${F(state.binding, "bindingId")}?organizationId=${state.organizationId}`);
    if (res.ok) { state.binding = res.data.binding; renderBinding(res.data.recentEvents || []); }
  }

  function renderBinding(events) {
    const b = state.binding;
    document.getElementById("eaDetailTitle").textContent = F(b, "bindingName") || "Source";
    document.getElementById("eaDetailInfo").innerHTML = info([
      ["Obligation", F(b, "obligationName")],
      ["Practice instance", `${F(b, "instanceName") || ""} (${F(b, "instanceCode") || ""})`],
      ["Evidence it answers", F(b, "instanceEvidenceName")
        ? `${F(b, "instanceEvidenceName")} (${F(b, "instanceEvidenceCadence") === "OneTime" ? "one-time" : "recurring"})` : "--"],
      ["Channel", CHANNEL[F(b, "channel")] || F(b, "channel")],
      ...(F(b, "channel") === "Email" ? [["Allowed senders", senderList(F(b, "allowedSenders"))]] : []),
      ["Source system", F(b, "sourceSystem")],
      ["Control ID", F(b, "externalControlRef")],
      ["Independence", F(b, "independence") === "Independent" ? "Independent" : "Self-attested"],
      ["Expected", `${CADENCE[F(b, "expectedCadence")] || ""}${F(b, "expectedCadence") !== "None" ? `, ${F(b, "graceDays")} grace day(s)` : ""}`],
      ["Next period end", date(F(b, "nextPeriodEnd")) || "--"],
      ["Missing for", date(F(b, "missedPeriodEnd")) || "--"],
      ["Valid for", F(b, "validityDays") ? `${F(b, "validityDays")} day(s) after the period` : "No expiry"],
      ["Evidence type", F(b, "evidenceType") || "Same as the evidence row"],
      ["Owner", F(b, "ownerName")],
      ["Obligation owner", F(b, "obligationOwnerName")],
      ["Classification", F(b, "classification")],
      ["Status", F(b, "status")],
      ["Last received", dateTime(F(b, "lastReceivedDt")) || "--"],
      ["Last result", F(b, "lastResult")],
      ["Last refused", F(b, "lastError") ? `${dateTime(F(b, "lastErrorDt"))}: ${F(b, "lastError")}` : "--"],
      ["Source code", F(b, "bindingCode")]
    ]);

    const status = F(b, "status");
    const actions = [];
    if (status !== "Retired") {
      if (CAN_EDIT) actions.push(`<button type="button" class="pm-button" data-ea-action="edit"><i class="fa-solid fa-pen"></i> Edit</button>`);
      if (CAN_EDIT && status === "Active") actions.push(`<button type="button" class="pm-button" data-ea-action="Pause"><i class="fa-solid fa-pause"></i> Pause</button>`);
      if (CAN_EDIT && status === "Paused") actions.push(`<button type="button" class="pm-button" data-ea-action="Resume"><i class="fa-solid fa-play"></i> Resume</button>`);
      if (CAN_DELETE) actions.push(`<button type="button" class="pm-button danger" data-ea-action="Retire"><i class="fa-solid fa-ban"></i> Retire</button>`);
    }
    actions.push(`<button type="button" class="pm-button" data-ea-action="received"><i class="fa-solid fa-inbox"></i> Show received</button>`);
    document.getElementById("eaDetailActions").innerHTML = actions.join("");

    document.getElementById("eaConnection").innerHTML = connection(b);

    document.getElementById("eaDetailEvents").innerHTML = events.map(e => `<tr>
        <td>${esc(dateTime(F(e, "receivedDt")))}</td>
        <td>${esc(period(e))}</td>
        <td>${badge(RESULT, F(e, "result"))}${F(e, "metricValue") ? ` ${esc(F(e, "metricValue"))}` : ""}</td>
        <td>${esc(F(e, "sourceFileName") || "")}</td>
        <td>${badge(STATUS, F(e, "status"))}</td>
      </tr>`).join("") || empty(5, "Nothing received yet.");
  }

  // How the organization's system reaches GRAC.
  function connection(b) {
    if (F(b, "channel") === "Email") {
      const address = intakeAddress(F(b, "bindingCode"));
      return `<p class="ea-note">Send each report to this address from one of the allowed senders (for example, add it as a
          recipient of the system's scheduled report). Every attachment becomes one item waiting for review; a mail without
          attachments is stored as the mail itself. If the mail system does not keep the <span class="ea-code">+code</span>
          part, send to the mailbox address and put <span class="ea-code">[${esc(F(b, "bindingCode"))}]</span> in the subject.
          The result is read from a <span class="ea-code">Result: Pass</span> line in the body, else from the subject's words
          (Success / Failed); <span class="ea-code">PeriodTo: yyyy-mm-dd</span> and <span class="ea-code">Metric:</span> lines are read too.</p>
        <div class="ea-pre">${esc(address)}</div>
        <p class="ea-note">Accepted senders: ${esc(senderList(F(b, "allowedSenders")) || "--")}. Mail from anyone else is refused.</p>
        ${state.lookups.emailEnabled ? "" : `<p class="pm-message">Email intake is not switched on for this installation (EvidenceAutomation:Email is not configured). Ask your GRAC administrator.</p>`}`;
    }
    if (F(b, "channel") === "FileDrop") {
      const folder = `<FileDropRoot>/${state.organizationId}/${F(b, "dropFolder") || ""}/`;
      return `<p class="ea-note">Write each evidence file into this folder on the GRAC server (or the share it is mounted from).
          A file is picked up once it has not changed for a minute, then moved to <span class="ea-code">_processed/</span>
          (or <span class="ea-code">_failed/</span> with a <span class="ea-code">.error.txt</span> saying why). An optional
          <span class="ea-code">&lt;file&gt;.json</span> next to it can give periodFrom, periodTo, result, metric, summary and sourceSystem.</p>
        <div class="ea-pre">${esc(folder)}</div>
        ${state.lookups.fileDropEnabled ? "" : `<p class="pm-message">File drop is not switched on for this installation (EvidenceAutomation:FileDropRoot is empty). Ask your GRAC administrator.</p>`}`;
    }
    const url = `${window.location.origin}${U("/intake/evidence")}`;
    const hasToken = F(b, "hasToken") === true || F(b, "hasToken") === 1;
    const tokenLine = hasToken
      ? `Token ending <span class="ea-code">...${esc(F(b, "tokenHint") || "")}</span>, issued ${esc(dateTime(F(b, "tokenIssuedDt")))}.`
      : "No token yet. Issue one to connect a system.";
    const canToken = CAN_EDIT && F(b, "status") !== "Retired";
    const sample = `curl -X POST "${url}" \\\n  -H "Authorization: Bearer <token>" \\\n  -H "Content-Type: application/json" \\\n  -d '{"eventId":"run-2026-11-12","periodTo":"2026-11-12","result":"Pass","metric":"0 failed jobs","sourceSystem":"${F(b, "sourceSystem") || "Backup"}","file":{"name":"report.pdf","contentType":"application/pdf","contentBase64":"<base64>"}}'`;
    return `<p class="ea-note">Your system posts each result to this address with the token. JSON (file in base64) or
        multipart/form-data (part <span class="ea-code">file</span> plus the same fields) are both accepted; without a file
        the event itself is stored as the evidence. Sending the same eventId again is ignored.</p>
      <div class="ea-pre">${esc(url)}</div>
      <p class="ea-note">${tokenLine}</p>
      ${canToken ? `<div class="ea-actions"><button type="button" class="pm-button" data-ea-token="1"><i class="fa-solid fa-key"></i> ${hasToken ? "Issue a new token" : "Issue token"}</button></div>` : ""}
      <div class="ea-pre">${esc(sample)}</div>`;
  }

  // evidence@grac.in + eab-1a2b... -> evidence+eab-1a2b...@grac.in
  function intakeAddress(code) {
    const a = state.lookups.emailAddress || "";
    const at = a.lastIndexOf("@");
    return at > 0 ? `${a.slice(0, at)}+${code}${a.slice(at)}` : `<intake mailbox>+${code}@<domain>`;
  }
  function senderList(v) { return String(v || "").split(",").filter(Boolean).join(", "); }

  async function bindingAction(action) {
    const b = state.binding;
    if (!b) return;
    if (action === "edit") { document.getElementById("eaDetailModal").hidden = true; openEdit(b); return; }
    if (action === "received") {
      document.getElementById("eaDetailModal").hidden = true;
      document.getElementById("eaEvSource").value = String(F(b, "bindingId"));
      document.getElementById("eaEvStatus").value = "All";
      state.evPager?.reset(true);
      selectTab("RECEIVED");
      return;
    }
    if (action === "Retire" && !await window.gracUi.confirm(
          "Retire this source? Evidence sent to it is refused from now on and its token stops working. What was already received stays.",
          { type: "warning", title: "Retire source", confirmText: "Retire" })) return;
    const res = await api("POST", `/bindings/${F(b, "bindingId")}/status`, { organizationId: state.organizationId, action });
    if (!res.ok) { showIn("eaDetailMessage", res.error); return; }
    showIn("eaDetailMessage", F(res.data, "message") || "Done.", "success");
    await reloadBinding();
    loadBindings();
  }

  async function issueToken() {
    const b = state.binding;
    if (!b) return;
    const hasToken = F(b, "hasToken") === true || F(b, "hasToken") === 1;
    if (hasToken && !await window.gracUi.confirm(
          "Issue a new token? The current token stops working at once; update the sending system with the new one.",
          { type: "warning", title: "New token", confirmText: "Issue new token" })) return;
    const res = await api("POST", `/bindings/${F(b, "bindingId")}/token`, { organizationId: state.organizationId });
    if (!res.ok) { showIn("eaDetailMessage", res.error); return; }
    document.getElementById("eaTokenValue").value = res.data.token || "";
    document.getElementById("eaTokenModal").hidden = false;
    await reloadBinding();
  }

  // ------------------------------------------------------------------ New / edit
  function openEdit(b) {
    state.editId = b ? Number(F(b, "bindingId")) : null;
    document.getElementById("eaEditTitle").textContent = b ? "Edit source" : "New source";
    hide("eaEditMessage");
    fillSelect("eaEdType", state.lookups.types, "evidenceTypeId", "evidenceType", "Same as the evidence row");
    fillSelect("eaEdOwner", state.lookups.employees, "employeeId", "employeeName", "The obligation owner");
    set("eaEdName", b ? F(b, "bindingName") : "");
    set("eaEdObSearch", "");
    const ob = document.getElementById("eaEdObligation");
    ob.length = 1;
    if (b) ob.add(new Option(`${F(b, "obligationName")} - ${F(b, "instanceName")}`, F(b, "practiceInstanceObligationId")));
    ob.value = b ? String(F(b, "practiceInstanceObligationId")) : "";
    set("eaEdChannel", b ? F(b, "channel") : "Webhook");
    set("eaEdFolder", b ? F(b, "dropFolder") : "");
    set("eaEdSenders", b ? senderList(F(b, "allowedSenders")) : "");
    set("eaEdSourceSystem", b ? F(b, "sourceSystem") : "");
    set("eaEdControlRef", b ? F(b, "externalControlRef") : "");
    set("eaEdIndependence", b ? F(b, "independence") : "SelfAttested");
    set("eaEdCadence", b ? F(b, "expectedCadence") : "None");
    set("eaEdGrace", b ? F(b, "graceDays") : 1);
    set("eaEdValidity", b ? F(b, "validityDays") : "");
    set("eaEdType", b ? F(b, "evidenceTypeId") : "");
    set("eaEdOwner", b ? F(b, "ownerEmployeeId") : "");
    set("eaEdClass", b ? F(b, "classification") : "Internal");
    syncChannel();
    loadObligationEvidence(b ? F(b, "instanceEvidenceId") : null);
    document.getElementById("eaEditModal").hidden = false;
  }

  function syncChannel() {
    const fileDrop = val("eaEdChannel") === "FileDrop";
    const email = val("eaEdChannel") === "Email";
    document.getElementById("eaEdFolderRow").hidden = !fileDrop;
    document.getElementById("eaEdSendersRow").hidden = !email;
    if (fileDrop && !state.lookups.fileDropEnabled)
      showIn("eaEditMessage", "File drop is not switched on for this installation yet. The source can be saved, but files are picked up only once your GRAC administrator sets EvidenceAutomation:FileDropRoot.", "info");
    else if (email && !state.lookups.emailEnabled)
      showIn("eaEditMessage", "Email intake is not switched on for this installation yet. The source can be saved, but mail is read only once your GRAC administrator configures EvidenceAutomation:Email.", "info");
    else hide("eaEditMessage");
  }

  async function searchObligations() {
    const sel = document.getElementById("eaEdObligation");
    const keep = sel.value;
    const res = await api("GET", `/obligations?organizationId=${state.organizationId}&search=${encodeURIComponent(val("eaEdObSearch"))}`);
    if (!res.ok) { showIn("eaEditMessage", res.error); return; }
    const kept = keep ? [...sel.options].find(o => o.value === keep) : null;
    sel.length = 1;
    if (kept) sel.add(new Option(kept.textContent, kept.value));
    (res.data.data || []).forEach(o => {
      const id = String(F(o, "practiceInstanceObligationId"));
      if (id === keep) return;
      sel.add(new Option(`${F(o, "obligationName")} - ${F(o, "instanceName")} (${F(o, "instanceCode")})${F(o, "assuranceType") === "Automated" ? " - automated" : ""}`, id));
    });
    if (!(res.data.data || []).length && !kept)
      showIn("eaEditMessage", "No obligation found. You can set up automated evidence for obligations you own (or any, as an organization administrator).", "info");
    sel.value = keep || "";
  }

  async function loadObligationEvidence(selectedId) {
    const sel = document.getElementById("eaEdEvidence");
    sel.length = 1;
    const pio = val("eaEdObligation");
    if (!pio) return;
    const res = await api("GET", `/obligations/${encodeURIComponent(pio)}/evidence?organizationId=${state.organizationId}`);
    if (!res.ok) return;
    (res.data.data || []).forEach(e => sel.add(new Option(
      `${F(e, "evidenceName")} (${F(e, "evidenceCadence") === "OneTime" ? "one-time" : "recurring"})`, F(e, "evidenceId"))));
    if (selectedId) sel.value = String(selectedId);
  }

  async function saveBinding() {
    const pio = Number(val("eaEdObligation"));
    if (!val("eaEdName")) { showIn("eaEditMessage", "Enter a name for this source."); return; }
    if (!pio) { showIn("eaEditMessage", "Choose the obligation this source provides evidence for."); return; }
    if (val("eaEdChannel") === "Email" && !val("eaEdSenders")) { showIn("eaEditMessage", "List the senders allowed to send evidence to this source."); return; }
    const body = {
      organizationId: state.organizationId,
      bindingName: val("eaEdName"),
      practiceInstanceObligationId: pio,
      instanceEvidenceId: Number(val("eaEdEvidence")) || null,
      channel: val("eaEdChannel"),
      sourceSystem: val("eaEdSourceSystem") || null,
      externalControlRef: val("eaEdControlRef") || null,
      independence: val("eaEdIndependence"),
      expectedCadence: val("eaEdCadence"),
      graceDays: Number(val("eaEdGrace") || 0),
      validityDays: Number(val("eaEdValidity")) || null,
      evidenceTypeId: Number(val("eaEdType")) || null,
      ownerEmployeeId: Number(val("eaEdOwner")) || null,
      classification: val("eaEdClass"),
      dropFolder: val("eaEdChannel") === "FileDrop" ? (val("eaEdFolder") || null) : null,
      allowedSenders: val("eaEdChannel") === "Email" ? val("eaEdSenders") : null   // 531
    };
    const btn = document.getElementById("eaEdSubmit");
    btn.disabled = true;
    const res = await api("POST", state.editId ? `/bindings/${state.editId}/save` : "/bindings", body);
    btn.disabled = false;
    if (!res.ok) { showIn("eaEditMessage", res.error); return; }
    document.getElementById("eaEditModal").hidden = true;
    showMessage(F(res.data, "message") || "Saved.", "success");
    selectTab("SOURCES");
    await loadSourceFilter();
    const id = Number(F(res.data, "bindingId"));
    if (id) openBinding(id);
  }

  // ------------------------------------------------------------------ helpers
  async function api(method, path, body) {
    try {
      const r = await fetch(U(base + path), {
        method, credentials: "same-origin",
        headers: body ? { "Content-Type": "application/json", "X-CSRF-TOKEN": CSRF } : undefined,
        body: body ? JSON.stringify(body) : undefined
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) return { ok: false, status: r.status, data, error: data.error || `Request failed (HTTP ${r.status}).` };
      return { ok: true, status: r.status, data };
    } catch (err) { return { ok: false, status: 0, data: {}, error: err.message }; }
  }

  function fillSelect(id, rows, valueKey, textKey, placeholder) {
    const sel = document.getElementById(id);
    sel.length = 0;
    sel.add(new Option(placeholder, ""));
    rows.forEach(x => sel.add(new Option(F(x, textKey), F(x, valueKey))));
  }

  function info(pairs) {
    return pairs.map(([label, value, html]) =>
      `<div><span>${esc(label)}</span>${html ? (value || "--") : esc(value ?? "--") || "--"}</div>`).join("");
  }
  function badge(map, key) {
    if (!key) return "";
    const [label, css] = map[key] || [key, ""];
    return `<span class="pm-badge ${css}">${esc(label)}</span>`;
  }
  function period(r) {
    const a = date(F(r, "periodFrom")), b = date(F(r, "periodTo"));
    return a && b && a !== b ? `${a} to ${b}` : (b || a || "");
  }
  function set(id, v) { document.getElementById(id).value = v == null ? "" : String(v); }
  function val(id) { return (document.getElementById(id)?.value || "").trim(); }
  function hide(id) { const el = document.getElementById(id); if (el) el.hidden = true; }
  function showMessage(text, kind) { showIn("eaMessage", text, kind); }
  function showIn(id, text, kind) {
    const el = document.getElementById(id);
    el.className = "pm-message" + (kind ? " " + kind : "") + (el.classList.contains("full") ? " full" : "");
    el.textContent = text || ""; el.hidden = !text;
  }
  function empty(cols, text) { return `<tr><td colspan="${cols}" class="pm-empty">${esc(text)}</td></tr>`; }
  function date(v) { return v ? String(v).substring(0, 10) : ""; }
  function dateTime(v) {
    if (!v) return "";
    if (typeof window.gracFormatDisplayDate === "function") { const g = window.gracFormatDisplayDate(v); if (g && g !== v) return g; }
    const x = new Date(v); return isNaN(x) ? String(v) : x.toLocaleString();
  }
  function esc(v) { return String(v ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
})();
