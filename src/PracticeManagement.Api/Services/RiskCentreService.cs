// =====================================================================
// RiskCentreService  (charter §5)
//
// Thin facade over grac_practice.sp_risk_candidate_* and
// sp_risk_register_* / sp_risk_analysis_* procs (migrations 169-172,
// 204-207).
//
// The Risk Centre is no longer a placeholder: migrations 204-207 added
// the Initial Risk Analysis and the Risk Register from the "Risk
// Candidate Analysis and Risk Register" BRD. This class stays a thin
// facade — every rule (mandatory fields, scoring, the analyse-before-
// register invariant) lives in the procedures, so the two entry routes
// cannot diverge in C# even if a future caller wants them to.
//
// Wire-up: RiskCentreServiceRegistration.cs
//     builder.Services.AddPracticeRiskCentreService();
// =====================================================================
using System.Data;
using System.Data.Common;
using Microsoft.Data.SqlClient;
using PracticeManagement.Api.Models;

namespace PracticeManagement.Api.Services;

public interface IRiskCentreService
{
    Task<RiskCandidateListResult> ListAsync(long organizationId, string? statusCode, int page, int pageSize, CancellationToken ct);
    Task<RiskCandidateDetail?>    GetAsync(long riskCandidateId, CancellationToken ct);
    Task<RiskActionResult>        AcceptAsync(long id, RiskAcceptRequest req, CancellationToken ct);
    Task<RiskActionResult>        RejectAsync(long id, RiskRejectRequest req, CancellationToken ct);
    Task<RiskActionResult>        WithdrawAsync(long id, RiskWithdrawRequest req, CancellationToken ct);
    Task<long>                    SaveAttachmentAsync(long id, string collectionMethodCode, string? evidenceTypeCode, string? fileName, string? contentType, byte[]? data, string? evidenceLocation, string? evidenceLocator, long? empId, string? caller, CancellationToken ct);
    Task<(byte[]? bytes, string? fileName, string? contentType)> GetAttachmentAsync(long attachmentId, CancellationToken ct);
    Task<IReadOnlyList<RiskAttachmentRow>> ListAttachmentsAsync(long id, CancellationToken ct);

    // ---- Risk Register (migrations 204-207) -------------------------
    Task<RiskScoringOptions>                 GetScoringOptionsAsync(long organizationId, CancellationToken ct);
    Task<RiskAnalysisSaveResult>             SaveAnalysisAsync(long? candidateId, long? organizationId, RiskAnalysisSaveRequest req, CancellationToken ct);
    Task<RiskAnalysisDetail?>                GetAnalysisAsync(long? candidateId, long? analysisId, CancellationToken ct);
    Task<IReadOnlyList<RiskAnalysisVersionRow>> GetAnalysisHistoryAsync(long candidateId, CancellationToken ct);
    Task<RiskRegisterActionResult>           AssignAsync(long candidateId, RiskCandidateAssignRequest req, CancellationToken ct);
    Task<RiskRegisterActionResult>           ClarifyAsync(long candidateId, RiskCandidateClarifyRequest req, CancellationToken ct);
    Task<RiskRegisterActionResult>           CloseDuplicateAsync(long candidateId, RiskCandidateDuplicateRequest req, CancellationToken ct);
    Task<RiskRegisterActionResult>           RegisterAsync(long candidateId, RiskRegisterRequest req, CancellationToken ct);
    Task<RiskRegisterActionResult>           CreateCustomRiskAsync(RiskCustomCreateRequest req, CancellationToken ct);
    Task<IReadOnlyList<RiskDuplicateMatch>>  CheckDuplicatesAsync(RiskDuplicateCheckRequest req, CancellationToken ct);
    Task<RiskRegisterListResult>             ListRegisterAsync(long organizationId, string? statusCode, string? sourceTypeCode, string? categoryCode, string? ratingCode, long? ownerEmployeeId, string? search, int page, int pageSize, bool? analysisPending, string? residualRatingCode, bool? residualPending, string? treatmentOptionCode, string? workflowStageCode, bool? reviewDue, CancellationToken ct);
    Task<RiskRegisterDetail?>                GetRegisterAsync(long riskRegisterId, CancellationToken ct);
    Task<RiskRegisterActionResult>           SetRegisterStatusAsync(long riskRegisterId, RiskRegisterStatusRequest req, CancellationToken ct);
    Task<RiskRegisterActionResult>           SetRegisterOwnerAsync(long riskRegisterId, RiskRegisterOwnerRequest req, CancellationToken ct);

    // ---- Phase B (migrations 208-211) -------------------------------
    Task<RiskConfigDetail?>                   GetConfigAsync(long organizationId, CancellationToken ct);
    Task<RiskConfigDetail?>                   SaveConfigAsync(long organizationId, RiskConfigSaveRequest req, CancellationToken ct);
    Task<RiskApprovalActionResult>            SubmitForApprovalAsync(long candidateId, RiskApprovalRequest req, CancellationToken ct);
    Task<RiskApprovalActionResult>            DecideApprovalAsync(long candidateId, RiskApprovalDecisionRequest req, CancellationToken ct);
    Task<RiskApprovalQueueResult>             ListApprovalQueueAsync(long organizationId, int page, int pageSize, CancellationToken ct);
    Task<RiskNotificationSweepResult>         SweepNotificationsAsync(long? organizationId, int sinceHours, int maxEvents, CancellationToken ct);
    Task<RiskNotificationListResult>          ListNotificationsAsync(long organizationId, string? statusCode, string? eventCode, string? subjectTypeCode, long? subjectRecordId, long? recipientEmployeeId, int page, int pageSize, CancellationToken ct);
    Task<RiskNotificationCounts>              GetNotificationCountsAsync(long organizationId, CancellationToken ct);
    Task<bool>                                MarkNotificationAsync(long notificationId, RiskNotificationMarkRequest req, CancellationToken ct);
    Task<RiskDashboard>                       GetDashboardAsync(long organizationId, int trendMonths, CancellationToken ct);
    Task<RiskAgeingListResult>                ListAgeingAsync(long organizationId, int minAgeDays, int page, int pageSize, CancellationToken ct);
    Task<RiskTreatmentTaskResult>             RaiseTreatmentTaskAsync(long riskRegisterId, RiskTreatmentTaskRequest req, CancellationToken ct);
    Task<IReadOnlyList<RiskRelatedWorkRow>>   ListTreatmentWorkAsync(long riskRegisterId, CancellationToken ct);

    // ---- Two-stage assessment (migration 216) -----------------------
    Task<RiskAssessmentOptions>               GetAssessmentOptionsAsync(long organizationId, CancellationToken ct);

    // ---- Organisation-owned threats / vulnerabilities (285, 286) ----
    Task<IReadOnlyList<RiskThreatItem>>        ListThreatsAsync(long organizationId, CancellationToken ct);
    Task<IReadOnlyList<RiskVulnerabilityItem>> ListVulnerabilitiesAsync(long organizationId, CancellationToken ct);
    Task<RiskThreatCreateResult>               CreateThreatAsync(long organizationId, string name, string? caller, CancellationToken ct);
    Task<RiskVulnerabilityCreateResult>        CreateVulnerabilityAsync(long organizationId, string name, string? caller, CancellationToken ct);
    Task<RiskThreatSelection>                  GetThreatSelectionAsync(long riskRegisterId, CancellationToken ct);
    Task<int>                                  SetThreatSelectionAsync(long organizationId, long? riskAnalysisId, long? riskRegisterId, IReadOnlyList<int>? threatIds, IReadOnlyList<int>? vulnerabilityIds, string? caller, CancellationToken ct);

    // ---- Risk Type: Confidentiality / Integrity / Availability (313, 314) --
    Task<IReadOnlyList<RiskTypeItem>>          ListRiskTypesAsync(long organizationId, CancellationToken ct);
    Task<RiskTypeSelection>                    GetRiskTypeSelectionAsync(long riskRegisterId, CancellationToken ct);
    Task<RiskTypeSelectionResult>              SetRiskTypeSelectionAsync(long organizationId, long? riskAnalysisId, long? riskRegisterId, IReadOnlyList<int>? riskTypeIds, string? caller, CancellationToken ct);

    // ---- Risk Category, multi-select (375, 376) ----------------------
    // No ListAsync here -- see the model file's header comment: the
    // options come from GetScoringOptionsAsync's Categories, which
    // already carries RiskCategoryId.
    Task<RiskCategorySelection>                GetRiskCategorySelectionAsync(long riskRegisterId, CancellationToken ct);
    Task<RiskCategorySelectionResult>          SetRiskCategorySelectionAsync(long organizationId, long? riskAnalysisId, long? riskRegisterId, IReadOnlyList<long>? riskCategoryIds, string? caller, CancellationToken ct);

    Task<RiskRegisterAssessResult>            AssessRegisteredRiskAsync(long riskRegisterId, RiskRegisterAssessRequest req, CancellationToken ct);
    Task<RiskApprovalActionResult>            DecideRegisterAnalysisAsync(long riskRegisterId, RiskApprovalDecisionRequest req, CancellationToken ct);

    // ---- Residual Risk Analysis (migration 258) ---------------------
    Task<RiskResidualSaveResult>              SaveResidualAnalysisAsync(long riskRegisterId, RiskResidualSaveRequest req, CancellationToken ct);
    Task<RiskResidualDetail?>                 GetResidualAnalysisAsync(long riskRegisterId, CancellationToken ct);
    Task<IReadOnlyList<RiskResidualVersionRow>> GetResidualHistoryAsync(long riskRegisterId, CancellationToken ct);

    // ---- Practice / Asset mapping (migrations 261, 262) -------------
    Task<RiskMappingDetail>                   GetMappingAsync(long riskRegisterId, CancellationToken ct);
    Task<RiskMappingOptions>                  GetMappingOptionsAsync(long riskRegisterId, string? search, int top, CancellationToken ct);
    Task<RiskPracticeMapResult>               MapPracticeAsync(long riskRegisterId, RiskPracticeMapRequest req, CancellationToken ct);
    Task<RiskPracticeUnmapResult>             UnmapPracticeAsync(long riskRegisterId, long practiceId, long? actorEmployeeId, string? caller, CancellationToken ct);
    // Migration 284 -- "Existing Controls" on the risk analysis page.
    Task<RiskScopePracticeContextResult>      GetScopePracticeContextAsync(long organizationId, long riskRegisterId, CancellationToken ct);
    Task<RiskDependencyMapResult>             MapDependencyAsync(long riskRegisterId, RiskDependencyMapRequest req, CancellationToken ct);
    Task<RiskDependencyUnmapResult>           UnmapDependencyAsync(long riskRegisterId, int dependencyTypeId, long dependencyObjectId, long? actorEmployeeId, string? caller, CancellationToken ct);

    // ---- Treatment Option (migrations 261, 263) ---------------------
    Task<RiskTreatmentOptionResult>           SetTreatmentOptionAsync(long riskRegisterId, RiskTreatmentOptionRequest req, CancellationToken ct);
    Task<RiskTreatmentState?>                 GetTreatmentStateAsync(long riskRegisterId, CancellationToken ct);
    Task<int>                                 SyncTreatmentAsync(long? riskRegisterId, long? organizationId, string? caller, CancellationToken ct);

    // ---- Acceptance, Review, Calendar (migration 264) ---------------
    Task<RiskAcceptanceDetail?>               GetAcceptanceAsync(long riskRegisterId, CancellationToken ct);
    Task<RiskAcceptanceResult>                SaveAcceptanceAsync(long riskRegisterId, RiskAcceptanceSaveRequest req, CancellationToken ct);
    Task<RiskReviewDueListResult>             ListReviewDueAsync(long organizationId, long? ownerEmployeeId, string? ratingCode, string? search, int? includeFutureDays, int page, int pageSize, CancellationToken ct);
    Task<IReadOnlyList<RiskCalendarEventRow>> GetReviewCalendarAsync(long organizationId, DateTime? fromDate, DateTime? toDate, long? ownerEmployeeId, CancellationToken ct);
    Task<RiskReviewPerformResult>             PerformReviewAsync(long riskRegisterId, RiskReviewPerformRequest req, CancellationToken ct);

    // Review frequency lookup (293). Global, not org-scoped:
    // frequency_master is a master table, the same list the practice
    // instance and the organisation committee already choose from.
    Task<IReadOnlyList<RiskReviewFrequencyRow>> ListReviewFrequenciesAsync(CancellationToken ct);

    // Bulk review (270). Deliberately NOT PerformReviewAsync over a list:
    // that one is a re-assessment and needs per-risk scores. See
    // RiskBulkReviewRequest.
    Task<RiskBulkReviewResult>                BulkReviewAsync(RiskBulkReviewRequest req, CancellationToken ct);

    // Bulk accept (295). Deliberately NOT BulkReviewAsync with StatusCode
    // "Accepted": that stamps a review. See RiskBulkAcceptRequest.
    Task<RiskBulkAcceptResult>                BulkAcceptAsync(RiskBulkAcceptRequest req, CancellationToken ct);

    // Risk acceptance approval authority (271). Org-scoped configuration,
    // reached from Organization -> Risk Acceptance Approval Authority.
    Task<RiskAcceptanceAuthorityResult>       GetAcceptanceAuthorityAsync(long organizationId, CancellationToken ct);
    Task<RiskAcceptanceAuthorityResult>       SaveAcceptanceAuthorityAsync(RiskAcceptanceAuthoritySaveRequest req, CancellationToken ct);
    Task<RiskAcceptanceAuthorityResolved?>    ResolveAcceptanceAuthorityAsync(long riskRegisterId, string? scopeCode, CancellationToken ct);
}

