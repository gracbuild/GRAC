/* Event Profiles (migrations 329-332, 407).
   List, create/edit with attribute criteria, and Configure Checklists.
   407: two profile types -- People (EMPLOYEE) and Asset (ASSET). The list
   has a Profile Type column and filter; the Add / Edit dialog has the two
   type tabs; criteria cascade by the master's parentDimensionCode.
   Criteria rows are rendered from /scope/profiles/dimensions, so a new
   dimension seeded in SQL appears here with no change to this file.
   Markup: Views/Practice/Partials/event-profiles.cshtml */
(function () {
  "use strict";

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  var FEATURE = "screen.event-profiles";

  // 407: subject_entity per profile type, and the words each one uses.
  // The dimensions themselves still come from the master -- this is only
  // the vocabulary the screen speaks in. `events` names the checklist
  // editor's event list an Asset Profile answers.
  var SUBJECTS = {
    EMPLOYEE: { type: "People", many: "employees", member: "an employee", events: null },
    ASSET:    { type: "Asset",  many: "assets",    member: "an asset",    events: "ASSET_CATEGORY" }
  };
  function subjectOf(code) { return SUBJECTS[code] ? code : "EMPLOYEE"; }

  var orgId = null;
  var pager = null;
  var formSubject = "EMPLOYEE";  // the Add / Edit dialog's active type tab
  var dimensionsBySubject = {};  // subjectEntity -> rows from the dimension master
  var criteriaSeq = 0;           // guards renderCriteria against a quicker tab switch
  var valueCache = {};        // dimensionCode -> [{id,textValue,name}]
  var editing = null;         // profile being edited, null while adding
  var previewTimer = null;
  var menu = null;            // the floating .pm-action-menu, if one is open
  var menuTrigger = null;

  // Checklists tab (migration 344). "profiles" | "checklists" -- which of
  // #epRoot / #ecRoot is showing. Both tabs share the one #epOrganization
  // selector in #epSharedToolbar, so switching tabs never re-asks for an
  // organization.
  var activeTab = "profiles";
  var ecPager = null;

  function U(p) {
    return String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  }
  function esc(v) { return window.__wfCommon.escape(v); }
  function csrf() {
    var m = document.querySelector('meta[name="csrf-token"]');
    return m ? m.content : "";
  }
  function el(id) { return document.getElementById(id); }
  function msg(text, kind) { window.__wfCommon.setMessage("epMessage", text, kind); }
  function formMsg(text, kind) { window.__wfCommon.setMessage("epFormMessage", text, kind); }

  // ------------------------------------------------------------------
  async function init() {
    var orgs = await window.__wfCommon.loadOrgs();
    if (!orgs.length) {
      return window.__wfCommon.unavailable("epUnavailable", "epUnavailableTitle", "epUnavailableBody",
        "No organizations are available for your account.", "");
    }
    el("epRoot").hidden = false;
    window.__wfCommon.populateOrgSelect("epOrganization", orgs);

    pager = window.__pmGrid ? window.__pmGrid.attach({
      hostId: "epPager",
      onChange: function () { loadList(); }
    }) : null;
    ecPager = window.__pmGrid ? window.__pmGrid.attach({
      hostId: "ecPager",
      onChange: function () { loadChecklists(); }
    }) : null;

    el("epOrganization").addEventListener("change", onOrgChange);
    // Filters reset to page 1. Staying on page 3 of a filter that now
    // matches four rows shows an empty grid and reads as a fault.
    el("epStatus").addEventListener("change", function () { resetAndLoad(); });
    el("epProfileType").addEventListener("change", function () { resetAndLoad(); });
    document.querySelectorAll("#epTypeTabs [data-ep-type]").forEach(function (tab) {
      tab.addEventListener("click", function () {
        if (tab.disabled || tab.getAttribute("data-ep-type") === formSubject) return;
        setFormSubject(tab.getAttribute("data-ep-type"), false);
        formMsg(null);
        renderCriteria(null);
        schedulePreview();
      });
    });
    el("epSearch").addEventListener("input", debounce(function () { resetAndLoad(); }, 250));
    el("epRefreshBtn").addEventListener("click", function () { valueCache = {}; refreshAll(); });
    el("epAddBtn").addEventListener("click", function () { openForm(null); });

    el("epTabProfiles").addEventListener("click", function () { switchTab("profiles"); });
    el("epTabChecklists").addEventListener("click", function () { switchTab("checklists"); });
    el("ecSearch").addEventListener("input", debounce(function () { resetAndLoadChecklists(); }, 250));
    el("ecRefreshBtn").addEventListener("click", function () { loadChecklists(); });
    el("ecMappedClose").addEventListener("click", closeMappedProfiles);
    el("ecMappedDone").addEventListener("click", closeMappedProfiles);

    el("epFormClose").addEventListener("click", closeForm);
    el("epFormCancel").addEventListener("click", closeForm);
    el("epForm").addEventListener("submit", onSubmit);

    el("epViewClose").addEventListener("click", closeView);
    el("epViewDone").addEventListener("click", closeView);

    el("epConfigureBack").addEventListener("click", async function () {
      // Going back is an in-page swap, so beforeunload never fires. Ticks
      // are staged until Save, and leaving would drop them silently.
      var ed = window.__scopeChecklistEditor;
      if (ed && ed.hasUnsavedChanges && ed.hasUnsavedChanges()) {
        var go = await window.gracUi.confirm(
          ed.unsavedCount() + " checklist change(s) have not been saved. Leave without saving?",
          { type: "warning", title: "Unsaved changes", confirmText: "Discard and go back" });
        if (!go) return;
      }
      el("epConfigure").hidden = true;
      // Configure Checklists is only ever entered from the Profiles tab's
      // row menu, so coming back always restores that tab.
      el("epSharedToolbar").hidden = false;
      activeTab = "profiles";
      el("epTabProfiles").classList.add("active");
      el("epTabProfiles").setAttribute("aria-selected", "true");
      el("epTabChecklists").classList.remove("active");
      el("epTabChecklists").setAttribute("aria-selected", "false");
      el("epRoot").hidden = false;
      el("ecRoot").hidden = true;
      refreshAll();
    });

    // A body-level floating menu cannot follow the page, so it is
    // dismissed rather than left stranded -- the same three listeners
    // practice.js registers. Scroll is captured, so scrolling the table
    // itself counts, not just the window.
    document.addEventListener("click", function (ev) {
      if (menu && !menu.contains(ev.target) && !ev.target.closest(".pm-action-trigger")) closeRowMenu();
    });
    document.addEventListener("keydown", function (ev) {
      if (ev.key === "Escape") closeRowMenu();
    });
    window.addEventListener("resize", closeRowMenu);
    window.addEventListener("scroll", closeRowMenu, true);

    await onOrgChange();
  }

  function debounce(fn, ms) {
    var t = null;
    return function () { clearTimeout(t); t = setTimeout(fn, ms); };
  }

  function resetAndLoad() {
    if (pager) pager.reset(true);
    loadList();
  }

  function resetAndLoadChecklists() {
    if (ecPager) ecPager.reset(true);
    loadChecklists();
  }

  // Which of #epRoot / #ecRoot shows. Both read the same orgId, so
  // switching tabs never re-asks for an organization or re-runs the
  // feature-flag probe -- it just loads that tab's own list.
  function switchTab(tab) {
    if (tab === activeTab) return;
    activeTab = tab;
    var onProfiles = tab === "profiles";
    el("epTabProfiles").classList.toggle("active", onProfiles);
    el("epTabProfiles").setAttribute("aria-selected", onProfiles ? "true" : "false");
    el("epTabChecklists").classList.toggle("active", !onProfiles);
    el("epTabChecklists").setAttribute("aria-selected", onProfiles ? "false" : "true");
    el("epRoot").hidden = !onProfiles;
    el("ecRoot").hidden = onProfiles;
    if (onProfiles) refreshAll(); else loadChecklists();
  }

  async function onOrgChange() {
    orgId = el("epOrganization").value || null;
    valueCache = {};
    if (!orgId) {
      setBody('<tr><td colspan="7" class="pm-empty">Select an organization.</td></tr>');
      setEcBody('<tr><td colspan="5" class="pm-empty">Select an organization.</td></tr>');
      return;
    }

    // The flag is per organization, so this is re-evaluated on every
    // change and BOTH panels are toggled both ways. Only hiding on the
    // disabled branch would leave the screen blank after switching from
    // an organization that has it off back to one that has it on.
    var enabled = await window.__wfCommon.checkFeature(FEATURE, orgId);
    el("epSharedToolbar").hidden = !enabled;
    el("epRoot").hidden = !enabled || activeTab !== "profiles";
    el("ecRoot").hidden = !enabled || activeTab !== "checklists";
    el("epUnavailable").hidden = enabled;
    if (!enabled) return;

    if (activeTab === "checklists") await loadChecklists(); else await refreshAll();
  }

  async function refreshAll() {
    await Promise.all([loadList(), loadCoverage()]);
  }

  function setBody(html) { el("epBody").innerHTML = html; }
  function setEcBody(html) { el("ecBody").innerHTML = html; }

  // ------------------------------------------------------------------
  // Criterion dimensions. Fetched once per profile type per screen load:
  // the master is global configuration, not per-organization data.
  // ------------------------------------------------------------------
  async function loadDimensions(subject) {
    if (dimensionsBySubject[subject]) return dimensionsBySubject[subject];
    try {
      var r = await fetch(U("/practice/api/workflow/scope/profiles/dimensions?subjectEntity=" + encodeURIComponent(subject)),
                          { credentials: "same-origin" });
      var b = r.ok ? await r.json() : {};
      // Not cached when the call failed, so the next open retries.
      if (r.ok) dimensionsBySubject[subject] = (b && b.rows) || [];
      return (b && b.rows) || [];
    } catch (err) {
      console.error("event-profiles: dimension list failed", err);
      return [];
    }
  }

  async function loadValues(dimensionCode) {
    if (valueCache[dimensionCode]) return valueCache[dimensionCode];
    try {
      var r = await fetch(U("/practice/api/workflow/scope/profiles/dimension-values?organizationId="
              + encodeURIComponent(orgId) + "&dimensionCode=" + encodeURIComponent(dimensionCode)),
              { credentials: "same-origin" });
      var b = r.ok ? await r.json() : {};
      valueCache[dimensionCode] = (b && b.rows) || [];
    } catch (_) {
      valueCache[dimensionCode] = [];
    }
    return valueCache[dimensionCode];
  }

  // ------------------------------------------------------------------
  // Grid
  // ------------------------------------------------------------------
  async function loadList() {
    if (!orgId) return;
    // The menu lives on <body>; re-rendering the grid would otherwise
    // leave it floating with its trigger gone.
    closeRowMenu();
    setBody('<tr><td colspan="7" class="pm-empty">Loading...</td></tr>');
    if (pager) pager.busy(true);

    var qs = new URLSearchParams({
      organizationId: orgId,
      // 407: the Profile Type filter -- ALL, EMPLOYEE (People) or ASSET.
      subjectEntity: el("epProfileType").value || "ALL",
      pageNumber: pager ? pager.page() : 1,
      pageSize: pager ? pager.size() : 25
    });
    var status = el("epStatus").value;
    var search = (el("epSearch").value || "").trim();
    if (status) qs.set("status", status);
    if (search) qs.set("search", search);

    try {
      var r = await fetch(U("/practice/api/workflow/scope/profiles?") + qs.toString(),
                          { credentials: "same-origin" });
      var b = await r.json().catch(function () { return {}; });
      if (!r.ok) {
        if (pager) pager.clear();
        setBody('<tr><td colspan="7" class="pm-empty">' + esc(b.error || ("Load failed (HTTP " + r.status + ")")) + "</td></tr>");
        return;
      }
      var rows = (b && b.rows) || [];
      // TotalRows is COUNT(*) OVER (); reading it removes the
      // rows.length < pageSize guess that is wrong when the last page is
      // exactly full.
      if (pager) pager.setTotal(b.totalRows, rows.length);
      renderRows(rows);
    } catch (err) {
      if (pager) pager.clear();
      setBody('<tr><td colspan="7" class="pm-empty">Failed: ' + esc(err.message) + "</td></tr>");
    }
  }

  function renderRows(rows) {
    var body = el("epBody");
    body.innerHTML = "";

    if (!rows.length) {
      setBody('<tr><td colspan="7" class="pm-empty">'
        + "No profiles yet. Add one to decide which event checklists apply to which people or assets."
        + "</td></tr>");
      return;
    }

    rows.forEach(function (p) {
      var tr = document.createElement("tr");
      if (p.status !== "Active") tr.style.opacity = ".6";

      tr.insertAdjacentHTML("beforeend",
          "<td>" + esc(p.profileName)
            + '<br><span style="font-size:11px; color:var(--fg-subtle);">' + esc(p.profileCode) + "</span></td>"
        + "<td>" + esc(profileTypeLabel(p)) + "</td>"
        + "<td>" + esc(p.description || "") + "</td>"
        + '<td><span style="font-size:12px; color:var(--fg-secondary);">' + esc(p.criteriaSummary || "(none)") + "</span></td>"
        + "<td>" + statusBadge(p.status) + "</td>"
        + "<td>" + checklistCell(p) + "</td>");

      var tdMenu = document.createElement("td");
      tdMenu.appendChild(rowMenu(p));
      tr.appendChild(tdMenu);

      body.appendChild(tr);
    });
  }

  // People / Asset. ProfileType is computed in the database from
  // subject_entity (407); the fallback only covers an API not yet restarted.
  function profileTypeLabel(p) {
    return (p && p.profileType) || SUBJECTS[subjectOf(p && p.subjectEntity)].type;
  }

  function statusBadge(status) {
    var on = status === "Active";
    return '<span style="padding:3px 9px; border-radius:10px; font-size:11px; background:'
      + (on ? "var(--success-100)" : "var(--bg-subtle)") + "; color:" + (on ? "var(--success-700)" : "var(--fg-secondary)") + ';">'
      + esc(status) + "</span>";
  }

  // Two numbers, kept apart for migration 130's reason: how many
  // obligations have been decided at all, and how many of those actually
  // apply. "12 decided, 0 apply" is a legitimate, fully-triaged state and
  // must not look like "not configured".
  function checklistCell(p) {
    var mapped = p.mappedObligationCount || 0;
    var apply = p.applicableObligationCount || 0;
    if (!mapped) {
      return '<span style="font-size:12px; color:var(--warning-700);">Not configured</span>';
    }
    return '<span style="font-size:12px; color:var(--neutral-700);">' + apply + " apply"
      + '<br><span style="color:var(--fg-subtle);">' + mapped + " decided</span></span>";
  }

  // ------------------------------------------------------------------
  // Row actions -- practice.js's .pm-action-trigger / .pm-action-menu
  // pattern, not a menu nested in the cell.
  //
  // The first cut put an absolutely-positioned menu inside the <td>.
  // .pm-table-wrap is overflow:auto, so the open menu extended past the
  // wrapper's box and the TABLE grew a scrollbar instead of the menu
  // overflowing it -- the alignment artefact on screen.
  //
  // practice.js solved this long ago: the menu is appended to
  // document.body, is position:fixed (.pm-action-menu), and is placed
  // from the trigger's bounding rect. Nothing inside the scroll
  // container ever changes size, so no scrollbar appears -- and the menu
  // now looks identical to every other grid in the product.
  // ------------------------------------------------------------------
  function rowMenu(p) {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "pm-action-trigger";
    btn.title = "Actions";
    btn.setAttribute("aria-haspopup", "menu");
    btn.setAttribute("aria-expanded", "false");
    // Both icon spellings, as practice.js emits them: fa-ellipsis-v is
    // Font Awesome 5, fa-ellipsis-vertical is 6.
    btn.innerHTML = '<i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i>'
      + '<span class="visually-hidden">Actions</span>';

    btn.addEventListener("click", function (ev) {
      ev.stopPropagation();
      // Second click on the same trigger closes it.
      if (menuTrigger === btn) { closeRowMenu(); return; }
      openRowMenu(btn, p);
    });

    return btn;
  }

  function openRowMenu(trigger, p) {
    var items = [
      { label: "View",                 icon: "fa-eye",        run: function () { openView(p); } },
      { label: "Edit",                 icon: "fa-pen",        run: function () { openForm(p); } },
      { label: "Configure Checklists", icon: "fa-list-check", run: function () { openConfigure(p); } },
      p.status === "Active"
        ? { label: "Deactivate", icon: "fa-ban",   run: function () { toggleStatus(p); } }
        : { label: "Activate",   icon: "fa-check", run: function () { toggleStatus(p); } }
    ];
    showActionMenu(trigger, items);
  }

  // Shared by the Profiles row menu above and the Checklists row menu
  // below -- one portal-to-body / position / dismiss implementation, not
  // two, per this file's own established pattern (see the note above
  // rowMenu).
  function showActionMenu(trigger, items) {
    closeRowMenu();

    menu = document.createElement("div");
    menu.className = "pm-action-menu";
    menu.setAttribute("role", "menu");

    items.forEach(function (it) {
      var b = document.createElement("button");
      b.type = "button";
      b.setAttribute("role", "menuitem");
      b.innerHTML = '<i class="fa-solid ' + it.icon + '" aria-hidden="true"></i> ' + esc(it.label);
      b.addEventListener("click", function () { closeRowMenu(); it.run(); });
      menu.appendChild(b);
    });

    document.body.appendChild(menu);
    menuTrigger = trigger;
    trigger.setAttribute("aria-expanded", "true");
    positionRowMenu(trigger);
  }

  function positionRowMenu(trigger) {
    if (!menu) return;
    var rect = trigger.getBoundingClientRect();
    var menuRect = menu.getBoundingClientRect();
    var gap = 6;
    var top = rect.bottom + gap;
    var left = rect.right - menuRect.width;
    // Flip above when it would run off the bottom, and clamp sideways --
    // the last row of a full page is exactly where this matters.
    if (top + menuRect.height > window.innerHeight - 8) top = Math.max(8, rect.top - menuRect.height - gap);
    if (left < 8) left = 8;
    if (left + menuRect.width > window.innerWidth - 8) left = window.innerWidth - menuRect.width - 8;
    menu.style.top = top + "px";
    menu.style.left = left + "px";
  }

  function closeRowMenu() {
    if (menuTrigger) menuTrigger.setAttribute("aria-expanded", "false");
    menuTrigger = null;
    if (menu) menu.remove();
    menu = null;
  }

  // ------------------------------------------------------------------
  // Coverage strip -- worst first, because it exists to draw the eye to
  // what has NOT been decided.
  // ------------------------------------------------------------------
  async function loadCoverage() {
    var host = el("epCoverage");
    host.innerHTML = "";
    if (!orgId) return;

    var rows = [];
    try {
      var r = await fetch(U("/practice/api/workflow/scope/obligation-coverage?organizationId="
              + encodeURIComponent(orgId) + "&scopeDimension=PROFILE"), { credentials: "same-origin" });
      if (!r.ok) return;
      var b = await r.json();
      rows = (b && b.rows) || [];
    } catch (_) { return; }

    rows.slice(0, 12).forEach(function (c) {
      var total = c.totalObligations || 0;
      var decided = c.decidedObligations || 0;
      var apply = c.applicableObligations || 0;
      var pct = total ? Math.round(decided * 100 / total) : 0;

      // The percentage is the GAP metric: how much has been triaged.
      // "Fully triaged but nothing applies" is a real state and must not
      // look identical to "fully applicable".
      var bg, fg;
      if (pct === 0)      { bg = "var(--danger-100)"; fg = "var(--danger-700)"; }
      else if (pct < 100) { bg = "var(--warning-100)"; fg = "var(--warning-700)"; }
      else if (apply === 0) { bg = "var(--neutral-200)"; fg = "var(--neutral-700)"; }
      else                { bg = "var(--success-100)"; fg = "var(--success-700)"; }

      var chip = document.createElement("span");
      chip.style.cssText = "padding:4px 10px; border-radius:12px; font-size:12px; background:" + bg + "; color:" + fg + ";";
      chip.textContent = c.scopeValueName + "  " + pct + "%  " + apply + " apply";
      chip.title = decided + " of " + total + " obligations decided; " + apply + " applicable, "
        + (c.excludedObligations || 0) + " excluded"
        + (pct === 100 && apply === 0 ? "  (fully triaged, nothing applies)" : "");
      host.appendChild(chip);
    });
  }

  // ------------------------------------------------------------------
  // Create / Edit
  // ------------------------------------------------------------------
  async function openForm(profile) {
    editing = null;
    el("epFormTitle").textContent = profile ? "Edit Profile" : "Add Profile";
    el("epName").value = "";
    el("epDescription").value = "";
    formMsg(null);

    if (profile) {
      var detail = await fetchProfile(profile.profileId);
      if (!detail) { msg("Could not load that profile.", "error"); return; }
      editing = detail;
      el("epName").value = detail.profileName || "";
      el("epDescription").value = detail.description || "";
      // Status is not on the form. The edited profile's own status is kept
      // on `editing` and sent back unchanged -- see onSubmit.
    }

    // 407: Add starts on People Profile; Edit opens the saved type and
    // locks the other tab (the type is fixed once saved -- the procedure
    // refuses a change too, 67438).
    setFormSubject(editing ? subjectOf(editing.subjectEntity) : "EMPLOYEE", !!editing);

    await renderCriteria(editing);
    schedulePreview();
    showDialog("epFormDialog");
  }

  function closeForm() { hideDialog("epFormDialog"); editing = null; }

  // Activates one Profile Type tab of the Add / Edit dialog. lockOthers is
  // set on Edit, where the saved type is the only one allowed.
  function setFormSubject(subject, lockOthers) {
    formSubject = subjectOf(subject);
    document.querySelectorAll("#epTypeTabs [data-ep-type]").forEach(function (tab) {
      var on = tab.getAttribute("data-ep-type") === formSubject;
      tab.classList.toggle("active", on);
      tab.setAttribute("aria-selected", on ? "true" : "false");
      tab.disabled = !!lockOthers && !on;
      tab.title = tab.disabled ? "The Profile Type of a saved profile cannot be changed." : "";
    });
    el("epCriteriaSubject").textContent = formSubject === "ASSET"
      ? "An asset is in this profile when it matches"
      : "A person is in this profile when they match";
  }
  function closeView() { hideDialog("epViewDialog"); }

  function showDialog(id) {
    var d = el(id);
    if (typeof d.showModal === "function") d.showModal(); else d.setAttribute("open", "open");
  }
  function hideDialog(id) {
    var d = el(id);
    if (typeof d.close === "function") d.close(); else d.removeAttribute("open");
  }

  async function fetchProfile(profileId) {
    try {
      var r = await fetch(U("/practice/api/workflow/scope/profiles/" + encodeURIComponent(profileId)
              + "?organizationId=" + encodeURIComponent(orgId)), { credentials: "same-origin" });
      return r.ok ? await r.json() : null;
    } catch (_) { return null; }
  }

  // One row per dimension, built from the master. No dimension code is
  // named here on purpose -- see the note at the top of the .cshtml.
  async function renderCriteria(detail) {
    var seq = ++criteriaSeq;
    var host = el("epCriteria");
    host.innerHTML = '<div class="pm-empty">Loading criteria...</div>';

    // 407: the active type tab's dimensions.
    var dimensions = await loadDimensions(formSubject);
    if (seq !== criteriaSeq) return;   // a quicker tab switch owns the host now
    host.innerHTML = "";

    if (!dimensions.length) {
      host.innerHTML = '<div class="pm-empty">No criteria dimensions are configured. '
        + "Seed grac_practice.event_profile_dimension_master (migration 329).</div>";
      return;
    }

    var existing = {};
    ((detail && detail.criteria) || []).forEach(function (c) { existing[c.dimensionCode] = c; });

    for (var i = 0; i < dimensions.length; i++) {
      var d = dimensions[i];
      var saved = existing[d.dimensionCode];
      // A dimension the profile has no row for is unconstrained, which is
      // the same thing matchAll means. Defaulting to All keeps the two
      // indistinguishable in the UI as well as in the matcher.
      var isAll = saved ? !!saved.matchAll : true;

      var row = document.createElement("div");
      row.className = "pm-criteria-row";
      row.setAttribute("data-dimension", d.dimensionCode);
      // 407: the criterion this one cascades under (Category -> Sub
      // Category -> Type), straight from the dimension master.
      if (d.parentDimensionCode) row.setAttribute("data-parent-dimension", d.parentDimensionCode);
      row.style.cssText = "display:grid; grid-template-columns:160px 90px 1fr; gap:10px; align-items:start;"
        + " padding:10px 0; border-bottom:1px solid var(--neutral-100);";

      row.insertAdjacentHTML("beforeend",
        '<label style="font-size:13px; color:var(--neutral-700); padding-top:6px;">' + esc(d.dimensionName) + "</label>"
        + '<label style="display:flex; align-items:center; gap:6px; font-size:13px; color:var(--fg-secondary); padding-top:6px;">'
        + '<input type="checkbox" data-ep-all ' + (isAll ? "checked" : "") + " /> All</label>"
        + '<div data-ep-values></div>');

      host.appendChild(row);

      var valuesHost = row.querySelector("[data-ep-values]");
      var allBox = row.querySelector("[data-ep-all]");

      await renderValuePicker(valuesHost, d, saved, isAll);
      if (seq !== criteriaSeq) return;

      /* eslint-disable no-loop-func */
      (function (vh, allCb) {
        allCb.addEventListener("change", function () {
          // Disable the TRIGGER, not the checkboxes: .pm-checkcombo-trigger
          // has its own :disabled styling, and leaving the trigger live
          // would let the menu open on a criterion set to All.
          var trigger = vh.querySelector("[data-checkcombo-trigger]");
          var menu    = vh.querySelector("[data-checkcombo-menu]");
          if (trigger) {
            trigger.disabled = allCb.checked;
            if (allCb.checked) trigger.setAttribute("aria-expanded", "false");
          }
          if (menu && allCb.checked) menu.hidden = true;
          vh.style.opacity = allCb.checked ? ".45" : "1";
          applyCascade();
          schedulePreview();
        });
      })(valuesHost, allBox);
      /* eslint-enable no-loop-func */
    }

    applyCascade();
  }

  // 407: cascading criteria (Asset Category -> Sub Category -> Type).
  // A child only offers values whose ParentId is in its parent's
  // effective set: the parent's picks when it is constrained, else the
  // parent's own offered values (so Type still narrows through a Sub
  // Category left on All). A pick hidden this way is cleared, because
  // it could never match together with the parent's picks. Rows are in
  // display_order, so every parent is settled before its children.
  function applyCascade() {
    var effective = {};   // dimensionCode -> {id: true} or null (unrestricted)
    document.querySelectorAll("#epCriteria .pm-criteria-row").forEach(function (row) {
      var code = row.getAttribute("data-dimension");
      var parentCode = row.getAttribute("data-parent-dimension");
      var allowed = parentCode ? (effective[parentCode] || null) : null;
      var combo = row.querySelector("[data-checkcombo]");
      var isAll = row.querySelector("[data-ep-all]").checked;
      var offered = {}, picked = {}, anyPicked = false;

      if (combo) {
        combo.querySelectorAll("[data-checkcombo-option]").forEach(function (opt) {
          var cb = opt.querySelector('input[type="checkbox"]');
          var parentId = cb.getAttribute("data-parent-id");
          // display, not the hidden attribute: the menu's search box owns
          // `hidden`, and the two filters must not undo each other.
          var show = !allowed || (parentId !== "" && allowed[parentId] === true);
          opt.style.display = show ? "" : "none";
          if (!show && cb.checked) cb.checked = false;
          if (show) offered[cb.value] = true;
          if (show && cb.checked) { picked[cb.value] = true; anyPicked = true; }
        });
        paintComboText(combo);
      }

      effective[code] = (!isAll && anyPicked) ? picked : (allowed ? offered : null);
    });
  }

  // The project's own multi-select: .pm-checkcombo, the same markup
  // practice.js emits for a "comboChecks" field and resolve-workspace uses
  // for its asset filters. practice-management.css already styles the
  // trigger, chips, menu, search box and options, so nothing here sets a
  // colour or a border -- a native <select multiple> was the odd one out on
  // this screen and would drift from the rest of the product on the first
  // theme change.
  //
  // Only the open/close, search and trigger-text handlers are local:
  // practice.js binds its own to its dialog host, which this screen does
  // not live inside.
  async function renderValuePicker(host, dimension, saved, isAll) {
    var selected = {};
    ((saved && saved.values) || []).forEach(function (v) {
      selected[v.valueId != null ? String(v.valueId) : String(v.valueText || "")] = true;
    });

    var values = await loadValues(dimension.dimensionCode);

    if (!values.length) {
      host.innerHTML = '<div style="font-size:12px; color:var(--warning-700); padding-top:7px;">'
        + "No " + esc(dimension.dimensionName.toLowerCase()) + " values exist for this organization yet."
        + "</div>";
      host.style.opacity = isAll ? ".45" : "1";
      return;
    }

    var options = values.map(function (v) {
      var key = v.id != null ? String(v.id) : String(v.textValue || "");
      // Both id and text are carried on the option so the save payload can
      // send whichever the dimension's value_kind expects, without this
      // screen having to know which.
      return '<label data-checkcombo-option>'
        + '<input type="checkbox" value="' + esc(key) + '"'
        + ' data-value-id="' + esc(v.id != null ? String(v.id) : "") + '"'
        + ' data-value-text="' + esc(v.textValue || "") + '"'
        + ' data-parent-id="' + esc(v.parentId != null ? String(v.parentId) : "") + '"'
        + (selected[key] ? " checked" : "") + "> "
        + "<span>" + esc(v.name || key) + "</span></label>";
    }).join("");

    host.innerHTML =
        '<div class="pm-checkcombo" data-checkcombo>'
      +   '<button class="pm-checkcombo-trigger" type="button" data-checkcombo-trigger'
      +     ' aria-expanded="false"' + (isAll ? " disabled" : "") + ">"
      +     "<span data-checkcombo-text></span>"
      +     '<span class="pm-checkcombo-caret" aria-hidden="true">&#9662;</span>'
      +   "</button>"
      +   '<div class="pm-checkcombo-menu" data-checkcombo-menu hidden>'
      +     '<input class="pm-checkcombo-search" type="search" placeholder="Search..." data-checkcombo-search>'
      +     '<div class="pm-checkcombo-options">' + options + "</div>"
      +   "</div>"
      + "</div>";

    var combo = host.querySelector("[data-checkcombo]");
    wireCheckcombo(combo);
    paintComboText(combo);
    host.style.opacity = isAll ? ".45" : "1";
  }

  // Selected values render as chips, not a comma-joined string:
  // .pm-checkcombo-chip and .pm-checkcombo-placeholder are what the
  // stylesheet expects inside [data-checkcombo-text], and a plain string
  // silently loses both.
  function paintComboText(combo) {
    if (!combo) return;
    var slot = combo.querySelector("[data-checkcombo-text]");
    if (!slot) return;

    var picked = combo.querySelectorAll('input[type="checkbox"]:checked');
    if (!picked.length) {
      slot.innerHTML = '<span class="pm-checkcombo-placeholder">Select...</span>';
      return;
    }
    slot.innerHTML = Array.prototype.map.call(picked, function (cb) {
      return '<span class="pm-checkcombo-chip">'
        + esc(cb.closest("label").querySelector("span").textContent.trim())
        + "</span>";
    }).join("");
  }

  function wireCheckcombo(combo) {
    if (!combo) return;
    var trigger = combo.querySelector("[data-checkcombo-trigger]");
    var menu    = combo.querySelector("[data-checkcombo-menu]");
    var search  = combo.querySelector("[data-checkcombo-search]");

    trigger.addEventListener("click", function (ev) {
      ev.preventDefault();
      // Close every other menu first: two open at once reads as the first
      // one having failed to respond.
      document.querySelectorAll("[data-checkcombo-menu]").forEach(function (m) {
        if (m !== menu) m.hidden = true;
      });
      document.querySelectorAll("[data-checkcombo-trigger]").forEach(function (t) {
        if (t !== trigger) t.setAttribute("aria-expanded", "false");
      });
      menu.hidden = !menu.hidden;
      trigger.setAttribute("aria-expanded", menu.hidden ? "false" : "true");
      if (!menu.hidden && search) search.focus();
    });

    combo.addEventListener("change", function (ev) {
      if (!ev.target.closest('input[type="checkbox"]')) return;
      paintComboText(combo);
      applyCascade();
      schedulePreview();
    });

    if (search) search.addEventListener("input", function () {
      var q = this.value.trim().toLowerCase();
      combo.querySelectorAll("[data-checkcombo-option]").forEach(function (opt) {
        opt.hidden = !!q && opt.textContent.toLowerCase().indexOf(q) === -1;
      });
    });

    // mousedown, not click: a click listener fires after the checkbox has
    // already toggled, which closed the menu on every tick.
    document.addEventListener("mousedown", function (ev) {
      if (!combo.contains(ev.target)) {
        menu.hidden = true;
        trigger.setAttribute("aria-expanded", "false");
      }
    });
  }

  function collectCriteria() {
    var out = [];
    document.querySelectorAll("#epCriteria .pm-criteria-row").forEach(function (row) {
      var code = row.getAttribute("data-dimension");
      var all = row.querySelector("[data-ep-all]").checked;

      var values = [];
      if (!all) {
        row.querySelectorAll('[data-ep-values] [data-checkcombo] input[type="checkbox"]:checked')
          .forEach(function (cb) {
            var id = cb.getAttribute("data-value-id");
            var text = cb.getAttribute("data-value-text");
            values.push({
              valueId: id ? Number(id) : null,
              valueText: id ? null : (text || cb.value),
              valueLabel: cb.closest("label").querySelector("span").textContent.trim()
            });
          });
      }
      out.push({ dimensionCode: code, matchAll: all, values: values });
    });
    return out;
  }

  // ------------------------------------------------------------------
  // Live preview. Answers "who does this actually match?" while the
  // criteria are being chosen, rather than weeks later when nobody's
  // onboarding produced a checklist.
  //
  // Only a SAVED profile can be counted exactly -- the matcher reads the
  // stored criteria. While adding, the panel says so instead of showing
  // a number that would be wrong.
  // ------------------------------------------------------------------
  function schedulePreview() {
    clearTimeout(previewTimer);
    previewTimer = setTimeout(runPreview, 300);
  }

  async function runPreview() {
    var host = el("epPreview");
    if (!orgId) return;

    var words = SUBJECTS[formSubject];
    if (!editing || !editing.profileId) {
      host.innerHTML = "Save the profile to see how many " + (formSubject === "ASSET" ? "assets" : "people") + " it matches.";
      return;
    }

    host.textContent = "Counting matching " + words.many + "...";
    try {
      var r = await fetch(U("/practice/api/workflow/scope/profiles/preview?organizationId="
              + encodeURIComponent(orgId) + "&profileId=" + encodeURIComponent(editing.profileId)),
              { credentials: "same-origin" });
      if (!r.ok) { host.textContent = "Could not count matching " + words.many + "."; return; }
      var b = await r.json();

      var names = (b.sample || []).map(function (s) { return s.memberName; }).filter(Boolean);
      if (!b.matchedCount) {
        host.innerHTML = '<strong style="color:var(--danger-700);">This profile currently matches nobody.</strong>'
          + '<br><span style="font-size:12px; color:var(--fg-muted);">It will save, but no checklist will ever fire from it '
          + "until " + words.member + " matches every criterion above.</span>";
        return;
      }
      host.innerHTML = "<strong>" + b.matchedCount + "</strong> of " + b.totalActive
        + " active " + words.many + " match this profile."
        + (names.length ? '<br><span style="font-size:12px; color:var(--fg-muted);">For example: '
            + esc(names.slice(0, 5).join(", ")) + "</span>" : "");
    } catch (err) {
      host.textContent = "Could not count matching " + words.many + ".";
    }
  }

  // ------------------------------------------------------------------
  async function onSubmit(e) {
    e.preventDefault();
    if (!orgId) return;

    var name = (el("epName").value || "").trim();
    if (!name) { formMsg("A profile name is required.", "error"); return; }

    var criteria = collectCriteria();
    var emptyConstrained = criteria.filter(function (c) { return !c.matchAll && !c.values.length; });
    if (emptyConstrained.length) {
      formMsg("\"" + emptyConstrained[0].dimensionCode + "\" is not set to All, so it needs at least one value.", "error");
      return;
    }
    // 407: an edit always saves as its own type -- the tab is locked, and
    // the procedure refuses a change anyway.
    var subject = editing ? subjectOf(editing.subjectEntity) : formSubject;

    el("epFormSave").disabled = true;
    try {
      var r = await fetch(U("/practice/api/workflow/scope/profiles"), {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrf() },
        credentials: "same-origin",
        body: JSON.stringify({
          profileId: editing ? editing.profileId : 0,
          organizationId: Number(orgId),
          profileCode: editing ? editing.profileCode : null,
          profileName: name,
          description: (el("epDescription").value || "").trim() || null,
          subjectEntity: subject,
          // A new profile is always Active; an edited one keeps the status
          // it already had. Never read from the form -- there is no status
          // control, and defaulting an edit to "Active" would silently
          // reactivate a profile somebody had deliberately switched off.
          status: editing ? (editing.status || "Active") : "Active",
          criteria: criteria
        })
      });
      var b = await r.json().catch(function () { return {}; });
      if (!r.ok) { formMsg(b.error || ("Save failed (HTTP " + r.status + ")"), "error"); return; }

      closeForm();
      msg("Profile saved.", "ok");
      setTimeout(function () { msg(null); }, 2000);
      await refreshAll();
    } catch (err) {
      formMsg("Save failed: " + err.message, "error");
    } finally {
      el("epFormSave").disabled = false;
    }
  }

  // ------------------------------------------------------------------
  async function toggleStatus(p) {
    var next = p.status === "Active" ? "Inactive" : "Active";
    try {
      var r = await fetch(U("/practice/api/workflow/scope/profiles/" + encodeURIComponent(p.profileId) + "/status"), {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrf() },
        credentials: "same-origin",
        body: JSON.stringify({ organizationId: Number(orgId), status: next })
      });
      var b = await r.json().catch(function () { return {}; });
      if (!r.ok) { msg(b.error || "Could not change the status.", "error"); return; }

      // Deactivating stops the profile matching from the next raise
      // onwards; instances already raised keep their snapshot. Said out
      // loud so nobody expects open checklists to disappear.
      msg(next === "Active"
        ? "Profile activated. It will be consulted on the next event raised."
        : "Profile deactivated. Checklists already raised from it are unaffected.", "ok");
      setTimeout(function () { msg(null); }, 3000);
      await refreshAll();
    } catch (err) {
      msg("Could not change the status: " + err.message, "error");
    }
  }

  // ------------------------------------------------------------------
  async function openView(p) {
    var detail = await fetchProfile(p.profileId);
    if (!detail) { msg("Could not load that profile.", "error"); return; }

    el("epViewTitle").textContent = detail.profileName;
    var words = SUBJECTS[subjectOf(detail.subjectEntity)];

    var criteriaHtml = (detail.criteria || []).map(function (c) {
      var values = c.matchAll
        ? "<em>All</em>"
        : ((c.values || []).map(function (v) { return esc(v.valueLabel || v.valueText || v.valueId); }).join(", ") || "(none)");
      return "<tr><td>" + esc(c.dimensionName || c.dimensionCode) + "</td><td>" + values + "</td></tr>";
    }).join("");

    el("epViewBody").innerHTML =
        '<p style="font-size:13px; color:var(--fg-secondary); margin:0 0 12px 0;">' + esc(detail.description || "") + "</p>"
      + '<p style="font-size:12px; color:var(--fg-muted); margin:0 0 12px 0;">Code <code>' + esc(detail.profileCode)
      + "</code> &middot; " + esc(profileTypeLabel(detail)) + " Profile &middot; " + statusBadge(detail.status) + "</p>"
      + '<div class="pm-table-wrap"><table><thead><tr><th style="width:180px;">Criterion</th><th>Values</th></tr></thead>'
      + "<tbody>" + (criteriaHtml || '<tr><td colspan="2" class="pm-empty">No criteria.</td></tr>') + "</tbody></table></div>"
      + '<div id="epViewPreview" style="margin-top:12px; font-size:13px; color:var(--neutral-700);">Counting matching ' + words.many + "...</div>";

    showDialog("epViewDialog");

    try {
      var r = await fetch(U("/practice/api/workflow/scope/profiles/preview?organizationId="
              + encodeURIComponent(orgId) + "&profileId=" + encodeURIComponent(p.profileId)),
              { credentials: "same-origin" });
      var host = el("epViewPreview");
      if (!host) return;
      if (!r.ok) { host.textContent = "Could not count matching " + words.many + "."; return; }
      var b = await r.json();
      host.innerHTML = b.matchedCount
        ? "<strong>" + b.matchedCount + "</strong> of " + b.totalActive + " active " + words.many + " match."
        : '<strong style="color:var(--danger-700);">This profile currently matches nobody.</strong>';
    } catch (_) { /* the dialog is still useful without the count */ }
  }

  // ------------------------------------------------------------------
  // Checklists tab (migration 344).
  //
  // One row per obligation+event "checklist" that exists -- catalog,
  // practice-level custom or instance-only custom -- read from
  // sp_event_driven_checklist_list. This is the reverse of the Profiles
  // tab's own Configure Checklists screen: that one maps a Profile to its
  // obligations, this one lists every checklist and, per row, the
  // Profiles mapped to it.
  // ------------------------------------------------------------------
  async function loadChecklists() {
    if (!orgId) return;
    closeRowMenu();
    setEcBody('<tr><td colspan="5" class="pm-empty">Loading...</td></tr>');
    if (ecPager) ecPager.busy(true);

    var qs = new URLSearchParams({
      organizationId: orgId,
      pageNumber: ecPager ? ecPager.page() : 1,
      pageSize: ecPager ? ecPager.size() : 25
    });
    var search = (el("ecSearch").value || "").trim();
    if (search) qs.set("search", search);

    try {
      var r = await fetch(U("/practice/api/workflow/scope/checklists?") + qs.toString(),
                          { credentials: "same-origin" });
      var b = await r.json().catch(function () { return {}; });
      if (!r.ok) {
        if (ecPager) ecPager.clear();
        setEcBody('<tr><td colspan="5" class="pm-empty">' + esc(b.error || ("Load failed (HTTP " + r.status + ")")) + "</td></tr>");
        return;
      }
      var rows = (b && b.rows) || [];
      if (ecPager) ecPager.setTotal(b.totalRows, rows.length);
      renderChecklistRows(rows);
    } catch (err) {
      if (ecPager) ecPager.clear();
      setEcBody('<tr><td colspan="5" class="pm-empty">Failed: ' + esc(err.message) + "</td></tr>");
    }
  }

  function renderChecklistRows(rows) {
    var body = el("ecBody");
    body.innerHTML = "";

    if (!rows.length) {
      setEcBody('<tr><td colspan="5" class="pm-empty">'
        + "No event-driven checklists yet. Tick an obligation in a Profile's or Role's "
        + "Configure Checklists screen to create one."
        + "</td></tr>");
      return;
    }

    rows.forEach(function (row) {
      var tr = document.createElement("tr");

      // Practice Instance means something different per row, on purpose
      // (confirmed design, see the note at the top of the .cshtml): the
      // procedure already picks PracticeInstanceDisplay -- the Practice
      // for a catalog or practice-level row, the real instance only for
      // an instance-only custom row -- so this cell never has to branch
      // on ObligationKind itself.
      tr.insertAdjacentHTML("beforeend",
          "<td>" + esc(row.practiceInstanceDisplay || row.practiceName || "")
            + (row.practiceCode ? '<br><span style="font-size:11px; color:var(--fg-subtle);">' + esc(row.practiceCode) + "</span>" : "")
            + "</td>"
        + "<td>" + esc(row.obligationName || "(untitled obligation)") + checklistKindBadge(row) + "</td>"
        + "<td>" + esc(row.eventTypeName || "")
            + (row.eventDomainName && row.eventDomainName !== row.eventTypeName
                 ? '<br><span style="font-size:11px; color:var(--fg-subtle);">' + esc(row.eventDomainName) + "</span>" : "")
            + "</td>"
        // 408: People / Asset -- same words as the Profiles tab's Profile Type.
        + "<td>" + esc(row.checklistType || "") + "</td>");

      var tdMenu = document.createElement("td");
      tdMenu.appendChild(checklistRowMenu(row));
      tr.appendChild(tdMenu);

      body.appendChild(tr);
    });
  }

  // Organisation-authored obligations (340-344) reach this list exactly
  // like a catalog one -- the badge only tells the admin which kind they
  // are looking at, matching the badge scope-checklist-editor.js shows in
  // Configure Checklists.
  function checklistKindBadge(row) {
    if (!row.obligationKind || row.obligationKind === "Catalog") return "";
    return '<br><span style="color:#6d28d9; font-size:10px; border:1px solid #ddd6fe; background:#f5f3ff;'
      + ' border-radius:3px; padding:0 4px;">Custom</span>';
  }

  function checklistRowMenu(row) {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "pm-action-trigger";
    btn.title = "Actions";
    btn.setAttribute("aria-haspopup", "menu");
    btn.setAttribute("aria-expanded", "false");
    btn.innerHTML = '<i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i>'
      + '<span class="visually-hidden">Actions</span>';

    btn.addEventListener("click", function (ev) {
      ev.stopPropagation();
      if (menuTrigger === btn) { closeRowMenu(); return; }
      showActionMenu(btn, [
        { label: "View Mapped Profiles", icon: "fa-users", run: function () { openMappedProfiles(row); } }
      ]);
    });

    return btn;
  }

  // "Which profiles will receive this checklist" -- read from real
  // event_obligation_applicability rows (sp_event_checklist_mapped_
  // profiles_list), never hardcoded. Reuses the epViewDialog show/hide
  // pattern (its own dialog, #ecMappedDialog).
  async function openMappedProfiles(row) {
    el("ecMappedTitle").textContent = row.obligationName || "Checklist";
    // textContent, not innerHTML -- an HTML entity would render literally, so
    // a plain ASCII separator is used here (openView's own &middot; note
    // above is inside an innerHTML string, a different situation).
    el("ecMappedSubtitle").textContent = [row.eventTypeName, row.practiceInstanceDisplay || row.practiceName]
      .filter(Boolean).join(" - ");
    el("ecMappedBody").innerHTML = '<div class="pm-empty">Loading...</div>';
    showDialog("ecMappedDialog");

    var qs = new URLSearchParams({ organizationId: orgId, eventTypeId: row.eventTypeId });
    // Exactly one of the three -- whichever identity this row carries.
    if (row.obligationId != null) qs.set("obligationId", row.obligationId);
    else if (row.localPracticeObligationId != null) qs.set("localPracticeObligationId", row.localPracticeObligationId);
    else if (row.localInstanceObligationId != null) qs.set("localInstanceObligationId", row.localInstanceObligationId);

    try {
      var r = await fetch(U("/practice/api/workflow/scope/checklist-mapped-profiles?") + qs.toString(),
                          { credentials: "same-origin" });
      var b = await r.json().catch(function () { return {}; });
      if (!r.ok) {
        el("ecMappedBody").innerHTML = '<div class="pm-empty">' + esc(b.error || ("Load failed (HTTP " + r.status + ")")) + "</div>";
        return;
      }
      var mapped = (b && b.rows) || [];
      if (!mapped.length) {
        el("ecMappedBody").innerHTML = '<div class="pm-empty">No profile currently receives this checklist.</div>';
        return;
      }
      el("ecMappedBody").innerHTML =
          '<div class="pm-table-wrap"><table><thead><tr>'
        + "<th>Profile Name</th><th>Description</th><th>Criteria</th><th style=\"width:110px;\">Status</th>"
        + "</tr></thead><tbody>"
        + mapped.map(function (p) {
            return "<tr><td>" + esc(p.profileName)
              + '<br><span style="font-size:11px; color:var(--fg-subtle);">' + esc(p.profileCode) + "</span></td>"
              + "<td>" + esc(p.description || "") + "</td>"
              + '<td><span style="font-size:12px; color:var(--fg-secondary);">' + esc(p.criteriaSummary || "(none)") + "</span></td>"
              + "<td>" + statusBadge(p.status) + "</td></tr>";
          }).join("")
        + "</tbody></table></div>";
    } catch (err) {
      el("ecMappedBody").innerHTML = '<div class="pm-empty">Failed: ' + esc(err.message) + "</div>";
    }
  }

  function closeMappedProfiles() { hideDialog("ecMappedDialog"); }

  // ------------------------------------------------------------------
  // Configure Checklists -- the shared editor, PROFILE scope.
  // ------------------------------------------------------------------
  function openConfigure(p) {
    el("epSharedToolbar").hidden = true;
    el("epRoot").hidden = true;
    el("epConfigure").hidden = false;
    el("epConfigureTitle").textContent = p.profileName;
    el("epConfigureSummary").textContent = p.criteriaSummary || "";

    var host = el("epConfigureHost");
    host.innerHTML = "";

    if (!window.__scopeChecklistEditor) {
      host.innerHTML = '<div class="pm-empty">The checklist editor did not load. '
        + "Refresh the page; if it persists, scope-checklist-editor.js is missing.</div>";
      return;
    }

    // 407: an Asset Profile is still scoped as PROFILE (its decisions are
    // profile rows the raise resolves), but it answers the asset events --
    // the same Commissioning / Decommissioning list the editor already
    // uses for Asset Category, taken from the editor rather than repeated.
    var isAsset = subjectOf(p.subjectEntity) === "ASSET";
    var ed = window.__scopeChecklistEditor;
    ed.render(host, {
      organizationId: orgId,
      scopeDimension: "PROFILE",
      scopeValueId: p.profileId,
      events: isAsset && ed.events ? ed.events[SUBJECTS.ASSET.events] : undefined,
      title: "Event Checklists for this Profile",
      subtitle: isAsset
        ? "Tick the obligations that apply to every asset in this profile when it is commissioned, "
            + "and when it is decommissioned, then press Save changes."
        : "Tick the obligations that apply to everyone in this profile when they join, "
            + "and when they leave, then press Save changes."
    });
  }
})();
