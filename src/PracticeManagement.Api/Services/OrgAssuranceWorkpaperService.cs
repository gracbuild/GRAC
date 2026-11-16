// =====================================================================
// OrgAssuranceWorkpaperService (567, Audit Change spec 4.6 / 4.7)
//
// Test Working Papers over the 567 procedures: the executions a person
// works on, an execution's questions / papers / team, the activity, and
// the writes (assign, paper save, paper action, conclude, audit
// conclusion, raise finding, a finding's spec 4.7 details). Reads return
// the procedures' rows (EvidenceCenterService's ReadRowsAsync pattern).
//
// Wire-up: Infrastructure/OrgAssuranceWorkpaperServiceRegistration.cs.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgAssuranceWorkpaperService
{
    Task<List<Dictionary<string, object?>>> ListTestingMethodsAsync(CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> ListObservationOriginsAsync(CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> ListExecutionsAsync(
        long organizationId, long? employeeId, bool mine, string? status, string? search, CancellationToken cancellationToken);
    Task<Dictionary<string, object?>> GetOverviewAsync(
        long organizationId, long executionId, long? employeeId, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> ListActivityAsync(
        long organizationId, long executionId, long? questionId, long? workingPaperId, CancellationToken cancellationToken);
    Task<OrgAssuranceWorkpaperResult> AssignQuestionAsync(
        long questionId, long employeeId, OrgAssuranceQuestionAssignRequest request, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceWorkpaperResult> ConcludeQuestionAsync(
        long questionId, long employeeId, OrgAssuranceQuestionConcludeRequest request, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceWorkpaperResult> SaveWorkingPaperAsync(
        long questionId, long employeeId, OrgAssuranceWorkingPaperSaveRequest request, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceWorkpaperResult> WorkingPaperActionAsync(
        long workingPaperId, long employeeId, OrgAssuranceWorkingPaperActionRequest request, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceWorkpaperResult> SaveAuditConclusionAsync(
        long executionId, long employeeId, OrgAssuranceAuditConclusionRequest request, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceWorkpaperResult> RaiseFindingAsync(
        long workingPaperId, long employeeId, OrgAssuranceRaiseFindingRequest request, string actor, CancellationToken cancellationToken);
    Task<Dictionary<string, object?>?> GetObservationFindingAsync(
        long organizationId, long observationId, CancellationToken cancellationToken);
    Task<OrgAssuranceWorkpaperResult> SaveObservationFindingAsync(
        long observationId, OrgAssuranceObservationFindingRequest request, string actor, CancellationToken cancellationToken);
}

public sealed class OrgAssuranceWorkpaperService(
    IConfiguration configuration,
    ILogger<OrgAssuranceWorkpaperService> logger) : IOrgAssuranceWorkpaperService
{
    // -----------------------------------------------------------------
    // Reads
    // -----------------------------------------------------------------
    public Task<List<Dictionary<string, object?>>> ListTestingMethodsAsync(CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_testing_method_list", _ => { }, cancellationToken);

    public Task<List<Dictionary<string, object?>>> ListObservationOriginsAsync(CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_observation_origin_list", _ => { }, cancellationToken);

    public Task<List<Dictionary<string, object?>>> ListExecutionsAsync(
        long organizationId, long? employeeId, bool mine, string? status, string? search, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_wp_execution_list", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,   organizationId);
            AddParam(c, "@employee_id",     DbType.Int64,   (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@mine",            DbType.Boolean, mine);
            AddParam(c, "@status",          DbType.String,  (object?)status ?? DBNull.Value, 60);
            AddParam(c, "@search",          DbType.String,  (object?)search ?? DBNull.Value, 200);
        }, cancellationToken);

    public async Task<Dictionary<string, object?>> GetOverviewAsync(
        long organizationId, long executionId, long? employeeId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "sp_org_assurance_wp_overview");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@execution_id",    DbType.Int64, executionId);
        AddParam(command, "@employee_id",     DbType.Int64, (object?)employeeId ?? DBNull.Value);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var execution = await ReadRowsAsync(reader, cancellationToken);
        var questions = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        var papers    = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        var team      = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        return new Dictionary<string, object?>
        {
            ["execution"] = execution.FirstOrDefault(),
            ["questions"] = questions,
            ["papers"]    = papers,
            ["team"]      = team
        };
    }

    public Task<List<Dictionary<string, object?>>> ListActivityAsync(
        long organizationId, long executionId, long? questionId, long? workingPaperId, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_wp_activity_list", c =>
        {
            AddParam(c, "@organization_id",       DbType.Int64, organizationId);
            AddParam(c, "@execution_id",          DbType.Int64, executionId);
            AddParam(c, "@execution_question_id", DbType.Int64, (object?)questionId ?? DBNull.Value);
            AddParam(c, "@working_paper_id",      DbType.Int64, (object?)workingPaperId ?? DBNull.Value);
        }, cancellationToken);

    public async Task<Dictionary<string, object?>?> GetObservationFindingAsync(
        long organizationId, long observationId, CancellationToken cancellationToken)
    {
        var rows = await ReadAsync("sp_org_assurance_observation_finding_get", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64, organizationId);
            AddParam(c, "@observation_id",  DbType.Int64, observationId);
        }, cancellationToken);
        return rows.FirstOrDefault();
    }

    // -----------------------------------------------------------------
    // Writes
    // -----------------------------------------------------------------
    public Task<OrgAssuranceWorkpaperResult> AssignQuestionAsync(
        long questionId, long employeeId, OrgAssuranceQuestionAssignRequest request, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_wp_question_assign", null, c =>
        {
            AddParam(c, "@organization_id",       DbType.Int64,  request.OrganizationId);
            AddParam(c, "@execution_question_id", DbType.Int64,  questionId);
            AddParam(c, "@assignee_employee_id",  DbType.Int64,  (object?)request.AssigneeEmployeeId ?? DBNull.Value);
            AddParam(c, "@employee_id",           DbType.Int64,  employeeId);
            AddParam(c, "@actor",                 DbType.String, actor, 100);
        }, questionId, cancellationToken);

    public Task<OrgAssuranceWorkpaperResult> ConcludeQuestionAsync(
        long questionId, long employeeId, OrgAssuranceQuestionConcludeRequest request, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_wp_question_conclude", null, c =>
        {
            AddParam(c, "@organization_id",       DbType.Int64,  request.OrganizationId);
            AddParam(c, "@execution_question_id", DbType.Int64,  questionId);
            AddParam(c, "@conclusion_code",       DbType.String, request.ConclusionCode, 20);
            AddParam(c, "@reason",                DbType.String, (object?)request.Reason ?? DBNull.Value, 2000);
            AddParam(c, "@employee_id",           DbType.Int64,  employeeId);
            AddParam(c, "@actor",                 DbType.String, actor, 100);
        }, questionId, cancellationToken);

    public Task<OrgAssuranceWorkpaperResult> SaveWorkingPaperAsync(
        long questionId, long employeeId, OrgAssuranceWorkingPaperSaveRequest r, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_working_paper_save", "@working_paper_id_out", c =>
        {
            AddParam(c, "@organization_id",       DbType.Int64,  r.OrganizationId);
            AddParam(c, "@execution_question_id", DbType.Int64,  questionId);
            AddParam(c, "@working_paper_id",      DbType.Int64,  (object?)r.WorkingPaperId ?? DBNull.Value);
            AddParam(c, "@testing_method_code",   DbType.String, (object?)r.TestingMethodCode ?? DBNull.Value, 40);
            AddParam(c, "@testing_guidance",      DbType.String, (object?)r.TestingGuidance ?? DBNull.Value, -1);
            AddParam(c, "@procedure_performed",   DbType.String, (object?)r.ProcedurePerformed ?? DBNull.Value, -1);
            AddParam(c, "@population",            DbType.String, (object?)r.Population ?? DBNull.Value, -1);
            AddParam(c, "@sampling_method",       DbType.String, (object?)r.SamplingMethod ?? DBNull.Value, 400);
            AddParam(c, "@sample_size",           DbType.Int32,  (object?)r.SampleSize ?? DBNull.Value);
            AddParam(c, "@sample_details",        DbType.String, (object?)r.SampleDetails ?? DBNull.Value, -1);
            AddParam(c, "@evidence_references",   DbType.String, (object?)r.EvidenceReferences ?? DBNull.Value, -1);
            AddParam(c, "@test_result",           DbType.String, (object?)r.TestResult ?? DBNull.Value, 20);
            AddParam(c, "@deviations",            DbType.String, (object?)r.Deviations ?? DBNull.Value, -1);
            AddParam(c, "@auditor_comments",      DbType.String, (object?)r.AuditorComments ?? DBNull.Value, -1);
            AddParam(c, "@conclusion",            DbType.String, (object?)r.Conclusion ?? DBNull.Value, -1);
            AddParam(c, "@employee_id",           DbType.Int64,  employeeId);
            AddParam(c, "@actor",                 DbType.String, actor, 100);
        }, null, cancellationToken);

    public Task<OrgAssuranceWorkpaperResult> WorkingPaperActionAsync(
        long workingPaperId, long employeeId, OrgAssuranceWorkingPaperActionRequest request, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_working_paper_action", null, c =>
        {
            AddParam(c, "@organization_id",  DbType.Int64,  request.OrganizationId);
            AddParam(c, "@working_paper_id", DbType.Int64,  workingPaperId);
            AddParam(c, "@action",           DbType.String, request.Action, 20);
            AddParam(c, "@comment",          DbType.String, (object?)request.Comment ?? DBNull.Value, -1);
            AddParam(c, "@employee_id",      DbType.Int64,  employeeId);
            AddParam(c, "@actor",            DbType.String, actor, 100);
        }, workingPaperId, cancellationToken);

    public Task<OrgAssuranceWorkpaperResult> SaveAuditConclusionAsync(
        long executionId, long employeeId, OrgAssuranceAuditConclusionRequest request, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_execution_conclusion_save", null, c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(c, "@execution_id",    DbType.Int64,  executionId);
            AddParam(c, "@conclusion",      DbType.String, (object?)request.Conclusion ?? DBNull.Value, -1);
            AddParam(c, "@employee_id",     DbType.Int64,  employeeId);
            AddParam(c, "@actor",           DbType.String, actor, 100);
        }, executionId, cancellationToken);

    public Task<OrgAssuranceWorkpaperResult> RaiseFindingAsync(
        long workingPaperId, long employeeId, OrgAssuranceRaiseFindingRequest r, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_wp_raise_finding", "@observation_id_out", c =>
        {
            AddParam(c, "@organization_id",     DbType.Int64,  r.OrganizationId);
            AddParam(c, "@working_paper_id",    DbType.Int64,  workingPaperId);
            AddParam(c, "@title",               DbType.String, r.Title, 300);
            AddParam(c, "@description",         DbType.String, (object?)r.Description ?? DBNull.Value, -1);
            AddParam(c, "@severity_code",       DbType.String, (object?)r.SeverityCode ?? "Medium", 30);
            AddParam(c, "@owner_employee_id",   DbType.Int64,  (object?)r.OwnerEmployeeId ?? DBNull.Value);
            AddParam(c, "@due_date",            DbType.Date,   (object?)r.DueDate ?? DBNull.Value);
            AddParam(c, "@audit_criteria",      DbType.String, (object?)r.AuditCriteria ?? DBNull.Value, -1);
            AddParam(c, "@condition_text",      DbType.String, (object?)r.ConditionText ?? DBNull.Value, -1);
            AddParam(c, "@root_cause",          DbType.String, (object?)r.RootCause ?? DBNull.Value, -1);
            AddParam(c, "@risk_impact",         DbType.String, (object?)r.RiskImpact ?? DBNull.Value, -1);
            AddParam(c, "@recommendation",      DbType.String, (object?)r.Recommendation ?? DBNull.Value, -1);
            AddParam(c, "@supporting_evidence", DbType.String, (object?)r.SupportingEvidence ?? DBNull.Value, -1);
            AddParam(c, "@employee_id",         DbType.Int64,  employeeId);
            AddParam(c, "@actor",               DbType.String, actor, 100);
        }, null, cancellationToken);

    public Task<OrgAssuranceWorkpaperResult> SaveObservationFindingAsync(
        long observationId, OrgAssuranceObservationFindingRequest r, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_observation_finding_save", null, c =>
        {
            AddParam(c, "@organization_id",     DbType.Int64,  r.OrganizationId);
            AddParam(c, "@observation_id",      DbType.Int64,  observationId);
            AddParam(c, "@origin_code",         DbType.String, (object?)r.OriginCode ?? DBNull.Value, 30);
            AddParam(c, "@audit_criteria",      DbType.String, (object?)r.AuditCriteria ?? DBNull.Value, -1);
            AddParam(c, "@condition_text",      DbType.String, (object?)r.ConditionText ?? DBNull.Value, -1);
            AddParam(c, "@root_cause",          DbType.String, (object?)r.RootCause ?? DBNull.Value, -1);
            AddParam(c, "@risk_impact",         DbType.String, (object?)r.RiskImpact ?? DBNull.Value, -1);
            AddParam(c, "@recommendation",      DbType.String, (object?)r.Recommendation ?? DBNull.Value, -1);
            AddParam(c, "@management_response", DbType.String, (object?)r.ManagementResponse ?? DBNull.Value, -1);
            AddParam(c, "@corrective_action",   DbType.String, (object?)r.CorrectiveAction ?? DBNull.Value, -1);
            AddParam(c, "@supporting_evidence", DbType.String, (object?)r.SupportingEvidence ?? DBNull.Value, -1);
            AddParam(c, "@actor",               DbType.String, actor, 100);
        }, observationId, cancellationToken);

    // -----------------------------------------------------------------
    // Helpers
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

    // A write: the id OUTPUT parameter when the procedure has one, else the
    // id the call was about; a THROW becomes Error + ReasonCode.
    private async Task<OrgAssuranceWorkpaperResult> WriteAsync(
        string procedure, string? idOutput, Action<DbCommand> addParams, long? id, CancellationToken cancellationToken)
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
                output.DbType        = DbType.Int64;
                output.Direction     = ParameterDirection.Output;
                command.Parameters.Add(output);
            }
            await command.ExecuteNonQueryAsync(cancellationToken);
            var outId = output?.Value is null or DBNull ? id : Convert.ToInt64(output.Value);
            return new OrgAssuranceWorkpaperResult(true, outId);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "OrgAssuranceWorkpaperService.{Procedure} SQL error {Number}: {Message}",
                procedure, ex.Number, ex.Message);
            return new OrgAssuranceWorkpaperResult(false, Error: ex.Message, ReasonCode: MapReason(ex.Number));
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

    // 567 THROW numbers (54051-54065) and the ones the procedures pass on.
    private static string MapReason(int errorNumber) => errorNumber switch
    {
        54009 => "IDS_REQUIRED",
        54010 => "EXECUTION_NOT_FOUND",
        54051 => "WP_NOT_ON_TEAM",
        54052 => "WP_EXECUTION_NOT_IN_PROGRESS",
        54053 => "WP_NOT_FOUND",
        54054 => "WP_NOT_EDITABLE",
        54055 => "WP_INCOMPLETE",
        54056 => "WP_REVIEWER_ONLY",
        54057 => "WP_REASON_REQUIRED",
        54058 => "WP_LEAD_ONLY",
        54059 => "WP_ASSIGNEE_NOT_ON_TEAM",
        54060 => "WP_PAPERS_NOT_APPROVED",
        54061 => "WP_CONCLUSION_REASON_REQUIRED",
        54062 => "WP_INVALID_VALUE",
        54063 => "WP_FINDING_NOT_ALLOWED",
        54065 => "OBSERVATION_CLOSED",
        54109 => "OBSERVATION_CODE_EXISTS",
        _     => "SQL_ERROR"
    };
}
