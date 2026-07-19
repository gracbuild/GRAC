(() => {
  "use strict";

  /* ── Globals ── */
  const screen = window.pmScreen || {};
  const appBasePath = () => (window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "");
  const buildAppUrl = path => {
    path = String(path || "");
    if (!path || path === "#") return path || "#";
    if (/^(?:[a-z][a-z0-9+.-]*:)?\/\//i.test(path)) return path;
    return `${appBasePath()}/${path.replace(/^\/+/, "")}`;
  };
  const api = window.pmApi || buildAppUrl("practice-management-gateway");
  const permissions = new Set(window.pmPermissions || []);
  const csrfMeta = document.querySelector('meta[name="csrf-token"]');
  const csrfToken = csrfMeta ? csrfMeta.content : "";
  const canEdit = permissions.has("EDIT") || permissions.has("ADD");

  /* ── State ── */
  let currentView = "month"; // month | week | day
  let currentDate = new Date();
  let events = [];
  let rules = [];
  let config = {};
  let organizations = [];
  let selectedOrgId = "";

  /* ── DOM refs ── */
  const grid = document.getElementById("calGrid");
  const titleEl = document.getElementById("calTitle");
  const orgFilter = document.getElementById("calOrganizationFilter");
  const sidePanel = document.getElementById("calSidePanel");
  const sidePanelBody = document.getElementById("calSideBody");
  const sidePanelTitle = document.getElementById("calSideTitle");

  /* ── Helpers ── */
  const DAYS = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
  const MONTHS = ["January","February","March","April","May","June","July","August","September","October","November","December"];

  function sameDay(a, b) { return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate(); }
  function toDateKey(d) { return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-${String(d.getDate()).padStart(2,"0")}`; }
  function parseDate(s) { if (!s) return null; const d = new Date(s); return isNaN(d) ? null : d; }
  function formatDate(d) { if (!d) return ""; return d.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", year: "numeric" }); }

  async function fetchJson(url, options = {}) {
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 45000);
    let response;
    try { response = await fetch(url, { ...options, signal: options.signal || controller.signal }); }
    catch (error) {
      if (error.name === "AbortError") throw new Error("Service did not respond in time.");
      throw error;
    } finally { window.clearTimeout(timeout); }
    let result;
    try { result = await response.json(); } catch { throw new Error("Invalid response from service."); }
    if (response.status === 401) {
      window.location.assign(`${window.location.origin}${buildAppUrl("Login")}?returnUrl=${encodeURIComponent(window.location.pathname)}`);
      throw new Error("Session expired.");
    }
    if (response.status === 403) throw new Error("You do not have permission.");
    if (response.status === 400) throw new Error(result.message || result.Message || "Invalid request.");
    if (!(result.success ?? result.Success)) throw new Error(result.message || result.Message || "Request failed.");
    return result;
  }

  /* ── API calls ── */
  async function loadCalendarEvents(rangeFrom, rangeTo) {
    const payload = {
      dateFrom: toDateKey(rangeFrom),
      dateTo: toDateKey(rangeTo),
      data: {}
    };
    if (selectedOrgId) payload.data.organizationId = Number(selectedOrgId);
    try {
      const result = await fetchJson(`${api}/assurance-calendar-events/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify(payload)
      });
      const data = result.data ?? result.Data ?? [];
      events = Array.isArray(data[0]) ? data[0] : (Array.isArray(data) ? data : []);
      rules = Array.isArray(data[1]) ? data[1] : [];
      config = Array.isArray(data[2]) && data[2].length > 0 ? data[2][0] : {};

      // Organizations come as 4th result set — avoids needing separate GET /organizations permission
      const orgsData = Array.isArray(data[3]) ? data[3] : [];
      if (orgsData.length > 0 && organizations.length === 0) {
        organizations = orgsData;
        populateOrganizationDropdowns();
      }
    } catch (e) {
      console.warn("Calendar load:", e.message);
      events = []; rules = []; config = {};
    }
  }

  function populateOrganizationDropdowns() {
    orgFilter.innerHTML = '<option value="">All organizations</option>';
    const genOrg = document.getElementById("genOrganization");
    if (genOrg) genOrg.innerHTML = '<option value="">Select organization</option>';
    organizations.forEach(o => {
      const id = o.Id || o.id || o.organization_id;
      const name = o.Name || o.name || o.organization_name || `Org ${id}`;
      orgFilter.insertAdjacentHTML("beforeend", `<option value="${id}">${name}</option>`);
      if (genOrg) genOrg.insertAdjacentHTML("beforeend", `<option value="${id}">${name}</option>`);
    });
    // Auto-select if user has only one organization
    if (organizations.length === 1) {
      const id = organizations[0].Id || organizations[0].id || organizations[0].organization_id;
      orgFilter.value = String(id);
      selectedOrgId = String(id);
    }
  }

  // Reuse the shared `${api}/lookups` endpoint that every other Practice
  // Management screen already relies on for its Organization dropdown, so
  // the calendar filter shows exactly the same list that the practice
  // grids show (and no duplicate endpoint has to be maintained). The
  // shared payload returns rows like { LookupKey: 'organizations',
  // Value: '<org-id>', Label: 'CODE - Name' } -- filter to the
  // organizations key and rehydrate the module-local `organizations`
  // array in the shape populateOrganizationDropdowns() expects.
  async function loadOrganizationsFromLookups() {
    try {
      const result = await fetchJson(`${api}/lookups`);
      const items = result.data ?? result.Data ?? [];
      const rows = Array.isArray(items[0]) ? items[0] : items;
      const orgs = (Array.isArray(rows) ? rows : []).filter(row => {
        const key = row.LookupKey ?? row.lookupKey;
        return key === "organizations";
      }).map(row => ({
        Id:   row.Value ?? row.value,
        Name: row.Label ?? row.label
      }));
      if (orgs.length) {
        organizations = orgs;
        populateOrganizationDropdowns();
      }
    } catch (e) {
      // Non-fatal -- the loadCalendarEvents fallback (4th result set)
      // still gets a chance to fill the dropdown after the first refresh.
      console.warn("Calendar organizations lookup:", e.message);
    }
  }

  async function saveScheduleRule(payload) {
    return fetchJson(`${api}/assurance-schedule-rules`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data: payload })
    });
  }

  async function saveScheduleOverride(payload) {
    return fetchJson(`${api}/assurance-schedule-overrides`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data: payload })
    });
  }

  async function loadPracticeInstances(orgId) {
    try {
      const result = await fetchJson(`${api}/practice-instances/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ data: { organizationId: Number(orgId) } })
      });
      return (result.data ?? result.Data ?? [])[0] ?? (result.data ?? result.Data ?? []);
    } catch { return []; }
  }

  /* ── Rendering: Month View ── */
  function renderMonth() {
    const year = currentDate.getFullYear();
    const month = currentDate.getMonth();
    titleEl.textContent = `${MONTHS[month]} ${year}`;

    const firstDay = new Date(year, month, 1);
    const lastDay = new Date(year, month + 1, 0);
    const startOffset = firstDay.getDay();
    const totalDays = lastDay.getDate();
    const weeks = Math.ceil((startOffset + totalDays) / 7);
    const today = new Date();

    // Build event map by date key
    const eventMap = {};
    events.forEach(ev => {
      const d = parseDate(ev.Date || ev.date);
      if (!d) return;
      const key = toDateKey(d);
      if (!eventMap[key]) eventMap[key] = [];
      eventMap[key].push(ev);
    });

    let html = '<div class="cal-header-row">';
    DAYS.forEach(d => { html += `<div class="cal-header-cell">${d}</div>`; });
    html += '</div>';

    let dayCounter = 1 - startOffset;
    for (let w = 0; w < weeks; w++) {
      html += '<div class="cal-week-row">';
      for (let d = 0; d < 7; d++) {
        const cellDate = new Date(year, month, dayCounter);
        const isOutside = cellDate.getMonth() !== month;
        const isToday = sameDay(cellDate, today);
        const key = toDateKey(cellDate);
        const dayEvents = eventMap[key] || [];

        let cls = "cal-day-cell";
        if (isOutside) cls += " outside-month";
        if (isToday) cls += " today";

        html += `<div class="${cls}" data-date="${key}">`;
        html += `<span class="cal-day-number">${cellDate.getDate()}</span>`;

        // Chip-based rendering: only the first letter is shown, the full
        // task label lives in the native `title` tooltip. Small circular
        // chips let us fit far more items per day than the old text
        // pills, so we lift maxShow accordingly.
        if (dayEvents.length) {
          html += '<div class="cal-event-chips">';
          const chipMax = 6;
          dayEvents.slice(0, chipMax).forEach((ev, idx) => {
            const crit = (ev.Criticality || ev.criticality || "medium").toLowerCase();
            const status = (ev.Status || ev.status || "upcoming").toLowerCase();
            const label = ev.PracticeInstance || ev.practiceInstance || "Assurance";
            const freq = ev.FrequencyName || ev.frequencyName || "";
            const initial = chipInitial(label);
            const tooltip = freq ? `${label} — ${freq}` : label;
            html += `<div class="cal-event cal-event-chip criticality-${crit} status-${status}" data-event-idx="${idx}" data-date="${key}" title="${escapeAttr(tooltip)}" aria-label="${escapeAttr(tooltip)}">${escapeHtml(initial)}</div>`;
          });
          if (dayEvents.length > chipMax) {
            html += `<div class="cal-event-more" data-date="${key}">+${dayEvents.length - chipMax}</div>`;
          }
          html += '</div>';
        }
        html += '</div>';
        dayCounter++;
      }
      html += '</div>';
    }

    grid.className = "cal-grid cal-month-view";
    grid.innerHTML = html;
    attachEventListeners();
  }

  // ── small helpers for chip rendering ─────────────────────────────────
  function chipInitial(label) {
    if (!label) return "?";
    // Prefer the first alphanumeric character of the label; fall back to
    // the raw first char if nothing matches.
    const match = String(label).match(/[A-Za-z0-9]/);
    return (match ? match[0] : String(label).trim().charAt(0) || "?").toUpperCase();
  }
  function escapeHtml(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }
  function escapeAttr(s) {
    return escapeHtml(s);
  }

  /* ── Rendering: Week View ── */
  function renderWeek() {
    const today = new Date();
    const dayOfWeek = currentDate.getDay();
    const weekStart = new Date(currentDate);
    weekStart.setDate(weekStart.getDate() - dayOfWeek);

    const weekEnd = new Date(weekStart);
    weekEnd.setDate(weekEnd.getDate() + 6);
    titleEl.textContent = `${MONTHS[weekStart.getMonth()]} ${weekStart.getDate()} – ${weekEnd.getDate()}, ${weekEnd.getFullYear()}`;

    const eventMap = {};
    events.forEach(ev => {
      const d = parseDate(ev.Date || ev.date);
      if (!d) return;
      const key = toDateKey(d);
      if (!eventMap[key]) eventMap[key] = [];
      eventMap[key].push(ev);
    });

    let html = '<div class="cal-header-row"><div class="cal-header-cell"></div>';
    for (let i = 0; i < 7; i++) {
      const d = new Date(weekStart);
      d.setDate(d.getDate() + i);
      const isToday = sameDay(d, today);
      html += `<div class="cal-week-header-cell${isToday ? " today" : ""}">${DAYS[i]}<span class="cal-week-day-num">${d.getDate()}</span></div>`;
    }
    html += '</div>';

    // All-day events row
    html += '<div class="cal-body"><div class="cal-time-label">All day</div>';
    for (let i = 0; i < 7; i++) {
      const d = new Date(weekStart);
      d.setDate(d.getDate() + i);
      const key = toDateKey(d);
      const isToday = sameDay(d, today);
      const dayEvents = eventMap[key] || [];
      html += `<div class="cal-week-day${isToday ? " today" : ""}" data-date="${key}">`;
      if (dayEvents.length) {
        html += '<div class="cal-event-chips">';
        dayEvents.forEach((ev, idx) => {
          const crit = (ev.Criticality || ev.criticality || "medium").toLowerCase();
          const status = (ev.Status || ev.status || "upcoming").toLowerCase();
          const label = ev.PracticeInstance || ev.practiceInstance || "Assurance";
          const freq = ev.FrequencyName || ev.frequencyName || "";
          const initial = chipInitial(label);
          const tooltip = freq ? `${label} — ${freq}` : label;
          html += `<div class="cal-event cal-event-chip criticality-${crit} status-${status}" data-event-idx="${idx}" data-date="${key}" title="${escapeAttr(tooltip)}" aria-label="${escapeAttr(tooltip)}">${escapeHtml(initial)}</div>`;
        });
        html += '</div>';
      }
      html += '</div>';
    }
    html += '</div>';

    grid.className = "cal-grid cal-week-view";
    grid.innerHTML = html;
    attachEventListeners();
  }

  /* ── Rendering: Day View ── */
  function renderDay() {
    const today = new Date();
    const isToday = sameDay(currentDate, today);
    const key = toDateKey(currentDate);
    titleEl.textContent = `${DAYS[currentDate.getDay()]}, ${MONTHS[currentDate.getMonth()]} ${currentDate.getDate()}, ${currentDate.getFullYear()}`;

    const dayEvents = events.filter(ev => {
      const d = parseDate(ev.Date || ev.date);
      return d && toDateKey(d) === key;
    });

    let html = `<div class="cal-day-header">${isToday ? "Today — " : ""}${formatDate(currentDate)}</div>`;
    html += '<div class="cal-day-events">';
    if (dayEvents.length === 0) {
      html += '<p style="color:var(--grac-muted);font-size:13px;padding:24px 0;">No assurance events scheduled for this day.</p>';
    } else {
      dayEvents.forEach((ev, idx) => {
        const crit = (ev.Criticality || ev.criticality || "medium").toLowerCase();
        const status = (ev.Status || ev.status || "upcoming").toLowerCase();
        const label = ev.PracticeInstance || ev.practiceInstance || "Assurance";
        const freq = ev.FrequencyName || ev.frequencyName || "";
        const owner = ev.Owner || ev.owner || "";
        html += `<div class="cal-event criticality-${crit} status-${status}" data-event-idx="${idx}" data-date="${key}">`;
        html += `<strong>${label}</strong> — ${freq}`;
        if (owner) html += ` · ${owner}`;
        if (ev.IsOverride || ev.isOverride) html += ` · <em>${ev.OverrideType || ev.overrideType || "Modified"}</em>`;
        html += '</div>';
      });
    }
    html += '</div>';

    grid.className = "cal-grid cal-day-view";
    grid.innerHTML = html;
    attachEventListeners();
  }

  /* ── Attach Event Click Listeners ── */
  function attachEventListeners() {
    grid.querySelectorAll(".cal-event").forEach(el => {
      el.addEventListener("click", e => {
        e.stopPropagation();
        const dateKey = el.dataset.date;
        const idx = parseInt(el.dataset.eventIdx, 10);
        const dayEvents = events.filter(ev => {
          const d = parseDate(ev.Date || ev.date);
          return d && toDateKey(d) === dateKey;
        });
        if (dayEvents[idx]) showSidePanel(dayEvents[idx]);
      });
    });
    grid.querySelectorAll(".cal-event-more").forEach(el => {
      el.addEventListener("click", e => {
        e.stopPropagation();
        const dateKey = el.dataset.date;
        const parts = dateKey.split("-");
        currentDate = new Date(+parts[0], +parts[1] - 1, +parts[2]);
        setView("day");
      });
    });
    grid.querySelectorAll(".cal-day-cell").forEach(el => {
      el.addEventListener("click", () => {
        const dateKey = el.dataset.date;
        if (dateKey) {
          const parts = dateKey.split("-");
          currentDate = new Date(+parts[0], +parts[1] - 1, +parts[2]);
          setView("day");
        }
      });
    });
  }

  /* ── Side Panel ── */
  function showSidePanel(ev) {
    sidePanelTitle.textContent = ev.PracticeInstance || ev.practiceInstance || "Event Details";
    const status = ev.Status || ev.status || "Upcoming";
    const statusLower = status.toLowerCase();

    let html = `
      <div class="cal-detail-row"><span class="cal-detail-label">Date</span><span class="cal-detail-value">${formatDate(parseDate(ev.Date || ev.date))}</span></div>
      <div class="cal-detail-row"><span class="cal-detail-label">Frequency</span><span class="cal-detail-value">${ev.FrequencyName || ev.frequencyName || "—"}</span></div>
      <div class="cal-detail-row"><span class="cal-detail-label">Criticality</span><span class="cal-detail-value">${ev.Criticality || ev.criticality || "—"}</span></div>
      <div class="cal-detail-row"><span class="cal-detail-label">Mode</span><span class="cal-detail-value">${ev.AssuranceMode || ev.assuranceMode || "—"}</span></div>
      <div class="cal-detail-row"><span class="cal-detail-label">Owner</span><span class="cal-detail-value">${ev.Owner || ev.owner || "—"}</span></div>
      <div class="cal-detail-row"><span class="cal-detail-label">Status</span><span class="cal-detail-value"><span class="cal-status-dot ${statusLower}"></span>${status}</span></div>`;

    if (ev.IsOverride || ev.isOverride) {
      html += `<div class="cal-detail-row"><span class="cal-detail-label">Override</span><span class="cal-detail-value">${ev.OverrideType || ev.overrideType || "Modified"}</span></div>`;
      if (ev.OriginalDate || ev.originalDate) {
        html += `<div class="cal-detail-row"><span class="cal-detail-label">Original Date</span><span class="cal-detail-value">${formatDate(parseDate(ev.OriginalDate || ev.originalDate))}</span></div>`;
      }
    }

    if (canEdit && statusLower !== "past" && statusLower !== "skipped") {
      html += `<div class="cal-side-actions">
        <button class="pm-button small primary" id="calEditEvent" type="button"><i class="fa-solid fa-pen" aria-hidden="true"></i> Edit Schedule</button>
      </div>`;
    }

    sidePanelBody.innerHTML = html;
    sidePanel.hidden = false;

    const editBtn = document.getElementById("calEditEvent");
    if (editBtn) {
      editBtn.addEventListener("click", () => openEditDialog(ev));
    }
  }

  function closeSidePanel() {
    sidePanel.hidden = true;
  }

  // Compute the valid reschedule window for a task given its current
  // occurrence date and its recurrence frequency. The window is always
  // the frequency's own period so a rescheduled slot never spills into
  // the next occurrence's period.
  //
  //   Weekly       -> Sun..Sat of the current occurrence's week
  //   Monthly      -> 1st..last day of the current occurrence's month
  //   Quarterly    -> 1st day of quarter month .. last day of quarter's
  //                    last month (Q1=Jan-Mar, Q2=Apr-Jun, etc.)
  //   Half yearly  -> H1 = Jan 1 .. Jun 30, H2 = Jul 1 .. Dec 31
  //   Annual/Year  -> Jan 1 .. Dec 31 of the same year
  //   Daily        -> null (caller hides the picker altogether)
  //   Unknown      -> null (no min/max constraint)
  function reschedulePeriodBounds(currentDate, freqRaw) {
    if (!currentDate) return null;
    const f = String(freqRaw || "").trim().toLowerCase();
    const y = currentDate.getFullYear();
    const m = currentDate.getMonth();
    const d = currentDate.getDate();
    const mk = (yy, mm, dd) => new Date(yy, mm, dd);

    if (/^(weekly|week)$/.test(f)) {
      // Sunday-first week to match the calendar grid header (DAYS array).
      const start = new Date(currentDate);
      start.setDate(d - start.getDay());
      const end = new Date(start);
      end.setDate(start.getDate() + 6);
      return { start, end };
    }
    if (/^(monthly|month)$/.test(f)) {
      return { start: mk(y, m, 1), end: mk(y, m + 1, 0) };
    }
    if (/^(quarterly|quarter)$/.test(f)) {
      const qStartMonth = Math.floor(m / 3) * 3;
      return { start: mk(y, qStartMonth, 1), end: mk(y, qStartMonth + 3, 0) };
    }
    if (/^(half\s*[- ]?yearly|semi\s*[- ]?annual(?:ly)?|bi\s*[- ]?annual(?:ly)?)$/.test(f)) {
      // H1: Jan 1 - Jun 30, H2: Jul 1 - Dec 31.
      const startMonth = m < 6 ? 0 : 6;
      const endMonth   = m < 6 ? 5 : 11;
      return { start: mk(y, startMonth, 1), end: mk(y, endMonth + 1, 0) };
    }
    if (/^(yearly|year|annual(?:ly)?)$/.test(f)) {
      return { start: mk(y, 0, 1), end: mk(y, 11, 31) };
    }
    return null;
  }

  /* ── Edit Dialog ── */
  function openEditDialog(ev) {
    closeSidePanel();
    const dialog = document.getElementById("calEditDialog");
    const currentDateObj = parseDate(ev.Date || ev.date);
    document.getElementById("editPracticeInstance").value = ev.PracticeInstance || ev.practiceInstance || "";
    document.getElementById("editCurrentDate").value = toDateKey(currentDateObj);
    const newDateInput = document.getElementById("editNewDate");
    newDateInput.value = "";
    document.getElementById("editReason").value = "";
    document.getElementById("editApplyFuture").checked = false;

    // Rescheduling ("Move to a different date") does not make sense for
    // a daily task -- tomorrow already has its own daily occurrence, so
    // moving today's slot forward would just collide. For daily tasks we
    // hide the Move option, force the Action to Skip, and hide the New
    // Date field. Non-daily tasks keep the previous default of Move.
    const freqRaw = ev.FrequencyType || ev.frequencyType || ev.FrequencyName || ev.frequencyName || "";
    const isDaily = /^\s*(daily|day)\s*$/i.test(String(freqRaw));
    const actionSelect = document.getElementById("editAction");
    const moveOption   = document.getElementById("editActionMoveOption");
    if (moveOption) moveOption.hidden = isDaily;
    if (moveOption) moveOption.disabled = isDaily;
    if (isDaily) {
      actionSelect.value = "Skip";
      document.getElementById("editNewDateField").hidden = true;
    } else {
      actionSelect.value = "Move";
      document.getElementById("editNewDateField").hidden = false;
    }

    // Constrain the New Date picker to the current occurrence's own
    // frequency period. The <input type="date"> min/max attributes tell
    // the native picker to grey out / block anything outside the window
    // so users cannot pick, for example, next month's date when moving
    // a Monthly task.
    const bounds = reschedulePeriodBounds(currentDateObj, freqRaw);
    if (bounds) {
      newDateInput.min = toDateKey(bounds.start);
      newDateInput.max = toDateKey(bounds.end);
    } else {
      newDateInput.removeAttribute("min");
      newDateInput.removeAttribute("max");
    }

    dialog._eventData = ev;
    dialog.showModal();
  }

  /* ── Generate Dialog ── */
  async function openGenerateDialog() {
    const dialog = document.getElementById("calGenerateDialog");
    const genOrg = document.getElementById("genOrganization");
    const instanceList = document.getElementById("genInstanceList");
    document.getElementById("genAnchorDate").value = toDateKey(new Date());
    instanceList.innerHTML = '<p class="pm-empty">Select an organization to see eligible practice instances.</p>';
    dialog.showModal();

    genOrg.onchange = async () => {
      const orgId = genOrg.value;
      if (!orgId) { instanceList.innerHTML = '<p class="pm-empty">Select an organization.</p>'; return; }
      instanceList.innerHTML = '<p class="pm-empty">Loading practice instances...</p>';
      const instances = await loadPracticeInstances(orgId);
      const existingRuleInstanceIds = new Set(rules.map(r => String(r.PracticeInstanceId || r.practice_instance_id)));

      if (!instances.length) { instanceList.innerHTML = '<p class="pm-empty">No practice instances found for this organization.</p>'; return; }

      let html = "";
      instances.forEach(inst => {
        const id = inst.Id || inst.id || inst.practice_instance_id;
        const name = inst.Name || inst.name || inst.instance_name || `Instance ${id}`;
        const code = inst.Code || inst.code || inst.instance_code || "";
        const freq = inst.AssuranceFrequency || inst.assurance_frequency || inst.ExecutionFrequency || "";
        const freqId = inst.AssuranceFrequencyId || inst.assurance_frequency_id || "";
        const alreadyScheduled = existingRuleInstanceIds.has(String(id));
        const disabled = alreadyScheduled || !freqId ? "disabled" : "";
        const rowClass = alreadyScheduled ? "cal-gen-row already-scheduled" : "cal-gen-row";
        const noFreqNote = !freqId && !alreadyScheduled ? ' <em style="color:var(--grac-muted);font-size:11px;">(no assurance frequency set)</em>' : "";
        html += `<div class="${rowClass}">
          <input type="checkbox" value="${id}" data-freq-id="${freqId}" data-org-id="${orgId}" ${disabled} />
          <label>${code ? code + " — " : ""}${name}${noFreqNote}</label>
          <span class="cal-gen-freq">${freq}</span>
        </div>`;
      });
      instanceList.innerHTML = html;
    };
  }

  async function submitGenerate() {
    const dialog = document.getElementById("calGenerateDialog");
    const anchorDate = document.getElementById("genAnchorDate").value;
    const msgEl = document.getElementById("calGenerateMessage");
    const checkboxes = dialog.querySelectorAll('.cal-gen-row input[type="checkbox"]:checked');

    if (!anchorDate) { showMsg(msgEl, "Please select an anchor date."); return; }
    if (checkboxes.length === 0) { showMsg(msgEl, "Please select at least one practice instance."); return; }

    let created = 0;
    let errors = [];
    for (const cb of checkboxes) {
      try {
        await saveScheduleRule({
          practiceInstanceId: cb.value,
          frequencyId: cb.dataset.freqId,
          organizationId: cb.dataset.orgId,
          anchorDate: anchorDate
        });
        created++;
      } catch (e) {
        errors.push(e.message);
      }
    }

    if (errors.length) showMsg(msgEl, `Created ${created} schedule(s). Errors: ${errors.join("; ")}`, errors.length < checkboxes.length);
    else { dialog.close(); await refresh(); }
  }

  function showMsg(el, text, isWarning = false) {
    if (!el) return;
    el.textContent = text;
    el.hidden = false;
    el.className = "pm-message" + (isWarning ? " warning" : " error");
    setTimeout(() => { el.hidden = true; }, 6000);
  }

  /* ── Edit Submit ── */
  async function submitEdit() {
    const dialog = document.getElementById("calEditDialog");
    const ev = dialog._eventData;
    const action = document.getElementById("editAction").value;
    const newDate = document.getElementById("editNewDate").value;
    const reason = document.getElementById("editReason").value;
    const applyFuture = document.getElementById("editApplyFuture").checked;
    const msgEl = document.getElementById("calEditMessage");

    if (action === "Move" && !newDate) { showMsg(msgEl, "Please select a new date."); return; }

    // Belt-and-braces guard: some browsers do not fully enforce the
    // <input type="date"> min / max attributes when a user *types* a
    // value (as opposed to picking one from the calendar popup). Re-check
    // the chosen date against the same reschedulePeriodBounds() window
    // used to configure the picker.
    if (action === "Move") {
      const freqRaw = ev.FrequencyType || ev.frequencyType || ev.FrequencyName || ev.frequencyName || "";
      const bounds = reschedulePeriodBounds(parseDate(ev.Date || ev.date), freqRaw);
      if (bounds) {
        const picked = parseDate(newDate);
        if (!picked || picked < bounds.start || picked > bounds.end) {
          showMsg(msgEl, `New Date must be within the current ${String(freqRaw).toLowerCase() || "occurrence"} period (${toDateKey(bounds.start)} - ${toDateKey(bounds.end)}).`);
          return;
        }
      }
    }

    try {
      await saveScheduleOverride({
        scheduleRuleId: ev.RuleId || ev.ruleId,
        organizationId: selectedOrgId || undefined,
        originalDate: toDateKey(parseDate(ev.Date || ev.date)),
        overrideType: action === "Move" ? "Moved" : "Skipped",
        newDate: action === "Move" ? newDate : null,
        reason: reason,
        applyToFuture: applyFuture
      });
      dialog.close();
      await refresh();
    } catch (e) {
      showMsg(msgEl, e.message);
    }
  }

  /* ── Navigation ── */
  function navigate(direction) {
    if (currentView === "month") {
      currentDate = new Date(currentDate.getFullYear(), currentDate.getMonth() + direction, 1);
    } else if (currentView === "week") {
      currentDate.setDate(currentDate.getDate() + direction * 7);
    } else {
      currentDate.setDate(currentDate.getDate() + direction);
    }
    refresh();
  }

  function goToday() {
    currentDate = new Date();
    refresh();
  }

  function setView(view) {
    currentView = view;
    document.querySelectorAll(".cal-view-toggle .pm-button").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.calView === view);
    });
    refresh();
  }

  /* ── Refresh ── */
  async function refresh() {
    let rangeFrom, rangeTo;
    if (currentView === "month") {
      rangeFrom = new Date(currentDate.getFullYear(), currentDate.getMonth(), 1);
      rangeFrom.setDate(rangeFrom.getDate() - rangeFrom.getDay()); // back to Sunday
      rangeTo = new Date(currentDate.getFullYear(), currentDate.getMonth() + 1, 0);
      rangeTo.setDate(rangeTo.getDate() + (6 - rangeTo.getDay())); // forward to Saturday
    } else if (currentView === "week") {
      rangeFrom = new Date(currentDate);
      rangeFrom.setDate(rangeFrom.getDate() - rangeFrom.getDay());
      rangeTo = new Date(rangeFrom);
      rangeTo.setDate(rangeTo.getDate() + 6);
    } else {
      rangeFrom = new Date(currentDate);
      rangeTo = new Date(currentDate);
    }
    await loadCalendarEvents(rangeFrom, rangeTo);
    render();
  }

  function render() {
    if (currentView === "month") renderMonth();
    else if (currentView === "week") renderWeek();
    else renderDay();
  }

  /* ── Wire up events ── */
  document.getElementById("calPrev")?.addEventListener("click", () => navigate(-1));
  document.getElementById("calNext")?.addEventListener("click", () => navigate(1));
  document.getElementById("calToday")?.addEventListener("click", goToday);
  document.getElementById("calSideClose")?.addEventListener("click", closeSidePanel);

  document.querySelectorAll(".cal-view-toggle .pm-button").forEach(btn => {
    btn.addEventListener("click", () => setView(btn.dataset.calView));
  });

  orgFilter?.addEventListener("change", () => {
    selectedOrgId = orgFilter.value;
    refresh();
  });

  document.getElementById("calGenerate")?.addEventListener("click", openGenerateDialog);
  document.getElementById("calGenerateClose")?.addEventListener("click", () => document.getElementById("calGenerateDialog").close());
  document.getElementById("calGenerateCancel")?.addEventListener("click", () => document.getElementById("calGenerateDialog").close());
  document.getElementById("calGenerateSubmit")?.addEventListener("click", submitGenerate);

  document.getElementById("calEditClose")?.addEventListener("click", () => document.getElementById("calEditDialog").close());
  document.getElementById("calEditCancel")?.addEventListener("click", () => document.getElementById("calEditDialog").close());
  document.getElementById("calEditSubmit")?.addEventListener("click", submitEdit);

  document.getElementById("editAction")?.addEventListener("change", e => {
    document.getElementById("editNewDateField").hidden = e.target.value === "Skip";
  });

  // Close side panel on Escape
  document.addEventListener("keydown", e => {
    if (e.key === "Escape") closeSidePanel();
  });

  /* ── Init ── */
  (async () => {
    // Step 1: populate the Organization filter + Generate Schedule modal
    // dropdown from the shared `${api}/lookups` endpoint -- same API the
    // rest of Practice Management uses, so the calendar sees exactly the
    // set of orgs the user is entitled to. If lookups auto-selects a
    // single org, selectedOrgId is already set before the first calendar
    // fetch, so we don't need a second round-trip.
    await loadOrganizationsFromLookups();

    // Step 2: fetch events. loadCalendarEvents still checks the response
    // for an embedded organizations result set (legacy path) and will
    // populate the dropdowns from there if lookups came back empty.
    await refresh();
    if (selectedOrgId && organizations.length !== 1) {
      // Only re-fetch when the org was set by the events-response
      // fallback (not by lookups' single-org auto-select, which already
      // filtered the first fetch).
      await refresh();
    }
  })();
})();
