// =====================================================================
// ManagementDashboardModels  (migrations 413 / 414)
//
// Contracts for ManagementDashboardController -- the landing dashboards
// of the Governance, Issues & Actions and Audit & Assurance parent menus
// -- and the drill-down filter the existing list endpoints accept when a
// dashboard tile, ageing band or distribution bar is clicked.
//
// Every dashboard procedure returns the same four result sets (KPIs,
// ageing bands, distributions, lists), so one set of records serves all
// three modules. See docs/management-dashboards.md.
// =====================================================================
namespace PracticeManagement.Api.Models;

public sealed record ManagementDashboardKpi(
    string SectionKey, string SectionTitle, string KpiKey, string Label,
    int Value, bool IsAlert, int SortOrder);

public sealed record ManagementDashboardAgeingBand(
    string GroupKey, string GroupTitle, string BandCode, string BandName,
    int SortOrder, int MinDays, int MaxDays, int ItemCount);

// ItemKey is the exact value the target list's own filter takes (a
// status code, a severity, a priority); null when the bucket has no
// value to filter on (e.g. "(not set)").
public sealed record ManagementDashboardDistributionItem(
    string GroupKey, string GroupTitle, string? ItemKey, string ItemLabel,
    int ItemCount, string? ColourHex, int SortOrder);

public sealed record ManagementDashboardListRow(
    string ListKey, string ListTitle, long? RecordId, string? RefText, string? Title,
    string? OwnerName, string? StatusText, DateTime? DateValue, int SortOrder);

public sealed record ManagementDashboard(
    string Module,
    IReadOnlyList<ManagementDashboardKpi> Kpis,
    IReadOnlyList<ManagementDashboardAgeingBand> Ageing,
    IReadOnlyList<ManagementDashboardDistributionItem> Distributions,
    IReadOnlyList<ManagementDashboardListRow> Lists);

/// <summary>
/// Dashboard drill-down filter (414), accepted by the Gap Register, Task
/// Board, Exceptions, audit Executions and Observations list endpoints.
/// Every member null = no opinion, so a list's own requests are
/// unchanged. Bound from the query string by property name:
/// ?drillCode=&amp;statusText=&amp;severityText=&amp;minAgeDays=&amp;maxAgeDays=&amp;noOwner=
/// </summary>
public sealed class ListDrillQuery
{
    public string? DrillCode    { get; init; }
    public string? StatusText   { get; init; }
    public string? SeverityText { get; init; }
    public int?    MinAgeDays   { get; init; }
    public int?    MaxAgeDays   { get; init; }
    // A string, like the Risk Centre's tri-state filters: the screens
    // send "1" / "0" and the bool? binder would turn that into a 400.
    public string? NoOwner      { get; init; }

    public ListDrillFilter ToFilter() => new(
        Clean(DrillCode), Clean(StatusText), Clean(SeverityText), MinAgeDays, MaxAgeDays,
        NoOwner?.Trim().ToLowerInvariant() is "1" or "true" or "yes" ? true : null);

    private static string? Clean(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}

public sealed record ListDrillFilter(
    string? DrillCode = null, string? StatusText = null, string? SeverityText = null,
    int? MinAgeDays = null, int? MaxAgeDays = null, bool? NoOwner = null);