public sealed class RiskCentreService(IConfiguration configuration, ILogger<RiskCentreService> logger) : IRiskCentreService
{
    public async Task<RiskCandidateListResult> ListAsync(long organizationId, string? statusCode, int page, int pageSize, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_candidate_list");
        AddParam(cmd, "@organization_id", DbType.Int64,  organizationId);
        AddParam(cmd, "@status_code",     DbType.String, (object?)statusCode ?? DBNull.Value, 30);
        AddParam(cmd, "@page_number",     DbType.Int32,  Math.Max(1, page));
        AddParam(cmd, "@page_size",       DbType.Int32,  Math.Clamp(pageSize <= 0 ? 25 : pageSize, 1, 200));

        var rows = new List<RiskCandidateRow>();
        long total = 0;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new RiskCandidateRow(
                Convert.ToInt64(r["RiskCandidateId"]),
                Convert.ToInt64(r["OrganizationId"]),
                r["CustomGapId"] as long?,
                r["GapTitle"] as string,
                r["CandidateTitle"]?.ToString() ?? "",
                r["SeverityCode"] as string,
                r["StatusCode"]?.ToString() ?? "",
                Convert.ToDateTime(r["RequestedOn"]),
                r["RequestedByName"] as string,
                r["AcceptedOn"] as DateTime?,
                r["AcceptedByName"] as string,
                r["RejectedOn"] as DateTime?,
                r["RejectedByName"] as string,
                r["FormalRiskRef"] as string,
                Convert.ToInt32(r["AttachmentCount"]),
                r["CandidateNumber"] as string,
                r["SourceTypeCode"] as string,
                r["SourceName"] as string,
                r["SourceRecordId"] as long?,
                r["SourceReference"] as string,
                r["SourceCentreCode"] as string,
                r["IdentifiedOn"] as DateTime?,
                r["AssignedAnalystEmployeeId"] as long?,
                r["AssignedAnalystName"] as string,
                r["RegisteredRiskId"] as long?,
                r["RegisteredRiskNumber"] as string,
                r["DuplicateOfRiskId"] as long?,
                r["CurrentAnalysisId"] as long?,
                r["CurrentAnalysisVersion"] as int?,
                r["InherentRatingCode"] as string));
            total = Convert.ToInt64(r["TotalRows"]);
        }
        return new RiskCandidateListResult(total, page, pageSize, rows);
    }

    public async Task<RiskCandidateDetail?> GetAsync(long id, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_candidate_get");
        AddParam(cmd, "@risk_candidate_id", DbType.Int64, id);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        return new RiskCandidateDetail(
            Convert.ToInt64(r["RiskCandidateId"]),
            Convert.ToInt64(r["OrganizationId"]),
            r["CustomGapId"] as long?,
            r["GapTitle"] as string,
            r["CandidateTitle"]?.ToString() ?? "",
            r["CandidateSummary"] as string,
            r["SeverityCode"] as string,
            r["SeverityName"] as string,
            r["ImpactSummary"] as string,
            r["LikelihoodSummary"] as string,
            r["StatusCode"]?.ToString() ?? "",
            r["RequestedByEmployeeId"] as long?,
            r["RequestedByName"] as string,
            Convert.ToDateTime(r["RequestedOn"]),
            r["AcceptedByEmployeeId"] as long?,
            r["AcceptedByName"] as string,
            r["AcceptedOn"] as DateTime?,
            r["AcceptanceNote"] as string,
            r["FormalRiskRef"] as string,
            r["RejectedByEmployeeId"] as long?,
            r["RejectedByName"] as string,
            r["RejectedOn"] as DateTime?,
            r["RejectionReason"] as string,
            r["CandidateNumber"] as string,
            r["SourceTypeCode"] as string,
            r["SourceName"] as string,
            r["SourceRecordId"] as long?,
            r["SourceReference"] as string,
            r["SourceDescription"] as string,
            r["SourceCentreCode"] as string,
            r["IdentifiedOn"] as DateTime?,
            r["BusinessUnit"] as string,
            r["AssignedAnalystEmployeeId"] as long?,
            r["AssignedAnalystName"] as string,
            r["ClarificationNote"] as string,
            r["ClarificationRequestedOn"] as DateTime?,
            r["RegisteredRiskId"] as long?,
            r["RegisteredRiskNumber"] as string,
            r["DuplicateOfRiskId"] as long?,
            r["DuplicateOfRiskNumber"] as string,
            r["CurrentAnalysisId"] as long?,
            r["CurrentAnalysisVersion"] as int?,
            r["InherentRatingCode"] as string);
    }

    public async Task<RiskActionResult> AcceptAsync(long id, RiskAcceptRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.AcceptedByEmployeeId is null or <= 0)
            return new RiskActionResult(false, id, null, "acceptedByEmployeeId is required.");
        if (string.IsNullOrWhiteSpace(req.AcceptanceNote))
            return new RiskActionResult(false, id, null, "acceptanceNote is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_candidate_accept");
            AddParam(cmd, "@risk_candidate_id",       DbType.Int64,  id);
            AddParam(cmd, "@acceptance_note",         DbType.String, req.AcceptanceNote, -1);
            AddParam(cmd, "@accepted_by_employee_id", DbType.Int64,  req.AcceptedByEmployeeId!.Value);
            AddParam(cmd, "@formal_risk_ref",         DbType.String, (object?)req.FormalRiskRef ?? DBNull.Value, 200);
            AddParam(cmd, "@caller_display_name",     DbType.String, req.CallerDisplayName ?? "system", 100);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskActionResult(true, Convert.ToInt64(r["RiskCandidateId"]), r["StatusCode"]?.ToString(), null);
            return new RiskActionResult(true, id, "Accepted", null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.Accept failed {Id}: {Msg}", id, ex.Message);
            return new RiskActionResult(false, id, null, ex.Message);
        }
    }

    public async Task<RiskActionResult> RejectAsync(long id, RiskRejectRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.RejectedByEmployeeId is null or <= 0)
            return new RiskActionResult(false, id, null, "rejectedByEmployeeId is required.");
        if (string.IsNullOrWhiteSpace(req.RejectionReason))
            return new RiskActionResult(false, id, null, "rejectionReason is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_candidate_reject");
            AddParam(cmd, "@risk_candidate_id",       DbType.Int64,  id);
            AddParam(cmd, "@rejection_reason",        DbType.String, req.RejectionReason, -1);
            AddParam(cmd, "@rejected_by_employee_id", DbType.Int64,  req.RejectedByEmployeeId!.Value);
            AddParam(cmd, "@caller_display_name",     DbType.String, req.CallerDisplayName ?? "system", 100);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskActionResult(true, Convert.ToInt64(r["RiskCandidateId"]), r["StatusCode"]?.ToString(), null);
            return new RiskActionResult(true, id, "Rejected", null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.Reject failed {Id}: {Msg}", id, ex.Message);
            return new RiskActionResult(false, id, null, ex.Message);
        }
    }

    public async Task<RiskActionResult> WithdrawAsync(long id, RiskWithdrawRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_candidate_withdraw");
            AddParam(cmd, "@risk_candidate_id",   DbType.Int64,  id);
            AddParam(cmd, "@withdraw_reason",     DbType.String, (object?)req.WithdrawReason ?? DBNull.Value, -1);
            AddParam(cmd, "@actor_employee_id",   DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, req.CallerDisplayName ?? "system", 100);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskActionResult(true, Convert.ToInt64(r["RiskCandidateId"]), r["StatusCode"]?.ToString(), null);
            return new RiskActionResult(true, id, "Withdrawn", null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.Withdraw failed {Id}: {Msg}", id, ex.Message);
            return new RiskActionResult(false, id, null, ex.Message);
        }
    }

    public async Task<long> SaveAttachmentAsync(long id, string collectionMethodCode, string? evidenceTypeCode,
                                                string? fileName, string? contentType, byte[]? data,
                                                string? evidenceLocation, string? evidenceLocator,
                                                long? empId, string? caller, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_candidate_attachment_save");
        AddParam(cmd, "@risk_candidate_id",       DbType.Int64,  id);
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
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_candidate_attachment_get");
        AddParam(cmd, "@attachment_id", DbType.Int64, attachmentId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return (null, null, null);
        return ((byte[])r["FileData"], r["FileName"]?.ToString(), r["ContentType"] as string);
    }

    public async Task<IReadOnlyList<RiskAttachmentRow>> ListAttachmentsAsync(long id, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_candidate_attachment_list");
        AddParam(cmd, "@risk_candidate_id", DbType.Int64, id);
        var rows = new List<RiskAttachmentRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new RiskAttachmentRow(
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

    // =================================================================
    // Risk Register (migrations 204-207)
    //
    // Every method here is a call-and-map. The BRD rules are enforced in
    // SQL, so a SqlException carrying a 560xx message IS the validation
    // failure and is surfaced verbatim rather than re-worded — the proc
    // messages name the BRD clause they enforce, and losing that in
    // translation would make a rejected registration hard to explain.
    // =================================================================

    public async Task<RiskScoringOptions> GetScoringOptionsAsync(long organizationId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_scoring_options_get");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);

        var likelihood = new List<RiskScaleLevel>();
        var impact     = new List<RiskScaleLevel>();
        var categories = new List<RiskCategoryOption>();
        var sources    = new List<RiskSourceOption>();
        var matrix     = new List<RiskMatrixCell>();

        await using var r = await cmd.ExecuteReaderAsync(ct);

        // Result sets are positional — see sp_risk_scoring_options_get.
        while (await r.ReadAsync(ct))
            likelihood.Add(new RiskScaleLevel(
                r["LikelihoodCode"]?.ToString() ?? "", r["LikelihoodName"]?.ToString() ?? "",
                Convert.ToInt32(r["LevelValue"]), r["Descriptor"] as string));

        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                impact.Add(new RiskScaleLevel(
                    r["ImpactCode"]?.ToString() ?? "", r["ImpactName"]?.ToString() ?? "",
                    Convert.ToInt32(r["LevelValue"]), r["Descriptor"] as string));

        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                categories.Add(new RiskCategoryOption(
                    r["CategoryCode"]?.ToString() ?? "", r["CategoryName"]?.ToString() ?? "",
                    r["Description"] as string, Convert.ToInt64(r["RiskCategoryId"])));

        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                sources.Add(new RiskSourceOption(
                    r["SourceTypeCode"]?.ToString() ?? "", r["SourceName"]?.ToString() ?? "",
                    r["Description"] as string, r["SourceCentreCode"] as string));

        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                matrix.Add(new RiskMatrixCell(
                    Convert.ToInt32(r["LikelihoodValue"]), Convert.ToInt32(r["ImpactValue"]),
                    r["RatingCode"]?.ToString() ?? "", r["RatingName"]?.ToString() ?? "",
                    r["RatingScore"] as int?, r["ColourHex"] as string));

        return new RiskScoringOptions(likelihood, impact, categories, sources, matrix);
    }

    public async Task<RiskAnalysisSaveResult> SaveAnalysisAsync(
        long? candidateId, long? organizationId, RiskAnalysisSaveRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (string.IsNullOrWhiteSpace(req.RiskStatement))
            return new RiskAnalysisSaveResult(false, 0, 0, null, null, null, "riskStatement is required.");
        if (candidateId is null && organizationId is null)
            return new RiskAnalysisSaveResult(false, 0, 0, null, null, null, "riskCandidateId or organizationId is required.");

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_analysis_save");
            AddParam(cmd, "@risk_candidate_id",       DbType.Int64,  (object?)candidateId ?? DBNull.Value);
            AddParam(cmd, "@organization_id",         DbType.Int64,  (object?)organizationId ?? DBNull.Value);
            AddParam(cmd, "@risk_statement",          DbType.String, req.RiskStatement, 1000);
            AddParam(cmd, "@risk_category_code",      DbType.String, (object?)req.RiskCategoryCode ?? DBNull.Value, 60);
            AddParam(cmd, "@risk_description",        DbType.String, (object?)req.RiskDescription ?? DBNull.Value, -1);
            AddParam(cmd, "@risk_cause",              DbType.String, (object?)req.RiskCause ?? DBNull.Value, -1);
            AddParam(cmd, "@potential_consequence",   DbType.String, (object?)req.PotentialConsequence ?? DBNull.Value, -1);
            AddParam(cmd, "@existing_controls",       DbType.String, (object?)req.ExistingControls ?? DBNull.Value, -1);
            AddParam(cmd, "@likelihood_code",         DbType.String, (object?)req.LikelihoodCode ?? DBNull.Value, 60);
            AddParam(cmd, "@impact_code",             DbType.String, (object?)req.ImpactCode ?? DBNull.Value, 60);
            AddParam(cmd, "@risk_owner_employee_id",  DbType.Int64,  (object?)req.RiskOwnerEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@business_unit",           DbType.String, (object?)req.BusinessUnit ?? DBNull.Value, 200);
            AddParam(cmd, "@process_name",            DbType.String, (object?)req.ProcessName ?? DBNull.Value, 200);
            AddParam(cmd, "@analyst_remarks",         DbType.String, (object?)req.AnalystRemarks ?? DBNull.Value, -1);
            AddParam(cmd, "@analysed_by_employee_id", DbType.Int64,  (object?)req.AnalysedByEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",     DbType.String, req.CallerDisplayName ?? "system", 100);
            AddParam(cmd, "@threat_id",               DbType.Int32,  (object?)req.ThreatId ?? DBNull.Value);
            AddParam(cmd, "@threat_description",      DbType.String, (object?)req.ThreatDescription ?? DBNull.Value, -1);
            AddParam(cmd, "@vulnerability_id",        DbType.Int32,  (object?)req.VulnerabilityId ?? DBNull.Value);
            AddParam(cmd, "@vulnerability_description", DbType.String, (object?)req.VulnerabilityDescription ?? DBNull.Value, -1);
            AddParam(cmd, "@business_function_id",    DbType.Int64,  (object?)req.BusinessFunctionId ?? DBNull.Value);
            var outId  = AddOutput(cmd, "@risk_analysis_id", DbType.Int64);
            var outVer = AddOutput(cmd, "@analysis_version", DbType.Int32);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            string? ratingCode = null, ratingName = null; int? ratingScore = null;
            if (await r.ReadAsync(ct))
            {
                ratingCode  = r["InherentRatingCode"] as string;
                ratingName  = r["InherentRatingName"] as string;
                ratingScore = r["InherentRatingScore"] as int?;
            }
            // Output parameters are only populated once the reader is done.
            await r.CloseAsync();

            return new RiskAnalysisSaveResult(true,
                outId.Value  is long id  ? id  : 0,
                outVer.Value is int  ver ? ver : 0,
                ratingCode, ratingName, ratingScore, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.SaveAnalysis failed {Id}: {Msg}", candidateId, ex.Message);
            return new RiskAnalysisSaveResult(false, 0, 0, null, null, null, ex.Message);
        }
    }

    public async Task<RiskAnalysisDetail?> GetAnalysisAsync(long? candidateId, long? analysisId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_analysis_get");
        AddParam(cmd, "@risk_candidate_id", DbType.Int64, (object?)candidateId ?? DBNull.Value);
        AddParam(cmd, "@risk_analysis_id",  DbType.Int64, (object?)analysisId ?? DBNull.Value);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        return new RiskAnalysisDetail(
            Convert.ToInt64(r["RiskAnalysisId"]),
            Convert.ToInt64(r["OrganizationId"]),
            r["AnalysisScopeCode"]?.ToString() ?? "Candidate",
            r["RiskCandidateId"] as long?,
            r["RiskRegisterId"] as long?,
            Convert.ToInt32(r["AnalysisVersion"]),
            Convert.ToBoolean(r["IsCurrent"]),
            r["RiskStatement"]?.ToString() ?? "",
            r["RiskCategoryCode"] as string,
            r["RiskCategoryName"] as string,
            r["RiskDescription"] as string,
            r["RiskCause"] as string,
            r["PotentialConsequence"] as string,
            r["ExistingControls"] as string,
            r["LikelihoodCode"] as string,
            r["LikelihoodName"] as string,
            r["LikelihoodValue"] as int?,
            r["ImpactCode"] as string,
            r["ImpactName"] as string,
            r["ImpactValue"] as int?,
            r["InherentRatingCode"] as string,
            r["InherentRatingName"] as string,
            r["InherentRatingScore"] as int?,
            r["RiskOwnerEmployeeId"] as long?,
            r["RiskOwnerName"] as string,
            r["BusinessUnit"] as string,
            r["ProcessName"] as string,
            r["AnalystRemarks"] as string,
            Convert.ToDateTime(r["AnalysisOn"]),
            r["AnalysedByEmployeeId"] as long?,
            r["AnalysedByName"] as string,
            r["DecisionCode"] as string,
            r["DecisionNote"] as string,
            r["DecisionOn"] as DateTime?,
            r["ApprovalStatusCode"] as string,
            r["ThreatId"] as int?,
            r["ThreatName"] as string,
            r["ThreatDescription"] as string,
            r["VulnerabilityId"] as int?,
            r["VulnerabilityName"] as string,
            r["VulnerabilityDescription"] as string,
            r["BusinessFunctionId"] as long?,
            r["BusinessFunctionName"] as string);
    }

    public async Task<IReadOnlyList<RiskAnalysisVersionRow>> GetAnalysisHistoryAsync(long candidateId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_analysis_history");
        AddParam(cmd, "@risk_candidate_id", DbType.Int64, candidateId);
        var rows = new List<RiskAnalysisVersionRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new RiskAnalysisVersionRow(
                Convert.ToInt64(r["RiskAnalysisId"]),
                Convert.ToInt32(r["AnalysisVersion"]),
                Convert.ToBoolean(r["IsCurrent"]),
                r["RiskStatement"]?.ToString() ?? "",
                r["LikelihoodName"] as string,
                r["ImpactName"] as string,
                r["InherentRatingCode"] as string,
                r["InherentRatingScore"] as int?,
                r["DecisionCode"] as string,
                Convert.ToDateTime(r["AnalysisOn"]),
                r["AnalysedByName"] as string,
                r["AnalystRemarks"] as string));
        return rows;
    }

    public Task<RiskRegisterActionResult> AssignAsync(long candidateId, RiskCandidateAssignRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.AnalystEmployeeId is null or <= 0)
            return Task.FromResult(new RiskRegisterActionResult(false, candidateId, null, null, null, "analystEmployeeId is required."));
        return CandidateActionAsync(candidateId, "grac_practice.sp_risk_candidate_assign", cmd =>
        {
            AddParam(cmd, "@risk_candidate_id",   DbType.Int64,  candidateId);
            AddParam(cmd, "@analyst_employee_id", DbType.Int64,  req.AnalystEmployeeId!.Value);
            AddParam(cmd, "@remark",              DbType.String, (object?)req.Remark ?? DBNull.Value, -1);
            AddParam(cmd, "@actor_employee_id",   DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, req.CallerDisplayName ?? "system", 100);
        }, ct);
    }

    public Task<RiskRegisterActionResult> ClarifyAsync(long candidateId, RiskCandidateClarifyRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (string.IsNullOrWhiteSpace(req.ClarificationNote))
            return Task.FromResult(new RiskRegisterActionResult(false, candidateId, null, null, null, "clarificationNote is required."));
        return CandidateActionAsync(candidateId, "grac_practice.sp_risk_candidate_clarify", cmd =>
        {
            AddParam(cmd, "@risk_candidate_id",   DbType.Int64,  candidateId);
            AddParam(cmd, "@clarification_note",  DbType.String, req.ClarificationNote, -1);
            AddParam(cmd, "@actor_employee_id",   DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, req.CallerDisplayName ?? "system", 100);
        }, ct);
    }

    public Task<RiskRegisterActionResult> CloseDuplicateAsync(long candidateId, RiskCandidateDuplicateRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.DuplicateOfRiskId is null or <= 0)
            return Task.FromResult(new RiskRegisterActionResult(false, candidateId, null, null, null, "duplicateOfRiskId is required."));
        return CandidateActionAsync(candidateId, "grac_practice.sp_risk_candidate_close_duplicate", cmd =>
        {
            AddParam(cmd, "@risk_candidate_id",    DbType.Int64,  candidateId);
            AddParam(cmd, "@duplicate_of_risk_id", DbType.Int64,  req.DuplicateOfRiskId!.Value);
            AddParam(cmd, "@remark",               DbType.String, (object?)req.Remark ?? DBNull.Value, -1);
            AddParam(cmd, "@actor_employee_id",    DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",  DbType.String, req.CallerDisplayName ?? "system", 100);
        }, ct);
    }

    public Task<RiskRegisterActionResult> RegisterAsync(long candidateId, RiskRegisterRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        return CandidateActionAsync(candidateId, "grac_practice.sp_risk_candidate_register", cmd =>
        {
            AddParam(cmd, "@risk_candidate_id",         DbType.Int64,  candidateId);
            AddParam(cmd, "@risk_title",                DbType.String, (object?)req.RiskTitle ?? DBNull.Value, 300);
            AddParam(cmd, "@registration_note",         DbType.String, (object?)req.RegistrationNote ?? DBNull.Value, -1);
            AddParam(cmd, "@registered_by_employee_id", DbType.Int64,  (object?)req.RegisteredByEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@linked_asset_id",           DbType.Int64,  (object?)req.LinkedAssetId ?? DBNull.Value);
            AddParam(cmd, "@linked_vendor_id",          DbType.Int64,  (object?)req.LinkedVendorId ?? DBNull.Value);
            AddParam(cmd, "@linked_practice_id",        DbType.Int64,  (object?)req.LinkedPracticeId ?? DBNull.Value);
            AddParam(cmd, "@linked_obligation_id",      DbType.Int64,  (object?)req.LinkedObligationId ?? DBNull.Value);
            AddParam(cmd, "@linked_control_id",         DbType.Int64,  (object?)req.LinkedControlId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",       DbType.String, req.CallerDisplayName ?? "system", 100);
        }, ct);
    }

    public Task<RiskRegisterActionResult> CreateCustomRiskAsync(RiskCustomCreateRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.OrganizationId <= 0)
            return Task.FromResult(new RiskRegisterActionResult(false, null, null, null, null, "organizationId is required."));
        if (string.IsNullOrWhiteSpace(req.RiskTitle))
            return Task.FromResult(new RiskRegisterActionResult(false, null, null, null, null, "riskTitle is required."));
        if (string.IsNullOrWhiteSpace(req.RiskStatement))
            return Task.FromResult(new RiskRegisterActionResult(false, null, null, null, null, "riskStatement is required."));

        return CandidateActionAsync(null, "grac_practice.sp_risk_custom_create", cmd =>
        {
            AddParam(cmd, "@organization_id",        DbType.Int64,  req.OrganizationId);
            AddParam(cmd, "@risk_title",             DbType.String, req.RiskTitle, 300);
            AddParam(cmd, "@risk_statement",         DbType.String, req.RiskStatement, 1000);
            AddParam(cmd, "@risk_category_code",     DbType.String, (object?)req.RiskCategoryCode ?? DBNull.Value, 60);
            AddParam(cmd, "@likelihood_code",        DbType.String, (object?)req.LikelihoodCode ?? DBNull.Value, 60);
            AddParam(cmd, "@impact_code",            DbType.String, (object?)req.ImpactCode ?? DBNull.Value, 60);
            AddParam(cmd, "@risk_owner_employee_id", DbType.Int64,  (object?)req.RiskOwnerEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@risk_description",       DbType.String, (object?)req.RiskDescription ?? DBNull.Value, -1);
            AddParam(cmd, "@risk_cause",             DbType.String, (object?)req.RiskCause ?? DBNull.Value, -1);
            AddParam(cmd, "@potential_consequence",  DbType.String, (object?)req.PotentialConsequence ?? DBNull.Value, -1);
            AddParam(cmd, "@existing_controls",      DbType.String, (object?)req.ExistingControls ?? DBNull.Value, -1);
            AddParam(cmd, "@business_unit",          DbType.String, (object?)req.BusinessUnit ?? DBNull.Value, 200);
            AddParam(cmd, "@process_name",           DbType.String, (object?)req.ProcessName ?? DBNull.Value, 200);
            AddParam(cmd, "@analyst_remarks",        DbType.String, (object?)req.AnalystRemarks ?? DBNull.Value, -1);
            AddParam(cmd, "@linked_asset_id",        DbType.Int64,  (object?)req.LinkedAssetId ?? DBNull.Value);
            AddParam(cmd, "@linked_vendor_id",       DbType.Int64,  (object?)req.LinkedVendorId ?? DBNull.Value);
            AddParam(cmd, "@linked_practice_id",     DbType.Int64,  (object?)req.LinkedPracticeId ?? DBNull.Value);
            AddParam(cmd, "@linked_obligation_id",   DbType.Int64,  (object?)req.LinkedObligationId ?? DBNull.Value);
            AddParam(cmd, "@linked_control_id",      DbType.Int64,  (object?)req.LinkedControlId ?? DBNull.Value);
            AddParam(cmd, "@created_by_employee_id", DbType.Int64,  (object?)req.CreatedByEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",    DbType.String, req.CallerDisplayName ?? "system", 100);
            // ---- stage 1 (migration 216) --------------------------------
            // 216 added these five parameters to sp_risk_custom_create and
            // made threat / vulnerability / owner mandatory in
            // sp_risk_register_insert, but this call site was never
            // extended. Every parameter carries a NULL default, so the
            // call still succeeded -- it just wrote risk_analysis with
            // threat_id = NULL, and the register insert then threw
            // 56410 "assessment is incomplete - a threat is required."
            // The screen and RiskCustomCreateRequest have been sending
            // these values the whole time; only the bridge was missing.
            AddParam(cmd, "@threat_id",                 DbType.Int32,  (object?)req.ThreatId ?? DBNull.Value);
            AddParam(cmd, "@threat_description",        DbType.String, (object?)req.ThreatDescription ?? DBNull.Value, -1);
            AddParam(cmd, "@vulnerability_id",          DbType.Int32,  (object?)req.VulnerabilityId ?? DBNull.Value);
            AddParam(cmd, "@vulnerability_description", DbType.String, (object?)req.VulnerabilityDescription ?? DBNull.Value, -1);
            AddParam(cmd, "@business_function_id",      DbType.Int64,  (object?)req.BusinessFunctionId ?? DBNull.Value);
        }, ct);
    }

    public async Task<IReadOnlyList<RiskDuplicateMatch>> CheckDuplicatesAsync(RiskDuplicateCheckRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_duplicate_check");
        AddParam(cmd, "@organization_id",    DbType.Int64,  req.OrganizationId);
        AddParam(cmd, "@risk_title",         DbType.String, (object?)req.RiskTitle ?? DBNull.Value, 300);
        AddParam(cmd, "@risk_statement",     DbType.String, (object?)req.RiskStatement ?? DBNull.Value, 1000);
        AddParam(cmd, "@risk_category_code", DbType.String, (object?)req.RiskCategoryCode ?? DBNull.Value, 60);
        AddParam(cmd, "@source_type_code",   DbType.String, (object?)req.SourceTypeCode ?? DBNull.Value, 40);
        AddParam(cmd, "@source_record_id",   DbType.Int64,  (object?)req.SourceRecordId ?? DBNull.Value);
        AddParam(cmd, "@business_unit",      DbType.String, (object?)req.BusinessUnit ?? DBNull.Value, 200);
        AddParam(cmd, "@exclude_risk_id",    DbType.Int64,  (object?)req.ExcludeRiskId ?? DBNull.Value);
        AddParam(cmd, "@min_score",          DbType.Int32,  (object?)req.MinScore ?? DBNull.Value);

        var rows = new List<RiskDuplicateMatch>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new RiskDuplicateMatch(
                Convert.ToInt64(r["RiskRegisterId"]),
                r["RiskNumber"]?.ToString() ?? "",
                r["RiskTitle"]?.ToString() ?? "",
                r["RiskStatement"] as string,
                r["RiskCategoryName"] as string,
                r["SourceTypeCode"] as string,
                r["SourceReference"] as string,
                r["StatusCode"]?.ToString() ?? "",
                r["InherentRatingCode"] as string,
                Convert.ToDateTime(r["RegisteredOn"]),
                r["RiskOwnerName"] as string,
                Convert.ToInt32(r["MatchScore"]),
                r["MatchReason"] as string));
        return rows;
    }

    public async Task<RiskRegisterListResult> ListRegisterAsync(
        long organizationId, string? statusCode, string? sourceTypeCode, string? categoryCode,
        string? ratingCode, long? ownerEmployeeId, string? search, int page, int pageSize,
        bool? analysisPending, string? residualRatingCode, bool? residualPending,
        string? treatmentOptionCode, string? workflowStageCode, bool? reviewDue,
        CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_register_list");
        AddParam(cmd, "@organization_id",   DbType.Int64,  organizationId);
        AddParam(cmd, "@status_code",       DbType.String, (object?)statusCode ?? DBNull.Value, 30);
        AddParam(cmd, "@source_type_code",  DbType.String, (object?)sourceTypeCode ?? DBNull.Value, 40);
        AddParam(cmd, "@category_code",     DbType.String, (object?)categoryCode ?? DBNull.Value, 60);
        AddParam(cmd, "@rating_code",       DbType.String, (object?)ratingCode ?? DBNull.Value, 30);
        AddParam(cmd, "@owner_employee_id", DbType.Int64,  (object?)ownerEmployeeId ?? DBNull.Value);
        AddParam(cmd, "@search",            DbType.String, (object?)search ?? DBNull.Value, 200);
        AddParam(cmd, "@page_number",       DbType.Int32,  Math.Max(1, page));
        AddParam(cmd, "@page_size",         DbType.Int32,  Math.Clamp(pageSize <= 0 ? 25 : pageSize, 1, 200));
        // The screen has offered an "Analysis pending" filter since 216
        // and sends analysisPending on every register fetch, but nothing
        // between the query string and here ever carried it -- so the
        // control silently did nothing. Sent only when the proc declares
        // it, so a database still on 206 is not handed a parameter it
        // does not have (which is the "too many arguments" failure mode).
        if (analysisPending.HasValue
            && await Infrastructure.ProcParameterProbe.HasParameterAsync(
                   conn, "sp_risk_register_list", "@analysis_pending", ct))
        {
            AddParam(cmd, "@analysis_pending", DbType.Boolean, analysisPending.Value);
        }

        // Same probe, same reason (migration 258). A database still on
        // 216 has no @residual_rating_code / @residual_pending, and
        // sending one it does not declare is the "too many arguments"
        // failure the analysisPending guard above already exists to
        // avoid. Probed independently of each other so a partially
        // applied 258 degrades one filter, not both.
        if (!string.IsNullOrWhiteSpace(residualRatingCode)
            && await Infrastructure.ProcParameterProbe.HasParameterAsync(
                   conn, "sp_risk_register_list", "@residual_rating_code", ct))
        {
            AddParam(cmd, "@residual_rating_code", DbType.String, residualRatingCode, 30);
        }
        if (residualPending.HasValue
            && await Infrastructure.ProcParameterProbe.HasParameterAsync(
                   conn, "sp_risk_register_list", "@residual_pending", ct))
        {
            AddParam(cmd, "@residual_pending", DbType.Boolean, residualPending.Value);
        }

        // Same probe again, same reason (migration 264). A database on
        // 258 has none of these three, and each is probed independently
        // so a partially applied 264 degrades one filter rather than
        // failing the whole list with "too many arguments".
        if (!string.IsNullOrWhiteSpace(treatmentOptionCode)
            && await Infrastructure.ProcParameterProbe.HasParameterAsync(
                   conn, "sp_risk_register_list", "@treatment_option_code", ct))
        {
            AddParam(cmd, "@treatment_option_code", DbType.String, treatmentOptionCode, 30);
        }
        if (!string.IsNullOrWhiteSpace(workflowStageCode)
            && await Infrastructure.ProcParameterProbe.HasParameterAsync(
                   conn, "sp_risk_register_list", "@workflow_stage_code", ct))
        {
            AddParam(cmd, "@workflow_stage_code", DbType.String, workflowStageCode, 30);
        }
        if (reviewDue.HasValue
            && await Infrastructure.ProcParameterProbe.HasParameterAsync(
                   conn, "sp_risk_register_list", "@review_due", ct))
        {
            AddParam(cmd, "@review_due", DbType.Boolean, reviewDue.Value);
        }

        var rows = new List<RiskRegisterRow>();
        long total = 0;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new RiskRegisterRow(
                Convert.ToInt64(r["RiskRegisterId"]),
                r["RiskNumber"]?.ToString() ?? "",
                Convert.ToInt64(r["OrganizationId"]),
                r["RiskTitle"]?.ToString() ?? "",
                r["RiskStatement"] as string,
                r["RiskCategoryCode"] as string,
                r["RiskCategoryName"] as string,
                r["SourceTypeCode"]?.ToString() ?? "",
                r["SourceRecordId"] as long?,
                r["SourceReference"] as string,
                r["SourceCentreCode"] as string,
                r["RiskCandidateId"] as long?,
                // NOT NULL by schema (BRD 24.1), but a DBNull here would
                // throw InvalidCast and take the whole list down rather
                // than one row -- and the failure would arrive on screen
                // as "no risks match these filters".
                r["RiskAnalysisId"] == DBNull.Value ? 0L : Convert.ToInt64(r["RiskAnalysisId"]),
                r["RiskOwnerEmployeeId"] as long?,
                r["RiskOwnerName"] as string,
                r["BusinessUnit"] as string,
                r["LikelihoodName"] as string,
                r["ImpactName"] as string,
                r["InherentRatingCode"] as string,
                r["InherentRatingName"] as string,
                r["InherentRatingScore"] as int?,
                r["StatusCode"]?.ToString() ?? "",
                Convert.ToDateTime(r["RegisteredOn"]),
                r["RegisteredByName"] as string,
                // The four 216 columns, read defensively. On a database
                // still running 206's sp_risk_register_list these are not
                // in the result set at all, and an unguarded read throws
                // IndexOutOfRange -- which apiGet then swallowed into
                // "No risks in the register match these filters", i.e. an
                // empty register rather than a broken one.
                HasColumn(r, "AnalysisPending")
                    && r["AnalysisPending"] != DBNull.Value
                    && Convert.ToBoolean(r["AnalysisPending"]),
                HasColumn(r, "ThreatName")           ? r["ThreatName"]           as string : null,
                HasColumn(r, "VulnerabilityName")    ? r["VulnerabilityName"]    as string : null,
                HasColumn(r, "BusinessFunctionName") ? r["BusinessFunctionName"] as string : null,
                // The 258 columns, read the same defensive way. On a
                // database still on 216 they are absent; ResidualPending
                // then falls back to TRUE, which is exactly right -- no
                // residual assessment exists there either.
                HasColumn(r, "ResidualLikelihoodName") ? r["ResidualLikelihoodName"] as string : null,
                HasColumn(r, "ResidualImpactName")     ? r["ResidualImpactName"]     as string : null,
                HasColumn(r, "ResidualRatingCode")     ? r["ResidualRatingCode"]     as string : null,
                HasColumn(r, "ResidualRatingName")     ? r["ResidualRatingName"]     as string : null,
                HasColumn(r, "ResidualRatingScore")    ? r["ResidualRatingScore"]    as int?   : null,
                HasColumn(r, "ResidualAssessedOn")     ? r["ResidualAssessedOn"]     as DateTime? : null,
                !HasColumn(r, "ResidualPending")
                    || r["ResidualPending"] == DBNull.Value
                    || Convert.ToBoolean(r["ResidualPending"]),
                // The 261-264 columns, read the same defensive way. On a
                // database still on 258 they are absent, and every one of
                // them then falls back to the value that means "this risk
                // has not reached that stage" -- which is true there.
                HasColumn(r, "TreatmentOptionCode") ? r["TreatmentOptionCode"] as string : null,
                HasColumn(r, "TreatmentOptionName") ? r["TreatmentOptionName"] as string : null,
                HasColumn(r, "TreatmentTaskId")     ? r["TreatmentTaskId"]     as long?  : null,
                HasColumn(r, "AcceptedOn")          ? r["AcceptedOn"]          as DateTime? : null,
                HasColumn(r, "AcceptedByName")      ? r["AcceptedByName"]      as string : null,
                HasColumn(r, "NextReviewDate")      ? r["NextReviewDate"]      as DateTime? : null,
                HasColumn(r, "LastReviewedOn")      ? r["LastReviewedOn"]      as DateTime? : null,
                NullableInt(HasColumn(r, "ReviewCount") ? r["ReviewCount"] : null),
                HasColumn(r, "WorkflowStageCode")   ? r["WorkflowStageCode"]   as string : null,
                NullableInt(HasColumn(r, "OpenTreatmentTaskCount") ? r["OpenTreatmentTaskCount"] : null),
                NullableInt(HasColumn(r, "TreatmentTaskCount")     ? r["TreatmentTaskCount"]     : null),
                HasColumn(r, "IsReviewDue")
                    && r["IsReviewDue"] != DBNull.Value
                    && Convert.ToBoolean(r["IsReviewDue"]),
                NullableInt(HasColumn(r, "MappedPracticeCount") ? r["MappedPracticeCount"] : null),
                NullableInt(HasColumn(r, "MappedDependencyCount") ? r["MappedDependencyCount"] : null),
                // 376. Absent on a database not yet migrated -- the grid
                // falls back to the legacy scalar RiskCategoryName itself.
                HasColumn(r, "RiskCategoryNames") ? r["RiskCategoryNames"] as string : null));
            total = Convert.ToInt64(r["TotalRows"]);
        }
        return new RiskRegisterListResult(total, page, pageSize, rows);
    }

    public async Task<RiskRegisterDetail?> GetRegisterAsync(long riskRegisterId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_register_get");
        AddParam(cmd, "@risk_register_id", DbType.Int64, riskRegisterId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        return new RiskRegisterDetail(
            Convert.ToInt64(r["RiskRegisterId"]),
            r["RiskNumber"]?.ToString() ?? "",
            Convert.ToInt64(r["OrganizationId"]),
            r["RiskTitle"]?.ToString() ?? "",
            r["RiskStatement"]?.ToString() ?? "",
            r["RiskDescription"] as string,
            r["RiskCategoryCode"] as string,
            r["RiskCategoryName"] as string,
            r["SourceTypeCode"]?.ToString() ?? "",
            r["SourceName"] as string,
            r["SourceRecordId"] as long?,
            r["SourceReference"] as string,
            r["SourceDescription"] as string,
            r["SourceCentreCode"] as string,
            r["RiskCandidateId"] as long?,
            r["CandidateNumber"] as string,
            r["CandidateTitle"] as string,
            r["CustomGapId"] as long?,
            Convert.ToInt64(r["RiskAnalysisId"]),
            r["AnalysisVersion"] as int?,
            r["AnalysisOn"] as DateTime?,
            r["AnalysedByName"] as string,
            r["RiskOwnerEmployeeId"] as long?,
            r["RiskOwnerName"] as string,
            r["BusinessUnit"] as string,
            r["ProcessName"] as string,
            r["RiskCause"] as string,
            r["PotentialConsequence"] as string,
            r["ExistingControls"] as string,
            r["LikelihoodCode"] as string,
            r["LikelihoodName"] as string,
            r["LikelihoodValue"] as int?,
            r["ImpactCode"] as string,
            r["ImpactName"] as string,
            r["ImpactValue"] as int?,
            r["InherentRatingCode"] as string,
            r["InherentRatingName"] as string,
            r["InherentRatingScore"] as int?,
            r["LinkedAssetId"] as long?,
            r["LinkedVendorId"] as long?,
            r["LinkedPracticeId"] as long?,
            r["LinkedObligationId"] as long?,
            r["LinkedControlId"] as long?,
            r["StatusCode"]?.ToString() ?? "",
            Convert.ToDateTime(r["RegisteredOn"]),
            r["RegisteredByEmployeeId"] as long?,
            r["RegisteredByName"] as string,
            r["ClosedOn"] as DateTime?,
            r["ClosedByName"] as string,
            r["ClosureReason"] as string,
            Convert.ToBoolean(r["AnalysisPending"]),
            r["ThreatId"] as int?,
            r["ThreatName"] as string,
            r["ThreatDescription"] as string,
            r["VulnerabilityId"] as int?,
            r["VulnerabilityName"] as string,
            r["VulnerabilityDescription"] as string,
            r["BusinessFunctionId"] as long?,
            r["BusinessFunctionName"] as string,
            r["AnalysisApprovalStatusCode"] as string,
            // ---- migration 258 ------------------------------------------
            // Guarded per column: this proc is rewritten by 258, so a
            // database still on 216 returns none of these and an
            // unguarded read would throw IndexOutOfRange and turn the
            // whole detail modal into "Risk not found."
            HasColumn(r, "ResidualAnalysisId")       ? r["ResidualAnalysisId"]       as long? : null,
            HasColumn(r, "ResidualVersion")          ? r["ResidualVersion"]          as int?  : null,
            HasColumn(r, "ResidualLikelihoodCode")   ? r["ResidualLikelihoodCode"]   as string : null,
            HasColumn(r, "ResidualLikelihoodName")   ? r["ResidualLikelihoodName"]   as string : null,
            HasColumn(r, "ResidualLikelihoodValue")  ? r["ResidualLikelihoodValue"]  as int?  : null,
            HasColumn(r, "ResidualImpactCode")       ? r["ResidualImpactCode"]       as string : null,
            HasColumn(r, "ResidualImpactName")       ? r["ResidualImpactName"]       as string : null,
            HasColumn(r, "ResidualImpactValue")      ? r["ResidualImpactValue"]      as int?  : null,
            HasColumn(r, "ResidualRatingCode")       ? r["ResidualRatingCode"]       as string : null,
            HasColumn(r, "ResidualRatingName")       ? r["ResidualRatingName"]       as string : null,
            HasColumn(r, "ResidualRatingScore")      ? r["ResidualRatingScore"]      as int?  : null,
            HasColumn(r, "ResidualAssessedOn")       ? r["ResidualAssessedOn"]       as DateTime? : null,
            !HasColumn(r, "ResidualPending")
                || r["ResidualPending"] == DBNull.Value
                || Convert.ToBoolean(r["ResidualPending"]),
            HasColumn(r, "ResidualTreatmentSummary") ? r["ResidualTreatmentSummary"] as string : null,
            HasColumn(r, "ResidualControls")         ? r["ResidualControls"]         as string : null,
            HasColumn(r, "ResidualRemarks")          ? r["ResidualRemarks"]          as string : null,
            HasColumn(r, "ResidualAssessedByName")   ? r["ResidualAssessedByName"]   as string : null,
            // ---- migrations 261-264 --------------------------------------
            // Guarded per column for the same reason: this proc is
            // rewritten again by 264, and a database still on 258 returns
            // none of these.
            HasColumn(r, "LinkedPracticeName")       ? r["LinkedPracticeName"]       as string : null,
            HasColumn(r, "TreatmentOptionCode")      ? r["TreatmentOptionCode"]      as string : null,
            HasColumn(r, "TreatmentOptionName")      ? r["TreatmentOptionName"]      as string : null,
            HasColumn(r, "TreatmentDecidedOn")       ? r["TreatmentDecidedOn"]       as DateTime? : null,
            HasColumn(r, "TreatmentDecidedByName")   ? r["TreatmentDecidedByName"]   as string : null,
            HasColumn(r, "TreatmentTaskId")          ? r["TreatmentTaskId"]          as long? : null,
            HasColumn(r, "AcceptedByEmployeeId")     ? r["AcceptedByEmployeeId"]     as long? : null,
            HasColumn(r, "AcceptedByName")           ? r["AcceptedByName"]           as string : null,
            // 292. Guarded like every column around it, so an API ahead
            // of its migration shows the bare name rather than throwing.
            HasColumn(r, "AcceptedByRoleNames")      ? r["AcceptedByRoleNames"]      as string : null,
            HasColumn(r, "AcceptedOn")               ? r["AcceptedOn"]               as DateTime? : null,
            HasColumn(r, "AcceptanceNote")           ? r["AcceptanceNote"]           as string : null,
            HasColumn(r, "NextReviewDate")           ? r["NextReviewDate"]           as DateTime? : null,
            HasColumn(r, "LastReviewedOn")           ? r["LastReviewedOn"]           as DateTime? : null,
            NullableInt(HasColumn(r, "ReviewCount") ? r["ReviewCount"] : null),
            HasColumn(r, "WorkflowStageCode")        ? r["WorkflowStageCode"]        as string : null,
            NullableInt(HasColumn(r, "OpenTreatmentTaskCount") ? r["OpenTreatmentTaskCount"] : null),
            NullableInt(HasColumn(r, "TreatmentTaskCount")     ? r["TreatmentTaskCount"]     : null),
            HasColumn(r, "IsReviewDue")
                && r["IsReviewDue"] != DBNull.Value
                && Convert.ToBoolean(r["IsReviewDue"]),
            NullableInt(HasColumn(r, "MappedPracticeCount") ? r["MappedPracticeCount"] : null),
            NullableInt(HasColumn(r, "MappedDependencyCount") ? r["MappedDependencyCount"] : null),
            // 310. Falls back to 1, not 0, when the column is absent --
            // this database may not have 310 yet, and every risk is at
            // least version 1 by definition. HasColumn is the same guard
            // every other v2 column here uses, for the same reason.
            HasColumn(r, "RiskVersion") && r["RiskVersion"] != DBNull.Value
                ? Convert.ToInt32(r["RiskVersion"])
                : 1,
            // 311. Falls back to MappedPracticeCount when the column is
            // absent (a database still on 310), which is the answer that
            // procedure gave before 311 -- degraded, never wrong in a
            // new way.
            HasColumn(r, "LinkedPracticeCount") && r["LinkedPracticeCount"] != DBNull.Value
                ? Convert.ToInt32(r["LinkedPracticeCount"])
                : NullableInt(HasColumn(r, "MappedPracticeCount") ? r["MappedPracticeCount"] : null),
            // 376. Same additive column as the list row above, for the
            // Risk View detail page.
            HasColumn(r, "RiskCategoryNames") ? r["RiskCategoryNames"] as string : null);
    }

    // =================================================================
    // Residual Risk Analysis (migration 258)
    //
    // The rating is never sent. sp_risk_residual_analysis_save resolves
    // it from the organisation's matrix through the same
    // sp_risk_rating_resolve the inherent rating uses, so the two scores
    // on the register grid are produced by one method and are
    // comparable.
    // =================================================================

    public async Task<RiskResidualSaveResult> SaveResidualAnalysisAsync(
        long riskRegisterId, RiskResidualSaveRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (string.IsNullOrWhiteSpace(req.ResidualLikelihoodCode))
            return new RiskResidualSaveResult(false, riskRegisterId, null, null, null, null, null, null, null, "residualLikelihoodCode is required.");
        if (string.IsNullOrWhiteSpace(req.ResidualImpactCode))
            return new RiskResidualSaveResult(false, riskRegisterId, null, null, null, null, null, null, null, "residualImpactCode is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_residual_analysis_save");
            AddParam(cmd, "@risk_register_id",         DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@residual_likelihood_code", DbType.String, req.ResidualLikelihoodCode, 60);
            AddParam(cmd, "@residual_impact_code",     DbType.String, req.ResidualImpactCode, 60);
            AddParam(cmd, "@treatment_summary",        DbType.String, (object?)req.TreatmentSummary ?? DBNull.Value, -1);
            AddParam(cmd, "@residual_controls",        DbType.String, (object?)req.ResidualControls ?? DBNull.Value, -1);
            AddParam(cmd, "@analyst_remarks",          DbType.String, (object?)req.AnalystRemarks ?? DBNull.Value, -1);
            AddParam(cmd, "@assessed_by_employee_id",  DbType.Int64,  (object?)req.AssessedByEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",      DbType.String, req.CallerDisplayName ?? "system", 100);

            // Migration 263 added @treatment_option_code. Probed, not
            // assumed, for exactly the reason ListRegisterAsync probes
            // its own additions: a database still on 258 does not declare
            // it, and sending an undeclared parameter fails the whole
            // save with "too many arguments" rather than degrading.
            if (!string.IsNullOrWhiteSpace(req.TreatmentOptionCode)
                && await Infrastructure.ProcParameterProbe.HasParameterAsync(
                       conn, "sp_risk_residual_analysis_save", "@treatment_option_code", ct))
            {
                AddParam(cmd, "@treatment_option_code", DbType.String, req.TreatmentOptionCode, 30);
            }

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskResidualSaveResult(true, riskRegisterId,
                    r["RiskResidualAnalysisId"] as long?,
                    r["ResidualVersion"] as int?,
                    r["ResidualRatingCode"] as string,
                    r["ResidualRatingName"] as string,
                    r["ResidualRatingScore"] as int?,
                    r["InherentRatingCode"] as string,
                    r["InherentRatingScore"] as int?,
                    null,
                    HasColumn(r, "TreatmentOptionCode") ? r["TreatmentOptionCode"] as string : null,
                    HasColumn(r, "TreatmentOptionName") ? r["TreatmentOptionName"] as string : null);
            return new RiskResidualSaveResult(true, riskRegisterId, null, null, null, null, null, null, null, null);
        }
        catch (SqlException ex)
        {
            // 56450-56462 are this migration's own refusals and name the
            // rule that refused (no inherent rating yet, risk still
            // Active, risk closed). Surfaced verbatim, like every other
            // 560xx in this service.
            logger.LogWarning(ex, "RiskCentreService.SaveResidualAnalysis failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskResidualSaveResult(false, riskRegisterId, null, null, null, null, null, null, null, ex.Message);
        }
    }

    public async Task<RiskResidualDetail?> GetResidualAnalysisAsync(long riskRegisterId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_residual_analysis_get");
        AddParam(cmd, "@risk_register_id", DbType.Int64, riskRegisterId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        // No row simply means no residual assessment yet. That is the
        // normal state of a newly registered risk, not an error, so the
        // controller answers 204 rather than 404.
        if (!await r.ReadAsync(ct)) return null;
        return new RiskResidualDetail(
            Convert.ToInt64(r["RiskResidualAnalysisId"]),
            Convert.ToInt64(r["OrganizationId"]),
            Convert.ToInt64(r["RiskRegisterId"]),
            r["InherentAnalysisId"] as long?,
            Convert.ToInt32(r["ResidualVersion"]),
            Convert.ToBoolean(r["IsCurrent"]),
            r["ResidualLikelihoodCode"] as string,
            r["ResidualLikelihoodName"] as string,
            r["ResidualLikelihoodValue"] as int?,
            r["ResidualImpactCode"] as string,
            r["ResidualImpactName"] as string,
            r["ResidualImpactValue"] as int?,
            r["ResidualRatingCode"] as string,
            r["ResidualRatingName"] as string,
            r["ResidualRatingScore"] as int?,
            r["InherentRatingCode"] as string,
            r["InherentRatingName"] as string,
            r["InherentRatingScore"] as int?,
            r["TreatmentSummary"] as string,
            r["ResidualControls"] as string,
            r["AnalystRemarks"] as string,
            Convert.ToDateTime(r["AssessedOn"]),
            r["AssessedByEmployeeId"] as long?,
            r["AssessedByName"] as string);
    }

    public async Task<IReadOnlyList<RiskResidualVersionRow>> GetResidualHistoryAsync(long riskRegisterId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_residual_analysis_history");
        AddParam(cmd, "@risk_register_id", DbType.Int64, riskRegisterId);
        var rows = new List<RiskResidualVersionRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new RiskResidualVersionRow(
                Convert.ToInt64(r["RiskResidualAnalysisId"]),
                Convert.ToInt32(r["ResidualVersion"]),
                Convert.ToBoolean(r["IsCurrent"]),
                r["ResidualLikelihoodName"] as string,
                r["ResidualImpactName"] as string,
                r["ResidualRatingCode"] as string,
                r["ResidualRatingScore"] as int?,
                r["InherentRatingCode"] as string,
                r["InherentRatingScore"] as int?,
                r["TreatmentSummary"] as string,
                r["AnalystRemarks"] as string,
                Convert.ToDateTime(r["AssessedOn"]),
                r["AssessedByName"] as string));
        return rows;
    }

    public async Task<RiskRegisterActionResult> SetRegisterStatusAsync(long riskRegisterId, RiskRegisterStatusRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (string.IsNullOrWhiteSpace(req.StatusCode))
            return new RiskRegisterActionResult(false, null, riskRegisterId, null, null, "statusCode is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_register_status_set");
            AddParam(cmd, "@risk_register_id",    DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@status_code",         DbType.String, req.StatusCode, 30);
            AddParam(cmd, "@remark",              DbType.String, (object?)req.Remark ?? DBNull.Value, -1);
            AddParam(cmd, "@actor_employee_id",   DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, req.CallerDisplayName ?? "system", 100);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskRegisterActionResult(true, null, riskRegisterId, null, r["StatusCode"]?.ToString(), null);
            return new RiskRegisterActionResult(true, null, riskRegisterId, null, req.StatusCode, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.SetRegisterStatus failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskRegisterActionResult(false, null, riskRegisterId, null, null, ex.Message);
        }
    }

    public async Task<RiskRegisterActionResult> SetRegisterOwnerAsync(long riskRegisterId, RiskRegisterOwnerRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.OwnerEmployeeId is null or <= 0)
            return new RiskRegisterActionResult(false, null, riskRegisterId, null, null, "ownerEmployeeId is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_register_owner_set");
            AddParam(cmd, "@risk_register_id",    DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@owner_employee_id",   DbType.Int64,  req.OwnerEmployeeId!.Value);
            AddParam(cmd, "@remark",              DbType.String, (object?)req.Remark ?? DBNull.Value, -1);
            AddParam(cmd, "@actor_employee_id",   DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, req.CallerDisplayName ?? "system", 100);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            await r.ReadAsync(ct);
            return new RiskRegisterActionResult(true, null, riskRegisterId, null, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.SetRegisterOwner failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskRegisterActionResult(false, null, riskRegisterId, null, null, ex.Message);
        }
    }

    // =================================================================
    // Phase B (migrations 208-211)
    // =================================================================

    // ---- 208: configuration + approval (§19) ------------------------
    public async Task<RiskConfigDetail?> GetConfigAsync(long organizationId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_config_get");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);
        return await ReadConfigAsync(cmd, ct);
    }

    public async Task<RiskConfigDetail?> SaveConfigAsync(long organizationId, RiskConfigSaveRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_config_save");
        AddParam(cmd, "@organization_id",              DbType.Int64,   organizationId);
        AddParam(cmd, "@approval_required",            DbType.Boolean, (object?)req.ApprovalRequired ?? DBNull.Value);
        AddParam(cmd, "@approval_min_rating_code",     DbType.String,  (object?)req.ApprovalMinRatingCode ?? DBNull.Value, 30);
        AddParam(cmd, "@approver_role_id",             DbType.Int64,   (object?)req.ApproverRoleId ?? DBNull.Value);
        AddParam(cmd, "@default_raise_treatment_task", DbType.Boolean, (object?)req.DefaultRaiseTreatmentTask ?? DBNull.Value);
        AddParam(cmd, "@allow_legacy_accept",          DbType.Boolean, (object?)req.AllowLegacyAccept ?? DBNull.Value);
        AddParam(cmd, "@notifications_enabled",        DbType.Boolean, (object?)req.NotificationsEnabled ?? DBNull.Value);
        AddParam(cmd, "@notes",                        DbType.String,  (object?)req.Notes ?? DBNull.Value, 1000);
        AddParam(cmd, "@clear_approver_role",          DbType.Boolean, req.ClearApproverRole ?? false);
        AddParam(cmd, "@clear_min_rating",             DbType.Boolean, req.ClearMinRating ?? false);
        AddParam(cmd, "@caller_display_name",          DbType.String,  req.CallerDisplayName ?? "system", 100);
        return await ReadConfigAsync(cmd, ct);
    }

    // Both config procs emit the same two result sets, so one reader
    // serves them and the save path cannot drift from the get path.
    private static async Task<RiskConfigDetail?> ReadConfigAsync(DbCommand cmd, CancellationToken ct)
    {
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;

        var id       = Convert.ToInt64(r["OrgRiskConfigId"]);
        var orgId    = Convert.ToInt64(r["OrganizationId"]);
        var required = Convert.ToBoolean(r["ApprovalRequired"]);
        var minRat   = r["ApprovalMinRatingCode"] as string;
        var roleId   = r["ApproverRoleId"] as long?;
        var roleName = r["ApproverRoleName"] as string;
        var defTask  = Convert.ToBoolean(r["DefaultRaiseTreatmentTask"]);
        var legacy   = Convert.ToBoolean(r["AllowLegacyAccept"]);
        var notify   = Convert.ToBoolean(r["NotificationsEnabled"]);
        var notes    = r["Notes"] as string;

        var roles = new List<RiskConfigNotifyRole>();
        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                roles.Add(new RiskConfigNotifyRole(
                    r["NotifyEventCode"]?.ToString() ?? "",
                    Convert.ToInt64(r["RoleId"]),
                    r["RoleName"] as string,
                    Convert.ToBoolean(r["IsActive"])));

        return new RiskConfigDetail(id, orgId, required, minRat, roleId, roleName,
                                    defTask, legacy, notify, notes, roles);
    }

    public Task<RiskApprovalActionResult> SubmitForApprovalAsync(long candidateId, RiskApprovalRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        return ApprovalActionAsync(candidateId, "grac_practice.sp_risk_analysis_submit_approval", cmd =>
        {
            AddParam(cmd, "@risk_candidate_id",   DbType.Int64,  candidateId);
            AddParam(cmd, "@remark",              DbType.String, (object?)req.Remark ?? DBNull.Value, -1);
            AddParam(cmd, "@actor_employee_id",   DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, req.CallerDisplayName ?? "system", 100);
        }, ct);
    }

    public Task<RiskApprovalActionResult> DecideApprovalAsync(long candidateId, RiskApprovalDecisionRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.Decision is not ("Approve" or "Return"))
            return Task.FromResult(new RiskApprovalActionResult(false, candidateId, null, null, null,
                "decision must be Approve or Return."));
        return ApprovalActionAsync(candidateId, "grac_practice.sp_risk_analysis_approve", cmd =>
        {
            AddParam(cmd, "@risk_candidate_id",   DbType.Int64,  candidateId);
            AddParam(cmd, "@decision",            DbType.String, req.Decision, 20);
            AddParam(cmd, "@remark",              DbType.String, (object?)req.Remark ?? DBNull.Value, -1);
            AddParam(cmd, "@actor_employee_id",   DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, req.CallerDisplayName ?? "system", 100);
        }, ct);
    }

    private async Task<RiskApprovalActionResult> ApprovalActionAsync(
        long candidateId, string procName, Action<DbCommand> bind, CancellationToken ct)
    {
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, procName);
            bind(cmd);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskApprovalActionResult(true, candidateId,
                    r["StatusCode"] as string,
                    r["RiskAnalysisId"] as long?,
                    r["ApprovalStatusCode"] as string,
                    null);
            return new RiskApprovalActionResult(true, candidateId, null, null, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.{Proc} failed {Id}: {Msg}", procName, candidateId, ex.Message);
            return new RiskApprovalActionResult(false, candidateId, null, null, null, ex.Message);
        }
    }

    public async Task<RiskApprovalQueueResult> ListApprovalQueueAsync(long organizationId, int page, int pageSize, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_approval_queue_list");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);
        AddParam(cmd, "@page_number",     DbType.Int32, Math.Max(1, page));
        AddParam(cmd, "@page_size",       DbType.Int32, Math.Clamp(pageSize <= 0 ? 25 : pageSize, 1, 200));

        var rows = new List<RiskApprovalQueueRow>();
        long total = 0;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new RiskApprovalQueueRow(
                Convert.ToInt64(r["RiskCandidateId"]),
                r["CandidateNumber"] as string,
                r["CandidateTitle"]?.ToString() ?? "",
                r["SourceTypeCode"] as string,
                r["SourceReference"] as string,
                r["StatusCode"]?.ToString() ?? "",
                Convert.ToInt64(r["RiskAnalysisId"]),
                Convert.ToInt32(r["AnalysisVersion"]),
                r["RiskStatement"]?.ToString() ?? "",
                r["RiskCategoryName"] as string,
                r["LikelihoodName"] as string,
                r["ImpactName"] as string,
                r["InherentRatingCode"] as string,
                r["InherentRatingScore"] as int?,
                r["RiskOwnerEmployeeId"] as long?,
                r["RiskOwnerName"] as string,
                Convert.ToDateTime(r["AnalysisOn"]),
                r["AnalysedByName"] as string,
                r["ApprovalNote"] as string,
                Convert.ToInt32(r["DaysWaiting"])));
            total = Convert.ToInt64(r["TotalRows"]);
        }
        return new RiskApprovalQueueResult(total, page, pageSize, rows);
    }

    // ---- 209: notifications (§21) -----------------------------------
    public async Task<RiskNotificationSweepResult> SweepNotificationsAsync(long? organizationId, int sinceHours, int maxEvents, CancellationToken ct)
    {
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_notification_sweep");
            // The sweep walks cursors over history and role holders; the
            // 30s default is not generous enough for a first run on a
            // busy organisation.
            cmd.CommandTimeout = 180;
            AddParam(cmd, "@organization_id",     DbType.Int64, (object?)organizationId ?? DBNull.Value);
            AddParam(cmd, "@since_hours",         DbType.Int32, sinceHours <= 0 ? 168 : sinceHours);
            AddParam(cmd, "@max_events",          DbType.Int32, maxEvents  <= 0 ? 500 : maxEvents);
            AddParam(cmd, "@caller_display_name", DbType.String, "sweep", 100);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskNotificationSweepResult(true,
                    Convert.ToInt32(r["EventsScanned"]),
                    Convert.ToInt32(r["NotificationsForScannedEvents"]), null);
            return new RiskNotificationSweepResult(true, 0, 0, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.SweepNotifications failed: {Msg}", ex.Message);
            return new RiskNotificationSweepResult(false, 0, 0, ex.Message);
        }
    }

    public async Task<RiskNotificationListResult> ListNotificationsAsync(
        long organizationId, string? statusCode, string? eventCode, string? subjectTypeCode,
        long? subjectRecordId, long? recipientEmployeeId, int page, int pageSize, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_notification_list");
        AddParam(cmd, "@organization_id",       DbType.Int64,  organizationId);
        AddParam(cmd, "@status_code",           DbType.String, (object?)statusCode ?? DBNull.Value, 20);
        AddParam(cmd, "@notify_event_code",     DbType.String, (object?)eventCode ?? DBNull.Value, 40);
        AddParam(cmd, "@subject_type_code",     DbType.String, (object?)subjectTypeCode ?? DBNull.Value, 20);
        AddParam(cmd, "@subject_record_id",     DbType.Int64,  (object?)subjectRecordId ?? DBNull.Value);
        AddParam(cmd, "@recipient_employee_id", DbType.Int64,  (object?)recipientEmployeeId ?? DBNull.Value);
        AddParam(cmd, "@page_number",           DbType.Int32,  Math.Max(1, page));
        AddParam(cmd, "@page_size",             DbType.Int32,  Math.Clamp(pageSize <= 0 ? 25 : pageSize, 1, 200));

        var rows = new List<RiskNotificationRow>();
        long total = 0;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new RiskNotificationRow(
                Convert.ToInt64(r["RiskNotificationId"]),
                Convert.ToInt64(r["OrganizationId"]),
                r["SubjectTypeCode"]?.ToString() ?? "",
                Convert.ToInt64(r["SubjectRecordId"]),
                r["SubjectNumber"] as string,
                r["SubjectTitle"] as string,
                r["NotifyEventCode"]?.ToString() ?? "",
                r["InherentRatingCode"] as string,
                r["SubjectStatusCode"] as string,
                r["RecipientEmployeeId"] as long?,
                r["RecipientName"] as string,
                r["RecipientEmail"] as string,
                r["RoleName"] as string,
                r["RecipientReasonCode"]?.ToString() ?? "",
                r["Subject"] as string,
                r["BodyText"] as string,
                r["StatusCode"]?.ToString() ?? "",
                Convert.ToInt32(r["AttemptCount"]),
                r["FailureReason"] as string,
                r["SentOn"] as DateTime?,
                Convert.ToDateTime(r["EventOn"]),
                Convert.ToDateTime(r["RecordedOn"])));
            total = Convert.ToInt64(r["TotalRows"]);
        }
        return new RiskNotificationListResult(total, page, pageSize, rows);
    }

    public async Task<RiskNotificationCounts> GetNotificationCountsAsync(long organizationId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_notification_counts");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return new RiskNotificationCounts(0, 0, 0, 0, 0);
        // SUM() over an empty table returns NULL, not 0.
        return new RiskNotificationCounts(
            NullableInt(r["PendingCount"]), NullableInt(r["SentCount"]),
            NullableInt(r["FailedCount"]),  NullableInt(r["SuppressedCount"]),
            NullableInt(r["TotalCount"]));
    }

    public async Task<bool> MarkNotificationAsync(long notificationId, RiskNotificationMarkRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_notification_mark");
        AddParam(cmd, "@risk_notification_id", DbType.Int64,  notificationId);
        AddParam(cmd, "@status_code",          DbType.String, req.StatusCode, 20);
        AddParam(cmd, "@failure_reason",       DbType.String, (object?)req.FailureReason ?? DBNull.Value, 1000);
        AddParam(cmd, "@caller_display_name",  DbType.String, req.CallerDisplayName ?? "system", 100);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        return await r.ReadAsync(ct);
    }

    // ---- 210: dashboard (§23) ---------------------------------------
    public async Task<RiskDashboard> GetDashboardAsync(long organizationId, int trendMonths, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_dashboard_counts");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);
        AddParam(cmd, "@trend_months",    DbType.Int32, trendMonths <= 0 ? 12 : trendMonths);

        await using var r = await cmd.ExecuteReaderAsync(ct);

        // Eleven result sets in a fixed order — see 210's header. Read
        // positionally; do not reorder.
        var candidates = new RiskCandidateSummary(0,0,0,0,0,0,0,0,0,0,0,0,null,null);
        if (await r.ReadAsync(ct))
            candidates = new RiskCandidateSummary(
                NullableInt(r["TotalCandidates"]), NullableInt(r["OpenCandidates"]),
                NullableInt(r["NewCandidates"]), NullableInt(r["UnderAnalysisCount"]),
                NullableInt(r["AwaitingClarificationCount"]), NullableInt(r["AwaitingApprovalCount"]),
                NullableInt(r["AnalysisCompletedCount"]), NullableInt(r["RejectedCount"]),
                NullableInt(r["ClosedAsDuplicateCount"]), NullableInt(r["WithdrawnCount"]),
                NullableInt(r["ConvertedToRiskCount"]), NullableInt(r["LegacyAcceptedCount"]),
                // AVG over an INT column returns INT in SQL Server, so
                // this arrives boxed as int, not double.
                NullableDouble(r["AvgOpenAgeDays"]),
                r["MaxOpenAgeDays"] as int?);

        var candBySource = await ReadGroupsAsync(r, "SourceTypeCode", "SourceName", ct);

        var register = new RiskRegisterSummary(0,0,0,0,0,0,0,0,0,0,null);
        if (await r.NextResultAsync(ct) && await r.ReadAsync(ct))
            register = new RiskRegisterSummary(
                NullableInt(r["TotalRisks"]), NullableInt(r["ActiveCount"]),
                NullableInt(r["UnderTreatmentCount"]), NullableInt(r["AcceptedCount"]),
                NullableInt(r["MonitoringCount"]), NullableInt(r["ClosedCount"]),
                NullableInt(r["RetiredCount"]), NullableInt(r["ElevatedRatingCount"]),
                NullableInt(r["CustomRiskCount"]), NullableInt(r["UnownedCount"]),
                NullableDouble(r["AvgInherentScore"]));

        var byCategory = await ReadGroupsAsync(r, "CategoryCode", "CategoryName", ct);
        var bySource   = await ReadGroupsAsync(r, "SourceTypeCode", "SourceName", ct);
        var byRating   = await ReadGroupsAsync(r, "RatingCode", "RatingName", ct);
        var byUnit     = await ReadGroupsAsync(r, "BusinessUnit", "BusinessUnit", ct);
        var byOwner    = await ReadGroupsAsync(r, "OwnerEmployeeId", "OwnerName", ct);

        var ageing = new List<RiskAgeingBand>();
        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                ageing.Add(new RiskAgeingBand(
                    r["BandCode"]?.ToString() ?? "", r["BandName"]?.ToString() ?? "",
                    Convert.ToInt32(r["SortOrder"]), Convert.ToInt32(r["CandidateCount"])));

        var trend = new List<RiskTrendPoint>();
        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                trend.Add(new RiskTrendPoint(
                    Convert.ToDateTime(r["MonthStart"]),
                    Convert.ToInt32(r["RegisteredCount"]),
                    Convert.ToInt32(r["ClosedCount"]),
                    Convert.ToInt32(r["CandidatesRaisedCount"])));

        var overdue = new List<RiskOverdueAction>();
        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                overdue.Add(new RiskOverdueAction(
                    r["TaskId"] as long?, r["TaskNumber"] as string, r["TaskTitle"] as string,
                    r["RiskCandidateId"] as long?, r["OwnerName"] as string,
                    r["Priority"] as string, r["DueAt"] as DateTime?,
                    r["SlaStatusCode"] as string, r["TaskStatusName"] as string));

        return new RiskDashboard(candidates, candBySource, register, byCategory, bySource,
                                 byRating, byUnit, byOwner, ageing, trend, overdue);
    }

    // Every "by X" result set in 210 shares a shape: a key, a label, two
    // counts and some optional extras. One reader keeps the dashboard
    // mapping honest — a tile cannot quietly grow a different contract.
    private static async Task<IReadOnlyList<RiskGroupCount>> ReadGroupsAsync(
        DbDataReader r, string keyColumn, string labelColumn, CancellationToken ct)
    {
        var rows = new List<RiskGroupCount>();
        if (!await r.NextResultAsync(ct)) return rows;
        var hasAvg    = HasColumn(r, "AvgInherentScore");
        var hasScore  = HasColumn(r, "RatingScore");
        var hasColour = HasColumn(r, "ColourHex");
        while (await r.ReadAsync(ct))
            rows.Add(new RiskGroupCount(
                r[keyColumn]?.ToString() ?? "",
                r[labelColumn]?.ToString() ?? "",
                Convert.ToInt32(r["TotalCount"]),
                HasColumn(r, "OpenCount") ? NullableInt(r["OpenCount"]) : 0,
                hasAvg    ? NullableDouble(r["AvgInherentScore"]) : null,
                hasScore  ? r["RatingScore"] as int?         : null,
                hasColour ? r["ColourHex"] as string         : null));
        return rows;
    }

    public async Task<RiskAgeingListResult> ListAgeingAsync(long organizationId, int minAgeDays, int page, int pageSize, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_candidate_ageing");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);
        AddParam(cmd, "@min_age_days",    DbType.Int32, Math.Max(0, minAgeDays));
        AddParam(cmd, "@page_number",     DbType.Int32, Math.Max(1, page));
        AddParam(cmd, "@page_size",       DbType.Int32, Math.Clamp(pageSize <= 0 ? 25 : pageSize, 1, 200));

        var rows = new List<RiskAgeingRow>();
        long total = 0;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new RiskAgeingRow(
                Convert.ToInt64(r["RiskCandidateId"]),
                r["CandidateNumber"] as string,
                r["CandidateTitle"]?.ToString() ?? "",
                r["SourceTypeCode"] as string,
                r["SourceReference"] as string,
                r["StatusCode"]?.ToString() ?? "",
                r["AssignedAnalystEmployeeId"] as long?,
                r["AssignedAnalystName"] as string,
                r["IdentifiedOn"] as DateTime?,
                Convert.ToInt32(r["AgeDays"]),
                r["InherentRatingCode"] as string,
                r["ApprovalStatusCode"] as string));
            total = Convert.ToInt64(r["TotalRows"]);
        }
        return new RiskAgeingListResult(total, page, pageSize, rows);
    }

    // ---- 211: treatment task, opt-in (§22) --------------------------
    public async Task<RiskTreatmentTaskResult> RaiseTreatmentTaskAsync(long riskRegisterId, RiskTreatmentTaskRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_treatment_task_raise");
            AddParam(cmd, "@risk_register_id",    DbType.Int64,   riskRegisterId);
            AddParam(cmd, "@task_title",          DbType.String,  (object?)req.TaskTitle ?? DBNull.Value, 250);
            AddParam(cmd, "@task_description",    DbType.String,  (object?)req.TaskDescription ?? DBNull.Value, -1);
            AddParam(cmd, "@proposed_priority",   DbType.String,  (object?)req.ProposedPriority ?? DBNull.Value, 30);
            AddParam(cmd, "@owner_employee_id",   DbType.Int64,   (object?)req.OwnerEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@allow_additional",    DbType.Boolean, req.AllowAdditional ?? false);
            AddParam(cmd, "@actor_employee_id",   DbType.Int64,   (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String,  req.CallerDisplayName ?? "system", 100);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskTreatmentTaskResult(true, riskRegisterId,
                    r["TaskCandidateId"] as long?,
                    Convert.ToBoolean(r["Created"]),
                    r["ProposedPriority"] as string, null);
            return new RiskTreatmentTaskResult(true, riskRegisterId, null, false, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.RaiseTreatmentTask failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskTreatmentTaskResult(false, riskRegisterId, null, false, null, ex.Message);
        }
    }

    public async Task<IReadOnlyList<RiskRelatedWorkRow>> ListTreatmentWorkAsync(long riskRegisterId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_treatment_task_list");
        AddParam(cmd, "@risk_register_id", DbType.Int64, riskRegisterId);
        var rows = new List<RiskRelatedWorkRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new RiskRelatedWorkRow(
                r["ItemKind"] as string,
                r["ItemId"] as long?,
                r["ItemNumber"] as string,
                r["Title"] as string,
                r["StatusCode"] as string,
                r["StatusName"] as string,
                r["OwnerEmployeeId"] as long?,
                r["OwnerName"] as string,
                r["Priority"] as string,
                r["DueAt"] as DateTime?,
                r["SlaStatusCode"] as string,
                r["IsChild"] as bool?,
                r["ParentTaskId"] as long?,
                r["ChildCount"] as int?,
                r["CompletedDt"] as DateTime?,
                r["RaisedDt"] as DateTime?));
        return rows;
    }

    // =================================================================
    // Two-stage assessment (migration 216)
    // =================================================================

    public async Task<RiskAssessmentOptions> GetAssessmentOptionsAsync(long organizationId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_threat_options_get");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);

        var threats = new List<RiskThreatOption>();
        var vulns   = new List<RiskVulnerabilityOption>();
        var funcs   = new List<RiskBusinessFunctionOption>();

        await using var r = await cmd.ExecuteReaderAsync(ct);
        // Three result sets, fixed order — see the proc header.
        while (await r.ReadAsync(ct))
            threats.Add(new RiskThreatOption(
                Convert.ToInt32(r["ThreatId"]), r["ThreatName"]?.ToString() ?? ""));

        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                vulns.Add(new RiskVulnerabilityOption(
                    Convert.ToInt32(r["VulnerabilityId"]), r["VulnerabilityName"]?.ToString() ?? ""));

        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                funcs.Add(new RiskBusinessFunctionOption(
                    Convert.ToInt64(r["BusinessFunctionId"]),
                    r["FunctionCode"] as string,
                    r["FunctionName"]?.ToString() ?? ""));

        return new RiskAssessmentOptions(threats, vulns, funcs);
    }

    // =================================================================
    // Organisation-owned threats and vulnerabilities (285, 286)
    //
    // Separate from GetAssessmentOptionsAsync above, which is left
    // exactly as it was: sp_risk_threat_options_get still backs the old
    // single-select picklists, and nothing that reads it changes.
    // =================================================================

    public async Task<IReadOnlyList<RiskThreatItem>> ListThreatsAsync(long organizationId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_threat_list");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);

        var rows = new List<RiskThreatItem>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new RiskThreatItem(
                Convert.ToInt32(r["ThreatId"]),
                r["ThreatName"]?.ToString() ?? "",
                NullableLong(r["OrganizationId"]),
                Convert.ToBoolean(r["IsShared"])));
        return rows;
    }

    public async Task<IReadOnlyList<RiskVulnerabilityItem>> ListVulnerabilitiesAsync(long organizationId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_vulnerability_list");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);

        var rows = new List<RiskVulnerabilityItem>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new RiskVulnerabilityItem(
                Convert.ToInt32(r["VulnerabilityId"]),
                r["VulnerabilityName"]?.ToString() ?? "",
                NullableLong(r["OrganizationId"]),
                Convert.ToBoolean(r["IsShared"])));
        return rows;
    }

    public async Task<RiskThreatCreateResult> CreateThreatAsync(
        long organizationId, string name, string? caller, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_threat_create");
        AddParam(cmd, "@organization_id",     DbType.Int64,  organizationId);
        AddParam(cmd, "@threat",              DbType.String, name, 400);
        AddParam(cmd, "@caller_display_name", DbType.String, caller ?? "system", 100);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct))
            throw new InvalidOperationException("sp_risk_threat_create returned no row.");

        return new RiskThreatCreateResult(
            Convert.ToInt32(r["ThreatId"]),
            r["ThreatName"]?.ToString() ?? "",
            NullableLong(r["OrganizationId"]),
            Convert.ToBoolean(r["IsShared"]),
            Convert.ToBoolean(r["WasCreated"]));
    }

    public async Task<RiskVulnerabilityCreateResult> CreateVulnerabilityAsync(
        long organizationId, string name, string? caller, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_vulnerability_create");
        AddParam(cmd, "@organization_id",     DbType.Int64,  organizationId);
        AddParam(cmd, "@vulnerability",       DbType.String, name, 400);
        AddParam(cmd, "@caller_display_name", DbType.String, caller ?? "system", 100);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct))
            throw new InvalidOperationException("sp_risk_vulnerability_create returned no row.");

        return new RiskVulnerabilityCreateResult(
            Convert.ToInt32(r["VulnerabilityId"]),
            r["VulnerabilityName"]?.ToString() ?? "",
            NullableLong(r["OrganizationId"]),
            Convert.ToBoolean(r["IsShared"]),
            Convert.ToBoolean(r["WasCreated"]));
    }

    // Three result sets, fixed order -- threats, vulnerabilities, then
    // the legacy "Others" text, which is absent entirely for a risk that
    // never used it. See sp_risk_threat_selection_get's header.
    public async Task<RiskThreatSelection> GetThreatSelectionAsync(long riskRegisterId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_threat_selection_get");
        AddParam(cmd, "@risk_register_id", DbType.Int64, riskRegisterId);

        var threats = new List<RiskThreatItem>();
        var vulns   = new List<RiskVulnerabilityItem>();
        string? legacyThreat = null, legacyVuln = null;

        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            threats.Add(new RiskThreatItem(
                Convert.ToInt32(r["ThreatId"]),
                r["ThreatName"]?.ToString() ?? "",
                null,
                Convert.ToBoolean(r["IsShared"])));

        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                vulns.Add(new RiskVulnerabilityItem(
                    Convert.ToInt32(r["VulnerabilityId"]),
                    r["VulnerabilityName"]?.ToString() ?? "",
                    null,
                    Convert.ToBoolean(r["IsShared"])));

        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
            {
                legacyThreat = r["LegacyThreatText"] as string;
                legacyVuln   = r["LegacyVulnerabilityText"] as string;
            }

        return new RiskThreatSelection(threats, vulns, legacyThreat, legacyVuln);
    }

    // Ids go down as a comma-separated string because that is what
    // STRING_SPLIT takes, and STRING_SPLIT is already how this codebase
    // passes id lists to SQL (20 existing uses). The procedure validates
    // every id against what the tenant may see, so a crafted list cannot
    // attach another tenant's private row.
    public async Task<int> SetThreatSelectionAsync(
        long organizationId, long? riskAnalysisId, long? riskRegisterId,
        IReadOnlyList<int>? threatIds, IReadOnlyList<int>? vulnerabilityIds,
        string? caller, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_threat_selection_set");
        AddParam(cmd, "@organization_id",     DbType.Int64,  organizationId);
        AddParam(cmd, "@risk_analysis_id",    DbType.Int64,  riskAnalysisId);
        AddParam(cmd, "@risk_register_id",    DbType.Int64,  riskRegisterId);
        AddParam(cmd, "@threat_ids",          DbType.String, Csv(threatIds));
        AddParam(cmd, "@vulnerability_ids",   DbType.String, Csv(vulnerabilityIds));
        AddParam(cmd, "@caller_display_name", DbType.String, caller ?? "system", 100);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        return await r.ReadAsync(ct) ? Convert.ToInt32(r["ThreatCount"]) : 0;

        // null and empty both mean "clear the set", which the procedure
        // reads the same way -- so this returns null rather than "" and
        // lets ISNULL(@threat_ids, N'') in SQL do the rest.
        static string? Csv(IReadOnlyList<int>? ids) =>
            ids is null || ids.Count == 0 ? null : string.Join(",", ids);
    }

    // ---- Risk Type: Confidentiality / Integrity / Availability (313, 314) --
    //
    // Same shape as the threat/vulnerability trio above, minus create --
    // 313 deliberately has no free-text escape hatch, so there is nothing
    // for a "create" endpoint to do.
    public async Task<IReadOnlyList<RiskTypeItem>> ListRiskTypesAsync(long organizationId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_type_list");
        AddParam(cmd, "@organization_id", DbType.Int64, organizationId);

        var rows = new List<RiskTypeItem>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new RiskTypeItem(
                Convert.ToInt32(r["RiskTypeId"]),
                r["RiskTypeCode"]?.ToString() ?? "",
                r["RiskTypeName"]?.ToString() ?? "",
                Convert.ToInt32(r["DisplayOrder"]),
                Convert.ToBoolean(r["IsShared"])));
        return rows;
    }

    public async Task<RiskTypeSelection> GetRiskTypeSelectionAsync(long riskRegisterId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_type_selection_get");
        AddParam(cmd, "@risk_register_id", DbType.Int64, riskRegisterId);

        var rows = new List<RiskTypeSelectionEntry>();
        var fromFallback = false;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new RiskTypeSelectionEntry(
                Convert.ToInt32(r["RiskTypeId"]),
                r["RiskTypeCode"]?.ToString() ?? "",
                r["RiskTypeName"]?.ToString() ?? "",
                Convert.ToInt32(r["DisplayOrder"])));
            fromFallback = Convert.ToBoolean(r["FromAnalysisFallback"]);
        }
        return new RiskTypeSelection(rows, fromFallback);
    }

    // Same CSV-down-STRING_SPLIT convention as SetThreatSelectionAsync, and
    // the same reason: 56731 (at least one risk type required) is thrown by
    // the procedure, not guessed at here, so it is caught and returned as
    // the result's Error rather than left to bubble as an unhandled 500.
    public async Task<RiskTypeSelectionResult> SetRiskTypeSelectionAsync(
        long organizationId, long? riskAnalysisId, long? riskRegisterId,
        IReadOnlyList<int>? riskTypeIds, string? caller, CancellationToken ct)
    {
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_type_selection_set");
            AddParam(cmd, "@organization_id",     DbType.Int64,  organizationId);
            AddParam(cmd, "@risk_analysis_id",    DbType.Int64,  riskAnalysisId);
            AddParam(cmd, "@risk_register_id",    DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@risk_type_ids",       DbType.String, Csv(riskTypeIds));
            AddParam(cmd, "@caller_display_name", DbType.String, caller ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            var count = await r.ReadAsync(ct) ? Convert.ToInt32(r["RiskTypeCount"]) : 0;
            return new RiskTypeSelectionResult(true, riskRegisterId ?? 0, count, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.SetRiskTypeSelection failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskTypeSelectionResult(false, riskRegisterId ?? 0, 0, ex.Message);
        }

        static string? Csv(IReadOnlyList<int>? ids) =>
            ids is null || ids.Count == 0 ? null : string.Join(",", ids);
    }

    // ---- Risk Category, multi-select (375, 376) -----------------------
    //
    // Same shape as GetRiskTypeSelectionAsync/SetRiskTypeSelectionAsync
    // above, called as a SECOND, independent request right after the
    // Analysis page's existing /assess POST succeeds -- sp_risk_register_
    // assess is not touched, matching the "no wrapper" precedent 314's
    // header lays out for Risk Type.
    public async Task<RiskCategorySelection> GetRiskCategorySelectionAsync(long riskRegisterId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_category_selection_get");
        AddParam(cmd, "@risk_register_id", DbType.Int64, riskRegisterId);

        var rows = new List<RiskCategorySelectionEntry>();
        var fromFallback = false;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new RiskCategorySelectionEntry(
                Convert.ToInt64(r["RiskCategoryId"]),
                r["CategoryCode"]?.ToString() ?? "",
                r["CategoryName"]?.ToString() ?? "",
                Convert.ToInt32(r["DisplayOrder"])));
            fromFallback = Convert.ToBoolean(r["FromAnalysisFallback"]);
        }
        return new RiskCategorySelection(rows, fromFallback);
    }

    // Same CSV-down-STRING_SPLIT convention as SetRiskTypeSelectionAsync,
    // and the same reason: 56757 (at least one risk category required) is
    // thrown by the procedure, not guessed at here, so it is caught and
    // returned as the result's Error rather than left to bubble as an
    // unhandled 500.
    public async Task<RiskCategorySelectionResult> SetRiskCategorySelectionAsync(
        long organizationId, long? riskAnalysisId, long? riskRegisterId,
        IReadOnlyList<long>? riskCategoryIds, string? caller, CancellationToken ct)
    {
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_category_selection_set");
            AddParam(cmd, "@organization_id",     DbType.Int64,  organizationId);
            AddParam(cmd, "@risk_analysis_id",    DbType.Int64,  riskAnalysisId);
            AddParam(cmd, "@risk_register_id",    DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@risk_category_ids",   DbType.String, Csv(riskCategoryIds));
            AddParam(cmd, "@caller_display_name", DbType.String, caller ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            var count = await r.ReadAsync(ct) ? Convert.ToInt32(r["RiskCategoryCount"]) : 0;
            return new RiskCategorySelectionResult(true, riskRegisterId ?? 0, count, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.SetRiskCategorySelection failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskCategorySelectionResult(false, riskRegisterId ?? 0, 0, ex.Message);
        }

        static string? Csv(IReadOnlyList<long>? ids) =>
            ids is null || ids.Count == 0 ? null : string.Join(",", ids);
    }

    public async Task<RiskRegisterAssessResult> AssessRegisteredRiskAsync(
        long riskRegisterId, RiskRegisterAssessRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (string.IsNullOrWhiteSpace(req.RiskCategoryCode))
            return new RiskRegisterAssessResult(false, riskRegisterId, null, null, false, null, null, "riskCategoryCode is required.");
        if (string.IsNullOrWhiteSpace(req.LikelihoodCode))
            return new RiskRegisterAssessResult(false, riskRegisterId, null, null, false, null, null, "likelihoodCode is required.");
        if (string.IsNullOrWhiteSpace(req.ImpactCode))
            return new RiskRegisterAssessResult(false, riskRegisterId, null, null, false, null, null, "impactCode is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_register_assess");
            AddParam(cmd, "@risk_register_id",       DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@risk_category_code",     DbType.String, req.RiskCategoryCode, 60);
            AddParam(cmd, "@likelihood_code",        DbType.String, req.LikelihoodCode, 60);
            AddParam(cmd, "@impact_code",            DbType.String, req.ImpactCode, 60);
            AddParam(cmd, "@risk_cause",             DbType.String, (object?)req.RiskCause ?? DBNull.Value, -1);
            AddParam(cmd, "@potential_consequence",  DbType.String, (object?)req.PotentialConsequence ?? DBNull.Value, -1);
            AddParam(cmd, "@existing_controls",      DbType.String, (object?)req.ExistingControls ?? DBNull.Value, -1);
            AddParam(cmd, "@risk_description",       DbType.String, (object?)req.RiskDescription ?? DBNull.Value, -1);
            AddParam(cmd, "@process_name",           DbType.String, (object?)req.ProcessName ?? DBNull.Value, 200);
            AddParam(cmd, "@analyst_remarks",        DbType.String, (object?)req.AnalystRemarks ?? DBNull.Value, -1);
            AddParam(cmd, "@analysed_by_employee_id", DbType.Int64, (object?)req.AnalysedByEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",    DbType.String, req.CallerDisplayName ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskRegisterAssessResult(true, riskRegisterId,
                    r["RiskAnalysisId"] as long?,
                    r["AnalysisVersion"] as int?,
                    Convert.ToBoolean(r["ApprovalRequired"]),
                    r["ApprovalReason"] as string,
                    r["InherentRatingCode"] as string, null);
            return new RiskRegisterAssessResult(true, riskRegisterId, null, null, false, null, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.AssessRegisteredRisk failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskRegisterAssessResult(false, riskRegisterId, null, null, false, null, null, ex.Message);
        }
    }

    public async Task<RiskApprovalActionResult> DecideRegisterAnalysisAsync(
        long riskRegisterId, RiskApprovalDecisionRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.Decision is not ("Approve" or "Return"))
            return new RiskApprovalActionResult(false, riskRegisterId, null, null, null, "decision must be Approve or Return.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_register_analysis_approve");
            AddParam(cmd, "@risk_register_id",    DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@decision",            DbType.String, req.Decision, 20);
            AddParam(cmd, "@remark",              DbType.String, (object?)req.Remark ?? DBNull.Value, -1);
            AddParam(cmd, "@actor_employee_id",   DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, req.CallerDisplayName ?? "system", 100);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                // RiskCandidateId carries the register id here — this
                // approval is about a registered risk, not a candidate.
                return new RiskApprovalActionResult(true, riskRegisterId, null,
                    r["RiskAnalysisId"] as long?, r["ApprovalStatusCode"] as string, null);
            return new RiskApprovalActionResult(true, riskRegisterId, null, null, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.DecideRegisterAnalysis failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskApprovalActionResult(false, riskRegisterId, null, null, null, ex.Message);
        }
    }

    // SUM() over no rows is NULL, and every count tile in 210 uses SUM.
    private static int NullableInt(object? value)
        => value is null || value == DBNull.Value ? 0 : Convert.ToInt32(value);

    // AVG returns INT for an INT column and FLOAT for a CAST one, so the
    // boxed type varies by tile. Convert rather than cast-match.
    private static double? NullableDouble(object? value)
        => value is null || value == DBNull.Value ? null : Convert.ToDouble(value);

    // NULLABLE, unlike NullableInt above, which coalesces to 0 because
    // its callers are count tiles. Here NULL is meaningful: a threat with
    // organization_id NULL is a SHARED row, and flattening that to 0
    // would claim it belongs to organisation zero. (285, 286)
    private static long? NullableLong(object? value)
        => value is null || value == DBNull.Value ? null : Convert.ToInt64(value);

    // Shared executor for the candidate/register write procs. They all
    // return the same optional columns, so one reader covers them and no
    // action method repeats the open/execute/catch dance.
    private async Task<RiskRegisterActionResult> CandidateActionAsync(
        long? candidateId, string procName, Action<DbCommand> bind, CancellationToken ct)
    {
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, procName);
            bind(cmd);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskRegisterActionResult(
                    true,
                    HasColumn(r, "RiskCandidateId") ? r["RiskCandidateId"] as long? ?? candidateId : candidateId,
                    HasColumn(r, "RiskRegisterId")  ? r["RiskRegisterId"]  as long? : null,
                    HasColumn(r, "RiskNumber")      ? r["RiskNumber"] as string : null,
                    HasColumn(r, "StatusCode")      ? r["StatusCode"] as string : null,
                    null);
            return new RiskRegisterActionResult(true, candidateId, null, null, null, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.{Proc} failed {Id}: {Msg}", procName, candidateId, ex.Message);
            return new RiskRegisterActionResult(false, candidateId, null, null, null, ex.Message);
        }
    }

    // =================================================================
    // Practice / Asset mapping — migrations 261, 262
    //
    // Every method here is a straight pass-through to one procedure. The
    // rules that make mapping correct — one asset row per (risk, asset),
    // contributions as the reason each row exists, removal that will not
    // steal an asset another practice still needs — all live in SQL, in
    // 262, behind constraints. Re-stating any of them in C# would create
    // a second place for them to be wrong.
    // =================================================================
    public async Task<RiskMappingDetail> GetMappingAsync(long riskRegisterId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);

        // THE AUTO-MAPPING REQUIREMENT LIVES HERE.
        //
        // "A risk will already be associated with a Practice when it
        // reaches Risk Analysis, and the assets that are dependencies of
        // that Practice should already be mapped." Nobody clicks anything
        // to make that true, so it has to happen on the read that first
        // shows the scope.
        //
        // sp_risk_mapping_sync_primary is idempotent by construction: it
        // returns immediately when the risk has no linked practice, and
        // again when the Primary row is already correct. So calling it on
        // every mapping read costs one indexed lookup in the steady state
        // and is the only thing that makes the requirement hold for risks
        // registered before these migrations existed.
        //
        // Run as a SEPARATE command, and its result set discarded: it
        // delegates to sp_risk_practice_map, which emits one, and folding
        // that into the read below would make "which result set is the
        // practice list?" depend on whether a sync happened to fire.
        //
        // A failure here must not fail the read. The scope is still
        // displayable without the primary practice, and reporting "scope
        // could not be loaded" because a derivation failed would hide the
        // data that IS there.
        try
        {
            await using var sync = Proc(conn, "grac_practice.sp_risk_mapping_sync_primary");
            AddParam(sync, "@risk_register_id",    DbType.Int64,  riskRegisterId);
            AddParam(sync, "@caller_display_name", DbType.String, "system", 100);
            await sync.ExecuteNonQueryAsync(ct);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.GetMapping: primary-practice sync failed for {Id}: {Msg}",
                riskRegisterId, ex.Message);
        }

        await using var cmd  = Proc(conn, "grac_practice.sp_risk_mapping_get");
        AddParam(cmd, "@risk_register_id", DbType.Int64, riskRegisterId);

        var practices  = new List<RiskMappedPracticeRow>();
        var categories = new List<RiskDependencyCategoryRow>();
        var deps       = new List<RiskMappedDependencyRow>();

        await using var r = await cmd.ExecuteReaderAsync(ct);

        // Result set 1: practices.
        while (await r.ReadAsync(ct))
            practices.Add(new RiskMappedPracticeRow(
                Convert.ToInt64(r["RiskPracticeMapId"]),
                Convert.ToInt64(r["PracticeId"]),
                r["PracticeName"] as string,
                r["PracticeCode"] as string,
                r["MapSourceCode"]?.ToString() ?? "Additional",
                r["IsPrimary"] != DBNull.Value && Convert.ToBoolean(r["IsPrimary"]),
                Convert.ToDateTime(r["MappedDt"]),
                r["MappedByEmployeeId"] as long?,
                r["MappedByName"] as string,
                r["Remarks"] as string,
                NullableInt(r["DependencyCount"])));

        // Result set 2: the categories, straight from dependency_type_master.
        // Every ACTIVE one, including the empty ones — that is how a user
        // discovers a category is available to map into.
        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                categories.Add(new RiskDependencyCategoryRow(
                    Convert.ToInt32(r["DependencyTypeId"]),
                    r["DependencyTypeCode"] as string,
                    r["DependencyTypeName"]?.ToString() ?? "",
                    NullableInt(r["DisplayOrder"]),
                    r["IsSelectable"] != DBNull.Value && Convert.ToBoolean(r["IsSelectable"]),
                    NullableInt(r["MappedCount"])));

        // Result set 3: the mapped dependencies, with provenance resolved.
        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                deps.Add(new RiskMappedDependencyRow(
                    Convert.ToInt64(r["RiskDependencyMapId"]),
                    Convert.ToInt32(r["DependencyTypeId"]),
                    r["DependencyTypeName"] as string,
                    Convert.ToInt64(r["DependencyObjectId"]),
                    r["DependencyObjectName"] as string,
                    Convert.ToDateTime(r["FirstMappedDt"]),
                    r["Remarks"] as string,
                    r["IsDirect"] != DBNull.Value && Convert.ToBoolean(r["IsDirect"]),
                    r["IsInherited"] != DBNull.Value && Convert.ToBoolean(r["IsInherited"]),
                    r["FromPrimaryPractice"] != DBNull.Value && Convert.ToBoolean(r["FromPrimaryPractice"]),
                    r["SourceLabel"]?.ToString() ?? "Additional",
                    NullableInt(r["SourceCount"]),
                    r["SourcePractices"] as string));

        return new RiskMappingDetail(riskRegisterId, practices, categories, deps);
    }

    public async Task<RiskMappingOptions> GetMappingOptionsAsync(
        long riskRegisterId, string? search, int top, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_mapping_options");
        AddParam(cmd, "@risk_register_id", DbType.Int64,  riskRegisterId);
        AddParam(cmd, "@search",           DbType.String, (object?)search ?? DBNull.Value, 200);
        AddParam(cmd, "@top",              DbType.Int32,  Math.Clamp(top <= 0 ? 200 : top, 1, 1000));

        // Practices only. The OBJECTS for each category are fetched by the
        // client from the repository gateway's `dependency-options/query`
        // — the same endpoint the Operationalize picker uses. See
        // RiskMappingOptions for why there is no second implementation.
        var practices = new List<RiskPracticeOption>();

        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            practices.Add(new RiskPracticeOption(
                Convert.ToInt64(r["PracticeId"]),
                r["PracticeName"]?.ToString() ?? "",
                r["PracticeCode"] as string,
                NullableInt(r["DependenciesFromPractice"])));

        return new RiskMappingOptions(practices);
    }

    public async Task<RiskPracticeMapResult> MapPracticeAsync(
        long riskRegisterId, RiskPracticeMapRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.PracticeId <= 0)
            return new RiskPracticeMapResult(false, riskRegisterId, req.PracticeId, null, false, 0, 0, "practiceId is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_practice_map");
            AddParam(cmd, "@risk_register_id",    DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@practice_id",         DbType.Int64,  req.PracticeId);
            // map_source_code is deliberately NOT taken from the client.
            // Only sp_risk_mapping_sync_primary may create a Primary row;
            // anything a user maps is Additional by definition.
            AddParam(cmd, "@map_source_code",     DbType.String, "Additional", 20);
            AddParam(cmd, "@remarks",             DbType.String, (object?)req.Remarks ?? DBNull.Value, 1000);
            AddParam(cmd, "@actor_employee_id",   DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, req.CallerDisplayName ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskPracticeMapResult(true, riskRegisterId,
                    Convert.ToInt64(r["PracticeId"]),
                    r["PracticeName"] as string,
                    r["Created"] != DBNull.Value && Convert.ToBoolean(r["Created"]),
                    NullableInt(r["DependenciesAdded"]),
                    NullableInt(r["ContributionsAdded"]),
                    null);
            return new RiskPracticeMapResult(true, riskRegisterId, req.PracticeId, null, false, 0, 0, null);
        }
        catch (SqlException ex)
        {
            // 56522-56527 are 262's own refusals and name the rule that
            // refused (risk closed, practice from another organisation).
            // Surfaced verbatim, like every other 565xx in this service.
            logger.LogWarning(ex, "RiskCentreService.MapPractice failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskPracticeMapResult(false, riskRegisterId, req.PracticeId, null, false, 0, 0, ex.Message);
        }
    }

    public async Task<RiskPracticeUnmapResult> UnmapPracticeAsync(
        long riskRegisterId, long practiceId, long? actorEmployeeId, string? caller, CancellationToken ct)
    {
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_practice_unmap");
            AddParam(cmd, "@risk_register_id",    DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@practice_id",         DbType.Int64,  practiceId);
            AddParam(cmd, "@actor_employee_id",   DbType.Int64,  (object?)actorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, caller ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskPracticeUnmapResult(true, riskRegisterId, practiceId,
                    r["Removed"] != DBNull.Value && Convert.ToBoolean(r["Removed"]),
                    NullableInt(r["DependenciesRemoved"]),
                    NullableInt(r["DependenciesKept"]),
                    null);
            return new RiskPracticeUnmapResult(true, riskRegisterId, practiceId, false, 0, 0, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.UnmapPractice failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskPracticeUnmapResult(false, riskRegisterId, practiceId, false, 0, 0, ex.Message);
        }
    }

    public async Task<RiskDependencyMapResult> MapDependencyAsync(
        long riskRegisterId, RiskDependencyMapRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.DependencyTypeId <= 0)
            return new RiskDependencyMapResult(false, riskRegisterId, null, req.DependencyTypeId, null,
                req.DependencyObjectId, null, false, "dependencyTypeId is required.");
        if (req.DependencyObjectId <= 0)
            return new RiskDependencyMapResult(false, riskRegisterId, null, req.DependencyTypeId, null,
                req.DependencyObjectId, null, false, "dependencyObjectId is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_dependency_map_direct");
            AddParam(cmd, "@risk_register_id",       DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@dependency_type_id",     DbType.Int32,  req.DependencyTypeId);
            AddParam(cmd, "@dependency_object_id",   DbType.Int64,  req.DependencyObjectId);
            AddParam(cmd, "@dependency_object_name", DbType.String, (object?)req.DependencyObjectName ?? DBNull.Value, 300);
            AddParam(cmd, "@remarks",                DbType.String, (object?)req.Remarks ?? DBNull.Value, 1000);
            AddParam(cmd, "@actor_employee_id",      DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",    DbType.String, req.CallerDisplayName ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskDependencyMapResult(true, riskRegisterId,
                    r["RiskDependencyMapId"] as long?,
                    Convert.ToInt32(r["DependencyTypeId"]),
                    r["DependencyTypeName"] as string,
                    Convert.ToInt64(r["DependencyObjectId"]),
                    r["DependencyObjectName"] as string,
                    r["Created"] != DBNull.Value && Convert.ToBoolean(r["Created"]),
                    null);
            return new RiskDependencyMapResult(true, riskRegisterId, null, req.DependencyTypeId, null,
                req.DependencyObjectId, req.DependencyObjectName, false, null);
        }
        catch (SqlException ex)
        {
            // 56673-56678 are 266's refusals and name the rule that
            // refused (risk closed, unknown or inactive category).
            logger.LogWarning(ex, "RiskCentreService.MapDependency failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskDependencyMapResult(false, riskRegisterId, null, req.DependencyTypeId, null,
                req.DependencyObjectId, req.DependencyObjectName, false, ex.Message);
        }
    }

    public async Task<RiskDependencyUnmapResult> UnmapDependencyAsync(
        long riskRegisterId, int dependencyTypeId, long dependencyObjectId,
        long? actorEmployeeId, string? caller, CancellationToken ct)
    {
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_dependency_unmap");
            AddParam(cmd, "@risk_register_id",     DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@dependency_type_id",   DbType.Int32,  dependencyTypeId);
            AddParam(cmd, "@dependency_object_id", DbType.Int64,  dependencyObjectId);
            AddParam(cmd, "@actor_employee_id",    DbType.Int64,  (object?)actorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",  DbType.String, caller ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskDependencyUnmapResult(true, riskRegisterId, dependencyTypeId, dependencyObjectId,
                    r["DependencyRemoved"] != DBNull.Value && Convert.ToBoolean(r["DependencyRemoved"]),
                    NullableInt(r["RemainingSources"]),
                    null);
            return new RiskDependencyUnmapResult(true, riskRegisterId, dependencyTypeId, dependencyObjectId, false, 0, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.UnmapDependency failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskDependencyUnmapResult(false, riskRegisterId, dependencyTypeId, dependencyObjectId, false, 0, ex.Message);
        }
    }

    // =================================================================
    // Treatment Option — migrations 261, 263
    // =================================================================
    public async Task<RiskTreatmentOptionResult> SetTreatmentOptionAsync(
        long riskRegisterId, RiskTreatmentOptionRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (string.IsNullOrWhiteSpace(req.TreatmentOptionCode))
            return new RiskTreatmentOptionResult(false, riskRegisterId, null, null, null, false, null, null,
                "treatmentOptionCode is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_treatment_option_set");
            AddParam(cmd, "@risk_register_id",      DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@treatment_option_code", DbType.String, req.TreatmentOptionCode, 30);
            AddParam(cmd, "@task_title",            DbType.String, (object?)req.TaskTitle ?? DBNull.Value, 250);
            AddParam(cmd, "@task_description",      DbType.String, (object?)req.TaskDescription ?? DBNull.Value, -1);
            AddParam(cmd, "@target_date",           DbType.DateTime2, (object?)req.TargetDate ?? DBNull.Value);
            AddParam(cmd, "@remark",                DbType.String, (object?)req.Remark ?? DBNull.Value, -1);
            AddParam(cmd, "@actor_employee_id",     DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",   DbType.String, req.CallerDisplayName ?? "system", 100);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskTreatmentOptionResult(true, riskRegisterId,
                    r["TreatmentOptionCode"] as string,
                    r["TreatmentOptionName"] as string,
                    r["TreatmentTaskId"] as long?,
                    r["TaskCreated"] != DBNull.Value && Convert.ToBoolean(r["TaskCreated"]),
                    r["StatusCode"] as string,
                    r["NextStep"] as string,
                    null);
            return new RiskTreatmentOptionResult(true, riskRegisterId, req.TreatmentOptionCode, null, null, false, null, null, null);
        }
        catch (SqlException ex)
        {
            // 56560-56569 are 263's refusals: analysis not complete, risk
            // closed, unknown option. Each names what to do next, so the
            // message goes to the screen unaltered.
            logger.LogWarning(ex, "RiskCentreService.SetTreatmentOption failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskTreatmentOptionResult(false, riskRegisterId, req.TreatmentOptionCode, null, null, false, null, null, ex.Message);
        }
    }

    public async Task<RiskTreatmentState?> GetTreatmentStateAsync(long riskRegisterId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_treatment_state");
        AddParam(cmd, "@risk_register_id", DbType.Int64, riskRegisterId);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;

        var optionCode   = r["TreatmentOptionCode"] as string;
        var statusCode   = r["StatusCode"] as string;
        var taskCount    = NullableInt(r["TreatmentTaskCount"]);
        var openCount    = NullableInt(r["OpenTreatmentTaskCount"]);
        var closedCount  = NullableInt(r["ClosedTreatmentTaskCount"]);
        var openSubCount = NullableInt(r["OpenSubTaskCount"]);
        var available    = r["ResidualAvailable"] != DBNull.Value && Convert.ToBoolean(r["ResidualAvailable"]);
        var pending      = r["ResidualPending"] == DBNull.Value || Convert.ToBoolean(r["ResidualPending"]);
        var reason       = r["Reason"] as string;

        var tasks = new List<RiskTreatmentTaskRow>();
        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                tasks.Add(new RiskTreatmentTaskRow(
                    Convert.ToInt64(r["TaskId"]),
                    r["TaskNumber"] as string,
                    r["Title"] as string,
                    r["StatusCode"] as string,
                    r["StatusName"] as string,
                    r["IsTerminal"] != DBNull.Value && Convert.ToBoolean(r["IsTerminal"]),
                    r["OwnerEmployeeId"] as long?,
                    r["OwnerName"] as string,
                    r["Priority"] as string,
                    r["DueAt"] as DateTime?,
                    r["ClosedAt"] as DateTime?,
                    r["IsChild"] != DBNull.Value && Convert.ToBoolean(r["IsChild"]),
                    r["ParentTaskId"] as long?,
                    NullableInt(r["ChildCount"]),
                    NullableInt(r["MandatoryChildOpenCount"]),
                    r["RaisedDt"] as DateTime?));

        return new RiskTreatmentState(riskRegisterId, optionCode, statusCode,
            taskCount, openCount, closedCount, openSubCount,
            available, pending, reason, tasks);
    }

    public async Task<int> SyncTreatmentAsync(
        long? riskRegisterId, long? organizationId, string? caller, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_treatment_sync");
        AddParam(cmd, "@risk_register_id",    DbType.Int64,  (object?)riskRegisterId ?? DBNull.Value);
        AddParam(cmd, "@organization_id",     DbType.Int64,  (object?)organizationId ?? DBNull.Value);
        AddParam(cmd, "@caller_display_name", DbType.String, caller ?? "system", 100);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (await r.ReadAsync(ct)) return NullableInt(r["RisksMovedToMonitoring"]);
        return 0;
    }

    // =================================================================
    // Acceptance, Review and the Risk Calendar — migration 264
    // =================================================================
    public async Task<RiskAcceptanceDetail?> GetAcceptanceAsync(long riskRegisterId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_acceptance_get");
        AddParam(cmd, "@risk_register_id", DbType.Int64, riskRegisterId);

        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;

        return new RiskAcceptanceDetail(
            Convert.ToInt64(r["RiskRegisterId"]),
            r["RiskNumber"] as string,
            r["RiskTitle"] as string,
            r["StatusCode"] as string,
            r["RiskOwnerEmployeeId"] as long?,
            r["RiskOwnerName"] as string,
            r["TreatmentOptionCode"] as string,
            r["TreatmentOptionName"] as string,
            r["InherentRatingCode"] as string,
            r["ResidualRatingCode"] as string,
            r["ResidualPending"] == DBNull.Value || Convert.ToBoolean(r["ResidualPending"]),
            r["AnalysisPending"] == DBNull.Value || Convert.ToBoolean(r["AnalysisPending"]),
            r["AcceptedByEmployeeId"] as long?,
            r["AcceptedByName"] as string,
            // 291. HasColumn-guarded: an API deployed ahead of its
            // migration would otherwise throw on every acceptance read
            // over a column that only enriches a label. Absent, the UI
            // shows the bare name, exactly as it did before.
            HasColumn(r, "AcceptedByRoleNames") ? r["AcceptedByRoleNames"] as string : null,
            r["AcceptedOn"] as DateTime?,
            r["AcceptanceNote"] as string,
            // 293, guarded the same way and for the same reason as 291's
            // column above: an API deployed ahead of its migration must
            // still read an acceptance. Absent, the modal simply opens
            // with no frequency preselected and the date stays manual --
            // exactly how it behaved before 293.
            HasColumn(r, "ReviewFrequencyId")   ? r["ReviewFrequencyId"] as int?     : null,
            HasColumn(r, "ReviewFrequencyName") ? r["ReviewFrequencyName"] as string : null,
            r["NextReviewDate"] as DateTime?,
            r["LastReviewedOn"] as DateTime?,
            NullableInt(r["ReviewCount"]),
            r["WorkflowStageCode"] as string,
            NullableInt(r["OpenTreatmentTaskCount"]),
            r["CanAccept"] != DBNull.Value && Convert.ToBoolean(r["CanAccept"]),
            r["AcceptGuidance"] as string);
    }

    public async Task<RiskAcceptanceResult> SaveAcceptanceAsync(
        long riskRegisterId, RiskAcceptanceSaveRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);

        // Checked here as well as in SQL, purely so the common mistake
        // gets a fast, plain answer instead of a SqlException. The
        // procedure's THROW is still the rule — this is the courtesy.
        if (req.NextReviewDate == default)
            return new RiskAcceptanceResult(false, riskRegisterId, null, null, null, null, null, null,
                "nextReviewDate is required — without one this risk would never return for review.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_acceptance_save");
            AddParam(cmd, "@risk_register_id",        DbType.Int64, riskRegisterId);
            AddParam(cmd, "@next_review_date",        DbType.Date,  req.NextReviewDate.Date);
            AddParam(cmd, "@accepted_by_employee_id", DbType.Int64, (object?)req.AcceptedByEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@accepted_date",           DbType.Date,  (object?)req.AcceptedDate?.Date ?? DBNull.Value);
            AddParam(cmd, "@acceptance_note",         DbType.String, (object?)req.AcceptanceNote ?? DBNull.Value, -1);
            AddParam(cmd, "@actor_employee_id",       DbType.Int64, (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",     DbType.String, req.CallerDisplayName ?? "system", 100);
            // 293. Null is a legitimate value, not an omission: a Custom
            // or Event-driven acceptance has a date the user typed and no
            // cadence behind it. The procedure defaults the parameter to
            // NULL, so sending it explicitly changes nothing for a caller
            // that leaves the select empty.
            AddParam(cmd, "@review_frequency_id",     DbType.Int32, (object?)req.ReviewFrequencyId ?? DBNull.Value);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (await r.ReadAsync(ct))
                return new RiskAcceptanceResult(true, riskRegisterId,
                    r["RiskNumber"] as string,
                    r["AcceptedByEmployeeId"] as long?,
                    r["AcceptedByName"] as string,
                    r["AcceptedOn"] as DateTime?,
                    r["NextReviewDate"] as DateTime?,
                    r["StatusCode"] as string,
                    null);
            return new RiskAcceptanceResult(true, riskRegisterId, null, null, null, null, req.NextReviewDate, "Accepted", null);
        }
        catch (SqlException ex)
        {
            // 56600-56608 are 264's refusals: missing or past review
            // date, analysis incomplete, no treatment option. Each says
            // what to fix.
            logger.LogWarning(ex, "RiskCentreService.SaveAcceptance failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskAcceptanceResult(false, riskRegisterId, null, null, null, null, null, null, ex.Message);
        }
    }

    // =================================================================
    // Review frequency lookup — migration 293
    //
    // No organizationId: frequency_master is a master table, and the
    // cadences an organisation may choose from are not per-tenant. The
    // procedure filters is_active and orders by display_order, so the
    // client neither filters nor sorts.
    //
    // FrequencyValue / FrequencyUnit are carried through untouched
    // because they are the whole point: the Acceptance screen derives
    // "Quarterly = today + 3 months" from them. Collapsing them into a
    // label here would push that arithmetic back into a hard-coded
    // switch in JavaScript, which is what 293's header refuses.
    // =================================================================
    public async Task<IReadOnlyList<RiskReviewFrequencyRow>> ListReviewFrequenciesAsync(CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_review_frequency_list");

        var rows = new List<RiskReviewFrequencyRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new RiskReviewFrequencyRow(
                Convert.ToInt32(r["FrequencyId"]),
                r["FrequencyCode"] as string,
                r["FrequencyName"]?.ToString() ?? "",
                // Nullable, and meaningfully so: Event Driven, Continuous
                // and Custom carry no value or unit, which is how the
                // client knows there is no date to derive.
                r["FrequencyValue"] as int?,
                r["FrequencyUnit"] as string,
                r["IsCustom"] != DBNull.Value && Convert.ToBoolean(r["IsCustom"])));
        return rows;
    }

    public async Task<RiskReviewDueListResult> ListReviewDueAsync(
        long organizationId, long? ownerEmployeeId, string? ratingCode, string? search,
        int? includeFutureDays, int page, int pageSize, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_review_due_list");
        AddParam(cmd, "@organization_id",     DbType.Int64,  organizationId);
        AddParam(cmd, "@owner_employee_id",   DbType.Int64,  (object?)ownerEmployeeId ?? DBNull.Value);
        AddParam(cmd, "@rating_code",         DbType.String, (object?)ratingCode ?? DBNull.Value, 30);
        AddParam(cmd, "@search",              DbType.String, (object?)search ?? DBNull.Value, 200);
        AddParam(cmd, "@include_future_days", DbType.Int32,  (object?)includeFutureDays ?? DBNull.Value);
        AddParam(cmd, "@page_number",         DbType.Int32,  Math.Max(1, page));
        AddParam(cmd, "@page_size",           DbType.Int32,  Math.Clamp(pageSize <= 0 ? 25 : pageSize, 1, 200));

        var rows = new List<RiskReviewDueRow>();
        long total = 0;
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            rows.Add(new RiskReviewDueRow(
                Convert.ToInt64(r["RiskRegisterId"]),
                r["RiskNumber"]?.ToString() ?? "",
                r["RiskTitle"]?.ToString() ?? "",
                r["RiskStatement"] as string,
                r["RiskCategoryName"] as string,
                r["StatusCode"]?.ToString() ?? "",
                r["RiskOwnerEmployeeId"] as long?,
                r["RiskOwnerName"] as string,
                r["BusinessUnit"] as string,
                r["InherentRatingCode"] as string,
                r["InherentRatingName"] as string,
                r["ResidualRatingCode"] as string,
                r["ResidualRatingName"] as string,
                r["TreatmentOptionCode"] as string,
                r["TreatmentOptionName"] as string,
                r["AcceptedOn"] as DateTime?,
                r["AcceptedByName"] as string,
                r["NextReviewDate"] as DateTime?,
                r["LastReviewedOn"] as DateTime?,
                NullableInt(r["ReviewCount"]),
                NullableInt(r["DaysOverdue"]),
                r["IsDue"] != DBNull.Value && Convert.ToBoolean(r["IsDue"]),
                r["WorkflowStageCode"] as string));
            total = Convert.ToInt64(r["TotalRows"]);
        }
        return new RiskReviewDueListResult(total, page, pageSize, rows);
    }

    public async Task<IReadOnlyList<RiskCalendarEventRow>> GetReviewCalendarAsync(
        long organizationId, DateTime? fromDate, DateTime? toDate, long? ownerEmployeeId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_review_calendar");
        AddParam(cmd, "@organization_id",   DbType.Int64, organizationId);
        AddParam(cmd, "@from_date",         DbType.Date,  (object?)fromDate?.Date ?? DBNull.Value);
        AddParam(cmd, "@to_date",           DbType.Date,  (object?)toDate?.Date ?? DBNull.Value);
        AddParam(cmd, "@owner_employee_id", DbType.Int64, (object?)ownerEmployeeId ?? DBNull.Value);

        var rows = new List<RiskCalendarEventRow>();
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new RiskCalendarEventRow(
                Convert.ToInt64(r["RiskRegisterId"]),
                r["RiskNumber"]?.ToString() ?? "",
                r["RiskTitle"]?.ToString() ?? "",
                Convert.ToDateTime(r["EventDate"]),
                r["StatusCode"]?.ToString() ?? "",
                r["RiskCategoryName"] as string,
                r["RiskOwnerEmployeeId"] as long?,
                r["RiskOwnerName"] as string,
                r["BusinessUnit"] as string,
                r["InherentRatingCode"] as string,
                r["ResidualRatingCode"] as string,
                r["EffectiveRatingCode"] as string,
                r["TreatmentOptionCode"] as string,
                r["TreatmentOptionName"] as string,
                r["AcceptedOn"] as DateTime?,
                r["AcceptedByName"] as string,
                NullableInt(r["ReviewCount"]),
                r["IsOverdue"] != DBNull.Value && Convert.ToBoolean(r["IsOverdue"]),
                r["IsToday"] != DBNull.Value && Convert.ToBoolean(r["IsToday"]),
                r["WorkflowStageCode"] as string));
        return rows;
    }

    public async Task<RiskReviewPerformResult> PerformReviewAsync(
        long riskRegisterId, RiskReviewPerformRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (string.IsNullOrWhiteSpace(req.RiskCategoryCode))
            return new RiskReviewPerformResult(false, riskRegisterId, null, null, null, null, "riskCategoryCode is required.");
        if (string.IsNullOrWhiteSpace(req.LikelihoodCode))
            return new RiskReviewPerformResult(false, riskRegisterId, null, null, null, null, "likelihoodCode is required.");
        if (string.IsNullOrWhiteSpace(req.ImpactCode))
            return new RiskReviewPerformResult(false, riskRegisterId, null, null, null, null, "impactCode is required.");
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_review_perform");
            AddParam(cmd, "@risk_register_id",        DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@risk_category_code",      DbType.String, req.RiskCategoryCode, 60);
            AddParam(cmd, "@likelihood_code",         DbType.String, req.LikelihoodCode, 60);
            AddParam(cmd, "@impact_code",             DbType.String, req.ImpactCode, 60);
            AddParam(cmd, "@risk_cause",              DbType.String, (object?)req.RiskCause ?? DBNull.Value, -1);
            AddParam(cmd, "@potential_consequence",   DbType.String, (object?)req.PotentialConsequence ?? DBNull.Value, -1);
            AddParam(cmd, "@existing_controls",       DbType.String, (object?)req.ExistingControls ?? DBNull.Value, -1);
            AddParam(cmd, "@risk_description",        DbType.String, (object?)req.RiskDescription ?? DBNull.Value, -1);
            AddParam(cmd, "@process_name",            DbType.String, (object?)req.ProcessName ?? DBNull.Value, 200);
            AddParam(cmd, "@review_remarks",          DbType.String, (object?)req.ReviewRemarks ?? DBNull.Value, -1);
            AddParam(cmd, "@treatment_option_code",   DbType.String, (object?)req.TreatmentOptionCode ?? DBNull.Value, 30);
            AddParam(cmd, "@next_review_date",        DbType.Date,   (object?)req.NextReviewDate?.Date ?? DBNull.Value);
            AddParam(cmd, "@reviewed_by_employee_id", DbType.Int64,  (object?)req.ReviewedByEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",     DbType.String, req.CallerDisplayName ?? "system", 100);
            // 299. The proposed cadence, stored on the risk so the Accept
            // screen opens with it preselected.
            AddParam(cmd, "@review_frequency_id",     DbType.Int32,  (object?)req.ReviewFrequencyId ?? DBNull.Value);

            // The procedure emits sp_risk_register_assess's result set
            // FIRST (it EXECs it without suppressing output), then its
            // own. Skipping to the last result set is what gets the
            // review's answer rather than the analysis's.
            await using var r = await cmd.ExecuteReaderAsync(ct);
            RiskReviewPerformResult? result = null;
            do
            {
                while (await r.ReadAsync(ct))
                {
                    if (!HasColumn(r, "RiskNumber")) continue;   // the assess result set
                    result = new RiskReviewPerformResult(true, riskRegisterId,
                        r["RiskNumber"] as string,
                        r["StatusCode"] as string,
                        r["NextReviewDate"] as DateTime?,
                        r["TreatmentOptionCode"] as string,
                        null);
                }
            } while (await r.NextResultAsync(ct));

            return result ?? new RiskReviewPerformResult(true, riskRegisterId, null, null, req.NextReviewDate, req.TreatmentOptionCode, null);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.PerformReview failed {Id}: {Msg}", riskRegisterId, ex.Message);
            return new RiskReviewPerformResult(false, riskRegisterId, null, null, null, null, ex.Message);
        }
    }

    /// <summary>
    /// Bulk review (270). Returns one row per selected risk saying what
    /// happened to it.
    ///
    /// <para>A SqlException here means the BATCH was rejected — an empty
    /// selection, a past review date, an attempt to close in bulk. A risk
    /// that individually failed a rule is not an exception: it comes back
    /// as a <c>Skipped</c> row with its reason, because that is
    /// information the user needs, not a fault.</para>
    /// </summary>
    public async Task<RiskBulkReviewResult> BulkReviewAsync(RiskBulkReviewRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);

        if (req.RiskRegisterIds is null || req.RiskRegisterIds.Count == 0)
            return new RiskBulkReviewResult(false, Array.Empty<RiskBulkReviewRow>(),
                                            "Select at least one risk.");

        // Rejected here as well as in SQL (56724) so the user is told
        // before a round trip, not after.
        if (string.Equals(req.StatusCode, "Closed", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(req.StatusCode, "Retired", StringComparison.OrdinalIgnoreCase))
            return new RiskBulkReviewResult(false, Array.Empty<RiskBulkReviewRow>(),
                "Closing or retiring is not a bulk action — each needs its own reason (BRD §20).");

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_bulk_review");

            // Comma-separated, matching the procedure's STRING_SPLIT. The
            // ids are longs already parsed by the model binder, so this
            // cannot carry anything but digits and commas.
            AddParam(cmd, "@risk_register_ids", DbType.String,
                     string.Join(",", req.RiskRegisterIds), -1);
            AddParam(cmd, "@review_remarks",    DbType.String, (object?)req.ReviewRemarks ?? DBNull.Value, -1);
            AddParam(cmd, "@status_code",       DbType.String, (object?)req.StatusCode ?? DBNull.Value, 30);
            AddParam(cmd, "@next_review_date",  DbType.Date,   (object?)req.NextReviewDate?.Date ?? DBNull.Value);
            AddParam(cmd, "@reviewed_by_employee_id", DbType.Int64, (object?)req.ReviewedByEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",     DbType.String, req.CallerDisplayName ?? "system", 100);
            // 294. Reaches sp_risk_acceptance_save when the status is
            // Accepted, so a bulk acceptance records the same cadence a
            // single one does. 56726 refuses an unknown or inactive id
            // once for the batch rather than per risk.
            AddParam(cmd, "@review_frequency_id",     DbType.Int32, (object?)req.ReviewFrequencyId ?? DBNull.Value);

            var rows = new List<RiskBulkReviewRow>();
            await using var r = await cmd.ExecuteReaderAsync(ct);

            // 294 makes the procedure return exactly one result set. This
            // guard is for the database that has NOT had 294 applied yet:
            // 270 EXEC'd sp_risk_acceptance_save / _status_set bare inside
            // its loop, and both end with a SELECT, so one result set per
            // status change arrived AHEAD of the report. Reading the first
            // reader then threw IndexOutOfRange on "Outcome" — which is
            // not a SqlException, so it escaped the catch below as a 500.
            //
            // Skipping to the set that actually carries Outcome costs one
            // check against a fixed database and rescues an unfixed one.
            while (!HasColumn(r, "Outcome") && await r.NextResultAsync(ct)) { }

            while (await r.ReadAsync(ct))
            {
                rows.Add(new RiskBulkReviewRow(
                    Convert.ToInt64(r["RiskRegisterId"]),
                    r["RiskNumber"]     as string,
                    r["RiskTitle"]      as string,
                    r["Outcome"]?.ToString() ?? "Skipped",
                    r["Reason"]         as string,
                    r["FromStatus"]     as string,
                    r["ToStatus"]       as string,
                    r["FromReviewDate"] as DateTime?,
                    r["ToReviewDate"]   as DateTime?));
            }

            return new RiskBulkReviewResult(true, rows);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.BulkReview failed for {Count} risk(s): {Msg}",
                              req.RiskRegisterIds.Count, ex.Message);
            return new RiskBulkReviewResult(false, Array.Empty<RiskBulkReviewRow>(), ex.Message);
        }
    }

    // =================================================================
    // Bulk accept — migration 295
    //
    // Not a loop over SaveAcceptanceAsync: that would be N round trips
    // and N transactions from the client, with no way to report a
    // partial outcome as one answer. sp_risk_bulk_accept does the loop
    // where the data is and returns one row per risk.
    // =================================================================
    public async Task<RiskBulkAcceptResult> BulkAcceptAsync(
        RiskBulkAcceptRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);

        if (req.RiskRegisterIds is null || req.RiskRegisterIds.Count == 0)
            return new RiskBulkAcceptResult(false, Array.Empty<RiskBulkAcceptRow>(),
                                            "Select at least one risk.");

        // Checked here as well as in SQL (56751/56752) so the common
        // mistake gets a plain answer instead of a SqlException.
        if (req.NextReviewDate == default)
            return new RiskBulkAcceptResult(false, Array.Empty<RiskBulkAcceptRow>(),
                "nextReviewDate is required — without one these risks would never return for review.");

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_bulk_accept");

            // Comma separated, matching the procedure's STRING_SPLIT. The
            // ids are longs already parsed by the model binder, so this
            // cannot carry anything but digits and commas.
            AddParam(cmd, "@risk_register_ids", DbType.String,
                     string.Join(",", req.RiskRegisterIds), -1);
            AddParam(cmd, "@next_review_date",        DbType.Date,   req.NextReviewDate.Date);
            AddParam(cmd, "@accepted_by_employee_id", DbType.Int64,  (object?)req.AcceptedByEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@accepted_date",           DbType.Date,   (object?)req.AcceptedDate?.Date ?? DBNull.Value);
            AddParam(cmd, "@acceptance_note",         DbType.String, (object?)req.AcceptanceNote ?? DBNull.Value, -1);
            AddParam(cmd, "@review_frequency_id",     DbType.Int32,  (object?)req.ReviewFrequencyId ?? DBNull.Value);
            AddParam(cmd, "@actor_employee_id",       DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name",     DbType.String, req.CallerDisplayName ?? "system", 100);

            var rows = new List<RiskBulkAcceptRow>();
            await using var r = await cmd.ExecuteReaderAsync(ct);

            // 295 returns exactly one result set by construction (its only
            // EXEC is an INSERT ... EXEC). Guarded anyway, for the same
            // reason BulkReviewAsync is: it costs one check and it means a
            // future change that reintroduces a streamed inner result set
            // degrades instead of throwing IndexOutOfRange out of a
            // catch that only handles SqlException.
            while (!HasColumn(r, "Outcome") && await r.NextResultAsync(ct)) { }

            while (await r.ReadAsync(ct))
            {
                rows.Add(new RiskBulkAcceptRow(
                    Convert.ToInt64(r["RiskRegisterId"]),
                    r["RiskNumber"]     as string,
                    r["RiskTitle"]      as string,
                    r["Outcome"]?.ToString() ?? "Skipped",
                    r["Reason"]         as string,
                    r["FromStatus"]     as string,
                    r["ToStatus"]       as string,
                    r["AcceptedOn"]     as DateTime?,
                    r["NextReviewDate"] as DateTime?));
            }

            return new RiskBulkAcceptResult(true, rows);
        }
        catch (SqlException ex)
        {
            // 56750-56754 are 295's batch refusals; 56601-56608 cannot
            // reach here, because per-risk failures are reported as rows.
            logger.LogWarning(ex, "RiskCentreService.BulkAccept failed for {Count} risk(s): {Msg}",
                              req.RiskRegisterIds.Count, ex.Message);
            return new RiskBulkAcceptResult(false, Array.Empty<RiskBulkAcceptRow>(), ex.Message);
        }
    }

    // =================================================================
    // Risk acceptance approval authority — migration 271
    //
    // The read and the save return the SAME shape, because
    // sp_org_risk_acceptance_authority_save ends by calling the get:
    // the page re-renders from what the database now holds rather than
    // from what it hoped it sent. One reader serves both.
    // =================================================================

    /// <summary>
    /// Three result sets: the levels (derived from the organisation's own
    /// risk matrix, not a fixed list), the roles it has, and the
    /// migration-212 settings an unconfigured level falls back to.
    /// </summary>
    private async Task<RiskAcceptanceAuthorityResult> ReadAuthorityAsync(DbCommand cmd, CancellationToken ct)
    {
        var levels = new List<RiskAcceptanceAuthorityRow>();
        var roles  = new List<RiskAuthorityRoleOption>();
        RiskAuthorityFallback? fallback = null;

        await using var r = await cmd.ExecuteReaderAsync(ct);

        while (await r.ReadAsync(ct))
        {
            levels.Add(new RiskAcceptanceAuthorityRow(
                r["RatingCode"]?.ToString() ?? "",
                r["RatingName"] as string,
                r["Severity"] as int?,
                r["InherentRoleId"]   as long?,
                r["InherentRoleName"] as string,
                r["ResidualRoleId"]   as long?,
                r["ResidualRoleName"] as string,
                Convert.ToBoolean(r["ResidualSameAsInherent"]),
                r["EffectiveInherentRoleId"]   as long?,
                r["EffectiveInherentRoleName"] as string,
                r["EffectiveResidualRoleId"]   as long?,
                r["EffectiveResidualRoleName"] as string,
                Convert.ToBoolean(r["InherentUsesFallback"]),
                Convert.ToBoolean(r["ResidualUsesFallback"])));
        }

        if (await r.NextResultAsync(ct))
            while (await r.ReadAsync(ct))
                roles.Add(new RiskAuthorityRoleOption(
                    Convert.ToInt64(r["RoleId"]), r["RoleName"]?.ToString() ?? ""));

        if (await r.NextResultAsync(ct) && await r.ReadAsync(ct))
            fallback = new RiskAuthorityFallback(
                r["ApprovalRequired"] is bool b && b,
                r["ApprovalMinRatingCode"] as string,
                r["FallbackRoleId"]        as long?,
                r["FallbackRoleName"]      as string);

        return new RiskAcceptanceAuthorityResult(levels, roles, fallback);
    }

    public async Task<RiskAcceptanceAuthorityResult> GetAcceptanceAuthorityAsync(
        long organizationId, CancellationToken ct)
    {
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_org_risk_acceptance_authority_get");
            AddParam(cmd, "@organization_id", DbType.Int64, organizationId);
            return await ReadAuthorityAsync(cmd, ct);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.GetAcceptanceAuthority failed for org {Org}", organizationId);
            return new RiskAcceptanceAuthorityResult(
                Array.Empty<RiskAcceptanceAuthorityRow>(),
                Array.Empty<RiskAuthorityRoleOption>(),
                null, false, ex.Message);
        }
    }

    /// <summary>
    /// Saves the whole grid. The procedure validates every rating against
    /// the organisation's matrix (56745), every role against the
    /// organisation (56746), and refuses "same as inherent" where no
    /// inherent approver exists (56747) — all BEFORE writing anything, so
    /// a rejected save leaves the configuration exactly as it was.
    /// </summary>
    public async Task<RiskAcceptanceAuthorityResult> SaveAcceptanceAuthorityAsync(
        RiskAcceptanceAuthoritySaveRequest req, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(req);
        if (req.Rows is null || req.Rows.Count == 0)
            return new RiskAcceptanceAuthorityResult(
                Array.Empty<RiskAcceptanceAuthorityRow>(),
                Array.Empty<RiskAuthorityRoleOption>(),
                null, false, "No rows were supplied.");

        // camelCase to match the OPENJSON ... WITH paths in the procedure.
        var json = System.Text.Json.JsonSerializer.Serialize(
            req.Rows.Select(x => new
            {
                ratingCode             = x.RatingCode,
                inherentRoleId         = x.InherentRoleId,
                residualRoleId         = x.ResidualRoleId,
                residualSameAsInherent = x.ResidualSameAsInherent
            }));

        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_org_risk_acceptance_authority_save");
            AddParam(cmd, "@organization_id",     DbType.Int64,  req.OrganizationId);
            AddParam(cmd, "@rows_json",           DbType.String, json, -1);
            AddParam(cmd, "@actor_employee_id",   DbType.Int64,  (object?)req.ActorEmployeeId ?? DBNull.Value);
            AddParam(cmd, "@caller_display_name", DbType.String, req.CallerDisplayName ?? "system", 100);

            // The save ends by re-running the get, so this is the state as
            // stored — not an echo of the request.
            return await ReadAuthorityAsync(cmd, ct);
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.SaveAcceptanceAuthority failed for org {Org}: {Msg}",
                              req.OrganizationId, ex.Message);
            return new RiskAcceptanceAuthorityResult(
                Array.Empty<RiskAcceptanceAuthorityRow>(),
                Array.Empty<RiskAuthorityRoleOption>(),
                null, false, ex.Message);
        }
    }

    /// <summary>
    /// Who may approve accepting this risk. The single answer, so the
    /// acceptance screen and any future queue or notification cannot
    /// disagree. <c>scopeCode</c> NULL lets the procedure decide from the
    /// risk (Residual once residually assessed, otherwise Inherent).
    /// </summary>
    public async Task<RiskAcceptanceAuthorityResolved?> ResolveAcceptanceAuthorityAsync(
        long riskRegisterId, string? scopeCode, CancellationToken ct)
    {
        try
        {
            await using var conn = await OpenAsync(ct);
            await using var cmd  = Proc(conn, "grac_practice.sp_risk_acceptance_authority_resolve");
            AddParam(cmd, "@risk_register_id", DbType.Int64,  riskRegisterId);
            AddParam(cmd, "@scope_code",       DbType.String, (object?)scopeCode ?? DBNull.Value, 20);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (!await r.ReadAsync(ct)) return null;

            return new RiskAcceptanceAuthorityResolved(
                Convert.ToInt64(r["RiskRegisterId"]),
                r["RiskNumber"] as string,
                Convert.ToInt64(r["OrganizationId"]),
                r["ScopeCode"]?.ToString() ?? "Inherent",
                r["RatingCode"] as string,
                r["ApproverRoleId"]   as long?,
                r["ApproverRoleName"] as string,
                r["ResolvedFrom"]?.ToString() ?? "NotConfigured");
        }
        catch (SqlException ex)
        {
            logger.LogWarning(ex, "RiskCentreService.ResolveAcceptanceAuthority failed for risk {Id}", riskRegisterId);
            return null;
        }
    }

    private static bool HasColumn(DbDataReader reader, string name)
    {
        for (var i = 0; i < reader.FieldCount; i++)
            if (string.Equals(reader.GetName(i), name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    // ---- helpers (same pattern as ExceptionCentreService) ----
    // =================================================================
    // Risk scope: practice context + tasks (migration 284)
    //
    // Two result sets from sp_risk_scope_practice_context. Read-only.
    // The caller groups tasks under their practice by PracticeId; the
    // procedure already orders them that way.
    // =================================================================
    public async Task<RiskScopePracticeContextResult> GetScopePracticeContextAsync(
        long organizationId, long riskRegisterId, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd  = Proc(conn, "grac_practice.sp_risk_scope_practice_context");
        AddParam(cmd, "@organization_id",  DbType.Int64, organizationId);
        AddParam(cmd, "@risk_register_id", DbType.Int64, riskRegisterId);

        var practices = new List<RiskScopePracticeContext>();
        var tasks     = new List<RiskScopePracticeTask>();

        // Columns are read inline with Convert / `as`, matching the rest
        // of this service rather than introducing a second reader style.
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            practices.Add(new RiskScopePracticeContext(
                Convert.ToInt64(reader["PracticeId"]),
                reader["PracticeCode"]       as string,
                reader["PracticeName"]       as string,
                reader["FrameworkName"]      as string,
                reader["StructureRootName"]  as string,
                reader["StatementReference"] as string,
                reader["StatementTitle"]     as string,
                NullableInt(reader["TaskCount"])));
        }

        if (await reader.NextResultAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                tasks.Add(new RiskScopePracticeTask(
                    Convert.ToInt64(reader["TaskId"]),
                    reader["PracticeId"] == DBNull.Value ? null : Convert.ToInt64(reader["PracticeId"]),
                    reader["Title"]      as string,
                    reader["StatusName"] as string,
                    reader["Priority"]   as string,
                    reader["DueAt"] == DBNull.Value ? null : Convert.ToDateTime(reader["DueAt"]),
                    reader["AssignedTo"] as string));
            }
        }

        return new RiskScopePracticeContextResult(practices, tasks);
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
    private static void AddParam(DbCommand command, string name, DbType type, object? value, int? size = null)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType = type;
        if (size.HasValue) p.Size = size.Value;
        p.Value = value ?? DBNull.Value;
        command.Parameters.Add(p);
    }
    private static DbParameter AddOutput(DbCommand command, string name, DbType type)
    {
        var p = command.CreateParameter();
        p.ParameterName = name;
        p.DbType = type;
        p.Direction = ParameterDirection.Output;
        p.Value = DBNull.Value;
        command.Parameters.Add(p);
        return p;
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
