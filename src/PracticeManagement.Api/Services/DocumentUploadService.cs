// =====================================================================
// DocumentUploadService  (charter §5)
//
// Thin facade over grac_practice.sp_document_* procedures.
// New file per charter §5 non-negotiable -- do not extend
// PracticeRepositoryService.cs or any other module's service.
//
// Wire-up: Api/Infrastructure/DocumentUploadServiceRegistration.cs
// The reviewer adds ONE line to Program.cs (pending charter §5 approval):
//     builder.Services.AddPracticeDocumentUploadService();
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IDocumentUploadService
{
    // Lookups
    Task<IReadOnlyList<DocumentTypeRow>>              ListTypesAsync(bool includeAll, CancellationToken ct);
    Task<IReadOnlyList<DocumentStageRow>>             ListStagesAsync(bool includeAll, CancellationToken ct);
    Task<IReadOnlyList<DocumentStatusRow>>            ListStatusesAsync(bool includeAll, CancellationToken ct);
    Task<IReadOnlyList<DocumentSourceTypeRow>>        ListSourceTypesAsync(bool includeAll, CancellationToken ct);
    Task<IReadOnlyList<DocumentDistributionTypeRow>>  ListDistributionTypesAsync(CancellationToken ct);
    Task<IReadOnlyList<OrganizationDepartmentRow>>    ListDepartmentsAsync(long organizationId, bool includeAll, CancellationToken ct);
    Task<IReadOnlyList<OrganizationEmployeeRow>>      ListEmployeesAsync(long organizationId, string? departmentIds, bool includeAll, CancellationToken ct);

    // Register
    Task<DocumentRegisterResult>                      ListRegisterAsync(DocumentRegisterQuery query, CancellationToken ct);
    Task<DocumentDetail?>                             GetDetailsAsync(long documentId, CancellationToken ct);
    Task<IReadOnlyList<OrganizationDepartmentRow>>    GetDistributionDepartmentsAsync(long documentId, CancellationToken ct);
    Task<IReadOnlyList<OrganizationEmployeeRow>>      GetDistributionEmployeesAsync(long documentId, CancellationToken ct);
    Task<DocumentFilePayload?>                        GetFileAsync(long documentId, CancellationToken ct);

    // Writes
    Task<DocumentSaveResult>                          SaveAsync(string mode, DocumentUploadSaveForm form, CancellationToken ct);
    Task<DocumentSaveResult>                          ToggleStatusAsync(long documentId, long organizationId, DocumentStatusToggleRequest request, CancellationToken ct);
    Task<DocumentWorkflowResult>                      TransitionAsync(long documentId, DocumentWorkflowRequest request, CancellationToken ct);
}

public sealed class DocumentUploadService(IConfiguration configuration, ILogger<DocumentUploadService> logger) : IDocumentUploadService
{
    // ================================================================
    // Lookups
    // ================================================================

