(() => {
  "use strict";

  // Build marker. Type window.pmBuildMarker in the console: if it is
  // undefined, the browser is running a cached copy of this file and no
  // change here can possibly be visible yet.
  window.pmBuildMarker = "practice-view-full-page";

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
  // Rules 3 + 4 — session identity for role-based release/statement gating.
  // dataScope ∈ { GLOBAL, ORGANIZATION, RELEASE, STATEMENT, PRACTICE, INSTANCE }.
  const sessionDataScope = String(window.pmDataScope || "ORGANIZATION").toUpperCase();
  const sessionRoleName = String(window.pmRoleName || "");
  const sessionEmployeeId = String(window.pmEmployeeId || "");
  const isOrgScopedAdmin = sessionDataScope === "GLOBAL" || sessionDataScope === "ORGANIZATION";
  const isEmployeeScope = !isOrgScopedAdmin; // RELEASE/STATEMENT/PRACTICE/INSTANCE
  const rows = document.querySelector("#practiceRows");
  const dialog = document.querySelector("#recordDialog");
  const fieldsHost = document.querySelector("#recordFields");
  // pmCascade top-level attach: this listener MUST live above the
  // organization-workspace early return (line ~5005), otherwise the
  // Add Asset cascade never binds when the group screen is
  // organization-dependencies. Attached to document.body so it works
  // regardless of which of the two #recordFields elements is visible
  // (Manage.cshtml declares one for Add and one for Edit).
  const __pmCascadeChangeHandler = event => {
    window.__pmChangeFires = (window.__pmChangeFires || 0) + 1;
    window.__pmLastFireTarget = event.target?.name || event.target?.tagName;
    const changed = event.target;
    if (!(changed?.name && changed.tagName === "SELECT")) return;
    const host = changed.closest("#recordFields") || fieldsHost;
    const children = host ? host.querySelectorAll(`select[data-parent-field='${changed.name}']`) : [];
    window.__pmLastCascade = {
      changed: changed?.name,
      childCount: children.length,
      hostFound: !!host,
      ranAt: new Date().toISOString()
    };
    if (!children.length) return;

    const stateReady = () => (state.lookups["asset-subcategories"]?.length ?? 0) > 0
                          || (state.lookups["asset-types"]?.length ?? 0) > 0;
    const applyCascade = () => children.forEach(child => {
      const label = child.closest("[data-field-name]");
      const key = label?.getAttribute("data-field-name") || child.name;
      const activeEntity = state.formEntity || (typeof setupState !== "undefined" ? setupState.activeTab : "") || screen.Key;
      let fieldDef = (schemas[activeEntity] || []).find(f => f.name === key);
      if (!fieldDef) {
        for (const list of Object.values(schemas)) {
          const hit = (list || []).find(f => f.name === key);
          if (hit) { fieldDef = hit; break; }
        }
      }
      const lookup = fieldDef?.lookup;
      if (!lookup) return;
      child.innerHTML = optionsFor(lookup, "", changed.value);
      child.value = "";
      child.dispatchEvent(new Event("change", { bubbles: true }));
    });
    if (stateReady()) applyCascade();
    else ensureAssetTaxonomyLookups().then(applyCascade).catch(applyCascade);
  };
  document.body.addEventListener("change", __pmCascadeChangeHandler);
  // pmCommitteeAndTeamClick top-level attach: same reason as pmCascade
  // just above -- the IIFE returns early on organization-workspace screens
  // (see the "if (screen.Key === "organizations" || isOrganizationWorkspace)"
  // guard, later in this file, right before it calls initOrganizationSetup),
  // and both the Team Members tree ("+"/"-" toggle, migration 362) and the
  // Committee Members section (migration 370, change request 2026-09-22)
  // are only ever shown on organization-workspace screens (Organization
  // Administration's Teams / Committees tabs). A listener registered after
  // that early return -- which is where this one originally lived -- would
  // never bind on the only screens that actually use it. Moved up here,
  // mirroring pmCascade, so it survives the early return. Every identifier
  // referenced below (fieldsHost, committeeMemberRow, refreshCommittee-
  // MembersSection, currentFormOrganizationId, fetchJson, api, csrfToken,
  // valueOf, apiData, ensureCommitteeDesignationLookup,
  // committeeDesignationLookupPromise, committeeDesignationDialog) is
  // declared elsewhere in this same top-level scope, so referencing them
  // from a callback that only runs on a later click event is safe
  // regardless of where in the file the addEventListener call itself
  // sits, or the const/let declaration for that matter.
  document.body.addEventListener("click", event => {
    // Team Members tree (migration 362): expand/collapse a Department
    // branch. Pure DOM toggle -- no re-render, no collapsed-Set -- because
    // this tree, unlike renderSubscriptionTree(), is built once per dialog
    // open and has no search box to keep in sync with collapse state.
    const teamTreeToggle = event.target.closest("[data-team-tree-toggle]");
    if (teamTreeToggle) {
      event.preventDefault();
      try {
        const branch = teamTreeToggle.closest(".pm-tree-branch");
        // Explicit class instead of a :scope structural selector -- avoids
        // depending on the wrapper always being "the last div child" and
        // is easier to diagnose if the markup ever changes shape.
        const children = branch ? branch.querySelector(".pm-team-tree-children") : null;
        if (children) {
          children.hidden = !children.hidden;
          teamTreeToggle.textContent = children.hidden ? "+" : "-";
        } else {
          console.error("Team Members tree: no .pm-team-tree-children found for branch", branch);
        }
      } catch (err) {
        console.error("Team Members tree toggle failed:", err);
      }
      return;
    }
    // Committee Members section (migration 370, change request
    // 2026-09-22) -- Add Member / Remove Member / inline Add Designation.
    const addCommitteeMember = event.target.closest("#addCommitteeMemberRow");
    if (addCommitteeMember) {
      event.preventDefault();
      const addRow = addCommitteeMember.closest("[data-committee-member-add-row]");
      const employeeSelect = addRow?.querySelector("[data-committee-add-employee]");
      const designationSelect = addRow?.querySelector("[data-committee-add-designation]");
      const employeeId = employeeSelect?.value || "";
      const designationId = designationSelect?.value || "";
      if (!employeeId) { employeeSelect?.classList.add("field-error"); return; }
      if (!designationId) { designationSelect?.classList.add("field-error"); return; }
      const body = fieldsHost.querySelector("#committeeMemberRows");
      if (!body) return;
      if (!body.querySelector("[data-committee-member-row]")) body.innerHTML = "";
      body.insertAdjacentHTML("beforeend", committeeMemberRow({
        EmployeeId: employeeId,
        Label: employeeSelect.options[employeeSelect.selectedIndex]?.textContent || "",
        DesignationId: designationId
      }, false));
      refreshCommitteeMembersSection();
      return;
    }
    const removeCommitteeMember = event.target.closest(".pm-committee-member-remove");
    if (removeCommitteeMember) {
      event.preventDefault();
      removeCommitteeMember.closest("[data-committee-member-row]")?.remove();
      refreshCommitteeMembersSection();
      return;
    }
    // Add Designation (change request 2026-09-22, revised): opening
    // #committeeDesignationDialog now happens from the Designation combo's
    // own "+ Add New Designation..." option (see the document.body
    // "change" listener below, right after this "click" listener closes)
    // instead of a separate icon-button trigger -- sir flagged two "+"
    // affordances sitting next to each other as confusing. Close/Save
    // still fire from inside the dialog itself, so they stay in this
    // click listener.
    const closeCommitteeDesignation = event.target.closest("#closeCommitteeDesignation, #cancelCommitteeDesignation");
    if (closeCommitteeDesignation) {
      event.preventDefault();
      committeeDesignationDialog?.close();
      return;
    }
    const saveCommitteeDesignation = event.target.closest("#saveCommitteeDesignation");
    if (saveCommitteeDesignation) {
      event.preventDefault();
      const nameInput = document.querySelector("#committeeDesignationName");
      const msg = document.querySelector("#committeeDesignationMessage");
      const name = (nameInput?.value || "").trim();
      if (!name) { nameInput?.classList.add("field-error"); return; }
      const organizationId = currentFormOrganizationId();
      if (!organizationId) {
        if (msg) { msg.hidden = false; msg.textContent = "Select an Organization before adding a Designation."; msg.className = "pm-message error"; }
        return;
      }
      saveCommitteeDesignation.disabled = true;
      fetchJson(`${api}/committee-designations`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id: 0, data: { organizationId: Number(organizationId), designationName: name } })
      }).then(result => {
        const savedId = String(valueOf(apiData(result)[0] || {}, "Id") || "");
        // Force a re-fetch so the new (or matched-existing) designation is
        // in state.lookups before the section re-renders with it selected.
        committeeDesignationLookupPromise = null;
        return ensureCommitteeDesignationLookup().then(() => savedId);
      }).then(savedId => {
        committeeDesignationDialog?.close();
        refreshCommitteeMembersSection();
        if (savedId) {
          const designationSelect = fieldsHost.querySelector("[data-committee-add-designation]");
          if (designationSelect) designationSelect.value = savedId;
        }
      }).catch(error => {
        if (msg) { msg.hidden = false; msg.textContent = error.message || "Unable to add Designation."; msg.className = "pm-message error"; }
      }).finally(() => {
        saveCommitteeDesignation.disabled = false;
      });
      return;
    }
  });
  // Add Designation (change request 2026-09-22, revised): picking
  // "+ Add New Designation..." (COMMITTEE_ADD_NEW_DESIGNATION_VALUE, the
  // last option in the add-row's Designation combo -- see
  // committeeMemberAddRowMarkup) opens #committeeDesignationDialog, the
  // same popup the old icon-button trigger opened. The select is reset to
  // "" right away so the sentinel is never left selected underneath the
  // dialog. A "change" listener (not "click") because the combo option is
  // a real, selectable <option>, not a button. COMMITTEE_ADD_NEW_DESIGNATION_VALUE
  // is declared further down this file (top-level const, same scope) --
  // safe to reference here for the same reason documented at the top of
  // this file: this callback only runs after the whole script has loaded.
  document.body.addEventListener("change", event => {
    const designationSelect = event.target.closest("[data-committee-add-designation]");
    if (!designationSelect || designationSelect.value !== COMMITTEE_ADD_NEW_DESIGNATION_VALUE) return;
    designationSelect.value = "";
    const nameInput = document.querySelector("#committeeDesignationName");
    const msg = document.querySelector("#committeeDesignationMessage");
    if (nameInput) { nameInput.value = ""; nameInput.classList.remove("field-error"); }
    if (msg) { msg.hidden = true; msg.textContent = ""; }
    if (committeeDesignationDialog && !committeeDesignationDialog.open) committeeDesignationDialog.showModal();
    setTimeout(() => nameInput?.focus(), 40);
  });
  const formMessage = document.querySelector("#formMessage");
  const addButton = document.querySelector("#addRecord");
  const saveButton = document.querySelector("#saveRecord");
  const closeButton = document.querySelector("#closeRecord");
  const cancelButton = document.querySelector("#cancelRecord");
  // Manage Source Structure / Statement Classification (change request
  // 2026-09-22) -- a separate <dialog> from #recordDialog, see the markup
  // comment in Manage.cshtml for why it is not reused: it needs to open as
  // a nested popup on top of the Add/Edit Control Statement form without
  // disturbing it.
  const manageStructureDialog = document.querySelector("#manageStructureDialog");
  const manageStructureBody = document.querySelector("#manageStructureBody");
  const manageStructureMessage = document.querySelector("#manageStructureMessage");
  const closeManageStructureBtn = document.querySelector("#closeManageStructure");
  // Manage Statement Classification (change request 2026-09-22, part 2):
  // a SEPARATE popup from Manage Source Structure above -- see the comment
  // above manageClassificationState further down for why.
  const manageClassificationDialog = document.querySelector("#manageClassificationDialog");
  const manageClassificationBody = document.querySelector("#manageClassificationBody");
  const manageClassificationMessage = document.querySelector("#manageClassificationMessage");
  const closeManageClassificationBtn = document.querySelector("#closeManageClassification");
  // Add Designation (change request 2026-09-22) -- lives inside the
  // isOrganizationWorkspace branch of Manage.cshtml (Committees is one of
  // its tabs), so this is null on every other screen, same as
  // manageStructureDialog/manageClassificationDialog above are null on
  // this one; every use is optional-chained. Wired from the Committee
  // Members click-delegation block near the top of this file, not a
  // second addEventListener like the two dialogs above it.
  const committeeDesignationDialog = document.querySelector("#committeeDesignationDialog");
  // View -> Edit (change request 2026-09-20): only present on Location/
  // Department/Teams -- see VIEW_EDIT_ENTITIES and editButton.hidden below.
  const editButton = document.querySelector("#editRecord");
  const search = document.querySelector("#search");
  const status = document.querySelector("#status");
  const organizationFilter = document.querySelector("#organizationFilter");
  const subscribedFrameworkFilter = document.querySelector("#subscribedFrameworkFilter");
  const originTypeFilter = document.querySelector("#originTypeFilter");
  const criticalityFilter = document.querySelector("#criticalityFilter");
  const ownerFilter = document.querySelector("#ownerFilter");
  const dateFromFilter = document.querySelector("#dateFromFilter");
  const dateToFilter = document.querySelector("#dateToFilter");
  // Paging is pm-grid's, not this file's. It renders Previous / range /
  // Next / rows-per-page into #practiceGridPager and owns the page number;
  // this grid sends the page it is given and hands back the total the
  // procedure returns. See docs/grid-and-pagination-standard.md.
  //
  // attach() returns null when the host div or pm-grid.js is missing. Every
  // use below is optional-chained, so the grid then loads page 1 with no
  // pager rather than throwing -- the same degrade path Risk Centre uses.
  const gridPager = window.__pmGrid
    ? window.__pmGrid.attach({ hostId: "practiceGridPager", pageSize: 25, onChange: () => loadRows() })
    : null;
  const bulkApplicabilityButton = document.querySelector("#bulkApplicability");
  const bulkApplicabilityCount = document.querySelector("#bulkApplicabilityCount");
  const refresh = document.querySelector("#refresh");
  const clearFilters = document.querySelector("#clearFilters");
  const tableHead = document.querySelector("#practiceGridHead");
  // Grid wrapper. Carries data-screen-key (set server-side) and, for the
  // two-level Repository Subscriptions screen, data-grid-level so CSS can
  // tell the release summary (Level 1) apart from the statement tree
  // (Level 2) -- they share one screen key but need different widths.
  const tableWrap = document.querySelector(".pm-table-wrap[data-screen-key]");
  const workbenchCategories = document.querySelector("#workbenchCategories");
  const workbenchHeading = document.querySelector("#workbenchHeading");
  const workbenchHint = document.querySelector("#workbenchHint");
  const setupOrganization = document.querySelector("#setupOrganization");
  const setupBasicFields = document.querySelector("#setupBasicFields");
  const setupAttributeFields = document.querySelector("#setupAttributeFields");
  const setupMessage = document.querySelector("#setupMessage");
  const subscriptionTree = document.querySelector("#subscriptionTree");
  const subscriptionSearch = document.querySelector("#subscriptionSearch");
  const recommendFrameworks = document.querySelector("#recommendFrameworks");
  const clearRecommendations = document.querySelector("#clearRecommendations");
  const recommendationSummary = document.querySelector("#recommendationSummary");
  const setupTabs = document.querySelectorAll("[data-setup-tab]");
  const setupPanels = document.querySelectorAll("[data-setup-panel]");
  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
  const query = new URLSearchParams(window.location.search);

  // WHICH ENTITY THE OPEN FORM IS FOR, which is not always the screen
  // behind it. openForm can be handed another entity -- "New Practice
  // Instance" on an Organization Requirement row opens the practice
  // instance form in place rather than navigating away -- and every
  // branch that shapes the FORM has to follow that, not screen.Key.
  //
  // Grid, menu and toolbar branches keep using screen.Key: they are
  // about the page you are on, not the dialog on top of it.
  const formEntity = () => state.formEntity || screen.Key;
  const isFormFor  = key => formEntity() === key;
  const state = { id: 0, mode: "add", records: [], lookups: {}, pageNumber: 1, pageSize: 25, navigationCode: query.get("code") || "", navigationContext: null, activeFormRecord: null, activeDependencies: [], activeEvidence: [], obligationRows: [], obligationFilters: {}, obligationSort: { key: "FrameworkRelease", direction: "asc" }, activeWorkbenchDependencyTypeId: "", activeWorkbenchLabel: "All Dependency Categories" };
  // Applications and Tools tabs were retired on the organization-dependencies
  // page after the Asset taxonomy (migration 239-241) subsumed them. The
  // default tab is now Vendors, matching the new first setupChildTabs entry
  // in Manage.cshtml.
  const setupState = { organizationId: "", activeTab: screen.Key === "organization-dependencies" ? "dependency-vendors" : "organization", childRows: {}, treeRows: [], collapsed: new Set(), selectedReleases: new Set(), attributes: {}, treeInitialized: false, recommendations: new Map(), recommendationAutoSelected: new Set() };
  const isOrganizationOnboarding = screen.Key === "organization-setup";
  const isOrganizationAdministration = screen.Key === "organization-administration";
  const isOrganizationDependencies = screen.Key === "organization-dependencies";
  const isOrganizationWorkspace = isOrganizationOnboarding || isOrganizationAdministration || isOrganizationDependencies;
  const isOperationalizationWorkbench = screen.Key === "resolve" || screen.Key === "practice-operationalization";
  const workbenchScreens = new Set(["workbench-applications", "workbench-tools", "workbench-vendors", "workbench-assets", "workbench-teams", "workbench-committees", "workbench-processes", "workbench-locations"]);
  const organizationScopedScreens = new Set(["organization-metadata", "repository-subscriptions", "locations", "departments", "business-functions", "teams", "committees", "roles", "role-menu-permissions", "users", "dependency-applications", "dependency-tools", "dependency-vendors", "dependency-assets", "dependency-processes", "user-assignments", "user-role-assignments", "owner-mappings", "organization-controls", "control-applicability", "organization-requirements", "practices", "practice-instances", "practice-operationalization", "resolve",
    // 'source-statements' is the auto-drill alias for the organization-controls
    // Source Statements grid (added by migration 056). Treat it as
    // organization-scoped so populateFilters auto-picks the first organization
    // and downstream handlers (subscribed framework filter + grid load) run
    // exactly like the parent organization-controls screen.
    "source-statements",
    ...workbenchScreens]);
  // --- Bulk applicability -------------------------------------------------
  //
  // Ids of the rows ticked for a bulk Mark Applicability. Which id that is
  // differs by screen -- FrameworkStatementId on Source Statements, the
  // organization_requirement id on Practices -- so bulkRowId() owns the choice
  // and nothing else needs to know.
  //
  // SELECTION IS PER LOAD. Every path that refetches the grid clears it, so a
  // page change, a search, a filter or a refresh always leaves the user
  // looking at exactly the rows they are about to change. Keeping a selection
  // alive across pages would mean saving against rows that are no longer on
  // screen, which is the kind of thing nobody notices until it has happened.
  const bulkSelection = new Set();

  // Where bulk applies. Not simply "which screen": the Source Statements
  // screen has two levels, and only the second one lists statements.
  //
  //  * Level 1 is the subscribed-release summary. Those rows carry no
  //    applicability at all, so without this guard every release would read as
  //    "Not Updated" and offer a checkbox that marks nothing.
  //  * A custom (organization-authored) release renders through its own flat
  //    grid, which has no applicability column and its own action set.
  //
  // Organization Practices has one level and is always eligible.
  function bulkEnabled() {
    if (screen.Key === "organization-requirements") return true;
    return isSourceStatements
        && sourceStatementState.level === "statements"
        && !sourceStatementState.isCustomRelease;
  }

  // A row can be ticked only while its applicability has not been decided.
  // Blank counts as Not Updated: a statement with no organization row yet has
  // no status at all, and the grid already renders that as "Not Updated".
  function isBulkEligible(record) {
    if (!bulkEnabled()) return false;
    const status = String(valueOf(record, "ApplicabilityStatus") || "Not Updated").trim().toLowerCase();
    return status === "not updated";
  }

  function bulkRowId(record) {
    const id = isSourceStatements
      ? valueOf(record, "FrameworkStatementId")
      : valueOf(record, "Id");
    return Number(id) || 0;
  }

  // The leading checkbox cell for a row, or an empty cell when the row is not
  // eligible. An empty cell rather than no cell: every row must keep the same
  // number of columns or the table misaligns.
  function bulkCell(record) {
    if (!bulkEnabled()) return "";
    const id = bulkRowId(record);
    if (!id || !isBulkEligible(record)) return `<td class="pm-select-cell"></td>`;
    const checked = bulkSelection.has(id) ? " checked" : "";
    return `<td class="pm-select-cell"><input type="checkbox" class="pm-row-select" data-bulk-id="${escapeHtml(id)}"${checked} aria-label="Select for bulk applicability"></td>`;
  }

  // Header cell matching bulkCell. No select-all: with paging, a select-all
  // that only covers the visible page invites the assumption that it covered
  // the register.
  function bulkHeaderCell() {
    return bulkEnabled() ? `<th class="pm-select-cell"></th>` : "";
  }

  // How many extra leading columns the grid has. Used by every colspan so the
  // loading, empty and error rows still span the table.
  function bulkColumnCount() {
    return bulkEnabled() ? 1 : 0;
  }

  function clearBulkSelection() {
    bulkSelection.clear();
    renderBulkButton();
  }

  // Drops any id that is not among the rows about to be drawn. A client-side
  // status filter can remove an eligible row without refetching, and a
  // selection the user can no longer see must not travel to the server.
  function pruneBulkSelection(records) {
    if (!bulkSelection.size) return;
    const visible = new Set((records || []).map(bulkRowId).filter(Boolean));
    [...bulkSelection].forEach(id => { if (!visible.has(id)) bulkSelection.delete(id); });
    renderBulkButton();
  }

  function renderBulkButton() {
    if (!bulkApplicabilityButton) return;
    // Belt and braces for a level change that did not go through loadRows --
    // drilling back out to the release summary must not leave the button up.
    if (!bulkEnabled()) { bulkApplicabilityButton.hidden = true; return; }
    const count = bulkSelection.size;
    bulkApplicabilityButton.hidden = count === 0;
    if (bulkApplicabilityCount) bulkApplicabilityCount.textContent = count ? ` (${count})` : "";
  }

  const lastOrganizationKey = "grac.practice.selectedOrganizationId";
  let actionMenu = null;
  let actionTrigger = null;
  // Source Statements (organization-controls) two-level drill-down:
  // Level 1 = subscribed Framework Release summary (RS2), Level 2 = Source
  // Structure tree with Source Statement child rows (RS3).
  //
  // The dedicated 'source-statements' screen key (added by migration 056)
  // aliases the same view but auto-drills into the first available release
  // so the Source Statements menu opens directly on the RS3 grid.
  const isSourceStatementDetail = screen.Key === "source-statements";
  const isSourceStatements = screen.Key === "organization-controls" || isSourceStatementDetail;
  const sourceStatementState = { level: "releases", release: null, releases: [], rows: [], collapsedNodes: new Set(), isCustomRelease: false };
  // Authority / Artifact / Version are deliberately absent: FrameworkRelease
  // already reads as "<artifact_code> <version_no>" (see
  // PracticeRepositoryService.QuerySubscribedFrameworksAsync), so three more
  // columns only repeat what the first one says. The underlying fields are
  // still returned by the API and are still used for search and sort.
  // Flat list -- kept because the empty / loading / error rows colspan across
  // it and because it documents the row template's cell count (8).
  const releaseSummaryColumns = ["Framework / Release", "Owner", "Total Statements", "Not Applicable Statements", "Applicable Statements", "Implemented Statements", "Not Updated Statements", "Actions"];
  // The five count columns are rendered under one "Governance Overview" group
  // header, so each of them only has to carry the short word that
  // distinguishes it. Repeating "... Statements" five times widened every
  // count column to the header text instead of the two-digit number in it.
  // Order must match the <td> order in loadReleaseSummary's row template.
  // Sir's requested order: Total, Not Applicable, Applicable, Implemented,
  // Not Updated -- display order only, the underlying counts/fields are
  // unchanged.
  const releaseSummaryMetricColumns = ["Total", "Not Applicable", "Applicable", "Implemented", "Not Updated"];
  // Statement Text is deliberately absent from both grids: the full text is
  // long enough that it had to be truncated to 80 characters anyway, so the
  // column carried no information the row didn't already give. The complete
  // text stays available in the statement view / edit form.
  // Level 2 statement tree. "Statement Reference" is the node hierarchy path and
  // the statement's own reference in one cell (e.g. "REQ-7 / 7.2") -- they were
  // two columns saying nearly the same thing, and the hierarchy already ends in
  // the reference for most releases. Implementation Status is derived server-side
  // from the statement's practice instances (see QueryReleaseStatementsAsync).
  // Each entry carries the cell class the width rules key off.
  const statementTreeColumnDefs = [
    { label: "Statement Reference", cls: "pm-cell-ref" },
    { label: "Statement Title", cls: "pm-cell-title" },
    { label: "Applicability Status", cls: "" },
    { label: "Implementation Status", cls: "" },
    { label: "Practice Count", cls: "" },
    { label: "Actions", cls: "" }
  ];
  const statementTreeColumns = statementTreeColumnDefs.map(column => column.label);
  const customStatementFlatColumns = ["Hierarchy", "Source Structure Node", "Statement Reference", "Statement Title", "Applicability Status", "Practice Count", "Actions"];
  // Source Structure state for custom releases
  const sourceStructureState = { nodes: [], active: false };
  // Statement Classification items for the currently-open Custom Release
  // (change request 2026-09-22, part 2). Populated by
  // loadCustomStatementClassificationOptions()/fetchClassificationOptionsForRelease()
  // against the NEW custom-statement-classification entity -- deliberately
  // NOT derived from sourceStructureState.nodes any more (that was the bug
  // the user pointed out: Statement Classification is not Source Structure).
  const customStatementClassificationState = { items: [] };
  const sourceFilter = document.getElementById("sourceFilter");
  const pageBackBtn = document.getElementById("pageBackBtn");
  // Organization Role Menu Permission matrix (role-menu-permissions).
  const isRolePermissionMatrix = screen.Key === "role-menu-permissions";
  const permissionMatrixColumns = ["Menu", "View", "Add", "Edit", "Inactive", "Approve"];
  const permissionMatrixState = { roleId: "", menus: [], existing: [] };
  const workbenchColumns = ["Name", "OwningDepartment", "PrimaryOwner", "Frequency", "Register", "ResolvedDependencyName", "ResolutionStatus", "ResolutionOwner", "LastUpdated"];
  const setupChildScreens = {
    "locations": { title: "Location", columns: ["Name", "LocationType", "LocationHead", "Region", "Status"] },
    "departments": { title: "Department", columns: ["Code", "Name", "HeadUser", "Status"] },
    "business-functions": { title: "Business Function", columns: ["Code", "Name", "OwnerName", "Criticality", "Status"] },
    // TeamTypeLabel / Vendor come from sp_org_team_list (migration 133).
    "teams": { title: "Teams", columns: ["Name", "TeamTypeLabel", "Vendor", "TeamManager", "ParentDepartment", "Status"] },
    "committees": { title: "Committees", columns: ["Name", "Chairperson", "ReviewFrequency", "Status"] },
    "roles": { title: "Role Master", columns: ["Organization", "RoleName", "Description", "Status"] },
    "role-menu-permissions": { title: "Role Menu Permission", columns: ["Organization", "RoleName", "MenuName", "CanView", "CanAdd", "CanEdit", "CanDelete", "CanApprove", "Status"] },
    // PersonnelType / Provider come from sp_org_user_list (migration 133).
    // PersonnelType sits third so the employee-versus-external split reads
    // at a glance -- that distinction is the first thing an access review
    // asks for, and burying it at the far right defeats the point.
    "users": { title: "Users / Employees", columns: ["EmployeeCode", "EmployeeName", "PersonnelType", "Email", "RoleName", "Provider", "Designation", "Location", "BusinessFunction", "ReportingOfficer", "CredentialStatus", "Status"] },
    "dependency-applications": { title: "Application", columns: ["Name", "BusinessOwner", "TechnicalOwner", "Vendor", "HostingType", "Criticality", "Status"] },
    "dependency-tools": { title: "Tool", columns: ["Name", "BusinessOwner", "Vendor", "LicenseType", "Criticality", "Status"] },
    "dependency-vendors": { title: "Vendor", columns: ["Name", "ServiceCategory", "RelationshipOwner", "Criticality", "Status"] },
    "dependency-assets": { title: "Asset", columns: ["Name", "AssetCategory", "Owner", "Location", "Criticality", "Status"] },
    "dependency-processes": { title: "Process", columns: ["Name", "ProcessOwner", "Version", "NextReviewDate", "Status"] }
  };

  function getSavedOrganizationId() {
    try { return window.localStorage?.getItem(lastOrganizationKey) || ""; }
    catch { return ""; }
  }

  function rememberOrganizationId(value) {
    try {
      if (value) window.localStorage?.setItem(lastOrganizationKey, value);
      else window.localStorage?.removeItem(lastOrganizationKey);
    } catch {
      // Some hardened browser policies block storage access. The filter still works for the current page.
    }
  }

  function currentColumns() {
    return isOperationalizationWorkbench || workbenchScreens.has(screen.Key) ? workbenchColumns : (screen.Columns || []);
  }

  function columnLabel(column) {
    const labels = {
      Name: "Practice Instance Name",
      Chairperson: "Committee Head",
      OwningDepartment: "Department",
      AssuranceMode: "Practice Type",
      AssuranceTypeName: "Assurance Type",
      RetentionPeriod: "Retention Period",
      ResolvedDependencyName: "Resolved Dependencies",
      LastUpdated: "Last Updated"
    };
    return labels[column] || column.replace(/([a-z])([A-Z])/g, "$1 $2");
  }

  function renderGridHeader() {
    if (!tableHead) return;
    tableHead.innerHTML = `<tr>${currentColumns().map(column => `<th>${escapeHtml(columnLabel(column))}</th>`).join("")}<th>Actions</th></tr>`;
  }

  function renderWorkbenchCategories() {
    if (!workbenchCategories) return;
    const wantedRegisters = new Set(["tool", "vendor", "application", "asset", "process", "location", "team", "committee"]);
    const registerLabels = {
      application: "Applications",
      tool: "Tools",
      vendor: "Vendors",
      asset: "Assets",
      process: "Processes",
      location: "Locations",
      team: "Teams",
      committee: "Committees"
    };
    const displayRegisterLabel = item => registerLabels[String(item.label || "").trim().toLowerCase()] || item.label;
    const categories = (state.lookups["dependency-types"] || [])
      .filter(item => String(item.label || "").trim())
      .filter(item => wantedRegisters.has(String(item.label || "").trim().toLowerCase()))
      .sort((a, b) => String(a.label).localeCompare(String(b.label)));
    const selected = String(state.activeWorkbenchDependencyTypeId || "");
    workbenchCategories.innerHTML = [
      ...categories.map(item => `<button type="button" class="${String(item.value) === selected ? "active" : ""}" data-workbench-category="${escapeHtml(item.value)}">${escapeHtml(displayRegisterLabel(item))}</button>`),
      `<button type="button" class="${selected === "evidence" ? "active" : ""}" data-workbench-category="evidence">Evidence</button>`
    ].join("");
    if (!selected && categories.length) {
      state.activeWorkbenchDependencyTypeId = String(categories[0].value);
      state.activeWorkbenchLabel = displayRegisterLabel(categories[0]);
      return renderWorkbenchCategories();
    }
    if (workbenchHeading) workbenchHeading.textContent = selected === "evidence" ? "Evidence" : (state.activeWorkbenchLabel || "Operationalize");
    if (workbenchHint) workbenchHint.textContent = selected === "evidence"
      ? "Showing Practice Instances configured with evidence."
      : `Showing Practice Instances configured with ${state.activeWorkbenchLabel || "selected"} dependency.`;
  }

  const text = (name, label, required = false, extra = {}) => ({ name, label, type: "text", required, ...extra });
  // No password() helper: nobody types another person's password into a form.
  // Users are provisioned with the configured default password by the Web
  // gateway (UserProvisioning:DefaultPassword) and must replace it at first
  // sign-in. See database/208_default_password_provisioning.sql.
  const area =(name, label, required = false, extra = {}) => ({ name, label, type: "textarea", required, full: true, ...extra });
  const select = (name, label, lookup, required = false, extra = {}) => ({ name, label, type: "select", lookup, required, ...extra });
  const number = (name, label, required = false, extra = {}) => ({ name, label, type: "number", required, ...extra });
  const date = (name, label, required = false) => ({ name, label, type: "date", required });
  const hidden = name => ({ name, label: name, type: "hidden" });
  // Organization Practices Applicability Status restriction (2026-09-16,
  // per sir): Deferred and Accepted Risk stay valid for Organization
  // Controls (organization-controls / control-applicability, untouched
  // below) but are no longer offered for Organization Practices
  // (organization-requirements / practices). See the optionsFor comment
  // for how an already-saved legacy value is still shown, just not
  // re-selectable.
  const PRACTICE_APPLICABILITY_STATUSES = ["Not Updated", "Applicable", "Not Applicable", "Retired"];

  // Location / Department / Teams status restriction (2026-09): the
  // "record-status" lookup returns every row in record_status_master
  // (Active, Inactive, Retired, Draft, Disposed, ...) because it is shared
  // by many other masters (committees, dependency-*, role-menu-permissions,
  // dependencies, evidence-configurations) that still need the full set --
  // so the cut happens here, per field, same as PRACTICE_APPLICABILITY_STATUSES
  // above, not by narrowing the shared lookup itself. A location/department/
  // team already saved with a legacy status outside this set still shows
  // and keeps that value on Edit (see optionsFor()'s "keep current value
  // visible" rule); this only narrows what a NEW pick can be. Department
  // already used the pre-filtered "status-active" lookup (Active/Inactive
  // only, hardcoded server-side) before this change and needed no edit.
  const ACTIVE_INACTIVE_ONLY_STATUSES = ["Active", "Inactive"];

  // View -> Edit button (change request 2026-09-20): Location, Department,
  // and Teams only, per the same three entities the status restriction
  // above covers. Checked against screen.Key in openForm() (standalone
  // screens) and against the entity argument in openSetupChildForm()
  // (Organization Administration's nested tabs) -- both already key their
  // own View-layout switches (useLocationViewLayout) the same way, so this
  // reuses that existing per-entity gating style rather than inventing a
  // new one.
  const VIEW_EDIT_ENTITIES = new Set(["locations", "departments", "teams", "business-functions"]);

  const staticLookups = {
    "origin-types": [{ value: "Repository", label: "Repository" }, { value: "Organization", label: "Organization" }, { value: "Hybrid", label: "Hybrid" }],
    "criticality": [{ value: "Critical", label: "Critical" }, { value: "High", label: "High" }, { value: "Medium", label: "Medium" }, { value: "Low", label: "Low" }],
    "assurance-modes": [{ value: "Manual", label: "Manual" }, { value: "Automated", label: "Automated" }],
    // Q13/Q14/Q15 v5 — Implementation Status catalog. Backend auto-syncs
    // implementation_status_id from this text value via trigger
    // tr_pm_practice_instance_impl_status_sync (migration 045).
    "implementation-status": [
      { value: "Not Implemented",        label: "Not Implemented" },
      { value: "Partially Implemented",  label: "Partially Implemented" },
      { value: "Implemented",            label: "Implemented" },
      { value: "Not Applicable",         label: "Not Applicable" }
    ],
    "subscription-types": [{ value: "Automatic", label: "Automatic" }, { value: "Manual", label: "Manual" }],
    "frequency-master": [{ value: "1", label: "Daily" }, { value: "2", label: "Weekly" }, { value: "3", label: "Monthly" }, { value: "4", label: "Quarterly" }, { value: "5", label: "Half-Yearly" }, { value: "6", label: "Annual" }, { value: "7", label: "Event Driven" }, { value: "8", label: "Continuous" }, { value: "9", label: "Custom" }],
    "frequency-units": [{ value: "Day", label: "Day" }, { value: "Week", label: "Week" }, { value: "Month", label: "Month" }, { value: "Quarter", label: "Quarter" }, { value: "Year", label: "Year" }],
    "frequency-units": [{ value: "Day", label: "Day" }, { value: "Week", label: "Week" }, { value: "Month", label: "Month" }, { value: "Year", label: "Year" }],
    "collection-methods": [{ value: "1", label: "Manual" }, { value: "2", label: "Automated" }],
    "assurance-types": [{ value: "1", label: "Manual" }, { value: "2", label: "Automated" }],
    "organization-roles": [{ value: "Owner", label: "Owner" }, { value: "Reviewer", label: "Reviewer" }, { value: "Approver", label: "Approver" }, { value: "Practice Owner", label: "Practice Owner" }, { value: "Evidence Owner", label: "Evidence Owner" }],
    "owner-roles": [{ value: "Primary Owner", label: "Primary Owner" }, { value: "Secondary Owner", label: "Secondary Owner" }, { value: "Practice Owner", label: "Practice Owner" }, { value: "Evidence Owner", label: "Evidence Owner" }, { value: "Location Head", label: "Location Head" }, { value: "Department Head", label: "Department Head" }],
    "evidence-alignment-status": [{ value: "1", label: "Inherited" }, { value: "2", label: "Enhanced" }, { value: "3", label: "Partially Aligned" }, { value: "4", label: "Organization Defined" }],
    // Migration 133. These four labels must stay identical to
    // grac_practice.sp_org_personnel_type_list / sp_org_team_type_list --
    // that procedure is the single source, and the CHECK constraints accept
    // only these codes. Changing a label here and not there leaves the grid
    // and the form disagreeing about the same row.
    "personnel-types": [
      { value: "Employee",   label: "Employee" },
      { value: "ThirdParty", label: "Third-party personnel" }
    ],
    "team-types": [
      { value: "InHouse", label: "In-house" },
      { value: "Vendor",  label: "Vendor-managed" }
    ]
  };
  /* Fallback dependency types — IDs are approximate and may not match actual DB IDENTITY values.
     These are superseded by state.lookups["dependency-types"] once the API lookups load. */
  const fallbackDependencyTypes = [{ value: "1", label: "Application" }, { value: "2", label: "Tool" }, { value: "3", label: "Vendor" }, { value: "4", label: "Asset" }, { value: "5", label: "Process" }, { value: "6", label: "Location" }, { value: "7", label: "Person" }, { value: "8", label: "Team" }, { value: "9", label: "Committee" }];
  const fallbackEvidenceTypes = [{ value: "1", label: "Policy Document" }, { value: "2", label: "Procedure Document" }, { value: "3", label: "System Screenshot" }, { value: "4", label: "System Report" }, { value: "5", label: "Audit Log" }];

  const schemas = {
    "organizations": [text("code", "Organization Short Name", true), text("name", "Organization Name", true), text("industry", "Industry"), text("entityType", "Entity Type"), text("country", "Country"), select("status", "Status", "status-active", true)],
    "organization-metadata": [select("organizationId", "Organization", "organizations", true), text("metadataKey", "Metadata Key", true), text("metadataName", "Metadata Name", true), select("dataType", "Data Type", "data-types", true), area("valueText", "Value"), select("status", "Status", "status-active", true)],
    "repository-subscriptions": [select("organizationId", "Organization", "organizations", true), number("authorityId", "Repository Authority ID"), number("artifactId", "Repository Artifact ID"), number("releaseId", "Repository Release ID"), select("subscriptionType", "Subscription Type", "subscription-types", true), select("subscriptionStatus", "Subscription Status", "subscription-status", true), date("effectiveDate", "Effective Date"), date("endDate", "End Date"), select("status", "Status", "status-active", true)],
    // Time Zone + address (change request 2026-09-20, migration 361):
    // timeZoneId is a select against the "time-zones" lookup, which
    // resolves through PracticeRepositoryService's shim to
    // GRAC_New.time_zone_master (managed in ControlManagement, not here --
    // this module only references it). Country reuses the existing
    // "countries" lookup that Organization's own Country field already
    // uses; City / State-Province / Postal Code have no matching master
    // anywhere in this codebase, so they stay plain text, like Region.
    // Field order is laid out for the 3-column .pm-form-grid-locations grid
    // (practice-management.css): Organization/Name/Type, then Location
    // Head/Time Zone/Region, then the address block (Address Line 1/2 are
    // full-width; City/State/Country share a row; Postal Code/Status share
    // the next), with Remarks (full-width by the area() helper's own
    // default) as the final row. Purely a display-order change -- every
    // field keeps its existing name/lookup/validation, so save/load are
    // unaffected.
    "locations": [select("organizationId", "Organization", "organizations", true), text("name", "Location Name", true), select("locationTypeId", "Location Type", "location-types", true), select("locationHeadId", "Location Head", "users-id"), select("timeZoneId", "Time Zone", "time-zones"), text("region", "Region"), text("addressLine1", "Address Line 1"), text("addressLine2", "Address Line 2"), text("city", "City"), text("stateProvince", "State / Province"), select("country", "Country", "countries"), text("postalCode", "Postal Code"), select("statusId", "Status", "record-status", true, { restrictTo: ACTIVE_INACTIVE_ONLY_STATUSES }), area("remarks", "Remarks")],
    "departments": [select("organizationId", "Organization", "organizations", true), text("code", "Department Short Name", true), text("name", "Department Name", true), select("headUserId", "Department Head", "users-id"), area("description", "Description"), select("status", "Status", "status-active", true)],
    "business-functions": [select("organizationId", "Organization", "organizations", true), text("code", "Function Code", true), text("name", "Function Name", true), select("ownerName", "Owner", "owners"), select("criticality", "Criticality", "criticality", true), select("status", "Status", "status-active", true)],
    // Team Type sits immediately after the name because it decides whether
    // Vendor has to be filled in. Team Manager is unchanged and stays the
    // accountable owner for both types -- a vendor-managed team is still
    // your team, delivered by someone else.
    "teams": [select("organizationId", "Organization", "organizations", true), text("name", "Team Name", true), select("teamType", "Team Type", "team-types", true), select("vendorId", "Vendor", "dependency-vendors"), select("teamManagerId", "Team Manager", "users-id"), select("parentDepartmentId", "Parent Department", "departments"), area("remarks", "Remarks"), { name: "memberIds", label: "Team Members", type: "deptEmployeeTree", lookup: "team-department-employees", full: true }, select("statusId", "Status", "record-status", true, { restrictTo: ACTIVE_INACTIVE_ONLY_STATUSES })],
    "committees": [select("organizationId", "Organization", "organizations", true), text("name", "Committee Name", true), select("chairpersonId", "Committee Head", "users-id"), hidden("secretaryId"), select("reviewFrequencyId", "Review Frequency", "frequency-master"), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "roles": [select("organizationId", "Organization", "organizations", true), text("roleCode", "Role Code"), text("roleName", "Role Name", true), area("description", "Description")],
    "role-menu-permissions": [select("organizationId", "Organization", "organizations", true), select("roleId", "Role", "roles", true), select("menuId", "Menu", "menus", true), { name: "canView", label: "View", type: "checkbox" }, { name: "canAdd", label: "Add", type: "checkbox" }, { name: "canEdit", label: "Edit", type: "checkbox" }, { name: "canDelete", label: "Delete", type: "checkbox" }, { name: "canApprove", label: "Approve", type: "checkbox" }, select("statusId", "Status", "record-status", true)],
    // Personnel Type comes second because it changes what the rest of the
    // form means: a third-party person must name the Provider that supplies
    // them, and their access should not outlive the engagement end date.
    // Provider and the engagement dates are driven by it -- see
    // conditionalFields -- so their labels stay plain.
    "users": [select("organizationId", "Organization", "organizations", true), select("partyType", "Personnel Type", "personnel-types", true), text("employeeCode", "Employee Code / User ID", true), text("employeeName", "Employee Name", true), text("email", "Email ID", true), select("roleId", "Role", "roles", true), text("designation", "Designation"), select("providerVendorId", "Provider", "dependency-vendors"), date("engagementStartDate", "Engagement Start Date"), date("engagementEndDate", "Engagement End Date"), select("locationId", "Location", "locations"), select("departmentId", "Department", "departments", true), select("reportingOfficerId", "Reporting Officer", "users-id"), { name: "isFunctionalUser", label: "Functional User", type: "checkbox" }, select("status", "Status", "status-active", true)],
    "dependency-applications": [select("organizationId", "Organization", "organizations", true), text("name", "Application Name", true), area("description", "Description"), select("businessOwnerId", "Business Owner", "owners-id"), select("technicalOwnerId", "Technical Owner", "owners-id"), select("vendorId", "Vendor", "dependency-vendors"), text("version", "Version"), select("hostingTypeId", "Hosting Type", "hosting-types"), date("supportExpiryDate", "Support Expiry Date"), date("endOfLifeDate", "End of Life Date"), select("criticalityId", "Criticality", "criticality-master", true), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "dependency-tools": [select("organizationId", "Organization", "organizations", true), text("name", "Tool Name", true), area("description", "Description"), select("businessOwnerId", "Business Owner", "owners-id"), select("vendorId", "Vendor", "dependency-vendors"), select("licenseTypeId", "License Type", "license-types"), date("licenseExpiryDate", "License Expiry Date"), date("supportExpiryDate", "Support Expiry Date"), select("criticalityId", "Criticality", "criticality-master", true), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "dependency-vendors": [select("organizationId", "Organization", "organizations", true), text("name", "Vendor Name", true), select("serviceCategoryId", "Service Category", "service-categories", true), select("relationshipOwnerId", "Relationship Owner", "owners-id"), date("contractStartDate", "Contract Start Date"), date("contractEndDate", "Contract End Date"), date("renewalDate", "Renewal Date"), { name: "slaApplicable", label: "SLA Applicable", type: "checkbox" }, select("criticalityId", "Criticality", "criticality-master", true), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "dependency-assets": [select("organizationId", "Organization", "organizations", true), text("name", "Asset Name", true), select("assetCategoryId", "Asset Category", "asset-categories", true), select("assetSubcategoryId", "Asset Sub Category", "asset-subcategories", false, { parentField: "assetCategoryId" }), select("assetTypeId", "Asset Type", "asset-types", false, { parentField: "assetSubcategoryId" }), select("ownerId", "Owner", "owners-id"), select("locationId", "Location", "locations"), date("purchaseDate", "Purchase Date"), date("warrantyExpiryDate", "Warranty Expiry Date"), date("amcExpiryDate", "AMC Expiry Date"), select("criticalityId", "Criticality", "criticality-master", true), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "dependency-processes": [select("organizationId", "Organization", "organizations", true), text("name", "Process Name", true), select("processOwnerId", "Process Owner", "owners-id"), text("version", "Version"), date("effectiveDate", "Effective Date"), date("lastReviewDate", "Last Review Date"), date("nextReviewDate", "Next Review Date"), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "user-assignments": [select("organizationId", "Organization", "organizations", true), select("departmentId", "Department", "departments"), select("userId", "User", "users-id", true), select("role", "Role", "organization-roles", true), select("status", "Status", "status-active", true)],
    "owner-mappings": [select("organizationId", "Organization", "organizations", true), select("role", "Owner Role", "owner-roles", true), select("ownerUserId", "Owner", "owners-id", true), select("backupOwnerUserId", "Backup Owner", "owners-id"), select("status", "Status", "status-active", true)],
    "organization-controls": [select("organizationId", "Organization", "organizations", true), text("code", "Statement Code", true), text("name", "Statement Name", true), area("description", "Description"), area("objective", "Objective"), area("businessJustification", "Business Justification"), select("status", "Status", "status-active", true)],
    "control-applicability": [select("organizationId", "Organization", "organizations", false, { readonly: true }), text("code", "Control Code", false, { readonly: true }), text("name", "Control Name", false, { readonly: true }), select("originType", "Origin Type", "origin-types", false, { readonly: true }), text("isManuallyAdded", "Manually Added", false, { readonly: true }), select("applicabilityStatus", "Applicability Status", "applicability-status", true), area("exclusionJustification", "Justification"), select("primaryOwner", "Primary Owner", "owners"), select("secondaryOwner", "Secondary Owner", "owners"), select("businessFunctionId", "Business Function", "business-functions"), select("criticality", "Criticality", "criticality", true), select("status", "Status", "status-active", true)],
    "organization-requirements": [select("organizationId", "Organization", "organizations", true), hidden("originType"), hidden("applicabilityStatus"), hidden("status"), hidden("implementationStatus"), text("code", "Practice Code", true), text("name", "Practice Name", true), area("statement", "Description"), select("practiceOwnerId", "Owner", "owners-id"), select("businessFunctionId", "Business Function", "business-functions"), select("criticality", "Criticality", "criticality"), area("remarks", "Remarks")],
    "practices": [select("organizationId", "Organization", "organizations", true), hidden("organizationRequirementId"), select("originType", "Origin Type", "origin-types", true), text("code", "Practice Code", true), text("name", "Practice Name", true), area("description", "Description"), select("applicabilityStatus", "Applicability Status", "applicability-status", true, { restrictTo: PRACTICE_APPLICABILITY_STATUSES }), select("practiceOwnerId", "Owner", "owners-id"), area("exclusionJustification", "Reason / Justification"), select("status", "Status", "status-active", true)],
    "practice-instances": [hidden("organizationRequirementId"), hidden("practiceId"), select("organizationId", "Organization", "organizations", true, { readonly: true }), text("code", "Instance Code", true), text("name", "Instance Name", true), select("primaryOwnerId", "Instance Owner", "owners-id", true), hidden("departmentId"), text("department", "Owner Department", false, { readonly: true }), select("businessFunctionId", "Business Function", "business-functions"), select("executionFrequencyId", "Execution Frequency", "frequency-master", true), select("assuranceFrequencyId", "Assurance Frequency", "frequency-master", true), select("assuranceMode", "Practice Type", "assurance-modes", true), select("criticality", "Criticality", "criticality", true), select("implementationStatus", "Implementation Status", "implementation-status", false, { readonly: true }), { name: "dependencyTypeIds", label: "Dependencies", type: "comboChecks", lookup: "dependency-types" }, { name: "evidenceTypeIds", label: "Evidence Types", type: "comboChecks", lookup: "evidence-types" }, select("status", "Status", "status-active", true)],
    "dependencies": [select("practiceInstanceId", "Practice Instance", "practice-instances", true), select("dependencyTypeId", "Dependency Type", "dependency-types", true), text("name", "Dependency Name", true), text("reference", "Reference"), text("ownerName", "Owner"), select("criticalityId", "Criticality", "criticality-master", true), select("statusId", "Status", "record-status", true)],
    "evidence-configurations": [select("practiceInstanceId", "Practice Instance", "practice-instances", true), select("evidenceTypeId", "Evidence Type", "evidence-types", true), select("assuranceTypeId", "Assurance Type", "assurance-types", true), text("retentionPeriod", "Retention Period"), select("collectionMethodId", "Collection Method", "collection-methods", true), select("collectionFrequencyId", "Collection Frequency", "frequency-master"), select("evidenceOwner", "Evidence Owner", "owners"), select("statusId", "Status", "record-status", true)]
  };
  // Organization Administration screens where Status is not worth asking for on
  // create: a record someone is adding right now is always Active, and making
  // them pick it is a required field that can only be answered one way.
  //
  // The field is dropped from the Add form only. It stays on Edit because
  // "Inactive/Delete" is a one-way row action -- the Edit dropdown is the only
  // way to bring a retired row back to Active.
  //
  // Safe to omit from the payload: every one of these branches in
  // pm_manage_practice_repository already defaults an INSERT to Active --
  // COALESCE(@payload_record_status_id, @active_record_status_id) for the
  // statusId-based entities, COALESCE(JSON_VALUE(...'$.status'),'Active') for
  // the status-text ones. collectForm still sends status='Active' explicitly so
  // the intent is visible in the payload rather than implied by the SP.
  const statusHiddenOnAddScreens = new Set([
    "locations", "departments", "business-functions", "teams", "committees", "users"
  ]);

  // Single source for "which fields does this entity's form show". Both entry
  // points render the same schemas -- openForm/schemaFor for the standalone
  // screens, openSetupChildForm for the Organization Setup tabs -- so the
  // Add-time Status removal has to live in one place or the two drift.
  // =====================================================================
  // Practice Instance form slimming — stage 1
  //
  // These four inputs are no longer captured when EDITING an instance,
  // because the value they hold is owned somewhere else now:
  //
  //   executionFrequencyId / assuranceFrequencyId
  //       Migration 145 defaults them from the parent practice's
  //       obligations (vw_pm_practice_default_frequency), and Resolve
  //       records the real per-obligation cadence in
  //       practice_instance_obligation. Typing them again here only
  //       created a second, divergent answer.
  //   implementationStatus
  //       Driven by the implementation task flow (migration 043).
  //   evidenceTypeIds
  //       Captured per obligation on the Resolve screen.
  //
  // TWO DIFFERENT TREATMENTS, ON PURPOSE
  //   The frequencies become hidden fields rather than being dropped.
  //   dbo.pm_manage_practice_repository still THROWs 51038 / 51039 when
  //   the payload carries no frequency, and its UPDATE assigns the
  //   frequency columns unconditionally — an absent key would blank the
  //   value migration 145 derived. Round-tripping the loaded value
  //   through a hidden input keeps the save byte-identical to today's
  //   while taking the control off the screen. Making the procedure
  //   tolerate an absent frequency is stage 2's job, together with the
  //   rest of the move into Resolve.
  //
  //   implementationStatus and evidenceTypeIds are dropped outright:
  //   the procedure already COALESCEs implementation_status to its
  //   stored value, and evidence rows are child records that are simply
  //   left alone when the form does not mention them (see the guard in
  //   collectEvidence).
  //
  // ADD IS UNCHANGED. Creating an instance from this form still has to
  // state a frequency — there is nothing stored to fall back on yet, and
  // 51038 is the only thing standing between that and an instance with
  // no cadence. Migration 139's Configure remains the normal way to
  // create instances, and it fills all four from the team + obligations.
  // =====================================================================
  const practiceInstanceHiddenOnEdit = new Set(["executionFrequencyId", "assuranceFrequencyId"]);
  const practiceInstanceDroppedOnEdit = new Set(["implementationStatus", "evidenceTypeIds"]);

  function entitySchema(entityKey, mode) {
    const fields = schemas[entityKey] || [];
    if (mode !== "add" || !statusHiddenOnAddScreens.has(entityKey)) return fields;
    // Both spellings appear across these schemas: statusId (record-status
    // lookup, value = record_status_id) and status (status-active lookup,
    // value = status_code). Drop whichever this entity uses.
    return fields.filter(field => field.name !== "status" && field.name !== "statusId");
  }
  const setupBasicSchema = [
    text("code", "Organization Short Name", true),
    text("name", "Organization Name", true),
    select("industry", "Industry", "industries", true),
    select("entityType", "Entity Type", "entity-types", true),
    select("country", "Country", "countries", true),
    select("status", "Status", "status-active", true),
    // Rule 1 + Rule 6 — every new org gets an auto-provisioned
    // Organisation GRAC Admin. Operator must supply the admin email at
    // creation time so credentials can be sent (best-effort).
    text("adminEmail", "Admin Email (Org GRAC Admin)", true),
    text("adminName", "Admin Full Name")
  ];
  const setupAttributeSchema = [
    select("deposit_taking_status", "Deposit Taking Status", "yes-no"),
    select("asset_size_scale", "Asset Size / Scale Classification", "asset-size-scale"),
    select("regulatory_registration_type", "Regulatory Registration Type", "regulatory-registration-types"),
    select("payment_aggregator_status", "Payment Aggregator Status", "yes-no"),
    select("investment_advisor_status", "Investment Advisor Status", "yes-no"),
    select("cloud_adoption", "Cloud Adoption", "adoption-levels"),
    { name: "stores_cardholder_data", label: "Stores Cardholder Data", type: "checkbox" },
    { name: "geographic_presence", label: "Geographic Presence", type: "comboChecks", lookup: "countries" },
    { name: "business_functions", label: "Business Operations", type: "comboChecks", lookup: "business-function-types" },
    { name: "technology_landscape", label: "Technology Landscape", type: "comboChecks", lookup: "technology-landscape" }
  ];
  const actionDefinitions = {
    "organizations": ["view", "edit", "manage", "inactive"],
    "organization-metadata": ["view", "edit", "configure", "inactive"],
    // "inactive" removed from these two: Location/Department status is
    // restricted to Active/Inactive via the Edit form's Status dropdown
    // only -- see the Status-restriction work alongside this. No 3-dot
    // action replaces it; Edit is still available and is the only way to
    // change status now.
    "locations": ["view", "edit"],
    "departments": ["view", "edit"],
    // "inactive" removed (2026-09): same restriction as locations/departments
    // above -- status changes go only through the Edit form now.
    "teams": ["view", "edit"],
    // "inactive" removed (change request 2026-09): Business Function status
    // changes go only through the Edit form now, same as locations/departments/teams.
    "business-functions": ["view", "edit"],
    "committees": ["view", "edit", "inactive"],
    "roles": ["view", "edit", "inactive"],
    "role-menu-permissions": ["view", "edit", "inactive"],
    "users": ["view", "edit", "resendCredentials", "inactive"],
    "dependency-applications": ["view", "edit", "inactive"],
    "dependency-tools": ["view", "edit", "inactive"],
    "dependency-vendors": ["view", "edit", "inactive"],
    "dependency-assets": ["view", "edit", "inactive"],
    "dependency-processes": ["view", "edit", "inactive"],
    "user-assignments": ["view", "edit", "inactive"],
    "user-role-assignments": ["manageRoles", "view"],
    "owner-mappings": ["view", "edit", "inactive"],
    "applicability-discovery": ["view", "accept", "reject"],
    "applicability-results": ["view", "accept", "reject"],
    "repository-subscriptions": ["view", "subscribe", "edit", "inactive"],
    "repository-import": ["view", "map", "manage"],
    "organization-controls": ["view", "markApplicability", "updateApplicability", "practices", "edit", "inactive"],
    // "viewObligations" was retired here: the full-page View
    // (practice-view.cshtml) renders the obligations panel itself, so the
    // 3-dot menu offered a second route to something View already shows.
    // The dialog it opened is still reachable from the Practice Instance
    // evidence section (#viewEvidenceObligations).
    // "instances" was retired from this screen: the Practice View lists every
    // instance under the practice, and Operationalize is where an instance is
    // actually worked on, so a third route to the same rows was noise.
    // Retired here only -- the "practices" screen below still offers it.
    "organization-requirements": ["view"],
    "control-applicability": ["view", "edit"],
    "requirement-applicability": ["view", "edit", "accept", "reject", "practice"],
    "practices": ["view"],
    // "configure", "evidence", "dependencies" removed per PR feedback --
    // these were standalone landing pages that duplicated fields already
    // available inside the main Edit form (Configure Frequencies /
    // Dependencies combo-checks / Evidence Types combo-checks) and the
    // inline obligations reference panel. Kept the router branches for
    // those action names in handleAction() so any deep-link URL still
    // works, but the row menu no longer surfaces them.
    "practice-instances": ["view", "edit", "inactive"],
    "resolve": ["resolveDependencies", "viewOperationalization"],
    "practice-operationalization": ["resolveDependencies", "viewOperationalization"],
    "workbench-applications": ["resolveDependencies", "modifyDependencies", "viewOperationalization"],
    "workbench-tools": ["resolveDependencies", "modifyDependencies", "viewOperationalization"],
    "workbench-vendors": ["resolveDependencies", "modifyDependencies", "viewOperationalization"],
    "workbench-assets": ["resolveDependencies", "modifyDependencies", "viewOperationalization"],
    "workbench-teams": ["resolveDependencies", "modifyDependencies", "viewOperationalization"],
    "workbench-committees": ["resolveDependencies", "modifyDependencies", "viewOperationalization"],
    "workbench-processes": ["resolveDependencies", "modifyDependencies", "viewOperationalization"],
    "workbench-locations": ["resolveDependencies", "modifyDependencies", "viewOperationalization"],
    "dependencies": ["view", "edit", "inactive"],
    "evidence-configurations": ["view", "configure", "edit", "inactive"],
    "assurance-attributes": ["view", "configure", "edit"],
    "vendor-attributes": ["view", "configure", "edit"],
    "risk-attributes": ["view", "configure", "edit"],
    "audit-attributes": ["view", "configure", "edit"],
    "task-attributes": ["view", "configure", "edit"],
    "resilience-attributes": ["view", "configure", "edit"],
    "future-triggers": ["view", "accept", "reject", "configure"],
    "audit-trace": ["view"]
  };
  // The dedicated Source Statements screen renders the SAME statement grid as
  // the organization-controls drill-down (renderStatementTree /
  // statementTreeColumns) and handleAction already routes both through the
  // isSourceStatements branch. Alias rather than copy the list so the two
  // screens cannot drift apart.
  actionDefinitions["source-statements"] = actionDefinitions["organization-controls"];
  const actionLabels = {
    view: "View",
    edit: "Edit",
    inactive: "Inactive/Delete",
    manage: "Manage",
    // Rule 3 — release-level actions on the Source Statements Level 1 grid.
    releaseView: "View Statements",
    releaseEdit: "Edit Release",
    releaseRetire: "Retire Release",
    releaseUpdateOwner: "Update Owner",
    // Rule 6 — best-effort "Resend credentials" action on the Users tab.
    resendCredentials: "Resend Credentials",
    markApplicability: "Mark Applicability",
    updateApplicability: "Update Applicability",
    configure: "Configure",
    map: "Map",
    subscribe: "Subscribe",
    accept: "Accept",
    reject: "Reject",
    practices: "Practices",
    manageRoles: "Manage Roles",
    viewOperationalization: "View Resolve Details",
    resolveDependencies: "Resolve",
    modifyDependencies: "Modify Dependencies",
    bulkResolution: "Bulk Resolution",
    dependencyIntelligence: "Dependency Intelligence",
    instances: "Practice Instances",
    // Creating an instance under a requirement. The Practice Instances
    // screen lost its menu row to migration 288, so this row action is
    // now the way in to its add form.
    newInstance: "New Practice Instance",
    evidence: "Evidence Configuration",
    dependencies: "Dependencies"
  };
  const actionIcons = {
    view: "fa-eye",
    edit: "fa-pen",
    inactive: "fa-ban",
    manage: "fa-sliders",
    releaseView: "fa-eye",
    releaseEdit: "fa-pen",
    releaseRetire: "fa-ban",
    releaseUpdateOwner: "fa-user-gear",
    resendCredentials: "fa-envelope",
    markApplicability: "fa-clipboard-check",
    updateApplicability: "fa-clipboard-check",
    configure: "fa-gear",
    map: "fa-diagram-project",
    subscribe: "fa-bell",
    accept: "fa-check",
    reject: "fa-xmark",
    practices: "fa-list-check",
    manageRoles: "fa-user-gear",
    viewOperationalization: "fa-eye",
    resolveDependencies: "fa-link",
    modifyDependencies: "fa-pen-to-square",
    bulkResolution: "fa-layer-group",
    dependencyIntelligence: "fa-brain",
    instances: "fa-layer-group",
    newInstance: "fa-square-plus",
    evidence: "fa-folder-open",
    dependencies: "fa-link"
  };

  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, ch => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", "\"":"&quot;", "'":"&#039;" })[ch]);
  const valueOf = (row, name) => row?.[name] ?? row?.[name[0]?.toUpperCase() + name.slice(1)] ?? "";
  const boolOf = (row, name, fallback = false) => {
    const value = valueOf(row, name);
    if (value === "" || value === null || value === undefined) return fallback;
    if (typeof value === "boolean") return value;
    if (typeof value === "number") return value === 1;
    return ["true", "1", "yes", "y"].includes(String(value).toLowerCase());
  };
  function unwrapApiValue(value) {
    if (typeof value === "string") {
      const text = value.trim();
      if ((text.startsWith("{") && text.endsWith("}")) || (text.startsWith("[") && text.endsWith("]"))) {
        try { return unwrapApiValue(JSON.parse(text)); }
        catch { return value; }
      }
    }
    if (value && typeof value === "object" && Array.isArray(value.$values)) {
      return value.$values.map(unwrapApiValue);
    }
    if (Array.isArray(value)) return value.map(unwrapApiValue);
    return value;
  }

  function apiTables(result) {
    const data = unwrapApiValue(result?.data ?? result?.Data ?? []);
    if (!Array.isArray(data)) return [];
    const isDirectRowSet = data.length > 0 && !Array.isArray(data[0]) && typeof data[0] === "object";
    return isDirectRowSet ? [data] : data;
  }

  function apiData(result) {
    const tables = apiTables(result);
    const first = unwrapApiValue(tables[0] ?? []);
    if (Array.isArray(first)) return first;
    if (first && typeof first === "object") return [first];
    return [];
  }

  function listColumnCount() {
    return currentColumns().length + 1 + bulkColumnCount();
  }

  function setListMessage(message, cssClass = "pm-empty") {
    if (!rows) return;
    rows.innerHTML = `<tr><td colspan="${listColumnCount()}" class="${cssClass}">${escapeHtml(message)}</td></tr>`;
  }

  function listEntityKey() {
    if (screen.Key === "resolve") return "resolve";
    if (isOperationalizationWorkbench) return "workbench-all";
    return screen.Key;
  }

  function logListTrace(stage, details = {}) {
    const entry = {
      screen: screen.Key,
      pageNumber: state.pageNumber,
      pageSize: state.pageSize,
      ...details
    };
    if (stage === "error") console.error("PracticeManagement list error", entry);
    else console.info(`PracticeManagement list ${stage}`, entry);
  }

  function dedupeLookupItems(items = []) {
    const seen = new Set();
    return items.filter(item => {
      const key = `${String(item.organizationId || "")}|${String(item.label || "").trim().toLowerCase() || String(item.value || "").trim().toLowerCase()}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }

  async function fetchJson(url, options = {}) {
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 45000);
    let response;
    try {
      response = await fetch(url, { ...options, signal: options.signal || controller.signal });
    } catch (error) {
      if (error.name === "AbortError") throw new Error("The practice service did not respond in time. Please retry or check the API logs.");
      throw error;
    } finally {
      window.clearTimeout(timeout);
    }
    let result;
    try { result = await response.json(); }
    catch {
      // A non-JSON body from a JSON endpoint is a server-side crash, not a
      // business failure -- the status code is the only thing left to go
      // on, so name it. This used to swallow every permission denial:
      // the gateway answered ControllerBase.Forbid(), which throws on this
      // app (no authentication scheme is registered), and the HTML error
      // page that came back landed here as "invalid response". The gateway
      // now returns JSON for those, so reaching this line means something
      // genuinely unexpected happened.
      throw new Error(`The practice service returned an invalid response (HTTP ${response.status}). Check the Practice Management Web log for this request.`);
    }
    if (response.status === 401) {
      window.location.assign(`${window.location.origin}${buildAppUrl("Login")}?returnUrl=${encodeURIComponent(window.location.pathname + window.location.search)}`);
      throw new Error(result.message || result.Message || "Session expired. Please sign in again.");
    }
    // The server's own message names the missing grant (which menu, which
    // action) or the organization that is out of scope. The generic
    // sentence is only the fallback for a body that carries neither.
    if (response.status === 403) throw new Error(result.message || result.Message || "You do not have permission to perform this action.");
    if (response.status === 400) throw new Error(result.message || result.Message || "The request is invalid or has expired.");
    if (!(result.success ?? result.Success)) {
      const error = new Error(result.message || result.Message || "Request failed.");
      // Set by the API when a stored-procedure validation THROW is
      // attributable to one payload key (PracticeRepositoryResult.Field).
      // The save handler marks that input instead of only printing the
      // message above the form.
      error.field = result.field || result.Field || "";
      throw error;
    }
    return result;
  }

  // Puts a server-side validation failure on the input it is about. Falls back
  // to the form-level message when the failure names no field, or names one
  // this form does not render.
  function showFormError(error) {
    fieldsHost?.querySelectorAll(".field-error").forEach(input => input.classList.remove("field-error"));
    const input = error.field ? fieldsHost?.querySelector(`[name="${error.field}"]`) : null;
    if (input) {
      input.classList.add("field-error");
      input.focus();
      const wrapper = input.closest("[data-field-name]");
      if (wrapper) wrapper.scrollIntoView({ behavior: "smooth", block: "nearest" });
    }
    formMessage.textContent = error.message;
    formMessage.hidden = false;
  }

  async function createNavigationCode(payload) {
    const result = await fetchJson(`${api}/navigation-code`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify(payload)
    });
    return result.code || result.Code || "";
  }

  async function createPracticeInstanceChildContext(practiceInstanceId, targetArea) {
    if (!practiceInstanceId) return "";
    return createNavigationCode({
      sourceArea: "practice-instances",
      targetArea,
      filterType: "PracticeInstance",
      filterId: Number(practiceInstanceId),
      organizationId: Number(valueOf(state.activeFormRecord, "OrganizationId") || valueOf(state.activeFormRecord, "organizationId") || organizationFilter?.value || 0) || null,
      organizationControlId: state.navigationContext?.organizationControlId ? Number(state.navigationContext.organizationControlId) : null,
      organizationRequirementId: Number(valueOf(state.activeFormRecord, "OrganizationRequirementId") || valueOf(state.activeFormRecord, "organizationRequirementId") || state.navigationContext?.organizationRequirementId || 0) || null,
      displayCode: valueOf(state.activeFormRecord, "Code") || "",
      displayName: valueOf(state.activeFormRecord, "Name") || ""
    });
  }

  async function loadNavigationContext() {
    if (!state.navigationCode) return;
    const result = await fetchJson(`${api}/navigation-context?code=${encodeURIComponent(state.navigationCode)}&targetArea=${encodeURIComponent(screen.Key)}`);
    state.navigationContext = {
      filterType: result.filterType || result.FilterType || "",
      filterId: result.filterId || result.FilterId || "",
      organizationId: result.organizationId || result.OrganizationId || "",
      releaseId: result.releaseId || result.ReleaseId || "",
      organizationControlId: result.organizationControlId || result.OrganizationControlId || "",
      organizationRequirementId: result.organizationRequirementId || result.OrganizationRequirementId || "",
      displayCode: result.displayCode || result.DisplayCode || "",
      displayName: result.displayName || result.DisplayName || "",
      displayStatus: result.displayStatus || result.DisplayStatus || ""
    };
    if ((state.navigationContext.filterType === "Organization" || state.navigationContext.organizationId) && organizationFilter) {
      const organizationId = String(state.navigationContext.organizationId || state.navigationContext.filterId || "");
      if (organizationId && ![...organizationFilter.options].some(option => option.value === organizationId)) {
        organizationFilter.add(new Option(state.navigationContext.displayCode || state.navigationContext.displayName || `Organization ${organizationId}`, organizationId));
      }
      organizationFilter.value = organizationId;
      rememberOrganizationId(organizationId);
      organizationFilter.disabled = Boolean(organizationId);
    }
    const heading = document.querySelector(".pm-page-heading h1");
    if (heading && state.navigationContext.displayCode) {
      heading.textContent = `${screen.Title} - ${state.navigationContext.displayCode}`;
    }
    if ((screen.Key === "organization-requirements" && ["OrganizationControl", "FrameworkStatement"].includes(state.navigationContext.filterType))
      || (screen.Key === "practices" && state.navigationContext.filterType === "OrganizationRequirement")
      || (screen.Key === "practice-instances" && ["Practice", "OrganizationRequirement"].includes(state.navigationContext.filterType))) {
      const panel = document.querySelector(".pm-panel");
      if (panel && !document.querySelector("#controlContextSummary")) {
        const summary = document.createElement("div");
        summary.id = "controlContextSummary";
        summary.className = "pm-context-summary";
        summary.innerHTML = `<strong>${escapeHtml(state.navigationContext.displayCode || "Selected Control")}</strong><span>${escapeHtml(state.navigationContext.displayName || "")}</span>${state.navigationContext.displayStatus ? `<em>${escapeHtml(state.navigationContext.displayStatus)}</em>` : ""}`;
        panel.prepend(summary);
      }
    }
  }

  async function loadLookups() {
    try {
      const result = await fetchJson(`${api}/lookups`);
      const items = apiData(result);
      state.lookups = items.reduce((all, item) => {
        const key = item.LookupKey ?? item.lookupKey;
        const organizationId = item.OrganizationId ?? item.organizationId ?? item.OrganizationID ?? item.organizationID ?? "";
        (all[key] ||= []).push({
          value: item.Value ?? item.value,
          label: item.Label ?? item.label,
          organizationId: String(organizationId || ""),
          departmentId: String(item.DepartmentId ?? item.departmentId ?? ""),
          departmentName: item.DepartmentName ?? item.departmentName ?? ""
        });
        return all;
      }, { ...staticLookups });
      Object.keys(state.lookups).forEach(key => { state.lookups[key] = dedupeLookupItems(state.lookups[key]); });
    } catch {
      state.lookups = { ...staticLookups };
    }
    state.lookups["frequency-master"] = state.lookups["frequency-master"]?.length ? state.lookups["frequency-master"] : staticLookups["frequency-master"];
    state.lookups["assurance-modes"] = staticLookups["assurance-modes"];
    state.lookups["assurance-types"] = state.lookups["assurance-types"]?.length ? state.lookups["assurance-types"] : staticLookups["assurance-types"];
    state.lookups.users = state.lookups.users?.length ? state.lookups.users : (state.lookups.employees || []);
    state.lookups["users-id"] = state.lookups["users-id"]?.length ? state.lookups["users-id"] : (state.lookups["employees-id"] || state.lookups.users || []);
    state.lookups.locations = state.lookups.locations || [];
    state.lookups.departments = state.lookups.departments || [];
    state.lookups.teams = state.lookups.teams || [];
    state.lookups.committees = state.lookups.committees || [];
    state.lookups["dependency-vendors"] = state.lookups["dependency-vendors"] || [];
    state.lookups["hosting-types"] = state.lookups["hosting-types"] || [];
    state.lookups["license-types"] = state.lookups["license-types"] || [];
    state.lookups["service-categories"] = state.lookups["service-categories"] || [];
    state.lookups["asset-categories"] = state.lookups["asset-categories"] || [];
    state.lookups["data-types"] = [{ value: "Text", label: "Text" }, { value: "Number", label: "Number" }, { value: "Date", label: "Date" }, { value: "Boolean", label: "Boolean" }, { value: "Json", label: "Json" }, { value: "Lookup", label: "Lookup" }];

    // Migration 241: prime the asset-taxonomy lookups. The helper below
    // both fires at page load and is re-callable inline from the cascade
    // handler, so a user who clicks Category before this returns still
    // gets a populated Sub Category once the fetch lands.
    await ensureAssetTaxonomyLookups();

    // Migration 342: derive the functional-user-only owner pickers. The
    // owners query returns only Functional Users (341); we intersect it
    // with the already-org-scoped users / users-id lists so owners /
    // owners-id inherit the same organization scoping without duplicating
    // it, while the shared users lists (Reporting Officer, Team Manager,
    // Chairperson, Task Assigned To, etc.) stay untouched.
    await ensureOwnersLookup();

    // Location's Time Zone dropdown (change request 2026-09-20, migration
    // 361): "time-zones" is not part of the generic /lookups UNION (same
    // reason asset-taxonomy / connection-types aren't -- see 241's own
    // comment on that monolith), so it is fetched here as its own entity
    // and merged into state.lookups the same way ensureAssetTaxonomyLookups
    // merges its rows.
    await ensureTimeZoneLookup();

    // Team Members tree (migration 362, change request 2026-09-20):
    // Department -> active Employee rows for the Add/Edit Team form.
    // "team-department-employees" is not part of the generic /lookups
    // UNION for the same reason asset-taxonomy/time-zones are not (see
    // ensureAssetTaxonomyLookups' own comment) -- fetched here as its own
    // entity and merged into state.lookups the same way.
    await ensureTeamMemberTreeLookup();

    // Committee Members section (migration 370, change request
    // 2026-09-22): the Designation picker for the Add/Edit Committee
    // form's Committee Members section. "committee-designations" is not
    // part of the generic /lookups UNION for the same reason
    // team-department-employees/time-zones are not -- fetched here as
    // its own entity and merged into state.lookups the same way.
    await ensureCommitteeDesignationLookup();

    // Debug hook for the Add Asset cascade -- exposes counts on demand.
    // Console: window.__pmAssetDebug()
    window.__pmAssetDebug = () => ({
      formEntity: state.formEntity,
      cats: state.lookups["asset-categories"]?.length ?? 0,
      subs: state.lookups["asset-subcategories"]?.length ?? 0,
      types: state.lookups["asset-types"]?.length ?? 0,
      sampleSub: (state.lookups["asset-subcategories"] || [])[0]
    });
    // Deeper hook: emulates my cascade for a given parent id, so we can
    // see where the redraw actually fails.
    window.__pmCascadeTest = (parentId) => {
      const key = "assetSubcategoryId";
      const activeEntity = state.formEntity || setupState.activeTab || screen.Key;
      let fieldDef = (schemas[activeEntity] || []).find(f => f.name === key);
      if (!fieldDef) {
        for (const list of Object.values(schemas)) {
          const hit = (list || []).find(f => f.name === key);
          if (hit) { fieldDef = hit; break; }
        }
      }
      const optionsHtml = fieldDef ? optionsFor(fieldDef.lookup, "", String(parentId)) : "(no fieldDef)";
      const items = state.lookups["asset-subcategories"] || [];
      const filtered = items.filter(item => String(item.organizationId || "") === String(parentId));
      return {
        activeEntity,
        fieldDef: fieldDef ? { name: fieldDef.name, lookup: fieldDef.lookup, parentField: fieldDef.parentField } : null,
        totalItems: items.length,
        matched: filtered.length,
        firstItem: items[0],
        htmlLength: optionsHtml.length
      };
    };

    populateFilters();
  }

  let assetTaxonomyPromise = null;
  function ensureAssetTaxonomyLookups() {
    // Concurrent callers share one in-flight fetch; a completed fetch is
    // free to re-run only when its results were empty (deploy in progress).
    const hasData = (state.lookups["asset-subcategories"]?.length ?? 0) > 0
                 || (state.lookups["asset-types"]?.length ?? 0) > 0;
    if (hasData) return Promise.resolve();
    if (assetTaxonomyPromise) return assetTaxonomyPromise;

    assetTaxonomyPromise = fetchJson(`${api}/asset-taxonomy/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data: { pageNumber: 1, pageSize: 1000 } })
    }).then(taxonomy => {
      const rows = apiData(taxonomy);
      const bucket = { "asset-categories": [], "asset-subcategories": [], "asset-types": [] };
      rows.forEach(row => {
        const key = row.EntityType ?? row.entityType ?? row.LookupKey ?? row.lookupKey;
        if (!(key in bucket)) return;
        bucket[key].push({
          value: row.Value ?? row.value,
          label: row.Label ?? row.label,
          organizationId: String(row.Parent ?? row.parent ?? row.OrganizationId ?? row.organizationId ?? ""),
          departmentId: "",
          departmentName: ""
        });
      });
      Object.keys(bucket).forEach(k => {
        if (bucket[k].length) state.lookups[k] = dedupeLookupItems(bucket[k]);
      });
    }).catch(() => {
      // 241 not deployed yet: cascade dropdowns will render empty. The
      // form still works for the top-level Asset Category picker.
      state.lookups["asset-subcategories"] = state.lookups["asset-subcategories"] || [];
      state.lookups["asset-types"] = state.lookups["asset-types"] || [];
    }).finally(() => {
      // Unconditionally cleared (not just when empty): loadLookups()
      // rebuilds state.lookups from scratch from the generic /lookups
      // UNION on every call (asset-taxonomy is deliberately excluded from
      // that UNION -- see this function's own header comment), so a
      // memoized promise that stays cached after a *successful* fetch
      // would skip re-populating state.lookups on the next loadLookups()
      // call, silently emptying the Asset Category cascade after any
      // second load (e.g. after a Save). Matches ensureOwnersLookup's
      // "re-derive on the next loadLookups" pattern below. The hasData
      // fast-path above still short-circuits repeat calls within the same
      // loadLookups() pass (e.g. from the cascade handler), so this does
      // not add extra fetches there -- only after state.lookups has been
      // wiped and rebuilt.
      assetTaxonomyPromise = null;
    });

    return assetTaxonomyPromise;
  }

  // Migration 342: build owners / owners-id from the functional-user
  // subset of the shared users lists. Re-derived on every loadLookups so
  // it tracks whatever the users lists were just populated with. Falls
  // back to the full user lists when the shim is not deployed yet, so
  // owner pickers keep working (no functional filter available).
  let timeZoneLookupPromise = null;
  function ensureTimeZoneLookup() {
    if (timeZoneLookupPromise) return timeZoneLookupPromise;
    timeZoneLookupPromise = fetchJson(`${api}/time-zones/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data: { pageNumber: 1, pageSize: 500 } })
    }).then(result => {
      const rows = apiData(result);
      state.lookups["time-zones"] = dedupeLookupItems(rows.map(row => ({
        value: row.Value ?? row.value,
        label: row.Label ?? row.label,
        organizationId: "",
        departmentId: "",
        departmentName: ""
      })));
    }).catch(() => {
      // 361 not deployed yet, or ControlManagement's 058 hasn't reached
      // this database: dropdown renders empty, same degrade-the-feature
      // rule as ensureAssetTaxonomyLookups above. The rest of the Location
      // form still works.
      state.lookups["time-zones"] = state.lookups["time-zones"] || [];
    }).finally(() => {
      // Unconditionally cleared, not just on an empty result: see the
      // matching comment on ensureAssetTaxonomyLookups' finally() above --
      // loadLookups() rebuilds state.lookups from scratch every call, and
      // "time-zones" is excluded from the generic UNION, so a promise left
      // cached after a *successful* fetch would silently empty the Time
      // Zone dropdown on the next loadLookups() (e.g. after a Save).
      timeZoneLookupPromise = null;
    });
    return timeZoneLookupPromise;
  }

  // Team Members tree (migration 362): one row per (active Department,
  // active Employee) pair, across every organization -- same shape and
  // same "UI filters to the org currently open" rule as ensureOwnersLookup
  // below (see 342's own header note). employeeId is null for a
  // Department that currently has no active employees (LEFT JOIN in
  // sp_get_team_department_employee_tree), so those rows are kept out of
  // the employee list but still recorded via team-departments, so an
  // otherwise-empty Department still shows as a branch in the tree.
  let teamMemberTreeLookupPromise = null;
  function ensureTeamMemberTreeLookup() {
    if (teamMemberTreeLookupPromise) return teamMemberTreeLookupPromise;
    teamMemberTreeLookupPromise = fetchJson(`${api}/team-department-employees/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data: { pageNumber: 1, pageSize: 5000 } })
    }).then(result => {
      const rows = apiData(result);
      state.lookups["team-department-employees"] = dedupeLookupItems(rows
        .filter(row => (row.EmployeeId ?? row.employeeId ?? "") !== "" && (row.EmployeeId ?? row.employeeId) !== null)
        .map(row => ({
          value: String(row.EmployeeId ?? row.employeeId),
          label: `${row.EmployeeCode ?? row.employeeCode ?? ""} - ${row.EmployeeName ?? row.employeeName ?? ""}`.replace(/^ - /, ""),
          organizationId: String(row.OrganizationId ?? row.organizationId ?? ""),
          departmentId: String(row.DepartmentId ?? row.departmentId ?? ""),
          departmentName: row.DepartmentName ?? row.departmentName ?? ""
        })));
      state.lookups["team-departments"] = dedupeLookupItems(rows
        .map(row => ({
          value: String(row.DepartmentId ?? row.departmentId ?? ""),
          label: row.DepartmentName ?? row.departmentName ?? "",
          organizationId: String(row.OrganizationId ?? row.organizationId ?? "")
        }))
        .filter(item => item.value));
    }).catch(() => {
      // 362 not deployed yet: the Team Members tree renders empty, same
      // degrade-the-feature rule as ensureAssetTaxonomyLookups above. The
      // rest of the Add/Edit Team form still works.
      state.lookups["team-department-employees"] = state.lookups["team-department-employees"] || [];
      state.lookups["team-departments"] = state.lookups["team-departments"] || [];
    }).finally(() => {
      // Unconditionally cleared, not just on an empty result (change
      // request 2026-09-22: Team Members tree going empty after
      // Edit Team -> add a member -> Save). Same root cause as
      // ensureAssetTaxonomyLookups/ensureTimeZoneLookup above: loadLookups()
      // rebuilds state.lookups from scratch on every call, and
      // "team-department-employees"/"team-departments" are excluded from
      // the generic UNION, so once this promise resolved successfully once
      // it stayed cached forever -- every *later* loadLookups() call (the
      // generic Save handler always calls loadLookups() again after
      // dialog.close()) wiped state.lookups but this already-settled
      // promise's .then() never re-ran, so the tree's two lookups stayed
      // undefined and the field rendered its "No departments or employees
      // found" empty state on the next time the form opened, even though
      // the data itself was fine.
      teamMemberTreeLookupPromise = null;
    });
    return teamMemberTreeLookupPromise;
  }

  // Committee Designation Master (migration 370, change request
  // 2026-09-22): every active designation, system and every
  // organization's custom ones alike -- see sp_get_committee_designation_
  // lookup's own header comment for why organization scoping is left to
  // the UI (lookupItemsFor's whitelist, same as team-department-employees
  // above) rather than duplicated server-side.
  let committeeDesignationLookupPromise = null;
  function ensureCommitteeDesignationLookup() {
    if (committeeDesignationLookupPromise) return committeeDesignationLookupPromise;
    committeeDesignationLookupPromise = fetchJson(`${api}/committee-designations/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data: { pageNumber: 1, pageSize: 2000 } })
    }).then(result => {
      const rows = apiData(result);
      state.lookups["committee-designations"] = dedupeLookupItems(rows.map(row => ({
        value: String(row.DesignationId ?? row.designationId ?? ""),
        label: row.Label ?? row.label ?? row.DesignationName ?? row.designationName ?? "",
        organizationId: String(row.OrganizationId ?? row.organizationId ?? "")
      })).filter(item => item.value));
    }).catch(() => {
      // 370 not deployed yet: the Designation picker renders empty, same
      // degrade-the-feature rule as ensureTeamMemberTreeLookup above. The
      // rest of the Add/Edit Committee form still works.
      state.lookups["committee-designations"] = state.lookups["committee-designations"] || [];
    }).finally(() => {
      // Unconditionally cleared, not just on an empty result -- same fix
      // as ensureTeamMemberTreeLookup's finally() just above, for the
      // identical reason (state.lookups gets rebuilt from scratch on every
      // loadLookups() call, and this lookup is excluded from the generic
      // UNION). The manual "committeeDesignationLookupPromise = null;"
      // before the inline "+ New Designation" re-fetch further up this
      // file is now redundant but harmless -- this keeps that one working
      // exactly as before while also fixing every other caller.
      committeeDesignationLookupPromise = null;
    });
    return committeeDesignationLookupPromise;
  }

  let ownersLookupPromise = null;
  function ensureOwnersLookup() {
    if (ownersLookupPromise) return ownersLookupPromise;
    ownersLookupPromise = fetchJson(`${api}/owners/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data: { pageNumber: 1, pageSize: 5000 } })
    }).then(result => {
      const rows = apiData(result);
      const functionalIds = new Set(rows.map(row => String(row.Value ?? row.value)));
      const functionalNames = new Set(rows.map(row => String(row.Label ?? row.label)));
      // If the owners shim returned nothing (e.g. migration 342 not deployed,
      // so the query fell back to the monolith and yielded no rows), don't
      // leave the owner pickers empty -- fall back to the full user lists.
      if (functionalIds.size === 0) {
        state.lookups["owners-id"] = state.lookups["users-id"] || [];
        state.lookups["owners"] = state.lookups["users"] || [];
        return;
      }
      // owners-id mirrors users-id (numeric employee_id Value); owners
      // mirrors users (employee_name Value). Filtering the org-scoped
      // users lists keeps each item's organizationId, so owner pickers
      // stay org-scoped through lookupItemsFor.
      state.lookups["owners-id"] = (state.lookups["users-id"] || []).filter(item => functionalIds.has(String(item.value)));
      state.lookups["owners"] = (state.lookups["users"] || []).filter(item => functionalNames.has(String(item.value)));
    }).catch(() => {
      state.lookups["owners-id"] = state.lookups["users-id"] || [];
      state.lookups["owners"] = state.lookups["users"] || [];
    }).finally(() => {
      // Re-derive on the next loadLookups (users lists may be refreshed).
      ownersLookupPromise = null;
    });
    return ownersLookupPromise;
  }

  function populateFilters() {
    if (organizationFilter) {
      const organizations = state.lookups.organizations || [];
      const emptyLabel = organizationScopedScreens.has(screen.Key) ? "Select organization" : "All organizations";
      organizationFilter.innerHTML = `<option value="">${emptyLabel}</option>${organizations.map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")}`;
      // source-statements + organization-controls always pick the first org
      // so the user lands directly on data instead of a "Select organization"
      // stub. Other org-scoped screens honour the last-selected org from
      // localStorage first.
      const skipSavedForFirstPick = ["organization-controls", "control-applicability", "source-statements"].includes(screen.Key);
      const savedOrganizationId = skipSavedForFirstPick ? "" : getSavedOrganizationId();
      if (organizationScopedScreens.has(screen.Key) && !state.navigationCode) {
        const selected = organizations.find(item => String(item.value) === savedOrganizationId) || organizations[0];
        if (selected) {
          const nextValue = String(selected.value);
          const previousValue = organizationFilter.value;
          organizationFilter.value = nextValue;
          // Programmatic .value assignment doesn't fire the change listener,
          // so the subscribed-framework filter + grid load would still be
          // gated on an empty selection. Fire it manually when the effective
          // value actually changed so downstream handlers (loadSubscribedFrameworks
          // + resetToFirstPage) run for the auto-picked organization.
          if (previousValue !== nextValue) {
            organizationFilter.dispatchEvent(new Event("change", { bubbles: true }));
          }
        }
      }
    }
    if (status) {
      const statusKey = screen.Key === "organization-requirements" || isSourceStatements ? "applicability-status" : "status-active";
      const emptyStatus = screen.Key === "organization-requirements" || isSourceStatements ? "All applicability statuses" : "All statuses";
      status.innerHTML = `<option value="">${emptyStatus}</option>${(state.lookups[statusKey] || []).map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")}`;
    }
    if (originTypeFilter) originTypeFilter.innerHTML = `<option value="">All origins</option>${(state.lookups["origin-types"] || []).map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")}`;
    if (criticalityFilter) criticalityFilter.innerHTML = `<option value="">All criticalities</option>${(state.lookups.criticality || []).map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")}`;
  }

  async function loadSubscribedFrameworks() {
    if (!subscribedFrameworkFilter) return;
    const organizationId = organizationFilter?.value || "";
    subscribedFrameworkFilter.innerHTML = `<option value="">All subscribed frameworks</option>`;
    subscribedFrameworkFilter.disabled = !organizationId;
    if (!organizationId) return;
    try {
      const result = await fetchJson(`${api}/subscribed-frameworks/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ data: { organizationId: Number(organizationId), pageNumber: 1, pageSize: 500 } })
      });
      const frameworks = apiData(result);
      subscribedFrameworkFilter.innerHTML = `<option value="">All subscribed frameworks</option>${frameworks.map(item => {
        const value = item.ReleaseId ?? item.releaseId;
        const label = item.FrameworkRelease || item.frameworkRelease || item.ReleaseVersion || item.releaseVersion || `Release ${value}`;
        return `<option value="${escapeHtml(value)}">${escapeHtml(label)}</option>`;
      }).join("")}`;
      subscribedFrameworkFilter.disabled = false;
      console.info("PracticeManagement Organization Practices subscribed frameworks", { organizationId, count: frameworks.length, frameworks });
    } catch (error) {
      subscribedFrameworkFilter.innerHTML = `<option value="">Unable to load frameworks</option>`;
      subscribedFrameworkFilter.disabled = true;
      console.error("PracticeManagement subscribed frameworks failed", error);
    }
  }

  function currentFormOrganizationId() {
    return String(
      valueOf(state.activeFormRecord, "OrganizationId")
      || valueOf(state.activeFormRecord, "organizationId")
      || organizationFilter?.value
      || setupState.organizationId
      || ""
    );
  }

  function lookupItemsFor(key) {
    const items = state.lookups[key] || [];
    if (!["employees", "employees-id", "users", "users-id", "owners", "owners-id", "users-detail", "roles", "business-functions", "locations", "departments", "teams", "committees", "dependency-vendors", "team-department-employees", "team-departments", "committee-designations"].includes(key)) return items;
    const organizationId = currentFormOrganizationId();
    if (!organizationId) return items;
    return items.filter(item => !item.organizationId || item.organizationId === organizationId);
  }

  function optionsFor(key, selected, parentValue, restrictToLabels) {
    const selectedText = String(selected ?? "");
    // A cascade select passes parentValue (e.g. asset-subcategories filtered by
    // the picked category). The seed proc encodes the parent id in the
    // organizationId column of the row shape so no schema change was needed;
    // when parentValue is undefined every row passes through (regular lookup).
    let items = lookupItemsFor(key);
    if (parentValue !== undefined && parentValue !== null) {
      const parentText = String(parentValue);
      items = parentText
        ? items.filter(item => String(item.organizationId || "") === parentText)
        : [];   // no parent picked -> empty picker, so the user picks the parent first
    }
    // Organization Practices Applicability Status restriction (2026-09-16,
    // per sir): applicability_status_master is shared across four screens
    // (organization-controls/control-applicability keep the full list --
    // Deferred and Accepted Risk are live concepts there, see the dashboard
    // stat queries in 002), so the cut has to happen here, per field, not
    // in the master table. A record already saved with a value outside the
    // restricted set (e.g. a legacy Deferred) still shows and stays
    // selected -- same "keep current value visible" rule as the owners
    // case below -- this only narrows what a NEW pick can be.
    if (Array.isArray(restrictToLabels) && restrictToLabels.length) {
      const allowed = items.filter(item => restrictToLabels.includes(item.label));
      const current = items.find(item => String(item.value) === selectedText);
      items = current && !allowed.some(item => String(item.value) === selectedText)
        ? allowed.concat([current])
        : allowed;
    }
    // Migration 342: owner pickers offer only Functional Users, but a
    // record whose current owner is not (or is no longer) a Functional
    // User must still show that existing value -- the "keep current value
    // visible" decision. If the selected value is missing from the
    // functional list, append it from the full users list so it stays
    // selectable; new picks remain functional-only.
    if ((key === "owners" || key === "owners-id") && selectedText
        && !items.some(item => String(item.value) === selectedText)) {
      const baseKey = key === "owners-id" ? "users-id" : "users";
      const current = (state.lookups[baseKey] || []).find(item => String(item.value) === selectedText);
      if (current) items = items.concat([current]);
    }
    return `<option value="">Select...</option>${items.map(item => `<option value="${escapeHtml(item.value)}"${String(item.value) === selectedText ? " selected" : ""}>${escapeHtml(item.label)}</option>`).join("")}`;
  }

  function setupFieldMarkup(field, value, readonly = false) {
    const required = field.required ? `<span class="required"> *</span>` : "";
    const disabled = readonly ? " disabled" : "";
    if (field.type === "checkbox") {
      const checked = value === true || value === "true" || value === "1" || value === 1;
      return `<label class="pm-field"><span>${escapeHtml(field.label)}${required}</span><span class="pm-checkline"><input name="${field.name}" type="checkbox"${checked ? " checked" : ""}${disabled}> Yes</span></label>`;
    }
    if (field.type === "checks") {
      const values = new Set(Array.isArray(value) ? value.map(String) : []);
      const options = lookupItemsFor(field.lookup).map(item => `<label><input name="${field.name}" type="checkbox" value="${escapeHtml(item.value)}"${values.has(String(item.value)) ? " checked" : ""}${disabled}> ${escapeHtml(item.label)}</label>`).join("");
      return `<div class="pm-field full"><span>${escapeHtml(field.label)}${required}</span><div class="pm-checkbox-list">${options}</div></div>`;
    }
    if (field.type === "comboChecks") {
      const values = new Set(Array.isArray(value) ? value.map(String) : []);
      const lookupItems = lookupItemsFor(field.lookup);
      const selectedLabels = lookupItems.filter(item => values.has(String(item.value))).map(item => item.label);
      const options = lookupItems.map(item => `<label data-checkcombo-option><input name="${field.name}" type="checkbox" value="${escapeHtml(item.value)}"${values.has(String(item.value)) ? " checked" : ""}${disabled}> <span>${escapeHtml(item.label)}</span></label>`).join("");
      return `<div class="pm-field pm-checkcombo" data-checkcombo>
        <span>${escapeHtml(field.label)}${required}</span>
        <button class="pm-checkcombo-trigger" type="button" data-checkcombo-trigger${disabled}>
          <span data-checkcombo-text>${escapeHtml(selectedLabels.join(", ") || "Select...")}</span>
        </button>
        <div class="pm-checkcombo-menu" data-checkcombo-menu hidden>
          <input class="pm-checkcombo-search" type="search" placeholder="Search..." data-checkcombo-search>
          <div class="pm-checkcombo-options">${options || `<div class="pm-empty compact">No options found.</div>`}</div>
        </div>
      </div>`;
    }
    return fieldMarkup(field, value ?? "", readonly);
  }

  // Read-only value display for Organization Administration's Organization
  // tab (change request 2026-09-20). setupFieldMarkup/fieldMarkup render a
  // real <input>/<select> with `disabled` for every other read-only case in
  // the app (View mode on ~30 other entity forms), and that shared path is
  // deliberately left untouched -- this is a SEPARATE function, wired in
  // only where renderSetupBasic() below checks isOrganizationAdministration,
  // so no other screen's read-only rendering changes. A disabled control
  // still looks like a form waiting to be enabled; this renders a plain
  // label above a value box instead, matching the .pm-field label styling
  // already used everywhere on this page (12px/700-weight muted label) so
  // it reads as the same design language, not a bolted-on variant.
  function setupViewFieldMarkup(field, value) {
    const label = escapeHtml(field.label);
    let text = null; // non-null once resolved to a real, non-empty display string
    if (field.type === "checkbox") {
      text = (value === true || value === "true" || value === "1" || value === 1) ? "Yes" : "No";
    } else if (field.type === "checks" || field.type === "comboChecks") {
      const values = new Set(Array.isArray(value) ? value.map(String) : []);
      const labels = lookupItemsFor(field.lookup).filter(item => values.has(String(item.value))).map(item => item.label);
      if (labels.length) text = labels.join(", ");
    } else if (field.type === "select") {
      const match = lookupItemsFor(field.lookup).find(item => String(item.value) === String(value ?? ""));
      if (match) text = match.label;
      else if (value) text = String(value);
    } else if (field.type === "date" || field.type === "datetime-local") {
      const shown = typeof window.gracFormatDisplayDate === "function" ? window.gracFormatDisplayDate(value) : value;
      if (shown) text = String(shown);
    } else {
      const raw = value === null || value === undefined ? "" : String(value).trim();
      if (raw) text = raw;
    }
    // .pm-field-empty is this codebase's existing "nothing here yet" box
    // (practice-management.css: "renders INSTEAD of an input... Any other
    // field that has to say 'nothing here yet' in a form row should use it
    // too") -- reused as-is rather than inventing a parallel empty state.
    // .pm-view-value is the new piece: the equivalent box for a value that
    // DOES exist, read-only.
    const valueMarkup = text === null
      ? `<div class="pm-field-empty">Not set</div>`
      : `<div class="pm-view-value">${escapeHtml(text)}</div>`;
    return `<div class="pm-field pm-view-field${field.full ? " full" : ""}" data-field-name="${escapeHtml(field.name)}"><span>${label}</span>${valueMarkup}</div>`;
  }

  function parseAttributeValue(row) {
    const dataType = row.DataType || row.dataType;
    const raw = dataType === "Json" ? (row.ValueJson || row.valueJson) : dataType === "Boolean" ? (row.ValueBool ?? row.valueBool) : (row.ValueText ?? row.valueText ?? row.ValueNumber ?? row.valueNumber ?? row.ValueDate ?? row.valueDate ?? "");
    if (dataType === "Json") {
      try { return JSON.parse(raw || "[]"); } catch { return []; }
    }
    return raw;
  }

  function populateSetupOrganizationSelector() {
    setupOrganization.innerHTML = `<option value="">${isOrganizationOnboarding ? "New Organization" : "Select Organization"}</option>${(state.lookups.organizations || []).map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")}`;
    const organizations = state.lookups.organizations || [];
    const saved = getSavedOrganizationId();
    const selected = organizations.find(item => String(item.value) === saved) || (isOrganizationOnboarding ? null : organizations[0]);
    if (!setupOrganization.value && selected) setupOrganization.value = String(selected.value);
    setupOrganization.disabled = !isOrganizationOnboarding && organizations.length === 1;
  }

  async function loadOrganizationSetup() {
    const orgId = setupOrganization.value || "";
    setupState.organizationId = orgId;
    setupState.treeInitialized = false;
    setupState.collapsed.clear();
    setupState.selectedReleases.clear();
    setupState.recommendations.clear();
    setupState.recommendationAutoSelected.clear();
    const result = await fetchJson(`${api}/organization-setup/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data: { organizationId: orgId ? Number(orgId) : null, pageSize: 200 } })
    });
    const tables = result.data || result.Data || [];
    const org = tables[0]?.[0] || {};
    const attributes = tables[1] || [];
    // Organization Administration reuses the repository tree payload
    // (tables[2]) so the "Subscribed Releases" read-only panel can render
    // without a second API round-trip. The interactive tree is still
    // onboarding-only.
    setupState.treeRows = (isOrganizationOnboarding || isOrganizationAdministration) ? (tables[2] || []) : [];
    setupState.attributes = attributes.reduce((all, row) => {
      all[row.MetadataKey || row.metadataKey] = parseAttributeValue(row);
      return all;
    }, {});
    setupState.treeRows.filter(row => row.IsSubscribed || row.isSubscribed).forEach(row => setupState.selectedReleases.add(String(row.ReleaseId || row.releaseId)));
    collapseSubscriptionTree();
    setupState.treeInitialized = true;
    renderSetupBasic(org);
    renderSetupAttributes();
    if (isOrganizationOnboarding) renderSubscriptionTree();
    if (isOrganizationAdministration) renderSubscribedReleasesReadonly();
    await loadSetupChildRows(setupState.activeTab);
  }

  // Renders the Subscribed Releases side panel on the Organization
  // Administration page. Read-only list grouped Authority -> Artifact ->
  // Release so it mirrors the onboarding tree without any editing affordance.
  function renderSubscribedReleasesReadonly() {
    const container = document.getElementById("subscribedReleasesList");
    if (!container) return;
    if (!setupState.organizationId) {
      container.textContent = "Select an organization to view subscribed releases.";
      return;
    }
    const subscribed = setupState.treeRows.filter(row => row.IsSubscribed || row.isSubscribed);
    if (!subscribed.length) {
      container.textContent = "This organization has no active repository subscriptions.";
      return;
    }
    // Group subscribed releases by Authority -> Artifact.
    const groups = new Map();
    subscribed.forEach(row => {
      const authorityKey = String(row.AuthorityId || row.authorityId || "");
      if (!groups.has(authorityKey)) {
        groups.set(authorityKey, {
          code: row.AuthorityCode || row.authorityCode || "",
          name: row.AuthorityName || row.authorityName || "",
          artifacts: new Map()
        });
      }
      const authority = groups.get(authorityKey);
      const artifactKey = String(row.ArtifactId || row.artifactId || "");
      if (!authority.artifacts.has(artifactKey)) {
        authority.artifacts.set(artifactKey, {
          code: row.ArtifactCode || row.artifactCode || "",
          name: row.ArtifactName || row.artifactName || "",
          releases: []
        });
      }
      authority.artifacts.get(artifactKey).releases.push({
        id: String(row.ReleaseId || row.releaseId),
        version: row.ReleaseVersion || row.releaseVersion || "",
        status: row.ReleaseStatus || row.releaseStatus || ""
      });
    });
    container.innerHTML = [...groups.values()].map(authority => `
      <div class="pm-tree-branch">
        <div class="pm-tree-row authority" style="--tree-depth:0"><strong>${escapeHtml(authority.code || "")}${authority.code && authority.name ? " - " : ""}${escapeHtml(authority.name || "")}</strong></div>
        ${[...authority.artifacts.values()].map(artifact => `
          <div class="pm-tree-row artifact" style="--tree-depth:1"><span>${escapeHtml(artifact.code || "")}${artifact.code && artifact.name ? " - " : ""}${escapeHtml(artifact.name || "")}</span></div>
          ${artifact.releases.map(release => `
            <div class="pm-tree-row release" style="--tree-depth:2"><span class="tree-spacer"></span><span>${escapeHtml(release.version)}${release.status ? ` <small>${escapeHtml(release.status)}</small>` : ""}</span></div>
          `).join("")}
        `).join("")}
      </div>
    `).join("");
  }

  function renderSetupBasic(org) {
    if (!setupBasicFields) return;
    const values = {
      code: org.Code || "",
      name: org.Name || "",
      industry: org.Industry || "",
      entityType: org.EntityType || "",
      country: org.Country || "",
      status: org.Status || "Active"
    };
    // Organization Administration's Organization tab is read-only by design
    // (change request 2026-09-20) -- render plain label/value pairs there
    // instead of the disabled-input form used everywhere else that reuses
    // this same field schema (Organization Setup's onboarding flow).
    setupBasicFields.innerHTML = isOrganizationAdministration
      ? setupBasicSchema.map(field => setupViewFieldMarkup(field, values[field.name])).join("")
      : setupBasicSchema.map(field => setupFieldMarkup(field, values[field.name], false)).join("");
  }

  function renderSetupAttributes() {
    if (!setupAttributeFields) return;
    setupAttributeFields.innerHTML = setupAttributeSchema.map(field => setupFieldMarkup(field, setupState.attributes[field.name], isOrganizationAdministration)).join("");
  }

  function repositoryTree() {
    const authorities = new Map();
    setupState.treeRows.forEach(row => {
      const authorityId = String(row.AuthorityId || row.authorityId);
      const artifactId = String(row.ArtifactId || row.artifactId);
      if (!authorities.has(authorityId)) authorities.set(authorityId, { id: authorityId, code: row.AuthorityCode, name: row.AuthorityName, artifacts: new Map() });
      const authority = authorities.get(authorityId);
      if (!authority.artifacts.has(artifactId)) authority.artifacts.set(artifactId, { id: artifactId, code: row.ArtifactCode, name: row.ArtifactName, releases: [] });
      authority.artifacts.get(artifactId).releases.push({ id: String(row.ReleaseId || row.releaseId), version: row.ReleaseVersion || row.releaseVersion, status: row.ReleaseStatus || row.releaseStatus });
    });
    return [...authorities.values()].map(authority => ({ ...authority, artifacts: [...authority.artifacts.values()] }));
  }

  function renderSubscriptionTree() {
    if (!setupState.treeInitialized) {
      collapseSubscriptionTree();
      setupState.treeInitialized = true;
    }
    const term = (subscriptionSearch?.value || "").trim().toLowerCase();
    const html = repositoryTree().map(authority => {
      const authorityKey = `a-${authority.id}`;
      const authorityCollapsed = setupState.collapsed.has(authorityKey);
      const artifacts = authority.artifacts.map(artifact => {
        const artifactKey = `r-${artifact.id}`;
        const artifactCollapsed = setupState.collapsed.has(artifactKey);
        const releases = artifact.releases.filter(release => !term || `${authority.code} ${authority.name} ${artifact.code} ${artifact.name} ${release.version}`.toLowerCase().includes(term));
        if (term && !releases.length) return "";
        return `<div class="pm-tree-branch">
          <div class="pm-tree-row artifact" style="--tree-depth:1"><button type="button" data-tree-toggle="${artifactKey}">${artifactCollapsed ? "+" : "-"}</button><span>${escapeHtml(artifact.code)} - ${escapeHtml(artifact.name)}</span></div>
          <div ${artifactCollapsed ? "hidden" : ""}>${releases.map(release => {
            const recommendation = setupState.recommendations.get(release.id);
            const title = recommendation ? ` title="${escapeHtml(recommendation.reason)} Confidence: ${escapeHtml(recommendation.confidence)}"` : "";
            return `<label class="pm-tree-row release${recommendation ? " recommended" : ""}" style="--tree-depth:2"${title}><span class="tree-spacer"></span><input type="checkbox" data-release-id="${escapeHtml(release.id)}"${setupState.selectedReleases.has(release.id) ? " checked" : ""}> <span>${escapeHtml(release.version)} <small>${escapeHtml(release.status)}${recommendation ? ` · ${escapeHtml(recommendation.confidence)} recommendation` : ""}</small></span></label>`;
          }).join("")}</div>
        </div>`;
      }).join("");
      if (term && !artifacts.trim()) return "";
      return `<div class="pm-tree-branch">
        <div class="pm-tree-row authority" style="--tree-depth:0"><button type="button" data-tree-toggle="${authorityKey}">${authorityCollapsed ? "+" : "-"}</button><strong>${escapeHtml(authority.code)} - ${escapeHtml(authority.name)}</strong></div>
        <div ${authorityCollapsed ? "hidden" : ""}>${artifacts}</div>
      </div>`;
    }).join("");
    subscriptionTree.innerHTML = html || `<div class="pm-empty">No repository releases found.</div>`;
  }

  function collapseSubscriptionTree() {
    setupState.collapsed.clear();
    repositoryTree().forEach(authority => {
      setupState.collapsed.add(`a-${authority.id}`);
      authority.artifacts.forEach(artifact => setupState.collapsed.add(`r-${artifact.id}`));
    });
  }

  function collectSetupFields(host) {
    const data = {};
    let valid = true;
    host.querySelectorAll("input,select,textarea").forEach(input => {
      input.classList.remove("field-error");
      if (input.required && !input.value.trim()) {
        input.classList.add("field-error");
        valid = false;
      }
      if (input.type === "checkbox" && input.closest(".pm-checkbox-list")) {
        const list = data[input.name] ||= [];
        if (input.checked) list.push(input.value);
      } else if (input.type === "checkbox" && input.closest("[data-checkcombo]")) {
        const list = data[input.name] ||= [];
        if (input.checked) list.push(input.value);
      } else if (input.type === "checkbox") data[input.name] = input.checked;
      else data[input.name] = input.value;
    });
    if (!valid) throw new Error("Please complete the required organization fields.");
    return data;
  }

  async function saveOrganizationSetup() {
    try {
      setupMessage.hidden = true;
      const organization = collectSetupFields(setupBasicFields);
      organization.id = setupState.organizationId ? Number(setupState.organizationId) : 0;
      const isNewOrganization = !organization.id || organization.id <= 0;
      const attributes = collectSetupFields(setupAttributeFields);
      const recommendations = [...setupState.recommendations.entries()].map(([releaseId, item]) => ({
        releaseId: Number(releaseId),
        reason: item.reason,
        confidence: item.confidence
      }));
      const saveResult = await fetchJson(`${api}/organization-setup`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id: organization.id, data: { organization, attributes, releaseIds: [...setupState.selectedReleases].map(Number), recommendations } })
      });

      // Rule 6 — best-effort admin provisioning for newly-created orgs.
      // Never let this step block the "org saved" confirmation.
      let provisioningNote = "";
      if (isNewOrganization) {
        const newOrgId = extractNewOrganizationId(saveResult) || setupState.organizationId;
        const adminEmail = String(organization.adminEmail || "").trim();
        if (newOrgId && adminEmail) {
          try {
            const provisionResp = await fetchJson(`${api}/organization-admin/provision-and-notify`, {
              method: "POST",
              headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
              body: JSON.stringify({
                organizationId: Number(newOrgId),
                adminEmail,
                adminName: String(organization.adminName || adminEmail),
                organizationName: String(organization.name || organization.code || "")
              })
            });
            provisioningNote = (provisionResp?.credentialsEmailed
              ? " Admin credentials were emailed."
              : " Admin was provisioned; credential email failed — use Resend from the Users tab.")
              + describeAccessProvisioning(provisionResp);
          } catch (provisionError) {
            provisioningNote = ` Admin provisioning failed: ${provisionError.message}`;
          }
        } else if (!adminEmail) {
          provisioningNote = " (No admin email supplied — admin not provisioned.)";
        }
      }

      setupMessage.textContent = "Organization setup saved successfully." + provisioningNote;
      setupMessage.hidden = false;
      await loadLookups();
      populateSetupOrganizationSelector();
      if (!setupOrganization.value) {
        const match = (state.lookups.organizations || []).find(item => String(item.label).includes(organization.code));
        if (match) setupOrganization.value = match.value;
      }
      await loadOrganizationSetup();
    } catch (error) {
      setupMessage.textContent = error.message;
      setupMessage.hidden = false;
    }
  }

  // Migration 217 — pm_create_organization_admin now grants the Admin
  // role every active menu and switches on every `screen.*` feature flag
  // the organization has no row for. Report it so the operator knows the
  // new org can open Gap Center / Task Center / Exception Centre without
  // a manual trip to Role Menu Permission. Counts of 0 mean "nothing was
  // missing", so stay quiet in that case.
  function describeAccessProvisioning(provisionResp) {
    const menus = Number(provisionResp?.menusGranted || 0);
    const flags = Number(provisionResp?.flagsEnabled || 0);
    if (menus <= 0 && flags <= 0) return "";
    const parts = [];
    if (menus > 0) parts.push(`${menus} menu permission${menus === 1 ? "" : "s"}`);
    if (flags > 0) parts.push(`${flags} screen feature flag${flags === 1 ? "" : "s"}`);
    return ` Default access granted: ${parts.join(" and ")}.`;
  }

  function extractNewOrganizationId(saveResult) {
    if (!saveResult) return 0;
    const data = saveResult.data || saveResult.Data;
    if (!data) return 0;
    const first = Array.isArray(data) ? (Array.isArray(data[0]) ? data[0][0] : data[0]) : data;
    if (!first) return 0;
    return Number(first.OrganizationId || first.organizationId || first.NewOrganizationId || first.newOrganizationId || 0) || 0;
  }

  function currentSetupPayload() {
    const organization = collectSetupFields(setupBasicFields);
    organization.id = setupState.organizationId ? Number(setupState.organizationId) : 0;
    return { organization, attributes: collectSetupFields(setupAttributeFields) };
  }

  async function loadFrameworkRecommendations() {
    try {
      recommendationSummary.textContent = "Evaluating recommendations...";
      const payload = currentSetupPayload();
      const result = await fetchJson(`${api}/applicability-recommendations/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id: payload.organization.id, data: payload })
      });
      const recommendations = apiData(result);
      setupState.recommendations.clear();
      recommendations.forEach(row => {
        const releaseId = String(row.ReleaseId || row.releaseId);
        setupState.recommendations.set(releaseId, {
          reason: row.RecommendationReason || row.recommendationReason || "Recommended by applicability engine.",
          confidence: row.ConfidenceLevel || row.confidenceLevel || "Medium"
        });
        if (!setupState.selectedReleases.has(releaseId)) setupState.recommendationAutoSelected.add(releaseId);
        setupState.selectedReleases.add(releaseId);
        const authorityId = String(row.AuthorityId || row.authorityId);
        const artifactId = String(row.ArtifactId || row.artifactId);
        setupState.collapsed.delete(`a-${authorityId}`);
        setupState.collapsed.delete(`r-${artifactId}`);
      });
      recommendationSummary.textContent = recommendations.length
        ? `${recommendations.length} recommendation(s) applied. Review, uncheck, or keep before saving.`
        : "No recommendations found for the current attributes.";
      renderSubscriptionTree();
    } catch (error) {
      recommendationSummary.textContent = error.message;
    }
  }

  function clearFrameworkRecommendations() {
    setupState.recommendationAutoSelected.forEach(releaseId => setupState.selectedReleases.delete(releaseId));
    setupState.recommendationAutoSelected.clear();
    setupState.recommendations.clear();
    if (recommendationSummary) recommendationSummary.textContent = "Recommendations cleared. Manual selections are preserved.";
    renderSubscriptionTree();
  }

  function initOrganizationSetup() {
    populateSetupOrganizationSelector();
    loadOrganizationSetup().catch(error => {
      setupMessage.textContent = error.message;
      setupMessage.hidden = false;
    });
    setupOrganization?.addEventListener("change", () => {
      rememberOrganizationId(setupOrganization.value);
      loadOrganizationSetup();
    });
    setupTabs.forEach(tab => tab.addEventListener("click", () => activateSetupTab(tab.dataset.setupTab || "organization")));
    document.querySelector("#saveOrganizationSetup")?.addEventListener("click", saveOrganizationSetup);
    recommendFrameworks?.addEventListener("click", loadFrameworkRecommendations);
    clearRecommendations?.addEventListener("click", clearFrameworkRecommendations);
    subscriptionTree?.addEventListener("click", event => {
      const toggle = event.target.closest("[data-tree-toggle]");
      if (toggle) {
        const key = toggle.dataset.treeToggle;
        setupState.collapsed.has(key) ? setupState.collapsed.delete(key) : setupState.collapsed.add(key);
        renderSubscriptionTree();
      }
    });
    subscriptionTree?.addEventListener("change", event => {
      const checkbox = event.target.closest("[data-release-id]");
      if (!checkbox) return;
      checkbox.checked ? setupState.selectedReleases.add(checkbox.dataset.releaseId) : setupState.selectedReleases.delete(checkbox.dataset.releaseId);
    });
    subscriptionSearch?.addEventListener("input", renderSubscriptionTree);
    setupAttributeFields?.addEventListener("click", event => {
      const trigger = event.target.closest("[data-checkcombo-trigger]");
      if (!trigger) return;
      const combo = trigger.closest("[data-checkcombo]");
      const menu = combo?.querySelector("[data-checkcombo-menu]");
      if (!menu) return;
      document.querySelectorAll("[data-checkcombo-menu]").forEach(item => { if (item !== menu) item.hidden = true; });
      menu.hidden = !menu.hidden;
      if (!menu.hidden) menu.querySelector("[data-checkcombo-search]")?.focus();
    });
    setupAttributeFields?.addEventListener("input", event => {
      const searchBox = event.target.closest("[data-checkcombo-search]");
      if (!searchBox) return;
      const term = searchBox.value.trim().toLowerCase();
      searchBox.closest("[data-checkcombo-menu]")?.querySelectorAll("[data-checkcombo-option]").forEach(option => {
        option.hidden = term && !option.textContent.toLowerCase().includes(term);
      });
    });
    setupAttributeFields?.addEventListener("change", event => {
      const input = event.target.closest("[data-checkcombo] input[type='checkbox']");
      if (!input) return;
      const combo = input.closest("[data-checkcombo]");
      const labels = [...combo.querySelectorAll("input[type='checkbox']:checked")].map(item => item.closest("label").querySelector("span").textContent.trim());
      combo.querySelector("[data-checkcombo-text]").textContent = labels.join(", ") || "Select...";
    });
    document.addEventListener("click", event => {
      if (!event.target.closest("[data-checkcombo]")) {
        document.querySelectorAll("[data-checkcombo-menu]").forEach(menu => menu.hidden = true);
      }
    });
    document.querySelector("#expandSubscriptionTree")?.addEventListener("click", () => { setupState.collapsed.clear(); renderSubscriptionTree(); });
    document.querySelector("#collapseSubscriptionTree")?.addEventListener("click", () => {
      collapseSubscriptionTree();
      renderSubscriptionTree();
    });
    document.querySelectorAll("[data-setup-add]").forEach(button => button.addEventListener("click", () => openSetupChildForm(button.dataset.setupAdd, "add")));
    document.querySelectorAll("[data-setup-refresh]").forEach(button => button.addEventListener("click", () => loadSetupChildRows(button.dataset.setupRefresh)));
    document.querySelectorAll("[data-setup-search]").forEach(input => input.addEventListener("input", () => window.clearTimeout(input._t) || (input._t = window.setTimeout(() => loadSetupChildRows(input.dataset.setupSearch), 250))));
    saveButton?.addEventListener("click", saveForm);
    closeButton?.addEventListener("click", () => dialog?.close());
    cancelButton?.addEventListener("click", () => dialog?.close());
    editButton?.addEventListener("click", handleEditFromView);
    document.addEventListener("click", event => {
      const action = event.target.closest("[data-setup-action]");
      if (!action) return;
      const entity = action.dataset.setupEntity;
      const rowIndex = Number(action.dataset.setupIndex || 0);
      const row = setupState.childRows[entity]?.[rowIndex];
      if (!row) return;
      // Close the popover BEFORE the async form-open runs so the menu
      // doesn't linger visually on top of the modal dialog.
      closeActionMenu();
      if (action.dataset.setupAction === "view") openSetupChildForm(entity, "view", valueOf(row, "Id"), row);
      if (action.dataset.setupAction === "edit") openSetupChildForm(entity, "edit", valueOf(row, "Id"), row);
      if (action.dataset.setupAction === "inactive") retireSetupChild(entity, valueOf(row, "Id"));
    });

    // 3-dot trigger inside the Organization Administration / Dependencies
    // child-tab tables. Builds the same floating .pm-action-menu the main
    // grids use so the sidebar looks visually identical everywhere.
    document.addEventListener("click", event => {
      const trigger = event.target.closest(".pm-action-trigger[data-setup-menu-index]");
      if (!trigger) return;
      // Toggle: a second click on the same trigger closes the menu.
      if (actionTrigger === trigger) { closeActionMenu(); return; }
      openSetupActionMenu(trigger);
    });
  }

  function openSetupActionMenu(trigger) {
    const entity   = trigger.dataset.setupMenuEntity;
    const rowIndex = Number(trigger.dataset.setupMenuIndex || 0);
    const record   = setupState.childRows[entity]?.[rowIndex];
    if (!record) return;
    closeActionMenu();
    actionTrigger = trigger;
    actionTrigger.setAttribute("aria-expanded", "true");
    actionMenu = document.createElement("div");
    actionMenu.className = "pm-action-menu";
    actionMenu.setAttribute("role", "menu");
    // Location, Department, and Teams no longer offer a direct "Inactive"
    // row action -- status changes for these three entities go only
    // through the Edit form's Status dropdown (Active/Inactive). Nothing
    // replaces the removed entry; every other setup-child entity keeps it
    // unchanged.
    const showInactive = entity !== "locations" && entity !== "departments" && entity !== "teams" && entity !== "business-functions";
    actionMenu.innerHTML = `
      <button type="button" role="menuitem"
              data-setup-action="view"  data-setup-entity="${escapeHtml(entity)}" data-setup-index="${rowIndex}">
        <i class="fa-solid fa-eye" aria-hidden="true"></i> View
      </button>
      <button type="button" role="menuitem"
              data-setup-action="edit"  data-setup-entity="${escapeHtml(entity)}" data-setup-index="${rowIndex}">
        <i class="fa-solid fa-pen" aria-hidden="true"></i> Edit
      </button>${showInactive ? `
      <button type="button" role="menuitem"
              data-setup-action="inactive" data-setup-entity="${escapeHtml(entity)}" data-setup-index="${rowIndex}">
        <i class="fa-solid fa-ban" aria-hidden="true"></i> Inactive
      </button>` : ""}`;
    document.body.appendChild(actionMenu);
    positionActionMenu(trigger);
  }

  function activateSetupTab(tabKey) {
    setupState.activeTab = tabKey;
    setupTabs.forEach(tab => tab.classList.toggle("active", tab.dataset.setupTab === tabKey));
    setupPanels.forEach(panel => panel.classList.toggle("active", panel.dataset.setupPanel === tabKey));
    loadSetupChildRows(tabKey);
  }

  function setupChildColumns(entity) {
    return setupChildScreens[entity]?.columns || [];
  }

  async function loadSetupChildRows(entity) {
    if (!entity || entity === "organization" || !setupChildScreens[entity]) return;
    const body = document.querySelector(`[data-setup-body='${entity}']`);
    const head = document.querySelector(`[data-setup-head='${entity}']`);
    if (!body || !head) return;
    const columns = setupChildColumns(entity);
    const setupHeaderLabels = { Chairperson: "Committee Head" };
    head.innerHTML = `<tr>${columns.map(column => `<th>${escapeHtml(setupHeaderLabels[column] || column)}</th>`).join("")}<th>Actions</th></tr>`;
    if (!setupState.organizationId) {
      body.innerHTML = `<tr><td colspan="${columns.length + 1}" class="pm-empty">Select an organization to manage ${escapeHtml(setupChildScreens[entity].title)} records.</td></tr>`;
      return;
    }
    body.innerHTML = `<tr><td colspan="${columns.length + 1}" class="pm-empty">Loading...</td></tr>`;
    const searchInput = document.querySelector(`[data-setup-search='${entity}']`);
    try {
      const result = await fetchJson(`${api}/${entity}/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ data: { organizationId: Number(setupState.organizationId), search: searchInput?.value || "", pageNumber: 1, pageSize: 100 } })
      });
      const records = apiData(result);
      setupState.childRows[entity] = records;
      if (!records.length) {
        body.innerHTML = `<tr><td colspan="${columns.length + 1}" class="pm-empty">No data found.</td></tr>`;
        return;
      }
      // Actions cell uses the same 3-dot trigger pattern the main grids
      // use (see `actions(index)` + `openActionMenu`). The previous inline
      // menu markup rendered View/Edit/Inactive as always-visible pills
      // -- inconsistent with every other grid in the app. The trigger's
      // data-setup-menu-* attributes let the delegated click handler
      // build a floating .pm-action-menu popover on click.
      body.innerHTML = records.map((row, index) => `<tr>${columns.map(column => `<td>${formatCell(valueOf(row, column))}</td>`).join("")}
        <td><div class="pm-inline-actions">
          <button type="button" class="pm-action-trigger"
                  data-setup-menu-entity="${escapeHtml(entity)}"
                  data-setup-menu-index="${index}"
                  aria-haspopup="menu" aria-expanded="false"
                  title="Actions">
            <i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i>
            <span class="visually-hidden">Actions</span>
          </button>
        </div></td></tr>`).join("");
    } catch (error) {
      body.innerHTML = `<tr><td colspan="${columns.length + 1}" class="pm-empty">${escapeHtml(error.message || "Unable to load setup records.")}</td></tr>`;
    }
  }

  async function openSetupChildForm(entity, mode, id = 0, record = null) {
    const setupConfig = setupChildScreens[entity];
    if (!setupConfig || !schemas[entity]) {
      if (setupMessage) {
        setupMessage.textContent = "This setup section is not configured correctly. Please refresh and try again.";
        setupMessage.hidden = false;
      }
      console.error("Unknown Organization Setup child entity.", { entity, setupConfig, hasSchema: Boolean(schemas[entity]) });
      return;
    }
    if (!setupState.organizationId) {
      if (setupMessage) {
        setupMessage.textContent = "Please select or save an organization first.";
        setupMessage.hidden = false;
      }
      return;
    }
    if (!dialog || !fieldsHost || !saveButton) {
      if (setupMessage) {
        setupMessage.textContent = "Add/Edit popup is not available on this page. Please refresh and try again.";
        setupMessage.hidden = false;
      }
      console.error("Organization Setup dialog elements missing.", { dialog: Boolean(dialog), fieldsHost: Boolean(fieldsHost), saveButton: Boolean(saveButton) });
      return;
    }
    state.mode = mode;
    state.id = Number(id || 0);
    state.formEntity = entity;
    const readonly = mode === "view";
    const selectedRecord = record || {};
    selectedRecord.organizationId = selectedRecord.OrganizationId || setupState.organizationId;
    selectedRecord.OrganizationId = selectedRecord.OrganizationId || setupState.organizationId;
    selectedRecord.status = selectedRecord.Status || "Active";
    selectedRecord.Status = selectedRecord.Status || "Active";
    // Team Members prefill (migration 362): the row passed in here comes
    // from the Teams grid (sp_org_team_list, deliberately left untouched --
    // see openForm's own comment on this same fetch), so it never carries
    // member data. Fetched here too so Edit/View reached from Organization
    // Administration's Teams tab pre-check/display the same as the
    // standalone Team Management screen.
    if (entity === "teams" && id) {
      try {
        const memberResult = await fetchJson(`${api}/team-members/query`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
          body: JSON.stringify({ id, data: { pageNumber: 1, pageSize: 2000 } })
        });
        selectedRecord.memberIds = apiData(memberResult).map(row => String(valueOf(row, "EmployeeId"))).filter(Boolean);
      } catch {
        selectedRecord.memberIds = selectedRecord.memberIds || [];
      }
    }
    // Committee Members prefill (migration 370): same reasoning as Team
    // Members above -- fetched here too so Edit/View reached from
    // Organization Administration's Committees tab pre-populates/displays
    // the same as the standalone Committee Management screen.
    if (entity === "committees" && id) {
      try {
        const memberResult = await fetchJson(`${api}/committee-members/query`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
          body: JSON.stringify({ id, data: { pageNumber: 1, pageSize: 2000 } })
        });
        selectedRecord.members = apiData(memberResult);
      } catch {
        selectedRecord.members = selectedRecord.members || [];
      }
    }
    state.activeFormRecord = selectedRecord;
    if (formMessage) formMessage.hidden = true;
    const title = document.querySelector("#dialogTitle");
    if (title) title.textContent = `${mode === "add" ? "Add" : mode === "edit" ? "Edit" : "View"} ${setupConfig.title}`;
    // Location's View page (change request 2026-09-20): render plain
    // label/value boxes instead of disabled form controls here too --
    // this is the "View Location" dialog opened from the Location table
    // inside Organization Setup / Organization Administration (title
    // "View Location", matching setupChildScreens.locations.title, as
    // opposed to the standalone Location Management grid's own View,
    // which still goes through openForm above). Scoped to
    // entity === "locations" && mode === "view" only -- every other
    // setup child entity sharing this function (departments,
    // business-functions, teams, committees, roles, role-menu-permissions,
    // users, dependency-applications, dependency-tools, dependency-vendors,
    // dependency-assets, dependency-processes) keeps rendering through
    // fieldMarkup exactly as before.
    const useLocationViewLayout = entity === "locations" && mode === "view";
    // Location Add/Edit/View (layout compaction, 2026-09-20) -- same
    // 3-column .pm-form-grid-locations modifier as the standalone Location
    // Management screen's openForm() above, applied here too since this
    // function renders the Location tab nested under Organization
    // Administration / Onboarding, which shares the same #recordFields.
    fieldsHost.classList.toggle("pm-form-grid-locations", entity === "locations");
    fieldsHost.innerHTML = entitySchema(entity, mode).map(field => useLocationViewLayout
      ? viewFieldMarkup(field, valueOf(selectedRecord, field.name), selectedRecord)
      : fieldMarkup(field, valueOf(selectedRecord, field.name), readonly, selectedRecord)).join("");
    applyConditionalFields();

    // Role Master is reachable from here as well as from its own screen, and
    // both dialogs share this host. Hooking only one would leave the checklist
    // section missing depending on how the user navigated -- the sort of
    // inconsistency that reads as a bug.
    if (entity === "roles") {
      renderScopeChecklistSection(fieldsHost, {
        organizationId: valueOf(selectedRecord, "organizationId") || setupState.organizationId,
        scopeDimension: "ORG_ROLE",
        scopeValueId:   state.id,
        title:          "Event Checklists for this Role",
        subtitle:       "What has to be done when somebody joins this role, and when they leave it."
      });
    }
    // Committee Members section (migration 370) -- same append pattern as
    // the roles checklist section above, for the Committees tab nested
    // under Organization Administration / Onboarding.
    if (entity === "committees") {
      renderCommitteeMembersSection(fieldsHost, {
        organizationId: valueOf(selectedRecord, "organizationId") || setupState.organizationId,
        members: selectedRecord.members || [],
        readonly
      });
    }

    saveButton.hidden = readonly;
    // View -> Edit (change request 2026-09-20): only for the three
    // entities in VIEW_EDIT_ENTITIES, only in View mode, and only with the
    // same Edit/Add permission the standalone screens' 3-dot Edit action
    // already requires (see allowedActions()'s "edit" branch) -- the
    // pre-existing Edit/Inactive items in this same menu have no such
    // check, but this task specifically calls for the new button to be
    // permission-gated, so it gets its own check rather than inheriting
    // that gap.
    if (editButton) editButton.hidden = !(readonly && VIEW_EDIT_ENTITIES.has(entity) && (permissions.has("EDIT") || permissions.has("ADD")));
    // Reopening on an already-open dialog (View -> Edit clicked without
    // closing first) would throw on showModal() -- see the same guard in
    // openForm() below.
    if (!dialog.open) dialog.showModal();
  }

  // View -> Edit (change request 2026-09-20): re-enters the SAME dialog
  // already open in View mode, in Edit mode, for the record already being
  // viewed. Routes to whichever of the two entry points is live on this
  // page -- isOrganizationWorkspace distinguishes them the same way
  // Manage.cshtml's own two mutually-exclusive #recordDialog blocks do.
  // No new save path: both branches are the exact calls the existing
  // 3-dot "Edit" action already makes.
  function handleEditFromView() {
    if (!state.id) return;
    if (isOrganizationWorkspace) openSetupChildForm(state.formEntity, "edit", state.id, state.activeFormRecord);
    else openForm("edit", state.id);
  }

  async function retireSetupChild(entity, id) {
    // gracUi.confirm -- the project dialog. window.confirm cannot be
    // overridden globally the way window.alert is (sync vs Promise), so
    // each site is converted by hand. See grac-dialog.js.
    if (!id || !await window.gracUi.confirm("Mark this record as inactive?",
          { type: "warning", title: "Mark inactive", confirmText: "Mark inactive" })) return;
    await fetchJson(`${api}/${entity}/retire`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ id: Number(id) })
    });
    await loadLookups();
    await loadSetupChildRows(entity);
  }

  async function loadRows() {
    // Every refetch starts with an empty selection -- page change, search,
    // filter, organization change and Refresh all arrive here. See the note on
    // bulkSelection for why selection does not survive a reload.
    clearBulkSelection();
    if (isSourceStatements) {
      await loadSourceStatements();
      return;
    }
    if (isRolePermissionMatrix) {
      await loadRolePermissionMatrix();
      return;
    }
    // The pager owns the page; state carries it for the dozen call sites
    // that build a payload or a trace line. Read once, here, so every one
    // of them sees the page this load is actually fetching.
    if (gridPager) {
      state.pageNumber = gridPager.page();
      state.pageSize = gridPager.size();
      gridPager.busy(true);
    }
    renderGridHeader();
    if (isOperationalizationWorkbench) renderWorkbenchCategories();
    setListMessage("Loading...");
    if (organizationScopedScreens.has(screen.Key) && !state.navigationCode && organizationFilter && !organizationFilter.value) {
      state.records = [];
      setListMessage("Please select an organization to view organization-specific records.");
      renderPager();
      logListTrace("blocked", { reason: "organization-required" });
      return;
    }
    const payload = {
      search: search.value || "",
      status: status.value || "",
      pageNumber: state.pageNumber,
      pageSize: state.pageSize,
      owner: ownerFilter.value || "",
      criticality: criticalityFilter.value || "",
      originType: originTypeFilter.value || "",
      dateFrom: dateFromFilter.value || "",
      dateTo: dateToFilter.value || ""
    };
    if (organizationFilter?.value) payload.organizationId = Number(organizationFilter.value);
    if (screen.Key === "organization-requirements" && subscribedFrameworkFilter?.value) payload.releaseId = Number(subscribedFrameworkFilter.value);
    if (isOperationalizationWorkbench && state.activeWorkbenchDependencyTypeId === "evidence") payload.registerType = "Evidence";
    else if (isOperationalizationWorkbench && state.activeWorkbenchDependencyTypeId) payload.dependencyTypeId = Number(state.activeWorkbenchDependencyTypeId);
    try {
      const queryRows = data => {
        const entityKey = listEntityKey();
        const url = `${api}/${entityKey}/query`;
        logListTrace("request", { url, payload: data, navigationContext: state.navigationContext || null });
        return fetchJson(url, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          search: data.search,
          status: data.status,
          owner: data.owner,
          criticality: data.criticality,
          originType: data.originType,
          dateFrom: data.dateFrom,
          dateTo: data.dateTo,
          pageNumber: data.pageNumber,
          pageSize: data.pageSize,
          contextCode: state.navigationCode,
          data: {
            ...data,
            // Statement-driven navigation: filter by FrameworkStatementId, never by
            // the removed Control concept.
            organizationControlId: state.navigationContext?.filterType === "FrameworkStatement"
              ? undefined
              : (state.navigationContext?.organizationControlId || data.organizationControlId || undefined),
            frameworkStatementId: state.navigationContext?.filterType === "FrameworkStatement"
              ? (Number(state.navigationContext.filterId) || undefined)
              : (data.frameworkStatementId || undefined),
            releaseId: data.releaseId || (Number(state.navigationContext?.releaseId) || undefined),
            organizationRequirementId: state.navigationContext?.organizationRequirementId || data.organizationRequirementId || undefined,
            practiceId: state.navigationContext?.filterType === "Practice" ? state.navigationContext.filterId : data.practiceId || undefined
          }
        })
      });
      };
      let result = await queryRows(payload);
      let tables = apiTables(result);
      let records = apiData(result);
      logListTrace("response", { rowCount: records.length, tableCount: tables.length, result });
      state.workbenchUnauthorized = (workbenchScreens.has(screen.Key) || isOperationalizationWorkbench)
        && String(valueOf((tables[1] || [])[0] || {}, "IsAuthorized")).toLowerCase() === "false";
      if (!records.length && screen.Key === "practice-instances" && state.navigationCode && payload.status) {
        const fallbackPayload = { ...payload, status: "" };
        const fallbackResult = await queryRows(fallbackPayload);
        const fallbackRecords = apiData(fallbackResult);
        if (fallbackRecords.length) {
          result = fallbackResult;
          tables = apiTables(fallbackResult);
          records = fallbackRecords;
          logListTrace("fallback-response", { reason: "practice-instances-status", rowCount: records.length, tableCount: tables.length, result });
        }
      }
      if (!records.length && ["organization-controls", "control-applicability", "practice-operationalization"].includes(screen.Key) && !state.navigationCode && organizationFilter) {
        const currentOrganizationId = String(organizationFilter.value || "");
        const organizations = (state.lookups.organizations || []).filter(item => String(item.value) !== currentOrganizationId);
        for (const organization of organizations) {
          const fallbackPayload = { ...payload, organizationId: Number(organization.value) };
          const fallbackResult = await queryRows(fallbackPayload);
          const fallbackRecords = apiData(fallbackResult);
          if (fallbackRecords.length) {
            organizationFilter.value = String(organization.value);
            rememberOrganizationId(organizationFilter.value);
            payload.organizationId = fallbackPayload.organizationId;
            result = fallbackResult;
            tables = apiTables(fallbackResult);
            records = fallbackRecords;
            logListTrace("fallback-response", { reason: "alternate-organization", organizationId: fallbackPayload.organizationId, rowCount: records.length, tableCount: tables.length, result });
            break;
          }
        }
      }
      state.records = records;
      if (screen.Key === "organization-requirements") {
        console.info("PracticeManagement Organization Practices payload", payload);
        console.info("PracticeManagement Organization Practices rows returned", records.length);
        console.info("PracticeManagement Organization Practices response", result);
      }
      if (!state.records.length && window.pmDebug === true) {
        console.warn("PracticeManagement list returned no rows.", {
          screen: screen.Key,
          payload,
          navigationContext: state.navigationContext || null,
          requestedOrganizationId: payload.organizationId || state.navigationContext?.organizationId || "",
          requestedOrganizationControlId: state.navigationContext?.organizationControlId || payload.organizationControlId || "",
          requestedOrganizationRequirementId: state.navigationContext?.organizationRequirementId || payload.organizationRequirementId || "",
          requestedPracticeId: state.navigationContext?.filterType === "Practice" ? state.navigationContext.filterId : payload.practiceId || "",
          tables,
          result
        });
      }
      renderRows();
    } catch (error) {
      state.records = [];
      setListMessage(error.message || "Unable to load records.");
      logListTrace("error", { message: error.message || String(error), payload });
    }
    renderPager();
  }

  async function loadSourceStatements() {
    const organizationId = organizationFilter?.value || "";
    if (!organizationId) {
      sourceStatementState.level = "releases";
      sourceStatementState.release = null;
      state.records = [];
      renderReleaseSummaryHeader();
      rows.innerHTML = `<tr><td colspan="${releaseSummaryColumns.length}" class="pm-empty">Please select an organization to view subscribed framework releases.</td></tr>`;
      renderPager();
      return;
    }
    if (sourceStatementState.release && String(sourceStatementState.release.organizationId) !== String(organizationId)) {
      sourceStatementState.level = "releases";
      sourceStatementState.release = null;
      // Org changed -- allow the source-statements screen to auto-drill
      // into the new org's first release again (bug: without this reset,
      // the screen shows the release summary instead of statements).
      sourceStatementState.hasAutoDrilled = false;
    }
    if (sourceStatementState.release && subscribedFrameworkFilter?.value
      && String(subscribedFrameworkFilter.value) !== String(sourceStatementState.release.releaseId)) {
      sourceStatementState.level = "releases";
      sourceStatementState.release = null;
      // Release filter changed -- treat as a new drill target.
      sourceStatementState.hasAutoDrilled = false;
    }
    if (sourceStatementState.level === "statements" && sourceStatementState.release) {
      if (sourceStatementState.isCustomRelease) {
        await loadCustomReleaseStatements();
      } else {
        await loadReleaseStatements();
      }
      return;
    }
    await loadReleaseSummary();
  }

  function renderReleaseSummaryHeader() {
    setGridLevel("releases");
    if (!tableHead) return;
    // Two-row header: Framework / Release, Owner and Actions span both rows;
    // the five counts sit under a single "Governance Overview" group cell.
    tableHead.innerHTML = `<tr>
      <th rowspan="2">${escapeHtml(releaseSummaryColumns[0])}</th>
      <th rowspan="2">${escapeHtml(releaseSummaryColumns[1])}</th>
      <th class="pm-th-group" colspan="${releaseSummaryMetricColumns.length}">Governance Overview</th>
      <th rowspan="2">Actions</th>
    </tr><tr>${releaseSummaryMetricColumns.map(column => `<th class="pm-th-metric">${escapeHtml(column)}</th>`).join("")}</tr>`;
  }

  // Marks which level of the two-level Repository Subscriptions grid is on
  // screen. Only the CSS reads it -- the release summary's count columns must
  // not inherit the wide name-column widths meant for the statement tree, and
  // the statement tree sizes its columns by class rather than by position.
  function setGridLevel(level) {
    if (tableWrap) tableWrap.dataset.gridLevel = level;
  }

  function renderStatementTreeHeader() {
    setGridLevel("statement-tree");
    if (!tableHead) return;
    tableHead.innerHTML = `<tr>${bulkHeaderCell()}${statementTreeColumnDefs
      .map(column => `<th${column.cls ? ` class="${column.cls}"` : ""}>${escapeHtml(column.label)}</th>`)
      .join("")}</tr>`;
  }

  function updateAddButtonLabel() {
    if (!isSourceStatements || !addButton) return;
    // Rule 4 — employees never see Add Release / Add Source Statement /
    // Manage Source Structure buttons. Only Applicability Marking is
    // allowed on the statement rows.
    if (isEmployeeScope) {
      addButton.hidden = true;
      const structureBtn = document.getElementById("manageSourceStructureBtn");
      if (structureBtn) structureBtn.hidden = true;
      return;
    }
    addButton.hidden = false;
    const label = sourceStatementState.level === "statements" ? "Add Control Statement" : "Add Release";
    addButton.innerHTML = `<i class="fa-solid fa-plus" aria-hidden="true"></i> ${label}`;
    // Show/hide "Manage Source Structure" button for custom releases
    let structureBtn = document.getElementById("manageSourceStructureBtn");
    if (sourceStatementState.level === "statements" && sourceStatementState.isCustomRelease) {
      if (!structureBtn) {
        structureBtn = document.createElement("button");
        structureBtn.className = "pm-button";
        structureBtn.id = "manageSourceStructureBtn";
        structureBtn.type = "button";
        structureBtn.innerHTML = `<i class="fa-solid fa-sitemap" aria-hidden="true"></i> Manage Source Structure`;
        structureBtn.addEventListener("click", () => openSourceStructurePanel());
        addButton.parentNode.insertBefore(structureBtn, addButton);
      }
      structureBtn.hidden = false;
    } else if (structureBtn) {
      structureBtn.hidden = true;
    }
  }

  async function loadReleaseSummary() {
    renderReleaseSummaryHeader();
    const colspan = releaseSummaryColumns.length;
    rows.innerHTML = `<tr><td colspan="${colspan}" class="pm-empty">Loading subscribed framework releases...</td></tr>`;
    state.records = [];
    try {
      const result = await fetchJson(`${api}/subscribed-frameworks/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ data: { organizationId: Number(organizationFilter.value), pageNumber: 1, pageSize: 500 } })
      });
      let releases = apiData(result);
      const term = (search?.value || "").trim().toLowerCase();
      if (term) {
        releases = releases.filter(release =>
          `${valueOf(release, "FrameworkRelease")} ${valueOf(release, "Authority")} ${valueOf(release, "AuthorityCode")} ${valueOf(release, "ArtifactName")} ${valueOf(release, "ArtifactCode")} ${valueOf(release, "ReleaseVersion")}`
            .toLowerCase().includes(term));
      }
      if (subscribedFrameworkFilter?.value) {
        releases = releases.filter(release => String(valueOf(release, "ReleaseId")) === String(subscribedFrameworkFilter.value));
      }
      // Source filter: Repository = positive ReleaseId, Organization = negative ReleaseId
      const sourceFilterValue = (sourceFilter?.value || "").toLowerCase();
      if (sourceFilterValue === "repository") {
        releases = releases.filter(release => Number(valueOf(release, "ReleaseId") || 0) > 0);
      } else if (sourceFilterValue === "organization") {
        releases = releases.filter(release => Number(valueOf(release, "ReleaseId") || 0) < 0);
      }
      // Rule 4 — employee-scope users only see releases they own or are
      // assigned to. Server-side filtering via fn_visible_releases is the
      // source of truth; this client-side filter is a defence-in-depth
      // narrow-down against rows the API might still return.
      if (isEmployeeScope) {
        const empId = sessionEmployeeId ? Number(sessionEmployeeId) : 0;
        releases = releases.filter(release =>
          Number(valueOf(release, "OwnerId") || 0) === empId
          || String(valueOf(release, "IsAssignedToCurrentUser") || "").toLowerCase() === "true"
        );
      }
      sourceStatementState.releases = releases;
      state.records = releases; // needed by allowedActions() for the 3-dot menu
      logListTrace("response", { level: "releases", rowCount: releases.length });
      if (!releases.length) {
        // Empty state -- when on the dedicated Source Statements screen,
        // keep the statement-tree columns (per requirement 6) so the user
        // doesn't see a release-summary column set with no rows.
        if (isSourceStatementDetail) {
          renderStatementTreeHeader();
          rows.innerHTML = `<tr><td colspan="${statementTreeColumns.length}" class="pm-empty">No subscribed releases found. Subscribe releases in Governance - Standards & Frameworks.</td></tr>`;
        } else {
          rows.innerHTML = `<tr><td colspan="${colspan}" class="pm-empty">No subscribed framework releases found for the selected organization. Subscribe releases in Organization Setup - Standards & Frameworks.</td></tr>`;
        }
        renderPager();
        return;
      }

      // If we're going to auto-drill anyway (source-statements screen,
      // or employee-scope + 1 release), skip painting the release
      // summary grid entirely -- rendering then instantly replacing it
      // makes the RS2 grid flash on organization change.
      const willAutoDrill =
        (isEmployeeScope && releases.length === 1) ||
        (isSourceStatementDetail && !sourceStatementState.hasAutoDrilled && releases.length >= 1);
      if (willAutoDrill) {
        const only = releases[0];
        sourceStatementState.release = mapReleaseSelection(only);
        sourceStatementState.isCustomRelease = Number(valueOf(only, "ReleaseId") || 0) < 0;
        sourceStatementState.level = "statements";
        sourceStatementState.hasAutoDrilled = true;
        await loadSourceStatements();
        return;
      }

      rows.innerHTML = releases.map((release, index) => {
        const ownerLabel = String(valueOf(release, "OwnerName") || "").trim();
        const ownerCell = ownerLabel
          ? escapeHtml(ownerLabel)
          // .pm-empty is the full-width "no rows" style: 20px of vertical
          // padding and text-align:center. Inside an owner cell that pushed
          // "Unassigned" out of line with the owner names above and below it,
          // so the placeholder uses the inline muted-cell style instead.
          : `<span class="pm-cell-muted">Unassigned</span>`;
        return `<tr class="pm-release-source-row" data-release-index="${index}" style="cursor:pointer" title="View Control Statements for this release">
        <td><i class="fa-solid fa-chevron-right" aria-hidden="true"></i> ${escapeHtml(valueOf(release, "FrameworkRelease") || valueOf(release, "ReleaseVersion"))}</td>
        <td>${ownerCell}</td>
        <td>${escapeHtml(valueOf(release, "TotalStatementsCount") ?? valueOf(release, "TotalRequirementsCount") ?? 0)}</td>
        <td>${escapeHtml(valueOf(release, "NotApplicableStatementsCount") ?? valueOf(release, "NotApplicableDeferredRequirementsCount") ?? 0)}</td>
        <td>${escapeHtml(valueOf(release, "ApplicableStatementsCount") ?? valueOf(release, "ApplicableMarkedRequirementsCount") ?? 0)}</td>
        <td>${escapeHtml(valueOf(release, "ImplementedStatementsCount") ?? 0)}</td>
        <td>${escapeHtml(valueOf(release, "NotUpdatedStatementsCount") ?? valueOf(release, "NotUpdatedRequirementsCount") ?? 0)}</td>
        <td class="pm-actions-cell" data-stop-row-click>${releaseActionsMarkup(index, release)}</td>
      </tr>`;
      }).join("");

      // Rule 4 — Employee-scope users see ONLY assigned releases and land
      // directly on the statements list when they open the only release
      // they have. If the filter left one row, auto-drill.
      //
      // Same auto-drill fires on the dedicated 'source-statements' screen
      // (migration 056) so the Source Statements menu opens directly on
      // the Level 2 statement grid. Gated by hasAutoDrilled so the Back
      // button on that screen doesn't re-drill in a loop.
      const shouldAutoDrillEmployee = isEmployeeScope && releases.length === 1;
      const shouldAutoDrillDetail   = isSourceStatementDetail
                                     && !sourceStatementState.hasAutoDrilled
                                     && releases.length >= 1;
      if (shouldAutoDrillEmployee || shouldAutoDrillDetail) {
        const only = releases[0];
        sourceStatementState.release = mapReleaseSelection(only);
        sourceStatementState.isCustomRelease = Number(valueOf(only, "ReleaseId") || 0) < 0;
        sourceStatementState.level = "statements";
        sourceStatementState.hasAutoDrilled = true;
        await loadSourceStatements();
        return;
      }
    } catch (error) {
      rows.innerHTML = `<tr><td colspan="${colspan}" class="pm-empty">${escapeHtml(error.message || "Unable to load subscribed framework releases.")}</td></tr>`;
      logListTrace("error", { level: "releases", message: error.message || String(error) });
    }
    renderPager();
  }

  async function loadReleaseStatements() {
    updateAddButtonLabel();
    const release = sourceStatementState.release;
    renderStatementTreeHeader();
    rows.innerHTML = `<tr><td colspan="${statementTreeColumns.length}" class="pm-empty">Loading source statements...</td></tr>`;
    try {
      const result = await fetchJson(`${api}/release-statements/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          search: search?.value || "",
          data: { organizationId: Number(release.organizationId), releaseId: Number(release.releaseId), pageNumber: 1, pageSize: 2000 }
        })
      });
      sourceStatementState.rows = apiData(result);
      logListTrace("response", { level: "statements", releaseId: release.releaseId, rowCount: sourceStatementState.rows.length });
      renderStatementTree();
    } catch (error) {
      state.records = [];
      rows.innerHTML = `${statementBreadcrumbRow()}<tr><td colspan="${statementTreeColumns.length}" class="pm-empty">${escapeHtml(error.message || "Unable to load source statements.")}</td></tr>`;
      logListTrace("error", { level: "statements", message: error.message || String(error) });
    }
    renderPager();
  }

  function statementBreadcrumbRow() {
    return "";
  }

  // Node hierarchy path + the statement's own reference in one value.
  // The last hierarchy segment is usually the statement's reference already
  // (node 7.2 holding statement 7.2), so appending it blindly would print
  // "REQ-7 / 7.2 / 7.2". Append only when it actually adds something.
  function statementReferencePath(hierarchy, statementReference) {
    const path = String(hierarchy || "").trim();
    const reference = String(statementReference || "").trim();
    if (!reference) return path;
    if (!path) return reference;
    const lastSegment = path.split("/").pop().trim();
    return lastSegment.toLowerCase() === reference.toLowerCase() ? path : `${path} / ${reference}`;
  }

  function renderStatementTree() {
    const cols = statementTreeColumns;
    const statusFilter = (status?.value || "").trim().toLowerCase();
    const allRows = sourceStatementState.rows || [];

    // Build node lookup and hierarchy paths
    const nodes = new Map();
    allRows.filter(row => String(valueOf(row, "RowType")).toLowerCase() === "node").forEach(row => {
      nodes.set(String(valueOf(row, "SourceStructureNodeId")), {
        row,
        ref: String(valueOf(row, "SourceStructureReference") || "").trim(),
        parentId: String(valueOf(row, "ParentSourceStructureNodeId") || "")
      });
    });

    // Build full hierarchy path for each node (e.g. "CH1 / CH2 / CH3")
    const pathCache = new Map();
    function nodePath(nodeId) {
      if (pathCache.has(nodeId)) return pathCache.get(nodeId);
      const node = nodes.get(nodeId);
      if (!node) { pathCache.set(nodeId, ""); return ""; }
      const parentPath = node.parentId && nodes.has(node.parentId) ? nodePath(node.parentId) : "";
      const path = parentPath ? `${parentPath} / ${node.ref}` : node.ref;
      pathCache.set(nodeId, path);
      return path;
    }

    // Collect statement rows only (no node rows as separate grid rows)
    const statements = allRows
      .filter(row => String(valueOf(row, "RowType")).toLowerCase() === "statement")
      .filter(row => !statusFilter || String(valueOf(row, "ApplicabilityStatus") || "Not Updated").toLowerCase() === statusFilter);

    // Sort by hierarchy path then statement order
    statements.sort((a, b) => {
      const pathA = nodePath(String(valueOf(a, "SourceStructureNodeId")));
      const pathB = nodePath(String(valueOf(b, "SourceStructureNodeId")));
      const cmp = pathA.localeCompare(pathB, undefined, { numeric: true });
      if (cmp !== 0) return cmp;
      return Number(valueOf(a, "StatementDisplayOrder") || 0) - Number(valueOf(b, "StatementDisplayOrder") || 0)
        || String(valueOf(a, "StatementReference")).localeCompare(String(valueOf(b, "StatementReference")), undefined, { numeric: true });
    });

    state.records = statements;
    closeActionMenu();

    const htmlRows = statements.map((s, i) => {
      const reference = statementReferencePath(nodePath(String(valueOf(s, "SourceStructureNodeId"))), valueOf(s, "StatementReference"));
      // Statement -> Organization Practices row-click: mirrors the release
      // row-click that drills Framework -> Control Statements. Only rows that
      // actually offer the "Practices" 3-dot action are made clickable, i.e.
      // an Applicable framework statement on a subscribed (non-custom) release,
      // and not for employee-scope users -- matching openActionMenu's gating so
      // the row click and the menu item resolve to the exact same navigation.
      const appCode = String(valueOf(s, "ApplicabilityStatusCode") || "").trim().toLowerCase();
      const appText = String(valueOf(s, "ApplicabilityStatus") || "Not Updated").trim().toLowerCase();
      const canOpenPractices = (appCode || appText) === "applicable"
        && !sourceStatementState.isCustomRelease
        && !isEmployeeScope
        && Boolean(valueOf(s, "FrameworkStatementId"));
      const rowAttrs = canOpenPractices
        ? ` class="pm-row-clickable" data-statement-index="${i}" title="View Organization Practices mapped to this statement"`
        : "";
      return `<tr${rowAttrs}>
        ${bulkCell(s)}
        <td class="pm-cell-ref" title="${escapeHtml(reference)}">${escapeHtml(reference)}</td>
        <td class="pm-cell-title">${escapeHtml(valueOf(s, "StatementTitle"))}</td>
        <td>${formatCell(valueOf(s, "ApplicabilityStatus") || "Not Updated")}</td>
        <td>${formatCell(valueOf(s, "ImplementationStatus") || "Not Implemented")}</td>
        <td>${escapeHtml(valueOf(s, "PracticeCount") || 0)}</td>
        <td>${actions(i)}</td>
      </tr>`;
    });

    // Rows that are no longer on screen must not stay ticked -- a status
    // filter can remove an eligible row without a refetch.
    pruneBulkSelection(statements);

    rows.innerHTML = statementBreadcrumbRow() + (htmlRows.length
      ? htmlRows.join("")
      : `<tr><td colspan="${cols.length + bulkColumnCount()}" class="pm-empty">No source statements found for this framework release.</td></tr>`);
  }

  function openStatementView(record) {
    state.mode = "view";
    state.formEntity = "statement-applicability";
    state.activeFormRecord = record;
    formMessage.hidden = true;
    document.querySelector("#dialogTitle").textContent = "View Control Statement";
    fieldsHost.innerHTML = `
      <label class="pm-field"><span>Statement Reference</span><input value="${escapeHtml(valueOf(record, "StatementReference"))}" disabled></label>
      <label class="pm-field"><span>Statement Title</span><input value="${escapeHtml(valueOf(record, "StatementTitle"))}" disabled></label>
      <label class="pm-field full"><span>Statement Text</span><textarea rows="5" disabled>${escapeHtml(valueOf(record, "StatementText"))}</textarea></label>
      <label class="pm-field"><span>Source Structure</span><input value="${escapeHtml(`${valueOf(record, "SourceStructureReference")} ${valueOf(record, "SourceStructureTitle")}`.trim())}" disabled></label>
      <label class="pm-field"><span>Applicability Status</span><input value="${escapeHtml(valueOf(record, "ApplicabilityStatus") || "Not Updated")}" disabled></label>
      <label class="pm-field"><span>Owner</span><input value="${escapeHtml(valueOf(record, "OwnerName"))}" disabled></label>
      <label class="pm-field"><span>Applicable / Total Practices</span><input value="${escapeHtml(valueOf(record, "ApplicablePracticeCount") || 0)} / ${escapeHtml(valueOf(record, "PracticeCount") || 0)}" disabled></label>
      <label class="pm-field full"><span>Reason / Justification</span><textarea rows="3" disabled>${escapeHtml(valueOf(record, "ExclusionJustification"))}</textarea></label>`;
    saveButton.hidden = true;
    dialog.showModal();
  }

  function openStatementApplicabilityForm(record) {
    state.mode = "statementApplicability";
    state.id = Number(valueOf(record, "OrgStatementId") || 0);
    state.formEntity = "statement-applicability";
    state.activeFormRecord = record;
    formMessage.hidden = true;
    const current = valueOf(record, "ApplicabilityStatus") || "Not Updated";
    const statusOptions = ["Not Updated", "Applicable", "Not Applicable", "Retired"]
      .map(value => `<option value="${value}"${value === current ? " selected" : ""}>${value}</option>`).join("");
    document.querySelector("#dialogTitle").textContent = `${current === "Not Updated" ? "Mark" : "Update"} Statement Applicability`;
    fieldsHost.innerHTML = `
      <input name="organizationId" type="hidden" value="${escapeHtml(sourceStatementState.release?.organizationId || organizationFilter?.value || "")}">
      <input name="releaseId" type="hidden" value="${escapeHtml(sourceStatementState.release?.releaseId || "")}">
      <input name="frameworkStatementId" type="hidden" value="${escapeHtml(valueOf(record, "FrameworkStatementId"))}">
      <label class="pm-field"><span>Statement Reference</span><input value="${escapeHtml(valueOf(record, "StatementReference"))}" disabled></label>
      <label class="pm-field"><span>Statement Title</span><input value="${escapeHtml(valueOf(record, "StatementTitle"))}" disabled></label>
      <label class="pm-field full"><span>Statement Text</span><textarea rows="3" disabled>${escapeHtml(valueOf(record, "StatementText"))}</textarea></label>
      <label class="pm-field"><span>Applicability Status<span class="required"> *</span></span><select name="applicabilityStatus" required>${statusOptions}</select></label>
      <label class="pm-field"><span>Owner</span><select name="ownerId">${optionsFor("owners-id", valueOf(record, "OwnerId"))}</select></label>
      <label class="pm-field full"><span>Reason / Justification</span><textarea name="exclusionJustification" rows="3">${escapeHtml(valueOf(record, "ExclusionJustification"))}</textarea></label>`;
    saveButton.hidden = false;
    dialog.showModal();
  }

  // --- Bulk Mark Applicability -------------------------------------------
  //
  // One modal, one set of values, applied to every ticked row. The fields are
  // the single-record form's, per screen -- same labels, same lookups, same
  // status vocabulary -- because a user who has marked one record should
  // recognise this immediately.
  //
  // Note the two vocabularies are genuinely different and always have been:
  // a statement is Not Updated / Applicable / Not Applicable / Retired (the
  // list openStatementApplicabilityForm hard-codes, matching THROW 51044),
  // while a practice takes whatever applicability_status_master publishes
  // through the "applicability-status" lookup. Bulk keeps them apart rather
  // than inventing a third.
  // The organization the bulk applies to. On Source Statements it is the
  // drilled-into release's organization; on Practices it is the filter, or the
  // navigation context when the screen was opened from a Control or Statement.
  function bulkOrganizationId() {
    return Number(
      isSourceStatements
        ? (sourceStatementState.release?.organizationId || organizationFilter?.value || 0)
        : (organizationFilter?.value || state.navigationContext?.organizationId || 0)
    ) || 0;
  }

  function openBulkApplicabilityForm() {
    if (!bulkSelection.size) return;
    state.mode = "bulkApplicability";
    state.id = 0;
    state.formEntity = isSourceStatements ? "statement-applicability-bulk" : "requirement-applicability-bulk";
    // Carries OrganizationId so currentFormOrganizationId -- and through it the
    // Owner picker -- resolves to this organization's Active employees, the
    // same way openReleaseOwnerForm seeds it. Leaving it null would fall back
    // to the toolbar filter, which is empty on a drilled-in Practices screen.
    state.activeFormRecord = { OrganizationId: bulkOrganizationId() };
    formMessage.hidden = true;

    const count = bulkSelection.size;
    const noun = isSourceStatements
      ? (count === 1 ? "Control Statement" : "Control Statements")
      : (count === 1 ? "Practice" : "Practices");
    document.querySelector("#dialogTitle").textContent = `Mark Applicability - ${count} ${noun}`;

    if (isSourceStatements) {
      const statusOptions = ["Applicable", "Not Applicable", "Retired"]
        .map(value => `<option value="${value}">${value}</option>`).join("");
      fieldsHost.innerHTML = `
        <p class="pm-empty compact" style="grid-column:1/-1">The Owner, Applicability Status and Reason below are applied to all ${count} selected ${noun.toLowerCase()}.</p>
        <label class="pm-field"><span>Applicability Status<span class="required"> *</span></span><select name="applicabilityStatus" required><option value="">Select status</option>${statusOptions}</select></label>
        <label class="pm-field"><span>Owner<span class="required"> *</span></span><select name="ownerId" required>${optionsFor("owners-id", "")}</select></label>
        <label class="pm-field full"><span>Reason / Justification</span><textarea name="exclusionJustification" rows="3"></textarea></label>`;
    } else {
      fieldsHost.innerHTML = `
        <p class="pm-empty compact" style="grid-column:1/-1">The Owner, Applicability Status and Reason below are applied to all ${count} selected ${noun.toLowerCase()}.</p>
        <label class="pm-field"><span>Applicability Status<span class="required"> *</span></span><select name="applicabilityStatus" required>${optionsFor("applicability-status", "", undefined, PRACTICE_APPLICABILITY_STATUSES)}</select></label>
        <label class="pm-field"><span>Owner<span class="required"> *</span></span><select name="practiceOwnerId" required>${optionsFor("owners-id", "")}</select></label>
        <label class="pm-field full"><span>Reason / Justification</span><textarea name="exclusionJustification" rows="3"></textarea></label>`;
    }
    saveButton.hidden = false;
    dialog.showModal();
  }

  // Mirrors the conditional rules the single-record save enforces, so the user
  // is told before the round trip rather than getting fifty identical skips
  // back. The SERVER remains the authority -- these same rules live in
  // SaveStatementApplicabilityAsync (51045/51047) and in the
  // organization-requirements branch of pm_manage_practice_repository
  // (51032/51034) -- which is why a rule missed here still cannot get past it.
  function validateBulkApplicability(data) {
    const status = String(data.applicabilityStatus || "").trim();
    const reason = String(data.exclusionJustification || "").trim();
    const reasonRequiredFor = isSourceStatements
      ? ["Not Applicable"]
      : ["Not Applicable", "Deferred", "Accepted Risk"];
    if (reasonRequiredFor.includes(status) && !reason) {
      fieldsHost.querySelector("[name='exclusionJustification']")?.classList.add("field-error");
      throw new Error(`Reason / Justification is required when applicability is ${reasonRequiredFor.join(", ")}.`);
    }
  }

  async function saveBulkApplicability() {
    const data = collectForm();
    validateBulkApplicability(data);

    const ids = [...bulkSelection];
    const organizationId = bulkOrganizationId();
    if (!organizationId) throw new Error("Organization could not be resolved. Select an organization and try again.");

    if (isSourceStatements) {
      const releaseId = Number(sourceStatementState.release?.releaseId || 0) || 0;
      if (!releaseId) throw new Error("Framework release could not be resolved. Reopen the release and try again.");
      data.organizationId = organizationId;
      data.releaseId = releaseId;
      data.frameworkStatementIds = ids;
    } else {
      data.organizationId = organizationId;
      data.organizationRequirementIds = ids;
    }

    const result = await fetchJson(`${api}/${state.formEntity}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ id: 0, contextCode: state.navigationCode, data })
    });

    // Skipped rows come back with their own reason. Surfacing them is the
    // point of skip-and-report: a silent partial success is worse than none.
    const rows = apiData(result);
    const skipped = rows.filter(row => String(valueOf(row, "Outcome")).toLowerCase() === "skipped");
    const message = result.message || result.Message || "Applicability updated.";
    dialog.close();
    clearBulkSelection();
    await loadRows();
    if (skipped.length) {
      const detail = skipped
        .slice(0, 5)
        .map(row => `- ${valueOf(row, "Id")}: ${valueOf(row, "Reason") || "Could not be updated."}`)
        .join("\n");
      const more = skipped.length > 5 ? `\n...and ${skipped.length - 5} more.` : "";
      window.alert(`${message}\n\nSkipped:\n${detail}${more}`);
    } else if (message) {
      window.alert(message);
    }
  }

  // --- Add Custom Release form (organization-specific, not repository) ---
  // Rule 3 — Update Owner action for the 3-dot menu on subscribed
  // framework release rows (Level 1 of Source Statements). Reassigns
  // repository_subscription.owner_id.
  //
  // Resolves the subscription id from the row in this order:
  //   1. SubscriptionId column (present after the recent API fix, both
  //      centrally-subscribed and Custom rows).
  //   2. For Custom releases the ReleaseId is `-1 * subscription_id`, so
  //      Math.abs(ReleaseId) is a safe fallback.
  //   3. If neither works we surface the specific reason.
  function openReleaseOwnerForm(release) {
    const orgId = Number(valueOf(release, "OrganizationId") || organizationFilter?.value || 0);
    const releaseIdRaw = Number(valueOf(release, "ReleaseId") || 0);
    let subscriptionId = Number(valueOf(release, "SubscriptionId") || 0);
    if (!subscriptionId && releaseIdRaw < 0) subscriptionId = Math.abs(releaseIdRaw);
    if (!orgId) { alert("Organization is required to update the release owner."); return; }
    if (!subscriptionId) {
      alert("Release subscription id could not be resolved from this row. Please refresh the list and try again.");
      return;
    }
    // Set activeFormRecord so lookupItemsFor("users") filters employees
    // by the correct organizationId (Rule 3, step 3 — only Active
    // employees of the same Organization appear in the picker).
    state.activeFormRecord = { OrganizationId: orgId };
    state.mode = "updateReleaseOwner";
    state.id = subscriptionId;
    state.formEntity = "subscription-owner";
    formMessage.hidden = true;
    document.querySelector("#dialogTitle").textContent = "Update Release Owner";
    const releaseTitle = valueOf(release, "FrameworkRelease") || valueOf(release, "ReleaseVersion") || "";
    // IMPORTANT: bind the picker to the `owners-id` lookup, NOT `users`
    // or `owners`. In 02_Create_Procedures.sql the `users`/`owners`
    // lookups emit `employee_name` as their Value (used for legacy
    // free-text owners), while `owners-id` (342: the functional-user
    // subset of `users-id`) emits the numeric employee_id -- which is
    // what repository_subscription.owner_id needs. Using a name-valued
    // lookup was the reason the API kept rejecting saves with
    // "Please select an employee to assign as the release owner."
    const employeeOptions = optionsFor("owners-id", valueOf(release, "OwnerId"));
    fieldsHost.innerHTML = `
      <input name="organizationId" type="hidden" value="${escapeHtml(orgId)}">
      <input name="subscriptionId" type="hidden" value="${escapeHtml(subscriptionId)}">
      <label class="pm-field"><span>Release</span><input value="${escapeHtml(releaseTitle)}" disabled></label>
      <label class="pm-field"><span>Source</span><input value="${escapeHtml(valueOf(release, "SubscriptionType") || (releaseIdRaw < 0 ? "Custom" : "Central"))}" disabled></label>
      <label class="pm-field"><span>Owner<span class="required"> *</span></span><select name="ownerId" required>${employeeOptions}</select></label>`;
    saveButton.hidden = false;
    dialog.showModal();
  }

  // Rule 3 — Retire action for the Custom-release-only menu items.
  // Marks the subscription inactive via the standard retire endpoint.
  // Rule 6 — best-effort resend of the one-time credentials to an
  // Organization GRAC Admin. Reuses the same provision-and-notify
  // endpoint; the SP updates the password hash + resets
  // email_credentials_sent, then the email service tries again.
  async function resendUserCredentials(record) {
    const email = valueOf(record, "Email") || valueOf(record, "EmployeeCode");
    const orgId = organizationFilter?.value || valueOf(record, "OrganizationId");
    if (!email || !orgId) { alert("Cannot resend credentials — missing email or organization."); return; }
    if (!await window.gracUi.confirm(`Resend admin credentials to ${email}?`,
          { title: "Resend credentials", confirmText: "Resend" })) return;
    try {
      const resp = await fetchJson(`${api}/organization-admin/provision-and-notify`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          organizationId: Number(orgId),
          adminEmail: String(email),
          adminName: String(valueOf(record, "EmployeeName") || email),
          organizationName: (organizationFilter?.selectedOptions?.[0]?.textContent || "").trim()
        })
      });
      alert((resp?.credentialsEmailed
        ? "Credentials email sent successfully."
        : `Credentials were re-generated but the email could not be delivered. Reason: ${resp?.emailFailureReason || "unknown"}.`)
        + describeAccessProvisioning(resp));
    } catch (error) {
      alert(error.message || "Unable to resend credentials.");
    }
  }

  async function retireCustomRelease(release) {
    const subscriptionId = Number(valueOf(release, "SubscriptionId") || 0);
    if (!subscriptionId) { alert("Cannot retire this release."); return; }
    if (!await window.gracUi.confirm(
          `Retire release "${valueOf(release, "FrameworkRelease") || valueOf(release, "ReleaseVersion")}"?`,
          { type: "warning", title: "Retire release", confirmText: "Retire" })) return;
    try {
      await fetchJson(`${api}/repository-subscriptions/retire`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id: subscriptionId })
      });
      await loadSourceStatements();
    } catch (error) {
      alert(error.message || "Unable to retire the release.");
    }
  }

  // release is present for the Edit action (3-dot menu, Custom rows only)
  // and absent for the toolbar's Add Release button. Owner reuses the exact
  // picker the Subscribed-release Update Owner dialog uses (openReleaseOwnerForm
  // below): the owners-id lookup (numeric employee_id, not the name-valued
  // owners lookup), scoped to this organization's Active employees via
  // state.activeFormRecord the same way. Optional here -- unlike the
  // dedicated Update Owner dialog, which exists solely to set one -- so a
  // release can still be saved Unassigned, exactly as before this field
  // existed.
  //
  // Owner is no longer offered as a separate "Update Owner" action for
  // Custom releases (see allowedReleaseActions) -- ticket: "a separate Owner
  // update page is not necessary" for Custom releases now that this form
  // carries it. Subscribed releases keep that dedicated flow untouched.
  function openCustomReleaseForm(release) {
    const isEdit = !!release;
    const orgId = isEdit
      ? Number(valueOf(release, "OrganizationId") || organizationFilter?.value || 0)
      : (organizationFilter?.value || "");
    if (!orgId) { alert("Please select an organization first."); return; }

    let subscriptionId = 0;
    if (isEdit) {
      // Same SubscriptionId-first, |ReleaseId|-fallback resolution
      // openReleaseOwnerForm uses -- Custom rows carry ReleaseId = -1 *
      // subscription_id wherever SubscriptionId itself is not present.
      subscriptionId = Number(valueOf(release, "SubscriptionId") || 0);
      const releaseIdRaw = Number(valueOf(release, "ReleaseId") || 0);
      if (!subscriptionId && releaseIdRaw < 0) subscriptionId = Math.abs(releaseIdRaw);
      if (!subscriptionId) {
        alert("Custom release id could not be resolved from this row. Please refresh the list and try again.");
        return;
      }
    }

    // Rule 3 pattern (openReleaseOwnerForm): activeFormRecord.OrganizationId
    // must be set BEFORE optionsFor("owners-id", ...) below, so the Owner
    // picker is scoped to this organization's employees, not the toolbar
    // filter or some other org's list.
    state.activeFormRecord = { OrganizationId: orgId };
    state.mode = isEdit ? "editRelease" : "addRelease";
    state.id = subscriptionId;
    state.formEntity = "custom-release";
    formMessage.hidden = true;
    document.querySelector("#dialogTitle").textContent = isEdit ? "Edit Release" : "Add Release";

    const nameVal = isEdit ? String(valueOf(release, "ReleaseVersion") || "") : "";
    const effectiveVal = isEdit ? String(valueOf(release, "EffectiveDate") || "").slice(0, 10) : "";
    const endVal = isEdit ? String(valueOf(release, "EndDate") || "").slice(0, 10) : "";
    const notesVal = isEdit ? String(valueOf(release, "ReleaseNotes") || "") : "";
    // owners-id, not owners: repository_subscription.owner_id needs the
    // numeric employee_id, the same reason openReleaseOwnerForm's comment
    // gives -- a name-valued lookup here would reproduce the exact "Please
    // select an employee..." save failure that fix exists to avoid.
    const ownerOptions = optionsFor("owners-id", isEdit ? valueOf(release, "OwnerId") : "");

    fieldsHost.innerHTML = `
      <input name="organizationId" type="hidden" value="${escapeHtml(orgId)}">
      ${isEdit ? `<input name="subscriptionId" type="hidden" value="${escapeHtml(subscriptionId)}">` : ""}
      <label class="pm-field"><span>Authority</span><input value="Organization" disabled></label>
      <label class="pm-field"><span>Artifact</span><input value="Custom" disabled></label>
      <label class="pm-field"><span>Release Name<span class="required"> *</span></span><input name="customReleaseName" required placeholder="e.g. Internal Policy v1.0" value="${escapeHtml(nameVal)}"></label>
      <label class="pm-field"><span>Owner</span><select name="ownerId">${ownerOptions}</select></label>
      <label class="pm-field"><span>Effective Date</span><input name="effectiveDate" type="date" value="${escapeHtml(effectiveVal)}"></label>
      <label class="pm-field"><span>End Date</span><input name="endDate" type="date" value="${escapeHtml(endVal)}"></label>
      <label class="pm-field full"><span>Release Notes</span><textarea name="releaseNotes" rows="4" placeholder="Optional notes about this release">${escapeHtml(notesVal)}</textarea></label>`;
    saveButton.hidden = false;
    dialog.showModal();
  }

  // --- Custom Release Statements (flat grid) ---
  async function loadCustomReleaseStatements() {
    updateAddButtonLabel();
    const release = sourceStatementState.release;
    await loadSourceStructureNodes();
    await loadCustomStatementClassificationOptions();
    const cols = customStatementFlatColumns;
    setGridLevel("statements");
    if (tableHead) tableHead.innerHTML = `<tr>${cols.map(c => `<th>${escapeHtml(c)}</th>`).join("")}</tr>`;
    rows.innerHTML = `<tr><td colspan="${cols.length}" class="pm-empty">Loading source statements...</td></tr>`;
    try {
      const result = await fetchJson(`${api}/custom-release-statements/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          search: search?.value || "",
          data: { organizationId: Number(release.organizationId), subscriptionId: Number(release.subscriptionId), pageNumber: 1, pageSize: 2000 }
        })
      });
      sourceStatementState.rows = apiData(result);
      renderCustomStatementGrid();
    } catch (error) {
      state.records = [];
      rows.innerHTML = `${customStatementBreadcrumbRow()}<tr><td colspan="${cols.length}" class="pm-empty">${escapeHtml(error.message || "Unable to load source statements.")}</td></tr>`;
    }
    renderPager();
  }

  function customStatementBreadcrumbRow() {
    return "";
  }

  function renderCustomStatementGrid() {
    const cols = customStatementFlatColumns;
    const statusFilter = (status?.value || "").trim().toLowerCase();
    let stmts = sourceStatementState.rows || [];
    if (statusFilter) {
      stmts = stmts.filter(s => String(valueOf(s, "ApplicabilityStatus") || "Not Updated").toLowerCase() === statusFilter);
    }
    state.records = stmts;
    closeActionMenu();
    const htmlRows = stmts.map((s, i) => {
      const hierarchy = escapeHtml(valueOf(s, "Hierarchy") || valueOf(s, "StatementTitle") || "");
      const structNode = valueOf(s, "StructureNodeReference") ? `${escapeHtml(valueOf(s, "StructureNodeReference"))} - ${escapeHtml(valueOf(s, "StructureNodeTitle"))}` : escapeHtml(valueOf(s, "StructureNodeTitle") || "");
      return `<tr>
        <td title="${hierarchy}">${hierarchy}</td>
        <td>${structNode}</td>
        <td>${escapeHtml(valueOf(s, "StatementReference"))}</td>
        <td>${escapeHtml(valueOf(s, "StatementTitle"))}</td>
        <td>${formatCell(valueOf(s, "ApplicabilityStatus") || "Not Updated")}</td>
        <td>${escapeHtml(valueOf(s, "PracticeCount") || 0)}</td>
        <td>${actions(i)}</td>
      </tr>`;
    });
    rows.innerHTML = customStatementBreadcrumbRow() + (htmlRows.length
      ? htmlRows.join("")
      : `<tr><td colspan="${cols.length}" class="pm-empty">No control statements found for this custom release. Click "Add Control Statement" to create one.</td></tr>`);
  }

  // Statement Classification options for the Add Control Statement form's
  // Statement Classification picker (change request 2026-09-22, part 2;
  // simplified same day after the user confirmed the shared grac_new.
  // statement_classification master should NOT be shown here at all --
  // the Release dropdown only ever offers Custom Releases, classification
  // is tagged against that release, so organization custom classification
  // for the selected Custom Release is the whole list). Built from
  // customStatementClassificationState.items, which
  // fetchClassificationOptionsForRelease()/loadCustomStatementClassificationOptions()
  // populate against grac_practice.custom_statement_classification only.
  function buildClassificationOptions(selectedTitle) {
    return (customStatementClassificationState.items || [])
      .map(c => {
        const name = valueOf(c, "ClassificationName") || "";
        return `<option value="${escapeHtml(name)}"${String(selectedTitle || "") === name ? " selected" : ""}>${escapeHtml(name)}</option>`;
      }).join("");
  }

  // Statement Classification items (organization's own custom values for
  // this Custom Release -- grac_new.statement_classification is NOT read;
  // see the comment above manageClassificationState) for one Organization +
  // Custom Release, against the custom-statement-classification entity
  // added alongside this feature. Parametrized the same way
  // fetchStructureNodesForRelease is, so the Add Control Statement dialog's
  // cascade can load it for whichever Organization/Release the user just
  // picked.
  async function fetchClassificationOptionsForRelease(organizationId, subscriptionId) {
    if (!organizationId || !subscriptionId) return [];
    try {
      const result = await fetchJson(`${api}/custom-statement-classification/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ data: { organizationId: Number(organizationId), subscriptionId: Number(subscriptionId) } })
      });
      return apiData(result);
    } catch (error) {
      return [];
    }
  }

  // Custom Releases (ReleaseId < 0, same convention as isCustomRelease
  // elsewhere) subscribed by one organization, for the Add Control
  // Statement dialog's Release dropdown. Reuses the exact subscribed-frameworks
  // call the toolbar's own Organization -> Release cascade already makes
  // (loadReleaseSummary) -- no new API, no new data shape.
  async function fetchCustomReleaseOptionsForOrg(organizationId) {
    if (!organizationId) return [];
    try {
      const result = await fetchJson(`${api}/subscribed-frameworks/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ data: { organizationId: Number(organizationId), pageNumber: 1, pageSize: 500 } })
      });
      return apiData(result).filter(r => Number(valueOf(r, "ReleaseId") || 0) < 0);
    } catch (error) {
      return [];
    }
  }

  // Source Structure nodes for one Organization + Release, for the Add
  // Control Statement dialog's cascade. Same call/shape loadSourceStructureNodes
  // already makes off sourceStatementState.release -- parametrized here so
  // the dialog can load nodes for whichever Organization/Release the user
  // just picked, independent of the grid's own drilled-into release.
  async function fetchStructureNodesForRelease(organizationId, subscriptionId) {
    if (!organizationId || !subscriptionId) return [];
    try {
      const result = await fetchJson(`${api}/custom-release-source-structure/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ data: { organizationId: Number(organizationId), subscriptionId: Number(subscriptionId) } })
      });
      return apiData(result);
    } catch (error) {
      return [];
    }
  }

  function openCustomStatementForm(existingRecord = null) {
    const release = sourceStatementState.release;
    const isEdit = !!existingRecord;
    state.mode = isEdit ? "editCustomStatement" : "addCustomStatement";
    state.id = isEdit ? Number(valueOf(existingRecord, "CustomStatementId") || 0) : 0;
    state.formEntity = "custom-statement";
    formMessage.hidden = true;
    document.querySelector("#dialogTitle").textContent = isEdit ? "Edit Control Statement" : "Add Control Statement";
    const classificationOptions = buildClassificationOptions(isEdit ? valueOf(existingRecord, "Classification") : "");
    // Edit keeps Organization/Release fixed to the statement's own release --
    // moving an existing statement to a different release is out of scope
    // (its structure node, id and downstream mappings stay tied to the
    // release it was created under), so this half is unchanged.
    //
    // Add (change request 2026-09): Organization and Release are now real,
    // independently selectable dropdowns instead of read-only text carried
    // over from whichever release the grid happened to be drilled into.
    // Organization reuses the existing organizations lookup via optionsFor
    // -- the same lookup every other Organization picker on this page uses.
    // Release reuses the existing subscribed-frameworks API, filtered to
    // Custom Releases only (Add Control Statement only ever applies to a
    // Custom Release -- this dialog is reachable only when
    // sourceStatementState.isCustomRelease is true). Neither field is
    // pre-selected; wireCustomStatementOrgReleaseCascade() below loads
    // Release once Organization is picked, and Source Structure Node (plus
    // Statement Classification) once Release is picked.
    const orgReleaseMarkup = isEdit
      ? `<input name="organizationId" type="hidden" value="${escapeHtml(release.organizationId)}">
         <input name="subscriptionId" type="hidden" value="${escapeHtml(release.subscriptionId)}">
         <label class="pm-field"><span>Organization</span><input value="${escapeHtml(release.organizationName)}" disabled></label>
         <label class="pm-field"><span>Release</span><input value="${escapeHtml(release.releaseVersion)}" disabled></label>`
      : `<label class="pm-field"><span>Organization<span class="required"> *</span></span><select name="organizationId" id="customStatementOrgSelect" required>${optionsFor("organizations", "")}</select></label>
         <label class="pm-field"><span>Release<span class="required"> *</span></span><select name="subscriptionId" id="customStatementReleaseSelect" required disabled><option value="">— Select organization first —</option></select></label>`;
    // Manage buttons (change request 2026-09-22): beside Source Structure
    // Node and beside Statement Classification, both in Add and Edit mode.
    // Part 2 (same day): these are two SEPARATE popups over two separate
    // tables -- Statement Classification is its own data (grac_practice.
    // custom_statement_classification, the organization's own values for
    // this Custom Release only; grac_new.statement_classification is not
    // read), not derived from Source Structure nodes. See
    // wireCustomStatementManageButtons.
    fieldsHost.innerHTML = `
      ${orgReleaseMarkup}
      ${isEdit ? `<input name="customStatementId" type="hidden" value="${escapeHtml(valueOf(existingRecord, "CustomStatementId"))}">` : ""}
      <label class="pm-field"><span>Source Structure Node<span class="required"> *</span></span>
        <div class="pm-field-with-action">
          <select name="structureNodeId" id="customStatementStructureSelect" required${isEdit ? "" : " disabled"}><option value="">${isEdit ? "— Select structure node —" : "— Select release first —"}</option>${isEdit ? buildStructureNodeOptions(valueOf(existingRecord, "StructureNodeId")) : ""}</select>
          <button type="button" class="pm-button small" id="customStatementManageStructureBtn"${isEdit ? "" : " disabled"}>Manage</button>
        </div>
      </label>
      <label class="pm-field"><span>Statement Reference</span><input name="statementReference" value="${escapeHtml(isEdit ? valueOf(existingRecord, "StatementReference") : "")}" placeholder="e.g. CS-001"></label>
      <label class="pm-field"><span>Statement Title<span class="required"> *</span></span><input name="statementTitle" required value="${escapeHtml(isEdit ? valueOf(existingRecord, "StatementTitle") : "")}" placeholder="Title of the source statement"></label>
      <!-- Applicability Status (change request 2026-09-22, part 3): editable
           here directly, instead of only shown read-only in View. Add mode
           defaults to "Applicable" -- the user can change it before saving;
           Edit mode shows/lets changing whatever the statement's current
           status is. Reuses the same "applicability-status" lookup and
           status-name-or-code resolution SaveCustomStatementAsync now does,
           matching how control-applicability/practices already work. -->
      <label class="pm-field"><span>Applicability Status</span><select name="applicabilityStatus">${optionsFor("applicability-status", isEdit ? (valueOf(existingRecord, "ApplicabilityStatus") || "Applicable") : "Applicable")}</select></label>
      <label class="pm-field full"><span>Statement Text</span><textarea name="statementText" rows="4" placeholder="Full text of the source statement">${escapeHtml(isEdit ? valueOf(existingRecord, "StatementText") : "")}</textarea></label>
      <label class="pm-field"><span>Statement Classification</span>
        <div class="pm-field-with-action">
          <select name="classification" id="customStatementClassificationSelect"${isEdit ? "" : " disabled"}><option value="">${isEdit ? "— Select classification —" : "— Select release first —"}</option>${isEdit ? classificationOptions : ""}</select>
          <button type="button" class="pm-button small" id="customStatementManageClassificationBtn"${isEdit ? "" : " disabled"}>Manage</button>
        </div>
      </label>
      <label class="pm-field"><span>Keywords</span><input name="keywords" value="${escapeHtml(isEdit ? valueOf(existingRecord, "Keywords") : "")}" placeholder="Comma-separated keywords"></label>`;
    if (!isEdit) wireCustomStatementOrgReleaseCascade();
    wireCustomStatementManageButtons(isEdit, release);
    saveButton.hidden = false;
    dialog.showModal();
  }

  // Reads whichever Organization/Release the Add Control Statement dialog
  // is currently scoped to -- the fixed release object in Edit mode, or
  // whatever the user has picked so far in the Add-mode cascade selects.
  function currentCustomStatementOrgSub(isEdit, release) {
    if (isEdit) return { organizationId: Number(release?.organizationId) || 0, subscriptionId: Number(release?.subscriptionId) || 0 };
    const organizationId = Number(fieldsHost.querySelector("#customStatementOrgSelect")?.value) || 0;
    const subscriptionId = Number(fieldsHost.querySelector("#customStatementReleaseSelect")?.value) || 0;
    return { organizationId, subscriptionId };
  }

  // Reloads Source Structure nodes for one Organization + Release and
  // repopulates both the Source Structure Node and Statement Classification
  // selects on the (still open, underneath) Add Control Statement dialog --
  // preserving each select's current value where it still exists after the
  // reload. Called after the Manage Source Structure popup closes, and
  // reused by the Add-mode cascade's Release change handler.
  async function refreshCustomStatementStructureAndClassification(organizationId, subscriptionId) {
    const structureSelect = fieldsHost.querySelector("#customStatementStructureSelect");
    const classificationSelect = fieldsHost.querySelector("#customStatementClassificationSelect");
    if (!structureSelect || !classificationSelect || !organizationId || !subscriptionId) return;
    const previousStructureValue = structureSelect.value;
    const previousClassificationValue = classificationSelect.value;
    structureSelect.disabled = true;
    classificationSelect.disabled = true;
    sourceStructureState.nodes = await fetchStructureNodesForRelease(organizationId, subscriptionId);
    customStatementClassificationState.items = await fetchClassificationOptionsForRelease(organizationId, subscriptionId);
    structureSelect.innerHTML = `<option value="">— Select structure node —</option>${buildStructureNodeOptions(previousStructureValue)}`;
    structureSelect.disabled = false;
    classificationSelect.innerHTML = `<option value="">— Select classification —</option>${buildClassificationOptions(previousClassificationValue)}`;
    classificationSelect.disabled = false;
  }

  // Wires the two "Manage" buttons beside Source Structure Node / Statement
  // Classification in openCustomStatementForm. Re-reads the current
  // Organization/Release at click time (not just once at dialog-open),
  // since in Add mode the user may change Organization/Release after the
  // dialog first renders.
  //
  // (change request 2026-09-22, part 2) These open TWO DIFFERENT popups --
  // Statement Classification is a separate table from Source Structure
  // (see customStatementClassificationState / manageClassificationState),
  // corrected after the user pointed out both buttons were opening the
  // same Manage Source Structure popup.
  function wireCustomStatementManageButtons(isEdit, release) {
    const structureBtn = fieldsHost.querySelector("#customStatementManageStructureBtn");
    const classificationBtn = fieldsHost.querySelector("#customStatementManageClassificationBtn");
    structureBtn?.addEventListener("click", () => {
      const { organizationId, subscriptionId } = currentCustomStatementOrgSub(isEdit, release);
      if (!organizationId || !subscriptionId) return;
      openManageStructureDialog(organizationId, subscriptionId, "Manage Source Structure",
        () => refreshCustomStatementStructureAndClassification(organizationId, subscriptionId));
    });
    classificationBtn?.addEventListener("click", () => {
      const { organizationId, subscriptionId } = currentCustomStatementOrgSub(isEdit, release);
      if (!organizationId || !subscriptionId) return;
      openManageClassificationDialog(organizationId, subscriptionId, "Manage Statement Classification",
        () => refreshCustomStatementStructureAndClassification(organizationId, subscriptionId));
    });
  }

  // Add-mode Organization -> Release -> (Source Structure Node + Statement
  // Classification) cascade for openCustomStatementForm(). Kept separate so
  // the markup above stays declarative; this only attaches behaviour, the
  // same split the generic field-descriptor cascade (parentField / data-parent-field)
  // uses elsewhere on this page.
  function wireCustomStatementOrgReleaseCascade() {
    const orgSelect = fieldsHost.querySelector("#customStatementOrgSelect");
    const releaseSelect = fieldsHost.querySelector("#customStatementReleaseSelect");
    const structureSelect = fieldsHost.querySelector("#customStatementStructureSelect");
    const classificationSelect = fieldsHost.querySelector("#customStatementClassificationSelect");
    const structureManageBtn = fieldsHost.querySelector("#customStatementManageStructureBtn");
    const classificationManageBtn = fieldsHost.querySelector("#customStatementManageClassificationBtn");
    if (!orgSelect || !releaseSelect || !structureSelect || !classificationSelect) return;

    function resetRelease(placeholder) {
      releaseSelect.innerHTML = `<option value="">${placeholder}</option>`;
      releaseSelect.disabled = true;
    }
    function resetDownstream(placeholder) {
      structureSelect.innerHTML = `<option value="">${placeholder}</option>`;
      structureSelect.disabled = true;
      classificationSelect.innerHTML = `<option value="">${placeholder}</option>`;
      classificationSelect.disabled = true;
      if (structureManageBtn) structureManageBtn.disabled = true;
      if (classificationManageBtn) classificationManageBtn.disabled = true;
    }

    orgSelect.addEventListener("change", async () => {
      resetDownstream("— Select release first —");
      const organizationId = orgSelect.value;
      if (!organizationId) { resetRelease("— Select organization first —"); return; }
      resetRelease("Loading releases...");
      const releaseRows = await fetchCustomReleaseOptionsForOrg(organizationId);
      if (!releaseRows.length) { resetRelease("— No custom releases for this organization —"); return; }
      releaseSelect.innerHTML = `<option value="">— Select release —</option>${releaseRows.map(r =>
        `<option value="${escapeHtml(valueOf(r, "SubscriptionId"))}">${escapeHtml(valueOf(r, "ReleaseVersion") || valueOf(r, "FrameworkRelease"))}</option>`).join("")}`;
      releaseSelect.disabled = false;
    });

    releaseSelect.addEventListener("change", async () => {
      const organizationId = orgSelect.value;
      const subscriptionId = releaseSelect.value;
      if (!organizationId || !subscriptionId) { resetDownstream("— Select release first —"); return; }
      structureSelect.innerHTML = `<option value="">Loading...</option>`;
      structureSelect.disabled = true;
      classificationSelect.innerHTML = `<option value="">Loading...</option>`;
      classificationSelect.disabled = true;
      sourceStructureState.nodes = await fetchStructureNodesForRelease(organizationId, subscriptionId);
      customStatementClassificationState.items = await fetchClassificationOptionsForRelease(organizationId, subscriptionId);
      structureSelect.innerHTML = `<option value="">— Select structure node —</option>${buildStructureNodeOptions("")}`;
      structureSelect.disabled = false;
      classificationSelect.innerHTML = `<option value="">— Select classification —</option>${buildClassificationOptions("")}`;
      classificationSelect.disabled = false;
      // The user can still Manage/add nodes even when this release has
      // none yet (e.g. a brand-new Custom Release) -- that IS how the
      // first node gets created, so the buttons enable regardless of
      // whether sourceStructureState.nodes came back empty.
      if (structureManageBtn) structureManageBtn.disabled = false;
      if (classificationManageBtn) classificationManageBtn.disabled = false;
    });
  }

  function openCustomStatementView(record) {
    state.mode = "view";
    state.formEntity = "custom-statement";
    formMessage.hidden = true;
    document.querySelector("#dialogTitle").textContent = "View Control Statement";
    fieldsHost.innerHTML = `
      <label class="pm-field"><span>Hierarchy</span><input value="${escapeHtml(valueOf(record, "Hierarchy"))}" disabled></label>
      <label class="pm-field"><span>Source Structure Node</span><input value="${escapeHtml(valueOf(record, "StructureNodeReference") ? valueOf(record, "StructureNodeReference") + " - " + valueOf(record, "StructureNodeTitle") : valueOf(record, "StructureNodeTitle") || "")}" disabled></label>
      <label class="pm-field"><span>Statement Reference</span><input value="${escapeHtml(valueOf(record, "StatementReference"))}" disabled></label>
      <label class="pm-field"><span>Statement Title</span><input value="${escapeHtml(valueOf(record, "StatementTitle"))}" disabled></label>
      <label class="pm-field full"><span>Statement Text</span><textarea rows="5" disabled>${escapeHtml(valueOf(record, "StatementText"))}</textarea></label>
      <label class="pm-field"><span>Statement Classification</span><input value="${escapeHtml(valueOf(record, "Classification"))}" disabled></label>
      <label class="pm-field"><span>Keywords</span><input value="${escapeHtml(valueOf(record, "Keywords"))}" disabled></label>
      <label class="pm-field"><span>Applicability Status</span><input value="${escapeHtml(valueOf(record, "ApplicabilityStatus") || "Not Updated")}" disabled></label>`;
    saveButton.hidden = true;
    dialog.showModal();
  }

  async function inactivateCustomStatement(record) {
    const id = valueOf(record, "CustomStatementId");
    if (!id) return;
    if (!await window.gracUi.confirm("Mark this source statement as inactive?",
          { type: "warning", title: "Mark inactive", confirmText: "Mark inactive" })) return;
    try {
      await fetchJson(`${api}/custom-statement`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          id: 0,
          data: {
            organizationId: Number(sourceStatementState.release?.organizationId || organizationFilter?.value || 0),
            subscriptionId: Number(sourceStatementState.release?.subscriptionId || 0),
            customStatementId: Number(id),
            statementTitle: valueOf(record, "StatementTitle") || "placeholder",
            statementAction: "INACTIVATE"
          }
        })
      });
      await loadCustomReleaseStatements();
    } catch (error) {
      alert(error.message || "Unable to inactivate statement.");
    }
  }

  // --- Custom Release Source Structure Management ---
  async function loadSourceStructureNodes() {
    const release = sourceStatementState.release;
    if (!release || !sourceStatementState.isCustomRelease) { sourceStructureState.nodes = []; return; }
    try {
      const result = await fetchJson(`${api}/custom-release-source-structure/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          data: { organizationId: Number(release.organizationId), subscriptionId: Number(release.subscriptionId) }
        })
      });
      sourceStructureState.nodes = apiData(result);
    } catch (error) {
      sourceStructureState.nodes = [];
    }
  }

  // Statement Classification counterpart to loadSourceStructureNodes()
  // above (change request 2026-09-22, part 2) -- called alongside it so
  // Edit mode (which needs customStatementClassificationState.items ready
  // synchronously at dialog-open time, same as sourceStructureState.nodes)
  // has the classification list available the moment the grid for a
  // Custom Release loads, before any row's Edit is even clicked.
  async function loadCustomStatementClassificationOptions() {
    const release = sourceStatementState.release;
    if (!release || !sourceStatementState.isCustomRelease) { customStatementClassificationState.items = []; return; }
    customStatementClassificationState.items = await fetchClassificationOptionsForRelease(
      Number(release.organizationId), Number(release.subscriptionId));
  }

  function buildStructureNodeOptions(selectedId, excludeId) {
    const nodes = sourceStructureState.nodes || [];
    return nodes
      .filter(n => !excludeId || String(valueOf(n, "StructureNodeId")) !== String(excludeId))
      .map(n => {
        const id = valueOf(n, "StructureNodeId");
        const label = `${valueOf(n, "NodeReference") ? valueOf(n, "NodeReference") + " - " : ""}${valueOf(n, "NodeTitle")}`;
        const indent = "  ".repeat(Math.max(0, (Number(valueOf(n, "NodeLevel")) || 1) - 1));
        return `<option value="${escapeHtml(id)}"${String(selectedId) === String(id) ? " selected" : ""}>${indent}${escapeHtml(label)}</option>`;
      }).join("");
  }

  function openSourceStructurePanel() {
    const release = sourceStatementState.release;
    if (!release) return;
    sourceStructureState.active = true;
    state.mode = "sourceStructure";
    state.formEntity = "custom-release-source-structure";
    formMessage.hidden = true;
    document.querySelector("#dialogTitle").textContent = `Source Structure — ${release.releaseVersion || release.title}`;
    renderSourceStructureDialog();
    saveButton.hidden = true;
    dialog.showModal();
  }

  function renderSourceStructureDialog() {
    const release = sourceStatementState.release;
    const nodes = sourceStructureState.nodes || [];
    const nodeRows = nodes.map((n, i) => {
      const indent = Number(valueOf(n, "NodeLevel") || 1) - 1;
      const ref = escapeHtml(valueOf(n, "NodeReference") || "");
      const title = escapeHtml(valueOf(n, "NodeTitle") || "");
      const desc = escapeHtml(String(valueOf(n, "Description") || "").substring(0, 60));
      const count = escapeHtml(valueOf(n, "StatementCount") || 0);
      return `<tr>
        <td>${"    ".repeat(indent)}${ref ? ref + " - " : ""}${title}</td>
        <td>${escapeHtml(valueOf(n, "NodeLevel") || 1)}</td>
        <td>${count}</td>
        <td>
          <button type="button" class="pm-button small" data-structure-edit="${i}" title="Edit"><i class="fa-solid fa-pen" aria-hidden="true"></i></button>
          <button type="button" class="pm-button small" data-structure-add-child="${i}" title="Add Child"><i class="fa-solid fa-plus" aria-hidden="true"></i></button>
          <button type="button" class="pm-button small" data-structure-inactivate="${i}" title="Inactivate"><i class="fa-solid fa-ban" aria-hidden="true"></i></button>
        </td>
      </tr>`;
    });
    fieldsHost.innerHTML = `
      <div class="pm-source-structure-panel" style="width:100%">
        <div style="margin-bottom:12px;display:flex;gap:8px;align-items:center">
          <button type="button" class="pm-button primary small" id="addRootNodeBtn"><i class="fa-solid fa-plus" aria-hidden="true"></i> Add Root Node</button>
          <span style="color:var(--pm-text-secondary);font-size:0.85rem">${nodes.length} node(s)</span>
        </div>
        <div class="pm-table-wrap compact" style="max-height:400px;overflow-y:auto">
          <table>
            <thead><tr><th>Node</th><th>Level</th><th>Statements</th><th>Actions</th></tr></thead>
            <tbody>${nodeRows.length ? nodeRows.join("") : '<tr><td colspan="4" class="pm-empty">No source structure nodes defined. Click "Add Root Node" to create one.</td></tr>'}</tbody>
          </table>
        </div>
      </div>`;
    // Attach events
    fieldsHost.querySelector("#addRootNodeBtn")?.addEventListener("click", () => openSourceStructureNodeForm(null, null));
    fieldsHost.querySelectorAll("[data-structure-edit]").forEach(btn => {
      btn.addEventListener("click", () => {
        const node = nodes[Number(btn.dataset.structureEdit)];
        if (node) openSourceStructureNodeForm(node, null);
      });
    });
    fieldsHost.querySelectorAll("[data-structure-add-child]").forEach(btn => {
      btn.addEventListener("click", () => {
        const parent = nodes[Number(btn.dataset.structureAddChild)];
        if (parent) openSourceStructureNodeForm(null, parent);
      });
    });
    fieldsHost.querySelectorAll("[data-structure-inactivate]").forEach(btn => {
      btn.addEventListener("click", () => {
        const node = nodes[Number(btn.dataset.structureInactivate)];
        if (node) inactivateSourceStructureNode(node);
      });
    });
  }

  function openSourceStructureNodeForm(existingNode, parentNode) {
    const release = sourceStatementState.release;
    const isEdit = !!existingNode;
    const parentId = parentNode ? valueOf(parentNode, "StructureNodeId") : (isEdit ? valueOf(existingNode, "ParentNodeId") : null);
    const parentLabel = parentNode
      ? `${valueOf(parentNode, "NodeReference") ? valueOf(parentNode, "NodeReference") + " - " : ""}${valueOf(parentNode, "NodeTitle")}`
      : isEdit && parentId
        ? (() => { const p = sourceStructureState.nodes.find(n => String(valueOf(n, "StructureNodeId")) === String(parentId)); return p ? `${valueOf(p, "NodeReference") ? valueOf(p, "NodeReference") + " - " : ""}${valueOf(p, "NodeTitle")}` : ""; })()
        : "";

    // Build a mini-dialog inside the existing dialog
    state.mode = isEdit ? "editSourceStructureNode" : "addSourceStructureNode";
    state.id = isEdit ? Number(valueOf(existingNode, "StructureNodeId") || 0) : 0;
    state.formEntity = "custom-release-source-structure";
    formMessage.hidden = true;
    document.querySelector("#dialogTitle").textContent = isEdit ? "Edit Source Structure Node" : (parentNode ? "Add Child Node" : "Add Root Node");

    const parentOptions = buildStructureNodeOptions(parentId, isEdit ? valueOf(existingNode, "StructureNodeId") : null);
    fieldsHost.innerHTML = `
      <input name="organizationId" type="hidden" value="${escapeHtml(release.organizationId)}">
      <input name="subscriptionId" type="hidden" value="${escapeHtml(release.subscriptionId)}">
      ${isEdit ? `<input name="structureNodeId" type="hidden" value="${escapeHtml(valueOf(existingNode, "StructureNodeId"))}">` : ""}
      <label class="pm-field"><span>Release</span><input value="${escapeHtml(release.releaseVersion || release.title)}" disabled></label>
      <label class="pm-field"><span>Parent Node</span><select name="parentNodeId"><option value="">— Root level (no parent) —</option>${parentOptions}</select></label>
      <label class="pm-field"><span>Node Reference</span><input name="nodeReference" value="${escapeHtml(isEdit ? valueOf(existingNode, "NodeReference") : "")}" placeholder="e.g. SS-001"></label>
      <label class="pm-field"><span>Node Title<span class="required"> *</span></span><input name="nodeTitle" required value="${escapeHtml(isEdit ? valueOf(existingNode, "NodeTitle") : "")}" placeholder="Title of the source structure node"></label>
      <label class="pm-field full"><span>Description</span><textarea name="description" rows="3" placeholder="Optional description">${escapeHtml(isEdit ? valueOf(existingNode, "Description") : "")}</textarea></label>`;
    saveButton.hidden = false;
    if (!dialog.open) dialog.showModal();
  }

  async function inactivateSourceStructureNode(node) {
    const id = valueOf(node, "StructureNodeId");
    if (!id) return;
    const count = Number(valueOf(node, "StatementCount") || 0);
    const msg = count > 0
      ? `This node has ${count} statement(s) mapped to it. Inactivating will unlink them. Continue?`
      : "Mark this source structure node as inactive?";
    if (!await window.gracUi.confirm(msg,
          { type: "warning", title: "Mark inactive", confirmText: "Mark inactive" })) return;
    try {
      await fetchJson(`${api}/custom-release-source-structure`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          id: 0,
          data: {
            organizationId: Number(sourceStatementState.release?.organizationId || 0),
            subscriptionId: Number(sourceStatementState.release?.subscriptionId || 0),
            structureNodeId: Number(id),
            nodeTitle: valueOf(node, "NodeTitle") || "placeholder",
            nodeAction: "INACTIVATE"
          }
        })
      });
      await loadSourceStructureNodes();
      renderSourceStructureDialog();
    } catch (error) {
      alert(error.message || "Unable to inactivate node.");
    }
  }


  // --- Manage Source Structure / Statement Classification popup ----------
  // (change request 2026-09-22) A separate, self-contained popup -- its own
  // state, its own fetch calls against the existing custom-release-source-
  // structure query/save entity -- deliberately NOT sharing dialog/fieldsHost/
  // saveButton/state.mode with the rest of this file, because it needs to
  // open ON TOP OF an already-open Add/Edit Control Statement dialog without
  // disturbing it (see the markup comment on #manageStructureDialog in
  // Manage.cshtml). Both the "Manage" button beside Source Structure Node
  // and the one beside Statement Classification in openCustomStatementForm
  // open this same popup -- Statement Classification IS the Level-1 Source
  // Structure nodes (buildClassificationOptions), so there is only one list
  // to manage, shown to the user two ways.
  const manageStructureState = { organizationId: 0, subscriptionId: 0, nodes: [], onClose: null };

  function manageStructureSetMessage(text, kind) {
    if (!manageStructureMessage) return;
    if (!text) { manageStructureMessage.hidden = true; manageStructureMessage.textContent = ""; return; }
    manageStructureMessage.hidden = false;
    manageStructureMessage.textContent = text;
    manageStructureMessage.className = `pm-message${kind ? ` ${kind}` : ""}`;
  }

  async function loadManageStructureNodes() {
    try {
      const result = await fetchJson(`${api}/custom-release-source-structure/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ data: { organizationId: manageStructureState.organizationId, subscriptionId: manageStructureState.subscriptionId } })
      });
      manageStructureState.nodes = apiData(result);
    } catch (error) {
      manageStructureState.nodes = [];
      manageStructureSetMessage(error.message || "Unable to load source structure nodes.");
    }
  }

  function openManageStructureDialog(organizationId, subscriptionId, title, onClose) {
    manageStructureState.organizationId = Number(organizationId) || 0;
    manageStructureState.subscriptionId = Number(subscriptionId) || 0;
    manageStructureState.onClose = typeof onClose === "function" ? onClose : null;
    const titleEl = document.querySelector("#manageStructureDialogTitle");
    if (titleEl) titleEl.textContent = title || "Manage Source Structure";
    manageStructureSetMessage("");
    manageStructureBody.innerHTML = `<p class="pm-empty" style="grid-column:1/-1">Loading...</p>`;
    if (!manageStructureDialog.open) manageStructureDialog.showModal();
    loadManageStructureNodes().then(renderManageStructureList);
  }

  function renderManageStructureList() {
    const nodes = manageStructureState.nodes || [];
    const nodeRows = nodes.map((n, i) => {
      const indent = Number(valueOf(n, "NodeLevel") || 1) - 1;
      const ref = escapeHtml(valueOf(n, "NodeReference") || "");
      const title = escapeHtml(valueOf(n, "NodeTitle") || "");
      const count = escapeHtml(valueOf(n, "StatementCount") || 0);
      return `<tr>
        <td>${"    ".repeat(indent)}${ref ? ref + " - " : ""}${title}</td>
        <td>${escapeHtml(valueOf(n, "NodeLevel") || 1)}</td>
        <td>${count}</td>
        <td>
          <button type="button" class="pm-button small" data-manage-structure-edit="${i}" title="Edit"><i class="fa-solid fa-pen" aria-hidden="true"></i></button>
          <button type="button" class="pm-button small" data-manage-structure-add-child="${i}" title="Add Child"><i class="fa-solid fa-plus" aria-hidden="true"></i></button>
          <button type="button" class="pm-button small" data-manage-structure-inactivate="${i}" title="Inactivate"><i class="fa-solid fa-ban" aria-hidden="true"></i></button>
        </td>
      </tr>`;
    });
    manageStructureSetMessage("");
    // grid-column:1/-1 -- #manageStructureBody keeps the shared .pm-form-grid
    // two-column layout (so the Add/Edit Node sub-form below lines up like
    // every other entity form), but the list view is table content, not
    // form fields, so it needs to span both columns to use the dialog's
    // full width instead of collapsing into a single half-width grid cell
    // (change request 2026-09-22 -- this popup looked cramped/narrow before).
    manageStructureBody.innerHTML = `
      <div class="pm-source-structure-panel" style="grid-column:1/-1;width:100%">
        <div style="margin-bottom:14px;display:flex;gap:10px;align-items:center">
          <button type="button" class="pm-button primary small" id="manageStructureAddRootBtn"><i class="fa-solid fa-plus" aria-hidden="true"></i> Add Root Node</button>
          <span style="color:var(--pm-text-secondary);font-size:0.85rem">${nodes.length} node(s)</span>
        </div>
        <div class="pm-table-wrap compact" style="max-height:min(55vh,520px);min-height:220px;overflow-y:auto">
          <table>
            <thead><tr><th>Node</th><th>Level</th><th>Statements</th><th>Actions</th></tr></thead>
            <tbody>${nodeRows.length ? nodeRows.join("") : '<tr><td colspan="4" class="pm-empty">No source structure nodes defined. Click "Add Root Node" to create one.</td></tr>'}</tbody>
          </table>
        </div>
      </div>`;
    manageStructureBody.querySelector("#manageStructureAddRootBtn")?.addEventListener("click", () => renderManageStructureNodeForm(null, null));
    manageStructureBody.querySelectorAll("[data-manage-structure-edit]").forEach(btn => {
      btn.addEventListener("click", () => {
        const node = nodes[Number(btn.dataset.manageStructureEdit)];
        if (node) renderManageStructureNodeForm(node, null);
      });
    });
    manageStructureBody.querySelectorAll("[data-manage-structure-add-child]").forEach(btn => {
      btn.addEventListener("click", () => {
        const parent = nodes[Number(btn.dataset.manageStructureAddChild)];
        if (parent) renderManageStructureNodeForm(null, parent);
      });
    });
    manageStructureBody.querySelectorAll("[data-manage-structure-inactivate]").forEach(btn => {
      btn.addEventListener("click", () => {
        const node = nodes[Number(btn.dataset.manageStructureInactivate)];
        if (node) inactivateManageStructureNode(node);
      });
    });
  }

  function renderManageStructureNodeForm(existingNode, parentNode) {
    const isEdit = !!existingNode;
    const parentId = parentNode ? valueOf(parentNode, "StructureNodeId") : (isEdit ? valueOf(existingNode, "ParentNodeId") : null);
    const nodes = manageStructureState.nodes || [];
    const parentOptions = nodes
      .filter(n => !isEdit || String(valueOf(n, "StructureNodeId")) !== String(valueOf(existingNode, "StructureNodeId")))
      .map(n => {
        const id = valueOf(n, "StructureNodeId");
        const label = `${valueOf(n, "NodeReference") ? valueOf(n, "NodeReference") + " - " : ""}${valueOf(n, "NodeTitle")}`;
        const indent = "  ".repeat(Math.max(0, (Number(valueOf(n, "NodeLevel")) || 1) - 1));
        return `<option value="${escapeHtml(id)}"${String(parentId) === String(id) ? " selected" : ""}>${indent}${escapeHtml(label)}</option>`;
      }).join("");
    manageStructureSetMessage("");
    manageStructureBody.innerHTML = `
      <label class="pm-field"><span>Parent Node</span><select id="manageStructureParent"><option value="">— Root level (no parent) —</option>${parentOptions}</select></label>
      <label class="pm-field"><span>Node Reference</span><input id="manageStructureRef" value="${escapeHtml(isEdit ? valueOf(existingNode, "NodeReference") : "")}" placeholder="e.g. SS-001"></label>
      <label class="pm-field"><span>Node Title<span class="required"> *</span></span><input id="manageStructureTitle" required value="${escapeHtml(isEdit ? valueOf(existingNode, "NodeTitle") : "")}" placeholder="Title of the source structure node"></label>
      <label class="pm-field full"><span>Description</span><textarea id="manageStructureDesc" rows="3" placeholder="Optional description">${escapeHtml(isEdit ? valueOf(existingNode, "Description") : "")}</textarea></label>
      <div class="pm-dialog-actions" style="grid-column:1/-1">
        <button type="button" class="pm-button" id="manageStructureFormCancel">Cancel / Back</button>
        <button type="button" class="pm-button primary" id="manageStructureFormSave">${isEdit ? "Save Changes" : "Add Node"}</button>
      </div>`;
    manageStructureBody.querySelector("#manageStructureFormCancel")?.addEventListener("click", renderManageStructureList);
    manageStructureBody.querySelector("#manageStructureFormSave")?.addEventListener("click", () => saveManageStructureNode(isEdit ? existingNode : null));
  }

  async function saveManageStructureNode(existingNode) {
    const titleInput = manageStructureBody.querySelector("#manageStructureTitle");
    const title = (titleInput?.value || "").trim();
    if (!title) { titleInput?.classList.add("field-error"); manageStructureSetMessage("Node Title is required."); return; }
    const data = {
      organizationId: manageStructureState.organizationId,
      subscriptionId: manageStructureState.subscriptionId,
      parentNodeId: manageStructureBody.querySelector("#manageStructureParent")?.value || null,
      nodeReference: manageStructureBody.querySelector("#manageStructureRef")?.value || "",
      nodeTitle: title,
      description: manageStructureBody.querySelector("#manageStructureDesc")?.value || "",
      nodeAction: "ADD"
    };
    if (existingNode) data.structureNodeId = Number(valueOf(existingNode, "StructureNodeId"));
    try {
      await fetchJson(`${api}/custom-release-source-structure`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id: 0, data })
      });
      await loadManageStructureNodes();
      renderManageStructureList();
    } catch (error) {
      manageStructureSetMessage(error.message || "Unable to save source structure node.");
    }
  }

  async function inactivateManageStructureNode(node) {
    const id = valueOf(node, "StructureNodeId");
    if (!id) return;
    const count = Number(valueOf(node, "StatementCount") || 0);
    const msg = count > 0
      ? `This node has ${count} statement(s) mapped to it. Inactivating will unlink them. Continue?`
      : "Mark this source structure node as inactive?";
    if (!await window.gracUi.confirm(msg, { type: "warning", title: "Mark inactive", confirmText: "Mark inactive" })) return;
    try {
      await fetchJson(`${api}/custom-release-source-structure`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          id: 0,
          data: {
            organizationId: manageStructureState.organizationId,
            subscriptionId: manageStructureState.subscriptionId,
            structureNodeId: Number(id),
            nodeTitle: valueOf(node, "NodeTitle") || "placeholder",
            nodeAction: "INACTIVATE"
          }
        })
      });
      await loadManageStructureNodes();
      renderManageStructureList();
    } catch (error) {
      manageStructureSetMessage(error.message || "Unable to inactivate node.");
    }
  }

  // Close wiring, once. The native <dialog> "close" event fires no matter
  // how the dialog was dismissed (X button below, Esc key, or a future
  // .close() call), so this is the single place the Add Control Statement
  // dialog's Source Structure Node / Statement Classification combos get
  // refreshed -- satisfies "when the popup closes, refresh the combo"
  // regardless of how the popup was dismissed.
  closeManageStructureBtn?.addEventListener("click", () => manageStructureDialog?.close());
  manageStructureDialog?.addEventListener("close", () => {
    const onClose = manageStructureState.onClose;
    manageStructureState.onClose = null;
    if (typeof onClose === "function") onClose();
  });

  // --- Manage Statement Classification popup ------------------------------
  // (change request 2026-09-22, part 2) A SEPARATE, self-contained popup
  // from Manage Source Structure above -- the user pointed out that both
  // "Manage" buttons were opening the Source Structure popup, and that
  // Statement Classification is a completely different table, tagged
  // against RELEASE. Since the Release dropdown on the Add Control
  // Statement form only ever offers Custom Releases, "against release"
  // here means against the Custom Release (subscription_id). The shared
  // Control Management master (grac_new.statement_classification, tagged
  // per REAL framework release) does NOT apply to Custom Releases and is
  // deliberately NOT read or shown here (confirmed with the user
  // 2026-09-22) -- every row in this popup is the organization's own
  // custom classification for the selected Custom Release, saved into
  // grac_practice.custom_statement_classification, scoped to
  // (organization_id, subscription_id) so one organization's custom
  // classification never leaks to another organization, nor to that same
  // organization's other Custom Releases.
  const manageClassificationState = { organizationId: 0, subscriptionId: 0, items: [], onClose: null };

  function manageClassificationSetMessage(text, kind) {
    if (!manageClassificationMessage) return;
    if (!text) { manageClassificationMessage.hidden = true; manageClassificationMessage.textContent = ""; return; }
    manageClassificationMessage.hidden = false;
    manageClassificationMessage.textContent = text;
    manageClassificationMessage.className = `pm-message${kind ? ` ${kind}` : ""}`;
  }

  async function loadManageClassificationItems() {
    try {
      manageClassificationState.items = await fetchClassificationOptionsForRelease(
        manageClassificationState.organizationId, manageClassificationState.subscriptionId);
    } catch (error) {
      manageClassificationState.items = [];
      manageClassificationSetMessage(error.message || "Unable to load statement classifications.");
    }
  }

  function openManageClassificationDialog(organizationId, subscriptionId, title, onClose) {
    manageClassificationState.organizationId = Number(organizationId) || 0;
    manageClassificationState.subscriptionId = Number(subscriptionId) || 0;
    manageClassificationState.onClose = typeof onClose === "function" ? onClose : null;
    const titleEl = document.querySelector("#manageClassificationDialogTitle");
    if (titleEl) titleEl.textContent = title || "Manage Statement Classification";
    manageClassificationSetMessage("");
    manageClassificationBody.innerHTML = `<p class="pm-empty" style="grid-column:1/-1">Loading...</p>`;
    if (!manageClassificationDialog.open) manageClassificationDialog.showModal();
    loadManageClassificationItems().then(renderManageClassificationList);
  }

  function renderManageClassificationList() {
    const items = manageClassificationState.items || [];
    const rows = items.map((c, i) => {
      const name = escapeHtml(valueOf(c, "ClassificationName") || "");
      const scheme = escapeHtml(valueOf(c, "ClassificationScheme") || "");
      return `<tr>
        <td>${name}</td>
        <td>${scheme}</td>
        <td>
          <button type="button" class="pm-button small" data-manage-classification-edit="${i}" title="Edit"><i class="fa-solid fa-pen" aria-hidden="true"></i></button>
          <button type="button" class="pm-button small" data-manage-classification-inactivate="${i}" title="Inactivate"><i class="fa-solid fa-ban" aria-hidden="true"></i></button>
        </td>
      </tr>`;
    });
    manageClassificationSetMessage("");
    // grid-column:1/-1 -- same reason as renderManageStructureList: this
    // popup's body keeps the shared .pm-form-grid two-column layout for the
    // Add/Edit sub-form below, but the list view needs the dialog's full
    // width, not a single half-width grid cell.
    manageClassificationBody.innerHTML = `
      <div class="pm-source-structure-panel" style="grid-column:1/-1;width:100%">
        <div style="margin-bottom:14px;display:flex;gap:10px;align-items:center">
          <button type="button" class="pm-button primary small" id="manageClassificationAddBtn"><i class="fa-solid fa-plus" aria-hidden="true"></i> Add Classification</button>
          <span style="color:var(--pm-text-secondary);font-size:0.85rem">${items.length} classification(s)</span>
        </div>
        <div class="pm-table-wrap compact" style="max-height:min(55vh,520px);min-height:220px;overflow-y:auto">
          <table>
            <thead><tr><th>Classification</th><th>Scheme</th><th>Actions</th></tr></thead>
            <tbody>${rows.length ? rows.join("") : '<tr><td colspan="3" class="pm-empty">No classifications found. Click "Add Classification" to create one for this organization/release.</td></tr>'}</tbody>
          </table>
        </div>
      </div>`;
    manageClassificationBody.querySelector("#manageClassificationAddBtn")?.addEventListener("click", () => renderManageClassificationItemForm(null));
    manageClassificationBody.querySelectorAll("[data-manage-classification-edit]").forEach(btn => {
      btn.addEventListener("click", () => {
        const item = items[Number(btn.dataset.manageClassificationEdit)];
        if (item) renderManageClassificationItemForm(item);
      });
    });
    manageClassificationBody.querySelectorAll("[data-manage-classification-inactivate]").forEach(btn => {
      btn.addEventListener("click", () => {
        const item = items[Number(btn.dataset.manageClassificationInactivate)];
        if (item) inactivateManageClassificationItem(item);
      });
    });
  }

  function renderManageClassificationItemForm(existingItem) {
    const isEdit = !!existingItem;
    manageClassificationSetMessage("");
    manageClassificationBody.innerHTML = `
      <label class="pm-field"><span>Classification Name<span class="required"> *</span></span><input id="manageClassificationName" required value="${escapeHtml(isEdit ? valueOf(existingItem, "ClassificationName") : "")}" placeholder="e.g. Governance"></label>
      <label class="pm-field"><span>Classification Code</span><input id="manageClassificationCode" value="${escapeHtml(isEdit ? valueOf(existingItem, "ClassificationCode") : "")}" placeholder="e.g. GOV"></label>
      <label class="pm-field"><span>Scheme</span><input id="manageClassificationScheme" value="${escapeHtml(isEdit ? valueOf(existingItem, "ClassificationScheme") : "")}" placeholder="Optional grouping/scheme name"></label>
      <label class="pm-field full"><span>Description</span><textarea id="manageClassificationDesc" rows="3" placeholder="Optional description">${escapeHtml(isEdit ? valueOf(existingItem, "Description") : "")}</textarea></label>
      <div class="pm-dialog-actions" style="grid-column:1/-1">
        <button type="button" class="pm-button" id="manageClassificationFormCancel">Cancel / Back</button>
        <button type="button" class="pm-button primary" id="manageClassificationFormSave">${isEdit ? "Save Changes" : "Add Classification"}</button>
      </div>`;
    manageClassificationBody.querySelector("#manageClassificationFormCancel")?.addEventListener("click", renderManageClassificationList);
    manageClassificationBody.querySelector("#manageClassificationFormSave")?.addEventListener("click", () => saveManageClassificationItem(isEdit ? existingItem : null));
  }

  async function saveManageClassificationItem(existingItem) {
    const nameInput = manageClassificationBody.querySelector("#manageClassificationName");
    const name = (nameInput?.value || "").trim();
    if (!name) { nameInput?.classList.add("field-error"); manageClassificationSetMessage("Classification Name is required."); return; }
    const data = {
      organizationId: manageClassificationState.organizationId,
      subscriptionId: manageClassificationState.subscriptionId,
      classificationCode: manageClassificationBody.querySelector("#manageClassificationCode")?.value || "",
      classificationName: name,
      classificationScheme: manageClassificationBody.querySelector("#manageClassificationScheme")?.value || "",
      description: manageClassificationBody.querySelector("#manageClassificationDesc")?.value || "",
      classificationAction: "ADD"
    };
    if (existingItem) data.classificationId = Number(valueOf(existingItem, "ClassificationId"));
    try {
      await fetchJson(`${api}/custom-statement-classification`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id: 0, data })
      });
      await loadManageClassificationItems();
      renderManageClassificationList();
    } catch (error) {
      manageClassificationSetMessage(error.message || "Unable to save statement classification.");
    }
  }

  async function inactivateManageClassificationItem(item) {
    const id = valueOf(item, "ClassificationId");
    if (!id) return;
    if (!await window.gracUi.confirm("Mark this statement classification as inactive?", { type: "warning", title: "Mark inactive", confirmText: "Mark inactive" })) return;
    try {
      await fetchJson(`${api}/custom-statement-classification`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          id: 0,
          data: {
            organizationId: manageClassificationState.organizationId,
            subscriptionId: manageClassificationState.subscriptionId,
            classificationId: Number(id),
            classificationName: valueOf(item, "ClassificationName") || "placeholder",
            classificationAction: "INACTIVATE"
          }
        })
      });
      await loadManageClassificationItems();
      renderManageClassificationList();
    } catch (error) {
      manageClassificationSetMessage(error.message || "Unable to inactivate classification.");
    }
  }

  closeManageClassificationBtn?.addEventListener("click", () => manageClassificationDialog?.close());
  manageClassificationDialog?.addEventListener("close", () => {
    const onClose = manageClassificationState.onClose;
    manageClassificationState.onClose = null;
    if (typeof onClose === "function") onClose();
  });

  // --- Organization Role Menu Permission matrix -----------------------
  async function loadRolePermissionMatrix() {
    if (tableHead) tableHead.innerHTML = `<tr>${permissionMatrixColumns.map(column => `<th>${escapeHtml(column)}</th>`).join("")}</tr>`;
    state.records = [];
    const organizationId = organizationFilter?.value || "";
    if (!organizationId) {
      permissionMatrixState.roleId = "";
      rows.innerHTML = `<tr><td colspan="${permissionMatrixColumns.length}" class="pm-empty">Please select an organization to manage role menu permissions.</td></tr>`;
      renderPager();
      return;
    }
    rows.innerHTML = `<tr><td colspan="${permissionMatrixColumns.length}" class="pm-empty">Loading menus and permissions...</td></tr>`;
    try {
      const [menuResult, permissionResult] = await Promise.all([
        fetchJson(`${api}/menu-master/query`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
          body: JSON.stringify({ data: { pageNumber: 1, pageSize: 500 } })
        }),
        fetchJson(`${api}/role-menu-permissions/query`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
          body: JSON.stringify({ data: { organizationId: Number(organizationId), pageNumber: 1, pageSize: 1000 } })
        })
      ]);
      permissionMatrixState.menus = apiData(menuResult)
        .filter(menu => String(valueOf(menu, "MenuKey")) !== "menu-master")
        .sort((a, b) => Number(valueOf(a, "DisplayOrder") || 0) - Number(valueOf(b, "DisplayOrder") || 0));
      permissionMatrixState.existing = apiData(permissionResult);
      const availableRoles = lookupItemsFor("roles");
      if (!availableRoles.some(role => String(role.value) === String(permissionMatrixState.roleId))) permissionMatrixState.roleId = "";
      if (!permissionMatrixState.roleId && availableRoles.length) permissionMatrixState.roleId = String(availableRoles[0].value);
      renderRolePermissionMatrix();
    } catch (error) {
      rows.innerHTML = `<tr><td colspan="${permissionMatrixColumns.length}" class="pm-empty">${escapeHtml(error.message || "Unable to load role menu permissions.")}</td></tr>`;
    }
    renderPager();
  }

  function rolePermissionFor(menuId) {
    return permissionMatrixState.existing.find(row =>
      String(valueOf(row, "RoleId")) === String(permissionMatrixState.roleId)
      && String(valueOf(row, "MenuId")) === String(menuId)) || null;
  }

  function renderRolePermissionMatrix() {
    const availableRoles = lookupItemsFor("roles");
    const roleOptions = `<option value="">Select role...</option>${availableRoles.map(role => `<option value="${escapeHtml(role.value)}"${String(role.value) === String(permissionMatrixState.roleId) ? " selected" : ""}>${escapeHtml(role.label)}</option>`).join("")}`;
    const canSave = permissions.has("EDIT") || permissions.has("ADD");
    const controlRow = `<tr class="pm-control-group-row"><td colspan="${permissionMatrixColumns.length}">
      <label style="display:inline-flex;align-items:center;gap:8px;font-weight:600">Organization Role
        <select data-permission-role>${roleOptions}</select>
      </label>
      ${canSave ? `<button type="button" class="pm-button primary small" data-permission-save style="margin-left:12px"><i class="fa-solid fa-floppy-disk" aria-hidden="true"></i> Save Permissions</button>` : ""}
      <span data-permission-message style="margin-left:12px"></span>
    </td></tr>`;
    if (!permissionMatrixState.roleId) {
      rows.innerHTML = `${controlRow}<tr><td colspan="${permissionMatrixColumns.length}" class="pm-empty">${availableRoles.length ? "Select an organization role to manage its menu permissions." : "No active roles found for this organization. Create roles in Organization Role Management first."}</td></tr>`;
      return;
    }
    const disabled = canSave ? "" : " disabled";
    const groups = new Map();
    permissionMatrixState.menus.forEach(menu => {
      const group = String(valueOf(menu, "ModuleType") || "Practice Management");
      if (!groups.has(group)) groups.set(group, []);
      groups.get(group).push(menu);
    });
    const bodyRows = [...groups.entries()].map(([group, menus]) => `
      <tr class="pm-control-group-row"><td colspan="${permissionMatrixColumns.length}">${escapeHtml(group)}</td></tr>
      ${menus.map(menu => {
        const menuId = valueOf(menu, "Id");
        const existing = rolePermissionFor(menuId);
        const check = (field) => `<td style="text-align:center"><input type="checkbox" data-perm-field="${field}"${existing && boolOf(existing, field) ? " checked" : ""}${disabled}></td>`;
        return `<tr data-permission-menu="${escapeHtml(menuId)}" data-permission-id="${escapeHtml(existing ? valueOf(existing, "Id") : "")}">
          <td>${escapeHtml(valueOf(menu, "MenuName"))} <small style="color:#64748b">${escapeHtml(valueOf(menu, "MenuKey"))}</small></td>
          ${check("CanView")}${check("CanAdd")}${check("CanEdit")}${check("CanDelete")}${check("CanApprove")}
        </tr>`;
      }).join("")}`).join("");
    rows.innerHTML = controlRow + bodyRows;
  }

  async function saveRolePermissionMatrix(saveButtonEl) {
    const messageHost = rows.querySelector("[data-permission-message]");
    const organizationId = Number(organizationFilter?.value || 0);
    const roleId = Number(permissionMatrixState.roleId || 0);
    if (!organizationId || !roleId) return;
    const changes = [];
    rows.querySelectorAll("[data-permission-menu]").forEach(row => {
      const menuId = Number(row.dataset.permissionMenu);
      const id = Number(row.dataset.permissionId || 0);
      const current = {
        canView: row.querySelector("[data-perm-field='CanView']")?.checked === true,
        canAdd: row.querySelector("[data-perm-field='CanAdd']")?.checked === true,
        canEdit: row.querySelector("[data-perm-field='CanEdit']")?.checked === true,
        canDelete: row.querySelector("[data-perm-field='CanDelete']")?.checked === true,
        canApprove: row.querySelector("[data-perm-field='CanApprove']")?.checked === true
      };
      const existing = rolePermissionFor(menuId);
      const original = existing ? {
        canView: boolOf(existing, "CanView"),
        canAdd: boolOf(existing, "CanAdd"),
        canEdit: boolOf(existing, "CanEdit"),
        canDelete: boolOf(existing, "CanDelete"),
        canApprove: boolOf(existing, "CanApprove")
      } : { canView: false, canAdd: false, canEdit: false, canDelete: false, canApprove: false };
      const changed = Object.keys(current).some(key => current[key] !== original[key]);
      const anyChecked = Object.values(current).some(Boolean);
      if (changed && (existing || anyChecked)) changes.push({ id, menuId, ...current });
    });
    if (!changes.length) {
      if (messageHost) messageHost.textContent = "No permission changes to save.";
      return;
    }
    if (saveButtonEl) saveButtonEl.disabled = true;
    if (messageHost) messageHost.textContent = `Saving ${changes.length} menu permission(s)...`;
    try {
      for (const change of changes) {
        await fetchJson(`${api}/role-menu-permissions`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
          body: JSON.stringify({
            id: change.id || 0,
            data: {
              organizationId,
              roleId,
              menuId: change.menuId,
              canView: change.canView,
              canAdd: change.canAdd,
              canEdit: change.canEdit,
              canDelete: change.canDelete,
              canApprove: change.canApprove
            }
          })
        });
      }
      if (messageHost) messageHost.textContent = "Permissions saved successfully. Users will receive them on their next sign-in.";
      await loadRolePermissionMatrix();
    } catch (error) {
      if (messageHost) messageHost.textContent = error.message || "Unable to save permissions.";
      if (saveButtonEl) saveButtonEl.disabled = false;
    }
  }

  // --- Organization User Role Assignment ------------------------------
  function openUserRoleAssignmentForm(record, readonly = false) {
    state.mode = readonly ? "view" : "edit";
    state.id = Number(valueOf(record, "Id") || 0);
    state.formEntity = "user-role-assignments";
    state.activeFormRecord = record;
    formMessage.hidden = true;
    const assignedRoleIds = String(valueOf(record, "RoleIds") || "").split(",").map(item => item.trim()).filter(Boolean);
    document.querySelector("#dialogTitle").textContent = readonly ? "View User Roles" : "Manage User Roles";
    fieldsHost.innerHTML = `
      <input name="organizationId" type="hidden" value="${escapeHtml(valueOf(record, "OrganizationId"))}">
      <input name="employeeId" type="hidden" value="${escapeHtml(valueOf(record, "Id"))}">
      <label class="pm-field"><span>Employee</span><input value="${escapeHtml(`${valueOf(record, "EmployeeCode")} - ${valueOf(record, "EmployeeName")}`)}" disabled></label>
      <label class="pm-field"><span>Email</span><input value="${escapeHtml(valueOf(record, "Email"))}" disabled></label>
      ${fieldMarkup({ name: "roleIds", label: "Organization Roles", type: "comboChecks", lookup: "roles", full: true }, assignedRoleIds, readonly)}
      <p class="pm-empty compact" style="grid-column:1/-1">Assign one or more organization roles. Menu permissions from all assigned roles are combined at sign-in.</p>`;
    saveButton.hidden = readonly;
    dialog.showModal();
  }

  function renderRows() {
    if (!state.records.length) {
      const emptyMessage = ["organization-controls", "control-applicability"].includes(screen.Key)
        ? "No organization controls found for the selected organization. Select the correct organization, subscribe it to releases that have Source Structure-Control mappings, then run the organization-control sync/import."
        : screen.Key === "organization-requirements"
          ? (state.navigationCode ? "No practices found for this Control Statement. Please verify the statement is Applicable and has mapped practices." : "No organization practices found for the selected organization.")
        : screen.Key === "practice-instances"
          ? "No practice instances found for the selected requirement/practice. Add a new instance or verify the selected requirement/practice context."
        : (workbenchScreens.has(screen.Key) || isOperationalizationWorkbench) && state.workbenchUnauthorized
          ? "You are not authorized to manage this dependency workbench."
        : (workbenchScreens.has(screen.Key) || isOperationalizationWorkbench)
          ? "No Practice Instances are queued for this dependency workbench."
        : "No data found.";
      rows.innerHTML = `<tr><td colspan="${screen.Columns.length + 1}" class="pm-empty">${escapeHtml(emptyMessage)}</td></tr>`;
      return;
    }
    closeActionMenu();
    if (screen.Key === "organization-requirements") {
      if (state.navigationContext?.filterType === "FrameworkStatement") {
        // Opened from a Source Statement: the heading already identifies the
        // statement, so practices render as a flat list. The Control concept is
        // removed from this flow — no Control grouping headers.
        renderStatementPracticeRows();
        return;
      }
      renderRequirementControlGroups();
      return;
    }
    // Q13/Q14/Q15 — expose a stable per-row identifier via data-record-id
    // so partial-hosted UI hooks (e.g. Add Implementation Task) can resolve
    // the row's primary key without needing access to the internal state
    // closure. Falls back to empty string when no id-like field is present.
    rows.innerHTML = state.records.map((row, index) => {
      const rowId = valueOf(row, "Id")
        || valueOf(row, "PracticeInstanceId")
        || valueOf(row, "PracticeId")
        || valueOf(row, "OrganizationControlId")
        || "";
      return `<tr data-record-id="${escapeHtml(rowId)}">${currentColumns().map(column => {
        const value = column === "Register" ? (valueOf(row, "Register") || valueOf(row, "DependencyCategory")) : valueOf(row, column);
        const title = column === "SourceFrameworkRelease" ? ` title="${escapeHtml(value)}"` : "";
        return `<td${title}>${formatCell(value)}</td>`;
      }).join("")}<td>${actions(index)}</td></tr>`;
    }).join("");
  }

  function renderStatementPracticeRows() {
    if (tableHead) tableHead.innerHTML = `<tr>
      ${bulkHeaderCell()}
      <th>Practice Code</th>
      <th>Practice Name</th>
      <th>Applicability Status</th>
      <th>Implementation Status</th>
      <th>Owner</th>
      <th>Origin Type</th>
      <th>Actions</th>
    </tr>`;
    pruneBulkSelection(state.records);
    rows.innerHTML = state.records.map((record, index) => `<tr>
      ${bulkCell(record)}
      <td>${formatCell(valueOf(record, "Code"))}</td>
      <td>${formatCell(valueOf(record, "Name"))}</td>
      <td>${formatCell(valueOf(record, "ApplicabilityStatus"))}</td>
      <td>${formatCell(practiceImplementationStatus(record))}</td>
      <td>${formatCell(valueOf(record, "PracticeOwner"))}</td>
      <td>${formatCell(valueOf(record, "OriginType"))}</td>
      <td>${actions(index)}</td>
    </tr>`).join("");
  }

  // Implementation Status for a Practice row. Derived server-side from the
  // Practice's instances (see QueryOrganizationRequirementFallbackAsync) and
  // read from PracticeImplementationStatus, NOT ImplementationStatus -- the
  // latter is the value stored on the requirement and is what the edit form's
  // hidden field posts back, so the two must not be confused.
  //
  // Falls back to "Not Implemented" the way the Source Statement grid does,
  // so a row from an older API build that does not carry the column still
  // renders a badge rather than an empty cell.
  function practiceImplementationStatus(record) {
    return valueOf(record, "practiceImplementationStatus") || "Not Implemented";
  }

  function renderRequirementControlGroups() {
    if (tableHead) tableHead.innerHTML = "";
    pruneBulkSelection(state.records);
    const groups = new Map();
    state.records.forEach((record, index) => {
      const controlId = valueOf(record, "OrganizationControlId") || valueOf(record, "ControlCode") || "unmapped";
      if (!groups.has(controlId)) {
        groups.set(controlId, {
          code: valueOf(record, "ControlCode") || `Control ${controlId}`,
          name: valueOf(record, "ControlName") || "",
          rows: []
        });
      }
      groups.get(controlId).rows.push({ record, index });
    });
    rows.innerHTML = [...groups.values()].map(group => {
      const title = `${group.code}${group.name ? ` - ${group.name}` : ""}`;
      const detailRows = group.rows.map(({ record, index }) => `<tr>
        ${bulkCell(record)}
        <td>${formatCell(valueOf(record, "Code"))}</td>
        <td>${formatCell(valueOf(record, "Name"))}</td>
        <td>${formatCell(valueOf(record, "ApplicabilityStatus"))}</td>
        <td>${formatCell(practiceImplementationStatus(record))}</td>
        <td>${formatCell(valueOf(record, "PracticeOwner"))}</td>
        <td>${formatCell(valueOf(record, "OriginType"))}</td>
        <td>${actions(index)}</td>
      </tr>`).join("");
      return `<tr class="pm-control-group-row"><td colspan="${7 + bulkColumnCount()}">Control: ${escapeHtml(title)}</td></tr>
        <tr class="pm-control-group-head">
          ${bulkHeaderCell()}
          <th>Practice Code</th>
          <th>Practice Name</th>
          <th>Applicability Status</th>
          <th>Implementation Status</th>
          <th>Owner</th>
          <th>Origin Type</th>
          <th>Actions</th>
        </tr>${detailRows}`;
    }).join("");
  }

  // TotalRows rides last in the projection of every paged branch of
  // dbo.pm_get_practice_repository (migration 300) and of the C# fallback
  // queries that shadow them, so it is the same on every row -- read it
  // off the first.
  //
  // Returns undefined, NOT 0, when the column is absent: a screen whose
  // endpoint does not report a total (Source Statements fetches its
  // releases in one page and filters them locally) must degrade to
  // pm-grid's "Page N" label rather than claim the list is empty.
  function totalRowsOf(records) {
    if (!records.length) return 0;
    const raw = valueOf(records[0], "totalRows");
    if (raw === "" || raw === null || raw === undefined) return undefined;
    const total = Number(raw);
    return Number.isFinite(total) && total >= 0 ? total : undefined;
  }

  function renderPager() {
    gridPager?.setTotal(totalRowsOf(state.records), state.records.length);
  }

  // A FILTER changed, not the page. reset(true) is silent -- it moves the
  // pager to page 1 without firing onChange -- because loadRows() below
  // is the one refetch we want, not two.
  function resetToFirstPage() {
    gridPager?.reset(true);
    state.pageNumber = 1;
    loadRows();
  }

  async function resetOrganizationRequirementFilters() {
    if (status) status.value = "";
    if (subscribedFrameworkFilter) subscribedFrameworkFilter.value = "";
    // The search box (Organization Practices only, unhidden alongside this
    // filter set) is otherwise cleared by the generic branch of the
    // clearFilters handler -- this screen takes its own branch instead
    // (it also reloads subscribed frameworks), so it has to clear search
    // itself.
    if (search) search.value = "";
    await loadSubscribedFrameworks();
    resetToFirstPage();
  }

  function formatCell(value) {
    if (value === true || value === false) return value ? "Yes" : "No";
    // Project-wide date format (dd-MMM-yyyy, +HH:mm when a real time is present).
    // gracFormatDisplayDate returns the value unchanged when it is not a date.
    if (typeof window.gracFormatDisplayDate === "function") {
      const asDate = window.gracFormatDisplayDate(value);
      if (asDate !== value) return escapeHtml(asDate);
    }
    if (String(value || "").match(/^(Active|Inactive|Applicable|Not Updated|Implemented|Partially Implemented|Not Implemented|Critical|High|Medium|Low|Deferred|Accepted Risk|Not Applicable|Configured|Partially Operationalized|Operationalized|Retired|Pending|Resolved|Default password|Password set)$/i)) return `<span class="pm-badge">${escapeHtml(value)}</span>`;
    return escapeHtml(value);
  }

  function actions(index) {
    return `<button type="button" class="pm-action-trigger" data-action-menu-index="${escapeHtml(index)}" aria-haspopup="menu" aria-expanded="false" title="Actions">
      <i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i><span class="visually-hidden">Actions</span>
    </button>`;
  }

  // Rule 3 — build the 3-dot menu markup for a subscribed-framework
  // release row. Admin (GLOBAL/ORGANIZATION scope) sees View + Update
  // Owner always; Edit/Retire only when the release is Custom.
  // Employees (narrower scope) never see this menu — they auto-drill
  // into the statements list via Rule 4.
  function releaseActionsMarkup(index, release) {
    if (isEmployeeScope) return "";
    // NOTE: no inline onclick here — the delegated click handler on
    // #practiceRows already special-cases `.pm-action-trigger` to skip
    // the row-drill, and adding `event.stopPropagation()` on the button
    // would stop the click from bubbling up to that delegated handler,
    // so openActionMenu would never run.
    return `<button type="button" class="pm-action-trigger" data-release-menu-index="${escapeHtml(index)}" aria-haspopup="menu" aria-expanded="false" title="Actions">
      <i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical" aria-hidden="true"></i><span class="visually-hidden">Actions</span>
    </button>`;
  }

  function allowedReleaseActions(release) {
    if (!release || isEmployeeScope) return [];
    const isCustom = Number(valueOf(release, "ReleaseId") || 0) < 0
      || String(valueOf(release, "SubscriptionType") || "").toLowerCase() === "custom";
    // Custom releases assign Owner through Edit Release now (it's one of
    // the form's fields, see openCustomReleaseForm) -- ticket: "a separate
    // Owner update page is not necessary" for Custom releases, so
    // releaseUpdateOwner is offered only for Subscribed (non-Custom) rows.
    // Subscribed releases are untouched: they keep their own dedicated
    // Update Owner flow exactly as before.
    const list = isCustom ? ["releaseView", "releaseEdit", "releaseRetire"] : ["releaseView", "releaseUpdateOwner"];
    return list.filter(action => {
      if (action === "releaseView") return permissions.has("VIEW");
      if (action === "releaseUpdateOwner") return permissions.has("EDIT") || permissions.has("ADD");
      if (action === "releaseEdit") return permissions.has("EDIT") || permissions.has("ADD");
      if (action === "releaseRetire") return permissions.has("DELETE");
      return false;
    });
  }

  // Normalises a subscribed-framework row into the shape
  // sourceStatementState.release expects.
  function mapReleaseSelection(release) {
    return {
      subscriptionId: Number(valueOf(release, "SubscriptionId") || 0),
      releaseId: valueOf(release, "ReleaseId"),
      organizationId: Number(valueOf(release, "OrganizationId") || organizationFilter?.value || 0),
      // Add Source Statements bug fix: openCustomStatementForm()'s read-only
      // Organization/Release display fields (and the Source Structure panel
      // title/dialog) read release.organizationName and release.releaseVersion
      // directly, with no fallback for the first one. The manual
      // click-a-release-row handler (below, on the data-release-index branch)
      // already sets both. This mapper is the OTHER way sourceStatementState.release
      // gets built -- auto-drilling into an organization's only release, and the
      // release-level "View" action -- and it never set either field, so both
      // paths opened Add Control Statement with a blank Organization and a blank
      // Release even though organizationId/subscriptionId/releaseId (what the
      // Source Structure Node data actually loads by) were always correct.
      organizationName: (organizationFilter?.selectedOptions?.[0]?.textContent || "").trim(),
      releaseVersion: valueOf(release, "ReleaseVersion") || "",
      title: valueOf(release, "FrameworkRelease") || valueOf(release, "ReleaseVersion"),
      subscriptionType: valueOf(release, "SubscriptionType") || ""
    };
  }

  function allowedActions(record = null) {
    let actions = actionDefinitions[screen.Key] || ["view", "edit", "inactive"];
    const applicabilityStatus = row => {
      const code = String(valueOf(row, "ApplicabilityStatusCode") || "").trim().toLowerCase();
      if (code) return code;
      const text = String(valueOf(row, "ApplicabilityStatus") || "Not Updated").trim().toLowerCase();
      return text;
    };
    // isSourceStatements, not screen.Key === "organization-controls": the
    // dedicated Source Statements screen renders the identical statement grid
    // and handleAction already dispatches it through the same branch. Keying
    // the menu on one screen key alone left source-statements falling back to
    // the default view/edit/inactive set.
    if (isSourceStatements && sourceStatementState.isCustomRelease && sourceStatementState.level === "statements") {
      // Rule 4 — employees can only mark applicability on custom statements,
      // not edit / inactive them.
      actions = isEmployeeScope ? ["view", "markApplicability"] : ["view", "edit", "inactive"];
    } else if (isSourceStatements && sourceStatementState.level === "statements" && record) {
      const applicability = applicabilityStatus(record);
      const manuallyAdded = valueOf(record, "IsManuallyAdded") === true || String(valueOf(record, "IsManuallyAdded")).toLowerCase() === "true" || String(valueOf(record, "IsManuallyAdded")) === "1";
      // Rule 4 — employees never get edit/inactive on statements; only
      // Applicability Marking (Mark or Update) and View.
      const manualExtras = isEmployeeScope ? [] : (manuallyAdded ? ["edit", "inactive"] : []);
      const manualEditOnly = isEmployeeScope ? [] : (manuallyAdded ? ["edit"] : []);
      if (applicability === "not updated") actions = ["markApplicability", "view", ...manualExtras];
      else if (applicability === "applicable") actions = [...(isEmployeeScope ? [] : ["practices"]), "view", ...manualEditOnly];
      else actions = ["updateApplicability", "view", ...manualEditOnly];
    }
    if (screen.Key === "organization-requirements" && record) {
      const applicability = applicabilityStatus(record);
      // See actionDefinitions: View Obligations is gone from this menu because
      // the View page shows the same panel.
      // "instances" is gone from this menu. View lists every instance under
      // the practice now, and Operationalize owns working on one, so the
      // entry was a third way to reach rows already reachable twice.
      // "newInstance" is gone too, per sir. Creating an instance is not an
      // action on a requirement row -- the Practice Instances screen owns
      // it, with its own Add New Instance button and the full form. The
      // entry here was applicable-only and opened a cut-down dialog, so it
      // was a second, narrower way to do the same thing.
      //
      // The label, icon and openNewPracticeInstance() below are LEFT IN
      // PLACE, unreachable from this menu. They are not dead by accident:
      // putting the entry back is adding "newInstance" to the line below
      // and nothing else. Deleting the handler would make that a rewrite.
      // Once a practice has been marked (any status, Applicable included),
      // the menu offers Update Applicability -- enabled and pre-filled with
      // the current decision -- instead of dropping the action. Only a
      // Not Updated row shows Mark Applicability.
      if (applicability === "not updated") actions = ["view", "markApplicability"];
      else actions = ["view", "updateApplicability"];
    }
    if (screen.Key === "practices") {
      const applicability = record ? applicabilityStatus(record) : "not updated";
      if (applicability === "not updated") actions = ["markApplicability", "view"];
      else if (applicability === "applicable") actions = ["instances", "view", "updateApplicability"];
      else actions = ["updateApplicability", "view"];
    }
    return actions.filter(action => {
      if (action === "view") return permissions.has("VIEW");
      if (action === "viewOperationalization" || action === "dependencyIntelligence") return permissions.has("VIEW");
      if (action === "edit" || action === "configure" || action === "manage" || action === "map" || action === "subscribe" || action === "markApplicability" || action === "updateApplicability" || action === "resolveDependencies" || action === "modifyDependencies" || action === "bulkResolution" || action === "manageRoles" || action === "resendCredentials" || action === "newInstance") return permissions.has("EDIT") || permissions.has("ADD");
      if (action === "inactive") return permissions.has("DELETE");
      if (action === "accept" || action === "reject") return permissions.has("APPROVE") || permissions.has("EDIT");
      if (action === "practice" || action === "practices" || action === "instances" || action === "evidence" || action === "dependencies") return permissions.has("VIEW");
      return true;
    });
  }

  function openActionMenu(trigger) {
    // Rule 3 — the Source Statements Level-1 grid uses a separate
    // release-scoped menu because its actions (View Statements, Update
    // Owner, Edit / Retire Custom) differ from the regular record
    // actions.
    const releaseIndex = trigger.dataset.releaseMenuIndex;
    const index = releaseIndex ?? trigger.dataset.actionMenuIndex;
    const record = releaseIndex !== undefined
      ? sourceStatementState.releases[Number(releaseIndex)] || null
      : state.records[Number(index)] || null;
    const actions = releaseIndex !== undefined
      ? allowedReleaseActions(record)
      : allowedActions(record);
    closeActionMenu();
    actionTrigger = trigger;
    actionTrigger.setAttribute("aria-expanded", "true");
    actionMenu = document.createElement("div");
    actionMenu.className = "pm-action-menu";
    actionMenu.setAttribute("role", "menu");
    actionMenu.innerHTML = actions.map(action => `<button type="button" role="menuitem" data-action="${action}" data-index="${escapeHtml(index)}"><i class="fa-solid ${escapeHtml(actionIcons[action] || "fa-circle-dot")}" aria-hidden="true"></i> ${escapeHtml(actionLabels[action] || action)}</button>`).join("");
    document.body.appendChild(actionMenu);
    positionActionMenu(trigger);
  }

  function positionActionMenu(trigger) {
    if (!actionMenu) return;
    const rect = trigger.getBoundingClientRect();
    const menuRect = actionMenu.getBoundingClientRect();
    const gap = 6;
    let top = rect.bottom + gap;
    let left = rect.right - menuRect.width;
    if (top + menuRect.height > window.innerHeight - 8) top = Math.max(8, rect.top - menuRect.height - gap);
    if (left < 8) left = 8;
    if (left + menuRect.width > window.innerWidth - 8) left = window.innerWidth - menuRect.width - 8;
    actionMenu.style.top = `${top}px`;
    actionMenu.style.left = `${left}px`;
  }

  function closeActionMenu() {
    actionTrigger?.setAttribute("aria-expanded", "false");
    actionTrigger = null;
    actionMenu?.remove();
    actionMenu = null;
  }

  function placeholderAction(action) {
    const label = actionLabels[action] || action;
    alert(`${label} will open its dedicated workspace in the next PracticeManagement phase.`);
  }

  // ==================================================================
  // Conditional fields (migrations 133/134).
  //
  // fieldMarkup already stamps every wrapper with data-field-name, so
  // showing and hiding by driver value needs no change to the renderer.
  //
  // Hidden fields are CLEARED, not just hidden: collectForm() gathers every
  // [name] in the host, so a Provider left over from a moment when
  // Personnel Type read ThirdParty would still be submitted for an
  // Employee -- and ck_pm_employee_provider_required would reject the save
  // with a constraint error instead of a readable message.
  // ==================================================================
  const conditionalFields = {
    providerVendorId:    { driver: "partyType", showWhen: ["ThirdParty"], required: true },
    engagementStartDate: { driver: "partyType", showWhen: ["ThirdParty"] },
    engagementEndDate:   { driver: "partyType", showWhen: ["ThirdParty"] },
    vendorId:            { driver: "teamType",  showWhen: ["Vendor"],     required: true }
  };

  function applyConditionalFields() {
    if (!fieldsHost) return;
    const drivers = new Set();

    Object.entries(conditionalFields).forEach(([name, rule]) => {
      const wrapper = fieldsHost.querySelector(`[data-field-name="${name}"]`);
      const driver = fieldsHost.querySelector(`[name="${rule.driver}"]`);
      // vendorId also exists on dependency-applications / dependency-tools,
      // where there is no teamType driver at all. No driver on this form
      // means the field is not conditional here -- leave it alone.
      if (!wrapper || !driver) return;
      drivers.add(rule.driver);

      const show = rule.showWhen.includes(String(driver.value || ""));
      wrapper.hidden = !show;
      const input = wrapper.querySelector("[name]");
      if (!input) return;
      if (show) {
        if (rule.required) input.required = true;
      } else {
        input.required = false;
        if (input.tagName === "SELECT") input.value = "";
        else input.value = "";
        input.classList.remove("field-error");
      }
    });

    drivers.forEach(driverName => {
      const driver = fieldsHost.querySelector(`[name="${driverName}"]`);
      if (!driver || driver.dataset.conditionalWired === "1") return;
      driver.dataset.conditionalWired = "1";
      driver.addEventListener("change", applyConditionalFields);
    });
  }

  // Reason / Justification lock on Applicable (2026-09-16).
  //
  // Unlike conditionalFields above, this does NOT hide-and-clear -- it only
  // disables the textarea. exclusionJustification only ever means "why is
  // this NOT applicable"; once a record is Applicable there is nothing new
  // to type, but a reason entered while it was Not Applicable / Deferred /
  // Accepted Risk must stay visible after the status changes back, per sir
  // (confirmed 2026-09-16). pm_manage_practice_repository (002) now
  // preserves the saved value instead of nulling it on Applicable -- this
  // only stops the UI from offering a new one; collectForm() still reads
  // the disabled textarea's (unchanged) value and resends it, which the
  // proc's COALESCE(new, existing) accepts harmlessly either way.
  //
  // Scoped to organization-requirements/practices applicability, matching
  // the SQL change -- organization-controls keeps clearing on Applicable.
  function applyApplicabilityReasonLock(mode) {
    if (mode !== "applicability" || !["organization-requirements", "practices"].includes(screen.Key)) return;
    const statusSelect = fieldsHost.querySelector("[name='applicabilityStatus']");
    const reasonField = fieldsHost.querySelector("[name='exclusionJustification']");
    if (!statusSelect || !reasonField) return;
    const sync = () => { reasonField.disabled = statusSelect.value === "Applicable"; };
    sync();
    if (statusSelect.dataset.reasonLockWired !== "1") {
      statusSelect.dataset.reasonLockWired = "1";
      statusSelect.addEventListener("change", sync);
    }
  }

  function fieldMarkup(field, value, readonly, record) {
    if (field.type === "hidden") return `<input name="${field.name}" type="hidden" value="${escapeHtml(value)}">`;
    const required = field.required ? `<span class="required"> *</span>` : "";
    const disabled = readonly || field.readonly ? " disabled" : "";
    let control;
    if (field.type === "textarea") control = `<textarea name="${field.name}" rows="3"${disabled}${field.required ? " required" : ""}>${escapeHtml(value)}</textarea>`;
    else if (field.type === "select") {
      // Cascade: at the first render every field arrives at once via one
      // innerHTML assignment, so fieldsHost.querySelector cannot see the
      // parent yet -- read parent from the incoming record instead. The
      // change handler below then keeps the two in step as the user edits.
      let parentValue;
      if (field.parentField) {
        if (record) parentValue = String(valueOf(record, field.parentField) ?? "");
        else {
          const parentInput = fieldsHost?.querySelector(`[name='${field.parentField}']`);
          parentValue = parentInput ? parentInput.value : "";
        }
      }
      const cascadeAttr = field.parentField ? ` data-parent-field="${escapeHtml(field.parentField)}"` : "";
      control = `<select name="${field.name}"${disabled}${field.required ? " required" : ""}${cascadeAttr}>${optionsFor(field.lookup, value, parentValue, field.restrictTo)}</select>`;
    }
    else if (field.type === "comboChecks") {
      const rawValues = Array.isArray(value) ? value : String(value || "").split(",").map(item => item.trim()).filter(Boolean);
      const values = new Set(rawValues.map(String));
      const lookupItems = lookupItemsFor(field.lookup);
      const selectedLabels = lookupItems.filter(item => values.has(String(item.value))).map(item => item.label);
      const options = lookupItems.map(item => `<label data-checkcombo-option><input name="${field.name}" type="checkbox" value="${escapeHtml(item.value)}"${values.has(String(item.value)) ? " checked" : ""}${disabled}> <span>${escapeHtml(item.label)}</span></label>`).join("");
      control = `<button class="pm-checkcombo-trigger" type="button" data-checkcombo-trigger${disabled}>
          <span data-checkcombo-text>${escapeHtml(selectedLabels.join(", ") || "Select...")}</span>
        </button>
        <div class="pm-checkcombo-menu" data-checkcombo-menu hidden>
          <input class="pm-checkcombo-search" type="search" placeholder="Search..." data-checkcombo-search>
          <div class="pm-checkcombo-options">${options || `<div class="pm-empty compact">No options found.</div>`}</div>
        </div>`;
      return `<div class="pm-field pm-checkcombo${field.full ? " full" : ""}" data-checkcombo data-field-name="${escapeHtml(field.name)}"><span>${escapeHtml(field.label)}${required}</span>${control}</div>`;
    }
    else if (field.type === "deptEmployeeTree") {
      // Team Members (migration 362, change request 2026-09-20): a
      // multi-select Department -> Employee tree. Reuses the Organization
      // Setup Subscribed Frameworks tree's exact markup/CSS wholesale --
      // .pm-subscription-tree / .pm-tree-branch / .pm-tree-row.authority
      // (parent, expand/collapse, no checkbox) / .pm-tree-row.release
      // (leaf, checkbox) / .tree-spacer -- per the "reuse existing tree,
      // checkbox, expand/collapse... styling patterns" requirement.
      // Department stands in for "authority", Employee for "release";
      // the class names are literally reused, not reinvented, so every
      // hover/selected/scroll rule already written for that tree applies
      // here unchanged. data-checkcombo on the outer wrapper is what
      // collectForm() already keys on to gather several same-name
      // checkboxes into one array (see its "input.closest('[data-checkcombo]')"
      // branch) -- reused purely for that accumulation behaviour, not for
      // the dropdown-menu chrome comboChecks itself renders.
      //
      // Matches "employees-id"/"users-id"/"departments" for org-scoping:
      // lookupItemsFor() filters this lookup by currentFormOrganizationId()
      // the same way it already does for the Team Manager / Parent
      // Department pickers -- picked once at render time, same as those
      // sibling fields (neither re-filters live if Organization is changed
      // after the form opens; this stays consistent with that).
      const values = new Set((Array.isArray(value) ? value : String(value || "").split(",").map(v => v.trim()).filter(Boolean)).map(String));
      const disabledAttr = disabled;
      const employees = lookupItemsFor(field.lookup || "team-department-employees");
      const departmentLookup = lookupItemsFor("team-departments");
      const orgId = currentFormOrganizationId();
      const byDept = new Map();
      departmentLookup.forEach(dept => {
        if (orgId && dept.organizationId && dept.organizationId !== orgId) return;
        byDept.set(dept.value, { id: dept.value, name: dept.label, employees: [] });
      });
      employees.forEach(item => {
        const deptId = item.departmentId || "";
        if (!deptId) return;
        if (!byDept.has(deptId)) byDept.set(deptId, { id: deptId, name: item.departmentName || "(No department)", employees: [] });
        byDept.get(deptId).employees.push(item);
      });
      const departments = [...byDept.values()].sort((a, b) => a.name.localeCompare(b.name));
      const treeHtml = departments.length
        ? departments.map(dept => {
            const selectedCount = dept.employees.filter(item => values.has(String(item.value))).length;
            const startCollapsed = selectedCount === 0;
            const countBadge = selectedCount ? ` <small>(${selectedCount} selected)</small>` : "";
            const employeeRows = dept.employees.length
              ? dept.employees.map(item => `<label class="pm-tree-row release" style="--tree-depth:1"><span class="tree-spacer"></span><input name="${escapeHtml(field.name)}" type="checkbox" value="${escapeHtml(item.value)}"${values.has(String(item.value)) ? " checked" : ""}${disabledAttr}> <span>${escapeHtml(item.label)}</span></label>`).join("")
              : `<div class="pm-tree-row release" style="--tree-depth:1"><span class="tree-spacer"></span><small>No active employees in this department.</small></div>`;
            return `<div class="pm-tree-branch">
              <div class="pm-tree-row authority"><button type="button" data-tree-toggle="team-dept-${escapeHtml(dept.id)}" data-team-tree-toggle aria-label="Expand or collapse ${escapeHtml(dept.name)}">${startCollapsed ? "+" : "-"}</button><strong>${escapeHtml(dept.name)}</strong>${countBadge}</div>
              <div class="pm-team-tree-children"${startCollapsed ? " hidden" : ""}>${employeeRows}</div>
            </div>`;
          }).join("")
        : `<div class="pm-empty compact">No departments or employees found${orgId ? " for this organization" : ""}. Select an Organization, or add Departments and Employees first.</div>`;
      return `<div class="pm-field${field.full ? " full" : ""}" data-checkcombo data-field-name="${escapeHtml(field.name)}"><span>${escapeHtml(field.label)}${required}</span><div class="pm-subscription-tree" data-team-tree>${treeHtml}</div></div>`;
    }
    else if (field.type === "checkbox") {
      // A real checkbox: reflect the stored value on edit (boolOf reads
      // true/1/"true"/"yes"/"y") and let collectForm read input.checked.
      // The generic else-branch below rendered a type=checkbox with a value
      // and no `checked`, so an edit never showed the stored state and a
      // save silently cleared it -- this branch fixes that for every
      // checkbox field, Functional User included.
      control = `<span class="pm-checkline"><input name="${field.name}" type="checkbox"${boolOf(record, field.name) ? " checked" : ""}${disabled}> Yes</span>`;
    }
    else if ((field.type === "date" || field.type === "datetime-local") && (readonly || field.readonly)) {
      // View / read-only: show the unified dd-MMM-yyyy(+HH:mm) text rather
      // than a native date input (which renders in the browser locale).
      // Edit mode keeps the real date picker via the default branch below.
      const shown = typeof window.gracFormatDisplayDate === "function" ? window.gracFormatDisplayDate(value) : value;
      control = `<input name="${field.name}" type="text" value="${escapeHtml(shown)}" disabled>`;
    }
    else control = `<input name="${field.name}" type="${field.type}" value="${escapeHtml(value)}"${disabled}${field.required ? " required" : ""}>`;
    return `<label class="pm-field${field.full ? " full" : ""}" data-field-name="${escapeHtml(field.name)}"><span>${escapeHtml(field.label)}${required}</span>${control}</label>`;
  }

  // Read-only value display for View mode (Location View page change
  // request 2026-09-20). fieldMarkup above renders a real disabled
  // <input>/<select>/<textarea> for View mode across every one of the ~30
  // entity forms that reuse the shared #recordDialog (actionDefinitions
  // lists "view" for organizations, departments, teams, users, and about
  // twenty others) -- fieldMarkup itself is left completely untouched so
  // none of those other screens' View pages change. This is a separate
  // function, wired in only where openForm's render call below checks
  // screen.Key === "locations" && mode === "view". A disabled control
  // still looks like a form waiting to be enabled; this renders a plain
  // label above a value box instead, reusing the same .pm-view-value /
  // .pm-field-empty pattern built for Organization Administration's
  // Organization tab (setupViewFieldMarkup above), per the request to
  // "use the same read-only/view-page design pattern used for the
  // updated Organization page".
  function viewFieldMarkup(field, value, record) {
    if (field.type === "hidden") return "";
    const label = escapeHtml(field.label);
    let text = null; // non-null once resolved to a real, non-empty display string
    if (field.type === "checkbox") {
      text = boolOf(record, field.name) ? "Yes" : "No";
    } else if (field.type === "comboChecks") {
      const rawValues = Array.isArray(value) ? value : String(value || "").split(",").map(item => item.trim()).filter(Boolean);
      const values = new Set(rawValues.map(String));
      const labels = lookupItemsFor(field.lookup).filter(item => values.has(String(item.value))).map(item => item.label);
      if (labels.length) text = labels.join(", ");
    } else if (field.type === "select") {
      const match = lookupItemsFor(field.lookup).find(item => String(item.value) === String(value ?? ""));
      if (match) text = match.label;
      else if (value) text = String(value);
    } else if (field.type === "date" || field.type === "datetime-local") {
      const shown = typeof window.gracFormatDisplayDate === "function" ? window.gracFormatDisplayDate(value) : value;
      if (shown) text = String(shown);
    } else {
      const raw = value === null || value === undefined ? "" : String(value).trim();
      if (raw) text = raw;
    }
    const valueMarkup = text === null
      ? `<div class="pm-field-empty">Not set</div>`
      : `<div class="pm-view-value">${escapeHtml(text)}</div>`;
    return `<div class="pm-field pm-view-field${field.full ? " full" : ""}" data-field-name="${escapeHtml(field.name)}"><span>${label}</span>${valueMarkup}</div>`;
  }

  const standardFrequencyMap = {
    "Daily": { value: 1, unit: "Day" },
    "Weekly": { value: 1, unit: "Week" },
    "Monthly": { value: 1, unit: "Month" },
    "Quarterly": { value: 3, unit: "Month" },
    "Half-Yearly": { value: 6, unit: "Month" },
    "Annual": { value: 12, unit: "Month" },
    "Event Driven": { value: "", unit: "" },
    "Continuous": { value: "", unit: "" },
    "Custom": { value: "", unit: "" }
  };

  function selectedFrequencyName(frequencyId) {
    const item = (state.lookups["frequency-master"] || []).find(option => String(option.value) === String(frequencyId || ""));
    return item?.label || "";
  }

  function frequencyIdFromName(name) {
    const item = (state.lookups["frequency-master"] || []).find(option => String(option.label || "").toLowerCase() === String(name || "").toLowerCase());
    return item?.value || "";
  }

  function updateFrequencyFields() {
    if (screen.Key !== "practice-instances") return;
    const frequencyId = fieldsHost.querySelector("[name='frequencyId']")?.value || "";
    const frequency = selectedFrequencyName(frequencyId);
    const isCustom = frequency === "Custom";
    ["frequencyValue", "frequencyUnit"].forEach(name => {
      const wrapper = fieldsHost.querySelector(`[data-field-name='${name}']`);
      const input = fieldsHost.querySelector(`[name='${name}']`);
      if (!wrapper || !input) return;
      wrapper.hidden = !isCustom;
      input.required = isCustom;
      if (!isCustom) {
        const mapped = standardFrequencyMap[frequency] || { value: "", unit: "" };
        input.value = name === "frequencyValue" ? mapped.value : mapped.unit;
      }
    });
  }

  function normalizeFrequency(data) {
    const frequency = selectedFrequencyName(data.frequencyId || data.executionFrequencyId);
    if (frequency !== "Custom") {
      const mapped = standardFrequencyMap[frequency] || { value: "", unit: "" };
      data.frequencyValue = mapped.value === "" ? "" : Number(mapped.value);
      data.frequencyUnit = mapped.unit;
      return data;
    }
    if (!String(data.frequencyValue || "").trim()) throw new Error("Frequency Value is required when Frequency is Custom.");
    if (!String(data.frequencyUnit || "").trim()) throw new Error("Frequency Unit is required when Frequency is Custom.");
    return data;
  }

  async function updateOwnerDepartment() {
    if (screen.Key !== "practice-instances") return;
    const ownerId = fieldsHost.querySelector("[name='primaryOwnerId']")?.value || "";
    let owner = lookupItemsFor("users-id").find(item => String(item.value) === String(ownerId));
    if (ownerId && (!owner?.departmentId && !owner?.departmentName)) {
      const organizationId = fieldsHost.querySelector("[name='organizationId']")?.value || currentFormOrganizationId();
      try {
        const result = await fetchJson(`${api}/users/query`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
          body: JSON.stringify({ id: Number(ownerId), data: { organizationId: organizationId ? Number(organizationId) : null, pageNumber: 1, pageSize: 1 } })
        });
        const row = apiData(result)[0] || {};
        owner = {
          ...owner,
          departmentId: String(valueOf(row, "DepartmentId") || ""),
          departmentName: valueOf(row, "DepartmentName") || valueOf(row, "Department") || ""
        };
      } catch {
        owner = owner || {};
      }
    }
    const departmentId = owner?.departmentId || "";
    const departmentName = owner?.departmentName || "";
    const departmentIdInput = fieldsHost.querySelector("[name='departmentId']");
    const departmentInput = fieldsHost.querySelector("[name='department']");
    if (departmentIdInput) departmentIdInput.value = departmentId;
    if (departmentInput) departmentInput.value = departmentName;
  }

  function optionList(items, selected) {
    const selectedText = String(selected ?? "");
    return items.map(item => `<option value="${escapeHtml(item.value)}"${String(item.value) === selectedText ? " selected" : ""}>${escapeHtml(item.label)}</option>`).join("");
  }

  function currentDependencyOrganizationId() {
    return valueOf(state.activeFormRecord, "OrganizationId")
      || valueOf(state.activeFormRecord, "organizationId")
      || state.navigationContext?.organizationId
      || organizationFilter?.value
      || "";
  }

  function dependencyPickerMarkup(row = {}, readonly = false) {
    const selectedId = valueOf(row, "DependencyReferenceId") || valueOf(row, "Reference") || "";
    const selectedLabel = valueOf(row, "Name") || "";
    const disabled = readonly ? " disabled" : "";
    return `<div class="pm-checkcombo pm-dependency-picker" data-checkcombo data-dependency-picker data-source-type="${escapeHtml(valueOf(row, "DependencySourceType"))}" data-selected-reference="${escapeHtml(selectedId)}" data-selected-label="${escapeHtml(selectedLabel)}">
      <button class="pm-checkcombo-trigger" type="button" data-checkcombo-trigger${disabled}>
        <span data-checkcombo-text>${escapeHtml(selectedLabel || "Select dependency...")}</span>
        <i class="fa-solid fa-chevron-down" aria-hidden="true"></i>
      </button>
      <div class="pm-checkcombo-menu" data-checkcombo-menu hidden>
        <input class="pm-checkcombo-search" type="search" placeholder="Search..." data-checkcombo-search>
        <div class="pm-checkcombo-options" data-dependency-options>
          <div class="pm-empty compact">Select dependency type to load records.</div>
        </div>
      </div>
    </div>`;
  }

  function normalizeDependencyOptions(result) {
    return apiData(result).map(item => ({
      value: valueOf(item, "Value") || valueOf(item, "value"),
      label: valueOf(item, "Label") || valueOf(item, "label"),
      sourceType: valueOf(item, "SourceType") || valueOf(item, "sourceType"),
      sourceTableName: valueOf(item, "SourceTableName") || valueOf(item, "sourceTableName")
    })).filter(item => item.value && item.label);
  }

  function logDependencyObjectTrace(stage, details = {}) {
    console.info(`PracticeManagement dependency objects ${stage}`, details);
  }

  function dependencyRow(row = {}, readonly = false) {
    const disabled = readonly ? " disabled" : "";
    const ownerValue = valueOf(row, "OwnerName");
    const criticalityItems = state.lookups["criticality-master"]?.length ? state.lookups["criticality-master"] : [
      { value: "1", label: "Critical" },
      { value: "2", label: "High" },
      { value: "3", label: "Medium" },
      { value: "4", label: "Low" }
    ];
    // Migration 342: the dependency's Owner column offers only Functional
    // Users (the Dependency Person picker in the previous column is
    // unaffected). The existing current-value branch below keeps a
    // non-functional stored owner visible.
    const employeeItems = lookupItemsFor("owners");
    const ownerOptions = `<option value="">Select...</option>${
      ownerValue && !employeeItems.some(item => String(item.value) === String(ownerValue))
        ? `<option value="${escapeHtml(ownerValue)}" selected>${escapeHtml(ownerValue)}</option>`
        : ""
    }${employeeItems.map(item => `<option value="${escapeHtml(item.value)}"${String(item.value) === String(ownerValue) ? " selected" : ""}>${escapeHtml(item.label)}</option>`).join("")}`;
    const statusItems = state.lookups["record-status"]?.length ? state.lookups["record-status"] : [{ value: "1", label: "Active" }, { value: "2", label: "Inactive" }];
    return `<tr data-dependency-row data-id="${escapeHtml(valueOf(row, "Id") || "")}">
      <td><select data-dependency-field="dependencyTypeId"${disabled} required>${optionList(state.lookups["dependency-types"]?.length ? state.lookups["dependency-types"] : fallbackDependencyTypes, valueOf(row, "DependencyTypeId") || "1")}</select></td>
      <td>${dependencyPickerMarkup(row, readonly)}</td>
      <td><select data-dependency-field="ownerName"${disabled}>${ownerOptions}</select></td>
      <td><select data-dependency-field="criticalityId"${disabled} required>${optionList(criticalityItems, valueOf(row, "CriticalityId") || "3")}</select></td>
      <td><select data-dependency-field="statusId"${disabled} required>${optionList(statusItems, valueOf(row, "StatusId") || "1")}</select></td>
      <td>${readonly ? "" : `<button class="pm-icon-button pm-dependency-remove" type="button" title="Remove dependency"><i class="fa-solid fa-xmark" aria-hidden="true"></i></button>`}</td>
    </tr>`;
  }

  function dependencyGridMarkup(rowsForGrid = [], readonly = false) {
    return `<section class="pm-dependency-section">
      <div class="pm-section-heading inline">
        <div>
          <h2>Dependency Capture</h2>
          <p>People, tools, assets, vendors, applications, processes, or locations required for this practice instance.</p>
        </div>
        ${readonly ? "" : `<button class="pm-button small" type="button" id="addDependencyRow"><i class="fa-solid fa-plus" aria-hidden="true"></i> Add Dependency</button>`}
      </div>
      <div class="pm-dependency-grid">
        <table>
          <thead><tr><th>Dependency Type</th><th>Dependency Name</th><th>Owner</th><th>Criticality</th><th>Status</th><th></th></tr></thead>
          <tbody id="dependencyRows">${(rowsForGrid.length ? rowsForGrid : [{}]).map(row => dependencyRow(row, readonly)).join("")}</tbody>
        </table>
      </div>
    </section>`;
  }

  async function loadDependencyOptionsForRow(row) {
    if (!row) return;
    const picker = row.querySelector("[data-dependency-picker]");
    const optionsHost = row.querySelector("[data-dependency-options]");
    const typeId = row.querySelector("[data-dependency-field='dependencyTypeId']")?.value || "";
    const organizationId = currentDependencyOrganizationId();
    const selected = new Set(String(picker?.dataset.selectedReference || "").split(",").map(item => item.trim()).filter(Boolean));
    if (!picker || !optionsHost) return;
    if (!typeId || !organizationId) {
      optionsHost.innerHTML = `<div class="pm-empty compact">Organization and dependency type are required.</div>`;
      picker.querySelector("[data-checkcombo-text]").textContent = "Select dependency...";
      logDependencyObjectTrace("blocked", { dependencyTypeId: typeId || "", organizationId: organizationId || "" });
      return;
    }
    optionsHost.innerHTML = `<div class="pm-empty compact">Dependency Objects Loading...</div>`;
    try {
      const payload = {
        organizationId: Number(organizationId),
        dependencyTypeId: Number(typeId),
        pageNumber: 1,
        pageSize: 500
      };
      logDependencyObjectTrace("request", { url: `${api}/dependency-options/query`, dependencyTypeId: payload.dependencyTypeId, organizationId: payload.organizationId, payload });
      const result = await fetchJson(`${api}/dependency-options/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          search: "",
          data: payload
        })
      });
      const tables = apiTables(result);
      const meta = (tables[1] || [])[0] || {};
      const options = normalizeDependencyOptions(result);
      logDependencyObjectTrace("response", {
        dependencyTypeId: payload.dependencyTypeId,
        organizationId: payload.organizationId,
        sourceTableName: valueOf(meta, "SourceTableName") || options[0]?.sourceTableName || "",
        recordsReturned: options.length,
        response: result
      });
      picker.dataset.sourceType = options[0]?.sourceType || picker.dataset.sourceType || "";
      optionsHost.innerHTML = options.length
        ? options.map(item => `<label data-checkcombo-option><input type="checkbox" data-dependency-reference value="${escapeHtml(item.value)}" data-label="${escapeHtml(item.label)}" data-source-type="${escapeHtml(item.sourceType || picker.dataset.sourceType || "")}"${selected.has(String(item.value)) ? " checked" : ""}> <span>${escapeHtml(item.label)}</span></label>`).join("")
        : `<div class="pm-empty compact">No dependency objects found.</div>`;
      const labels = [...optionsHost.querySelectorAll("input[type='checkbox']:checked")].map(input => input.dataset.label || input.closest("label")?.querySelector("span")?.textContent?.trim() || "");
      picker.querySelector("[data-checkcombo-text]").textContent = labels.join(", ") || picker.dataset.selectedLabel || "Select dependency...";
    } catch (error) {
      optionsHost.innerHTML = `<div class="pm-empty compact">${escapeHtml(error.message || "Unable to load dependency objects.")}</div>`;
      picker.querySelector("[data-checkcombo-text]").textContent = "Unable to load";
      console.error("PracticeManagement dependency objects error", {
        dependencyTypeId: Number(typeId),
        organizationId: Number(organizationId),
        message: error.message || String(error)
      });
    }
  }

  async function hydrateDependencyRows() {
    if (screen.Key !== "practice-instances") return;
    await Promise.all([...fieldsHost.querySelectorAll("[data-dependency-row]")].map(row => loadDependencyOptionsForRow(row)));
  }

  function evidenceRow(row = {}, readonly = false) {
    const disabled = readonly ? " disabled" : "";
    const evidenceTypes = state.lookups["evidence-types"]?.length ? state.lookups["evidence-types"] : fallbackEvidenceTypes;
    const collectionMethods = state.lookups["collection-methods"]?.length ? state.lookups["collection-methods"] : staticLookups["collection-methods"];
    const assuranceTypes = state.lookups["assurance-types"]?.length ? state.lookups["assurance-types"] : staticLookups["assurance-types"];
    const frequencies = state.lookups["frequency-master"]?.length ? state.lookups["frequency-master"] : staticLookups["frequency-master"];
    const statusItems = state.lookups["record-status"]?.length ? state.lookups["record-status"] : [{ value: "1", label: "Active" }, { value: "2", label: "Inactive" }];
    const evidenceTypeId = valueOf(row, "EvidenceTypeId") || "";
    const evidenceTypeName = valueOf(row, "EvidenceType")
      || evidenceTypes.find(item => String(item.value) === String(evidenceTypeId))?.label
      || (evidenceTypeId ? `Evidence Type #${evidenceTypeId}` : "");
    const evidenceTypeOptions = evidenceTypeId && !evidenceTypes.some(item => String(item.value) === String(evidenceTypeId))
      ? `<option value="${escapeHtml(evidenceTypeId)}" selected>${escapeHtml(evidenceTypeName)}</option>${optionList(evidenceTypes, "")}`
      : optionList(evidenceTypes, evidenceTypeId);
    const typeControl = !readonly
      ? `<select data-evidence-field="evidenceTypeId" required><option value="">Select evidence type...</option>${evidenceTypeOptions}</select>`
      : `<strong>${escapeHtml(evidenceTypeName)}</strong><input type="hidden" data-evidence-field="evidenceTypeId" value="${escapeHtml(evidenceTypeId)}">`;
    return `<tr data-evidence-row data-id="${escapeHtml(valueOf(row, "Id") || "")}">
      <td>${typeControl}</td>
      <td class="pm-check-cell"><input data-evidence-field="mandatory" type="checkbox"${boolOf(row, "Mandatory", true) ? " checked" : ""}${disabled}></td>
      <td><select data-evidence-field="assuranceTypeId"${disabled} required>${optionList(assuranceTypes, valueOf(row, "AssuranceTypeId") || "1")}</select></td>
      <td><input data-evidence-field="retentionPeriod" value="${escapeHtml(valueOf(row, "RetentionPeriod") || valueOf(row, "RetentionRequirement"))}"${disabled}></td>
      <td><select data-evidence-field="collectionMethodId"${disabled} required>${optionList(collectionMethods, valueOf(row, "CollectionMethodId") || "1")}</select></td>
      <td><select data-evidence-field="collectionFrequencyId"${disabled}>${`<option value=""></option>${optionList(frequencies, valueOf(row, "CollectionFrequencyId"))}`}</select></td>
      <td><select data-evidence-field="evidenceOwner"${disabled}>${optionsFor("owners", valueOf(row, "EvidenceOwner"))}</select></td>
      <td><span class="pm-readonly-pill muted">${escapeHtml(valueOf(row, "Status") || "Active")}</span><input type="hidden" data-evidence-field="statusId" value="${escapeHtml(valueOf(row, "StatusId") || statusItems[0]?.value || "1")}"></td>
      ${readonly ? "" : `<td><button class="pm-icon-button pm-evidence-remove" type="button" title="Remove evidence"><i class="fa-solid fa-xmark" aria-hidden="true"></i></button></td>`}
    </tr>`;
  }

  function evidenceGridMarkup(rowsForGrid = [], readonly = false, warning = "") {
    const hasRows = rowsForGrid.length > 0;
    const actionHead = readonly ? "" : "<th></th>";
    const emptyColspan = readonly ? 8 : 9;
    const emptyText = warning
      ? `Evidence could not be loaded: ${warning}`
      : "No evidence configured. Use Add New Evidence, or view obligations for framework recommendations.";
    return `<section class="pm-dependency-section">
      <div class="pm-section-heading inline">
        <div>
          <h2>Evidence Collection</h2>
          <p>Configure organization evidence manually. Use obligations as reference; alignment is calculated after save.</p>
        </div>
        <div class="pm-inline-actions">
          <button class="pm-button small" type="button" id="viewEvidenceObligations"><i class="fa-solid fa-list-check" aria-hidden="true"></i> View Obligations</button>
          ${readonly ? "" : `<button class="pm-button small" type="button" id="addEvidenceRow"><i class="fa-solid fa-plus" aria-hidden="true"></i> Add New Evidence</button>`}
        </div>
      </div>
      <div class="pm-dependency-grid">
        <table>
          <thead><tr><th>Evidence Type</th><th>Mandatory</th><th>Assurance Type</th><th>Retention Period</th><th>Collection Method</th><th>Collection Frequency</th><th>Evidence Owner</th><th>Status</th>${actionHead}</tr></thead>
          <tbody id="evidenceRows">${hasRows ? rowsForGrid.map(row => evidenceRow(row, readonly)).join("") : `<tr><td colspan="${emptyColspan}" class="pm-empty compact">${escapeHtml(emptyText)}</td></tr>`}</tbody>
        </table>
      </div>
    </section>`;
  }

  function normalizeEvidenceRows(rowsForGrid = []) {
    return rowsForGrid.map(row => ({
      Id: valueOf(row, "Id") || valueOf(row, "id"),
      PracticeInstanceId: valueOf(row, "PracticeInstanceId") || valueOf(row, "practiceInstanceId"),
      EvidenceTypeId: valueOf(row, "EvidenceTypeId") || valueOf(row, "evidenceTypeId"),
      EvidenceType: valueOf(row, "EvidenceType") || valueOf(row, "evidenceType"),
      Mandatory: boolOf(row, "Mandatory", boolOf(row, "mandatory", true)),
      AssuranceTypeId: valueOf(row, "AssuranceTypeId") || valueOf(row, "assuranceTypeId") || "1",
      AssuranceTypeName: valueOf(row, "AssuranceTypeName") || valueOf(row, "assuranceTypeName") || "",
      RetentionPeriod: valueOf(row, "RetentionPeriod") || valueOf(row, "retentionPeriod") || valueOf(row, "RetentionRequirement") || "",
      CollectionMethodId: valueOf(row, "CollectionMethodId") || valueOf(row, "collectionMethodId") || "1",
      CollectionMethod: valueOf(row, "CollectionMethod") || valueOf(row, "collectionMethod"),
      CollectionFrequencyId: valueOf(row, "CollectionFrequencyId") || valueOf(row, "collectionFrequencyId"),
      CollectionFrequency: valueOf(row, "CollectionFrequency") || valueOf(row, "collectionFrequency"),
      EvidenceOwner: valueOf(row, "EvidenceOwner") || valueOf(row, "evidenceOwner") || "",
      StatusId: valueOf(row, "StatusId") || valueOf(row, "statusId") || "1",
      Status: valueOf(row, "Status") || valueOf(row, "status") || "Active"
    }));
  }

  // =====================================================================
  // Committee Members section (migration 370, change request
  // 2026-09-22). Appended after the generic field-descriptor form for
  // the "committees" screen, the same way renderScopeChecklistSection is
  // appended for "roles" -- not a field-descriptor entry, because the
  // generic select()/text()/comboChecks() field types have no notion of
  // a repeating {employee, designation} pair. Structurally the same
  // "table of rows + Add row + data-*-row/data-*-field attributes read
  // back on submit" pattern as the Dependency Capture / Evidence
  // Collection sections on practice-instances (dependencyRow/evidenceRow
  // above) -- reused wholesale rather than inventing a new interaction
  // model, per the "reuse existing... member-selection component"
  // requirement. Read back by collectCommitteeMembers() above.
  // =====================================================================
  // Sentinel option value for "+ Add New Designation..." inside the add
  // row's Designation combo (change request 2026-09-22, revised) -- see
  // committeeMemberAddRowMarkup and the document.body "change" listener
  // a few hundred lines up that watches for it.
  const COMMITTEE_ADD_NEW_DESIGNATION_VALUE = "__add_new_designation__";

  function committeeMemberRow(row = {}, readonly = false) {
    const employeeId = String(valueOf(row, "EmployeeId") || valueOf(row, "employeeId") || "");
    const employeeLabel = valueOf(row, "Label") || valueOf(row, "label")
      || `${valueOf(row, "EmployeeCode") || ""} - ${valueOf(row, "EmployeeName") || valueOf(row, "employeeName") || ""}`.replace(/^ - /, "");
    const designationId = String(valueOf(row, "DesignationId") || valueOf(row, "designationId") || "");
    const designationItems = lookupItemsFor("committee-designations");
    return `<tr data-committee-member-row data-employee-id="${escapeHtml(employeeId)}">
      <td>${escapeHtml(employeeLabel)}</td>
      <td><select data-committee-member-field="designationId"${readonly ? " disabled" : ""} required>${optionsForInline(designationItems, designationId)}</select></td>
      <td>${readonly ? "" : `<button class="pm-icon-button pm-committee-member-remove" type="button" title="Remove member"><i class="fa-solid fa-xmark" aria-hidden="true"></i></button>`}</td>
    </tr>`;
  }

  // Designation cell (change request 2026-09-22, revised): the previous
  // revision put a second, separate .pm-icon-button "+" right beside the
  // "+ Add" button -- sir flagged the two "+"s sitting together as
  // confusing. "Add New Designation..." is now the LAST option inside the
  // Designation combo itself (COMMITTEE_ADD_NEW_DESIGNATION_VALUE), so
  // there is exactly one Add affordance in this row again. Picking it
  // opens #committeeDesignationDialog via the document.body "change"
  // listener a few lines below the existing Committee Members "click"
  // listener (same reasoning for living above the organization-workspace
  // early return, same reason it is not just a plain <option disabled>
  // separator -- it has to be a real, selectable option to fire change).
  function committeeMemberAddRowMarkup(availableEmployees, designationItems) {
    return `<tr data-committee-member-add-row>
      <td>
        <select data-committee-add-employee>
          <option value="">Select employee...</option>
          ${availableEmployees.map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")}
        </select>
      </td>
      <td>
        <select data-committee-add-designation>${optionsForInline(designationItems, "")}<option value="${COMMITTEE_ADD_NEW_DESIGNATION_VALUE}">+ Add New Designation...</option></select>
      </td>
      <td><button class="pm-button small" type="button" id="addCommitteeMemberRow"><i class="fa-solid fa-plus" aria-hidden="true"></i> Add</button></td>
    </tr>`;
  }

  // Renders the section and appends it to `host`. `members` is the array
  // sp_get_committee_member_list returns (EmployeeId/Label/DesignationId
  // shape), prefetched by the two call sites below before this runs.
  function renderCommitteeMembersSection(host, opts = {}) {
    if (!host) return;
    host.querySelector("[data-committee-members-section]")?.remove();
    const readonly = Boolean(opts.readonly);
    const members = Array.isArray(opts.members) ? opts.members : [];
    const organizationId = String(opts.organizationId || "");
    const employeeItems = organizationId
      ? lookupItemsFor("users-id").filter(item => !item.organizationId || item.organizationId === organizationId)
      : lookupItemsFor("users-id");
    const addedIds = new Set(members.map(row => String(valueOf(row, "EmployeeId") || valueOf(row, "employeeId") || "")));
    const availableEmployees = employeeItems.filter(item => !addedIds.has(String(item.value)));
    const designationItems = lookupItemsFor("committee-designations");
    const rowsMarkup = members.length
      ? members.map(row => committeeMemberRow(row, readonly)).join("")
      : `<tr><td colspan="3" class="pm-empty compact">No members added yet.</td></tr>`;
    // Add row above the list (change request 2026-09-22): kept as its own
    // small, unstyled .pm-dependency-grid table (Employee select +
    // Designation select + Add button on one line) -- same convention
    // used for every other inline "add a row" control in this codebase
    // (dependencyGridMarkup, evidenceGridMarkup above). Deliberately a
    // separate <table> from the member list below now, not a second
    // <tbody> sharing one <table>/<thead> with it: the two used to share
    // a header ("Member / Designation / ()") that only ever described the
    // list, never the add row, and splitting them is what let the list
    // move into .pm-table-wrap on its own without dragging the add row's
    // plain selects into that styling too.
    //
    // List styling (change request 2026-09-22, second revision): sir
    // pointed out this list had no header/border/stripe treatment while
    // every other list in the app (the Committees tab's own list on this
    // same screen, Resolved Dependencies, Resolve Details, etc.) uses
    // .pm-table-wrap -- bordered container, shaded <th>, zebra stripes,
    // row hover. Moved the member rows into that same component instead
    // of leaving them in the barely-styled .pm-dependency-grid, so this
    // list now matches the one styling convention the rest of the app
    // already uses everywhere. #committeeMemberRows itself, and every
    // caller that reads/appends to it (addCommitteeMemberRow's click
    // handler, refreshCommitteeMembersSection above), is untouched -- it
    // is still exactly the member rows, nothing else, just inside a
    // differently-styled wrapper.
    const markup = `<section class="pm-dependency-section" data-committee-members-section>
      <div class="pm-section-heading inline">
        <div>
          <h2>Committee Members</h2>
          <p>Members of this Committee and their Designation. The same person can hold a different Designation on another Committee.</p>
        </div>
      </div>
      ${readonly ? "" : `<div class="pm-dependency-grid">
        <table>
          <tbody>${committeeMemberAddRowMarkup(availableEmployees, designationItems)}</tbody>
        </table>
      </div>`}
      <div class="pm-table-wrap compact">
        <table>
          <thead><tr><th>Member</th><th>Designation</th><th>Action</th></tr></thead>
          <tbody id="committeeMemberRows">${rowsMarkup}</tbody>
        </table>
      </div>
    </section>`;
    host.insertAdjacentHTML("beforeend", markup);
  }

  // Re-derives the member list from whatever [data-committee-member-row]
  // rows are currently in the DOM (so an in-progress Designation edit on
  // an existing row is not lost) and re-renders the whole section --
  // simplest way to keep the Add row's employee options (must exclude
  // already-added members) and the member table in sync after an add,
  // a remove, or a newly-created Designation.
  function refreshCommitteeMembersSection() {
    if (!fieldsHost) return;
    const members = [...fieldsHost.querySelectorAll("[data-committee-member-row]")].map(row => ({
      EmployeeId: row.dataset.employeeId || "",
      Label: row.querySelector("td")?.textContent || "",
      DesignationId: row.querySelector("[data-committee-member-field='designationId']")?.value || ""
    }));
    renderCommitteeMembersSection(fieldsHost, {
      organizationId: currentFormOrganizationId(),
      members,
      readonly: state.mode === "view"
    });
  }

  function schemaFor(mode, record) {
    if (screen.Key === "organization-controls" && mode === "applicability") {
      return [
        text("code", "Control Code", false, { readonly: true }),
        text("name", "Control Name", false, { readonly: true }),
        select("applicabilityStatus", "Applicability Status", "applicability-status", true),
        select("primaryOwner", "Primary Owner", "owners"),
        select("secondaryOwner", "Secondary Owner", "owners"),
        select("businessFunctionId", "Business Function", "business-functions"),
        select("criticality", "Criticality", "criticality", true),
        area("exclusionJustification", "Justification / Reason")
      ];
    }
    if (screen.Key === "organization-requirements" && mode === "applicability") {
      // hidden("organizationId") is required -- sp_manage_organization_requirement
      // throws 51035 "Organization is required." when the POST body has no
      // organizationId field. valueOf(record, "organizationId") reads
      // record.OrganizationId (PascalCase from the /query API) via the
      // fallback in valueOf(), so no extra plumbing needed.
      return [
        hidden("organizationId"),
        text("code", "Practice Code", false, { readonly: true }),
        text("name", "Practice Name", false, { readonly: true }),
        select("applicabilityStatus", "Applicability Status", "applicability-status", true, { restrictTo: PRACTICE_APPLICABILITY_STATUSES }),
        select("practiceOwnerId", "Owner", "owners-id"),
        area("exclusionJustification", "Reason / Justification")
      ];
    }
    if (screen.Key === "practices" && mode === "applicability") {
      // Same reason as organization-requirements above -- sp_manage_practice
      // throws 51028 "Organization is required." without organizationId in the
      // POST body. This was reported by users on the 3-dot menu > Mark
      // Applicability save.
      return [
        hidden("organizationId"),
        text("code", "Practice Code", false, { readonly: true }),
        text("name", "Practice Name", false, { readonly: true }),
        select("applicabilityStatus", "Applicability Status", "applicability-status", true, { restrictTo: PRACTICE_APPLICABILITY_STATUSES }),
        select("practiceOwnerId", "Owner", "owners-id"),
        area("exclusionJustification", "Reason / Justification")
      ];
    }
    if (screen.Key === "organization-requirements" && mode === "add") {
      // Custom Practice Code Auto Generation (change request): Practice Code
      // is generated by pm_manage_practice_repository's organization-requirements
      // branch as PR_001, PR_002, ... and is never taken from the create
      // payload for a new custom practice. "code" is left out of this
      // Add-mode schema entirely -- not just hidden -- so collectForm() has
      // no [name="code"] input to read and the create request never carries
      // a Practice Code (requirements 1, 5 and 6 of the change request).
      // Edit/View are untouched: they still fall through to the default
      // "organization-requirements" schema above, which keeps the code
      // field, per the change request's own note to scope this to creation
      // only and not touch existing Practice functionality.
      return [
        select("organizationId", "Organization", "organizations", true),
        hidden("originType"),
        hidden("applicabilityStatus"),
        hidden("status"),
        hidden("implementationStatus"),
        text("name", "Practice Name", true),
        area("statement", "Description"),
        select("practiceOwnerId", "Owner", "owners-id"),
        select("businessFunctionId", "Business Function", "business-functions"),
        select("criticality", "Criticality", "criticality"),
        area("remarks", "Remarks")
      ];
    }
    if (screen.Key === "practices" && mode === "add") {
      // Same reasoning as the organization-requirements add branch above --
      // "code" is generated by pm_manage_practice_repository's practices
      // branch and left out of this Add-mode schema entirely.
      return [
        select("organizationId", "Organization", "organizations", true),
        hidden("organizationRequirementId"),
        hidden("originType"),
        hidden("applicabilityStatus"),
        hidden("status"),
        text("name", "Practice Name", true),
        area("description", "Description"),
        select("practiceOwnerId", "Owner", "owners-id"),
        select("businessFunctionId", "Business Function", "business-functions"),
        select("criticality", "Criticality", "criticality"),
        area("remarks", "Remarks")
      ];
    }
    // Practice Instance EDIT — stage 1. Derived from the one shared
    // schema rather than restated, so a field added to the list above
    // reaches this form too and only the named exceptions differ.
    //
    // Scoped to "edit", not "not add": in view mode these are not inputs,
    // they are read-only facts about the instance, and hiding them there
    // would remove information rather than remove data entry. The grid
    // (PracticeScreen.cs) shows the same four columns for the same reason.
    if (isFormFor("practice-instances") && mode === "edit") {
      return entitySchema("practice-instances", mode)
        .filter(field => !practiceInstanceDroppedOnEdit.has(field.name))
        .map(field => practiceInstanceHiddenOnEdit.has(field.name) ? hidden(field.name) : field);
    }
    return entitySchema(formEntity(), mode);
  }

  // opts.entity opens the form for an entity other than this screen's
  // own; opts.seed pre-populates it. Both default to today's behaviour,
  // so every existing openForm(mode, id) call is unaffected.
  async function openForm(mode, id = 0, opts = {}) {
    state.mode = mode;
    state.id = id;
    state.formEntity = opts.entity || screen.Key;
    formMessage.hidden = true;
    const readonly = mode === "view";
    // Seeded BEFORE the per-screen defaults below, so those can still
    // override or complete it -- the seed says where the form came from,
    // not what every field must be.
    let record = Object.assign({}, opts.seed || {});
    let dependencies = [];
    let evidence = [];
    let evidenceWarning = "";
    if (id) {
      const result = await fetchJson(`${api}/${screen.Key}/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id, contextCode: state.navigationCode, data: { pageNumber: 1, pageSize: 1 } })
      });
      record = apiData(result)[0] || state.records.find(row => String(valueOf(row, "Id")) === String(id)) || {};
      if (isFormFor("practice-instances")) {
        state.activeFormRecord = record;
        const dependencyContextCode = await createPracticeInstanceChildContext(id, "dependencies");
        const dependencyResult = await fetchJson(`${api}/dependencies/query`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
          body: JSON.stringify({ contextCode: dependencyContextCode, data: { pageNumber: 1, pageSize: 200 } })
        });
        dependencies = apiData(dependencyResult);
        const evidenceContextCode = await createPracticeInstanceChildContext(id, "evidence-configurations");
        const evidenceResult = await fetchJson(`${api}/evidence-configurations/query`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
          body: JSON.stringify({ contextCode: evidenceContextCode, data: { pageNumber: 1, pageSize: 200 } })
        });
        evidence = normalizeEvidenceRows(apiData(evidenceResult));
      }
      // Team Members prefill (migration 362, change request 2026-09-20):
      // sp_org_team_list is deliberately left untouched (it feeds the Teams
      // grid and must keep working even if 362 has not been applied), so
      // the currently-selected members are read separately here, the same
      // way practice-instances' dependencies/evidence are fetched and
      // merged onto record above. Feeds both Edit's pre-checked tree and
      // View's disabled-but-checked one; a fetch failure (362 not deployed)
      // just leaves record.memberIds empty rather than breaking the form.
      if (screen.Key === "teams") {
        try {
          const memberResult = await fetchJson(`${api}/team-members/query`, {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
            body: JSON.stringify({ id, data: { pageNumber: 1, pageSize: 2000 } })
          });
          record.memberIds = apiData(memberResult).map(row => String(valueOf(row, "EmployeeId"))).filter(Boolean);
        } catch {
          record.memberIds = record.memberIds || [];
        }
      }
      // Committee Members prefill (migration 370, change request
      // 2026-09-22): same "read the separate shim, don't touch the grid
      // query" reasoning as Team Members above. record.members carries
      // the full row shape (EmployeeId/Label/DesignationId) so
      // renderCommitteeMembersSection can render it directly without a
      // second lookup join.
      if (screen.Key === "committees") {
        try {
          const memberResult = await fetchJson(`${api}/committee-members/query`, {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
            body: JSON.stringify({ id, data: { pageNumber: 1, pageSize: 2000 } })
          });
          record.members = apiData(memberResult);
        } catch {
          record.members = record.members || [];
        }
      }
      // Update Applicability prefill for Practices (organization-requirements):
      // the requirements grid read returns the linked practice's owner but not
      // its exclusion justification, so the saved Reason came back blank. The
      // owner and reason both live on the linked practice row, which the
      // `practices` read does return -- pull them from there so Update
      // Applicability opens fully pre-filled. Silent-fail: if the practice
      // cannot be read the fields simply stay blank, as before.
      if (mode === "applicability" && screen.Key === "organization-requirements") {
        const practiceId = valueOf(record, "PracticeId");
        if (practiceId) {
          try {
            const practiceResult = await fetchJson(`${api}/practices/query`, {
              method: "POST",
              headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
              body: JSON.stringify({ id: Number(practiceId), data: { pageNumber: 1, pageSize: 1 } })
            });
            const practiceRow = apiData(practiceResult)[0];
            if (practiceRow) {
              if (!String(valueOf(record, "ExclusionJustification") || "").trim())
                record.ExclusionJustification = valueOf(practiceRow, "ExclusionJustification");
              if (!String(valueOf(record, "PracticeOwnerId") || "").trim())
                record.PracticeOwnerId = valueOf(practiceRow, "PracticeOwnerId");
              if (!String(valueOf(record, "PracticeOwner") || "").trim())
                record.PracticeOwner = valueOf(practiceRow, "PracticeOwner");
            }
          } catch (_) { /* leave prefill blank if the practice cannot be read */ }
        }
      }
      // Owner dropdown is keyed on employee_id, but a practice's owner is
      // often stored only as a name (practice_owner_id is NULL, practice_owner
      // holds the name). In that case the id-based select had nothing to
      // select and opened blank. Resolve the owner NAME back to its employee
      // id from the users-id lookup (labels are "CODE - Name"), so the
      // dropdown pre-selects the saved owner. Applies to both applicability
      // screens; only runs when we don't already have an id.
      if (mode === "applicability" && (screen.Key === "organization-requirements" || screen.Key === "practices")
          && !String(valueOf(record, "PracticeOwnerId") || "").trim()) {
        const ownerName = String(valueOf(record, "PracticeOwner") || "").trim().toLowerCase();
        if (ownerName) {
          const src = state.lookups["users-id"] || [];
          const namePart = label => {
            const parts = String(label || "").split(" - ");
            return parts[parts.length - 1].trim().toLowerCase();
          };
          const match = src.find(item => String(item.label || "").trim().toLowerCase() === ownerName)
            || src.find(item => namePart(item.label) === ownerName)
            || src.find(item => String(item.label || "").trim().toLowerCase().endsWith(ownerName));
          if (match) record.PracticeOwnerId = match.value;
        }
      }
    }
    if (!id && screen.Key === "organization-controls" && organizationFilter?.value) {
      record.organizationId = organizationFilter.value;
      record.OrganizationId = organizationFilter.value;
      record.status = "Active";
      record.Status = "Active";
    }
    if (!id && screen.Key === "organization-requirements") {
      record.organizationId = organizationFilter?.value || state.navigationContext?.organizationId || "";
      record.OrganizationId = record.organizationId;
      record.originType = "Organization";
      record.OriginType = "Organization";
      record.applicabilityStatus = "Applicable";
      record.ApplicabilityStatus = "Applicable";
      record.implementationStatus = "Not Started";
      record.ImplementationStatus = "Not Started";
      record.status = "Active";
      record.Status = "Active";
      record.criticality = "Medium";
      record.Criticality = "Medium";
    }
    if (!id && screen.Key === "practices") {
      record.organizationId = organizationFilter?.value || state.navigationContext?.organizationId || "";
      record.OrganizationId = record.organizationId;
      record.originType = "Organization";
      record.OriginType = "Organization";
      record.applicabilityStatus = "Applicable";
      record.ApplicabilityStatus = "Applicable";
      record.status = "Active";
      record.Status = "Active";
      record.criticality = "Medium";
      record.Criticality = "Medium";
    }
    if (!id && screen.Key === "practice-instances" && ["Practice", "OrganizationRequirement"].includes(state.navigationContext?.filterType || "")) {
      if (state.navigationContext.filterType === "Practice") {
        record.practiceId = state.navigationContext.filterId;
        record.PracticeId = state.navigationContext.filterId;
        record.organizationRequirementId = state.navigationContext.organizationRequirementId || "";
        record.OrganizationRequirementId = record.organizationRequirementId;
      } else {
        record.organizationRequirementId = state.navigationContext.filterId;
        record.OrganizationRequirementId = state.navigationContext.filterId;
      }
      record.organizationId = state.navigationContext.organizationId || organizationFilter?.value || "";
      record.OrganizationId = record.organizationId;
      record.assuranceMode = "Manual";
      record.AssuranceMode = "Manual";
      record.criticality = "Medium";
      record.Criticality = "Medium";
      record.status = "Active";
      record.Status = "Active";
    }
    if (isFormFor("practice-instances") && !valueOf(record, "frequencyId") && valueOf(record, "FrequencyType")) {
      record.frequencyId = frequencyIdFromName(valueOf(record, "FrequencyType"));
      record.FrequencyId = record.frequencyId;
    }
    if (isFormFor("practice-instances")) {
      record.primaryOwnerId = valueOf(record, "PrimaryOwnerId") || valueOf(record, "primaryOwnerId") || "";
      record.departmentId = valueOf(record, "DepartmentId") || valueOf(record, "departmentId") || "";
      record.executionFrequencyId = valueOf(record, "ExecutionFrequencyId") || valueOf(record, "executionFrequencyId") || valueOf(record, "FrequencyId") || valueOf(record, "frequencyId") || "";
      record.assuranceFrequencyId = valueOf(record, "AssuranceFrequencyId") || valueOf(record, "assuranceFrequencyId") || "";
      record.dependencyTypeIds = [...new Set(dependencies.map(row => valueOf(row, "DependencyTypeId")).filter(Boolean).map(String))];
      record.evidenceTypeIds = [...new Set(evidence.map(row => valueOf(row, "EvidenceTypeId")).filter(Boolean).map(String))];
    }
    state.activeFormRecord = record;
    state.activeDependencies = dependencies;
    state.activeEvidence = evidence;
    const schema = schemaFor(mode, record);
    const alreadyMarked = String(valueOf(record, "ApplicabilityStatus") || "Not Updated").trim().toLowerCase() !== "not updated";
    const titlePrefix = mode === "add" ? "Add" : mode === "edit" ? "Edit" : mode === "applicability" ? (alreadyMarked ? "Update Applicability" : "Mark Applicability") : "View";
    document.querySelector("#dialogTitle").textContent = screen.Key === "organization-controls" && mode === "add"
      ? "Add Release"
      : (screen.Key === "organization-requirements" || screen.Key === "practices") && mode === "add"
        ? "Add Practice"
        : `${titlePrefix} ${screen.Title}`;
    // Location's View page (change request 2026-09-20): render plain
    // label/value boxes instead of disabled form controls, matching
    // Organization Administration's read-only layout. Scoped to
    // screen.Key === "locations" && mode === "view" only -- every other
    // screen sharing this same render call (organizations, departments,
    // teams, users, and the rest of the ~30 forms using #recordDialog)
    // keeps rendering through fieldMarkup exactly as before.
    const useLocationViewLayout = screen.Key === "locations" && mode === "view";
    fieldsHost.innerHTML = schema.length
      ? `${schema.map(field => useLocationViewLayout
          ? viewFieldMarkup(field, valueOf(record, field.name), record)
          : fieldMarkup(field, valueOf(record, field.name), readonly)).join("")}`
      : `<p class="pm-empty">This screen is planned for the next implementation phase.</p>`;
    updateFrequencyFields();
    applyConditionalFields();
    applyApplicabilityReasonLock(mode);

    // Role Master owns the People side of event checklist mapping: the role
    // is the thing being scoped, so the mapping belongs on its own form
    // rather than on a screen the user has to know to visit separately.
    //
    // Deliberately not awaited, matching renderInlineObligationsSection
    // below: the section makes two HTTP calls per event, and the dialog must
    // not sit blank waiting for them. It fills in once loaded.
    if (screen.Key === "roles") {
      renderScopeChecklistSection(fieldsHost, {
        organizationId: valueOf(record, "organizationId")
                        || fieldsHost.querySelector("[name='organizationId']")?.value,
        scopeDimension: "ORG_ROLE",
        scopeValueId:   valueOf(record, "id") || valueOf(record, "roleId"),
        title:          "Event Checklists for this Role",
        subtitle:       "What has to be done when somebody joins this role, and when they leave it."
      });
    }

    // Committee Members section (migration 370, change request
    // 2026-09-22). Appended the same way as the roles checklist section
    // above -- record.members is prefetched from committee-members below
    // (see the "Committee Members prefill" block), same convention as
    // Team Members' record.memberIds prefill.
    if (screen.Key === "committees") {
      renderCommitteeMembersSection(fieldsHost, {
        organizationId: valueOf(record, "organizationId") || fieldsHost.querySelector("[name='organizationId']")?.value,
        members: record.members || [],
        readonly
      });
    }

    // Source Statement mapping picker (Organization Requirements Add/Edit
    // only -- the function itself no-ops and clears any stale section for
    // every other screen/mode). Not awaited, same as the roles checklist
    // section and the inline obligations panel below: it makes several
    // HTTP calls and the dialog must not sit blank waiting for them.
    renderStatementMappingSection(record, mode, id);

    if (isFormFor("practice-instances")) await updateOwnerDepartment();
    // Practice Instance view/edit/add flows show a read-only reference
    // panel with the parent Practice's framework obligations. Async load,
    // silent-fail -- the panel never blocks the form.
    if (isFormFor("practice-instances")) {
      renderInlineObligationsSection(record);
    }
    saveButton.hidden = readonly || !schema.length;
    // View -> Edit (change request 2026-09-20): same gating as the
    // setup-child dialog's editButton.hidden above -- View mode, one of
    // the three entities in VIEW_EDIT_ENTITIES, and Edit/Add permission,
    // matching the standalone screens' own "edit" 3-dot action check in
    // allowedActions().
    if (editButton) editButton.hidden = !(readonly && VIEW_EDIT_ENTITIES.has(screen.Key) && (permissions.has("EDIT") || permissions.has("ADD")));
    // Add/Edit Practice grew a Source Statement mapping picker (change
    // request 2026-09-16) that needs real room -- the shared #recordDialog
    // element is reused by ~30 other entity forms, so this widens it only
    // for this one screen and these two modes via a modifier class rather
    // than changing dialog's own default sizing (control-management.css).
    // Cleared for every other screen/mode so the dialog snaps back to its
    // normal size the next time it opens for anything else.
    const isFullpage = screen.Key === "organization-requirements" && (mode === "add" || mode === "edit");
    dialog.classList.toggle("pm-dialog-fullpage", isFullpage);

    // Location Add/Edit/View (layout compaction, 2026-09-20) -- 3-column
    // field grid instead of the shared 2-column default (see
    // .pm-form-grid-locations in practice-management.css). Scoped to this
    // one screen and cleared for every other one, same as isFullpage above,
    // so #recordFields snaps back to its normal 2-column layout the next
    // time it opens for anything else.
    fieldsHost.classList.toggle("pm-form-grid-locations", screen.Key === "locations");

    // showModal() vs show(): sizing the dialog to sit beside the sidebar
    // and below the topbar (practice-management.css's pm-dialog-fullpage
    // rules) made the master layout VISIBLE again, but its icons and menu
    // links stayed unclickable -- "master page nte icons onnum click
    // cheyyan pattunnilla". That was never the ::backdrop (already
    // pointer-events:none): showModal() puts <dialog> in the browser's
    // top layer and makes EVERYTHING else in the document inert -- not
    // just visually covered but excluded from hit-testing and focus --
    // for as long as the dialog is open. That's baked into what "modal"
    // means natively and no CSS on the backdrop can undo it. show()
    // opens the dialog WITHOUT that modal state: no top-layer promotion,
    // no inert page, no native backdrop at all -- exactly what "fit the
    // master page and let it stay usable" needs. Scoped to isFullpage
    // only; every other one of the ~30 forms sharing #recordDialog keeps
    // showModal() and its normal modal behaviour untouched.
    if (isFullpage) {
      if (!dialog.__fullpageEscapeBound) {
        dialog.__fullpageEscapeBound = true;
        // showModal() closes on Escape natively; show() does not, so
        // that has to be re-added by hand for this case only -- guarded
        // on isFullpage so it never double-closes a showModal() dialog,
        // which already handles Escape itself.
        dialog.addEventListener("keydown", event => {
          if (event.key === "Escape" && dialog.classList.contains("pm-dialog-fullpage")) {
            event.preventDefault();
            dialog.close();
          }
        });
      }
      // View -> Edit (change request 2026-09-20): show() on an
      // already-open <dialog> is a no-op error-wise (unlike showModal()
      // below), but guarding both the same way keeps the two branches
      // symmetric and makes the reopen-while-open intent explicit.
      if (!dialog.open) dialog.show();
    } else {
      // Reopening on an already-open dialog (View -> Edit clicked without
      // closing first) would throw "already has an 'open' attribute" on
      // showModal() -- guard it the same way the setup-child dialog does.
      if (!dialog.open) dialog.showModal();
    }
  }

  function collectForm() {
    const data = {};
    let valid = true;
    fieldsHost.querySelectorAll("[name]").forEach(input => {
      input.classList.remove("field-error");
      if (input.required && !input.value.trim()) {
        input.classList.add("field-error");
        valid = false;
      }
      if (input.type === "checkbox" && input.closest("[data-checkcombo]")) {
        const list = data[input.name] ||= [];
        if (input.checked) list.push(input.value);
      } else if (input.type === "checkbox") {
        data[input.name] = input.checked;
      } else {
        data[input.name] = input.type === "number" && input.value !== "" ? Number(input.value) : input.value;
      }
    });
    if (!valid) throw new Error("Please complete the required fields.");
    // Status is not on the Add form for these screens (see
    // statusHiddenOnAddScreens). Send it explicitly rather than leaning on the
    // stored procedure's default. 'Active' works for both field spellings:
    // pm_manage_practice_repository resolves $.status against
    // record_status_master by status_code OR status_name, so the statusId-based
    // entities land on the right record_status_id too.
    // state.formEntity, not screen.Key: on the Organization Setup page screen.Key
    // is "organization-setup" while the dialog is editing a child entity.
    // saveForm() resolves the POST target the same way.
    if (state.mode === "add" && statusHiddenOnAddScreens.has(state.formEntity || screen.Key)) data.status ||= "Active";
    if (screen.Key === "organization-controls" && state.mode === "add") {
      data.applicabilityStatus = "Not Updated";
      data.originType = "Organization";
      data.isManuallyAdded = true;
      data.criticality ||= "Medium";
      data.status ||= "Active";
    }
    if (screen.Key === "organization-requirements" && state.mode === "add") {
      data.originType = "Organization";
      data.repositoryRequirementId = "";
      data.organizationControlId = "";
      data.applicabilityStatus = "Applicable";
      data.exclusionJustification = "";
      data.implementationStatus ||= "Not Started";
      data.status = "Active";
    }
    if (screen.Key === "practices" && state.mode === "add") {
      data.organizationRequirementId = "";
      data.originType = "Organization";
      data.applicabilityStatus = "Applicable";
      data.exclusionJustification = "";
      data.status = "Active";
    }
    if ((screen.Key === "control-applicability" || (screen.Key === "organization-controls" && state.mode === "applicability")) && ["Not Applicable", "Deferred", "Accepted Risk"].includes(data.applicabilityStatus) && !String(data.exclusionJustification || "").trim()) {
      const input = fieldsHost.querySelector("[name='exclusionJustification']");
      input?.classList.add("field-error");
      throw new Error("Justification is required when applicability is Not Applicable, Deferred, or Accepted Risk.");
    }
    if (screen.Key === "organization-controls" && state.mode === "applicability" && data.applicabilityStatus === "Applicable") {
      if (!String(data.primaryOwner || "").trim()) {
        fieldsHost.querySelector("[name='primaryOwner']")?.classList.add("field-error");
        throw new Error("Primary Owner is required when control is Applicable.");
      }
      if (!String(data.criticality || "").trim()) {
        fieldsHost.querySelector("[name='criticality']")?.classList.add("field-error");
        throw new Error("Criticality is required when control is Applicable.");
      }
    }
    if ((screen.Key === "organization-requirements" || screen.Key === "practices") && state.mode === "applicability") {
      if (["Not Applicable", "Deferred", "Accepted Risk"].includes(data.applicabilityStatus) && !String(data.exclusionJustification || "").trim()) {
        fieldsHost.querySelector("[name='exclusionJustification']")?.classList.add("field-error");
        throw new Error("Reason / Justification is required when applicability is Not Applicable, Deferred, or Accepted Risk.");
      }
    }
    if (["organization-requirements", "practices"].includes(screen.Key) && data.applicabilityStatus === "Applicable" && !String(data.practiceOwnerId || "").trim()) {
      fieldsHost.querySelector("[name='practiceOwnerId']")?.classList.add("field-error");
      throw new Error("Owner is required when practice is Applicable.");
    }
    if (isSourceStatements && state.mode === "statementApplicability") {
      if (["Applicable", "Not Applicable"].includes(data.applicabilityStatus) && !String(data.ownerId || "").trim()) {
        fieldsHost.querySelector("[name='ownerId']")?.classList.add("field-error");
        throw new Error("Owner is required when the statement is Applicable or Not Applicable.");
      }
      if (data.applicabilityStatus === "Not Applicable" && !String(data.exclusionJustification || "").trim()) {
        fieldsHost.querySelector("[name='exclusionJustification']")?.classList.add("field-error");
        throw new Error("Reason / Justification is required when the statement is Not Applicable.");
      }
    }
    if (isFormFor("practice-instances")) normalizeFrequency(data);
    if (state.formEntity === "custom-statement") {
      data.statementAction = state.mode === "editCustomStatement" ? "EDIT" : "ADD";
    }
    // Source Statement mapping picker. Only sent once it has successfully
    // loaded this practice's current mappings (Edit) or has nothing to
    // load (Add) -- see seedStatementMappingSelection / seedOk. If the
    // picker never reached a known-good state (e.g. its seed fetch failed,
    // or the user saved before it finished loading), the field is left off
    // the payload entirely so 002's save proc leaves existing mappings
    // untouched instead of wiping them out.
    if (screen.Key === "organization-requirements" && (state.mode === "add" || state.mode === "edit") && statementMappingState.seedOk) {
      data.mappedOrgStatementIds = [...statementMappingState.selected].map(Number);
    }
    return data;
  }

  // Committee Members (migration 370, change request 2026-09-22): reads
  // the row list rendered by renderCommitteeMembersSection back into
  // [{ employeeId, designationId }], the shape sp_org_committee_save's
  // @p_payload.members expects. Same "read data-*-field attributes off
  // each [data-*-row]" pattern as collectDependencies()/collectEvidence()
  // below, not the generic name-based collectForm() loop -- a plain
  // name="members" checkbox/array cannot carry a second value (the
  // designation) per selection.
  function collectCommitteeMembers() {
    if (screen.Key !== "committees" && state.formEntity !== "committees") return undefined;
    const rows = [];
    fieldsHost.querySelectorAll("[data-committee-member-row]").forEach(row => {
      const employeeId = row.dataset.employeeId || "";
      const designationSelect = row.querySelector("[data-committee-member-field='designationId']");
      const designationId = designationSelect ? designationSelect.value : "";
      if (employeeId && designationId) rows.push({ employeeId: Number(employeeId), designationId: Number(designationId) });
    });
    return rows;
  }

  function collectDependencies() {
    if (screen.Key !== "practice-instances") return { rows: [], removedIds: [] };
    const selectedTypeIds = new Set((fieldsHost.querySelectorAll("[name='dependencyTypeIds']:checked") ? [...fieldsHost.querySelectorAll("[name='dependencyTypeIds']:checked")] : []).map(input => String(input.value)));
    if (selectedTypeIds.size || fieldsHost.querySelector("[name='dependencyTypeIds']")) {
      const rowsToSave = [];
      const activeExistingIds = new Set();
      selectedTypeIds.forEach(typeId => {
        const existing = state.activeDependencies.find(row => String(valueOf(row, "DependencyTypeId")) === String(typeId) && !valueOf(row, "DependencyReferenceId"));
        if (existing && valueOf(existing, "Id")) activeExistingIds.add(String(valueOf(existing, "Id")));
        rowsToSave.push({
          id: existing ? Number(valueOf(existing, "Id") || 0) : 0,
          dependencyTypeId: typeId,
          dependencyReferenceId: null,
          sourceType: "",
          name: "",
          ownerName: "",
          criticalityId: "",
          statusId: "1"
        });
      });
      const removedIds = state.activeDependencies
        .filter(row => !valueOf(row, "DependencyReferenceId"))
        .map(row => String(valueOf(row, "Id") || ""))
        .filter(id => id && !activeExistingIds.has(id));
      return { rows: rowsToSave, removedIds };
    }
    const activeIds = new Set();
    const rowsToSave = [];
    let valid = true;
    fieldsHost.querySelectorAll("[data-dependency-row]").forEach(row => {
      const id = row.dataset.id || "";
      const dependency = { id: id ? Number(id) : 0 };
      row.querySelectorAll("[data-dependency-field]").forEach(input => {
        input.classList.remove("field-error");
        dependency[input.dataset.dependencyField] = input.value;
      });
      const picker = row.querySelector("[data-dependency-picker]");
      const selectedReferences = [...row.querySelectorAll("[data-dependency-reference]:checked")].map(input => ({
        id: input.value,
        label: input.dataset.label || input.closest("label")?.querySelector("span")?.textContent?.trim() || "",
        sourceType: input.dataset.sourceType || picker?.dataset.sourceType || ""
      }));
      const hasAnyValue = Boolean(dependency.id) || selectedReferences.length > 0 || Boolean(String(dependency.ownerName || "").trim());
      if (hasAnyValue) {
        row.querySelectorAll("[data-dependency-field]").forEach(input => {
          if (input.required && !input.value.trim()) {
            input.classList.add("field-error");
            valid = false;
          }
        });
        picker?.querySelector("[data-checkcombo-trigger]")?.classList.remove("field-error");
        if (!selectedReferences.length) {
          picker?.querySelector("[data-checkcombo-trigger]")?.classList.add("field-error");
          valid = false;
        }
        if (dependency.id) activeIds.add(String(dependency.id));
        selectedReferences.forEach((reference, index) => {
          rowsToSave.push({
            ...dependency,
            id: index === 0 ? dependency.id : 0,
            dependencyReferenceId: reference.id,
            name: reference.label,
            sourceType: reference.sourceType
          });
        });
      }
    });
    if (!valid) throw new Error("Please complete required dependency fields.");
    const removedIds = state.activeDependencies
      .map(row => String(valueOf(row, "Id") || ""))
      .filter(id => id && !activeIds.has(id));
    return { rows: rowsToSave, removedIds };
  }

  function collectEvidence() {
    if (screen.Key !== "practice-instances") return { rows: [], removedIds: [] };
    // "The form does not mention evidence" and "the user cleared every
    // evidence row" are different things, and the two branches below
    // cannot tell them apart: with no evidenceTypeIds control and no
    // [data-evidence-row] markup, the row branch finds nothing, so every
    // id in state.activeEvidence lands in removedIds and the save retires
    // the instance's entire evidence configuration.
    //
    // Stage 1 drops the control from the edit form, so this stopped being
    // hypothetical. A form with no evidence input at all now means "leave
    // evidence alone", which is the only defensible reading.
    const hasEvidenceInput = Boolean(fieldsHost.querySelector("[name='evidenceTypeIds'], [data-evidence-row]"));
    if (!hasEvidenceInput) return { rows: [], removedIds: [] };
    const selectedEvidenceTypeIds = new Set((fieldsHost.querySelectorAll("[name='evidenceTypeIds']:checked") ? [...fieldsHost.querySelectorAll("[name='evidenceTypeIds']:checked")] : []).map(input => String(input.value)));
    if (selectedEvidenceTypeIds.size || fieldsHost.querySelector("[name='evidenceTypeIds']")) {
      const rowsToSave = [];
      const activeExistingIds = new Set();
      selectedEvidenceTypeIds.forEach(typeId => {
        const existing = state.activeEvidence.find(row => String(valueOf(row, "EvidenceTypeId")) === String(typeId));
        if (existing && valueOf(existing, "Id")) activeExistingIds.add(String(valueOf(existing, "Id")));
        rowsToSave.push({
          id: existing ? Number(valueOf(existing, "Id") || 0) : 0,
          evidenceTypeId: typeId,
          mandatory: true,
          collectionMethodId: "",
          collectionFrequencyId: "",
          evidenceOwner: "",
          statusId: "1"
        });
      });
      const removedIds = state.activeEvidence
        .map(row => String(valueOf(row, "Id") || ""))
        .filter(id => id && !activeExistingIds.has(id));
      return { rows: rowsToSave, removedIds };
    }
    const activeIds = new Set();
    const rowsToSave = [];
    let valid = true;
    fieldsHost.querySelectorAll("[data-evidence-row]").forEach(row => {
      const id = row.dataset.id || "";
      const evidence = { id: id ? Number(id) : 0 };
      row.querySelectorAll("[data-evidence-field]").forEach(input => {
        input.classList.remove("field-error");
        evidence[input.dataset.evidenceField] = input.type === "checkbox" ? input.checked : input.value;
      });
      const hasAnyValue = Boolean(evidence.id) || Boolean(String(evidence.evidenceTypeId || "").trim());
      if (hasAnyValue) {
        row.querySelectorAll("[data-evidence-field]").forEach(input => {
          if (input.required && !input.value.trim()) {
            input.classList.add("field-error");
            valid = false;
          }
        });
        if (evidence.id) activeIds.add(String(evidence.id));
        rowsToSave.push(evidence);
      }
    });
    if (!valid) throw new Error("Please complete required evidence fields.");
    const removedIds = state.activeEvidence
      .map(row => String(valueOf(row, "Id") || ""))
      .filter(id => id && !activeIds.has(id));
    return { rows: rowsToSave, removedIds };
  }

  async function saveDependencies(practiceInstanceId, organizationId, dependencyState) {
    if (screen.Key !== "practice-instances") return;
    const contextCode = await createPracticeInstanceChildContext(practiceInstanceId, "dependencies");
    for (const dependency of dependencyState.rows) {
      await fetchJson(`${api}/dependencies`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          id: dependency.id || 0,
          contextCode,
          data: {
            organizationId,
            dependencyTypeId: dependency.dependencyTypeId ? Number(dependency.dependencyTypeId) : null,
            dependencyReferenceId: dependency.dependencyReferenceId ? Number(dependency.dependencyReferenceId) : null,
            sourceType: dependency.sourceType || "",
            name: dependency.name,
            ownerName: dependency.ownerName || "",
            criticalityId: dependency.criticalityId ? Number(dependency.criticalityId) : null,
            statusId: dependency.statusId ? Number(dependency.statusId) : null
          }
        })
      });
    }
    for (const id of dependencyState.removedIds) {
      await fetchJson(`${api}/dependencies/retire`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id: Number(id) })
      });
    }
  }

  async function saveEvidence(practiceInstanceId, organizationId, evidenceState) {
    if (screen.Key !== "practice-instances") return;
    if (!evidenceState.rows.length && !evidenceState.removedIds.length) return;
    const contextCode = await createPracticeInstanceChildContext(practiceInstanceId, "evidence-configurations");
    for (const evidence of evidenceState.rows) {
      await fetchJson(`${api}/evidence-configurations`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          id: evidence.id || 0,
          contextCode,
          data: {
            organizationId,
            evidenceTypeId: evidence.evidenceTypeId ? Number(evidence.evidenceTypeId) : null,
            mandatory: Boolean(evidence.mandatory),
            assuranceTypeId: evidence.assuranceTypeId ? Number(evidence.assuranceTypeId) : null,
            retentionPeriod: evidence.retentionPeriod || "",
            collectionMethodId: evidence.collectionMethodId ? Number(evidence.collectionMethodId) : null,
            collectionFrequencyId: evidence.collectionFrequencyId ? Number(evidence.collectionFrequencyId) : null,
            evidenceOwner: evidence.evidenceOwner || "",
            statusId: evidence.statusId ? Number(evidence.statusId) : null
          }
        })
      });
    }
    for (const id of evidenceState.removedIds) {
      await fetchJson(`${api}/evidence-configurations/retire`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id: Number(id) })
      });
    }
  }

  async function loadEvidenceForInstance(practiceInstanceId) {
    const contextCode = await createPracticeInstanceChildContext(practiceInstanceId, "evidence-configurations");
    const evidenceResult = await fetchJson(`${api}/evidence-configurations/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ contextCode, data: { pageNumber: 1, pageSize: 200 } })
    });
    return normalizeEvidenceRows(apiData(evidenceResult));
  }

  function formatPopupRows(title, rowsForPopup, columns, emptyMessage) {
    if (!rowsForPopup.length) return `${title}\n\n${emptyMessage}`;
    const lines = rowsForPopup.map(row => columns.map(column => `${column.label}: ${valueOf(row, column.name) || "-"}`).join("\n")).join("\n\n");
    return `${title}\n\n${lines}`;
  }

  function obligationValue(row, name) {
    return valueOf(row, name) || "";
  }

  // ------------------------------------------------------------------
  // Obligation taxonomy (Phase 2F) helpers.
  //
  // The API now serves obligations via /evidence-obligations-typed/query
  // (backed by dbo.sp_pm_view_obligations_typed).  That SP returns ONE
  // row per obligation with typed detail as JSON arrays -- fewer rows,
  // richer per-row shape.  The existing modal and inline-panel renderers
  // group by (FrameworkRelease, ObligationId) and expect one row per
  // obligation-evidence pair, so we expand the typed shape back into
  // "flat" rows here and carry the typed metadata columns forward on
  // each row.  Downstream card renderers get an extra TypeCode/TypeName
  // + per-type detail arrays without any grouping changes.
  // ------------------------------------------------------------------
  function safeParseJsonArray(text) {
    if (Array.isArray(text)) return text;
    if (!text || typeof text !== "string") return [];
    try { const value = JSON.parse(text); return Array.isArray(value) ? value : []; }
    catch { return []; }
  }

  function expandTypedObligationRows(typedRows) {
    if (!Array.isArray(typedRows)) return [];
    const expanded = [];
    typedRows.forEach(t => {
      const evidences = safeParseJsonArray(t.EvidenceJson || t.evidenceJson);
      const baseColumns = {
        // Preserve keys used by the existing grouping/search logic.
        FrameworkReleaseId: t.FrameworkReleaseId,
        FrameworkRelease: t.FrameworkRelease,
        ObligationId: t.ObligationId,
        ObligationName: t.ObligationName,
        ExecutionFrequency: t.ExecutionFrequency,
        ObligationRetention: t.ObligationRetention,
        ApprovalAuthority: t.ApprovalAuthority,
        Responsibility: t.Responsibility,
        // New taxonomy-typed columns, carried on every expanded row.
        ObligationTypeId: t.ObligationTypeId,
        TypeCode: t.TypeCode,
        TypeName: t.TypeName,
        StateRulesJson: t.StateRulesJson,
        ExecutionSpecsJson: t.ExecutionSpecsJson,
        AssuranceSpecsJson: t.AssuranceSpecsJson,
        EventResponsesJson: t.EventResponsesJson,
        ConstraintRulesJson: t.ConstraintRulesJson,
        RetentionSpecsJson: t.RetentionSpecsJson,
        EvidenceJson: t.EvidenceJson
      };
      if (!evidences.length) {
        // Obligation with no evidence -- keep a bare row so it still
        // renders as a card in the modal / inline panel.
        expanded.push(baseColumns);
        return;
      }
      evidences.forEach(ev => {
        expanded.push({
          ...baseColumns,
          ObligationEvidenceId: ev.ObligationEvidenceId,
          EvidenceTypeId: ev.EvidenceTypeId,
          EvidenceType: ev.EvidenceType,
          FrequencyId: ev.FrequencyId,
          Frequency: ev.Frequency,
          RetentionRequirement: ev.RetentionRequirement,
          Remarks: ev.Remarks,
          EvidenceSource: ev.Source,       // 'Direct' | 'Link'
          EvidenceLinkTypeCode: ev.LinkTypeCode
        });
      });
    });
    return expanded;
  }

  // Returns HTML for a Type badge + per-type detail block for one
  // obligation card.  Reads TypeCode from the row and parses the
  // matching *Json column.  Returns "" when the obligation is
  // un-typed (pre-taxonomy) so the card degrades cleanly.
  function renderTypedObligationDetail(row) {
    const typeCode = obligationValue(row, "TypeCode");
    if (!typeCode) return "";
    const typeName = obligationValue(row, "TypeName") || typeCode;
    const badgeClass = `pm-obligation-type-badge pm-obligation-type-${typeCode.toLowerCase()}`;
    let detailHtml = "";
    if (typeCode === "State") {
      const rules = safeParseJsonArray(row.StateRulesJson);
      detailHtml = rules.map(r => `<div class="pm-typed-detail-row">
          <strong>${escapeHtml(r.attribute || "")}</strong>
          <span class="pm-typed-op">${escapeHtml(r.operator || "")}</span>
          <span class="pm-typed-value">${escapeHtml(r.value || "")}${r.unit ? " " + escapeHtml(r.unit) : ""}</span>
          ${r.tolerance ? `<em title="Tolerance">&plusmn;${escapeHtml(r.tolerance)}</em>` : ""}
        </div>`).join("");
    } else if (typeCode === "Execution") {
      const specs = safeParseJsonArray(row.ExecutionSpecsJson);
      detailHtml = specs.map(s => `<div class="pm-typed-detail-row">
          <strong>${escapeHtml(s.action || "")}</strong>
          ${s.ExecutionFrequency ? `<span>${escapeHtml(s.ExecutionFrequency)}</span>` : ""}
          ${s.responsible_party ? `<em>${escapeHtml(s.responsible_party)}</em>` : ""}
          ${s.due_within ? `<span>Due: ${escapeHtml(s.due_within)}</span>` : ""}
        </div>`).join("");
    } else if (typeCode === "Assurance") {
      const specs = safeParseJsonArray(row.AssuranceSpecsJson);
      detailHtml = specs.map(s => `<div class="pm-typed-detail-row">
          <strong>${escapeHtml(s.verification_method || "")}</strong>
          ${s.scope ? `<span>${escapeHtml(s.scope)}</span>` : ""}
          ${s.AssuranceFrequency ? `<span>${escapeHtml(s.AssuranceFrequency)}</span>` : ""}
          ${s.assurance_party ? `<em>${escapeHtml(s.assurance_party)}</em>` : ""}
        </div>`).join("");
    } else if (typeCode === "EventResponse") {
      const specs = safeParseJsonArray(row.EventResponsesJson);
      detailHtml = specs.map(s => `<div class="pm-typed-detail-row">
          <strong>If:</strong> ${escapeHtml(s.trigger_event || "")}
          <strong>Then:</strong> ${escapeHtml(s.response_action || "")}
          ${s.SlaValue ? `<span>within ${escapeHtml(String(s.SlaValue))} ${escapeHtml(s.SlaUnit || "")}</span>` : ""}
          ${s.escalation_path ? `<em>Escalate: ${escapeHtml(s.escalation_path)}</em>` : ""}
        </div>`).join("");
    } else if (typeCode === "Constraint") {
      const rules = safeParseJsonArray(row.ConstraintRulesJson);
      detailHtml = rules.map(r => `<div class="pm-typed-detail-row">
          <strong>MUST NOT:</strong> ${escapeHtml(r.prohibited_condition || "")}
          ${r.scope ? `<span>Scope: ${escapeHtml(r.scope)}</span>` : ""}
          ${r.exception_policy ? `<em>Exception: ${escapeHtml(r.exception_policy)}</em>` : ""}
        </div>`).join("");
    } else if (typeCode === "Retention") {
      const specs = safeParseJsonArray(row.RetentionSpecsJson);
      detailHtml = specs.map(s => `<div class="pm-typed-detail-row">
          <strong>${escapeHtml(s.retained_object || "")}</strong>
          ${s.MinRetentionValue ? `<span>min ${escapeHtml(String(s.MinRetentionValue))} ${escapeHtml(s.MinRetentionUnit || "")}</span>` : ""}
          ${s.MaxRetentionValue ? `<span>max ${escapeHtml(String(s.MaxRetentionValue))} ${escapeHtml(s.MaxRetentionUnit || "")}</span>` : ""}
          ${s.disposal_policy ? `<em>Disposal: ${escapeHtml(s.disposal_policy)}</em>` : ""}
        </div>`).join("");
    }
    // Evidence-type obligations use the standard evidence subgrid --
    // no separate typed-detail section needed.  Just show the badge.
    return `<div class="pm-typed-detail">
        <span class="${badgeClass}">${escapeHtml(typeName)}</span>
        ${detailHtml ? `<div class="pm-typed-detail-body">${detailHtml}</div>` : ""}
      </div>`;
  }

  function filteredObligationRows() {
    const filters = state.obligationFilters || {};
    const term = String(filters.search || "").trim().toLowerCase();
    const searchKeys = ["ObligationName", "ExecutionFrequency", "EvidenceType", "Frequency", "RetentionRequirement", "ObligationRetention", "ApprovalAuthority", "Remarks", "FrameworkRelease"];
    return [...(state.obligationRows || [])]
      .filter(row => !term || searchKeys.some(key => String(obligationValue(row, key)).toLowerCase().includes(term)))
      .sort((a, b) => String(obligationValue(a, "FrameworkRelease")).localeCompare(String(obligationValue(b, "FrameworkRelease")), undefined, { sensitivity: "base" })
        || String(obligationValue(a, "ObligationName")).localeCompare(String(obligationValue(b, "ObligationName")), undefined, { sensitivity: "base" })
        || String(obligationValue(a, "EvidenceType")).localeCompare(String(obligationValue(b, "EvidenceType")), undefined, { sensitivity: "base" }));
  }

  function renderObligationModalRows() {
    const modal = document.querySelector("#obligationReferenceModal");
    if (!modal) return;
    const rowsToRender = filteredObligationRows();
    const count = modal.querySelector("[data-obligation-count]");
    if (count) count.textContent = `${rowsToRender.length} of ${state.obligationRows.length} record${state.obligationRows.length === 1 ? "" : "s"}`;
    const body = modal.querySelector("[data-obligation-body]");
    if (!body) return;
    if (!rowsToRender.length) {
      body.innerHTML = `<div class="pm-obligation-empty">No obligation recommendations configured for this requirement.</div>`;
      return;
    }
    // Group: Framework Release -> Obligation -> Evidence rows.
    const groups = new Map();
    rowsToRender.forEach(row => {
      const release = obligationValue(row, "FrameworkRelease") || "Framework Release";
      if (!groups.has(release)) groups.set(release, new Map());
      const obligations = groups.get(release);
      const key = String(obligationValue(row, "ObligationId") || obligationValue(row, "ObligationName") || obligationValue(row, "EvidenceType"));
      if (!obligations.has(key)) obligations.set(key, {
        name: obligationValue(row, "ObligationName"),
        executionFrequency: obligationValue(row, "ExecutionFrequency"),
        retention: obligationValue(row, "ObligationRetention") || obligationValue(row, "RetentionRequirement"),
        approvalAuthority: obligationValue(row, "ApprovalAuthority"),
        responsibility: obligationValue(row, "Responsibility"),
        typedRow: row,                         // full typed row for renderTypedObligationDetail
        evidence: []
      });
      const evidenceType = obligationValue(row, "EvidenceType");
      if (evidenceType) obligations.get(key).evidence.push({
        type: evidenceType,
        frequency: obligationValue(row, "Frequency"),
        retention: obligationValue(row, "RetentionRequirement"),
        remarks: obligationValue(row, "Remarks"),
        source: obligationValue(row, "EvidenceSource"),      // 'Direct' | 'Link'
        linkTypeCode: obligationValue(row, "EvidenceLinkTypeCode")
      });
    });
    const metaChip = (label, value) => value
      ? `<span class="pm-obligation-chip"><em>${escapeHtml(label)}</em>${escapeHtml(value)}</span>`
      : "";
    body.innerHTML = [...groups.entries()].map(([release, obligations]) => {
      const collapsed = state.obligationCollapsed.has(release);
      const cards = [...obligations.values()].map(ob => `<article class="pm-obligation-card">
          <h4>${escapeHtml(ob.name || "Obligation")}</h4>
          ${renderTypedObligationDetail(ob.typedRow || {})}
          <div class="pm-obligation-meta">
            ${metaChip("Execution Frequency", ob.executionFrequency)}
            ${metaChip("Assurance / Evidence Frequency", ob.evidence.map(ev => ev.frequency).filter(Boolean).filter((v, i, all) => all.indexOf(v) === i).join(", "))}
            ${metaChip("Retention", ob.retention)}
            ${metaChip("Approval Authority", ob.approvalAuthority)}
            ${metaChip("Responsibility", ob.responsibility)}
          </div>
          ${ob.evidence.length ? `<div class="pm-obligation-evidence">
            <span class="pm-obligation-evidence-title">Evidence</span>
            ${ob.evidence.map(ev => `<div class="pm-obligation-evidence-row">
              <strong>${escapeHtml(ev.type || "-")}</strong>
              <span title="Frequency">${escapeHtml(ev.frequency || "-")}</span>
              <span title="Retention">${escapeHtml(ev.retention || "-")}</span>
              ${ev.source === "Link" && ev.linkTypeCode ? `<span class="pm-typed-src" title="Attached via ${escapeHtml(ev.linkTypeCode)} link table">via ${escapeHtml(ev.linkTypeCode)}</span>` : ""}
              ${ev.remarks ? `<em title="${escapeHtml(ev.remarks)}">${escapeHtml(ev.remarks)}</em>` : ""}
            </div>`).join("")}
          </div>` : ""}
        </article>`).join("");
      return `<section class="pm-obligation-group${collapsed ? " collapsed" : ""}">
        <button type="button" class="pm-obligation-group-toggle" data-obligation-release-toggle="${escapeHtml(release)}" aria-expanded="${!collapsed}">
          <i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}" aria-hidden="true"></i>
          <span>${escapeHtml(release)}</span>
          <em>${obligations.size} obligation${obligations.size === 1 ? "" : "s"}</em>
        </button>
        ${collapsed ? "" : `<div class="pm-obligation-group-body">${cards}</div>`}
      </section>`;
    }).join("");
  }

  function openObligationModal(rowsForModal, context = {}) {
    state.obligationRows = rowsForModal || [];
    state.obligationFilters = { search: "" };
    state.obligationCollapsed = new Set();
    state.obligationContext = context;
    document.querySelector("#obligationReferenceModal")?.remove();
    const practiceList = context.practiceList || [];
    const currentPracticeId = String(context.practiceId || "");
    const practiceName = context.practiceName || "";
    const organizationName = context.organizationName || "";
    const practiceOptions = practiceList.length
      ? practiceList.map(p => `<option value="${escapeHtml(p.id)}"${p.id === currentPracticeId ? " selected" : ""}>${escapeHtml(p.name || p.id)}</option>`).join("")
      : (currentPracticeId ? `<option value="${escapeHtml(currentPracticeId)}" selected>${escapeHtml(practiceName || currentPracticeId)}</option>` : "");
    const contextHeader = (practiceName || organizationName)
      ? `<div class="pm-obligation-context">${practiceName ? `<span><em>Practice:</em> ${escapeHtml(practiceName)}</span>` : ""}${organizationName ? `<span><em>Organization:</em> ${escapeHtml(organizationName)}</span>` : ""}</div>`
      : "";
    document.body.insertAdjacentHTML("beforeend", `<dialog class="pm-obligation-dialog" id="obligationReferenceModal" aria-labelledby="obligationReferenceTitle">
      <div class="pm-obligation-modal">
        <header class="pm-obligation-header">
          <div>
            <h2 id="obligationReferenceTitle">View Obligations</h2>
            ${contextHeader}
            <p>Reference-only obligation recommendations from subscribed framework releases.</p>
          </div>
          <span data-obligation-count class="pm-obligation-count"></span>
          <button type="button" class="pm-modal-close" data-close-obligation-modal aria-label="Close"><i class="fa-solid fa-xmark"></i></button>
        </header>
        <div class="pm-obligation-toolbar">
          <label><span>Practice</span>
            <select data-obligation-filter="practice">
              ${practiceOptions}
            </select>
          </label>
          <label class="grow"><span>Search</span>
            <input type="search" data-obligation-filter="search" placeholder="Search obligations, evidence, frequency, retention...">
          </label>
        </div>
        <div data-obligation-body class="pm-obligation-body"></div>
      </div>
    </dialog>`);
    const modal = document.querySelector("#obligationReferenceModal");
    modal?.addEventListener("close", () => modal.remove(), { once: true });
    /* Practice filter change → reload obligations for the selected practice */
    const practiceSelect = modal?.querySelector("[data-obligation-filter='practice']");
    if (practiceSelect) {
      practiceSelect.addEventListener("change", async () => {
        const selectedId = practiceSelect.value;
        if (!selectedId) return;
        const body = modal.querySelector("[data-obligation-body]");
        if (body) body.innerHTML = `<div class="pm-obligation-empty">Loading obligations...</div>`;
        try {
          await showEvidenceObligations(state.obligationContext?.contextRecord || null, selectedId);
        } catch (error) {
          if (body) body.innerHTML = `<div class="pm-obligation-empty">${escapeHtml(error.message || "Failed to load obligations.")}</div>`;
        }
      });
    }
    modal?.showModal();
    renderObligationModalRows();
  }

  async function showEvidenceObligations(contextRecord = null, overridePracticeId = null) {
    const record = contextRecord || state.activeFormRecord || {};
    const navigation = state.navigationContext || {};
    const formOrganizationRequirementId = fieldsHost?.querySelector("[name='organizationRequirementId']")?.value || "";
    const formPracticeId = fieldsHost?.querySelector("[name='practiceId']")?.value || "";
    const formOrganizationId = fieldsHost?.querySelector("[name='organizationId']")?.value || "";
    const organizationRequirementId = overridePracticeId ? "" : (
      valueOf(record, "organizationRequirementId")
      || valueOf(record, "OrganizationRequirementId")
      || formOrganizationRequirementId
      || (screen.Key === "organization-requirements" ? valueOf(record, "Id") : "")
      || (navigation.filterType === "OrganizationRequirement" ? navigation.filterId : "")
      || navigation.organizationRequirementId
      || "");
    const practiceId = overridePracticeId || valueOf(record, "practiceId")
      || valueOf(record, "PracticeId")
      || formPracticeId
      || (navigation.filterType === "Practice" ? navigation.filterId : "")
      || "";
    const organizationId = valueOf(record, "organizationId")
      || valueOf(record, "OrganizationId")
      || formOrganizationId
      || navigation.organizationId
      || organizationFilter?.value
      || "";
    const practiceName = valueOf(record, "Name") || valueOf(record, "name") || valueOf(record, "RequirementName") || navigation.displayName || "";
    const organizationName = state.obligationContext?.organizationName
      || (organizationFilter?.selectedOptions?.[0]?.text || "")
      || "";
    const data = {
      organizationId: organizationId || undefined,
      practiceInstanceId: isFormFor("practice-instances") && state.id ? state.id : undefined,
      practiceId: practiceId || undefined,
      organizationRequirementId: organizationRequirementId || undefined,
      pageNumber: 1,
      pageSize: 200
    };
    if (!data.practiceInstanceId && !data.practiceId && !data.organizationRequirementId) {
      throw new Error("Requirement context is required to view obligation recommendations.");
    }
    const result = await fetchJson(`${api}/evidence-obligations-typed/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data })
    });
    // Typed endpoint returns one row per obligation with EvidenceJson;
    // expand back to the flat "one row per obligation-evidence" shape
    // the modal renderer already knows how to group.  Extra TypeCode
    // + *Json columns ride along on each expanded row.
    const obligationRows = expandTypedObligationRows(apiData(result));
    /* Build practice list for the filter dropdown from the current grid rows */
    const practiceList = (state.records || [])
      .filter(r => valueOf(r, "Id") || valueOf(r, "PracticeId"))
      .map(r => ({
        id: String(valueOf(r, "Id") || valueOf(r, "PracticeId") || ""),
        name: valueOf(r, "Name") || valueOf(r, "RequirementName") || valueOf(r, "Code") || ""
      }))
      .filter((v, i, all) => v.id && all.findIndex(x => x.id === v.id) === i);
    const context = {
      practiceId: practiceId || organizationRequirementId || "",
      practiceName,
      organizationId,
      organizationName,
      practiceList,
      contextRecord: record
    };
    openObligationModal(obligationRows, context);
  }

  // ------------------------------------------------------------------
  // Inline "Parent Practice Obligations" reference panel.
  // Rendered directly inside the Practice Instance view/edit/add form,
  // right below the schema fields. Reuses the /evidence-obligations/query
  // endpoint (which already accepts practiceInstanceId + practiceId +
  // organizationRequirementId as scoping keys) and the pm-obligation-*
  // CSS classes from the modal so we don't fork the visual language.
  //
  // Read-only by design -- the user asked for "just show, for reference
  // only". Any error (missing context, empty result set, network fail)
  // degrades to a short muted message instead of a red banner so it
  // never blocks the actual form.
  // ------------------------------------------------------------------
  // ==================================================================
  // Scope checklist editor -- implementation lives in
  // wwwroot/js/scope-checklist-editor.js.
  //
  // It is a separate file because Manage.cshtml renders workflow-layer
  // screens through their own partial and RETURNS before this file's script
  // tag. The Asset Category Assurance screen is one of those, so an editor
  // defined in here would be unreachable from it. These wrappers keep the
  // call sites below unchanged and fail quietly if the module is absent --
  // a missing editor must not take the whole form down.
  // ==================================================================
  async function renderScopeChecklistSection(host, opts) {
    if (!window.__scopeChecklistEditor) {
      console.warn("scope-checklist-editor.js is not loaded; the event checklist section is unavailable.");
      return;
    }
    return window.__scopeChecklistEditor.render(host, opts);
  }

  async function flushPendingScopeChecklists(scopeValueId) {
    if (!window.__scopeChecklistEditor) return { saved: 0, failed: 0 };
    return window.__scopeChecklistEditor.flushPending(scopeValueId);
  }

  function scopeMsg(container, text, kind) {
    const el = container?.querySelector("[data-scope-message]");
    if (!el) return;
    if (!text) { el.style.display = "none"; el.textContent = ""; return; }
    el.style.display = "block"; el.textContent = text;
    if (kind === "error")   { el.style.background = "#fee2e2"; el.style.color = "#7f1d1d"; }
    else if (kind === "ok") { el.style.background = "#dcfce7"; el.style.color = "#166534"; }
    else                    { el.style.background = "#dbeafe"; el.style.color = "#1e40af"; }
  }

  async function renderInlineObligationsSection(record) {
    if (!fieldsHost) return;
    // Nuke any previous inline section so re-opens don't stack.
    fieldsHost.querySelector("[data-inline-obligations]")?.remove();

    const container = document.createElement("section");
    container.className = "pm-inline-obligations";
    container.setAttribute("data-inline-obligations", "1");
    container.innerHTML = `
      <div class="pm-inline-obligations-header">
        <div>
          <h3>Parent Practice Obligations</h3>
          <p>Framework recommendations for the practice this instance belongs to. Reference only.</p>
        </div>
        <span data-inline-obligations-count class="pm-obligation-count"></span>
      </div>
      <div data-inline-obligations-body class="pm-inline-obligations-body">
        <div class="pm-obligation-empty">Loading obligations...</div>
      </div>`;
    fieldsHost.appendChild(container);

    const body = container.querySelector("[data-inline-obligations-body]");
    const countEl = container.querySelector("[data-inline-obligations-count]");

    // Resolve the three scoping keys the same way showEvidenceObligations
    // does. Prefer the concrete record (from /practice-instances/query)
    // over the loose form/nav context because on Edit the record has the
    // authoritative practiceId + organizationId.
    const navigation = state.navigationContext || {};
    const formPracticeId = fieldsHost.querySelector("[name='practiceId']")?.value || "";
    const formOrgId = fieldsHost.querySelector("[name='organizationId']")?.value || "";
    const formOrgReqId = fieldsHost.querySelector("[name='organizationRequirementId']")?.value || "";
    const practiceInstanceId = isFormFor("practice-instances") && state.id ? state.id : undefined;
    const practiceId = valueOf(record, "practiceId")
      || valueOf(record, "PracticeId")
      || formPracticeId
      || (navigation.filterType === "Practice" ? navigation.filterId : "")
      || "";
    const organizationRequirementId = valueOf(record, "organizationRequirementId")
      || valueOf(record, "OrganizationRequirementId")
      || formOrgReqId
      || (navigation.filterType === "OrganizationRequirement" ? navigation.filterId : "")
      || navigation.organizationRequirementId
      || "";
    const organizationId = valueOf(record, "organizationId")
      || valueOf(record, "OrganizationId")
      || formOrgId
      || navigation.organizationId
      || organizationFilter?.value
      || "";

    // If we don't yet know which practice this instance belongs to (e.g.
    // Add flow with no navigation context), quietly hide the section
    // rather than throwing -- the user hasn't chosen a parent yet.
    if (!practiceInstanceId && !practiceId && !organizationRequirementId) {
      container.hidden = true;
      return;
    }

    try {
      const result = await fetchJson(`${api}/evidence-obligations-typed/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          data: {
            organizationId: organizationId || undefined,
            practiceInstanceId: practiceInstanceId || undefined,
            practiceId: practiceId || undefined,
            organizationRequirementId: organizationRequirementId || undefined,
            pageNumber: 1,
            pageSize: 200
          }
        })
      });
      // Expand typed rows into per-evidence rows so the same grouping
      // logic used by the modal works here.
      const rowsForInline = expandTypedObligationRows(apiData(result));
      if (!rowsForInline.length) {
        body.innerHTML = `<div class="pm-obligation-empty">No obligation recommendations configured for this practice.</div>`;
        if (countEl) countEl.textContent = "0";
        return;
      }
      if (countEl) countEl.textContent = `${rowsForInline.length} record${rowsForInline.length === 1 ? "" : "s"}`;

      // Group by framework release, then by obligation -- same shape the
      // modal uses (see renderObligationModalRows) so the compact card
      // reads the same way in both places.
      const groups = new Map();
      rowsForInline.forEach(row => {
        const release = obligationValue(row, "FrameworkRelease") || "Framework Release";
        if (!groups.has(release)) groups.set(release, new Map());
        const obligations = groups.get(release);
        const key = String(obligationValue(row, "ObligationId") || obligationValue(row, "ObligationName") || obligationValue(row, "EvidenceType"));
        if (!obligations.has(key)) obligations.set(key, {
          name: obligationValue(row, "ObligationName"),
          executionFrequency: obligationValue(row, "ExecutionFrequency"),
          retention: obligationValue(row, "ObligationRetention") || obligationValue(row, "RetentionRequirement"),
          approvalAuthority: obligationValue(row, "ApprovalAuthority"),
          responsibility: obligationValue(row, "Responsibility"),
          typedRow: row,                     // for renderTypedObligationDetail
          evidence: []
        });
        const evidenceType = obligationValue(row, "EvidenceType");
        if (evidenceType) obligations.get(key).evidence.push({
          type: evidenceType,
          frequency: obligationValue(row, "Frequency"),
          retention: obligationValue(row, "RetentionRequirement"),
          remarks: obligationValue(row, "Remarks"),
          source: obligationValue(row, "EvidenceSource"),
          linkTypeCode: obligationValue(row, "EvidenceLinkTypeCode")
        });
      });

      const chip = (label, value) => value
        ? `<span class="pm-obligation-chip"><em>${escapeHtml(label)}</em>${escapeHtml(value)}</span>`
        : "";
      body.innerHTML = [...groups.entries()].map(([release, obligations]) => {
        const cards = [...obligations.values()].map(ob => `<article class="pm-obligation-card">
          <header class="pm-obligation-card-header"><h4>${escapeHtml(ob.name || "Obligation")}</h4></header>
          ${renderTypedObligationDetail(ob.typedRow || {})}
          <div class="pm-obligation-meta">
            ${chip("Execution", ob.executionFrequency)}
            ${chip("Retention", ob.retention)}
            ${chip("Approval", ob.approvalAuthority)}
            ${chip("Responsibility", ob.responsibility)}
          </div>
          ${ob.evidence.length ? `<div class="pm-obligation-evidence">
            <span class="pm-obligation-evidence-title">Evidence</span>
            ${ob.evidence.map(ev => `<div class="pm-obligation-evidence-row">
              <strong>${escapeHtml(ev.type)}</strong>
              ${chip("Freq", ev.frequency)}
              ${chip("Retention", ev.retention)}
              ${ev.source === "Link" && ev.linkTypeCode ? `<span class="pm-typed-src" title="Attached via ${escapeHtml(ev.linkTypeCode)} link table">via ${escapeHtml(ev.linkTypeCode)}</span>` : ""}
              ${ev.remarks ? `<span class="pm-obligation-remarks">${escapeHtml(ev.remarks)}</span>` : ""}
            </div>`).join("")}
          </div>` : ""}
        </article>`).join("");
        return `<section class="pm-obligation-group">
          <header class="pm-obligation-group-header">
            <strong>${escapeHtml(release)}</strong>
            <em>${obligations.size} obligation${obligations.size === 1 ? "" : "s"}</em>
          </header>
          <div class="pm-obligation-cards">${cards}</div>
        </section>`;
      }).join("");
    } catch (error) {
      // Soft-fail: don't block the form. Reference panel is optional.
      body.innerHTML = `<div class="pm-obligation-empty">Obligations reference unavailable: ${escapeHtml(error.message || error)}</div>`;
      if (countEl) countEl.textContent = "";
    }
  }

  // --- Source Statement mapping picker on the Add/Edit Practice form ---
  // (Organization Requirements screen, change request 2026-09-16/17). Same
  // "extra section appended into fieldsHost, filled in async" pattern as
  // renderInlineObligationsSection above.
  //
  // A real collapsible tree, not a flat list -- the reference for this is
  // the existing "Practices - Statement Mapping" screen in the separate
  // ControlManagement admin app (Repository/Index/source-control-mappings,
  // repository.js: buildTree/flattenTree/renderMappingTree). That screen
  // has no separate framework/release picker either -- every subscribed
  // framework's structure sits in ONE tree, with each framework's own root
  // node as a top-level branch, so this mirrors that instead of asking the
  // user to pick a release first: every subscribed release is fetched up
  // front and combined into one tree, each release wrapped in its own
  // synthetic root node (id `rel-<releaseId>`) so a Framework's identity is
  // just the top branch you expand, not a separate control.
  //
  // `selected` is the FULL desired mapping set (org_statement_id strings)
  // for the practice being added/edited right now, seeded from the server
  // on Edit. Because every release is loaded into the one combined tree,
  // there's no "mapped in a release you're not currently viewing" case
  // left to account for -- everything the practice is mapped to is always
  // visible in the Mapped pane, under its own release branch.
  const statementMappingState = {
    selected: new Set(),
    releases: [],
    rowsByRelease: new Map(),  // releaseId -> rows from release-statements/query, all loaded up front
    collapsed: new Set(),      // "rel-<id>"/"sn-<id>" ids currently collapsed in both trees
    leftChecked: new Set(),    // "fs-<orgStatementId>" ticked in Unmapped, pending "Map ->"
    rightChecked: new Set(),   // "fs-<orgStatementId>" ticked in Mapped, pending "<- Remove"
    seedOk: false
  };

  function resetStatementMappingState() {
    statementMappingState.selected = new Set();
    statementMappingState.releases = [];
    statementMappingState.rowsByRelease = new Map();
    statementMappingState.collapsed = new Set();
    statementMappingState.leftChecked = new Set();
    statementMappingState.rightChecked = new Set();
    statementMappingState.seedOk = false;
  }

  // Returns false on failure without throwing -- the caller treats that as
  // "don't touch this practice's mappings on save" (see collectForm),
  // which is the only safe response to not knowing what is already mapped.
  async function seedStatementMappingSelection(organizationRequirementId) {
    try {
      const result = await fetchJson(`${api}/practice-statement-mappings/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ data: { organizationRequirementId: Number(organizationRequirementId) } })
      });
      apiData(result).forEach(row => {
        const orgStatementId = String(valueOf(row, "OrgStatementId") || "");
        if (orgStatementId) statementMappingState.selected.add(orgStatementId);
      });
      return true;
    } catch (error) {
      console.error("PracticeManagement statement mapping seed failed", error);
      return false;
    }
  }

  // Same shape as ControlManagement's repository.js buildTree/flattenTree,
  // generalized to plain {Id, ParentNodeId, DisplayOrder, Reference} records
  // so both the Unmapped and Mapped trees can reuse it.
  function buildStatementMapTree(records) {
    const map = new Map(records.map(row => [String(row.Id), { row, children: [] }]));
    const roots = [];
    map.forEach(node => {
      const parentId = String(node.row.ParentNodeId || "");
      if (parentId && map.has(parentId) && parentId !== String(node.row.Id)) map.get(parentId).children.push(node);
      else roots.push(node);
    });
    const sortItems = items => {
      items.sort((a, b) => Number(a.row.DisplayOrder || 0) - Number(b.row.DisplayOrder || 0)
        || String(a.row.Reference || "").localeCompare(String(b.row.Reference || ""), undefined, { numeric: true }));
      items.forEach(item => sortItems(item.children));
    };
    sortItems(roots);
    return roots;
  }
  function flattenStatementMapTree(records, collapsedSet) {
    const output = [];
    const walk = (items, depth) => items.forEach(item => {
      output.push({ row: item.row, depth, hasChildren: item.children.length > 0 });
      if (!collapsedSet.has(String(item.row.Id))) walk(item.children, depth + 1);
    });
    walk(buildStatementMapTree(records), 0);
    return output;
  }
  function includeStatementMapAncestors(records, ids) {
    const byId = new Map(records.map(row => [String(row.Id), row])), keep = new Set(ids);
    ids.forEach(id => {
      let current = byId.get(String(id));
      while (current?.ParentNodeId) {
        keep.add(String(current.ParentNodeId));
        current = byId.get(String(current.ParentNodeId));
      }
    });
    return records.filter(row => keep.has(String(row.Id)));
  }
  // release-statements/query returns Node + Statement rows scoped to one
  // release/organization. Every subscribed release loaded so far
  // (statementMappingState.rowsByRelease) is combined into ONE record set
  // here: each release gets its own synthetic root (`rel-<releaseId>`,
  // __kind "release") labelled with the release's own name, and that
  // release's top-level Source Structure nodes are reparented onto it --
  // so the Framework/Release sits inside the tree itself instead of behind
  // a separate selector. Source Structure node ids are prefixed with the
  // release id so two releases can't collide onto the same tree node even
  // if they happen to share underlying structure ids; org statement ids
  // (`fs-<id>`) are already unique per organization and stay bare, since
  // the "fs-" prefix length is relied on elsewhere (leftChecked/rightChecked
  // use id.slice(3) to recover the bare org_statement_id).
  //
  // A statement with no OrgStatementId has never been touched by this
  // organization (Mark Applicability on Source Statements creates it) and
  // can't be mapped from here, so it's left out entirely rather than shown
  // disabled.
  // A stable per-release key for rowsByRelease and tree node ids. Repository
  // releases key on ReleaseId; custom releases have no repository ReleaseId, so
  // they key on their subscription (c<SubscriptionId>).
  function mapReleaseKey(release) {
    if (String(valueOf(release, "SubscriptionType") || "").toLowerCase() === "custom")
      return `c${valueOf(release, "SubscriptionId") || ""}`;
    return String(valueOf(release, "ReleaseId") || "");
  }

  function buildStatementMapRecords() {
    const records = [];
    statementMappingState.releases.forEach(release => {
      const key = mapReleaseKey(release);
      const rows = statementMappingState.rowsByRelease.get(key);
      if (!rows || !rows.length) return;
      const isCustom = String(valueOf(release, "SubscriptionType") || "").toLowerCase() === "custom";
      const releaseLabel = valueOf(release, "FrameworkRelease") || valueOf(release, "ReleaseVersion")
        || (isCustom ? "Organization / Custom Release" : `Release ${key}`);
      records.push({ Id: `rel-${key}`, ParentNodeId: "", Reference: "", Title: releaseLabel, DisplayOrder: 0, __kind: "release" });

      if (isCustom) {
        // custom-release-statements rows carry no RowType. Build one structure
        // node per distinct StructureNodeId, then hang each statement (keyed on
        // its OrgStatementId overlay, migration 347) under that node -- or under
        // the release itself when it has no structure node.
        const seenNodes = new Set();
        rows.forEach(row => {
          const nodeId = valueOf(row, "StructureNodeId");
          if (nodeId && !seenNodes.has(String(nodeId))) {
            seenNodes.add(String(nodeId));
            records.push({
              Id: `sn-${key}-${nodeId}`,
              ParentNodeId: `rel-${key}`,
              Reference: valueOf(row, "StructureNodeReference"),
              Title: valueOf(row, "StructureNodeTitle"),
              DisplayOrder: 0,
              __kind: "structure"
            });
          }
        });
        rows
          .filter(row => valueOf(row, "OrgStatementId"))
          .forEach(row => {
            const nodeId = valueOf(row, "StructureNodeId");
            records.push({
              Id: `fs-${valueOf(row, "OrgStatementId")}`,
              ParentNodeId: nodeId ? `sn-${key}-${nodeId}` : `rel-${key}`,
              Reference: valueOf(row, "StatementReference"),
              Title: valueOf(row, "StatementTitle"),
              DisplayOrder: valueOf(row, "DisplayOrder"),
              __kind: "statement",
              __orgStatementId: String(valueOf(row, "OrgStatementId"))
            });
          });
        return;
      }

      // Repository release: RowType Node / Statement rows.
      rows
        .filter(row => String(valueOf(row, "RowType")).toLowerCase() === "node")
        .forEach(row => {
          const parentId = valueOf(row, "ParentSourceStructureNodeId");
          records.push({
            Id: `sn-${key}-${valueOf(row, "SourceStructureNodeId")}`,
            ParentNodeId: parentId ? `sn-${key}-${parentId}` : `rel-${key}`,
            Reference: valueOf(row, "SourceStructureReference"),
            Title: valueOf(row, "SourceStructureTitle"),
            DisplayOrder: valueOf(row, "SourceStructureDisplayOrder"),
            __kind: "structure"
          });
        });
      rows
        .filter(row => String(valueOf(row, "RowType")).toLowerCase() === "statement" && valueOf(row, "OrgStatementId"))
        .forEach(row => {
          records.push({
            Id: `fs-${valueOf(row, "OrgStatementId")}`,
            ParentNodeId: `sn-${key}-${valueOf(row, "SourceStructureNodeId")}`,
            Reference: valueOf(row, "StatementReference"),
            Title: valueOf(row, "StatementTitle"),
            DisplayOrder: valueOf(row, "StatementDisplayOrder"),
            __kind: "statement",
            __orgStatementId: String(valueOf(row, "OrgStatementId"))
          });
        });
    });
    return records;
  }

  async function renderStatementMappingSection(record, mode, organizationRequirementId) {
    if (!fieldsHost) return;
    resetStatementMappingState();
    fieldsHost.querySelector("[data-statement-mapping]")?.remove();
    if (screen.Key !== "organization-requirements" || !(mode === "add" || mode === "edit")) return;

    const container = document.createElement("section");
    container.className = "pm-statement-mapping";
    container.setAttribute("data-statement-mapping", "1");
    container.innerHTML = `
      <div class="pm-statement-mapping-header">
        <div>
          <h3>Control Statement Mapping</h3>
          <p>Map this practice to Framework Statements grouped under their Source Structure hierarchy. Every subscribed release is shown below as its own branch.</p>
        </div>
      </div>
      <div data-mapping-message class="pm-obligation-empty">Loading Control Statement mapping...</div>
      <div class="pm-map-panels-wrap" data-mapping-panes hidden>
        <div class="pm-map-warning" data-mapping-warning hidden></div>
        <div class="pm-map-actions">
          <button type="button" class="pm-button small" data-map-expand-all>Expand all</button>
          <button type="button" class="pm-button small" data-map-collapse-all>Collapse all</button>
        </div>
        <div class="pm-map-panels">
          <section class="pm-map-panel">
            <div class="pm-map-panel-head">
              <div><strong>Unmapped Framework Nodes</strong><small data-mapping-left-count>0 selected</small><small class="pm-map-hint">Release &rarr; Source Structure &rarr; Framework Statements. Only Framework Statements are selectable.</small></div>
              <input data-mapping-left-search placeholder="Search unmapped..." />
            </div>
            <div class="pm-map-tree" data-mapping-left-tree></div>
          </section>
          <section class="pm-map-panel">
            <div class="pm-map-panel-head">
              <div><strong>Mapped Framework Nodes</strong><small data-mapping-right-count>0 selected</small><small class="pm-map-hint">Framework Statements already mapped to this practice.</small></div>
              <input data-mapping-right-search placeholder="Search mapped..." />
            </div>
            <div class="pm-map-tree" data-mapping-right-tree></div>
          </section>
        </div>
        <div class="pm-map-footer">
          <button type="button" class="pm-button primary" data-map-move-right>Map <i class="fa-solid fa-arrow-right" aria-hidden="true"></i></button>
          <button type="button" class="pm-button" data-map-move-left><i class="fa-solid fa-arrow-left" aria-hidden="true"></i> Remove</button>
        </div>
      </div>`;
    fieldsHost.appendChild(container);

    const messageEl = container.querySelector("[data-mapping-message]");
    const panesEl = container.querySelector("[data-mapping-panes]");
    const warningEl = container.querySelector("[data-mapping-warning]");
    const leftTreeEl = container.querySelector("[data-mapping-left-tree]");
    const rightTreeEl = container.querySelector("[data-mapping-right-tree]");
    const leftCountEl = container.querySelector("[data-mapping-left-count]");
    const rightCountEl = container.querySelector("[data-mapping-right-count]");
    const leftSearchEl = container.querySelector("[data-mapping-left-search]");
    const rightSearchEl = container.querySelector("[data-mapping-right-search]");

    const organizationId = valueOf(record, "organizationId") || valueOf(record, "OrganizationId")
      || fieldsHost.querySelector("[name='organizationId']")?.value || "";

    // Re-run this whole section the first time the Organization field
    // changes (Add mode commonly opens with no organization chosen yet).
    // Guarded on the field itself so re-opening the section doesn't stack
    // a second listener on the same, otherwise-untouched schema field.
    const orgField = fieldsHost.querySelector("[name='organizationId']");
    if (orgField && !orgField.__statementMappingBound) {
      orgField.__statementMappingBound = true;
      orgField.addEventListener("change", () => {
        renderStatementMappingSection(record, mode, organizationRequirementId);
      });
    }

    if (!organizationId) {
      messageEl.textContent = "Select an Organization above to map Control Statements.";
      panesEl.hidden = true;
      return;
    }

    if (organizationRequirementId) {
      const seeded = await seedStatementMappingSelection(organizationRequirementId);
      if (!seeded) {
        messageEl.textContent = "Unable to load this practice's current Control Statement mappings. Close and reopen this form to try again -- mapping changes won't be saved until this loads successfully.";
        panesEl.hidden = true;
        return;
      }
    }
    statementMappingState.seedOk = true;

    function renderTreeSide(host, records, side) {
      const search = ((side === "left" ? leftSearchEl : rightSearchEl).value || "").trim().toLowerCase();
      const matches = row => `${row.Reference || ""} ${row.Title || ""}`.toLowerCase().includes(search);
      const filtered = search ? includeStatementMapAncestors(records, new Set(records.filter(matches).map(row => String(row.Id)))) : records;
      const flat = flattenStatementMapTree(filtered, statementMappingState.collapsed)
        .filter(({ row, hasChildren }) => row.__kind === "statement" || hasChildren);
      const checkedSet = side === "left" ? statementMappingState.leftChecked : statementMappingState.rightChecked;
      host.innerHTML = flat.length ? flat.map(({ row, depth, hasChildren }) => {
        const id = String(row.Id);
        const isStatement = row.__kind === "statement";
        const collapsed = statementMappingState.collapsed.has(id);
        const toggle = !isStatement && hasChildren
          ? `<button type="button" class="pm-map-tree-toggle" data-map-toggle="${escapeHtml(id)}"><i class="fa-solid fa-chevron-${collapsed ? "right" : "down"}" aria-hidden="true"></i></button>`
          : `<span class="pm-map-tree-spacer"></span>`;
        const isRelease = row.__kind === "release";
        const checkbox = isStatement
          ? `<input type="checkbox" data-map-node="${escapeHtml(id)}" data-side="${side}"${checkedSet.has(id) ? " checked" : ""}>`
          : `<span class="pm-map-parent-dot pm-map-folder-dot" title="${isRelease ? "Subscribed Framework Release" : "Source Structure node -- only Framework Statements can be mapped."}"><i class="fa-solid ${isRelease ? "fa-layer-group" : "fa-folder"}" aria-hidden="true"></i></span>`;
        const label = isStatement ? `${row.Reference || ""} - ${row.Title || ""}` : (isRelease ? (row.Title || "") : `${row.Reference || ""}${row.Title ? " - " + row.Title : ""}`);
        return `<div class="pm-map-tree-row${!isStatement ? " parent" : " leaf-statement"}${isRelease ? " release-row" : ""}" style="--tree-depth:${depth}" data-node-id="${escapeHtml(id)}">${toggle}${checkbox}<span class="pm-map-node-text" title="${escapeHtml(label)}">${escapeHtml(label)}</span></div>`;
      }).join("") : `<div class="pm-map-empty">No framework statements found</div>`;
    }

    function refreshMapTrees() {
      const records = buildStatementMapRecords();
      const unmappedIds = new Set(records.filter(row => row.__kind === "statement" && !statementMappingState.selected.has(row.__orgStatementId)).map(row => String(row.Id)));
      const mappedIdsHere = new Set(records.filter(row => row.__kind === "statement" && statementMappingState.selected.has(row.__orgStatementId)).map(row => String(row.Id)));
      const unmappedRecords = includeStatementMapAncestors(records, unmappedIds).filter(row => row.__kind !== "statement" || unmappedIds.has(String(row.Id)));
      const mappedRecords = includeStatementMapAncestors(records, mappedIdsHere).filter(row => row.__kind !== "statement" || mappedIdsHere.has(String(row.Id)));
      renderTreeSide(leftTreeEl, unmappedRecords, "left");
      renderTreeSide(rightTreeEl, mappedRecords, "right");
      leftCountEl.textContent = `${statementMappingState.leftChecked.size} selected`;
      rightCountEl.textContent = `${statementMappingState.rightChecked.size} selected`;
    }

    // Every subscribed release is fetched up front (in parallel) and merged
    // into one combined tree by buildStatementMapRecords -- there's no
    // per-release lazy load anymore, since there's no release selector left
    // to trigger one.
    // Each subscribed release is fetched independently and failures don't
    // take the others down with them -- release-statements/query re-checks
    // grac_practice.repository_subscription itself (organization_id +
    // release_id + status='Active') and THROWs 51042 "The selected
    // framework release is not subscribed for this organization" if that
    // specific row isn't there, even though the SAME release just came
    // back from subscribed-frameworks/query a moment earlier. That check
    // was always this strict -- the single-release dropdown just never
    // surfaced it, because the user picked one release at a time and a
    // stale/mismatched one could go unpicked. Loading every subscribed
    // release at once (no dropdown left to hide behind) means any one
    // release failing this check is now something the user will actually
    // hit. Promise.all's fail-fast behaviour previously took the WHOLE
    // picker down empty over one bad release; Promise.allSettled plus a
    // small warning banner instead shows every release that DID load and
    // names the one(s) that didn't, instead of hiding everything.
    async function loadAllMappingReleases() {
      messageEl.hidden = true;
      panesEl.hidden = false;
      warningEl.hidden = true;
      leftTreeEl.innerHTML = `<div class="pm-map-empty">Loading source statements...</div>`;
      rightTreeEl.innerHTML = "";
      const pending = statementMappingState.releases
        .map(release => ({ release, key: mapReleaseKey(release) }))
        .filter(({ key }) => key && !statementMappingState.rowsByRelease.has(key));
      const outcomes = await Promise.allSettled(pending.map(async ({ release, key }) => {
        // Custom releases are keyed on subscriptionId and served by a different
        // endpoint (custom-release-statements); repository releases by releaseId.
        const isCustom = String(valueOf(release, "SubscriptionType") || "").toLowerCase() === "custom";
        const endpoint = isCustom ? "custom-release-statements" : "release-statements";
        const data = isCustom
          ? { organizationId: Number(organizationId), subscriptionId: Number(valueOf(release, "SubscriptionId") || 0) }
          : { organizationId: Number(organizationId), releaseId: Number(valueOf(release, "ReleaseId") || 0), pageNumber: 1, pageSize: 2000 };
        const result = await fetchJson(`${api}/${endpoint}/query`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
          body: JSON.stringify({ data })
        });
        statementMappingState.rowsByRelease.set(key, apiData(result));
        return release;
      }));
      const failed = outcomes
        .map((outcome, index) => ({ outcome, release: pending[index].release }))
        .filter(({ outcome }) => outcome.status === "rejected");
      failed.forEach(({ outcome, release }) => {
        console.error("PracticeManagement statement mapping release load failed",
          valueOf(release, "FrameworkRelease") || valueOf(release, "ReleaseVersion") || valueOf(release, "ReleaseId"), outcome.reason);
      });
      if (failed.length && failed.length === statementMappingState.releases.length) {
        // Every release failed -- there is genuinely nothing to show.
        messageEl.textContent = failed[0].outcome.reason?.message || "Unable to load source statements for the subscribed releases.";
        messageEl.hidden = false;
        panesEl.hidden = true;
        return;
      }
      if (failed.length) {
        const names = failed.map(({ release }) => valueOf(release, "FrameworkRelease") || valueOf(release, "ReleaseVersion") || "a subscribed release").join(", ");
        warningEl.textContent = `Couldn't load source statements for: ${names}. The rest are shown below -- this usually means that release's subscription needs to be re-checked in Governance - Standards & Frameworks.`;
        warningEl.hidden = false;
      }
      refreshMapTrees();
    }

    leftSearchEl.addEventListener("input", refreshMapTrees);
    rightSearchEl.addEventListener("input", refreshMapTrees);
    container.addEventListener("click", event => {
      if (event.target.closest(".pm-map-parent-dot")) {
        messageEl.textContent = "Only Framework Statements can be mapped to a Practice. Source Structure nodes act as folders.";
        messageEl.hidden = false;
        return;
      }
      const toggle = event.target.closest("[data-map-toggle]");
      if (toggle) {
        const id = toggle.dataset.mapToggle;
        statementMappingState.collapsed.has(id) ? statementMappingState.collapsed.delete(id) : statementMappingState.collapsed.add(id);
        refreshMapTrees();
        return;
      }
      if (event.target.closest("[data-map-expand-all]")) { statementMappingState.collapsed.clear(); refreshMapTrees(); return; }
      if (event.target.closest("[data-map-collapse-all]")) {
        statementMappingState.releases.forEach(release => {
          const releaseId = String(valueOf(release, "ReleaseId") || "");
          statementMappingState.collapsed.add(`rel-${releaseId}`);
          (statementMappingState.rowsByRelease.get(releaseId) || [])
            .filter(row => String(valueOf(row, "RowType")).toLowerCase() === "node")
            .forEach(row => statementMappingState.collapsed.add(`sn-${releaseId}-${valueOf(row, "SourceStructureNodeId")}`));
        });
        refreshMapTrees();
        return;
      }
      if (event.target.closest("[data-map-move-right]")) {
        statementMappingState.leftChecked.forEach(id => { if (id.startsWith("fs-")) statementMappingState.selected.add(id.slice(3)); });
        statementMappingState.leftChecked = new Set();
        refreshMapTrees();
        return;
      }
      if (event.target.closest("[data-map-move-left]")) {
        statementMappingState.rightChecked.forEach(id => { if (id.startsWith("fs-")) statementMappingState.selected.delete(id.slice(3)); });
        statementMappingState.rightChecked = new Set();
        refreshMapTrees();
      }
    });
    container.addEventListener("change", event => {
      const box = event.target.closest("[data-map-node]");
      if (!box) return;
      const set = box.dataset.side === "left" ? statementMappingState.leftChecked : statementMappingState.rightChecked;
      box.checked ? set.add(box.dataset.mapNode) : set.delete(box.dataset.mapNode);
      // Update the "N selected" counts only -- a full refreshMapTrees() here
      // would rebuild both lists on every single checkbox click, which is
      // unnecessary until the user actually moves the selection.
      leftCountEl.textContent = `${statementMappingState.leftChecked.size} selected`;
      rightCountEl.textContent = `${statementMappingState.rightChecked.size} selected`;
    });

    try {
      const result = await fetchJson(`${api}/subscribed-frameworks/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ data: { organizationId: Number(organizationId), pageNumber: 1, pageSize: 500 } })
      });
      // subscribed-frameworks/query also unions in the organization's own
      // Custom Releases (QuerySubscribedFrameworksAsync's second SELECT,
      // ReleaseId = -1 * subscription_id, SubscriptionType "Custom") so
      // the Organization Controls summary can show them alongside real
      // framework releases. This picker was scoped to subscribed FRAMEWORK
      // releases only from the start, and there's a structural reason it
      // has to stay that way: a Custom Release's statements live in
      // grac_practice.custom_release_statement, a self-contained hierarchy
      // with no org_statement_id and no link to
      // organization_framework_statements -- the table the mapping-sync
      // procedure validates every mappedOrgStatementIds entry against
      // before writing organization_statement_practice_mapping. Passing a
      // Custom Release's synthetic negative id to release-statements/query
      // (grac_new-backed) doesn't just fail to find it there -- there's no
      // grac_practice.repository_subscription row with that release_id
      // either (custom subscriptions store release_id NULL), so it 51042s
      // as "not subscribed" even though the subscription is perfectly
      // fine. Even loading it correctly (via custom-release-statements,
      // the endpoint QueryCustomReleaseStatementsAsync actually serves)
      // would let a user tick and "Map" a custom statement that the save
      // path would then silently drop, since it can never match an
      // org_statement_id. Filtering these out here -- before ever
      // fetching them -- avoids both the false error and that silent
      // no-op, until Custom Release mapping is built out as its own
      // feature with its own junction table.
      // 347: custom releases ARE now mappable -- each custom statement carries a
      // source-agnostic org_statement_id overlay (organization_framework_statements,
      // source_type='Custom'), so the existing save persists it exactly like a
      // repository statement. Load them alongside repository releases; the loader
      // and tree builder branch on SubscriptionType='Custom'.
      statementMappingState.releases = apiData(result);
      if (!statementMappingState.releases.length) {
        messageEl.textContent = "No subscribed framework releases found for this organization. Subscribe releases in Governance - Standards & Frameworks.";
        panesEl.hidden = true;
        return;
      }
    } catch (error) {
      messageEl.textContent = error.message || "Unable to load subscribed framework releases.";
      panesEl.hidden = true;
      console.error("PracticeManagement statement mapping releases load failed", error);
      return;
    }

    await loadAllMappingReleases();
  }

  async function showEvidenceAlignmentSummary(practiceInstanceId, showEmpty = true) {
    if (!practiceInstanceId) return;
    const result = await fetchJson(`${api}/evidence-alignments/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data: { practiceInstanceId, pageNumber: 1, pageSize: 200 } })
    });
    const alignmentRows = apiData(result);
    if (!alignmentRows.length && !showEmpty) return;
    window.alert(formatPopupRows("Evidence Alignment Summary", alignmentRows, [
      { name: "FrameworkRelease", label: "Framework Release" },
      { name: "AlignmentStatus", label: "Result" },
      { name: "AlignmentReason", label: "Reason" }
    ], "No framework obligation alignment results were calculated. Configure evidence and verify obligation recommendations exist."));
  }

  async function loadOperationalizationDependencyOptions(dependencyTypeId, organizationId, selectedValue = "", targetSelect = null) {
    const selectEl = targetSelect || fieldsHost?.querySelector("[name='resolvedDependencyId']");
    if (!selectEl) return;
    selectEl.innerHTML = `<option value="">Dependency Objects Loading...</option>`;
    if (!dependencyTypeId || !organizationId) {
      selectEl.innerHTML = `<option value="">Select dependency category first...</option>`;
      logDependencyObjectTrace("blocked", { dependencyTypeId: dependencyTypeId || "", organizationId: organizationId || "" });
      return;
    }
    const payload = {
      organizationId: Number(organizationId),
      dependencyTypeId: Number(dependencyTypeId),
      pageNumber: 1,
      pageSize: 200
    };
    try {
      logDependencyObjectTrace("request", { url: `${api}/dependency-options/query`, dependencyTypeId: payload.dependencyTypeId, organizationId: payload.organizationId, payload });
      const result = await fetchJson(`${api}/dependency-options/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ data: payload })
      });
      const tables = apiTables(result);
      const meta = (tables[1] || [])[0] || {};
      const options = normalizeDependencyOptions(result);
      logDependencyObjectTrace("response", {
        dependencyTypeId: payload.dependencyTypeId,
        organizationId: payload.organizationId,
        sourceTableName: valueOf(meta, "SourceTableName") || options[0]?.sourceTableName || "",
        recordsReturned: options.length,
        response: result
      });
      if (options.length) {
        selectEl.innerHTML = `<option value="">Select...</option>${optionList(options, selectedValue)}`;
      } else {
        const debugMsg = valueOf(meta, "DebugMessage") || "";
        const srcTable = valueOf(meta, "SourceTableName") || "";
        const hint = debugMsg
          ? `No objects: ${debugMsg}`
          : srcTable
            ? `No active records in ${srcTable} for org ${payload.organizationId}`
            : `No dependency objects found (typeId=${payload.dependencyTypeId}, orgId=${payload.organizationId})`;
        selectEl.innerHTML = `<option value="">${escapeHtml(hint)}</option>`;
        console.warn("PracticeManagement dependency objects EMPTY", { dependencyTypeId: payload.dependencyTypeId, organizationId: payload.organizationId, meta, debugMsg, srcTable });
      }
    } catch (error) {
      selectEl.innerHTML = `<option value="">${escapeHtml(error.message || "Unable to load dependency objects.")}</option>`;
      console.error("PracticeManagement dependency objects error", {
        dependencyTypeId: payload.dependencyTypeId,
        organizationId: payload.organizationId,
        message: error.message || String(error)
      });
    }
  }

  function operationalizationResolutionRow(row = {}, readonly = false) {
    const disabled = readonly ? " disabled" : "";
    return `<tr data-op-resolution-row data-resolution-id="${escapeHtml(valueOf(row, "ResolutionId") || "")}">
      <td><select data-op-field="resolvedDependencyId"${disabled} required><option value="">Loading...</option></select></td>
      <td><select data-op-field="resolutionOwnerId"${disabled}>${optionsFor("owners-id", valueOf(row, "ResolutionOwnerId"))}</select></td>
      <td><input data-op-field="remarks" value="${escapeHtml(valueOf(row, "Remarks"))}"${disabled}></td>
      <td>${readonly ? "" : `<button type="button" class="pm-icon-button pm-op-resolution-remove" title="Remove"><i class="fa-solid fa-xmark"></i></button>`}</td>
    </tr>`;
  }

  async function hydrateOperationalizationResolutionRows(dependencyTypeId, organizationId) {
    const jobs = [...fieldsHost.querySelectorAll("[data-op-resolution-row]")].map(row => {
      const select = row.querySelector("[data-op-field='resolvedDependencyId']");
      const selected = valueOf(row.dataset, "selectedDependencyId") || row.dataset.selectedDependencyId || "";
      return loadOperationalizationDependencyOptions(dependencyTypeId, organizationId, selected, select);
    });
    await Promise.all(jobs);
  }

  async function loadResolveCategoryRows(practiceInstanceId, organizationId, record = {}) {
    const existingTypeId = valueOf(record, "DependencyTypeId");
    if (existingTypeId) {
      return [{
        PracticeInstanceId: practiceInstanceId,
        DependencyTypeId: existingTypeId,
        DependencyCategory: valueOf(record, "DependencyCategory") || valueOf(record, "Register"),
        ResolvedDependencyId: valueOf(record, "ResolvedDependencyId"),
        ResolvedDependencyName: valueOf(record, "ResolvedDependencyName"),
        ResolutionStatus: valueOf(record, "ResolutionStatus"),
        ResolutionOwner: valueOf(record, "ResolutionOwner"),
        CategoryStatus: valueOf(record, "ResolutionStatus"),
        Remarks: valueOf(record, "Remarks")
      }];
    }

    const result = await fetchJson(`${api}/resolve/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({
        id: practiceInstanceId,
        data: {
          organizationId,
          pageNumber: 1,
          pageSize: 100
        }
      })
    });
    const tables = apiTables(result);
    const resolutionRows = (tables[1] || []).filter(row => valueOf(row, "DependencyTypeId"));
    if (resolutionRows.length) return resolutionRows;
    return apiData(result).filter(row => valueOf(row, "DependencyTypeId"));
  }

  function collectOperationalizationResolutions() {
    return [...fieldsHost.querySelectorAll("[data-op-resolution-row]")].map(row => ({
      id: Number(row.dataset.resolutionId || 0),
      resolvedDependencyId: row.querySelector("[data-op-field='resolvedDependencyId']")?.value || "",
      resolutionOwnerId: row.querySelector("[data-op-field='resolutionOwnerId']")?.value || "",
      remarks: row.querySelector("[data-op-field='remarks']")?.value || ""
    })).filter(item => item.resolvedDependencyId);
  }

  async function saveOperationalizationResolutions(data) {
    const resolutions = collectOperationalizationResolutions();
    if (!data.practiceInstanceId) throw new Error("Practice Instance context is required.");
    if (!data.dependencyTypeId) throw new Error("Dependency Category is required.");
    if (!resolutions.length) throw new Error("Add at least one resolved dependency.");
    for (const resolution of resolutions) {
      await fetchJson(`${api}/practice-dependency-resolutions`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({
          id: resolution.id || 0,
          data: {
            organizationId: Number(data.organizationId),
            practiceInstanceId: Number(data.practiceInstanceId),
            dependencyTypeId: Number(data.dependencyTypeId),
            resolvedDependencyId: Number(resolution.resolvedDependencyId),
            resolutionOwnerId: resolution.resolutionOwnerId ? Number(resolution.resolutionOwnerId) : null,
            remarks: resolution.remarks || ""
          }
        })
      });
    }
    return { message: "Saved successfully." };
  }

  async function openOperationalization(record, readonly = false) {
    const practiceInstanceId = Number(valueOf(record, "PracticeInstanceId") || valueOf(record, "Id") || 0);
    const organizationId = Number(valueOf(record, "OrganizationId") || organizationFilter?.value || 0);
    const registerName = valueOf(record, "Register") || valueOf(record, "DependencyCategory") || state.activeWorkbenchLabel || "";
    if (String(registerName).toLowerCase().includes("evidence") || state.activeWorkbenchDependencyTypeId === "evidence") {
      await openEvidenceResolution(record, readonly, practiceInstanceId, organizationId);
      return;
    }
    const isWorkbench = workbenchScreens.has(screen.Key) || isOperationalizationWorkbench;
    if (!practiceInstanceId) throw new Error("Practice Instance context is required.");
    state.mode = readonly ? "view" : "resolve";
    state.id = 0;
    state.formEntity = "practice-dependency-resolutions";
    state.activeFormRecord = record;
    formMessage.hidden = true;

    let summary = record;
    let resolutionRows = [];
    if (isWorkbench) {
      resolutionRows = await loadResolveCategoryRows(practiceInstanceId, organizationId, record);
    } else {
      const result = await fetchJson(`${api}/${screen.Key === "resolve" ? "resolve" : "practice-operationalization"}/query`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id: practiceInstanceId, data: { organizationId, pageNumber: 1, pageSize: 1 } })
      });
      const tables = apiTables(result);
      summary = (tables[0] || [])[0] || record;
      resolutionRows = tables[1] || [];
    }
    let categoryOptions = resolutionRows
      .filter(row => valueOf(row, "DependencyTypeId"))
      .map(row => ({ value: valueOf(row, "DependencyTypeId"), label: valueOf(row, "DependencyCategory") || valueOf(row, "Register") || `Dependency Type ${valueOf(row, "DependencyTypeId")}` }))
      .filter((item, index, items) => items.findIndex(other => String(other.value) === String(item.value)) === index);
    if (!categoryOptions.length) {
      const categoryText = String(valueOf(record, "DependencyCategory") || valueOf(record, "Register") || valueOf(record, "DependencyCategories") || "")
        .replace(/\s+Register\b/ig, "")
        .trim();
      const dependencyLookups = state.lookups["dependency-types"]?.length ? state.lookups["dependency-types"] : fallbackDependencyTypes;
      const namedCategories = categoryText
        ? categoryText.split(",").map(item => item.trim()).filter(Boolean)
        : [];
      categoryOptions = namedCategories
        .map(name => {
          const match = dependencyLookups.find(item => String(item.label || "").trim().toLowerCase() === name.toLowerCase()
            || String(item.label || "").toLowerCase().includes(name.toLowerCase())
            || name.toLowerCase().includes(String(item.label || "").toLowerCase()));
          return match ? { value: match.value, label: match.label } : null;
        })
        .filter(Boolean);
      if (!categoryOptions.length && Number(valueOf(summary, "PendingDependenciesCount") || 0) > 0) {
        categoryOptions = dependencyLookups.map(item => ({ value: item.value, label: item.label }));
      }
    }
    const selectedDependencyTypeId = valueOf(record, "DependencyTypeId") || categoryOptions[0]?.value || "";
    const selectedDependencyCategory = valueOf(record, "DependencyCategory") || categoryOptions.find(item => String(item.value) === String(selectedDependencyTypeId))?.label || "";
    const editableResolutionRows = resolutionRows
      .filter(row => !selectedDependencyTypeId || String(valueOf(row, "DependencyTypeId")) === String(selectedDependencyTypeId))
      .filter(row => valueOf(row, "ResolvedDependencyId"));
    if (!readonly && !editableResolutionRows.length) editableResolutionRows.push({});
    const resolutionTable = resolutionRows.length
      ? resolutionRows.map(row => `<tr>
          <td>${escapeHtml(valueOf(row, "DependencyCategory"))}</td>
          <td>${escapeHtml(valueOf(row, "ResolvedDependencyName") || "Pending")}</td>
          <td>${formatCell(valueOf(row, "CategoryStatus") || valueOf(row, "ResolutionStatus") || "Pending")}</td>
          <td>${escapeHtml(valueOf(row, "ResolutionOwner"))}</td>
          <td>${escapeHtml(valueOf(row, "Remarks"))}</td>
        </tr>`).join("")
      : `<tr><td colspan="5" class="pm-empty compact">No dependency categories are configured for this Practice Instance.</td></tr>`;

    document.querySelector("#dialogTitle").textContent = readonly ? "View Resolve Details" : `Resolve ${escapeHtml(selectedDependencyCategory || "Dependency")}`;
    fieldsHost.innerHTML = `
      <section class="pm-setup-card full">
        <div class="pm-section-heading inline">
          <div>
            <h2>${escapeHtml(valueOf(summary, "Name"))}</h2>
            <p>${escapeHtml(valueOf(summary, "Code"))} | ${escapeHtml(valueOf(summary, "ResolutionStatus") || valueOf(summary, "OperationalizationStatus") || "Pending")}</p>
          </div>
        </div>
        <div class="pm-form-grid pm-form-grid-compact">
          <label class="pm-field"><span>Owning Department</span><input value="${escapeHtml(valueOf(summary, "OwningDepartment"))}" disabled></label>
          <label class="pm-field"><span>Primary Owner</span><input value="${escapeHtml(valueOf(summary, "PrimaryOwner"))}" disabled></label>
          <label class="pm-field"><span>Frequency</span><input value="${escapeHtml(valueOf(summary, "Frequency"))}" disabled></label>
          <label class="pm-field"><span>Resolved / Pending</span><input value="${escapeHtml(valueOf(summary, "ResolvedDependenciesCount"))} / ${escapeHtml(valueOf(summary, "PendingDependenciesCount"))}" disabled></label>
        </div>
      </section>
      <section class="pm-setup-card full">
        <div class="pm-section-heading inline">
          <div><h2>Resolve Details</h2><p>Resolve configured register items against organization objects.</p></div>
        </div>
        <div class="pm-table-wrap compact">
          <table>
            <thead><tr><th>Category</th><th>Resolved Dependency</th><th>Status</th><th>Resolution Owner</th><th>Remarks</th></tr></thead>
            <tbody>${resolutionTable}</tbody>
          </table>
        </div>
      </section>
      <input name="organizationId" type="hidden" value="${escapeHtml(organizationId)}">
      <input name="practiceInstanceId" type="hidden" value="${escapeHtml(practiceInstanceId)}">
      <label class="pm-field"><span>Dependency Category <span class="required">*</span></span><select id="opDependencyType" name="dependencyTypeId"${readonly ? " disabled" : ""} required>${optionsForInline(categoryOptions.length ? categoryOptions : [{ value: selectedDependencyTypeId, label: selectedDependencyCategory || "Dependency Category" }], selectedDependencyTypeId)}</select></label>
      <section class="pm-setup-card full">
        <div class="pm-section-heading inline">
          <div><h2>Resolved Dependencies</h2><p>Add one or more active organization objects for this dependency category.</p></div>
          ${readonly ? "" : `<button class="pm-button" id="addOperationalizationResolution" type="button"><i class="fa-solid fa-plus"></i> Add Dependency</button>`}
        </div>
        <div class="pm-table-wrap compact">
          <table>
            <thead><tr><th>Dependency Object</th><th>Resolution Owner</th><th>Remarks</th><th>Actions</th></tr></thead>
            <tbody id="opResolutionRows">
              ${editableResolutionRows.length ? editableResolutionRows.map(row => operationalizationResolutionRow(row, readonly).replace("data-op-resolution-row", `data-op-resolution-row data-selected-dependency-id="${escapeHtml(valueOf(row, "ResolvedDependencyId"))}"`)).join("") : `<tr><td colspan="4" class="pm-empty compact">No resolved dependencies saved.</td></tr>`}
            </tbody>
          </table>
        </div>
      </section>
    `;
    saveButton.hidden = readonly || !selectedDependencyTypeId;
    dialog.showModal();
    if (selectedDependencyTypeId) {
      await hydrateOperationalizationResolutionRows(selectedDependencyTypeId, organizationId);
    } else {
      await hydrateOperationalizationResolutionRows("", organizationId);
    }
  }

  async function openEvidenceResolution(record, readonly, practiceInstanceId, organizationId) {
    if (!practiceInstanceId) throw new Error("Practice Instance context is required.");
    state.mode = readonly ? "view" : "resolveEvidence";
    state.id = Number(valueOf(record, "EvidenceId") || 0);
    state.formEntity = "evidence-configurations";
    state.activeFormRecord = record;
    formMessage.hidden = true;

    document.querySelector("#dialogTitle").textContent = readonly ? "View Evidence Resolve Details" : "Resolve Evidence";
    fieldsHost.innerHTML = `
      <section class="pm-setup-card full">
        <div class="pm-section-heading inline">
          <div>
            <h2>${escapeHtml(valueOf(record, "Name"))}</h2>
            <p>${escapeHtml(valueOf(record, "Code"))} | ${escapeHtml(valueOf(record, "Register") || "Evidence Register")}</p>
          </div>
        </div>
        <div class="pm-form-grid pm-form-grid-compact">
          <label class="pm-field"><span>Department</span><input value="${escapeHtml(valueOf(record, "OwningDepartment"))}" disabled></label>
          <label class="pm-field"><span>Owner</span><input value="${escapeHtml(valueOf(record, "PrimaryOwner"))}" disabled></label>
          <label class="pm-field"><span>Frequency</span><input value="${escapeHtml(valueOf(record, "Frequency"))}" disabled></label>
          <label class="pm-field"><span>Status</span><input value="${escapeHtml(valueOf(record, "ResolutionStatus") || "Pending")}" disabled></label>
        </div>
      </section>
      <input name="organizationId" type="hidden" value="${escapeHtml(organizationId)}">
      <input name="practiceInstanceId" type="hidden" value="${escapeHtml(practiceInstanceId)}">
      <input name="collectionMethodId" type="hidden" value="${escapeHtml(valueOf(record, "CollectionMethodId") || "1")}">
      <input name="statusId" type="hidden" value="1">
      <label class="pm-field"><span>Evidence Type <span class="required">*</span></span><select name="evidenceTypeId"${readonly ? " disabled" : ""} required>${optionsFor("evidence-types", valueOf(record, "EvidenceTypeId"))}</select></label>
      <label class="pm-field"><span>Assurance Type <span class="required">*</span></span><select name="assuranceTypeId"${readonly ? " disabled" : ""} required>${optionsFor("assurance-types", valueOf(record, "AssuranceTypeId") || "1")}</select></label>
      <label class="pm-field"><span>Retention Period</span><input name="retentionPeriod" value="${escapeHtml(valueOf(record, "RetentionPeriod") || valueOf(record, "RetentionRequirement"))}"${readonly ? " disabled" : ""}></label>
      <label class="pm-field full"><span>Evidence Description / Details</span><textarea name="evidenceDescription"${readonly ? " disabled" : ""}>${escapeHtml(valueOf(record, "EvidenceDescription"))}</textarea></label>
      <label class="pm-field"><span>Evidence Location</span><input name="evidenceLocation" value="${escapeHtml(valueOf(record, "EvidenceLocation"))}"${readonly ? " disabled" : ""}></label>
      <label class="pm-field"><span>Evidence Locator</span><input name="evidenceLocator" value="${escapeHtml(valueOf(record, "EvidenceLocator"))}"${readonly ? " disabled" : ""}></label>
      <label class="pm-field full"><span>Remarks</span><textarea name="remarks"${readonly ? " disabled" : ""}>${escapeHtml(valueOf(record, "Remarks"))}</textarea></label>
    `;
    saveButton.hidden = readonly;
    dialog.showModal();
  }

  function optionsForInline(items, selected) {
    const selectedText = String(selected ?? "");
    return `<option value="">Select...</option>${items.map(item => `<option value="${escapeHtml(item.value)}"${String(item.value) === selectedText ? " selected" : ""}>${escapeHtml(item.label)}</option>`).join("")}`;
  }

  async function saveForm() {
    try {
      // Bulk applicability posts a list of ids to its own entity and reports
      // per row, so it does not go through the single-record save below. It
      // shares the dialog and this button, and it shares showFormError's
      // handling of whatever comes back.
      if (state.mode === "bulkApplicability") {
        await saveBulkApplicability();
        return;
      }
      const data = collectForm();
      // Committee Members (migration 370, change request 2026-09-22):
      // collected from the custom row list rendered by
      // renderCommitteeMembersSection, not from name-based inputs -- same
      // reasoning as collectDependencies()/collectEvidence() below. Set
      // here (after collectForm(), before the POST) so it overrides
      // whatever a stray name="members" field would otherwise have
      // produced; committees has none, but this keeps the same shape as
      // every other screen-specific post-process in this function.
      if (isFormFor("committees")) data.members = collectCommitteeMembers();
      const dependencyState = collectDependencies();
      const evidenceState = collectEvidence();
      const targetEntity = state.mode === "applicability" && screen.Key === "organization-controls" ? "control-applicability" : (state.formEntity || screen.Key);
      const saveResult = targetEntity === "practice-dependency-resolutions"
        ? await saveOperationalizationResolutions(data)
        : await fetchJson(`${api}/${targetEntity}`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
          body: JSON.stringify({ id: state.id || 0, contextCode: state.navigationCode, data })
        });
      if (isFormFor("practice-instances")) {
        const savedRow = apiData(saveResult)[0] || {};
        const savedId = Number(valueOf(savedRow, "Id") || state.id || 0);
        if (!savedId) throw new Error("Practice Instance was saved, but the new Instance ID was not returned.");
        await saveEvidence(savedId, data.organizationId, evidenceState);
        await saveDependencies(savedId, data.organizationId, dependencyState);
      }
      // Custom Release Source Structure: reload nodes and re-open panel instead of full reload
      if (state.formEntity === "custom-release-source-structure") {
        await loadSourceStructureNodes();
        renderSourceStructureDialog();
        const saveMessage = saveResult.message || saveResult.Message || "";
        if (saveMessage && saveMessage !== "Saved successfully.") window.alert(saveMessage);
        return;
      }
      // Custom Statement: reload custom statement grid after save
      if (state.formEntity === "custom-statement") {
        // Add mode: Organization and Release are now independently
        // selectable inside the dialog (change request 2026-09) instead of
        // being carried over from whichever release the grid was drilled
        // into, so the statement may have just been saved against a
        // *different* release than the one still on screen. Point
        // sourceStatementState.release at the release actually picked
        // before reloading -- otherwise the grid would reload the old
        // context unchanged and the freshly saved statement would look
        // like it never got created, the exact "saved but missing from the
        // list" failure mode Practice Management already had once (Custom
        // Practice creation) and shouldn't grow a second copy of here.
        if (state.mode === "addCustomStatement") {
          const orgSelect = fieldsHost.querySelector("#customStatementOrgSelect");
          const releaseSelect = fieldsHost.querySelector("#customStatementReleaseSelect");
          if (orgSelect && releaseSelect && releaseSelect.value) {
            const releaseLabel = (releaseSelect.selectedOptions[0]?.textContent || "").trim();
            sourceStatementState.release = {
              organizationId: Number(data.organizationId) || 0,
              subscriptionId: Number(data.subscriptionId) || 0,
              organizationName: (orgSelect.selectedOptions[0]?.textContent || "").trim(),
              releaseVersion: releaseLabel,
              title: releaseLabel
            };
            sourceStatementState.isCustomRelease = true;
            sourceStatementState.level = "statements";
          }
        }
        dialog.close();
        await loadCustomReleaseStatements();
        const saveMessage = saveResult.message || saveResult.Message || "";
        if (saveMessage && saveMessage !== "Saved successfully.") window.alert(saveMessage);
        return;
      }
      // Update Owner: reload the release summary so the new owner shows.
      if (state.formEntity === "subscription-owner") {
        dialog.close();
        await loadSourceStatements();
        const saveMessage = saveResult.message || saveResult.Message || "Release owner updated successfully.";
        window.alert(saveMessage);
        return;
      }
      // Role Master, Add: the event checklist section needs a role id, and a
      // brand-new role has none until this point. Closing here would force
      // the user to find the role again and reopen it just to configure the
      // checklists they came to configure. Instead the dialog stays open,
      // adopts the new id -- so the next Save updates rather than inserts --
      // and the section comes alive in place.
      // Keyed on the entity actually written, not on screen.Key: Role Master
      // opens both from its own screen and from the Organization Setup
      // workspace, and only targetEntity is right in both cases.
      if (targetEntity === "roles" && !state.id) {
        const savedRole = apiData(saveResult)[0] || {};
        const newRoleId = Number(valueOf(savedRole, "Id") || 0);
        if (newRoleId) {
          state.id = newRoleId;
          state.mode = "edit";
          const title = document.querySelector("#dialogTitle");
          if (title) title.textContent = (title.textContent || "").replace(/^Add\b/, "Edit");

          await loadLookups();
          if (isOrganizationWorkspace) {
            populateSetupOrganizationSelector();
            if (setupState.organizationId) setupOrganization.value = setupState.organizationId;
            await loadSetupChildRows(state.formEntity || setupState.activeTab);
          } else {
            await loadRows();
          }

          // Write whatever was ticked or typed while the role had no id.
          const flushed = await flushPendingScopeChecklists(newRoleId);

          await renderScopeChecklistSection(fieldsHost, {
            organizationId: data.organizationId,
            scopeDimension: "ORG_ROLE",
            scopeValueId:   newRoleId,
            title:          "Event Checklists for this Role",
            subtitle:       "What has to be done when somebody joins this role, and when they leave it."
          });
          const section = fieldsHost.querySelector("[data-scope-checklist]");
          if (section) {
            // A partial flush must not read as success -- the user would
            // leave believing checklists were configured that were not.
            scopeMsg(section,
              flushed.failed
                ? `Role saved, but ${flushed.failed} checklist setting(s) could not be written. Set them again below.`
                : flushed.saved
                  ? `Role saved with ${flushed.saved} checklist setting(s).`
                  : "Role saved. You can now set its onboarding and offboarding checklists.",
              flushed.failed ? "error" : "ok");
            section.scrollIntoView({ behavior: "smooth", block: "nearest" });
          }
          return;
        }
      }

      dialog.close();
      await loadLookups();
      if (isOrganizationWorkspace) {
        populateSetupOrganizationSelector();
        if (setupState.organizationId) setupOrganization.value = setupState.organizationId;
        await loadSetupChildRows(state.formEntity || setupState.activeTab);
      } else {
        await loadRows();
      }
      const saveMessage = saveResult.message || saveResult.Message || "";
      if (saveMessage && saveMessage !== "Saved successfully.") window.alert(saveMessage);
    } catch (error) {
      showFormError(error);
    }
  }

  async function retire(id) {
    if (!await window.gracUi.confirm("Mark this record as inactive?",
          { type: "warning", title: "Mark inactive", confirmText: "Mark inactive" })) return;
    try {
      await fetchJson(`${api}/${screen.Key}/retire`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
        body: JSON.stringify({ id })
      });
      await loadRows();
    } catch (error) {
      // Migration 345: deactivating a user who still owns items is blocked
      // in the database (trigger THROW 51950, message prefixed
      // OWNERSHIP_ACTIVE|). Turn that into the "reassign first" flow: offer
      // to open Ownership Management with this user pre-selected, rather
      // than showing a dead-end error.
      const raw = String(error?.message || "");
      const blocked = screen.Key === "users"
        && (/OWNERSHIP_ACTIVE/i.test(raw) || /currently assigned as an owner/i.test(raw));
      if (blocked) {
        const human = raw.includes("|") ? raw.split("|").slice(1).join("|").trim() : raw;
        const goManage = await window.gracUi.confirm(
          human || "This user cannot be deactivated because they are currently assigned as an owner of one or more items. Please reassign the ownership before deactivating the user.",
          { type: "warning", title: "Reassign ownership first", confirmText: "Manage Ownership", cancelText: "Cancel" });
        if (goManage) {
          window.location.assign(
            `${window.location.origin}${buildAppUrl("Practice/Index/ownership-management")}?userId=${encodeURIComponent(id)}`);
        }
        return;
      }
      alert(raw || "Unable to mark the record inactive.");
    }
  }

  // 287. "Practice Instances" from a Practice or an Organization
  // Requirement row. Opens Operationalize filtered to that parent.
  //
  // organizationId travels with it deliberately: Operationalize picks its
  // organization from a shared picker with its own default, so without it
  // the page could land on one organization and apply a practice filter
  // from another -- an empty list that reads as "no instances" rather
  // than "wrong organization".
  function openInstancesFor(record, scopeParam, id) {
    const params = new URLSearchParams();
    params.set(scopeParam, String(id));
    const orgId = valueOf(record, "OrganizationId") || organizationFilter?.value || "";
    if (orgId) params.set("organizationId", String(orgId));
    // Label only, for the banner. The filter itself is the id above.
    const label = [valueOf(record, "Code"), valueOf(record, "Name")].filter(Boolean).join(" - ");
    if (label) params.set("scopeLabel", label);
    window.location.assign(
      `${window.location.origin}${buildAppUrl("Practice/Index/resolve")}?${params.toString()}`);
  }

  // "New Practice Instance" on an Organization Requirement row.
  //
  // The requirement is seeded straight into the form rather than being
  // carried through a navigation code, because there is no navigation:
  // the dialog opens over the grid the user is already looking at.
  //
  // The seed mirrors what the navigationContext branch in openForm sets
  // for a requirement-scoped add -- requirement, organisation, and the
  // three defaults an instance is created with -- so the two entry
  // points produce the same record.
  async function openNewPracticeInstance(record, requirementId) {
    const organizationId = valueOf(record, "OrganizationId")
      || organizationFilter?.value
      || state.navigationContext?.organizationId
      || "";

    // The lookups the instance form needs are not necessarily loaded on
    // this screen -- it has its own, smaller set. Without this the owner,
    // frequency and business-function selects would open empty.
    await loadLookups();

    await openForm("add", 0, {
      entity: "practice-instances",
      seed: {
        organizationRequirementId: requirementId,
        OrganizationRequirementId: requirementId,
        organizationId,
        OrganizationId: organizationId,
        // Same three defaults Configure (139) writes, so an instance
        // created here starts life identically to one created there.
        assuranceMode: "Manual",  AssuranceMode: "Manual",
        criticality:   "Medium",  Criticality:   "Medium",
        status:        "Active",  Status:        "Active"
      }
    });
  }

  async function navigateWithContext(targetArea, filterType, filterId, displayCode, displayName) {
    const code = await createNavigationCode({
      sourceArea: screen.Key,
      targetArea,
      filterType,
      filterId: Number(filterId),
      organizationId: arguments.length > 5 ? Number(arguments[5]) : null,
      organizationControlId: arguments.length > 6 ? Number(arguments[6]) : null,
      organizationRequirementId: arguments.length > 8 ? Number(arguments[8]) : null,
      releaseId: arguments.length > 9 ? (Number(arguments[9]) || null) : null,
      displayStatus: arguments.length > 7 ? String(arguments[7] || "") : "",
      displayCode: displayCode || "",
      displayName: displayName || ""
    });
    window.location.assign(`${window.location.origin}${buildAppUrl(`Practice/Index/${targetArea}`)}?code=${encodeURIComponent(code)}`);
  }

  function handleAction(action, index) {
    // Rule 3 — release-level actions on the Source Statements Level 1 grid.
    if (isSourceStatements && sourceStatementState.level === "releases"
        && (action === "releaseView" || action === "releaseUpdateOwner"
            || action === "releaseEdit" || action === "releaseRetire")) {
      const release = sourceStatementState.releases[Number(index)];
      if (!release) return placeholderAction(action);
      if (action === "releaseView") {
        sourceStatementState.release = mapReleaseSelection(release);
        sourceStatementState.isCustomRelease = Number(valueOf(release, "ReleaseId") || 0) < 0
          || String(valueOf(release, "SubscriptionType") || "").toLowerCase() === "custom";
        sourceStatementState.level = "statements";
        return loadSourceStatements();
      }
      if (action === "releaseUpdateOwner") return openReleaseOwnerForm(release);
      if (action === "releaseEdit") return openCustomReleaseForm(release);
      if (action === "releaseRetire") return retireCustomRelease(release);
    }
    const record = state.records[Number(index)] || {};
    if (isSourceStatements && sourceStatementState.level === "statements" && sourceStatementState.isCustomRelease) {
      if (action === "view") return openCustomStatementView(record);
      if (action === "edit") return openCustomStatementForm(record);
      if (action === "inactive") return inactivateCustomStatement(record);
      return placeholderAction(action);
    }
    if (isSourceStatements && sourceStatementState.level === "statements") {
      if (action === "view") return openStatementView(record);
      if (action === "markApplicability" || action === "updateApplicability") return openStatementApplicabilityForm(record);
      if (action === "practices") {
        // Statement -> Practices: context carries FrameworkStatementId + ReleaseId.
        // organizationControlId is null — the Control concept is not part of this flow.
        return navigateWithContext(
          "organization-requirements",
          "FrameworkStatement",
          valueOf(record, "FrameworkStatementId"),
          valueOf(record, "StatementReference"),
          valueOf(record, "StatementTitle"),
          Number(sourceStatementState.release?.organizationId || organizationFilter?.value || 0) || null,
          null,
          valueOf(record, "ApplicabilityStatus"),
          null,
          Number(sourceStatementState.release?.releaseId || 0) || null
        ).catch(error => alert(error.message));
      }
      return placeholderAction(action);
    }
    if (screen.Key === "user-role-assignments" && (action === "manageRoles" || action === "view")) {
      return openUserRoleAssignmentForm(record, action === "view");
    }
    const id = valueOf(record, "Id");
    if (action === "resendCredentials" && screen.Key === "users") return resendUserCredentials(record);
    // Practice View is a full page, not a modal: it carries the practice
    // header, its obligations and the Configure panel, and a modal would put
    // all three inside a scrolling box within a scrolling page.
    //
    // Two screens show practices. The one in the menu ("Organization
    // Practices") is screen.Key "organization-requirements" -- titled
    // "Practices", one row per requirement, carrying the practice fields and
    // a PracticeId. "practices" is the older standalone grid. Both route
    // here; only the id differs, because on the requirement screen the row
    // Id is the organization_requirement_id, not the practice.
    if (action === "view" && (screen.Key === "practices" || screen.Key === "organization-requirements")) {
      // valueOf only tries the given name and its first-letter-uppercased
      // form, so "PracticeId" misses a camelCase "practiceId" payload.
      const practiceId = screen.Key === "practices"
        ? id
        : (valueOf(record, "practiceId") || valueOf(record, "PracticeId"));

      // The Organization Practices grid is one row per organization_requirement
      // and does not reliably carry a practice id, so navigate on whichever
      // identifier this row actually has. sp_practice_detail_get resolves the
      // practice from either. Making the page depend on a single column is
      // what left View silently opening the old modal.
      const filterType = practiceId ? "Practice" : "OrganizationRequirement";
      const filterId   = practiceId || id;

      if (filterId) {
        return navigateWithContext("practice-view", filterType, filterId,
          valueOf(record, "Code"), valueOf(record, "Name"),
          valueOf(record, "OrganizationId"),
          state.navigationContext?.organizationControlId || null,
          valueOf(record, "ApplicabilityStatus"),
          screen.Key === "organization-requirements" ? id : valueOf(record, "OrganizationRequirementId"))
          .catch(error => alert(error.message));
      }

      console.warn("[practice-view] Row has neither a practice id nor an id; opening the modal.",
        Object.keys(record || {}));
    }
    if (action === "view" || action === "edit") openForm(action, id);
    else if (action === "markApplicability" || action === "updateApplicability") openForm("applicability", id);
    else if (action === "inactive") retire(id);
    else if (action === "manage" && screen.Key === "organizations") navigateWithContext("control-applicability", "Organization", id, valueOf(record, "Code"), valueOf(record, "Name")).catch(error => alert(error.message));
    // The organization-requirements arm is gone with the menu entry that was
    // its only caller -- the Practice View lists the instances now. The
    // "practices" arm below is untouched and still reaches openInstancesFor.
    //
    // 287. It opens Operationalize filtered, not the Practice Instances grid.
    // NOT via navigateWithContext: that posts a navigation code and lands on
    // Practice/Index/{area}?code=..., which only the generic grid knows how to
    // read. 'resolve' stopped being a generic grid at 140/141 and is its own
    // partial, so it takes plain query parameters instead.
    // Opens the Practice Instance add form as a dialog ON THIS PAGE.
    //
    // It used to navigate to the Practice Instances screen and open the
    // form there, which worked but threw the user onto a different page
    // to create a child of the row they were looking at. The form's
    // practice-instance behaviour now follows state.formEntity rather
    // than screen.Key -- see isFormFor() -- so it behaves identically
    // wherever it is opened, and the requirement is seeded directly
    // instead of being carried through a navigation code.
    else if (action === "newInstance" && screen.Key === "organization-requirements")
      openNewPracticeInstance(record, id).catch(error => alert(error.message));
    else if (action === "instances" && screen.Key === "practices")
      openInstancesFor(record, "practiceId", id);
    else if (action === "practices" && screen.Key === "organization-controls") navigateWithContext("organization-requirements", "OrganizationControl", id, valueOf(record, "Code"), valueOf(record, "Name"), valueOf(record, "OrganizationId"), id, valueOf(record, "ApplicabilityStatus")).catch(error => alert(error.message));
    else if (action === "evidence" && screen.Key === "practice-instances") openForm("edit", id);
    else if (action === "dependencies" && screen.Key === "practice-instances") navigateWithContext("dependencies", "PracticeInstance", id, valueOf(record, "Code"), valueOf(record, "Name")).catch(error => alert(error.message));
    else if (action === "viewOperationalization" && (screen.Key === "practice-operationalization" || screen.Key === "resolve")) openOperationalization(record, true).catch(error => alert(error.message));
    else if ((action === "resolveDependencies" || action === "modifyDependencies") && (screen.Key === "practice-operationalization" || screen.Key === "resolve")) openOperationalization(record, false).catch(error => alert(error.message));
    else if (action === "viewOperationalization" && workbenchScreens.has(screen.Key)) openOperationalization(record, true).catch(error => alert(error.message));
    else if ((action === "resolveDependencies" || action === "modifyDependencies") && workbenchScreens.has(screen.Key)) openOperationalization(record, false).catch(error => alert(error.message));
    else placeholderAction(action);
  }

  if (screen.Key === "organizations" || isOrganizationWorkspace) {
    loadLookups().then(initOrganizationSetup).catch(error => {
      if (setupMessage) {
        setupMessage.textContent = error.message || "Unable to load Organization Setup.";
        setupMessage.hidden = false;
      }
      console.error("Organization Setup initial load failed.", error);
    });
    return;
  }

  if ((isRolePermissionMatrix || screen.Key === "user-role-assignments") && addButton) addButton.hidden = true;

  // Practice Instances are no longer created here. Configure, on the practice
  // page, creates one per team with a derived code, name and owner -- typing
  // those three by hand was both work and a source of drift. View and Edit
  // stay: owner, frequencies, criticality and department are still set here.
  if (screen.Key === "practice-instances" && addButton) addButton.hidden = true;
  rows.addEventListener("change", event => {
    if (!isRolePermissionMatrix) return;
    const roleSelect = event.target.closest("[data-permission-role]");
    if (roleSelect) {
      permissionMatrixState.roleId = roleSelect.value;
      renderRolePermissionMatrix();
    }
  });
  rows.addEventListener("click", event => {
    if (isRolePermissionMatrix) {
      const saveTrigger = event.target.closest("[data-permission-save]");
      if (saveTrigger) {
        saveRolePermissionMatrix(saveTrigger);
        return;
      }
    }
    if (isSourceStatements) {
      const back = event.target.closest("[data-release-back]");
      if (back) {
        // On the dedicated Source Statements screen the release list is
        // owned by the sibling Repository Subscriptions menu -- redirect
        // there rather than showing the list under the wrong URL/heading.
        if (isSourceStatementDetail) {
          window.location.href = "/Practice/Index/organization-controls";
          return;
        }
        sourceStatementState.level = "releases";
        sourceStatementState.release = null;
        sourceStatementState.isCustomRelease = false;
        sourceStatementState.collapsedNodes.clear();
        if (subscribedFrameworkFilter) subscribedFrameworkFilter.value = "";
        loadRows();
        return;
      }
      const addCustomStmt = event.target.closest("[data-custom-add-statement]");
      if (addCustomStmt) { openCustomStatementForm(); return; }
      const toggle = event.target.closest("[data-node-toggle]");
      if (toggle) {
        const nodeId = toggle.dataset.nodeToggle;
        sourceStatementState.collapsedNodes.has(nodeId)
          ? sourceStatementState.collapsedNodes.delete(nodeId)
          : sourceStatementState.collapsedNodes.add(nodeId);
        renderStatementTree();
        return;
      }
      const releaseRow = event.target.closest("[data-release-index]");
      if (releaseRow && !event.target.closest(".pm-action-trigger")) {
        const release = sourceStatementState.releases[Number(releaseRow.dataset.releaseIndex)] || {};
        const releaseId = Number(valueOf(release, "ReleaseId") || 0);
        const isCustom = releaseId < 0;
        sourceStatementState.isCustomRelease = isCustom;
        sourceStatementState.release = {
          releaseId: valueOf(release, "ReleaseId"),
          subscriptionId: isCustom ? Math.abs(releaseId) : null,
          organizationId: organizationFilter?.value || "",
          organizationName: (organizationFilter?.selectedOptions?.[0]?.textContent || "").trim(),
          authority: valueOf(release, "Authority") || valueOf(release, "AuthorityCode") || "",
          artifactName: valueOf(release, "ArtifactName") || valueOf(release, "ArtifactCode") || "",
          releaseVersion: valueOf(release, "ReleaseVersion") || "",
          title: valueOf(release, "FrameworkRelease") || `${valueOf(release, "ArtifactName")} ${valueOf(release, "ReleaseVersion")}`.trim()
        };
        // Drill-down context rule: parent context auto-populates the filters so the
        // user never re-selects them (organization stays as-is, framework release is
        // selected to match the clicked row instead of resetting to "All").
        if (subscribedFrameworkFilter) {
          const releaseValue = String(valueOf(release, "ReleaseId") ?? "");
          if ([...subscribedFrameworkFilter.options].some(option => String(option.value) === releaseValue)) {
            subscribedFrameworkFilter.value = releaseValue;
          }
        }
        sourceStatementState.level = "statements";
        sourceStatementState.collapsedNodes.clear();
        loadRows();
        return;
      }
      // Statement row-click -> Organization Practices (mapped to this statement
      // under the current organization). Reuses the exact same navigation the
      // "Practices" 3-dot action performs (handleAction's "practices" branch ->
      // navigateWithContext with FrameworkStatement). Only rows rendered with
      // data-statement-index are eligible (see renderStatementTree's gating);
      // clicks on the action menu, the bulk checkbox or any inner control are
      // left to their own handlers.
      const statementRow = event.target.closest("[data-statement-index]");
      if (statementRow
          && !event.target.closest(".pm-action-trigger")
          && !event.target.closest(".pm-select-cell")
          && !event.target.closest("a, button, input, label")) {
        handleAction("practices", Number(statementRow.dataset.statementIndex));
        return;
      }
    }
    const trigger = event.target.closest(".pm-action-trigger");
    if (!trigger) return;
    event.stopPropagation();
    if (actionTrigger === trigger) closeActionMenu();
    else openActionMenu(trigger);
  });
  document.addEventListener("click", event => {
    if (event.target.closest("[data-close-obligation-modal]")) {
      document.querySelector("#obligationReferenceModal")?.remove();
      return;
    }
    const releaseToggle = event.target.closest("[data-obligation-release-toggle]");
    if (releaseToggle) {
      const releaseKey = releaseToggle.dataset.obligationReleaseToggle;
      state.obligationCollapsed.has(releaseKey)
        ? state.obligationCollapsed.delete(releaseKey)
        : state.obligationCollapsed.add(releaseKey);
      renderObligationModalRows();
      return;
    }
    const menuButton = event.target.closest(".pm-action-menu button[data-action]");
    if (menuButton) {
      const { action, index } = menuButton.dataset;
      closeActionMenu();
      handleAction(action, index);
      return;
    }
    if (!event.target.closest(".pm-action-menu") && !event.target.closest(".pm-action-trigger")) closeActionMenu();
  });
  // Bound to document.body, not fieldsHost, because Manage.cshtml declares
  // TWO elements with id="recordFields" (add and edit modes); a document-
  // level delegated listener finds whichever one is actually visible.
  //
  // NOTE: this listener sits AFTER the organization-workspace early return
  // ("if (screen.Key === \"organizations\" || isOrganizationWorkspace) { ...
  // return; }", earlier in this file), so it never binds at all on
  // Organization Administration / Onboarding / Dependencies screens. That
  // is fine for everything still handled here (checkCombo trigger for
  // non-org screens, dependency/evidence rows, obligation viewer,
  // operationalization resolution rows -- none of these appear on
  // organization-workspace screens, which have their own separate
  // checkCombo/action handling inside initOrganizationSetup()). The Team
  // Members tree toggle and Committee Members handlers used to live here
  // too, but DO need to work on organization-workspace screens (Teams and
  // Committees are managed there), so they were moved to their own
  // pmCommitteeAndTeamClick listener near the top of the file, alongside
  // pmCascade, where they run before that early return.
  document.body.addEventListener("click", event => {
    const checkComboTrigger = event.target.closest("[data-checkcombo-trigger]");
    if (checkComboTrigger) {
      event.preventDefault();
      const combo = checkComboTrigger.closest("[data-checkcombo]");
      const menu = combo?.querySelector("[data-checkcombo-menu]");
      if (!menu) return;
      document.querySelectorAll("[data-checkcombo-menu]").forEach(item => { if (item !== menu) item.hidden = true; });
      menu.hidden = !menu.hidden;
      if (!menu.hidden) menu.querySelector("[data-checkcombo-search]")?.focus();
      return;
    }
    const addDependency = event.target.closest("#addDependencyRow");
    if (addDependency) {
      event.preventDefault();
      const body = fieldsHost.querySelector("#dependencyRows");
      body?.insertAdjacentHTML("beforeend", dependencyRow({}, false));
      loadDependencyOptionsForRow(body?.lastElementChild).catch(error => alert(error.message));
      return;
    }
    const removeDependency = event.target.closest(".pm-dependency-remove");
    if (removeDependency) {
      event.preventDefault();
      const row = removeDependency.closest("[data-dependency-row]");
      const body = row?.parentElement;
      row?.remove();
      if (body && !body.querySelector("[data-dependency-row]")) {
        body.insertAdjacentHTML("beforeend", dependencyRow({}, false));
        loadDependencyOptionsForRow(body.lastElementChild).catch(error => alert(error.message));
      }
      return;
    }
    const addEvidence = event.target.closest("#addEvidenceRow");
    if (addEvidence) {
      event.preventDefault();
      const body = fieldsHost.querySelector("#evidenceRows");
      if (!body) return;
      if (!body.querySelector("[data-evidence-row]")) body.innerHTML = "";
      body.insertAdjacentHTML("beforeend", evidenceRow({ ManualEntry: true }, false));
      return;
    }
    const removeEvidence = event.target.closest(".pm-evidence-remove");
    if (removeEvidence) {
      event.preventDefault();
      const row = removeEvidence.closest("[data-evidence-row]");
      const body = row?.parentElement;
      row?.remove();
      if (body && !body.querySelector("[data-evidence-row]")) {
        body.innerHTML = `<tr><td colspan="7" class="pm-empty compact">No evidence configured. Use Add New Evidence, or view obligations for framework recommendations.</td></tr>`;
      }
      return;
    }
    const viewObligations = event.target.closest("#viewEvidenceObligations");
    if (viewObligations) {
      event.preventDefault();
      showEvidenceObligations().catch(error => alert(error.message));
      return;
    }
    const addOpResolution = event.target.closest("#addOperationalizationResolution");
    if (addOpResolution) {
      event.preventDefault();
      const body = fieldsHost.querySelector("#opResolutionRows");
      const dependencyTypeId = fieldsHost.querySelector("[name='dependencyTypeId']")?.value || "";
      const organizationId = fieldsHost.querySelector("[name='organizationId']")?.value || "";
      if (!body) return;
      if (!body.querySelector("[data-op-resolution-row]")) body.innerHTML = "";
      body.insertAdjacentHTML("beforeend", operationalizationResolutionRow({}, false));
      const row = body.lastElementChild;
      const select = row?.querySelector("[data-op-field='resolvedDependencyId']");
      loadOperationalizationDependencyOptions(dependencyTypeId, organizationId, "", select).catch(error => alert(error.message));
      return;
    }
    const removeOpResolution = event.target.closest(".pm-op-resolution-remove");
    if (removeOpResolution) {
      event.preventDefault();
      const row = removeOpResolution.closest("[data-op-resolution-row]");
      const body = row?.parentElement;
      row?.remove();
      if (body && !body.querySelector("[data-op-resolution-row]")) {
        body.innerHTML = `<tr><td colspan="4" class="pm-empty compact">No resolved dependencies saved.</td></tr>`;
      }
    }
  });
  // Cascade change listener is attached to document.body rather than
  // fieldsHost because Manage.cshtml declares TWO elements with
  // id="recordFields" (add and edit modes) -- querySelector picks the
  // first, and the visible dialog often turns out to be the second one.
  // A document-level delegated listener finds the current active dialog
  // whichever one it is; the `child` container is discovered from the
  // event target itself.
  // Cascade block moved OUT of this listener because the IIFE returns
  // early on organization-workspace screens (see line ~5005), and
  // Add Asset lives inside organization-dependencies. The cascade now
  // attaches to document.body at the very top of the file (search for
  // "pmCascade top-level attach"), so it survives the early return.
  document.body.addEventListener("change", event => {
    const checkComboInput = event.target.closest("[data-checkcombo] input[type='checkbox']");
    if (checkComboInput) {
      const combo = checkComboInput.closest("[data-checkcombo]");
      const labels = [...combo.querySelectorAll("input[type='checkbox']:checked")].map(item => item.closest("label").querySelector("span").textContent.trim());
      combo.querySelector("[data-checkcombo-text]").textContent = labels.join(", ") || "Select...";
      combo.dataset.selectedReference = [...combo.querySelectorAll("input[type='checkbox']:checked")].map(item => item.value).join(",");
    }
    if (isFormFor("practice-instances") && event.target?.name === "frequencyId") updateFrequencyFields();
    if (isFormFor("practice-instances") && event.target?.name === "primaryOwnerId") updateOwnerDepartment().catch(error => alert(error.message));
    const dependencyType = event.target.closest("[data-dependency-field='dependencyTypeId']");
    if (isFormFor("practice-instances") && dependencyType) {
      const row = dependencyType.closest("[data-dependency-row]");
      const picker = row?.querySelector("[data-dependency-picker]");
      if (picker) {
        picker.dataset.selectedReference = "";
        picker.dataset.sourceType = "";
        picker.querySelector("[data-checkcombo-text]").textContent = "Select dependency...";
      }
      loadDependencyOptionsForRow(row).catch(error => alert(error.message));
    }
    if ((screen.Key === "practice-operationalization" || screen.Key === "resolve") && event.target?.name === "dependencyTypeId") {
      const organizationId = fieldsHost.querySelector("[name='organizationId']")?.value || "";
      fieldsHost.querySelectorAll("[data-op-resolution-row]").forEach(row => {
        row.dataset.selectedDependencyId = "";
        const select = row.querySelector("[data-op-field='resolvedDependencyId']");
        if (select) select.innerHTML = `<option value="">Dependency Objects Loading...</option>`;
      });
      if (saveButton) saveButton.hidden = !event.target.value;
      hydrateOperationalizationResolutionRows(event.target.value, organizationId).catch(error => {
        formMessage.textContent = error.message;
        formMessage.hidden = false;
      });
    }
  });
  document.addEventListener("input", event => {
    const checkComboSearch = event.target.closest("[data-checkcombo-search]");
    if (checkComboSearch) {
      const term = checkComboSearch.value.trim().toLowerCase();
      checkComboSearch.closest("[data-checkcombo-menu]")?.querySelectorAll("[data-checkcombo-option]").forEach(option => {
        option.hidden = term && !option.textContent.toLowerCase().includes(term);
      });
      return;
    }
    const obligationFilter = event.target.closest("[data-obligation-filter]");
    if (!obligationFilter || obligationFilter.dataset.obligationFilter === "practice") return;
    state.obligationFilters[obligationFilter.dataset.obligationFilter] = obligationFilter.value;
    renderObligationModalRows();
  });
  document.addEventListener("change", event => {
    const obligationFilter = event.target.closest("select[data-obligation-filter]");
    if (!obligationFilter || obligationFilter.dataset.obligationFilter === "practice") return;
    state.obligationFilters[obligationFilter.dataset.obligationFilter] = obligationFilter.value;
    renderObligationModalRows();
  });
  window.addEventListener("resize", closeActionMenu);
  window.addEventListener("scroll", closeActionMenu, true);
  addButton?.addEventListener("click", () => {
    if (isSourceStatements) {
      if (sourceStatementState.level === "statements") {
        openCustomStatementForm();
      } else {
        openCustomReleaseForm();
      }
      return;
    }
    openForm("add");
  });
  saveButton?.addEventListener("click", saveForm);
  closeButton?.addEventListener("click", () => dialog.close());
  cancelButton?.addEventListener("click", () => dialog.close());
  editButton?.addEventListener("click", handleEditFromView);
  refresh?.addEventListener("click", loadRows);
  workbenchCategories?.addEventListener("click", event => {
    const button = event.target.closest("[data-workbench-category]");
    if (!button) return;
    state.activeWorkbenchDependencyTypeId = button.dataset.workbenchCategory || "";
    state.activeWorkbenchLabel = button.textContent.trim() || "All Dependency Categories";
    resetToFirstPage();
  });
  search?.addEventListener("input", () => window.clearTimeout(search._t) || (search._t = window.setTimeout(resetToFirstPage, 250)));
  status?.addEventListener("change", resetToFirstPage);
  organizationFilter?.addEventListener("change", () => {
    rememberOrganizationId(organizationFilter.value);
    if (screen.Key === "organization-requirements") {
      loadSubscribedFrameworks().then(resetToFirstPage).catch(error => alert(error.message));
    } else {
      resetToFirstPage();
    }
  });
  subscribedFrameworkFilter?.addEventListener("change", resetToFirstPage);
  sourceFilter?.addEventListener("change", resetToFirstPage);
  if (isSourceStatements && pageBackBtn) {
    pageBackBtn.addEventListener("click", (e) => {
      if (sourceStatementState.level === "statements") {
        e.preventDefault();
        sourceStatementState.level = "releases";
        sourceStatementState.release = null;
        sourceStatementState.isCustomRelease = false;
        sourceStatementState.collapsedNodes.clear();
        if (subscribedFrameworkFilter) subscribedFrameworkFilter.value = "";
        updateAddButtonLabel();
        loadRows();
      }
    });
  }
  clearFilters?.addEventListener("click", () => {
    if (screen.Key === "organization-requirements") resetOrganizationRequirementFilters().catch(error => alert(error.message));
    else if (isSourceStatements) {
      if (search) search.value = "";
      if (status) status.value = "";
      if (subscribedFrameworkFilter) subscribedFrameworkFilter.value = "";
      if (sourceFilter) sourceFilter.value = "";
      resetToFirstPage();
    }
  });
  originTypeFilter?.addEventListener("change", resetToFirstPage);
  criticalityFilter?.addEventListener("change", resetToFirstPage);
  ownerFilter?.addEventListener("input", () => window.clearTimeout(ownerFilter._t) || (ownerFilter._t = window.setTimeout(resetToFirstPage, 250)));
  dateFromFilter?.addEventListener("change", resetToFirstPage);
  dateToFilter?.addEventListener("change", resetToFirstPage);
  // Previous / Next / rows-per-page are pm-grid's own controls now. It
  // fires onChange -> loadRows() for all three, and bounds Next by the
  // total, so the old "records.length >= pageSize" guess -- which left
  // Next enabled on a full last page and landed the user on an empty
  // grid -- is gone with the buttons it guarded.

  // Row checkboxes are delegated. The grid is re-rendered wholesale on every
  // load, so per-checkbox listeners would have to be re-attached each time and
  // would leak on the renders in between.
  rows?.addEventListener("change", event => {
    const box = event.target?.closest?.("input.pm-row-select");
    if (!box) return;
    const id = Number(box.dataset.bulkId) || 0;
    if (!id) return;
    if (box.checked) bulkSelection.add(id); else bulkSelection.delete(id);
    renderBulkButton();
  });
  bulkApplicabilityButton?.addEventListener("click", () => openBulkApplicabilityForm());

  if (isOrganizationWorkspace) {
    loadLookups().then(initOrganizationSetup).catch(error => {
      if (setupMessage) {
        setupMessage.textContent = error.message || "Unable to load Organization Setup.";
        setupMessage.hidden = false;
      }
      console.error("Organization Setup initial load failed.", error);
    });
  } else {
    loadLookups().then(loadNavigationContext).then(loadSubscribedFrameworks).then(loadRows)
      .catch(error => {
        if (rows) {
          rows.innerHTML = `<tr><td colspan="${(screen.Columns?.length || 0) + 1}" class="pm-empty">${escapeHtml(error.message || "Unable to load Practice Management data.")}</td></tr>`;
        }
        console.error("PracticeManagement initial load failed.", error);
      });
  }
})();
