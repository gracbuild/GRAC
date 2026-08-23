// =====================================================================
// RiskCentreModels  (charter §5)
// Request/response contracts for RiskCentreController. Mirrors
// ExceptionCentreModels for consistency across governance modules.
// =====================================================================
using Microsoft.AspNetCore.Http;

namespace PracticeManagement.Api.Models;

// Status vocabulary after migration 205 (BRD §16). 'Pending' is the
// stored code for BRD's "New" — see 205's header for why the legacy word
// was kept. 'Accepted' is the legacy pre-register triage state.
//   Pending | UnderAnalysis | ClarificationRequired | AnalysisCompleted
//   | Registered | Rejected | ClosedAsDuplicate | Withdrawn | Accepted
public sealed record RiskCandidateRow(
    long RiskCandidateId,
    long OrganizationId,
    long? CustomGapId,           // nullable since 205 — non-gap sources exist
    string? GapTitle,
    string CandidateTitle,
    string? SeverityCode,
    string StatusCode,
    DateTime RequestedOn,
    string? RequestedByName,
    DateTime? AcceptedOn,
    string? AcceptedByName,
    DateTime? RejectedOn,
    string? RejectedByName,
    string? FormalRiskRef,
    int AttachmentCount,
    // ---- added with the Risk Register (migrations 205-207) ----------
    string? CandidateNumber,
    string? SourceTypeCode,
    string? SourceName,
    long? SourceRecordId,
    string? SourceReference,
    string? SourceCentreCode,
    DateTime? IdentifiedOn,
    long? AssignedAnalystEmployeeId,
    string? AssignedAnalystName,
    long? RegisteredRiskId,
    string? RegisteredRiskNumber,
    long? DuplicateOfRiskId,
    long? CurrentAnalysisId,
    int? CurrentAnalysisVersion,
    string? InherentRatingCode);

public sealed record RiskCandidateListResult(
    long TotalRows, int Page, int PageSize,
    IReadOnlyList<RiskCandidateRow> Rows);

public sealed record RiskCandidateDetail(
    long RiskCandidateId,
    long OrganizationId,
    long? CustomGapId,
    string? GapTitle,
    string CandidateTitle,
    string? CandidateSummary,
    string? SeverityCode,
    string? SeverityName,
    string? ImpactSummary,
    string? LikelihoodSummary,
    string StatusCode,
    long? RequestedByEmployeeId,
    string? RequestedByName,
    DateTime RequestedOn,
    long? AcceptedByEmployeeId,
    string? AcceptedByName,
    DateTime? AcceptedOn,
    string? AcceptanceNote,
    string? FormalRiskRef,
    long? RejectedByEmployeeId,
    string? RejectedByName,
    DateTime? RejectedOn,
    string? RejectionReason,
    // ---- added with the Risk Register (migrations 205-207) ----------
    string? CandidateNumber,
    string? SourceTypeCode,
    string? SourceName,
    long? SourceRecordId,
    string? SourceReference,
    string? SourceDescription,
    string? SourceCentreCode,
    DateTime? IdentifiedOn,
    string? BusinessUnit,
    long? AssignedAnalystEmployeeId,
    string? AssignedAnalystName,
    string? ClarificationNote,
    DateTime? ClarificationRequestedOn,
    long? RegisteredRiskId,
    string? RegisteredRiskNumber,
    long? DuplicateOfRiskId,
    string? DuplicateOfRiskNumber,
    long? CurrentAnalysisId,
    int? CurrentAnalysisVersion,
    string? InherentRatingCode);

public sealed record RiskAcceptRequest(
    string AcceptanceNote,
    long? AcceptedByEmployeeId,
    string? FormalRiskRef,
    string? CallerDisplayName);

public sealed record RiskRejectRequest(
    string RejectionReason,
    long? RejectedByEmployeeId,
    string? CallerDisplayName);