    public async Task<IReadOnlyList<DocumentTypeRow>> ListTypesAsync(bool includeAll, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_type_list");
        AddParam(cmd, "@include_all", DbType.Boolean, includeAll);
        var rows = new List<DocumentTypeRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new DocumentTypeRow(
                Convert.ToInt32(r["DocumentTypeId"]),
                r["DocumentType"]?.ToString() ?? "",
                r["TypeCode"]?.ToString() ?? "",
                Convert.ToInt32(r["SortOrder"])));
        return rows;
    }

    public async Task<IReadOnlyList<DocumentStageRow>> ListStagesAsync(bool includeAll, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_stage_list");
        AddParam(cmd, "@include_all", DbType.Boolean, includeAll);
        var rows = new List<DocumentStageRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new DocumentStageRow(
                Convert.ToInt32(r["DocumentStageId"]),
                r["DocumentStage"]?.ToString() ?? "",
                r["StageCode"]?.ToString() ?? "",
                Convert.ToInt32(r["SortOrder"])));
        return rows;
    }

    public async Task<IReadOnlyList<DocumentStatusRow>> ListStatusesAsync(bool includeAll, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_status_list");
        AddParam(cmd, "@include_all", DbType.Boolean, includeAll);
        var rows = new List<DocumentStatusRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new DocumentStatusRow(
                Convert.ToInt32(r["DocumentStatusId"]),
                r["DocumentStatus"]?.ToString() ?? "",
                r["StatusCode"]?.ToString() ?? "",
                Convert.ToInt32(r["SortOrder"])));
        return rows;
    }

    public async Task<IReadOnlyList<DocumentSourceTypeRow>> ListSourceTypesAsync(bool includeAll, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_source_type_list");
        AddParam(cmd, "@include_all", DbType.Boolean, includeAll);
        var rows = new List<DocumentSourceTypeRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new DocumentSourceTypeRow(
                Convert.ToInt32(r["SourceTypeId"]),
                r["SourceType"]?.ToString() ?? "",
                r["SourceCode"]?.ToString() ?? "",
                Convert.ToInt32(r["SortOrder"])));
        return rows;
    }

    public async Task<IReadOnlyList<DocumentDistributionTypeRow>> ListDistributionTypesAsync(CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_distribution_type_list");
        var rows = new List<DocumentDistributionTypeRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new DocumentDistributionTypeRow(
                Convert.ToInt32(r["DistributionTypeId"]),
                r["DistributionType"]?.ToString() ?? "",
                r["DistributionCode"]?.ToString() ?? "",
                Convert.ToInt32(r["SortOrder"])));
        return rows;
    }

    public async Task<IReadOnlyList<OrganizationDepartmentRow>> ListDepartmentsAsync(long organizationId, bool includeAll, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_organization_department_list");
        AddParam(cmd, "@organization_id", DbType.Int64,   organizationId);
        AddParam(cmd, "@include_all",     DbType.Boolean, includeAll);
        var rows = new List<OrganizationDepartmentRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new OrganizationDepartmentRow(
                Convert.ToInt64(r["DepartmentId"]),
                r["DepartmentName"]?.ToString() ?? ""));
        return rows;
    }

    public async Task<IReadOnlyList<OrganizationEmployeeRow>> ListEmployeesAsync(long organizationId, string? departmentIds, bool includeAll, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_organization_employee_by_department");
        AddParam(cmd, "@organization_id", DbType.Int64,   organizationId);
        AddParam(cmd, "@department_ids",  DbType.String,  (object?)departmentIds ?? DBNull.Value, -1);
        AddParam(cmd, "@include_all",     DbType.Boolean, includeAll);
        var rows = new List<OrganizationEmployeeRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new OrganizationEmployeeRow(
                Convert.ToInt64(r["EmployeeId"]),
                r["EmployeeName"]?.ToString() ?? "",
                r["EmployeeCode"] as string,
                r["Email"] as string));
        return rows;
    }

    // ================================================================
    // Register
    // ================================================================

    public async Task<DocumentRegisterResult> ListRegisterAsync(DocumentRegisterQuery query, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(query);

        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_register_list");
        AddParam(cmd, "@organization_id",  DbType.Int64,  query.OrganizationId);
        AddParam(cmd, "@document_type_id", DbType.Int32,  query.DocumentTypeId ?? -1);
        AddParam(cmd, "@stage_id",         DbType.Int32,  query.StageId ?? -1);
        AddParam(cmd, "@status_id",        DbType.Int32,  query.StatusId ?? -1);
        AddParam(cmd, "@search",           DbType.String, (object?)query.Search ?? DBNull.Value, 300);
        AddParam(cmd, "@page_number",      DbType.Int32,  Math.Max(1, query.Page));
        AddParam(cmd, "@page_size",        DbType.Int32,  Math.Clamp(query.PageSize <= 0 ? 25 : query.PageSize, 1, 200));

        var rows  = new List<DocumentRegisterRow>();
        long total = 0;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new DocumentRegisterRow(
                Convert.ToInt64(r["DocumentId"]),
                r["DocumentCode"]?.ToString() ?? "",
                r["CompanyDocumentCode"] as string,
                r["DocumentName"]?.ToString() ?? "",
                Convert.ToInt32(r["DocumentTypeId"]),
                r["DocumentType"]?.ToString() ?? "",
                r["VersionNumber"]?.ToString() ?? "",
                r["NextReviewDate"] as DateTime?,
                Convert.ToInt32(r["StageId"]),
                r["DocumentStage"]?.ToString() ?? "",
                Convert.ToInt32(r["StatusId"]),
                r["DocumentStatus"]?.ToString() ?? "",
                Convert.ToDateTime(r["LastActivityDt"])));
            total = Convert.ToInt64(r["TotalRows"]);
        }
        return new DocumentRegisterResult(total, query.Page, query.PageSize, rows);
    }

    public async Task<DocumentDetail?> GetDetailsAsync(long documentId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_details_get");
        AddParam(cmd, "@document_id", DbType.Int64, documentId);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;

        return new DocumentDetail(
            Convert.ToInt64(r["DocumentId"]),
            Convert.ToInt64(r["OrganizationId"]),
            r["OrganizationName"]?.ToString() ?? "",
            r["DocumentCode"]?.ToString() ?? "",
            r["CompanyDocumentCode"] as string,
            r["DocumentName"]?.ToString() ?? "",
            Convert.ToInt32(r["DocumentTypeId"]),
            r["DocumentType"]?.ToString() ?? "",
            r["SourceTypeId"] as int?,
            r["SourceType"] as string,
            r["VersionNumber"]?.ToString() ?? "",
            r["EffectiveDate"] as DateTime?,
            r["NextReviewDate"] as DateTime?,
            Convert.ToBoolean(r["AcknowledgementRequired"]),
            Convert.ToInt32(r["StageId"]),
            r["DocumentStage"]?.ToString() ?? "",
            Convert.ToInt32(r["StatusId"]),
            r["DocumentStatus"]?.ToString() ?? "",
            r["ChangeSummary"] as string,
            r["KeywordsTag"] as string,
            r["OwnerId"] as long?,
            r["OwnerName"] as string,
            r["ReviewerId"] as long?,
            r["ReviewerName"] as string,
            r["ApproverId"] as long?,
            r["ApproverName"] as string,
            r["DistributionTypeId"] as int?,
            r["DistributionType"] as string,
            r["ReviewedById"] as long?,
            r["ReviewedByName"] as string,
            r["ReviewedOn"] as DateTime?,
            r["ReviewRemark"] as string,
            r["ApprovedById"] as long?,
            r["ApprovedByName"] as string,
            r["ApprovedOn"] as DateTime?,
            r["ApprovedRemark"] as string,
            r["CreatedBy"]?.ToString() ?? "",
            Convert.ToDateTime(r["CreatedOn"]),
            r["UpdatedBy"] as string,
            r["UpdatedOn"] as DateTime?);
    }

    public async Task<IReadOnlyList<OrganizationDepartmentRow>> GetDistributionDepartmentsAsync(long documentId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_distribution_department_list");
        AddParam(cmd, "@document_id", DbType.Int64, documentId);
        var rows = new List<OrganizationDepartmentRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new OrganizationDepartmentRow(
                Convert.ToInt64(r["DepartmentId"]),
                r["DepartmentName"]?.ToString() ?? ""));
        return rows;
    }

    public async Task<IReadOnlyList<OrganizationEmployeeRow>> GetDistributionEmployeesAsync(long documentId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_distribution_employee_list");
        AddParam(cmd, "@document_id", DbType.Int64, documentId);
        var rows = new List<OrganizationEmployeeRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new OrganizationEmployeeRow(
                Convert.ToInt64(r["EmployeeId"]),
                r["EmployeeName"]?.ToString() ?? "",
                r["EmployeeCode"] as string,
                r["Email"] as string));
        return rows;
    }

    public async Task<DocumentFilePayload?> GetFileAsync(long documentId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_file_get");
        AddParam(cmd, "@document_id",      DbType.Int64, documentId);
        AddParam(cmd, "@document_file_id", DbType.Int64, DBNull.Value);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;

        return new DocumentFilePayload(
            Convert.ToInt64(r["DocumentFileId"]),
            Convert.ToInt64(r["DocumentId"]),
            r["VersionNumber"]?.ToString() ?? "",
            r["FileName"]?.ToString() ?? "",
            r["ContentType"] as string,
            Convert.ToInt64(r["FileSizeBytes"]),
            (byte[])r["FileData"],
            Convert.ToDateTime(r["UploadedOn"]));
    }

    // ================================================================
    // Writes
    // ================================================================

    public async Task<DocumentSaveResult> SaveAsync(string mode, DocumentUploadSaveForm form, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(form);
        if (string.IsNullOrWhiteSpace(mode) || (mode != "New" && mode != "Edit"))
            return new DocumentSaveResult(false, null, "mode must be 'New' or 'Edit'.");
        if (form.OrganizationId <= 0)
            return new DocumentSaveResult(false, null, "OrganizationId is required.");

        byte[]? fileBytes = null;
        string? contentType = form.File?.ContentType;
        string? fileName    = form.File?.FileName;
        if (form.File is { Length: > 0 } uploaded)
        {
            using var ms = new MemoryStream();
            await uploaded.CopyToAsync(ms, ct);
            fileBytes = ms.ToArray();
        }

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_document_upload_save");

            AddParam(cmd, "@mode",                     DbType.String,  mode, 20);
            AddParam(cmd, "@document_id",              DbType.Int64,   (object?)form.DocumentId ?? DBNull.Value);
            AddParam(cmd, "@organization_id",          DbType.Int64,   form.OrganizationId);
            AddParam(cmd, "@document_name",            DbType.String,  (object?)form.DocumentName ?? DBNull.Value, 500);
            AddParam(cmd, "@company_document_code",    DbType.String,  (object?)form.CompanyDocumentCode ?? DBNull.Value, 100);
            AddParam(cmd, "@document_type_id",         DbType.Int32,   form.DocumentTypeId);
            AddParam(cmd, "@source_type_id",           DbType.Int32,   (object?)form.SourceTypeId ?? DBNull.Value);
            AddParam(cmd, "@version_number",           DbType.String,  (object?)form.VersionNumber ?? DBNull.Value, 30);
            AddParam(cmd, "@effective_date",           DbType.Date,    (object?)form.EffectiveDate ?? DBNull.Value);
            AddParam(cmd, "@next_review_date",         DbType.Date,    (object?)form.NextReviewDate ?? DBNull.Value);
            AddParam(cmd, "@distribution_type_code",   DbType.String,  (object?)form.DistributionTypeCode ?? DBNull.Value, 60);
            AddParam(cmd, "@distribution_ids",         DbType.String,  (object?)form.DistributionIds ?? DBNull.Value, -1);
            AddParam(cmd, "@acknowledgement_required", DbType.Boolean, form.AcknowledgementRequired);
            AddParam(cmd, "@change_summary",           DbType.String,  (object?)form.ChangeSummary ?? DBNull.Value, -1);
            AddParam(cmd, "@keywords_tag",             DbType.String,  (object?)form.KeywordsTag ?? DBNull.Value, -1);
            AddParam(cmd, "@owner_id",                 DbType.Int64,   (object?)form.OwnerId ?? DBNull.Value);
            AddParam(cmd, "@reviewer_id",              DbType.Int64,   (object?)form.ReviewerId ?? DBNull.Value);
            AddParam(cmd, "@approver_id",              DbType.Int64,   (object?)form.ApproverId ?? DBNull.Value);
            AddParam(cmd, "@file_name",                DbType.String,  (object?)fileName ?? DBNull.Value, 500);
            AddParam(cmd, "@content_type",             DbType.String,  (object?)contentType ?? DBNull.Value, 200);
            AddParamBinary(cmd, "@file_data",          fileBytes);
            AddParam(cmd, "@caller_employee_id",       DbType.Int64,   (object?)form.CallerEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",      DbType.String,  form.CallerDisplayName ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            long? docId = form.DocumentId;
            if (await SeekResultSetAsync(r, "DocumentId", ct))
                docId = Convert.ToInt64(r["DocumentId"]);
            else
                logger.LogWarning("DocumentUploadService.Save ({Mode}): the procedure returned no DocumentId row; the write itself committed.", mode);
            return new DocumentSaveResult(true, docId, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "DocumentUploadService.Save failed ({Mode}): {Message}", mode, ex.Message);
            return new DocumentSaveResult(false, form.DocumentId, ex.Message);
        }
    }

    public async Task<DocumentSaveResult> ToggleStatusAsync(long documentId, long organizationId, DocumentStatusToggleRequest request, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_document_upload_save");
            AddParam(cmd, "@mode",                DbType.String, "StatusToggle", 20);
            AddParam(cmd, "@document_id",         DbType.Int64,  documentId);
            AddParam(cmd, "@organization_id",     DbType.Int64,  organizationId);
            AddParam(cmd, "@caller_employee_id",  DbType.Int64,  (object?)request.CallerEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, request.CallerDisplayName ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            long? id = documentId;
            if (await SeekResultSetAsync(r, "DocumentId", ct)) id = Convert.ToInt64(r["DocumentId"]);
            return new DocumentSaveResult(true, id, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "DocumentUploadService.ToggleStatus failed for {DocumentId}: {Message}", documentId, ex.Message);
            return new DocumentSaveResult(false, documentId, ex.Message);
        }
    }

    public async Task<DocumentWorkflowResult> TransitionAsync(long documentId, DocumentWorkflowRequest request, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(request);
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_document_upload_workflow_transition");
            AddParam(cmd, "@document_id",         DbType.Int64,  documentId);
            AddParam(cmd, "@transition",          DbType.String, request.Transition, 20);
            AddParam(cmd, "@decision",            DbType.String, request.Decision, 20);
            AddParam(cmd, "@remark",              DbType.String, (object?)request.Remark ?? DBNull.Value, -1);
            AddParam(cmd, "@caller_employee_id",  DbType.Int64,  (object?)request.CallerEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, request.CallerDisplayName ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await SeekResultSetAsync(r, "DocumentId", ct))
            {
                return new DocumentWorkflowResult(
                    true,
                    Convert.ToInt64(r["DocumentId"]),
                    Convert.ToInt32(r["StageId"]),
                    r["StageCode"]?.ToString(),
                    null);
            }
            return new DocumentWorkflowResult(true, documentId, null, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "DocumentUploadService.Transition failed for {DocumentId}: {Message}", documentId, ex.Message);
            return new DocumentWorkflowResult(false, documentId, null, null, ex.Message);
        }
    }

    // ================================================================
    // Helpers (same shape as TaskService / PermissionService)
    // ================================================================

    private async Task<DbConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connString = Infrastructure.SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(connString))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");
        var connection = new SqlConnection(connString);
        await connection.OpenAsync(cancellationToken);
        return connection;
    }

    // Advances the reader to the first result set that carries `column`
    // and positions it on that set's first row. Returns false when no
    // result set has the column, or when the one that does has no rows.
    //
    // Why this is not a plain ReadAsync: a SELECT issued inside a nested
    // procedure reaches the client BEFORE the outer procedure's own
    // SELECT. sp_document_upload_save EXECs sp_document_file_save, whose
    // "SELECT SCOPE_IDENTITY() AS DocumentFileId" therefore arrived first
    // on every save that carried a file -- and r["DocumentId"] against
    // that row throws IndexOutOfRangeException whose Message is the bare
    // string "DocumentId", which the browser then showed as the save
    // error. Migration 219 removes that nested SELECT; this keeps the Api
    // correct against a database where 219 has not been applied yet, and
    // stops a reader mismatch from ever being reported as a business error.
    private static async Task<bool> SeekResultSetAsync(DbDataReader reader, string column, CancellationToken cancellationToken)
    {
        do
        {
            if (HasColumn(reader, column))
                return await reader.ReadAsync(cancellationToken);
        }
        while (await reader.NextResultAsync(cancellationToken));
        return false;
    }

    private static bool HasColumn(DbDataReader reader, string column)
    {
        for (var i = 0; i < reader.FieldCount; i++)
            if (string.Equals(reader.GetName(i), column, StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }

    private static DbCommand Proc(DbConnection connection, string name)
    {
        var cmd = connection.CreateCommand();
        cmd.CommandType = CommandType.StoredProcedure;
        cmd.CommandText = name;
        return cmd;
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

    private static void AddParamBinary(DbCommand command, string name, byte[]? value)
    {
        var p = (SqlParameter)command.CreateParameter();
        p.ParameterName = name;
        p.SqlDbType = SqlDbType.VarBinary;
        p.Size = -1; // MAX
        p.Value = (object?)value ?? DBNull.Value;
        command.Parameters.Add(p);
    }
}
