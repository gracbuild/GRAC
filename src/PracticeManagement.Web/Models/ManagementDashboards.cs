// =====================================================================
// ManagementDashboards  (migrations 413 / 414)
//
// The module dashboards and the child screens each of their sections
// summarises. One map, read by:
//   * PracticeController -- a dashboard page opens when the caller has
//     VIEW on the dashboard's own menu row (the "Dashboard" submenu,
//     migration 416) AND may VIEW at least one of its child screens; only
//     the sections whose child the caller may VIEW are shown (CanOpen);
//   * ManagementDashboardController (Web proxy) -- the same rule for the
//     data read.
// A dashboard summarises its children; it never shows what the child
// page itself would refuse.
// =====================================================================
namespace PracticeManagement.Web.Models;

public static class ManagementDashboards
{
    /// <summary>Dashboard screen key -> (section key, child screen key).</summary>
    public static readonly IReadOnlyDictionary<string, (string Section, string ChildScreen)[]> Sections =
        new Dictionary<string, (string, string)[]>(StringComparer.OrdinalIgnoreCase)
        {
            ["governance-dashboard"] =
            [
                ("frameworks", "organization-controls"),
                ("practices",  "organization-requirements"),
                ("instances",  "resolve"),
                // 503: evidence and dependency position of the same
                // instances -- both are captured on Operationalize.
                ("evidence",     "resolve"),
                ("dependencies", "resolve")
            ],
            ["issues-actions-dashboard"] =
            [
                ("gaps",       "gaps"),
                ("tasks",      "tasks"),
                ("exceptions", "exception-centre")
            ],
            ["audit-assurance-dashboard"] =
            [
                ("audits",   "org-assurance-executions"),
                ("findings", "org-assurance-observations"),
                ("plans",    "org-assurance-plans")
            ],
            // 451: Asset & Contract dashboard (sp_dashboard_asset_contract).
            ["asset-contract-dashboard"] =
            [
                ("governance",    "asset-governance"),
                ("assets",        "asset-register"),
                ("technology",    "asset-register"),
                ("contracts",     "asset-contracts"),
                ("attestation",   "asset-attestation"),
                ("activities",    "asset-activities"),
                ("privacy",       "asset-privacy"),
                ("discovery",     "asset-discovery"),
                ("services",      "business-services"),
                ("relationships", "asset-relationships"),
                ("notifications", "asset-notifications")
            ],
            // 490: Third-Party Management dashboard (sp_dashboard_tprm; module renamed by 521).
            ["tprm-dashboard"] =
            [
                ("tprmthirdparties", "tprm-third-parties"),
                ("tprmengagements",  "tprm-engagements"),
                ("tprmdiligence",    "tprm-engagements"),
                ("tprmfindings",     "tprm-engagements"),
                ("tprmreviews",      "tprm-reviews"),
                ("tprmacceptance",   "tprm-engagements"),
                ("tprmregister",     "tprm-risk-register")   // 525: TP Risk Register (CR 2 8)
            ],
            // 508: Policies & Documents dashboard (sp_dashboard_documents).
            ["documents-dashboard"] =
            [
                ("documents",        "document-uploads"),
                ("acknowledgements", "document-acknowledgements"),
                ("docevidence",      "evidence-center")   // "evidence" is Governance's (503)
            ]
        };

    /// <summary>
    /// 503 (Dashboard UI specification v2, Home): the module dashboards Home
    /// offers as snapshot cards, in display order. Module = the data route
    /// segment (management-dashboard/{module}; "risk" reads the Risk Centre
    /// dashboard), ScreenKey = the dashboard page the card opens. Home shows
    /// a card only when PracticeController.CanViewScreen(ScreenKey) -- the
    /// rule the dashboard page itself applies.
    /// </summary>
    public static readonly (string Module, string ScreenKey, string Title)[] HomeSnapshots =
    [
        ("governance",      "governance-dashboard",      "Governance"),
        ("issues-actions",  "issues-actions-dashboard",  "Issues & Actions"),
        ("risk",            "risk-centre-dashboard",     "Risk Management"),
        ("audit-assurance", "audit-assurance-dashboard", "Audit Assurance"),
        ("tprm",            "tprm-dashboard",            "Third-Party Management"),   // 521
        ("documents",       "documents-dashboard",       "Policies & Documents"),   // 508
        ("asset-contract",  "asset-contract-dashboard",  "Asset & Contract")
    ];

    /// <summary>API module key (route segment) of a dashboard screen:
    /// "governance-dashboard" -> "governance".</summary>
    public static string ModuleOf(string screenKey) =>
        screenKey.EndsWith("-dashboard", StringComparison.OrdinalIgnoreCase)
            ? screenKey[..^"-dashboard".Length]
            : screenKey;

    public static bool IsDashboard(string? screenKey) =>
        !string.IsNullOrWhiteSpace(screenKey) && Sections.ContainsKey(screenKey);

    /// <summary>
    /// Whether a dashboard page / its data may be opened (416): VIEW on
    /// the dashboard's own menu row (its "Dashboard" submenu, keyed by the
    /// screen key) plus VIEW on at least one child screen it summarises.
    /// 416 granted the row to exactly the roles that could VIEW a child,
    /// so nobody lost access; Role Master can now withhold it.
    /// </summary>
    public static bool CanOpen(string screenKey, Func<string, bool> hasOwnView, Func<string, bool> canViewChild) =>
        IsDashboard(screenKey) && hasOwnView(screenKey) && AllowedSections(screenKey, canViewChild).Length > 0;

    /// <summary>The sections whose child screen passes <paramref name="canView"/>.</summary>
    public static string[] AllowedSections(string screenKey, Func<string, bool> canView) =>
        Sections.TryGetValue(screenKey, out var sections)
            ? sections.Where(s => canView(s.ChildScreen)).Select(s => s.Section).ToArray()
            : [];
}