public sealed record RiskWithdrawRequest(
    string? WithdrawReason,
    long? ActorEmployeeId,
    string? CallerDisplayName);

public sealed record RiskActionResult(
    bool Success,
    long RiskCandidateId,
    string? StatusCode,
    string? Error);

public sealed class RiskAttachmentUploadForm
{
    // Manual (default) requires File; Automated requires EvidenceLocation
    // + EvidenceLocator. Same vocabulary as practice_instance_evidence
    // and exception attachment.
    public string? CollectionMethodCode { get; set; } = "Manual";
    public string? EvidenceTypeCode { get; set; }        // optional; from evidence_type_master
    public IFormFile? File { get; set; }
    public string? EvidenceLocation { get; set; }
    public string? EvidenceLocator { get; set; }
    public long? UploadedByEmployeeId { get; set; }
    public string? CallerDisplayName { get; set; }
}

public sealed record RiskAttachmentRow(
    long AttachmentId,
    string? CollectionMethodCode,
    string? CollectionMethodName,
    string? EvidenceTypeCode,
    string? EvidenceTypeName,
    string? FileName,
    string? ContentType,
    long FileSizeBytes,
    string? EvidenceLocation,
    string? EvidenceLocator,
    long? UploadedByEmployeeId,
    string? UploadedByName,
    DateTime UploadedOn);

// =====================================================================
// Risk Register — BRD "Risk Candidate Analysis and Risk Register"
// Migrations 204-207. Contracts below back these routes:
//
//   GET  /scoring-options            §7, §12, §13 — the org's framework
//   GET  /{id}/analysis              §7.1 current version
//   GET  /{id}/analysis/history      §20 all versions
//   POST /{id}/analysis              §7   save (new version each time)
//   POST /{id}/assign                §6.2 analyst
//   POST /{id}/clarify               §8C
//   POST /{id}/register              §8A  Route A
//   POST /{id}/close-duplicate       §15
//   POST /duplicate-check            §15  advisory
//   POST /custom                     §4B, §11 — Route B
//   GET  /register                   §9, §23
//   GET  /register/{riskId}          §9.1 + §10 traceability
//   POST /register/{riskId}/status   §17
//   POST /register/{riskId}/owner    §18
// =====================================================================

// ---- Scoring framework (§7, §12, §13) -------------------------------
public sealed record RiskScaleLevel(
    string Code, string Name, int LevelValue, string? Descriptor);

public sealed record RiskCategoryOption(
    string CategoryCode, string CategoryName, string? Description);

public sealed record RiskSourceOption(
    string SourceTypeCode, string SourceName, string? Description, string? SourceCentreCode);

public sealed record RiskMatrixCell(
    int LikelihoodValue, int ImpactValue,
    string RatingCode, string RatingName, int? RatingScore, string? ColourHex);

public sealed record RiskScoringOptions(
    IReadOnlyList<RiskScaleLevel> Likelihood,
    IReadOnlyList<RiskScaleLevel> Impact,
    IReadOnlyList<RiskCategoryOption> Categories,
    IReadOnlyList<RiskSourceOption> Sources,
    IReadOnlyList<RiskMatrixCell> Matrix);

// ---- Initial Risk Analysis (§7.1) -----------------------------------
// One request shape for both routes, because §12 says both routes use
// the same analysis. The custom route reuses these same fields inside
// RiskCustomCreateRequest rather than declaring its own.
public sealed record RiskAnalysisSaveRequest(
    string RiskStatement,
    string? RiskCategoryCode,
    string? RiskDescription,
    string? RiskCause,
    string? PotentialConsequence,
    string? ExistingControls,
    string? LikelihoodCode,
    string? ImpactCode,
    long? RiskOwnerEmployeeId,
    string? BusinessUnit,
    string? ProcessName,
    string? AnalystRemarks,
    long? AnalysedByEmployeeId,
    string? CallerDisplayName,
    // ---- stage 1 (migration 216) ------------------------------------
    // Threat, vulnerability and business function are what the candidate
    // assessment actually asks for. Category / likelihood / impact stay
    // above because stage 2 reuses this same contract — one request
    // shape, both stages, which is what keeps them from diverging.
    // ThreatId/VulnerabilityId 0 means "Others" and requires the matching
    // description; the procedure enforces it (56403 / 56405).
    int? ThreatId = null,
    string? ThreatDescription = null,
    int? VulnerabilityId = null,
    string? VulnerabilityDescription = null,
    long? BusinessFunctionId = null);

