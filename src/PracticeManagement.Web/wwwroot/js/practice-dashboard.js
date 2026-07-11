(() => {
  "use strict";

  const pathBase = (window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "");
  const buildAppUrl = path => {
    path = String(path || "");
    if (!path || path === "#") return path || "#";
    if (/^(?:[a-z][a-z0-9+.-]*:)?\/\//i.test(path)) return path;
    return `${pathBase}/${path.replace(/^\/+/, "")}`;
  };
  const api = window.pmApi || buildAppUrl("practice-management-gateway");
  const apiData = result => result.data?.[0] || result.Data?.[0] || [];
  const apiTables = result => result.data || result.Data || [];
  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, ch => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", "\"":"&quot;", "'":"&#039;" })[ch]);
  const csrfToken = document.querySelector("input[name='__RequestVerificationToken']")?.value || document.querySelector("meta[name='csrf-token']")?.content || "";
  const organizationSelect = document.querySelector("#dashboardOrganization");
  const attentionHost = document.querySelector("#attentionList");

  function loginRedirect() {
    window.location.assign(`${window.location.origin}${buildAppUrl("Login")}?returnUrl=${encodeURIComponent(window.location.pathname + window.location.search)}`);
  }

  async function fetchJson(url, options = {}) {
    const response = await fetch(url, options);
    if (response.status === 401) {
      loginRedirect();
      return null;
    }
    if (!response.ok) throw new Error(`Request failed (${response.status}).`);
    return response.json();
  }

  async function postQuery(entityType, data) {
    return fetchJson(`${api}/${entityType}/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data })
    });
  }

  function setLoading() {
    document.querySelectorAll("[data-summary]").forEach(item => { item.textContent = "-"; });
    if (attentionHost) attentionHost.innerHTML = `<div class="pm-empty compact">Loading dashboard...</div>`;
  }

  function updateSummary(summary) {
    document.querySelectorAll("[data-summary]").forEach(item => {
      const key = item.dataset.summary;
      item.textContent = summary[key] ?? summary[key?.[0]?.toLowerCase() + key?.slice(1)] ?? "0";
    });
  }

  function renderAttention(rows) {
    if (!attentionHost) return;
    rows = rows.filter(row => Number(row.ItemCount ?? row.itemCount ?? 0) > 0);
    attentionHost.innerHTML = rows.length
      ? rows.map(row => {
        const severity = row.Severity || row.severity || "Info";
        const count = row.ItemCount ?? row.itemCount ?? 0;
        const title = row.Title || row.title || "-";
        const detail = row.Detail || row.detail || "";
        const route = row.Route || row.route || "";
        return `<div class="pm-attention-row severity-${escapeHtml(severity).toLowerCase().replace(/\s+/g, "-")}">
          <div><strong>${escapeHtml(title)}</strong><span>${escapeHtml(detail)}</span></div>
          <div class="pm-attention-action"><b>${escapeHtml(count)}</b>${route ? `<a href="${escapeHtml(buildAppUrl(route))}">Open</a>` : ""}</div>
        </div>`;
      }).join("")
      : `<div class="pm-empty compact">No attention items for the selected organization.</div>`;
  }

  async function loadOrganizations() {
    if (!organizationSelect) return "";
    const result = await postQuery("lookups", { pageNumber: 1, pageSize: 1 });
    if (!result || !(result.success ?? result.Success)) throw new Error(result?.message || result?.Message || "Unable to load organizations.");
    const organizations = apiData(result)
      .filter(item => (item.LookupKey || item.lookupKey) === "organizations")
      .map(item => ({ value: item.Value || item.value, label: item.Label || item.label }))
      .filter(item => item.value);
    organizationSelect.innerHTML = organizations.length
      ? organizations.map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")
      : `<option value="">No organizations available</option>`;
    organizationSelect.disabled = organizations.length <= 1;
    return organizations[0]?.value || "";
  }

  async function loadDashboard(organizationId) {
    if (!organizationId) {
      setLoading();
      if (attentionHost) attentionHost.innerHTML = `<div class="pm-empty compact">Select an organization to view dashboard.</div>`;
      return;
    }
    setLoading();
    const result = await postQuery("dashboard-summary", { organizationId: Number(organizationId), pageNumber: 1, pageSize: 1 });
    if (!result || !(result.success ?? result.Success)) throw new Error(result?.message || result?.Message || "Unable to load dashboard.");
    const tables = apiTables(result);
    updateSummary(apiData(result)[0] || {});
    renderAttention(tables[1] || []);
  }

  async function init() {
    try {
      const organizationId = await loadOrganizations();
      if (organizationSelect && organizationId) organizationSelect.value = organizationId;
      await loadDashboard(organizationSelect?.value || organizationId);
      organizationSelect?.addEventListener("change", () => loadDashboard(organizationSelect.value).catch(error => {
        if (attentionHost) attentionHost.innerHTML = `<div class="pm-empty compact">${escapeHtml(error.message)}</div>`;
      }));
    } catch (error) {
      if (attentionHost) attentionHost.innerHTML = `<div class="pm-empty compact">${escapeHtml(error.message)}</div>`;
    }
  }

  init();
})();
