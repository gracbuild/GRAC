// =====================================================================
// Vendor Registry (migrations 486-490; restructured by 521 -- Third-Party
// Management Phase 1; 522 -- CR 2 lightweight registration, progressive
// vendor information). Loaded by tprm-third-parties.cshtml.
// Backend: practice/api/tprm (TprmController -> sp_tprm_*)
//   GET  third-parties?organizationId&search&statusCode&serviceCategoryCode
//        &includeArchived&sample&pageNumber&pageSize        grid
//   GET  third-parties/{id}?organizationId                  detail (9 sets:
//        header, categories, contacts, engagements, history, customValues,
//        duplicates, transitions, matchReviews)
//   POST third-parties             { organizationId, thirdPartyId?, ..., matchReviewsJson? }
//        409 = possible duplicates still to review (nothing saved): each
//        gets a "why it is a different vendor" rationale, then save again
//   POST third-parties/{id}/status { organizationId, action, statusCode?, reason, evidenceReference? }
//        action = one of the transitions the detail lists (APPROVE; 522:
//        registration activates, there is no separate activation)
//   POST third-parties/{id}/match-reviews
//        { organizationId, matchedThirdPartyId, decision NOT_DUPLICATE | DUPLICATE, rationale }
//   POST samples/load              { organizationId }
// The procedures decide every rule (fn_tprm_vendor_transitions gives the
// allowed changes and why one is blocked); the buttons only mirror the
// screen permissions (data-can-*).
// =====================================================================
(() => {
  "use strict";

  const T = window.gracTprm;
  const root = document.getElementById("tpRoot");
  if (!root || !T) return;
  const { F, esc, date, empty, info, show, hide, api, qs } = T;
  const CAN_ADD = root.dataset.canAdd === "1";
  const CAN_EDIT = root.dataset.canEdit === "1";
  const CAN_APPROVE = root.dataset.canApprove === "1";
  const state = { org: null, lk: null, pager: null, detail: null };

  // Lifecycle actions (fn_tprm_vendor_transitions ActionCode) -- button text.
  const ACTIONS = {
    SUSPEND: { text: "Suspend", icon: "fa-circle-pause" },
    REINSTATE: { text: "Reinstate", icon: "fa-circle-play" },
    INACTIVATE: { text: "Make inactive", icon: "fa-circle-minus" },
    REACTIVATE: { text: "Reactivate", icon: "fa-circle-play" },
    ARCHIVE: { text: "Archive", icon: "fa-box-archive" },
    RESTORE: { text: "Restore", icon: "fa-rotate-left" }
  };
  const OPEN_FOR_ENGAGEMENTS = ["ACTIVE"];   // 522: sp_tprm_engagement_save

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    state.pager = window.__pmGrid ? window.__pmGrid.attach({ hostId: "tpPager", onChange: refreshList }) : null;
    bind();
    // 525: a link onto one vendor carries it in the encrypted navigation
    // code (?code=), never as ?thirdPartyId=.
    const ctx = await T.navigationContext("tprm-third-parties");
    await changeOrg(await T.orgs("tpOrg", ctx?.organizationId));
    if (ctx?.error) show("tpMessage", ctx.error);
    if (ctx?.filterType === "TprmThirdParty" && ctx.filterId && state.org) openDetail(ctx.filterId);
  }

  function bind() {
    document.getElementById("tpOrg").addEventListener("change", e => changeOrg(Number(e.target.value) || null));
    document.getElementById("tpRefresh").addEventListener("click", () => refreshList());
    let t = null;
    document.getElementById("tpSearch").addEventListener("input", () => { clearTimeout(t); t = setTimeout(() => { state.pager?.reset(true); refreshList(); }, 300); });
    ["tpStatusFilter", "tpCategoryFilter", "tpSampleFilter", "tpArchived"].forEach(id =>
      document.getElementById(id).addEventListener("change", () => { state.pager?.reset(true); refreshList(); }));
    document.getElementById("tpNew")?.addEventListener("click", () => editThirdParty(null));
    document.getElementById("tpSamples")?.addEventListener("click", loadSamples);
    document.getElementById("tpListBody").addEventListener("click", ev => {
      const tr = ev.target.closest("tr[data-tp-row]");
      if (tr) openDetail(Number(tr.dataset.tpRow));
    });
    document.querySelectorAll("[data-close-tp]").forEach(b => b.addEventListener("click", () => { document.getElementById(b.dataset.closeTp).hidden = true; }));
    document.querySelectorAll("[data-tp-tab]").forEach(b => b.addEventListener("click", () => selectTab(b.dataset.tpTab)));
    document.getElementById("tpDetailActions").addEventListener("click", ev => {
      const b = ev.target.closest("[data-tp-action]");
      if (b && !b.disabled) detailAction(b.dataset.tpAction);
    });
    document.getElementById("tpDupBody").addEventListener("click", ev => {
      const b = ev.target.closest("[data-dup-action]");
      if (b) reviewMatch(Number(b.dataset.matchId), b.dataset.dupAction);
    });
  }

  async function changeOrg(id) {
    state.org = id;
    hide("tpMessage");
    state.pager?.reset(true);
    state.lk = await T.lookups(id);
    if (state.lk.error) show("tpMessage", state.lk.error);
    fill("tpStatusFilter", state.lk.options("TP_STATUS"), "All statuses");
    fill("tpCategoryFilter", state.lk.options("SERVICE_CATEGORY"), "All service categories");
    await refreshList();
  }

  function fill(id, options, blank) {
    const sel = document.getElementById(id);
    const keep = sel.value;
    sel.length = 0;
    sel.add(new Option(blank, ""));
    options.forEach(o => sel.add(new Option(o.label, o.value)));
    if ([...sel.options].some(o => o.value === keep)) sel.value = keep;
  }

  // ------------------------------------------------------------------ grid
  async function refreshList() {
    const body = document.getElementById("tpListBody");
    if (!state.org) { body.innerHTML = empty(8, "Select an organization."); state.pager?.clear(); return; }
    body.innerHTML = empty(8, "Loading...");
    const res = await api("GET", `/third-parties?${qs({
      organizationId: state.org, search: val("tpSearch"), statusCode: val("tpStatusFilter"),
      serviceCategoryCode: val("tpCategoryFilter"), sample: val("tpSampleFilter"),
      includeArchived: val("tpArchived"),
      pageNumber: state.pager ? state.pager.page() : 1, pageSize: state.pager ? state.pager.size() : 25 })}`);
    if (!res.ok) { body.innerHTML = empty(8, res.error); state.pager?.clear(); return; }
    const rows = res.data.data || [];
    state.pager?.setTotal(res.data.totalRows, rows.length);
    body.innerHTML = rows.map(r => `<tr data-tp-row="${esc(F(r, "thirdPartyId"))}">
        <td>${esc(F(r, "thirdPartyCode"))}${T.yes(F(r, "isSample")) ? ' <span class="pm-badge tprm-sample">Sample</span>' : ""}</td>
        <td>${esc(F(r, "legalName"))}${F(r, "tradingName") ? `<div class="tprm-muted">${esc(F(r, "tradingName"))}</div>` : ""}${F(r, "duplicateOfCode") ? `<div class="tprm-muted">Duplicate of ${esc(F(r, "duplicateOfCode"))}</div>` : ""}</td>
        <td>${esc(F(r, "providerType") || "--")}</td>
        <td>${esc(F(r, "serviceCategory") || "--")}</td>
        <td>${T.badge(F(r, "statusLabel") || F(r, "statusCode"), F(r, "statusColor"))}</td>
        <td>${esc(F(r, "engagementCount") ?? 0)}<div class="tprm-muted">${esc(F(r, "activeEngagementCount") ?? 0)} active, ${esc(F(r, "inAssessmentCount") ?? 0)} in assessment</div></td>
        <td>${F(r, "highestResidualScore") != null ? `Residual ${esc(Number(F(r, "highestResidualScore")).toFixed(1))}`
              : F(r, "highestInherentScore") != null ? `Inherent ${esc(Number(F(r, "highestInherentScore")).toFixed(1))}` : '<span class="tprm-muted">Not assessed</span>'}</td>
        <td>${esc(F(r, "relationshipOwnerName") || "--")}</td>
      </tr>`).join("") || empty(8, "No vendors yet. Register one, or load the sample records.");
  }

  // ------------------------------------------------------------------ detail
  async function openDetail(id) {
    const res = await api("GET", `/third-parties/${id}?${qs({ organizationId: state.org })}`);
    if (!res.ok) { show("tpMessage", res.error); return; }
    state.detail = res.data;
    render();
    hide("tpDetailMessage");
    document.getElementById("tpDetailModal").hidden = false;
    selectTab("ENG");
  }
  async function reloadDetail() {
    const h = head();
    if (!h) return;
    const res = await api("GET", `/third-parties/${F(h, "thirdPartyId")}?${qs({ organizationId: state.org })}`);
    if (res.ok) { state.detail = res.data; render(); }
  }
  const head = () => (state.detail?.header || [])[0];

  function render() {
    const h = head();
    const d = state.detail;
    const meaning = F(h, "statusMeaning");
    const archived = meaning === "ARCHIVED";
    document.getElementById("tpDetailTitle").textContent = `${F(h, "thirdPartyCode")} - ${F(h, "legalName")}`;
    const cats = (d.categories || []).map(c => F(c, "label")).join(", ");
    document.getElementById("tpDetailInfo").innerHTML = info([
      ["Status", T.badge(F(h, "statusLabel") || F(h, "statusCode"), F(h, "statusColor"))
        + (T.yes(F(h, "isSample")) ? ' <span class="pm-badge tprm-sample">Sample record</span>' : ""), true],
      ["Trading name", F(h, "tradingName")],
      ["Vendor type", F(h, "providerType")],
      ["Service categories", cats || F(h, "serviceCategory")],
      ["Registration number", F(h, "registrationNumber")],
      ["Tax ID", F(h, "taxId")],
      ["LEI", F(h, "leiCode")],
      ["Jurisdiction", [F(h, "city"), F(h, "stateRegion"), F(h, "country")].filter(Boolean).join(", ")],
      ["Relationship owner", F(h, "relationshipOwnerName")],
      ["Reporting category", F(h, "reportingCategory")],
      F(h, "duplicateOfThirdPartyId") ? ["Duplicate of", `${F(h, "duplicateOfCode")} - ${F(h, "duplicateOfName")}`] : null,
      ["First active", T.dateTime(F(h, "firstActivatedDt"))]
    ]);

    // Edit, then the lifecycle changes the procedure allows from here
    // (blocked ones are shown disabled with the reason), then New engagement.
    const b = [];
    if (CAN_EDIT && !archived)
      b.push(`<button type="button" class="pm-button" data-tp-action="EDIT"><i class="fa-solid fa-pen"></i> Edit</button>`);
    (d.transitions || []).forEach(tr => {
      const action = F(tr, "actionCode");
      const allowedByRole = F(tr, "permission") === "EDIT" ? CAN_EDIT : CAN_APPROVE;
      if (!allowedByRole) return;
      const a = ACTIONS[action] || { text: action, icon: "fa-flag" };
      const blocked = !T.yes(F(tr, "isAllowed"));
      const title = blocked ? F(tr, "blockReason") : `${a.text}: ${F(tr, "toStatusLabel") || F(tr, "toStatusCode")}`;
      b.push(`<button type="button" class="pm-button" data-tp-action="${esc(action)}" title="${esc(title)}"${blocked ? " disabled" : ""}><i class="fa-solid ${esc(a.icon)}"></i> ${esc(a.text)}</button>`);
    });
    if (OPEN_FOR_ENGAGEMENTS.includes(meaning))
      // 525: the vendor travels in the navigation code (Engagement Management opens New engagement for it)
      b.push(`<a class="pm-button primary" href="${esc(T.U("/Practice/Index/tprm-engagements"))}"${T.navAttrs("tprm-third-parties", "tprm-engagements", "TprmThirdParty", F(h, "thirdPartyId"), state.org)}><i class="fa-solid fa-plus"></i> New engagement</a>`);
    document.getElementById("tpDetailActions").innerHTML = b.join("");
    const blockedNote = (d.transitions || []).filter(tr => !T.yes(F(tr, "isAllowed")) && F(tr, "actionCode") === "REACTIVATE").map(tr => F(tr, "blockReason"));
    document.getElementById("tpDetailNote").textContent = blockedNote.length ? `To reactivate: ${blockedNote[0]}` : "";
    document.getElementById("tpDetailNote").hidden = !blockedNote.length;

    // 525: the engagement travels in the navigation code, not in the URL
    const engLink = e => `<a href="${esc(T.U("/Practice/Index/tprm-engagements"))}"${T.navAttrs("tprm-third-parties", "tprm-engagements", "TprmEngagement", F(e, "engagementId"), state.org)}>${esc(F(e, "engagementCode"))}</a>`;
    document.getElementById("tpEngBody").innerHTML = (d.engagements || []).map(e => `<tr>
        <td>${engLink(e)} ${esc(F(e, "engagementTitle"))}</td>
        <td>${esc(T.stageLabel(F(e, "stageCode")))}</td>
        <td>${state.lk.badge("CRITICALITY", F(e, "criticalityCode")) || "--"}</td>
        <td>${F(e, "inherentScore") != null ? esc(Number(F(e, "inherentScore")).toFixed(1)) + " " + esc(F(e, "inherentBandCode") || "") : "--"}</td>
        <td>${F(e, "residualScore") != null ? esc(Number(F(e, "residualScore")).toFixed(1)) + " " + esc(F(e, "residualBandCode") || "") : "--"}</td>
        <td>${esc(state.lk.label("DD_TIER", F(e, "ddTierCode")) || "--")}</td>
        <td>${esc(date(F(e, "nextReviewDt")) || "--")}</td>
        <td>${esc(F(e, "businessOwnerName") || "--")}</td>
      </tr>`).join("") || empty(8, "No engagements yet.");
    document.getElementById("tpContactBody").innerHTML = (d.contacts || []).map(c => `<tr>
        <td>${esc(F(c, "contactName"))}</td><td>${esc(F(c, "contactRole") || "--")}</td><td>${esc(F(c, "email") || "--")}</td>
        <td>${esc(F(c, "phone") || "--")}</td><td>${T.yes(F(c, "isPrimary")) ? "Yes" : ""}</td></tr>`).join("") || empty(5, "No contacts.");
    document.getElementById("tpProfileInfo").innerHTML = info([
      ["Address", F(h, "address")], ["Website", F(h, "website")], ["Parent company", F(h, "parentCompany")],
      ["Year established", F(h, "yearEstablished")], ["Employees", F(h, "employeeCountBand")], ["Annual revenue", F(h, "annualRevenueBand")],
      ["Certifications", F(h, "certificationsText")], ["Notes", F(h, "profileNotes")],
      ...(d.customValues || []).map(c => [F(c, "label"), F(c, "value")]),
      ["Registered", `${T.dateTime(F(h, "enteredDt"))} by ${F(h, "enteredBy") || ""}`],
      ["Updated", F(h, "updatedDt") ? `${T.dateTime(F(h, "updatedDt"))} by ${F(h, "updatedBy") || ""}` : ""]
    ]);

    // Possible duplicates now, and every review of this vendor.
    const kinds = { STRONG: "Same identifier", POSSIBLE: "Possible match" };
    document.getElementById("tpDupBody").innerHTML = (d.duplicates || []).map(m => {
      const reviewed = F(m, "reviewDecision");
      const actions = archived ? "" : [
        CAN_EDIT && !reviewed ? `<button type="button" class="pm-button small" data-dup-action="NOT_DUPLICATE" data-match-id="${esc(F(m, "matchId"))}">Different vendor</button>` : "",
        CAN_APPROVE ? `<button type="button" class="pm-button small" data-dup-action="DUPLICATE" data-match-id="${esc(F(m, "matchId"))}" title="Archive this vendor as a duplicate of ${esc(F(m, "matchCode"))}">Mark this one as duplicate</button>` : ""
      ].join(" ");
      return `<tr>
        <td>${esc(kinds[F(m, "matchKind")] || F(m, "matchKind"))}</td>
        <td>${esc(F(m, "matchCode"))} ${esc(F(m, "matchName"))}<div class="tprm-muted">${esc(F(m, "matchStatus") || F(m, "matchStatusCode") || "")}</div></td>
        <td>${esc(F(m, "matchReason"))}</td>
        <td>${reviewed ? `${esc(reviewed === "DUPLICATE" ? "Duplicate" : "Different vendor")}<div class="tprm-muted">${esc(F(m, "reviewRationale") || "")}</div>` : '<span class="tprm-muted">Not reviewed</span>'}</td>
        <td>${actions}</td></tr>`;
    }).join("") || empty(5, "No possible duplicates.");
    document.getElementById("tpReviewBody").innerHTML = (d.matchReviews || []).map(r => `<tr>
        <td>${esc(T.dateTime(F(r, "reviewedDt")))}</td>
        <td>${esc(F(r, "otherCode"))} ${esc(F(r, "otherName"))}</td>
        <td>${F(r, "decision") === "DUPLICATE" ? (T.yes(F(r, "thisIsDuplicate")) ? "This vendor is the duplicate" : "The other vendor is the duplicate") : "Different vendors"}</td>
        <td>${esc(F(r, "rationale") || "")}${F(r, "matchReason") ? `<div class="tprm-muted">Matched on: ${esc(F(r, "matchReason"))}</div>` : ""}</td>
        <td>${esc(F(r, "reviewedBy") || "")}</td></tr>`).join("") || empty(5, "No reviews recorded.");

    document.getElementById("tpHistoryBody").innerHTML = (d.history || []).map(x => `<tr>
        <td>${esc(T.dateTime(F(x, "changedDt")))}</td><td>${esc(state.lk.label("TP_STATUS", F(x, "fromStatusCode")) || "--")}</td>
        <td>${esc(state.lk.label("TP_STATUS", F(x, "toStatusCode")))}</td>
        <td>${esc(F(x, "reason") || "")}${F(x, "evidenceReference") ? `<div class="tprm-muted">Evidence: ${esc(F(x, "evidenceReference"))}</div>` : ""}${T.yes(F(x, "isAutomatic")) ? ' <span class="tprm-muted">(automatic)</span>' : ""}</td>
        <td>${esc(F(x, "actorName") || F(x, "actor") || "")}</td></tr>`).join("") || empty(5, "No status changes.");
  }

  function selectTab(name) {
    document.querySelectorAll("[data-tp-tab]").forEach(x => { const on = x.dataset.tpTab === name; x.classList.toggle("active", on); x.setAttribute("aria-selected", on ? "true" : "false"); });
    document.querySelectorAll("[data-tp-panel]").forEach(p => { p.hidden = p.dataset.tpPanel !== name; });
  }

  // A lifecycle change: reason always; evidence reference optional; the
  // status value when the organization has more than one of that kind.
  async function detailAction(action) {
    const h = head();
    if (action === "EDIT") { editThirdParty(state.detail); return; }
    const tr = (state.detail.transitions || []).find(x => F(x, "actionCode") === action);
    if (!tr) return;
    const a = ACTIONS[action] || { text: action };
    const choices = state.lk.values("TP_STATUS").filter(v => F(v, "meaningCode") === F(tr, "toMeaning"))
      .map(v => ({ value: F(v, "valueCode"), label: F(v, "label") }));
    const r = await T.form({
      title: `${a.text} ${F(h, "thirdPartyCode")}`, submitText: a.text,
      intro: `New status: ${F(tr, "toStatusLabel") || F(tr, "toStatusCode")}. The change is recorded with your reason in the status history.`,
      fields: [
        ...(choices.length > 1 ? [{ name: "statusCode", label: "Status", type: "select", options: choices, value: F(tr, "toStatusCode"), required: true }] : []),
        { name: "reason", label: "Reason", type: "textarea", required: true, maxLength: 1000 },
        { name: "evidenceReference", label: "Evidence reference", maxLength: 500, full: true,
          help: "Optional: the document, ticket or Evidence Center item that supports the change." }
      ],
      onSubmit: v => api("POST", `/third-parties/${F(h, "thirdPartyId")}/status`, {
        organizationId: state.org, action, statusCode: v.statusCode || null, reason: v.reason, evidenceReference: v.evidenceReference })
    });
    if (!r) return;
    state.lk = await T.lookups(state.org, true);
    await reloadDetail();
    show("tpDetailMessage", "Status changed.", "success");
    await refreshList();
  }

  // Review one possible duplicate from the Duplicates tab.
  async function reviewMatch(matchId, decision) {
    const h = head();
    const m = (state.detail.duplicates || []).find(x => Number(F(x, "matchId")) === matchId);
    const other = m ? `${F(m, "matchCode")} ${F(m, "matchName")}` : String(matchId);
    const dup = decision === "DUPLICATE";
    const r = await T.form({
      title: dup ? "Mark as duplicate" : "Different vendor", submitText: dup ? "Mark as duplicate" : "Record review",
      intro: dup
        ? `${F(h, "thirdPartyCode")} ${F(h, "legalName")} will be archived as a duplicate of ${other}. Nothing is merged; open engagements must be closed first.`
        : `Record that ${F(h, "thirdPartyCode")} and ${other} are different vendors.`,
      fields: [{ name: "rationale", label: "Reason", type: "textarea", required: true, maxLength: 1000 }],
      onSubmit: v => api("POST", `/third-parties/${F(h, "thirdPartyId")}/match-reviews`, {
        organizationId: state.org, matchedThirdPartyId: matchId, decision, rationale: v.rationale })
    });
    if (!r) return;
    state.lk = await T.lookups(state.org, true);
    await reloadDetail();
    show("tpDetailMessage", dup ? "Marked as a duplicate and archived." : "Review recorded.", "success");
    await refreshList();
  }

  // ------------------------------------------------------------------ register / edit
  // Two pages on the same surface (tpEditor), both saved by
  // POST third-parties:
  //   Register vendor (detail = null) -- CR 2 4.1: only the eight
  //     registration fields. The vendor is active on save (522), with no
  //     approval; activation is not a TPRM assessment or admission.
  //   Edit vendor (detail = the loaded vendor) -- CR 2 4.3: the
  //     registration fields plus the progressive information (identifiers,
  //     address, ownership, profile, all contacts, custom fields), none of
  //     it mandatory.
  // Possible duplicates (409) are listed for review before anything is saved.
  async function editThirdParty(detail) {
    const lk = state.lk;
    const h = detail ? (detail.header || [])[0] : {};
    const contacts = detail ? (detail.contacts || []) : [];
    const cats = detail ? (detail.categories || []).map(c => F(c, "serviceCategoryCode")) : [];
    let lastMatches = null;   // the 409 being answered, if any
    const reasons = {};       // every rationale typed so far, by matchId -- sent each time, so
                              // a match reasoned in an earlier round is not asked for again
    const registration = [
      { name: "legalName", label: "Legal name", required: true, maxLength: 250, value: F(h, "legalName") },
      { name: "tradingName", label: "Trading name", maxLength: 250, value: F(h, "tradingName") },
      { name: "primaryServiceCategoryCode", label: "Primary service category", type: "select", options: lk.options("SERVICE_CATEGORY"), value: F(h, "serviceCategoryCode"), required: true },
      { name: "relationshipOwnerEmployeeId", label: "Relationship owner", type: "select", options: lk.employeeOptions(), value: F(h, "relationshipOwnerEmployeeId"), required: true },
      { name: "country", label: "Country", maxLength: 120, value: F(h, "country"), required: true }
    ];
    const fields = detail ? [
      { type: "section", label: "Registration", name: "_reg" },
      ...registration,
      { type: "section", label: "Identity", name: "_id" },
      { name: "registrationNumber", label: "Registration number", maxLength: 100, value: F(h, "registrationNumber") },
      { name: "taxId", label: "Tax ID", maxLength: 100, value: F(h, "taxId") },
      { name: "leiCode", label: "LEI", maxLength: 40, value: F(h, "leiCode") },
      { name: "providerTypeCode", label: "Vendor type", type: "select", options: lk.options("PROVIDER_TYPE"), value: F(h, "providerTypeCode") },
      { name: "reportingCategoryCode", label: "Reporting category", type: "select", options: lk.options("REPORTING_CATEGORY"), value: F(h, "reportingCategoryCode") },
      { name: "categories", label: "Other service categories", type: "multi", options: lk.options("SERVICE_CATEGORY"), value: cats },
      { type: "section", label: "Address and operating locations", name: "_loc" },
      { name: "stateRegion", label: "State / region", maxLength: 120, value: F(h, "stateRegion") },
      { name: "city", label: "City", maxLength: 120, value: F(h, "city") },
      { name: "website", label: "Corporate website", maxLength: 300, value: F(h, "website") },
      { name: "address", label: "Registered address and operating locations", type: "textarea", rows: 2, maxLength: 1000, value: F(h, "address") },
      { type: "section", label: "Ownership and profile", name: "_prof" },
      { name: "parentCompany", label: "Parent company / ownership", maxLength: 250, value: F(h, "parentCompany") },
      { name: "yearEstablished", label: "Year established", type: "number", min: 1800, max: 2100, value: F(h, "yearEstablished") },
      { name: "employeeCountBand", label: "Employee strength (band)", maxLength: 60, value: F(h, "employeeCountBand") },
      { name: "annualRevenueBand", label: "Annual revenue (band)", maxLength: 60, value: F(h, "annualRevenueBand") },
      { name: "certificationsText", label: "Certifications and assurance reports", type: "textarea", rows: 2, maxLength: 1000, value: F(h, "certificationsText"),
        help: "As stated by the vendor. A certification counts only when it is evidenced and verified in due diligence." },
      { name: "profileNotes", label: "Financial, legal and other notes", type: "textarea", rows: 2, value: F(h, "profileNotes") },
      { type: "section", label: "Contacts", name: "_ct" },
      { name: "contacts", label: "Contacts", type: "rows", keyName: "contactId", addText: "Add contact", required: true,
        help: "One primary contact with an e-mail address is required.",
        columns: [{ name: "name", label: "Name", maxLength: 200, required: true }, { name: "role", label: "Role", maxLength: 150 },
                  { name: "email", label: "E-mail", maxLength: 250 }, { name: "phone", label: "Phone", maxLength: 60 },
                  { name: "isPrimary", label: "Primary", type: "radio" }],
        value: contacts.map(c => ({ contactId: F(c, "contactId"), name: F(c, "contactName"), role: F(c, "contactRole"),
                                    email: F(c, "email"), phone: F(c, "phone"), isPrimary: T.yes(F(c, "isPrimary")) })) },
      ...T.customFields(lk, "THIRD_PARTY", detail.customValues)
    ] : [
      ...registration,
      { name: "contactName", label: "Primary contact name", required: true, maxLength: 200 },
      { name: "contactEmail", label: "Contact email", required: true, maxLength: 250 },
      { name: "contactPhone", label: "Contact phone", maxLength: 60 }
    ];
    // A full page in place of the list: the screen heading, the list and an
    // open vendor detail step aside while it is open and come back when it closes.
    const detailModal = document.getElementById("tpDetailModal");
    const detailWasOpen = !detailModal.hidden;
    const swap = editing => {
      document.getElementById("tpHeading").hidden = editing;
      document.getElementById("tpList").hidden = editing;
      if (detailWasOpen) detailModal.hidden = editing;
    };
    const res = await T.form({
      page: "tpEditor", onOpen: () => swap(true), onClose: () => swap(false),
      title: detail ? `Edit ${F(h, "thirdPartyCode")} - ${F(h, "legalName")}` : "Register vendor", submitText: detail ? "Save" : "Register",
      intro: detail
        ? "Add further vendor information when it is relevant to an engagement or assessment. Only the registration fields are required."
        : "The vendor is active as soon as it is registered and can be used for engagements at once -- no approval is needed. Activation does not mean the vendor is assessed, approved or in formal TPRM. Possible duplicates are listed for review before anything is saved; add further details later from the vendor's profile.",
      fields,
      validate: v => detail ? contactsProblem(v.contacts) : (EMAIL.test(v.contactEmail || "") ? null : "Enter a valid contact email."),
      onSubmit: async v => {
        const shown = lastMatches ? JSON.parse(T.duplicateReviews() || "[]") : [];
        if (shown.some(x => !x.rationale))
          return { ok: false, error: "Give the reason for each possible duplicate, or cancel and open the existing vendor." };
        shown.forEach(x => { reasons[x.matchId] = x.rationale; });
        const reviews = Object.keys(reasons).length
          ? JSON.stringify(Object.entries(reasons).map(([matchId, rationale]) => ({ matchId: Number(matchId), rationale }))) : null;
        const contactsJson = detail
          ? JSON.stringify((v.contacts || []).map(c => ({ contactId: c.contactId, name: c.name, role: c.role, email: c.email, phone: c.phone, isPrimary: !!c.isPrimary })))
          : JSON.stringify([{ contactId: null, name: v.contactName, role: null, email: v.contactEmail, phone: v.contactPhone, isPrimary: true }]);
        // Registration sends only its fields; the edit page sends them all.
        const body = {
          organizationId: state.org,
          thirdPartyId: detail ? F(h, "thirdPartyId") : null,
          legalName: v.legalName, tradingName: v.tradingName, primaryServiceCategoryCode: v.primaryServiceCategoryCode,
          relationshipOwnerEmployeeId: v.relationshipOwnerEmployeeId ? Number(v.relationshipOwnerEmployeeId) : null,
          country: v.country, contactsJson, matchReviewsJson: reviews,
          ...(detail ? {
            registrationNumber: v.registrationNumber, taxId: v.taxId, leiCode: v.leiCode,
            providerTypeCode: v.providerTypeCode, categoriesCsv: (v.categories || []).join(",") || null,
            reportingCategoryCode: v.reportingCategoryCode, stateRegion: v.stateRegion, city: v.city, address: v.address,
            website: v.website, parentCompany: v.parentCompany, yearEstablished: v.yearEstablished,
            employeeCountBand: v.employeeCountBand, annualRevenueBand: v.annualRevenueBand,
            certificationsText: v.certificationsText, profileNotes: v.profileNotes,
            customJson: T.customJson(v), expectedRecordVersion: F(h, "recordVersion")
          } : {})
        };
        const r = await api("POST", "/third-parties", body);
        if (r.status === 409 && r.data.duplicate) {
          lastMatches = r.data;
          return { ok: false, extraHtml: T.duplicatesHtml(r.data, null, reasons) };
        }
        return r.ok ? { ok: true, id: F(r.data.result, "thirdPartyId") } : r;
      }
    });
    if (!res) return;
    state.lk = await T.lookups(state.org, true);   // the Vendor Registry list in the lookups changed
    show("tpMessage", detail ? "Vendor saved." : "Vendor registered and activated. It is available for engagements.", "success");
    await refreshList();
    if (detail) await reloadDetail(); else if (res.result.id) openDetail(res.result.id);
  }

  // Edit vendor: the contact rows need one primary contact with an e-mail
  // address, and every e-mail must look like one (sp_tprm_third_party_save
  // checks the same).
  const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  function contactsProblem(rows) {
    const list = rows || [];
    const primary = list.filter(c => c.isPrimary);
    if (primary.length !== 1 || !primary[0].email) return "Mark one contact as primary and give its e-mail address.";
    const bad = list.find(c => c.email && !EMAIL.test(c.email));
    return bad ? `"${bad.email}" is not a valid e-mail address.` : null;
  }

  async function loadSamples() {
    if (!state.org) { show("tpMessage", "Select an organization."); return; }
    if (!await T.confirm("Load the GRAC sample vendors and engagements into this organization? They are registered (and so active), marked as samples, are for illustration only and can be inactivated and archived at any time.",
      "Load sample records", "Load samples")) return;
    const res = await api("POST", "/samples/load", { organizationId: state.org });
    if (!res.ok) { show("tpMessage", res.error); return; }
    show("tpMessage", `${F(res.data.result, "loadedCount") ?? 0} sample record(s) loaded.`, "success");
    await refreshList();
  }

  function val(id) { return (document.getElementById(id).value || "").trim(); }
})();