// ---- Assessment picklists (migration 216) ---------------------------
public sealed record RiskThreatOption(int ThreatId, string ThreatName);
public sealed record RiskVulnerabilityOption(int VulnerabilityId, string VulnerabilityName);
public sealed record RiskBusinessFunctionOption(long BusinessFunctionId, string? FunctionCode, string FunctionName);

public sealed record RiskAssessmentOptions(
    IReadOnlyList<RiskThreatOption> Threats,
    IReadOnlyList<RiskVulnerabilityOption> Vulnerabilities,
    IReadOnlyList<RiskBusinessFunctionOption> BusinessFunctions);

// ---- Stage 2: the scored analysis on a registered risk (216) --------
public sealed record RiskRegisterAssessRequest(
    string RiskCategoryCode,
    string LikelihoodCode,
    string ImpactCode,
    string? RiskCause,
    string? PotentialConsequence,
    string? ExistingControls,
    string? RiskDescription,
    string? ProcessName,
    string? AnalystRemarks,
    long? AnalysedByEmployeeId,
    string? CallerDisplayName);

public sealed record RiskRegisterAssessResult(
    bool Success,
    long RiskRegisterId,
    long? RiskAnalysisId,
    int? AnalysisVersion,
    // True when BRD §19 held the rating back for approval — the register
    // keeps its previous rating until an approver releases it.
    bool ApprovalRequired,
    string? ApprovalReason,
    string? InherentRatingCode,
    string? Error);

public sealed record RiskAnalysisDetail(
    long RiskAnalysisId,
    long OrganizationId,
    string AnalysisScopeCode,       // Candidate | Custom
    long? RiskCandidateId,
    long? RiskRegisterId,
    int AnalysisVersion,
    bool IsCurrent,
    string RiskStatement,
    string? RiskCategoryCode,
    string? RiskCategoryName,
    string? RiskDescription,
    string? RiskCause,
    string? PotentialConsequence,
    string? ExistingControls,
    string? LikelihoodCode,
    string? LikelihoodName,
    int? LikelihoodValue,
    string? ImpactCode,
    string? ImpactName,
    int? ImpactValue,
    string? InherentRatingCode,
    string? InherentRatingName,
    int? InherentRatingScore,
    long? RiskOwnerEmployeeId,
    string? RiskOwnerName,
    string? BusinessUnit,
    string? ProcessName,
    string? AnalystRemarks,
    DateTime AnalysisOn,
    long? AnalysedByEmployeeId,
    string? AnalysedByName,
    string? DecisionCode,           // Register | Reject | Clarify
    string? DecisionNote,
    DateTime? DecisionOn,
    string? ApprovalStatusCode,
    // ---- stage 1 (migration 216) ------------------------------------
    int? ThreatId,
    string? ThreatName,
    string? ThreatDescription,
    int? VulnerabilityId,
    string? VulnerabilityName,
    string? VulnerabilityDescription,
    long? BusinessFunctionId,
    string? BusinessFunctionName);

public sealed record RiskAnalysisVersionRow(
    long RiskAnalysisId,
    int AnalysisVersion,
    bool IsCurrent,
    string RiskStatement,
    string? LikelihoodName,
    string? ImpactName,
    string? InherentRatingCode,
    int? InherentRatingScore,
    string? DecisionCode,
    DateTime AnalysisOn,
    string? AnalysedByName,
    string? AnalystRemarks);

