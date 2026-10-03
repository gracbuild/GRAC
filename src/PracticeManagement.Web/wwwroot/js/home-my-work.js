// =====================================================================
// home-my-work.js -- Home page "My work" (change request 2026-09-27)
//
// The Home page replaces the separate "My Notification" sidebar group
// (My Notifications / Practices / Tasks / Approvals / Acknowledgements)
// with two things:
//   * "Needs your attention" -- ONE list, most urgent first, drawn from
//     every area the user can act in;
//   * "My work" -- one line per area: a count, a one-line status and the
//     way into the existing detailed page.
//
// NO NEW API. Every read is an endpoint the detailed page already uses,
// and every one takes the employee from the SESSION (or, for tasks and
// practice instances, narrows by the session's employee id, with the
// server's own ownership/organisation rules still applied):
//   notifications     GET /practice/api/task-notifications/me[/counts]
//   tasks             GET /practice/api/tasks?assignedToEmployeeId=&statusCode=OpenSet[&overdueOnly=true]
//   practices         GET /practice/api/workflow/resolve/instances?ownerEmployeeId=
//   approvals         GET /practice/api/risk-centre/approval-queue
//   acknowledgements  GET /practice/api/document-acknowledgements/my/batches
//   repository updates GET /practice/api/repository-changes/me/notifications
//                      (migration 395 -- attention items only, no My work line)
//
// A section is only on the page when PracticeController.Dashboard found
// the grant that opens its detailed page (data-access-* on #homeMyWork),
// so Home never shows what the full page would refuse. Each section fails
// on its own: one endpoint down leaves the others working.
//
// The organisation is the Home page's existing picker; practice-
// dashboard.js publishes it as "pm:home-organization".
// =====================================================================
(() => {
  "use strict";

  const root = document.getElementById("homeMyWork");
  if (!root) return;

  const base = String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "");
  const U = path => `${base}/${String(path || "").replace(/^\/+/, "")}`;
  const esc = value => String(value ?? "").replace(/[&<>"']/g, ch =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#039;" })[ch]);
  const F = (row, key) => row == null ? undefined
    : (row[key] !== undefined ? row[key] : row[key.charAt(0).toUpperCase() + key.slice(1)]);
  const fmtDate = value => {
    if (!value) return "";
    if (typeof window.gracFormatDateOnly === "function") return window.gracFormatDateOnly(value);
    return String(value).slice(0, 10);
  };
  const plural = (n, one, many) => `${n} ${n === 1 ? one : (many || one + "s")}`;

  const employeeId = root.dataset.employeeId || "";
  const can = key => root.dataset["access" + key.charAt(0).toUpperCase() + key.slice(1)] === "1";

  const listHost = document.getElementById("homeAttentionList");
  const moreHost = document.getElementById("homeAttentionMore");
  const ATTENTION_LIMIT = 8;
  const SEVERITY_RANK = { danger: 0, warning: 1, info: 2 };
  const DAY_MS = 86400000;

  let generation = 0;

  // ---- plumbing -------------------------------------------------------
  async function getJson(path) {
    try {
      const r = await fetch(U(path), { credentials: "same-origin" });
      if (r.status === 401) {
        window.location.assign(`${U("Login")}?returnUrl=${encodeURIComponent(window.location.pathname + window.location.search)}`);
        return { ok: false, status: 401, body: null };
      }
      const body = await r.json().catch(() => null);
      return { ok: r.ok, status: r.status, body };
    } catch (err) {
      return { ok: false, status: 0, body: null, error: err.message };
    }
  }

  function section(key) {
    return root.querySelector(`[data-home-section="${key}"]`);
  }

  function setSummary(key, count, detail, opts) {
    const li = section(key);
    if (!li) return;
    opts = opts || {};
    const countEl  = li.querySelector("[data-home-count]");
    const detailEl = li.querySelector("[data-home-detail]");
    if (countEl) countEl.textContent = count == null ? "–" : String(count);
    if (detailEl) {
      detailEl.textContent = detail || "";
      detailEl.classList.toggle("is-alert", !!opts.alert);
    }
    if (opts.href) {
      const link = li.querySelector("[data-home-link]");
      if (link) link.href = opts.href;
    }
  }

  function unavailable(key, message) {
    setSummary(key, null, message);
    return [];
  }

  // ---- sections: each returns attention items --------------------------
  // item: { key, severity, type, title, detail, href, due }
  async function loadNotifications() {
    const [counts, list] = await Promise.all([
      getJson("/practice/api/task-notifications/me/counts"),
      getJson("/practice/api/task-notifications/me?page=1&pageSize=10&statusCode=Pending")
    ]);
    if (!counts.ok) {
      return unavailable("notifications", counts.status === 403 || counts.status === 404
        ? "Not available for your sign-in." : "Could not load notifications.");
    }
    const unread = Number(F(counts.body, "pendingCount")) || 0;
    const rows = (list.ok && (F(list.body, "rows") || [])) || [];
    const breached = rows.filter(n => ["BREACH", "ESCALATION"].includes(F(n, "notifyEventCode"))).length;
    setSummary("notifications", unread,
      unread === 0 ? "No unread alerts"
        : breached > 0 ? `${plural(unread, "unread alert")} · ${breached} breach / escalation`
        : plural(unread, "unread alert"),
      { alert: breached > 0 });

    return rows.map(n => {
      const ev = F(n, "notifyEventCode");
      const taskId = F(n, "taskId");
      return {
        key: `task:${taskId}`,
        severity: ev === "WARNING" ? "warning" : "danger",
        type: ev === "BREACH" ? "Alert · SLA breached"
            : ev === "ESCALATION" ? "Alert · Escalated to you"
            : "Alert · Due soon",
        title: [F(n, "taskNumber") || `#${taskId}`, F(n, "taskTitle")].filter(Boolean).join(" — "),
        detail: [F(n, "dueAt") ? `Due ${fmtDate(F(n, "dueAt"))}` : "",
                 F(n, "recipientReasonCode") === "OWNER" ? "You own this task"
                   : (F(n, "roleName") ? `Role: ${F(n, "roleName")}` : "")].filter(Boolean).join(" · "),
        href: U(`/Practice/Index/task-view?taskId=${encodeURIComponent(taskId)}`),
        due: F(n, "dueAt")
      };
    });
  }

  async function loadTasks(orgId) {
    if (!employeeId) return unavailable("tasks", "Your sign-in is not linked to an employee record.");
    const q = `/practice/api/tasks?organizationId=${encodeURIComponent(orgId)}`
            + `&assignedToEmployeeId=${encodeURIComponent(employeeId)}&statusCode=OpenSet`;
    const [open, overdue] = await Promise.all([
      getJson(`${q}&page=1&pageSize=50`),
      getJson(`${q}&overdueOnly=true&page=1&pageSize=1`)
    ]);
    if (!open.ok) return unavailable("tasks", "Could not load your tasks.");
    const total = Number(F(open.body, "totalCount")) || 0;
    const overdueCount = overdue.ok ? (Number(F(overdue.body, "totalCount")) || 0) : null;
    setSummary("tasks", total,
      total === 0 ? "No open tasks"
        : overdueCount ? `${overdueCount} overdue · ${total - overdueCount} on track or due soon`
        : "None overdue",
      { alert: !!overdueCount });

    const soon = Date.now() + 3 * DAY_MS;
    return (F(open.body, "rows") || [])
      .filter(t => {
        const due = F(t, "slaDueAt");
        return F(t, "isOverdue") || ["DueSoon", "DueToday", "Breached"].includes(F(t, "slaStatusCode"))
            || (due && new Date(due).getTime() <= soon);
      })
      .map(t => {
        const id = F(t, "taskId");
        const overdueRow = !!F(t, "isOverdue") || F(t, "slaStatusCode") === "Breached";
        return {
          key: `task:${id}`,
          severity: overdueRow ? "danger" : "warning",
          type: overdueRow ? "Task · Overdue" : "Task · Due soon",
          title: [F(t, "taskNumber") || `#${id}`, F(t, "subjectTitle")].filter(Boolean).join(" — "),
          detail: [F(t, "slaDueAt") ? `Due ${fmtDate(F(t, "slaDueAt"))}` : "",
                   F(t, "priority") ? `${F(t, "priority")} priority` : "",
                   F(t, "currentStatusName") || ""].filter(Boolean).join(" · "),
          href: U(`/Practice/Index/task-view?taskId=${encodeURIComponent(id)}`),
          due: F(t, "slaDueAt")
        };
      });
  }

  async function loadPractices(orgId) {
    if (!employeeId) return unavailable("practices", "Your sign-in is not linked to an employee record.");
    const res = await getJson(`/practice/api/workflow/resolve/instances?organizationId=${encodeURIComponent(orgId)}`
      + `&ownerEmployeeId=${encodeURIComponent(employeeId)}&includeRetired=false&search=&pageNumber=1&pageSize=200`);
    if (!res.ok) return unavailable("practices", "Could not load your practice instances.");
    const rows = F(res.body, "data") || [];
    const total = Number(F(res.body, "totalRows"));
    const count = Number.isFinite(total) ? total : rows.length;
    // "Needs operationalizing" = the same two progress measures the
    // Operationalize grid shows: obligations adopted, dependencies resolved.
    const incomplete = rows.filter(r =>
      (Number(F(r, "adoptedObligations")) || 0) < (Number(F(r, "totalObligations")) || 0)
      || (Number(F(r, "resolvedDependencies")) || 0) < (Number(F(r, "totalDependencies")) || 0));
    setSummary("practices", count,
      count === 0 ? "You own no practice instances here"
        : incomplete.length ? `${incomplete.length} not fully operationalized`
        : "All operationalized",
      { href: U(`/Practice/Index/resolve?organizationId=${encodeURIComponent(orgId)}&ownerEmployeeId=${encodeURIComponent(employeeId)}`) });

    return incomplete.slice(0, 3).map(r => {
      const id = F(r, "practiceInstanceId");
      return {
        key: `instance:${id}`,
        severity: "warning",
        type: "Practice instance · Operationalize",
        title: [F(r, "instanceCode"), F(r, "instanceName")].filter(Boolean).join(" — ")
               + (F(r, "practiceName") ? ` (${F(r, "practiceName")})` : ""),
        detail: [`${Number(F(r, "adoptedObligations")) || 0} of ${Number(F(r, "totalObligations")) || 0} obligations adopted`,
                 `${Number(F(r, "resolvedDependencies")) || 0} of ${Number(F(r, "totalDependencies")) || 0} dependencies resolved`].join(" · "),
        href: U(`/Practice/Index/resolve-workspace?instanceId=${encodeURIComponent(id)}&organizationId=${encodeURIComponent(orgId)}`),
        due: null
      };
    });
  }

  async function loadApprovals(orgId) {
    const res = await getJson(`/practice/api/risk-centre/approval-queue?organizationId=${encodeURIComponent(orgId)}&page=1&pageSize=5`);
    if (!res.ok) return unavailable("approvals", "Could not load the approval queue.");
    const rows = F(res.body, "rows") || [];
    const total = Number(F(res.body, "totalRows")) || rows.length;
    setSummary("approvals", total,
      total === 0 ? "Nothing waiting for approval" : `${plural(total, "risk analysis", "risk analyses")} awaiting a decision`);
    return rows.map(a => ({
      key: `approval:${F(a, "riskCandidateId")}`,
      severity: "info",
      type: "Approval · Risk analysis",
      title: [F(a, "candidateNumber"), F(a, "candidateTitle")].filter(Boolean).join(" — "),
      detail: [F(a, "inherentRatingCode") ? `Inherent ${F(a, "inherentRatingCode")}` : "",
               F(a, "analysedByName") ? `Analysed by ${F(a, "analysedByName")}` : "",
               F(a, "daysWaiting") != null ? `Waiting ${plural(Number(F(a, "daysWaiting")) || 0, "day")}` : ""]
               .filter(Boolean).join(" · "),
      // The "Awaiting approval" queue is on the Risk Candidates screen
      // (moved from the Risk dashboard, 2026-10-01).
      href: U("/Practice/Index/risk-centre-candidates"),
      due: null
    }));
  }

  async function loadAcknowledgements(orgId) {
    const res = await getJson(`/practice/api/document-acknowledgements/my/batches?includeCompleted=false&organizationId=${encodeURIComponent(orgId)}`);
    if (!res.ok) {
      return unavailable("acknowledgements", res.status === 403
        ? "Your sign-in is not linked to an employee record." : "Could not load acknowledgements.");
    }
    const batches = Array.isArray(res.body) ? res.body : [];
    const pending = batches.reduce((sum, b) => sum + (Number(F(b, "myPendingCount")) || 0), 0);
    setSummary("acknowledgements", pending,
      pending === 0 ? "Nothing to acknowledge" : `Documents in ${plural(batches.length, "batch", "batches")}`);

    const now = Date.now();
    return batches
      .filter(b => (Number(F(b, "myPendingCount")) || 0) > 0)
      .map(b => {
        const due = F(b, "dueDate");
        const dueMs = due ? new Date(due).getTime() : null;
        return {
          key: `ack:${F(b, "acknowledgementId")}`,
          severity: dueMs != null && dueMs < now ? "danger" : dueMs != null && dueMs <= now + 7 * DAY_MS ? "warning" : "info",
          type: dueMs != null && dueMs < now ? "Acknowledgement · Overdue" : "Acknowledgement",
          title: F(b, "acknowledgementName") || "Acknowledgement batch",
          detail: [`${plural(Number(F(b, "myPendingCount")) || 0, "document")} to acknowledge`,
                   due ? `Due ${fmtDate(due)}` : ""].filter(Boolean).join(" · "),
          href: U("/Practice/Index/my-acknowledgements"),
          due
        };
      });
  }

  // Migration 395: Control Management changes waiting for this person's
  // approval (they are the release owner or an organization admin).
  async function loadRepositoryUpdates(orgId) {
    const res = await getJson(`/practice/api/repository-changes/me/notifications?organizationId=${encodeURIComponent(orgId)}`);
    if (!res.ok) return [];
    return (F(res.body, "data") || [])
      .filter(n => (Number(F(n, "pendingCount")) || 0) > 0)
      .map(n => {
        const releaseId = F(n, "releaseId");
        const pending = Number(F(n, "pendingCount")) || 0;
        return {
          key: `repo-updates:${orgId}:${releaseId ?? "shared"}`,
          severity: "info",
          type: "Approval · Repository updates",
          title: F(n, "frameworkRelease") || "Subscribed release",
          detail: [`${plural(pending, "update")} from Control Management waiting for approval`,
                   F(n, "recipientReason") === "ReleaseOwner" ? "You own this release" : ""].filter(Boolean).join(" · "),
          href: U(`/Practice/Index/repository-updates?organizationId=${encodeURIComponent(orgId)}`
                  + (releaseId ? `&releaseId=${encodeURIComponent(releaseId)}` : "")),
          due: null
        };
      });
  }

  // ---- the one attention list ------------------------------------------
  function renderAttention(items) {
    // One row per underlying record: a task reached both as "assigned to
    // me" and through an unread alert is listed once, at its most urgent.
    const byKey = new Map();
    items.forEach(item => {
      const seen = byKey.get(item.key);
      if (!seen || SEVERITY_RANK[item.severity] < SEVERITY_RANK[seen.severity]) byKey.set(item.key, item);
    });
    const ordered = [...byKey.values()].sort((a, b) =>
      (SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity])
      || ((a.due ? new Date(a.due).getTime() : Infinity) - (b.due ? new Date(b.due).getTime() : Infinity)));

    listHost.classList.toggle("is-empty", !ordered.length);
    if (!ordered.length) {
      listHost.innerHTML = `<div class="pm-empty compact">You are all caught up &mdash; nothing assigned to you needs action in this organization.</div>`;
      moreHost.hidden = true;
      return;
    }
    listHost.innerHTML = ordered.slice(0, ATTENTION_LIMIT).map(item => `
      <div class="pm-attention-row pm-home-item severity-${item.severity}">
        <div class="pm-home-item-main">
          <span class="pm-home-item-type">${esc(item.type)}</span>
          <strong title="${esc(item.title)}">${esc(item.title)}</strong>
          ${item.detail ? `<span>${esc(item.detail)}</span>` : ""}
        </div>
        <div class="pm-attention-action"><a href="${esc(item.href)}">Open</a></div>
      </div>`).join("");
    moreHost.hidden = ordered.length <= ATTENTION_LIMIT;
    moreHost.textContent = ordered.length > ATTENTION_LIMIT
      ? `Showing the ${ATTENTION_LIMIT} most urgent of ${ordered.length}. Use "My work" to open each area in full.`
      : "";
  }

  async function load(orgId) {
    const mine = ++generation;
    listHost.classList.add("is-empty");
    listHost.innerHTML = `<div class="pm-empty compact">Loading your work...</div>`;
    moreHost.hidden = true;
    root.querySelectorAll("[data-home-section]").forEach(li => setSummary(li.dataset.homeSection, null, "Loading..."));

    const jobs = [];
    // Notifications are addressed to the person, not the organization.
    if (can("notifications")) jobs.push(loadNotifications());
    const orgScoped = [["tasks", loadTasks], ["practices", loadPractices],
                       ["approvals", loadApprovals], ["acknowledgements", loadAcknowledgements]];
    // Attention-only: no My work line, so no "Select an organization." summary.
    if (can("repositoryUpdates") && orgId) jobs.push(loadRepositoryUpdates(orgId));
    orgScoped.forEach(([key, fn]) => {
      if (!can(key)) return;
      jobs.push(orgId ? fn(orgId) : Promise.resolve(unavailable(key, "Select an organization.")));
    });

    const results = await Promise.all(jobs.map(p => p.catch(() => [])));
    if (mine !== generation) return;            // the organization changed meanwhile
    renderAttention(results.flat());
  }

  document.addEventListener("pm:home-organization", ev => {
    load(ev.detail && ev.detail.organizationId ? String(ev.detail.organizationId) : "");
  });
})();
