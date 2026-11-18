// =====================================================================
// OrgAssuranceRbiaService (582, CR2 - AA Part D -- RBIA)
//
// Risk-Based Internal Audit over the 582 procedures: the versioned
// methodology (draft, save, publish, discard) and the assessments (list,
// create, get, save answers / override, workflow). On APPROVE the subject's
// enterprise risk intelligence (581, IOrgAssuranceUniverseService) is read
// at that moment and frozen on the assessment as its risk snapshot.
// Reads return the procedures' rows (OrgAssuranceReportService pattern).
//
// Wire-up: Infrastructure/OrgAssuranceRbiaServiceRegistration.cs.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgAssuranceRbiaService
{
    Task<List<Dictionary<string, object?>>> ListMethodologiesAsync(long organizationId, CancellationToken cancellationToken);
    Task<Dictionary<string, object?>> GetMethodologyAsync(long organizationId, long? methodologyId, CancellationToken cancellationToken);
    Task<OrgAssuranceRbiaResult> StartDraftAsync(OrgAssuranceRbiaDraftRequest request, long? employeeId, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceRbiaResult> SaveMethodologyAsync(long methodologyId, OrgAssuranceRbiaMethodologySaveRequest request, long? employeeId, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceRbiaResult> PublishMethodologyAsync(long methodologyId, long organizationId, long employeeId, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceRbiaResult> DiscardMethodologyAsync(long methodologyId, long organizationId, long? employeeId, string actor, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> ListAssessmentsAsync(
        long organizationId, string? status, string? period, string? band, bool currentOnly, string? search, long? employeeId, CancellationToken cancellationToken);
    Task<OrgAssuranceRbiaResult> CreateAssessmentsAsync(OrgAssuranceRbiaCreateRequest request, long? employeeId, string actor, CancellationToken cancellationToken);
    Task<Dictionary<string, object?>?> GetAssessmentAsync(long organizationId, long assessmentId, long? employeeId, CancellationToken cancellationToken);
    Task<OrgAssuranceRbiaResult> SaveAssessmentAsync(long assessmentId, OrgAssuranceRbiaSaveRequest request, long employeeId, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceRbiaResult> AssessmentActionAsync(long assessmentId, OrgAssuranceRbiaActionRequest request, long employeeId, string actor, CancellationToken cancellationToken);
}

public sealed class OrgAssuranceRbiaService(
    IConfiguration configuration,
    IOrgAssuranceUniverseService universe,
    ILogger<OrgAssuranceRbiaService> logger) : IOrgAssuranceRbiaService
{
    // -----------------------------------------------------------------
    // Methodology
    // -----------------------------------------------------------------
    public Task<List<Dictionary<string, object?>>> ListMethodologiesAsync(long organizationId, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_rbia_methodology_list", c => AddParam(c, "@organization_id", DbType.Int64, organizationId), cancellationToken);

    public Task<Dictionary<string, object?>> GetMethodologyAsync(long organizationId, long? methodologyId, CancellationToken cancellationToken)
        => ReadSetsAsync("sp_org_assurance_rbia_methodology_get", c =>
        {
            AddParam(c, "@organization_id",     DbType.Int64, organizationId);
            AddParam(c, "@rbia_methodology_id", DbType.Int64, (object?)methodologyId ?? DBNull.Value);
        }, ["methodology", "levels", "parameters", "questions", "options", "bands"], cancellationToken);

    public Task<OrgAssuranceRbiaResult> StartDraftAsync(OrgAssuranceRbiaDraftRequest r, long? employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_rbia_methodology_draft", "@rbia_methodology_id_out", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,   r.OrganizationId);
            AddParam(c, "@source",          DbType.String,  r.Source, 20);
            AddParam(c, "@replace",         DbType.Boolean, r.Replace);
            AddParam(c, "@employee_id",     DbType.Int64,   (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@actor",           DbType.String,  actor, 100);
        }, null, cancellationToken);

    public Task<OrgAssuranceRbiaResult> SaveMethodologyAsync(long methodologyId, OrgAssuranceRbiaMethodologySaveRequest r, long? employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_rbia_methodology_save", null, c =>
        {
            AddParam(c, "@organization_id",     DbType.Int64,  r.OrganizationId);
            AddParam(c, "@rbia_methodology_id", DbType.Int64,  methodologyId);
            AddParam(c, "@content_json",        DbType.String, r.Content.GetRawText(), -1);
            AddParam(c, "@employee_id",         DbType.Int64,  (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@actor",               DbType.String, actor, 100);
        }, methodologyId, cancellationToken);

    public Task<OrgAssuranceRbiaResult> PublishMethodologyAsync(long methodologyId, long organizationId, long employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_rbia_methodology_publish", null, c =>
        {
            AddParam(c, "@organization_id",     DbType.Int64,  organizationId);
            AddParam(c, "@rbia_methodology_id", DbType.Int64,  methodologyId);
            AddParam(c, "@employee_id",         DbType.Int64,  employeeId);
            AddParam(c, "@actor",               DbType.String, actor, 100);
        }, methodologyId, cancellationToken);

    public Task<OrgAssuranceRbiaResult> DiscardMethodologyAsync(long methodologyId, long organizationId, long? employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_rbia_methodology_discard", null, c =>
        {
            AddParam(c, "@organization_id",     DbType.Int64,  organizationId);
            AddParam(c, "@rbia_methodology_id", DbType.Int64,  methodologyId);
            AddParam(c, "@employee_id",         DbType.Int64,  (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@actor",               DbType.String, actor, 100);
        }, methodologyId, cancellationToken);

    // -----------------------------------------------------------------
    // Assessments
    // -----------------------------------------------------------------
    public Task<List<Dictionary<string, object?>>> ListAssessmentsAsync(
        long organizationId, string? status, string? period, string? band, bool currentOnly, string? search, long? employeeId, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_rbia_assessment_list", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,   organizationId);
            AddParam(c, "@status",          DbType.String,  (object?)status ?? DBNull.Value, 20);
            AddParam(c, "@period",          DbType.String,  (object?)period ?? DBNull.Value, 60);
            AddParam(c, "@band_code",       DbType.String,  (object?)band ?? DBNull.Value, 30);
            AddParam(c, "@current_only",    DbType.Boolean, currentOnly);
            AddParam(c, "@search",          DbType.String,  (object?)search ?? DBNull.Value, 200);
            AddParam(c, "@employee_id",     DbType.Int64,   (object?)employeeId ?? DBNull.Value);
        }, cancellationToken);

    public Task<OrgAssuranceRbiaResult> CreateAssessmentsAsync(OrgAssuranceRbiaCreateRequest r, long? employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_rbia_assessment_create", "@created_count", c =>
        {
            AddParam(c, "@organization_id",      DbType.Int64,  r.OrganizationId);
            AddParam(c, "@subject_ids_json",     DbType.String, System.Text.Json.JsonSerializer.Serialize(r.SubjectIds ?? Array.Empty<long>()), -1);
            AddParam(c, "@assessment_period",    DbType.String, r.Period, 60);
            AddParam(c, "@assessment_type",      DbType.String, r.Type, 20);
            AddParam(c, "@trigger_reason",       DbType.String, (object?)r.TriggerReason ?? DBNull.Value, 2000);
            AddParam(c, "@assessor_employee_id", DbType.Int64,  r.AssessorEmployeeId);
            AddParam(c, "@employee_id",          DbType.Int64,  (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@actor",                DbType.String, actor, 100);
        }, null, cancellationToken, DbType.Int32);

    public async Task<Dictionary<string, object?>?> GetAssessmentAsync(long organizationId, long assessmentId, long? employeeId, CancellationToken cancellationToken)
    {
        var sets = await ReadSetsAsync("sp_org_assurance_rbia_assessment_get", c =>
        {
            AddParam(c, "@organization_id",    DbType.Int64, organizationId);
            AddParam(c, "@rbia_assessment_id", DbType.Int64, assessmentId);
            AddParam(c, "@employee_id",        DbType.Int64, (object?)employeeId ?? DBNull.Value);
        }, ["assessment", "parameters", "questions", "options", "levels", "bands", "history"], cancellationToken);
        if (sets["assessment"] is not List<Dictionary<string, object?>> head || head.Count == 0) return null;
        sets["assessment"] = head[0];
        return sets;
    }

    public Task<OrgAssuranceRbiaResult> SaveAssessmentAsync(long assessmentId, OrgAssuranceRbiaSaveRequest r, long employeeId, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_rbia_assessment_save", null, c =>
        {
            AddParam(c, "@organization_id",    DbType.Int64,  r.OrganizationId);
            AddParam(c, "@rbia_assessment_id", DbType.Int64,  assessmentId);
            AddParam(c, "@row_version_no",     DbType.Int32,  r.RowVersionNo);
            AddParam(c, "@responses_json",     DbType.String, r.Responses is { } rs ? (object)rs.GetRawText() : DBNull.Value, -1);
            AddParam(c, "@override_json",      DbType.String,
                     r.Override is { ValueKind: System.Text.Json.JsonValueKind.Object } ov ? (object)ov.GetRawText() : DBNull.Value, -1);
            AddParam(c, "@employee_id",        DbType.Int64,  employeeId);
            AddParam(c, "@actor",              DbType.String, actor, 100);
        }, assessmentId, cancellationToken);

    public async Task<OrgAssuranceRbiaResult> AssessmentActionAsync(long assessmentId, OrgAssuranceRbiaActionRequest r, long employeeId, string actor, CancellationToken cancellationToken)
    {
        // APPROVE freezes the enterprise risk information of that moment
        // (581) on the assessment -- read here, from the same procedure the
        // Risk Intelligence screen uses.
        string? snapshot = null;
        if (string.Equals(r.Action?.Trim(), "APPROVE", StringComparison.OrdinalIgnoreCase))
        {
            var current = await GetAssessmentAsync(r.OrganizationId, assessmentId, employeeId, cancellationToken);
            if (current?["assessment"] is Dictionary<string, object?> head && head.TryGetValue("UniverseSubjectId", out var sid) && sid is not null)
            {
                var intelligence = await universe.GetRiskIntelligenceAsync(r.OrganizationId, Convert.ToInt64(sid), cancellationToken);
                snapshot = System.Text.Json.JsonSerializer.Serialize(new
                {
                    capturedUtc = DateTime.UtcNow,
                    risks       = intelligence.GetValueOrDefault("risks"),
                    summary     = intelligence.GetValueOrDefault("summary"),
                    gaps        = intelligence.GetValueOrDefault("gaps"),
                    findings    = intelligence.GetValueOrDefault("findings")
                });
            }
        }
        return await WriteAsync("sp_org_assurance_rbia_assessment_action", "@new_assessment_id", c =>
        {
            AddParam(c, "@organization_id",    DbType.Int64,  r.OrganizationId);
            AddParam(c, "@rbia_assessment_id", DbType.Int64,  assessmentId);
            AddParam(c, "@action",             DbType.String, r.Action, 20);
            AddParam(c, "@comment",            DbType.String, (object?)r.Comment ?? DBNull.Value, -1);
            AddParam(c, "@row_version_no",     DbType.Int32,  (object?)r.RowVersionNo ?? DBNull.Value);
            AddParam(c, "@risk_snapshot_json", DbType.String, (object?)snapshot ?? DBNull.Value, -1);
            AddParam(c, "@employee_id",        DbType.Int64,  employeeId);
            AddParam(c, "@actor",              DbType.String, actor, 100);
        }, null, cancellationToken);
    }

    // -----------------------------------------------------------------
    // Helpers (as OrgAssuranceReportService)
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

    // Several result sets, named in order.
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

    private async Task<OrgAssuranceRbiaResult> WriteAsync(
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
            return new OrgAssuranceRbiaResult(true, outId);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "OrgAssuranceRbiaService.{Procedure} SQL error {Number}: {Message}",
                procedure, ex.Number, ex.Message);
            return new OrgAssuranceRbiaResult(false, Error: ex.Message, ReasonCode: MapReason(ex.Number));
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

    // 582 THROW numbers (54130-54143).
    private static string MapReason(int errorNumber) => errorNumber switch
    {
        54130 => "RBIA_NOT_FOUND",
        54131 => "RBIA_STATE",
        54132 => "RBIA_NO_METHODOLOGY",
        54133 => "RBIA_METHODOLOGY_INVALID",
        54134 => "RBIA_ASSESSOR_ONLY",
        54135 => "RBIA_REVIEWER_ONLY",
        54136 => "RBIA_HIA_ONLY",
        54137 => "RBIA_UNANSWERED",
        54138 => "RBIA_REASON_REQUIRED",
        54139 => "RBIA_CONCURRENCY",
        54140 => "RBIA_NOTHING_SELECTED",
        54141 => "RBIA_SUBJECT_NOT_ACTIVE",
        54142 => "RBIA_OVERRIDE_JUSTIFICATION",
        54143 => "RBIA_DRAFT_EXISTS",
        _     => "SQL_ERROR"
    };
}