public sealed record RiskAnalysisSaveResult(
    bool Success,
    long RiskAnalysisId,
    int AnalysisVersion,
    string? InherentRatingCode,
    string? InherentRatingName,
    int? InherentRatingScore,
    string? Error);

// ---- Candidate decisions (§6.2, §8, §15) ----------------------------
public sealed record RiskCandidateAssignRequest(
    long? AnalystEmployeeId, string? Remark,
    long? ActorEmployeeId, string? CallerDisplayName);

public sealed record RiskCandidateClarifyRequest(
    string ClarificationNote,
    long? ActorEmployeeId, string? CallerDisplayName);

public sealed record RiskCandidateDuplicateRequest(
    long? DuplicateOfRiskId, string? Remark,
    long? ActorEmployeeId, string? CallerDisplayName);

public sealed record RiskRegisterRequest(
    string? RiskTitle,
    string? RegistrationNote,
    long? RegisteredByEmployeeId,
    long? LinkedAssetId,
    long? LinkedVendorId,
    long? LinkedPracticeId,
    long? LinkedObligationId,
    long? LinkedControlId,
    string? CallerDisplayName);

public sealed record RiskRegisterActionResult(
    bool Success,
    long? RiskCandidateId,
    long? RiskRegisterId,
    string? RiskNumber,
    string? StatusCode,
    string? Error);

// ---- Duplicate detection (§15) --------------------------------------
public sealed record RiskDuplicateCheckRequest(
    long OrganizationId,
    string? RiskTitle,
    string? RiskStatement,
    string? RiskCategoryCode,
    string? SourceTypeCode,
    long? SourceRecordId,
    string? BusinessUnit,
    long? ExcludeRiskId,
    int? MinScore);

public sealed record RiskDuplicateMatch(
    long RiskRegisterId,
    string RiskNumber,
    string RiskTitle,
    string? RiskStatement,
    string? RiskCategoryName,
    string? SourceTypeCode,
    string? SourceReference,
    string StatusCode,
    string? InherentRatingCode,
    DateTime RegisteredOn,
    string? RiskOwnerName,
    int MatchScore,
    string? MatchReason);

// ---- Custom risk, Route B (§4B, §11) --------------------------------
public sealed record RiskCustomCreateRequest(
    long OrganizationId,
    string RiskTitle,
    string RiskStatement,
    // Optional since 216: a custom risk is created with the same five
    // stage-1 fields as a candidate, and scored later from the Risk
    // Register. An organisation that wants to score immediately still
    // can — §12's "same methodology, both routes" cuts both ways.
    string? RiskCategoryCode,
    string? LikelihoodCode,
    string? ImpactCode,
    long? RiskOwnerEmployeeId,
    string? RiskDescription,
    string? RiskCause,
    string? PotentialConsequence,
    string? ExistingControls,
    string? BusinessUnit,
    string? ProcessName,
    string? AnalystRemarks,
    long? LinkedAssetId,
    long? LinkedVendorId,
    long? LinkedPracticeId,
    long? LinkedObligationId,
    long? LinkedControlId,
    long? CreatedByEmployeeId,
    string? CallerDisplayName,
    // ---- stage 1 (migration 216) ------------------------------------
    int? ThreatId = null,
    string? ThreatDescription = null,
    int? VulnerabilityId = null,
    string? VulnerabilityDescription = null,
    long? BusinessFunctionId = null);

