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

  // Task Calendar -- Scheduler Edit Permission (change request 2026-09-23):
  // canEdit above is the screen-level EDIT/ADD grant (same for every row);
  // isSchedulerOwner() is the additional per-row gate -- only the Practice
  // Instance Owner (or a system admin) may edit a given scheduler. Backend
  // also enforces this (PracticeRepositoryService.ExecuteAsync, entityType
  // 'assurance-schedule-overrides') so this is the UI-side mirror, applied
  // wherever Edit Schedule can be reached: the Calendar side panel button
  // and the Scheduler List row menu.
  const sessionEmployeeId = String(window.pmEmployeeId || "");
  const isSystemAdmin = !!window.pmIsSystemAdmin;
  function isSchedulerOwner(ownerEmployeeId) {
    if (isSystemAdmin) return true;
    if (!sessionEmployeeId) return false;
    const owner = ownerEmployeeId === null || ownerEmployeeId === undefined ? "" : String(ownerEmployeeId);
    return owner !== "" && owner === sessionEmployeeId;
  }

  /* ── State ── */
  let currentView = "month"; // month | week | day
  // Display mode -- independent of currentView. Both modes render the same
  // `events` array (see refresh()/render()); List never triggers its own
  // fetch, so Calendar and List always show the same underlying data.
  let currentMode = "calendar"; // calendar | list
  let currentDate = new Date();
  let events = [];
  let rules = [];
  let config = {};
  let organizations = [];
  let selectedOrgId = "";

  /* Calendar filter state (Status / Criticality / Search).
     Persisted to localStorage per user so returning to the page restores
     the same view. */
  // v3 (migration 336-340): this screen is purely the audit-schedule
  // calendar. It shows only the two obligation-driven schedule types --
  // Execution and Assurance -- and has no module selector, so sourceModules
  // is no longer part of the (persisted) filter state. Key bumped so a v2
  // set carrying the old module list is dropped.
  const LS_FILTERS_KEY = "pmCalFilters.v3";
  // Fixed source-module set for every calendar query. Sending exactly these
  // makes the API skip the five Assurance-Management module blocks (their
  // WantsModule gate is false) -- so Plan / Plan Item / Audit Execution /
  // Observation / Gap never reach this calendar, and only the audit schedule
  // (Execution + Assurance) does.
  const CALENDAR_MODULES = ["Execution", "Assurance"];
  let filters = loadFilterState();

  function loadFilterState() {
    try {
      const raw = localStorage.getItem(LS_FILTERS_KEY);
      if (!raw) return defaultFilters();
      const parsed = JSON.parse(raw);
      return {
        statuses       : Array.isArray(parsed.statuses)       ? parsed.statuses       : [],
        criticalities  : Array.isArray(parsed.criticalities)  ? parsed.criticalities  : [],
        search         : typeof parsed.search === "string" ? parsed.search : ""
      };
    } catch { return defaultFilters(); }
  }
  function defaultFilters() {
    return {
      statuses       : [],
      criticalities  : [],
      search         : ""
    };
  }
  function saveFilterState() {
    try { localStorage.setItem(LS_FILTERS_KEY, JSON.stringify(filters)); }
    catch { /* quota / private-mode -- non-fatal */ }
  }

  /* ── DOM refs ── */
  const grid = document.getElementById("calGrid");
  const listView = document.getElementById("calListView");
  const navHeader = document.getElementById("calNavHeader");
  // Event-oriented filter panel (Status / Criticality / Search). It narrows
  // the calendar's occurrence set, not the scheduler-config rows -- so it is
  // hidden in List mode, where the Scheduler List carries its own search over
  // `rules` (see renderList / setMode).
  const filterPanel = document.getElementById("calFilterPanel");
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
  function formatDate(d) { if (!d) return ""; return (window.gracFormatDisplayDateObj ? window.gracFormatDisplayDateObj(d) : d.toDateString()); }

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
    // Same reasoning as practice.js fetchJson: a non-JSON body from a JSON
    // endpoint is a server-side crash, so name the status rather than
    // hiding it, and let a 403 speak for itself — the gateway's message
    // says which grant is missing.
    try { result = await response.json(); }
    catch { throw new Error(`Invalid response from service (HTTP ${response.status}). Check the Practice Management Web log for this request.`); }
    if (response.status === 401) {
      window.location.assign(`${window.location.origin}${buildAppUrl("Login")}?returnUrl=${encodeURIComponent(window.location.pathname)}`);
      throw new Error("Session expired.");
    }
    if (response.status === 403) throw new Error(result.message || result.Message || "You do not have permission.");
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

    // Audit-schedule calendar: always scope to the two schedule types. This
    // is fixed, not user-selectable -- sending it makes the API skip the five
    // Assurance-Management module blocks entirely (WantsModule gate false), so
    // only Execution + Assurance occurrences come back. Status / criticality /
    // search stay as user filters below (empty array = no restriction).
    payload.data.sourceModules = CALENDAR_MODULES;
    if (filters.statuses && filters.statuses.length)
      payload.data.statuses = filters.statuses;
    if (filters.criticalities && filters.criticalities.length)
      payload.data.criticalities = filters.criticalities;
    if (filters.search && filters.search.trim())
      payload.data.search = filters.search.trim();
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
    organizations.forEach(o => {
      const id = o.Id || o.id || o.organization_id;
      const name = o.Name || o.name || o.organization_name || `Org ${id}`;
      orgFilter.insertAdjacentHTML("beforeend", `<option value="${id}">${name}</option>`);
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

  async function saveScheduleOverride(payload) {
    return fetchJson(`${api}/assurance-schedule-overrides`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data: payload })
    });
  }

  /* ── Rendering: Month View ── */
  function renderMonth() {
    const year = currentDate.getFullYear();
    const month = currentDate.getMonth();

    const firstDay = new Date(year, month, 1);
    const lastDay = new Date(year, month + 1, 0);
    const startOffset = firstDay.getDay();
    const totalDays = lastDay.getDate();
    const weeks = Math.ceil((startOffset + totalDays) / 7);
    const today = new Date();

    // Split events into point-events (rendered as chips inside day cells)
    // and range-events (rendered as spanning bars overlaid on the week
    // row). Range = an event with an EndDate later than its StartDate.
    const pointMap = {};
    const rangeEvents = [];
    events.forEach(ev => {
      const start = parseDate(ev.StartDate || ev.startDate || ev.Date || ev.date);
      if (!start) return;
      const end = parseDate(ev.EndDate || ev.endDate);
      const isRange = (ev.IsRange || ev.isRange) === true && end && end.getTime() > start.getTime();
      if (isRange) {
        rangeEvents.push({ ev, start, end });
      } else {
        const key = toDateKey(start);
        if (!pointMap[key]) pointMap[key] = [];
        pointMap[key].push(ev);
      }
    });

    let html = '<div class="cal-header-row">';
    DAYS.forEach(d => { html += `<div class="cal-header-cell">${d}</div>`; });
    html += '</div>';

    let dayCounter = 1 - startOffset;
    for (let w = 0; w < weeks; w++) {
      // Compute this week's Sun..Sat range so we know which range-events
      // intersect it. Then lay each intersecting event onto a "lane"
      // (row inside the range-bar layer) using a simple greedy packing.
      const weekStart = new Date(year, month, dayCounter);
      const weekEnd = new Date(year, month, dayCounter + 6);
      const weekEndInclusive = new Date(weekEnd);
      weekEndInclusive.setHours(23, 59, 59, 999);
      const barsThisWeek = rangeEvents
        .filter(r => r.start <= weekEndInclusive && r.end >= weekStart)
        .map(r => {
          const clippedStart = r.start < weekStart ? weekStart : r.start;
          const clippedEnd   = r.end   > weekEnd   ? weekEnd   : r.end;
          const startCol = Math.round((clippedStart - weekStart) / 86400000); // 0..6
          const endCol   = Math.round((clippedEnd   - weekStart) / 86400000); // 0..6
          return {
            ev: r.ev,
            startCol,
            endCol,
            continuesLeft:  r.start < weekStart,
            continuesRight: r.end   > weekEnd
          };
        })
        .sort((a, b) => (a.startCol - b.startCol) || (b.endCol - a.endCol));

      // Greedy lane packing so overlapping bars stack.
      const lanes = []; // lanes[i] = array of bars in that lane
      barsThisWeek.forEach(bar => {
        let placed = false;
        for (let i = 0; i < lanes.length; i++) {
          const last = lanes[i][lanes[i].length - 1];
          if (last.endCol < bar.startCol) {
            lanes[i].push(bar);
            bar.lane = i;
            placed = true;
            break;
          }
        }
        if (!placed) { bar.lane = lanes.length; lanes.push([bar]); }
      });

      let rowClass = "cal-week-row";
      if (lanes.length === 1) rowClass += " has-bars";
      else if (lanes.length === 2) rowClass += " has-bars-2";
      else if (lanes.length === 3) rowClass += " has-bars-3";
      else if (lanes.length >= 4) rowClass += " has-bars-many";

      html += `<div class="${rowClass}">`;

      // Range bars: absolutely-positioned overlay across the 7-col grid.
      if (barsThisWeek.length) {
        html += `<div class="cal-range-bar-layer" style="grid-template-rows: repeat(${Math.min(lanes.length, 4)}, 18px);">`;
        barsThisWeek.slice(0, 12).forEach((bar, idx) => {
          const ev = bar.ev;
          const src = (ev.SourceModule || ev.sourceModule || "Assurance");
          const kind = (ev.StatusKind || ev.statusKind || "info").toLowerCase();
          const title = ev.Title || ev.title || ev.PracticeInstance || "";
          const subtitle = ev.Subtitle || ev.subtitle || "";
          const tooltip = subtitle ? `${title} — ${subtitle}` : title;
          let barCls = `cal-range-bar source-${src} status-kind-${kind}`;
          if (bar.continuesLeft)  barCls += " cal-range-bar-continues-left";
          if (bar.continuesRight) barCls += " cal-range-bar-continues-right";
          const laneRow = Math.min(bar.lane, 3) + 1;   // 1-indexed
          const gridCol = `${bar.startCol + 1} / ${bar.endCol + 2}`; // grid-column end is exclusive
          html += `<div class="${barCls}" data-range-event-idx="${idx}" data-week-index="${w}" style="grid-row:${laneRow}; grid-column:${gridCol};" title="${escapeAttr(tooltip)}" aria-label="${escapeAttr(tooltip)}">${escapeHtml(title)}</div>`;
        });
        html += '</div>';
      }

      for (let d = 0; d < 7; d++) {
        const cellDate = new Date(year, month, dayCounter);
        const isOutside = cellDate.getMonth() !== month;
        const isToday = sameDay(cellDate, today);
        const key = toDateKey(cellDate);
        const dayEvents = pointMap[key] || [];

        let cls = "cal-day-cell";
        if (isOutside) cls += " outside-month";
        if (isToday) cls += " today";

        html += `<div class="${cls}" data-date="${key}">`;
        html += `<span class="cal-day-number">${cellDate.getDate()}</span>`;

        if (dayEvents.length) {
          html += '<div class="cal-event-chips">';
          const chipMax = 6;
          dayEvents.slice(0, chipMax).forEach((ev, idx) => {
            const crit = (ev.Criticality || ev.criticality || "medium").toLowerCase();
            const status = (ev.Status || ev.status || "upcoming").toLowerCase();
            const src = ev.SourceModule || ev.sourceModule || "Assurance";
            const kind = (ev.StatusKind || ev.statusKind || "info").toLowerCase();
            const label = ev.Title || ev.title || ev.PracticeInstance || ev.practiceInstance || "Audit";
            const subtitle = ev.Subtitle || ev.subtitle || ev.FrequencyName || ev.frequencyName || "";
            const initial = chipInitial(label);
            const tooltip = subtitle ? `${label} — ${subtitle}` : label;
            html += `<div class="cal-event cal-event-chip source-${src} criticality-${crit} status-${status} status-kind-${kind}" data-event-idx="${idx}" data-date="${key}" title="${escapeAttr(tooltip)}" aria-label="${escapeAttr(tooltip)}">${escapeHtml(initial)}</div>`;
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
    // Stash the range map so the event listener can find bars by index/week.
    window.__pmCalRangeWeeks = grid.__rangeWeeks = grid.__rangeWeeks; // no-op
    grid.__rangeWeeks = null; // range bars carry data attrs -- no separate map needed
    attachEventListeners();
    // Bars aren't in .cal-event, wire them here (rebound on every render).
    grid.querySelectorAll(".cal-range-bar").forEach(el => {
      el.addEventListener("click", e => {
        e.stopPropagation();
        const wIdx = Number(el.dataset.weekIndex);
        const rIdx = Number(el.dataset.rangeEventIdx);
        // Recompute the same barsThisWeek slice we used at render time so
        // the click delivers the exact same event object.
        const weekStartClk = new Date(year, month, 1 - startOffset + wIdx * 7);
        const weekEndClk   = new Date(year, month, 1 - startOffset + wIdx * 7 + 6);
        const weekEndIncl  = new Date(weekEndClk); weekEndIncl.setHours(23,59,59,999);
        const bars = rangeEvents
          .filter(r => r.start <= weekEndIncl && r.end >= weekStartClk);
        if (bars[rIdx]) showSidePanel(bars[rIdx].ev);
      });
    });
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

  // Shared event-shape helpers -- used by the side panel AND the List
  // View so both read the same event the same way (see showSidePanel()
  // and renderList() below). Keeping this in one place instead of two
  // near-identical inline blocks.
  const SOURCE_LABELS = {
    Execution:             "Execution",
    Assurance:             "Assurance",
    AssurancePlan:         "Plan",
    AssurancePlanItem:     "Plan Item",
    AssuranceExecution:    "Audit Execution",
    AssuranceObservation:  "Observation",
    AssuranceGap:          "Gap"
  };
  // Obligation schedule occurrences always carry a SourceModule (Execution /
  // Assurance) from the API; the old "PracticeInstance" default is gone.
  function sourceModuleOf(ev) { return ev.SourceModule || ev.sourceModule || "Assurance"; }
  function sourceLabelOf(ev) { const src = sourceModuleOf(ev); return SOURCE_LABELS[src] || src; }
  function ownerLabelOf(ev) {
    const ownerRole = ev.OwnerRoleName || ev.ownerRoleName || "";
    const ownerEmp = ev.OwnerDisplayName || ev.ownerDisplayName || ev.Owner || ev.owner || "";
    return ownerRole && ownerEmp ? `${ownerRole} (${ownerEmp})` : (ownerRole || ownerEmp || "—");
  }
  // Short reference code for the List View's Task ID column. Built only
  // from ids the assurance-calendar-events endpoint already returns
  // (SourceRefId for the 5 Assurance modules, RuleId/PracticeInstanceId
  // for Practice Instance occurrences) -- no new id, no schema change.
  const REF_PREFIXES = {
    Execution:            "EXE",
    Assurance:            "ASR",
    AssurancePlan:        "PLN",
    AssurancePlanItem:    "ITM",
    AssuranceExecution:   "AEX",
    AssuranceObservation: "OBS",
    AssuranceGap:         "GAP"
  };
  function eventRefCode(ev) {
    const src = sourceModuleOf(ev);
    const prefix = REF_PREFIXES[src] || src.slice(0, 3).toUpperCase();
    const id = ev.SourceRefId ?? ev.sourceRefId ?? ev.RuleId ?? ev.ruleId
             ?? ev.PracticeInstanceId ?? ev.practiceInstanceId;
    return (id === undefined || id === null) ? "—" : `${prefix}-${id}`;
  }
  // "10 Sep 2026" -- matches the List View's date-group heading format.
  function formatListDate(d) {
    if (!d) return "";
    return (window.gracFormatDisplayDateObj
      ? window.gracFormatDisplayDateObj(d)
      : `${d.getDate()} ${MONTHS[d.getMonth()].slice(0, 3)} ${d.getFullYear()}`);
  }

  /* ── Rendering: Week View ── */
  function renderWeek() {
    const today = new Date();
    const dayOfWeek = currentDate.getDay();
    const weekStart = new Date(currentDate);
    weekStart.setDate(weekStart.getDate() - dayOfWeek);

    const weekEnd = new Date(weekStart);
    weekEnd.setDate(weekEnd.getDate() + 6);

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
          const label = ev.PracticeInstance || ev.practiceInstance || "Audit";
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

    const dayEvents = events.filter(ev => {
      const d = parseDate(ev.Date || ev.date);
      return d && toDateKey(d) === key;
    });

    let html = `<div class="cal-day-header">${isToday ? "Today — " : ""}${formatDate(currentDate)}</div>`;
    html += '<div class="cal-day-events">';
    if (dayEvents.length === 0) {
      html += '<p style="color:var(--grac-muted);font-size:13px;padding:24px 0;">No audit events scheduled for this day.</p>';
    } else {
      dayEvents.forEach((ev, idx) => {
        const crit = (ev.Criticality || ev.criticality || "medium").toLowerCase();
        const status = (ev.Status || ev.status || "upcoming").toLowerCase();
        const label = ev.PracticeInstance || ev.practiceInstance || "Audit";
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
    const title = ev.Title || ev.title || ev.PracticeInstance || ev.practiceInstance || "Event Details";
    sidePanelTitle.textContent = title;
    const status = ev.Status || ev.status || "Upcoming";
    const statusLower = status.toLowerCase();
    const src = sourceModuleOf(ev);
    const srcLabel = sourceLabelOf(ev);
    const subtitle = ev.Subtitle || ev.subtitle || "";
    const startDate = parseDate(ev.StartDate || ev.startDate || ev.Date || ev.date);
    const endDate = parseDate(ev.EndDate || ev.endDate);
    const entity = ev.EntityLabel || ev.entityLabel || "";
    const defCode = ev.DefinitionCode || ev.definitionCode || "";
    const ownerLabel = ownerLabelOf(ev);
    // Linked Task Centre task (Gap / Observation events only -- see
    // PracticeRepositoryService.QueryCalendarEventsAsync). Absent for
    // every other module, so this stays a no-op for them.
    const linkedTaskNumber = ev.LinkedTaskNumber || ev.linkedTaskNumber;
    const linkedTaskStatus = ev.LinkedTaskStatus || ev.linkedTaskStatus;
    const linkedTaskDeepLink = ev.LinkedTaskDeepLink || ev.linkedTaskDeepLink;

    let html = `<div class="cal-side-source-badge source-${src}"><i class="fa-solid fa-tag" aria-hidden="true"></i>${escapeHtml(srcLabel)}</div>`;
    if (subtitle) html += `<div style="color:var(--grac-muted, #758095); font-size:12px; margin-bottom:10px;">${escapeHtml(subtitle)}</div>`;
    html += `<div class="cal-detail-row"><span class="cal-detail-label">Date</span><span class="cal-detail-value">${formatDate(startDate)}${endDate && endDate.getTime() !== (startDate ? startDate.getTime() : 0) ? " → " + formatDate(endDate) : ""}</span></div>`;
    if (ev.FrequencyName || ev.frequencyName) html += `<div class="cal-detail-row"><span class="cal-detail-label">Cadence</span><span class="cal-detail-value">${escapeHtml(ev.FrequencyName || ev.frequencyName)}</span></div>`;
    if (defCode) html += `<div class="cal-detail-row"><span class="cal-detail-label">Definition</span><span class="cal-detail-value">${escapeHtml(defCode)}</span></div>`;
    if (entity) html += `<div class="cal-detail-row"><span class="cal-detail-label">Context</span><span class="cal-detail-value">${escapeHtml(entity)}</span></div>`;
    html += `<div class="cal-detail-row"><span class="cal-detail-label">Criticality</span><span class="cal-detail-value">${escapeHtml(ev.Criticality || ev.criticality || "—")}</span></div>`;
    if (ev.AssuranceMode || ev.assuranceMode) html += `<div class="cal-detail-row"><span class="cal-detail-label">Mode</span><span class="cal-detail-value">${escapeHtml(ev.AssuranceMode || ev.assuranceMode)}</span></div>`;
    html += `<div class="cal-detail-row"><span class="cal-detail-label">Owner</span><span class="cal-detail-value">${escapeHtml(ownerLabel)}</span></div>`;
    html += `<div class="cal-detail-row"><span class="cal-detail-label">Status</span><span class="cal-detail-value"><span class="cal-status-dot ${statusLower}"></span>${escapeHtml(status)}</span></div>`;
    if (linkedTaskNumber) {
      html += `<div class="cal-detail-row"><span class="cal-detail-label">Task</span><span class="cal-detail-value">${escapeHtml(linkedTaskNumber)}${linkedTaskStatus ? ` <span style="color:var(--grac-muted, #758095);">(${escapeHtml(linkedTaskStatus)})</span>` : ""}</span></div>`;
    }

    if (ev.IsOverride || ev.isOverride) {
      html += `<div class="cal-detail-row"><span class="cal-detail-label">Override</span><span class="cal-detail-value">${escapeHtml(ev.OverrideType || ev.overrideType || "Modified")}</span></div>`;
      if (ev.OriginalDate || ev.originalDate) {
        html += `<div class="cal-detail-row"><span class="cal-detail-label">Original Date</span><span class="cal-detail-value">${formatDate(parseDate(ev.OriginalDate || ev.originalDate))}</span></div>`;
      }
    }

    // Action row: a schedule occurrence (Execution / Assurance -- it carries
    // a RuleId) keeps the "Edit Schedule" button, which now only offers an
    // Execution Date change (Skip This Occurrence was removed, change
    // request 2026-09-23). The five Assurance-Management modules are not
    // rule-based, so they get only the "Open in Assurance" deep link into
    // the module page instead.
    const isScheduleOccurrence = (ev.RuleId ?? ev.ruleId) != null;
    const freqForEdit = ev.FrequencyType || ev.frequencyType || ev.FrequencyName || ev.frequencyName || "";
    // Task Calendar Scheduler Edit Permission (2026-09-23): only the
    // Practice Instance Owner (or a system admin) sees the Edit trigger.
    const occurrenceOwnerId = ev.OwnerEmployeeId ?? ev.ownerEmployeeId;
    html += `<div class="cal-side-actions">`;
    if (canEdit && isScheduleOccurrence && statusLower !== "past" && statusLower !== "skipped" && !isDailyFrequency(freqForEdit) && isSchedulerOwner(occurrenceOwnerId)) {
      html += `<button class="pm-button small primary" id="calEditEvent" type="button"><i class="fa-solid fa-pen" aria-hidden="true"></i> Edit Schedule</button>`;
    }
    const deep = ev.DeepLink || ev.deepLink;
    if (deep && !isScheduleOccurrence) {
      html += `<a class="cal-side-deep-link" href="${escapeAttr(buildAppUrl(deep.replace(/^\//, "")))}" target="_blank" rel="noopener"><i class="fa-solid fa-arrow-up-right-from-square" aria-hidden="true"></i>${escapeHtml(`Open ${srcLabel}`)}</a>`;
    }
    if (linkedTaskNumber && linkedTaskDeepLink) {
      html += `<a class="cal-side-deep-link" href="${escapeAttr(buildAppUrl(linkedTaskDeepLink.replace(/^\//, "")))}" target="_blank" rel="noopener"><i class="fa-solid fa-list-check" aria-hidden="true"></i>Open Task ${escapeHtml(linkedTaskNumber)}</a>`;
    }
    html += `</div>`;

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
  // Task Calendar Edit Scheduler (change request 2026-09-23): a daily
  // occurrence was already excluded from rescheduling before this change
  // -- "tomorrow already has its own daily occurrence, so moving today's
  // slot forward would just collide" (openEditDialog's own prior
  // reasoning, see below). Now that Skip This Occurrence is gone too, a
  // daily occurrence has no valid edit left at all, so Edit Schedule is
  // withheld for it wherever it is offered (side panel button, Scheduler
  // List row menu) rather than opening a dialog with nothing it can do.
  function isDailyFrequency(freqRaw) {
    return /^\s*(daily|day)\s*$/i.test(String(freqRaw || ""));
  }

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
  // Task Calendar Edit Scheduler (change request 2026-09-23): Skip This
  // Occurrence is gone, so the only editable field left is the Execution
  // Date -- there is no more Action select to drive. Reason and "apply
  // to all future occurrences" are unchanged (confirmed with the
  // requester, not assumed). A daily occurrence is withheld from every
  // caller (side panel button, Scheduler List row menu) before this ever
  // runs; the guard below stays only as a defensive backstop.
  function openEditDialog(ev) {
    const freqRaw = ev.FrequencyType || ev.frequencyType || ev.FrequencyName || ev.frequencyName || "";
    if (isDailyFrequency(freqRaw)) return;
    // Task Calendar Scheduler Edit Permission (2026-09-23): defensive
    // re-check, same as the isDailyFrequency guard above -- both trigger
    // points (side panel button, Scheduler List row menu) already gate on
    // this, but the dialog refuses to open for a non-owner regardless of
    // how it was reached.
    if (!isSchedulerOwner(ev.OwnerEmployeeId ?? ev.ownerEmployeeId)) return;

    closeSidePanel();
    const dialog = document.getElementById("calEditDialog");
    const currentDateObj = parseDate(ev.Date || ev.date);
    document.getElementById("editPracticeInstance").value = ev.PracticeInstance || ev.practiceInstance || "";
    document.getElementById("editCurrentDate").value = toDateKey(currentDateObj);
    const newDateInput = document.getElementById("editNewDate");
    newDateInput.value = "";
    document.getElementById("editReason").value = "";
    document.getElementById("editApplyFuture").checked = false;

    // Constrain the Execution Date picker to the current occurrence's own
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
    renderEditObligationDetails({ loading: true });
    wireViewPracticeButton(ev);
    loadEditObligationDetails(ev);
    dialog.showModal();
  }

  // ------------------------------------------------------------------
  // Read-only Obligation / Scheduler Details panel (requirement #3).
  // Frequency and Owner are already on every occurrence -- no fetch
  // needed. Obligation Description, Action and Execution Frequency come
  // from the obligation's own typed "Execution" spec (Shared/obligation-
  // form.js's TYPE_SCHEMA.Execution), reached the same way that form
  // reads it: GET .../resolve/instances/{id}/obligations, find this
  // occurrence's row, parse its ExecutionSpecsJson[0] with the same
  // normKey() case/underscore-insensitive match. Per the requester
  // (Assurance-kind occurrences have no "Action" -- their typed detail is
  // Verification Method / Assurance Frequency instead), Action and
  // Execution Frequency are shown only when ScheduleKind is "Execution".
  // Evidence Type / Evidence Details come from the sibling
  // .../resolve/instances/{id}/evidence feed, matched to this obligation
  // by SourceObligationId (published) or SourcePracticeInstanceObligationId
  // (organisation-defined) -- ResolveWorkspaceModels.cs's own documented
  // distinction between the two. Both are separate GETs, not folded into
  // the calendar query itself -- same "no wrapper" precedent as Risk
  // Category's separate save call: a second read for a field the
  // existing endpoint already owns, rather than teaching
  // QueryCalendarEventsAsync a new join.
  // ------------------------------------------------------------------
  const normKey = k => String(k).replace(/_/g, "").toLowerCase();

  function parseJsonArraySafe(raw) {
    if (!raw) return [];
    if (Array.isArray(raw)) return raw;
    try { const parsed = JSON.parse(raw); return Array.isArray(parsed) ? parsed : []; }
    catch (_) { return []; }
  }

  function fieldFrom(item, name) {
    if (!item) return null;
    const key = Object.keys(item).find(k => normKey(k) === normKey(name));
    return key !== undefined && item[key] !== null && item[key] !== "" ? item[key] : null;
  }

  // The resolve/instances/.../obligations and .../evidence feeds are the
  // API tier's own Ok(new { data = ... }) results, which ASP.NET Core's
  // default System.Text.Json output formatter serialises camelCase --
  // unlike `ev` itself (QueryCalendarEventsAsync's raw Dictionary<string,
  // object?>, always PascalCase). Same dual-case accessor
  // Shared/obligation-form.js already uses for these same rows (its own
  // `F` helper, "rows arrive camelCase from the Web tier and PascalCase
  // from some gateway paths").
  const rowGet = (row, k) => row?.[k] ?? row?.[k.charAt(0).toUpperCase() + k.slice(1)] ?? null;

  async function loadEditObligationDetails(ev) {
    const dialog = document.getElementById("calEditDialog");
    const instanceId = ev.PracticeInstanceId || ev.practiceInstanceId;
    const obligationRowId = ev.ObligationId || ev.obligationId;
    if (!instanceId || !obligationRowId) { renderEditObligationDetails(null); return; }

    try {
      const obligationsUrl = buildAppUrl(`practice/api/workflow/resolve/instances/${encodeURIComponent(instanceId)}/obligations`);
      const obligationsResp = await fetch(obligationsUrl, { credentials: "same-origin" });
      const obligationsBody = await obligationsResp.json();
      if (!obligationsResp.ok) { renderEditObligationDetails(null); return; }
      const rows = Array.isArray(obligationsBody.data) ? obligationsBody.data : [];
      const row = rows.find(r => String(rowGet(r, "adoptionId")) === String(obligationRowId));
      // The dialog may have moved on to a different occurrence while this
      // was in flight (fast double-click through the calendar).
      if (dialog._eventData !== ev) return;
      if (!row) { renderEditObligationDetails(null); return; }

      const scheduleKind = ev.ScheduleKind || ev.scheduleKind || "Assurance";
      let action = null, executionFrequency = null;
      if (String(scheduleKind).toLowerCase() === "execution") {
        const spec = parseJsonArraySafe(rowGet(row, "executionSpecsJson"))[0] || null;
        action = fieldFrom(spec, "action");
        executionFrequency = fieldFrom(spec, "ExecutionFrequency");
      }

      const rowObligationId = rowGet(row, "obligationId");
      const rowAdoptionId = rowGet(row, "adoptionId");
      let evidenceRows = [];
      try {
        const evidenceUrl = buildAppUrl(`practice/api/workflow/resolve/instances/${encodeURIComponent(instanceId)}/evidence`);
        const evidenceResp = await fetch(evidenceUrl, { credentials: "same-origin" });
        const evidenceBody = await evidenceResp.json();
        if (evidenceResp.ok && Array.isArray(evidenceBody.data)) {
          evidenceRows = evidenceBody.data.filter(e =>
            (rowObligationId && Number(rowGet(e, "sourceObligationId")) === Number(rowObligationId))
            || (rowAdoptionId && Number(rowGet(e, "sourcePracticeInstanceObligationId")) === Number(rowAdoptionId)));
        }
      } catch (_) { /* Evidence is a nice-to-have on this panel; the rest of it still renders without it. */ }

      if (dialog._eventData !== ev) return;
      renderEditObligationDetails({
        description: rowGet(row, "obligationDescription"),
        action,
        frequency: ev.FrequencyName || ev.frequencyName,
        owner: ev.Owner || ev.owner,
        executionFrequency,
        scheduleKind,
        evidence: evidenceRows
      });
    } catch (_) {
      if (dialog._eventData === ev) renderEditObligationDetails(null);
    }
  }

  function renderEditObligationDetails(data) {
    const host = document.getElementById("calEditObligationDetails");
    if (!host) return;
    if (data && data.loading) {
      host.innerHTML = `<div class="cal-detail-row"><span class="cal-detail-value muted">Loading obligation details…</span></div>`;
      return;
    }
    if (!data) {
      host.innerHTML = `<div class="cal-detail-row"><span class="cal-detail-value muted">Obligation details are not available for this occurrence.</span></div>`;
      return;
    }
    const row = (label, value, isMuted) => `<div class="cal-detail-row"><span class="cal-detail-label">${escapeHtml(label)}</span><span class="cal-detail-value${isMuted ? " muted" : ""}">${escapeHtml(value || "—")}</span></div>`;
    let html = "";
    html += row("Obligation Description", data.description);
    if (String(data.scheduleKind || "").toLowerCase() === "execution") {
      html += row("Action", data.action);
      html += row("Execution Frequency", data.executionFrequency);
    }
    html += row("Frequency", data.frequency);
    html += row("Owner", data.owner);
    const evidence = data.evidence || [];
    if (evidence.length) {
      html += row("Evidence Type", evidence.map(e => rowGet(e, "evidenceType")).filter(Boolean).join(", "));
      html += row("Evidence Details", evidence.map(e => {
        const retention = rowGet(e, "retentionPeriod");
        const bits = [rowGet(e, "evidenceName"), rowGet(e, "evidenceDescription"), retention ? `Retention: ${retention}` : null].filter(Boolean);
        return bits.length ? bits.join(" — ") : (rowGet(e, "evidenceType") || "");
      }).filter(Boolean).join("; "));
    } else {
      html += row("Evidence Type", null, true);
      html += row("Evidence Details", null, true);
    }
    host.innerHTML = html;
  }

  // ------------------------------------------------------------------
  // View Practice (requirement #4). Reuses the exact navigation-code +
  // Practice/Index/practice-view flow practice.js's own navigateWithContext
  // already uses for every other "View Practice" link in the app --
  // practice-calendar.js runs in its own page/closure with no access to
  // that function, so the same two calls (POST navigation-code, then
  // window.location.assign) are reproduced here rather than left
  // unreachable, matching the existing precedent of buildAppUrl itself
  // being a small per-file copy rather than a shared module.
  // ------------------------------------------------------------------
  function wireViewPracticeButton(ev) {
    const btn = document.getElementById("calEditViewPractice");
    if (!btn) return;
    const practiceId = ev.PracticeId || ev.practiceId;
    btn.hidden = !practiceId;
    btn.onclick = practiceId ? () => navigateToPractice(ev) : null;
  }

  async function navigateToPractice(ev) {
    const practiceId = ev.PracticeId || ev.practiceId;
    if (!practiceId) return;
    const msgEl = document.getElementById("calEditMessage");
    try {
      const result = await fetchJson(`${api}/navigation-code`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          sourceArea: "assurance-calendar",
          targetArea: "practice-view",
          filterType: "Practice",
          filterId: Number(practiceId),
          organizationId: Number(selectedOrgId) || null,
          displayName: ev.PracticeInstance || ev.practiceInstance || ""
        })
      });
      const code = result.code || result.Code || "";
      window.location.assign(`${window.location.origin}${buildAppUrl(`Practice/Index/practice-view`)}?code=${encodeURIComponent(code)}`);
    } catch (e) {
      showMsg(msgEl, e.message);
    }
  }

  // Migration 336-339: the "Generate Schedules" dialog was retired. It
  // created instance-wide rules by hand; schedules are now per obligation,
  // created automatically on obligation save and backfilled by
  // sp_pm_reconcile_schedule_rules. openGenerateDialog / submitGenerate /
  // saveScheduleRule / loadPracticeInstances all went with it.

  function showMsg(el, text, isWarning = false) {
    if (!el) return;
    el.textContent = text;
    el.hidden = false;
    el.className = "pm-message" + (isWarning ? " warning" : " error");
    setTimeout(() => { el.hidden = true; }, 6000);
  }

  /* ── Edit Submit ── */
  // Task Calendar Edit Scheduler (change request 2026-09-23): Move is the
  // only action left -- Execution Date is always required, and the
  // override is always saved as "Moved". The API's own shim
  // (sp_pm_schedule_override_repository_manage, migration 377) hard-codes
  // the same thing server-side, so overrideType is not even worth sending
  // any more, but it is kept in the payload (fixed to "Moved") so the
  // request shape stays self-documenting.
  async function submitEdit() {
    const dialog = document.getElementById("calEditDialog");
    const ev = dialog._eventData;
    const newDate = document.getElementById("editNewDate").value;
    const reason = document.getElementById("editReason").value;
    const applyFuture = document.getElementById("editApplyFuture").checked;
    const msgEl = document.getElementById("calEditMessage");

    if (!newDate) { showMsg(msgEl, "Please select an Execution Date."); return; }

    // Belt-and-braces guard: some browsers do not fully enforce the
    // <input type="date"> min / max attributes when a user *types* a
    // value (as opposed to picking one from the calendar popup). Re-check
    // the chosen date against the same reschedulePeriodBounds() window
    // used to configure the picker.
    const freqRaw = ev.FrequencyType || ev.frequencyType || ev.FrequencyName || ev.frequencyName || "";
    const bounds = reschedulePeriodBounds(parseDate(ev.Date || ev.date), freqRaw);
    if (bounds) {
      const picked = parseDate(newDate);
      if (!picked || picked < bounds.start || picked > bounds.end) {
        showMsg(msgEl, `Execution Date must be within the current ${String(freqRaw).toLowerCase() || "occurrence"} period (${toDateKey(bounds.start)} - ${toDateKey(bounds.end)}).`);
        return;
      }
    }

    try {
      await saveScheduleOverride({
        scheduleRuleId: ev.RuleId || ev.ruleId,
        organizationId: selectedOrgId || undefined,
        originalDate: toDateKey(parseDate(ev.Date || ev.date)),
        overrideType: "Moved",
        newDate: newDate,
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

  // Calendar / List toggle. Switching mode never re-fetches -- it only
  // changes which of #calGrid / #calListView is shown and how the
  // already-loaded `events` array is rendered. currentView (Month/Week/
  // Day) still governs which date range is loaded either way.
  function setMode(mode) {
    currentMode = mode;
    document.querySelectorAll("#calModeToggle .pm-button").forEach(btn => {
      btn.classList.toggle("active", btn.dataset.calMode === mode);
    });
    grid.hidden = mode === "list";
    listView.hidden = mode !== "list";
    // #calNavHeader now holds Prev/Today/Next/title AND the Month/Week/
    // Day switch together as one row -- both belong to the calendar
    // grid, so hiding the header hides the switch with it (it's nested
    // inside, no separate toggle needed). currentView still governs the
    // date range List loads (see the comment above); only the controls
    // disappear.
    if (navHeader) navHeader.hidden = mode === "list";
    // The Status / Criticality / Search filter panel acts on calendar
    // occurrences; it has no effect on the scheduler-config rows the List
    // shows (the rules query is org-scoped only). Hide it in List so it can't
    // read as a dead control -- the List provides its own search instead.
    if (filterPanel) filterPanel.hidden = mode === "list";
    render();
  }

  // Single source of truth for the toolbar title -- month/week/day/list
  // all share it so switching mode never leaves a stale title behind.
  function updateTitle() {
    if (currentView === "month") {
      titleEl.textContent = `${MONTHS[currentDate.getMonth()]} ${currentDate.getFullYear()}`;
    } else if (currentView === "week") {
      const weekStart = new Date(currentDate);
      weekStart.setDate(weekStart.getDate() - weekStart.getDay());
      const weekEnd = new Date(weekStart);
      weekEnd.setDate(weekEnd.getDate() + 6);
      titleEl.textContent = `${MONTHS[weekStart.getMonth()]} ${weekStart.getDate()} – ${weekEnd.getDate()}, ${weekEnd.getFullYear()}`;
    } else {
      titleEl.textContent = `${DAYS[currentDate.getDay()]}, ${MONTHS[currentDate.getMonth()]} ${currentDate.getDate()}, ${currentDate.getFullYear()}`;
    }
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
    updateTitle();
    if (currentMode === "list") { renderList(); return; }
    if (currentView === "month") renderMonth();
    else if (currentView === "week") renderWeek();
    else renderDay();
  }

  /* ── Rendering: Scheduler List ──
     One distinct row per configured schedule rule -- NOT a date-wise
     re-presentation of the occurrence `events`. The source is `rules`
     (data[1] from QueryCalendarEventsAsync = the raw, org-scoped, date-
     range-independent assurance_schedule_rule set), so every active
     scheduler appears exactly once regardless of the Calendar view's
     month/week/day window.

     Columns: Obligation Name, Type (Execution / Assurance), Frequency,
     Owner, Next Schedule Date. "Next Schedule Date" is the first
     occurrence on or after today, computed from the rule's own
     anchor_date + frequency using advanceByFrequency() -- a direct mirror
     of the occurrence stepping in PracticeRepositoryService, so the value
     matches the dates the grid draws and reflects the scheduler
     configuration rather than whatever happens to fall in the loaded
     window. Client-side search + pagination over the rule set, rendered
     with the app's standard .pm-table grid. Schedule generation itself is
     untouched -- this only presents the existing scheduler data. */
  let schedulerSearch = "";
  let schedulerPage = 0;
  const SCHEDULER_PAGE_SIZE = 15;

  // Mirror of the C# occurrence stepping. AddMonths/AddYears clamp to the
  // end of the target month (Jan-31 stepped one month -> Feb-28), so the
  // JS-computed next date lands on the same day the grid would draw.
  function addMonthsClamped(d, months) {
    const target = new Date(d.getFullYear(), d.getMonth() + months, 1);
    const lastDay = new Date(target.getFullYear(), target.getMonth() + 1, 0).getDate();
    target.setDate(Math.min(d.getDate(), lastDay));
    return target;
  }
  function advanceByFrequency(d, value, unit) {
    const u = String(unit || "").toLowerCase();
    if (u === "day")  { const nd = new Date(d); nd.setDate(nd.getDate() + value); return nd; }
    if (u === "week") { const nd = new Date(d); nd.setDate(nd.getDate() + value * 7); return nd; }
    if (u === "month") return addMonthsClamped(d, value);
    if (u === "year")  return addMonthsClamped(d, value * 12);
    return addMonthsClamped(d, value > 0 ? value : 1);
  }
  // First occurrence on/after today for a scheduler rule, or null when the
  // rule is non-periodic (Event Driven / Continuous / Custom -> freqValue<=0
  // or no unit -- the same rows the grid skips) or has already ended.
  function nextScheduleDateForRule(rule) {
    const anchor = parseDate(rule.anchor_date);
    if (!anchor) return null;
    const freqValue = Number(rule.frequency_value) || 0;
    const freqUnit = rule.frequency_unit;
    if (freqValue <= 0 || !freqUnit) return null;
    const end = parseDate(rule.end_date);
    const today = new Date(); today.setHours(0, 0, 0, 0);
    let cur = new Date(anchor.getFullYear(), anchor.getMonth(), anchor.getDate());
    let guard = 0;
    while (cur < today) {
      cur = advanceByFrequency(cur, freqValue, freqUnit);
      if (++guard > 5000) return null; // guard against a degenerate rule
    }
    if (end && cur > end) return null;
    return cur;
  }

  // Project `rules` (snake_case rows straight from the reader) into display
  // rows. Owner precedence: the schedule's own owner, then the obligation's
  // responsibility, then the practice instance's primary owner.
  function schedulerRows() {
    return (rules || []).map(r => {
      const kind = r.schedule_kind || "Assurance";
      const obligation = (r.obligation_name && String(r.obligation_name).trim())
        || (r.instance_name && String(r.instance_name).trim())
        || "—";
      const owner = (r.schedule_owner && String(r.schedule_owner).trim())
        || (r.responsibility && String(r.responsibility).trim())
        || (r.primary_owner && String(r.primary_owner).trim())
        || "—";
      // practiceInstance / frequencyName / organizationId are carried
      // through (not shown as their own columns -- Obligation Name already
      // covers this row's identity) so the row menu's Edit action can hand
      // openEditDialog() the same shape of object a calendar occurrence
      // carries (see PracticeRepositoryService.QueryCalendarEventsAsync's
      // `practiceLabel = "{instanceCode} - {instanceName}"`), without a
      // second lookup back into `rules`.
      const instanceCode = (r.instance_code && String(r.instance_code).trim()) || "";
      const instanceName = (r.instance_name && String(r.instance_name).trim()) || "";
      const practiceInstance = instanceCode && instanceName ? `${instanceCode} - ${instanceName}`
        : (instanceName || instanceCode || obligation);
      return {
        ruleId: r.schedule_rule_id,
        organizationId: r.organization_id,
        obligation,
        kind,
        frequency: (r.frequency_name && String(r.frequency_name).trim()) || "—",
        owner,
        next: nextScheduleDateForRule(r),
        practiceInstance,
        // Task Calendar Edit Scheduler (2026-09-23): carried through so
        // the row menu's Edit action can hand openEditDialog() the same
        // occurrence shape the Calendar grid itself produces (ObligationId,
        // PracticeId, PracticeInstanceId, ScheduleKind, Criticality,
        // AssuranceMode -- see QueryCalendarEventsAsync), without a second
        // lookup back into `rules`.
        obligationId: r.practice_instance_obligation_id,
        practiceId: r.practice_id,
        practiceInstanceId: r.practice_instance_id,
        scheduleKind: kind,
        criticality: (r.criticality && String(r.criticality).trim()) || "Medium",
        assuranceMode: (r.assurance_mode && String(r.assurance_mode).trim()) || "Manual",
        // Task Calendar Scheduler Edit Permission (2026-09-23): the
        // Practice Instance Owner's employee id, so the row's Actions
        // trigger can be gated the same way the Calendar side panel's
        // Edit Schedule button is.
        ownerEmployeeId: r.primary_owner_id
      };
    });
  }

  // Rows currently on screen, keyed by ruleId, for the 3-dot menu's Edit
  // action to look up without a second pass over `rules`.
  let schedulerRowsById = new Map();

  function renderList() {
    let rows = schedulerRows();

    // Search across the visible text columns.
    const q = schedulerSearch.trim().toLowerCase();
    if (q) {
      rows = rows.filter(r =>
        r.obligation.toLowerCase().includes(q) ||
        r.kind.toLowerCase().includes(q) ||
        r.frequency.toLowerCase().includes(q) ||
        r.owner.toLowerCase().includes(q));
    }

    // Stable order: obligation name, then type.
    rows.sort((a, b) => {
      const o = a.obligation.toLowerCase().localeCompare(b.obligation.toLowerCase());
      return o !== 0 ? o : a.kind.toLowerCase().localeCompare(b.kind.toLowerCase());
    });

    const total = rows.length;
    const pageCount = Math.max(1, Math.ceil(total / SCHEDULER_PAGE_SIZE));
    if (schedulerPage > pageCount - 1) schedulerPage = pageCount - 1;
    if (schedulerPage < 0) schedulerPage = 0;
    const start = schedulerPage * SCHEDULER_PAGE_SIZE;
    const pageRows = rows.slice(start, start + SCHEDULER_PAGE_SIZE);

    const toolbar = `<div class="cal-scheduler-toolbar">
        <div class="cal-scheduler-search">
          <i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i>
          <input type="search" id="calSchedulerSearch" placeholder="Search obligation, type, frequency or owner..."
                 aria-label="Search schedulers" value="${escapeAttr(schedulerSearch)}" />
        </div>
        <span class="cal-scheduler-count">${total} schedule${total === 1 ? "" : "s"}</span>
      </div>`;

    if (total === 0) {
      listView.innerHTML = toolbar +
        `<p class="pm-empty">${q ? "No schedules match your search." : "No configured schedules yet. Schedules are created automatically when an Execution or Assurance obligation is saved on the Operationalize screen."}</p>`;
      wireSchedulerSearch();
      return;
    }

    // Cache this page's rows by ruleId so the 3-dot menu's Edit action
    // (delegated click handler, wired once -- see wireSchedulerRowMenu)
    // can find a row's data without walking `rules` again.
    schedulerRowsById = new Map(pageRows.map(r => [String(r.ruleId), r]));

    let body = "";
    pageRows.forEach(r => {
      const kindLabel = SOURCE_LABELS[r.kind] || r.kind;
      // Actions column follows the same permission gate as the Calendar's
      // own "Edit Schedule" button: the screen-level EDIT/ADD grant
      // (canEdit, computed once at module load) AND, per row, the Practice
      // Instance Owner check (isSchedulerOwner, change request 2026-09-23)
      // -- a user without either sees no trigger at all, not an empty menu.
      const actionsCell = (canEdit && isSchedulerOwner(r.ownerEmployeeId))
        ? `<td>
            <button type="button" class="pm-action-trigger" data-sched-menu="${escapeAttr(String(r.ruleId))}"
                    aria-haspopup="menu" aria-expanded="false" title="Actions">
              <i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i>
              <span class="visually-hidden">Actions</span>
            </button>
          </td>`
        : "";
      body += `<tr>
        <td class="cal-sched-obligation">${escapeHtml(r.obligation)}</td>
        <td><span class="cal-side-source-badge source-${escapeAttr(r.kind)}">${escapeHtml(kindLabel)}</span></td>
        <td>${escapeHtml(r.frequency)}</td>
        <td>${escapeHtml(r.owner)}</td>
        <td class="cal-sched-next">${r.next ? escapeHtml(formatListDate(r.next)) : '<span class="cal-sched-none">—</span>'}</td>
        ${actionsCell}
      </tr>`;
    });

    const from = start + 1;
    const to = start + pageRows.length;
    const pager = pageCount > 1 ? `<div class="cal-scheduler-pager">
        <button type="button" class="pm-button small" data-sched-page="prev" ${schedulerPage === 0 ? "disabled" : ""}>
          <i class="fa-solid fa-chevron-left" aria-hidden="true"></i> Prev
        </button>
        <span class="cal-scheduler-pageinfo">${from}–${to} of ${total} &middot; Page ${schedulerPage + 1} of ${pageCount}</span>
        <button type="button" class="pm-button small" data-sched-page="next" ${schedulerPage >= pageCount - 1 ? "disabled" : ""}>
          Next <i class="fa-solid fa-chevron-right" aria-hidden="true"></i>
        </button>
      </div>` : "";

    listView.innerHTML = toolbar +
      `<div class="pm-table-wrap cal-scheduler-table-wrap">
        <table class="pm-table cal-scheduler-table">
          <thead>
            <tr>
              <th>Obligation Name</th>
              <th>Type</th>
              <th>Frequency</th>
              <th>Owner</th>
              <th>Next Schedule Date</th>
              ${canEdit ? '<th aria-label="Actions"></th>' : ""}
            </tr>
          </thead>
          <tbody>${body}</tbody>
        </table>
      </div>` + pager;

    wireSchedulerSearch();
    listView.querySelectorAll("[data-sched-page]").forEach(btn => {
      btn.addEventListener("click", () => {
        schedulerPage += btn.dataset.schedPage === "prev" ? -1 : 1;
        renderList();
      });
    });
  }

  // Re-attach the search input after each render (innerHTML replaced the old
  // one) and restore focus + caret so typing is never interrupted.
  function wireSchedulerSearch() {
    const input = document.getElementById("calSchedulerSearch");
    if (!input) return;
    input.addEventListener("input", () => {
      schedulerSearch = input.value;
      schedulerPage = 0;
      renderList();
      const fresh = document.getElementById("calSchedulerSearch");
      if (fresh) {
        fresh.focus();
        const len = fresh.value.length;
        try { fresh.setSelectionRange(len, len); } catch { /* type=search rejects setSelectionRange in some browsers */ }
      }
    });
  }

  /* ── Scheduler (Schedule List) row menu -- PM standard 3-dot pattern ──
     Same pattern document-uploads.js and the Task Center / Gap Center use:
     one `pm-action-trigger` per row, click opens a floating
     `.pm-action-menu` (shared practice-management.css classes, already
     loaded by the layout -- no new CSS needed) positioned relative to the
     trigger. Close on outside click, Escape, resize, or scroll. Wired
     ONCE via delegation on `listView` (see wireSchedulerRowMenu, called
     from the module's one-time "Wire up events" section) since renderList()
     replaces listView's innerHTML on every render/page/search change. */
  let schedOpenMenuEl = null;
  let schedOpenMenuTrigger = null;

  function closeSchedulerRowMenu() {
    if (schedOpenMenuEl) { schedOpenMenuEl.remove(); schedOpenMenuEl = null; }
    if (schedOpenMenuTrigger) {
      schedOpenMenuTrigger.setAttribute("aria-expanded", "false");
      schedOpenMenuTrigger = null;
    }
  }

  function positionSchedulerRowMenu(trigger) {
    if (!schedOpenMenuEl) return;
    const r  = trigger.getBoundingClientRect();
    const mr = schedOpenMenuEl.getBoundingClientRect();
    const gap = 6;
    let top = r.bottom + gap, left = r.right - mr.width;
    if (top + mr.height > window.innerHeight - 8) top = Math.max(8, r.top - mr.height - gap);
    if (left < 8) left = 8;
    if (left + mr.width > window.innerWidth - 8) left = window.innerWidth - mr.width - 8;
    schedOpenMenuEl.style.top  = top  + "px";
    schedOpenMenuEl.style.left = left + "px";
  }

  function openSchedulerRowMenu(trigger, items) {
    closeSchedulerRowMenu();
    schedOpenMenuTrigger = trigger;
    trigger.setAttribute("aria-expanded", "true");
    schedOpenMenuEl = document.createElement("div");
    schedOpenMenuEl.className = "pm-action-menu";
    schedOpenMenuEl.setAttribute("role", "menu");
    for (const it of items) {
      const b = document.createElement("button");
      b.type = "button";
      b.setAttribute("role", "menuitem");
      b.innerHTML = `<i class="fa-solid ${escapeHtml(it.icon)}" aria-hidden="true"></i> ${escapeHtml(it.label)}`;
      if (it.disabled) { b.disabled = true; b.title = it.disabledReason || ""; }
      b.addEventListener("click", ev => {
        ev.preventDefault();
        ev.stopPropagation();
        closeSchedulerRowMenu();
        try { it.action(); } catch (err) { console.error("[practice-calendar] scheduler menu action failed", err); }
      });
      schedOpenMenuEl.appendChild(b);
    }
    document.body.appendChild(schedOpenMenuEl);
    positionSchedulerRowMenu(trigger);
  }

  // Row menu contains only "Edit". Not visible at all unless canEdit AND
  // the caller is the row's Practice Instance Owner (change request
  // 2026-09-23) -- the trigger cell itself is omitted from the row when
  // either is missing (see renderList()), so this only has to handle the
  // one case where permission is present but there is nothing to edit: a
  // rule with no upcoming occurrence (nextScheduleDateForRule returned
  // null -- e.g. its end_date has already passed). Same rule the
  // Calendar's own side panel applies via isScheduleOccurrence /
  // statusLower checks, adapted to what a List row actually has (no
  // per-occurrence status).
  function buildSchedulerRowMenu(row) {
    // Task Calendar Edit Scheduler (2026-09-23): a daily-frequency rule
    // has no valid edit left (see isDailyFrequency's own comment) --
    // same reasoning the Calendar side panel now applies, adapted to
    // what a List row has (no per-occurrence status, so only the
    // frequency and "is there an upcoming date at all" gate this).
    const isDaily = isDailyFrequency(row.frequency);
    const items = [{
      icon: "fa-pen",
      label: "Edit",
      disabled: !row.next || isDaily,
      disabledReason: !row.next ? "No upcoming occurrence to reschedule."
        : (isDaily ? "Daily occurrences cannot be rescheduled." : ""),
      // Reuses the Calendar's existing "Edit Schedule" dialog verbatim
      // (openEditDialog / submitEdit / saveScheduleOverride) -- same
      // dialog, same validation, same API. The only thing built here is
      // a calendar-occurrence-shaped object from this row's rule data,
      // since the List's `rules` rows and the Calendar's `events` rows are
      // different shapes even though they both come from
      // assurance-calendar-events/query (rules is that response's 2nd
      // result set; events is the 1st, already occurrence-shaped).
      action: () => openEditDialog({
        RuleId: row.ruleId,
        Date: row.next,
        PracticeInstance: row.practiceInstance,
        FrequencyName: row.frequency,
        ObligationId: row.obligationId,
        PracticeId: row.practiceId,
        PracticeInstanceId: row.practiceInstanceId,
        ScheduleKind: row.scheduleKind,
        Owner: row.owner,
        OwnerEmployeeId: row.ownerEmployeeId,
        Criticality: row.criticality,
        AssuranceMode: row.assuranceMode
      })
    }];
    return items;
  }

  function wireSchedulerRowMenu() {
    if (!listView) return;
    listView.addEventListener("click", ev => {
      const trigger = ev.target.closest(".pm-action-trigger[data-sched-menu]");
      if (!trigger || !listView.contains(trigger)) return;
      ev.preventDefault();
      ev.stopPropagation();
      const row = schedulerRowsById.get(trigger.dataset.schedMenu);
      if (!row) return;
      if (schedOpenMenuTrigger === trigger) { closeSchedulerRowMenu(); return; }
      openSchedulerRowMenu(trigger, buildSchedulerRowMenu(row));
    });
    document.addEventListener("click", ev => {
      if (!schedOpenMenuEl) return;
      if (ev.target.closest(".pm-action-menu")) return;
      if (ev.target.closest(".pm-action-trigger[data-sched-menu]")) return;
      closeSchedulerRowMenu();
    });
    document.addEventListener("keydown", ev => { if (ev.key === "Escape") closeSchedulerRowMenu(); });
    window.addEventListener("resize", closeSchedulerRowMenu);
    window.addEventListener("scroll", closeSchedulerRowMenu, true);
  }

  /* ==================================================================
     Unified Calendar filter wiring: chips, owner picker, definition
     dropdown, search, reset. Every change persists to localStorage and
     triggers a refresh (which re-fetches with the new payload).
     ================================================================== */
  function applyFilterStateToUI() {
    // Sync every multi-select combo (sourceModules / statuses /
    // criticalities) to filters[group]: tick the matching checkboxes and
    // refresh the trigger's summary text.
    document.querySelectorAll('.pm-checkcombo[data-cal-filter-group]').forEach(syncComboFromState);
    // Search text.
    const searchEl = document.getElementById("calFilterSearch");
    if (searchEl) searchEl.value = filters.search || "";
    // Definition + owner selects get their values set once the async
    // populate calls complete (see loadFilterDropdowns / attachOwnerPicker).
  }

  /* ---- Multi-select filter combos (.pm-checkcombo) -----------------
     These replace the old Modules / Status / Criticality chip rows so
     the filter set fits on one row. Each combo's data-cal-filter-group
     names the filters[] array it drives; each option checkbox carries
     data-cal-chip-value (the same value vocabulary the chips used).
     Ticking a box rebuilds filters[group] from the checked boxes and
     refreshes -- functionally identical to the old toggleChip, so the
     API payload and persisted state are unchanged. */
  const COMBO_META = {
    statuses     : { noun: "statuses",      allWhenFull: false },
    criticalities: { noun: "criticalities", allWhenFull: false }
  };
  function comboBoxes(combo) {
    return Array.from(combo.querySelectorAll('input[type="checkbox"][data-cal-chip-value]'));
  }
  function updateComboSummary(combo) {
    const group = combo.dataset.calFilterGroup;
    const meta = COMBO_META[group] || { noun: "items", allWhenFull: false };
    const boxes = comboBoxes(combo);
    const total = boxes.length;
    // Only count values that actually exist as options in this combo.
    const sel = (filters[group] || []).filter(v => boxes.some(b => b.dataset.calChipValue === v));
    const textEl = combo.querySelector("[data-checkcombo-text]");
    if (!textEl) return;
    let label, isDefault;
    if (sel.length === 0 || (meta.allWhenFull && sel.length === total)) {
      // Empty status/criticality = no constraint (all shown); a full
      // module set is the "all" default too -- both read as "All ...".
      label = "All " + meta.noun; isDefault = true;
    } else {
      label = sel.length + " of " + total; isDefault = false;
    }
    textEl.innerHTML = "";
    const span = document.createElement("span");
    span.className = "pm-checkcombo-summary" + (isDefault ? " is-default" : "");
    span.textContent = label;
    textEl.appendChild(span);
  }
  function syncComboFromState(combo) {
    const group = combo.dataset.calFilterGroup;
    const set = new Set(filters[group] || []);
    comboBoxes(combo).forEach(b => { b.checked = set.has(b.dataset.calChipValue); });
    updateComboSummary(combo);
  }
  function filterComboOptions(combo, q) {
    const needle = (q || "").trim().toLowerCase();
    combo.querySelectorAll("[data-checkcombo-option]").forEach(opt => {
      opt.hidden = needle ? !opt.textContent.toLowerCase().includes(needle) : false;
    });
  }
  function closeAllCombos(except) {
    document.querySelectorAll('.pm-checkcombo[data-cal-filter-group].open').forEach(c => {
      if (c === except) return;
      c.classList.remove("open");
      const menu = c.querySelector(".pm-checkcombo-menu");
      const trig = c.querySelector(".pm-checkcombo-trigger");
      if (menu) menu.hidden = true;
      if (trig) trig.setAttribute("aria-expanded", "false");
    });
  }
  function initCheckCombo(combo) {
    const trigger = combo.querySelector(".pm-checkcombo-trigger");
    const menu = combo.querySelector(".pm-checkcombo-menu");
    const search = combo.querySelector(".pm-checkcombo-search");
    const group = combo.dataset.calFilterGroup;
    if (!trigger || !menu) return;

    trigger.addEventListener("click", e => {
      e.stopPropagation();
      const willOpen = menu.hidden;
      closeAllCombos(combo);
      menu.hidden = !willOpen;
      combo.classList.toggle("open", willOpen);
      trigger.setAttribute("aria-expanded", willOpen ? "true" : "false");
      if (willOpen && search) { search.value = ""; filterComboOptions(combo, ""); search.focus(); }
    });
    // Clicks inside the open menu must not bubble to the document closer.
    menu.addEventListener("click", e => e.stopPropagation());
    if (search) search.addEventListener("input", () => filterComboOptions(combo, search.value));

    comboBoxes(combo).forEach(box => {
      box.addEventListener("change", () => {
        filters[group] = comboBoxes(combo).filter(b => b.checked).map(b => b.dataset.calChipValue);
        updateComboSummary(combo);
        saveFilterState();
        refresh();
      });
    });
  }

  document.querySelectorAll('.pm-checkcombo[data-cal-filter-group]').forEach(initCheckCombo);
  // One document-level closer for every combo (outside click + Escape).
  document.addEventListener("click", () => closeAllCombos(null));
  document.addEventListener("keydown", e => { if (e.key === "Escape") closeAllCombos(null); });

  // Search input -- debounced so we don't refetch on every keystroke.
  let searchDebounce = null;
  document.getElementById("calFilterSearch")?.addEventListener("input", e => {
    filters.search = e.target.value || "";
    if (searchDebounce) clearTimeout(searchDebounce);
    searchDebounce = setTimeout(() => {
      saveFilterState();
      refresh();
    }, 300);
  });

  // Reset button -- clears every filter to defaults + re-syncs the UI.
  document.getElementById("calFilterReset")?.addEventListener("click", () => {
    filters = defaultFilters();
    saveFilterState();
    applyFilterStateToUI();
    refresh();
  });

  /* ── Wire up events ── */
  document.getElementById("calPrev")?.addEventListener("click", () => navigate(-1));
  document.getElementById("calNext")?.addEventListener("click", () => navigate(1));
  document.getElementById("calToday")?.addEventListener("click", goToday);
  document.getElementById("calSideClose")?.addEventListener("click", closeSidePanel);

  document.querySelectorAll(".cal-view-toggle .pm-button").forEach(btn => {
    btn.addEventListener("click", () => setView(btn.dataset.calView));
  });
  document.querySelectorAll("#calModeToggle .pm-button").forEach(btn => {
    btn.addEventListener("click", () => setMode(btn.dataset.calMode));
  });

  orgFilter?.addEventListener("change", () => {
    selectedOrgId = orgFilter.value;
    refresh();
  });

  document.getElementById("calEditClose")?.addEventListener("click", () => document.getElementById("calEditDialog").close());
  document.getElementById("calEditCancel")?.addEventListener("click", () => document.getElementById("calEditDialog").close());
  document.getElementById("calEditSubmit")?.addEventListener("click", submitEdit);

  // Schedule List's 3-dot Edit action -- delegated, wired once (renderList()
  // rebuilds listView's innerHTML on every render, so per-row listeners
  // would leak and need re-wiring on every keystroke of the search box).
  wireSchedulerRowMenu();

  // Close side panel on Escape
  document.addEventListener("keydown", e => {
    if (e.key === "Escape") closeSidePanel();
  });

  /* ── Init ── */
  (async () => {
    // Step 1: restore combo / search UI from saved filter state so the
    // page loads showing exactly what the user last saw (defaults on
    // first visit = all modules ON, no other constraints).
    applyFilterStateToUI();

    // Step 2: populate the Organization filter + Generate Schedule modal
    // dropdown from the shared `${api}/lookups` endpoint -- same API the
    // rest of Practice Management uses, so the calendar sees exactly the
    // set of orgs the user is entitled to. If lookups auto-selects a
    // single org, selectedOrgId is already set before the first calendar
    // fetch, so we don't need a second round-trip.
    await loadOrganizationsFromLookups();

    // Step 3: fetch events. loadCalendarEvents still checks the response
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
