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
        new("teams","Team Management","Organization teams mapped to departments and managed by employees","people-group",["Organization","Name","TeamManager","ParentDepartment","Status"], OrganizationGroup),
        new("committees","Committee Management","Organization committees with chairperson, secretary, and review frequency","users-gear",["Organization","Name","Chairperson","Secretary","ReviewFrequency","Status"], OrganizationGroup),
        new("roles","Role Master","Organization-specific roles used for menu and action permissions","user-lock",["Organization","RoleCode","RoleName","Description","Status"], AdministrationGroup),
        new("role-menu-permissions","Role Menu Permission","Assign Practice Management menu permissions to an organization role","list-check",["Organization","RoleName","MenuName","CanView","CanAdd","CanEdit","CanDelete","CanApprove","Status"], AdministrationGroup),
        new("user-role-assignments","User Role Assignment","Assign one or more organization roles to organization users","user-gear",["EmployeeCode","EmployeeName","Email","RoleNames","Status"], AdministrationGroup),
        new("users","User Management","Users available for organization ownership and assignment","users",["EmployeeCode","EmployeeName","Email","RoleName","Designation","Status"], AdministrationGroup),
        new("organization-dependencies","Organization Dependencies","Organization dependency objects for applications, tools, vendors, assets, and processes","diagram-project",["Name","Owner","Criticality","Status"], OrganizationDependenciesGroup),
        new("dependency-applications","Applications","Business applications supporting organization practices","window-restore",["Name","BusinessOwner","TechnicalOwner","Vendor","HostingType","Criticality","Status"], OperationsGroup),
        new("dependency-tools","Tools","Utility tools supporting execution of practices","screwdriver-wrench",["Name","BusinessOwner","Vendor","LicenseType","Criticality","Status"], OperationsGroup),
        new("dependency-vendors","Vendors","Third parties providing services or products","handshake",["Name","ServiceCategory","RelationshipOwner","Criticality","Status"], OperationsGroup),
        new("dependency-assets","Assets","Physical or logical assets supporting practices","server",["Name","AssetCategory","Owner","Location","Criticality","Status"], OperationsGroup),
        new("dependency-processes","Processes","Business processes supporting organizational execution","arrows-spin",["Name","ProcessOwner","Version","NextReviewDate","Status"], OperationsGroup),
        new("user-assignments","User Assignment","Assign users to organization and department scope","user-check",["Organization","Department","User","Role","Status"], OrganizationOnboardingGroup),
        new("owner-mappings","Role / Owner Mapping","Map ownership roles to users for organization operations","user-shield",["Organization","Role","Owner","BackupOwner","Status"], OrganizationOnboardingGroup),
        // organization-controls is the underlying two-level screen: Level 1 renders
        // the subscribed Framework Release summary (RS2); Level 2 drills into that
        // release's Source Statement tree (RS3). Migration 056 makes this the target
        // of the Repository Subscriptions menu so users land on Level 1 by default.
        new("organization-controls","Repository Subscriptions","Subscribed Framework Release summary with drill-down into Source Statements.","shield",["Code","Name","OriginType","SourceFrameworkRelease","ApplicabilityStatus","ApplicablePracticeCount","PrimaryOwner","Criticality"], GovernanceGroup),
        // source-statements is an ALIAS of organization-controls -- same view, same
        // columns, same JS. It exists so the Source Statements menu has its own
        // sidebar-highlighting URL and lands users directly on the Level 2 statement
        // grid (auto-drilling into the first subscribed release).
        new("source-statements","Source Statements","Source Statement grid for a subscribed Framework Release.","shield",["Code","Name","OriginType","SourceFrameworkRelease","ApplicabilityStatus","ApplicablePracticeCount","PrimaryOwner","Criticality"], GovernanceGroup),
        new("organization-requirements","Practices","Organization-scoped practices and applicability decisions with expandable Practice Instances","list-check",["Code","Name","ApplicabilityStatus","PracticeOwner","PracticeInstanceCount"], GovernanceGroup),
        new("practices","Practice Management","Implementation approaches for applicable requirements","clipboard-check",["Code","Name","OriginType","ApplicabilityStatus","PracticeOwner","Status"], GovernanceGroup),
        new("practice-instances","Practice Instances","Operational implementation units for practice intelligence","network-wired",["Code","Name","PrimaryOwner","Department","ExecutionFrequency","AssuranceFrequency","AssuranceMode","Criticality","ImplementationStatus","Status"], GovernanceGroup),
        new("resolve","Resolve","Resolve practice instance dependency and evidence registers assigned to you","gears",["Name","OwningDepartment","PrimaryOwner","Frequency","Register","ResolvedDependencyName","ResolutionStatus","ResolutionOwner","LastUpdated"], OperationsGroup),
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
        new("gaps","Gap Center","Sources of work — Practice Instances not yet Implemented / Partially Implemented, and future Assurance / Custom gaps","triangle-exclamation",["Instance","Practice","Organization","ImplementationStatus","Owner","Criticality","ExistingTasks"], OversightGroup),
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
    ];
}

