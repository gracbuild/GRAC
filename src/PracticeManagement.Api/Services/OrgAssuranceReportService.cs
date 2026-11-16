// =====================================================================
// OrgAssuranceReportService (568, Audit Change spec 4.9 -- reports)
//
// Audit reports over the 568 procedures: the section master, report
// templates, the engagements with their report, one report (its data as
// JSON -- live, or frozen when issued), section saves and the report
// lifecycle. Reads return the procedures' rows (EvidenceCenterService's
// ReadRowsAsync pattern, as OrgAssuranceWorkpaperService).
//
// Wire-up: Infrastructure/OrgAssuranceReportServiceRegistration.cs.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgAssuranceReportService
{
    Task<List<Dictionary<string, object?>>> ListSectionsAsync(CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> ListTemplatesAsync(long organizationId, string actor, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> GetTemplateAsync(long organizationId, long templateId, CancellationToken cancellationToken);
    Task<OrgAssuranceReportResult> SaveTemplateAsync(OrgAssuranceReportTemplateSaveRequest request, string actor, CancellationToken cancellationToken);
    Task<List<Dictionary<string, object?>>> ListReportsAsync(
        long organizationId, long? employeeId, string? status, string? search, CancellationToken cancellationToken);
    Task<OrgAssuranceReportResult> CreateReportAsync(long employeeId, OrgAssuranceReportCreateRequest request, string actor, CancellationToken cancellationToken);
    Task<Dictionary<string, object?>?> GetReportAsync(
        long organizationId, long reportId, long? employeeId, int? versionNo, CancellationToken cancellationToken);
    Task<OrgAssuranceReportResult> SaveSectionsAsync(
        long reportId, long employeeId, OrgAssuranceReportSectionsSaveRequest request, string actor, CancellationToken cancellationToken);
    Task<OrgAssuranceReportResult> ReportActionAsync(
        long reportId, long employeeId, OrgAssuranceReportActionRequest request, string actor, CancellationToken cancellationToken);
}

public sealed class OrgAssuranceReportService(
    IConfiguration configuration,
    ILogger<OrgAssuranceReportService> logger) : IOrgAssuranceReportService
{
    // -----------------------------------------------------------------
    // Reads
    // -----------------------------------------------------------------
    public Task<List<Dictionary<string, object?>>> ListSectionsAsync(CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_report_section_master_list", _ => { }, cancellationToken);

    public Task<List<Dictionary<string, object?>>> ListTemplatesAsync(long organizationId, string actor, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_report_template_list", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,  organizationId);
            AddParam(c, "@actor",           DbType.String, actor, 100);
        }, cancellationToken);

    public Task<List<Dictionary<string, object?>>> GetTemplateAsync(long organizationId, long templateId, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_report_template_get", c =>
        {
            AddParam(c, "@organization_id",    DbType.Int64, organizationId);
            AddParam(c, "@report_template_id", DbType.Int64, templateId);
        }, cancellationToken);

    public Task<List<Dictionary<string, object?>>> ListReportsAsync(
        long organizationId, long? employeeId, string? status, string? search, CancellationToken cancellationToken)
        => ReadAsync("sp_org_assurance_report_list", c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,  organizationId);
            AddParam(c, "@employee_id",     DbType.Int64,  (object?)employeeId ?? DBNull.Value);
            AddParam(c, "@status",          DbType.String, (object?)status ?? DBNull.Value, 20);
            AddParam(c, "@search",          DbType.String, (object?)search ?? DBNull.Value, 200);
        }, cancellationToken);

    public async Task<Dictionary<string, object?>?> GetReportAsync(
        long organizationId, long reportId, long? employeeId, int? versionNo, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = Proc(connection, "sp_org_assurance_report_get");
        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@report_id",       DbType.Int64, reportId);
        AddParam(command, "@employee_id",     DbType.Int64, (object?)employeeId ?? DBNull.Value);
        AddParam(command, "@version_no",      DbType.Int32, (object?)versionNo ?? DBNull.Value);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var report   = await ReadRowsAsync(reader, cancellationToken);
        var sections = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        var history  = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        var versions = await reader.NextResultAsync(cancellationToken) ? await ReadRowsAsync(reader, cancellationToken) : new List<Dictionary<string, object?>>();
        if (report.Count == 0) return null;
        return new Dictionary<string, object?>
        {
            ["report"]   = report[0],
            ["sections"] = sections,
            ["history"]  = history,
            ["versions"] = versions
        };
    }

    // -----------------------------------------------------------------
    // Writes
    // -----------------------------------------------------------------
    public Task<OrgAssuranceReportResult> SaveTemplateAsync(OrgAssuranceReportTemplateSaveRequest r, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_report_template_save", "@report_template_id_out", c =>
        {
            AddParam(c, "@organization_id",    DbType.Int64,   r.OrganizationId);
            AddParam(c, "@report_template_id", DbType.Int64,   (object?)r.ReportTemplateId ?? DBNull.Value);
            AddParam(c, "@template_name",      DbType.String,  r.TemplateName, 200);
            AddParam(c, "@description",        DbType.String,  (object?)r.Description ?? DBNull.Value, 1000);
            AddParam(c, "@is_default",         DbType.Boolean, r.IsDefault);
            AddParam(c, "@is_active",          DbType.Boolean, r.IsActive);
            // camelCase keys for the procedure's OPENJSON
            AddParam(c, "@sections_json",      DbType.String,  System.Text.Json.JsonSerializer.Serialize(
                (r.Sections ?? []).Select(s => new
                {
                    sectionCode  = s.SectionCode,
                    heading      = s.Heading,
                    displayOrder = s.DisplayOrder,
                    isIncluded   = s.IsIncluded,
                    standardText = s.StandardText
                })), -1);
            AddParam(c, "@actor",              DbType.String,  actor, 100);
        }, r.ReportTemplateId, cancellationToken);

    public Task<OrgAssuranceReportResult> CreateReportAsync(long employeeId, OrgAssuranceReportCreateRequest r, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_report_create", "@report_id_out", c =>
        {
            AddParam(c, "@organization_id",    DbType.Int64,  r.OrganizationId);
            AddParam(c, "@plan_item_id",       DbType.Int64,  r.EngagementId);
            AddParam(c, "@report_template_id", DbType.Int64,  (object?)r.ReportTemplateId ?? DBNull.Value);
            AddParam(c, "@employee_id",        DbType.Int64,  employeeId);
            AddParam(c, "@actor",              DbType.String, actor, 100);
        }, null, cancellationToken);

    public Task<OrgAssuranceReportResult> SaveSectionsAsync(
        long reportId, long employeeId, OrgAssuranceReportSectionsSaveRequest r, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_report_section_save", null, c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,  r.OrganizationId);
            AddParam(c, "@report_id",       DbType.Int64,  reportId);
            AddParam(c, "@sections_json",   DbType.String, System.Text.Json.JsonSerializer.Serialize(
                (r.Sections ?? []).Select(s => new { sectionCode = s.SectionCode, isIncluded = s.IsIncluded, narrative = s.Narrative })), -1);
            AddParam(c, "@employee_id",     DbType.Int64,  employeeId);
            AddParam(c, "@actor",           DbType.String, actor, 100);
        }, reportId, cancellationToken);

    public Task<OrgAssuranceReportResult> ReportActionAsync(
        long reportId, long employeeId, OrgAssuranceReportActionRequest r, string actor, CancellationToken cancellationToken)
        => WriteAsync("sp_org_assurance_report_action", null, c =>
        {
            AddParam(c, "@organization_id", DbType.Int64,  r.OrganizationId);
            AddParam(c, "@report_id",       DbType.Int64,  reportId);
            AddParam(c, "@action",          DbType.String, r.Action, 20);
            AddParam(c, "@comment",         DbType.String, (object?)r.Comment ?? DBNull.Value, -1);
            AddParam(c, "@employee_id",     DbType.Int64,  employeeId);
            AddParam(c, "@actor",           DbType.String, actor, 100);
        }, reportId, cancellationToken);

    // -----------------------------------------------------------------
    // Helpers (as OrgAssuranceWorkpaperService)
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

    private async Task<OrgAssuranceReportResult> WriteAsync(
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
            return new OrgAssuranceReportResult(true, outId);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "OrgAssuranceReportService.{Procedure} SQL error {Number}: {Message}",
                procedure, ex.Number, ex.Message);
            return new OrgAssuranceReportResult(false, Error: ex.Message, ReasonCode: MapReason(ex.Number));
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

    // 568 THROW numbers (54070-54079).
    private static string MapReason(int errorNumber) => errorNumber switch
    {
        54070 => "REPORT_LEAD_ONLY",
        54071 => "REPORT_REVIEWER_ONLY",
        54072 => "REPORT_STATE",
        54073 => "REPORT_NO_EXECUTION",
        54074 => "REPORT_EXISTS",
        54075 => "REPORT_NOT_FOUND",
        54076 => "REPORT_NARRATIVE_REQUIRED",
        54077 => "REPORT_EXECUTIONS_NOT_APPROVED",
        54078 => "REPORT_REASON_REQUIRED",
        54079 => "REPORT_TEMPLATE_INVALID",
        _     => "SQL_ERROR"
    };
}
