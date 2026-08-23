namespace PracticeManagement.Web.Models;

public sealed record PracticeScreen(string Key, string Title, string Description, string Icon, string[] Columns, string Group)
{
    public const string OrganizationOnboardingGroup = "Organization Setup";
    public const string OrganizationAdministrationGroup = "Organization Administration";
    public const string OrganizationDependenciesGroup = "Organization Dependencies";
    public const string OrganizationAccessAdministrationGroup = "Organization Access Administration";
    public const string OrganizationSetupGroup = OrganizationOnboardingGroup;
    public const string PracticeManagementGroup = "Practice Management";
    public const string AssuranceManagementGroup = "Assurance Management";
    public const string DependencyWorkbenchGroup = "Registers";
    public const string DashboardGroup = "Dashboard";
    // Oversight group — split off from PracticeManagementGroup so
    // gap-identification (Gap Center) and task-execution (Task Center)
    // sit alongside future Assurance / Exceptions / Risks screens.
    // Introduced when Task Center's Gaps tab was extracted into its
    // own Gap Center module.
    public const string OversightGroup = "Oversight";
    // Sidebar reorganisation (migration 051) — enterprise-GRC grouping.
    // These match module_type values in grac_practice.menu_master; the
    // Group value on each PracticeScreen is used for the page eyebrow
    // (see Views/Practice/Manage.cshtml → `@Model.Group / @Model.Title`)
    // so the eyebrow stays consistent with the sidebar hierarchy.
    public const string GovernanceGroup     = "Governance";
    public const string OrganizationGroup   = "Organization";
    public const string OperationsGroup     = "Operations";
    public const string AdministrationGroup = "Administration";
    // Workflow & Event-Driven Assurance Engine (BRD v1.0) -- sits
    // beside Oversight (400) in the sidebar, seeded by migration 068.
    // Independent of the Practice Assurance Engine (BRD Sec 4).
    public const string WorkflowGroup       = "Workflow";
    // Phase 2 Assurance Management (BRD Part 2 -- Organization Portal).
    // NEW, INDEPENDENT module. Screens live under the existing
    // nav-assurance parent (seeded by migration 063). Menu rows and
    // permissions added by migration 071. Distinct from
    // AssuranceManagementGroup above -- that group belongs to the
    // unrelated legacy assurance-* screens which stay untouched.
    public const string OrganizationAssuranceGroup = "Organization Assurance";

