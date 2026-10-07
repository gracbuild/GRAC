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
                ("instances",  "resolve")
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
            ]
        };

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
