// =====================================================================
// Organization View  (2026-11-02)
// Loaded by Views/Practice/Partials/organization-view.cshtml.
//
// URL: /OrganizationManagement/organization-view?code=<encrypted>
//
// WHAT THIS FILE DOES, AND WHAT IT DELIBERATELY DOES NOT
// --------------------------------------------------------------------
// Reads one organization and lays it out read-only. Three reads, all of
// them calls that already existed before this page:
//
//   POST {gateway}/organizations/query      { id }   -- migration 510's
//        sp_org_organization_list, the same read the Organization
//        Management landing list uses. This is where SpocName comes from.
//   POST {gateway}/organization-setup/query          -- 404's
//        'organization-setup' branch. Table 2 is the metadata definitions
//        with this organization's values; table 3 is the authority /
//        artifact / release tree carrying IsSubscribed.
//   GET  {gateway}/lookups                           -- Time Zone is
//        stored as an id, so its label comes from here.
//   POST {gateway}/subscribed-frameworks/query       -- (2026-11-03) the
//        release owner of each subscribed release (OwnerName), the same
//        read and the same "code - name" text Standards & Frameworks
//        shows. A supporting read (LoginController.SupportingReads), so it
//        needs no grant of its own; allowed to fail -- the owner then
//        reads "Not assigned" and the rest of the page is unaffected.
//
// No new endpoint, no new stored procedure, no new column. Nothing is
// written from this page at all: the only thing that leaves it is
// Actions > Edit, which navigates to Organization Setup.
//
// THE ORGANIZATION IS NEVER IN THE URL. It arrives inside the encrypted
// navigation code the landing list minted (?code=), resolved here through
// the gateway's own navigation-context endpoint -- which re-checks VIEW on
// the target area and rejects a code minted for a different screen. Opened
// without a code, the page says so rather than falling back to some
// organization. Actions > Edit mints a fresh code the same way.
//
// The navigation-code POST and the buildAppUrl helper are small per-file
// copies rather than a shared module, which is this codebase's existing
// convention for a standalone page -- see the note in practice-calendar.js
// .navigateToPractice, which says so for the same two calls.
// =====================================================================
(() => {
  "use strict";

  const U = p => String(window.appBasePath || window.pmPathBase || "").replace(/\/+$/, "") + p;
  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
  const permissions = new Set(window.pmPermissions || []);

  // Resolved in init(), never at parse time. _Layout sets
  // window.appBasePath AFTER @RenderBody, so a U() call made while this
  // partial's <script> is still being parsed would build the URL with an
  // empty base path -- the PathBase trap this codebase has hit before.
  let api = "";

  const state = {
    organizationId: 0,
    displayCode: "",
    displayName: "",
    organization: {},
    attributes: [],
    treeRows: [],
    ownerByRelease: new Map(),
    lookups: {}
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  async function init() {
    if (!document.getElementById("ovRoot")) return;
    api = (window.pmApi || U("/practice-management-gateway")).replace(/\/+$/, "");
    document.getElementById("ovRefreshBtn")?.addEventListener("click", () => { load().catch(showUnavailable); });

    // The page Actions menu, through the shared module every other
    // full-page record view uses. getItems() runs on each open, so Edit is
    // offered only once an organization is actually loaded, and only with
    // the screen's EDIT or ADD grant -- the pair ActionsFor emits for an
    // editable screen, and the same pair the gateway re-checks on the save.
    window.gracPageActions?.attach("ovActionsBtn", () => {
      if (!state.organizationId) return [];
      if (!permissions.has("EDIT") && !permissions.has("ADD")) return [];
      return [{
        icon: "fa-pen-to-square",
        label: "Edit",
        run: () => { openEditPage().catch(error => alert(error.message || "Unable to open the edit page.")); }
      }];
    });

    const code = new URLSearchParams(location.search).get("code") || "";
    if (!code) {
      showUnavailable(null, "No organization was supplied.",
        "Open this page by clicking a row on the Organizations list.");
      return;
    }
    try {
      const context = await getJson(`${api}/navigation-context?code=${encodeURIComponent(code)}&targetArea=organization-view`);
      state.organizationId = Number(context.organizationId || context.OrganizationId
        || context.filterId || context.FilterId || 0);
      state.displayCode = context.displayCode || context.DisplayCode || "";
      state.displayName = context.displayName || context.DisplayName || "";
    } catch (error) {
      // A code is good for 30 minutes (NavigationContextProtector), so a
      // bookmarked or re-opened link lands here. Say that, rather than
      // showing a blank page or someone else's organization.
      showUnavailable(error, "This link is no longer valid.",
        "Organization links expire. Open the organization again from the Organizations list.");
      return;
    }
    if (!state.organizationId) {
      showUnavailable(null, "No organization was supplied.",
        "Open this page by clicking a row on the Organizations list.");
      return;
    }
    await load().catch(showUnavailable);
  }

  async function load() {
    // "time-zones" is deliberately NOT part of the generic /lookups UNION
    // (migration 361; same reason asset-taxonomy is not), so it is its own
    // entity -- exactly as practice.js's ensureTimeZoneLookup fetches it.
    // Both lookup reads are allowed to fail: a missing label degrades one
    // field, it does not fail the page.
    const [lookups, timeZones, orgRows, setupTables, subscribedFrameworks] = await Promise.all([
      getJson(`${api}/lookups`).catch(() => ({})),
      postJson(`${api}/time-zones/query`, { data: { pageNumber: 1, pageSize: 500 } }).catch(() => ({})),
      postJson(`${api}/organizations/query`, { id: state.organizationId, data: { pageNumber: 1, pageSize: 1 } }),
      postJson(`${api}/organization-setup/query`, { data: { organizationId: state.organizationId, pageSize: 200 } }),
      postJson(`${api}/subscribed-frameworks/query`, { search: "", data: { organizationId: state.organizationId } }).catch(() => ({}))
    ]);

    // Release owner per subscribed release (repository_subscription.owner_id).
    const frameworkRows = dataOf(subscribedFrameworks) || [];
    state.ownerByRelease = new Map(
      (Array.isArray(frameworkRows[0]) ? frameworkRows[0] : frameworkRows)
        .filter(row => Number(F(row, "ReleaseId")) > 0)
        .map(row => [String(F(row, "ReleaseId")), String(F(row, "OwnerName") || "").trim()]));

    state.lookups = (dataOf(lookups) || []).reduce((all, item) => {
      const key = item.LookupKey ?? item.lookupKey;
      if (key) (all[key] = all[key] || []).push({
        value: String(item.Value ?? item.value ?? ""),
        label: String(item.Label ?? item.label ?? "")
      });
      return all;
    }, {});
    state.lookups["time-zones"] = ((dataOf(timeZones) || [])[0] || []).map(row => ({
      value: String(F(row, "Value")),
      label: String(F(row, "Label"))
    }));

    const orgTables = dataOf(orgRows) || [];
    state.organization = (orgTables[0] || [])[0] || {};
    const tables = dataOf(setupTables) || [];
    state.attributes = tables[1] || [];
    state.treeRows = tables[2] || [];

    if (!F(state.organization, "Id")) {
      showUnavailable(null, "Organization not found.",
        "It may have been removed, or it is outside the organizations you can see.");
      return;
    }
    render();
    document.getElementById("ovUnavailable").hidden = true;
    document.getElementById("ovRoot").hidden = false;
  }

  // ---- rendering -------------------------------------------------------
  function render() {
    const org = state.organization;
    const code = F(org, "Code");
    const name = F(org, "Name");

    document.getElementById("ovHeading").textContent = name || code || "Organization";
    document.getElementById("ovSubHeading").textContent =
      "Everything recorded for this organization, read-only.";
    document.getElementById("ovTitle").textContent = [code, name].filter(Boolean).join(" - ");
    const chip = document.getElementById("ovStatusChip");
    chip.textContent = F(org, "Status") || "-";

    facts("ovDetails", [
      ["Organisation Short Name", F(org, "Code")],
      ["Organisation Long Name", F(org, "Name")],
      ["Industry", F(org, "Industry")],
      ["Entity Type", F(org, "EntityType")],
      ["SPOC Name", F(org, "SpocName")],
      ["Organisation Status", F(org, "Status")]
    ]);

    const frameworkCount = Number(F(org, "FrameworkCount") || 0);
    facts("ovSubscription", [
      ["Start Date", fmtDate(F(org, "SubscriptionStartDate"))],
      ["End Date", fmtDate(F(org, "SubscriptionEndDate"))],
      ["Selected Standards and Frameworks", frameworkCount
        ? `${frameworkCount} framework${frameworkCount === 1 ? "" : "s"}`
        : ""]
    ]);

    facts("ovAddress", [
      ["Address Line 1", F(org, "AddressLine1")],
      ["Address Line 2", F(org, "AddressLine2")],
      ["City", F(org, "City")],
      ["State / Province", F(org, "StateProvince")],
      ["Pin Code", F(org, "PostalCode")],
      ["Country", lookupLabel("countries", F(org, "Country")) || F(org, "Country")],
      ["Time Zone", lookupLabel("time-zones", F(org, "TimeZoneId"))]
    ]);

    const attributeFacts = state.attributes.map(row => [
      String(F(row, "MetadataName") || F(row, "MetadataKey") || ""),
      attributeValue(row)
    ]).filter(pair => pair[0]);
    document.getElementById("ovAttributesWrap").hidden = attributeFacts.length === 0;
    if (attributeFacts.length) facts("ovAttributes", attributeFacts);

    renderFrameworks();
  }

  // dt/dd pairs into one .ov-facts panel. An empty value gets the
  // codebase's existing "nothing here yet" treatment rather than being
  // dropped, so the shape of the record stays visible.
  function facts(hostId, pairs) {
    const host = document.getElementById(hostId);
    if (!host) return;
    host.innerHTML = pairs.map(([label, value]) => {
      const text = value === null || value === undefined ? "" : String(value).trim();
      return `<div><dt>${escapeHtml(label)}</dt>`
        + (text ? `<dd>${escapeHtml(text)}</dd>` : `<dd class="ov-empty">Not set</dd>`)
        + `</div>`;
    }).join("");
  }

  function renderFrameworks() {
    const host = document.getElementById("ovFrameworks");
    const empty = document.getElementById("ovFrameworksEmpty");
    const subscribed = state.treeRows.filter(row => isTrue(F(row, "IsSubscribed")));
    empty.hidden = subscribed.length > 0;
    host.hidden = subscribed.length === 0;
    if (!subscribed.length) { host.innerHTML = ""; return; }

    // Authority > Artifact > release versions, built in the order the API
    // already sorted them (authority code, artifact code, version).
    const authorities = new Map();
    subscribed.forEach(row => {
      const authorityKey = String(F(row, "AuthorityId") || F(row, "AuthorityCode") || "");
      if (!authorities.has(authorityKey)) {
        authorities.set(authorityKey, {
          title: [F(row, "AuthorityCode"), F(row, "AuthorityName")].filter(Boolean).join(" - "),
          artifacts: new Map()
        });
      }
      const artifacts = authorities.get(authorityKey).artifacts;
      const artifactKey = String(F(row, "ArtifactId") || F(row, "ArtifactCode") || "");
      if (!artifacts.has(artifactKey)) {
        artifacts.set(artifactKey, {
          title: [F(row, "ArtifactCode"), F(row, "ArtifactName")].filter(Boolean).join(" - "),
          releases: []
        });
      }
      artifacts.get(artifactKey).releases.push({
        version: String(F(row, "ReleaseVersion") || ""),
        owner: state.ownerByRelease.get(String(F(row, "ReleaseId"))) || ""
      });
    });

    host.innerHTML = [...authorities.values()].map(authority => `
      <div class="ov-authority">
        <div class="ov-authority-name">${escapeHtml(authority.title)}</div>
        ${[...authority.artifacts.values()].map(artifact => `
          <div class="ov-artifact">
            <span class="ov-artifact-name">${escapeHtml(artifact.title)}</span>
            ${artifact.releases.filter(release => release.version).map(release =>
              `<span class="ov-release-item"><span class="ov-release">${escapeHtml(release.version)}</span>`
              + `<span class="ov-release-owner${release.owner ? "" : " ov-empty"}">Owner: ${escapeHtml(release.owner || "Not assigned")}</span></span>`).join("")}
          </div>`).join("")}
      </div>`).join("");
  }

  // ---- Actions > Edit --------------------------------------------------
  // A fresh navigation code for Organization Setup, so the id stays out of
  // the URL on that hop too. "organization-setup" is the AREA KEY, not the
  // "OrganizationSetup" attribute route: /OrganizationManagement is a
  // PathBase in a hosted deployment but a conventional route on a plain
  // host, and only the area key is correct under both.
  async function openEditPage() {
    const result = await postJson(`${api}/navigation-code`, {
      sourceArea: "organization-view",
      targetArea: "organization-setup",
      filterType: "Organization",
      filterId: state.organizationId,
      organizationId: state.organizationId,
      displayCode: F(state.organization, "Code") || state.displayCode || "",
      displayName: F(state.organization, "Name") || state.displayName || ""
    });
    const code = result.code || result.Code || "";
    window.location.assign(`${U("/organization-setup")}?code=${encodeURIComponent(code)}`);
  }

  // ---- helpers ---------------------------------------------------------
  function showUnavailable(error, title, body) {
    const root = document.getElementById("ovRoot");
    const panel = document.getElementById("ovUnavailable");
    if (root) root.hidden = true;
    if (!panel) return;
    if (title) document.getElementById("ovUnavailableTitle").textContent = title;
    if (body) document.getElementById("ovUnavailableBody").textContent = body;
    else if (error?.message) document.getElementById("ovUnavailableBody").textContent = error.message;
    panel.hidden = false;
    if (error) console.error("Organization View could not load.", error);
  }

  async function getJson(url) {
    const response = await fetch(url, { credentials: "same-origin" });
    return unwrap(response);
  }

  // Returns the whole envelope. Callers that want the result tables run it
  // through dataOf(); navigation-code answers with a top-level "code"
  // instead, and reads that directly.
  async function postJson(url, body) {
    const response = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify(body)
    });
    return unwrap(response);
  }

  async function unwrap(response) {
    const payload = await response.json().catch(() => ({}));
    const ok = payload.success ?? payload.Success;
    if (!response.ok || ok === false) {
      throw new Error(payload.message || payload.Message || `Request failed (HTTP ${response.status}).`);
    }
    return payload;
  }

  const dataOf = payload => payload?.data ?? payload?.Data ?? null;

  // The gateway answers in PascalCase or camelCase depending on the
  // procedure, so every field read goes through this.
  function F(row, name) {
    if (!row) return "";
    const camel = name.charAt(0).toLowerCase() + name.slice(1);
    const value = row[name] ?? row[camel];
    return value === null || value === undefined ? "" : value;
  }

  const isTrue = v => v === true || v === 1 || String(v).toLowerCase() === "true" || String(v) === "1";

  function lookupLabel(key, value) {
    if (value === "" || value === null || value === undefined) return "";
    const match = (state.lookups[key] || []).find(item => item.value === String(value));
    return match ? match.label : "";
  }

  // Same selection parseAttributeValue() makes in practice.js, rendered as
  // text: by DataType, falling back across the value columns so a row whose
  // DataType this page has not seen still shows whatever it holds.
  function attributeValue(row) {
    const dataType = String(F(row, "DataType") || "");
    if (dataType === "Boolean") {
      const raw = row.ValueBool ?? row.valueBool;
      return raw === null || raw === undefined || raw === "" ? "" : (isTrue(raw) ? "Yes" : "No");
    }
    if (dataType === "Json") {
      try {
        const parsed = JSON.parse(String(F(row, "ValueJson") || "[]"));
        return Array.isArray(parsed) ? parsed.join(", ") : String(parsed ?? "");
      } catch { return ""; }
    }
    if (dataType === "Date") return fmtDate(F(row, "ValueDate"));
    const text = F(row, "ValueText");
    if (String(text).trim() !== "") return text;
    const number = F(row, "ValueNumber");
    if (String(number).trim() !== "") return number;
    return fmtDate(F(row, "ValueDate"));
  }

  function fmtDate(value) {
    if (!value) return "";
    if (typeof window.gracFormatDisplayDate === "function") {
      const formatted = window.gracFormatDisplayDate(value);
      if (formatted) return formatted;
    }
    const parsed = new Date(value);
    return isNaN(parsed.getTime()) ? String(value).slice(0, 10) : parsed.toLocaleDateString();
  }

  function escapeHtml(value) {
    if (value === null || value === undefined) return "";
    return String(value).replace(/[&<>"']/g, c =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
})();
