(() => {
  "use strict";

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
  const formMessage = document.querySelector("#formMessage");
  const addButton = document.querySelector("#addRecord");
  const saveButton = document.querySelector("#saveRecord");
  const closeButton = document.querySelector("#closeRecord");
  const cancelButton = document.querySelector("#cancelRecord");
  const search = document.querySelector("#search");
  const status = document.querySelector("#status");
  const organizationFilter = document.querySelector("#organizationFilter");
  const subscribedFrameworkFilter = document.querySelector("#subscribedFrameworkFilter");
  const originTypeFilter = document.querySelector("#originTypeFilter");
  const criticalityFilter = document.querySelector("#criticalityFilter");
  const ownerFilter = document.querySelector("#ownerFilter");
  const dateFromFilter = document.querySelector("#dateFromFilter");
  const dateToFilter = document.querySelector("#dateToFilter");
  const previousPage = document.querySelector("#previousPage");
  const nextPage = document.querySelector("#nextPage");
  const pageInfo = document.querySelector("#pageInfo");
  const pageSize = document.querySelector("#pageSize");
  const refresh = document.querySelector("#refresh");
  const clearFilters = document.querySelector("#clearFilters");
  const tableHead = document.querySelector("#practiceGridHead");
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
  const state = { id: 0, mode: "add", records: [], lookups: {}, pageNumber: 1, pageSize: 25, navigationCode: query.get("code") || "", navigationContext: null, activeFormRecord: null, activeDependencies: [], activeEvidence: [], obligationRows: [], obligationFilters: {}, obligationSort: { key: "FrameworkRelease", direction: "asc" }, activeWorkbenchDependencyTypeId: "", activeWorkbenchLabel: "All Dependency Categories" };
  const setupState = { organizationId: "", activeTab: screen.Key === "organization-dependencies" ? "dependency-applications" : "organization", childRows: {}, treeRows: [], collapsed: new Set(), selectedReleases: new Set(), attributes: {}, treeInitialized: false, recommendations: new Map(), recommendationAutoSelected: new Set() };
  const isOrganizationOnboarding = screen.Key === "organization-setup";
  const isOrganizationAdministration = screen.Key === "organization-administration";
  const isOrganizationDependencies = screen.Key === "organization-dependencies";
  const isOrganizationWorkspace = isOrganizationOnboarding || isOrganizationAdministration || isOrganizationDependencies;
  const isOperationalizationWorkbench = screen.Key === "resolve" || screen.Key === "practice-operationalization";
  const workbenchScreens = new Set(["workbench-applications", "workbench-tools", "workbench-vendors", "workbench-assets", "workbench-teams", "workbench-committees", "workbench-processes", "workbench-locations"]);
  const organizationScopedScreens = new Set(["organization-metadata", "repository-subscriptions", "locations", "departments", "business-functions", "teams", "committees", "roles", "role-menu-permissions", "users", "dependency-applications", "dependency-tools", "dependency-vendors", "dependency-assets", "dependency-processes", "user-assignments", "user-role-assignments", "owner-mappings", "organization-controls", "control-applicability", "organization-requirements", "practices", "practice-instances", "practice-operationalization", "resolve", ...workbenchScreens]);
  const lastOrganizationKey = "grac.practice.selectedOrganizationId";
  let actionMenu = null;
  let actionTrigger = null;
  // Source Statements (organization-controls) two-level drill-down:
  // Level 1 = subscribed Framework Release summary, Level 2 = Source
  // Structure tree with Source Statement child rows.
  const isSourceStatements = screen.Key === "organization-controls";
  const sourceStatementState = { level: "releases", release: null, releases: [], rows: [], collapsedNodes: new Set(), isCustomRelease: false };
  const releaseSummaryColumns = ["Framework / Release", "Authority", "Artifact", "Version", "Owner", "Total Statements", "Applicable Statements", "Not Updated Statements", "Not Applicable Statements", "Actions"];
  const statementTreeColumns = ["Source Node / Hierarchy", "Statement Reference", "Statement Title", "Statement Text", "Applicability Status", "Practice Count", "Actions"];
  const customStatementFlatColumns = ["Hierarchy", "Source Structure Node", "Statement Reference", "Statement Title", "Statement Text", "Applicability Status", "Practice Count", "Actions"];
  // Source Structure state for custom releases
  const sourceStructureState = { nodes: [], active: false };
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
    "teams": { title: "Teams", columns: ["Name", "TeamManager", "ParentDepartment", "Status"] },
    "committees": { title: "Committees", columns: ["Name", "Chairperson", "Secretary", "ReviewFrequency", "Status"] },
    "roles": { title: "Role Master", columns: ["Organization", "RoleName", "Description", "Status"] },
    "role-menu-permissions": { title: "Role Menu Permission", columns: ["Organization", "RoleName", "MenuName", "CanView", "CanAdd", "CanEdit", "CanDelete", "CanApprove", "Status"] },
    "users": { title: "Users / Employees", columns: ["EmployeeCode", "EmployeeName", "Email", "RoleName", "Designation", "Location", "BusinessFunction", "ReportingOfficer", "Status"] },
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
    if (workbenchHeading) workbenchHeading.textContent = selected === "evidence" ? "Evidence" : (state.activeWorkbenchLabel || "Resolve");
    if (workbenchHint) workbenchHint.textContent = selected === "evidence"
      ? "Showing Practice Instances configured with evidence."
      : `Showing Practice Instances configured with ${state.activeWorkbenchLabel || "selected"} dependency.`;
  }

  const text = (name, label, required = false, extra = {}) => ({ name, label, type: "text", required, ...extra });
  const password = (name, label, required = false, extra = {}) => ({ name, label, type: "password", required, ...extra });
  const area = (name, label, required = false, extra = {}) => ({ name, label, type: "textarea", required, full: true, ...extra });
  const select = (name, label, lookup, required = false, extra = {}) => ({ name, label, type: "select", lookup, required, ...extra });
  const number = (name, label, required = false, extra = {}) => ({ name, label, type: "number", required, ...extra });
  const date = (name, label, required = false) => ({ name, label, type: "date", required });
  const hidden = name => ({ name, label: name, type: "hidden" });

  const staticLookups = {
    "origin-types": [{ value: "Repository", label: "Repository" }, { value: "Organization", label: "Organization" }, { value: "Hybrid", label: "Hybrid" }],
    "criticality": [{ value: "Critical", label: "Critical" }, { value: "High", label: "High" }, { value: "Medium", label: "Medium" }, { value: "Low", label: "Low" }],
    "assurance-modes": [{ value: "Manual", label: "Manual" }, { value: "Automated", label: "Automated" }],
    "subscription-types": [{ value: "Automatic", label: "Automatic" }, { value: "Manual", label: "Manual" }],
    "frequency-master": [{ value: "1", label: "Daily" }, { value: "2", label: "Weekly" }, { value: "3", label: "Monthly" }, { value: "4", label: "Quarterly" }, { value: "5", label: "Half-Yearly" }, { value: "6", label: "Annual" }, { value: "7", label: "Event Driven" }, { value: "8", label: "Continuous" }, { value: "9", label: "Custom" }],
    "frequency-units": [{ value: "Day", label: "Day" }, { value: "Week", label: "Week" }, { value: "Month", label: "Month" }, { value: "Quarter", label: "Quarter" }, { value: "Year", label: "Year" }],
    "frequency-units": [{ value: "Day", label: "Day" }, { value: "Week", label: "Week" }, { value: "Month", label: "Month" }, { value: "Year", label: "Year" }],
    "collection-methods": [{ value: "1", label: "Manual" }, { value: "2", label: "Automated" }],
    "assurance-types": [{ value: "1", label: "Manual" }, { value: "2", label: "Automated" }],
    "organization-roles": [{ value: "Owner", label: "Owner" }, { value: "Reviewer", label: "Reviewer" }, { value: "Approver", label: "Approver" }, { value: "Practice Owner", label: "Practice Owner" }, { value: "Evidence Owner", label: "Evidence Owner" }],
    "owner-roles": [{ value: "Primary Owner", label: "Primary Owner" }, { value: "Secondary Owner", label: "Secondary Owner" }, { value: "Practice Owner", label: "Practice Owner" }, { value: "Evidence Owner", label: "Evidence Owner" }, { value: "Location Head", label: "Location Head" }, { value: "Department Head", label: "Department Head" }],
    "evidence-alignment-status": [{ value: "1", label: "Inherited" }, { value: "2", label: "Enhanced" }, { value: "3", label: "Partially Aligned" }, { value: "4", label: "Organization Defined" }]
  };
  /* Fallback dependency types — IDs are approximate and may not match actual DB IDENTITY values.
     These are superseded by state.lookups["dependency-types"] once the API lookups load. */
  const fallbackDependencyTypes = [{ value: "1", label: "Application" }, { value: "2", label: "Tool" }, { value: "3", label: "Vendor" }, { value: "4", label: "Asset" }, { value: "5", label: "Process" }, { value: "6", label: "Location" }, { value: "7", label: "Person" }, { value: "8", label: "Team" }, { value: "9", label: "Committee" }];
  const fallbackEvidenceTypes = [{ value: "1", label: "Policy Document" }, { value: "2", label: "Procedure Document" }, { value: "3", label: "System Screenshot" }, { value: "4", label: "System Report" }, { value: "5", label: "Audit Log" }];

  const schemas = {
    "organizations": [text("code", "Organization Code", true), text("name", "Organization Name", true), text("industry", "Industry"), text("entityType", "Entity Type"), text("country", "Country"), select("status", "Status", "status-active", true)],
    "organization-metadata": [select("organizationId", "Organization", "organizations", true), text("metadataKey", "Metadata Key", true), text("metadataName", "Metadata Name", true), select("dataType", "Data Type", "data-types", true), area("valueText", "Value"), select("status", "Status", "status-active", true)],
    "repository-subscriptions": [select("organizationId", "Organization", "organizations", true), number("authorityId", "Repository Authority ID"), number("artifactId", "Repository Artifact ID"), number("releaseId", "Repository Release ID"), select("subscriptionType", "Subscription Type", "subscription-types", true), select("subscriptionStatus", "Subscription Status", "subscription-status", true), date("effectiveDate", "Effective Date"), date("endDate", "End Date"), select("status", "Status", "status-active", true)],
    "locations": [select("organizationId", "Organization", "organizations", true), text("name", "Location Name", true), select("locationTypeId", "Location Type", "location-types", true), select("locationHeadId", "Location Head", "users-id"), text("region", "Region"), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "departments": [select("organizationId", "Organization", "organizations", true), text("code", "Department Code", true), text("name", "Department Name", true), select("headUserId", "Department Head", "users-id"), area("description", "Description"), select("status", "Status", "status-active", true)],
    "business-functions": [select("organizationId", "Organization", "organizations", true), text("code", "Function Code", true), text("name", "Function Name", true), select("ownerName", "Owner", "users"), select("criticality", "Criticality", "criticality", true), select("status", "Status", "status-active", true)],
    "teams": [select("organizationId", "Organization", "organizations", true), text("name", "Team Name", true), select("teamManagerId", "Team Manager", "users-id"), select("parentDepartmentId", "Parent Department", "departments"), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "committees": [select("organizationId", "Organization", "organizations", true), text("name", "Committee Name", true), select("chairpersonId", "Chairperson", "users-id"), select("secretaryId", "Secretary", "users-id"), select("reviewFrequencyId", "Review Frequency", "frequency-master"), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "roles": [select("organizationId", "Organization", "organizations", true), text("roleCode", "Role Code"), text("roleName", "Role Name", true), area("description", "Description")],
    "role-menu-permissions": [select("organizationId", "Organization", "organizations", true), select("roleId", "Role", "roles", true), select("menuId", "Menu", "menus", true), { name: "canView", label: "View", type: "checkbox" }, { name: "canAdd", label: "Add", type: "checkbox" }, { name: "canEdit", label: "Edit", type: "checkbox" }, { name: "canDelete", label: "Delete", type: "checkbox" }, { name: "canApprove", label: "Approve", type: "checkbox" }, select("statusId", "Status", "record-status", true)],
    "users": [select("organizationId", "Organization", "organizations", true), text("employeeCode", "Employee Code / User ID", true), text("employeeName", "Employee Name", true), text("email", "Email ID", true), password("password", "Password"), select("roleId", "Role", "roles", true), text("designation", "Designation"), select("locationId", "Location", "locations"), select("businessFunctionId", "Business Function", "business-functions"), select("reportingOfficerId", "Reporting Officer", "users-id"), select("status", "Status", "status-active", true)],
    "dependency-applications": [select("organizationId", "Organization", "organizations", true), text("name", "Application Name", true), area("description", "Description"), select("businessOwnerId", "Business Owner", "users-id"), select("technicalOwnerId", "Technical Owner", "users-id"), select("vendorId", "Vendor", "dependency-vendors"), text("version", "Version"), select("hostingTypeId", "Hosting Type", "hosting-types"), date("supportExpiryDate", "Support Expiry Date"), date("endOfLifeDate", "End of Life Date"), select("criticalityId", "Criticality", "criticality-master", true), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "dependency-tools": [select("organizationId", "Organization", "organizations", true), text("name", "Tool Name", true), area("description", "Description"), select("businessOwnerId", "Business Owner", "users-id"), select("vendorId", "Vendor", "dependency-vendors"), select("licenseTypeId", "License Type", "license-types"), date("licenseExpiryDate", "License Expiry Date"), date("supportExpiryDate", "Support Expiry Date"), select("criticalityId", "Criticality", "criticality-master", true), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "dependency-vendors": [select("organizationId", "Organization", "organizations", true), text("name", "Vendor Name", true), select("serviceCategoryId", "Service Category", "service-categories", true), select("relationshipOwnerId", "Relationship Owner", "users-id"), date("contractStartDate", "Contract Start Date"), date("contractEndDate", "Contract End Date"), date("renewalDate", "Renewal Date"), { name: "slaApplicable", label: "SLA Applicable", type: "checkbox" }, select("criticalityId", "Criticality", "criticality-master", true), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "dependency-assets": [select("organizationId", "Organization", "organizations", true), text("name", "Asset Name", true), select("assetCategoryId", "Asset Category", "asset-categories", true), select("ownerId", "Owner", "users-id"), select("locationId", "Location", "locations"), date("purchaseDate", "Purchase Date"), date("warrantyExpiryDate", "Warranty Expiry Date"), date("amcExpiryDate", "AMC Expiry Date"), select("criticalityId", "Criticality", "criticality-master", true), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "dependency-processes": [select("organizationId", "Organization", "organizations", true), text("name", "Process Name", true), select("processOwnerId", "Process Owner", "users-id"), text("version", "Version"), date("effectiveDate", "Effective Date"), date("lastReviewDate", "Last Review Date"), date("nextReviewDate", "Next Review Date"), area("remarks", "Remarks"), select("statusId", "Status", "record-status", true)],
    "user-assignments": [select("organizationId", "Organization", "organizations", true), select("departmentId", "Department", "departments"), select("userId", "User", "users-id", true), select("role", "Role", "organization-roles", true), select("status", "Status", "status-active", true)],
    "owner-mappings": [select("organizationId", "Organization", "organizations", true), select("role", "Owner Role", "owner-roles", true), select("ownerUserId", "Owner", "users-id", true), select("backupOwnerUserId", "Backup Owner", "users-id"), select("status", "Status", "status-active", true)],
    "organization-controls": [select("organizationId", "Organization", "organizations", true), text("code", "Statement Code", true), text("name", "Statement Name", true), area("description", "Description"), area("objective", "Objective"), area("businessJustification", "Business Justification"), select("status", "Status", "status-active", true)],
    "control-applicability": [select("organizationId", "Organization", "organizations", false, { readonly: true }), text("code", "Control Code", false, { readonly: true }), text("name", "Control Name", false, { readonly: true }), select("originType", "Origin Type", "origin-types", false, { readonly: true }), text("isManuallyAdded", "Manually Added", false, { readonly: true }), select("applicabilityStatus", "Applicability Status", "applicability-status", true), area("exclusionJustification", "Justification"), select("primaryOwner", "Primary Owner", "users"), select("secondaryOwner", "Secondary Owner", "users"), select("businessFunctionId", "Business Function", "business-functions"), select("criticality", "Criticality", "criticality", true), select("status", "Status", "status-active", true)],
    "organization-requirements": [select("organizationId", "Organization", "organizations", true), hidden("originType"), hidden("applicabilityStatus"), hidden("status"), hidden("implementationStatus"), text("code", "Practice Code", true), text("name", "Practice Name", true), area("statement", "Description"), select("practiceOwnerId", "Owner", "users-id"), select("businessFunctionId", "Business Function", "business-functions"), select("criticality", "Criticality", "criticality"), area("remarks", "Remarks")],
    "practices": [select("organizationId", "Organization", "organizations", true), hidden("organizationRequirementId"), select("originType", "Origin Type", "origin-types", true), text("code", "Practice Code", true), text("name", "Practice Name", true), area("description", "Description"), select("applicabilityStatus", "Applicability Status", "applicability-status", true), select("practiceOwnerId", "Owner", "users-id"), area("exclusionJustification", "Reason / Justification"), select("status", "Status", "status-active", true)],
    "practice-instances": [hidden("organizationRequirementId"), hidden("practiceId"), select("organizationId", "Organization", "organizations", true, { readonly: true }), text("code", "Instance Code", true), text("name", "Instance Name", true), select("primaryOwnerId", "Instance Owner", "users-id", true), hidden("departmentId"), text("department", "Owner Department", false, { readonly: true }), select("businessFunctionId", "Business Function", "business-functions"), select("executionFrequencyId", "Execution Frequency", "frequency-master", true), select("assuranceFrequencyId", "Assurance Frequency", "frequency-master", true), select("assuranceMode", "Practice Type", "assurance-modes", true), select("criticality", "Criticality", "criticality", true), { name: "dependencyTypeIds", label: "Dependencies", type: "comboChecks", lookup: "dependency-types" }, { name: "evidenceTypeIds", label: "Evidence Types", type: "comboChecks", lookup: "evidence-types" }, select("status", "Status", "status-active", true)],
    "dependencies": [select("practiceInstanceId", "Practice Instance", "practice-instances", true), select("dependencyTypeId", "Dependency Type", "dependency-types", true), text("name", "Dependency Name", true), text("reference", "Reference"), text("ownerName", "Owner"), select("criticalityId", "Criticality", "criticality-master", true), select("statusId", "Status", "record-status", true)],
    "evidence-configurations": [select("practiceInstanceId", "Practice Instance", "practice-instances", true), select("evidenceTypeId", "Evidence Type", "evidence-types", true), select("assuranceTypeId", "Assurance Type", "assurance-types", true), text("retentionPeriod", "Retention Period"), select("collectionMethodId", "Collection Method", "collection-methods", true), select("collectionFrequencyId", "Collection Frequency", "frequency-master"), select("evidenceOwner", "Evidence Owner", "users"), select("statusId", "Status", "record-status", true)]
  };
  const setupBasicSchema = [
    text("code", "Organization Code", true),
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
    "locations": ["view", "edit", "inactive"],
    "departments": ["view", "edit", "inactive"],
    "teams": ["view", "edit", "inactive"],
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
    "organization-requirements": ["viewObligations", "instances", "view"],
    "control-applicability": ["view", "edit"],
    "requirement-applicability": ["view", "edit", "accept", "reject", "practice"],
    "practices": ["view"],
    "practice-instances": ["view", "edit", "configure", "evidence", "dependencies", "inactive"],
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
    viewObligations: "View Obligations",
    viewOperationalization: "View Resolve Details",
    resolveDependencies: "Resolve",
    modifyDependencies: "Modify Dependencies",
    bulkResolution: "Bulk Resolution",
    dependencyIntelligence: "Dependency Intelligence",
    instances: "Practice Instances",
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
    viewObligations: "fa-list-check",
    viewOperationalization: "fa-eye",
    resolveDependencies: "fa-link",
    modifyDependencies: "fa-pen-to-square",
    bulkResolution: "fa-layer-group",
    dependencyIntelligence: "fa-brain",
    instances: "fa-layer-group",
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
    return currentColumns().length + 1;
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
    catch { throw new Error("The practice service returned an invalid response."); }
    if (response.status === 401) {
      window.location.assign(`${window.location.origin}${buildAppUrl("Login")}?returnUrl=${encodeURIComponent(window.location.pathname + window.location.search)}`);
      throw new Error(result.message || result.Message || "Session expired. Please sign in again.");
    }
    if (response.status === 403) throw new Error("You do not have permission to perform this action.");
    if (response.status === 400) throw new Error(result.message || result.Message || "The request is invalid or has expired.");
    if (!(result.success ?? result.Success)) throw new Error(result.message || result.Message || "Request failed.");
    return result;
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
    populateFilters();
  }

  function populateFilters() {
    if (organizationFilter) {
      const organizations = state.lookups.organizations || [];
      const emptyLabel = organizationScopedScreens.has(screen.Key) ? "Select organization" : "All organizations";
      organizationFilter.innerHTML = `<option value="">${emptyLabel}</option>${organizations.map(item => `<option value="${escapeHtml(item.value)}">${escapeHtml(item.label)}</option>`).join("")}`;
      const savedOrganizationId = ["organization-controls", "control-applicability"].includes(screen.Key) ? "" : getSavedOrganizationId();
      if (organizationScopedScreens.has(screen.Key) && !state.navigationCode) {
        const selected = organizations.find(item => String(item.value) === savedOrganizationId) || organizations[0];
        if (selected) organizationFilter.value = String(selected.value);
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
    if (!["employees", "employees-id", "users", "users-id", "users-detail", "roles", "business-functions", "locations", "departments", "teams", "committees", "dependency-vendors"].includes(key)) return items;
    const organizationId = currentFormOrganizationId();
    if (!organizationId) return items;
    return items.filter(item => !item.organizationId || item.organizationId === organizationId);
  }

  function optionsFor(key, selected) {
    const selectedText = String(selected ?? "");
    return `<option value="">Select...</option>${lookupItemsFor(key).map(item => `<option value="${escapeHtml(item.value)}"${String(item.value) === selectedText ? " selected" : ""}>${escapeHtml(item.label)}</option>`).join("")}`;
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
    setupState.treeRows = isOrganizationOnboarding ? (tables[2] || []) : [];
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
    await loadSetupChildRows(setupState.activeTab);
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
    setupBasicFields.innerHTML = setupBasicSchema.map(field => setupFieldMarkup(field, values[field.name], isOrganizationAdministration)).join("");
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
            provisioningNote = provisionResp?.credentialsEmailed
              ? " Admin credentials were emailed."
              : " Admin was provisioned; credential email failed — use Resend from the Users tab.";
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
    document.addEventListener("click", event => {
      const action = event.target.closest("[data-setup-action]");
      if (!action) return;
      const entity = action.dataset.setupEntity;
      const rowIndex = Number(action.dataset.setupIndex || 0);
      const row = setupState.childRows[entity]?.[rowIndex];
      if (!row) return;
      if (action.dataset.setupAction === "view") openSetupChildForm(entity, "view", valueOf(row, "Id"), row);
      if (action.dataset.setupAction === "edit") openSetupChildForm(entity, "edit", valueOf(row, "Id"), row);
      if (action.dataset.setupAction === "inactive") retireSetupChild(entity, valueOf(row, "Id"));
    });
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
    head.innerHTML = `<tr>${columns.map(column => `<th>${escapeHtml(column)}</th>`).join("")}<th>Actions</th></tr>`;
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
      body.innerHTML = records.map((row, index) => `<tr>${columns.map(column => `<td>${formatCell(valueOf(row, column))}</td>`).join("")}
        <td><div class="pm-inline-actions">
          <button type="button" class="pm-action-trigger" title="Actions"><i class="fas fa-ellipsis-v fa-solid fa-ellipsis-vertical"></i></button>
          <div class="pm-inline-menu">
            <button type="button" data-setup-action="view" data-setup-entity="${escapeHtml(entity)}" data-setup-index="${index}"><i class="fa-solid fa-eye"></i> View</button>
            <button type="button" data-setup-action="edit" data-setup-entity="${escapeHtml(entity)}" data-setup-index="${index}"><i class="fa-solid fa-pen"></i> Edit</button>
            <button type="button" data-setup-action="inactive" data-setup-entity="${escapeHtml(entity)}" data-setup-index="${index}"><i class="fa-solid fa-ban"></i> Inactive</button>
          </div>
        </div></td></tr>`).join("");
    } catch (error) {
      body.innerHTML = `<tr><td colspan="${columns.length + 1}" class="pm-empty">${escapeHtml(error.message || "Unable to load setup records.")}</td></tr>`;
    }
  }

  function openSetupChildForm(entity, mode, id = 0, record = null) {
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
    state.activeFormRecord = selectedRecord;
    if (formMessage) formMessage.hidden = true;
    const title = document.querySelector("#dialogTitle");
    if (title) title.textContent = `${mode === "add" ? "Add" : mode === "edit" ? "Edit" : "View"} ${setupConfig.title}`;
    fieldsHost.innerHTML = (schemas[entity] || []).map(field => fieldMarkup(field, valueOf(selectedRecord, field.name), readonly)).join("");
    saveButton.hidden = readonly;
    dialog.showModal();
  }

  async function retireSetupChild(entity, id) {
    if (!id || !confirm("Mark this record as inactive?")) return;
    await fetchJson(`${api}/${entity}/retire`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ id: Number(id) })
    });
    await loadLookups();
    await loadSetupChildRows(entity);
  }

  async function loadRows() {
    if (isSourceStatements) {
      await loadSourceStatements();
      return;
    }
    if (isRolePermissionMatrix) {
      await loadRolePermissionMatrix();
      return;
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
    }
    if (sourceStatementState.release && subscribedFrameworkFilter?.value
      && String(subscribedFrameworkFilter.value) !== String(sourceStatementState.release.releaseId)) {
      sourceStatementState.level = "releases";
      sourceStatementState.release = null;
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
    if (tableHead) tableHead.innerHTML = `<tr>${releaseSummaryColumns.map(column => `<th>${escapeHtml(column)}</th>`).join("")}</tr>`;
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
    const label = sourceStatementState.level === "statements" ? "Add Source Statement" : "Add Release";
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
        rows.innerHTML = `<tr><td colspan="${colspan}" class="pm-empty">No subscribed framework releases found for the selected organization. Subscribe releases in Organization Setup - Repository Subscription.</td></tr>`;
        renderPager();
        return;
      }
      rows.innerHTML = releases.map((release, index) => {
        const ownerLabel = String(valueOf(release, "OwnerName") || "").trim();
        const ownerCell = ownerLabel
          ? escapeHtml(ownerLabel)
          : `<span class="pm-empty compact" style="color:#94a3b8">Unassigned</span>`;
        return `<tr class="pm-release-source-row" data-release-index="${index}" style="cursor:pointer" title="View Source Statements for this release">
        <td><i class="fa-solid fa-chevron-right" aria-hidden="true"></i> <strong>${escapeHtml(valueOf(release, "FrameworkRelease") || valueOf(release, "ReleaseVersion"))}</strong></td>
        <td>${escapeHtml(valueOf(release, "Authority") || valueOf(release, "AuthorityCode"))}</td>
        <td>${escapeHtml(valueOf(release, "ArtifactName") || valueOf(release, "ArtifactCode"))}</td>
        <td>${escapeHtml(valueOf(release, "ReleaseVersion"))}</td>
        <td>${ownerCell}</td>
        <td>${escapeHtml(valueOf(release, "TotalStatementsCount") ?? valueOf(release, "TotalRequirementsCount") ?? 0)}</td>
        <td>${escapeHtml(valueOf(release, "ApplicableStatementsCount") ?? valueOf(release, "ApplicableMarkedRequirementsCount") ?? 0)}</td>
        <td>${escapeHtml(valueOf(release, "NotUpdatedStatementsCount") ?? valueOf(release, "NotUpdatedRequirementsCount") ?? 0)}</td>
        <td>${escapeHtml(valueOf(release, "NotApplicableStatementsCount") ?? valueOf(release, "NotApplicableDeferredRequirementsCount") ?? 0)}</td>
        <td class="pm-actions-cell" data-stop-row-click>${releaseActionsMarkup(index, release)}</td>
      </tr>`;
      }).join("");

      // Rule 4 — Employee-scope users see ONLY assigned releases and land
      // directly on the statements list when they open the only release
      // they have. If the filter left one row, auto-drill.
      if (isEmployeeScope && releases.length === 1) {
        const only = releases[0];
        sourceStatementState.release = mapReleaseSelection(only);
        sourceStatementState.isCustomRelease = Number(valueOf(only, "ReleaseId") || 0) < 0;
        sourceStatementState.level = "statements";
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
    if (tableHead) tableHead.innerHTML = `<tr>${statementTreeColumns.map(column => `<th>${escapeHtml(column)}</th>`).join("")}</tr>`;
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
      const hierarchy = nodePath(String(valueOf(s, "SourceStructureNodeId")));
      const stmtText = String(valueOf(s, "StatementText") || "");
      return `<tr>
        <td title="${escapeHtml(hierarchy)}">${escapeHtml(hierarchy)}</td>
        <td>${escapeHtml(valueOf(s, "StatementReference"))}</td>
        <td>${escapeHtml(valueOf(s, "StatementTitle"))}</td>
        <td title="${escapeHtml(stmtText)}">${escapeHtml(stmtText.length > 80 ? stmtText.substring(0, 80) + "..." : stmtText)}</td>
        <td>${formatCell(valueOf(s, "ApplicabilityStatus") || "Not Updated")}</td>
        <td>${escapeHtml(valueOf(s, "PracticeCount") || 0)}</td>
        <td>${actions(i)}</td>
      </tr>`;
    });

    rows.innerHTML = statementBreadcrumbRow() + (htmlRows.length
      ? htmlRows.join("")
      : `<tr><td colspan="${cols.length}" class="pm-empty">No source statements found for this framework release.</td></tr>`);
  }

  function openStatementView(record) {
    state.mode = "view";
    state.formEntity = "statement-applicability";
    state.activeFormRecord = record;
    formMessage.hidden = true;
    document.querySelector("#dialogTitle").textContent = "View Source Statement";
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
      <label class="pm-field"><span>Owner</span><select name="ownerId">${optionsFor("users-id", valueOf(record, "OwnerId"))}</select></label>
      <label class="pm-field full"><span>Reason / Justification</span><textarea name="exclusionJustification" rows="3">${escapeHtml(valueOf(record, "ExclusionJustification"))}</textarea></label>`;
    saveButton.hidden = false;
    dialog.showModal();
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
    // IMPORTANT: bind the picker to the `users-id` lookup, NOT `users`.
    // In 02_Create_Procedures.sql the `users` lookup emits
    // `employee_name` as its Value (used for legacy free-text owners),
    // while `users-id` emits the numeric employee_id — which is what
    // repository_subscription.owner_id needs. Using the wrong lookup
    // was the reason the API kept rejecting saves with
    // "Please select an employee to assign as the release owner."
    const employeeOptions = optionsFor("users-id", valueOf(release, "OwnerId"));
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
    if (!confirm(`Resend admin credentials to ${email}?`)) return;
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
      alert(resp?.credentialsEmailed
        ? "Credentials email sent successfully."
        : `Credentials were re-generated but the email could not be delivered. Reason: ${resp?.emailFailureReason || "unknown"}.`);
    } catch (error) {
      alert(error.message || "Unable to resend credentials.");
    }
  }

  async function retireCustomRelease(release) {
    const subscriptionId = Number(valueOf(release, "SubscriptionId") || 0);
    if (!subscriptionId) { alert("Cannot retire this release."); return; }
    if (!confirm(`Retire release "${valueOf(release, "FrameworkRelease") || valueOf(release, "ReleaseVersion")}"?`)) return;
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

  function openCustomReleaseForm() {
    const orgId = organizationFilter?.value || "";
    if (!orgId) { alert("Please select an organization first."); return; }
    state.mode = "addRelease";
    state.id = 0;
    state.formEntity = "custom-release";
    formMessage.hidden = true;
    document.querySelector("#dialogTitle").textContent = "Add Release";
    fieldsHost.innerHTML = `
      <input name="organizationId" type="hidden" value="${escapeHtml(orgId)}">
      <label class="pm-field"><span>Authority</span><input value="Organization" disabled></label>
      <label class="pm-field"><span>Artifact</span><input value="Custom" disabled></label>
      <label class="pm-field"><span>Release Name<span class="required"> *</span></span><input name="customReleaseName" required placeholder="e.g. Internal Policy v1.0"></label>
      <label class="pm-field"><span>Effective Date</span><input name="effectiveDate" type="date"></label>
      <label class="pm-field"><span>End Date</span><input name="endDate" type="date"></label>
      <label class="pm-field full"><span>Release Notes</span><textarea name="releaseNotes" rows="4" placeholder="Optional notes about this release"></textarea></label>`;
    saveButton.hidden = false;
    dialog.showModal();
  }

  // --- Custom Release Statements (flat grid) ---
  async function loadCustomReleaseStatements() {
    updateAddButtonLabel();
    const release = sourceStatementState.release;
    await loadSourceStructureNodes();
    const cols = customStatementFlatColumns;
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
        <td title="${escapeHtml(valueOf(s, "StatementText"))}">${escapeHtml(String(valueOf(s, "StatementText") || "").substring(0, 80))}${String(valueOf(s, "StatementText") || "").length > 80 ? "..." : ""}</td>
        <td>${formatCell(valueOf(s, "ApplicabilityStatus") || "Not Updated")}</td>
        <td>${escapeHtml(valueOf(s, "PracticeCount") || 0)}</td>
        <td>${actions(i)}</td>
      </tr>`;
    });
    rows.innerHTML = customStatementBreadcrumbRow() + (htmlRows.length
      ? htmlRows.join("")
      : `<tr><td colspan="${cols.length}" class="pm-empty">No source statements found for this custom release. Click "Add Source Statement" to create one.</td></tr>`);
  }

  function openCustomStatementForm(existingRecord = null) {
    const release = sourceStatementState.release;
    const isEdit = !!existingRecord;
    state.mode = isEdit ? "editCustomStatement" : "addCustomStatement";
    state.id = isEdit ? Number(valueOf(existingRecord, "CustomStatementId") || 0) : 0;
    state.formEntity = "custom-statement";
    formMessage.hidden = true;
    document.querySelector("#dialogTitle").textContent = isEdit ? "Edit Source Statement" : "Add Source Statement";
    // Build classification options from root-level source structure nodes for this release
    const classificationOptions = (sourceStructureState.nodes || [])
      .filter(n => !valueOf(n, "ParentNodeId") || String(valueOf(n, "NodeLevel")) === "1")
      .map(n => {
        const title = valueOf(n, "NodeTitle") || "";
        return `<option value="${escapeHtml(title)}"${isEdit && valueOf(existingRecord, "Classification") === title ? " selected" : ""}>${escapeHtml(title)}</option>`;
      }).join("");
    fieldsHost.innerHTML = `
      <input name="organizationId" type="hidden" value="${escapeHtml(release.organizationId)}">
      <input name="subscriptionId" type="hidden" value="${escapeHtml(release.subscriptionId)}">
      ${isEdit ? `<input name="customStatementId" type="hidden" value="${escapeHtml(valueOf(existingRecord, "CustomStatementId"))}">` : ""}
      <label class="pm-field"><span>Organization</span><input value="${escapeHtml(release.organizationName)}" disabled></label>
      <label class="pm-field"><span>Release</span><input value="${escapeHtml(release.releaseVersion)}" disabled></label>
      <label class="pm-field"><span>Source Structure Node<span class="required"> *</span></span><select name="structureNodeId" required><option value="">— Select structure node —</option>${buildStructureNodeOptions(isEdit ? valueOf(existingRecord, "StructureNodeId") : "")}</select></label>
      <label class="pm-field"><span>Statement Reference</span><input name="statementReference" value="${escapeHtml(isEdit ? valueOf(existingRecord, "StatementReference") : "")}" placeholder="e.g. CS-001"></label>
      <label class="pm-field"><span>Statement Title<span class="required"> *</span></span><input name="statementTitle" required value="${escapeHtml(isEdit ? valueOf(existingRecord, "StatementTitle") : "")}" placeholder="Title of the source statement"></label>
      <label class="pm-field full"><span>Statement Text</span><textarea name="statementText" rows="4" placeholder="Full text of the source statement">${escapeHtml(isEdit ? valueOf(existingRecord, "StatementText") : "")}</textarea></label>
      <label class="pm-field"><span>Statement Classification</span><select name="classification"><option value="">— Select classification —</option>${classificationOptions}</select></label>
      <label class="pm-field"><span>Keywords</span><input name="keywords" value="${escapeHtml(isEdit ? valueOf(existingRecord, "Keywords") : "")}" placeholder="Comma-separated keywords"></label>`;
    saveButton.hidden = false;
    dialog.showModal();
  }

  function openCustomStatementView(record) {
    state.mode = "view";
    state.formEntity = "custom-statement";
    formMessage.hidden = true;
    document.querySelector("#dialogTitle").textContent = "View Source Statement";
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
    if (!confirm("Mark this source statement as inactive?")) return;
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
    if (!confirm(msg)) return;
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
          ? (state.navigationCode ? "No practices found for this Source Statement. Please verify the statement is Applicable and has mapped practices." : "No organization practices found for the selected organization.")
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
    rows.innerHTML = state.records.map((row, index) => `<tr>${currentColumns().map(column => {
      const value = column === "Register" ? (valueOf(row, "Register") || valueOf(row, "DependencyCategory")) : valueOf(row, column);
      const title = column === "SourceFrameworkRelease" ? ` title="${escapeHtml(value)}"` : "";
      return `<td${title}>${formatCell(value)}</td>`;
    }).join("")}<td>${actions(index)}</td></tr>`).join("");
  }

  function renderStatementPracticeRows() {
    if (tableHead) tableHead.innerHTML = `<tr>
      <th>Practice Code</th>
      <th>Practice Name</th>
      <th>Applicability Status</th>
      <th>Owner</th>
      <th>Origin Type</th>
      <th>Actions</th>
    </tr>`;
    rows.innerHTML = state.records.map((record, index) => `<tr>
      <td>${formatCell(valueOf(record, "Code"))}</td>
      <td>${formatCell(valueOf(record, "Name"))}</td>
      <td>${formatCell(valueOf(record, "ApplicabilityStatus"))}</td>
      <td>${formatCell(valueOf(record, "PracticeOwner"))}</td>
      <td>${formatCell(valueOf(record, "OriginType"))}</td>
      <td>${actions(index)}</td>
    </tr>`).join("");
  }

  function renderRequirementControlGroups() {
    if (tableHead) tableHead.innerHTML = "";
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
        <td>${formatCell(valueOf(record, "Code"))}</td>
        <td>${formatCell(valueOf(record, "Name"))}</td>
        <td>${formatCell(valueOf(record, "ApplicabilityStatus"))}</td>
        <td>${formatCell(valueOf(record, "PracticeOwner"))}</td>
        <td>${formatCell(valueOf(record, "OriginType"))}</td>
        <td>${actions(index)}</td>
      </tr>`).join("");
      return `<tr class="pm-control-group-row"><td colspan="6">Control: ${escapeHtml(title)}</td></tr>
        <tr class="pm-control-group-head">
          <th>Practice Code</th>
          <th>Practice Name</th>
          <th>Applicability Status</th>
          <th>Owner</th>
          <th>Origin Type</th>
          <th>Actions</th>
        </tr>${detailRows}`;
    }).join("");
  }

  function renderPager() {
    pageInfo.textContent = `Page ${state.pageNumber}`;
    previousPage.disabled = state.pageNumber <= 1;
    nextPage.disabled = state.records.length < state.pageSize;
  }

  function resetToFirstPage() {
    state.pageNumber = 1;
    loadRows();
  }

  async function resetOrganizationRequirementFilters() {
    if (status) status.value = "";
    if (subscribedFrameworkFilter) subscribedFrameworkFilter.value = "";
    await loadSubscribedFrameworks();
    resetToFirstPage();
  }

  function formatCell(value) {
    if (value === true || value === false) return value ? "Yes" : "No";
    if (String(value || "").match(/^(Active|Inactive|Applicable|Not Updated|Implemented|Critical|High|Medium|Low|Deferred|Accepted Risk|Not Applicable|Configured|Partially Operationalized|Operationalized|Retired|Pending|Resolved)$/i)) return `<span class="pm-badge">${escapeHtml(value)}</span>`;
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
    const list = ["releaseView", "releaseUpdateOwner"];
    if (isCustom) list.push("releaseEdit", "releaseRetire");
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
    if (screen.Key === "organization-controls" && sourceStatementState.isCustomRelease && sourceStatementState.level === "statements") {
      // Rule 4 — employees can only mark applicability on custom statements,
      // not edit / inactive them.
      actions = isEmployeeScope ? ["view", "markApplicability"] : ["view", "edit", "inactive"];
    } else if (screen.Key === "organization-controls" && record) {
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
      if (applicability === "applicable") actions = ["viewObligations", "view", "instances"];
      else if (applicability === "not updated") actions = ["viewObligations", "view", "markApplicability"];
      else actions = ["viewObligations", "view", "updateApplicability"];
    }
    if (screen.Key === "practices") {
      const applicability = record ? applicabilityStatus(record) : "not updated";
      if (applicability === "not updated") actions = ["markApplicability", "view"];
      else if (applicability === "applicable") actions = ["instances", "view"];
      else actions = ["updateApplicability", "view"];
    }
    return actions.filter(action => {
      if (action === "view") return permissions.has("VIEW");
      if (action === "viewObligations" || action === "viewOperationalization" || action === "dependencyIntelligence") return permissions.has("VIEW");
      if (action === "edit" || action === "configure" || action === "manage" || action === "map" || action === "subscribe" || action === "markApplicability" || action === "updateApplicability" || action === "resolveDependencies" || action === "modifyDependencies" || action === "bulkResolution" || action === "manageRoles" || action === "resendCredentials") return permissions.has("EDIT") || permissions.has("ADD");
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

  function fieldMarkup(field, value, readonly) {
    if (field.type === "hidden") return `<input name="${field.name}" type="hidden" value="${escapeHtml(value)}">`;
    const required = field.required ? `<span class="required"> *</span>` : "";
    const disabled = readonly || field.readonly ? " disabled" : "";
    let control;
    if (field.type === "textarea") control = `<textarea name="${field.name}" rows="3"${disabled}${field.required ? " required" : ""}>${escapeHtml(value)}</textarea>`;
    else if (field.type === "select") control = `<select name="${field.name}"${disabled}${field.required ? " required" : ""}>${optionsFor(field.lookup, value)}</select>`;
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
    else control = `<input name="${field.name}" type="${field.type}" value="${escapeHtml(value)}"${disabled}${field.required ? " required" : ""}>`;
    return `<label class="pm-field${field.full ? " full" : ""}" data-field-name="${escapeHtml(field.name)}"><span>${escapeHtml(field.label)}${required}</span>${control}</label>`;
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
    const employeeItems = lookupItemsFor("users");
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
      <td><select data-evidence-field="evidenceOwner"${disabled}>${optionsFor("users", valueOf(row, "EvidenceOwner"))}</select></td>
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

  function schemaFor(mode, record) {
    if (screen.Key === "organization-controls" && mode === "applicability") {
      return [
        text("code", "Control Code", false, { readonly: true }),
        text("name", "Control Name", false, { readonly: true }),
        select("applicabilityStatus", "Applicability Status", "applicability-status", true),
        select("primaryOwner", "Primary Owner", "users"),
        select("secondaryOwner", "Secondary Owner", "users"),
        select("businessFunctionId", "Business Function", "business-functions"),
        select("criticality", "Criticality", "criticality", true),
        area("exclusionJustification", "Justification / Reason")
      ];
    }
    if (screen.Key === "organization-requirements" && mode === "applicability") {
      return [
        text("code", "Practice Code", false, { readonly: true }),
        text("name", "Practice Name", false, { readonly: true }),
        select("applicabilityStatus", "Applicability Status", "applicability-status", true),
        select("practiceOwnerId", "Owner", "users-id"),
        area("exclusionJustification", "Reason / Justification")
      ];
    }
    if (screen.Key === "practices" && mode === "applicability") {
      return [
        text("code", "Practice Code", false, { readonly: true }),
        text("name", "Practice Name", false, { readonly: true }),
        select("applicabilityStatus", "Applicability Status", "applicability-status", true),
        select("practiceOwnerId", "Owner", "users-id"),
        area("exclusionJustification", "Reason / Justification")
      ];
    }
    if (screen.Key === "practices" && mode === "add") {
      return [
        select("organizationId", "Organization", "organizations", true),
        hidden("organizationRequirementId"),
        hidden("originType"),
        hidden("applicabilityStatus"),
        hidden("status"),
        text("code", "Practice Code", true),
        text("name", "Practice Name", true),
        area("description", "Description"),
        select("practiceOwnerId", "Owner", "users-id"),
        select("businessFunctionId", "Business Function", "business-functions"),
        select("criticality", "Criticality", "criticality"),
        area("remarks", "Remarks")
      ];
    }
    return schemas[screen.Key] || [];
  }

  async function openForm(mode, id = 0) {
    state.mode = mode;
    state.id = id;
    state.formEntity = screen.Key;
    formMessage.hidden = true;
    const readonly = mode === "view";
    let record = {};
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
      if (screen.Key === "practice-instances") {
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
    if (screen.Key === "practice-instances" && !valueOf(record, "frequencyId") && valueOf(record, "FrequencyType")) {
      record.frequencyId = frequencyIdFromName(valueOf(record, "FrequencyType"));
      record.FrequencyId = record.frequencyId;
    }
    if (screen.Key === "practice-instances") {
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
    const titlePrefix = mode === "add" ? "Add" : mode === "edit" ? "Edit" : mode === "applicability" ? "Mark Applicability" : "View";
    document.querySelector("#dialogTitle").textContent = screen.Key === "organization-controls" && mode === "add"
      ? "Add Release"
      : (screen.Key === "organization-requirements" || screen.Key === "practices") && mode === "add"
        ? "Add Practice"
        : `${titlePrefix} ${screen.Title}`;
    fieldsHost.innerHTML = schema.length
      ? `${schema.map(field => fieldMarkup(field, valueOf(record, field.name), readonly)).join("")}`
      : `<p class="pm-empty">This screen is planned for the next implementation phase.</p>`;
    updateFrequencyFields();
    if (screen.Key === "practice-instances") await updateOwnerDepartment();
    saveButton.hidden = readonly || !schema.length;
    dialog.showModal();
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
    if (screen.Key === "practice-instances") normalizeFrequency(data);
    if (state.formEntity === "custom-statement") {
      data.statementAction = state.mode === "editCustomStatement" ? "EDIT" : "ADD";
    }
    return data;
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
        evidence: []
      });
      const evidenceType = obligationValue(row, "EvidenceType");
      if (evidenceType) obligations.get(key).evidence.push({
        type: evidenceType,
        frequency: obligationValue(row, "Frequency"),
        retention: obligationValue(row, "RetentionRequirement"),
        remarks: obligationValue(row, "Remarks")
      });
    });
    const metaChip = (label, value) => value
      ? `<span class="pm-obligation-chip"><em>${escapeHtml(label)}</em>${escapeHtml(value)}</span>`
      : "";
    body.innerHTML = [...groups.entries()].map(([release, obligations]) => {
      const collapsed = state.obligationCollapsed.has(release);
      const cards = [...obligations.values()].map(ob => `<article class="pm-obligation-card">
          <h4>${escapeHtml(ob.name || "Obligation")}</h4>
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
      practiceInstanceId: screen.Key === "practice-instances" && state.id ? state.id : undefined,
      practiceId: practiceId || undefined,
      organizationRequirementId: organizationRequirementId || undefined,
      pageNumber: 1,
      pageSize: 200
    };
    if (!data.practiceInstanceId && !data.practiceId && !data.organizationRequirementId) {
      throw new Error("Requirement context is required to view obligation recommendations.");
    }
    const result = await fetchJson(`${api}/evidence-obligations/query`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ data })
    });
    const obligationRows = apiData(result);
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
      <td><select data-op-field="resolutionOwnerId"${disabled}>${optionsFor("users-id", valueOf(row, "ResolutionOwnerId"))}</select></td>
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
      const data = collectForm();
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
      if (screen.Key === "practice-instances") {
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
      formMessage.textContent = error.message;
      formMessage.hidden = false;
    }
  }

  async function retire(id) {
    if (!confirm("Mark this record as inactive?")) return;
    await fetchJson(`${api}/${screen.Key}/retire`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-TOKEN": csrfToken },
      body: JSON.stringify({ id })
    });
    await loadRows();
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
    if (action === "view" || action === "edit") openForm(action, id);
    else if (action === "markApplicability" || action === "updateApplicability") openForm("applicability", id);
    else if (action === "inactive") retire(id);
    else if (action === "manage" && screen.Key === "organizations") navigateWithContext("control-applicability", "Organization", id, valueOf(record, "Code"), valueOf(record, "Name")).catch(error => alert(error.message));
    else if (action === "instances" && screen.Key === "organization-requirements") navigateWithContext("practice-instances", "OrganizationRequirement", id, valueOf(record, "Code"), valueOf(record, "Name"), valueOf(record, "OrganizationId"), valueOf(record, "OrganizationControlId"), valueOf(record, "ApplicabilityStatus"), id).catch(error => alert(error.message));
    else if (action === "instances" && screen.Key === "practices") navigateWithContext("practice-instances", "Practice", id, valueOf(record, "Code"), valueOf(record, "Name"), valueOf(record, "OrganizationId"), state.navigationContext?.organizationControlId || null, valueOf(record, "ApplicabilityStatus"), valueOf(record, "OrganizationRequirementId")).catch(error => alert(error.message));
    else if (action === "practices" && screen.Key === "organization-controls") navigateWithContext("organization-requirements", "OrganizationControl", id, valueOf(record, "Code"), valueOf(record, "Name"), valueOf(record, "OrganizationId"), id, valueOf(record, "ApplicabilityStatus")).catch(error => alert(error.message));
    else if (action === "viewObligations" && screen.Key === "organization-requirements") showEvidenceObligations(record).catch(error => alert(error.message));
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
  fieldsHost?.addEventListener("click", event => {
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
  fieldsHost?.addEventListener("change", event => {
    const checkComboInput = event.target.closest("[data-checkcombo] input[type='checkbox']");
    if (checkComboInput) {
      const combo = checkComboInput.closest("[data-checkcombo]");
      const labels = [...combo.querySelectorAll("input[type='checkbox']:checked")].map(item => item.closest("label").querySelector("span").textContent.trim());
      combo.querySelector("[data-checkcombo-text]").textContent = labels.join(", ") || "Select...";
      combo.dataset.selectedReference = [...combo.querySelectorAll("input[type='checkbox']:checked")].map(item => item.value).join(",");
    }
    if (screen.Key === "practice-instances" && event.target?.name === "frequencyId") updateFrequencyFields();
    if (screen.Key === "practice-instances" && event.target?.name === "primaryOwnerId") updateOwnerDepartment().catch(error => alert(error.message));
    const dependencyType = event.target.closest("[data-dependency-field='dependencyTypeId']");
    if (screen.Key === "practice-instances" && dependencyType) {
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
  pageSize?.addEventListener("change", () => { state.pageSize = Number(pageSize.value || 25); resetToFirstPage(); });
  previousPage?.addEventListener("click", () => { if (state.pageNumber > 1) { state.pageNumber -= 1; loadRows(); } });
  nextPage?.addEventListener("click", () => { if (state.records.length >= state.pageSize) { state.pageNumber += 1; loadRows(); } });

  if (isOrganizationWorkspace) {
    loadLookups().then(initOrganizationSetup).catch(error => {
      if (setupMessage) {
        setupMessage.textContent = error.message || "Unable to load Organization Setup.";
        setupMessage.hidden = false;
      }
      console.error("Organization Setup initial load failed.", error);
    });
  } else {
    loadLookups().then(loadNavigationContext).then(loadSubscribedFrameworks).then(loadRows).catch(error => {
      if (rows) {
        rows.innerHTML = `<tr><td colspan="${(screen.Columns?.length || 0) + 1}" class="pm-empty">${escapeHtml(error.message || "Unable to load Practice Management data.")}</td></tr>`;
      }
      console.error("PracticeManagement initial load failed.", error);
    });
  }
})();