// ---- Risk Register reads (§9.1, §17, §23) ---------------------------
public sealed record RiskRegisterRow(
    long RiskRegisterId,
    string RiskNumber,
    long OrganizationId,
    string RiskTitle,
    string? RiskStatement,
    string? RiskCategoryCode,
    string? RiskCategoryName,
    string SourceTypeCode,
    long? SourceRecordId,
    string? SourceReference,
    string? SourceCentreCode,
    long? RiskCandidateId,
    long RiskAnalysisId,
    long? RiskOwnerEmployeeId,
    string? RiskOwnerName,
    string? BusinessUnit,
    string? LikelihoodName,
    string? ImpactName,
    string? InherentRatingCode,
    string? InherentRatingName,
    int? InherentRatingScore,
    string StatusCode,
    DateTime RegisteredOn,
    string? RegisteredByName,
    // ---- migration 216 ----------------------------------------------
    // True until the stage-2 analysis has been applied. The grid badges
    // it, because a registered risk with no rating is work outstanding,
    // not a data error.
    bool AnalysisPending,
    string? ThreatName,
    string? VulnerabilityName,
    string? BusinessFunctionName);

public sealed record RiskRegisterListResult(
    long TotalRows, int Page, int PageSize,
    IReadOnlyList<RiskRegisterRow> Rows);

public sealed record RiskRegisterDetail(
    long RiskRegisterId,
    string RiskNumber,
    long OrganizationId,
    string RiskTitle,
    string RiskStatement,
    string? RiskDescription,
    string? RiskCategoryCode,
    string? RiskCategoryName,
    // §10 traceability chain
    string SourceTypeCode,
    string? SourceName,
    long? SourceRecordId,
    string? SourceReference,
    string? SourceDescription,
    string? SourceCentreCode,
    long? RiskCandidateId,
    string? CandidateNumber,
    string? CandidateTitle,
    long? CustomGapId,
    long RiskAnalysisId,
    int? AnalysisVersion,
    DateTime? AnalysisOn,
    string? AnalysedByName,
    // §9.1 assessment
    long? RiskOwnerEmployeeId,
    string? RiskOwnerName,
    string? BusinessUnit,
    string? ProcessName,
    string? RiskCause,
    string? PotentialConsequence,
    string? ExistingControls,
    string? LikelihoodCode,
    string? LikelihoodName,
    int? LikelihoodValue,
    string? ImpactCode,
    string? ImpactName,
    int? ImpactValue,
    string? InherentRatingCode,
    string? InherentRatingName,
    int? InherentRatingScore,
    long? LinkedAssetId,
    long? LinkedVendorId,
    long? LinkedPracticeId,
    long? LinkedObligationId,
    long? LinkedControlId,
    // §17 lifecycle
    string StatusCode,
    DateTime RegisteredOn,
    long? RegisteredByEmployeeId,
    string? RegisteredByName,
    DateTime? ClosedOn,
    string? ClosedByName,
    string? ClosureReason,
    // ---- migration 216 ----------------------------------------------
    bool AnalysisPending,
    int? ThreatId,
    string? ThreatName,
    string? ThreatDescription,
    int? VulnerabilityId,
    string? VulnerabilityName,
    string? VulnerabilityDescription,
    long? BusinessFunctionId,
    string? BusinessFunctionName,
    // Approval state of the CURRENT assessment, so the detail screen can
    // say "rating awaiting approval" instead of silently showing the old
    // one as if nothing were pending.
    string? AnalysisApprovalStatusCode);

public sealed record RiskRegisterStatusRequest(
    string StatusCode, string? Remark,
    long? ActorEmployeeId, string? CallerDisplayName);

public sealed record RiskRegisterOwnerRequest(
    long? OwnerEmployeeId, string? Remark,
    long? ActorEmployeeId, string? CallerDisplayName);

// =====================================================================
// Phase B — migrations 208-211
//
//   208  organisation config + the §19 approval gate
//   209  §21 notification outbox
//   210  §23 dashboard and reporting
//   211  §22 treatment task, opt-in
// =====================================================================

// ---- 208: org configuration (§19, §22, conflict 1) ------------------
public sealed record RiskConfigNotifyRole(
    string NotifyEventCode, long RoleId, string? RoleName, bool IsActive);

