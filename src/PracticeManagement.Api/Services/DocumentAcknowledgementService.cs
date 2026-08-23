// =====================================================================
// DocumentAcknowledgementService  (charter §5)
//
// Thin facade over grac_practice.sp_document_ack_* procedures.
// Wire-up: Api/Infrastructure/DocumentAcknowledgementServiceRegistration.cs
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IDocumentAcknowledgementService
{
    // Admin
    Task<DocumentAckPendingResult>                      ListPendingAsync(long organizationId, int page, int pageSize, CancellationToken ct);
    Task<DocumentAckCreateResult>                       CreateAsync(DocumentAckCreateRequest request, CancellationToken ct);
    Task<DocumentAckBatchListResult>                    ListBatchesAsync(long organizationId, int page, int pageSize, CancellationToken ct);
    Task<IReadOnlyList<DocumentAckBatchDocumentRow>>    ListBatchDocumentsAsync(long acknowledgementId, CancellationToken ct);
    Task<IReadOnlyList<DocumentAckDocumentUserRow>>     ListDocumentUsersAsync(long acknowledgementId, long documentId, CancellationToken ct);
    // User (Phase 3). Admin mode (isAdmin=true) ignores the employee
    // filter and returns org-wide aggregates. `organizationId` is only
    // needed when isAdmin=true.
    Task<IReadOnlyList<DocumentAckUserBatchRow>>        ListUserBatchesAsync(long employeeId, bool includeCompleted, bool isAdmin, long? organizationId, CancellationToken ct);
    Task<IReadOnlyList<DocumentAckUserDocumentRow>>     ListUserDocumentsAsync(long acknowledgementId, long employeeId, bool isAdmin, CancellationToken ct);
    Task<DocumentAckUserAckResult>                      AcknowledgeAsync(long employeeId, DocumentAckUserAckRequest request, CancellationToken ct);
}

