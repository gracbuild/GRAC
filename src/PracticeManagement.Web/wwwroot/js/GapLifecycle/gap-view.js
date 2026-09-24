// =====================================================================
// Gap View  (migration 325)
// Loaded by Views/Practice/Partials/gap-view.cshtml.
//
// URL: /Practice/Index/gap-view?gapId=NNN[&orgId=...&title=...]
//
// WHAT THIS FILE DOES, AND WHAT IT DELIBERATELY DOES NOT
// --------------------------------------------------------------------
// Reads the gap header and its linked artefacts (both calls gap-detail.js
// already makes), then, for whichever of Task / Exception / Risk the gap
// actually owns, reads THAT artefact's own single-record endpoint --
// the exact same read its own Centre page uses to render its View/Detail
// surface -- for the summary a card needs (owner, due date, requested
// by, risk level, ...). No new business logic, no new stored procedure
// for any of that: the only database change in migration 325 is one
// extra column (IdentifiedDate) on the gap header itself.
//
// A card only opens a NEW TAB at a screen that already exists:
//   Task      -> task-view?taskId=<id>         (dedicated Task View full
//                page, added when Task's own "View" was converted from a
//                dialog to a full page -- see task-view.js)
//   Exception -> exception-view?exceptionId=<id> (dedicated Exception
//                View full page -- exception-analysis stays the Pending-
//                request analysis workflow, unchanged, and is linked
//                separately from that page's own "Open Analysis" button)
//   Risk      -> risk-centre#riskId=<id> once REGISTERED, else
//                risk-centre#candidateId=<id> (both 325's hash deep-links
//                -- a not-yet-registered candidate has no full PAGE, so it
//                opens its own read-only "View details" modal instead)
// =====================================================================
(() => {
  "use strict";

  const U        = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const gapBase   = "/practice/api/gap-lifecycle";
  const taskBase  = "/practice/api/tasks";
  const excBase   = "/practice/api/exception-centre";
  const riskBase  = "/practice/api/risk-centre";

  // Change request 2026-09-22: this used to be a standalone "Open
  // Analysis" button's href, set once in load(). It is now built on
  // demand for the "Analysis" item in the Actions menu instead -- same
  // URL, same target (gap-detail.cshtml), just no longer a fixed link
  // sitting in the page header.
  const analysisUrl = h =>
    U("/Practice/Index/gap-detail")
    + "?gapId=" + encodeURIComponent(state.gapId)
    + "&orgId=" + encodeURIComponent(state.orgId || (h && h.organizationId) || 0)
    + "&title=" + encodeURIComponent((h && h.title) || state.initialTitle || "");

  const state = {
    gapId: null,
    orgId: null,
    initialTitle: null,
    gapHeader: null,
    // Cache for fetchExistingTaskCount() -- null means "not fetched yet"
    // (distinct from 0, a genuine zero-tasks result), so the Actions
    // menu only makes that call once per page load.
    existingTaskCount: null
  };
  let actionsMenuEl = null;

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    const root = document.getElementById("gvRoot");
    if (!root) return;

    const params = new URLSearchParams(location.search);
    state.gapId = Number(params.get("gapId")) || 0;
    state.orgId = Number(params.get("orgId")) || 0;
    state.initialTitle = params.get("title") || "";

    if (!state.gapId) {
      unavailable("No gap was specified.", "Open this page from Gap Centre's Actions menu.");
      return;
    }

    document.getElementById("gvRefreshBtn").addEventListener("click", load);

    const actionsBtn = document.getElementById("gvActionsBtn");
    if (actionsBtn) actionsBtn.addEventListener("click", toggleActionsMenu);
    document.addEventListener("click", e => {
      if (!actionsMenuEl) return;
      if (e.target.closest(".pm-action-menu")) return;
      if (e.target.closest("#gvActionsBtn")) return;
      closeActionsMenu();
    });
    document.addEventListener("keydown", e => { if (e.key === "Escape") closeActionsMenu(); });
    window.addEventListener("resize", closeActionsMenu);
    window.addEventListener("scroll", closeActionsMenu, true);

    await load();
  }

  function unavailable(title, body) {
    const box = document.getElementById("gvUnavailable");
    if (!box) return;
    box.hidden = false;
    document.getElementById("gvUnavailableTitle").textContent = title;
    document.getElementById("gvUnavailableBody").textContent  = body;
  }

  async function load() {
    const header = await apiGet(gapBase, `/gaps/${state.gapId}/header`);
    if (!header) {
      unavailable("Could not load this gap.", `Gap #${state.gapId} was not found.`);
      return;
    }
    state.gapHeader = header;

    document.getElementById("gvUnavailable").hidden = true;
    document.getElementById("gvRoot").hidden = false;

    renderHeader(header);
    renderFacts(header);
    renderInstanceLink(header);

    const artefacts = await apiGet(gapBase, `/gaps/${state.gapId}/linked-artefacts`);
    renderObligations(artefacts && artefacts.failedObligations);
    await renderCards(artefacts);
  }

  function renderHeader(h) {
    document.getElementById("gvHeading").textContent = h.title || `Gap #${state.gapId}`;
    document.getElementById("gvGapTitle").textContent = h.title || "";
    // 379: sp_custom_gap_close only ever sets custom_gap.status -- it
    // never moves lifecycle_state_id (174/175 retired that state-machine
    // path down to New/Delegated for Custom gaps; see this fix's own
    // migration header). So a Closed gap still carries whatever
    // lifecycleStateName it had before closing (almost always
    // "Analysed"), and that must not outrank the record's own Closed
    // status here, same one-line fix as sp_gap_centre_list's StatusText.
    const isClosed  = h.statusCode === "Closed";
    const stateCode = (isClosed ? "Closed" : (h.lifecycleStateCode || h.statusCode || "")).toLowerCase();
    const chip = document.getElementById("gvStatusChip");
    chip.textContent = isClosed ? "Closed" : (h.lifecycleStateName || h.statusCode || "-");
    chip.className = "pm-badge gap-state-chip" + (stateCode ? ` state-${stateCode}` : "");
  }

  // dd() drops an empty fact rather than showing a bare "--" for every
  // field a Custom/manually-raised gap simply has nothing to say about
  // (Detection Method, SLA, Practice Instance...); a page of dashes for
  // those is noise, not information.
  function dd(label, value) {
    if (value === null || value === undefined || String(value).trim() === "") return "";
    return `<div><dt>${escapeHtml(label)}</dt><dd>${escapeHtml(value)}</dd></div>`;
  }

  function renderFacts(h) {
    const sla = h.slaMasterName
      ? `${h.slaMasterName}${h.slaDaysEffective != null ? ` (${h.slaDaysEffective} days)` : ""}`
      : "";
    const facts = [
      dd("Gap Reference",    `GAP-${h.customGapId}`),
      dd("Description",      h.description),
      dd("Source / Origin",  h.sourceModuleCode),
      dd("Detection Method", h.detectionMethodName || h.detectionMethodCode),
      dd("Practice / Practice Instance",
         h.practiceInstanceName ? `${h.practiceInstanceName}${h.practiceInstanceCode ? ` (${h.practiceInstanceCode})` : ""}` : ""),
      // 379: same precedence bug as the status chip above -- a Closed
      // gap must not have its lifecycle label (almost always "Analysed")
      // outrank its own Closed status in this facts panel either.
      dd("Gap Status",       h.statusCode === "Closed" ? "Closed" : (h.lifecycleStateName || h.statusCode)),
      dd("Priority",         h.priority),
      dd("Severity",         h.severityName || h.severityCode),
      dd("Owner",            h.ownerName),
      dd("Due Date",         fmtDate(h.dueDate)),
      dd("Identified Date",  fmtDate(h.identifiedDate)),
      dd("SLA",              sla),
      dd("Duplicate Of",     h.duplicateOfGapId ? `${h.duplicateOfGapTitle || ""} (GAP-${h.duplicateOfGapId})` : ""),
      dd("Invalid Reason",   h.invalidReason)
    ].join("");
    document.getElementById("gvFacts").innerHTML = facts
      || `<div><dd class="gv-empty">No further details recorded.</dd></div>`;
    renderGvMappedPractices();
  }

  // Migration 382: read-only list of practices mapped to this Custom Gap.
  async function renderGvMappedPractices() {
    const el = document.getElementById("gvFacts");
    if (!el) return;
    let rows = [];
    try {
      const r = await fetch(
        U(`/practice/api/gaps/custom/${state.gapId}/practices?organizationId=${encodeURIComponent(state.orgId || 0)}`),
        { credentials: "same-origin" });
      if (r.ok) { const b = await r.json(); rows = (b && (b.data || b.Data)) || []; }
    } catch (_) { return; }
    const names = rows.map(x => escapeHtml(x.practiceName || x.PracticeName || ("Practice #" + (x.practiceId || x.PracticeId))));
    el.insertAdjacentHTML("beforeend",
      `<div><dt>Mapped Practices</dt><dd>${names.length ? names.join(", ") : "None"}</dd></div>`);
  }

  // Same destination gap-detail.cshtml's own "View Practice Instance"
  // link and gaps.cshtml's row menu already use -- Framework / Source
  // Statement / Control live on that page already; this links to them
  // rather than re-deriving the same joins a second time here.
  function renderInstanceLink(h) {
    const wrap = document.getElementById("gvInstanceLinkWrap");
    const link = document.getElementById("gvInstanceLink");
    const text = document.getElementById("gvInstanceLinkText");
    if (!wrap || !link) return;
    const instanceId = h.practiceInstanceId;
    if (!instanceId) { wrap.hidden = true; return; }
    text.textContent = `View Practice Instance${h.practiceInstanceName ? ` (${h.practiceInstanceName})` : ""} — Framework, Control Statement, Control, Implementation Status`;
    link.href = window.location.origin
      + U("/Practice/Index/resolve-workspace")
      + "?instanceId=" + encodeURIComponent(instanceId)
      + "&organizationId=" + encodeURIComponent(state.orgId || h.organizationId || 0)
      + "&mode=view";
    wrap.hidden = false;
  }

  function renderObligations(list) {
    const strip = document.getElementById("gvObligationsStrip");
    const chips = document.getElementById("gvObligationsChips");
    if (!strip || !chips) return;
    if (!list || !list.length) { strip.hidden = true; chips.innerHTML = ""; return; }
    strip.hidden = false;
    chips.innerHTML = list.map(o => `
      <div class="gv-chip">
        <span class="chip-type">${escapeHtml(o.obligationTypeCode || "Obligation")}</span>
        <span class="chip-title">${escapeHtml(o.obligationName || "(unnamed obligation)")}</span>
        <span class="chip-status">${escapeHtml(o.loggedStatusCode || "")}</span>
      </div>`).join("");
  }

  // ---- Related Actions cards -----------------------------------------
  // artefacts is GapLinkedArtefactsResult: { task, exception, risk,
  // failedObligations }. Each of task/exception/risk is null or the
  // ONE row sp_custom_gap_linked_artefacts returns for this gap -- so
  // "only the artefact actually associated with the current gap" holds
  // by construction; there is nothing here to accidentally over-fetch.
  async function renderCards(artefacts) {
    const wrap  = document.getElementById("gvCards");
    const empty = document.getElementById("gvRelatedEmpty");
    const cards = [];

    if (artefacts && artefacts.task)      cards.push(await buildTaskCard(artefacts.task));
    if (artefacts && artefacts.exception) cards.push(await buildExceptionCard(artefacts.exception));
    if (artefacts && artefacts.risk)      cards.push(await buildRiskCard(artefacts.risk));

    wrap.innerHTML = cards.join("");
    empty.hidden = cards.length > 0;

    // role="button" cards need their own keyboard activation -- unlike a
    // plain <a>, a <div> gets none for free.
    const openCard = el => window.open(el.getAttribute("data-open-href"), "_blank", "noopener");
    wrap.querySelectorAll("[data-open-href]").forEach(el => {
      el.addEventListener("click", () => openCard(el));
      el.addEventListener("keydown", ev => {
        if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); openCard(el); }
      });
    });
  }

  function cardShell(kind, typeLabel, refText, title, statusText, metaRows, openHref, note) {
    const clickable = !!openHref;
    const attrs = clickable
      ? `class="gv-card type-${kind} is-clickable" data-open-href="${escapeHtml(openHref)}" role="button" tabindex="0"`
      : `class="gv-card type-${kind}"`;
    return `
      <div ${attrs}>
        <div class="gv-card-head">
          <span class="gv-card-type">${escapeHtml(typeLabel)}${refText ? ` #${escapeHtml(refText)}` : ""}</span>
          ${clickable ? `<span class="gv-card-open-hint">Open</span>` : ""}
        </div>
        <div class="gv-card-title">${escapeHtml(title || "(untitled)")}</div>
        ${statusText ? `<span class="gv-card-status">${escapeHtml(statusText)}</span>` : ""}
        ${metaRows ? `<dl class="gv-card-meta">${metaRows}</dl>` : ""}
        ${note ? `<span class="gv-card-note">${escapeHtml(note)}</span>` : ""}
      </div>`;
  }
  function metaRow(label, value) {
    if (value === null || value === undefined || String(value).trim() === "") return "";
    return `<dt>${escapeHtml(label)}</dt><dd>${escapeHtml(value)}</dd>`;
  }

  async function buildTaskCard(row) {
    const detail = await apiGet(taskBase, `/${row.artefactId}`);
    const h = (detail && detail.header) || {};
    const due = h.approvedExtendedDueAt || h.standardDueAt;
    const owner = h.assignedToEmployeeName || (h.assignedToEmployeeId ? `Employee #${h.assignedToEmployeeId}` : "Unassigned");
    const meta = metaRow("Assigned To", owner) + metaRow("Due Date", fmtDate(due));
    // Task Card -> Task View full page (new tab), not the old #taskId=
    // dialog deep-link -- Task's own "View" now opens the same page.
    const openHref = U("/Practice/Index/task-view") + "?taskId=" + encodeURIComponent(row.artefactId);
    return cardShell("task", "Task", h.taskNumber || row.artefactId,
      h.subjectTitle || row.title, h.currentStatusName || row.statusCode, meta, openHref, null);
  }

  async function buildExceptionCard(row) {
    const res = await apiGet(excBase, `/${row.artefactId}`);
    const d = (res && res.data) || res || {};
    const meta = metaRow("Requested By", d.requestedByName) + metaRow("Request Date", fmtDate(d.requestedOn));
    // Exception Card -> Exception View full page (new tab): a genuine
    // read-only view in any status, unlike exception-analysis (the
    // Pending-only analysis workflow, whose own row-menu link disables
    // itself once a request leaves Pending/SubmittedForApproval).
    const openHref = U("/Practice/Index/exception-view") + "?exceptionId=" + encodeURIComponent(row.artefactId);
    return cardShell("exception", "Exception", row.artefactId,
      d.requestTitle || row.title, d.statusCode || row.statusCode, meta, openHref, null);
  }

  async function buildRiskCard(row) {
    // row.artefactId is the risk CANDIDATE id (sp_custom_gap_linked_artefacts
    // sources Risk from risk_candidate, not risk_register -- see 174/207).
    // A candidate only has a full view once it has been REGISTERED
    // (risk_candidate.registered_risk_id / RegisteredRiskId), which is
    // also when it gets the risk_register_id the read-only full page
    // (risk-centre.js openRiskDetailPage) actually opens by.
    const candidate = await apiGet(riskBase, `/${row.artefactId}`);
    const c = candidate || {};
    const registeredId = c.registeredRiskId;

    if (!registeredId) {
      // No risk_register_id yet -- risk_candidate_id has no full PAGE of
      // its own (openRiskDetailPage opens a REGISTERED risk by
      // risk_register_id; a candidate isn't one yet), but it does have a
      // genuine read-only full-detail VIEW: the same "View details" modal
      // (openDetailModal, risk-centre.js) the candidate row menu's own eye
      // icon opens, showing title, meta, and every retained assessment
      // version. #candidateId= deep-links straight into that modal instead
      // of landing on the bare Candidates list -- reusing it rather than
      // building a second candidate-detail surface.
      const meta = metaRow("Requested By", c.requestedByName) + metaRow("Identified On", fmtDate(c.identifiedOn || c.requestedOn));
      const openHref = U("/Practice/Index/risk-centre") + "#candidateId=" + encodeURIComponent(row.artefactId);
      return cardShell("risk", "Risk Candidate", c.candidateNumber || row.artefactId,
        c.candidateTitle || row.title, c.statusCode || row.statusCode, meta, openHref,
        "Not yet registered in the Risk Register -- opens its assessment details.");
    }

    const reg = await apiGet(riskBase, `/register/${registeredId}`);
    const r = reg || {};
    const meta = metaRow("Risk Owner", r.riskOwnerName)
               + metaRow("Inherent", r.inherentRatingCode)
               + metaRow("Residual", r.residualRatingCode || (r.residualPending === false ? null : "Not assessed"));
    const openHref = U("/Practice/Index/risk-centre") + "#riskId=" + encodeURIComponent(registeredId);
    return cardShell("risk", "Risk", r.riskNumber || registeredId,
      r.riskTitle || c.candidateTitle || row.title,
      r.statusCode === "Retired" ? "Retired" : (r.workflowStageCode || r.statusCode || c.statusCode),
      meta, openHref, null);
  }

  // ---- shared helpers --------------------------------------------------
  async function apiGet(base, path) {
    try {
      const r = await fetch(U(base + path), { credentials: "same-origin" });
      if (r.status === 404) return null;
      if (r.status === 204) return null;
      if (!r.ok) return null;
      return await r.json();
    } catch (_) {
      return null;
    }
  }

  function fmtDate(v) {
    if (!v) return "";
    if (typeof window.gracFormatDateOnly === "function") { var _g = window.gracFormatDateOnly(v); if (_g && _g !== v) return _g; }
    const d = new Date(v);
    return isNaN(d.getTime()) ? String(v).slice(0, 10) : d.toLocaleDateString();
  }

  function escapeHtml(v) {
    if (v === null || v === undefined) return "";
    return String(v).replace(/[&<>"']/g, c =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  // ===================================================================
  // Actions menu -- one button, not a per-row trigger, so the popover
  // logic here is a smaller cousin of Gap Centre's own openRowMenu/
  // closeRowMenu/positionRowMenu (gaps.cshtml), and a near-copy of Task
  // View's own version of the same thing (task-view.js). It renders with
  // the SAME .pm-action-menu / .pm-button CSS those already use
  // (wwwroot/css/practice-management.css), so the popover looks like
  // every other action menu in the product; only the item LIST comes
  // from the shared window.gracGapActions.buildMenu() (see the header
  // comment at the top of Shared/gap-actions.js for why that matters).
  // ===================================================================
  function closeActionsMenu() {
    if (actionsMenuEl) { actionsMenuEl.remove(); actionsMenuEl = null; }
    const btn = document.getElementById("gvActionsBtn");
    if (btn) btn.setAttribute("aria-expanded", "false");
  }

  function positionActionsMenu(trigger) {
    if (!actionsMenuEl) return;
    const r = trigger.getBoundingClientRect();
    const mr = actionsMenuEl.getBoundingClientRect();
    const gap = 6;
    let top = r.bottom + gap, left = r.left;
    if (top + mr.height > window.innerHeight - 8) top = Math.max(8, r.top - mr.height - gap);
    if (left + mr.width > window.innerWidth - 8) left = window.innerWidth - mr.width - 8;
    if (left < 8) left = 8;
    actionsMenuEl.style.top = top + "px";
    actionsMenuEl.style.left = left + "px";
  }

  function toggleActionsMenu() {
    if (actionsMenuEl) { closeActionsMenu(); return; }
    openActionsMenu();
  }

  function renderActionsMenuItems(items) {
    if (!actionsMenuEl) return;
    actionsMenuEl.innerHTML = "";
    const shown = items.filter(it => it && it.applicable !== false);

    if (!shown.length) {
      const p = document.createElement("div");
      p.style.cssText = "padding:8px 12px; font-size:12px; color:#94a3b8; white-space:nowrap;";
      p.textContent = "No actions available";
      actionsMenuEl.appendChild(p);
    }

    shown.forEach(it => {
      const b = document.createElement("button");
      b.type = "button";
      b.setAttribute("role", "menuitem");
      b.innerHTML = `<i class="fa-solid ${escapeHtml(it.icon)}" aria-hidden="true"></i> ${escapeHtml(it.label)}`;
      if (it.disabled) {
        b.disabled = true;
        b.title = it.disabledReason || "";
      }
      b.addEventListener("click", e => {
        e.preventDefault();
        e.stopPropagation();
        closeActionsMenu();
        try { it.action(); } catch (err) { console.error("[gap-view] action failed", err); }
      });
      actionsMenuEl.appendChild(b);
    });
  }

  // The task count that gates "View Existing Tasks" the same way
  // gaps.cshtml's own row (row.existingTaskCount, already on the grid
  // row it built its menu from) does -- Gap View has no grid row to read
  // that off, so it asks the exact same search Task Centre's own search
  // box calls (GET /practice/api/tasks?search=...) for just the count,
  // via pageSize=1. No new endpoint, no new business rule -- the same
  // list Gap Centre's "View Existing Tasks" link already opens, read
  // once to decide whether the item is worth showing. Cached on state so
  // opening the menu twice in a row does not refetch.
  async function fetchExistingTaskCount(h) {
    if (state.existingTaskCount != null) return state.existingTaskCount;
    const code = h.practiceInstanceCode || "";
    const name = h.practiceInstanceName || "";
    const term = code || name;
    if (!term) { state.existingTaskCount = 0; return 0; }
    const orgId = state.orgId || h.organizationId || 0;
    const payload = await apiGet(taskBase, `?organizationId=${encodeURIComponent(orgId)}`
      + `&page=1&pageSize=1&search=${encodeURIComponent(term)}`);
    state.existingTaskCount = (payload && Number(payload.totalCount)) || 0;
    return state.existingTaskCount;
  }

  async function openActionsMenu() {
    const btn = document.getElementById("gvActionsBtn");
    const h = state.gapHeader;
    if (!btn || !h) return;
    if (!window.gracGapActions) {
      console.error("[gap-view] Shared/gap-actions.js did not load -- Actions menu unavailable.");
      return;
    }

    actionsMenuEl = document.createElement("div");
    actionsMenuEl.className = "pm-action-menu";
    actionsMenuEl.setAttribute("role", "menu");
    const loading = document.createElement("div");
    loading.style.cssText = "padding:8px 12px; font-size:12px; color:#94a3b8; white-space:nowrap;";
    loading.textContent = "Loading…";
    actionsMenuEl.appendChild(loading);
    document.body.appendChild(actionsMenuEl);
    btn.setAttribute("aria-expanded", "true");
    positionActionsMenu(btn);

    const code = h.practiceInstanceCode || "";
    const name = h.practiceInstanceName || "";
    const nOpen = h.practiceInstanceId ? await fetchExistingTaskCount(h) : 0;
    if (!actionsMenuEl) return; // closed while the count was loading

    // Same fields Gap Centre's own buildRowMenu() reads off its grid
    // row (row.sourceModuleCode, row.rawStatusCode, ...) -- here read
    // straight off the header this page already fetched, so
    // applicability/permission gating is byte-for-byte the same rule,
    // just a different source for the same values. Gap View is only
    // ever reached for a materialized gap (it is opened BY gapId), so
    // isMaterialized is always true here -- the un-materialized branch
    // in buildMenu() can never apply on this page.
    const isAnalysed = (h.lifecycleStateCode || "") === "Delegated";
    const fields = {
      gapId: state.gapId, isMaterialized: true, isAnalysed: isAnalysed,
      sourceModuleCode: h.sourceModuleCode || "", statusCode: h.statusCode || "",
      practiceInstanceId: h.practiceInstanceId || null, existingTaskCount: nOpen
    };

    // No onAnalysis, no onView passed to buildMenu(): this page already
    // IS the read-only view Gap Centre's "View" item would navigate to,
    // and buildMenu()'s own Analysis/View pair (Analysis pre-analysis,
    // View once analysed) is the wrong shape for Gap View -- "View" has
    // no meaning here, and the shared gate would hide "Analysis" the
    // moment the gap is analysed. buildMenu() only includes an item
    // whose handler is supplied, so neither is offered from it.
    const items = window.gracGapActions.buildMenu(fields, {
      onViewExistingTasks: () => {
        // Bug fix (2026-09-22): this was a bare "/Practice/Index/tasks..."
        // href -- an absolute path that ignores the app's PathBase when
        // published under a virtual directory (same class of bug as
        // exception-analysis.cshtml's "Back to Exception Centre" link,
        // fixed the same day). Every other navigation in this file already
        // goes through U() (see analysisUrl above, renderInstanceLink);
        // this was the one spot that didn't.
        window.location.href = U("/Practice/Index/tasks") + "#search=" + encodeURIComponent(code || name || "");
      },
      onCloseGap: () => {
        window.gracGapActions.closeGap(state.gapId, "Closed from Gap View Actions menu.", load);
      }
    });

    // "Analysis" -- change request 2026-09-22: replaces the standalone
    // "Open Analysis" button that used to sit in the page header. Added
    // here directly rather than through buildMenu(), and unconditionally
    // (not gated on isAnalysed), for the same reason that button was
    // unconditional: an already-analysed gap still needs a way back into
    // gap-detail.cshtml. Placed first, the position the button held.
    items.unshift({
      icon: "fa-magnifying-glass", label: "Analysis",
      action: () => { window.location.href = analysisUrl(h); }
    });

    renderActionsMenuItems(items);
    positionActionsMenu(btn);
  }
})();
