// =====================================================================
// Gap Detail (Gap Centre v2 -- simplified lifecycle, migration 174)
// Loaded by Views/Practice/Partials/gap-detail.cshtml.
//
// URL: /Practice/Index/gap-detail?gapId=NNN[&title=...]
//
// SIMPLIFIED MODEL (sir-approved, migration 174):
//   States:      New -> Validation -> Analysis -> Delegated
//                                   -> Invalid (terminal)
//                                   -> Duplicate (terminal)
//   Auto-transitions:
//     Save Analysis -> lifecycle proc auto-moves gap to Delegated and
//     spawns Task (remediation='Y') / Exception ('N') / Risk ('Y'), each
//     idempotent per gap. Old ResolutionPlanning/Execution/Verification
//     transitions were deactivated -- the transitions endpoint won't
//     return them.
//
// UI:
//   * Single column (no left pane, no Downstream tab).
//   * Top toolbar: back, state chip, compact stepper pills, refresh.
//   * Action strip: whatever transitions the current state allows, minus
//     MarkInvalid -- hidden from this UI on request (321 follow-up) even
//     though the transition itself is unchanged server-side; typically
//     just Mark Duplicate remains. Delegate is auto (never shown).
//   * Analysis tab: "View Practice Instance" link (321, when the gap has
//     one) + Failed Obligation(s) strip (migration 317, automatic gaps
//     only) + form + linked-artefacts chip strip (both populated from
//     /gaps/{id}/linked-artefacts after save).
//   * Metadata & History tab: metadata dl + compact history list.
// =====================================================================
(() => {
  "use strict";

  const U    = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const base = "/practice/api/gap-lifecycle";

  const state = {
    gapId: null,
    orgId: null,
    initialTitle: null,
    currentStateCode: "New",
    states: [],
    actions: [],
    gapHeader: null,
    // Migration 321. Set once the header names a linked Practice
    // Instance -- drives the "View Practice Instance" link's href and
    // visibility (renderPracticeInstanceLink()).
    instanceLinkUrl: null,
    // Migration 367 (broadened set), narrowed by 372 (blocking
    // criterion). Captured by renderFailedObligations() from the same
    // /linked-artefacts response the Failed Obligation(s) strip already
    // renders from -- the obligations currently displayed under this
    // gap that are not yet Implemented (Not Implemented, Partially
    // Implemented, Not Set). unassessedObligations() below filters this
    // down to only the Not Set / Not Started ones, which is what
    // isBlockedByUnresolvedObligations() actually gates on -- the strip
    // itself keeps showing all of them, unchanged.
    failedObligations: []
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("gapDetailRoot")) return;
    const params = new URLSearchParams(location.search);
    state.gapId = Number(params.get("gapId")) || 0;
    state.orgId = Number(params.get("orgId")) || 0;
    state.initialTitle = params.get("title") || "";
    state.currentStateCode = params.get("state") || "New";

    if (!state.gapId) {
      document.getElementById("gapDetailTitle").textContent = "Gap not selected";
      document.getElementById("gapDetailSubtitle").textContent = "Open a gap from Gap Centre to see its lifecycle.";
      return;
    }

    document.getElementById("gapDetailRoot").hidden = false;
    bindEvents();

    // Boot-time lock for the Severity dropdown -- Razor / plugins
    // sometimes strip the HTML `disabled` attribute, and this fires
    // Wire the RCA checkbox so the RCA block appears / disappears the
    // moment the analyst ticks it. Also runs once on load via
    // applyAnalysisToForm's own call to toggleRcaBlockVisibility -- so
    // an analysis that has RCA already recorded opens with the block
    // visible without a click. Guarded because the field may not exist
    // yet in some page states (e.g. read-only header-only view).
    const anRcaBoot = document.getElementById("anRcaRequired");
    if (anRcaBoot) {
        anRcaBoot.addEventListener("change", toggleRcaBlockVisibility);
    }

    // BEFORE any analysis load so it takes effect immediately.
    const anSevBoot = document.getElementById("anSeverityCode");
    if (anSevBoot) {
      anSevBoot.disabled = true;
      anSevBoot.setAttribute("aria-disabled", "true");
      // Kill any change events just in case the disabled attribute is
      // stripped after this by an unrelated script; nothing wants a
      // silent severity mutation.
      anSevBoot.addEventListener("mousedown", ev => { ev.preventDefault(); ev.stopPropagation(); });
      anSevBoot.addEventListener("keydown",   ev => { ev.preventDefault(); ev.stopPropagation(); });
      anSevBoot.addEventListener("change",    ev => {
        // If somehow the value did change, snap it back to the
        // gap-header severity so we never persist the drift.
        const hSev = (state.gapHeader && state.gapHeader.severityCode) || "";
        if (anSevBoot.value !== hSev) anSevBoot.value = hSev;
        ev.preventDefault(); ev.stopPropagation();
      });
    }

    // Bootstrap: derive orgId, title, current state SERVER-SIDE from
    // the gap itself. URL params are only used as an initial hint.
    const header = await apiGet(`/gaps/${state.gapId}/header`);
    if (header) {
      state.orgId              = header.organizationId || state.orgId;
      state.initialTitle       = header.title || state.initialTitle;
      state.currentStateCode   = header.lifecycleStateCode || state.currentStateCode || "New";
      state.gapHeader          = header;
    } else {
      document.getElementById("gapDetailTitle").textContent = `Gap #${state.gapId} -- could not load`;
      return;
    }

    document.getElementById("gapDetailTitle").textContent =
      `Gap #${state.gapId} -- ${state.initialTitle || ""}`;
    document.getElementById("gapDetailSubtitle").textContent =
      `Organization ${state.orgId}. Validate, analyse, delegate.`;

    // Migration 325. Read-only companion page -- full gap details plus
    // Task/Exception/Risk cards, independent of analysis stage.
    const gapViewLink = document.getElementById("gapOpenViewLink");
    if (gapViewLink) {
      gapViewLink.href = U("/Practice/Index/gap-view")
        + "?gapId=" + encodeURIComponent(state.gapId)
        + "&orgId=" + encodeURIComponent(state.orgId || 0);
      gapViewLink.hidden = false;
    }

    renderMetadata();
    renderPracticeInstanceLink();  // migration 321
    renderSlaCard();       // migration 184

    state.states = (await apiGet("/states")) || [];
    renderCompactStepper();

    await refreshActions();
    await refreshAnalysis();
    await refreshLinkedArtefacts();
    await refreshHistory();

    applyTerminalInvalidMode();
    await refreshDuplicateCard();
    refreshInvalidCard();
  }

  // -------------------- events --------------------
  function bindEvents() {
    document.getElementById("gapDetailRefresh").addEventListener("click", async () => {
      const fresh = await apiGet(`/gaps/${state.gapId}/header`);
      if (fresh) {
        state.gapHeader = fresh;
        state.currentStateCode = fresh.lifecycleStateCode || state.currentStateCode;
      }
      renderCompactStepper();
      renderSlaCard();
      renderPracticeInstanceLink();  // migration 321
      await refreshActions();
      await refreshAnalysis();
      await refreshLinkedArtefacts();
      await refreshHistory();
      applyTerminalInvalidMode();
      await refreshDuplicateCard();
      refreshInvalidCard();
    });

    // Tabs (Analysis, Metadata & History)
    document.querySelectorAll(".pm-tabs [role=tab]").forEach(btn => {
      btn.addEventListener("click", ev => {
        const tab = ev.currentTarget.dataset.tab;
        document.querySelectorAll(".pm-tabs [role=tab]").forEach(b => {
          const on = b.dataset.tab === tab;
          b.classList.toggle("active", on);
          b.setAttribute("aria-selected", on ? "true" : "false");
        });
        document.querySelectorAll(".pm-tab-panel").forEach(p => {
          p.hidden = p.dataset.panel !== tab;
        });
      });
    });

    document.getElementById("gapAnalysisForm").addEventListener("submit", onAnalysisSubmit);
    document.getElementById("gapActionForm").addEventListener("submit", onActionConfirmSubmit);
    document.querySelectorAll("[data-close-gap-action]").forEach(el =>
      el.addEventListener("click", () => hide("gapActionModal")));
  }

  // -------------------- stepper --------------------
  // Display label mapping: state_code -> user-facing label. Backend
  // keeps `Delegated` as the code (migration 175 renamed the display
  // name in the master; we mirror the same rename here for consistency
  // in case the header cache is stale).
  const STATE_LABEL = {
    "New":                "New",
    "Validation":         "Validation",
    "Analysis":           "Analysis",
    "Delegated":          "Analysed",
    "Invalid":            "Invalid",
    "Duplicate":          "Duplicate",
    "ResolutionPlanning": "Planning",
    "Execution":          "Execution",
    "Verification":       "Verification",
    "Closed":             "Closed"
  };

  // Compact 2-pill stepper: New -> Analysed (happy path) OR
  // New -> Invalid / Duplicate (terminal-invalid). Intermediate states
  // Validation and Analysis are transient (analyst passes through them
  // on save); showing them as separate steps was noise. Dormant states
  // (Planning / Execution / Verification / Closed) appear ONLY when the
  // current gap is historically stuck in one of them.
  function renderCompactStepper() {
    const container = document.getElementById("gapStepperCompact");
    if (!container) return;
    const dormant = ["ResolutionPlanning", "Execution", "Verification", "Closed"];
    const terminalInvalid = ["Invalid", "Duplicate"];
    // 379: state.currentStateCode is only ever set from
    // header.lifecycleStateCode, which sp_custom_gap_close never touches
    // -- so a Closed gap keeps showing whatever step it was on before
    // closing (almost always Delegated/"Analysed") unless the stepper
    // itself checks the record's own status first. This reads only the
    // local `current` used to pick the highlighted step below -- it does
    // NOT reassign state.currentStateCode, which isAlreadyAnalysed(),
    // the terminal-invalid checks and the actions fetch all still rely
    // on for its real (lifecycle) meaning, unchanged.
    const current = (state.gapHeader && state.gapHeader.statusCode === "Closed")
        ? "Closed"
        : state.currentStateCode;

    let path;
    if (terminalInvalid.includes(current))       path = ["New", current];
    // 379: Closed needs its own branch, checked before the generic
    // dormant one below (Closed is also listed in `dormant`, but that
    // branch's ["New", current, "Delegated"] shape would place Closed
    // BEFORE Delegated -- backwards for the one path that can actually
    // happen today, New -> Delegated -> Closed. lifecycleStateCode still
    // holds whatever stage the gap reached before it was closed (Close
    // Gap never moves it), so it tells us whether Delegated came first.
    else if (current === "Closed")
      path = (state.gapHeader && state.gapHeader.lifecycleStateCode === "Delegated")
           ? ["New", "Delegated", "Closed"]
           : ["New", "Closed"];
    else if (dormant.includes(current))          path = ["New", current, "Delegated"];
    else if (current === "Delegated")            path = ["New", "Delegated"];
    else                                          path = ["New", "Delegated"];  // in-progress: New -> Analysed

    const currentIdx = path.indexOf(current);
    container.innerHTML = "";
    path.forEach((code, i) => {
      if (i > 0) {
        const sep = document.createElement("span");
        sep.className = "sep";
        sep.textContent = ">";
        container.appendChild(sep);
      }
      const step = document.createElement("span");
      step.className = "step";
      if (i < currentIdx) step.classList.add("past");
      if (i === currentIdx) step.classList.add("current");
      if (terminalInvalid.includes(code) && code === current)
        step.classList.add("terminal-invalid");
      step.textContent = STATE_LABEL[code] || code;
      container.appendChild(step);
    });
  }

  function renderMetadata() {
    const dl = document.getElementById("gapDetailMetadata");
    if (!dl) return;
    const h = state.gapHeader || {};
    const row = (label, value) => value != null && value !== ""
      ? `<dt>${escapeHtml(label)}</dt><dd>${escapeHtml(String(value))}</dd>`
      : "";
    // "Duplicate of" and "Invalid reason" only show for the matching
    // terminal states; otherwise the header proc returns null for them.
    const duplicateOfDisplay = h.duplicateOfGapId
      ? `Gap #${h.duplicateOfGapId}${h.duplicateOfGapTitle ? ` -- ${h.duplicateOfGapTitle}` : ""}`
      : null;

    dl.innerHTML =
      row("Gap ID",          h.customGapId) +
      row("Title",           h.title) +
      row("Description",     h.description) +
      row("Source module",   h.sourceModuleCode) +
      row("Lifecycle state", h.lifecycleStateName || h.lifecycleStateCode) +
      row("Duplicate of",    duplicateOfDisplay) +
      row("Invalid reason",  h.invalidReason) +
      row("Legacy status",   h.statusCode) +
      row("Priority",        h.priority) +
      row("Severity",        h.severityName || h.severityCode) +
      row("Owner",           h.ownerName) +
      row("Owner emp id",    h.ownerEmployeeId) +
      row("Due date",        h.dueDate ? window.gracFormatDateOnly(h.dueDate) : null) +
      row("Organization id", h.organizationId);
    if (!dl.innerHTML) dl.innerHTML = `<dt>--</dt><dd>No metadata available.</dd>`;

    renderRelatedTasks();
    renderGapMappedPractices();
  }

  // Migration 382: read-only list of practices mapped to this Custom Gap
  // (captured on the Add Custom Gap form). Appended to the header metadata.
  async function renderGapMappedPractices() {
    const dl = document.getElementById("gapDetailMetadata");
    if (!dl) return;
    let rows = [];
    try {
      const url = U(`/practice/api/gaps/custom/${state.gapId}/practices?organizationId=${encodeURIComponent(state.orgId || 0)}`);
      const r = await fetch(url, { credentials: "same-origin" });
      if (r.ok) { const b = await r.json(); rows = (b && (b.data || b.Data)) || []; }
    } catch (err) { console.warn("gap mapped practices load failed", err); return; }
    const names = rows.map(x => escapeHtml(x.practiceName || x.PracticeName || ("Practice #" + (x.practiceId || x.PracticeId))));
    dl.innerHTML += `<dt>Mapped practices</dt><dd>${names.length ? names.join(", ") : "None"}</dd>`;
  }

  // -------------------- Practice Instance link (migration 321) --------
  // A plain "open in a new tab" link to gaps.cshtml's existing
  // destination (resolve-workspace, ?mode=view) -- an iframe embed was
  // tried first but hit connectivity issues a normal link doesn't (sir's
  // follow-up), so this replaced it rather than adding a fallback next
  // to a frame that shouldn't need one. Stays hidden for a gap with no
  // linked instance (Custom / Assurance gaps, or an Implementation gap
  // that has not been materialized).
  function renderPracticeInstanceLink() {
    const wrap = document.getElementById("gapInstanceLinkWrap");
    const link = document.getElementById("gapInstanceLink");
    if (!wrap || !link) return;
    const h = state.gapHeader || {};
    const instanceId = h.practiceInstanceId || h.PracticeInstanceId || null;
    if (!instanceId) {
      wrap.hidden = true;
      state.instanceLinkUrl = null;
      return;
    }
    // Built from location.origin rather than a bare relative path --
    // there is no upside to leaving relative-URL resolution to chance
    // versus spelling out the origin the page itself is already known
    // to be running on.
    state.instanceLinkUrl = window.location.origin
      + U("/Practice/Index/resolve-workspace")
      + "?instanceId=" + encodeURIComponent(instanceId)
      + "&organizationId=" + encodeURIComponent(state.orgId || h.organizationId || 0)
      + "&mode=view";
    link.href = state.instanceLinkUrl;
    wrap.hidden = false;
  }

  // -------------------- related tasks (BRD §15 / §14) -----------------
  // Rendered by the shared _related-tasks-panel partial, which every task
  // source mounts — Gap, Risk and Assurance Observations all get the same
  // list and the same §14 task-action status line from one implementation.
  //
  // Guarded on the global because the panel is a separate partial: if it
  // is ever removed from the page, the gap screen must still render.
  function renderRelatedTasks() {
    const host = document.getElementById("gapRelatedTasks");
    if (!host) return;
    if (!window.__gracRelatedTasks) { host.innerHTML = ""; return; }

    window.__gracRelatedTasks.mount(host, {
      sourceTypeCode: "Gap",
      sourceRecordId: state.gapId,
      organizationId: state.orgId
    });
  }

  // -------------------- terminal-invalid mode (from 173) --------------
  function isTerminalInvalid() {
    const h = state.gapHeader || {};
    if (h.lifecycleIsTerminal === true && h.lifecycleIsValidTerminal === false) return true;
    const code = (state.currentStateCode || "").toLowerCase();
    return code === "invalid" || code === "duplicate";
  }

  // -------------------- already-analysed mode (migration 324) ---------
  // Delegated is terminal-VALID (is_terminal=1, is_valid_terminal=1) --
  // the display name "Analysed" (175/319) is a label on that same
  // state_code, not a separate one. Once a gap is here the server
  // (sp_custom_gap_analysis_save, migration 324) rejects a second save
  // outright (THROW 55143); this mirrors that same rule client-side so
  // the analyst sees View instead of a form that would only fail on
  // submit. Request C part 2: "Show View only. Hide/disable Analyse."
  function isAlreadyAnalysed() {
    const h = state.gapHeader || {};
    if (h.lifecycleIsTerminal === true && h.lifecycleIsValidTerminal === true) return true;
    return (state.currentStateCode || "").toLowerCase() === "delegated";
  }

  // -------------------- obligations/Operationalization gate (367) -----
  // Mirrors the two new server-side guards in sp_custom_gap_analysis_save
  // (THROW 55144 unresolved obligations, THROW 55145 not-Operationalized)
  // so the analyst sees a locked form instead of one that would only
  // fail on submit. Only meaningful for a gap materialized from a
  // Practice Instance -- state.gapHeader.practiceInstanceId is null for
  // Custom/Assurance/Exception/Risk gaps, and this returns false for
  // those exactly like the server-side guards, which are scoped the
  // same way.
  // Migration 372: which currently-displayed obligations still block
  // Analysis -- only those completely unmarked (Not Set / Not Started).
  // Not Implemented and Partially Implemented no longer block (the
  // server's sp_custom_gap_analysis_save THROW 55144 guard narrowed the
  // same way) but stay visible, unchanged, on the Failed Obligation(s)
  // strip below. A missing currentStatusCode (a pre-372 database, whose
  // /linked-artefacts response has no CurrentStatusCode column yet)
  // falls back to "Not Started" so this degrades to the old, broader
  // client-side lock -- matching what the still-unmigrated server-side
  // guard would enforce anyway.
  function unassessedObligations() {
    return (state.failedObligations || [])
      .filter(o => (o.currentStatusCode || "Not Started") === "Not Started");
  }

  function isBlockedByUnresolvedObligations() {
    const h = state.gapHeader || {};
    if (!h.practiceInstanceId) return false;
    if (unassessedObligations().length > 0) return true;
    return h.isPracticeOperationalized === false;
  }

  function applyTerminalInvalidMode() {
    const invalidLocked      = isTerminalInvalid();
    const analysedLocked     = isAlreadyAnalysed();
    // Migration 367: only meaningful when neither of the two locks above
    // already applies -- an Invalid/Duplicate/Delegated gap is locked for
    // its own reason regardless of obligation/Operationalization state.
    const obligationsLocked  = !invalidLocked && !analysedLocked && isBlockedByUnresolvedObligations();
    const locked = invalidLocked || analysedLocked || obligationsLocked;

    const banner = document.getElementById("gapTerminalInvalidBanner");
    // The generic red banner is a FALLBACK for terminal-invalid states
    // that don't have a richer specific card. Duplicate has the purple
    // parent-link strip; Invalid has the red rationale card. Both convey
    // the same "closed to analysis" message with better context, so
    // hide the generic banner in those cases to avoid duplication.
    const hasSpecificCard = state.currentStateCode === "Duplicate"
                         || state.currentStateCode === "Invalid";
    if (banner) banner.hidden = !invalidLocked || hasSpecificCard;
    if (invalidLocked && !hasSpecificCard) {
      const h = state.gapHeader || {};
      const stateName = h.lifecycleStateName || h.lifecycleStateCode || "";
      const titleEl = document.getElementById("gapTerminalInvalidTitle");
      const textEl  = document.getElementById("gapTerminalInvalidText");
      if (titleEl) titleEl.textContent =
        `This gap is ${stateName} -- analysis is not applicable.`;
      if (textEl) textEl.textContent =
        `A ${stateName} gap does not need analysis, tasks, exceptions or risk candidates. ` +
        `Data below (if any) is kept read-only for audit.`;
    }

    // Migration 324: the "already Analysed" banner -- a friendlier,
    // non-error counterpart to the red terminal-invalid banner above.
    // Reuses the exact same read-only-lock mechanism just below; only
    // the messaging differs, since being Analysed is the successful
    // outcome, not a problem.
    const analysedBanner = document.getElementById("gapAlreadyAnalysedBanner");
    if (analysedBanner) analysedBanner.hidden = !analysedLocked;

    // Migration 367: amber banner explaining WHY analysis is blocked --
    // unresolved obligations, the Practice not yet Operationalized, or
    // both. Only shown when it is the reason the form is locked (i.e.
    // neither the red nor the green banner above already applies).
    const obligationsBanner = document.getElementById("gapObligationsBlockedBanner");
    if (obligationsBanner) {
      obligationsBanner.hidden = !obligationsLocked;
      if (obligationsLocked) {
        const h = state.gapHeader || {};
        // Migration 372: count only the still-blocking (Not Set) ones --
        // see unassessedObligations() above.
        const unassessedCount = unassessedObligations().length;
        const notOperationalized = h.isPracticeOperationalized === false;
        const textEl = document.getElementById("gapObligationsBlockedText");
        if (textEl) {
          const parts = [];
          if (unassessedCount > 0) {
            parts.push(unassessedCount === 1
              ? "1 obligation under this Practice has not been assessed yet"
              : `${unassessedCount} obligations under this Practice have not been assessed yet`);
          }
          if (notOperationalized) parts.push("the Practice has not been Operationalized yet");
          textEl.textContent = `Analysis is blocked until ${parts.join(" and ")}.`;
        }
      }
    }

    const form = document.getElementById("gapAnalysisForm");
    if (form) {
      form.querySelectorAll("input, select, textarea, button").forEach(el => {
        if (el.type === "submit") { el.hidden = locked; el.disabled = locked; }
        else                       { el.disabled = locked; }
      });
    }
  }

  // -------------------- actions strip --------------------
  async function refreshActions() {
    const container = document.getElementById("gapActionStrip");
    if (!container) return;
    state.actions = (await apiGet(`/actions?fromStateCode=${encodeURIComponent(state.currentStateCode)}`)) || [];
    // Hide actions the user should not click directly:
    //   'Delegate' -- fires automatically inside the analysis save proc.
    //   'Validate' -- redundant with save-analysis; saving analysis is
    //                 the implicit validation. Also deactivated at the
    //                 SQL layer in migration 175, but filter here too
    //                 in case a pre-175 server still returns it.
    //   'ReopenObligation' -- migration 356. Fires automatically from
    //                 sp_practice_gap_sync_for_instance when a new
    //                 Obligation fails under this gap's Practice
    //                 Instance after the gap was already Analysed. Its
    //                 transition row has to stay Active for the SQL
    //                 engine to accept that automatic call (see 356's
    //                 header), so it is filtered here rather than
    //                 deactivated server-side, the same way Delegate
    //                 already is.
    const AUTO_ONLY = new Set(["Delegate", "Validate", "ReopenObligation"]);
    // Hidden from THIS UI on request -- 'MarkInvalid' is still a fully
    // valid, functional transition at the lifecycle/API layer
    // (gap_lifecycle_transition_master, unchanged); only its button is
    // removed here. 'MarkDuplicate' is a separate action_code and stays
    // visible -- only Mark Invalid was asked to be hidden.
    const HIDDEN_BY_REQUEST = new Set(["MarkInvalid"]);
    const visible = state.actions.filter(a => !AUTO_ONLY.has(a.actionCode) && !HIDDEN_BY_REQUEST.has(a.actionCode));
    container.innerHTML = "";
    if (!visible.length) return;
    visible.forEach(a => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "pm-button";
      btn.title = a.description || "";
      btn.innerHTML = `<i class="fa-solid fa-arrow-right"></i> ${escapeHtml(a.actionName)}`;
      btn.addEventListener("click", () => openActionModal(a));
      container.appendChild(btn);
    });
  }

  function openActionModal(action) {
    document.getElementById("gapActionModalTitle").textContent = action.actionName;
    document.getElementById("gapActionCode").value = action.actionCode;
    document.getElementById("gapActionRemark").value = "";
    document.getElementById("gapActionMessage").textContent = "";
    document.getElementById("gapActionRemarkHint").textContent =
      action.remarkRequired ? "(required)" : "(optional)";
    const dupWrap = document.getElementById("gapActionDuplicateWrap");
    const invWrap = document.getElementById("gapActionInvalidWrap");
    dupWrap.hidden = action.toStateCode !== "Duplicate";
    invWrap.hidden = action.toStateCode !== "Invalid";
    document.getElementById("gapActionInvalidReason").value = "";
    // Mark Duplicate: (re)populate the picker fresh every open rather
    // than caching -- a gap raised a minute ago should already be
    // selectable, and this list is cheap (capped at 200 rows).
    if (!dupWrap.hidden) {
      loadDuplicateOfGapOptions();
    } else {
      document.getElementById("gapActionDuplicateOfId").innerHTML =
        '<option value="">-- select the gap this duplicates --</option>';
    }
    show("gapActionModal");
  }

  // Mark Duplicate used to ask the analyst to type a raw gap id. That
  // still is what gets saved (duplicateOfGapId, unchanged below) -- but
  // the field is now a picker of this gap's OWN organisation's gaps,
  // shown by title, so nobody has to go find and copy a number from
  // another tab. Reuses the same Gap Centre list endpoint gaps.cshtml
  // renders its grid from, so the two screens never disagree about what
  // a gap is called.
  //
  // Capped at the API's own 200-row clamp
  // (CustomGapService.ListGapCentreAsync / GapCentreController) -- an
  // organisation with more open gaps than that would need a search box
  // here rather than a plain list, which is outside what was asked.
  async function loadDuplicateOfGapOptions() {
    const sel  = document.getElementById("gapActionDuplicateOfId");
    const hint = document.getElementById("gapActionDuplicateOfHint");
    if (!sel) return;
    sel.disabled = true;
    sel.innerHTML = '<option value="">Loading gaps...</option>';
    if (hint) hint.textContent = "";
    try {
      const params = new URLSearchParams({
        organizationId: String(state.orgId || ""),
        page: "1",
        pageSize: "200"
      });
      const r = await fetch(U("/practice/api/gaps/custom/centre?" + params.toString()),
                             { credentials: "same-origin" });
      const body = r.ok ? await r.json() : null;
      const rows = (body && (body.rows || body.Rows)) || [];
      // Never offer the gap being closed as a duplicate of itself.
      const others = rows.filter(row => Number(row.customGapId || row.CustomGapId) !== state.gapId);
      sel.innerHTML = '<option value="">-- select the gap this duplicates --</option>'
        + others.map(row => {
            const id    = row.customGapId || row.CustomGapId;
            const title = row.title || row.Title || "(untitled)";
            return `<option value="${id}">#${id} -- ${escapeHtml(title)}</option>`;
          }).join("");
      if (!others.length && hint) hint.textContent = "No other gaps found for this organization.";
      sel.disabled = false;
    } catch (err) {
      console.error("loadDuplicateOfGapOptions failed", err);
      sel.innerHTML = '<option value="">Could not load gaps</option>';
      if (hint) hint.textContent = "Could not load this organization's gaps -- close and reopen this dialog to retry.";
    }
  }

  async function onActionConfirmSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("gapActionMessage");
    msg.textContent = "";
    const action = state.actions.find(a => a.actionCode === document.getElementById("gapActionCode").value);
    if (!action) return;
    const remark = document.getElementById("gapActionRemark").value.trim();
    const dupId  = Number(document.getElementById("gapActionDuplicateOfId").value) || null;
    const invR   = document.getElementById("gapActionInvalidReason").value.trim() || null;
    if (action.remarkRequired && !remark) { msg.textContent = "Remark is required for this action."; return; }
    if (action.toStateCode === "Duplicate" && !dupId) { msg.textContent = "Select the gap this is a duplicate of."; return; }
    if (action.toStateCode === "Invalid"   && !invR)  { msg.textContent = "Invalid reason is required.";     return; }
    const result = await apiPost(`/gaps/${state.gapId}/transition`, {
      actionCode:       action.actionCode,
      remark:           remark || null,
      duplicateOfGapId: dupId,
      invalidReason:    invR
    });
    if (!result || result.success === false) {
      const err = (result && result.error) || "Transition failed.";
      msg.textContent = err; alert(err);
      return;
    }
    hide("gapActionModal");
    if (result.toStateCode) state.currentStateCode = result.toStateCode;
    const fresh = await apiGet(`/gaps/${state.gapId}/header`);
    if (fresh) state.gapHeader = fresh;
    applyTerminalInvalidMode();
    renderCompactStepper();
    await refreshActions();
    await refreshHistory();
    renderMetadata();
    renderPracticeInstanceLink();  // migration 321
    await refreshDuplicateCard();
    refreshInvalidCard();
  }

  // -------------------- analysis --------------------
  async function refreshAnalysis() {
    const a = await apiGet(`/gaps/${state.gapId}/analysis`);
    // Never analysed yet? Apply an empty record anyway so the "auto"
    // severity and any other Add-Gap-side facts (detection method for
    // custom gaps, etc.) still populate from gapHeader inside
    // applyAnalysisToForm's own fallbacks. Without this the analyst
    // opened the page and saw a blank Severity select despite the
    // "(auto)" label -- the code that fills it was never called.
    applyAnalysisToForm(a || {});
  }

  async function onAnalysisSubmit(ev) {
    ev.preventDefault();
    const msg = document.getElementById("anMessage");
    msg.textContent = "";
    const payload = {
      detectionMethodCode:     valOrNull("anDetectionMethodCode"),
      detectionMethodName:     null,
      severityCode:            valOrNull("anSeverityCode"),
      severityName:            null,
      businessImpactCode:      valOrNull("anBusinessImpactCode"),
      businessImpactSummary:   valOrNull("anBusinessImpactSummary"),
      regulatoryImpactCode:    valOrNull("anRegulatoryImpactCode"),
      regulatoryImpactSummary: valOrNull("anRegulatoryImpactSummary"),
      rcaRequired:             document.getElementById("anRcaRequired").checked,
      // rcaMethodCode retired -- the taxonomy picker was noise on an
      // already-optional workflow. Sent as null so a server still on the
      // old schema treats it as "no opinion" and keeps its stored value.
      rcaMethodCode:           null,
      rcaSummary:              valOrNull("anRcaSummary"),
      // Renamed input id: anRecommendedActionSummary -> anCorrectiveAction.
      // Wire name (recommendedActionSummary) stays because that is what
      // the API contract is keyed on.
      recommendedActionSummary: valOrNull("anCorrectiveAction"),
      // New free-text column added by migration 249. Optional.
      preventiveAction:        valOrNull("anPreventiveAction"),
      // Migration 323: three independent checkboxes, sent as-is. No
      // longer derived from / deriving a mandatory Yes-No pair -- see
      // gap-detail.cshtml's decision-checkboxes comment. None of the
      // three is required; an analysis can be saved with all unchecked.
      recommendTask:           document.getElementById("anGenerateTask").checked,
      recommendException:      document.getElementById("anRequestException").checked,
      recommendRisk:           document.getElementById("anCreateRisk").checked,
      // 168's fields are no longer set by this UI. Sent as null so the
      // server-side legacy columns are left exactly as they were
      // (sp_custom_gap_analysis_save COALESCEs them, per migration 323) --
      // never overwritten, never used to drive anything.
      remediationPossible:     null,
      businessRiskPresent:     null
    };
    const result = await apiPut(`/gaps/${state.gapId}/analysis`, payload);
    if (!result || result.success === false) {
      const err = (result && result.error) || "Save failed.";
      msg.textContent = err; alert(err);
      return;
    }
    // Refresh downstream state FIRST, then report from it. The message
    // below is built from what the server actually has, never from the
    // payload we just sent -- see the note above buildSaveSummary().
    const fresh = await apiGet(`/gaps/${state.gapId}/header`);
    if (fresh) {
      state.gapHeader = fresh;
      state.currentStateCode = fresh.lifecycleStateCode || state.currentStateCode;
    }
    renderCompactStepper();
    renderMetadata();
    renderPracticeInstanceLink();  // migration 321
    renderSlaCard();       // migration 184 -- new severity may have re-matched SLA
    await refreshActions();
    const artefacts = await refreshLinkedArtefacts();
    await refreshHistory();
    // Migration 324: if this save just auto-delegated the gap to
    // Analysed, lock the form into read-only/View mode immediately --
    // otherwise the analyst would see an editable form (that the server
    // will now reject on a second submit) until the next manual refresh.
    applyTerminalInvalidMode();

    const summary = buildSaveSummary(result, payload, fresh, artefacts);
    alert(summary);
    msg.textContent = summary;
    // Still green: the analysis itself saved successfully whenever we
    // reach this point (a failed save already returned earlier, above).
    // A best-effort trigger failure is called out in the text itself
    // ("Failed: ...") rather than by recoloring the whole message.
    msg.style.color = "#22543d";
  }

  // Report what the save actually produced.
  //
  // This used to be built from the request payload: remediationPossible
  // === "Y" printed "Auto-created: a Task", and the state was hardcoded
  // to "Analysed". Both were wrong. Migration 199 rerouted the gap seam
  // to raise an invisible Task Candidate, so "a Task" was a lie for
  // several migrations and this message never noticed -- it was
  // describing the request, not the result. The lifecycle proc has also
  // moved the gap to Delegated, not Analysed, since 174.
  //
  // Reading /gaps/{id}/linked-artefacts instead means the message and
  // the chip strip below it come from one source of truth for what
  // WAS created. Migration 323 adds the other half: sp_custom_gap_
  // analysis_save's new second result set (result.taskCreated/
  // taskError/...) says WHY something the analyst asked for is
  // missing, instead of a requested-but-failed trigger looking
  // identical to one that was simply never ticked.
  function buildSaveSummary(result, payload, header, artefacts) {
    const created = [];
    if (artefacts && artefacts.task)
      created.push(`a Task (#${artefacts.task.artefactId})`);
    if (artefacts && artefacts.exception)
      created.push(`an Exception request (#${artefacts.exception.artefactId})`);
    if (artefacts && artefacts.risk)
      created.push(`a Risk candidate (#${artefacts.risk.artefactId})`);

    const failed = [];
    if (payload.recommendTask && !(artefacts && artefacts.task) && result && result.taskError)
      failed.push(`Task (${result.taskError})`);
    if (payload.recommendException && !(artefacts && artefacts.exception) && result && result.exceptionError)
      failed.push(`Exception request (${result.exceptionError})`);
    if (payload.recommendRisk && !(artefacts && artefacts.risk) && result && result.riskError)
      failed.push(`Risk candidate (${result.riskError})`);
    // Migration 324: sp_custom_gap_analysis_save now reports the auto-
    // Delegate ("Analysed") transition's own outcome the same way it
    // already reports Task/Exception/Risk -- a failure here is why the
    // status stays on its previous value instead of becoming Analysed.
    if (result && result.lifecycleTransitioned === false && result.lifecycleError)
      failed.push(`Status update to Analysed (${result.lifecycleError})`);

    const stateName = (result && result.lifecycleStateName)
                   || (header && (header.lifecycleStateName || header.lifecycleStateCode))
                   || state.currentStateCode || "";
    const parts = ["Analysis saved."];
    if (created.length) parts.push(`Linked: ${created.join(" + ")}.`);
    if (failed.length)  parts.push(`Failed: ${failed.join(" + ")}.`);
    if (stateName)      parts.push(`Gap is now ${stateName}.`);
    return parts.join("  ");
  }

  // -------------------- linked artefacts --------------------
  // Reads /gaps/{id}/linked-artefacts (backed by
  // sp_custom_gap_linked_artefacts) and renders one chip per Task /
  // Exception / Risk that the gap owns. Chips deep-link to the
  // respective Centre so the user can inspect the artefact.
  // Also renders the Failed Obligation(s) strip (migration 317) from the
  // SAME response's failedObligations array -- one read serves both
  // strips, so adding the Obligation strip did not add a second request.
  // Returns the artefact payload so callers can report on it (see
  // buildSaveSummary) without issuing a second identical request.
  async function refreshLinkedArtefacts() {
    const strip = document.getElementById("gapLinkedArtefactsStrip");
    const chips = document.getElementById("gapLinkedArtefactsChips");
    if (!strip || !chips) return null;

    const result = await apiGet(`/gaps/${state.gapId}/linked-artefacts`);
    if (!result) {
      strip.hidden = true;
      renderFailedObligations(null);
      return null;
    }
    // Screen keys match PracticeScreen.cs entries:
    //   tasks (Task Center), exception-centre, risk-centre.
    const rows = [
      { kind: "task",      label: "Task",             row: result.task,      centre: "tasks" },
      { kind: "exception", label: "Exception",        row: result.exception, centre: "exception-centre" },
      { kind: "risk",      label: "Risk Candidate",   row: result.risk,      centre: "risk-centre" }
    ].filter(x => x.row);

    renderFailedObligations(result.failedObligations);

    if (!rows.length) {
      strip.hidden = true;
      return result;   // no artefacts, but the read succeeded
    }
    strip.hidden = false;
    chips.innerHTML = "";
    rows.forEach(x => {
      const a = document.createElement("a");
      a.className = `gap-linked-chip type-${x.kind}`;
      // Task Center's own detail route may differ per install; link to
      // the centre page and rely on the user's role-based landing to
      // resolve the specific record. Exception + Risk Centres take you
      // to their list view, which shows the row filtered by org.
      a.href = U(`/Practice/Index/${x.centre}`);
      a.title = `Open in ${x.label} centre`;
      a.innerHTML = `
        <span class="chip-type">${escapeHtml(x.label)} #${x.row.artefactId}</span>
        <span class="chip-title">${escapeHtml(x.row.title || "(untitled)")}</span>
        <span class="chip-status">${escapeHtml(x.row.statusCode || "")}</span>`;
      chips.appendChild(a);
    });
    return result;
  }

  // Failed Obligation(s) strip (migration 317). Zero rows for any gap
  // that is not an automatically generated Implementation gap -- the
  // proc itself only ever returns rows for that case (see
  // sp_custom_gap_linked_artefacts, migration 317), so this function does
  // not need to re-check gap source; an empty/absent array just means
  // "nothing to show", same as a manually created gap.
  // Obligations have no detail page of their own to deep-link to (they
  // live inside the source Practice Instance's own workspace, which this
  // response does not carry an id for), so these render as plain
  // (non-anchor) info chips rather than links, unlike the Task/Exception/
  // Risk chips above.
  function renderFailedObligations(list) {
    // Migration 367: captured regardless of whether the strip elements
    // exist on this page, so isBlockedByUnresolvedObligations() always
    // has the current set -- applyTerminalInvalidMode() is called again
    // right after every refreshLinkedArtefacts() (see init(), the manual
    // refresh handler, and onAnalysisSubmit()), so this is always fresh
    // before the lock is (re)computed.
    state.failedObligations = list || [];

    const strip = document.getElementById("gapFailedObligationsStrip");
    const chips = document.getElementById("gapFailedObligationsChips");
    if (!strip || !chips) return;

    if (!list || !list.length) {
      strip.hidden = true;
      chips.innerHTML = "";
      return;
    }
    strip.hidden = false;
    chips.innerHTML = "";
    list.forEach(o => {
      const div = document.createElement("div");
      div.className = "gap-linked-chip type-obligation";
      div.innerHTML = `
        <span class="chip-type">${escapeHtml(o.obligationTypeCode || "Obligation")}</span>
        <span class="chip-title">${escapeHtml(o.obligationName || "(unnamed obligation)")}</span>
        <span class="chip-status">${escapeHtml(o.loggedStatusCode || "")}</span>`;
      chips.appendChild(div);
    });
  }

  // -------------------- duplicate handling (from migration 177) ------
  // For a Duplicate gap:
  //   * show a compact strip with a link to the parent gap
  //   * populate the (already-disabled) Analysis form fields with the
  //     PARENT gap's analysis so reviewers see the covered case without
  //     duplicating the same data in a separate card AND in the tabs
  async function refreshDuplicateCard() {
    const card = document.getElementById("gapDuplicateCard");
    if (!card) return;
    const h = state.gapHeader || {};
    if (state.currentStateCode !== "Duplicate" || !h.duplicateOfGapId) {
      card.hidden = true;
      return;
    }

    const parentId    = h.duplicateOfGapId;
    const parentTitle = h.duplicateOfGapTitle || `Gap #${parentId}`;
    const link = document.getElementById("gapDuplicateParentLink");
    link.textContent = `Gap #${parentId} -- ${parentTitle}`;
    link.href = U(`/Practice/Index/gap-detail?gapId=${parentId}&orgId=${state.orgId || ""}`);
    card.hidden = false;

    // Overwrite the analysis form (already read-only via terminal-invalid
    // mode) with the parent's analysis. If the parent has no analysis
    // yet, the form stays blank -- the strip explains why.
    const parent = await apiGet(`/gaps/${parentId}/analysis`);
    if (parent) applyAnalysisToForm(parent);
  }

  // Extracted from refreshAnalysis so both paths (own analysis + parent
  // analysis for Duplicate gaps) populate the same form the same way.
  // Show / hide the RCA fieldset in step with the RCA Required tick.
  // Analyst does not need RCA -> block is not on the page at all, so a
  // vacant fieldset does not read like an unfinished form.
  function toggleRcaBlockVisibility() {
    const box   = document.getElementById("anRcaRequired");
    const block = document.getElementById("anRcaBlock");
    if (!box || !block) return;
    block.hidden = !box.checked;
  }

  function applyAnalysisToForm(a) {
    // Migration 250: fall back to the header's detection method when
    // the analysis row has none yet. On a Custom gap the operator will
    // have entered it at Add time; on other sources it stays null and
    // the analyst picks one.
    const detFromAnalysis = a.detectionMethodCode;
    const detFromHeader   = (state.gapHeader && state.gapHeader.detectionMethodCode) || "";
    setVal("anDetectionMethodCode",  detFromAnalysis || detFromHeader);
    // Severity is auto-derived at gap creation now (post-189). If the
    // analysis record is fresh (severityCode still null) but the gap
    // header carries a severity, show that instead of leaving the
    // disabled field blank -- avoids operator confusion.
    const sevFromAnalysis = a.severityCode;
    const sevFromHeader   = (state.gapHeader && state.gapHeader.severityCode) || "";
    setVal("anSeverityCode",         sevFromAnalysis || sevFromHeader);
    // Belt-and-suspenders JS lock -- guarantees the field is disabled
    // even if Razor / a plugin strips the HTML `disabled` attribute.
    const anSev = document.getElementById("anSeverityCode");
    if (anSev) { anSev.disabled = true; anSev.setAttribute("aria-disabled", "true"); }
    setVal("anBusinessImpactCode",   a.businessImpactCode);
    setVal("anRegulatoryImpactCode", a.regulatoryImpactCode);
    setVal("anBusinessImpactSummary",   a.businessImpactSummary || "");
    setVal("anRegulatoryImpactSummary", a.regulatoryImpactSummary || "");
    const rcaBox = document.getElementById("anRcaRequired");
    rcaBox.checked = !!a.rcaRequired;
    // anRcaMethodCode retired. anRecommendedActionSummary renamed to
    // anCorrectiveAction, and a new anPreventiveAction column was added
    // by migration 249; both feed off the analysis record.
    setVal("anRcaSummary",         a.rcaSummary || "");
    setVal("anCorrectiveAction",   a.recommendedActionSummary || "");
    setVal("anPreventiveAction",   a.preventiveAction || "");
    toggleRcaBlockVisibility();
    // Migration 323: three independent checkboxes, bound straight to the
    // three flags -- no more deriving a Yes/No from them or a Yes/No
    // deriving them (168's remediationPossible/businessRiskPresent are no
    // longer read here; recommendTask/recommendException/recommendRisk
    // are the columns' original, pre-168 meaning and are what the save
    // path now writes directly).
    const genTaskBox = document.getElementById("anGenerateTask");
    const reqExcBox  = document.getElementById("anRequestException");
    const createRiskBox = document.getElementById("anCreateRisk");
    if (genTaskBox)    genTaskBox.checked    = !!a.recommendTask;
    if (reqExcBox)     reqExcBox.checked     = !!a.recommendException;
    if (createRiskBox) createRiskBox.checked = !!a.recommendRisk;
  }

  // -------------------- invalid-reason card (from 177) ---------------
  function refreshInvalidCard() {
    const card = document.getElementById("gapInvalidReasonCard");
    if (!card) return;
    const h = state.gapHeader || {};
    if (state.currentStateCode !== "Invalid" || !h.invalidReason) {
      card.hidden = true;
      return;
    }
    document.getElementById("gapInvalidReasonText").textContent = h.invalidReason;
    card.hidden = false;
  }

  // -------------------- history (compact) --------------------
  async function refreshHistory() {
    const ul = document.getElementById("gapHistoryList");
    if (!ul) return;
    ul.innerHTML = `<li class="pm-hint">History is captured in custom_gap_history by the transition proc. Use the Gap Centre report for the full log.</li>`;
  }

  // -------------------- helpers --------------------
  function show(id) { document.getElementById(id).hidden = false; }
  function hide(id) { document.getElementById(id).hidden = true; }
  function setVal(id, v) { const el = document.getElementById(id); if (el) el.value = v == null ? "" : v; }
  function valOrNull(id) { const v = document.getElementById(id)?.value?.trim() ?? ""; return v.length ? v : null; }
  function escapeHtml(s) {
    if (s == null) return "";
    return String(s).replace(/[&<>"']/g, ch => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[ch]));
  }

  async function apiGet(path) {
    const url = U(`${base}${path.startsWith("/") ? path : "/" + path}`);
    try {
      const r = await fetch(url, { credentials: "same-origin" });
      if (r.status === 404) return null;
      if (!r.ok) { console.warn("gap-lifecycle GET", url, r.status); return null; }
      return await r.json();
    } catch (err) { console.error("gap-lifecycle GET failed", url, err); return null; }
  }
  async function apiPost(path, body) { return jsonWrite("POST", path, body); }
  async function apiPut(path, body)  { return jsonWrite("PUT",  path, body); }

  // -------------------- SLA card + override dialog (184) --------------
  // Reads sla_* fields from the gap header (populated post-184). Shows
  // an Auto or Overridden badge, effective SLA days + due date, and an
  // Override button that raises an SLA_CANDIDATE exception request. A
  // Pending override displays a hint and disables the button until the
  // Exception Centre resolves it.
  function renderSlaCard() {
    const card = document.getElementById("gapSlaCard");
    if (!card) return;
    const h = state.gapHeader || {};
    // If the header proc has not been extended to emit sla_* yet, or
    // there is no severity to match, keep the card hidden.
    const hasSla = h.slaMasterId || h.slaDaysEffective != null;
    if (!hasSla) { card.style.display = "none"; return; }
    card.style.display = "block";

    const badge = document.getElementById("gapSlaSourceBadge");
    if (badge) {
      const src = String(h.slaSourceCode || "AUTO").toUpperCase();
      badge.textContent = src === "OVERRIDDEN" ? "Overridden" : "Auto";
      badge.style.background = src === "OVERRIDDEN" ? "#fef3c7" : "#dcfce7";
      badge.style.color      = src === "OVERRIDDEN" ? "#78350f" : "#166534";
    }
    const name = document.getElementById("gapSlaMasterName");
    if (name) name.textContent = h.slaMasterName || h.slaMasterCode || `Master #${h.slaMasterId}`;
    const daysEl = document.getElementById("gapSlaDaysText");
    if (daysEl) daysEl.textContent = h.slaDaysEffective != null ? `${h.slaDaysEffective} days` : "-- days";
    const dueEl = document.getElementById("gapSlaDueText");
    if (dueEl) dueEl.textContent = h.dueDate ? `Due ${window.gracFormatDateOnly(h.dueDate)}` : "";

    // Pending override lock -- the server enforces one pending SLA
    // request per gap. Reflect that in the UI so double-clicks are
    // impossible.
    const pending = !!h.slaOverridePending;
    document.getElementById("gapSlaPendingHint").hidden = !pending;
    const btn = document.getElementById("gapSlaOverrideBtn");
    if (btn) {
      btn.disabled = pending || isTerminalInvalid();
      btn.onclick  = pending ? null : openSlaOverrideDialog;
    }
  }

  function openSlaOverrideDialog() {
    const dlg = document.getElementById("gapSlaOverrideDialog");
    if (!dlg) return;
    const h = state.gapHeader || {};
    document.getElementById("gapSlaOverrideCurrent").value   = h.slaDaysEffective != null ? h.slaDaysEffective : "";
    document.getElementById("gapSlaOverrideRequested").value = h.slaDaysEffective != null ? h.slaDaysEffective : "";
    document.getElementById("gapSlaOverrideReason").value    = "";
    document.getElementById("gapSlaOverrideMessage").style.display = "none";
    dlg.showModal();
  }

  // Wire dialog close + submit once, on script load.
  document.addEventListener("DOMContentLoaded", () => {
    const dlg    = document.getElementById("gapSlaOverrideDialog");
    const closeB = document.getElementById("gapSlaOverrideClose");
    const cancel = document.getElementById("gapSlaOverrideCancel");
    const form   = document.getElementById("gapSlaOverrideForm");
    if (closeB && dlg) closeB.addEventListener("click", () => dlg.close());
    if (cancel && dlg) cancel.addEventListener("click", () => dlg.close());
    if (form) form.addEventListener("submit", async ev => {
      ev.preventDefault();
      const requested = Number(document.getElementById("gapSlaOverrideRequested").value);
      const reason    = document.getElementById("gapSlaOverrideReason").value;
      if (!Number.isFinite(requested) || requested < 0) {
        showSlaMsg("Requested SLA days must be >= 0.", true); return;
      }
      if (!reason || !reason.trim()) {
        showSlaMsg("Reason is required.", true); return;
      }
      const payload = {
        customGapId:           state.gapId,
        slaDaysRequested:      requested,
        requestReason:         reason.trim(),
        requestedByEmployeeId: Number(window.pmEmployeeId || 0) || null,
        callerDisplayName:     window.pmEmail || "system"
      };
      try {
        // Web-tier proxy for CustomGap endpoints lives at
        // /practice/api/gaps/custom/* (see Web GapsController), not
        // under a /custom-gaps root.
        const r = await fetch(
          U(`/practice/api/gaps/custom/${state.gapId}/sla/override`), {
            method:      "POST",
            headers:     { "Content-Type": "application/json" },
            credentials: "same-origin",
            body:        JSON.stringify(payload)
          });
        const b = await r.json().catch(() => ({}));
        if (!r.ok || !b.success) throw new Error(b.error || r.statusText);
        dlg.close();
        // Refresh so pending-flag / disabled state kicks in.
        const fresh = await apiGet(`/gaps/${state.gapId}/header`);
        if (fresh) { state.gapHeader = fresh; renderSlaCard(); }
      } catch (err) {
        showSlaMsg(String(err.message || err), true);
      }
    });
  });

  function showSlaMsg(msg, isError) {
    const el = document.getElementById("gapSlaOverrideMessage");
    if (!el) return;
    el.style.display    = "block";
    el.style.background = isError ? "#fee2e2" : "#dcfce7";
    el.style.color      = isError ? "#991b1b" : "#166534";
    el.textContent      = msg;
  }

  async function jsonWrite(method, path, body) {
    const url = U(`${base}${path.startsWith("/") ? path : "/" + path}`);
    try {
      const r = await fetch(url, {
        method,
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) return { success: false, error: data.error || `HTTP ${r.status}` };
      return { success: true, ...data };
    } catch (err) {
      console.error(`gap-lifecycle ${method} failed`, url, err);
      return { success: false, error: err.message };
    }
  }
})();
