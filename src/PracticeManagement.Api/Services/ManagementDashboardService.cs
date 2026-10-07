// =====================================================================
// ManagementDashboardService  (migration 414)
//
// Facade over the module dashboard procedures -- one call, four result
// sets, org-scoped:
//   governance       sp_dashboard_governance        (+ caller scoping)
//   issues-actions   sp_dashboard_issues_actions
//   audit-assurance  sp_dashboard_audit_assurance
//   asset-contract   sp_dashboard_asset_contract    (451)
// Risk Management keeps its own dashboard (RiskCentreService, 413).
//
// Every number is computed in SQL; this class only maps rows.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IManagementDashboardService
{
    /// <summary>Null when <paramref name="module"/> is not a dashboard.</summary>
    Task<ManagementDashboard?> GetAsync(string module, long organizationId,
        long? callerEmployeeId, bool callerIsAdmin, CancellationToken cancellationToken);
}

public sealed class ManagementDashboardService(IConfiguration configuration) : IManagementDashboardService
{
    // Module key (the route segment) -> procedure. The keys are the
    // Practice/Index/<module>-dashboard screen keys without the suffix.
    private static readonly Dictionary<string, string> Procedures = new(StringComparer.OrdinalIgnoreCase)
    {
        ["governance"]      = "grac_practice.sp_dashboard_governance",
        ["issues-actions"]  = "grac_practice.sp_dashboard_issues_actions",
        ["audit-assurance"] = "grac_practice.sp_dashboard_audit_assurance",
        ["asset-contract"]  = "grac_practice.sp_dashboard_asset_contract"       // 451
    };

    public async Task<ManagementDashboard?> GetAsync(string module, long organizationId,
        long? callerEmployeeId, bool callerIsAdmin, CancellationToken cancellationToken)
    {
        if (!Procedures.TryGetValue(module ?? "", out var procedure)) return null;

        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = procedure;
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        // Governance applies Operationalize's ownership rule (a non-admin
        // sees the instances they own), so it needs the caller.
        if (module!.Equals("governance", StringComparison.OrdinalIgnoreCase))
        {
            AddParam(command, "@caller_employee_id", DbType.Int64, (object?)callerEmployeeId ?? DBNull.Value);
            AddParam(command, "@is_admin", DbType.Boolean, callerIsAdmin);
        }

        var kpis = new List<ManagementDashboardKpi>();
        var ageing = new List<ManagementDashboardAgeingBand>();
        var distributions = new List<ManagementDashboardDistributionItem>();
        var lists = new List<ManagementDashboardListRow>();

        await using var r = await command.ExecuteReaderAsync(cancellationToken);
        // Four result sets, fixed order (see 414 section 6).
        while (await r.ReadAsync(cancellationToken))
            kpis.Add(new ManagementDashboardKpi(
                Str(r, "SectionKey"), Str(r, "SectionTitle"), Str(r, "KpiKey"), Str(r, "Label"),
                Int(r, "Value"), r["IsAlert"] != DBNull.Value && Convert.ToBoolean(r["IsAlert"]), Int(r, "SortOrder")));

        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                ageing.Add(new ManagementDashboardAgeingBand(
                    Str(r, "GroupKey"), Str(r, "GroupTitle"), Str(r, "BandCode"), Str(r, "BandName"),
                    Int(r, "SortOrder"), Int(r, "MinDays"), Int(r, "MaxDays"), Int(r, "ItemCount")));

        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                distributions.Add(new ManagementDashboardDistributionItem(
                    Str(r, "GroupKey"), Str(r, "GroupTitle"), r["ItemKey"] as string, Str(r, "ItemLabel"),
                    Int(r, "ItemCount"), r["ColourHex"] as string, Int(r, "SortOrder")));

        if (await r.NextResultAsync(cancellationToken))
            while (await r.ReadAsync(cancellationToken))
                lists.Add(new ManagementDashboardListRow(
                    Str(r, "ListKey"), Str(r, "ListTitle"),
                    r["RecordId"] == DBNull.Value ? null : Convert.ToInt64(r["RecordId"]),
                    r["RefText"] as string, r["Title"] as string, r["OwnerName"] as string,
                    r["StatusText"] as string,
                    r["DateValue"] == DBNull.Value ? null : Convert.ToDateTime(r["DateValue"]),
                    Int(r, "SortOrder")));

        return new ManagementDashboard(module.ToLowerInvariant(), kpis, ageing, distributions, lists);
    }

    // SUM over no rows is NULL in SQL; a tile reads it as 0.
    private static int Int(DbDataReader r, string column) =>
        r[column] == DBNull.Value ? 0 : Convert.ToInt32(r[column]);

    private static string Str(DbDataReader r, string column) =>
        r[column] == DBNull.Value ? "" : Convert.ToString(r[column]) ?? "";

    private async Task<DbConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connString = Infrastructure.SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");

        var connection = new SqlConnection(connString);
        await connection.OpenAsync(cancellationToken);
        await Infrastructure.ViewScopeSession.ApplyAsync(connection, cancellationToken);   // 415: View Data Scope
        return connection;
    }

    private static void AddParam(DbCommand command, string name, DbType type, object? value, int? size = null)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType = type;
        if (size.HasValue) p.Size = size.Value;
        p.Value = value ?? DBNull.Value;
        command.Parameters.Add(p);
    }
}
