// =====================================================================
// OrgAssurancePlanRecommendationService (583, CR2 - AA Part E -- Audit Plan
// Recommendations)
//
// The recommendation engine over the 583 procedures: settings, generate
// for a plan, list, change timing / programme / audit definition, Defer /
// Reject / Reopen, and Accept (link the engagement the shared engagement
// form created through the existing plan-items endpoint). Reads return the
// procedures' rows (OrgAssuranceRbiaService pattern).
//
// Wire-up: Infrastructure/OrgAssurancePlanRecommendationServiceRegistration.cs.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgAssurancePlanRecommendationService
{
    Task<Dictionary<string, object?>> GetSettingsAsync(long organizationId, long? employeeId, CancellationToken cancellationToken);
    Task<OrgAssurancePlanRecResult> SaveSettingsAsync(OrgAssurancePlanRecSettingRequest request, long employeeId, string actor, CancellationToken cancellationToken);
    Task<OrgAssurancePlanRecResult> GenerateAsync(OrgAssurancePlanRecGenerateRequest request, long employeeId, string actor, CancellationToken cancellationToken);
    Task<Dictionary<string, object?>> ListAsync(long organizationId, long planId, string? kind, string? status, string? search, long? employeeId, CancellationToken cancellationToken);
    Task<OrgAssurancePlanRecResult> UpdateAsync(long recommendationId, OrgAssurancePlanRecUpdateRequest request, long employeeId, string actor, CancellationToken cancellationToken);
    Task<OrgAssurancePlanRecResult> ActionAsync(long recommendationId, OrgAssurancePlanRecActionRequest request, long employeeId, string actor, CancellationToken cancellationToken);
    Task<OrgAssurancePlanRecResult> LinkAsync(long recommendationId, OrgAssurancePlanRecLinkRequest request, long employeeId, string actor, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> HistoryAsync(long organizationId, long planId, long? recommendationId, CancellationToken cancellationToken);
}

public sealed class OrgAssurancePlanRecommendationService(
    IConfiguration configuration,
    ILogger<OrgAssurancePlanRecommendationService> logger) : IOrgAssurancePlanRecommendationService
{
    public async Task<Dictionary<string, object?>> GetSettingsAsync(long organizationId, long? employeeId, CancellationToken cancellationToken)
    {
        var sets = await ReadSetsAsync("sp_org_assurance_plan_rec_setting_get", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64, organizationId);
            AddParam(c, "@employee_id",     DbType.Int64, (object?)employeeId ?? DBNull.Value);
        }, ["settings", "bands"], cancellationToken);
        if (sets["settings"] is List<Dictionary<string, object?>> head && head.Count > 0) sets["settings"] = head[0];
        return sets;
    }

    public Task<OrgAssurancePlanRecResult> SaveSettingsAsync(OrgAssurancePlanRecSettingRequest r, long employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_plan_rec_setting_save", null, c =>
        {
            AddParam(c, "@organization_id",           DbType.Int64,   r.OrganizationId);
            AddParam(c, "@include_band_codes",        DbType.String,  (object?)r.IncludeBandCodes ?? DBNull.Value, 400);
            AddParam(c, "@due_window_months",         DbType.Int32,   r.DueWindowMonths);
            AddParam(c, "@always_open_high_findings", DbType.Boolean, r.AlwaysOpenHighFindings);
            AddParam(c, "@always_high_reg",           DbType.Boolean, r.AlwaysHighRegSignificance);
            AddParam(c, "@always_never_audited",      DbType.Boolean, r.AlwaysNeverAudited);
            AddParam(c, "@ranking_order",             DbType.String,  (object?)r.RankingOrder ?? DBNull.Value, 400);
            AddParam(c, "@employee_id",               DbType.Int64,   employeeId);
            AddParam(c, "@actor",                     DbType.String,  actor, 100);
        }, r.OrganizationId, cancellationToken);

    public Task<OrgAssurancePlanRecResult> GenerateAsync(OrgAssurancePlanRecGenerateRequest r, long employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_plan_recommendation_generate", "@generated_count", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,  r.OrganizationId);
            AddParam(c, "@plan_id",         DbType.Int64,  r.PlanId);
            AddParam(c, "@employee_id",     DbType.Int64,  employeeId);
            AddParam(c, "@actor",           DbType.String, actor, 100);
        }, null, cancellationToken, DbType.Int32);

    public async Task<Dictionary<string, object?>> ListAsync(long organizationId, long planId, string? kind, string? status, string? search, long? employeeId, CancellationToken cancellationToken)
    {
        var sets = await ReadSetsAsync("sp_org_assurance_plan_recommendation_list", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,  organizationId);
            AddParam(c, "@plan_id",         DbType.Int64,  planId);
            AddParam(c, "@rec_kind",        DbType.String, (object?)kind ?? DBNull.Value, 20);
            AddParam(c, "@status",          DbType.String, (object?)status ?? DBNull.Value, 20);
            AddParam(c, "@search",          DbType.String, (object?)search ?? DBNull.Value, 200);
            AddParam(c, "@employee_id",     DbType.Int64,  (object?)employeeId ?? DBNull.Value);
        }, ["data", "summary"], cancellationToken);
        if (sets["summary"] is List<Dictionary<string, object?>> head && head.Count > 0) sets["summary"] = head[0];
        return sets;
    }

    public Task<OrgAssurancePlanRecResult> UpdateAsync(long recommendationId, OrgAssurancePlanRecUpdateRequest r, long employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_plan_recommendation_update", null, c =>
        {
            AddParam(c, "@organization_id",        DbType.Int64,  r.OrganizationId);
            AddParam(c, "@plan_recommendation_id", DbType.Int64,  recommendationId);
            AddParam(c, "@suggested_from",         DbType.Date,   (object?)r.SuggestedFrom?.Date ?? DBNull.Value);
            AddParam(c, "@suggested_to",           DbType.Date,   (object?)r.SuggestedTo?.Date ?? DBNull.Value);
            AddParam(c, "@programme_id",           DbType.Int64,  (object?)r.ProgrammeId ?? DBNull.Value);
            AddParam(c, "@definition_id",          DbType.Int64,  (object?)r.DefinitionId ?? DBNull.Value);
            AddParam(c, "@employee_id",            DbType.Int64,  employeeId);
            AddParam(c, "@actor",                  DbType.String, actor, 100);
        }, recommendationId, cancellationToken);

    public Task<OrgAssurancePlanRecResult> ActionAsync(long recommendationId, OrgAssurancePlanRecActionRequest r, long employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_plan_recommendation_action", null, c =>
        {
            AddParam(c, "@organization_id",        DbType.Int64,  r.OrganizationId);
            AddParam(c, "@plan_recommendation_id", DbType.Int64,  recommendationId);
            AddParam(c, "@action",                 DbType.String, r.Action, 20);
            AddParam(c, "@reason",                 DbType.String, (object?)r.Reason ?? DBNull.Value, 2000);
            AddParam(c, "@employee_id",            DbType.Int64,  employeeId);
            AddParam(c, "@actor",                  DbType.String, actor, 100);
        }, recommendationId, cancellationToken);

    public Task<OrgAssurancePlanRecResult> LinkAsync(long recommendationId, OrgAssurancePlanRecLinkRequest r, long employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_plan_recommendation_link", null, c =>
        {
            AddParam(c, "@organization_id",        DbType.Int64,  r.OrganizationId);
            AddParam(c, "@plan_recommendation_id", DbType.Int64,  recommendationId);
            AddParam(c, "@plan_item_id",           DbType.Int64,  r.PlanItemId);
            AddParam(c, "@comment",                DbType.String, (object?)r.Comment ?? DBNull.Value, 2000);
            AddParam(c, "@employee_id",            DbType.Int64,  employeeId);
            AddParam(c, "@actor",                  DbType.String, actor, 100);
        }, recommendationId, cancellationToken);

    public Task<List<Dictionary<string, object?>>> HistoryAsync(long organizationId, long planId, long? recommendationId, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_plan_recommendation_history", c =>
        {
            AddParam(c, "@organization_id",        DbType.Int64, organizationId);
            AddParam(c, "@plan_id",                DbType.Int64, planId);
            AddParam(c, "@plan_recommendation_id", DbType.Int64, (object?)recommendationId ?? DBNull.Value);
        }, cancellationToken);

    // -----------------------------------------------------------------
    // Helpers (as OrgAssuranceRbiaService)
    // -----------------------------------------------------------------
    private async Task<List<Dictionary<string, object?>>> ReadAsync(
        string procedure, Action<DbCommand> addParams, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, procedure);
        addParams(command);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await ReadRowsAsync(reader, cancellationToken);
    }

    private async Task<Dictionary<string, object?>> ReadSetsAsync(
        string procedure, Action<DbCommand> addParams, string[] names, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, procedure);
        addParams(command);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var result = new Dictionary<string, object?>();
        for (var i = 0; i < names.Length; i++)
        {
            if (i > 0 && !await reader.NextResultAsync(cancellationToken)) { result[names[i]] = new List<Dictionary<string, object?>>(); continue; }
            result[names[i]] = await ReadRowsAsync(reader, cancellationToken);
        }
        return result;
    }

    private async Task<OrgAssurancePlanRecResult> WriteAsync(
        string procedure, string? idOutput, Action<DbCommand> addParams, long? id, CancellationToken cancellationToken,
        DbType outputType = DbType.Int64)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = Proc(connection, procedure);
            addParams(command);
            DbParameter? output = null;
            if (idOutput is not null)
            {
                output = command.CreateParameter();
                output.ParameterName = idOutput;
                output.DbType        = outputType;
                output.Direction     = ParameterDirection.Output;
                command.Parameters.Add(output);
            }
            await command.ExecuteNonQueryAsync(cancellationToken);
            var outId = output?.Value is null or DBNull ? id : Convert.ToInt64(output.Value);
            return new OrgAssurancePlanRecResult(true, outId);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "OrgAssurancePlanRecommendationService.{Procedure} SQL error {Number}: {Message}",
                procedure, ex.Number, ex.Message);
            return new OrgAssurancePlanRecResult(false, Error: ex.Message, ReasonCode: MapReason(ex.Number));
        }
    }

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

    // 583 THROW numbers (54160-54168).
    private static string MapReason(int errorNumber) => errorNumber switch
    {
        54160 => "PLAN_REC_NOT_FOUND",
        54161 => "PLAN_REC_HIA_ONLY",
        54162 => "PLAN_REC_PLAN_NOT_OPEN",
        54163 => "PLAN_REC_STATE",
        54164 => "PLAN_REC_REASON_REQUIRED",
        54165 => "PLAN_REC_INVALID_PERIOD",
        54166 => "PLAN_REC_INVALID_REFERENCE",
        54167 => "PLAN_REC_ENGAGEMENT_NOT_IN_PLAN",
        54168 => "PLAN_REC_INVALID_SETTINGS",
        _     => "SQL_ERROR"
    };
}