public sealed class DocumentAcknowledgementService(IConfiguration configuration, ILogger<DocumentAcknowledgementService> logger)
    : IDocumentAcknowledgementService
{
    public async Task<DocumentAckPendingResult> ListPendingAsync(long organizationId, int page, int pageSize, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_ack_pending_list");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);
        AddParam(cmd, "@page_number",     DbType.Int32, Math.Max(1, page));
        AddParam(cmd, "@page_size",       DbType.Int32, Math.Clamp(pageSize <= 0 ? 50 : pageSize, 1, 200));

        var rows = new List<DocumentAckPendingRow>();
        long total = 0;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new DocumentAckPendingRow(
                Convert.ToInt64(r["PendingId"]),
                Convert.ToInt64(r["DocumentId"]),
                r["DocumentCode"]?.ToString() ?? "",
                r["DocumentName"]?.ToString() ?? "",
                r["VersionNumber"]?.ToString() ?? "",
                r["NextReviewDate"] as DateTime?,
                Convert.ToInt32(r["CycleNo"]),
                Convert.ToDateTime(r["QueuedOn"])));
            total = Convert.ToInt64(r["TotalRows"]);
        }
        return new DocumentAckPendingResult(total, page, pageSize, rows);
    }

    public async Task<DocumentAckCreateResult> CreateAsync(DocumentAckCreateRequest request, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.OrganizationId <= 0)
            return new DocumentAckCreateResult(false, null, "OrganizationId is required.");
        if (string.IsNullOrWhiteSpace(request.AcknowledgementName))
            return new DocumentAckCreateResult(false, null, "AcknowledgementName is required.");
        if (request.PendingIds is null || request.PendingIds.Count == 0)
            return new DocumentAckCreateResult(false, null, "Pick at least one pending document.");

        var csv = string.Join(",", request.PendingIds);

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_document_ack_create");
            AddParam(cmd, "@organization_id",      DbType.Int64,  request.OrganizationId);
            AddParam(cmd, "@acknowledgement_name", DbType.String, request.AcknowledgementName, 200);
            AddParam(cmd, "@due_date",             DbType.Date,   (object?)request.DueDate ?? DBNull.Value);
            AddParam(cmd, "@pending_ids",          DbType.String, csv, -1);
            AddParam(cmd, "@caller_employee_id",   DbType.Int64,  (object?)request.CallerEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",  DbType.String, request.CallerDisplayName ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            long? batchId = null;
            if (await r.ReadAsync(ct))
                batchId = Convert.ToInt64(r["AcknowledgementId"]);
            return new DocumentAckCreateResult(true, batchId, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "DocumentAcknowledgementService.Create failed: {Message}", ex.Message);
            return new DocumentAckCreateResult(false, null, ex.Message);
        }
    }

    public async Task<DocumentAckBatchListResult> ListBatchesAsync(long organizationId, int page, int pageSize, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_ack_list");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);
        AddParam(cmd, "@page_number",     DbType.Int32, Math.Max(1, page));
        AddParam(cmd, "@page_size",       DbType.Int32, Math.Clamp(pageSize <= 0 ? 25 : pageSize, 1, 200));

        var rows = new List<DocumentAckBatchRow>();
        long total = 0;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new DocumentAckBatchRow(
                Convert.ToInt64(r["AcknowledgementId"]),
                r["AcknowledgementName"]?.ToString() ?? "",
                r["DueDate"] as DateTime?,
                r["StatusCode"]?.ToString() ?? "",
                Convert.ToInt32(r["DocumentCount"]),
                Convert.ToInt32(r["UserCount"]),
                Convert.ToInt32(r["AckCount"]),
                Convert.ToDecimal(r["CompletionPct"]),
                r["ProgressLabel"]?.ToString() ?? "",
                Convert.ToDateTime(r["CreatedOn"]),
                r["CreatedBy"]?.ToString() ?? ""));
            total = Convert.ToInt64(r["TotalRows"]);
        }
        return new DocumentAckBatchListResult(total, page, pageSize, rows);
    }

    public async Task<IReadOnlyList<DocumentAckBatchDocumentRow>> ListBatchDocumentsAsync(long acknowledgementId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_ack_documents_list");
        AddParam(cmd, "@acknowledgement_id", DbType.Int64, acknowledgementId);
        var rows = new List<DocumentAckBatchDocumentRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new DocumentAckBatchDocumentRow(
                Convert.ToInt64(r["DocumentId"]),
                r["DocumentCode"]?.ToString() ?? "",
                r["DocumentName"]?.ToString() ?? "",
                r["VersionNumber"]?.ToString() ?? "",
                Convert.ToInt32(r["CycleNo"]),
                Convert.ToInt32(r["UserCount"]),
                Convert.ToInt32(r["AckCount"]),
                Convert.ToDecimal(r["CompletionPct"]),
                r["ProgressLabel"]?.ToString() ?? ""));
        return rows;
    }

    public async Task<IReadOnlyList<DocumentAckDocumentUserRow>> ListDocumentUsersAsync(long acknowledgementId, long documentId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_ack_document_users_list");
        AddParam(cmd, "@acknowledgement_id", DbType.Int64, acknowledgementId);
        AddParam(cmd, "@document_id",        DbType.Int64, documentId);
        var rows = new List<DocumentAckDocumentUserRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new DocumentAckDocumentUserRow(
                Convert.ToInt64(r["EmployeeId"]),
                r["EmployeeCode"] as string,
                r["EmployeeName"]?.ToString() ?? "",
                r["Email"] as string,
                r["StatusCode"]?.ToString() ?? "",
                r["AcknowledgedOn"] as DateTime?,
                r["Remark"] as string));
        return rows;
    }

    // ================================================================
    // USER SIDE (Phase 3)
    // ================================================================

    public async Task<IReadOnlyList<DocumentAckUserBatchRow>> ListUserBatchesAsync(long employeeId, bool includeCompleted, bool isAdmin, long? organizationId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_ack_user_batches");
        AddParam(cmd, "@employee_id",       DbType.Int64,   isAdmin ? (object)DBNull.Value : employeeId);
        AddParam(cmd, "@include_completed", DbType.Boolean, includeCompleted);
        AddParam(cmd, "@is_admin",          DbType.Boolean, isAdmin);
        AddParam(cmd, "@organization_id",   DbType.Int64,   (object?)organizationId ?? DBNull.Value);
        var rows = new List<DocumentAckUserBatchRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new DocumentAckUserBatchRow(
                Convert.ToInt64(r["AcknowledgementId"]),
                r["AcknowledgementName"]?.ToString() ?? "",
                r["DueDate"] as DateTime?,
                r["BatchStatusCode"]?.ToString() ?? "",
                Convert.ToInt32(r["MyDocCount"]),
                Convert.ToInt32(r["MyAckCount"]),
                Convert.ToInt32(r["MyPendingCount"]),
                Convert.ToDecimal(r["MyCompletionPct"]),
                r["MyStatusLabel"]?.ToString() ?? "",
                Convert.ToDateTime(r["CreatedOn"])));
        return rows;
    }

    public async Task<IReadOnlyList<DocumentAckUserDocumentRow>> ListUserDocumentsAsync(long acknowledgementId, long employeeId, bool isAdmin, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_document_ack_user_documents");
        AddParam(cmd, "@acknowledgement_id", DbType.Int64,   acknowledgementId);
        AddParam(cmd, "@employee_id",        DbType.Int64,   isAdmin ? (object)DBNull.Value : employeeId);
        AddParam(cmd, "@is_admin",           DbType.Boolean, isAdmin);
        var rows = new List<DocumentAckUserDocumentRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new DocumentAckUserDocumentRow(
                Convert.ToInt64(r["AcknowledgementUserId"]),
                Convert.ToInt64(r["AcknowledgementId"]),
                r["AcknowledgementName"]?.ToString() ?? "",
                r["DueDate"] as DateTime?,
                Convert.ToInt64(r["DocumentId"]),
                r["DocumentCode"]?.ToString() ?? "",
                r["DocumentName"]?.ToString() ?? "",
                r["VersionNumber"]?.ToString() ?? "",
                r["NextReviewDate"] as DateTime?,
                r["StatusCode"]?.ToString() ?? "",
                r["AcknowledgedOn"] as DateTime?,
                r["Remark"] as string,
                Convert.ToInt64(r["EmployeeId"]),
                r["EmployeeName"]?.ToString() ?? "",
                r["EmployeeCode"] as string,
                r["EmployeeEmail"] as string));
        return rows;
    }

    public async Task<DocumentAckUserAckResult> AcknowledgeAsync(long employeeId, DocumentAckUserAckRequest request, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (employeeId <= 0)
            return new DocumentAckUserAckResult(false, 0, 0, 0, null, null, "employeeId is required.");
        if (request.AcknowledgementId <= 0 || request.DocumentId <= 0)
            return new DocumentAckUserAckResult(false, request.AcknowledgementId, request.DocumentId, employeeId, null, null,
                "AcknowledgementId and DocumentId are required.");

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_document_ack_user_ack");
            AddParam(cmd, "@acknowledgement_id",  DbType.Int64,  request.AcknowledgementId);
            AddParam(cmd, "@document_id",         DbType.Int64,  request.DocumentId);
            AddParam(cmd, "@employee_id",         DbType.Int64,  employeeId);
            AddParam(cmd, "@remark",              DbType.String, (object?)request.Remark ?? DBNull.Value, -1);
            AddParam(cmd, "@caller_display_name", DbType.String, request.CallerDisplayName ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
            {
                return new DocumentAckUserAckResult(true,
                    Convert.ToInt64(r["AcknowledgementId"]),
                    Convert.ToInt64(r["DocumentId"]),
                    Convert.ToInt64(r["EmployeeId"]),
                    r["StatusCode"]?.ToString(),
                    r["AcknowledgedOn"] as DateTime?,
                    null);
            }
            return new DocumentAckUserAckResult(true, request.AcknowledgementId, request.DocumentId, employeeId,
                "Acknowledged", DateTime.UtcNow, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "DocumentAcknowledgementService.Acknowledge failed: {Message}", ex.Message);
            return new DocumentAckUserAckResult(false, request.AcknowledgementId, request.DocumentId, employeeId, null, null, ex.Message);
        }
    }

    // ---- helpers -----------------------------------------------------

    private async Task<DbConnection> OpenAsync(CancellationToken ct)
    {
        var cs = Infrastructure.SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(cs))
            throw new InvalidOperationException("PracticeManagement connection string is not configured.");
        var c = new SqlConnection(cs);
        await c.OpenAsync(ct);
        return c;
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
}
