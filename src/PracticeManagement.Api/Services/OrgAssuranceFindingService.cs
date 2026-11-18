// =====================================================================
// OrgAssuranceFindingService (584, CR2 - AA Part F / G 9.2)
//
// Audit findings to the Gap Register and Risk Management:
//   * RaiseRiskCandidateAsync -- sp_org_assurance_finding_raise_risk (which
//     composes Risk Centre's sp_risk_candidate_create; its own result set
//     comes first, so the last result set is read).
//   * GapAuditSourceAsync -- sp_custom_gap_audit_source (Gap detail).
// Gap Candidates are raised by the existing CustomGapService
// (POST gaps/custom/generate).
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgAssuranceFindingService
{
    Task<OrgAssuranceFindingRiskResult> RaiseRiskCandidateAsync(long observationId, OrgAssuranceFindingRiskRequest request, long? employeeId, string actor, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> GapAuditSourceAsync(long organizationId, long gapId, CancellationToken cancellationToken);
}

public sealed class OrgAssuranceFindingService(
    IConfiguration configuration,
    ILogger<OrgAssuranceFindingService> logger) : IOrgAssuranceFindingService
{
    public async Task<OrgAssuranceFindingRiskResult> RaiseRiskCandidateAsync(
        long observationId, OrgAssuranceFindingRiskRequest r, long? employeeId, string actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = Proc(connection, "sp_org_assurance_finding_raise_risk");
            AddParam(command, "@organization_id", DbType.Int64,  r.OrganizationId);
            AddParam(command, "@observation_id",  DbType.Int64,  observationId);
            AddParam(command, "@employee_id",     DbType.Int64,  (object?)employeeId ?? DBNull.Value);
            AddParam(command, "@actor",           DbType.String, actor, 100);
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            List<Dictionary<string, object?>> last = [];
            do { last = await ReadRowsAsync(reader, cancellationToken); }
            while (await reader.NextResultAsync(cancellationToken));
            var row = last.Count > 0 ? last[0] : null;
            if (row is null || !row.ContainsKey("CandidateNumber"))
                return new OrgAssuranceFindingRiskResult(false, Error: "The risk candidate could not be read back.", ReasonCode: "SQL_ERROR");
            return new OrgAssuranceFindingRiskResult(true,
                row["RiskCandidateId"] is null ? null : Convert.ToInt64(row["RiskCandidateId"]),
                row["CandidateNumber"] as string, row["StatusCode"] as string,
                row["Created"] is bool b && b);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "OrgAssuranceFindingService.RaiseRiskCandidateAsync SQL error {Number}: {Message}", ex.Number, ex.Message);
            return new OrgAssuranceFindingRiskResult(false, Error: ex.Message, ReasonCode: MapReason(ex.Number));
        }
    }

    public async Task<List<Dictionary<string, object?>>> GapAuditSourceAsync(long organizationId, long gapId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "sp_custom_gap_audit_source");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@custom_gap_id",   DbType.Int64, gapId);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await ReadRowsAsync(reader, cancellationToken);
    }

    // -----------------------------------------------------------------
    // Helpers (as OrgAssuranceRbiaService)
    // -----------------------------------------------------------------
    private static DbCommand Proc(DbConnection connection, string procedure)
    {
        var command = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice." + procedure;
        return command;
    }

    private static async Task<List<Dictionary<string, object?>>> ReadRowsAsync(DbDataReader reader, CancellationToken cancellationToken)
    {
        var rows = new List<Dictionary<string, object?>>();
        while (await reader.ReadAsync(cancellationToken))
        {
            var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < reader.FieldCount; i++)
                row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            rows.Add(row);
        }
        return rows;
    }

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
        p.DbType        = type;
        p.Value         = value ?? DBNull.Value;
        if (size.HasValue) p.Size = size.Value;
        command.Parameters.Add(p);
    }

    // 584 THROW numbers; Risk Centre's candidate errors (56200-56203) pass through.
    private static string MapReason(int errorNumber) => errorNumber switch
    {
        54170 => "FINDING_NOT_FOUND",
        54171 => "FINDING_NOT_ACCEPTED",
        54172 => "FINDING_INFORMATIONAL",
        >= 56200 and <= 56203 => "RISK_CANDIDATE_REJECTED",
        _     => "SQL_ERROR"
    };
}
