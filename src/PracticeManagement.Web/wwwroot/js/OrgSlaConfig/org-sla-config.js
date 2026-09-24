// =====================================================================
// Organization SLA Configuration -- master-first flow (post-182).
// Loaded by Views/Practice/Partials/org-sla-config.cshtml.
//
// Screen contract:
//   Grid lists every grac_new.sla_master row for the org, one of:
//       Not Configured -> Configure (only action)
//       Active         -> Configure | Processes | Inactivate
//       Inactive       -> Configure | Processes | Reactivate
//
//   Configure dialog (post-182) is the one-stop shop for:
//     * Threshold days (Warning before / Escalation after)
//     * Notes
//     * Notify roles for THREE events: WARNING, BREACH, ESCALATION
//
//   Save flow issues two sequential POSTs:
//     1. /configs       -- upsert thresholds (creates row if new;
//                          fresh row is Active by design)
//     2. /configs/{id}/notify-roles -- full-replace all three event
//                                      role lists in one call
//
//   Configure on an already-configured row edits fields without
//   touching is_active -- the explicit Inactivate / Reactivate menu
//   items are the only way to change status.
//
// Auth model: the Web tier proxy at /practice/api/org-sla/* enforces
// session + cross-org isolation.
// =====================================================================
(() => {
  "use strict";

  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const SLA_API   = "/practice/api/org-sla";
  const ORGS_API  = "/practice/api/organizations/allowed";
  const ROLES_API = "/practice/api/org-roles";

  const state = {
    orgId              : null,
    search             : "",
    rows               : [],   // OrgSlaMasterGridRow[]
    roles              : [],   // { roleId, roleName }
    editing            : null  // current row when the Configure dialog is open
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("oaSlaRoot")) return;
    bindEvents();
    wireRowMenu();       // shared 3-dot menu -- delegated, bound once
    await populateOrgs();
    const sel = document.getElementById("oaSlaPickOrg");
    if (sel && sel.options.length > 1) {
      sel.selectedIndex = 1;
      state.orgId = Number(sel.value) || null;
      await Promise.all([loadRoles(), loadGrid()]);
    }
  }

  // -------------------------------------------------------------
  // Event wiring
  // -------------------------------------------------------------
  function bindEvents() {
    document.getElementById("oaSlaPickOrg").addEventListener("change", async ev => {
      state.orgId = Number(ev.target.value) || null;
      state.rows = [];
      await Promise.all([loadRoles(), loadGrid()]);
    });
    document.getElementById("oaSlaSearch").addEventListener("input", debounce(ev => {
      state.search = String(ev.target.value || "").trim();
      loadGrid();
    }, 300));
    document.getElementById("oaSlaReloadBtn").addEventListener("click", loadGrid);

    // Configure dialog (also handles notify roles post-182)
    document.getElementById("oaSlaConfigClose").addEventListener("click", () => document.getElementById("oaSlaConfigDialog").close());
    document.getElementById("oaSlaConfigCancel").addEventListener("click", () => document.getElementById("oaSlaConfigDialog").close());
    document.getElementById("oaSlaConfigForm").addEventListener("submit", submitConfigure);
    // Process bindings dialog wiring retired in migration 186.
  }

  // -------------------------------------------------------------
  // Lookups
  // -------------------------------------------------------------
  async function populateOrgs() {
    const sel = document.getElementById("oaSlaPickOrg");
    sel.innerHTML = '<option value="">-- pick organization --</option>';
    let rows = [];
    try {
      const r = await fetch(U(ORGS_API), { credentials: "same-origin" });
      if (r.ok) { const b = await r.json(); rows = (b && (b.data || b.Data)) || []; }
    } catch (_) {}
    rows.forEach(row => {
      const value = String(row.organizationId ?? row.OrganizationId ?? "");
      const label = String(row.organizationName ?? row.OrganizationName ?? "");
      if (!value) return;
      const opt = document.createElement("option");
      opt.value = value; opt.textContent = label;
      sel.appendChild(opt);
    });
  }

  async function loadRoles() {
    if (!state.orgId) { state.roles = []; return; }
    try {
      const r = await fetch(U(`${ROLES_API}?organizationId=${state.orgId}`), { credentials: "same-origin" });
      if (!r.ok) throw new Error(await r.text());
      const b = await r.json();
      state.roles = (b && (b.data || b.Data)) || [];
    } catch (err) { console.warn("loadRoles failed", err); state.roles = []; }
  }

  // loadProcessTypes removed in migration 186 alongside the endpoint.

  // -------------------------------------------------------------
  // Grid (master-first, 181)
  // -------------------------------------------------------------
  async function loadGrid() {
    const body = document.getElementById("oaSlaGridBody");
    if (!state.orgId) {
      body.innerHTML = `<tr><td colspan="10" class="pm-empty">Pick an organization to see the SLA masters.</td></tr>`;
      return;
    }
    body.innerHTML = `<tr><td colspan="10" class="pm-empty">Loading...</td></tr>`;
    try {
      const qs = new URLSearchParams({
        organizationId: state.orgId,
        search:         state.search || ""
      });
      const r = await fetch(U(`${SLA_API}/masters-with-config?${qs}`), { credentials: "same-origin" });
      if (!r.ok) throw new Error(await r.text());
      const b = await r.json();
      const result = (b && (b.data || b.Data)) || {};
      state.rows = (result.rows || result.Rows || []);
    } catch (err) {
      body.innerHTML = `<tr><td colspan="10" class="pm-empty pm-error">Failed to load: ${escapeHtml(String(err.message || err))}</td></tr>`;
      return;
    }
    renderGrid();
  }

  function renderGrid() {
    const body = document.getElementById("oaSlaGridBody");
    if (!state.rows.length) {
      body.innerHTML = `<tr><td colspan="10" class="pm-empty">No SLA masters available for this organization.
        Confirm Control Management has published masters in grac_new.sla_master.</td></tr>`;
      return;
    }
    const html = state.rows.map(r => {
      const name       = escapeHtml(r.slaMasterName || r.slaMasterCode || `SLA #${r.slaMasterId}`);
      const codeMarkup = r.slaMasterCode ? `<div style="color:#64748b; font-size:11px;">${escapeHtml(r.slaMasterCode)}</div>` : "";
      const duration   = (r.durationValue != null && r.durationUnit)
                           ? `${Number(r.durationValue)} ${escapeHtml(r.durationUnit)}`
                           : (r.totalSlaDays != null ? `${Number(r.totalSlaDays)} Days` : "-");
      const timeBasis  = escapeHtml(r.timeBasis || r.masterTimeBasis || "-");
      const overridden = (r.timeBasis && r.masterTimeBasis && r.timeBasis !== r.masterTimeBasis)
                           ? ' <span style="font-size:10px; color:#78350f;">(override)</span>' : "";
      const warnPct    = r.warningPct    != null ? `${Number(r.warningPct)}%`    : "-";
      const escPct     = r.escalationPct != null ? `${Number(r.escalationPct)}%` : "-";
      const badge      = statusBadge(r.configStatusCode, r.configStatusLabel);
      const menu       = actionMenu(r);
      return `
        <tr data-id="${r.slaMasterId}">
          <td>${name}${codeMarkup}</td>
          <td>${escapeHtml(r.processCode || "-")}</td>
          <td>${escapeHtml(r.classification || "-")}</td>
          <td>${duration}</td>
          <td>${timeBasis}${overridden}</td>
          <td>${warnPct}</td>
          <td>${escPct}</td>
          <td>${badge}</td>
          <td>${Number(r.notifyRoleCount)}</td>
          <td>${menu}</td>
        </tr>`;
    }).join("");
    body.innerHTML = html;

    // 3-dot menu handler is bound once at module load (wireRowMenu()
    // below) via event delegation. Nothing per-row to wire here.
  }

  function statusBadge(code, label) {
    const map = {
      NotConfigured: { bg: "#f1f5f9", fg: "#475569", text: label || "Not Configured" },
      Active:        { bg: "#dcfce7", fg: "#166534", text: label || "Active" },
      Inactive:      { bg: "#fef3c7", fg: "#78350f", text: label || "Inactive" }
    };
    const s = map[code] || map.NotConfigured;
    return `<span class="pm-badge"
              style="background:${s.bg}; color:${s.fg}; padding:2px 8px; border-radius:12px; font-size:12px; font-weight:600;">
              ${escapeHtml(s.text)}
            </span>`;
  }

  // Renders the row's 3-dot trigger only. The popover menu itself is
  // built on click by wireRowMenu() below, matching the pm-action-menu
  // pattern used across the codebase (see exception-centre.js).
  function actionMenu(r) {
    return `<button type="button" class="pm-action-trigger"
                    data-sla-menu="${r.slaMasterId}"
                    data-sla-status="${r.configStatusCode}"
                    aria-haspopup="menu" aria-expanded="false"
                    title="Actions" aria-label="Actions">
              <i class="fa-solid fa-ellipsis-vertical" aria-hidden="true"></i>
              <span class="visually-hidden">Actions</span>
            </button>`;
  }

  // -------------------------------------------------------------
  // 3-dot menu (shared PM pattern). Delegated so a single listener
  // handles every row in the grid without per-row rebinding.
  // -------------------------------------------------------------
  let openMenuEl = null, openMenuTrigger = null;

  function closeRowMenu() {
    if (openMenuEl) { openMenuEl.remove(); openMenuEl = null; }
    if (openMenuTrigger) {
      openMenuTrigger.setAttribute("aria-expanded", "false");
      openMenuTrigger = null;
    }
  }

  function positionRowMenu(trigger) {
    if (!openMenuEl) return;
    const tr = trigger.getBoundingClientRect();
    const mr = openMenuEl.getBoundingClientRect();
    let top = tr.bottom + 6, left = tr.right - mr.width;
    if (top + mr.height > window.innerHeight - 8) top = Math.max(8, tr.top - mr.height - 6);
    if (left < 8) left = 8;
    if (left + mr.width > window.innerWidth - 8) left = window.innerWidth - mr.width - 8;
    openMenuEl.style.top  = top  + "px";
    openMenuEl.style.left = left + "px";
  }

  function openRowMenu(trigger, items) {
    closeRowMenu();
    openMenuTrigger = trigger;
    trigger.setAttribute("aria-expanded", "true");
    openMenuEl = document.createElement("div");
    openMenuEl.className = "pm-action-menu";
    openMenuEl.setAttribute("role", "menu");
    items.forEach(it => {
      const b = document.createElement("button");
      b.type = "button";
      b.setAttribute("role", "menuitem");
      b.innerHTML = `<i class="fa-solid ${escapeHtml(it.icon)}" aria-hidden="true"></i> ${escapeHtml(it.label)}`;
      if (it.disabled) { b.disabled = true; b.title = it.disabledReason || ""; }
      b.addEventListener("click", ev => {
        ev.preventDefault(); ev.stopPropagation(); closeRowMenu();
        try { it.action(); } catch (err) { console.error("[sla] menu action failed", err); }
      });
      openMenuEl.appendChild(b);
    });
    document.body.appendChild(openMenuEl);
    positionRowMenu(trigger);
  }

  // Bind the delegated click handler ONCE (init calls this).
  function wireRowMenu() {
    const root = document.getElementById("oaSlaRoot");
    if (!root || root.dataset.wired === "1") return;
    root.dataset.wired = "1";

    root.addEventListener("click", ev => {
      const trigger = ev.target.closest(".pm-action-trigger[data-sla-menu]");
      if (!trigger) return;
      ev.preventDefault(); ev.stopPropagation();
      if (openMenuTrigger === trigger) { closeRowMenu(); return; }

      const id     = Number(trigger.dataset.slaMenu);
      const status = trigger.dataset.slaStatus;
      const row    = state.rows.find(r => Number(r.slaMasterId) === id);
      if (!row) return;
      state.editing = row;

      // Bind Processes retired in migration 186 -- SLA-to-process
      // matching is done exclusively by severity -> classification now.
      const items = [
        { icon: "fa-gear", label: "Configure",
          action: () => openConfigureDialog(row) }
      ];
      if (status === "Active") {
        items.push({ icon: "fa-ban", label: "Inactivate",
          action: () => toggleActive(row, false) });
      } else if (status === "Inactive") {
        items.push({ icon: "fa-check", label: "Reactivate",
          action: () => toggleActive(row, true) });
      }
      openRowMenu(trigger, items);
    });

    // Close on outside click / Escape.
    document.addEventListener("click", ev => {
      if (!openMenuEl) return;
      if (ev.target.closest(".pm-action-menu")) return;
      if (ev.target.closest(".pm-action-trigger[data-sla-menu]")) return;
      closeRowMenu();
    });
    document.addEventListener("keydown", ev => {
      if (ev.key === "Escape") closeRowMenu();
    });
    window.addEventListener("resize", () => {
      if (openMenuTrigger) positionRowMenu(openMenuTrigger);
    });
    window.addEventListener("scroll", () => {
      if (openMenuTrigger) positionRowMenu(openMenuTrigger);
    }, true);
  }

  // -------------------------------------------------------------
  // Configure dialog (thresholds + notes + notify roles for 3 events)
  // -------------------------------------------------------------
  async function openConfigureDialog(row) {
    state.editing = row;
    // Master identity header (read-only).
    document.getElementById("oaSlaConfigTitle").textContent =
      row.configStatusCode === "NotConfigured" ? "Configure SLA" : "Edit SLA Configuration";
    document.getElementById("oaSlaConfigMessage").style.display = "none";
    document.getElementById("oaSlaConfigMasterName").textContent = row.slaMasterName || row.slaMasterCode || `SLA #${row.slaMasterId}`;
    document.getElementById("oaSlaConfigMasterCode").textContent = row.slaMasterCode ? `[${row.slaMasterCode}]` : "";

    // Master identity meta -- always show what the MASTER defines
    // (not the effective tunables) so the operator can compare their
    // override against the source of truth.
    const metaParts = [];
    if (row.processCode)    metaParts.push(`Process: ${row.processCode}`);
    if (row.classification) metaParts.push(`Classification: ${row.classification}`);
    if (row.durationValue != null && row.durationUnit)
                            metaParts.push(`Duration: ${row.durationValue} ${row.durationUnit}`);
    if (row.masterTimeBasis)       metaParts.push(`Master Time Basis: ${row.masterTimeBasis}`);
    if (row.masterWarningPct    != null) metaParts.push(`Master Warning %: ${row.masterWarningPct}`);
    if (row.masterEscalationPct != null) metaParts.push(`Master Escalation %: ${row.masterEscalationPct}`);
    document.getElementById("oaSlaConfigMasterMeta").textContent = metaParts.join(" · ");

    // Threshold inputs -- pre-populated with the effective values
    // (config override if present, master fallback otherwise).
    document.getElementById("oaSlaConfigTotal").value   = row.totalSlaDays ?? "";
    document.getElementById("oaSlaConfigWarning").value = row.warningPct    ?? row.masterWarningPct    ?? "";
    document.getElementById("oaSlaConfigEsc").value     = row.escalationPct ?? row.masterEscalationPct ?? "";
    // Time basis combo: prefer override, fall back to master, else empty (== "-- from master --").
    const tb = row.timeBasis || row.masterTimeBasis || "";
    const tbSel = document.getElementById("oaSlaConfigTimeBasis");
    let matched = false;
    Array.from(tbSel.options).forEach(o => {
      if (o.value === tb) { o.selected = true; matched = true; }
      else o.selected = false;
    });
    if (!matched && tb) {
      // Master exposes an option we don't have hardcoded -- inject it.
      const opt = document.createElement("option");
      opt.value = tb; opt.textContent = tb; opt.selected = true;
      tbSel.appendChild(opt);
    } else if (!tb) {
      tbSel.selectedIndex = 0;
    }

    // Populate notify-role selects with the org's roles first, then
    // hydrate current selections from the existing config (if any).
    // Roles were loaded on org change; ensure it happened.
    if (!state.roles.length) await loadRoles();
    populateRoleSelect("oaSlaConfigNotifyWarning");
    populateRoleSelect("oaSlaConfigNotifyBreach");
    populateRoleSelect("oaSlaConfigNotifyEsc");

    let notesVal = "";
    if (row.orgSlaConfigId) {
      // Hydrate notes + current notify roles from detail.
      try {
        const r = await fetch(
          U(`${SLA_API}/configs/${row.orgSlaConfigId}?organizationId=${state.orgId}`),
          { credentials: "same-origin" });
        if (r.ok) {
          const b = await r.json();
          const detail = (b && (b.data || b.Data)) || {};
          const header = detail.header || detail.Header || {};
          notesVal = header.notes || header.Notes || "";
          const notifies = detail.notifyRoles || detail.NotifyRoles || [];
          selectRolesForEvent("oaSlaConfigNotifyWarning",
            notifies.filter(n => (n.notifyEventCode || "").toUpperCase() === "WARNING"));
          selectRolesForEvent("oaSlaConfigNotifyBreach",
            notifies.filter(n => (n.notifyEventCode || "").toUpperCase() === "BREACH"));
          selectRolesForEvent("oaSlaConfigNotifyEsc",
            notifies.filter(n => (n.notifyEventCode || "").toUpperCase() === "ESCALATION"));
        }
      } catch (_) { /* best effort */ }
    }
    document.getElementById("oaSlaConfigNotes").value = notesVal;

    document.getElementById("oaSlaConfigDialog").showModal();
  }

  // Save flow: two sequential POSTs so the notify-role save can
  // address the config by id (needed on first-time configuration
  // where the id is created by the first POST).
  async function submitConfigure(ev) {
    ev.preventDefault();
    if (!state.orgId || !state.editing) return;
    const row = state.editing;

    // Step 1 -- upsert thresholds (pct) + time basis + notes.
    const wPct = parseFloat(document.getElementById("oaSlaConfigWarning").value);
    const ePct = parseFloat(document.getElementById("oaSlaConfigEsc").value);
    if (isNaN(wPct) || wPct < 0 || wPct > 100) {
      showDialogMessage("oaSlaConfigMessage", "Warning % must be between 0 and 100.", true);
      return;
    }
    if (isNaN(ePct) || ePct < 0 || ePct > 100) {
      showDialogMessage("oaSlaConfigMessage", "Escalation % must be between 0 and 100.", true);
      return;
    }
    if (wPct > ePct) {
      showDialogMessage("oaSlaConfigMessage",
        "Warning % must be less than or equal to Escalation % (WARNING fires before ESCALATION).", true);
      return;
    }
    const upsertReq = {
      organizationId: state.orgId,
      orgSlaConfigId: row.orgSlaConfigId ?? null,
      slaMasterId:    Number(row.slaMasterId),
      slaMasterCode:  row.slaMasterCode || null,
      slaMasterName:  row.slaMasterName || null,
      totalSlaDays:   parseIntOrNull(document.getElementById("oaSlaConfigTotal").value),
      warningPct:     wPct,
      escalationPct:  ePct,
      timeBasis:      document.getElementById("oaSlaConfigTimeBasis").value || null,
      notes:          document.getElementById("oaSlaConfigNotes").value || null,
      actor:          window.pmEmail || "system"
    };

    let configId = row.orgSlaConfigId;
    try {
      const r = await fetch(U(`${SLA_API}/configs`), {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify(upsertReq)
      });
      const b = await r.json().catch(() => ({}));
      if (!r.ok || !b.success) throw new Error(b.error || r.statusText);
      configId = b.orgSlaConfigId || configId;
    } catch (err) {
      showDialogMessage("oaSlaConfigMessage",
        `Failed to save thresholds: ${err.message || err}`, true);
      return;
    }

    // Step 2 -- full-replace notify roles for all three events.
    const collect = (elId, code) =>
      Array.from(document.getElementById(elId).selectedOptions)
           .map(o => ({ notifyEventCode: code, roleId: Number(o.value) }));
    const rolesReq = {
      organizationId: state.orgId,
      orgSlaConfigId: Number(configId),
      roles: [
        ...collect("oaSlaConfigNotifyWarning", "WARNING"),
        ...collect("oaSlaConfigNotifyBreach",  "BREACH"),
        ...collect("oaSlaConfigNotifyEsc",     "ESCALATION")
      ],
      actor: window.pmEmail || "system"
    };
    try {
      const r = await fetch(U(`${SLA_API}/configs/${configId}/notify-roles`), {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify(rolesReq)
      });
      const b = await r.json().catch(() => ({}));
      if (!r.ok || !b.success) throw new Error(b.error || r.statusText);
    } catch (err) {
      showDialogMessage("oaSlaConfigMessage",
        `Thresholds saved, but notify roles failed: ${err.message || err}. Try Save again to retry.`, true);
      await loadGrid();
      return;
    }

    document.getElementById("oaSlaConfigDialog").close();
    showBanner("Saved.", false);
    await loadGrid();
  }

  // -------------------------------------------------------------
  // Inactivate / Reactivate
  // -------------------------------------------------------------
  async function toggleActive(row, makeActive) {
    if (!await window.gracUi.confirm(makeActive
          ? `Reactivate this SLA for ${row.slaMasterName || row.slaMasterCode}?`
          : `Inactivate this SLA for ${row.slaMasterName || row.slaMasterCode}? Downstream process pickers will stop surfacing it.`,
          { type: makeActive ? "confirm" : "warning",
            title: makeActive ? "Reactivate SLA" : "Inactivate SLA",
            confirmText: makeActive ? "Reactivate" : "Inactivate" }))
      return;
    try {
      const r = await fetch(U(`${SLA_API}/configs/set-active`), {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify({
          organizationId: state.orgId,
          slaMasterId:    Number(row.slaMasterId),
          isActive:       !!makeActive,
          actor:          window.pmEmail || "system"
        })
      });
      const b = await r.json().catch(() => ({}));
      if (!r.ok || !b.success) throw new Error(b.error || r.statusText);
      showBanner(makeActive ? "Reactivated." : "Inactivated.", false);
      await loadGrid();
    } catch (err) {
      showBanner(String(err.message || err), true);
    }
  }

  // -------------------------------------------------------------
  // Role select helpers -- shared by the Configure dialog's three
  // notify-role multi-selects.
  //
  // The underlying <select multiple> stays in the DOM as the semantic
  // backing (submit code reads its selectedOptions unchanged); the
  // visible UI is a collapsible trigger + popover built by
  // mountMultiDropdown so operators aren't stuck with the native
  // Ctrl+click list box.
  // -------------------------------------------------------------
  const dropdownRefreshers = {}; // selectId -> () => void

  function populateRoleSelect(elId) {
    const sel = document.getElementById(elId);
    sel.innerHTML = "";
    state.roles.forEach(r => {
      const opt = document.createElement("option");
      opt.value       = String(r.roleId);
      opt.textContent = String(r.roleName || `Role #${r.roleId}`);
      sel.appendChild(opt);
    });
    mountMultiDropdown(elId);
  }

  function selectRolesForEvent(elId, rows) {
    const sel = document.getElementById(elId);
    const set = new Set((rows || []).map(r => String(r.roleId)));
    Array.from(sel.options).forEach(o => { o.selected = set.has(o.value); });
    const refresh = dropdownRefreshers[elId];
    if (refresh) refresh();
  }

  // -------------------------------------------------------------
  // mountMultiDropdown(selectId)
  //   Hides the underlying <select multiple> and injects a trigger
  //   button + checkbox popover into the sibling .pm-multi-host div.
  //   The popover closes on outside click and Escape (globals below).
  // -------------------------------------------------------------
  function mountMultiDropdown(selectId) {
    const sel  = document.getElementById(selectId);
    const host = document.querySelector(`.pm-multi-host[data-target="${selectId}"]`);
    if (!host || !sel) return;
    host.innerHTML = "";

    const trigger = document.createElement("button");
    trigger.type = "button";
    trigger.className = "pm-multi-trigger";
    trigger.style.cssText =
      "padding:6px 8px; border:1px solid #cbd5e1; border-radius:4px; background:#fff; " +
      "width:100%; text-align:left; cursor:pointer; display:flex; " +
      "justify-content:space-between; align-items:center; font-size:13px; color:#0f172a;";

    const popover = document.createElement("div");
    popover.className = "pm-multi-popover";
    popover.hidden = true;
    popover.style.cssText =
      "position:absolute; top:calc(100% + 2px); left:0; right:0; background:#fff; " +
      "border:1px solid #cbd5e1; border-radius:4px; " +
      "box-shadow:0 4px 12px rgba(15,23,42,.15); max-height:220px; overflow:auto; " +
      "z-index:20; padding:2px 0;";

    Array.from(sel.options).forEach(opt => {
      const lbl = document.createElement("label");
      lbl.style.cssText =
        "display:flex; align-items:center; gap:8px; padding:6px 10px; cursor:pointer; " +
        "font-size:13px; color:#0f172a;";
      lbl.addEventListener("mouseover", () => { lbl.style.background = "#f1f5f9"; });
      lbl.addEventListener("mouseout",  () => { lbl.style.background = ""; });
      const cb = document.createElement("input");
      cb.type    = "checkbox";
      cb.value   = opt.value;
      cb.checked = opt.selected;
      cb.addEventListener("change", () => {
        opt.selected = cb.checked;
        refreshTrigger();
      });
      lbl.appendChild(cb);
      lbl.appendChild(document.createTextNode(" " + opt.textContent));
      popover.appendChild(lbl);
    });

    function refreshTrigger() {
      const selected = Array.from(sel.selectedOptions).map(o => o.textContent);
      const summary  = selected.length === 0
                        ? "Select roles"
                        : selected.length <= 2
                        ? selected.join(", ")
                        : `${selected.length} selected`;
      trigger.innerHTML = "";
      const label = document.createElement("span");
      label.textContent = summary;
      label.style.cssText = "flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;";
      label.style.color   = selected.length === 0 ? "#94a3b8" : "#0f172a";
      const chev = document.createElement("span");
      chev.textContent = "▾";
      chev.style.marginLeft = "6px";
      chev.style.color      = "#64748b";
      trigger.appendChild(label);
      trigger.appendChild(chev);
    }
    refreshTrigger();

    trigger.addEventListener("click", (e) => {
      e.stopPropagation();
      // Close any other open popover first (single-open UX).
      document.querySelectorAll(".pm-multi-popover").forEach(p => {
        if (p !== popover) p.hidden = true;
      });
      popover.hidden = !popover.hidden;
      if (!popover.hidden) positionPopover();
    });
    // Clicks inside the popover must not bubble to the outside-close handler.
    popover.addEventListener("click", (e) => e.stopPropagation());

    // Flip popover upward when opening below would spill past the
    // viewport bottom -- avoids the whole page picking up a scrollbar.
    function positionPopover() {
      const rect  = trigger.getBoundingClientRect();
      const below = window.innerHeight - rect.bottom;
      const above = rect.top;
      const popH  = 240; // approx max content + padding
      if (below < popH && above > below) {
        popover.style.top    = "auto";
        popover.style.bottom = "calc(100% + 2px)";
      } else {
        popover.style.top    = "calc(100% + 2px)";
        popover.style.bottom = "auto";
      }
    }

    host.appendChild(trigger);
    host.appendChild(popover);

    dropdownRefreshers[selectId] = refreshTrigger;
  }

  // One-time global close bindings for the multi-dropdown popovers.
  if (!window.__pmMultiBound) {
    window.__pmMultiBound = true;
    document.addEventListener("click", () => {
      document.querySelectorAll(".pm-multi-popover:not([hidden])").forEach(p => { p.hidden = true; });
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        document.querySelectorAll(".pm-multi-popover:not([hidden])").forEach(p => { p.hidden = true; });
      }
    });
  }

  // Process bindings dialog + related helpers were removed in
  // migration 186 alongside the org_sla_process_binding table.

  // -------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------
  function debounce(fn, ms) {
    let t;
    return function (...args) { clearTimeout(t); t = setTimeout(() => fn.apply(this, args), ms); };
  }
  function parseIntOrNull(v) {
    if (v === null || v === undefined || v === "") return null;
    const n = Number(v);
    return isNaN(n) ? null : n;
  }
  function escapeHtml(s) {
    return String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  }
  function showBanner(msg, isError) {
    const el = document.getElementById("oaSlaMessage");
    el.hidden = false;
    el.style.background = isError ? "#fee2e2" : "#dcfce7";
    el.style.color      = isError ? "#991b1b" : "#166534";
    el.textContent      = msg;
    setTimeout(() => { el.hidden = true; }, 4500);
  }
  function showDialogMessage(elId, msg, isError) {
    const el = document.getElementById(elId);
    el.style.display    = "block";
    el.style.background = isError ? "#fee2e2" : "#dcfce7";
    el.style.color      = isError ? "#991b1b" : "#166534";
    el.textContent      = msg;
  }
})();