    public static readonly PracticeScreen[] All =
    [
        new("dashboard","Dashboard","Practice Management summary dashboard","chart-line",["Id","Message"], DashboardGroup),
        new("organization-setup","Organization Setup","GRAC Admin module for organization onboarding, metadata, repository subscription, locations, departments, business functions, teams, committees, and employees","building",["Code","Name","Industry","EntityType","Country","Status"], OrganizationOnboardingGroup),
        new("organization-administration","Organization Administration","Organization profile, locations, departments, business functions, teams, committees, and employees for organization users","building-user",["Code","Name","Industry","EntityType","Country","Status"], OrganizationAdministrationGroup),
        new("organizations","Organization Onboarding","Legal entities and organization-level operating context","building",["Code","Name","Industry","EntityType","Country","Status"], OrganizationGroup),
        new("organization-metadata","Organization Metadata","Configurable metadata used for applicability discovery","sliders",["OrganizationId","MetadataName","DataType","ValueText","Status"], OrganizationGroup),
        new("repository-subscriptions","Repository Subscriptions","Organization subscriptions to repository artifacts and releases","bookmark",["OrganizationId","AuthorityId","ArtifactId","ReleaseId","SubscriptionStatus","Status"], GovernanceGroup),
        new("locations","Location Management","Organization locations used for operating context, ownership, and responsibility mapping","location-dot",["Organization","Name","LocationType","LocationHead","Region","Status"], OrganizationGroup),
        new("departments","Department Management","Departments mapped to organizations","building-user",["Organization","Code","Name","HeadUser","Status"], OrganizationGroup),
        new("teams","Team Management","Organization teams mapped to departments and managed by employees. In-house or vendor-managed; accountability stays with the team manager either way","people-group",["Organization","Name","TeamType","Vendor","TeamManager","ParentDepartment","Status"], OrganizationGroup),
        new("committees","Committee Management","Organization committees with chairperson, secretary, and review frequency","users-gear",["Organization","Name","Chairperson","Secretary","ReviewFrequency","Status"], OrganizationGroup),
        new("roles","Role Master","Organization-specific roles used for menu and action permissions","user-lock",["Organization","RoleCode","RoleName","Description","Status"], AdministrationGroup),
        new("role-menu-permissions","Role Menu Permission","Assign Practice Management menu permissions to an organization role","list-check",["Organization","RoleName","MenuName","CanView","CanAdd","CanEdit","CanDelete","CanApprove","Status"], AdministrationGroup),
        new("user-role-assignments","User Role Assignment","Assign one or more organization roles to organization users","user-gear",["EmployeeCode","EmployeeName","Email","RoleNames","Status"], AdministrationGroup),
        new("users","User Management","Users available for organization ownership and assignment. Employees and third-party personnel; a third party must name the provider that supplies them","users",["EmployeeCode","EmployeeName","PersonnelType","Email","RoleName","Provider","Designation","Status"], AdministrationGroup),
        new("organization-dependencies","Organization Dependencies","Organization dependency objects for applications, tools, vendors, assets, and processes","diagram-project",["Name","Owner","Criticality","Status"], OrganizationDependenciesGroup),
        new("dependency-applications","Applications","Business applications supporting organization practices","window-restore",["Name","BusinessOwner","TechnicalOwner","Vendor","HostingType","Criticality","Status"], OperationsGroup),
        new("dependency-tools","Tools","Utility tools supporting execution of practices","screwdriver-wrench",["Name","BusinessOwner","Vendor","LicenseType","Criticality","Status"], OperationsGroup),
        new("dependency-vendors","Vendors","Third parties providing services or products","handshake",["Name","ServiceCategory","RelationshipOwner","Criticality","Status"], OperationsGroup),
        new("dependency-assets","Assets","Physical or logical assets supporting practices","server",["Name","AssetCategory","Owner","Location","Criticality","Status"], OperationsGroup),
        // Asset counterpart of the checklist section on the Role Master form
        // (migration 138). A screen of its own, not a section on an Asset
        // Category form, because dependency_asset_category_master is global
        // master data with no organization_id -- while the checklist decision
        // is per (organization, category). Renders via
        // Views/Practice/Partials/asset-category-assurance.cshtml; the columns
        // below are unused (the partial owns its own layout) but are kept
        // meaningful so the screen registry stays self-describing.
        new("asset-category-assurance","Asset Category Assurance","Set what has to be done when an asset of a given category is commissioned or decommissioned.","boxes-stacked",["Applies","Event","Checklist","Items","OwnerRole","DueDays","State"], OperationsGroup),
        new("dependency-processes","Processes","Business processes supporting organizational execution","arrows-spin",["Name","ProcessOwner","Version","NextReviewDate","Status"], OperationsGroup),
        new("user-assignments","User Assignment","Assign users to organization and department scope","user-check",["Organization","Department","User","Role","Status"], OrganizationOnboardingGroup),
        new("owner-mappings","Role / Owner Mapping","Map ownership roles to users for organization operations","user-shield",["Organization","Role","Owner","BackupOwner","Status"], OrganizationOnboardingGroup),
        // organization-controls is the underlying two-level screen: Level 1 renders
        // the subscribed Framework Release summary (RS2); Level 2 drills into that
        // release's Source Statement tree (RS3). Migration 056 makes this the target
        // of the Repository Subscriptions menu so users land on Level 1 by default.
        // Columns here paint the pre-hydration header only; practice.js swaps in
        // releaseSummaryColumns (Level 1) or statementTreeColumns (Level 2) as soon
        // as it runs. They are kept in step with releaseSummaryColumns so the grid
        // does not flash a header with columns that were removed from Level 1.
        new("organization-controls","Repository Subscriptions","Subscribed Framework Release summary with drill-down into Source Statements.","shield",["Framework / Release","Owner","Total Statements","Applicable Statements","Implemented Statements","Not Updated Statements","Not Applicable Statements"], GovernanceGroup),
        // source-statements is an ALIAS of organization-controls -- same view, same
        // columns, same JS. It exists so the Source Statements menu has its own
        // sidebar-highlighting URL and lands users directly on the Level 2 statement
        // grid (auto-drilling into the first subscribed release).
        new("source-statements","Source Statements","Source Statement grid for a subscribed Framework Release.","shield",["Code","Name","OriginType","SourceFrameworkRelease","ApplicabilityStatus","ApplicablePracticeCount","PrimaryOwner","Criticality"], GovernanceGroup),
        new("organization-requirements","Practices","Organization-scoped practices and applicability decisions with expandable Practice Instances","list-check",["Code","Name","ApplicabilityStatus","PracticeOwner","PracticeInstanceCount"], GovernanceGroup),
        new("practices","Practice Management","Implementation approaches for applicable requirements","clipboard-check",["Code","Name","OriginType","ApplicabilityStatus","PracticeOwner","Status"], GovernanceGroup),
        // Resolve workspace (migrations 140/141). Not a menu screen: it is
        // reached from a row on the Resolve list, carrying the instance id.
        new("resolve-workspace","Operationalize","Everything one practice instance still needs -- its obligations and its dependencies.","link",["Obligation","Type","Release","Adopted","Evidence"], OperationsGroup),
        // Full-page replacement for the practice View modal (migration 139).
        // Not a menu screen: it is reached only from the Practices grid, with
        // an encrypted navigation code carrying the practice id. Registered
        // here so PracticeController.ShowArea can resolve and permission it.
        new("practice-view","Practice","Practice details, its obligations, and Configure -- one Practice Instance per team.","clipboard-check",["Obligation","Type","Frequency","Responsible","Approval"], GovernanceGroup),
        new("practice-instances","Practice Instances","Operational implementation units for practice intelligence","network-wired",["Code","Name","PrimaryOwner","Department","ExecutionFrequency","AssuranceFrequency","AssuranceMode","Criticality","ImplementationStatus","Status"], GovernanceGroup),
        new("resolve","Operationalize","Operationalize practice instance dependency and evidence registers assigned to you","gears",["Name","OwningDepartment","PrimaryOwner","Frequency","Register","ResolvedDependencyName","ResolutionStatus","ResolutionOwner","LastUpdated"], OperationsGroup),
        new("workbench-applications","Applications","Application custodian queue for resolving configured Practice Instance application dependencies","window-restore",["Name","OwningDepartment","PrimaryOwner","Frequency","DependencyCategory","ResolvedDependencyName","ResolutionStatus","ResolutionOwner","LastUpdated"], DependencyWorkbenchGroup),
        new("workbench-tools","Tools","Tool custodian queue for resolving configured Practice Instance tool dependencies","screwdriver-wrench",["Name","OwningDepartment","PrimaryOwner","Frequency","DependencyCategory","ResolvedDependencyName","ResolutionStatus","ResolutionOwner","LastUpdated"], DependencyWorkbenchGroup),
        new("workbench-vendors","Vendors","Vendor custodian queue for resolving configured Practice Instance vendor dependencies","handshake",["Name","OwningDepartment","PrimaryOwner","Frequency","DependencyCategory","ResolvedDependencyName","ResolutionStatus","ResolutionOwner","LastUpdated"], DependencyWorkbenchGroup),
        new("workbench-assets","Assets","Asset custodian queue for resolving configured Practice Instance asset dependencies","server",["Name","OwningDepartment","PrimaryOwner","Frequency","DependencyCategory","ResolvedDependencyName","ResolutionStatus","ResolutionOwner","LastUpdated"], DependencyWorkbenchGroup),
        new("workbench-teams","Teams","Team custodian queue for resolving configured Practice Instance team dependencies","people-group",["Name","OwningDepartment","PrimaryOwner","Frequency","DependencyCategory","ResolvedDependencyName","ResolutionStatus","ResolutionOwner","LastUpdated"], DependencyWorkbenchGroup),
        new("workbench-committees","Committees","Committee custodian queue for resolving configured Practice Instance committee dependencies","users-gear",["Name","OwningDepartment","PrimaryOwner","Frequency","DependencyCategory","ResolvedDependencyName","ResolutionStatus","ResolutionOwner","LastUpdated"], DependencyWorkbenchGroup),
        new("workbench-processes","Processes","Process custodian queue for resolving configured Practice Instance process dependencies","arrows-spin",["Name","OwningDepartment","PrimaryOwner","Frequency","DependencyCategory","ResolvedDependencyName","ResolutionStatus","ResolutionOwner","LastUpdated"], DependencyWorkbenchGroup),
        new("workbench-locations","Locations","Location custodian queue for resolving configured Practice Instance location dependencies","location-dot",["Name","OwningDepartment","PrimaryOwner","Frequency","DependencyCategory","ResolvedDependencyName","ResolutionStatus","ResolutionOwner","LastUpdated"], DependencyWorkbenchGroup),
        new("dependencies","Dependency Intelligence","People, tools, assets, vendors, applications, processes and locations","diagram-project",["DependencyType","Name","OwnerName","Criticality","Status"], PracticeManagementGroup),
        new("evidence-configurations","Evidence Configuration","Organization evidence expectations and collection settings","file-circle-check",["EvidenceType","AssuranceTypeName","RetentionPeriod","CollectionMethod","CollectionFrequency","EvidenceOwner","Status"], PracticeManagementGroup),
        new("evidence-obligations","View Obligations","Evidence obligations inherited from applicable requirements and practices","list-check",["FrameworkRelease","ObligationName","ExecutionFrequency","EvidenceType","Frequency","RetentionRequirement","Remarks"], PracticeManagementGroup),
        new("assurance-attributes","Assurance Attributes","Manual and automated assurance metadata","user-shield",["Id","Message"], PracticeManagementGroup),
        new("vendor-attributes","Vendor Attributes","Vendor, contract, SLA and service criticality metadata","handshake",["Id","Message"], PracticeManagementGroup),
        new("risk-attributes","Risk Attributes","Operational, compliance, financial, cyber and reputational impacts","triangle-exclamation",["Id","Message"], PracticeManagementGroup),
        new("audit-attributes","Audit Attributes","Auditable assets, tools, configuration scope and frequency recommendations","magnifying-glass-chart",["Id","Message"], PracticeManagementGroup),
        new("task-attributes","Task/Ticket Attributes","Execution frequency, due date logic, reminders, escalation and SLA","calendar-days",["Id","Message"], PracticeManagementGroup),
        new("resilience-attributes","Resilience Attributes","Single-point dependencies and operational resilience signals","arrows-spin",["Id","Message"], PracticeManagementGroup),
        new("future-triggers","Future Integration Trigger Matrix","Candidate leads for risk, audit, vendor, task and resilience modules","bolt",["Id","Message"], PracticeManagementGroup),
        new("audit-trace","Audit Traceability","Immutable history for major practice entities","timeline",["EntityType","EntityId","ActionType","Status","EnteredBy","EnteredDt"], AdministrationGroup)
        ,
        // ===== Workflow Layer (§12.1.3) — feature-flagged OFF by default =====
        // Task Center now lives under Oversight (was PracticeManagementGroup) so
        // it sits alongside Gap Center and future Assurance / Exceptions / Risks.
        new("tasks","Task Center","Tasks created to address gaps and lifecycle work — Implementation, Assurance, Custom","list-check",["TaskId","Type","Subject","Assignee","Status","Priority","SlaDueAt"], OversightGroup),
        // Gap Center — identifies work that needs to be done (Implementation
        // gaps today; Assurance / Custom gaps expand later). Kept independent
        // of Task Center because gap sources (assurance findings, exceptions,
        // risk register, audits, repository gaps) can grow well beyond
        // Implementation. See conversation notes for full source list.
        new("gaps","Gap Center","Unified sources of work — Implementation, Assurance and Custom gaps in one place","triangle-exclamation",["Instance","Practice","Organization","ImplementationStatus","Owner","Criticality","ExistingTasks"], OversightGroup),
        // Document Upload + Acknowledgement module (migrations 146-149).
        // Sits beside Task Center / Gap Center under Oversight. Columns
        // are unused (the partial owns its own layout) but kept meaningful
        // so the screen registry stays self-describing.
        new("document-uploads","Document Uploads","Register controlled documents, distribute them, and route them through review and approval","file-lines",["Code","Name","Type","Version","Stage","Status","NextReview"], OversightGroup),
        // Phase 2 companion to Document Uploads (migrations 150-152) --
        // admin batches for tracking user acknowledgement of published
        // documents. Renders via document-acknowledgements.cshtml.
        new("document-acknowledgements","Document Acknowledgements","Roll published documents into named batches and track who has acknowledged each","file-signature",["Name","Due","Docs","Users","AckCount","Progress","Status"], OversightGroup),
        // Phase 3 user-side counterpart (migrations 153-154). Every
        // employee sees their own pending acknowledgements here.
        new("my-acknowledgements","My Acknowledgements","Documents you are asked to acknowledge -- pick a batch and confirm each one","inbox",["Batch","Due","MyDocs","Acknowledged","Pending","Progress","Status"], OversightGroup),
        // Personal inbox for SLA task notifications (migrations 201-203).
        // Sits next to My Acknowledgements: both are addressed to the
        // signed-in individual rather than to a role or an organisation.
        new("my-notifications","My Notifications","Task SLA warnings, breaches and escalations addressed to you","bell",["Event","Task","WhyYou","Due","Received","Status"], OversightGroup),
        // Gap Centre v1.0 (migrations 156-158 / AES) -- lifecycle
        // engine on a single custom_gap row: canonical states, Gap
        // Analysis Engine, Decision Gateway with downstream links.
        // Reached from Gap Centre's 3-dot menu with ?gapId=.
        new("gap-detail","Gap Details","Gap lifecycle, analysis and downstream link management","route",["State","Severity","Impact"], OversightGroup),
        // Exception Centre (migrations 161-163) -- time-boxed
        // acceptance of gaps. Auto-populated from gap analysis.
        new("exception-centre","Exception Centre","Approve or reject time-boxed exception requests raised from gap analysis","shield-halved",["Request","Gap","Status","EffectiveUntil"], OversightGroup),
        // Risk Centre (migrations 169-172, 176, 204-207) -- the full
        // module: candidates from any GRAC source, the mandatory initial
        // risk analysis, and the Risk Register both entry routes feed.
        new("risk-centre","Risk Centre","Analyse risk candidates raised by Gap, Exception, Assurance and other GRAC sources, then register them; or create a custom risk directly","triangle-exclamation",["Candidate","Source","Rating","Status"], OversightGroup),
        // =====================================================================
        new("assurance-dashboard","Assurance Dashboard","Operational assurance coverage, overdue activities, findings, and health signals for resolved practice instances","chart-line",["Metric","Value","Severity","Message"], AssuranceManagementGroup),
        new("assurance-generation","Assurance Activity Generation","Generate assurance activities for eligible resolved practice instances based on assurance frequency","calendar-plus",["PracticeInstance","AssuranceFrequency","AssuranceType","EligibilityStatus","NextDueDate","ActionStatus"], AssuranceManagementGroup),
        new("assurance-activities","Assurance Activity List","Assurance activities generated for resolved practice instances","clipboard-list",["ActivityNumber","PracticeInstance","PeriodFrom","PeriodTo","AssuranceType","ActivityOwner","DueDate","Status"], AssuranceManagementGroup),
        new("assurance-execution","Assurance Execution","Execute manual or automated assurance checks for an activity","person-circle-check",["ActivityNumber","PracticeInstance","ExecutionDate","Executor","EvidenceStatus","DependencyStatus","ResultStatus","Status"], AssuranceManagementGroup),
        new("evidence-assurance","Evidence Assurance","Verify expected evidence exists, is accessible, matches expected type, and relates to assurance","file-circle-check",["ActivityNumber","PracticeInstance","EvidenceType","EvidenceExists","EvidenceAccessible","MatchesExpectedType","RelatesToAssurance","ResultStatus"], AssuranceManagementGroup),
        new("dependency-assurance","Dependency Assurance","Verify resolved dependencies remain valid and support practice operation during the assurance period","network-wired",["ActivityNumber","PracticeInstance","DependencyType","ResolvedDependency","DependencyAvailable","DependencyCurrent","ResultStatus"], AssuranceManagementGroup),
        new("assurance-results","Assurance Result","Final assurance outcomes and operating effectiveness conclusions","square-poll-vertical",["ActivityNumber","PracticeInstance","ResultStatus","OperatingEffectiveness","CompletedDate","CompletedBy"], AssuranceManagementGroup),
        new("assurance-findings","Findings","Findings raised from assurance activities and unresolved evidence or dependency gaps","triangle-exclamation",["FindingNumber","ActivityNumber","PracticeInstance","Severity","FindingStatus","Owner","DueDate"], AssuranceManagementGroup),
        new("assurance-signals","Assurance Signals","Signals derived from evidence, dependency, trend, risk, and audit intelligence","wave-square",["SignalType","PracticeInstance","Severity","SignalStatus","DetectedDate","Message"], AssuranceManagementGroup),
        new("assurance-trends","Trend Engine","Assurance trend indicators across practice instances and periods","chart-column",["PracticeInstance","TrendType","CurrentValue","PreviousValue","TrendDirection","Severity"], AssuranceManagementGroup),
        new("practice-health","Practice Health Engine","Practice instance health calculated from assurance results, evidence, dependency, and findings","heart-pulse",["PracticeInstance","HealthScore","HealthStatus","Criticality","LastAssuredDate","OpenFindings"], AssuranceManagementGroup),
        new("audit-intelligence","Audit Intelligence View","Audit-oriented assurance intelligence for resolved practice instances","magnifying-glass-chart",["PracticeInstance","AuditableArea","LastAssuranceResult","EvidenceStatus","OpenFindings","AuditPriority"], AssuranceManagementGroup),
        new("risk-intelligence","Risk Intelligence View","Risk-oriented assurance intelligence for resolved practice instances","shield-halved",["PracticeInstance","RiskSignal","Criticality","HealthStatus","OpenFindings","RiskPriority"], AssuranceManagementGroup),
        new("assurance-calendar","Assurance Calendar","Google Calendar-style view of assurance schedules generated from practice instance frequencies","calendar-days",["PracticeInstance","Frequency","NextDue","Status"], AssuranceManagementGroup)
        ,
        // ===== Workflow & Event-Driven Assurance Engine (BRD v1.0) =====
        // Every screen renders via Views/Practice/Partials/{key}.cshtml
        // (dispatched from Manage.cshtml's workflowScreens set). Menu
        // rows + Admin permissions are seeded in migration 068.
        new("workflows","Workflow Definitions","Organization workflows -- unlimited, versioned, org-defined (BRD Sec 6).","sitemap",["Code","Name","ApplicableEntityType","Version","Owner","Status"], WorkflowGroup),
        new("workflow-stages","Workflow Stages","Ordered stages within a workflow with allowed transitions (BRD Sec 7).","route",["Sequence","Code","Name","AllowedTransitions","Status"], WorkflowGroup),
        new("workflow-entity-types","Entity Types","Configurable, org-defined entity types the engine understands -- no hard-coded categories (BRD Sec 9).","shapes",["Code","Name","Category","Status"], WorkflowGroup),
        new("workflow-events","Events","Lifecycle events organizations wish to observe -- People / Assets / Vendor / Application / Custom (BRD Sec 8).","bolt",["Code","Name","EntityCategory","TriggerSource","Status"], WorkflowGroup),
        new("workflow-checklists","Checklists","Reusable checklists composed of items -- Manual / Automated / API / Document / Approval / Integration (BRD Sec 11).","list-check",["Code","Name","Version","Items","Status"], WorkflowGroup),
        new("workflow-event-mappings","Event-Checklist Mappings","Entity + Event -> Checklist mappings driving the trigger engine (BRD Sec 10).","link",["EntityType","Event","Checklist","DefaultOwnerRole","DefaultDueDays","Status"], WorkflowGroup),
        // "workflow-scope-mapping" retired by migration 138. It was one screen
        // doing two unrelated jobs. Each half moved to where its master data
        // is maintained: role checklists to Role Master Add/Edit (a section on
        // the role form), asset-category checklists to "asset-category-
        // assurance" under Operations. No mapping data moved.
        // "workflow-event-inbox" retired: its contents are the Event Driven
        // Assurance tab of Task Center (Oversight). Two places showing the same
        // open checklists would mean two places to close them from, and no
        // answer to which one is the queue of record.
        new("event-assurance","Event Assurance","Event-driven assurance instances -- received, pending, completed, failed, overdue (BRD Sec 13/14).","shield-halved",["EventCode","Entity","Checklist","Owner","DueDate","Status"], WorkflowGroup),
        new("workflow-dashboard","Workflow Dashboard","Cross-workflow event and assurance KPIs (BRD Sec 16).","chart-line",["Metric","Value"], WorkflowGroup)
        ,
        // ===== Phase 2 Assurance Management (BRD Part 2) =====
        // NEW, INDEPENDENT module. Menu row seeded under nav-assurance
        // (parent_menu_id) by migration 071. Consumes Admin (grac_new)
        // published assurance metadata via repository_subscription.
        // Stage 1 = Assurance Definitions + lifecycle only.
        new("org-assurance-definitions","Assurance Definitions","Organization-level Assurance Definitions with lifecycle Draft / Under Review / Approved / Active / Retired (BRD Part 2 Sec 1).","file-shield",["Code","Name","Category","Owner","Version","Status"], OrganizationAssuranceGroup),
        // Scope Builder (BRD Part 2 Sec 2). Menu row seeded by
        // migration 075. Loads a definition via ?definitionId=X and
        // renders read-only when the current version is not Draft.
        new("org-assurance-scope-builder","Scope Builder","Configure the assurance scope for a definition using groups + conditions across 17 dimensions with AND / OR / NOT operators (BRD Part 2 Sec 2).","diagram-project",["Group","Operator","Dimension","Condition","Values"], OrganizationAssuranceGroup),
        // Question Builder (BRD Part 2 Sec 4). Menu row seeded by
        // migration 078. Question sets are organization-level reusable
        // artifacts; each definition later ADOPTS one or more sets.
        new("org-assurance-question-sets","Question Sets","Reusable Question Sets and their Questions -- with Admin-published question types, mandatory / weight / order / expected response (BRD Part 2 Sec 4).","clipboard-list",["Code","Name","Owner","Questions","Status"], OrganizationAssuranceGroup),
        // Evidence Configuration (BRD Part 2 Sec 5). Per-definition-
        // version evidence expectations. Menu row seeded by migration
        // 081; reuses PM evidence_type_master + collection_method_master.
        new("org-assurance-evidence-config","Evidence Config","Configure the evidence expected for a definition -- type, collection method (existing / API / manual), mandatory flag, validity, expiry (BRD Part 2 Sec 5).","file-circle-check",["Label","Type","Method","Mandatory","Validity"], OrganizationAssuranceGroup),
        // Workflow Configuration (BRD Part 2 Sec 6). Per-definition-
        // version workflow with stages (Auditor / Reviewer / Approver /
        // Custom), assigned role / employee, SLA and escalation.
        // Menu row seeded by migration 085.
        new("org-assurance-workflow-config","Workflow Config","Configure the workflow for a definition -- customize from an Admin template; stages with auditor / reviewer / approver, assignments, SLA, escalation (BRD Part 2 Sec 6).","sitemap",["Order","Stage","Type","Assigned","SLA"], OrganizationAssuranceGroup),
        // Scoring Configuration (BRD Part 2 Sec 7). Per-definition-
        // version scoring model + bands. Menu row seeded by migration
        // 088. Controlled representation -- no user formulas, no
        // dynamic SQL.
        new("org-assurance-scoring-config","Scoring Config","Configure the scoring model for a definition -- Pass/Fail, Weighted, Risk Based, Maturity Based, Percentage or Custom; with thresholds and bands (BRD Part 2 Sec 7).","gauge",["ModelType","Bands","Pass","Warning","Fail"], OrganizationAssuranceGroup),
        // Assurance Plans (BRD Part 2 Sec 8). Stage 3. Annual /
        // Quarterly / Monthly / One-Time plans; items link to
        // assurance definitions with schedule + assignments.
        // Menu row seeded by migration 091.
        new("org-assurance-plans","Assurance Plans","Annual / Quarterly / Monthly / One-Time Assurance Plans with items that schedule assurance definitions and assign owner / team / auditor / department / branch (BRD Part 2 Sec 8).","calendar-days",["Code","Name","Type","Period","Owner","Items","Status"], OrganizationAssuranceGroup),
        // Triggers (BRD Part 2 Sec 9). Stage 3. Per-definition-version
        // triggers of type SCHEDULED / EVENT_DRIVEN / CONTINUOUS /
        // MANUAL. Menu row seeded by migration 094.
        new("org-assurance-triggers","Triggers","Configure Scheduled / Event Driven / Continuous / Manual triggers for a definition version. Scheduled uses Daily/Weekly/Monthly/Quarterly/Annual; Event Driven uses License Expiry / User Termination / Vendor Renewal / High Value Transaction / New Asset / Policy Change / Security Incident (BRD Part 2 Sec 9).","bolt",["Code","Name","Type","Enabled","Details"], OrganizationAssuranceGroup),
        // Scope Resolution (BRD Part 2 Sec 3). Stage 3. Runs the
        // resolver over a definition version's scope and stores an
        // immutable snapshot for historical execution. Menu row seeded
        // by migration 097.
        new("org-assurance-scope-resolution","Scope Resolution","Preview or view historical Scope Resolution snapshots for an assurance definition (BRD Part 2 Sec 3).","circle-nodes",["When","Purpose","Dimensions","Total"], OrganizationAssuranceGroup),
        // Executions (BRD Part 2 Sec 9-10). Stage 3. Materializes a
        // definition + resolved scope + immutable config snapshot into
        // a live executable record. Menu row seeded by migration 100.
        new("org-assurance-executions","Executions","Materialize and manage live assurance executions against resolved scope snapshots (BRD Part 2 Sec 9-10).","play-circle",["Execution","Definition","Status","Progress"], OrganizationAssuranceGroup),
        // Observations (BRD Part 2 Sec 11). Stage 4. Findings recorded
        // during an execution, evidence attachments, review + resolution
        // lifecycle. Menu row seeded by migration 103.
        // Assurance-source gaps now land in the UNIFIED Gap Center
        // (Practice/Index/gaps -> Assurance Gaps tab) instead of a
        // separate assurance-only page. See migrations 109 - 113.
        new("org-assurance-observations","Observations","Findings recorded during assurance executions -- capture, evidence, review, resolve (BRD Part 2 Sec 11).","triangle-exclamation",["Observation","Severity","Status","Owner"], OrganizationAssuranceGroup),
        // ===== Organization SLA Configuration (migrations 178/179/180) =====
        // Adopts SLA masters published by Control Management (grac_new)
        // into per-organization configurations with warning/escalation
        // day thresholds, notify roles (WARNING / ESCALATION), and
        // process bindings (GAP / TASK / OBSERVATION / EXCEPTION ...).
        // Screen sits under nav-governance (menu seed 180).
        new("org-sla-config","SLA Configuration","Adopt Control Management SLA masters, configure warning + escalation day thresholds, pick notify roles, and bind the tuned SLA against processes (Gap / Task / Observation / Exception).","clock",["SLA","TotalDays","Warning","Escalation","Roles","Processes"], GovernanceGroup)
    ];
}

