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

  // ===================================================================
  // Grid pagers (wwwroot/js/pm-grid.js)
  //
  // One per paged list. Every procedure behind these already returns
  // TotalRows -- COUNT(*) OVER (), last in the projection -- and every
  // API model already carries TotalRows/Page/PageSize; this screen was
  // discarding all of it and fetching a fixed page size with no way to
  // reach page 2.
  //
  // Mounted in initPagers() once the DOM exists. Held here so the load
  // functions can read page() / size() without threading an argument
  // through every caller.
  // ===================================================================
  const pagers = { cand: null, reg: null, rev: null, appr: null };

  function initPagers() {
    if (!window.__pmGrid) return;
    // onChange refetches. It must never slice a local array -- the whole
    // point of the procedures' OFFSET/FETCH is that a long register is
    // never all in the browser.
    pagers.cand = window.__pmGrid.attach({ hostId: "candPager", onChange: () => refresh() });
    pagers.reg  = window.__pmGrid.attach({ hostId: "regPager",  onChange: () => refreshRegister() });
    pagers.rev  = window.__pmGrid.attach({ hostId: "revPager",  onChange: () => refreshReviewDue() });
    pagers.acc  = window.__pmGrid.attach({ hostId: "accPager",  onChange: () => refreshAcceptDue() });
    pagers.appr = window.__pmGrid.attach({ hostId: "apprPager", onChange: () => refreshApprovalQueue() });
  }

  // Page + size for a request, and a no-op when pm-grid did not load, so
  // a missing script degrades to the old fixed first page rather than
  // throwing on every list.
  function pageParams(p) {
    return p ? { pageNumber: p.page(), pageSize: p.size() } : {};
  }

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
    // Risk Type options (313, 314) — Confidentiality / Integrity /
    // Availability, from risk_type_master. Reloaded per organisation like
    // `assess` above, not fetched once like reviewFrequencies below: the
    // master supports an organisation-owned band of its own rows, even
    // though nothing creates one yet.
    riskTypes: null,
    // The Review Frequency options for the acceptance modal (293).
    // frequency_master is a master table, so this is NOT reloaded per
    // organisation the way employees are — it is fetched once, the first
    // time the acceptance modal opens, and kept for the session.
    reviewFrequencies: [],
    // Set when the analyst asked to register straight from the analysis
    // form, so the duplicate-check step knows what to do on "continue".
    pendingRegisterCandidateId: null,
    // The registration note typed on the assessment form, carried across
    // the same "continue" step -- collected once, up front, not asked
    // for again after the duplicate check.
    pendingRegisterNote: null,
    // The treatment tasks currently on the Risk Treatment page. Held so
    // the row menu can name the parent it was opened on without
    // re-fetching a list the page is already showing.
    treatmentTasks: []
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("riskListView")) return;
    bindEvents();
    // Before the first load, so page()/size() are available to it.
    initPagers();
    showTab("candidates");
    await populateOrgFilter();
    const sel = document.getElementById("riskFilterOrganization");
    if (sel && sel.options.length > 1 && !state.organizationId) {
      sel.selectedIndex = 1;
      state.organizationId = Number(sel.value) || null;
      // Mirror the auto-selection onto the other tabs' controls before
      // anything loads, so every tab shows which organisation it is
      // displaying rather than an unset "Select organization".
      syncOrgSelects();
      if (state.organizationId) await onOrganizationChanged();
    }

    // Deep-link support for Gap View → Risk Centre hand-off (migration
    // 325). #riskId=<id> opens that REGISTERED risk's own read-only full
    // page directly -- openRiskDetailPage() is the exact function the
    // register grid's "View risk" row-menu action already calls, reused
    // rather than a second detail surface. It fetches the risk itself
    // (apiGet(`/register/${riskId}`)) and only toggles which of the
    // screen's own panels is visible (showFullPage()), so it does not
    // depend on the organisation filter or the grid having loaded first
    // -- safe to call unconditionally, after the block above rather than
    // gated on it.
    const hashParams = new URLSearchParams((window.location.hash || "").replace(/^#/, ""));
    const riskId = Number(hashParams.get("riskId"));
    if (Number.isFinite(riskId) && riskId > 0) {
      openRiskDetailPage(riskId);
    }

    // #candidateId=<id> -- companion deep-link for a Gap's risk that has
    // NOT yet been registered. There is no separate full page for a
    // candidate (openRiskDetailPage() opens a REGISTERED risk by
    // risk_register_id, which a candidate doesn't have yet), so this
    // reuses openDetailModal() -- the same read-only "View details" modal
    // the candidate row menu's own eye icon opens -- rather than inventing
    // a second, duplicate candidate-detail surface. Same independence as
    // openRiskDetailPage above: openDetailModal() fetches the candidate
    // and its analysis history itself, so it is safe to call unconditionally.
    const candidateId = Number(hashParams.get("candidateId"));
    if (Number.isFinite(candidateId) && candidateId > 0) {
      openDetailModal(candidateId);
    }
  }

  // ---- events -------------------------------------------------------
  function bindEvents() {
    document.querySelectorAll("[data-risk-tab]").forEach(btn =>
      btn.addEventListener("click", () => showTab(btn.dataset.riskTab)));

    // One organisation value, three controls -- one in each tab's filter
    // row, because a picker that lives in a single tab is invisible from
    // the other two (showTab hides the whole panel). Whichever one the
    // operator uses, the others follow.
    document.querySelectorAll(".risk-org-filter").forEach(el =>
      el.addEventListener("change", e => {
        state.organizationId = e.target.value ? Number(e.target.value) : null;
        state.options = null; state.employees = []; state.riskTypes = null;
        // A different organisation is a different data set entirely --
        // every list goes back to page 1, silently, because
        // onOrganizationChanged reloads them all immediately after.
        Object.values(pagers).forEach(p => p?.reset(true));
        syncOrgSelects();
        onOrganizationChanged();
      }));
    on("riskFilterStatus", "change", e => {
      state.statusCode = e.target.value || null;
      pagers.cand?.reset(true); refresh();
    });
    on("riskFilterSource", "change", e => {
      state.sourceTypeCode = e.target.value || null;
      pagers.cand?.reset(true); refresh();
    });
    on("riskRefreshBtn", "click", refresh);

    // A FILTER change goes back to page 1. Staying on page 4 of a filter
    // that now matches six rows shows an empty grid, which reads as a
    // fault rather than as a filter. reset(true) is silent -- it moves
    // the pager without firing onChange, so the refresh below happens
    // once rather than twice.
    const regFiltered = () => { pagers.reg?.reset(true); refreshRegister(); };
    ["regFilterSource", "regFilterCategory", "regFilterRating",
     "regFilterStage", "regFilterTreatment"]
      .forEach(id => on(id, "change", regFiltered));
    on("regFilterSearch", "change", regFiltered);
    on("regFilterPending", "change", regFiltered);
    // Refresh is NOT a filter change: it re-reads the page you are on.
    on("regRefreshBtn", "click", refreshRegister);
    on("regCustomBtn", "click", openCustomModal);

    // ---- Review Risk tab (migration 264) ----------------------------
    const revFiltered = () => { pagers.rev?.reset(true); refreshReviewDue(); };
    ["revFilterOwner", "revFilterRating", "revFilterHorizon"]
      .forEach(id => on(id, "change", revFiltered));
    on("revFilterSearch", "change", revFiltered);
    on("revRefreshBtn", "click", refreshReviewDue);

    // ---- Risk Calendar tab (migration 264) --------------------------
    on("calFilterOwner", "change", refreshCalendar);
    on("calPrevBtn",  "click", () => { calMonth = addMonths(calMonth, -1); refreshCalendar(); });
    on("calNextBtn",  "click", () => { calMonth = addMonths(calMonth,  1); refreshCalendar(); });
    on("calTodayBtn", "click", () => { calMonth = startOfMonth(new Date()); refreshCalendar(); });

    on("riskAnalysisForm", "submit", ev => onAnalysisSubmit(ev, false));
    on("anSaveRegisterBtn", "click", () => onAnalysisSubmit(null, true));
    // BRD §8B — "not a risk". Hands off to the existing reject modal
    // rather than growing a second reason-capture form.
    on("anRejectBtn", "click", () => {
      const id = Number(document.getElementById("anCandidateId").value);
      hide("riskAnalysisModal");
      openRejectModal(id);
    });
    // "Others" (id 0) reveals the description box. One handler shape
    // for both forms and both fields, so they cannot drift.
    on("anThreat", "change", () => toggleOther("an", "Threat"));
    on("anVulnerability", "change", () => toggleOther("an", "Vuln"));

    on("riskCustomForm", "submit", onCustomSubmit);
    on("cxThreat", "change", () => toggleOther("cx", "Threat"));
    on("cxVulnerability", "change", () => toggleOther("cx", "Vuln"));
    on("riskRegAnalysisForm", "submit", onRegAnalysisSubmit);
    on("raLikelihood", "change", () => renderRating("ra"));
    on("raImpact", "change", () => renderRating("ra"));
    on("riskRegApprovalForm", "submit", ev => onRegApprovalDecision(ev, "Approve"));
    on("rgaReturnBtn", "click", () => onRegApprovalDecision(null, "Return"));
    // Residual risk (258). Same renderRating resolver as the inherent
    // form — one preview function, so the two scores cannot be previewed
    // by two different rules.
    on("riskResidualForm", "submit", ev => onResidualSubmit(ev, false));
    // One handler, three consumers: the rating preview, the delta against
    // the inherent score, and the flow rail's third step all describe the
    // same choice and must not be updated by three separate listeners.
    on("rrLikelihood", "change", onResidualScoreChanged);
    on("rrImpact", "change", onResidualScoreChanged);
    // Step 2 is read-only. This is the way out to where treatment is
    // actually edited -- navigation, not a second editing surface.
    on("rrOpenTreatmentBtn", "click", () => {
      const id = Number(document.getElementById("rrRiskId").value || 0);
      if (!id) return;
      // Page-to-page, not through a tab: showFullPage() swaps them. The
      // mapping panel this page mounted is unmounted first -- that is
      // backFromFullPage()'s job on the normal exit, and this is the one
      // path that leaves the residual page without taking it.
      riskMapping.clear("rrMapping");
      openTreatmentWorkModal(id);
    });
    // Save-then-accept. It goes through the SAME submit handler with a
    // flag rather than a second save path, so the two buttons cannot
    // save differently.
    on("rrAcceptBtn", "click", () => onResidualSubmit(null, true));
    closers("reg-approval", "riskRegApprovalModal");
    // Risk Analysis is a PAGE now, not a modal: Back and Cancel both
    // return to the tab it was opened from, and both unmount the mapping
    // panel so a stale risk id cannot linger in riskMapping's host map.
    on("raBackBtn",   "click", backFromAnalysisPage);
    on("raCancelBtn", "click", backFromAnalysisPage);
    // Residual risk is a PAGE too now: Back and Cancel both leave through
    // backFromFullPage(), which unmounts the mapping panel it hosts.
    on("rrBackBtn",   "click", backFromFullPage);
    on("rrCancelBtn", "click", backFromFullPage);

    // ---- Read-only Risk Details page --------------------------------
    on("rdBackBtn",  "click", backFromFullPage);
    // window.print() rather than a server-side export: the browser's own
    // dialog already offers "Save as PDF", so this needs no route and no
    // library. The @@media print rules are in risk-centre.cshtml.
    on("rdPrintBtn", "click", () => window.print());

    // ---- Treatment work, acceptance and review (261-264) ------------
    on("twAddChildBtn", "click", onAddSubTask);
    // Risk Treatment is a PAGE now: Close returns to the tab it was
    // opened from, through the same single exit path the analysis page
    // uses.
    on("twBackBtn",  "click", backFromFullPage);
    on("twCloseBtn", "click", backFromFullPage);
    on("twResidualBtn", "click", ev => {
      const id = Number(ev.currentTarget.dataset.riskId || 0);
      if (!id) return;
      // Residual is a full page now, and showFullPage() hides every other
      // one, so this is a direct swap: treatment page out, residual page
      // in. Bouncing through the register tab first (which is what the
      // modal required) would refetch the grid nobody is going to look at.
      openResidualPage(id);
    });
    on("riskAcceptanceForm", "submit", onAcceptanceSubmit);
    // 293 / 294. The frequency drives the date, so changing it rewrites
    // the date field. Both forms bind the same function against their
    // own two ids.
    on("acReviewFrequency", "change", () => applyReviewFrequencyToDate("acReviewFrequency", "acNextReview"));
    on("brReviewFrequency", "change", () => applyReviewFrequencyToDate("brReviewFrequency", "brNextReview"));
    // 299. The review page proposes both; same derivation as the other
    // two forms. Safe here in a way it was not before 299: filling the
    // date no longer prevents the risk reaching the Accept tab.
    on("rvReviewFrequency", "change", () => applyReviewFrequencyToDate("rvReviewFrequency", "rvNextReview"));
    on("riskReviewForm", "submit", onReviewSubmit);
    // Review is a PAGE now, not a modal. Back and Cancel take the same
    // exit as the residual page's, which unmounts the scope panel and
    // returns to the tab the review was opened from.
    on("rvBackBtn",   "click", backFromFullPage);
    on("rvCancelBtn", "click", backFromFullPage);
    // The rail restates the live score and the routing, so it refreshes
    // with the rating and whenever the treatment option changes.
    on("rvLikelihood", "change", () => { renderRating("rv"); renderReviewFlow(); });
    on("rvImpact", "change", () => { renderRating("rv"); renderReviewFlow(); });
    const rvOpts = document.getElementById("rvTreatmentOptions");
    if (rvOpts) rvOpts.addEventListener("change", renderReviewFlow);
    // ---- Accept: a PAGE, not a modal --------------------------------
    //
    // No closers() and no [data-close-risk-acceptance] handler any more:
    // both belonged to the modal. Back and Cancel take the same single
    // exit every full page takes, which unmounts the scope hosts.
    //
    // The scope panel is no longer lazily mounted on expand either. It
    // was collapsed because the modal had no room for it and because
    // four API calls were too much for a popup opened to press one
    // button; on a page whose entire purpose is showing the record, the
    // section IS the page and it loads with it.
    on("acBackBtn",   "click", backFromFullPage);
    on("acCancelBtn", "click", backFromFullPage);
    // The two read-only sections that have a page of their own to go and
    // change things on. PAGE-TO-PAGE, exactly as rrOpenTreatmentBtn
    // does it: showFullPage() swaps the views, so going through
    // backFromFullPage() would flash the register tab on the way. The
    // scope hosts this page mounted are unmounted by hand here, because
    // this is the one path that leaves the page without taking the
    // normal exit.
    on("acOpenTreatmentBtn", "click", () => {
      const id = Number(val("acRiskId") || 0);
      if (!id) return;
      riskMapping.clear("acMapping");
      openTreatmentWorkModal(id);
    });
    on("acOpenResidualBtn", "click", () => {
      const id = Number(val("acRiskId") || 0);
      if (!id) return;
      riskMapping.clear("acMapping");
      openResidualPage(id);
    });

    // ---- Bulk review (270) ------------------------------------------
    // Delegated, because the review grid is re-rendered on every filter
    // change and per-row listeners would be rebound each time.
    document.addEventListener("change", ev => {
      if (ev.target.matches("#revTableBody .rev-pick")) { syncBulkBar(); return; }
      if (ev.target.id === "revSelectAll") {
        const on = ev.target.checked;
        document.querySelectorAll("#revTableBody .rev-pick").forEach(cb => { cb.checked = on; });
        syncBulkBar();
      }
    });
    on("revBulkReviewBtn", "click", openBulkReviewModal);
    on("revBulkClearBtn", "click", () => {
      document.querySelectorAll("#revTableBody .rev-pick").forEach(cb => { cb.checked = false; });
      syncBulkBar();
    });
    on("riskBulkReviewForm", "submit", onBulkReviewSubmit);
    closers("bulk-review", "riskBulkReviewModal");

    // ---- Accept Risk tab (295) --------------------------------------
    // Filters refetch rather than filtering a local array, the same way
    // every other grid on this screen works.
    ["accFilterOrganization", "accFilterOwner", "accFilterRating", "accFilterStage"]
      .forEach(id => on(id, "change", () => {
        if (id === "accFilterOrganization") {
          state.organizationId = Number(val(id)) || null;
          syncOrgSelects();
          if (state.organizationId) { onOrganizationChanged(); return; }
        }
        refreshAcceptDue();
      }));
    on("accFilterSearch", "change", refreshAcceptDue);
    on("accRefreshBtn",   "click",  refreshAcceptDue);

    on("accSelectAll", "change", ev => {
      document.querySelectorAll("#accTableBody .acc-pick")
              .forEach(cb => { cb.checked = ev.currentTarget.checked; });
      syncAcceptBulkBar();
    });
    // Delegated: the grid is re-rendered on every filter and page change,
    // so per-checkbox handlers would be rebound constantly.
    const accBody = document.getElementById("accTableBody");
    if (accBody) accBody.addEventListener("change", ev => {
      if (ev.target.classList.contains("acc-pick")) syncAcceptBulkBar();
    });
    if (accBody) accBody.addEventListener("click", ev => {
      const btn = ev.target.closest("[data-accept-risk]");
      if (!btn) return;
      ev.preventDefault();
      // SINGLE ACCEPT IS THE EXISTING MODAL -- not a second
      // implementation. It carries its own guidance banner and its own
      // rules, and reusing it means the tab cannot drift from the
      // register's and residual page's version of accepting one risk.
      openAcceptancePage(Number(btn.dataset.acceptRisk));
    });

    on("accBulkClearBtn", "click", () => {
      document.querySelectorAll("#accTableBody .acc-pick").forEach(cb => { cb.checked = false; });
      const all = document.getElementById("accSelectAll");
      if (all) { all.checked = false; all.indeterminate = false; }
      syncAcceptBulkBar();
    });
    on("accBulkAcceptBtn",   "click",  openBulkAcceptModal);
    on("riskBulkAcceptForm", "submit", onBulkAcceptSubmit);
    closers("bulk-accept", "riskBulkAcceptModal");
    // Reassign a treatment task -- POSTs to the existing /tasks/{id}/assign.
    on("riskTaskAssignForm", "submit", onTaskAssignSubmit);
    closers("task-assign", "riskTaskAssignModal");
    // Review buttons appear in two grids (Review Risk and the calendar's
    // month list), so one delegated listener serves both rather than
    // rebinding after every render.
    document.addEventListener("click", ev => {
      const rev = ev.target.closest("[data-review-risk]");
      if (rev) { ev.preventDefault(); openReviewPage(Number(rev.dataset.reviewRisk)); return; }
    });

    on("riskAcceptForm", "submit", onAcceptSubmit);
    on("riskRejectForm", "submit", onRejectSubmit);
    on("regStatusForm", "submit", onRegStatusSubmit);
    on("regOwnerForm", "submit", onRegOwnerSubmit);
    on("dupContinueBtn", "click", onDuplicateContinue);

    // ---- Phase B ----
    on("riskConfigBtn", "click", openConfigModal);
    on("riskConfigForm", "submit", onConfigSubmit);
    on("dashRefreshBtn", "click", refreshDashboard);
    on("dashTrendMonths", "change", refreshDashboard);
    on("riskApprovalForm", "submit", ev => onApprovalDecision(ev, "Approve"));
    on("apReturnBtn", "click", () => onApprovalDecision(null, "Return"));
    on("riskTreatmentForm", "submit", onTreatmentSubmit);
    on("notifSweepBtn", "click", onNotificationSweep);
    on("notifFilterStatus", "change", refreshNotifications);
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

    on("riskAcceptMethod", "change", renderAcceptMethodFields);
  }
  // One missing element must not take the whole screen down. Every
  // binding in bindEvents used to be
  // document.getElementById(id).addEventListener, so a single id that the
  // partial no longer renders (a stale build, a feature not yet deployed)
  // threw inside bindEvents and left the grid, the filters and every modal
  // unbound. Skip what is not there and name the id, so the gap is visible
  // instead of fatal.
  function on(id, type, handler, opts) {
    const el = document.getElementById(id);
    if (!el) { console.warn(`[risk-centre] element #${id} not found — "${type}" handler not bound.`); return null; }
    el.addEventListener(type, handler, opts);
    return el;
  }

  function closers(attr, modalId) {
    document.querySelectorAll(`[data-close-${attr}]`).forEach(el =>
      el.addEventListener("click", () => hide(modalId)));
  }

  // ---- Full-page views inside this partial ---------------------------
  //
  // The Risk Analysis page is a sibling of the tab panels, not a tab: it
  // is opened for ONE risk and returns to where it was opened from. So
  // showTab() hides it, and showAnalysisPage() hides the tab bar and all
  // the panels. Two functions, one invariant — exactly one of {a tab, the
  // analysis page} is visible.
  //
  // returnTab remembers where the user came from. Opening the page from
  // the Review tab and being returned to the Register would be a small
  // betrayal of context, and the register row menu is not the only way in.
  // EVERY tab panel, keyed by the tab that owns it.
  //
  // ONE list, because two lists drifted. showFullPage() carried its own
  // array of five panel ids and showTab() its own set of six lines, and
  // #riskAcceptView was in the second but not the first -- so a full
  // page opened from the Accept tab left that tab's list on screen and
  // rendered UNDERNEATH it. That is the exact failure the FULL_PAGES
  // comment below warns about, in the other direction: a panel added
  // later can no longer be missed by one of the two functions, because
  // there is only one place to add it.
  const TAB_PANELS = {
    candidates: "riskListView",
    register:   "riskRegisterView",
    accept:     "riskAcceptView",
    review:     "riskReviewView",
    calendar:   "riskCalendarView",
    dashboard:  "riskDashboardView"
  };

  // Every full-page view in this partial. One list, so a page added
  // later cannot be forgotten by showTab() and left visible underneath a
  // tab -- which is the failure mode a per-page hide() invites.
  const FULL_PAGES = ["riskAnalysisPageView", "riskTreatmentPageView",
                      "riskResidualPageView", "riskDetailPageView",
                      // Review became a full page for the same reasons
                      // the residual analysis did: a full reassessment,
                      // the scope panel and the treatment options do not
                      // fit a modal, and the scope panel's dropdowns were
                      // clipped inside one.
                      "riskReviewPageView",
                      // Acceptance, for a different reason: it asks for
                      // four values but it is a JUDGEMENT about the whole
                      // record, and the modal could show five summary
                      // lines of that record. The page shows all of it,
                      // read-only, above the four fields.
                      "riskAcceptancePageView"];

  let analysisReturnTab = "register";

  function hideAllFullPages() {
    FULL_PAGES.forEach(id => {
      const el = document.getElementById(id);
      if (el) el.hidden = true;
    });
  }

  // The tab bar AND the partial's own page heading. Both belong to the
  // tabbed screen; the analysis page replaces that screen rather than
  // sitting inside it, and it brings its own heading naming the risk.
  function setTabChromeVisible(on) {
    const bar = document.querySelector(".risk-tabs");
    if (bar) bar.hidden = !on;
    const head = document.getElementById("riskCentreHeading");
    if (head) head.hidden = !on;
  }

  // Show ONE full page: hide every tab panel, hide the tab chrome, hide
  // any other full page, then reveal this one. Generic because there are
  // two of them now and a per-page copy of this would drift the moment a
  // third arrived -- and "both pages visible at once" is a silent bug,
  // not a crash.
  function showFullPage(pageId) {
    // TAB_PANELS, not a second array. The array this used to hold was
    // missing #riskAcceptView, so a full page opened from the Accept tab
    // appeared below that tab's list instead of replacing it.
    Object.values(TAB_PANELS).forEach(id => {
      const el = document.getElementById(id);
      if (el) el.hidden = true;
    });
    hideAllFullPages();
    setTabChromeVisible(false);
    const page = document.getElementById(pageId);
    if (page) page.hidden = false;
    // A full-page view opened from a grid must start at its own top; the
    // browser keeps the scroll position of the list otherwise, and the
    // page appears to open half way down.
    window.scrollTo({ top: 0, behavior: "auto" });
  }

  // Leaving ANY full page: unmount what that page mounted, then go back
  // to the tab it was opened from. One exit path, so a page cannot be
  // left with a stale mapping panel behind it.
  // Every mapping host a full page can mount, cleared on the single exit
  // path rather than by whichever button happened to be clicked. The
  // residual page mounts "rrMapping"; leaving it through Back while only
  // "raMapping" was cleared would leave a stale risk id in riskMapping's
  // host map -- the exact bug this one-exit rule exists to prevent.
  function backFromFullPage() {
    riskMapping.clear("raMapping");
    riskMapping.clear("rrMapping");
    riskMapping.clear("rdMapping");
    // Review's scope panel. Was cleared by the modal's close handler
    // until the review became a full page; missing it here would leave
    // the previous risk's practices mounted for the next one.
    riskMapping.clear("rvMapping");
    // Acceptance's, for the same reason. clear() empties the paired
    // impact host from the stored state, so acImpactScope goes with it.
    riskMapping.clear("acMapping");
    hideAllFullPages();
    setTabChromeVisible(true);
    showTab(analysisReturnTab || "register");
  }

  function showAnalysisPage()     { showFullPage("riskAnalysisPageView"); }
  function backFromAnalysisPage() { backFromFullPage(); }
  function showTreatmentPage()    { showFullPage("riskTreatmentPageView"); }
  function showResidualPage()     { showFullPage("riskResidualPageView"); }
  function showReviewPage()       { showFullPage("riskReviewPageView"); }
  function showAcceptancePage()   { showFullPage("riskAcceptancePageView"); }

  function showTab(tab) {
    state.tab = tab;
    hideAllFullPages();
    setTabChromeVisible(true);
    document.querySelectorAll("[data-risk-tab]").forEach(b => {
      const on = b.dataset.riskTab === tab;
      b.classList.toggle("is-active", on);
      b.setAttribute("aria-selected", on ? "true" : "false");
    });
    // Same one list showFullPage() hides, driven the other way: exactly
    // the panel whose tab this is stays visible. Six hand-written lines
    // here and a five-entry array there is how they came apart.
    Object.entries(TAB_PANELS).forEach(([owner, id]) => {
      const el = document.getElementById(id);
      if (el) el.hidden = (tab !== owner);
    });
    if (tab === "register"  && state.organizationId) refreshRegister();
    if (tab === "accept"    && state.organizationId) refreshAcceptDue();
    if (tab === "review"    && state.organizationId) refreshReviewDue();
    if (tab === "calendar"  && state.organizationId) refreshCalendar();
    if (tab === "dashboard" && state.organizationId) refreshDashboard();
  }

  async function onOrganizationChanged() {
    await loadOptions();
    await loadAssessOptions();
    await loadRiskTypeOptions();
    await loadEmployees();
    await loadConfig();
    fillReviewOwnerFilters();
    await refresh();
    if (state.tab === "register")  await refreshRegister();
    if (state.tab === "accept")    await refreshAcceptDue();
    if (state.tab === "review")    await refreshReviewDue();
    if (state.tab === "calendar")  await refreshCalendar();
    if (state.tab === "dashboard") await refreshDashboard();
    // The Review tab's badge is a count people act on, so it is kept
    // current whatever tab they are looking at -- a badge that only
    // updates when you open the tab it belongs to is decoration.
    refreshReviewBadge();
    // Same reasoning for the Accept badge (295): "eleven risks are
    // waiting on you" is only useful if it is true from any tab.
    refreshAcceptBadge();
  }

  // ---- lookups ------------------------------------------------------
  // Fills every .risk-org-filter -- one per tab toolbar -- from a single
  // fetch, so the three controls can never offer different lists.
  async function populateOrgFilter() {
    const sels = [...document.querySelectorAll(".risk-org-filter")];
    if (!sels.length) return;
    let rows = [];
    try {
      const r = await fetch(U("/practice/api/organizations/allowed"), { credentials: "same-origin" });
      if (r.ok) { const b = await r.json(); rows = (b && (b.data || b.Data)) || []; }
    } catch (_) {}
    sels.forEach(sel => {
      rows.forEach(row => {
        const value = String(row.organizationId ?? row.OrganizationId ?? "");
        const label = String(row.organizationName ?? row.OrganizationName ?? "");
        if (!value) return;
        const opt = document.createElement("option");
        opt.value = value; opt.textContent = label;
        sel.appendChild(opt);
      });
      // Placeholder + exactly one org means there is nothing to choose.
      if (sel.options.length === 2) sel.disabled = true;
    });
  }

  // Push state.organizationId onto every control. Called after a change
  // and after the initial auto-select, so a tab the operator has not
  // opened yet still shows the organisation actually being displayed --
  // which is the thing that was missing when the picker lived in one tab.
  function syncOrgSelects() {
    const v = state.organizationId ? String(state.organizationId) : "";
    document.querySelectorAll(".risk-org-filter").forEach(el => { el.value = v; });
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
    // 375, 376: raCategory is now a pm-checkcombo, not a <select> --
    // rendered fresh (no selection yet; openRiskAnalysisPage re-renders
    // it with the risk's own set once a specific risk is loaded).
    renderCategoryOptions([]);
    fillSelect("raLikelihood", state.options.likelihood, "code", "name", "-- select --");
    fillSelect("raImpact",     state.options.impact,     "code", "name", "-- select --");

    // Residual (258) reads the SAME scale as the inherent form. Two
    // scales would make the register's two rating columns
    // incomparable, which is the one thing they must not be.
    fillSelect("rrLikelihood", state.options.likelihood, "code", "name", "-- select --");
    fillSelect("rrImpact",     state.options.impact,     "code", "name", "-- select --");
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

    // The hidden anThreat / cxThreat selects above are still filled, and
    // deliberately: they are what carries the LEAD id into 216's
    // unchanged procedures. The pickers below are what the user touches.
    //
    // invalidateCaches first, because the organisation may have changed
    // and a picker mounted for the previous tenant must not serve its
    // list to this one.
    if (window.__tagPicker) window.__tagPicker.invalidateCaches();
    mountThreatPickers();
  }

  // "Others" is id 0 in both masters. It is no longer OFFERED -- 286's
  // list procedures exclude it -- but the id and this helper stay,
  // because risks created before 285 still carry it and their wording
  // still has to render. The textareas it reveals are hidden in the
  // markup now; nothing calls toggleOther with a live "Others"
  // selection any more.
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

  // ===================================================================
  // Threat / Vulnerability multi-select (285, 286)
  //
  // One control (wwwroot/js/tag-picker.js) mounted four times: threat
  // and vulnerability, on the Analysis form and the Add New Risk form.
  // Keyed by the form prefix so assessmentPayload can find the right
  // pair without either form knowing about the other.
  // ===================================================================
  const threatPickers = {};

  function mountThreatPickers() {
    if (!window.__tagPicker || !state.organizationId) return;

    [["an", "anThreatPicker", "anVulnPicker"],
     ["cx", "cxThreatPicker", "cxVulnPicker"]].forEach(([prefix, threatHost, vulnHost]) => {
      // Mounted once per host; re-selecting an organisation re-points
      // the existing instance rather than building a second one on top
      // of the first, which would leave two menus fighting for the same
      // click.
      if (threatPickers[prefix]) {
        threatPickers[prefix].threat.setOrganization(state.organizationId).clear();
        threatPickers[prefix].vuln.setOrganization(state.organizationId).clear();
        return;
      }
      // U(base + path), the same construction apiGet/apiPost use.
      // `base` is "/practice/api/risk-centre" -- the Web controller's
      // actual [Route]. An earlier version of this called
      // "/Practice/RiskCentre/threats", a path that does not exist, and
      // the picker reported it as "Request failed (404)".
      const threat = window.__tagPicker.attach({
        hostId: threatHost,
        listUrl: U(`${base}/threats`),
        createUrl: U(`${base}/threats`),
        idField: "threatId", nameField: "threatName",
        label: "threat", organizationId: state.organizationId,
        placeholder: "Search threats, or type to add one"
      });
      const vuln = window.__tagPicker.attach({
        hostId: vulnHost,
        listUrl: U(`${base}/vulnerabilities`),
        createUrl: U(`${base}/vulnerabilities`),
        idField: "vulnerabilityId", nameField: "vulnerabilityName",
        label: "vulnerability", organizationId: state.organizationId,
        placeholder: "Search vulnerabilities, or type to add one"
      });
      if (threat && vuln) threatPickers[prefix] = { threat, vuln };
    });
  }

  // ===================================================================
  // Risk Type multi-select: Confidentiality / Integrity / Availability
  // (313, 314)
  //
  // Not the tag-picker above -- that widget's whole point is search and
  // free-text create, and Risk Type has neither (313's header: "no
  // 'Others' free-text escape hatch"). Three fixed checkboxes styled as
  // the same .risk-treat-opt card the Treatment option list below
  // already uses on this exact page, so the two option groups read as
  // siblings rather than two different controls.
  //
  // Currently mounted once, on the Risk Analysis page only ("ra" prefix)
  // — the only screen this was asked for. renderRiskTypeOptions takes a
  // host id rather than assuming raRiskTypeOptions, so wiring a second
  // screen (Review Risk, say) later is a call, not a rewrite.
  // ===================================================================

  async function loadRiskTypeOptions() {
    state.riskTypes = null;
    if (!state.organizationId) return;
    state.riskTypes = (await apiGet(`/risk-types?organizationId=${state.organizationId}`)) || [];
    renderRiskTypeOptions("raRiskTypeOptions");
  }

  function renderRiskTypeOptions(hostId) {
    const host = document.getElementById(hostId);
    if (!host) return;
    const types = state.riskTypes || [];
    host.innerHTML = types.map(t => `
      <label class="risk-treat-opt">
        <input type="checkbox" class="risk-type-check" value="${t.riskTypeId}" />
        <span class="t">${escapeHtml(t.riskTypeName)}</span>
      </label>`).join("")
      || `<p class="pm-hint">No risk types configured.</p>`;
  }

  function getRiskTypeIds(hostId) {
    const host = document.getElementById(hostId);
    if (!host) return [];
    return Array.from(host.querySelectorAll(".risk-type-check:checked")).map(el => Number(el.value));
  }

  function setRiskTypeIds(hostId, ids) {
    const host = document.getElementById(hostId);
    if (!host) return;
    const set = new Set((ids || []).map(Number));
    host.querySelectorAll(".risk-type-check").forEach(el => {
      el.checked = set.has(Number(el.value));
    });
  }

  // ===================================================================
  // Risk Category multi-select (375, 376)
  //
  // pm-checkcombo, not the risk-treat-options card grid Risk Type uses
  // above. risk_category_master is organisation-defined and open-ended
  // (unlike Risk Type's fixed 3-value CIA triad, 313's "no free-text
  // escape hatch" set), so a widget with a search box is the one that
  // scales, and it lets Category keep its seat in the four-column score
  // row (raLikelihood/raImpact/raRating) instead of dropping to a
  // full-width band the way a card grid would need.
  //
  // The widget's markup and CSS are the SAME shared pm-checkcombo the
  // Impacted Assets/dependency pickers below already use on this page
  // (practice-management.css, "14b. Multi-select combo") -- only the
  // click/change/search wiring had to be widened to recognise this
  // field's host; see comboInHost() further down.
  //
  // No separate "list" endpoint the way Risk Type needed one: the
  // options ride on state.options.categories (loadOptions/scoring-
  // options), which now carries RiskCategoryId alongside CategoryCode/
  // CategoryName.
  //
  // Renders fresh every time -- checked state baked into the markup up
  // front, never toggled after the fact -- the same convention the
  // dependency-object combo elsewhere on this page already uses, so
  // there is nothing to keep in sync across a re-render.
  // ===================================================================

  function renderCategoryOptions(selectedIds) {
    const host = document.getElementById("raCategoryCombo");
    if (!host) return;
    const sel  = new Set((selectedIds || []).map(Number));
    const cats = (state.options && state.options.categories) || [];
    const options = cats.map(c => {
      const checked = sel.has(Number(c.riskCategoryId));
      return `<label data-checkcombo-option>`
           + `<input type="checkbox" value="${c.riskCategoryId}" `
           + `data-object-name="${escapeHtml(c.categoryName)}"${checked ? " checked" : ""}> `
           + `<span>${escapeHtml(c.categoryName)}</span></label>`;
    }).join("");
    const selectedLabels = cats
      .filter(c => sel.has(Number(c.riskCategoryId)))
      .map(c => c.categoryName)
      .join(", ");
    host.innerHTML =
        `<button class="pm-checkcombo-trigger" type="button" data-checkcombo-trigger>`
      +   `<span data-checkcombo-text>${escapeHtml(selectedLabels || "Select...")}</span>`
      +   `<span class="pm-checkcombo-caret" aria-hidden="true"></span>`
      + `</button>`
      + `<div class="pm-checkcombo-menu" data-checkcombo-menu hidden>`
      +   `<input class="pm-checkcombo-search" type="search" placeholder="Search..." data-checkcombo-search>`
      +   `<div class="pm-checkcombo-options">${options
             || `<div class="pm-empty compact">No risk categories configured.</div>`}</div>`
      + `</div>`;
  }

  function getCategoryIds() {
    const host = document.getElementById("raCategoryCombo");
    if (!host) return [];
    return Array.from(host.querySelectorAll("input[type='checkbox']:checked")).map(el => Number(el.value));
  }

  // The scalar risk_category_code the legacy /assess call still writes
  // (the "no wrapper" precedent -- sp_risk_register_assess itself is
  // untouched, see 376's header): the FIRST ticked category's code, in
  // the combo's own list order (risk_category_master.display_order), so
  // a database not yet reading the link tables shows something rather
  // than nothing.
  function firstCategoryCode() {
    const ids = getCategoryIds();
    if (!ids.length) return "";
    const cats  = (state.options && state.options.categories) || [];
    const first = cats.find(c => Number(c.riskCategoryId) === ids[0]);
    return first ? first.categoryCode : "";
  }

  // READ-ONLY display of the full set, for pages that show a risk
  // rather than edit it. Without this the details page would keep
  // rendering risk.threatName -- the LEAD threat only -- and a risk
  // facing three would appear to face one, which is the exact problem
  // 285 set out to fix showing up somewhere else.
  //
  // Returns null on any failure so the caller can fall back to the
  // single legacy value rather than showing nothing.
  async function threatSelectionText(riskRegisterId) {
    if (!riskRegisterId) return null;
    const sel = await apiGet(`/register/${riskRegisterId}/threats`).catch(() => null);
    if (!sel) return null;

    const join = (rows, nameKey, legacy) => {
      const names = (rows || []).map(r => r[nameKey]).filter(Boolean);
      // The pre-285 free text is appended, marked, rather than shown
      // instead of the real entries -- a risk can legitimately have both
      // if somebody added chips without converting the old wording.
      if (legacy) names.push(legacy + " (legacy)");
      return names.length ? names.join(", ") : null;
    };

    return {
      threats: join(sel.threats, "threatName", sel.legacyThreatText),
      vulnerabilities: join(sel.vulnerabilities, "vulnerabilityName", sel.legacyVulnerabilityText)
    };
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
    const lkCode = document.getElementById(prefix + "Likelihood")?.value || "";
    const imCode = document.getElementById(prefix + "Impact")?.value || "";
    if (!lkCode || !imCode) {
      out.textContent = "Select likelihood and impact";
      out.removeAttribute("data-rating");
      return;
    }
    // resolveRating() is the single matrix lookup. It was inline here
    // until the residual page's rail and delta line needed the same
    // answer -- three copies of one lookup is three ways for a screen to
    // disagree with itself about what a score is worth.
    const cell = resolveRating(lkCode, imCode);
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
      tbody.innerHTML = `<tr><td colspan="7" class="pm-empty-row">Select an organization.</td></tr>`;
      return;
    }
    tbody.innerHTML = `<tr><td colspan="7" class="pm-empty-row">Loading...</td></tr>`;
    const qs = new URLSearchParams({
      organizationId: state.organizationId,
      ...pageParams(pagers.cand)
    });
    if (state.statusCode)     qs.set("statusCode", state.statusCode);
    if (state.sourceTypeCode) qs.set("sourceTypeCode", state.sourceTypeCode);
    // Same distinction as refreshRegister below: a failed read must not
    // be reported as an empty list.
    const res = await apiGetChecked(`?${qs}`);
    if (!res.ok) {
      tbody.innerHTML = `<tr><td colspan="7" class="pm-empty-row">`
        + `Could not load candidates: ${escapeHtml(res.error)}</td></tr>`;
      pagers.cand?.clear();
      return;
    }
    const rows = res.data?.rows || [];
    pagers.cand?.setTotal(res.data?.totalRows, rows.length);
    if (!rows.length) {
      tbody.innerHTML = `<tr><td colspan="7" class="pm-empty-row">No matching risk candidates.</td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    rows.forEach(r => {
      const tr = document.createElement("tr");
      // Row click-to-View (change request, 2026-09-22): a candidate's
      // "View" is its own quick-look modal (openDetailModal, the same
      // one candTrigger's own "View details" menu item opens below) --
      // a candidate has no full page of its own until it is registered.
      tr.className = "pm-row-clickable";
      tr.setAttribute("data-cand-view", String(r.riskCandidateId));
      tr.innerHTML = `
        <td>${escapeHtml(displayCandidateTitle(r.candidateTitle))}<br>
            <span class="pm-hint">${escapeHtml(r.candidateNumber || "")}</span></td>
        <td>${sourceCell(r)}</td>
        <td>${r.inherentRatingCode ? severityChip(r.inherentRatingCode)
                                   : (r.severityCode ? severityChip(r.severityCode) + ' <span class="pm-hint">(intake)</span>' : "--")}</td>
        <td>${r.identifiedOn ? window.gracFormatDateOnly(r.identifiedOn) : "--"}<br>
            <span class="pm-hint">${escapeHtml(r.requestedByName || "system")}</span></td>
        <td>${statusChip(r.statusCode)}</td>
        <td>${r.registeredRiskNumber
                ? `<a href="#" data-open-risk="${r.registeredRiskId}">${escapeHtml(r.registeredRiskNumber)}</a>`
                : escapeHtml(r.formalRiskRef || "--")}</td>
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
  // "Vinod - Risk Owner". Delegates to __wfCommon rather than carrying a
  // second copy of the format -- resolve-workspace renders people the
  // same way from its own script, and one separator defined twice is one
  // separator that drifts. risk-centre.cshtml renders the partial.
  //
  // Falls back to the bare name if the partial is somehow absent, so a
  // missing helper costs the role suffix and not the whole picker.
  function personWithRole(name, roleNames) {
    return window.__wfCommon
      ? window.__wfCommon.personWithRole(name, roleNames)
      : String(name || "").trim();
  }

  // "3 Practices", with the originating practice named beneath it.
  //
  // linkedPracticeCount, NOT mappedPracticeCount (311). The mapped count
  // is rows in risk_practice_map, and that map's Primary row is DERIVED
  // by sp_risk_mapping_sync_primary -- whose only caller is the /mapping
  // read. This page renders Risk Context from /register/{id} first and
  // mounts the scope panel afterwards, so on the first view of a risk
  // the mapped count was 0 while the section plainly showed a practice.
  // That was the empty cell. The count now comes from SQL as "the map,
  // plus this risk's own linked practice when it is not in the map yet".
  //
  // Both numbers still exist and answer different questions; this cell
  // wants "how many practices is this risk linked to".
  function practiceScopeCell(risk) {
    // Falls back to the mapped count if the API is older than 311, so a
    // stale tier degrades to the previous answer rather than to blank.
    const n = Number(
      risk.linkedPracticeCount != null ? risk.linkedPracticeCount
                                       : (risk.mappedPracticeCount || 0));
    if (!n) {
      // A risk genuinely linked to nothing -- a Custom risk raised
      // without a practice. Said in words, because "0 Practices" reads
      // like a data fault rather than a state.
      return `<span class="rd-none">No practices linked</span>`;
    }
    const origin = risk.linkedPracticeName
      ? `<div class="pm-hint">from ${escapeHtml(risk.linkedPracticeName)}</div>`
      : "";
    return `<strong>${n} Practice${n === 1 ? "" : "s"}</strong>${origin}`;
  }

  // The one common risk version (310). The NUMBER AND NOTHING ELSE.
  //
  // It used to carry "after 1 acceptance" beside it. That is derivable
  // from the number itself, and a version field that explains its own
  // arithmetic reads as though the number needed defending. The
  // acceptance history is on this page already -- Reviews, Next review,
  // and the register's own history.
  //
  // Falls back to 1 rather than rendering nothing: every risk is at
  // least version 1 by definition, and a database still on 309 returns
  // no RiskVersion at all. The API defaults it for the same reason.
  function riskVersionCell(risk) {
    return `<strong>v${Number(risk.riskVersion || 1)}</strong>`;
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

  // The Residual column (258). Three distinct states, three distinct
  // cells, because they call for three different actions:
  //
  //   no inherent rating yet  -> nothing to be residual TO. Says so,
  //                              rather than inviting a click that
  //                              error 56454 would refuse.
  //   inherent but no residual-> outstanding work, badged the same way
  //                              216 badges an unscored risk.
  //   assessed                -> the chip, plus the likelihood x impact
  //                              that produced it, same as the detail
  //                              modal shows for the inherent rating.
  //
  // Deliberately reuses severityChip: the two rating columns must be
  // read with the same eye, so they are painted by the same function.
  function residualCell(r) {
    if (r.analysisPending)
      return `<span class="pm-hint">awaiting inherent rating</span>`;
    if (!r.residualRatingCode)
      return `<span class="risk-status-chip risk-clarify">Not assessed</span>`;
    return severityChip(r.residualRatingCode)
      + (r.residualLikelihoodName && r.residualImpactName
          ? `<br><span class="pm-hint">${escapeHtml(r.residualLikelihoodName)} x ${escapeHtml(r.residualImpactName)}</span>`
          : "");
  }

  // ---- Register grid -------------------------------------------------
  // 8 columns: Treatment, Scope, Status and Registered were removed on
  // an earlier request; Category and Source were removed and the
  // remaining columns reordered to Risk ID, Risk, Owner, Stage,
  // Inherent Risk Score, Residual Risk Score, Next Review Date (change
  // request, 2026-09-23). MUST match the <thead> in risk-centre.cshtml --
  // one constant, so a column cannot be changed in the markup and
  // forgotten in four empty-state messages.
  const REG_COLS = 8;

  async function refreshRegister() {
    const tbody = document.getElementById("regTableBody");
    if (!state.organizationId) {
      tbody.innerHTML = `<tr><td colspan="${REG_COLS}" class="pm-empty-row">Select an organization.</td></tr>`;
      return;
    }
    tbody.innerHTML = `<tr><td colspan="${REG_COLS}" class="pm-empty-row">Loading...</td></tr>`;

    // Migration 263: move any risk whose treatment tasks have all closed
    // to Monitoring before reading the grid, so the Stage column is
    // right the first time rather than one refresh behind. The sweep is
    // idempotent and cheap -- it is a set operation over one filtered
    // index -- which is exactly why it can be called on every load.
    // Failure here must not stop the register rendering, so it is fired
    // and its result ignored.
    apiPost(`/register/treatment-sync?organizationId=${state.organizationId}`, null)
      .catch(() => {});

    const qs = new URLSearchParams({
      organizationId: state.organizationId,
      ...pageParams(pagers.reg)
    });
    const add = (id, key) => {
      const el = document.getElementById(id);
      const v = el ? el.value : "";
      if (v) qs.set(key, v);
    };
    // No statusCode: the Record status control was removed, so the
    // procedure's @status_code stays NULL and every risk lists. The
    // parameter itself is untouched -- a caller that wants one still
    // has it.
    add("regFilterSource",    "sourceTypeCode");
    add("regFilterCategory",  "categoryCode");
    add("regFilterRating",    "ratingCode");
    add("regFilterSearch",    "search");
    add("regFilterPending",   "analysisPending");
    add("regFilterStage",     "workflowStageCode");
    add("regFilterTreatment", "treatmentOptionCode");

    const res = await apiGetChecked(`/register?${qs}`);
    if (!res.ok) {
      // Say the register could not be READ. Reporting a failure as an
      // empty result sent people hunting for missing data instead of a
      // broken endpoint.
      tbody.innerHTML = `<tr><td colspan="${REG_COLS}" class="pm-empty-row">`
        + `Could not load the register: ${escapeHtml(res.error)}</td></tr>`;
      // Clear rather than leave the previous page's count standing
      // beside an error the user is now looking at.
      pagers.reg?.clear();
      return;
    }
    const rows = res.data?.rows || [];
    // The total the procedure already computed. Passing the row count
    // too is what lets the label read "26-40 of 40" on a short last page
    // instead of assuming every page is full.
    pagers.reg?.setTotal(res.data?.totalRows, rows.length);
    if (!rows.length) {
      // Name the filters that are actually in force. "These filters" told
      // the reader nothing, and Organization is auto-selected at load, so
      // it is the one they are least likely to realise is set.
      //
      // The Record status filter used to be read here directly --
      // getElementById(...).value with no guard -- which would now throw
      // on the removed element and leave the grid stuck on "Loading...".
      // Every filter goes through the same optional lookup instead, so
      // removing another one later cannot break this message.
      const orgSel  = document.getElementById("riskFilterOrganization");
      const orgName = orgSel?.selectedOptions?.[0]?.textContent?.trim() || state.organizationId;
      const applied = [`organization ${orgName}`];
      ["regFilterSource", "regFilterCategory", "regFilterRating", "regFilterSearch",
       "regFilterPending", "regFilterStage", "regFilterTreatment"]
        .forEach(id => { const el = document.getElementById(id); const v = el ? el.value : ""; if (v) applied.push(v); });

      tbody.innerHTML = `<tr><td colspan="${REG_COLS}" class="pm-empty-row">`
        + `No risks in the register for ${escapeHtml(applied.join(" · "))}.`
        + (applied.length > 1
             ? ` Clear a filter, or try another organization.`
             : ` Try another organization.`)
        + `</td></tr>`;
      return;
    }
    tbody.innerHTML = "";
    rows.forEach(r => {
      const tr = document.createElement("tr");
      // Row click-to-View (change request, 2026-09-22): "View risk" is
      // unconditional in buildRegisterMenu() (no applicable/disabled gate
      // at all), so every row gets it -- the same full riskDetailPageView
      // the Risk ID link above and the row's own 3-dot menu both open.
      tr.className = "pm-row-clickable";
      tr.setAttribute("data-reg-view", String(r.riskRegisterId));
      tr.innerHTML = `
        <td><a href="#" data-open-risk="${r.riskRegisterId}">${escapeHtml(r.riskNumber)}</a></td>
        <td>${escapeHtml(r.riskTitle)}</td>
        <td>${escapeHtml(r.riskOwnerName || "--")}</td>
        <td>${stageCell(r)}</td>
        <td>${r.analysisPending
              ? `<span class="risk-status-chip risk-clarify">Analysis pending</span>`
              : severityChip(r.inherentRatingCode)}</td>
        <td>${residualCell(r)}</td>
        <td>${reviewDateCell(r)}</td>
        <td>
          <button type="button" class="pm-action-trigger" data-reg-menu="${r.riskRegisterId}"
                  data-reg-status="${escapeHtml(r.statusCode)}"
                  data-reg-pending="${r.analysisPending ? 1 : 0}"
                  data-reg-residual-pending="${r.residualPending === false ? 0 : 1}"
                  data-reg-option="${escapeHtml(r.treatmentOptionCode || "")}"
                  data-reg-stage="${escapeHtml(r.workflowStageCode || "")}"
                  data-reg-open-tasks="${r.openTreatmentTaskCount || 0}"
                  data-reg-task-count="${r.treatmentTaskCount || 0}"
                  data-reg-review-due="${r.isReviewDue ? 1 : 0}"
                  aria-haspopup="menu" aria-expanded="false" title="Actions">
            <i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i>
          </button>
        </td>`;
      tbody.appendChild(tr);
    });
  }

  // ---- Register cell renderers (migrations 261-264) -------------------
  // These are functions rather than inline template fragments because
  // each is shared: statusChip by eleven call sites, stageCell by the
  // risk detail header, residualCell and reviewDateCell by the review
  // and calendar grids.
  //
  // treatmentCell / scopeCell / TREATMENT_LABEL were deleted with the
  // Treatment and Scope columns -- they had no other caller, and a
  // renderer nothing renders is worse than a missing one. The fields they
  // read (treatmentOptionCode, treatmentTaskCount, mappedPracticeCount,
  // mappedDependencyCount) are all still in the /register payload and
  // still drive the 3-dot menu, so bringing the columns back is markup
  // plus a renderer, not an API change.

  // The stage vocabulary lives in ONE place in the client, mirroring
  // vw_pm_risk_workflow_stage. The view is the authority; this is the
  // wording.
  const STAGE_LABEL = {
    AnalysisDue:   "Analysis due",
    TreatmentDue:  "Treatment option due",
    InTreatment:   "In treatment",
    ResidualDue:   "Residual analysis due",
    AcceptanceDue: "Acceptance due",
    Accepted:      "Accepted",
    ReviewDue:     "Review due",
    Closed:        "Closed"
  };

  // ====================================================================
  // ONE LIFECYCLE VALUE ON SCREEN -- and it is the STAGE.
  //
  // A risk carries two lifecycle-looking fields and they are NOT the
  // same thing. Both are needed; only one belongs in front of a user:
  //
  //   workflow_stage_code  DERIVED, vw_pm_risk_workflow_stage (264).
  //                        Where the risk has actually got to, computed
  //                        from analysis_pending, the treatment option,
  //                        the open task count, residual_pending,
  //                        accepted_dt and next_review_date. It cannot
  //                        drift because nothing keeps it in sync.
  //                        THIS is what a reader means by "status".
  //
  //   status_code          STORED, BRD §17, set by an operator or by a
  //                        workflow step. It is NOT redundant: the stage
  //                        view READS it (Closed/Retired is the view's
  //                        first CASE branch), risk_register_history
  //                        records every transition of it, closure
  //                        reason/date/actor hang off it, it is the
  //                        indexed filter on the register list, and
  //                        CanAccept, duplicate detection and the
  //                        review-due list all gate on it.
  //
  // So the UI shows the stage, everywhere, and calls the stored one
  // "Record status" where it genuinely has to appear.
  // ====================================================================

  // The chip alone. Split out of stageCell so the page headings can show
  // the same value without the grid's second line.
  function stageChip(r) {
    const code = r.workflowStageCode;
    if (!code) return `<span class="pm-hint">--</span>`;
    return `<span class="risk-stage-chip" data-stage="${escapeHtml(code)}">${
      escapeHtml(STAGE_LABEL[code] || code)}</span>`;
  }

  // THE one badge every screen shows, with a single correction.
  // vw_pm_risk_workflow_stage collapses Closed AND Retired to the stage
  // 'Closed', because for the workflow they end it the same way. To a
  // reader they are not the same, and Retired exists ONLY in
  // status_code -- so for that one case the badge takes the record
  // status back, rather than telling somebody a retired risk was closed.
  function lifecycleChip(r) {
    if (r.statusCode === "Retired")
      return `<span class="risk-stage-chip" data-stage="Closed">Retired</span>`;
    return stageChip(r);
  }

  function stageCell(r) {
    if (!r.workflowStageCode) return `<span class="pm-hint">--</span>`;
    // "In treatment (2 open)" is actionable; "In treatment" is not. The
    // count comes from the same view as the stage, so they agree.
    const extra = r.workflowStageCode === "InTreatment" && r.openTreatmentTaskCount > 0
      ? `<br><span class="pm-hint">${r.openTreatmentTaskCount} task(s) open</span>` : "";
    return lifecycleChip(r) + extra;
  }

  function reviewDateCell(r) {
    if (!r.nextReviewDate) return `<span class="pm-hint">--</span>`;
    const d = new Date(r.nextReviewDate);
    const cls = r.isReviewDue ? "risk-overdue" : "";
    return `<span class="${cls}">${window.gracFormatDisplayDateObj(d)}</span>`
         + (r.isReviewDue ? `<br><span class="pm-hint">due</span>` : "");
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
  // ===================================================================
  // THREE STATES, NOT TWO.  (the same contract as Task Center's menu)
  //
  //   applicable: false   Can NEVER apply to this item -- a closed risk
  //                       cannot be re-analysed, Tolerate raises no
  //                       treatment task, a sub task has no sub tasks of
  //                       its own. HIDDEN, because a permanently grey row
  //                       is noise the reader re-evaluates every visit.
  //
  //   disabled + reason   Applicable, but blocked by something that CAN
  //                       change -- the analysis is not finished, a
  //                       mandatory sub task is still open. SHOWN and
  //                       greyed, because the reader needs to know the
  //                       action exists and what would unblock it.
  //
  //   (neither)           Available now.
  //
  // Roughly: a TERMINAL or STRUCTURAL fact hides; an unmet PREREQUISITE
  // disables. Both used to be `disabled`, so a Closed risk offered nine
  // grey rows that would never become anything else.
  //
  // NOTE ON AUTHORITY: presentation only. Every gate mirrored here is
  // also enforced in SQL -- 56454/56456 on residual analysis, the §12
  // child gate on completion, the acceptance rules in 264. Hiding an item
  // removes a button, never a check.
  // ===================================================================
  function openRowMenu(trigger, items) {
    closeRowMenu();
    openMenuTrigger = trigger;
    trigger.setAttribute("aria-expanded", "true");
    openMenuEl = document.createElement("div");
    openMenuEl.className = "pm-action-menu";
    openMenuEl.setAttribute("role", "menu");

    const shown = items.filter(it => it && it.applicable !== false);

    if (!shown.length) {
      // Better than an empty popover: says the row is read-only rather
      // than looking like a rendering fault.
      const p = document.createElement("div");
      p.className = "pm-action-menu-empty";
      p.style.cssText = "padding:8px 12px; font-size:12px; color:#94a3b8; white-space:nowrap;";
      p.textContent = "No actions available";
      openMenuEl.appendChild(p);
    }

    shown.forEach(it => {
      const b = document.createElement("button");
      b.type = "button"; b.setAttribute("role", "menuitem");
      b.innerHTML = `<i class="fa-solid ${escapeHtml(it.icon)}" aria-hidden="true"></i> ${escapeHtml(it.label)}`;
      if (it.disabled) {
        b.disabled = true;
        b.title = it.disabledReason || "";
        // A greyed item that cannot say why is a dead end. Surfaced in
        // development rather than shipped as a silent shrug.
        if (!it.disabledReason) {
          console.warn(`[risk] menu item "${it.label}" is disabled with no reason. `
                     + `Give it a disabledReason, or mark it applicable:false so it is hidden.`);
        }
      }
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

  // The three treatment options that raise work. Tolerate raises none
  // (§21), which is why gate 3 of sp_risk_residual_analysis_save only
  // applies to these.
  const TREATMENT_RAISES_WORK = ["Terminate", "Treat", "Transfer"];

  // ===================================================================
  // The residual-analysis gate, in ONE place.
  //
  // WHY A FUNCTION AND NOT FOUR CONDITIONS INLINE
  // The same action is offered from two screens -- the register row menu
  // and the Risk Treatment page's button -- and the two were answering
  // differently for the same risk: the page disabled its button on
  // sp_risk_treatment_state's `residualAvailable`, while the menu asked
  // only "analysis pending or Active?". A risk in treatment with three
  // open tasks therefore offered an ENABLED menu item that 56574 then
  // refused -- the exact click this menu exists to not offer.
  //
  // WHAT IT MIRRORS, AND WHAT IT DELIBERATELY DOES NOT
  // It mirrors the refusals sp_risk_residual_analysis_save actually
  // makes, one branch per THROW:
  //
  //   56455  closed / retired          terminal    -> applicable:false
  //   56454  no inherent rating yet    prerequisite-> disabled
  //   56456  status still Active       prerequisite-> disabled
  //   56574  open treatment tasks      prerequisite-> disabled
  //
  // It does NOT gate on "no treatment option recorded" or "no task
  // raised", even though sp_risk_treatment_state reports both as
  // not-ready. The save permits both on purpose: gate 3's own comment
  // (263, validation case 13) says tightening the rule must not make
  // pre-263 rows -- which have no option recorded -- unassessable.
  // Disabling the menu item there would re-impose in the UI a rule the
  // procedure went out of its way not to impose.
  //
  // Tolerate is the one item here that is not a mirrored refusal: the
  // save allows it, but §21 means no treatment was performed, so there
  // is nothing for a residual score to be residual TO. It is disabled
  // rather than hidden because the option can be changed, and the reason
  // is the signpost sp_risk_treatment_state itself gives -- go and
  // accept the risk.
  //
  // AUTHORITY: presentation only. Every branch is enforced in SQL and
  // arrives verbatim if this function is ever wrong.
  // ===================================================================
  function residualMenuGate(d) {
    const closed = d.status === "Closed" || d.status === "Retired";
    if (closed) return { applicable: false };

    if (d.analysisPending) return {
      applicable: true, disabled: true,
      disabledReason: "Complete the inherent risk analysis first — there is nothing to be residual to."
    };
    if (d.status === "Active") return {
      applicable: true, disabled: true,
      disabledReason: "Residual risk is what remains after treatment. Move this risk to "
                    + "Under treatment, Monitoring or Accepted first."
    };
    if (d.option === "Tolerate") return {
      applicable: true, disabled: true,
      disabledReason: "Tolerate / Accept raises no treatment work, so there is nothing to be "
                    + "residual to — accept the risk instead."
    };
    if (TREATMENT_RAISES_WORK.includes(d.option) && d.openTasks > 0) return {
      applicable: true, disabled: true,
      disabledReason: `${d.openTasks} treatment task${d.openTasks === 1 ? " is" : "s are"} still open. `
                    + "Residual risk can only be assessed once the treatment work is complete."
    };
    return { applicable: true };
  }

  // ===================================================================
  // The Register row-menu's item list, in ONE place (change request,
  // 2026-09-22) -- the Register grid's own row menu AND the read-only
  // Risk View page (riskDetailPageView, reached via #riskId=) now both
  // build their menu by calling this one function, so there is exactly
  // one implementation of the item list and every applicability/disabled
  // rule (residualMenuGate included). Unlike Task/Gap/Exception, Risk
  // View lives in THIS SAME file as the Register grid -- there is no
  // second file to keep in sync, so this stays a local function rather
  // than a Shared/risk-actions.js module: the module-scope closure IS
  // the sharing mechanism here.
  //
  // fields: { riskRegisterId, statusCode, analysisPending, residualPending,
  //           treatmentOptionCode, openTreatmentTaskCount, treatmentTaskCount,
  //           isReviewDue, approvalRequired } -- every one of these is a
  // raw field already returned by GET /register/{riskId} (state.activeRisk
  // on Risk View) or already carried on the Register grid row's own
  // data-reg-* attributes; approvalRequired alone is NOT part of the risk
  // record (it is an organization-level setting from GET /config) -- see
  // each caller for how it supplies it.
  //
  // handlers: { onView, onAnalysis, onResidual, onReviewAnalysis,
  //             onChangeStatus, onChangeOwner, onScope, onTreatmentWork,
  //             onAccept, onReview, onRaiseTask }. A handler that is
  // omitted means that item is not offered at all -- Risk View has no use
  // for "View risk" (the page already IS that view), so it simply does
  // not pass onView, exactly as Gap View/Exception View omit their own
  // "View" handler.
  // ===================================================================
  function buildRegisterMenu(fields, handlers) {
    fields = fields || {};
    handlers = handlers || {};
    const id = fields.riskRegisterId;
    const regClosed = fields.statusCode === "Closed" || fields.statusCode === "Retired";
    const regOption = fields.treatmentOptionCode || "";
    const openTasks = Number(fields.openTreatmentTaskCount || 0);
    const taskCount = Number(fields.treatmentTaskCount || 0);
    const reviewDue = !!fields.isReviewDue;
    const items = [];

    if (handlers.onView) {
      items.push({ icon: "fa-eye", label: "View risk", action: handlers.onView });
    }

    if (handlers.onAnalysis) {
      items.push({
        icon: "fa-magnifying-glass-chart",
        label: fields.analysisPending ? "Analysis (pending)" : "Analysis",
        applicable: !regClosed,
        action: handlers.onAnalysis
      });
    }

    if (handlers.onResidual) {
      items.push(Object.assign({
        icon: "fa-shield-halved",
        label: fields.residualPending === false
                 ? "Residual risk analysis" : "Residual risk analysis (not assessed)",
        action: handlers.onResidual
      }, residualMenuGate({
        status: fields.statusCode, analysisPending: fields.analysisPending,
        option: regOption, openTasks
      })));
    }

    if (handlers.onReviewAnalysis) {
      items.push({
        icon: "fa-gavel", label: "Review analysis",
        applicable: !regClosed && !!fields.approvalRequired,
        disabled: !!fields.analysisPending,
        disabledReason: "No analysis has been submitted for review yet. Complete the risk analysis first.",
        action: handlers.onReviewAnalysis
      });
    }

    if (handlers.onChangeStatus) {
      items.push({ icon: "fa-flag", label: "Change status", action: handlers.onChangeStatus });
    }
    if (handlers.onChangeOwner) {
      items.push({ icon: "fa-user-check", label: "Change owner", action: handlers.onChangeOwner });
    }

    if (handlers.onScope) {
      items.push({
        icon: "fa-diagram-project", label: "Practices & assets",
        applicable: !regClosed, action: handlers.onScope
      });
    }

    if (handlers.onTreatmentWork) {
      items.push({
        icon: "fa-list-check",
        label: openTasks > 0 ? `Risk treatment (${openTasks} open)`
             : taskCount > 0 ? "Risk treatment" : "Risk treatment (none raised)",
        applicable: !regClosed && regOption !== "Tolerate",
        disabled: !regOption,
        disabledReason: "Choose a treatment option in Risk analysis first.",
        action: handlers.onTreatmentWork
      });
    }

    if (handlers.onAccept) {
      items.push({
        icon: "fa-circle-check", label: "Accept risk",
        applicable: !regClosed,
        disabled: !!fields.analysisPending || !regOption,
        disabledReason: fields.analysisPending
            ? "Complete the risk analysis before accepting this risk."
            : "Choose a treatment option first.",
        action: handlers.onAccept
      });
    }

    if (handlers.onReview) {
      items.push({
        icon: "fa-rotate-left",
        label: reviewDue ? "Review risk (due)" : "Review risk",
        applicable: !regClosed,
        disabled: !!fields.analysisPending,
        disabledReason: "Complete the risk analysis before reviewing this risk.",
        action: handlers.onReview
      });
    }

    if (handlers.onRaiseTask) {
      items.push({
        icon: "fa-square-plus", label: "Raise additional task (via candidate)",
        applicable: !regClosed, action: handlers.onRaiseTask
      });
    }

    return items;
  }

  // Delegated ONCE at module scope, for both grids and the register
  // links. The old per-refresh wiring guarded itself with a dataset
  // flag; a single document-level listener is simpler and survives the
  // grids being re-rendered, which they are on every filter change.
  (function wireDelegation() {
    document.addEventListener("click", ev => {
      // Change request 2026-09-22: every [data-open-risk] link (the
      // Register grid's own Risk ID column, plus the same reference on
      // Accept-due, Review-due, Calendar and dashboard drill-downs) used
      // to open openRegisterDetail()'s regDetailModal -- a lighter
      // quick-look (Statement/Rating/Owner, no Print, no Actions, no
      // 4-step flow rail) that predates the full riskDetailPageView added
      // for Task H. Clarified with sir: the Register side of the product
      // should show the SAME full Risk View the 3-dot menu's own "View
      // risk" item opens, everywhere a registered risk is linked to, not
      // a second lighter one. openRegisterDetail() itself is untouched --
      // onReviewAnalysis's three call sites still use it directly (not
      // through this click path) purely to prime state.activeRisk before
      // opening the approval modal, and still do.
      const openRisk = ev.target.closest("[data-open-risk]");
      if (openRisk) {
        ev.preventDefault();
        openRiskDetailPage(Number(openRisk.dataset.openRisk));
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
          // A closed candidate will never be assessed again -- registered,
          // rejected, withdrawn or duplicated, it is finished. Hidden
          // rather than greyed: nothing the reader does brings it back.
          { icon: "fa-magnifying-glass-chart", label: "Assessment",
            applicable: isOpen,
            action: () => openAnalysisModal(id) }
        ]);
        return;
      }

      // ---- Expand / collapse a parent treatment task ------------------
      // Before the menu branch: the toggle is its own control and must
      // not also count as a click on the row it sits in.
      const twToggle = ev.target.closest("[data-tw-toggle]");
      if (twToggle) {
        ev.preventDefault(); ev.stopPropagation();
        toggleTreatmentChildren(twToggle);
        return;
      }

      // ---- Risk Treatment row menu (the 3 dots on a treatment task) ---
      // "Add Sub Task" here is the case the requirement describes: the
      // parent is the row the menu was opened on, so it is passed to the
      // common form and shown read-only. Nothing is guessed and nothing
      // is re-fetched -- state.treatmentTasks is the list already on
      // screen.
      const twTrigger = ev.target.closest(".pm-action-trigger[data-tw-menu]");
      if (twTrigger) {
        ev.preventDefault(); ev.stopPropagation();
        if (openMenuTrigger === twTrigger) { closeRowMenu(); return; }
        const taskId  = Number(twTrigger.dataset.twMenu);
        const isChild = twTrigger.dataset.twChild === "1";
        const closed  = twTrigger.dataset.twClosed === "1";
        const mandOpen = Number(twTrigger.dataset.twMandopen || 0);
        const task    = (state.treatmentTasks || []).find(t => t.taskId === taskId) || null;
        const riskId  = Number(document.getElementById("twRiskId").value || 0);

        openRowMenu(twTrigger, [
          { icon: "fa-arrow-up-right-from-square", label: "Open in Task Center",
            action: () => window.open(U(`/Practice/Index/tasks?taskId=${taskId}`), "_blank", "noopener") },

          // BRD §11: a child cannot have children of its own -- structural,
          // permanent, so hidden on a child row rather than greyed. A
          // closed task is likewise not somewhere work gets added.
          { icon: "fa-diagram-project", label: "Add Sub Task",
            applicable: !isChild && !closed,
            action: () => {
              const orgName = document.getElementById("regFilterOrganization")
                                ?.selectedOptions?.[0]?.textContent?.trim() || null;
              window.gracTaskForm.open({
                mode: "subtask",
                organizationId: state.organizationId,
                organizationName: orgName,
                // The parent, from the row itself.
                parentTask: {
                  taskId,
                  taskNumber: task?.taskNumber || null,
                  title: task?.title || null
                },
                // Open the parent before re-rendering, or the sub task
                // the user just created lands behind a closed chevron
                // and reads as "the save did nothing".
                onSaved: () => {
                  (state.twExpanded || (state.twExpanded = new Set())).add(taskId);
                  return refreshTreatmentState(riskId);
                }
              });
            } },

          // sp_task_assign has NO terminal guard -- it would happily move
          // a closed task to a new owner. The refusal is ours, and it is
          // a HIDE rather than a grey row: there is no work left to
          // reassign and no future state of this task in which there is.
          { icon: "fa-user-pen", label: "Reassign",
            applicable: !closed,
            action: () => openTaskAssignModal(taskId, riskId) },

          // COMPLETE, then CLOSE -- two different acts, deliberately both
          // offered and deliberately in this order.
          //
          //   Complete  the work was done. sp_task_complete enforces the
          //             BRD §12 mandatory-child gate, which is the rule
          //             this page's own subheading promises.
          //   Close     the task is being shut without being finished --
          //             superseded, duplicated, no longer relevant.
          //
          // Both satisfy the residual gate, which counts
          // "ClosedAt IS NOT NULL OR IsTerminal = 1" and does not care
          // which one got it there.
          // The two states side by side on one item:
          //   already closed -> never applicable again -> HIDDEN
          //   mandatory sub tasks open -> applicable, blocked, and the
          //   block clears when they close -> SHOWN, greyed, reason given
          { icon: "fa-circle-check", label: "Complete task",
            applicable: !closed,
            disabled: mandOpen > 0,
            disabledReason: `${mandOpen} mandatory sub task${mandOpen === 1 ? " is" : "s are"} still open. `
              + "BRD §12: the parent cannot be completed until they are done.",
            action: () => completeTreatmentTask(taskId, riskId, task) },

          { icon: "fa-lock", label: "Close task",
            applicable: !closed,
            action: () => closeTreatmentTask(taskId, riskId, task, mandOpen) }
        ]);
        return;
      }

      const regTrigger = ev.target.closest(".pm-action-trigger[data-reg-menu]");
      if (regTrigger) {
        ev.preventDefault(); ev.stopPropagation();
        if (openMenuTrigger === regTrigger) { closeRowMenu(); return; }
        const id = Number(regTrigger.dataset.regMenu);
        const regStatus = regTrigger.dataset.regStatus;
        // Read off the row rather than re-fetched: the grid already
        // carries every value these gates need, and a menu that fires a
        // request to decide what to render opens a visible beat late.
        //
        // Change request 2026-09-22: the item list itself now comes from
        // buildRegisterMenu() (above), the same function Risk View's own
        // Actions button calls -- see that function's header comment.
        const items = buildRegisterMenu(
          {
            riskRegisterId: id, statusCode: regStatus,
            analysisPending: regTrigger.dataset.regPending === "1",
            residualPending: regTrigger.dataset.regResidualPending !== "0",
            treatmentOptionCode: regTrigger.dataset.regOption || "",
            openTreatmentTaskCount: Number(regTrigger.dataset.regOpenTasks || 0),
            treatmentTaskCount: Number(regTrigger.dataset.regTaskCount || 0),
            isReviewDue: regTrigger.dataset.regReviewDue === "1",
            approvalRequired: !!state.config?.approvalRequired
          },
          {
            // The read-only details PAGE, not the old summary modal. The
            // modal is still what "Review analysis" below loads, because
            // that path wants state.activeRisk primed and then hides it.
            onView: () => openRiskDetailPage(id),
            // Stage 2 (216) — the scoring work lives here, not on the
            // candidate. Labelled "Analysis" to match what it produces.
            onAnalysis: () => openRiskAnalysisPage(id),
            // Migration 258 — the SECOND score, on a risk that has been
            // treated. Every branch of the gate lives in residualMenuGate()
            // (above buildRegisterMenu), shared in spirit with the Risk
            // Treatment page's button so one action cannot read as
            // available in one place and blocked in the other.
            onResidual: () => openResidualPage(id),
            // §19 — TWO different gates on one item, and they are different
            // kinds:
            //   approval not configured for the organisation  CONFIGURATION,
            //     nothing the reader does to this risk turns it on -> HIDDEN
            //   analysis never submitted                      PREREQUISITE,
            //     clears the moment it is analysed -> DISABLED, and the
            //     reason points at the Analysis item directly above.
            onReviewAnalysis: async () => { await openRegisterDetail(id); hide("regDetailModal"); openRegApprovalModal(id); },
            // UNGATED ON PURPOSE, INCLUDING ON A CLOSED RISK -- not an
            // oversight. sp_risk_register_status_set and _owner_set carry no
            // closed-state refusal (206): the only rule either enforces is
            // "closing needs a reason" (56174). Changing the status IS the
            // way a closed risk is reopened, so hiding it would leave every
            // other item on this menu permanently unreachable, and a risk
            // closed by mistake with no way back through the UI.
            onChangeStatus: () => openRegStatusModal(id),
            onChangeOwner:  () => openRegOwnerModal(id),
            // ---- migrations 261-264 ------------------------------------
            // Every gate below mirrors one the server enforces, and each
            // carries its OWN reason rather than a shared "not available".
            // A greyed item that cannot say why is a dead end.
            onScope: () => openScopePage(id),
            // Tolerate / Accept raises no treatment task AT ALL (§21) --
            // that is what choosing it means, so the item is not offered
            // rather than offered and greyed. Having no option chosen YET
            // is the opposite: it is the next thing to go and do, so the
            // item stays visible pointing at Risk analysis.
            onTreatmentWork: () => openTreatmentWorkModal(id),
            onAccept:        () => openAcceptancePage(id),
            onReview:        () => openReviewPage(id),
            // BRD §22 — 215's manual, candidate-gated raise. Kept because
            // 263 added an automatic path without closing this one: an
            // organisation that wants a human to confirm owner, SLA and
            // priority before work lands in a queue still has it.
            onRaiseTask: () => openTreatmentModal(id)
          }
        );
        openRowMenu(regTrigger, items);
        return;
      }

      // Risk View's own Actions button (change request, 2026-09-22;
      // markup fix same day) -- same trigger/menu machinery as the grid
      // rows above, but there is only ever one of these on the page, so
      // it needs no id in its data attribute the way data-reg-menu/
      // data-tw-menu carry one. Matched on [data-rd-menu] ALONE, not
      // .pm-action-trigger[data-rd-menu]: the button intentionally does
      // not carry that class (see its markup comment in risk-centre.cshtml
      // -- combining it with pm-button broke the button's own styling),
      // and data-rd-menu is unique to it, so the class is not needed to
      // disambiguate the match either.
      const rdTrigger = ev.target.closest("[data-rd-menu]");
      if (rdTrigger) {
        ev.preventDefault(); ev.stopPropagation();
        openRiskViewActionsMenu(rdTrigger);
        return;
      }

      // Row click-to-View (change request, 2026-09-22): every branch
      // above already returns for its own trigger or link, so reaching
      // here means the click landed elsewhere on the row. A Register row
      // (data-reg-view, set in refreshRegister()) opens the full Risk
      // View -- the same page its own Risk ID link and 3-dot "View risk"
      // both open. A Candidates row (data-cand-view, refreshCandidates())
      // opens its own quick-look modal instead -- a candidate has no
      // full page until it is registered. !ev.target.closest("a") keeps
      // the Risk ID link's own [data-open-risk] branch (above) as the
      // one that handles it, not this fallback.
      if (!ev.target.closest("a")) {
        const regRow = ev.target.closest("tr[data-reg-view]");
        if (regRow) { openRiskDetailPage(Number(regRow.dataset.regView)); return; }
        const candRow = ev.target.closest("tr[data-cand-view]");
        if (candRow) { openDetailModal(Number(candRow.dataset.candView)); return; }
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
            <td>${window.gracFormatDisplayDate(v.analysisOn)}</td>
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
    // Write-only, per registration -- there is nothing to pre-fill from
    // a prior save, unlike every field above it.
    setVal("anRegistrationNote", "");
    toggleOther("an", "Threat");
    toggleOther("an", "Vuln");

    // Chips for what this analysis already holds. The candidate has no
    // register id, so the selection endpoint cannot be used -- instead
    // the analysis row's own ids seed the chips, and its legacy free
    // text (threatId 0) is passed through as a pending chip.
    if (threatPickers.an) {
      const items = [];
      if (a?.threatId != null && Number(a.threatId) !== 0)
        items.push({ id: a.threatId, name: a.threatName || `#${a.threatId}` });
      const vItems = [];
      if (a?.vulnerabilityId != null && Number(a.vulnerabilityId) !== 0)
        vItems.push({ id: a.vulnerabilityId, name: a.vulnerabilityName || `#${a.vulnerabilityId}` });

      threatPickers.an.threat.setState(
        Number(a?.threatId) === 0 && a?.threatDescription
          ? items.concat([{ name: a.threatDescription }]) : items);
      threatPickers.an.vuln.setState(
        Number(a?.vulnerabilityId) === 0 && a?.vulnerabilityDescription
          ? vItems.concat([{ name: a.vulnerabilityDescription }]) : vItems);
    }

    show("riskAnalysisModal");
  }

  async function onAnalysisSubmit(ev, thenRegister) {
    if (ev) ev.preventDefault();
    const msg = document.getElementById("anMessage");
    msg.textContent = "";
    const id = Number(document.getElementById("anCandidateId").value);
    const statement = val("anStatement");
    if (!statement) { msg.textContent = "Risk statement is required."; return; }

    // await: assessmentPayload creates any pending legacy chip first.
    const gate = await assessmentPayload("an", msg);
    if (!gate) return;

    const result = await apiPost(`/${id}/analysis`, { riskStatement: statement, ...gate });
    if (result && result.success !== false && result.riskAnalysisId) {
      // The full set, after the analysis row exists to hang it off.
      // Deliberately not awaited into the failure path: the analysis is
      // already saved and its LEAD threat is on the row, so a failure
      // here loses the extra chips, not the assessment.
      // sp_risk_threat_selection_get falls back to the lead id when the
      // link table is empty, so the form still shows something -- see
      // 286, DECISION 1.
      await saveThreatSelection(
        `/analysis/${result.riskAnalysisId}/threats`, gate, msg);
    }
    if (!result || result.success === false) {
      msg.textContent = (result && result.error) || "Save failed.";
      return;
    }
    hide("riskAnalysisModal");
    await refresh();
    // The note was read from the form BEFORE this save, same as every
    // other field Save & register submits -- see startRegister's header
    // for why it no longer asks again afterwards.
    if (thenRegister) startRegister(id, val("anRegistrationNote"));
    // No "v4" in the title: the number is risk_analysis's history
    // sequence, not the risk's version (310), and a toast is exactly
    // where the two used to be confused.
    else dlg.alert("Assessment saved.", { title: "Assessment saved", type: "success" });
  }

  // The four shared assessment fields, validated and shaped once for
  // both forms. Returning null means "already told the user why not" —
  // §12's one-methodology rule applies to the client too: if the two
  // forms validated separately they would eventually disagree.
  // ASYNC since 285/286: a pending legacy "Others" chip has to become a
  // real master row before its id can be sent, and that is a round trip.
  async function assessmentPayload(prefix, msgEl) {
    const owner  = val(prefix + "Owner");
    const bf     = val(prefix + "BusinessFunction");
    const threatDesc = val(prefix + "ThreatDescription");
    const vulnDesc   = val(prefix + "VulnerabilityDescription");

    const fail = m => { if (msgEl) msgEl.textContent = m; return null; };

    const tp = threatPickers[prefix];
    if (!tp || !tp.threat || !tp.vuln)
      return fail("The threat picker did not load. Refresh the page and try again.");

    // Convert first, THEN read: convertPending turns each legacy chip
    // into a real row and selects it, so readState below sees the id it
    // just created rather than skipping the chip. This is the "convert
    // Others when the user saves" path -- a human has seen the wording
    // on screen and chosen to save it.
    try {
      await tp.threat.convertPending();
      await tp.vuln.convertPending();
    } catch (e) {
      return fail(e.message || "Could not add the new entry.");
    }

    const threatIds = tp.threat.readState();
    const vulnIds   = tp.vuln.readState();

    if (!threatIds.length) return fail("At least one threat is required.");
    if (!vulnIds.length)   return fail("At least one vulnerability is required.");
    if (!owner)  return fail("Risk owner is required.");
    if (!bf)     return fail("Business function is required.");

    // THE LEAD ID keeps 216 working untouched: risk_analysis.threat_id
    // has a foreign key and a CHECK, and sp_risk_register_list reads
    // ThreatName off it with no join. Lowest rather than first-clicked,
    // so re-saving the same selection does not shuffle which one leads
    // -- the same rule 286's header states for the SQL side.
    const lead = ids => Math.min.apply(null, ids);

    return {
      threatId:                 lead(threatIds),
      threatIds:                threatIds,
      threatDescription:        threatDesc || null,
      vulnerabilityId:          lead(vulnIds),
      vulnerabilityIds:         vulnIds,
      vulnerabilityDescription: vulnDesc || null,
      riskOwnerEmployeeId:      Number(owner),
      businessFunctionId:       Number(bf)
    };
  }

  // ---- Registration (BRD §8A) with §15 duplicate detection first -----
  //
  // The registration note used to be collected HERE, in a prompt() shown
  // after the assessment was already saved -- a second, separate ask the
  // analyst had not been told was coming. It is now a field on the
  // assessment form itself (Save & register reads it the same way it
  // reads owner and business function), so by the time this function
  // runs the note already exists; it is only threaded through to
  // doRegister, never asked for again. The one remaining interruption
  // between Save & register and the risk actually being registered is
  // the §15 duplicate-check modal below, which is a substantive warning
  // about a possible double-entry, not a confirmation of what was just
  // typed.
  async function startRegister(id, note) {
    state.pendingRegisterCandidateId = id;
    state.pendingRegisterNote = note || null;
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
    if (!rows.length) { await doRegister(id, state.pendingRegisterNote); return; }
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
    if (id) await doRegister(id, state.pendingRegisterNote);
  }

  // No prompt() here anymore -- the note was already typed on the
  // assessment form before Save & register was clicked (see
  // startRegister's header). Clicking that button is the confirmation;
  // asking again here, after the assessment is already saved, was the
  // exact double-ask this was rewritten to remove.
  async function doRegister(id, note) {
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
    // A new risk starts with no chips. clear() rather than setState([]),
    // so any error left over from a previous attempt goes too.
    if (threatPickers.cx) { threatPickers.cx.threat.clear(); threatPickers.cx.vuln.clear(); }
    show("riskCustomModal");
  }

  async function onCustomSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("cxMessage");
    msg.textContent = "";

    const statement = val("cxStatement");
    if (!val("cxTitle"))  { msg.textContent = "Risk title is required."; return; }
    if (!statement)       { msg.textContent = "Risk statement is required."; return; }
    const gate = await assessmentPayload("cx", msg);
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
    // A custom risk creates candidate, analysis AND register in one
    // call, so unlike the candidate form there IS a register id to key
    // the selection on.
    if (result.riskRegisterId)
      await saveThreatSelection(`/register/${result.riskRegisterId}/threats`, gate, msg);

    hide("riskCustomModal");
    dlg.alert(`Custom risk registered as ${result.riskNumber}.`, { title: "Risk registered", type: "success" });
    showTab("register");
    await refreshRegister();
  }

  // The second of the two calls described in 286, DECISION 1. Never
  // throws: the risk is already saved with its lead threat by the time
  // this runs, and turning a link-table hiccup into a red banner on a
  // successful save would say the wrong thing.
  async function saveThreatSelection(path, gate, msgEl) {
    try {
      await apiPost(path, {
        organizationId:   state.organizationId,
        threatIds:        gate.threatIds,
        vulnerabilityIds: gate.vulnerabilityIds
      });
    } catch (e) {
      if (msgEl) msgEl.textContent =
        "Saved, but the full threat list could not be recorded. Re-open and save again to retry.";
    }
  }

  // ====================================================================
  // Risk Details -- READ-ONLY FULL PAGE
  //
  // "View risk" on the register's 3-dot menu. One risk's whole life on
  // one page. Every read below is an EXISTING GET; nothing here needed a
  // new endpoint, a new procedure or a new column:
  //   /register/{id}                 context, inherent, treatment
  //                                  option, residual, acceptance,
  //                                  review, workflow stage -- 96 fields
  //                                  and this page needs no 97th
  //   /register/{id}/treatment-state gate, counts and the task rows
  //   riskMapping (readOnly)         practices + dependencies, which
  //                                  itself reads /mapping and
  //                                  /practice-context
  //
  // NOT ONE WRITE. refreshTreatmentState defaults to sync:true and POSTs
  // treatment-sync before reading, which is right on the Treatment and
  // Residual pages -- they act on the tasks. Here it is passed FALSE:
  // opening a risk to look at it must not move it to Monitoring.
  // ====================================================================

  // What the risk has actually reached. Each section is gated on the
  // DATA it needs, not on a stage string, because the two can disagree
  // (a risk can be Monitoring by status while its residual is unscored)
  // and the data is the thing being displayed.
  function riskReach(risk) {
    return {
      inherent:  !risk.analysisPending,
      // The decision, not the tasks: Tolerate raises no task at all and
      // is still a treatment decision that was taken.
      treatment: !!risk.treatmentOptionCode,
      scope:     !risk.analysisPending,
      residual:  risk.residualPending === false,
      accepted:  !!risk.acceptedOn
    };
  }

  // A section that has nothing to show yet says what has to happen
  // first. "Not applicable" alone reads as a broken feature.
  function rdNotYet(what, next) {
    return `<div class="rd-na">
      <span class="rd-na-tag">Not applicable yet</span>
      <p><strong>${escapeHtml(what)}</strong> ${escapeHtml(next)}</p>
    </div>`;
  }

  // The fields each section is REQUIRED to show are rendered even when
  // empty, as "Not available". dd() drops an empty value, which is right
  // for the optional extras -- a wall of "--" tells nobody anything --
  // but wrong for Owner or Score, where a missing row is
  // indistinguishable from a page that failed to load.
  function ddReq(label, value, isHtml) {
    const empty = value == null || value === "";
    return empty
      ? dd(label, `<span class="rd-none">Not available</span>`, true)
      : dd(label, value, isHtml);
  }

  // Change request 2026-09-22: Change status / Change owner / Review
  // analysis can now be reached from the Risk View page's own Actions
  // button, not only from the Register grid. Their submit handlers
  // already refresh the grid (refreshRegister()) -- that leaves Risk
  // View's own display stale if it is the page open when one of them is
  // used, since Risk View renders from a one-time snapshot (state.activeRisk)
  // taken when the page was opened, not from the grid. This helper is
  // the fix: if Risk View is the page currently showing AND it is showing
  // the SAME risk the submit just changed, it re-runs openRiskDetailPage()
  // to pull a fresh copy -- a no-op in every other case (grid open, a
  // different risk's page open, or the page not open at all).
  async function refreshRiskViewIfShowing(riskId) {
    const page = document.getElementById("riskDetailPageView");
    if (page && !page.hidden && state.activeRisk && state.activeRisk.riskRegisterId === riskId) {
      await openRiskDetailPage(riskId);
    }
  }

  async function openRiskDetailPage(riskId) {
    const risk = await apiGet(`/register/${riskId}`);
    if (!risk) { dlg.alert("Risk not found.", { type: "error" }); return; }
    state.activeRisk = risk;
    analysisReturnTab = "register";

    const reach = riskReach(risk);

    // The FULL threat/vulnerability sets (285/286). Optional: if the
    // call fails the context grid falls back to risk.threatName below,
    // which is the lead one -- degraded, not broken.
    const tvSet = await threatSelectionText(riskId);

    setText("rdPageTitle", `${risk.riskNumber} — ${risk.riskTitle}`);
    setText("rdPageSubtitle", "Everything recorded for this risk, read-only.");
    // ONE badge. This page used to carry the stage AND the record status
    // side by side, which is the duplication that prompted this review:
    // two chips, both read as "the status", frequently disagreeing
    // (Monitoring by record status while the stage says Residual due).
    document.getElementById("rdHeadStage").innerHTML = lifecycleChip(risk);

    showFullPage("riskDetailPageView");

    // ---- Stage rail --------------------------------------------------
    document.getElementById("rdFlow").innerHTML = [
      rdStep(1, "Inherent", reach.inherent,
             reach.inherent ? severityChip(risk.inherentRatingCode)
                            : `<span class="pm-hint">Not scored</span>`,
             reach.inherent
               ? `${escapeHtml(risk.likelihoodName || "?")} x ${escapeHtml(risk.impactName || "?")}`
               : "Analysis not completed"),
      rdStep(2, "Treatment", reach.treatment,
             escapeHtml(risk.treatmentOptionName || "Not chosen"),
             risk.treatmentTaskCount > 0
               ? `${(risk.treatmentTaskCount - (risk.openTreatmentTaskCount || 0))} of ${risk.treatmentTaskCount} tasks closed`
               : risk.treatmentOptionCode === "Tolerate" ? "No treatment task required"
               : reach.treatment ? "No task raised" : "No option chosen"),
      rdStep(3, "Residual", reach.residual,
             reach.residual ? severityChip(risk.residualRatingCode)
                            : `<span class="pm-hint">Not assessed</span>`,
             reach.residual
               ? `${escapeHtml(risk.residualLikelihoodName || "?")} x ${escapeHtml(risk.residualImpactName || "?")}`
               : "Residual analysis not done"),
      rdStep(4, "Acceptance", reach.accepted,
             reach.accepted ? `<span class="risk-status-chip risk-accepted">Accepted</span>`
                            : `<span class="pm-hint">Not accepted</span>`,
             reach.accepted && risk.acceptedOn
               ? `${window.gracFormatDateOnly(risk.acceptedOn)}${
                    risk.acceptedByName
                      ? ` — ${escapeHtml(personWithRole(risk.acceptedByName, risk.acceptedByRoleNames))}`
                      : ""}`
               : "Not yet accepted")
    // NO ARROW ELEMENTS -- see .risk-flow-4 in risk-centre.cshtml. The
    // shared .risk-flow rail is a fixed FIVE-track grid, 1fr auto 1fr auto
    // 1fr, sized for three steps and the two <li.risk-flow-arrow> between
    // them. Four steps plus three arrows is seven items in five tracks, and
    // the overflow wraps onto a second row. Four-step rails take four equal
    // tracks and carry the sequence with the step numbers plus a CSS chevron
    // drawn in the gap, so there is no extra grid item to size around.
    ].join("");

    // ---- 1. Risk context ---------------------------------------------
    document.getElementById("rdContext").innerHTML =
      ddReq("Risk ID",        risk.riskNumber) +
      dd("Title",             risk.riskTitle) +
      ddReq("Statement",      risk.riskStatement) +
      dd("Description",       risk.riskDescription) +
      dd("Category",          risk.riskCategoryNames || risk.riskCategoryName) +
      ddReq("Source",         (risk.sourceName || risk.sourceTypeCode || "") +
                              (risk.sourceReference ? ` — ${risk.sourceReference}` : "")) +
      // NO "Business unit". Removed from this section on request. The
      // COLUMN is untouched -- risk_register.business_unit still stores
      // it, sp_risk_register_get still returns it, and the register
      // detail drawer still shows it. This page simply stops asking for
      // it, so nothing is lost and nothing has to be migrated.
      dd("Business function", risk.businessFunctionName) +
      dd("Process",           risk.processName) +
      ddReq("Owner",          risk.riskOwnerName) +
      // HOW MANY PRACTICES, not just the one the risk arrived with.
      //
      // risk_register.linked_practice_id is a single column -- the
      // practice the risk was raised against. The real scope is
      // risk_practice_map (261), which is one row per mapped practice
      // and is what the Existing Controls panel below renders.
      //
      // The count needed no schema or procedure change:
      // sp_risk_register_get has returned MappedPracticeCount as
      // COUNT(*) over risk_practice_map since 265, and the API has
      // carried it since. It was simply never displayed.
      //
      // The originating practice keeps its name beside the count, when
      // there is one -- "3 Practices" alone would lose which practice
      // the risk came from, and that is the one this page's trace
      // section is built around.
      ddReq("Linked practice", practiceScopeCell(risk), true) +
      // The whole set when 286 could supply it, otherwise the single
      // legacy value. threatId/vulnerabilityId 0 means "typed in, not
      // picked" -- the same test openRegisterDetail uses.
      dd("Threats", tvSet?.threats
            || (risk.threatId === 0 ? risk.threatDescription : risk.threatName)) +
      dd("Vulnerabilities", tvSet?.vulnerabilities
            || (risk.vulnerabilityId === 0 ? risk.vulnerabilityDescription : risk.vulnerabilityName)) +
      dd("Risk cause",        risk.riskCause) +
      dd("Existing controls", risk.existingControls) +
      // NOT "Status". The heading badge and the four-step rail above
      // already carry the lifecycle; repeating it here as a second
      // "status" is what made the two look like rival answers to one
      // question. What is left is the stored §17 value under a name that
      // says what it is -- an operator-set record state that also drives
      // closure, the register filter and the accept/duplicate gates.
      ddReq("Record status", statusChip(risk.statusCode), true) +
      // THE RISK VERSION. One number for the whole risk, shown once, in
      // the section that describes the risk itself.
      //
      // It is NOT analysisVersion or residualVersion. Those are the
      // per-table history sequences of risk_analysis and
      // risk_residual_analysis, and this page used to show both as
      // "Version" inside their own panels -- which is why one risk
      // appeared to have two different versions at once.
      //
      // Only an acceptance moves this number (310). Registering is
      // version 1; each completed acceptance is the next one.
      ddReq("Risk version", riskVersionCell(risk), true) +
      dd("Registered",        `${window.gracFormatDisplayDate(risk.registeredOn)} by ${
                                 escapeHtml(risk.registeredByName || "system")}`, true) +
      dd("Next review",       risk.nextReviewDate
                                ? window.gracFormatDateOnly(risk.nextReviewDate) : null) +
      dd("Last reviewed",     risk.lastReviewedOn
                                ? window.gracFormatDateOnly(risk.lastReviewedOn) : null) +
      dd("Reviews",           risk.reviewCount ? String(risk.reviewCount) : null) +
      (risk.closedOn
        ? dd("Closed", `${window.gracFormatDisplayDate(risk.closedOn)} — ${
              escapeHtml(risk.closureReason || "")}`, true)
        : "");

    document.getElementById("rdTrace").innerHTML = riskTraceSteps(risk);

    // ---- 2. Inherent risk level --------------------------------------
    document.getElementById("rdInherent").innerHTML = !reach.inherent
      ? rdNotYet("This risk has not been analysed.",
                 "Its inherent likelihood and impact are set from the Analysis action.")
      : `<dl class="pm-detail-grid">
           ${ddReq("Likelihood", risk.likelihoodName
                 ? `${escapeHtml(risk.likelihoodName)}${
                     risk.likelihoodValue != null ? ` <span class="pm-hint">(${risk.likelihoodValue})</span>` : ""}`
                 : null, true)}
           ${ddReq("Impact", risk.impactName
                 ? `${escapeHtml(risk.impactName)}${
                     risk.impactValue != null ? ` <span class="pm-hint">(${risk.impactValue})</span>` : ""}`
                 : null, true)}
           ${ddReq("Score", risk.inherentRatingScore != null ? String(risk.inherentRatingScore) : null)}
           ${ddReq("Rating", risk.inherentRatingCode ? severityChip(risk.inherentRatingCode) : null, true)}
           ${dd("Assessed", risk.analysisOn
                 ? `${window.gracFormatDisplayDate(risk.analysisOn)}${
                     risk.analysedByName ? ` by ${escapeHtml(risk.analysedByName)}` : ""}` : null, true)}
           ${dd("Approval", risk.analysisApprovalStatusCode
                 ? `<span class="risk-status-chip">${escapeHtml(risk.analysisApprovalStatusCode)}</span>` : null, true)}
           ${dd("Potential consequence", risk.potentialConsequence)}
         </dl>`;

    // ---- 3. Treatment details ----------------------------------------
    // Tolerate raises no task by design (§21), so the task table is not
    // shown for it -- an empty grid would read as work missing rather
    // than work never required.
    const twWork  = document.getElementById("rdTreatmentWork");
    const showWork = reach.treatment && risk.treatmentOptionCode !== "Tolerate";
    if (twWork) twWork.hidden = !showWork;

    // Fetched BEFORE the summary is rendered, because the summary's
    // target date comes out of the task rows -- see below.
    let twState = null;
    if (showWork) {
      twState = await refreshTreatmentState(riskId, {
        gateId: "rdGate", tilesId: "rdTiles", bodyId: "rdTaskBody",
        residualBtnId: null, colspan: 7, readOnly: true, sync: false
      });
    }

    // THERE IS NO TREATMENT-LEVEL TARGET DATE IN THE SCHEMA. The date a
    // treatment is worked to belongs to its TASKS (DueAt), so the
    // earliest still-open one is the honest answer to "by when?" and the
    // label says which date it is rather than implying a field that
    // does not exist. The full set is in the task table below.
    const openDue = (twState?.tasks || [])
      .filter(t => t.dueAt && !t.closedAt && !t.isTerminal)
      .map(t => new Date(t.dueAt))
      .sort((a, b) => a - b)[0];

    const twStatus = !reach.treatment ? null
      : risk.treatmentOptionCode === "Tolerate" ? "No treatment task required"
      : (risk.treatmentTaskCount || 0) === 0    ? "No task raised yet"
      : (risk.openTreatmentTaskCount || 0) > 0
          ? `${risk.openTreatmentTaskCount} of ${risk.treatmentTaskCount} still open`
          : `All ${risk.treatmentTaskCount} closed`;

    document.getElementById("rdTreatment").innerHTML = !reach.treatment
      ? rdNotYet("No treatment option has been chosen.",
                 "The decision is recorded on the Analysis page, after the risk has been scored.")
      : `<dl class="pm-detail-grid">
           ${ddReq("Treatment option", risk.treatmentOptionName || risk.treatmentOptionCode)}
           ${ddReq("Treatment owner", risk.riskOwnerName)}
           ${ddReq("Treatment status", twStatus)}
           ${/* Plain text label: dd() escapes it, so markup here would
                 be printed rather than rendered. */""}
           ${ddReq("Target date (earliest open task)",
                   openDue ? window.gracFormatDisplayDateObj(openDue) : null)}
           ${dd("Decided", risk.treatmentDecidedOn
                 ? `${window.gracFormatDisplayDate(risk.treatmentDecidedOn)}${
                     risk.treatmentDecidedByName ? ` by ${escapeHtml(risk.treatmentDecidedByName)}` : ""}` : null, true)}
           ${dd("Tasks raised", String(risk.treatmentTaskCount || 0))}
           ${dd("Treatment plan", risk.residualTreatmentSummary)}
         </dl>`;

    // ---- 4 + 5. Existing controls and dependencies -------------------
    await riskMapping.mount("rdMapping", riskId, { readOnly: true, showHeading: false,
                                                   impactHostId: "rdImpactScope" });

    // ---- 6. Residual risk level --------------------------------------
    document.getElementById("rdResidual").innerHTML = !reach.residual
      ? rdNotYet("Residual risk has not been assessed.",
                 reach.treatment
                   ? "It is scored once the treatment work is complete."
                   : "It follows the treatment decision and the work raised for it.")
      : `<dl class="pm-detail-grid">
           ${ddReq("Likelihood", risk.residualLikelihoodName
                 ? `${escapeHtml(risk.residualLikelihoodName)}${
                     risk.residualLikelihoodValue != null ? ` <span class="pm-hint">(${risk.residualLikelihoodValue})</span>` : ""}`
                 : null, true)}
           ${ddReq("Impact", risk.residualImpactName
                 ? `${escapeHtml(risk.residualImpactName)}${
                     risk.residualImpactValue != null ? ` <span class="pm-hint">(${risk.residualImpactValue})</span>` : ""}`
                 : null, true)}
           ${ddReq("Score", risk.residualRatingScore != null ? String(risk.residualRatingScore) : null)}
           ${ddReq("Rating", risk.residualRatingCode ? severityChip(risk.residualRatingCode) : null, true)}
           ${dd("Assessed", risk.residualAssessedOn
                 ? `${window.gracFormatDisplayDate(risk.residualAssessedOn)}${
                     risk.residualAssessedByName ? ` by ${escapeHtml(risk.residualAssessedByName)}` : ""}` : null, true)}
           ${dd("Controls now in place", risk.residualControls)}
           ${dd("Analyst remarks", risk.residualRemarks)}
         </dl>`;

    // ---- 7. Risk acceptance ------------------------------------------
    document.getElementById("rdAcceptance").innerHTML = !reach.accepted
      ? rdNotYet("This risk has not been accepted.",
                 reach.residual
                   ? "Acceptance is recorded from the register's Accept risk action."
                   : "Acceptance follows the residual assessment.")
      : `<dl class="pm-detail-grid">
           ${ddReq("Decision", `<span class="risk-status-chip risk-accepted">Accepted</span>`, true)}
           ${ddReq("Accepted by", personWithRole(risk.acceptedByName, risk.acceptedByRoleNames))}
           ${ddReq("Accepted on", risk.acceptedOn ? window.gracFormatDisplayDate(risk.acceptedOn) : null)}
           ${ddReq("Justification", risk.acceptanceNote)}
           ${ddReq("Next review", risk.nextReviewDate
                 ? `${window.gracFormatDateOnly(risk.nextReviewDate)}${
                     risk.isReviewDue ? ` <span class="risk-status-chip risk-clarify">due</span>` : ""}` : null, true)}
           ${dd("Last reviewed", risk.lastReviewedOn
                 ? window.gracFormatDateOnly(risk.lastReviewedOn) : null)}
           ${dd("Reviews so far", String(risk.reviewCount || 0))}
         </dl>`;

    function rdStep(n, label, done, value, sub) {
      return `<li class="risk-flow-step rd-step${done ? " is-done" : " is-pending"}">
        <div class="k"><span class="n">${n}</span>${escapeHtml(label)}</div>
        <div class="v">${value}</div>
        <div class="s">${escapeHtml(sub)}</div>
      </li>`;
    }
  }

  // ===================================================================
  // Risk View's own Actions button (change request, 2026-09-22).
  //
  // Same item list, same every applicability/permission/status gate as
  // the Register row menu -- both call buildRegisterMenu() (above,
  // beside residualMenuGate) so there is exactly one place those rules
  // live. "View risk" is not offered: this page already IS that view,
  // exactly as Gap View/Exception View omit their own "View" item.
  //
  // approvalRequired is the one field buildRegisterMenu() needs that is
  // NOT on the risk record. state.config (loadConfig()/state.config)
  // cannot be reused here: it reflects whichever organisation the
  // Register tab's OWN filter dropdown happens to have selected, which
  // is not necessarily the organisation of the risk this page is
  // showing when reached by direct link (#riskId=). So this fetches
  // /config for the risk's OWN organisationId, independently, and never
  // touches state.config -- opening Risk View for one org's risk must
  // not silently change what the Register tab's own config reflects.
  // ===================================================================
  async function openRiskViewActionsMenu(trigger) {
    const risk = state.activeRisk;
    if (!risk) return;
    if (openMenuTrigger === trigger) { closeRowMenu(); return; }
    const id = risk.riskRegisterId;
    const cfg = await apiGet(`/config?organizationId=${risk.organizationId}`);
    const items = buildRegisterMenu(
      {
        riskRegisterId: id, statusCode: risk.statusCode,
        analysisPending: risk.analysisPending,
        residualPending: risk.residualPending,
        treatmentOptionCode: risk.treatmentOptionCode || "",
        openTreatmentTaskCount: risk.openTreatmentTaskCount || 0,
        treatmentTaskCount: risk.treatmentTaskCount || 0,
        isReviewDue: risk.isReviewDue,
        approvalRequired: !!cfg?.approvalRequired
      },
      {
        // Same handlers as the Register row menu's regTrigger branch
        // (wireDelegation, above) -- onView omitted, see header comment.
        onAnalysis: () => openRiskAnalysisPage(id),
        onResidual: () => openResidualPage(id),
        onReviewAnalysis: async () => { await openRegisterDetail(id); hide("regDetailModal"); openRegApprovalModal(id); },
        onChangeStatus: () => openRegStatusModal(id),
        onChangeOwner:  () => openRegOwnerModal(id),
        onScope: () => openScopePage(id),
        onTreatmentWork: () => openTreatmentWorkModal(id),
        onAccept:        () => openAcceptancePage(id),
        onReview:        () => openReviewPage(id),
        onRaiseTask: () => openTreatmentModal(id)
      }
    );
    openRowMenu(trigger, items);
  }

  // BRD §10 -- Risk Register -> Analysis -> Candidate -> Source.
  // Extracted from openRegisterDetail so the details page and the modal
  // render the SAME chain from one copy. A second trace builder would
  // have drifted the first time a source type was added.
  function riskTraceSteps(risk) {
    const steps = [`<span class="risk-trace-step"><strong>${escapeHtml(risk.riskNumber)}</strong></span>`];
    // "Assessment - Name", not "Assessment v4". The trace says WHERE the
    // risk came from; the one risk version is stated once, in Risk
    // Context, and analysis_version belongs to the Analysis history
    // table alone (310).
    steps.push(`<span class="risk-trace-step">Assessment${
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
    return steps.join(`<span class="risk-trace-arrow"><i class="fa-solid fa-arrow-right"></i></span>`);
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
      dd("Category",    risk.riskCategoryNames || risk.riskCategoryName) +
      // "Record status", consistent with every other risk surface: the
      // stored §17 value, not the derived workflow stage.
      dd("Record status", statusChip(risk.statusCode), true) +
      dd("Rating", risk.analysisPending
            ? `<span class="risk-status-chip risk-clarify">Analysis pending</span>
               <span class="pm-hint">score this risk from the Analysis action</span>`
            : severityChip(risk.inherentRatingCode) +
              ` <span class="pm-hint">${escapeHtml(risk.likelihoodName || "?")} x ${escapeHtml(risk.impactName || "?")}</span>`
              + (risk.analysisApprovalStatusCode === "Pending"
                   ? ` <span class="risk-status-chip risk-clarify">new rating awaiting approval</span>` : ""), true) +
      dd("Owner",       risk.riskOwnerName) +
      dd("Business unit", risk.businessUnit) +
      dd("Consequence", risk.potentialConsequence) +
      dd("Registered",  `${window.gracFormatDisplayDate(risk.registeredOn)} by ${escapeHtml(risk.registeredByName || "system")}`, true) +
      (risk.closedOn ? dd("Closed", `${window.gracFormatDisplayDate(risk.closedOn)} — ${escapeHtml(risk.closureReason || "")}`, true) : "");

    // BRD §10 — Risk Register -> Analysis -> Candidate -> Source.
    // Shared with the read-only details page; see riskTraceSteps().
    document.getElementById("regTrace").innerHTML = riskTraceSteps(risk);

    // BRD §22 — treatment work, if the organisation chose to raise any.
    mountRelatedTasks("regRelatedTasks", "Risk", risk.riskCandidateId || riskId);
    show("regDetailModal");
  }

  // ---- Stage 2: the scored analysis on a registered risk (216) -------
  async function openRiskAnalysisPage(riskId) {
    const risk = await apiGet(`/register/${riskId}`);
    if (!risk) { dlg.alert("Risk not found.", { type: "error" }); return; }
    if (!state.options) await loadOptions();
    if (!state.riskTypes) await loadRiskTypeOptions();
    state.activeRisk = risk;

    // Remember where we came from before the page hides the tabs.
    analysisReturnTab = state.tab || "register";

    document.getElementById("raRiskId").value = riskId;
    document.getElementById("raMessage").textContent = "";

    // The risk is the page's subject, so it is the heading — not a line
    // of metadata inside the form, which is what it had to be in a modal.
    setText("raPageTitle", `${risk.riskNumber} — ${risk.riskTitle}`);
    setText("raPageSubtitle",
      risk.analysisPending
        ? "This risk has no inherent rating yet. Score it, set its scope, and choose how it will be treated."
        : "Re-score the risk, adjust its scope, and confirm how it will be treated.");

    // Lifecycle and approval state belong in the heading bar on a page:
    // they qualify the whole screen rather than any one field.
    // lifecycleChip, not statusChip -- the same badge the register grid
    // and every other risk page now show.
    document.getElementById("raHeadStatus").innerHTML =
      lifecycleChip(risk)
      + (risk.analysisApprovalStatusCode === "Pending"
          ? ` <span class="risk-status-chip risk-clarify">Awaiting approval</span>` : "");

    document.getElementById("raMeta").innerHTML =
      dd("Risk ID", risk.riskNumber) +
      dd("Statement", risk.riskStatement) +
      dd("Threat", risk.threatId === 0 ? risk.threatDescription : risk.threatName) +
      dd("Vulnerability", risk.vulnerabilityId === 0 ? risk.vulnerabilityDescription : risk.vulnerabilityName) +
      dd("Owner", risk.riskOwnerName) +
      dd("Business function", risk.businessFunctionName) +
      dd("Business unit", risk.businessUnit) +
      dd("Source", risk.sourceName || risk.sourceTypeCode) +
      dd("Linked practice", risk.linkedPracticeName) +
      dd("Current inherent", risk.inherentRatingCode ? severityChip(risk.inherentRatingCode) : "not scored", true) +
      dd("Current residual", risk.residualRatingCode ? severityChip(risk.residualRatingCode) : "not assessed", true) +
      (risk.analysisApprovalStatusCode === "Pending"
        ? dd("Note", `<span class="pm-hint">Saving again replaces the version waiting for review.</span>`, true)
        : "");

    setVal("raLikelihood",  risk.likelihoodCode || "");
    setVal("raImpact",      risk.impactCode || "");
    // The five fields the modal had no room for. sp_risk_register_assess
    // has accepted all of them since 216; the modal sent only
    // potentialConsequence, so the rest were written NULL on every
    // re-assessment. Pre-filled from the register so a re-save preserves
    // what is there instead of blanking it.
    setVal("raDescription", risk.riskDescription || "");
    setVal("raCause",       risk.riskCause || "");
    setVal("raConsequence", risk.potentialConsequence || "");
    setVal("raControls",    risk.existingControls || "");
    setVal("raProcess",     risk.processName || "");
    setVal("raRemarks",     "");
    renderRating("ra");

    // Risk Type (313, 314). Render the options first (in case this is
    // the first risk opened this organisation and loadRiskTypeOptions()
    // has not painted them yet), then load and tick this risk's current
    // set — from the register, falling back to the newest analysis
    // version if the register link is empty (see sp_risk_type_selection_get).
    renderRiskTypeOptions("raRiskTypeOptions");
    const riskTypeSelection = await apiGet(`/register/${riskId}/risk-types`);
    setRiskTypeIds("raRiskTypeOptions",
      (riskTypeSelection && riskTypeSelection.riskTypes || []).map(t => t.riskTypeId));

    // Risk Category (375, 376). Same fetch-then-tick sequence as Risk
    // Type above -- render the combo now (state.options.categories is
    // already loaded, guaranteed by the `if (!state.options)` call at
    // the top of this function), then tick this risk's current set --
    // from the register, falling back to the newest analysis version if
    // the register link is empty (see sp_risk_category_selection_get).
    renderCategoryOptions([]);
    const categorySelection = await apiGet(`/register/${riskId}/risk-categories`);
    renderCategoryOptions(
      (categorySelection && categorySelection.riskCategories || []).map(c => c.riskCategoryId));

    // The treatment option already recorded, pre-selected. Re-saving the
    // same option is a no-op server-side (263 is idempotent on the task),
    // so showing the current choice costs nothing and prevents the
    // analyst wondering whether a blank means "none" or "not loaded".
    setRadio("raTreatment", risk.treatmentOptionCode || "");

    // Show the page BEFORE mounting the scope panel, so the form is on
    // screen while the mapping loads instead of the click appearing to
    // do nothing until the round trip finishes.
    showAnalysisPage();

    // The scope panel. Mounted AFTER the risk is loaded because it needs
    // the risk id, and awaited because mapping the risk's own practice
    // (sp_risk_mapping_sync_primary) is what puts the inherited assets on
    // screen -- the requirement's "should already be mapped" only looks
    // automatic if it has finished before the panel paints.
    //
    // showHeading:false — the panel above supplies the section heading,
    // and two headings for one section is what a copied component looks
    // like.
    await riskMapping.mount("raMapping", riskId, { readOnly: false, showHeading: false,
                                                   impactHostId: "raImpactScope" });
  }

  async function onRegAnalysisSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("raMessage");
    msg.textContent = "";
    const riskId = Number(document.getElementById("raRiskId").value);
    // Affordance only -- 56757 is the real guarantee, enforced by
    // sp_risk_category_selection_set. See the Risk Category section below.
    const categoryIds = getCategoryIds();
    if (!categoryIds.length)  { msg.textContent = "Select at least one Risk category."; return; }
    if (!val("raLikelihood")) { msg.textContent = "Likelihood is required."; return; }
    if (!val("raImpact"))     { msg.textContent = "Impact is required."; return; }
    // Affordance only -- 56731 is the real guarantee, enforced by
    // sp_risk_type_selection_set. See the Risk Type section below.
    const riskTypeIds = getRiskTypeIds("raRiskTypeOptions");
    if (!riskTypeIds.length) { msg.textContent = "Select at least one Risk Type (Confidentiality, Integrity or Availability)."; return; }

    const res = await apiPost(`/register/${riskId}/assess`, {
      // Legacy scalar column, still written by this same call (the "no
      // wrapper" precedent -- sp_risk_register_assess itself is
      // untouched). The full set goes to /risk-categories below.
      riskCategoryCode:     firstCategoryCode(),
      likelihoodCode:       val("raLikelihood"),
      impactCode:           val("raImpact"),
      // The five below are new to the page. They were always parameters
      // of sp_risk_register_assess; the modal simply had nowhere to ask
      // for them, so every re-assessment wrote them NULL.
      riskDescription:      val("raDescription") || null,
      riskCause:            val("raCause") || null,
      potentialConsequence: val("raConsequence") || null,
      existingControls:     val("raControls") || null,
      processName:          val("raProcess") || null,
      analystRemarks:       val("raRemarks") || null
    });
    if (!res || res.success === false) { msg.textContent = (res && res.error) || "Failed."; return; }

    // ---- Risk Type (313, 314), right after the rating is saved --------
    // res.riskAnalysisId is the version sp_risk_register_assess just
    // inserted. Sending it alongside the register id writes BOTH link
    // tables in one call, so the versioned analysis and the register's
    // current answer agree -- see sp_risk_type_selection_set's header.
    //
    // A failure here is reported but does not undo the analysis, same as
    // the treatment-option failure below: the rating IS saved.
    const riskTypeRes = await apiPost(`/register/${riskId}/risk-types`, {
      organizationId:     state.activeRisk?.organizationId ?? state.organizationId,
      riskAnalysisId:     res.riskAnalysisId || null,
      riskTypeIds
    });
    if (!riskTypeRes || riskTypeRes.success === false) {
      msg.textContent = `Analysis saved, but the risk type was not saved: `
                      + `${(riskTypeRes && riskTypeRes.error) || "unknown error"}`;
      await refreshRegister();
      return;
    }

    // ---- Risk Category (375, 376), same second call right after -------
    // res.riskAnalysisId is the version sp_risk_register_assess just
    // inserted; sending it alongside the register id writes BOTH link
    // tables in one call, exactly like the Risk Type call above.
    //
    // A failure here is reported but does not undo the analysis, same as
    // the risk-type and treatment-option failures: the rating IS saved.
    const categoryRes = await apiPost(`/register/${riskId}/risk-categories`, {
      organizationId:     state.activeRisk?.organizationId ?? state.organizationId,
      riskAnalysisId:     res.riskAnalysisId || null,
      riskCategoryIds:    categoryIds
    });
    if (!categoryRes || categoryRes.success === false) {
      msg.textContent = `Analysis saved, but the risk category was not saved: `
                      + `${(categoryRes && categoryRes.error) || "unknown error"}`;
      await refreshRegister();
      return;
    }

    // ---- The treatment option, AFTER the rating (migration 263) ------
    // Order is not incidental. sp_risk_treatment_option_set refuses while
    // analysis_pending = 1 (error 56569), and the task's priority is
    // derived from the rating this save just produced. Sending the option
    // first would be refused; sending it second gets the right priority.
    //
    // A failure here is reported but does not undo the analysis: the
    // rating IS saved, and telling the analyst otherwise would be false.
    const option = getRadio("raTreatment");
    let dispatch = null;
    if (option) {
      dispatch = await apiPost(`/register/${riskId}/treatment-option`, {
        treatmentOptionCode: option
      });
      if (!dispatch || dispatch.success === false) {
        msg.textContent = `Analysis saved, but the treatment option was not applied: `
                        + `${(dispatch && dispatch.error) || "unknown error"}`;
        await refreshRegister();
        return;
      }
    }

    // Saving returns to the list the page was opened from. backFrom...
    // also unmounts the mapping panel, so there is one teardown path
    // rather than one per exit.
    backFromAnalysisPage();

    // §19 — "saved and live" and "saved and waiting for an approver" are
    // different outcomes, so they get different messages.
    if (res.approvalRequired)
      dlg.alert(`Rated ${res.inherentRatingCode}. It needs approval before it becomes `
                + `the register's rating. ${res.approvalReason || ""}`,
                { title: "Analysis submitted", type: "warning" });
    else
      dlg.alert(`Inherent rating: ${res.inherentRatingCode}.`
                + treatmentOutcomeText(dispatch),
                { title: "Analysis saved", type: "success" });

    await refreshRegister();

    // Tolerate/Accept goes straight to acceptance -- that is the whole
    // difference between the fourth option and the other three, and
    // making the user find the row menu to continue would hide it.
    if (dispatch && dispatch.nextStep === "Acceptance") await openAcceptancePage(riskId);
    else if (dispatch && dispatch.taskCreated) await openTreatmentWorkModal(riskId);
  }

  // One sentence describing what the treatment decision did, used by the
  // analysis, residual and review flows so all three report it alike.
  function treatmentOutcomeText(dispatch) {
    if (!dispatch || dispatch.success === false) return "";
    if (dispatch.nextStep === "Acceptance")
      return ` Tolerate / Accept chosen — no treatment task raised; continue to Risk Acceptance.`;
    if (dispatch.taskCreated)
      return ` ${dispatch.treatmentOptionName} chosen — treatment task raised and assigned to the risk owner.`;
    if (dispatch.treatmentTaskId)
      return ` ${dispatch.treatmentOptionName} chosen — the existing treatment task was reused, not duplicated.`;
    return dispatch.treatmentOptionName ? ` ${dispatch.treatmentOptionName} chosen.` : "";
  }

  // ---- Residual Risk Analysis (migration 258) ------------------------
  //
  // The mirror image of openRiskAnalysisPage, and deliberately so: same
  // scale, same rating preview, same shape of form, and — since it grew
  // the same scope panel, treatment picker and history table — the same
  // full-page shell. The differences are the two that matter: it asks
  // what the treatment WAS, and it shows the inherent rating it is being
  // measured against, so the analyst scores a reduction rather than
  // scoring in a vacuum.
  async function openResidualPage(riskId) {
    const risk = await apiGet(`/register/${riskId}`);
    if (!risk) { dlg.alert("Risk not found.", { type: "error" }); return; }
    if (!state.options) await loadOptions();
    state.activeRisk = risk;

    // Where Back returns to. The page can be opened from the register row
    // menu or from the treatment page, and being dropped on a tab the
    // user did not come from is a small betrayal of context.
    analysisReturnTab = state.tab || "register";

    // Cleared before the first render, so the rail cannot show the
    // previous risk's treatment counts for the half-second before this
    // risk's state arrives.
    state.treatmentStateForResidual = undefined;

    document.getElementById("rrRiskId").value = riskId;
    document.getElementById("rrMessage").textContent = "";

    // The risk is the page's subject, so it is the heading — not the
    // first line of a metadata list, which is what it had to be inside
    // a modal whose header was a fixed title.
    setText("rrPageTitle", `${risk.riskNumber} — ${risk.riskTitle}`);
    setText("rrPageSubtitle",
      risk.residualPending
        ? "No residual assessment yet. Score what the treatment has left, and confirm how the risk is carried from here."
        : "Re-score what the treatment has left, and confirm how the risk is carried from here.");

    // Status qualifies the whole screen, so it sits in the heading bar
    // beside the Back button rather than inside the form.
    document.getElementById("rrHeadStatus").innerHTML = lifecycleChip(risk);

    // ---- Step 1: the risk, and the score it started with -------------
    // Split across two lists rather than one long one: "what the risk is"
    // and "what it scored" are two questions, and the second is the one
    // this page is measured against.
    document.getElementById("rrMeta").innerHTML =
      dd("Risk ID", risk.riskNumber) +
      dd("Statement", risk.riskStatement) +
      dd("Category", risk.riskCategoryNames || risk.riskCategoryName) +
      dd("Owner", risk.riskOwnerName) +
      dd("Business function", risk.businessFunctionName) +
      dd("Business unit", risk.businessUnit) +
      dd("Linked practice", risk.linkedPracticeName) +
      dd("Source", risk.sourceName || risk.sourceTypeCode);

    // FIVE FIELDS, AND ONE OF THEM IS THE ANALYST'S OWN WORDS.
    //
    // Cause and Controls at analysis are gone: the Analysis page stopped
    // asking for them (its Analysis detail section is one field now --
    // see the comment on .ra-grid-single in risk-centre.cshtml), so on
    // any risk analysed since, they render empty for good. A label with
    // nothing behind it is worse than no label.
    //
    // Score is gone too: the chip beside it already names the level, and
    // Likelihood x Impact is what produced the number, so the row was
    // the same fact a third time.
    //
    // What replaces them is "Impact analysis" -- risk.potentialConsequence,
    // which IS the value typed into the Analysis page's Impact Analysis
    // box (#raConsequence saves to that column). Same data, called what
    // the person who typed it was asked for, instead of the pre-216 label
    // "Potential consequence" that no field on the page uses any more.
    document.getElementById("rrInherent").innerHTML =
      dd("Inherent rating", severityChip(risk.inherentRatingCode), true) +
      dd("Likelihood", risk.likelihoodName) +
      dd("Impact", risk.impactName) +
      dd("Analysed", risk.analysisOn
          ? `${window.gracFormatDateOnly(risk.analysisOn)}${
              risk.analysedByName ? ` by ${escapeHtml(risk.analysedByName)}` : ""}${
              ""}`
          : null, true) +
      // isHtml FALSE -- this is the analyst's own typed text, so it is
      // escaped like every other value on the page. pm-detail-span is
      // the existing "this value is a sentence, not a field" modifier
      // (risk-centre.cshtml): in a 240px cell beside four one-line
      // fields, 4000 characters of prose wraps to a column of its own
      // height.
      dd("Impact analysis", risk.potentialConsequence, false, "pm-detail-span");

    // ---- Step 2 (the part that comes from the register row) ----------
    // The task list, the counts and the gate come from
    // sp_risk_treatment_state below; these four are the decision itself,
    // which lives on the register.
    document.getElementById("rrTreatmentMeta").innerHTML =
      dd("Treatment strategy", risk.treatmentOptionName || "not chosen") +
      dd("Decided", risk.treatmentDecidedOn
          ? `${window.gracFormatDateOnly(risk.treatmentDecidedOn)}${
              risk.treatmentDecidedByName ? ` by ${escapeHtml(risk.treatmentDecidedByName)}` : ""}`
          : null, true) +
      dd("Risk owner", risk.riskOwnerName) +
      // The register's own stage chip, not a raw code -- the same cell
      // renderer the Risk Register grid uses, so the two screens name
      // this risk's stage identically.
      dd("Current stage", stageCell(risk), true);

    // ---- Acceptance, as it stands ------------------------------------
    document.getElementById("rrAcceptance").innerHTML =
      risk.acceptedOn
        ? dd("Accepted", `${window.gracFormatDateOnly(risk.acceptedOn)}${
              risk.acceptedByName
                ? ` by ${escapeHtml(personWithRole(risk.acceptedByName, risk.acceptedByRoleNames))}`
                : ""}`, true) +
          dd("Next review", risk.nextReviewDate
              ? window.gracFormatDateOnly(risk.nextReviewDate) : "not set") +
          dd("Last reviewed", risk.lastReviewedOn
              ? window.gracFormatDateOnly(risk.lastReviewedOn) : null) +
          dd("Reviews", risk.reviewCount != null ? String(risk.reviewCount) : null) +
          dd("Rationale", risk.acceptanceNote)
        // Wrapped like every dd() pair, and spanning: rrAcceptance is a
        // .pm-detail-grid, where the item is the pair, and this sentence
        // needs the row rather than one 240px cell.
        : `<div class="pm-detail-item pm-detail-span"><dt>Accepted</dt>`
        + `<dd><span class="pm-hint">Not accepted yet. `
        + `Use <strong>Save &amp; accept risk</strong> below to record the acceptance decision `
        + `against this residual score.</span></dd></div>`;

    // Pre-fill from the current residual version if there is one, so a
    // re-assessment starts from what was last recorded rather than from
    // an empty form the analyst has to reconstruct.
    setVal("rrLikelihood", risk.residualLikelihoodCode || "");
    setVal("rrImpact",     risk.residualImpactCode || "");
    // The Justification card is gone; only the remark survived, and it
    // starts empty because it belongs to THIS assessment, not the last
    // one. The treatment summary and controls it used to prefill are
    // shown read-only elsewhere on the page instead.
    setVal("rrRemarks",    "");
    renderRating("rr");
    renderResidualDelta();

    // The rail, drawn from the register row alone so it is on screen with
    // the rest of step 1. Step 2's half is filled in below, once the
    // treatment state has been read.
    renderResidualFlow();

    // Show the page BEFORE the scope panel, treatment state and history
    // load, so the form is on screen while they arrive instead of the
    // click appearing to do nothing until three round trips finish.
    showResidualPage();

    // ---- Step 2, from treatment's own source --------------------------
    // The SAME renderer the Risk Treatment page uses, pointed at this
    // page's hosts and told not to sweep: a read-only section must not
    // move a risk's status as a side effect of being looked at.
    const st = await refreshTreatmentState(riskId, {
      gateId: "rrGate", tilesId: "rrTiles", bodyId: "rrTaskBody",
      residualBtnId: null, colspan: 7, readOnly: true, sync: false
    });
    // Kept so the rail can be redrawn on every score change without
    // asking the server what the treatment state was again.
    state.treatmentStateForResidual = st;

    // TREATMENT NOT FINISHED IS THE THING THE READER MUST NOT MISS.
    // sp_risk_residual_analysis_save refuses this case (56574) and that
    // refusal is the actual rule -- this is the warning that stops the
    // analyst assuming the score they are about to type describes
    // completed work. It is stated twice on purpose: on the gate beside
    // the tasks, and beside the score itself three panels down.
    //
    // It says what IS true, not what the server will do. "Saving will be
    // refused" is only certain while treatment tasks are open (56574);
    // the gate closes for other reasons too -- no option chosen, Tolerate,
    // no task raised -- and some of those still save. Promising a refusal
    // that then does not happen would teach the analyst to disbelieve the
    // banner, so the refusal is only named in the case that guarantees it.
    const warn = document.getElementById("rrIncompleteWarning");
    if (warn) {
      const incomplete = !!st && !st.residualAvailable;
      const openTasks  = st ? (st.openTreatmentTaskCount || 0) : 0;
      warn.hidden = !incomplete;
      warn.textContent = incomplete
        ? `Treatment is not complete — ${st.reason} `
          + `A residual score recorded now would not describe finished treatment.`
          + (openTasks > 0
              ? ` Saving is refused while any treatment task is still open.` : "")
        : "";
    }
    // Now the rail knows what step 2 is worth.
    renderResidualFlow(st);

    // showHeading:false — the pm-panel around this host supplies the
    // section heading, exactly as on the analysis page.
    // impactReadOnly: the scope panel stays editable (a residual
    // assessment may find the risk now reaches different practices) but
    // Impact Details does not -- it was established at Analysis and is
    // revised at Review. See mount()'s header.
    await riskMapping.mount("rrMapping", riskId, { readOnly: false, showHeading: false,
                                                   impactHostId: "rrImpactScope",
                                                   impactReadOnly: true });
    await renderResidualHistory(riskId);
  }

  // ---- The Inherent -> Treatment -> Residual rail ---------------------
  //
  // Reads state.activeRisk and, when it has been fetched, the treatment
  // state. NOTHING IS FETCHED HERE: it renders what the page already
  // knows, which is what lets it be called again on every change of the
  // two selects without a round trip per keystroke.
  //
  // Step 3 shows the rating being CHOSEN, resolved from the same matrix
  // the preview uses, so the rail and the preview cannot disagree.
  function renderResidualFlow(st) {
    const host = document.getElementById("rrFlow");
    const risk = state.activeRisk;
    if (!host || !risk) return;

    // Step 2's summary line: the option, then how the work stands.
    const total  = st ? (st.treatmentTaskCount || 0) : null;
    const open   = st ? (st.openTreatmentTaskCount || 0) : null;
    const done   = st ? (st.closedTreatmentTaskCount || 0) : null;
    const twWarn = !!st && !st.residualAvailable;
    const twSub  = st === undefined ? "Loading treatment state..."
                 : !st              ? "Treatment state unavailable"
                 : total === 0      ? "No treatment task raised"
                 : open > 0         ? `${done} of ${total} tasks closed — ${open} still open`
                                    : `All ${total} task${total === 1 ? "" : "s"} closed`;

    // Step 3: what is on the form right now, falling back to what is
    // saved. resolveRating returns the same cell renderRating uses.
    const live = resolveRating(val("rrLikelihood"), val("rrImpact"));
    const resCode = live ? live.ratingCode : risk.residualRatingCode;
    const resSub  = live
      ? `${escapeHtml(optionName("likelihood", val("rrLikelihood")))}`
        + ` x ${escapeHtml(optionName("impact", val("rrImpact")))}`
        + (live.ratingScore != null ? ` — score ${live.ratingScore}` : "")
      : risk.residualRatingCode
        ? `${escapeHtml(risk.residualLikelihoodName || "?")} x ${escapeHtml(risk.residualImpactName || "?")}`
        : "Not assessed yet";

    // Step 4 is what replaced the treatment-option radios: the analyst
    // used to be asked where the risk goes next, and is now simply told.
    // Assessing the residual risk sets residual_pending = 0, which makes
    // the stage AcceptanceDue -- so acceptance is not a choice made here,
    // it is the consequence of finishing this page.
    const accepted = !!risk.acceptedOn;

    // NO ARROW ITEMS. This rail carries .risk-flow-4 (four equal tracks,
    // CSS chevrons drawn in the gaps) precisely because seven items --
    // four steps and three <li> arrows -- do not fit the shared rail's
    // five tracks, which is what wrapped Risk acceptance onto a second
    // row with an orphaned arrow beside it. The Review rail still has
    // three steps and keeps its arrow items.
    host.innerHTML =
        step(1, "Inherent risk",
             severityChip(risk.inherentRatingCode),
             `${escapeHtml(risk.likelihoodName || "?")} x ${escapeHtml(risk.impactName || "?")}`)
      + step(2, "Risk treatment",
             escapeHtml(risk.treatmentOptionName || "Not chosen"),
             twSub, { warn: twWarn })
      + step(3, "Residual risk",
             resCode ? severityChip(resCode) : `<span class="pm-hint">Pending</span>`,
             resSub, { current: true })
      + step(4, "Risk acceptance",
             accepted ? `<span class="pm-badge">Accepted</span>`
                      : `<span class="pm-hint">Next</span>`,
             accepted
               ? `Accepted ${risk.acceptedOn ? window.gracFormatDateOnly(risk.acceptedOn) : ""}`
               : "Goes here automatically once the residual risk is saved");

    function step(n, label, value, sub, o) {
      o = o || {};
      return `<li class="risk-flow-step${o.current ? " is-current" : ""}${o.warn ? " is-warn" : ""}">
        <div class="k"><span class="n">${n}</span>${escapeHtml(label)}</div>
        <div class="v">${value}</div>
        <div class="s">${sub}</div>
      </li>`;
    }
  }

  // The matrix lookup renderRating does, lifted out so the rail and the
  // delta line can ask the same question without re-reading the DOM
  // preview's text. One resolver, so three places cannot disagree about
  // what a likelihood and an impact are worth.
  function resolveRating(likelihoodCode, impactCode) {
    if (!state.options || !likelihoodCode || !impactCode) return null;
    const lk = state.options.likelihood.find(x => x.code === likelihoodCode);
    const im = state.options.impact.find(x => x.code === impactCode);
    if (!lk || !im) return null;
    return state.options.matrix.find(c =>
      c.likelihoodValue === lk.levelValue && c.impactValue === im.levelValue) || null;
  }

  // "L3" is a code; "Likely" is what the organisation calls it. The
  // selects show names, so the rail beside them must too.
  function optionName(kind, code) {
    if (!code) return "?";
    return state.options?.[kind]?.find(x => x.code === code)?.name || code;
  }

  // Residual scoring changed: the preview, the delta against inherent,
  // and the rail's third step all describe the same choice, so they are
  // updated together rather than by three listeners.
  function onResidualScoreChanged() {
    renderRating("rr");
    renderResidualDelta();
    renderResidualFlow(state.treatmentStateForResidual);
  }

  // Inherent -> residual, in words. The whole purpose of scoring twice is
  // the difference between the two numbers, and a page that shows both
  // but never subtracts them leaves that arithmetic to the reader.
  function renderResidualDelta() {
    const out  = document.getElementById("rrDelta");
    const risk = state.activeRisk;
    if (!out || !risk) return;
    const cell = resolveRating(val("rrLikelihood"), val("rrImpact"));
    if (!cell || !risk.inherentRatingCode) {
      out.innerHTML = `<span class="pm-hint">Select a residual likelihood and impact.</span>`;
      return;
    }
    const before = risk.inherentRatingScore;
    const after  = cell.ratingScore;
    const move   = (before == null || after == null) ? null
                 : after < before ? "reduced" : after > before ? "increased" : "unchanged";
    out.innerHTML =
      severityChip(risk.inherentRatingCode)
      + `<span class="arrow"><i class="fa-solid fa-arrow-right"></i></span>`
      + severityChip(cell.ratingCode)
      + (move ? ` <span class="pm-hint">exposure ${move}`
                + (move !== "unchanged" ? ` (${before} &rarr; ${after})` : "") + `</span>` : "");
  }

  // BRD §20 — every retained version. Each row carries the inherent
  // rating AS IT STOOD at the time, frozen by the migration, so an old
  // version still reads correctly after the inherent risk is re-scored.
  async function renderResidualHistory(riskId) {
    const host = document.getElementById("rrHistory");
    if (!host) return;
    const rows = await apiGet(`/register/${riskId}/residual/history`) || [];
    host.innerHTML = rows.length
      ? `<table><thead><tr><th>Ver</th><th>Likelihood</th><th>Impact</th>
           <th>Inherent</th><th>Residual</th><th>Treatment</th><th>Assessed</th><th>By</th></tr></thead><tbody>` +
        rows.map(v => `<tr${v.isCurrent ? ' style="font-weight:600"' : ""}>
            <td>v${v.residualVersion}</td>
            <td>${escapeHtml(v.residualLikelihoodName || "--")}</td>
            <td>${escapeHtml(v.residualImpactName || "--")}</td>
            <td>${v.inherentRatingCode ? severityChip(v.inherentRatingCode) : "--"}</td>
            <td>${v.residualRatingCode ? severityChip(v.residualRatingCode) : "--"}</td>
            <td>${escapeHtml(v.treatmentSummary || "--")}</td>
            <td>${window.gracFormatDisplayDate(v.assessedOn)}</td>
            <td>${escapeHtml(v.assessedByName || "--")}</td>
          </tr>`).join("") + `</tbody></table>`
      : `<p class="pm-hint">No residual assessment yet for this risk.</p>`;
  }

  // thenAccept: the "Save & accept risk" button. It saves FIRST and then
  // opens acceptance — accepting a risk while an unsaved residual score
  // sits on screen would record an acceptance of a number that was never
  // persisted.
  async function onResidualSubmit(ev, thenAccept) {
    if (ev) ev.preventDefault();
    const msg = document.getElementById("rrMessage");
    msg.textContent = "";
    const riskId = Number(document.getElementById("rrRiskId").value);
    if (!val("rrLikelihood")) { msg.textContent = "Residual likelihood is required."; return; }
    if (!val("rrImpact"))     { msg.textContent = "Residual impact is required."; return; }

    // No rating in the payload. The server resolves it from the
    // organisation's matrix; a client-supplied score could disagree
    // with the matrix, and then the two columns stop being comparable.
    //
    // treatmentOptionCode is deliberately NOT sent any more. The residual
    // analysis no longer concludes with a treatment decision -- assessing
    // the residual risk IS the conclusion, and the risk goes to
    // acceptance from here. sp_risk_residual_analysis_save only invokes
    // sp_risk_treatment_option_set when an option is passed, so omitting
    // it means nothing is re-dispatched.
    //
    // treatmentSummary and residualControls are not sent either: they
    // were the Justification card, and both are already on the page as
    // read-only facts (the treated tasks in step 2, the controls in the
    // scope panel). Retyping them created a second copy that could
    // disagree with the first.
    const res = await apiPost(`/register/${riskId}/residual`, {
      residualLikelihoodCode: val("rrLikelihood"),
      residualImpactCode:     val("rrImpact"),
      analystRemarks:         val("rrRemarks") || null
    });
    // 56454-56457 and 56574 arrive here verbatim and name the rule that
    // refused, so they are shown rather than replaced with "Failed."
    if (!res || res.success === false) { msg.textContent = (res && res.error) || "Failed."; return; }

    // One exit path: backFromFullPage() unmounts the mapping panel, hides
    // the page, restores the tab chrome and returns to the tab this was
    // opened from -- the same route Back and Cancel take.
    backFromFullPage();
    await refreshRegister();

    if (thenAccept) { await openAcceptancePage(riskId); return; }

    // The Accept tab's count changes the moment the residual is
    // assessed, because the stage becomes AcceptanceDue -- so refresh it
    // rather than leave a stale badge behind.
    refreshAcceptBadge();
    if (state.tab === "accept") await refreshAcceptDue();

    // Says where the risk went. It is no longer obvious from the form
    // now that this page asks for no treatment decision, so the message
    // has to carry it.
    dlg.alert(`Inherent ${res.inherentRatingCode || "?"} -> residual ${res.residualRatingCode}. `
            + `This risk is now waiting on Accept Risk.`,
              { title: "Residual analysis saved", type: "success" });
  }

  // ===================================================================
  // Scope: practices and assets  (migrations 261, 262)
  //
  // ONE COMPONENT, MOUNTED IN FOUR PLACES
  // -------------------------------------
  // Risk analysis, residual analysis, review, and the standalone scope
  // modal all need the same panel with the same add/remove semantics.
  // Four copies of that markup would be four places for the removal
  // rules to drift -- and the removal rules are the subtle part:
  // unmapping a practice must not steal an asset another practice still
  // needs, and un-mapping a direct asset that a practice also reaches
  // must leave it in place, relabelled.
  //
  // So it is built the way __gracRelatedTasks already is in this file:
  // an empty host div, a mount() that fills it, a clear() that empties
  // it. Nothing about it is specific to the modal it happens to be in.
  //
  // WHAT IT DOES NOT DO
  // -------------------
  // It does not decide the badge on an asset. sp_risk_mapping_get
  // returns SourceLabel already resolved, because "is this asset here
  // because of the primary practice, an additional one, a direct
  // mapping, or both?" is a rule, and rules live in SQL.
  // ===================================================================
  const riskMapping = (() => {
    // Per-host state, so two mounted panels cannot overwrite each
    // other's risk id -- which would be a very quiet bug.
    const hosts = new Map();

    // showHeading defaults TRUE so the three modal mounts are unchanged.
    // The full page passes false because its own pm-panel already carries
    // the section heading, and two headings for one section is what a
    // copied component looks like.
    //
    // TWO HOSTS, ONE COMPONENT, ONE FETCH -- opts.impactHostId.
    //
    // Impact Details has to sit ABOVE Existing Controls, and Existing
    // Controls is a pm-panel with its own <h2>: no ordering inside that
    // panel can put a section above its heading. So the impact section is
    // rendered into a second element, in its own panel above, while the
    // practices go into the main host. Both still come from the ONE
    // /mapping call and the one refresh() -- the alternative, a second
    // component, would mean a second fetch of the same rows and two
    // places for the same save to go wrong.
    //
    // Omit impactHostId and both sections render into the main host as
    // before, so a caller that has only one element still works.
    async function mount(hostId, riskId, opts = {}) {
      const host = document.getElementById(hostId);
      if (!host) return;
      // impactReadOnly is SEPARATE from readOnly, and defaults to it.
      //
      // Residual Analysis needs the two halves in different modes: the
      // scope panel stays editable, because a residual assessment may
      // legitimately find the risk now reaches different practices, but
      // Impact Details is read-only there -- it was established at
      // Analysis and is revised at Review, and editing it mid-residual
      // would change the thing being measured while measuring it.
      // Every other mount passes nothing and keeps one mode for both.
      hosts.set(hostId, {
        riskId,
        readOnly: !!opts.readOnly,
        impactReadOnly: opts.impactReadOnly === undefined
          ? !!opts.readOnly
          : !!opts.impactReadOnly,
        showHeading: opts.showHeading !== false,
        impactHostId: opts.impactHostId || null
      });
      host.innerHTML = `<p class="pm-hint">Loading practices and assets...</p>`;
      const ih = opts.impactHostId ? document.getElementById(opts.impactHostId) : null;
      if (ih) ih.innerHTML = `<p class="pm-hint">Loading impact details...</p>`;
      await refresh(hostId);
    }

    function clear(hostId) {
      const st = hosts.get(hostId);
      const host = document.getElementById(hostId);
      if (host) host.innerHTML = "";
      // The impact host is emptied from the state we are about to drop,
      // not from a second argument at every call site -- backFromFullPage
      // clears four hosts and must not have to know each one's twin.
      if (st && st.impactHostId) {
        const ih = document.getElementById(st.impactHostId);
        if (ih) ih.innerHTML = "";
      }
      hosts.delete(hostId);
    }

    async function refresh(hostId) {
      const st = hosts.get(hostId);
      const host = document.getElementById(hostId);
      if (!st || !host) return;

      // Practice context (284) is fetched alongside the mapping, not
      // after it, so the panel still renders in one pass. It is
      // non-essential decoration: if it fails the practices still list,
      // just without provenance or tasks.
      // /mapping/options was fetched here and its result never read --
      // it fed the flat practice <select> that migration 282 replaced
      // with the cascading Practice Picker, which loads its own levels
      // on demand. Dropped rather than left as a round trip whose answer
      // goes in the bin.
      const [data, context] = await Promise.all([
        apiGet(`/register/${st.riskId}/mapping`),
        state.organizationId
          ? apiGet(`/register/${st.riskId}/practice-context?organizationId=${encodeURIComponent(state.organizationId)}`)
              .catch(() => null)
          : Promise.resolve(null)
      ]);
      const impactHost = st.impactHostId ? document.getElementById(st.impactHostId) : null;
      if (!data) {
        host.innerHTML = `<p class="pm-hint">Scope could not be loaded.</p>`;
        // The impact host would otherwise keep its "Loading..." line for
        // good, which reads as a hang rather than a failure.
        if (impactHost) impactHost.innerHTML = `<p class="pm-hint">Impact details could not be loaded.</p>`;
        return;
      }

      st.orgId = state.organizationId;

      // practiceId -> { context row, tasks[] }
      st.practiceContext = new Map();
      if (context) {
        (context.practices || []).forEach(c =>
          st.practiceContext.set(Number(c.practiceId), { ctx: c, tasks: [] }));
        (context.tasks || []).forEach(t => {
          const entry = st.practiceContext.get(Number(t.practiceId));
          if (entry) entry.tasks.push(t);
        });
      }

      const practices  = data.practices    || [];
      const categories = data.categories   || [];
      const deps       = data.dependencies || [];

      // Bucket the mapped rows by category once.
      const byCat = new Map();
      deps.forEach(d => {
        if (!byCat.has(d.dependencyTypeId)) byCat.set(d.dependencyTypeId, []);
        byCat.get(d.dependencyTypeId).push(d);
      });

      // WHAT EACH PRACTICE ALREADY BRINGS IN, per practice, read-only.
      //
      // The practice card used to state only a count ("Dependencies: 7"),
      // which said how many without ever saying which. The rows to answer
      // that are already on the page: sp_risk_mapping_get (267) returns
      // SourcePractices as STRING_AGG(practice_name, ', ') for every
      // inherited dependency, so the list is derived here with no extra
      // call and no schema change.
      //
      // A dependency with no SourcePractices is a direct one -- added on
      // this risk rather than inherited from a practice -- and belongs to
      // no card. It appears in Impact Details only.
      const catName = new Map(categories.map(c => [c.dependencyTypeId, c.dependencyTypeName]));
      const depsByPractice = new Map();
      deps.forEach(d => {
        const src = String(d.sourcePractices || "").trim();
        if (!src) return;
        // The separator is ", ". A practice name may itself contain a
        // comma, so a name that matches no whole token is still accepted
        // as a substring rather than silently dropped from its own card.
        const tokens = src.split(",").map(s => s.trim()).filter(Boolean);
        practices.forEach(p => {
          const name = String(p.practiceName || "").trim();
          if (!name) return;
          if (!tokens.includes(name) && src.indexOf(name) < 0) return;
          const key = Number(p.practiceId);
          if (!depsByPractice.has(key)) depsByPractice.set(key, []);
          depsByPractice.get(key).push({
            categoryName: catName.get(d.dependencyTypeId) || "Other",
            objectName:   d.dependencyObjectName || `#${d.dependencyObjectId}`,
            roleNames:    d.roleNames || ""
          });
        });
      });

      // Load every category's object list UP FRONT, exactly as
      // renderDependencyTable() does on the Operationalize page. Five
      // categories is a small enough fan-out to pay once, and a combo
      // that populates on focus cannot show its selected labels on the
      // trigger before it is opened -- which is most of the point of
      // this widget.
      // Keyed on impactReadOnly, not readOnly: the object lists and the
      // asset taxonomy exist to fill the Impact Details pickers and
      // nothing else. A read-only impact table renders chips, has no
      // Asset cascade to narrow and no picker to fill, so both would be
      // fetches whose results nothing reads -- five of them plus the
      // taxonomy, on Residual as well as View Risk and Accept.
      const taxonomyPromise = st.impactReadOnly ? Promise.resolve(null) : loadAssetTaxonomy();
      const lists = await Promise.all(categories.map(async c =>
        (!st.impactReadOnly && c.isSelectable && st.orgId)
          ? [c.dependencyTypeId, await loadDependencyObjects(st.orgId, c.dependencyTypeId)]
          : [c.dependencyTypeId, []]));
      const objectsByCat = new Map(lists);
      const assetTaxonomy = await taxonomyPromise;

      // Practice selection goes through the reusable cascading Practice
      // Picker (wwwroot/js/practice-picker.js, migration 282) instead of
      // one flat <select> holding every mappable practice. The old
      // control loaded the whole list with the panel; the picker loads
      // only the frameworks up front and fetches each level on demand.
      //
      // Map opens the picker in a dialog (#riskMapPracticeModal).
      // The four cascading dropdowns need a full row each; inline in the
      // panel their labels wrapped and the selects were unusable.
      // The panel keeps one button and nothing else has to move.
      const practiceAdd = st.readOnly ? "" : `
        <button type="button" class="pm-button primary" data-map-practice-add="${escapeHtml(hostId)}">
          <i class="fa-solid fa-plus" aria-hidden="true"></i> Map a practice
        </button>`;

      // TWO STACKED FULL-WIDTH SECTIONS, not two columns.
      //
      // These used to sit side by side, practices pinned to a 260px
      // column. Once each practice card had to carry a provenance trail
      // (framework > structure root > statement) and its tasks, 260px
      // wrapped every line to two or three and the section was unreadable.
      // Stacking gives both halves the full panel width and turns the
      // panel into something you scan downward instead of across.
      //
      const practicesBlock = `
          <section class="risk-scope-block risk-scope-practices">
            <div class="risk-scope-head">
              <h4>Mapped practices <span class="rmp-count">${practices.length}</span></h4>
              ${practiceAdd}
            </div>
            ${practices.length
              // A BLOCK PER PRACTICE, not one flat table.
              //
              // The single table put the practice name, its provenance,
              // its dependency count and its tasks in rows of equal
              // weight, so nothing said which belonged to what. Each
              // practice is now its own bordered block: title + badge,
              // then labelled facts, then its tasks in an inset mini
              // table that is visibly subordinate to both.
              ? `<div class="rmp-list">${practices.map(p =>
                   practiceItem(hostId, p, st,
                                depsByPractice.get(Number(p.practiceId)) || [])).join("")}</div>`
              : `<div class="risk-map-empty">
                   <strong>No practices mapped yet.</strong>
                   <span>Map a practice to record what controls this risk and to
                         pull its dependencies into scope.</span>
                 </div>`}
          </section>`;

      // "Impact Details", not "Dependencies". This section always
      // captured what the risk impacts -- which assets, vendors, people,
      // teams and committees, grouped by Operationalize category -- and
      // the old label made it read as a duplicate of the dependencies a
      // mapped practice already carries. Those inherited dependencies
      // are a separate thing and are listed read-only on each practice's
      // own card. Table, categories, store and save path are unchanged.
      //
      // The <h4> is emitted only when this block shares the main host.
      // In its own panel the panel's <h2> is the heading, and two
      // headings for one section is what a copied component looks like.
      const impactBlock = `
          <section class="risk-scope-block risk-scope-deps">
            ${impactHost ? "" : `
            <div class="risk-scope-head">
              <h4>Impact Details <span class="rmp-count">${deps.length}</span>
                  <span class="pm-hint">impacted assets, vendors, people &mdash; by Operationalize category</span></h4>
            </div>`}
            ${categories.length
              // NO .pm-table-wrap here, deliberately. That wrapper sets
              // overflow:auto, and the pm-checkcombo menu is
              // position:absolute -- inside it the dropdown is clipped to
              // the table box and the options are unreachable. The
              // Operationalize dependency table is a bare .pm-table for
              // exactly this reason; table-layout:fixed keeps the columns
              // steady without a scroll container.
              ? `<table class="pm-table risk-dep-table" style="width:100%;table-layout:fixed">
                   <thead><tr><th style="width:160px">Category</th><th style="width:auto">Impacted records</th></tr></thead>
                   <tbody>${categories.map(c =>
                     categoryRow(hostId, c, byCat.get(c.dependencyTypeId) || [],
                                 objectsByCat.get(c.dependencyTypeId) || [], st, assetTaxonomy)).join("")}
                   </tbody></table>
                 ${st.impactReadOnly ? "" : `
                 <div class="risk-dep-savebar">
                   <span class="pm-hint">Tick what this risk impacts, then save. Items a mapped practice brought in are locked &mdash; unmap the practice to remove them.</span>
                   <button type="button" class="pm-button primary" data-dep-save="${escapeHtml(hostId)}">
                     <i class="fa-solid fa-floppy-disk"></i> Save impact details
                   </button>
                 </div>`}`
              : `<p class="pm-hint">No dependency categories are configured for this organisation.</p>`}
          </section>`;

      // msg() writes to EVERY element carrying this host's marker, so
      // one is rendered in each host: the save button lives in the
      // impact panel and the Map/unmap buttons in the practices panel,
      // and a result shown in the other panel is a result nobody sees.
      const messageLine = `
        <p class="pm-form-message" data-map-message="${escapeHtml(hostId)}" role="status" aria-live="polite"></p>`;

      if (impactHost) {
        host.innerHTML = `
        ${st.showHeading ? `
        <h3 class="risk-subhead">Existing Controls</h3>
        <p class="pm-hint">Practices that control this risk and the dependencies each one brings in.</p>` : ""}
        <div class="risk-scope">${practicesBlock}</div>${messageLine}`;
        impactHost.innerHTML = `<div class="risk-scope">${impactBlock}</div>${messageLine}`;
      } else {
        host.innerHTML = `
        ${st.showHeading ? `
        <h3 class="risk-subhead">Existing Controls</h3>
        <p class="pm-hint">Practices that control this risk, the dependencies each one brings in,
           and what the risk impacts.</p>` : ""}
        <div class="risk-scope">${impactBlock}${practicesBlock}</div>${messageLine}`;
      }

      // Remember what this panel already has mapped, so the dialog can
      // exclude them without re-reading the DOM.
      st.mappedPracticeIds = (practices || []).map(p => p.practiceId);
    }

    // ------------------------------------------------------------------
    // Practice Picker dialog (migration 282).
    //
    // ONE picker instance for the whole page, mounted in the modal and
    // re-pointed at whichever scope panel opened it. The panel re-renders
    // on every refresh; keeping the picker outside that markup means it
    // is not torn down and rebuilt each time, and the two scope panels
    // (inherent and residual) share it safely because only one dialog is
    // ever open.
    //
    // Nothing about the cascade lives here -- this only opens the shared
    // component and reads its result.
    // ------------------------------------------------------------------
    let mapPicker     = null;   // the attached picker instance
    let mapPickerHost = null;   // hostId that opened the dialog

    function openMapPracticeDialog(hostId, st) {
      const mount = document.getElementById("riskMapPickerHost");
      const msgEl = document.getElementById("riskMapPickerMessage");
      if (!mount) return;
      mapPickerHost = hostId;
      if (msgEl) { msgEl.textContent = ""; msgEl.className = "pm-form-message"; }

      if (!window.__practicePicker) {
        mount.innerHTML = `<span class="pm-hint">Practice picker unavailable - practice-picker.js did not load.</span>`;
        show("riskMapPracticeModal");
        return;
      }
      if (!st.orgId) {
        mount.innerHTML = `<span class="pm-hint">Select an organization first.</span>`;
        show("riskMapPracticeModal");
        return;
      }

      // EXCLUDED IS THIS RISK'S OWN MAPPING, AND NOTHING ELSE.
      //
      // st.mappedPracticeIds comes from data.practices in refresh(),
      // which is GET /register/{riskId}/mapping -> sp_risk_mapping_get,
      // whose practice list is `WHERE pm.risk_register_id =
      // @risk_register_id`. So it is per risk at every layer, and no
      // query anywhere asks "is this practice mapped to ANY risk":
      // risk_practice_map is UNIQUE(risk_register_id, practice_id),
      // sp_risk_practice_map's duplicate guard is keyed on the pair, and
      // sp_practice_picker_practices has no risk parameter at all -- it
      // excludes only the ids handed to it here.
      //
      // One thing DOES put a practice in this list without anybody
      // mapping it: sp_risk_mapping_sync_primary derives the Primary row
      // from risk_register.linked_practice_id on the first /mapping
      // read. A risk raised from a practice therefore arrives with that
      // practice already in its own scope -- correctly -- and the picker
      // will not offer it again. That is the one case that can look like
      // a global exclusion and is not.
      const excluded = st.mappedPracticeIds || [];
      if (mapPicker) {
        // Re-open: reset to the top and refresh the exclusions rather
        // than building a second instance (and a second set of fetches).
        //
        // The ORGANISATION is re-set too. It is captured at attach time,
        // and this is one picker reused for every risk on the page -- so
        // without this, opening a risk in a second organisation would
        // browse the first organisation's frameworks. setOrganizationId
        // clears the selected path when it changes and reports whether
        // it did.
        mapPicker.setOrganizationId(st.orgId);
        // 312. AND the risk. The exclusion is now decided in SQL on
        // organization_id AND risk_register_id, so the picker has to be
        // told which risk it is opened for -- otherwise it would keep
        // asking about whichever risk was opened first on this page,
        // which is the cross-risk answer this whole area was reported
        // for.
        mapPicker.setRiskRegisterId(st.riskId);
        // reset() AFTER setExcluded's reload has settled. setExcluded
        // reloads the practice level when a control is still selected,
        // and that fetch used to land after reset() had cleared the
        // selects -- repopulating a list for a control the user was no
        // longer on. Awaiting it makes the order deterministic; the
        // dialog is shown either way, so nothing waits on the network.
        Promise.resolve(mapPicker.setExcluded(excluded))
               .catch(() => {})
               .then(() => mapPicker.reset());
      } else {
        mapPicker = window.__practicePicker.attach({
          host:               mount,
          organizationId:     st.orgId,
          // 312. The exclusion is decided in SQL from these two
          // together. excludePracticeIds below still applies on top --
          // it costs nothing and it is what covers a caller with no
          // risk -- but it is no longer the only thing enforcing it.
          riskRegisterId:     st.riskId,
          required:           true,
          excludePracticeIds: excluded,
          // SAY WHOSE MAPPING IT IS. "All 3 practices here are already
          // used" is what made this look global -- it does not say used
          // BY WHAT, so a practice hidden because it is already on THIS
          // risk read as a practice locked by some other risk. The
          // picker cannot know; the host does.
          excludedAllText: n => n === 1
            ? "Its only practice is already mapped to this risk"
            : `All ${n} practices here are already mapped to this risk`,
          excludedHintText: n => `${n} already mapped to this risk`
        });
      }
      show("riskMapPracticeModal");
    }

    function closeMapPracticeDialog() {
      hide("riskMapPracticeModal");
      mapPickerHost = null;
    }

    // One table row per category, carrying the SAME pm-checkcombo widget
    // the Operationalize dependency table uses.
    //
    // Nothing about the widget is reimplemented here: practice.js already
    // carries the delegated open/close, search-filter and trigger-label
    // behaviour for [data-checkcombo], and practice-management.css
    // already styles it. It is loaded on every Practice/Manage screen,
    // this one included. Reproducing the markup is the whole integration.
    //
    // INHERITED ITEMS ARE CHECKED AND DISABLED.
    // Operationalize's combo is a complete-set control: what you tick is
    // what you get. Here the list mixes two kinds of row -- dependencies
    // inherited from a mapped practice, which only unmapping that
    // practice can remove, and ones added directly, which can be
    // unticked. A combo that let you untick an inherited item would
    // promise a removal the model refuses (266 keeps the row while a
    // practice still vouches for it), so those checkboxes are locked and
    // say why on hover.

    function categoryRow(hostId, cat, mapped, list, st, assetTaxonomy) {
      const mappedById = new Map(mapped.map(d => [d.dependencyObjectId, d]));

      if (!cat.isSelectable) {
        return `<tr>
          <td><strong>${escapeHtml(cat.dependencyTypeName)}</strong></td>
          <td><span class="pm-hint">Not configured for object selection on this database.</span></td>
        </tr>`;
      }

      // READ-ONLY IS CHIPS, NOT A DISABLED PICKER.
      //
      // A read-only mount used to render the same pm-checkcombo as an
      // editable one. There is no save button on those pages, so nothing
      // persisted -- but the trigger opened, the boxes ticked, and the
      // reader was invited to make a change that would be silently
      // thrown away on the next render. `disabled` on every box would
      // have fixed the writing and kept the lie that this is a control.
      //
      // So read-only renders what it actually is: the mapped names, as
      // the same .rmp-dep-chip the practice cards use, with the
      // inherited-via title kept as a tooltip. No trigger, no menu, no
      // checkbox, and nothing for the asset cascade filters to narrow --
      // which is why they are skipped here too.
      if (st.impactReadOnly) {
        return `<tr class="risk-dep-row" data-dep-cat="${cat.dependencyTypeId}">
          <td><strong>${escapeHtml(cat.dependencyTypeName)}</strong>${
            mapped.length ? ` <span class="pm-hint">(${mapped.length})</span>` : ""}</td>
          <td>${mapped.length
            ? `<div class="risk-dep-chips">${mapped.map(d => {
                 const why = d.sourcePractices ? `Inherited via ${d.sourcePractices}` : "Mapped directly";
                 return `<span class="rmp-dep-chip" title="${escapeHtml(why)}">${escapeHtml(
                          personWithRole(d.dependencyObjectName || `#${d.dependencyObjectId}`,
                                         d.roleNames))}</span>`;
               }).join("")}</div>`
            : `<span class="rmp-dash">--</span>`}</td>
        </tr>`;
      }

      // Anything mapped but absent from the option list -- a retired
      // object, or one the picker's page size did not reach -- still has
      // to appear, or saving would silently drop it.
      const extra = mapped
        .filter(d => !list.some(o => o.id === d.dependencyObjectId))
        .map(d => ({ id: d.dependencyObjectId, name: d.dependencyObjectName || `#${d.dependencyObjectId}` }));
      const all = list.concat(extra);

      // The three taxonomy ids ride on each option as data attributes;
      // the cascade filters below match on them without another fetch.
      const options = all.map(o => {
        const d        = mappedById.get(o.id);
        const checked  = !!d;
        const locked   = !!d && !d.isDirect;         // inherited-only
        const why      = d && d.sourcePractices ? `Inherited via ${d.sourcePractices}` : "";
        return `<label data-checkcombo-option${locked ? ' class="is-locked"' : ""}${
                 why ? ` title="${escapeHtml(why)}"` : ""}`
             + (o.assetCategoryId    != null ? ` data-asset-category="${escapeHtml(String(o.assetCategoryId))}"` : "")
             + (o.assetSubcategoryId != null ? ` data-asset-subcategory="${escapeHtml(String(o.assetSubcategoryId))}"` : "")
             + (o.assetTypeId        != null ? ` data-asset-type="${escapeHtml(String(o.assetTypeId))}"` : "")
             + `>`
             + `<input type="checkbox" value="${o.id}"`
             // Bare name, never the role-suffixed label: this attribute
             // is what saveDependencies persists as the object name.
             + ` data-object-name="${escapeHtml(o.name)}"`
             + `${checked ? " checked" : ""}${locked ? " disabled" : ""}> `
             + `<span>${escapeHtml(personWithRole(o.name, o.roleNames))}${locked ? " &middot; inherited" : ""}</span></label>`;
      }).join("");

      // Same format in the collapsed trigger text as in the open list.
      const selectedLabels = all.filter(o => mappedById.has(o.id))
                                .map(o => personWithRole(o.name, o.roleNames)).join(", ");

      // Asset gets the three cascade filters on the SAME row as its
      // picker, exactly as the Operationalize Asset row does -- stacking
      // them would make the Asset row twice the height of every other
      // one and split filter from picker. Only when the taxonomy loaded.
      const isAsset = /^asset$/i.test(cat.dependencyTypeName || "")
                   || /^asset$/i.test(cat.dependencyTypeCode || "");
      const showAssetFilters = isAsset && !st.impactReadOnly && assetTaxonomy
                            && assetTaxonomy.cats.length > 0 && all.length > 0;

      const combo = all.length
        ? `<div class="risk-dep-object pm-field pm-checkcombo" data-checkcombo style="width:100%">
             <button class="pm-checkcombo-trigger" type="button" data-checkcombo-trigger>
               <span data-checkcombo-text>${escapeHtml(selectedLabels || "Select...")}</span>
               <span class="pm-checkcombo-caret" aria-hidden="true"></span>
             </button>
             <div class="pm-checkcombo-menu" data-checkcombo-menu hidden>
               <input class="pm-checkcombo-search" type="search" placeholder="Search..." data-checkcombo-search>
               <div class="pm-checkcombo-options">${options}</div>
             </div>
           </div>`
        // Was a bare <span class="pm-hint">, which has no border and no
        // height -- so a category with no records collapsed its row and
        // sat out of line with every category above it that had a
        // picker. Same message, rendered in the box the picker would
        // have occupied. Static text, not a control: nothing is focused
        // and nothing is submitted, so the save path is untouched.
        : `<div class="pm-field-empty">No active ${escapeHtml(cat.dependencyTypeName.toLowerCase())} records for this organization yet.</div>`;

      const picker = showAssetFilters
        ? `<div class="risk-asset-row">${assetFilterCells(assetTaxonomy)}
             <div class="risk-asset-picker">
               <label class="pm-hint">Assets</label>
               ${combo}
             </div>
           </div>`
        : combo;

      return `<tr class="risk-dep-row" data-dep-cat="${cat.dependencyTypeId}">
        <td><strong>${escapeHtml(cat.dependencyTypeName)}</strong>${
          mapped.length ? ` <span class="pm-hint">(${mapped.length})</span>` : ""}</td>
        <td>${picker}</td>
      </tr>`;
    }

    function practiceItem(hostId, p, st, practiceDeps) {
      // The primary practice cannot be unmapped here: it mirrors the
      // risk's own linked practice, and removing it through this panel
      // would leave the register and the map disagreeing about what the
      // risk is attached to. sp_risk_practice_unmap refuses it too
      // (error 56672) -- this is the affordance, that is the rule.
      const canRemove = !st.readOnly && !p.isPrimary;

      // Provenance + tasks come from /practice-context (284). Absent
      // when that call failed or the org is not known -- the row then
      // renders exactly as it did before, which is the point of keeping
      // this optional.
      const entry = st.practiceContext ? st.practiceContext.get(Number(p.practiceId)) : null;
      const c     = entry ? entry.ctx : null;
      const tasks = entry ? entry.tasks : [];

      // LABELLED FACTS, not one long breadcrumb. The trail told the
      // reader the order of the levels but never named them, so
      // "RBI-IT-GOV 2023 > IT Governance > 7.2 ..." had to be decoded.
      // A fact with no value is DROPPED, not rendered as "--": a row of
      // five empty chips is noise, and the levels are genuinely optional
      // (284 LEFT joins statement and structure).
      const statement = c
        ? [c.statementReference, c.statementTitle].filter(Boolean).join(" ")
        : "";

      // "Dependencies" is no longer a fact here. It used to be a bare
      // count, and the count is now the badge on the list below, which
      // also names them -- two numbers for one thing, one of them
      // useless.
      const facts = [
        ["Framework",    c && c.frameworkName],
        ["Source root",  c && c.structureRootName],
        ["Statement",    statement],
        ["Practice ref", p.practiceCode]
      ].filter(f => f[1] && String(f[1]).trim());

      const factList = facts.map(([k, v]) => `
        <div class="rmp-fact"><dt>${escapeHtml(k)}</dt><dd>${escapeHtml(String(v))}</dd></div>`).join("");

      // Tasks in an INSET mini table -- shaded, smaller type, its own
      // header row. That is what makes them read as belonging to the
      // practice above rather than as siblings of it.
      const taskBlock = tasks.length
        ? `<div class="rmp-tasks-label">Tasks <span class="rmp-count sm">${tasks.length}</span></div>
           <table class="rmp-task-table">
             <thead><tr>
               <th>Task</th>
               <th style="width:120px">Status</th>
               <th style="width:150px">Owner</th>
               <th style="width:100px">Due</th>
             </tr></thead>
             <tbody>${tasks.map(t => `
               <tr>
                 <td>${escapeHtml(t.title || `Task #${t.taskId}`)}</td>
                 <td>${t.statusName
                        ? `<span class="pm-badge t-status">${escapeHtml(t.statusName)}</span>`
                        : `<span class="rmp-dash">--</span>`}</td>
                 <td>${t.assignedTo ? escapeHtml(t.assignedTo) : `<span class="rmp-dash">--</span>`}</td>
                 <td>${t.dueAt ? escapeHtml(String(t.dueAt).slice(0, 10)) : `<span class="rmp-dash">--</span>`}</td>
               </tr>`).join("")}</tbody>
           </table>`
        : `<p class="rmp-no-tasks">No tasks linked</p>`;

      // THE PRACTICE'S OWN DEPENDENCIES, READ-ONLY.
      //
      // These are what the practice's obligations already declared on the
      // Operationalize page and brought with them when the practice was
      // mapped to this risk. They are not editable here -- the way to
      // change them is on the practice, and the way to remove them from
      // this risk is to unmap the practice. So: no checkboxes, no save,
      // grouped by the same Operationalize category names used in Impact
      // Details, in the same inset style as the task table so it reads as
      // belonging to the practice above it.
      //
      // sqlCount is the authoritative per-practice count from
      // sp_risk_mapping_get. The names are derived from SourcePractices,
      // which is a name match, so when the two disagree the count is
      // trusted and the shortfall is stated rather than hidden.
      const sqlCount = Number(p.dependencyCount ?? 0);
      const depGroups = new Map();
      (practiceDeps || []).forEach(d => {
        if (!depGroups.has(d.categoryName)) depGroups.set(d.categoryName, []);
        depGroups.get(d.categoryName).push(d);
      });
      const shown  = (practiceDeps || []).length;
      const missing = sqlCount > shown ? sqlCount - shown : 0;

      const depBlock = depGroups.size
        ? `<div class="rmp-deps-label">Dependencies
             <span class="rmp-count sm">${sqlCount || shown}</span></div>
           <dl class="rmp-dep-groups">${[...depGroups.entries()].map(([cat, items]) => `
             <div class="rmp-dep-group">
               <dt>${escapeHtml(cat)}</dt>
               <dd>${items.map(i =>
                 `<span class="rmp-dep-chip">${escapeHtml(
                    personWithRole(i.objectName, i.roleNames))}</span>`).join("")}</dd>
             </div>`).join("")}</dl>
           ${missing
             ? `<p class="rmp-no-deps">${missing} further dependenc${missing === 1 ? "y" : "ies"}
                  could not be attributed to this practice by name.</p>`
             : ""}`
        : `<p class="rmp-no-deps">No dependencies inherited from this practice</p>`;

      return `<article class="rmp-card">
        <header class="rmp-card-head">
          <div class="rmp-title">
            <h5>${escapeHtml(p.practiceName || `#${p.practiceId}`)}</h5>
            <span class="risk-src-badge" data-src="${p.isPrimary ? "Primary" : "Additional"}">${
              p.isPrimary ? "Primary" : "Additional"}</span>
          </div>
          <button type="button" class="rmp-remove"
                  title="${canRemove ? "Unmap this practice" : "The primary practice cannot be unmapped here"}"
                  ${canRemove ? "" : "disabled"}
                  data-map-practice-remove="${escapeHtml(hostId)}" data-practice-id="${p.practiceId}">
            <i class="fa-solid fa-xmark"></i></button>
        </header>
        <dl class="rmp-facts">${factList}</dl>
        <div class="rmp-deps">${depBlock}</div>
        <div class="rmp-tasks">${taskBlock}</div>
      </article>`;
    }

    // The object picker for one category, loaded lazily on first focus.
    //
    // THIS IS THE OPERATIONALIZE ENDPOINT, NOT A RISK CENTRE ONE.
    // `dependency-options/query` reads dependency_type_source_config and
    // queries whichever of the nine source tables that category names.
    // resolve-workspace.cshtml's loadDependencyObjectsFor() calls exactly
    // this with exactly this payload; Risk Analysis calls it the same way
    // so there is one answer to "what objects exist for a category".
    // The repository gateway is antiforgery-protected. Every gateway POST
    // in resolve-workspace.cshtml sends this header; the first version of
    // this function did not, so the gateway rejected the request, the
    // catch below swallowed it, and every category rendered
    // "-- nothing available --" with nothing in the console to say why.
    const CSRF = document.querySelector('meta[name="csrf-token"]')?.content || "";

    // unwrap / rowsOf are resolve-workspace.cshtml's helpers, copied
    // deliberately rather than reinvented.
    //
    // The gateway can hand back the same rows in several shapes: a plain
    // array, `{ data: [...] }`, an array OF tables (`data[0]` is the
    // rows), a JSON *string* that still needs parsing, and objects
    // wrapped in `$values` by ReferenceHandler.Preserve. Hand-rolled
    // shape guessing handles the first two and quietly returns nothing
    // for the rest -- which is exactly what happened here.
    function unwrap(v) {
      if (typeof v === "string") {
        const t = v.trim();
        if ((t.startsWith("{") && t.endsWith("}")) || (t.startsWith("[") && t.endsWith("]"))) {
          try { return unwrap(JSON.parse(t)); } catch (_) { return v; }
        }
      }
      if (v && typeof v === "object" && Array.isArray(v.$values)) return v.$values.map(unwrap);
      if (Array.isArray(v)) return v.map(unwrap);
      return v;
    }
    function rowsOf(body) {
      const d = unwrap(body?.data ?? body?.Data ?? body ?? []);
      if (!Array.isArray(d)) return [];
      return (d.length && Array.isArray(d[0])) ? d.flat() : d;
    }

    // ---- Asset taxonomy (migration 241) --------------------------------
    //
    // The Operationalize Asset row carries three cascade filters --
    // category, sub-category, type -- because an asset register is the
    // one dependency list that routinely runs to hundreds of rows, and a
    // flat picker of 400 assets is not a picker.
    //
    // Same endpoint, same payload, same bucketing as
    // resolve-workspace.cshtml's loadAssetTaxonomy(). Failure degrades to
    // a flat picker rather than an error: 241 may not be deployed
    // everywhere, and an Asset row without filters still works.
    let assetTaxonomyCache = null;
    async function loadAssetTaxonomy() {
      if (assetTaxonomyCache) return assetTaxonomyCache;
      try {
        const r = await fetch(U("/practice-management-gateway/asset-taxonomy/query"), {
          method: "POST",
          credentials: "same-origin",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": CSRF },
          body: JSON.stringify({ data: { pageNumber: 1, pageSize: 1000 } })
        });
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const bucket = { cats: [], subs: [], types: [] };
        rowsOf(await r.json()).forEach(row => {
          const kind = String(row.EntityType || row.entityType || "");
          const item = {
            id:   Number(row.Value ?? row.value),
            name: String(row.Label ?? row.label ?? ""),
            parent: row.Parent != null ? Number(row.Parent) : null
          };
          if (!item.id) return;
          if (kind === "asset-categories")         bucket.cats.push(item);
          else if (kind === "asset-subcategories") bucket.subs.push(item);
          else if (kind === "asset-types")         bucket.types.push(item);
        });
        assetTaxonomyCache = bucket;
      } catch (err) {
        console.warn("[risk-centre] asset taxonomy unavailable; Asset picker stays flat", err);
        assetTaxonomyCache = { cats: [], subs: [], types: [] };
      }
      return assetTaxonomyCache;
    }

    // Three filter combos, same markup as buildAssetFilterCells().
    // "All" on the trigger, and no selection means no restriction.
    function assetFilterCells(tax) {
      const bucket = (label, dataAttr, items) =>
          `<div class="risk-asset-filter">`
        +   `<label class="pm-hint">${escapeHtml(label)}</label>`
        +   `<div class="pm-field pm-checkcombo" data-checkcombo ${dataAttr}>`
        +     `<button class="pm-checkcombo-trigger" type="button" data-checkcombo-trigger>`
        +       `<span data-checkcombo-text>All</span>`
        +       `<span class="pm-checkcombo-caret" aria-hidden="true"></span>`
        +     `</button>`
        +     `<div class="pm-checkcombo-menu" data-checkcombo-menu hidden>`
        +       `<input class="pm-checkcombo-search" type="search" placeholder="Search..." data-checkcombo-search>`
        +       `<div class="pm-checkcombo-options">`
        +         items.map(o => `<label data-checkcombo-option>`
                    + `<input type="checkbox" value="${o.id}"> `
                    + `<span>${escapeHtml(o.name)}</span></label>`).join("")
        +       `</div>`
        +     `</div>`
        +   `</div>`
        + `</div>`;
      return bucket("Asset category",     "data-asset-cat-filter",    tax.cats)
           + bucket("Asset sub-category", "data-asset-subcat-filter", tax.subs)
           + bucket("Asset type",         "data-asset-type-filter",   tax.types);
    }

    const depObjectCache = new Map();
    async function loadDependencyObjects(orgId, typeId) {
      const key = `${orgId}:${typeId}`;
      if (depObjectCache.has(key)) return depObjectCache.get(key);
      try {
        const r = await fetch(U("/practice-management-gateway/dependency-options/query"), {
          method: "POST",
          credentials: "same-origin",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": CSRF },
          body: JSON.stringify({ data: {
            organizationId: Number(orgId), dependencyTypeId: Number(typeId),
            pageNumber: 1, pageSize: 500
          }})
        });
        if (!r.ok) {
          // Reported, not swallowed. A silent empty list is
          // indistinguishable from an organisation that genuinely has no
          // vendors, and that ambiguity is what made this hard to see.
          const body = await r.text().catch(() => "");
          console.error("[risk-centre] dependency-options HTTP", r.status,
                        "type", typeId, body.slice(0, 300));
          return null;
        }
        const list = rowsOf(await r.json())
          .map(x => ({
            id:   Number(x.Value ?? x.value ?? x.Id ?? x.id ?? 0),
            name: String(x.Label ?? x.label ?? x.Name ?? x.name ?? ""),
            // 291. Person options carry the employee's active roles.
            // Kept SEPARATE from name: the dependency save persists the
            // option's name (sent as data-object-name), so a role folded
            // into it would be written to the mapping row. Display only.
            roleNames: x.RoleNames ?? x.roleNames ?? null,
            // Asset options carry three taxonomy ids (migration 242 in
            // the API's dependency-options query). They are what the
            // cascade filters match on, so they must survive this
            // mapping -- the first version dropped them.
            assetCategoryId:    x.AssetCategoryId    ?? x.assetCategoryId    ?? null,
            assetSubcategoryId: x.AssetSubcategoryId ?? x.assetSubcategoryId ?? null,
            assetTypeId:        x.AssetTypeId        ?? x.assetTypeId        ?? null
          }))
          .filter(x => x.id && x.name);
        depObjectCache.set(key, list);
        return list;
      } catch (err) {
        console.error("[risk-centre] dependency-options failed for type", typeId, err);
        return null;
      }
    }

    // querySelectorAll, not querySelector: a panel split across two
    // hosts renders one message line in each, and the caller does not
    // know or care which of them the reader is looking at.
    function msg(hostId, text, isError) {
      document.querySelectorAll(`[data-map-message="${CSS.escape(hostId)}"]`).forEach(el => {
        el.textContent = text || "";
        el.style.color = isError ? "#c53030" : "#2f855a";
      });
    }

    // One delegated listener for every mounted panel, bound once. Per-
    // panel listeners would have to be torn down on clear(), and a
    // missed teardown is a leak that only shows up after a few opens.
    document.addEventListener("click", async ev => {
      const addP = ev.target.closest("[data-map-practice-add]");
      if (addP) {
        ev.preventDefault();
        // "Map a practice" only opens the dialog now; the actual mapping
        // happens on the dialog's confirm button below.
        const hostId = addP.dataset.mapPracticeAdd;
        const st = hosts.get(hostId); if (!st) return;
        openMapPracticeDialog(hostId, st);
        return;
      }

      // ---- Practice Picker dialog: confirm --------------------------
      if (ev.target.closest("#riskMapPickerConfirm")) {
        ev.preventDefault();
        const btn    = document.getElementById("riskMapPickerConfirm");
        const msgEl  = document.getElementById("riskMapPickerMessage");
        const hostId = mapPickerHost;
        const st     = hostId ? hosts.get(hostId) : null;
        const setMsg = (t, bad) => {
          if (!msgEl) return;
          msgEl.textContent = t || "";
          msgEl.className = "pm-form-message" + (bad ? " is-error" : "");
        };

        if (!st) { setMsg("The scope panel is no longer open.", true); return; }
        // The picker's own validate() reports which level is missing.
        if (mapPicker && !mapPicker.validate()) return;
        const pid = mapPicker ? mapPicker.getPracticeId() : 0;
        if (!pid) { setMsg("Choose a practice to map.", true); return; }

        btn.disabled = true;
        try {
          // Payload unchanged from the flat-select version: the picker
          // yields the same practice.practice_id.
          const res = await apiPost(`/register/${st.riskId}/practices`, { practiceId: pid });
          if (!res || res.success === false) {
            setMsg((res && res.error) || "Could not map that practice.", true);
            return;
          }
          closeMapPracticeDialog();
          await refresh(hostId);
          msg(hostId, `${res.practiceName || "Practice"} mapped. `
                    + `${res.dependenciesAdded} dependenc${res.dependenciesAdded === 1 ? "y" : "ies"} newly in scope.`);
        } finally { btn.disabled = false; }
        return;
      }

      if (ev.target.closest("[data-close-map-practice]")) {
        ev.preventDefault();
        closeMapPracticeDialog();
        return;
      }

      const remP = ev.target.closest("[data-map-practice-remove]");
      if (remP && !remP.disabled) {
        ev.preventDefault();
        const hostId = remP.dataset.mapPracticeRemove;
        const st = hosts.get(hostId); if (!st) return;
        const pid = Number(remP.dataset.practiceId);
        if (!await dlg.confirm(
              "Unmap this practice? Dependencies it is the only source for will be removed from "
            + "the risk, across every category; ones another mapped practice also reaches, or "
            + "that were added directly, are kept.",
              { title: "Unmap practice", confirmText: "Unmap" })) return;
        const res = await apiPost(`/register/${st.riskId}/practices/${pid}`, null, "DELETE");
        if (!res || res.success === false) { msg(hostId, (res && res.error) || "Could not unmap.", true); return; }
        await refresh(hostId);
        msg(hostId, `Practice unmapped. ${res.dependenciesRemoved} dependenc${res.dependenciesRemoved === 1 ? "y" : "ies"} removed, `
                  + `${res.dependenciesKept} kept.`);
        return;
      }

      const save = ev.target.closest("[data-dep-save]");
      if (save) {
        ev.preventDefault();
        const hostId = save.dataset.depSave;
        const st = hosts.get(hostId); if (!st) return;
        await saveDependencies(hostId, st, save);
        return;
      }

    });

    // ---- pm-checkcombo behaviour --------------------------------------
    //
    // The widget's MARKUP and CSS are shared (practice-management.css),
    // but its behaviour is NOT globally delegated: practice.js binds it
    // to the organization-setup screen's own container, and
    // resolve-workspace.cshtml wires each combo by hand in
    // wireCheckcombo(). Neither reaches this screen, so the Risk Centre
    // has to wire its own.
    //
    // DELEGATED, not per-element. refresh() replaces the host's innerHTML
    // on every save and every practice change; per-combo listeners would
    // have to be re-attached after each one, and the render that forgot
    // would produce a combo that opens on one screen and not the other.
    // A single document-level listener has nothing to forget.
    //
    // Every branch is scoped to a combo inside one of THIS screen's own
    // hosts, so this cannot touch a checkcombo belonging to another
    // screen. Two host classes now, not one:
    //   .risk-map-host      -- the analysis page, residual modal and
    //                          review modal's Impacted Assets/dependency
    //                          pickers (285/261).
    //   .risk-category-host -- raCategoryCombo, the Risk Category
    //                          multi-select (375, 376). Same widget,
    //                          different mount point, so it gets its own
    //                          host class rather than being folded into
    //                          the mapping one it has nothing to do with.
    function comboInHost(el) {
      const combo = el && el.closest("[data-checkcombo]");
      return combo && combo.closest(".risk-map-host, .risk-category-host") ? combo : null;
    }

    function comboText(combo) {
      const labels = [...combo.querySelectorAll("input[type='checkbox']:checked")]
        .map(cb => cb.dataset.objectName || cb.nextElementSibling?.textContent?.trim() || "")
        .filter(Boolean);
      return labels.join(", ") || "Select...";
    }

    document.addEventListener("click", ev => {
      const trigger = ev.target.closest("[data-checkcombo-trigger]");
      if (!trigger) return;
      const combo = comboInHost(trigger);
      if (!combo) return;                       // another screen's combo
      ev.preventDefault();
      const menu = combo.querySelector("[data-checkcombo-menu]");
      if (!menu) return;
      document.querySelectorAll("[data-checkcombo-menu]").forEach(m => { if (m !== menu) m.hidden = true; });
      menu.hidden = !menu.hidden;
      if (!menu.hidden) combo.querySelector("[data-checkcombo-search]")?.focus();
    });

    document.addEventListener("change", ev => {
      const cb = ev.target.closest("[data-checkcombo] input[type='checkbox']");
      if (!cb) return;
      const combo = comboInHost(cb);
      if (!combo) return;

      const text = combo.querySelector("[data-checkcombo-text]");
      if (text) {
        // A filter combo with nothing ticked reads "All", not
        // "Select..." -- an empty filter is no restriction, and
        // "Select..." would imply the user still has to.
        const isFilter = combo.hasAttribute("data-asset-cat-filter")
                      || combo.hasAttribute("data-asset-subcat-filter")
                      || combo.hasAttribute("data-asset-type-filter");
        const t = comboText(combo);
        text.textContent = (isFilter && t === "Select...") ? "All" : t;
      }

      // Changing a filter re-narrows the asset picker in the same row.
      if (combo.closest(".risk-asset-row")) applyAssetFilters(combo.closest(".risk-asset-row"));
    });

    // The intersection filter, same rule as the Operationalize Asset row:
    // an option survives only if it matches EVERY non-empty filter set.
    // Selecting nothing on a filter means "no restriction" rather than
    // "match nothing", which is why each set is tested for size first.
    function applyAssetFilters(row) {
      if (!row) return;
      const picker = row.querySelector(".risk-dep-object[data-checkcombo]");
      if (!picker) return;
      const ticks = sel => {
        const c = row.querySelector(sel);
        return c ? new Set([...c.querySelectorAll("input[type='checkbox']:checked")].map(cb => cb.value))
                 : new Set();
      };
      const cats  = ticks("[data-asset-cat-filter]");
      const subs  = ticks("[data-asset-subcat-filter]");
      const types = ticks("[data-asset-type-filter]");
      picker.querySelectorAll("[data-checkcombo-option]").forEach(opt => {
        const okCat  = !cats.size  || cats.has(opt.dataset.assetCategory || "");
        const okSub  = !subs.size  || subs.has(opt.dataset.assetSubcategory || "");
        const okType = !types.size || types.has(opt.dataset.assetType || "");
        opt.hidden = !(okCat && okSub && okType);
      });
    }

    document.addEventListener("input", ev => {
      const search = ev.target.closest("[data-checkcombo-search]");
      if (!search) return;
      const combo = comboInHost(search);
      if (!combo) return;
      const q = search.value.toLowerCase().trim();
      combo.querySelectorAll("[data-checkcombo-option]").forEach(opt => {
        const t = (opt.querySelector("span")?.textContent || "").toLowerCase();
        opt.hidden = !!q && !t.includes(q);
      });
    });

    // mousedown, not click: closing on click would fire after the
    // trigger's own handler had already toggled the menu open.
    document.addEventListener("mousedown", ev => {
      if (ev.target.closest("[data-checkcombo]")) return;
      document.querySelectorAll(".risk-map-host [data-checkcombo-menu], .risk-category-host [data-checkcombo-menu]")
        .forEach(m => { m.hidden = true; });
    });

    // Diff every category's combo against what is stored, then issue the
    // adds and removes.
    //
    // WHY A DIFF AND NOT A COMPLETE-SET SYNC
    // --------------------------------------
    // Operationalize sends the whole desired list per category and lets
    // sp_resolve_dependency_category_sync reconcile. That works there
    // because every row in its combo is the same kind of thing.
    //
    // Here the combo mixes inherited rows (locked; only unmapping the
    // practice removes them) with direct ones. A complete-set payload
    // would have to include the inherited items to avoid deleting them,
    // and would then be asserting ownership of rows it does not own. So
    // the client sends only what actually changed, and only for the
    // checkboxes it was allowed to change.
    async function saveDependencies(hostId, st, btn) {
      const host = document.getElementById(hostId);
      if (!host) return;

      const adds = [], removes = [];
      host.querySelectorAll("[data-dep-cat]").forEach(row => {
        const typeId = Number(row.dataset.depCat);
        // ONLY the object picker. The Asset row also carries three
        // taxonomy filter combos; their checkboxes are view state, and
        // treating them as dependencies would try to map an asset
        // category as though it were an asset.
        row.querySelectorAll(".risk-dep-object[data-checkcombo] input[type='checkbox']").forEach(cb => {
          if (cb.disabled) return;                       // inherited: not ours to change
          const objId  = Number(cb.value);
          const wasSet = cb.defaultChecked;              // the state the server rendered
          if (cb.checked && !wasSet)
            adds.push({ typeId, objId, name: cb.dataset.objectName || null });
          else if (!cb.checked && wasSet)
            removes.push({ typeId, objId });
        });
      });

      if (!adds.length && !removes.length) { msg(hostId, "Nothing changed."); return; }

      btn.disabled = true;
      const original = btn.innerHTML;
      btn.innerHTML = `<i class="fa-solid fa-spinner fa-spin"></i> Saving...`;
      let added = 0, removed = 0, kept = 0, failed = 0, lastError = "";
      try {
        // Sequential, not Promise.all: these hit one risk row and the
        // procedures take their own transactions. Firing a dozen at once
        // buys nothing and invites deadlocks on risk_register_history.
        for (const a of adds) {
          const res = await apiPost(`/register/${st.riskId}/dependencies`, {
            dependencyTypeId: a.typeId, dependencyObjectId: a.objId, dependencyObjectName: a.name
          });
          if (!res || res.success === false) { failed++; lastError = (res && res.error) || ""; }
          else added++;
        }
        for (const r of removes) {
          const res = await apiPost(`/register/${st.riskId}/dependencies/${r.typeId}/${r.objId}`, null, "DELETE");
          if (!res || res.success === false) { failed++; lastError = (res && res.error) || ""; }
          else if (res.dependencyRemoved) removed++;
          else kept++;     // a practice still reaches it; the direct mapping went
        }
        await refresh(hostId);
        const parts = [];
        if (added)   parts.push(`${added} added`);
        if (removed) parts.push(`${removed} removed`);
        if (kept)    parts.push(`${kept} kept (still reached by a mapped practice)`);
        if (failed)  parts.push(`${failed} failed${lastError ? `: ${lastError}` : ""}`);
        msg(hostId, parts.join(" · ") || "Saved.", failed > 0);
      } finally {
        btn.disabled = false;
        btn.innerHTML = original;
      }
    }

    return { mount, clear, refresh };
  })();

  // "Practices & assets" on the row menu.
  //
  // It opens the Risk Analysis PAGE rather than a scope-only surface of
  // its own, and that is the whole point: scope is PART of the analysis,
  // not a separate record. A dedicated screen would be a second surface
  // showing the same panel, and the two would drift the first time one
  // of them gained a column.
  //
  // The menu entry exists because "I just want to add an asset" is a
  // real errand and hunting for it under "Analysis" is not obvious. On
  // the full page the scope panel is a section the user can see on
  // arrival, which is what makes one entry point enough.
  const openScopePage = openRiskAnalysisPage;

  // ===================================================================
  // Risk treatment work and sub tasks  (migrations 261, 263)
  //
  // Everything shown here belongs to Task Centre. This modal reads
  // sp_risk_treatment_state for the risk-side view, and writes sub tasks
  // through Task Centre's OWN endpoint (api/practice/tasks/{id}/children,
  // proxied at practice/api/tasks/...). There is no second task
  // mechanism and no copy of task state.
  // ===================================================================
  async function openTreatmentWorkModal(riskId) {
    const risk = await apiGet(`/register/${riskId}`);
    if (!risk) { dlg.alert("Risk not found.", { type: "error" }); return; }
    if (!state.employees.length) await loadEmployees();

    // Remember where we came from before the page hides the tabs.
    analysisReturnTab = state.tab || "register";

    document.getElementById("twRiskId").value = riskId;
    document.getElementById("twMessage").textContent = "";

    // The risk is the page's subject, so it is the heading.
    setText("twPageTitle", `${risk.riskNumber} — ${risk.riskTitle}`);
    setText("twPageSubtitle",
      risk.treatmentOptionName
        ? `Treatment option: ${risk.treatmentOptionName}. Track the work and break it into sub tasks.`
        : "No treatment option has been chosen for this risk yet.");
    document.getElementById("twHeadStatus").innerHTML = lifecycleChip(risk);

    document.getElementById("twMeta").innerHTML =
      dd("Risk ID", risk.riskNumber) +
      dd("Statement", risk.riskStatement) +
      dd("Treatment option", risk.treatmentOptionName || "not chosen") +
      dd("Decided", risk.treatmentDecidedOn
          ? `${window.gracFormatDateOnly(risk.treatmentDecidedOn)}${
              risk.treatmentDecidedByName ? ` by ${risk.treatmentDecidedByName}` : ""}` : null) +
      dd("Owner", risk.riskOwnerName) +
      dd("Business unit", risk.businessUnit) +
      dd("Inherent rating", risk.inherentRatingCode ? severityChip(risk.inherentRatingCode) : "not scored", true) +
      dd("Residual rating", risk.residualRatingCode ? severityChip(risk.residualRatingCode) : "not assessed", true);
      // Status is NOT repeated here: the heading bar already carries it
      // (twHeadStatus), and the same chip twice on one screen reads as a
      // rendering fault rather than emphasis.

    // A different risk starts collapsed. This is where "on load" begins
    // -- not every re-render, which would fight the user.
    state.twExpanded = new Set();

    // Show the page BEFORE the state round trip, so the click does not
    // appear to do nothing while the sweep and read complete.
    showTreatmentPage();
    await refreshTreatmentState(riskId);
  }

  // ONE RENDERER, TWO HOSTS.
  //
  // The Risk Treatment page owns this view; the Residual page shows the
  // same thing read-only, because a residual score is meaningless without
  // the treatment it is residual to. The alternative -- a second reader
  // and a second table markup on the residual page -- would be two
  // renderings of one truth, and the day the gate wording or the child
  // grouping changed, only one of them would follow.
  //
  // So the hosts are parameters. Defaults are the Treatment page's ids,
  // which is why its own call site is unchanged.
  //
  //   sync   the UnderTreatment -> Monitoring sweep. TRUE on the
  //          Treatment page, where the user is acting on the tasks and
  //          the gate must be acted on before it is reported. FALSE on
  //          the Residual page: that section is read-only, and a
  //          read-only section must not move a risk's status as a side
  //          effect of being looked at.
  //   readOnly  drops the row-action column (see taskRow).
  //
  // Returns the state, so a caller can render its own summary from the
  // same answer instead of asking for it twice.
  const TW_HOSTS = {
    gateId: "twGate", tilesId: "twTiles", bodyId: "twTableBody",
    residualBtnId: "twResidualBtn", colspan: 8, readOnly: false, sync: true
  };

  async function refreshTreatmentState(riskId, opts) {
    const o = Object.assign({}, TW_HOSTS, opts || {});

    // The sweep first, so "all tasks closed" is acted on before it is
    // reported. Without it the gate would say "available" while the
    // status was still UnderTreatment, and the residual save would then
    // be refused by a rule the screen had just said was satisfied.
    if (o.sync)
      await apiPost(`/register/treatment-sync?riskRegisterId=${riskId}`, null).catch(() => {});

    const st = await apiGet(`/register/${riskId}/treatment-state`);
    const gate = document.getElementById(o.gateId);
    const body = document.getElementById(o.bodyId);
    const residualBtn = o.residualBtnId ? document.getElementById(o.residualBtnId) : null;

    if (!st) {
      if (gate) {
        gate.textContent = "Treatment state could not be loaded.";
        gate.className = "risk-gate is-blocked";
      }
      if (body)
        body.innerHTML = `<tr><td colspan="${o.colspan}" class="pm-empty-row">`
                       + `Treatment work could not be loaded.</td></tr>`;
      return null;
    }

    if (gate) {
      gate.textContent = st.reason || "";
      gate.className = "risk-gate " + (st.residualAvailable ? "is-ready" : "is-blocked");
    }
    if (residualBtn) {
      residualBtn.disabled = !st.residualAvailable;
      residualBtn.dataset.riskId = riskId;
    }

    // The counts as tiles. Same .risk-tile the dashboard uses, so it
    // needs no styling of its own.
    const tiles = document.getElementById(o.tilesId);
    if (tiles) {
      const open = st.openTreatmentTaskCount || 0;
      tiles.innerHTML =
          tile(st.treatmentTaskCount || 0, "Treatment tasks")
        + tile(open, "Open", open > 0)
        + tile(st.closedTreatmentTaskCount || 0, "Closed")
        + tile(st.openSubTaskCount || 0, "Open sub tasks", (st.openSubTaskCount || 0) > 0);
    }

    // Remember the tasks for the row menu, so opening it does not have to
    // re-fetch a list the page is already showing. NOT from the read-only
    // render: that view has no row menu, and letting it write the cache
    // the Treatment page's menu reads from would be a quiet coupling
    // between a page that acts and a page that only looks.
    if (!o.readOnly) state.treatmentTasks = st.tasks || [];

    const tasks    = st.tasks || [];
    const parents  = tasks.filter(t => !t.isChild);
    const children = tasks.filter(t => t.isChild);

    if (!tasks.length) {
      body.innerHTML = `<tr><td colspan="${o.colspan}" class="pm-empty-row">`
                     + `No treatment work raised.</td></tr>`;
      return st;
    }

    // Parents first, each followed by its own children -- the shape the
    // work actually has. A flat list sorted by id would interleave
    // children of different parents.
    //
    // The children are emitted hidden. Collapsed is the load state
    // because the parents are what the reader came for: a risk with four
    // treatment tasks and a dozen sub tasks would otherwise open as a
    // wall of sixteen rows with no visible grouping.
    //
    // They are emitted, not withheld -- expanding is a class change on
    // rows that already exist, so it costs no request and cannot fail.
    //
    // COLLAPSED ON LOAD, NOT COLLAPSED ON EVERY RENDER. This table is
    // re-rendered after every action, and a set that reset each time
    // would swallow the sub task the user had just created: added,
    // saved, and immediately hidden behind a chevron. state.twExpanded
    // survives the re-render; it is cleared when a different risk is
    // opened, which is where "on load" actually begins.
    const expanded = state.twExpanded || (state.twExpanded = new Set());

    const ro = o.readOnly;
    body.innerHTML = parents.map(p => {
      const kids = children.filter(c => c.parentTaskId === p.taskId);
      const isOpen = expanded.has(p.taskId);
      return taskRow(p, { kidCount: kids.length, expanded: isOpen, readOnly: ro })
           + kids.map(c => taskRow(c, { parentTaskId: p.taskId, expanded: isOpen, readOnly: ro })).join("");
    }).join("")
    // Children whose parent is not in this list (raised against the
    // legacy candidate source, say) have no parent row to expand, so
    // hiding them behind a toggle that does not exist would lose them
    // entirely. They stay visible and say why they stand alone.
    + children.filter(c => !parents.some(p => p.taskId === c.parentTaskId))
              .map(c => taskRow(c, { orphan: true, readOnly: ro })).join("");

    return st;
  }

  // One renderer, three shapes:
  //   { kidCount, expanded }       a parent -- toggle when kidCount > 0
  //   { parentTaskId, expanded }   a sub task -- indented, hidden while
  //                                its parent is collapsed
  //   { orphan: true }             a sub task whose parent is not listed
  //
  // and one modifier: readOnly OMITS the actions cell entirely (the
  // Residual page's treatment section). Omitted rather than disabled --
  // a menu that opens onto nothing the reader may do is worse than no
  // menu, and the read-only table's header carries seven columns to
  // match.
  function taskRow(t, opt) {
    opt = opt || {};
    const isChild = !!opt.parentTaskId || !!opt.orphan;
    const closed  = !!t.closedAt || t.isTerminal;
    const kids    = opt.kidCount || 0;
    const open    = !!opt.expanded;

    // Hidden via the attribute, not a class: [hidden] cannot be beaten by
    // the table's own display rules the way a utility class can.
    const rowAttrs = isChild
      ? `class="tw-sub${opt.orphan ? " tw-orphan" : ""}"`
        + (opt.orphan ? "" : ` data-tw-parent="${opt.parentTaskId}"${open ? "" : " hidden"}`)
      : `class="tw-parent${open && kids > 0 ? " is-open" : ""}" data-tw-row="${t.taskId}"`;

    // A childless parent gets a spacer so its task number lines up with
    // the ones that do have a toggle.
    const toggle = isChild
      ? `<span class="tw-sub-mark">&#8627;</span>`
      : kids > 0
        ? `<button type="button" class="tw-toggle" data-tw-toggle="${t.taskId}"
                   aria-expanded="${open ? "true" : "false"}"
                   aria-label="${open ? "Hide" : "Show"} sub tasks"
                   title="${open ? "Hide" : "Show"} ${kids} sub task${kids === 1 ? "" : "s"}">
             <i class="fa-solid ${open ? "fa-chevron-down" : "fa-chevron-right"}" aria-hidden="true"></i>
           </button>`
        : `<span class="tw-toggle-spacer"></span>`;

    return `<tr ${rowAttrs}>
      <td>${toggle}${escapeHtml(t.taskNumber || `#${t.taskId}`)}</td>
      <td>${escapeHtml(t.title || "")}</td>
      <td>${escapeHtml(t.ownerName || "--")}</td>
      <td>${escapeHtml(t.priority || "--")}</td>
      <td>${t.dueAt ? window.gracFormatDateOnly(t.dueAt) : "--"}</td>
      <td>${closed
            ? `<span class="risk-status-chip risk-done">${escapeHtml(t.statusName || t.statusCode || "Closed")}</span>`
            : `<span class="risk-status-chip risk-open">${escapeHtml(t.statusName || t.statusCode || "Open")}</span>`}</td>
      <td>${isChild
            ? `<span class="pm-hint">${opt.orphan ? "sub task (parent not listed)" : "sub task"}</span>`
            : kids > 0
              ? `${kids}${t.mandatoryChildOpenCount > 0
                    ? ` <span class="pm-hint">(${t.mandatoryChildOpenCount} mandatory open)</span>` : ""}`
              : `<span class="pm-hint">none</span>`}</td>
      ${opt.readOnly ? "" : `<td>
        <button type="button" class="pm-action-trigger" data-tw-menu="${t.taskId}"
                data-tw-child="${isChild ? 1 : 0}"
                data-tw-closed="${closed ? 1 : 0}"
                data-tw-mandopen="${t.mandatoryChildOpenCount || 0}"
                aria-haspopup="menu" aria-expanded="false" title="Actions">
          <i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i>
        </button>
      </td>`}
    </tr>`;
  }

  // Expand / collapse one parent. The child rows are already in the DOM,
  // so this only flips their hidden attribute -- no fetch, nothing to
  // fail, and the state cannot disagree with what was rendered.
  function toggleTreatmentChildren(btn) {
    const taskId   = btn.dataset.twToggle;
    const expanded = btn.getAttribute("aria-expanded") === "true";
    const next     = !expanded;

    // Remembered, so the next re-render (any action on this page causes
    // one) reopens what the user had open.
    const set = state.twExpanded || (state.twExpanded = new Set());
    if (next) set.add(Number(taskId)); else set.delete(Number(taskId));

    btn.setAttribute("aria-expanded", next ? "true" : "false");
    btn.setAttribute("aria-label", next ? "Hide sub tasks" : "Show sub tasks");
    const icon = btn.querySelector("i");
    if (icon) {
      icon.classList.toggle("fa-chevron-right", !next);
      icon.classList.toggle("fa-chevron-down", next);
    }
    btn.closest("tr")?.classList.toggle("is-open", next);

    // Scoped to the toggle's OWN tbody, not to #twTableBody. The same
    // rows are rendered read-only inside the Residual page, and a
    // hard-coded host id would have made that copy's chevrons turn
    // without its rows moving.
    const scope = btn.closest("tbody") || document;
    scope.querySelectorAll(`tr[data-tw-parent="${taskId}"]`)
         .forEach(tr => { tr.hidden = !next; });
  }

  // "Add sub task" on the Risk Treatment page.
  //
  // Opens THE common Task / Sub Task form with the treatment task fixed
  // as the parent. This page used to carry its own panel -- six fields,
  // its own validation, its own payload -- which is exactly the
  // duplication the shared component exists to remove.
  //
  // The parent is chosen here rather than in the form: a risk can have
  // several treatment tasks, so when there is more than one open the user
  // picks which one the sub task belongs under, and the form shows that
  // choice read-only. With a single open task there is nothing to ask.
  async function onAddSubTask() {
    const riskId = Number(document.getElementById("twRiskId").value);
    if (!riskId) return;

    const st = await apiGet(`/register/${riskId}/treatment-state`);
    const parents = (st?.tasks || []).filter(t => !t.isChild && !t.closedAt && !t.isTerminal);

    if (!parents.length) {
      dlg.alert("There is no open treatment task to add a sub task under. "
              + "Choose a treatment option on Risk Analysis first.",
                { title: "No treatment task", type: "warning" });
      return;
    }

    const orgName = document.getElementById("regFilterOrganization")
                      ?.selectedOptions?.[0]?.textContent?.trim() || null;
    const toParent = t => ({ taskId: t.taskId, taskNumber: t.taskNumber, title: t.title });

    window.gracTaskForm.open({
      mode: "subtask",
      organizationId: state.organizationId,
      organizationName: orgName,
      // One open task -> fixed and read-only. Several -> the form offers
      // the choice, which is the same dialog with its other parent row.
      parentTask:    parents.length === 1 ? toParent(parents[0]) : null,
      parentOptions: parents.length === 1 ? null : parents.map(toParent),
      // The form reports which parent it went under -- read it back
      // rather than assuming parents[0], because with several open tasks
      // the user chose one in the dialog.
      onSaved: res => {
        const pid = res?.parentTaskId || (parents.length === 1 ? parents[0].taskId : null);
        if (pid) (state.twExpanded || (state.twExpanded = new Set())).add(Number(pid));
        return refreshTreatmentState(riskId);
      }
    });
  }

  // ===================================================================
  // Treatment task actions — Complete, Reassign, Close
  //
  // Every one of these posts to an endpoint that ALREADY EXISTED and is
  // already proxied by Web/Controllers/TaskController.cs:
  //
  //     POST /practice/api/tasks/{id}/complete   sp_task_complete
  //     POST /practice/api/tasks/{id}/assign     sp_task_assign
  //     POST /practice/api/tasks/{id}/close      sp_task_close
  //
  // No API method, no procedure and no table changed for this. Closing
  // and reassigning were always possible; this page simply had no way in
  // to them, so the work had to be finished in Task Center.
  //
  // COMPLETE vs CLOSE
  // -----------------
  // sp_task_complete carries the BRD §12 mandatory-child gate and throws
  // 55693 while a mandatory sub task is open. sp_task_close carries no
  // child gate at all -- it sets closed_at and moves on.
  //
  // sp_risk_treatment_state counts a task as done when
  // "ClosedAt IS NOT NULL OR IsTerminal = 1", so BOTH open the residual
  // gate. Which means Close on a parent with open mandatory sub tasks
  // would unlock residual analysis while the work underneath it is
  // unfinished -- bypassing the rule the panel above the table promises.
  //
  // That is Task Center's existing behaviour and this page does not
  // quietly diverge from it, but it does not hide it either: the confirm
  // names the bypass and counts the sub tasks it is stepping over.
  // ===================================================================

  // Same normalisation as apiPost, against the task API rather than the
  // risk-centre one. A second base, not a second error contract.
  async function taskPost(taskId, path, body) {
    const url = U(`/practice/api/tasks/${encodeURIComponent(taskId)}${path}`);
    try {
      const r = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify(body || {})
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) {
        // reasonCode carries the BRD rule that refused the action.
        // Surfacing it is the difference between "no" and "why".
        return {
          success: false,
          error: (data.error || `HTTP ${r.status}`)
               + (data.reasonCode ? ` [${data.reasonCode}]` : "")
        };
      }
      return { success: true, ...data };
    } catch (err) {
      return { success: false, error: err.message || "Network error" };
    }
  }

  function taskLabel(task, taskId) {
    return task?.taskNumber
      ? `${task.taskNumber}${task.title ? ` — ${task.title}` : ""}`
      : `#${taskId}`;
  }

  async function completeTreatmentTask(taskId, riskId, task) {
    const remark = await dlg.prompt(
      `Completing ${taskLabel(task, taskId)}.`,
      { title: "Complete treatment task",
        inputLabel: "Completion remark (optional)",
        confirmText: "Complete task" });
    // null is cancel. An empty string is a deliberate "no remark", which
    // is allowed -- the endpoint takes CompletionRemark as optional.
    if (remark === null) return;

    const res = await taskPost(taskId, "/complete",
                               { completionRemark: remark || null });
    if (!res.success) {
      dlg.alert(res.error || "The task could not be completed.",
                { title: "Not completed", type: "error" });
      return;
    }
    // The sweep inside refreshTreatmentState is what moves the risk to
    // Monitoring once this was the last open task, so the gate and the
    // tiles both settle from one call.
    await refreshTreatmentState(riskId);
  }

  async function closeTreatmentTask(taskId, riskId, task, mandOpen) {
    const bypass = mandOpen > 0
      ? `\n\nWARNING: ${mandOpen} mandatory sub task${mandOpen === 1 ? " is" : "s are"} `
        + "still open. Closing steps over the BRD §12 gate and will unlock "
        + "residual analysis with that work unfinished. Complete the task "
        + "instead if the work was actually done."
      : "";

    if (!await dlg.confirm(
          `Close ${taskLabel(task, taskId)} without completing it?${bypass}`,
          { title: "Close treatment task",
            type: mandOpen > 0 ? "warning" : "confirm",
            confirmText: "Close task" })) return;

    const reason = await dlg.prompt(
      "Recorded on the task and on its audit trail.",
      { title: "Why is this task being closed?",
        inputLabel: "Reason", confirmText: "Close task" });
    if (reason === null) return;

    const res = await taskPost(taskId, "/close", {
      reasonCode: "RISK_TREATMENT_CLOSE",
      reasonText: reason || "Closed from the Risk Treatment page."
    });
    if (!res.success) {
      dlg.alert(res.error || "The task could not be closed.",
                { title: "Not closed", type: "error" });
      return;
    }
    await refreshTreatmentState(riskId);
  }

  // ---- Reassign ------------------------------------------------------
  // A picker, not the prompt()-for-an-employee-id that Task Center still
  // uses. state.employees is already loaded here for the owner and
  // acceptance selects, so the list is free.
  async function openTaskAssignModal(taskId, riskId) {
    const task = (state.treatmentTasks || []).find(t => t.taskId === taskId) || null;
    if (!state.employees.length) await loadEmployees();

    document.getElementById("taTaskId").value = taskId;
    document.getElementById("taTaskId").dataset.riskId = riskId;
    document.getElementById("taMessage").textContent = "";
    document.getElementById("taReason").value = "";
    document.getElementById("taMeta").innerHTML =
        dd("Task", escapeHtml(taskLabel(task, taskId)), true)
      + dd("Current owner", task?.ownerName || "unassigned")
      + dd("Status", task?.statusName || task?.statusCode)
      + dd("Priority", task?.priority);

    const sel = document.getElementById("taAssignee");
    sel.innerHTML = `<option value="">-- select --</option>`;
    state.employees.forEach(e => {
      const o = document.createElement("option");
      o.value = String(e.employeeId);
      o.textContent = e.employeeName + (e.employeeCode ? ` (${e.employeeCode})` : "");
      // The current owner is pre-selected so the picker opens showing
      // who holds it -- and submitting unchanged is refused below rather
      // than writing an audit row that records no change.
      if (task && e.employeeId === task.ownerEmployeeId) o.selected = true;
      sel.appendChild(o);
    });

    show("riskTaskAssignModal");
  }

  async function onTaskAssignSubmit(ev) {
    ev.preventDefault();
    const idEl   = document.getElementById("taTaskId");
    const taskId = Number(idEl.value);
    const riskId = Number(idEl.dataset.riskId || 0);
    const empId  = Number(document.getElementById("taAssignee").value || 0);
    const msg    = document.getElementById("taMessage");

    if (!empId) { msg.textContent = "Choose who this task is going to."; return; }

    const task = (state.treatmentTasks || []).find(t => t.taskId === taskId) || null;
    if (task && empId === task.ownerEmployeeId) {
      msg.textContent = "That is already the owner of this task.";
      return;
    }

    msg.textContent = "Reassigning…";
    const res = await taskPost(taskId, "/assign", {
      assignedToEmployeeId: empId,
      reasonCode: "RISK_TREATMENT_REASSIGN",
      reasonText: val("taReason") || "Reassigned from the Risk Treatment page."
    });
    if (!res.success) { msg.textContent = res.error || "Reassignment failed."; return; }

    hide("riskTaskAssignModal");
    await refreshTreatmentState(riskId);
  }

  // ===================================================================
  // Risk acceptance  (migration 264)
  // ===================================================================
  // ---- Review frequency (293) ----------------------------------------
  // The list is fetched once and kept: frequency_master is a master
  // table, so unlike the employee list it does not change with the
  // selected organisation.
  async function loadReviewFrequencies() {
    if (state.reviewFrequencies.length) return;
    state.reviewFrequencies = (await apiGet("/review-frequencies")) || [];
  }

  // Whether a cadence can produce a date at all. isCustom marks the rows
  // where the user types one; Event Driven and Continuous are not custom
  // but carry no value or unit, and "every event" is not a date either.
  // Both cases land here, so the caller has one question to ask.
  function frequencyDerivesDate(f) {
    return !!f && !f.isCustom && Number(f.frequencyValue) > 0 && !!f.frequencyUnit;
  }

  // today + value x unit. The unit strings come from frequency_master
  // (Day / Week / Month today); Quarter and Year are matched too so a
  // row added to the master later works without a code change, and an
  // unrecognised unit derives nothing rather than guessing a period.
  function addFrequency(from, value, unit) {
    const n = Number(value);
    switch (String(unit || "").trim().toLowerCase()) {
      case "day":     case "days":     return addDays(from, n);
      case "week":    case "weeks":    return addDays(from, n * 7);
      case "month":   case "months":   return addMonths(from, n);
      case "quarter": case "quarters": return addMonths(from, n * 3);
      case "year":    case "years":    return addMonths(from, n * 12);
      default: return null;
    }
  }

  // The select's whole effect on the form. Custom, blank, Event Driven
  // and Continuous all leave the date exactly as it is -- the user owns
  // it in those cases, and clearing what they typed would be worse than
  // doing nothing.
  //
  // Takes its ids as arguments (294) so the Accept form and the Bulk
  // review form share one rule. Two copies would be two chances for
  // "Quarterly" to mean different things on two screens.
  function applyReviewFrequencyToDate(selectId, dateId) {
    const id = Number(val(selectId) || 0);
    const f  = state.reviewFrequencies.find(x => Number(x.frequencyId) === id);
    if (!frequencyDerivesDate(f)) return;

    const due = addFrequency(new Date(), f.frequencyValue, f.frequencyUnit);
    if (due) setVal(dateId, isoDate(due));
  }

  // Populates one frequency select. selectedId is applied with .value,
  // which fires no change event -- so preselecting never rewrites the
  // date beside it. See the note in openAcceptancePage.
  function fillReviewFrequencySelect(selectId, selectedId, emptyLabel) {
    const sel = document.getElementById(selectId);
    if (!sel) return;
    sel.innerHTML = `<option value="">${escapeHtml(emptyLabel || "-- select --")}</option>`;
    state.reviewFrequencies.forEach(f => {
      const o = document.createElement("option");
      o.value = String(f.frequencyId);
      o.textContent = f.frequencyName;
      sel.appendChild(o);
    });
    sel.value = selectedId ? String(selectedId) : "";
  }

  // Which option to preselect for a risk that already has a cadence.
  // The id wins where present -- it is the exact value. The name is the
  // fallback, and keeps working if a master row is ever re-seeded under
  // a new id.
  function resolveReviewFrequencyId(id, name) {
    if (id) return id;
    if (!name) return null;
    const match = state.reviewFrequencies.find(f =>
      String(f.frequencyName).toLowerCase() === String(name).toLowerCase());
    return match ? match.frequencyId : null;
  }

  // ===================================================================
  // Accept Risk -- a FULL PAGE
  //
  // It was a modal. Acceptance is the one step of the four that is a
  // JUDGEMENT rather than a measurement -- somebody signs that this
  // level of residual risk is acceptable -- and the modal could show
  // five summary lines of the record that judgement is about. The page
  // shows all of it, read-only, above the four fields it asks for.
  //
  // TWO READS, not one. The modal needed only /acceptance (the gate and
  // the four defaults). The page also needs the register row for every
  // read-only section, exactly as openResidualPage does -- so the same
  // renderers can be pointed at this page's hosts instead of a second
  // set being written.
  //
  // The form ids are the modal's, unchanged, so onAcceptanceSubmit and
  // the frequency-to-date rule came across untouched.
  // ===================================================================
  async function openAcceptancePage(riskId) {
    const [risk, info] = await Promise.all([
      apiGet(`/register/${riskId}`),
      apiGet(`/register/${riskId}/acceptance`)
    ]);
    if (!risk || !info) { dlg.alert("Risk not found.", { type: "error" }); return; }
    if (!state.employees.length) await loadEmployees();
    await loadReviewFrequencies();
    state.activeRisk = risk;

    // Where Back returns to. Acceptance is reachable from the register
    // row menu, the Accept tab, the treatment dispatch and the residual
    // page's Save & accept, and being dropped on a tab the user did not
    // come from is a small betrayal of context.
    analysisReturnTab = state.tab || "register";

    document.getElementById("acRiskId").value = riskId;
    document.getElementById("acMessage").textContent = "";

    // The risk is the page's subject, so it is the heading -- not the
    // first line of a metadata list, which is what it had to be inside a
    // modal whose header was the fixed title "Accept risk".
    setText("acPageTitle", `${risk.riskNumber} — ${risk.riskTitle}`);
    setText("acPageSubtitle", info.acceptedOn
      ? "Already accepted. Re-recording the decision replaces what was stored."
      : "Confirm that this level of residual risk is acceptable, and set when it comes back for review.");
    document.getElementById("acHeadStatus").innerHTML = lifecycleChip(risk);

    // ---- Read-only: the risk, and what it scored ---------------------
    // The SAME field lists the residual page's step 1 uses. Two lists
    // rather than one long one: "what the risk is" and "what it scored"
    // are two questions.
    document.getElementById("acSummary").innerHTML =
      dd("Risk ID", risk.riskNumber) +
      dd("Statement", risk.riskStatement) +
      dd("Category", risk.riskCategoryNames || risk.riskCategoryName) +
      dd("Owner", risk.riskOwnerName) +
      dd("Business function", risk.businessFunctionName) +
      dd("Business unit", risk.businessUnit) +
      dd("Linked practice", risk.linkedPracticeName) +
      dd("Source", risk.sourceName || risk.sourceTypeCode);

    // Same five fields as the residual page's inherent panel, for the
    // same reasons -- no Cause, no Controls at analysis (the Analysis
    // page stopped asking for them) and no Score (the chip and
    // Likelihood x Impact already carry it).
    document.getElementById("acInherent").innerHTML =
      dd("Inherent rating", severityChip(risk.inherentRatingCode), true) +
      dd("Likelihood", risk.likelihoodName) +
      dd("Impact", risk.impactName) +
      dd("Analysed", risk.analysisOn
          ? `${window.gracFormatDateOnly(risk.analysisOn)}${
              risk.analysedByName ? ` by ${escapeHtml(risk.analysedByName)}` : ""}${
              ""}`
          : null, true) +
      dd("Impact analysis", risk.potentialConsequence, false, "pm-detail-span");

    // ---- Read-only: what is left, which is what is being accepted ----
    document.getElementById("acResidual").innerHTML = risk.residualRatingCode
      ? dd("Residual rating", severityChip(risk.residualRatingCode), true) +
        dd("Likelihood", risk.residualLikelihoodName) +
        dd("Impact", risk.residualImpactName) +
        dd("Score", risk.residualRatingScore != null ? String(risk.residualRatingScore) : null) +
        // residualAssessedOn / residualAssessedByName -- the names the
        // register-detail model actually uses (RiskRegisterDetail in
        // RiskCentreModels.cs), and the ones the View Risk page reads.
        dd("Assessed", risk.residualAssessedOn
            ? `${window.gracFormatDateOnly(risk.residualAssessedOn)}${
                risk.residualAssessedByName ? ` by ${escapeHtml(risk.residualAssessedByName)}` : ""}${
                ""}`
            : null, true) +
        dd("Analyst remark", risk.residualRemarks, false, "pm-detail-span")
      // Not an empty grid: a risk with no residual score cannot be
      // accepted, and the reason has to be on screen next to the way out
      // of it. The gate in step 4 says the same thing; this says it
      // where the missing value would have been.
      : `<div class="pm-detail-item pm-detail-span"><dt>Residual rating</dt>`
        + `<dd><span class="pm-hint">Not assessed yet. A risk cannot be accepted until the `
        + `residual score is recorded &mdash; use <strong>Open residual analysis</strong> above.`
        + `</span></dd></div>`;

    // The rail, drawn from the register row alone so it is on screen
    // with the rest of the page. Step 2's counts are filled in below,
    // once the treatment state has been read.
    renderAcceptanceFlow();

    const gate = document.getElementById("acGuidance");
    gate.textContent = info.acceptGuidance || "";
    gate.className = "risk-gate " + (info.canAccept ? "is-ready" : "is-blocked");

    const by = document.getElementById("acAcceptedBy");
    by.innerHTML = `<option value="">-- select --</option>`;
    state.employees.forEach(e => {
      const o = document.createElement("option");
      o.value = e.employeeId;
      o.textContent = e.employeeName + (e.employeeCode ? ` (${e.employeeCode})` : "");
      by.appendChild(o);
    });
    // The risk owner accepting their own risk is the common case, so it
    // is the default. An existing acceptance wins over it -- re-opening
    // the form must show what was recorded, not re-propose a default.
    by.value = info.acceptedByEmployeeId || info.riskOwnerEmployeeId || "";

    // 293. Preselected from the cadence the acceptance already carries:
    // sp_risk_acceptance_get joins frequency_master and returns
    // reviewFrequencyName alongside the id, so no second lookup is
    // needed to show what this risk was last set to.
    fillReviewFrequencySelect(
      "acReviewFrequency",
      resolveReviewFrequencyId(info.reviewFrequencyId, info.reviewFrequencyName),
      "-- select --");

    setVal("acAcceptedDate", info.acceptedOn ? isoDate(info.acceptedOn) : isoDate(new Date()));
    // A year out, as a starting point rather than a policy. The field is
    // required and the server refuses a past date; the default only
    // saves the common case a calendar click.
    // Set AFTER the frequency select above, and deliberately not derived
    // from it: assigning select.value in script fires no change event, so
    // re-opening an acceptance shows the date that was RECORDED, not a
    // date recomputed from today. The frequency only moves the date when
    // a person picks one.
    setVal("acNextReview", info.nextReviewDate ? isoDate(info.nextReviewDate) : isoDate(addMonths(new Date(), 12)));
    setVal("acNote", info.acceptanceNote || "");

    // Show the page BEFORE the treatment state and the scope panel load,
    // so the form is on screen while they arrive instead of the click
    // appearing to do nothing until three round trips finish. The same
    // order openResidualPage uses.
    showAcceptancePage();

    // ---- Read-only: what was done about it ---------------------------
    // The SAME renderer the Risk Treatment page uses, pointed at this
    // page's hosts and told not to sweep: a read-only section must not
    // move a risk's status as a side effect of being looked at.
    const st = await refreshTreatmentState(riskId, {
      gateId: "acTreatmentGate", tilesId: "acTiles", bodyId: "acTaskBody",
      residualBtnId: null, colspan: 7, readOnly: true, sync: false
    });
    // Not stashed on state, unlike the residual page's: nothing on this
    // page re-renders the rail after load, because nothing above the
    // decision panel can change. It is passed straight to the one call
    // that needs it.

    // The four values that ARE the treatment decision live on the
    // register row; the counts, tasks and gate above came from
    // sp_risk_treatment_state.
    document.getElementById("acTreatmentMeta").innerHTML =
      dd("Treatment strategy", risk.treatmentOptionName || "not chosen") +
      dd("Decided", risk.treatmentDecidedOn
          ? `${window.gracFormatDateOnly(risk.treatmentDecidedOn)}${
              risk.treatmentDecidedByName ? ` by ${escapeHtml(risk.treatmentDecidedByName)}` : ""}`
          : null, true) +
      dd("Risk owner", risk.riskOwnerName) +
      dd("Current stage", stageCell(risk), true);

    // Now the rail knows what step 2 is worth.
    renderAcceptanceFlow(st);

    // Both scope hosts, read-only, from ONE mount and one /mapping call.
    // No lazy expand any more: on a page whose purpose is showing the
    // record, this section IS the page.
    await riskMapping.mount("acMapping", riskId, { readOnly: true, showHeading: false,
                                                   impactHostId: "acImpactScope" });
  }

  // ---- The Inherent -> Treatment -> Residual -> Acceptance rail -------
  //
  // renderResidualFlow's twin, and deliberately not a shared function
  // with it: the two rails agree on steps 1 and 2 but disagree on the
  // two that matter. There, step 3 is the score BEING CHOSEN and step 4
  // is "next"; here, step 3 is the score AS RECORDED and step 4 is the
  // current step, carrying the acceptance as it stands.
  //
  // NOTHING IS FETCHED HERE. It renders what the page already knows.
  function renderAcceptanceFlow(st) {
    const host = document.getElementById("acFlow");
    const risk = state.activeRisk;
    if (!host || !risk) return;

    const total = st ? (st.treatmentTaskCount || 0) : null;
    const open  = st ? (st.openTreatmentTaskCount || 0) : null;
    const done  = st ? (st.closedTreatmentTaskCount || 0) : null;
    const twSub = st === undefined ? "Loading treatment state..."
                : !st              ? "Treatment state unavailable"
                : total === 0      ? "No treatment task raised"
                : open > 0         ? `${done} of ${total} tasks closed — ${open} still open`
                                   : `All ${total} task${total === 1 ? "" : "s"} closed`;

    const accepted = !!risk.acceptedOn;

    host.innerHTML =
        step(1, "Inherent risk",
             severityChip(risk.inherentRatingCode),
             `${escapeHtml(risk.likelihoodName || "?")} x ${escapeHtml(risk.impactName || "?")}`)
      + step(2, "Risk treatment",
             escapeHtml(risk.treatmentOptionName || "Not chosen"),
             twSub, { warn: !!st && !st.residualAvailable })
      + step(3, "Residual risk",
             risk.residualRatingCode
               ? severityChip(risk.residualRatingCode)
               : `<span class="pm-hint">Not assessed</span>`,
             risk.residualRatingCode
               ? `${escapeHtml(risk.residualLikelihoodName || "?")} x ${escapeHtml(risk.residualImpactName || "?")}`
                 + (risk.residualRatingScore != null ? ` — score ${risk.residualRatingScore}` : "")
               : "Score it before accepting",
             // Amber, not just muted: no residual score is the one state
             // that stops this page saving at all.
             { warn: !risk.residualRatingCode })
      + step(4, "Risk acceptance",
             accepted ? `<span class="pm-badge">Accepted</span>`
                      : `<span class="pm-hint">Recording now</span>`,
             accepted
               ? `Accepted ${window.gracFormatDateOnly(risk.acceptedOn)}${
                   risk.nextReviewDate
                     ? ` — next review ${window.gracFormatDateOnly(risk.nextReviewDate)}` : ""}`
               : "The decision below is what completes the risk's lifecycle",
             { current: true });

    // NO ARROW ITEMS -- the rail carries .risk-flow-4. See the note in
    // renderResidualFlow.
    function step(n, label, value, sub, o) {
      o = o || {};
      return `<li class="risk-flow-step${o.current ? " is-current" : ""}${o.warn ? " is-warn" : ""}">
        <div class="k"><span class="n">${n}</span>${escapeHtml(label)}</div>
        <div class="v">${value}</div>
        <div class="s">${sub}</div>
      </li>`;
    }
  }

  async function onAcceptanceSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("acMessage");
    msg.textContent = "";
    const riskId = Number(document.getElementById("acRiskId").value);
    const next   = val("acNextReview");

    // Checked here as an affordance only. 56601 and 56602 are the rule,
    // and they arrive here verbatim if this check is ever wrong.
    if (!next) { msg.textContent = "A next review date is required — without one this risk never returns for review."; return; }
    if (new Date(next) <= new Date(isoDate(new Date()))) {
      msg.textContent = "The next review date must be in the future."; return;
    }

    const res = await apiPost(`/register/${riskId}/acceptance`, {
      nextReviewDate:       next,
      acceptedByEmployeeId: val("acAcceptedBy") ? Number(val("acAcceptedBy")) : null,
      acceptedDate:         val("acAcceptedDate") || null,
      acceptanceNote:       val("acNote") || null,
      // 293. Null when nothing was picked, which is a real answer: this
      // date has no cadence behind it. The date above is still what the
      // server validates and what brings the risk back.
      reviewFrequencyId:    val("acReviewFrequency") ? Number(val("acReviewFrequency")) : null
    });
    if (!res || res.success === false) { msg.textContent = (res && res.error) || "Failed."; return; }

    // Leave through the one exit every full page uses -- it unmounts the
    // scope hosts and returns to the tab this page was opened from.
    // Only on success: a failed accept leaves the page up with the
    // message on it, which is the whole point of a sticky action bar.
    backFromFullPage();
    dlg.alert(`Accepted by ${res.acceptedByName || "—"}. `
            + `Next review ${window.gracFormatDateOnly(res.nextReviewDate)}.`,
              { title: "Risk accepted", type: "success" });
    await refreshRegister();
    refreshReviewBadge();
    // 295. Accepting from the Accept tab must remove the row from the
    // pending list and decrement its badge, or the tab keeps offering a
    // risk that has just been dealt with.
    refreshAcceptBadge();
    if (state.tab === "accept")   await refreshAcceptDue();
    if (state.tab === "calendar") await refreshCalendar();
  }

  // ===================================================================
  // Accept Risk  (migration 295)
  //
  // The list is the REGISTER filtered to workflowStageCode, not a query
  // of its own. vw_pm_risk_workflow_stage (264) already decides what
  // "ready to accept" means; a second definition here would let this tab
  // and the register grid disagree about the same risk.
  //
  // The stage select is the whole toggle: AcceptanceDue (waiting) or
  // Accepted (done). One query-string value, same endpoint, same
  // renderer.
  // ===================================================================
  function acceptStage() {
    return val("accFilterStage") || "AcceptanceDue";
  }

  async function refreshAcceptDue() {
    const tbody = document.getElementById("accTableBody");
    if (!tbody) return;
    if (!state.organizationId) {
      tbody.innerHTML = `<tr><td colspan="10" class="pm-empty-row">Select an organization.</td></tr>`;
      return;
    }
    tbody.innerHTML = `<tr><td colspan="10" class="pm-empty-row">Loading...</td></tr>`;

    const stage = acceptStage();
    const qs = new URLSearchParams({
      organizationId:    state.organizationId,
      workflowStageCode: stage,
      ...pageParams(pagers.acc)
    });
    const owner  = val("accFilterOwner");
    const rating = val("accFilterRating");
    const search = val("accFilterSearch");
    if (owner)  qs.set("ownerEmployeeId", owner);
    if (rating) qs.set("ratingCode", rating);
    if (search) qs.set("search", search);

    const res = await apiGetChecked(`/register?${qs}`);
    if (!res.ok) {
      tbody.innerHTML = `<tr><td colspan="10" class="pm-empty-row">`
        + `Could not load risks: ${escapeHtml(res.error)}</td></tr>`;
      pagers.acc?.clear();
      return;
    }
    const rows = res.data?.rows || [];
    pagers.acc?.setTotal(res.data?.totalRows, rows.length);

    if (!rows.length) {
      tbody.innerHTML = `<tr><td colspan="10" class="pm-empty-row">`
        + (stage === "Accepted"
            ? `No risks have been accepted yet.`
            : `Nothing is waiting for acceptance. A risk appears here once its `
              + `analysis is complete and either Tolerate was chosen or its residual `
              + `risk has been assessed.`)
        + `</td></tr>`;
      syncAcceptBulkBar();
      return;
    }

    // Already-accepted rows are not selectable: bulk accept would be
    // re-accepting them, which is a review decision and belongs to the
    // Review tab. The checkbox cell stays (so the columns line up) and
    // simply holds nothing.
    const selectable = stage !== "Accepted";

    tbody.innerHTML = rows.map(r => `<tr>
      <td>${selectable
              ? `<input type="checkbox" class="acc-pick" value="${r.riskRegisterId}"
                        data-risk-number="${escapeHtml(r.riskNumber)}"
                        aria-label="Select ${escapeHtml(r.riskNumber)}" />`
              : ``}</td>
      <td><a href="#" data-open-risk="${r.riskRegisterId}">${escapeHtml(r.riskNumber)}</a></td>
      <td>${escapeHtml(r.riskTitle)}<br>
          <span class="pm-hint">${escapeHtml(r.riskCategoryNames || r.riskCategoryName || "")}</span></td>
      <td>${escapeHtml(r.riskOwnerName || "--")}</td>
      <td>${r.inherentRatingCode ? severityChip(r.inherentRatingCode) : "--"}</td>
      <td>${r.residualRatingCode ? severityChip(r.residualRatingCode)
                                 : `<span class="pm-hint">not assessed</span>`}</td>
      <td>${escapeHtml(r.treatmentOptionName || "--")}</td>
      <td>${r.acceptedOn ? `${window.gracFormatDateOnly(r.acceptedOn)}<br>
            <span class="pm-hint">${escapeHtml(r.acceptedByName || "")}</span>` : "--"}</td>
      <td>${r.nextReviewDate ? window.gracFormatDateOnly(r.nextReviewDate) : "--"}</td>
      <td><button type="button" class="pm-button primary" data-accept-risk="${r.riskRegisterId}">
            <i class="fa-solid fa-circle-check"></i> ${selectable ? "Accept" : "Re-accept"}</button></td>
    </tr>`).join("");

    // A re-render replaces every row, so any previous selection is gone.
    syncAcceptBulkBar();
  }

  function updateAcceptBadge(n) {
    const badge = document.getElementById("acceptDueBadge");
    if (!badge) return;
    badge.textContent = String(n);
    badge.hidden = n <= 0;
  }

  // Counts what is WAITING, never what the grid happens to be showing --
  // switching the toggle to "Already accepted" must not make the badge
  // claim nothing needs attention.
  async function refreshAcceptBadge() {
    if (!state.organizationId) { updateAcceptBadge(0); return; }
    const res = await apiGet(
      `/register?organizationId=${state.organizationId}&workflowStageCode=AcceptanceDue&pageSize=1`);
    updateAcceptBadge(res?.totalRows || 0);
  }

  function selectedAcceptIds() {
    return Array.from(document.querySelectorAll("#accTableBody .acc-pick:checked"))
                .map(cb => Number(cb.value))
                .filter(Boolean);
  }

  function syncAcceptBulkBar() {
    const bar   = document.getElementById("accBulkBar");
    const count = document.getElementById("accBulkCount");
    const all   = document.getElementById("accSelectAll");
    if (!bar) return;

    const picked = selectedAcceptIds().length;
    const total  = document.querySelectorAll("#accTableBody .acc-pick").length;

    bar.hidden = picked === 0;
    if (count) count.textContent = `${picked} risk${picked === 1 ? "" : "s"} selected`;

    if (all) {
      all.checked = total > 0 && picked === total;
      all.indeterminate = picked > 0 && picked < total;
    }
  }

  // ---- Bulk accept (295) ---------------------------------------------
  async function openBulkAcceptModal() {
    const ids = selectedAcceptIds();
    if (!ids.length) {
      dlg.alert("Select at least one risk first.", { type: "warning" });
      return;
    }
    if (!state.employees.length) await loadEmployees();
    await loadReviewFrequencies();

    document.getElementById("baSubject").textContent =
      `${ids.length} risk${ids.length === 1 ? "" : "s"} selected. `
      + `The same accepter, date, frequency and rationale are recorded on each.`;

    // Same employee list the single Accept modal uses. Defaulted to the
    // signed-in user where we can identify them -- they are the common
    // case -- while staying changeable, because a committee chair often
    // accepts what somebody else is clicking.
    const by = document.getElementById("baAcceptedBy");
    by.innerHTML = `<option value="">-- select --</option>`;
    state.employees.forEach(e => {
      const o = document.createElement("option");
      o.value = e.employeeId;
      o.textContent = e.employeeName + (e.employeeCode ? ` (${e.employeeCode})` : "");
      by.appendChild(o);
    });
    // Rendered into the form by the view from session (see the @@ block at
    // the top of risk-centre.cshtml). Blank when the account is not
    // mapped to an employee, in which case the picker opens unset and the
    // required-field check below asks for one.
    const sessionEmp = document.getElementById("riskBulkAcceptForm")?.dataset.sessionEmployeeId || "";
    // Only if that employee is actually in this organisation's list --
    // pre-selecting someone the server would refuse (56608) would be
    // offering a default that cannot be saved.
    by.value = state.employees.some(e => String(e.employeeId) === String(sessionEmp)) ? sessionEmp : "";

    fillReviewFrequencySelect("baReviewFrequency", null, "-- select --");
    setVal("baAcceptedDate", isoDate(new Date()));
    setVal("baNextReview", isoDate(addMonths(new Date(), 12)));
    setVal("baNote", "");

    document.getElementById("baMessage").textContent = "";
    document.getElementById("baOutcome").innerHTML = "";

    // Undo what a previous run left behind, exactly as the bulk review
    // modal does -- otherwise the second use opens unable to save.
    const submit = document.getElementById("baSubmit");
    if (submit) { submit.disabled = false; submit.removeAttribute("title"); }
    document.querySelectorAll("[data-close-bulk-accept]").forEach(b => {
      if (b.tagName === "BUTTON" && b.textContent.trim() === "Close") b.textContent = "Cancel";
    });

    show("riskBulkAcceptModal");
  }

  async function onBulkAcceptSubmit(ev) {
    ev.preventDefault();
    const ids  = selectedAcceptIds();
    const msg  = document.getElementById("baMessage");
    const next = val("baNextReview");
    const by   = val("baAcceptedBy");

    msg.style.color = "";
    if (!ids.length) { msg.textContent = "Nothing is selected any more — close and re-select."; return; }
    if (!by)   { msg.textContent = "Choose who is accepting these risks."; return; }

    // Checked here as an affordance only. 56751 and 56752 are the rule.
    if (!next) { msg.textContent = "A next review date is required — without one these risks never return for review."; return; }
    if (new Date(next) <= new Date(isoDate(new Date()))) {
      msg.textContent = "The next review date must be in the future."; return;
    }

    document.getElementById("baSubmit").disabled = true;
    msg.textContent = `Accepting ${ids.length} risk${ids.length === 1 ? "" : "s"}...`;

    const res = await apiPost("/register/bulk-accept", {
      riskRegisterIds:      ids,
      nextReviewDate:       next,
      acceptedByEmployeeId: Number(by),
      acceptedDate:         val("baAcceptedDate") || null,
      acceptanceNote:       val("baNote") || null,
      reviewFrequencyId:    val("baReviewFrequency") ? Number(val("baReviewFrequency")) : null
    });

    document.getElementById("baSubmit").disabled = false;

    // A rejected BATCH -- nothing selected, no or past date, bad cadence.
    if (!res || res.success === false) {
      msg.style.color = "#b91c1c";
      msg.textContent = res?.error || "The risks could not be accepted.";
      return;
    }

    const rows    = res.rows || [];
    const skipped = rows.filter(r => r.outcome === "Skipped");

    await refreshAcceptDue();
    refreshAcceptBadge();
    refreshReviewBadge();
    if (state.tab === "calendar") await refreshCalendar();


    // CLOSE WHEN THERE IS NOTHING TO READ, STAY OPEN WHEN THERE IS --
    // the same rule the bulk review modal follows. A report saying
    // "all twelve fine" that the user must dismiss reads as a save that
    // did not work; a report naming three skipped risks must be read.
    if (!skipped.length) {
      hide("riskBulkAcceptModal");
      dlg.alert(`${res.appliedCount} risk${res.appliedCount === 1 ? "" : "s"} accepted. `
              + `Next review ${window.gracFormatDateOnly(next)}.`,
                { title: "Risks accepted", type: "success" });
      return;
    }

    msg.style.color = "";
    msg.textContent = `${res.appliedCount} accepted, ${res.skippedCount} skipped.`;
    // Skipped first: those are the ones needing a decision.
    document.getElementById("baOutcome").innerHTML =
      `<div class="risk-gate is-blocked" style="margin-bottom:8px;">`
      + `${skipped.length} risk${skipped.length === 1 ? " was" : "s were"} not accepted. `
      + `Each reason comes from the acceptance rules, not from this form.</div>`
      + `<ul class="pm-hint" style="margin:0;padding-left:18px;">`
      + skipped.map(r =>
          `<li><strong>${escapeHtml(r.riskNumber || String(r.riskRegisterId))}</strong> — `
          + `${escapeHtml(r.reason || "skipped")}</li>`).join("")
      + `</ul>`;

    // The accepted ones are gone from the pending list, so re-submitting
    // would only retry the skipped ones -- which will fail identically
    // until someone fixes them. Disabling says so.
    const submit = document.getElementById("baSubmit");
    if (submit) {
      submit.disabled = true;
      submit.title = "Fix the skipped risks individually, then try again.";
    }
    document.querySelectorAll("[data-close-bulk-accept]").forEach(b => {
      if (b.tagName === "BUTTON" && b.textContent.trim() === "Cancel") b.textContent = "Close";
    });
  }

  // ===================================================================
  // Review Risk  (migration 264)
  //
  // The list is "next_review_date <= today". The client does not filter:
  // sp_risk_review_due_list owns the rule, and re-implementing the date
  // comparison here would give the badge and the grid two chances to
  // disagree about what "due" means.
  // ===================================================================
  async function refreshReviewDue() {
    const tbody = document.getElementById("revTableBody");
    if (!state.organizationId) {
      tbody.innerHTML = `<tr><td colspan="11" class="pm-empty-row">Select an organization.</td></tr>`;
      return;
    }
    tbody.innerHTML = `<tr><td colspan="11" class="pm-empty-row">Loading...</td></tr>`;

    // pageSize now comes from the pager rather than a fixed 100, which
    // silently truncated any organisation with more than that due.
    const qs = new URLSearchParams({
      organizationId: state.organizationId,
      ...pageParams(pagers.rev)
    });
    const owner   = val("revFilterOwner");
    const rating  = val("revFilterRating");
    const search  = val("revFilterSearch");
    const horizon = val("revFilterHorizon");
    if (owner)   qs.set("ownerEmployeeId", owner);
    if (rating)  qs.set("ratingCode", rating);
    if (search)  qs.set("search", search);
    if (horizon) qs.set("includeFutureDays", horizon);

    const res = await apiGetChecked(`/review-due?${qs}`);
    if (!res.ok) {
      tbody.innerHTML = `<tr><td colspan="11" class="pm-empty-row">`
        + `Could not load risks due for review: ${escapeHtml(res.error)}</td></tr>`;
      pagers.rev?.clear();
      return;
    }
    const rows = res.data?.rows || [];
    pagers.rev?.setTotal(res.data?.totalRows, rows.length);
    if (!rows.length) {
      tbody.innerHTML = `<tr><td colspan="11" class="pm-empty-row">`
        + (horizon
            ? `No risks due for review, or due in the next ${escapeHtml(horizon)} days.`
            : `No risks are due for review. Risks appear here on or after their next review date.`)
        + `</td></tr>`;
      updateReviewBadge(0);
      return;
    }
    // The checkbox carries the values the bulk bar needs to describe the
    // selection, so nothing has to be re-fetched to say "3 selected".
    tbody.innerHTML = rows.map(r => `<tr>
      <td><input type="checkbox" class="rev-pick" value="${r.riskRegisterId}"
                 data-risk-number="${escapeHtml(r.riskNumber)}"
                 aria-label="Select ${escapeHtml(r.riskNumber)}" /></td>
      <td><a href="#" data-open-risk="${r.riskRegisterId}">${escapeHtml(r.riskNumber)}</a></td>
      <td>${escapeHtml(r.riskTitle)}<br>
          <span class="pm-hint">${escapeHtml(r.riskCategoryName || "")}</span></td>
      <td>${escapeHtml(r.riskOwnerName || "--")}</td>
      <td>${r.inherentRatingCode ? severityChip(r.inherentRatingCode) : "--"}</td>
      <td>${r.residualRatingCode ? severityChip(r.residualRatingCode)
                                 : `<span class="pm-hint">not assessed</span>`}</td>
      <td>${escapeHtml(r.treatmentOptionName || "--")}</td>
      <td>${r.acceptedOn ? `${window.gracFormatDateOnly(r.acceptedOn)}<br>
            <span class="pm-hint">${escapeHtml(r.acceptedByName || "")}</span>` : "--"}</td>
      <td>${r.nextReviewDate ? window.gracFormatDateOnly(r.nextReviewDate) : "--"}</td>
      <td>${overdueCell(r)}</td>
      <td><button type="button" class="pm-button primary" data-review-risk="${r.riskRegisterId}">
            <i class="fa-solid fa-rotate-left"></i> Review</button></td>
    </tr>`).join("");

    // Only the genuinely due ones count towards the badge. With a
    // horizon set the grid also shows what is coming, and counting those
    // as due would make the badge lie.
    updateReviewBadge(rows.filter(r => r.isDue).length);
    // A re-render replaces every row, so the previous selection is gone.
    // Said out loud rather than left as a stale count above an empty grid.
    syncBulkBar();
  }

  // ===================================================================
  // Bulk review  (migration 270)
  //
  // NOT the single-risk Review over a list. That one re-assesses:
  // sp_risk_review_perform requires likelihood and impact and produces a
  // new rating. Those are per-risk judgements, and one pair applied to
  // thirty risks would be an assessment nobody made.
  //
  // This is a review DISPOSITION over a selection -- note, standing,
  // next date -- and a risk needing a genuine re-score still goes
  // through the single-risk path, which is untouched.
  // ===================================================================
  function selectedReviewIds() {
    return Array.from(document.querySelectorAll("#revTableBody .rev-pick:checked"))
                .map(cb => Number(cb.value))
                .filter(Boolean);
  }

  function syncBulkBar() {
    const bar   = document.getElementById("revBulkBar");
    const count = document.getElementById("revBulkCount");
    const all   = document.getElementById("revSelectAll");
    if (!bar) return;

    const picked = selectedReviewIds().length;
    const total  = document.querySelectorAll("#revTableBody .rev-pick").length;

    bar.hidden = picked === 0;
    if (count) count.textContent = `${picked} risk${picked === 1 ? "" : "s"} selected`;

    // Indeterminate rather than a half-truth: with 3 of 10 picked, a
    // checkbox that reads either "all" or "none" is wrong both ways.
    if (all) {
      all.checked = total > 0 && picked === total;
      all.indeterminate = picked > 0 && picked < total;
    }
  }

  async function openBulkReviewModal() {
    const ids = selectedReviewIds();
    if (!ids.length) {
      dlg.alert("Select at least one risk first.", { type: "warning" });
      return;
    }
    document.getElementById("brSubject").textContent =
      `${ids.length} risk${ids.length === 1 ? "" : "s"} selected. `
      + `Each is recorded as reviewed and sent to Accept Risk, with the same `
      + `description, frequency and suggested review date.`;
    setVal("brRemarks", "");
    setVal("brNextReview", "");

    // 294. The same list the Accept form uses, through the same loader —
    // fetched once for the session, so opening this modal after an
    // acceptance costs nothing.
    await loadReviewFrequencies();
    fillReviewFrequencySelect("brReviewFrequency", null, "-- leave unchanged --");
    document.getElementById("brMessage").textContent = "";
    document.getElementById("brOutcome").innerHTML = "";

    // Undo what a previous run left behind. After a save with skips the
    // submit button is disabled and Cancel is relabelled "Close"; without
    // this reset the next bulk review would open unable to save, which is
    // the kind of bug that only appears on the second use.
    const submit = document.getElementById("brSubmit");
    if (submit) { submit.disabled = false; submit.removeAttribute("title"); }
    document.querySelectorAll("[data-close-bulk-review]").forEach(b => {
      if (b.tagName === "BUTTON" && b.textContent.trim() === "Close") b.textContent = "Cancel";
    });

    show("riskBulkReviewModal");
  }

  async function onBulkReviewSubmit(ev) {
    ev.preventDefault();
    const ids  = selectedReviewIds();
    const msg  = document.getElementById("brMessage");
    const note = val("brRemarks");
    const due  = val("brNextReview");
    const freq = val("brReviewFrequency");

    msg.style.color = "";
    if (!ids.length) { msg.textContent = "Nothing is selected any more — close and re-select."; return; }
    // Mirrors 56721. The status picker is gone (299), so the two fields
    // that can satisfy it are the note and the date -- and picking a
    // frequency fills the date, so this only fires on a genuinely empty
    // form. The procedure's own default status is applied AFTER that
    // check, which is why an empty submission is still refused rather
    // than quietly recording thirty reviews nobody described.
    if (!note && !due) {
      msg.textContent = "Add a description, or a next review date, to record this review.";
      return;
    }

    // Checked here as well as in SQL (56722) so the user is told before a
    // round trip. The rule is the server's; this is only earlier.
    if (due) {
      const today = new Date(); today.setHours(0, 0, 0, 0);
      if (new Date(due + "T00:00:00") <= today) {
        msg.textContent = "The next review date must be in the future — otherwise every "
                        + "selected risk would be refused for the same reason.";
        return;
      }
    }

    document.getElementById("brSubmit").disabled = true;
    msg.textContent = `Applying to ${ids.length} risk${ids.length === 1 ? "" : "s"}...`;

    const res = await apiPost("/register/bulk-review", {
      riskRegisterIds: ids,
      reviewRemarks:   note || null,
      // statusCode is deliberately NOT sent (299). Omitted, the procedure
      // sets Monitoring, which is what routes these risks to the Accept
      // tab. Sending one would override that -- which is exactly how a
      // review could previously go nowhere.
      nextReviewDate:  due  || null,
      // The reviewer's suggestion, carried to the Accept screen with the
      // date rather than deciding anything here.
      reviewFrequencyId: freq ? Number(freq) : null
    });

    document.getElementById("brSubmit").disabled = false;

    // A rejected BATCH -- nothing selected, past date, bulk close.
    if (!res || res.success === false) {
      msg.style.color = "#b91c1c";
      msg.textContent = res?.error || "The bulk review could not be applied.";
      return;
    }

    // CLOSE WHEN THERE IS NOTHING TO READ, STAY OPEN WHEN THERE IS.
    //
    // The modal used to stay open unconditionally so the per-risk report
    // could be shown -- but when every risk succeeded that report says
    // "all fine" and the dialog just sits there, which reads as a save
    // that did not work.
    //
    // So the outcome decides:
    //   nothing skipped -> close, and confirm in one line. The grid
    //                      behind it already shows the new review dates.
    //   something skipped -> stay open with the list, because those
    //                      risks were NOT updated and the user has to
    //                      see which and why. Closing would bury it.
    const skipped = res.skippedCount
                 ?? (res.rows || []).filter(r => r.outcome === "Skipped").length;

    await refreshReviewDue();      // also clears the selection (rows are re-rendered)
    refreshReviewBadge?.();
    // 297. A bulk review with the date left blank clears the schedule,
    // which moves those risks onto the Accept tab. Refresh its badge (and
    // the grid, if that is where the user is) or the count sits stale
    // until something else happens to reload it.
    refreshAcceptBadge?.();
    if (state.tab === "accept") await refreshAcceptDue();

    if (!skipped) {
      hide("riskBulkReviewModal");
      const applied = res.appliedCount
                   ?? (res.rows || []).filter(r => r.outcome === "Applied").length;
      const same    = res.unchangedCount ?? 0;
      dlg.alert(
        applied
          ? `${applied} risk${applied === 1 ? "" : "s"} reviewed`
            + (same ? `, ${same} already up to date.` : ".")
          : "Nothing was different — no changes were recorded.",
        { title: "Bulk review", type: applied ? "success" : "info" });
      return;
    }

    renderBulkOutcome(res);

    // The work is done; the dialog is now a report. Re-submitting would
    // re-review the risks that already succeeded, so the primary action
    // is retired and Cancel becomes the way out.
    const submit = document.getElementById("brSubmit");
    if (submit) { submit.disabled = true; submit.title = "Already applied — close to continue."; }
    document.querySelectorAll("[data-close-bulk-review]").forEach(b => {
      if (b.tagName === "BUTTON" && b.textContent.trim() === "Cancel") b.textContent = "Close";
    });
  }

  // The result, per risk. A count alone would hide which three of thirty
  // were skipped, and "skipped" is the part that needs acting on.
  function renderBulkOutcome(res) {
    const rows    = res.rows || [];
    const applied = res.appliedCount   ?? rows.filter(r => r.outcome === "Applied").length;
    const skipped = res.skippedCount   ?? rows.filter(r => r.outcome === "Skipped").length;
    const same    = res.unchangedCount ?? rows.filter(r => r.outcome === "Unchanged").length;

    const msg = document.getElementById("brMessage");
    msg.style.color = skipped ? "#92400e" : "#166534";
    msg.textContent = skipped
      ? `${applied} applied, ${skipped} skipped${same ? `, ${same} unchanged` : ""}. `
        + `The skipped risks are listed below with the reason.`
      : `${applied} risk${applied === 1 ? "" : "s"} reviewed${same ? `, ${same} unchanged` : ""}.`;

    const line = r => {
      const chip = r.outcome === "Applied"
        ? `<span class="risk-status-chip risk-done">applied</span>`
        : r.outcome === "Skipped"
          ? `<span class="risk-status-chip risk-open">skipped</span>`
          : `<span class="pm-hint">unchanged</span>`;
      // The review-date move, shown as old -> new, matching the audit row
      // written against the risk so the screen and the trail agree.
      const dates = (r.fromReviewDate || r.toReviewDate) && r.fromReviewDate !== r.toReviewDate
        ? ` <span class="pm-hint">review ${r.fromReviewDate
              ? window.gracFormatDateOnly(r.fromReviewDate) : "none"} &rarr; ${
            r.toReviewDate ? window.gracFormatDateOnly(r.toReviewDate) : "none"}</span>`
        : "";
      const status = r.fromStatus && r.toStatus && r.fromStatus !== r.toStatus
        ? ` <span class="pm-hint">${escapeHtml(r.fromStatus)} &rarr; ${escapeHtml(r.toStatus)}</span>`
        : "";
      return `<li style="margin-bottom:3px;">${chip} <strong>${escapeHtml(r.riskNumber || "")}</strong>
                ${escapeHtml(r.riskTitle || "")}${status}${dates}
                ${r.reason ? `<div class="pm-hint" style="margin-left:2px;">${escapeHtml(r.reason)}</div>` : ""}
              </li>`;
    };

    // Skipped first: it is the part that needs doing something about.
    const ordered = rows.slice().sort((a, b) =>
      (a.outcome === "Skipped" ? 0 : 1) - (b.outcome === "Skipped" ? 0 : 1));

    document.getElementById("brOutcome").innerHTML =
      `<ul style="list-style:none; margin:0; padding:0; max-height:220px; overflow:auto;
                  border:1px solid #e2e8f0; border-radius:6px; padding:8px;">`
      + ordered.map(line).join("") + `</ul>`;
  }

  function overdueCell(r) {
    if (!r.isDue) {
      const days = -(r.daysOverdue || 0);
      return `<span class="pm-hint">in ${days} day${days === 1 ? "" : "s"}</span>`;
    }
    if ((r.daysOverdue || 0) === 0) return `<span class="risk-duetoday">due today</span>`;
    return `<span class="risk-overdue">${r.daysOverdue} day${r.daysOverdue === 1 ? "" : "s"} overdue</span>`;
  }

  function updateReviewBadge(n) {
    const badge = document.getElementById("reviewDueBadge");
    if (!badge) return;
    badge.textContent = String(n);
    badge.hidden = n <= 0;
  }

  // Counts only. Asks for one row and reads totalRows, so the badge does
  // not pay for a page of data nobody is going to look at.
  async function refreshReviewBadge() {
    if (!state.organizationId) { updateReviewBadge(0); return; }
    const res = await apiGet(`/review-due?organizationId=${state.organizationId}&pageSize=1`);
    updateReviewBadge(res?.totalRows || 0);
  }

  function fillReviewOwnerFilters() {
    ["revFilterOwner", "calFilterOwner", "accFilterOwner"].forEach(id => {
      const sel = document.getElementById(id);
      if (!sel) return;
      const keep = sel.value;
      sel.innerHTML = `<option value="">All owners</option>`;
      state.employees.forEach(e => {
        const o = document.createElement("option");
        o.value = e.employeeId;
        o.textContent = e.employeeName;
        sel.appendChild(o);
      });
      sel.value = keep;
    });
  }

  // ---- The review form ------------------------------------------------
  // The same three controls as Risk analysis, on purpose: the server
  // delegates to the same sp_risk_register_assess, so the form that
  // feeds it must ask for the same things.
  async function openReviewPage(riskId) {
    const risk = await apiGet(`/register/${riskId}`);
    if (!risk) { dlg.alert("Risk not found.", { type: "error" }); return; }
    if (!state.options) await loadOptions();
    state.activeRisk = risk;

    // Which tab Back and Cancel return to. Same line the analysis,
    // treatment and residual pages use, so a review opened from the
    // Review-due tab goes back there and one opened from the register
    // goes back to the register.
    analysisReturnTab = state.tab || "register";

    document.getElementById("rvRiskId").value = riskId;
    document.getElementById("rvMessage").textContent = "";

    // Split across the two step-1 panels. In the modal all seven pairs
    // sat in one dl; on a page "what the risk is" and "where it stands"
    // are two different questions and get a panel each.
    document.getElementById("rvMeta").innerHTML =
      dd("Risk", `${escapeHtml(risk.riskNumber)} — ${escapeHtml(risk.riskTitle)}`, true) +
      dd("Statement", risk.riskStatement);

    document.getElementById("rvStanding").innerHTML =
      dd("Current inherent", risk.inherentRatingCode ? severityChip(risk.inherentRatingCode) : "--", true) +
      dd("Current residual", risk.residualRatingCode
          ? severityChip(risk.residualRatingCode)
          : `<span class="pm-hint">not assessed</span>`, true) +
      dd("Treatment option", risk.treatmentOptionName) +
      dd("Review due", risk.nextReviewDate ? window.gracFormatDateOnly(risk.nextReviewDate) : "--") +
      dd("Last reviewed", risk.lastReviewedOn
          ? `${window.gracFormatDateOnly(risk.lastReviewedOn)} (${risk.reviewCount} so far)` : "never");

    const head = document.getElementById("rvHeadStatus");
    if (head) head.innerHTML = risk.riskNumber
      ? `<span class="pm-badge">${escapeHtml(risk.riskNumber)}</span>` : "";

    // Pre-filled with what stands today. A review starts from the current
    // picture and changes what has moved; an empty form would make the
    // reviewer retype an assessment they may not be revising.
    setVal("rvCategory",    risk.riskCategoryCode || "");
    setVal("rvLikelihood",  risk.likelihoodCode || "");
    setVal("rvImpact",      risk.impactCode || "");
    // rvConsequence and rvControls are gone with the Justification card.
    // Their VALUES are not: onReviewSubmit carries them forward from
    // state.activeRisk, because a review writes a new analysis version
    // and omitting them would blank the live assessment.
    setVal("rvRemarks",     "");
    setVal("rvNextReview",  "");
    setRadio("rvTreatment", "");
    // 299. The reviewer proposes a cadence; it travels to the Accept
    // screen with the date.
    //
    // Opens UNSET today: this page reads /register/{id}, and that payload
    // (RiskRegisterDetail) does not carry the frequency -- only
    // sp_risk_acceptance_get does, which is why the Accept modal can
    // preselect and this cannot. The resolve call is written anyway so
    // that adding the two columns to sp_risk_register_get is the only
    // change needed to light it up; until then it resolves to null and
    // the select simply opens empty.
    await loadReviewFrequencies();
    fillReviewFrequencySelect(
      "rvReviewFrequency",
      resolveReviewFrequencyId(risk.reviewFrequencyId, risk.reviewFrequencyName),
      "-- select --");
    renderRating("rv");
    renderReviewFlow();

    // showHeading:false like the other three. #rvScopePanel supplies its
    // own "Existing Controls" heading and prose, so the default (true)
    // rendered both -- two headings for one section.
    await riskMapping.mount("rvMapping", riskId, { readOnly: false, showHeading: false,
                                                   impactHostId: "rvImpactScope" });
    showReviewPage();
  }

  // The rail: what was decided last time, what is being entered now, and
  // where saving will land. Three steps and two arrows, which is exactly
  // what .risk-flow's five-track grid holds.
  //
  // Step 3 is the point of it. The treatment option decides where the
  // save goes, and stating that before the reviewer commits is the
  // difference between a routing rule and a surprise.
  function renderReviewFlow() {
    const host = document.getElementById("rvFlow");
    const risk = state.activeRisk;
    if (!host || !risk) return;

    const live    = resolveRating(val("rvLikelihood"), val("rvImpact"));
    const newCode = live ? live.ratingCode : risk.inherentRatingCode;
    const newSub  = live
      ? `${escapeHtml(optionName("likelihood", val("rvLikelihood")))}`
        + ` x ${escapeHtml(optionName("impact", val("rvImpact")))}`
        + (live.ratingScore != null ? ` — score ${live.ratingScore}` : "")
      : "Choose a likelihood and impact";

    const opt  = getRadio("rvTreatment") || "";
    const next = reviewNextStep(opt);

    host.innerHTML =
        step(1, "Last assessment",
             risk.inherentRatingCode ? severityChip(risk.inherentRatingCode) : "--",
             `${escapeHtml(risk.likelihoodName || "?")} x ${escapeHtml(risk.impactName || "?")}`)
      + arrow()
      + step(2, "This review",
             newCode ? severityChip(newCode) : `<span class="pm-hint">Pending</span>`,
             newSub, { current: true })
      + arrow()
      + step(3, "Next step", escapeHtml(next.label), next.sub);

    function step(n, label, value, sub, o) {
      o = o || {};
      return `<li class="risk-flow-step${o.current ? " is-current" : ""}">
        <div class="k"><span class="n">${n}</span>${escapeHtml(label)}</div>
        <div class="v">${value}</div>
        <div class="s">${sub}</div></li>`;
    }
    function arrow() { return `<li class="risk-flow-arrow" aria-hidden="true"></li>`; }
  }

  // Where a saved review lands, by treatment option. One rule, read by
  // both the rail above and onReviewSubmit below, so what the page
  // promises and what it does cannot drift apart.
  //
  // Tolerate goes to acceptance -- that was already true before this
  // page existed. The other three go to residual analysis, because for
  // them the next real step is the treatment work and the residual score
  // that follows it; sending them to acceptance would invite accepting a
  // risk whose residual has never been assessed. "No change" keeps
  // whatever decision already stands, so it routes on that.
  function reviewNextStep(optionCode) {
    const opt = optionCode || (state.activeRisk && state.activeRisk.treatmentOptionCode) || "";
    if (opt === "Tolerate")
      return { code: "accept", label: "Risk acceptance",
               sub: "Opens acceptance when this review is saved." };
    if (opt)
      return { code: "residual", label: "Residual analysis",
               sub: "Opens residual analysis when this review is saved." };
    return { code: "none", label: "Back to the register",
             sub: "No treatment decision recorded yet." };
  }

  async function onReviewSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("rvMessage");
    msg.textContent = "";
    const riskId = Number(document.getElementById("rvRiskId").value);
    if (!val("rvCategory"))   { msg.textContent = "Risk category is required."; return; }
    if (!val("rvLikelihood")) { msg.textContent = "Likelihood is required."; return; }
    if (!val("rvImpact"))     { msg.textContent = "Impact is required."; return; }

    const next = val("rvNextReview");
    if (next && new Date(next) <= new Date(isoDate(new Date()))) {
      msg.textContent = "A next review date must be in the future."; return;
    }

    const res = await apiPost(`/register/${riskId}/review`, {
      riskCategoryCode:     val("rvCategory"),
      likelihoodCode:       val("rvLikelihood"),
      impactCode:           val("rvImpact"),
      // CARRIED FORWARD, not collected. The Justification card that used
      // to ask for these is gone, but they must still be sent:
      // sp_risk_review_perform delegates to sp_risk_register_assess ->
      // sp_risk_analysis_save, which INSERTS a new analysis version from
      // the values it is handed and marks it is_current. Sending null
      // would blank potential_consequence and existing_controls on the
      // risk's live assessment -- a silent data loss on every review.
      //
      // state.activeRisk is the row this page was opened with, so these
      // are exactly what the risk already holds.
      potentialConsequence: (state.activeRisk && state.activeRisk.potentialConsequence) || null,
      existingControls:     (state.activeRisk && state.activeRisk.existingControls) || null,
      reviewRemarks:        val("rvRemarks") || null,
      treatmentOptionCode:  getRadio("rvTreatment") || null,
      nextReviewDate:       next || null,
      // 299. Proposed alongside the date; both are carried to the Accept
      // screen. Neither decides where the risk goes — the review moves it
      // to Monitoring, and that is what routes it.
      reviewFrequencyId:    val("rvReviewFrequency") ? Number(val("rvReviewFrequency")) : null
    });
    if (!res || res.success === false) { msg.textContent = (res && res.error) || "Failed."; return; }

    // Decided BEFORE the exit unmounts the form -- backFromFullPage()
    // clears the scope panel and hides the page, and getRadio would then
    // be reading a form that is no longer on screen.
    const nextStep = reviewNextStep(getRadio("rvTreatment"));

    // One exit path, the same one the residual page takes: unmount the
    // mapping panel, hide the page, restore the tab chrome and return to
    // the tab this was opened from. Replaces hide(modal) + a separate
    // riskMapping.clear, which backFromFullPage now does for us.
    backFromFullPage();

    await refreshRegister();
    if (state.tab === "review")   await refreshReviewDue();
    if (state.tab === "calendar") await refreshCalendar();
    refreshReviewBadge();

    // Straight on to the next step -- nobody has to find it by hand.
    // Acceptance for Tolerate, residual analysis for the other three;
    // reviewNextStep owns that rule and the rail above states it, so the
    // page cannot promise one destination and go to another.
    if (nextStep.code === "accept")   { await openAcceptancePage(riskId); return; }
    if (nextStep.code === "residual") { await openResidualPage(riskId);    return; }

    // No treatment decision to route on: report and stay on the register.
    dlg.alert(
      next
        ? `Reviewed. Next review ${window.gracFormatDateOnly(next)}.`
        : `Reviewed. This risk is back in the flow — it gets a new review date when it is next accepted.`,
      { title: "Review saved", type: "success" });
  }

  // ===================================================================
  // Risk Calendar  (migration 264)
  //
  // A month grid over next_review_date. Weeks start Monday, matching
  // practice-calendar.js.
  // ===================================================================
  let calMonth = startOfMonth(new Date());

  async function refreshCalendar() {
    const grid = document.getElementById("calGrid");
    const list = document.getElementById("calListBody");
    const title = document.getElementById("calTitle");
    if (!grid) return;

    title.textContent = calMonth.toLocaleDateString(undefined, { month: "long", year: "numeric" });

    if (!state.organizationId) {
      grid.innerHTML = "";
      list.innerHTML = `<tr><td colspan="7" class="pm-empty-row">Select an organization.</td></tr>`;
      document.getElementById("calSummary").textContent = "";
      return;
    }

    // The grid always shows whole weeks, so the fetch window is the
    // rendered range rather than the calendar month -- otherwise reviews
    // falling in the leading or trailing days would be silently absent
    // from cells that are on screen.
    const first = startOfMonth(calMonth);
    const gridStart = mondayBefore(first);
    const gridEnd   = addDays(gridStart, 41);          // 6 weeks

    const qs = new URLSearchParams({
      organizationId: state.organizationId,
      fromDate: isoDate(gridStart),
      toDate:   isoDate(gridEnd)
    });
    const owner = val("calFilterOwner");
    if (owner) qs.set("ownerEmployeeId", owner);

    const events = await apiGet(`/review-calendar?${qs}`) || [];

    // Bucket by date once. Re-scanning the array per cell is 42 passes
    // over the same data for no reason.
    const byDate = new Map();
    events.forEach(e => {
      const k = isoDate(e.eventDate);
      if (!byDate.has(k)) byDate.set(k, []);
      byDate.get(k).push(e);
    });

    const todayKey = isoDate(new Date());
    const thisMonth = first.getMonth();
    let html = "";
    for (let i = 0; i < 42; i++) {
      const d = addDays(gridStart, i);
      const k = isoDate(d);
      const evs = byDate.get(k) || [];
      const cls = ["risk-cal-cell"];
      if (d.getMonth() !== thisMonth) cls.push("is-outside");
      if (k === todayKey) cls.push("is-today");
      // Three events, then a count. A cell that grows without limit
      // breaks the grid's rhythm and the list below carries the rest.
      const shown = evs.slice(0, 3);
      html += `<div class="${cls.join(" ")}">
        <div class="d">${d.getDate()}</div>
        ${shown.map(e => `<button type="button" class="risk-cal-ev${e.isOverdue ? " is-overdue" : ""}"
             data-rating="${escapeHtml(e.effectiveRatingCode || "")}"
             data-open-risk="${e.riskRegisterId}"
             title="${escapeHtml(`${e.riskNumber} — ${e.riskTitle}`)}">${escapeHtml(e.riskTitle)}</button>`).join("")}
        ${evs.length > shown.length
          ? `<div class="risk-cal-more">+${evs.length - shown.length} more</div>` : ""}
      </div>`;
    }
    grid.innerHTML = html;

    const inMonth = events.filter(e => new Date(e.eventDate).getMonth() === thisMonth);
    const overdue = events.filter(e => e.isOverdue).length;
    document.getElementById("calSummary").textContent =
      `${inMonth.length} review${inMonth.length === 1 ? "" : "s"} this month`
      + (overdue ? ` · ${overdue} overdue in view` : "");

    list.innerHTML = inMonth.length
      ? inMonth.map(e => `<tr>
          <td>${window.gracFormatDateOnly(e.eventDate)}${
            e.isOverdue ? ` <span class="risk-overdue">overdue</span>`
                        : e.isToday ? ` <span class="risk-duetoday">today</span>` : ""}</td>
          <td><a href="#" data-open-risk="${e.riskRegisterId}">${escapeHtml(e.riskNumber)}</a></td>
          <td>${escapeHtml(e.riskTitle)}</td>
          <td>${e.effectiveRatingCode ? severityChip(e.effectiveRatingCode) : "--"}</td>
          <td>${escapeHtml(e.riskOwnerName || "--")}</td>
          <td>${escapeHtml(e.treatmentOptionName || "--")}</td>
          <td><button type="button" class="pm-button" data-review-risk="${e.riskRegisterId}">Review</button></td>
        </tr>`).join("")
      : `<tr><td colspan="7" class="pm-empty-row">No reviews scheduled this month.</td></tr>`;
  }

  // ---- small date helpers, local to this file -------------------------
  // isoDate is used both for <input type="date"> values and as the
  // calendar's bucket key, so it must be LOCAL date parts, not
  // toISOString() -- which converts to UTC and lands a review on the
  // wrong day for anyone east or west of it.
  function isoDate(d) {
    const x = (d instanceof Date) ? d : new Date(d);
    return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, "0")}-${String(x.getDate()).padStart(2, "0")}`;
  }
  function startOfMonth(d) { return new Date(d.getFullYear(), d.getMonth(), 1); }
  function addDays(d, n)   { const x = new Date(d); x.setDate(x.getDate() + n); return x; }
  function addMonths(d, n) { const x = new Date(d); x.setMonth(x.getMonth() + n); return x; }
  // Weeks start Monday. getDay() is 0 for Sunday, so Sunday goes back 6.
  function mondayBefore(d) {
    const x = new Date(d);
    const shift = (x.getDay() + 6) % 7;
    x.setDate(x.getDate() - shift);
    return x;
  }

  // ---- radio-group helpers -------------------------------------------
  function getRadio(name) {
    const el = document.querySelector(`input[name="${CSS.escape(name)}"]:checked`);
    return el ? el.value : "";
  }
  function setRadio(name, value) {
    document.querySelectorAll(`input[name="${CSS.escape(name)}"]`)
      .forEach(el => { el.checked = (el.value === (value || "")); });
  }

  function openRegApprovalModal(riskId) {
    const r = state.activeRisk && state.activeRisk.riskRegisterId === riskId ? state.activeRisk : null;
    document.getElementById("rgaRiskId").value = riskId;
    document.getElementById("rgaRemark").value = "";
    document.getElementById("rgaMessage").textContent = "";
    document.getElementById("rgaMeta").innerHTML = r
      ? dd("Risk", `${escapeHtml(r.riskNumber)} — ${escapeHtml(r.riskTitle)}`, true) +
        dd("Proposed rating", severityChip(r.inherentRatingCode), true) +
        dd("Category", r.riskCategoryNames || r.riskCategoryName) +
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
    await refreshRiskViewIfShowing(riskId);
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
    await refreshRiskViewIfShowing(riskId);
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
    await refreshRiskViewIfShowing(riskId);
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
      dd("Assessed",  `${window.gracFormatDisplayDate(analysis.analysisOn)} by ${escapeHtml(analysis.analysedByName || "—")}`, true);
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
          <td>${t.dueAt ? window.gracFormatDateOnly(t.dueAt) : "—"}</td>
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
    const qs = new URLSearchParams({
      organizationId: state.organizationId,
      ...pageParams(pagers.appr)
    });
    const data = await apiGet(`/approval-queue?${qs}`);
    const rows = data?.rows || [];
    pagers.appr?.setTotal(data?.totalRows, rows.length);
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
      <td>${window.gracFormatDateOnly(a.analysisOn)}<br>
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
          <td>${window.gracFormatDisplayDate(n.eventOn)}</td>
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
      dd("Record status", statusChip(risk.statusCode), true);
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
          <td>${w.dueAt ? window.gracFormatDateOnly(w.dueAt) : "—"}</td>
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
                ? `${window.gracFormatDisplayDate(c.identifiedOn)} by ${escapeHtml(c.requestedByName || "system")}`
                : null, true);
  }
  // Renders one <dt>/<dd> pair, or nothing when the value is empty —
  // so a candidate from a source with little context does not display a
  // wall of "--".
  //
  // THE WRAPPER IS LOAD-BEARING, not decoration. .pm-detail-grid is a
  // <dl> with display:grid, and a bare <dt>/<dd> are two SEPARATE grid
  // items -- so across three columns the browser placed them
  // dt,dd,dt / dd,dt,dd and every label ended up over somebody else's
  // value. Wrapping each pair makes the PAIR the grid item, which is
  // what the multi-column layout always assumed. HTML5 allows <div>
  // as a grouping child of <dl> for exactly this.
  // cls is an OPTIONAL extra class on the item -- "pm-detail-span" spans
  // the grid, for a value that is prose rather than a word. Fourth
  // parameter, so every existing three-argument call is untouched.
  function dd(label, value, isHtml, cls) {
    if (value == null || value === "") return "";
    return `<div class="pm-detail-item${cls ? " " + cls : ""}">`
         + `<dt>${escapeHtml(label)}</dt>`
         + `<dd>${isHtml ? value : escapeHtml(value)}</dd>`
         + `</div>`;
  }

  function val(id)          { const el = document.getElementById(id); return el ? String(el.value || "").trim() : ""; }
  function setVal(id, v)    { const el = document.getElementById(id); if (el) el.value = v ?? ""; }
  // textContent, not innerHTML: these carry risk titles and statements,
  // which are user input and must not be able to inject markup into the
  // page heading.
  function setText(id, v)   { const el = document.getElementById(id); if (el) el.textContent = v ?? ""; }
  function show(id) { document.getElementById(id).hidden = false; }
  function hide(id) { document.getElementById(id).hidden = true; }
  function escapeHtml(s) {
    if (s == null) return "";
    return String(s).replace(/[&<>"']/g, ch => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[ch]));
  }

  // Change request 2026-09-22: the Risk Candidates grid showed "Risk:
  // <gap title>" verbatim -- that prefix is baked into the STORED
  // candidate_title by sp_risk_candidate_create (COALESCE default of
  // "Risk: " + gap/source title when no explicit title is given; see
  // database/207_risk_centre_source_wiring.sql). Display-only strip for
  // the Candidates grid row (refresh() above); r.candidateTitle itself is
  // untouched, so every other reader of it -- the detail modal, the
  // analysis form, the dashboard ageing table -- still sees the real
  // stored value. Case-insensitive and whitespace-tolerant, same as the
  // matching fix on the Exception Centre grid.
  function displayCandidateTitle(title) {
    return String(title || "").replace(/^\s*Risk:\s*/i, "");
  }

  async function apiGet(path) {
    const url = U(`${base}${path.startsWith("/") || path.startsWith("?") ? path : "/" + path}`);
    try {
      const r = await fetch(url, { credentials: "same-origin" });
      if (r.status === 404) return null;
      // 204 is a legitimate "nothing yet" from the residual endpoint
      // (258) -- a risk that has not been residually assessed. Without
      // this guard r.json() throws on the empty body and the caller
      // still gets null, but via an error log that reads like a fault.
      if (r.status === 204) return null;
      if (!r.ok) { console.warn("risk GET", url, r.status); return null; }
      return await r.json();
    } catch (err) { console.error("risk GET failed", url, err); return null; }
  }

  // apiGet collapses every failure into null, and a caller that renders
  // null as "nothing matched" cannot tell an empty result from a broken
  // endpoint -- which is exactly how a 500 on the register reached the
  // operator as "No risks in the register match these filters."
  //
  // This variant keeps that distinction. Used by the list refreshers;
  // apiGet is left alone so its other call sites are unaffected.
  async function apiGetChecked(path) {
    const url = U(`${base}${path.startsWith("/") || path.startsWith("?") ? path : "/" + path}`);
    try {
      const r = await fetch(url, { credentials: "same-origin" });
      if (r.ok) return { ok: true, data: await r.json() };
      const body = await r.json().catch(() => ({}));
      return { ok: false, error: body.error || body.title || `HTTP ${r.status}` };
    } catch (err) {
      return { ok: false, error: err.message || "Network error" };
    }
  }
  // `method` was added for the unmap routes (262), which are DELETEs.
  // They go through this function rather than a separate apiDelete
  // because everything else about them is identical -- same base, same
  // credentials, same success-flag normalisation, same error shape --
  // and a second near-copy would be a second place to fix the day the
  // error contract changes.
  //
  // A null body sends no payload at all. JSON.stringify(null) is the
  // four characters "null", which a DELETE endpoint has no reason to
  // receive and some proxies object to.
  async function apiPost(path, body, method) {
    const url = U(`${base}${path.startsWith("/") ? path : "/" + path}`);
    try {
      const init = { method: method || "POST", credentials: "same-origin" };
      if (body !== null && body !== undefined) {
        init.headers = { "Content-Type": "application/json" };
        init.body = JSON.stringify(body);
      }
      const r = await fetch(url, init);
      const data = await r.json().catch(() => ({}));
      if (!r.ok) return { success: false, error: data.error || `HTTP ${r.status}` };
      // Array responses (duplicate-check) are returned as-is; object
      // responses get the success flag the callers expect.
      if (Array.isArray(data)) return data;
      return { success: data.success !== false, ...data };
    } catch (err) { return { success: false, error: err.message }; }
  }
})();
