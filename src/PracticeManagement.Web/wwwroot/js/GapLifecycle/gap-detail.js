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
//   * Action strip: whatever transitions the current state allows
//     (typically Mark Invalid / Mark Duplicate; Delegate is auto).
//   * Analysis tab: form + linked-artefacts chip strip (populated from
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
    gapHeader: null
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

    renderMetadata();
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
    const current = state.currentStateCode;

    let path;
    if (terminalInvalid.includes(current))       path = ["New", current];
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
      row("Due date",        h.dueDate ? new Date(h.dueDate).toLocaleDateString() : null) +
      row("Organization id", h.organizationId);
    if (!dl.innerHTML) dl.innerHTML = `<dt>--</dt><dd>No metadata available.</dd>`;

    renderRelatedTasks();
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

  function applyTerminalInvalidMode() {
    const locked = isTerminalInvalid();
    const banner = document.getElementById("gapTerminalInvalidBanner");
    // The generic red banner is a FALLBACK for terminal-invalid states
    // that don't have a richer specific card. Duplicate has the purple
    // parent-link strip; Invalid has the red rationale card. Both convey
    // the same "closed to analysis" message with better context, so
    // hide the generic banner in those cases to avoid duplication.
    const hasSpecificCard = state.currentStateCode === "Duplicate"
                         || state.currentStateCode === "Invalid";
    if (banner) banner.hidden = !locked || hasSpecificCard;
    if (locked && !hasSpecificCard) {
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
    const AUTO_ONLY = new Set(["Delegate", "Validate"]);
    const visible = state.actions.filter(a => !AUTO_ONLY.has(a.actionCode));
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
    document.getElementById("gapActionDuplicateOfId").value = "";
    document.getElementById("gapActionInvalidReason").value = "";
    show("gapActionModal");
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
    if (action.toStateCode === "Duplicate" && !dupId) { msg.textContent = "duplicate_of_gap_id is required."; return; }
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
    await refreshDuplicateCard();
    refreshInvalidCard();
  }

  // -------------------- analysis --------------------
  async function refreshAnalysis() {
    const a = await apiGet(`/gaps/${state.gapId}/analysis`);
    if (!a) return;    // 404 = never analysed yet
    applyAnalysisToForm(a);
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
      rcaMethodCode:           valOrNull("anRcaMethodCode"),
      rcaSummary:              valOrNull("anRcaSummary"),
      recommendedActionSummary: valOrNull("anRecommendedActionSummary"),
      recommendTask:           false,
      recommendException:      false,
      recommendRisk:           false,
      remediationPossible:     valOrNull("anRemediationPossible"),
      businessRiskPresent:     valOrNull("anBusinessRiskPresent")
    };
    if (!payload.remediationPossible || !payload.businessRiskPresent) {
      msg.textContent = "Please answer both decision questions before saving.";
      alert("Please answer both decision questions before saving.");
      return;
    }
    const result = await apiPut(`/gaps/${state.gapId}/analysis`, payload);
    if (!result || result.success === false) {
      const err = (result && result.error) || "Save failed.";
      msg.textContent = err; alert(err);
      return;
    }
    // Describe what got auto-created + auto-delegated.
    const created = [];
    if (payload.remediationPossible === "Y") created.push("a Task");
    if (payload.remediationPossible === "N") created.push("an Exception request");
    if (payload.businessRiskPresent  === "Y") created.push("a Risk candidate");
    const suffix = created.length
      ? `  Auto-created: ${created.join(" + ")}. Gap moved to Analysed.`
      : "  Gap moved to Analysed.";
    alert("Analysis saved." + suffix);
    msg.textContent = "Analysis saved." + suffix;
    msg.style.color = "#22543d";

    // Refresh downstream state: header (state chip + terminal flags),
    // stepper, actions, linked artefacts. The state chip itself is
    // rendered by renderCompactStepper (no separate setStateChip
    // helper -- that reference was a dead call that threw ReferenceError
    // whenever an analysis save completed).
    const fresh = await apiGet(`/gaps/${state.gapId}/header`);
    if (fresh) {
      state.gapHeader = fresh;
      state.currentStateCode = fresh.lifecycleStateCode || state.currentStateCode;
    }
    renderCompactStepper();
    renderMetadata();
    renderSlaCard();       // migration 184 -- new severity may have re-matched SLA
    await refreshActions();
    await refreshLinkedArtefacts();
    await refreshHistory();
  }

  // -------------------- linked artefacts --------------------
  // Reads /gaps/{id}/linked-artefacts (backed by
  // sp_custom_gap_linked_artefacts) and renders one chip per Task /
  // Exception / Risk that the gap owns. Chips deep-link to the
  // respective Centre so the user can inspect the artefact.
  async function refreshLinkedArtefacts() {
    const strip = document.getElementById("gapLinkedArtefactsStrip");
    const chips = document.getElementById("gapLinkedArtefactsChips");
    if (!strip || !chips) return;

    const result = await apiGet(`/gaps/${state.gapId}/linked-artefacts`);
    if (!result) {
      strip.hidden = true;
      return;
    }
    // Screen keys match PracticeScreen.cs entries:
    //   tasks (Task Center), exception-centre, risk-centre.
    const rows = [
      { kind: "task",      label: "Task",             row: result.task,      centre: "tasks" },
      { kind: "exception", label: "Exception",        row: result.exception, centre: "exception-centre" },
      { kind: "risk",      label: "Risk Candidate",   row: result.risk,      centre: "risk-centre" }
    ].filter(x => x.row);

    if (!rows.length) {
      strip.hidden = true;
      return;
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
  function applyAnalysisToForm(a) {
    setVal("anDetectionMethodCode",  a.detectionMethodCode);
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
    document.getElementById("anRcaRequired").checked = !!a.rcaRequired;
    setVal("anRcaMethodCode",              a.rcaMethodCode);
    setVal("anRcaSummary",                 a.rcaSummary || "");
    setVal("anRecommendedActionSummary",   a.recommendedActionSummary || "");
    const remedVal = a.remediationPossible
                  || (a.recommendTask ? "Y" : (a.recommendException ? "N" : ""));
    const riskVal  = a.businessRiskPresent
                  || (a.recommendRisk ? "Y" : "");
    setVal("anRemediationPossible",  remedVal);
    setVal("anBusinessRiskPresent",  riskVal);
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
    if (dueEl) dueEl.textContent = h.dueDate ? `Due ${new Date(h.dueDate).toLocaleDateString()}` : "";

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
