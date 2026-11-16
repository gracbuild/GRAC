// =====================================================================
// TP Risk Register (CR 2 Round C, migration 524). Loaded by
// tprm-risk-register.cshtml.
// Backend: practice/api/tprm (TprmController)
//   GET  risk-register?organizationId&status&bandCode&attention&search&pageNumber&pageSize
//   GET  risk-register/{id}?organizationId   header, areas, ratingHistory, dimensions,
//        engagements, findings, decisions, admissions, impactReviews, reviews, history
//   POST risk-register/{id}/ratings          { organizationId, areaCode, bandCode, rationale, evidenceReference }  (EDIT)
//   POST risk-register/impact-reviews/{id}/decide { organizationId, outcome, rationale }                     (APPROVE)
//   POST risk-register/{id}/close            { organizationId, rationale }                                    (APPROVE)
//   POST risk-register/{id}/profile-reviews  { organizationId, rationale }                                    (EDIT, 525)
// Dashboard drill (525): status, band, attention (Shared/dashboard-drill.js banner).
// A record opens in place of the list; links to and from Engagement
// Management carry the record in the encrypted navigation code (?code=).
// The procedures decide every rule (segregation of duties included).
// =====================================================================
(() => {
  "use strict";

  const T = window.gracTprm;
  const root = document.getElementById("rrRoot");
  if (!root || !T) return;
  const { F, esc, date, empty, show, hide, api, qs, info, yes } = T;
  const btn = T.button;
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";
  const ME = root.dataset.employeeId || "";
  const STATUS = { OPEN: "Open", EXIT_IN_PROGRESS: "Exit in progress", CLOSED: "Closed" };
  const LINK = { LINKED: "Linked", ENDED: "Ended" };
  const IMPACT = { NO_CHANGE: "No change to the vendor profile", PROFILE_UPDATED: "Vendor profile updated" };
  const EVENTS = {
    CREATED: "Record created", REOPENED: "Exit stopped", ENGAGEMENT_LINKED: "Engagement linked", ENGAGEMENT_ENDED: "Engagement ended",
    PROFILE_RATED: "Profile area rated", PROFILE_REVIEWED: "Vendor profile reviewed", IMPACT_REVIEW_RAISED: "Impact review raised", IMPACT_REVIEW_COMPLETED: "Impact review completed",
    EXIT_STARTED: "Exit started", CLOSED: "Record closed"
  };
  const state = { org: null, lk: null, pager: null, rows: [], id: null, rec: null, tab: "PROFILE", drill: null };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "rrPager", onChange: refreshList }) : null;
    bind();
    // A link from Engagement Management carries the record in the
    // encrypted navigation code.
    const ctx = await T.navigationContext("tprm-risk-register");
    state.org = await T.orgs("rrOrg", ctx?.organizationId);
    await loadOrg();
    // 525: TPRM dashboard drill -- status / overall band / attention.
    const q = new URLSearchParams(window.location.search);
    state.drill = window.__pmDrill ? window.__pmDrill.read() : null;
    if (q.get("status")) preselect("rrStatusFilter", q.get("status"));
    if (q.get("band")) preselect("rrBandFilter", q.get("band"));
    if (q.get("attention")) preselect("rrAttentionFilter", q.get("attention"));
    if (q.get("from") && (q.get("status") || q.get("band") || q.get("attention"))) {
      let host = document.getElementById("pmDrillBanner");
      if (!host) { host = document.createElement("div"); host.id = "pmDrillBanner"; root.parentNode.insertBefore(host, root); }
      window.__pmDrill?.banner(host, { ...(state.drill || {}), active: true, label: q.get("drillLabel") || "a dashboard selection" });
    }
    await refreshList();
    if (ctx?.error) show("rrMessage", ctx.error);
    if (ctx?.filterType === "TprmRegister" && ctx.filterId && state.org) openRecord(ctx.filterId);
  }

  // A drill value the filter does not list (a band of an earlier risk model
  // version) is added, so the list really narrows -- the Engagement
  // Management preselect does the same.
  function preselect(id, v) {
    const sel = document.getElementById(id);
    if (![...sel.options].some(o => o.value === v)) sel.add(new Option(v, v));
    sel.value = v;
  }

  function bind() {
    document.getElementById("rrOrg").addEventListener("change", async e => {
      state.org = Number(e.target.value) || null; closeRecord(); await loadOrg(); await refreshList();
    });
    document.getElementById("rrRefresh").addEventListener("click", () => refreshList());
    let t = null;
    document.getElementById("rrSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => { state.pager?.reset(true); refreshList(); }, 300); });
    ["rrStatusFilter", "rrBandFilter", "rrAttentionFilter"].forEach(id =>
      document.getElementById(id).addEventListener("change", () => { state.pager?.reset(true); refreshList(); }));
    document.getElementById("rrListBody").addEventListener("click", ev => {
      const tr = ev.target.closest("[data-rr-row]");
      if (tr) openRecord(Number(tr.dataset.rrRow));
    });
    document.getElementById("rrBack").addEventListener("click", () => { closeRecord(); refreshList(); });
    document.querySelectorAll("[data-rr-tab]").forEach(b => b.addEventListener("click", () => selectTab(b.dataset.rrTab)));
    document.getElementById("rrRecord").addEventListener("click", ev => {
      const b = ev.target.closest("[data-act]");
      if (b && !b.disabled) act(b.dataset.act, b.dataset);
    });
  }

  async function loadOrg() {
    hide("rrMessage");
    state.pager?.reset(true);
    state.lk = await T.lookups(state.org);
    if (state.lk.error) show("rrMessage", state.lk.error);
    const sel = document.getElementById("rrBandFilter");
    sel.length = 1;
    state.lk.bands.forEach(b => sel.add(new Option(F(b, "bandName"), F(b, "bandCode"))));
  }

  // ------------------------------------------------------------------ list
  async function refreshList() {
    const body = document.getElementById("rrListBody");
    if (!state.org) { body.innerHTML = empty(8, "Select an organization."); state.pager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const res = await api("GET", `/risk-register?${qs({
      organizationId: state.org, status: val("rrStatusFilter") || "ACTIVE", bandCode: val("rrBandFilter"), attention: val("rrAttentionFilter"),
      search: val("rrSearch"), pageNumber: state.pager ? state.pager.page() : 1, pageSize: state.pager ? state.pager.size() : 25 })}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.pager?.clear(); return; }
    state.rows = res.data.data || [];
    state.pager?.setTotal(res.data.totalRows, state.rows.length);
    body.innerHTML = state.rows.map(r => `<tr data-rr-row="${esc(F(r, "registerId"))}">
        <td>${esc(F(r, "registerCode"))}<div class="tprm-muted">admitted ${esc(date(F(r, "admittedDt")))}</div></td>
        <td>${esc(F(r, "thirdPartyCode"))} ${esc(F(r, "thirdPartyName"))}</td>
        <td>${esc(STATUS[F(r, "status")] || F(r, "status"))}${Number(F(r, "openImpactReviews")) > 0 ? '<div class="tprm-alert">Impact review open</div>' : ""}</td>
        <td>${overallHtml(r)}</td>
        <td>${esc(F(r, "linkedEngagements"))}</td>
        <td>${esc(F(r, "ratedAreas"))} / ${esc(F(r, "profileAreas"))} rated${F(r, "lastRatedDt") ? `<div class="tprm-muted">last ${esc(date(F(r, "lastRatedDt")))}</div>` : ""}
          ${F(r, "nextProfileReviewDt") ? `<div class="${yes(F(r, "profileReviewOverdue")) ? "tprm-alert" : "tprm-muted"}">review ${yes(F(r, "profileReviewOverdue")) ? "overdue" : "due"} ${esc(date(F(r, "nextProfileReviewDt")))}</div>` : ""}</td>
        <td>${esc(F(r, "openFindings"))}</td>
        <td>${esc(date(F(r, "nextReviewDt")) || "--")}</td>
      </tr>`).join("") || empty(8, "No vendor is on the register for this selection. A vendor joins it when an engagement is admitted to formal TPRM.");
  }
  // The overall vendor risk status and what set it -- "highest wins", never an average.
  function overallHtml(r) {
    if (!F(r, "overallBandCode")) return '<span class="tprm-muted">Not rated or assessed</span>';
    const kind = F(r, "overallSourceKind");
    const src = kind === "VENDOR_AREA"
      ? `vendor profile: ${state.lk ? state.lk.label("VENDOR_PROFILE_AREA", F(r, "overallSourceCode")) : F(r, "overallSourceCode")}`
      : `engagement ${F(r, "overallSourceCode")}`;
    return `${T.badge(F(r, "overallBand"), F(r, "overallBandColor"))}<div class="tprm-muted">set by ${esc(src)}</div>`;
  }

  // ------------------------------------------------------------------ record
  async function openRecord(id) {
    const res = await api("GET", `/risk-register/${id}?${qs({ organizationId: state.org })}`);
    if (!res.ok) { show(state.rec ? "rrRecordMessage" : "rrMessage", res.error); return false; }
    state.id = id;
    state.rec = res.data;
    document.getElementById("rrList").hidden = true;
    document.getElementById("rrRecord").hidden = false;
    renderHeader();
    renderTab(state.tab);
    return true;
  }
  async function reload() { if (state.id) await openRecord(state.id); }
  function closeRecord() {
    state.id = null; state.rec = null;
    document.getElementById("rrRecord").hidden = true;
    document.getElementById("rrList").hidden = false;
    hide("rrRecordMessage");
  }
  const H = k => F((state.rec?.header || [])[0], k);
  const set = k => (state.rec && (state.rec[k] || state.rec[k.charAt(0).toUpperCase() + k.slice(1)])) || [];
  const closed = () => H("status") === "CLOSED";
  const profileReviewOverdue = () => !closed() && H("nextProfileReviewDt") && date(H("nextProfileReviewDt")) < new Date().toISOString().substring(0, 10);

  function renderHeader() {
    document.getElementById("rrTitle").textContent = `${H("registerCode")} - ${H("thirdPartyName")}`;
    document.getElementById("rrSub").innerHTML = `${esc(H("thirdPartyCode"))} &middot; ${esc(STATUS[H("status")] || H("status"))}`;
    const src = H("overallSourceKind") === "VENDOR_AREA" ? `vendor profile: ${H("overallSourceLabel") || H("overallSourceCode")}`
      : H("overallSourceKind") === "ENGAGEMENT" ? `engagement ${H("overallSourceCode")} ${H("overallSourceLabel") || ""}` : "";
    const linked = set("engagements").filter(e => F(e, "linkStatus") === "LINKED").length;
    document.getElementById("rrSummary").innerHTML = info([
      ["Overall vendor risk", H("overallBandCode")
        ? `${T.badge(H("overallBand"), H("overallBandColor"))}<div class="tprm-muted">set by ${esc(src)}</div>`
        : '<span class="tprm-muted">Not rated or assessed</span>', true],
      ["Status", `<strong>${esc(STATUS[H("status")] || H("status"))}</strong>`, true],
      ["Admitted", T.dateTime(H("admittedDt"))],
      ["Linked engagements", String(linked)],
      ["Vendor status", H("thirdPartyStatus")],
      ["Service category", H("serviceCategory")],
      ["Country", H("country")],
      ["Relationship owner", H("relationshipOwnerName")],
      // 525: periodic vendor profile review
      ["Vendor profile review", `${H("nextProfileReviewDt") ? `${profileReviewOverdue() ? '<span class="tprm-alert">Overdue</span> ' : "Due "}${esc(date(H("nextProfileReviewDt")))}` : "--"}${
        H("lastProfileReviewDt") ? `<div class="tprm-muted">last ${esc(T.dateTime(H("lastProfileReviewDt")))}</div>` : ""}`, true],
      H("exitStartedDt") ? ["Exit started", `${T.dateTime(H("exitStartedDt"))}${H("exitStartedBy") ? ` (${H("exitStartedBy")})` : ""}`] : null,
      H("closedDt") ? ["Closed", `${T.dateTime(H("closedDt"))} by ${H("closedBy") || ""}`] : null,
      H("closureRationale") ? ["Closure rationale", H("closureRationale")] : null
    ]);
    const actions = [];
    if (CAN_APPROVE && H("status") === "EXIT_IN_PROGRESS") actions.push(btn("close-record", "fa-box-archive", "Close record", {}, "primary"));
    document.getElementById("rrActions").innerHTML = actions.join("");
    const banner = H("status") === "EXIT_IN_PROGRESS"
      ? "No admitted engagement remains. Complete the vendor exit, then close the record (someone other than the person who completed the last exit)."
      : closed() ? "This record is closed. It stays readable for audit." : "";
    if (banner) show("rrRecordMessage", banner, "info"); else hide("rrRecordMessage");
    const openImpact = set("impactReviews").some(i => F(i, "status") === "OPEN");
    document.querySelector('[data-rr-chip="IMPACT"]').classList.toggle("current", openImpact);
  }

  function selectTab(name) {
    state.tab = name;
    document.querySelectorAll("[data-rr-tab]").forEach(x => { const on = x.dataset.rrTab === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-rr-panel]").forEach(p => { p.hidden = p.dataset.rrPanel !== name; });
    renderTab(name);
  }
  function renderTab(name) {
    if (!state.rec) return;
    if (name === "PROFILE") renderProfile();
    else if (name === "ENGAGEMENTS") renderEngagements();
    else if (name === "OVERSIGHT") renderOversight();
    else if (name === "IMPACT") renderImpact();
    else if (name === "HISTORY") renderHistory();
  }

  // ---- vendor-level profile (CR 2 8.2) and the engagement exposure per dimension (8.3)
  function renderProfile() {
    const canRate = CAN_EDIT && !closed();
    const areas = set("areas").map(a => `<tr>
        <td>${esc(F(a, "areaLabel"))}${F(a, "areaDescription") ? `<div class="tprm-muted">${esc(F(a, "areaDescription"))}</div>` : ""}
          ${yes(F(a, "isActiveArea")) ? "" : '<div class="tprm-muted">Area no longer in use -- not counted in the overall vendor risk</div>'}</td>
        <td>${F(a, "bandCode") ? T.badge(F(a, "bandName") || F(a, "bandCode"), F(a, "bandColor")) : '<span class="tprm-muted">Not rated</span>'}</td>
        <td>${esc(F(a, "rationale") || "")}${F(a, "evidenceReference") ? `<div class="tprm-muted">Evidence: ${esc(F(a, "evidenceReference"))}</div>` : ""}</td>
        <td>${F(a, "assessedDt") ? `${esc(F(a, "assessedBy") || "")}<div class="tprm-muted">${esc(T.dateTime(F(a, "assessedDt")))}</div>` : ""}</td>
        <td>${canRate && yes(F(a, "isActiveArea")) ? btn("rate", "fa-pen", F(a, "bandCode") ? "Re-rate" : "Rate", { area: F(a, "areaCode") }) : ""}</td>
      </tr>`).join("");
    const dims = set("dimensions").map(d => `<tr><td>${esc(F(d, "dimensionName") || F(d, "dimensionCode"))}</td>
        <td>${esc(Number(F(d, "score")).toFixed(1))} <span class="tprm-muted">${F(d, "scoreKind") === "RESIDUAL" ? "residual" : "inherent"}</span></td>
        <td>${engLink(F(d, "engagementId"), F(d, "engagementCode"))} ${esc(F(d, "engagementTitle") || "")}</td></tr>`).join("");
    // 525: periodic profile reviews
    const reviews = set("profileReviews").map(v => `<tr><td>${esc(T.dateTime(F(v, "reviewedDt")))}</td><td>${esc(F(v, "reviewedBy") || "")}</td>
        <td>${esc(F(v, "overallBandName") || "Not rated")}</td><td>${esc(F(v, "rationale") || "")}</td>
        <td>${esc(date(F(v, "nextReviewDt")))}<div class="tprm-muted">rule ${esc(F(v, "ruleCode"))}, every ${esc(F(v, "frequencyMonths"))} months</div></td></tr>`).join("");
    const hist = set("ratingHistory").filter(h => F(h, "status") === "SUPERSEDED").map(h => `<tr>
        <td>${esc(T.dateTime(F(h, "assessedDt")))}</td><td>${esc(F(h, "areaLabel"))}</td>
        <td>${T.badge(F(h, "bandName") || F(h, "bandCode"), F(h, "bandColor"))}</td><td>${esc(F(h, "rationale") || "")}</td>
        <td>${esc(F(h, "assessedBy") || "")}</td></tr>`).join("");
    document.getElementById("rrPanelProfile").innerHTML = `
      <p class="tprm-note">The vendor-level profile is assessed for the vendor as a whole, separately from each engagement's own assessment. The overall vendor risk is the highest of these ratings and the linked engagements' risk -- never an average.</p>
      <div class="tprm-subhead">Vendor-level profile <span>${canRate ? btn("profile-review", "fa-clipboard-check", "Record profile review") : ""}</span></div>
      <div class="pm-table-wrap"><table><thead><tr><th style="width:28%">Area</th><th>Rating</th><th>Rationale and evidence</th><th>Assessed</th><th></th></tr></thead>
        <tbody>${areas || empty(5, "No vendor profile areas are configured (Third-Party Settings -> Vendor profile areas).")}</tbody></table></div>
      <div class="tprm-subhead">Highest engagement exposure per risk dimension</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Dimension</th><th>Highest score</th><th>Engagement that sets it</th></tr></thead>
        <tbody>${dims || empty(3, "No linked engagement has a risk assessment yet.")}</tbody></table></div>
      <div class="tprm-subhead">Profile reviews</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Reviewed</th><th>By</th><th>Overall vendor risk</th><th>Findings</th><th>Next review</th></tr></thead>
        <tbody>${reviews || empty(5, H("nextProfileReviewDt") ? `No review recorded yet; the first is due ${date(H("nextProfileReviewDt"))}.` : "No review recorded yet.")}</tbody></table></div>
      ${hist ? `<div class="tprm-subhead">Earlier ratings</div>
      <div class="pm-table-wrap"><table><thead><tr><th>When</th><th>Area</th><th>Rating</th><th>Rationale</th><th>By</th></tr></thead><tbody>${hist}</tbody></table></div>` : ""}`;
  }

  // ---- engagements (each keeps its own assessment -- CR 2 8.3)
  function renderEngagements() {
    const rows = set("engagements").map(e => `<tr>
        <td>${engLink(F(e, "engagementId"), F(e, "engagementCode"))}<div>${esc(F(e, "engagementTitle"))}</div></td>
        <td>${esc(LINK[F(e, "linkStatus")] || F(e, "linkStatus"))}<div class="tprm-muted">${esc(date(F(e, "linkedDt")))}${F(e, "endedDt") ? ` -- ${esc(date(F(e, "endedDt")))} (${esc(T.stageLabel(F(e, "endReason")))})` : ""}</div></td>
        <td>${esc(T.stageLabel(F(e, "stageCode")))}</td>
        <td>${T.badge(F(e, "criticality"), F(e, "criticalityColor"))}</td>
        <td>${T.band(F(e, "inherentBand"), F(e, "inherentBandColor"), F(e, "inherentScore"))}</td>
        <td>${T.band(F(e, "residualBand"), F(e, "residualBandColor"), F(e, "residualScore"))}</td>
        <td>${esc(F(e, "dueDiligenceStatus") || "--")}${F(e, "dueDiligenceTier") ? `<div class="tprm-muted">${esc(F(e, "dueDiligenceTier"))}</div>` : ""}</td>
        <td>${esc(F(e, "contractReference") || "--")}${F(e, "contractEndDt") ? `<div class="tprm-muted">to ${esc(date(F(e, "contractEndDt")))}</div>` : ""}</td>
        <td>${esc(date(F(e, "nextReviewDt")) || "--")}${yes(F(e, "reassessmentRequired")) ? '<div class="tprm-alert">Reassessment</div>' : ""}</td>
        <td>${esc(F(e, "openFindings"))}</td></tr>`).join("");
    document.getElementById("rrPanelEngagements").innerHTML = `
      <div class="pm-table-wrap"><table><thead><tr><th>Engagement</th><th>Link</th><th>Stage</th><th>Criticality</th><th>Inherent risk</th><th>Residual risk</th><th>Due diligence</th><th>Contract</th><th>Next review</th><th>Open findings</th></tr></thead>
        <tbody>${rows || empty(10, "No engagements.")}</tbody></table></div>`;
  }

  // ---- findings, risk decisions and acceptances, admissions, reviews (CR 2 8.2)
  function renderOversight() {
    const findings = set("findings").map(f => `<tr><td>${esc(F(f, "findingNumber"))} ${esc(F(f, "title"))}</td>
        <td>${T.badge(F(f, "severity") || F(f, "severityCode"), F(f, "severityColor"))}</td><td>${esc(F(f, "status"))}</td>
        <td>${esc(date(F(f, "dueDt")) || "--")}</td><td>${esc(F(f, "ownerName") || "--")}</td>
        <td>${engLink(F(f, "engagementId"), F(f, "engagementCode"))}</td></tr>`).join("");
    const decisions = set("decisions").map(d => `<tr><td>${engLink(F(d, "engagementId"), F(d, "engagementCode"))} #${esc(F(d, "decisionNo"))}</td>
        <td>${esc(F(d, "outcome") || F(d, "status"))}</td>
        <td>${yes(F(d, "riskAccepted")) ? `Accepted until ${esc(date(F(d, "acceptanceUntil")))}` : "--"}</td>
        <td>${esc(F(d, "rationale") || "")}</td><td>${esc(F(d, "decidedBy") || "")}<div class="tprm-muted">${esc(T.dateTime(F(d, "decidedDt")))}</div></td></tr>`).join("");
    const admissions = set("admissions").map(a => `<tr><td>${engLink(F(a, "engagementId"), F(a, "engagementCode"))} #${esc(F(a, "admissionNo"))}</td>
        <td>${esc(F(a, "approvalRuleName") || F(a, "approvalRuleCode") || "")}</td><td>${esc(F(a, "status"))}</td>
        <td>${esc(F(a, "outcomeRationale") || "")}</td>
        <td>${esc(F(a, "submittedBy") || "")} <span class="tprm-muted">${esc(T.dateTime(F(a, "submittedDt")))}</span></td>
        <td>${esc(F(a, "decidedBy") || "")} <span class="tprm-muted">${esc(T.dateTime(F(a, "decidedDt")))}</span></td></tr>`).join("");
    const reviews = set("reviews").map(v => `<tr><td>${esc(F(v, "reviewNumber"))}</td><td>${esc(F(v, "reviewType"))}</td>
        <td>${esc(date(F(v, "dueDt")))}${yes(F(v, "isOverdue")) ? ' <span class="tprm-alert">Overdue</span>' : ""}</td>
        <td>${engLink(F(v, "engagementId"), F(v, "engagementCode"))}</td></tr>`).join("");
    document.getElementById("rrPanelOversight").innerHTML = `
      <div class="tprm-subhead">Open findings and remediation</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Finding</th><th>Severity</th><th>Status</th><th>Due</th><th>Owner</th><th>Engagement</th></tr></thead>
        <tbody>${findings || empty(6, "No open findings.")}</tbody></table></div>
      <div class="tprm-subhead">Risk decisions and acceptances</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Decision</th><th>Outcome</th><th>Risk acceptance</th><th>Rationale</th><th>Decided</th></tr></thead>
        <tbody>${decisions || empty(5, "No risk decisions yet.")}</tbody></table></div>
      <div class="tprm-subhead">Formal TPRM admissions</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Admission</th><th>Approval rule</th><th>Outcome</th><th>Rationale</th><th>Requested</th><th>Decided</th></tr></thead>
        <tbody>${admissions || empty(6, "No admissions.")}</tbody></table></div>
      <div class="tprm-subhead">Open reviews (monitoring)</div>
      <div class="pm-table-wrap"><table><thead><tr><th>Review</th><th>Type</th><th>Due</th><th>Engagement</th></tr></thead>
        <tbody>${reviews || empty(4, "No open reviews.")}</tbody></table></div>`;
  }

  // ---- impact reviews (CR 2 8.4)
  function renderImpact() {
    const rows = set("impactReviews").map(i => {
      const open = F(i, "status") === "OPEN";
      const mine = ME && String(F(i, "requestedByEmployeeId") ?? "") === ME;
      return `<tr>
        <td>${engLink(F(i, "engagementId"), F(i, "engagementCode"))}<div>${esc(F(i, "engagementTitle"))}</div></td>
        <td>${esc(T.dateTime(F(i, "raisedDt")))}<div class="tprm-muted">${esc(F(i, "requestedBy") || "")}</div></td>
        <td>${esc(atRaise(F(i, "profileAtRaiseJson")))}</td>
        <td>${open ? "Open" : esc(F(i, "status") === "CANCELLED" ? "Cancelled" : (IMPACT[F(i, "outcome")] || F(i, "outcome")))}
          ${F(i, "rationale") ? `<div class="tprm-muted">${esc(F(i, "rationale"))}</div>` : ""}
          ${F(i, "reviewedBy") ? `<div class="tprm-muted">${esc(F(i, "reviewedBy"))}, ${esc(T.dateTime(F(i, "reviewedDt")))}</div>` : ""}</td>
        <td>${open && CAN_APPROVE && !closed() && !mine ? btn("impact-decide", "fa-check", "Record outcome", { id: F(i, "impactReviewId") }) : ""}</td></tr>`;
    }).join("");
    document.getElementById("rrPanelImpact").innerHTML = `
      <p class="tprm-note">When a further engagement of this vendor is admitted, review whether it changes the vendor-level profile. The new engagement still has its own risk assessment. The decision-maker who included the engagement cannot record the outcome.</p>
      <div class="pm-table-wrap"><table><thead><tr><th>New engagement</th><th>Raised</th><th>Profile when raised</th><th>Outcome</th><th></th></tr></thead>
        <tbody>${rows || empty(5, "No impact reviews.")}</tbody></table></div>`;
  }
  function atRaise(json) {
    try {
      const s = JSON.parse(json || "{}") || {};
      const parts = [];
      if (s.overall && s.overall.bandName) parts.push(`overall ${s.overall.bandName}`);
      if (Array.isArray(s.engagements) && s.engagements.length) parts.push(`${s.engagements.length} other engagement(s): ${s.engagements.map(e => e.engagementCode).join(", ")}`);
      return parts.join("; ") || "--";
    } catch (_) { return "--"; }
  }

  function renderHistory() {
    document.getElementById("rrPanelHistory").innerHTML = `
      <div class="pm-table-wrap"><table><thead><tr><th>When</th><th>Event</th><th>Engagement</th><th>Detail</th><th>By</th></tr></thead><tbody>${
        set("history").map(h => `<tr><td>${esc(T.dateTime(F(h, "eventDt")))}</td><td>${esc(EVENTS[F(h, "eventCode")] || F(h, "eventCode"))}</td>
          <td>${esc(F(h, "engagementCode") || "")}</td><td>${esc(F(h, "detail") || "")}</td><td>${esc(F(h, "actorName") || "")}</td></tr>`).join("")
        || empty(5, "No history.")}</tbody></table></div>`;
  }

  // ------------------------------------------------------------------ actions
  async function act(name, data) {
    switch (name) {
      case "rate": return rate(data.area);
      case "impact-decide": return decideImpact(Number(data.id));
      case "close-record": return closeRegister();
      case "profile-review": return recordProfileReview();
      case "open-engagement": {
        const err = await T.navigate("tprm-risk-register", "tprm-engagements", "TprmEngagement", data.id, state.org);
        if (err) show("rrRecordMessage", err);
        return;
      }
    }
  }

  // Rate one area on the bands of the risk model in force (decision 2026-11-08).
  async function rate(areaCode) {
    const area = set("areas").find(a => F(a, "areaCode") === areaCode);
    if (!area) return;
    if (!state.lk.bands.length) { show("rrRecordMessage", "No risk model is in force. Activate one in Third-Party Settings."); return; }
    const res = await T.form({
      title: `Rate: ${F(area, "areaLabel")}`, submitText: "Save rating",
      intro: `${F(area, "areaDescription") || ""} Rated on the bands of the risk model in force.${F(area, "bandCode") ? ` The current rating (${F(area, "bandName")}) is kept in the history.` : ""}`,
      fields: [
        { name: "bandCode", label: "Rating", type: "select", required: true, blank: "Choose",
          options: state.lk.bands.map(b => ({ value: F(b, "bandCode"), label: F(b, "bandName") })) },
        { name: "rationale", label: "Rationale", type: "textarea", required: true, maxLength: 2000 },
        { name: "evidenceReference", label: "Evidence or reference", maxLength: 1000, full: true,
          help: "The document, report or source the rating rests on." }
      ],
      onSubmit: v => api("POST", `/risk-register/${state.id}/ratings`, {
        organizationId: state.org, areaCode, bandCode: v.bandCode, rationale: v.rationale, evidenceReference: v.evidenceReference })
    });
    if (!res) return;
    await reload();
    show("rrRecordMessage", "Rating saved.", "success");
  }

  async function decideImpact(id) {
    const review = set("impactReviews").find(i => Number(F(i, "impactReviewId")) === id);
    if (!review) return;
    const res = await T.form({
      title: `Impact review: ${F(review, "engagementCode")}`, submitText: "Record outcome",
      intro: "Does the new engagement change the vendor-level profile? For \"profile updated\", re-rate the affected area(s) on the Vendor profile tab first.",
      fields: [
        { name: "outcome", label: "Outcome", type: "select", required: true, blank: "Choose",
          options: Object.entries(IMPACT).map(([value, label]) => ({ value, label })) },
        { name: "rationale", label: "Rationale", type: "textarea", required: true, maxLength: 2000 }
      ],
      onSubmit: v => api("POST", `/risk-register/impact-reviews/${id}/decide`, { organizationId: state.org, outcome: v.outcome, rationale: v.rationale })
    });
    if (!res) return;
    await reload();
    show("rrRecordMessage", "Impact review recorded.", "success");
  }

  // 525 (open point 7): the periodic review of the vendor profile. Every
  // area in use must be rated; re-rate what changed first.
  async function recordProfileReview() {
    const unrated = set("areas").filter(a => yes(F(a, "isActiveArea")) && !F(a, "bandCode")).length;
    if (unrated) { show("rrRecordMessage", `${unrated} profile area(s) are not rated yet. Rate every area before recording the review.`); return; }
    const res = await T.form({
      title: `Vendor profile review: ${H("registerCode")}`, submitText: "Record review",
      intro: "Confirm the vendor-level profile is current (re-rate any area that changed first). The next review date follows the TPRM review rule for the overall vendor risk and the engagements' criticality.",
      fields: [{ name: "rationale", label: "What the review found", type: "textarea", required: true, maxLength: 2000 }],
      onSubmit: v => api("POST", `/risk-register/${state.id}/profile-reviews`, { organizationId: state.org, rationale: v.rationale })
    });
    if (!res) return;
    await reload();
    show("rrRecordMessage", `Profile review recorded. Next review ${date(F(res.result.data?.result, "nextProfileReviewDt")) || ""}.`, "success");
  }

  async function closeRegister() {
    const res = await T.form({
      title: `Close ${H("registerCode")}`, submitText: "Close record",
      intro: "Every admitted engagement of this vendor has ended. Closing the record ends the vendor's place on the TP Risk Register; the record stays readable.",
      fields: [{ name: "rationale", label: "Closure rationale", type: "textarea", required: true, maxLength: 2000 }],
      onSubmit: v => api("POST", `/risk-register/${state.id}/close`, { organizationId: state.org, rationale: v.rationale })
    });
    if (!res) return;
    await reload();
    show("rrRecordMessage", "Record closed.", "success");
  }

  // ------------------------------------------------------------------ helpers
  function engLink(id, code) {
    return id ? btn("open-engagement", "fa-file-signature", code, { id }, "", "Open in Engagement Management") : esc(code || "");
  }
  function val(id) { return (document.getElementById(id).value || "").trim(); }
})();