public sealed record RiskConfigDetail(
    long OrgRiskConfigId,
    long OrganizationId,
    bool ApprovalRequired,
    // NULL with ApprovalRequired = true means every risk needs approval.
    string? ApprovalMinRatingCode,
    long? ApproverRoleId,
    string? ApproverRoleName,
    bool DefaultRaiseTreatmentTask,
    bool AllowLegacyAccept,
    bool NotificationsEnabled,
    string? Notes,
    IReadOnlyList<RiskConfigNotifyRole> NotifyRoles);

public sealed record RiskConfigSaveRequest(
    bool? ApprovalRequired,
    string? ApprovalMinRatingCode,
    long? ApproverRoleId,
    bool? DefaultRaiseTreatmentTask,
    bool? AllowLegacyAccept,
    bool? NotificationsEnabled,
    string? Notes,
    // NULL means "leave alone" for every field above; these two switches
    // are how a caller un-sets the two fields where NULL is also a value.
    bool? ClearApproverRole,
    bool? ClearMinRating,
    string? CallerDisplayName);

// ---- 208: approval workflow (§19) -----------------------------------
public sealed record RiskApprovalRequest(
    string? Remark, long? ActorEmployeeId, string? CallerDisplayName);

public sealed record RiskApprovalDecisionRequest(
    string Decision,                 // Approve | Return
    string? Remark, long? ActorEmployeeId, string? CallerDisplayName);

public sealed record RiskApprovalActionResult(
    bool Success,
    long RiskCandidateId,
    string? StatusCode,
    long? RiskAnalysisId,
    string? ApprovalStatusCode,
    string? Error);

public sealed record RiskApprovalQueueRow(
    long RiskCandidateId,
    string? CandidateNumber,
    string CandidateTitle,
    string? SourceTypeCode,
    string? SourceReference,
    string StatusCode,
    long RiskAnalysisId,
    int AnalysisVersion,
    string RiskStatement,
    string? RiskCategoryName,
    string? LikelihoodName,
    string? ImpactName,
    string? InherentRatingCode,
    int? InherentRatingScore,
    long? RiskOwnerEmployeeId,
    string? RiskOwnerName,
    DateTime AnalysisOn,
    string? AnalysedByName,
    string? ApprovalNote,
    int DaysWaiting);

public sealed record RiskApprovalQueueResult(
    long TotalRows, int Page, int PageSize,
    IReadOnlyList<RiskApprovalQueueRow> Rows);

// ---- 209: notifications (§21) ---------------------------------------
public sealed record RiskNotificationRow(
    long RiskNotificationId,
    long OrganizationId,
    string SubjectTypeCode,          // Candidate | Risk
    long SubjectRecordId,
    string? SubjectNumber,
    string? SubjectTitle,
    string NotifyEventCode,
    string? InherentRatingCode,
    string? SubjectStatusCode,
    long? RecipientEmployeeId,
    string? RecipientName,
    string? RecipientEmail,
    string? RoleName,
    string RecipientReasonCode,      // ANALYST | OWNER | APPROVER | REQUESTER | ROLE
    string? Subject,
    string? BodyText,
    string StatusCode,               // Pending | Sent | Failed | Suppressed
    int AttemptCount,
    string? FailureReason,
    DateTime? SentOn,
    DateTime EventOn,
    DateTime RecordedOn);

public sealed record RiskNotificationListResult(
    long TotalRows, int Page, int PageSize,
    IReadOnlyList<RiskNotificationRow> Rows);

public sealed record RiskNotificationCounts(
    int PendingCount, int SentCount, int FailedCount,
    int SuppressedCount, int TotalCount);

public sealed record RiskNotificationSweepResult(
    bool Success, int EventsScanned, int NotificationsForScannedEvents, string? Error);

public sealed record RiskNotificationMarkRequest(
    string StatusCode, string? FailureReason, string? CallerDisplayName);

