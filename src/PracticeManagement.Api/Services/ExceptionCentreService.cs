// =====================================================================
// ExceptionCentreService  (charter §5)
//
// Thin facade over grac_practice.sp_exception_request_* procs.
// Wire-up: ExceptionCentreServiceRegistration.cs
//     builder.Services.AddPracticeExceptionCentreService();
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IExceptionCentreService
{
    // requestType filter (post-184): NULL = both tabs, "GAP_CANDIDATE" or "SLA_CANDIDATE".
    Task<ExceptionRequestListResult> ListAsync(long organizationId, string? statusCode, string? requestType, int page, int pageSize, CancellationToken ct);
    Task<ExceptionRequestDetail?>    GetAsync(long exceptionRequestId, CancellationToken ct);
    Task<ExceptionActionResult>      ApproveAsync(long id, ExceptionApproveRequest req, CancellationToken ct);
    Task<ExceptionActionResult>      RejectAsync(long id, ExceptionRejectRequest req, CancellationToken ct);
    // Migration 184: SLA override candidates use their own approve path
    // (no effective_until / approval_note required; sla_days_requested
    // already lives on the request).
    Task<ExceptionActionResult>      ApproveSlaAsync(long id, ExceptionApproveSlaRequest req, CancellationToken ct);
    Task<IReadOnlyList<EvidenceTypeRow>> ListEvidenceTypesAsync(CancellationToken ct);
    Task<IReadOnlyList<ExceptionTypeRow>> ListExceptionTypesAsync(CancellationToken ct);
    Task<IReadOnlyList<OrganizationPracticeRow>> ListPracticesAsync(long organizationId, CancellationToken ct);
    Task<int>                        ExpireDueAsync(string? callerDisplayName, CancellationToken ct);
    Task<long>                       SaveAttachmentAsync(long id, string collectionMethodCode, string? evidenceTypeCode, string? fileName, string? contentType, byte[]? data, string? evidenceLocation, string? evidenceLocator, long? empId, string? caller, CancellationToken ct);
    Task<(byte[]? bytes, string? fileName, string? contentType)> GetAttachmentAsync(long attachmentId, CancellationToken ct);
    Task<IReadOnlyList<ExceptionAttachmentRow>> ListAttachmentsAsync(long id, CancellationToken ct);
}

