    document.getElementById("tvUnavailableBody").textContent = body;
  }

  async function load() {
    const detail = await apiGet(`/${state.taskId}`);
    if (!detail || !detail.header) {
      unavailable("Task not found.", "It may have been removed, or the link is out of date.");
      return;
    }
    state.detail = detail;
    document.getElementById("tvRoot").hidden = false;
    document.getElementById("tvUnavailable").hidden = true;
    render(detail);
  }

  async function apiGet(path) {
    try {
      const r = await fetch(U(taskBase + path), { credentials: "same-origin" });
      if (!r.ok) return null;
      return await r.json();
    } catch (_) {
      return null;
    }
  }

  function render(d) {
    const h = d.header;

    document.getElementById("tvHeading").textContent =
      (h.taskNumber || ("Task #" + h.taskId)) + " — " + (h.subjectTitle || "");
    document.getElementById("tvStatusChip").textContent = h.currentStatusName || h.currentStatusCode || "-";
    document.getElementById("tvOpenTaskCenterLink").href =
      U("/Practice/Index/tasks") + "#taskId=" + encodeURIComponent(h.taskId);

    document.getElementById("tvFacts").innerHTML = renderFacts(h);
    renderRelatedSource(h);
    renderDescription(h);
    renderCompletion(h);
    renderChildren(d.children || [], h);
    renderGovernanceRequests(d.governanceRequests || []);
    renderEvidence(d.attachments || []);
    renderCreatedUpdated(h);
    renderActivity(d.activity || []);
  }

  function factRow(label, value) {
    const empty = value === null || value === undefined || value === "";
    return `<div><dt>${escapeHtml(label)}</dt><dd${empty ? ' class="tv-empty"' : ""}>${empty ? "—" : value}</dd></div>`;
  }

  function ownerValue(h) {
    if (h.assignedToEmployeeName) {
      const src = h.ownerSourceCode && h.ownerSourceCode !== "EXPLICIT_SOURCE" && h.ownerSourceCode !== "REASSIGNED"
        ? ` <span class="tv-hint">(${escapeHtml(ownerSourceLabel(h.ownerSourceCode))})</span>` : "";
      return escapeHtml(h.assignedToEmployeeName) + src;
    }
    if (h.assignedToEmployeeId) return escapeHtml(String(h.assignedToEmployeeId));
    return '<span class="tv-warn">Unassigned</span>';
  }

  function ownerSourceLabel(code) {
    return ({
      PRACTICE_OWNER: "from Practice owner", CONTROL_OWNER: "from Control owner",
      PROCESS_OWNER: "from Process owner", FUNCTION_OWNER: "from Function owner",
      ORG_DEFAULT: "org default owner", MANUAL: "manual assignment"
    })[code] || "";
  }

  function slaStatusValue(h) {
    const code = h.slaStatusCode;
    if (!code) return h.isOverdue ? statusPill("Breached") : "";
    return statusPill(code.replace(/([a-z])([A-Z])/g, "$1 $2"));
  }

  function statusPill(text) {
    return `<span class="pm-badge">${escapeHtml(text)}</span>`;
  }

  function renderFacts(h) {
    const rows = [
      factRow("Task Reference", escapeHtml(h.taskNumber || ("#" + h.taskId))),
      factRow("Type", escapeHtml(h.taskTypeName || h.taskTypeCode)),
      factRow("Status", escapeHtml(h.currentStatusName || h.currentStatusCode)),