// ---- 210: dashboard (§23) -------------------------------------------
public sealed record RiskCandidateSummary(
    int TotalCandidates, int OpenCandidates, int NewCandidates,
    int UnderAnalysisCount, int AwaitingClarificationCount,
    int AwaitingApprovalCount, int AnalysisCompletedCount,
    int RejectedCount, int ClosedAsDuplicateCount, int WithdrawnCount,
    int ConvertedToRiskCount, int LegacyAcceptedCount,
    double? AvgOpenAgeDays, int? MaxOpenAgeDays);

public sealed record RiskRegisterSummary(
    int TotalRisks, int ActiveCount, int UnderTreatmentCount,
    int AcceptedCount, int MonitoringCount, int ClosedCount, int RetiredCount,
    int ElevatedRatingCount, int CustomRiskCount, int UnownedCount,
    double? AvgInherentScore);

public sealed record RiskGroupCount(
    string Key, string Label, int TotalCount, int OpenCount,
    double? AvgInherentScore, int? SortValue, string? ColourHex);

public sealed record RiskAgeingBand(
    string BandCode, string BandName, int SortOrder, int CandidateCount);

public sealed record RiskTrendPoint(
    DateTime MonthStart, int RegisteredCount, int ClosedCount, int CandidatesRaisedCount);

public sealed record RiskOverdueAction(
    long? TaskId, string? TaskNumber, string? TaskTitle,
    long? RiskCandidateId, string? OwnerName, string? Priority,
    DateTime? DueAt, string? SlaStatusCode, string? TaskStatusName);

public sealed record RiskDashboard(
    RiskCandidateSummary Candidates,
    IReadOnlyList<RiskGroupCount> CandidatesBySource,
    RiskRegisterSummary Register,
    IReadOnlyList<RiskGroupCount> RisksByCategory,
    IReadOnlyList<RiskGroupCount> RisksBySource,
    IReadOnlyList<RiskGroupCount> RisksByRating,
    IReadOnlyList<RiskGroupCount> RisksByBusinessUnit,
    IReadOnlyList<RiskGroupCount> RisksByOwner,
    IReadOnlyList<RiskAgeingBand> CandidateAgeing,
    IReadOnlyList<RiskTrendPoint> Trend,
    IReadOnlyList<RiskOverdueAction> OverdueActions);

public sealed record RiskAgeingRow(
    long RiskCandidateId,
    string? CandidateNumber,
    string CandidateTitle,
    string? SourceTypeCode,
    string? SourceReference,
    string StatusCode,
    long? AssignedAnalystEmployeeId,
    string? AssignedAnalystName,
    DateTime? IdentifiedOn,
    int AgeDays,
    string? InherentRatingCode,
    string? ApprovalStatusCode);

public sealed record RiskAgeingListResult(
    long TotalRows, int Page, int PageSize,
    IReadOnlyList<RiskAgeingRow> Rows);

// ---- 211: treatment task, opt-in (§22) ------------------------------
public sealed record RiskTreatmentTaskRequest(
    string? TaskTitle,
    string? TaskDescription,
    string? ProposedPriority,
    long? OwnerEmployeeId,
    // Second and subsequent actions for the same risk — the BRD's
    // one-source-many-tasks path.
    bool? AllowAdditional,
    long? ActorEmployeeId,
    string? CallerDisplayName);

public sealed record RiskTreatmentTaskResult(
    bool Success,
    long RiskRegisterId,
    long? TaskCandidateId,
    bool Created,
    string? ProposedPriority,
    string? Error);

public sealed record RiskRelatedWorkRow(
    string? ItemKind,                // Task | Candidate
    long? ItemId,
    string? ItemNumber,
    string? Title,
    string? StatusCode,
    string? StatusName,
    long? OwnerEmployeeId,
    string? OwnerName,
    string? Priority,
    DateTime? DueAt,
    string? SlaStatusCode,
    bool? IsChild,
    long? ParentTaskId,
    int? ChildCount,
    DateTime? CompletedDt,
    DateTime? RaisedDt);