public sealed class ExceptionCentreService(IConfiguration configuration, ILogger<ExceptionCentreService> logger) : IExceptionCentreService
{
    public async Task<ExceptionRequestListResult> ListAsync(long organizationId, string? statusCode, string? requestType, int page, int pageSize, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_list");
        AddParam(cmd, "@organization_id",   DbType.Int64,  organizationId);
        AddParam(cmd, "@status_code",       DbType.String, (object?)statusCode ?? DBNull.Value, 30);
        AddParam(cmd, "@request_type_code", DbType.String, (object?)requestType ?? DBNull.Value, 30);
        AddParam(cmd, "@page_number",       DbType.Int32,  Math.Max(1, page));
        AddParam(cmd, "@page_size",         DbType.Int32,  Math.Clamp(pageSize <= 0 ? 25 : pageSize, 1, 200));

        var rows = new List<ExceptionRequestRow>();
        long total = 0;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new ExceptionRequestRow(
                Convert.ToInt64(r["ExceptionRequestId"]),
                Convert.ToInt64(r["OrganizationId"]),
                Convert.ToInt64(r["CustomGapId"]),
                r["GapTitle"] as string,
                r["RequestTitle"]?.ToString() ?? "",
                r["ExceptionTypeName"] as string,
                r["StatusCode"]?.ToString() ?? "",
                Convert.ToDateTime(r["RequestedOn"]),
                r["RequestedByName"] as string,
                r["ApprovedOn"] as DateTime?,
                r["ApprovedByName"] as string,
                r["EffectiveFrom"] as DateTime?,
                r["EffectiveUntil"] as DateTime?,
                r["RejectedOn"] as DateTime?,
                r["RejectedByName"] as string,
                Convert.ToInt32(r["AttachmentCount"]),
                // Post-184: request type (Gap Candidate / SLA Candidate)
                // and SLA payload snapshots surface in the grid too.
                ReadStringSafe(r, "RequestTypeCode") ?? "GAP_CANDIDATE",
                ReadIntSafe(r,    "SlaDaysOriginal"),
                ReadIntSafe(r,    "SlaDaysRequested")));
            total = Convert.ToInt64(r["TotalRows"]);
        }
        return new ExceptionRequestListResult(total, page, pageSize, rows);
    }

    // Tolerant readers for columns added post-166 -- the migration might
    // not be deployed everywhere yet.
    private static string? ReadStringSafe(System.Data.Common.DbDataReader r, string col)
    {
        try { var v = r[col]; return v == DBNull.Value ? null : v?.ToString(); }
        catch (IndexOutOfRangeException) { return null; }
    }
    private static int? ReadIntSafe(System.Data.Common.DbDataReader r, string col)
    {
        try { var v = r[col]; return v == DBNull.Value ? (int?)null : Convert.ToInt32(v); }
        catch (IndexOutOfRangeException) { return null; }
    }

    public async Task<ExceptionRequestDetail?> GetAsync(long id, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_get");
        AddParam(cmd, "@exception_request_id", DbType.Int64, id);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        return new ExceptionRequestDetail(
            Convert.ToInt64(r["ExceptionRequestId"]),
            Convert.ToInt64(r["OrganizationId"]),
            Convert.ToInt64(r["CustomGapId"]),
            r["GapTitle"] as string,
            r["RequestTitle"]?.ToString() ?? "",
            r["RequestReason"] as string,
            r["Justification"] as string,
            r["RiskImpact"] as string,
            r["ExceptionTypeCode"] as string,
            r["ExceptionTypeName"] as string,
            r["OwnerEmployeeId"] as long?,
            r["OwnerName"] as string,
            r["LinkedPracticeId"] as long?,
            r["LinkedRequirementRef"] as string,
            r["StatusCode"]?.ToString() ?? "",
            r["RequestedByEmployeeId"] as long?,
            r["RequestedByName"] as string,
            Convert.ToDateTime(r["RequestedOn"]),
            r["ApprovedByEmployeeId"] as long?,
            r["ApprovedByName"] as string,
            r["ApprovedOn"] as DateTime?,
            r["EffectiveFrom"] as DateTime?,
            r["EffectiveUntil"] as DateTime?,
            r["ApprovalNote"] as string,
            r["CompensatingControl"] as string,
            r["ReviewFrequencyId"] as int?,
            r["ReviewFrequencyName"] as string,
            r["RejectedByEmployeeId"] as long?,
            r["RejectedByName"] as string,
            r["RejectedOn"] as DateTime?,
            r["RejectionReason"] as string);
    }

    public async Task<ExceptionActionResult> ApproveAsync(long id, ExceptionApproveRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.ApprovedByEmployeeId is null or <= 0)
            return new ExceptionActionResult(false, id, null, "approvedByEmployeeId is required.");
        if (string.IsNullOrWhiteSpace(req.ApprovalNote))
            return new ExceptionActionResult(false, id, null, "approvalNote is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_approve");
            AddParam(cmd, "@exception_request_id",    DbType.Int64,  id);
            AddParam(cmd, "@effective_until",         DbType.Date,   req.EffectiveUntil);
            AddParam(cmd, "@approval_note",           DbType.String, req.ApprovalNote, -1);
            AddParam(cmd, "@approved_by_employee_id", DbType.Int64,  req.ApprovedByEmployeeId!.Value);
            AddParam(cmd, "@effective_from",          DbType.Date,   (object?)req.EffectiveFrom ?? DBNull.Value);
            AddParam(cmd, "@compensating_control",    DbType.String, (object?)req.CompensatingControl ?? DBNull.Value, -1);
            AddParam(cmd, "@review_frequency_id",     DbType.Int32,  (object?)req.ReviewFrequencyId ?? DBNull.Value);
            AddParam(cmd, "@exception_type_code",     DbType.String, (object?)req.ExceptionTypeCode ?? DBNull.Value, 60);
            AddParam(cmd, "@justification",           DbType.String, (object?)req.Justification ?? DBNull.Value, -1);
            AddParam(cmd, "@risk_impact",             DbType.String, (object?)req.RiskImpact ?? DBNull.Value, -1);
            AddParam(cmd, "@owner_employee_id",       DbType.Int64,  (object?)req.OwnerEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@linked_practice_id",      DbType.Int64,  (object?)req.LinkedPracticeId ?? DBNull.Value);
            AddParam(cmd, "@linked_requirement_ref",  DbType.String, (object?)req.LinkedRequirementRef ?? DBNull.Value, 200);
            AddParam(cmd, "@caller_display_name",     DbType.String, req.CallerDisplayName ?? "system", 100);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new ExceptionActionResult(true, Convert.ToInt64(r["ExceptionRequestId"]), r["StatusCode"]?.ToString(), null);
            return new ExceptionActionResult(true, id, "Approved", null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "ExceptionCentreService.Approve failed {Id}: {Msg}", id, ex.Message);
            return new ExceptionActionResult(false, id, null, ex.Message);
        }
    }

    public async Task<ExceptionActionResult> RejectAsync(long id, ExceptionRejectRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.RejectedByEmployeeId is null or <= 0)
            return new ExceptionActionResult(false, id, null, "rejectedByEmployeeId is required.");
        if (string.IsNullOrWhiteSpace(req.RejectionReason))
            return new ExceptionActionResult(false, id, null, "rejectionReason is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_reject");
            AddParam(cmd, "@exception_request_id",    DbType.Int64,  id);
            AddParam(cmd, "@rejection_reason",        DbType.String, req.RejectionReason, -1);
            AddParam(cmd, "@rejected_by_employee_id", DbType.Int64,  req.RejectedByEmployeeId!.Value);
            AddParam(cmd, "@caller_display_name",     DbType.String, req.CallerDisplayName ?? "system", 100);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new ExceptionActionResult(true, Convert.ToInt64(r["ExceptionRequestId"]), r["StatusCode"]?.ToString(), null);
            return new ExceptionActionResult(true, id, "Rejected", null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "ExceptionCentreService.Reject failed {Id}: {Msg}", id, ex.Message);
            return new ExceptionActionResult(false, id, null, ex.Message);
        }
    }

    // Migration 184 -- SLA Candidate approval. Different from Gap
    // Candidate approve because no effective_until / approval_note
    // is meaningful; the request already carries sla_days_requested.
    public async Task<ExceptionActionResult> ApproveSlaAsync(long id, ExceptionApproveSlaRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        // Post-190: approvedByEmployeeId is OPTIONAL. If missing, resolve
        // from callerDisplayName (session email or employee_code) so
        // Practice Admin sessions can still approve. Falls back to null
        // when no match -- audit persists via callerDisplayName.
        long? resolvedApproverId = req.ApprovedByEmployeeId;
        if ((resolvedApproverId is null or <= 0)
            && !string.IsNullOrWhiteSpace(req.CallerDisplayName))
        {
            try
            {
                await using var lookupConn = await OpenAsync(ct);
                await using var lookupCmd  = lookupConn.CreateCommand();
                lookupCmd.CommandType = CommandType.Text;
                lookupCmd.CommandText = @"
                    SELECT TOP 1 employee_id
                      FROM grac_practice.organization_employee
                     WHERE (email = @caller OR employee_code = @caller)
                       AND status = N'Active'
                     ORDER BY employee_id DESC;";
                AddParam(lookupCmd, "@caller", DbType.String, req.CallerDisplayName, 240);
                var v = await lookupCmd.ExecuteScalarAsync(ct);
                if (v is not null && v != DBNull.Value)
                    resolvedApproverId = Convert.ToInt64(v);
            }
            catch (SqlException ex)
            {
                logger.LogWarning(ex,
                    "ExceptionCentre.ApproveSla: email->employee lookup failed for {Email}; passing null.",
                    req.CallerDisplayName);
            }
        }

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_sla_override_approve");
            AddParam(cmd, "@exception_request_id",    DbType.Int64,  id);
            AddParam(cmd, "@approved_by_employee_id", DbType.Int64,
                     (resolvedApproverId is > 0 ? (object)resolvedApproverId.Value : DBNull.Value));
            AddParam(cmd, "@caller_display_name",     DbType.String, req.CallerDisplayName ?? "system", 100);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new ExceptionActionResult(true, Convert.ToInt64(r["ExceptionRequestId"]), r["StatusCode"]?.ToString(), null);
            return new ExceptionActionResult(true, id, "Approved", null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "ExceptionCentreService.ApproveSla failed {Id}: {Msg}", id, ex.Message);
            return new ExceptionActionResult(false, id, null, ex.Message);
        }
    }

    public async Task<IReadOnlyList<EvidenceTypeRow>> ListEvidenceTypesAsync(CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_evidence_type_list");
        var rows = new List<EvidenceTypeRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new EvidenceTypeRow(
                Convert.ToInt32(r["EvidenceTypeId"]),
                r["EvidenceTypeCode"]?.ToString() ?? "",
                r["EvidenceTypeName"]?.ToString() ?? "",
                Convert.ToInt32(r["SortOrder"])));
        return rows;
    }

    public async Task<long> SaveAttachmentAsync(long id, string collectionMethodCode, string? evidenceTypeCode,
                                                string? fileName, string? contentType, byte[]? data,
                                                string? evidenceLocation, string? evidenceLocator,
                                                long? empId, string? caller, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_attachment_save");
        AddParam(cmd, "@exception_request_id",    DbType.Int64,  id);
        AddParam(cmd, "@collection_method_code",  DbType.String, (object?)collectionMethodCode ?? "Manual", 60);
        AddParam(cmd, "@evidence_type_code",      DbType.String, (object?)evidenceTypeCode ?? DBNull.Value, 60);
        AddParam(cmd, "@file_name",               DbType.String, (object?)fileName ?? DBNull.Value, 500);
        AddParam(cmd, "@content_type",            DbType.String, (object?)contentType ?? DBNull.Value, 200);
        AddParamBinary(cmd, "@file_data",         data);
        AddParam(cmd, "@evidence_location",       DbType.String, (object?)evidenceLocation ?? DBNull.Value, 500);
        AddParam(cmd, "@evidence_locator",        DbType.String, (object?)evidenceLocator ?? DBNull.Value, 500);
        AddParam(cmd, "@uploaded_by_employee_id", DbType.Int64,  (object?)empId ?? DBNull.Value);
        AddParam(cmd, "@caller_display_name",     DbType.String, caller ?? "system", 100);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (await r.ReadAsync(ct)) return Convert.ToInt64(r["AttachmentId"]);
        return 0;
    }

    public async Task<(byte[]? bytes, string? fileName, string? contentType)> GetAttachmentAsync(long attachmentId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_attachment_get");
        AddParam(cmd, "@attachment_id", DbType.Int64, attachmentId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return (null, null, null);
        return ((byte[])r["FileData"], r["FileName"]?.ToString(), r["ContentType"] as string);
    }

    public async Task<IReadOnlyList<ExceptionAttachmentRow>> ListAttachmentsAsync(long id, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_attachment_list");
        AddParam(cmd, "@exception_request_id", DbType.Int64, id);
        var rows = new List<ExceptionAttachmentRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new ExceptionAttachmentRow(
                Convert.ToInt64(r["AttachmentId"]),
                r["CollectionMethodCode"] as string,
                r["CollectionMethodName"] as string,
                r["EvidenceTypeCode"] as string,
                r["EvidenceTypeName"] as string,
                r["FileName"] as string,
                r["ContentType"] as string,
                Convert.ToInt64(r["FileSizeBytes"]),
                r["EvidenceLocation"] as string,
                r["EvidenceLocator"] as string,
                r["UploadedByEmployeeId"] as long?,
                r["UploadedByName"] as string,
                Convert.ToDateTime(r["UploadedOn"])));
        return rows;
    }

    public async Task<IReadOnlyList<ExceptionTypeRow>> ListExceptionTypesAsync(CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_exception_type_list");
        var rows = new List<ExceptionTypeRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new ExceptionTypeRow(
                Convert.ToInt32(r["ExceptionTypeId"]),
                r["ExceptionTypeCode"]?.ToString() ?? "",
                r["ExceptionTypeName"]?.ToString() ?? "",
                r["Description"] as string,
                Convert.ToInt32(r["SortOrder"])));
        return rows;
    }

    public async Task<IReadOnlyList<OrganizationPracticeRow>> ListPracticesAsync(long organizationId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_organization_practice_list");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);
        var rows = new List<OrganizationPracticeRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new OrganizationPracticeRow(
                Convert.ToInt64(r["PracticeId"]),
                r["PracticeCode"]?.ToString() ?? "",
                r["PracticeName"]?.ToString() ?? "",
                r["ApplicabilityStatus"] as string,
                r["PracticeOwner"] as string));
        return rows;
    }

    public async Task<int> ExpireDueAsync(string? callerDisplayName, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_expire_due");
        AddParam(cmd, "@caller_display_name", DbType.String, callerDisplayName ?? "expiry-runner", 100);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (await r.ReadAsync(ct)) return Convert.ToInt32(r["ExpiredCount"]);
        return 0;
    }

    // ---- helpers ----
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
    private static void AddParamBinary(DbCommand command, string name, byte[]? value)
    {
        var p = (SqlParameter)command.CreateParameter();
        p.ParameterName = name;
        p.SqlDbType = SqlDbType.VarBinary;
        p.Size = -1;
        p.Value = (object?)value ?? DBNull.Value;
        command.Parameters.Add(p);
    }
}
