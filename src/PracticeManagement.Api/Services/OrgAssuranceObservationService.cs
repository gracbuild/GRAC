// =====================================================================
// OrgAssuranceObservationService
//
// Phase 2 Assurance Management -- Stage 4 Observation Management.
//
// Thin wrapper over the sp_org_assurance_observation_* stored
// procedures (migration 102). Mirrors OrgAssuranceExecutionService /
// OrgAssurancePlanService conventions.
//
// Wire-up: Infrastructure/OrgAssuranceObservationServiceRegistration.cs.
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IOrgAssuranceObservationService
{
    Task<IReadOnlyList<OrgAssuranceObservationSeverityRow>> ListSeveritiesAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceObservationStatusRow>>   ListStatusesAsync  (CancellationToken cancellationToken);
    Task<IReadOnlyList<OrgAssuranceObservationTypeRow>>     ListTypesAsync     (CancellationToken cancellationToken);

    // Header
    Task<OrgAssuranceObservationListResult> ListAsync(
        OrgAssuranceObservationListQuery query, CancellationToken cancellationToken);
    Task<OrgAssuranceObservationDetail?> GetAsync(
        long organizationId, long observationId, CancellationToken cancellationToken);
    Task<OrgAssuranceObservationSaveResult> SaveAsync(
        OrgAssuranceObservationSaveRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceObservationCommandResult> DeleteAsync(
        OrgAssuranceObservationCommandRequest request, CancellationToken cancellationToken);

    // Lifecycle
    Task<OrgAssuranceObservationCommandResult> SubmitReviewAsync(
        OrgAssuranceObservationCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceObservationCommandResult> AcceptAsync(
        OrgAssuranceObservationCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceObservationCommandResult> RejectAsync(
        OrgAssuranceObservationCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceObservationCommandResult> ResolveAsync(
        OrgAssuranceObservationCommandRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceObservationCommandResult> CloseAsync(
        OrgAssuranceObservationCommandRequest request, CancellationToken cancellationToken);

    // Evidence
    Task<IReadOnlyList<OrgAssuranceObservationEvidenceRow>> ListEvidenceAsync(
        long organizationId, long observationId, CancellationToken cancellationToken);
    Task<OrgAssuranceObservationEvidenceSaveResult> SaveEvidenceAsync(
        OrgAssuranceObservationEvidenceSaveRequest request, CancellationToken cancellationToken);
    Task<OrgAssuranceObservationCommandResult> DeleteEvidenceAsync(
        long organizationId, long observationId, long evidenceId, string? actor, CancellationToken cancellationToken);

    // History
    Task<IReadOnlyList<OrgAssuranceObservationHistoryRow>> ListHistoryAsync(
        long organizationId, long observationId, CancellationToken cancellationToken);
}

public sealed class OrgAssuranceObservationService(
    IConfiguration configuration,
    ILogger<OrgAssuranceObservationService> logger) : IOrgAssuranceObservationService
{
    // ------------------------------------------------------------
    // Lookups
    // ------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceObservationSeverityRow>> ListSeveritiesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_observation_severity_list";

        var rows = new List<OrgAssuranceObservationSeverityRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceObservationSeverityRow(
                Convert.ToInt32(reader["SeverityId"]),
                reader["SeverityCode"]?.ToString() ?? "",
                reader["SeverityName"]?.ToString() ?? "",
                Convert.ToInt32(reader["DisplayOrder"]),
                ReadStringOrNull(reader, "ColorHex")));
        }
        return rows;
    }

    public async Task<IReadOnlyList<OrgAssuranceObservationStatusRow>> ListStatusesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_observation_status_list";

        var rows = new List<OrgAssuranceObservationStatusRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceObservationStatusRow(
                Convert.ToInt32(reader["StatusId"]),
                reader["StatusCode"]?.ToString() ?? "",
                reader["StatusName"]?.ToString() ?? "",
                Convert.ToInt32(reader["DisplayOrder"]),
                Convert.ToBoolean(reader["IsTerminal"])));
        }
        return rows;
    }

    public async Task<IReadOnlyList<OrgAssuranceObservationTypeRow>> ListTypesAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_observation_type_list";

        var rows = new List<OrgAssuranceObservationTypeRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceObservationTypeRow(
                reader["TypeCode"]?.ToString() ?? "",
                reader["TypeName"]?.ToString() ?? "",
                Convert.ToInt32(reader["DisplayOrder"])));
        }
        return rows;
    }

    // ------------------------------------------------------------
    // List / Get
    // ------------------------------------------------------------
    public async Task<OrgAssuranceObservationListResult> ListAsync(
        OrgAssuranceObservationListQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_observation_list";

        AddParam(command, "@organization_id",  DbType.Int64,  query.OrganizationId);
        AddParam(command, "@execution_id",     DbType.Int64,  (object?)query.ExecutionId  ?? DBNull.Value);
        AddParam(command, "@entity_id",        DbType.Int64,  (object?)query.EntityId     ?? DBNull.Value);
        AddParam(command, "@status_code",      DbType.String, (object?)query.StatusCode        ?? DBNull.Value, 60);
        AddParam(command, "@severity_code",    DbType.String, (object?)query.SeverityCode      ?? DBNull.Value, 30);
        AddParam(command, "@observation_type", DbType.String, (object?)query.ObservationType   ?? DBNull.Value, 30);
        AddParam(command, "@search",           DbType.String, (object?)query.Search            ?? DBNull.Value, 200);
        AddParam(command, "@page",             DbType.Int32,  Math.Max(1, query.Page));
        AddParam(command, "@page_size",        DbType.Int32,  Math.Clamp(query.PageSize, 1, 200));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);

        long total = 0;
        int  page  = query.Page;
        int  size  = query.PageSize;
        if (await reader.ReadAsync(cancellationToken))
        {
            total = Convert.ToInt64(reader["TotalCount"]);
            page  = Convert.ToInt32(reader["PageNumber"]);
            size  = Convert.ToInt32(reader["PageSize"]);
        }

        var rows = new List<OrgAssuranceObservationListRow>();
        if (await reader.NextResultAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
                rows.Add(MapListRow(reader));
        }
        return new OrgAssuranceObservationListResult(total, page, size, rows);
    }

    public async Task<OrgAssuranceObservationDetail?> GetAsync(
        long organizationId, long observationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_observation_get";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@observation_id",  DbType.Int64, observationId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? MapDetailRow(reader) : null;
    }

    // ------------------------------------------------------------
    // Save + Delete
    // ------------------------------------------------------------
    public async Task<OrgAssuranceObservationSaveResult> SaveAsync(
        OrgAssuranceObservationSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.ObservationTitle))
            return new OrgAssuranceObservationSaveResult(false, Error: "ObservationTitle is required.");
        if (request.ExecutionId <= 0)
            return new OrgAssuranceObservationSaveResult(false, Error: "ExecutionId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_observation_save";

            AddParam(command, "@organization_id",                DbType.Int64,  request.OrganizationId);
            AddParam(command, "@observation_id",                 DbType.Int64,  (object?)request.ObservationId ?? DBNull.Value);
            AddParam(command, "@execution_id",                   DbType.Int64,  request.ExecutionId);
            AddParam(command, "@execution_entity_id",            DbType.Int64,  (object?)request.ExecutionEntityId ?? DBNull.Value);
            AddParam(command, "@observation_code",               DbType.String, (object?)request.ObservationCode ?? DBNull.Value, 120);
            AddParam(command, "@observation_title",              DbType.String, request.ObservationTitle.Trim(), 300);
            AddParam(command, "@observation_description",        DbType.String, (object?)request.ObservationDescription ?? DBNull.Value, -1);
            AddParam(command, "@observation_type",               DbType.String, (object?)request.ObservationType ?? (object)"Finding", 30);
            AddParam(command, "@severity_code",                  DbType.String, (object?)request.SeverityCode ?? (object)"Medium", 30);
            AddParam(command, "@source_question_code",           DbType.String, (object?)request.SourceQuestionCode ?? DBNull.Value, 120);
            AddParam(command, "@source_question_text",           DbType.String, (object?)request.SourceQuestionText ?? DBNull.Value, -1);
            AddParam(command, "@assigned_owner_employee_id",     DbType.Int64,  (object?)request.AssignedOwnerEmployeeId ?? DBNull.Value);
            AddParam(command, "@assigned_owner_display_name",    DbType.String, (object?)request.AssignedOwnerDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@assigned_reviewer_employee_id",  DbType.Int64,  (object?)request.AssignedReviewerEmployeeId ?? DBNull.Value);
            AddParam(command, "@assigned_reviewer_display_name", DbType.String, (object?)request.AssignedReviewerDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@reported_by_employee_id",        DbType.Int64,  (object?)request.ReportedByEmployeeId ?? DBNull.Value);
            AddParam(command, "@reported_by_display_name",       DbType.String, (object?)request.ReportedByDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@observed_dt",                    DbType.DateTime2, (object?)request.ObservedDt ?? DBNull.Value);
            AddParam(command, "@due_date",                       DbType.Date,      (object?)request.DueDate ?? DBNull.Value);
            // 116a hybrid role+employee
            AddParam(command, "@assigned_owner_role_id",         DbType.Int64,  (object?)request.AssignedOwnerRoleId ?? DBNull.Value);
            AddParam(command, "@assigned_owner_role_name",       DbType.String, (object?)request.AssignedOwnerRoleName ?? DBNull.Value, 120);
            AddParam(command, "@assigned_reviewer_role_id",      DbType.Int64,  (object?)request.AssignedReviewerRoleId ?? DBNull.Value);
            AddParam(command, "@assigned_reviewer_role_name",    DbType.String, (object?)request.AssignedReviewerRoleName ?? DBNull.Value, 120);
            AddParam(command, "@actor",                          DbType.String, (object?)request.Actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@observation_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);
            return new OrgAssuranceObservationSaveResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceObservationService.SaveAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceObservationSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public Task<OrgAssuranceObservationCommandResult> DeleteAsync      (OrgAssuranceObservationCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_observation_delete",         r, ct, includeNotes: false);
    public Task<OrgAssuranceObservationCommandResult> SubmitReviewAsync(OrgAssuranceObservationCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_observation_submit_review",  r, ct, includeNotes: true);
    public Task<OrgAssuranceObservationCommandResult> AcceptAsync      (OrgAssuranceObservationCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_observation_accept",         r, ct, includeNotes: true);
    public Task<OrgAssuranceObservationCommandResult> RejectAsync      (OrgAssuranceObservationCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_observation_reject",         r, ct, includeNotes: true);
    public Task<OrgAssuranceObservationCommandResult> ResolveAsync     (OrgAssuranceObservationCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_observation_resolve",        r, ct, includeNotes: true);
    public Task<OrgAssuranceObservationCommandResult> CloseAsync       (OrgAssuranceObservationCommandRequest r, CancellationToken ct) => TransitionAsync("grac_practice.sp_org_assurance_observation_close",          r, ct, includeNotes: true);

    private async Task<OrgAssuranceObservationCommandResult> TransitionAsync(
        string procName, OrgAssuranceObservationCommandRequest request,
        CancellationToken cancellationToken, bool includeNotes)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.ObservationId <= 0)
            return new OrgAssuranceObservationCommandResult(false, Error: "ObservationId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = procName;

            AddParam(command, "@organization_id", DbType.Int64,  request.OrganizationId);
            AddParam(command, "@observation_id",  DbType.Int64,  request.ObservationId);
            if (includeNotes)
                AddParam(command, "@notes", DbType.String, (object?)request.Notes ?? DBNull.Value, -1);
            AddParam(command, "@actor", DbType.String, (object?)request.Actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssuranceObservationCommandResult(true, request.ObservationId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceObservationService.{Proc} SQL error {Number}: {Message}",
                procName, ex.Number, ex.Message);
            return new OrgAssuranceObservationCommandResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // ------------------------------------------------------------
    // Evidence
    // ------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceObservationEvidenceRow>> ListEvidenceAsync(
        long organizationId, long observationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_observation_evidence_list";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@observation_id",  DbType.Int64, observationId);

        var rows = new List<OrgAssuranceObservationEvidenceRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            rows.Add(MapEvidenceRow(reader));
        return rows;
    }

    public async Task<OrgAssuranceObservationEvidenceSaveResult> SaveEvidenceAsync(
        OrgAssuranceObservationEvidenceSaveRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.ObservationId <= 0)
            return new OrgAssuranceObservationEvidenceSaveResult(false, Error: "ObservationId is required.");

        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_observation_evidence_save";

            AddParam(command, "@organization_id",           DbType.Int64,  request.OrganizationId);
            AddParam(command, "@observation_id",            DbType.Int64,  request.ObservationId);
            AddParam(command, "@evidence_id",               DbType.Int64,  (object?)request.EvidenceId ?? DBNull.Value);
            AddParam(command, "@evidence_config_id",        DbType.Int64,  (object?)request.EvidenceConfigId ?? DBNull.Value);
            AddParam(command, "@evidence_type_code",        DbType.String, (object?)request.EvidenceTypeCode ?? DBNull.Value, 60);
            AddParam(command, "@evidence_type_name",        DbType.String, (object?)request.EvidenceTypeName ?? DBNull.Value, 200);
            AddParam(command, "@evidence_label",            DbType.String, (object?)request.EvidenceLabel ?? DBNull.Value, 240);
            AddParam(command, "@file_id",                   DbType.Int64,  (object?)request.FileId ?? DBNull.Value);
            AddParam(command, "@storage_location",          DbType.String, (object?)request.StorageLocation ?? DBNull.Value, 120);
            AddParam(command, "@storage_locator",           DbType.String, (object?)request.StorageLocator ?? DBNull.Value, 1000);
            AddParam(command, "@original_file_name",        DbType.String, (object?)request.OriginalFileName ?? DBNull.Value, 400);
            AddParam(command, "@file_size_bytes",           DbType.Int64,  (object?)request.FileSizeBytes ?? DBNull.Value);
            AddParam(command, "@mime_type",                 DbType.String, (object?)request.MimeType ?? DBNull.Value, 200);
            AddParam(command, "@collected_by_employee_id",  DbType.Int64,  (object?)request.CollectedByEmployeeId ?? DBNull.Value);
            AddParam(command, "@collected_by_display_name", DbType.String, (object?)request.CollectedByDisplayName ?? DBNull.Value, 240);
            AddParam(command, "@collected_dt",              DbType.DateTime2, (object?)request.CollectedDt ?? DBNull.Value);
            AddParam(command, "@notes",                     DbType.String, (object?)request.Notes ?? DBNull.Value, -1);
            AddParam(command, "@actor",                     DbType.String, (object?)request.Actor ?? (object)"system", 100);

            var idOut = command.CreateParameter();
            idOut.ParameterName = "@evidence_id_out";
            idOut.DbType        = DbType.Int64;
            idOut.Direction     = ParameterDirection.Output;
            command.Parameters.Add(idOut);

            await command.ExecuteNonQueryAsync(cancellationToken);
            var id = idOut.Value is long l ? l : Convert.ToInt64(idOut.Value);
            return new OrgAssuranceObservationEvidenceSaveResult(true, id);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceObservationService.SaveEvidenceAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceObservationEvidenceSaveResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    public async Task<OrgAssuranceObservationCommandResult> DeleteEvidenceAsync(
        long organizationId, long observationId, long evidenceId, string? actor, CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command    = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
            command.CommandText = "grac_practice.sp_org_assurance_observation_evidence_delete";

            AddParam(command, "@organization_id", DbType.Int64,  organizationId);
            AddParam(command, "@observation_id",  DbType.Int64,  observationId);
            AddParam(command, "@evidence_id",     DbType.Int64,  evidenceId);
            AddParam(command, "@actor",           DbType.String, (object?)actor ?? (object)"system", 100);

            await command.ExecuteNonQueryAsync(cancellationToken);
            return new OrgAssuranceObservationCommandResult(true, evidenceId);
        }
        catch (SqlException ex)
        {
            var reason = MapReason(ex.Number);
            logger.LogWarning(ex, "OrgAssuranceObservationService.DeleteEvidenceAsync SQL error {Number}: {Message}",
                ex.Number, ex.Message);
            return new OrgAssuranceObservationCommandResult(false, Error: ex.Message, ReasonCode: reason);
        }
    }

    // ------------------------------------------------------------
    // History
    // ------------------------------------------------------------
    public async Task<IReadOnlyList<OrgAssuranceObservationHistoryRow>> ListHistoryAsync(
        long organizationId, long observationId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command    = connection.CreateCommand();
        command.CommandType = CommandType.StoredProcedure;
        command.CommandText = "grac_practice.sp_org_assurance_observation_history_list";

        AddParam(command, "@organization_id", DbType.Int64, organizationId);
        AddParam(command, "@observation_id",  DbType.Int64, observationId);

        var rows = new List<OrgAssuranceObservationHistoryRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            rows.Add(new OrgAssuranceObservationHistoryRow(
                Convert.ToInt64(reader["HistoryId"]),
                reader["ActionCode"]?.ToString() ?? "",
                ReadIntOrNull(reader,   "FromStatusId"),
                ReadStringOrNull(reader,"FromStatusCode"),
                ReadStringOrNull(reader,"FromStatusName"),
                ReadIntOrNull(reader,   "ToStatusId"),
                ReadStringOrNull(reader,"ToStatusCode"),
                ReadStringOrNull(reader,"ToStatusName"),
                ReadStringOrNull(reader,"ReasonText"),
                ReadStringOrNull(reader,"ActorDisplayName"),
                ReadStringOrNull(reader,"EnteredBy"),
                ReadDateTimeOrNull(reader,"EnteredDt")));
        }
        return rows;
    }

    // ------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------
    private async Task<DbConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connString = Infrastructure.SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");
        var connection = new SqlConnection(connString);
        await connection.OpenAsync(cancellationToken);
        return connection;
    }

    private static void AddParam(DbCommand command, string name, DbType type, object? value, int? size = null)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType        = type;
        if (size.HasValue) p.Size = size.Value;
        p.Value = value ?? DBNull.Value;
        command.Parameters.Add(p);
    }

    private static long?    ReadLongOrNull(DbDataReader r, string col)     => r[col] == DBNull.Value ? null : Convert.ToInt64(r[col]);
    private static int?     ReadIntOrNull(DbDataReader r, string col)      => r[col] == DBNull.Value ? null : Convert.ToInt32(r[col]);
    private static DateTime? ReadDateTimeOrNull(DbDataReader r, string col)=> r[col] == DBNull.Value ? null : Convert.ToDateTime(r[col]);
    private static string?  ReadStringOrNull(DbDataReader r, string col)   => r[col] == DBNull.Value ? null : r[col].ToString();

    private static OrgAssuranceObservationListRow MapListRow(DbDataReader r) => new(
        Convert.ToInt64(r["ObservationId"]),
        Convert.ToInt64(r["OrganizationId"]),
        Convert.ToInt64(r["ExecutionId"]),
        ReadLongOrNull(r,   "EntityId"),
        ReadStringOrNull(r, "ExecutionCode"),
        ReadStringOrNull(r, "ExecutionName"),
        ReadStringOrNull(r, "EntityDimensionCode"),
        ReadStringOrNull(r, "EntityDimensionName"),
        ReadStringOrNull(r, "EntityCode"),
        ReadStringOrNull(r, "EntityName"),
        r["ObservationCode"]?.ToString() ?? "",
        r["ObservationTitle"]?.ToString() ?? "",
        r["ObservationType"]?.ToString() ?? "",
        r["SeverityCode"]?.ToString() ?? "",
        ReadStringOrNull(r, "SeverityName"),
        r["StatusCode"]?.ToString() ?? "",
        r["StatusName"]?.ToString() ?? "",
        Convert.ToBoolean(r["StatusIsTerminal"]),
        ReadStringOrNull(r, "OwnerDisplayName"),
        ReadLongOrNull(r,   "OwnerRoleId"),
        ReadStringOrNull(r, "OwnerRoleName"),
        ReadStringOrNull(r, "ReviewerDisplayName"),
        ReadLongOrNull(r,   "ReviewerRoleId"),
        ReadStringOrNull(r, "ReviewerRoleName"),
        ReadDateTimeOrNull(r, "ObservedDt"),
        ReadDateTimeOrNull(r, "DueDate"),
        ReadLongOrNull(r,   "GapId"),
        Convert.ToInt64(r["EvidenceCount"]),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadDateTimeOrNull(r, "UpdatedDt"));

    private static OrgAssuranceObservationDetail MapDetailRow(DbDataReader r) => new(
        Convert.ToInt64(r["ObservationId"]),
        Convert.ToInt64(r["OrganizationId"]),
        Convert.ToInt64(r["ExecutionId"]),
        ReadLongOrNull(r,   "EntityId"),
        ReadStringOrNull(r, "ExecutionCode"),
        ReadStringOrNull(r, "ExecutionName"),
        ReadStringOrNull(r, "EntityDimensionCode"),
        ReadStringOrNull(r, "EntityDimensionName"),
        ReadStringOrNull(r, "EntityCode"),
        ReadStringOrNull(r, "EntityName"),
        r["ObservationCode"]?.ToString() ?? "",
        r["ObservationTitle"]?.ToString() ?? "",
        ReadStringOrNull(r, "ObservationDescription"),
        r["ObservationType"]?.ToString() ?? "",
        Convert.ToInt32(r["SeverityId"]),
        r["SeverityCode"]?.ToString() ?? "",
        ReadStringOrNull(r, "SeverityName"),
        r["StatusCode"]?.ToString() ?? "",
        r["StatusName"]?.ToString() ?? "",
        Convert.ToBoolean(r["StatusIsTerminal"]),
        ReadStringOrNull(r, "SourceQuestionCode"),
        ReadStringOrNull(r, "SourceQuestionText"),
        ReadStringOrNull(r, "SourceQuestionSnapshotJson"),
        ReadLongOrNull(r,   "ReportedByEmployeeId"),
        ReadStringOrNull(r, "ReportedByDisplayName"),
        ReadLongOrNull(r,   "OwnerEmployeeId"),
        ReadStringOrNull(r, "OwnerDisplayName"),
        ReadLongOrNull(r,   "OwnerRoleId"),
        ReadStringOrNull(r, "OwnerRoleName"),
        ReadLongOrNull(r,   "ReviewerEmployeeId"),
        ReadStringOrNull(r, "ReviewerDisplayName"),
        ReadLongOrNull(r,   "ReviewerRoleId"),
        ReadStringOrNull(r, "ReviewerRoleName"),
        ReadDateTimeOrNull(r, "ObservedDt"),
        ReadDateTimeOrNull(r, "DueDate"),
        ReadDateTimeOrNull(r, "AcceptedDt"),
        ReadDateTimeOrNull(r, "RejectedDt"),
        ReadDateTimeOrNull(r, "ResolvedDt"),
        ReadDateTimeOrNull(r, "ClosedDt"),
        ReadLongOrNull(r,   "GapId"),
        ReadStringOrNull(r, "ResolutionNotes"),
        ReadStringOrNull(r, "RejectionReason"),
        ReadStringOrNull(r, "EnteredBy"),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),
        ReadDateTimeOrNull(r, "UpdatedDt"));

    private static OrgAssuranceObservationEvidenceRow MapEvidenceRow(DbDataReader r) => new(
        Convert.ToInt64(r["EvidenceId"]),
        Convert.ToInt64(r["ObservationId"]),
        ReadLongOrNull(r,   "EvidenceConfigId"),
        ReadStringOrNull(r, "EvidenceTypeCode"),
        ReadStringOrNull(r, "EvidenceTypeName"),
        ReadStringOrNull(r, "EvidenceLabel"),
        ReadLongOrNull(r,   "FileId"),
        ReadStringOrNull(r, "StorageLocation"),
        ReadStringOrNull(r, "StorageLocator"),
        ReadStringOrNull(r, "OriginalFileName"),
        ReadLongOrNull(r,   "FileSizeBytes"),
        ReadStringOrNull(r, "MimeType"),
        ReadLongOrNull(r,   "CollectedByEmployeeId"),
        ReadStringOrNull(r, "CollectedByDisplayName"),
        ReadDateTimeOrNull(r, "CollectedDt"),
        ReadStringOrNull(r, "Notes"),
        ReadStringOrNull(r, "EnteredBy"),
        ReadDateTimeOrNull(r, "EnteredDt"),
        ReadStringOrNull(r, "UpdatedBy"),
        ReadDateTimeOrNull(r, "UpdatedDt"));

    // THROW numbers used in 102 (54100-54199).
    private static string MapReason(int errorNumber) => errorNumber switch
    {
        54100 => "ORGANIZATION_ID_REQUIRED",
        54101 => "IDS_REQUIRED",
        54102 => "EXECUTION_ID_REQUIRED",
        54103 => "TITLE_REQUIRED",
        54104 => "INVALID_TYPE",
        54105 => "EXECUTION_NOT_FOUND",
        54106 => "EXECUTION_WRONG_ORGANIZATION",
        54107 => "ENTITY_NOT_FOUND",
        54108 => "INVALID_SEVERITY",
        54109 => "DUPLICATE_OBSERVATION_CODE",
        54110 => "OBSERVATION_NOT_FOUND",
        54111 => "WRONG_ORGANIZATION",
        54112 => "NOT_EDITABLE_IN_STATUS",
        54113 => "DELETE_NOT_ALLOWED_IN_STATUS",
        54114 => "STATUS_LOOKUP_FAILED",
        54115 => "ILLEGAL_TRANSITION",
        54116 => "EVIDENCE_NOT_ALLOWED_IN_STATUS",
        54117 => "EVIDENCE_NOT_FOUND",
        54118 => "EVIDENCE_OBSERVATION_MISMATCH",
        _     => "SQL_ERROR"
    };
}
