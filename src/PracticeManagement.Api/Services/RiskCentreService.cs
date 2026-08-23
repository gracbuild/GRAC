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
    Task<RiskRegisterListResult>             ListRegisterAsync(long organizationId, string? statusCode, string? sourceTypeCode, string? categoryCode, string? ratingCode, long? ownerEmployeeId, string? search, int page, int pageSize, CancellationToken ct);
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
    Task<RiskRegisterAssessResult>            AssessRegisteredRiskAsync(long riskRegisterId, RiskRegisterAssessRequest req, CancellationToken ct);
    Task<RiskApprovalActionResult>            DecideRegisterAnalysisAsync(long riskRegisterId, RiskApprovalDecisionRequest req, CancellationToken ct);
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
                    r["Description"] as string));

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
        string? ratingCode, long? ownerEmployeeId, string? search, int page, int pageSize, CancellationToken ct)
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
                Convert.ToInt64(r["RiskAnalysisId"]),
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
                Convert.ToBoolean(r["AnalysisPending"]),
                r["ThreatName"] as string,
                r["VulnerabilityName"] as string,
                r["BusinessFunctionName"] as string));
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
            r["AnalysisApprovalStatusCode"] as string);
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

    private static bool HasColumn(DbDataReader reader, string name)
    {
        for (var i = 0; i < reader.FieldCount; i++)
            if (string.Equals(reader.GetName(i), name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    // ---- helpers (same pattern as ExceptionCentreService) ----
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
