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
    // Approve Exception dialog's Review Frequency select -- reuses
    // grac_practice.sp_risk_review_frequency_list (293) unchanged; see
    // ExceptionReviewFrequencyRow's own header for why this is not a
    // new/duplicate frequency list.
    Task<IReadOnlyList<ExceptionReviewFrequencyRow>> ListReviewFrequenciesAsync(CancellationToken ct);
    Task<int>                        ExpireDueAsync(string? callerDisplayName, CancellationToken ct);
    Task<long>                       SaveAttachmentAsync(long id, string collectionMethodCode, string? evidenceTypeCode, string? fileName, string? contentType, byte[]? data, string? evidenceLocation, string? evidenceLocator, long? empId, string? caller, CancellationToken ct);
    Task<(byte[]? bytes, string? fileName, string? contentType)> GetAttachmentAsync(long attachmentId, CancellationToken ct);
    Task<IReadOnlyList<ExceptionAttachmentRow>> ListAttachmentsAsync(long id, CancellationToken ct);
    Task<IReadOnlyList<ExceptionHistoryRow>> ListHistoryAsync(long id, CancellationToken ct);

    // Migration 257 -- the Analysis stage that now sits between Pending
    // and the approval decision.
    Task<ExceptionActionResult> SaveAnalysisAsync(long id, ExceptionAnalysisSaveRequest req, CancellationToken ct);
    Task<ExceptionActionResult> SubmitForApprovalAsync(long id, ExceptionSubmitForApprovalRequest req, CancellationToken ct);
    Task<IReadOnlyList<ExceptionTaskRow>>          ListTasksAsync(long id, CancellationToken ct);
    Task<ExceptionTaskCandidatesResult>            ListTaskCandidatesAsync(long id, string? search, CancellationToken ct);
    Task<ExceptionActionResult> LinkTaskAsync(long id, ExceptionTaskLinkRequest req, CancellationToken ct);
    Task<ExceptionActionResult> UnlinkTaskAsync(long id, long taskId, string? caller, CancellationToken ct);

    // Migration 327 -- "+ Add Custom Exception." Creates a standalone
    // exception_request (request_type_code = 'CUSTOM') that then runs
    // through the same Analysis / Submit / Approve-Reject flow as every
    // other request type.
    Task<ExceptionActionResult> CreateCustomAsync(ExceptionCreateCustomRequest req, CancellationToken ct);
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
                // 327: CustomGapId is NULL for a task-linked or CUSTOM
                // request. Convert.ToInt64 on DBNull throws -- this list
                // would 500 the instant such a row appeared in an org's
                // results, so it reads the same way the other post-166
                // columns just below already do.
                ReadLongSafe(r, "CustomGapId"),
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

    private static bool HasCol(System.Data.Common.DbDataReader r, string name)
    {
        for (var i = 0; i < r.FieldCount; i++)
            if (string.Equals(r.GetName(i), name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
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
    // 327: same tolerant pattern, for BIGINT columns that can be NULL
    // (CustomGapId, now that gap-less requests are a normal shape).
    private static long? ReadLongSafe(System.Data.Common.DbDataReader r, string col)
    {
        try { var v = r[col]; return v == DBNull.Value ? (long?)null : Convert.ToInt64(v); }
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
            // 327: sp_exception_request_get now LEFT JOINs custom_gap, so
            // this column is genuinely NULL for a gap-less request.
            ReadLongSafe(r, "CustomGapId"),
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
            // 327: sp_exception_request_get now returns this column too.
            ReadStringSafe(r, "RequestTypeCode") ?? "GAP_CANDIDATE",
            r["RequestedByEmployeeId"] as long?,
            r["RequestedByName"] as string,
            Convert.ToDateTime(r["RequestedOn"]),
            r["ProposedEffectiveFrom"] as DateTime?,
            r["ProposedEffectiveUntil"] as DateTime?,
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
        // The actor may arrive as an id (a database sign-in stamps one on
        // the session) or as nothing at all (the bootstrap admin, whose
        // password is checked against configuration). Fall back to the
        // caller's own email / employee_code, exactly as the SLA approval
        // has done since 190 -- refusing outright made the screen unusable
        // for a session that is otherwise perfectly entitled to approve.
        var approverId = await ResolveActorIdAsync(req.ApprovedByEmployeeId, req.CallerDisplayName, "Approve", ct);
        if (approverId is null or <= 0)
            return new ExceptionActionResult(false, id, null,
                "No employee could be identified for this approval. The signed-in user needs an "
                + "organization_employee row (matched on email or employee code) before they can approve.");
        if (string.IsNullOrWhiteSpace(req.ApprovalNote))
            return new ExceptionActionResult(false, id, null, "approvalNote is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_approve");
            AddParam(cmd, "@exception_request_id",    DbType.Int64,  id);
            AddParam(cmd, "@effective_until",         DbType.Date,   req.EffectiveUntil);
            AddParam(cmd, "@approval_note",           DbType.String, req.ApprovalNote, -1);
            AddParam(cmd, "@approved_by_employee_id", DbType.Int64,  approverId.Value);
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
        // Same fallback as Approve: rejecting is the other half of one
        // decision, and an approver who can approve can reject.
        var rejecterId = await ResolveActorIdAsync(req.RejectedByEmployeeId, req.CallerDisplayName, "Reject", ct);
        if (rejecterId is null or <= 0)
            return new ExceptionActionResult(false, id, null,
                "No employee could be identified for this rejection. The signed-in user needs an "
                + "organization_employee row (matched on email or employee code) before they can reject.");
        if (string.IsNullOrWhiteSpace(req.RejectionReason))
            return new ExceptionActionResult(false, id, null, "rejectionReason is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_reject");
            AddParam(cmd, "@exception_request_id",    DbType.Int64,  id);
            AddParam(cmd, "@rejection_reason",        DbType.String, req.RejectionReason, -1);
            AddParam(cmd, "@rejected_by_employee_id", DbType.Int64,  rejecterId.Value);
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
        // Post-190: approvedByEmployeeId is OPTIONAL here, and unlike the
        // gap-candidate approve the procedure accepts a null actor -- the
        // audit still persists via callerDisplayName. The lookup itself is
        // the shared one below.
        var resolvedApproverId = await ResolveActorIdAsync(req.ApprovedByEmployeeId, req.CallerDisplayName, "ApproveSla", ct);

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

    public async Task<IReadOnlyList<ExceptionReviewFrequencyRow>> ListReviewFrequenciesAsync(CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_review_frequency_list");

        var rows = new List<ExceptionReviewFrequencyRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new ExceptionReviewFrequencyRow(
                Convert.ToInt32(r["FrequencyId"]),
                r["FrequencyCode"] as string,
                r["FrequencyName"]?.ToString() ?? "",
                r["FrequencyValue"] as int?,
                r["FrequencyUnit"] as string,
                r["IsCustom"] != DBNull.Value && Convert.ToBoolean(r["IsCustom"])));
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
    // =================================================================
    // Migration 257 -- Analysis stage
    // =================================================================

    public async Task<ExceptionActionResult> SaveAnalysisAsync(
        long id, ExceptionAnalysisSaveRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_analysis_save");
            AddParam(cmd, "@exception_request_id", DbType.Int64,  id);
            AddParam(cmd, "@exception_type_code",  DbType.String, (object?)req.ExceptionTypeCode ?? DBNull.Value, 60);
            AddParam(cmd, "@justification",        DbType.String, (object?)req.Justification ?? DBNull.Value, -1);
            AddParam(cmd, "@risk_impact",          DbType.String, (object?)req.RiskImpact ?? DBNull.Value, -1);
            AddParam(cmd, "@owner_employee_id",    DbType.Int64,  (object?)req.OwnerEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@proposed_effective_from",  DbType.Date,
                     (object?)req.ProposedEffectiveFrom ?? DBNull.Value);
            AddParam(cmd, "@proposed_effective_until", DbType.Date,
                     (object?)req.ProposedEffectiveUntil ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",  DbType.String,
                     string.IsNullOrWhiteSpace(req.CallerDisplayName) ? "system" : req.CallerDisplayName, 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct)) { /* consume */ }
            return new ExceptionActionResult(true, id, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "sp_exception_request_analysis_save failed for {Id}: {Msg}", id, ex.Message);
            return new ExceptionActionResult(false, id, null, ex.Message);
        }
    }

    public async Task<ExceptionActionResult> SubmitForApprovalAsync(
        long id, ExceptionSubmitForApprovalRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_submit_for_approval");
            AddParam(cmd, "@exception_request_id", DbType.Int64,  id);
            AddParam(cmd, "@actor_employee_id",    DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",  DbType.String,
                     string.IsNullOrWhiteSpace(req.CallerDisplayName) ? "system" : req.CallerDisplayName, 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct)) { /* consume */ }
            return new ExceptionActionResult(true, id, null, null);
        }
        catch (SqlException ex)
        {
            // 55268 / 55269 are the "justification / risk impact missing"
            // guards. Their message text is written for the operator, so
            // it is surfaced as-is rather than replaced.
            logger.LogWarning(ex, "sp_exception_request_submit_for_approval failed for {Id}: {Msg}", id, ex.Message);
            return new ExceptionActionResult(false, id, null, ex.Message);
        }
    }

    public async Task<IReadOnlyList<ExceptionTaskRow>> ListTasksAsync(long id, CancellationToken ct)
    {
        var rows = new List<ExceptionTaskRow>();
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_task_list");
            AddParam(cmd, "@exception_request_id", DbType.Int64, id);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
                rows.Add(new ExceptionTaskRow(
                    Convert.ToInt64(r["ExceptionRequestTaskId"]),
                    Convert.ToInt64(r["TaskId"]),
                    r["TaskNumber"] as string,
                    r["TaskTitle"] as string,
                    r["TaskTypeCode"] as string,
                    r["TaskTypeName"] as string,
                    r["TaskStatusCode"] as string,
                    r["TaskStatusName"] as string,
                    r["Priority"] as string,
                    r["DueAt"] as DateTime?,
                    r["AssignedToEmployeeId"] as long?,
                    r["AssignedToName"] as string,
                    r["LinkSourceCode"] as string,
                    r["LinkedBy"] as string,
                    r["LinkedOn"] as DateTime?));
        }
        catch (SqlException ex)
        {
            // Non-fatal: the analysis page still works without its task
            // panel, and a missing 257 should not blank the whole screen.
            logger.LogError(ex, "sp_exception_request_task_list failed for {Id}.", id);
        }
        return rows;
    }

    public async Task<IReadOnlyList<ExceptionHistoryRow>> ListHistoryAsync(long id, CancellationToken ct)
    {
        var rows = new List<ExceptionHistoryRow>();
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_history_list");
            AddParam(cmd, "@exception_request_id", DbType.Int64, id);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
                rows.Add(new ExceptionHistoryRow(
                    Convert.ToInt64(r["HistoryId"]),
                    Convert.ToInt64(r["ExceptionRequestId"]),
                    r["ActionCode"]?.ToString() ?? "",
                    r["FromStatusCode"] as string,
                    r["ToStatusCode"] as string,
                    r["Remark"] as string,
                    r["ActorEmployeeId"] as long?,
                    r["ActorName"] as string,
                    Convert.ToDateTime(r["EnteredOn"])));
        }
        catch (SqlException ex)
        {
            // Non-fatal, same reasoning as the task panel above: a screen
            // that cannot draw its audit trail is still a usable screen,
            // and a database without 260 should not blank it.
            logger.LogError(ex, "sp_exception_request_history_list failed for {Id}.", id);
        }
        return rows;
    }

    public async Task<ExceptionTaskCandidatesResult> ListTaskCandidatesAsync(
        long id, string? search, CancellationToken ct)
    {
        var rows = new List<ExceptionTaskCandidateRow>();
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_exception_practice_task_candidates");
            AddParam(cmd, "@exception_request_id", DbType.Int64,  id);
            AddParam(cmd, "@search",               DbType.String, (object?)search ?? DBNull.Value, 200);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
                rows.Add(new ExceptionTaskCandidateRow(
                    Convert.ToInt64(r["TaskId"]),
                    r["TaskNumber"] as string,
                    r["TaskTitle"] as string,
                    r["TaskTypeCode"] as string,
                    r["TaskTypeName"] as string,
                    r["TaskStatusCode"] as string,
                    r["TaskStatusName"] as string,
                    r["Priority"] as string,
                    r["DueAt"] as DateTime?,
                    r["AssignedToName"] as string,
                    r["IsLinked"] is bool b && b));

            // Migration 258's second result set: WHICH practice the list
            // was scoped to. An empty grid then says whether the practice
            // had no tasks, or no practice could be resolved at all.
            // Guarded, so a database still on 257 simply returns no scope.
            if (await r.NextResultAsync(ct) && await r.ReadAsync(ct))
            {
                return new ExceptionTaskCandidatesResult(
                    rows,
                    r["PracticeId"] as long?,
                    r["PracticeCode"] as string,
                    r["PracticeName"] as string,
                    // 259. Read defensively: a database still on 258
                    // returns the scope row without this column.
                    HasCol(r, "ScopeCode") ? r["ScopeCode"] as string : null);
            }
        }
        catch (SqlException ex)
        {
            logger.LogError(ex, "sp_exception_practice_task_candidates failed for {Id}.", id);
        }
        return new ExceptionTaskCandidatesResult(rows, null, null, null);
    }

    public async Task<ExceptionActionResult> LinkTaskAsync(
        long id, ExceptionTaskLinkRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_task_link");
            AddParam(cmd, "@exception_request_id", DbType.Int64,  id);
            AddParam(cmd, "@task_id",              DbType.Int64,  req.TaskId);
            AddParam(cmd, "@link_source_code",     DbType.String,
                     string.IsNullOrWhiteSpace(req.LinkSourceCode) ? "Mapped" : req.LinkSourceCode, 20);
            AddParam(cmd, "@caller_display_name",  DbType.String,
                     string.IsNullOrWhiteSpace(req.CallerDisplayName) ? "system" : req.CallerDisplayName, 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct)) { /* consume */ }
            return new ExceptionActionResult(true, id, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "sp_exception_request_task_link failed for {Id}: {Msg}", id, ex.Message);
            return new ExceptionActionResult(false, id, null, ex.Message);
        }
    }

    public async Task<ExceptionActionResult> UnlinkTaskAsync(
        long id, long taskId, string? caller, CancellationToken ct)
    {
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_task_unlink");
            AddParam(cmd, "@exception_request_id", DbType.Int64,  id);
            AddParam(cmd, "@task_id",              DbType.Int64,  taskId);
            AddParam(cmd, "@caller_display_name",  DbType.String,
                     string.IsNullOrWhiteSpace(caller) ? "system" : caller, 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct)) { /* consume */ }
            return new ExceptionActionResult(true, id, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "sp_exception_request_task_unlink failed for {Id}: {Msg}", id, ex.Message);
            return new ExceptionActionResult(false, id, null, ex.Message);
        }
    }

    // =================================================================
    // Migration 327 -- "+ Add Custom Exception."
    //
    // Thin wrapper over the now-extended sp_exception_request_create,
    // same shape as every other write in this file: named params, THROWs
    // from the proc surface as the SqlException's own message (55205 =
    // organization required, 55206 = title required, 55207 = the named
    // gap does not exist), nothing re-validated here that the proc
    // already validates.
    // =================================================================
    public async Task<ExceptionActionResult> CreateCustomAsync(
        ExceptionCreateCustomRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_exception_request_create");
            AddParam(cmd, "@custom_gap_id",             DbType.Int64,  (object?)req.CustomGapId ?? DBNull.Value);
            AddParam(cmd, "@request_title",              DbType.String, req.RequestTitle, 300);
            AddParam(cmd, "@request_reason",              DbType.String, (object?)req.RequestReason ?? DBNull.Value, -1);
            AddParam(cmd, "@requested_by_employee_id",    DbType.Int64,  (object?)req.RequestedByEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@exception_type_code",         DbType.String, (object?)req.ExceptionTypeCode ?? DBNull.Value, 60);
            AddParam(cmd, "@justification",               DbType.String, (object?)req.Justification ?? DBNull.Value, -1);
            AddParam(cmd, "@owner_employee_id",           DbType.Int64,  (object?)req.OwnerEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@linked_practice_id",          DbType.Int64,  (object?)req.LinkedPracticeId ?? DBNull.Value);
            AddParam(cmd, "@linked_requirement_ref",      DbType.String, (object?)req.LinkedRequirementRef ?? DBNull.Value, 200);
            // 328. JSON array of practice ids from the Add Custom Exception
            // dialog's cascading Practice Picker list; the procedure derives
            // @linked_practice_id from the first entry when the caller (as
            // here) did not set it explicitly.
            AddParam(cmd, "@practice_ids_json",           DbType.String,
                     (req.LinkedPracticeIds is { Count: > 0 })
                         ? System.Text.Json.JsonSerializer.Serialize(req.LinkedPracticeIds)
                         : (object)DBNull.Value, -1);
            AddParam(cmd, "@request_type_code",           DbType.String, "CUSTOM", 30);
            AddParam(cmd, "@organization_id",             DbType.Int64,  req.OrganizationId);
            AddParam(cmd, "@proposed_effective_from",     DbType.Date,   (object?)req.ProposedEffectiveFrom ?? DBNull.Value);
            AddParam(cmd, "@proposed_effective_until",    DbType.Date,   (object?)req.ProposedEffectiveUntil ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",         DbType.String,
                     string.IsNullOrWhiteSpace(req.CallerDisplayName) ? "system" : req.CallerDisplayName, 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            long newId = 0;
            if (await r.ReadAsync(ct)) newId = Convert.ToInt64(r["ExceptionRequestId"]);
            return new ExceptionActionResult(true, newId, "Pending", null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "sp_exception_request_create (CUSTOM) failed: {Msg}", ex.Message);
            return new ExceptionActionResult(false, 0, null, ex.Message);
        }
    }

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
    // =================================================================
    // Who is acting?
    //
    // Three decision paths needed the same answer and only the SLA one
    // had it (inline, since 190). The id is the preferred answer: a
    // database sign-in stamps employee_id onto the session and the Web
    // tier forwards it. But the bootstrap (ReviewLogin) admin is verified
    // against configuration, not the employee table, so it can arrive
    // with no id at all -- and callerDisplayName, which the Web tier
    // always stamps from the session, is that user's email.
    //
    // Resolving from it is a lookup, not a guess: no row, no id, and the
    // caller decides whether that is fatal. The gap-candidate procedures
    // require a real actor (the column is an FK); the SLA one tolerates
    // null. Nothing here invents an employee.
    // =================================================================
    private async Task<long?> ResolveActorIdAsync(
        long? suppliedEmployeeId, string? callerDisplayName, string operation, CancellationToken ct)
    {
        if (suppliedEmployeeId is > 0) return suppliedEmployeeId;
        if (string.IsNullOrWhiteSpace(callerDisplayName)) return null;

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = conn.CreateCommand();
            cmd.CommandType = CommandType.Text;
            cmd.CommandText = @"
                SELECT TOP 1 employee_id
                  FROM grac_practice.organization_employee
                 WHERE (email = @caller OR employee_code = @caller)
                   AND status = N'Active'
                 ORDER BY employee_id DESC;";
            AddParam(cmd, "@caller", DbType.String, callerDisplayName, 240);
            var v = await cmd.ExecuteScalarAsync(ct);
            if (v is not null && v != DBNull.Value) return Convert.ToInt64(v);

            logger.LogWarning(
                "ExceptionCentre.{Operation}: no active employee matches caller {Caller}. "
                + "Add an organization_employee row with this email or employee_code.",
                operation, callerDisplayName);
            return null;
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex,
                "ExceptionCentre.{Operation}: caller->employee lookup failed for {Caller}.",
                operation, callerDisplayName);
            return null;
        }
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
