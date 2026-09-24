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

// 376: RiskCategoryId added, additive -- the multi-select combo on the
// Analysis form (raCategoryCombo, risk-centre.js) keys on this id
// (risk_category_master's real PK); every existing reader of
// CategoryCode/CategoryName (the single-select filters,
// sp_risk_register_assess's legacy scalar) is unaffected.
public sealed record RiskCategoryOption(
    string CategoryCode, string CategoryName, string? Description, long RiskCategoryId = 0);

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

// ---- Organisation-owned threats and vulnerabilities (285, 286) ------
//
// Separate records from RiskThreatOption above, which stays exactly as
// it is: sp_risk_threat_options_get and everything reading it are
// untouched. These carry the two facts the picker needs and that one
// does not -- who owns the row, and whether a create actually created
// anything.
public sealed record RiskThreatItem(
    int ThreatId, string ThreatName, long? OrganizationId, bool IsShared);

public sealed record RiskVulnerabilityItem(
    int VulnerabilityId, string VulnerabilityName, long? OrganizationId, bool IsShared);

// CallerDisplayName is stamped into the body by the Web tier's
// ForwardJsonWithCallerStampAsync, the same way every other write on
// this controller receives it. The API is called server-to-server, so
// User.Identity.Name is null here and reading it would make every
// master row say "system".
public sealed record RiskThreatCreateRequest(
    long OrganizationId, string Name, string? CallerDisplayName = null);

// WasCreated is false when the name already existed. Not an error --
// sp_risk_threat_create is idempotent by name, and the caller's next
// move is identical either way: show the chip. See 286, DECISION 3.
public sealed record RiskThreatCreateResult(
    int ThreatId, string ThreatName, long? OrganizationId, bool IsShared, bool WasCreated);

public sealed record RiskVulnerabilityCreateResult(
    int VulnerabilityId, string VulnerabilityName, long? OrganizationId, bool IsShared, bool WasCreated);

// What one risk currently carries. LegacyThreatText is the pre-285
// "Others" free text and is null for every risk that has moved on --
// which is how the form knows whether it has anything to offer to
// convert.
public sealed record RiskThreatSelection(
    IReadOnlyList<RiskThreatItem> Threats,
    IReadOnlyList<RiskVulnerabilityItem> Vulnerabilities,
    string? LegacyThreatText,
    string? LegacyVulnerabilityText);

public sealed record RiskThreatSelectionRequest(
    long OrganizationId,
    IReadOnlyList<int>? ThreatIds,
    IReadOnlyList<int>? VulnerabilityIds,
    string? CallerDisplayName = null);

// ---- Risk Type: Confidentiality / Integrity / Availability (313, 314) --
//
// Master-table driven, NOT a hardcoded three-string list -- see 313's
// header. The seeded rows are shared (OrganizationId null); the shape
// still carries IsShared for the same reason RiskThreatItem does, in
// case an organisation is ever given its own row in the 1,000,000+ band.
public sealed record RiskTypeItem(
    int RiskTypeId, string RiskTypeCode, string RiskTypeName, int DisplayOrder, bool IsShared);

// sp_risk_type_selection_get does not return IsShared (the form only
// needs to know WHICH ids are selected, not who owns each master row),
// so this is its own shape rather than a reuse of RiskTypeItem with a
// fabricated value.
public sealed record RiskTypeSelectionEntry(
    int RiskTypeId, string RiskTypeCode, string RiskTypeName, int DisplayOrder);

public sealed record RiskTypeSelection(
    IReadOnlyList<RiskTypeSelectionEntry> RiskTypes,
    // True when the register link table was empty and the newest
    // analysis version's set was returned instead -- see 314's header.
    bool FromAnalysisFallback);

// RiskAnalysisId is sent by the Analysis page alongside the register id
// it already knows, so ONE call writes both link tables in the same
// round trip sp_risk_register_assess's own save already makes: the new
// analysis version AND the register's current answer stay in step.
public sealed record RiskTypeSelectionRequest(
    long OrganizationId,
    IReadOnlyList<int>? RiskTypeIds,
    long? RiskAnalysisId = null,
    string? CallerDisplayName = null);

public sealed record RiskTypeSelectionResult(
    bool Success,
    long RiskRegisterId,
    int RiskTypeCount,
    // Verbatim from SQL -- 56731 ("at least one risk type is required")
    // is the message the analyst needs to see, not a generic failure.
    string? Error);

// ---- Risk Category, multi-select (375, 376) --------------------------
//
// Same shape as Risk Type above, and for the same reason -- 376's header.
// The options themselves are NOT re-listed here: they already come from
// RiskScoringOptions.Categories (GetScoringOptionsAsync), which now
// carries RiskCategoryId alongside CategoryCode/CategoryName, so there is
// no separate "list" endpoint the way Risk Type needed one (risk_category_
// master has no free-text escape hatch either, same as Risk Type -- no
// "create" endpoint here for the same reason 314 gives).
public sealed record RiskCategorySelectionEntry(
    long RiskCategoryId, string CategoryCode, string CategoryName, int DisplayOrder);

public sealed record RiskCategorySelection(
    IReadOnlyList<RiskCategorySelectionEntry> RiskCategories,
    // True when the register link table was empty and the newest
    // analysis version's set was returned instead -- see 376's header.
    bool FromAnalysisFallback);

// RiskAnalysisId is sent by the Analysis page alongside the register id
// it already knows, so ONE call writes both link tables in the same
// round trip sp_risk_register_assess's own save already makes.
public sealed record RiskCategorySelectionRequest(
    long OrganizationId,
    IReadOnlyList<long>? RiskCategoryIds,
    long? RiskAnalysisId = null,
    string? CallerDisplayName = null);

public sealed record RiskCategorySelectionResult(
    bool Success,
    long RiskRegisterId,
    int RiskCategoryCount,
    // Verbatim from SQL -- 56757 ("at least one risk category is
    // required") is the message the analyst needs to see, not a generic
    // failure.
    string? Error);

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
    string? BusinessFunctionName,
    // ---- migration 258: the second score ----------------------------
    // Inherent is the rating BEFORE treatment; Residual is the rating
    // AFTER it. Both resolve through sp_risk_rating_resolve against the
    // same matrix, so the grid's two columns are comparable.
    // ResidualPending is true until a residual assessment exists —
    // "not assessed", not "no risk", which is why the grid badges it
    // instead of showing a blank cell.
    string? ResidualLikelihoodName = null,
    string? ResidualImpactName = null,
    string? ResidualRatingCode = null,
    string? ResidualRatingName = null,
    int? ResidualRatingScore = null,
    DateTime? ResidualAssessedOn = null,
    bool ResidualPending = true,
    // ---- migrations 261-264: treatment, acceptance, review ----------
    // WorkflowStageCode is DERIVED, not stored — vw_pm_risk_workflow_stage
    // computes it from the columns beside it, so it can never disagree
    // with them. The grid renders it as the risk's stage chip; the codes
    // are AnalysisDue / TreatmentDue / InTreatment / ResidualDue /
    // AcceptanceDue / Accepted / ReviewDue / Closed.
    //
    // OpenTreatmentTaskCount counts PARENT tasks only (BRD §11 — the
    // parent owns the commitment), which is why a risk with one parent
    // and three open children reads "1 open", not "4".
    string? TreatmentOptionCode = null,
    string? TreatmentOptionName = null,
    long? TreatmentTaskId = null,
    DateTime? AcceptedOn = null,
    string? AcceptedByName = null,
    DateTime? NextReviewDate = null,
    DateTime? LastReviewedOn = null,
    int ReviewCount = 0,
    string? WorkflowStageCode = null,
    int OpenTreatmentTaskCount = 0,
    int TreatmentTaskCount = 0,
    bool IsReviewDue = false,
    int MappedPracticeCount = 0,
    int MappedDependencyCount = 0,
    // 376. Comma-separated CategoryName list for every category this
    // risk is mapped to in risk_register_risk_category, built by an
    // additive STRING_AGG subquery in sp_risk_register_list (same
    // pattern as MappedPracticeCount/MappedDependencyCount above). Null
    // on a database not yet migrated to 376 -- the grid falls back to
    // the legacy scalar RiskCategoryName in that case.
    string? RiskCategoryNames = null);

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
    string? AnalysisApprovalStatusCode,
    // ---- migration 258: residual risk -------------------------------
    // The register's own denormalised block, plus the narrative fields
    // from the version it points at. The narrative is what makes the
    // score readable: TreatmentSummary says what was done, and
    // ResidualControls says what is in place now.
    long? ResidualAnalysisId = null,
    int? ResidualVersion = null,
    string? ResidualLikelihoodCode = null,
    string? ResidualLikelihoodName = null,
    int? ResidualLikelihoodValue = null,
    string? ResidualImpactCode = null,
    string? ResidualImpactName = null,
    int? ResidualImpactValue = null,
    string? ResidualRatingCode = null,
    string? ResidualRatingName = null,
    int? ResidualRatingScore = null,
    DateTime? ResidualAssessedOn = null,
    bool ResidualPending = true,
    string? ResidualTreatmentSummary = null,
    string? ResidualControls = null,
    string? ResidualRemarks = null,
    string? ResidualAssessedByName = null,
    // ---- migrations 261-264: treatment, acceptance, review ----------
    string? LinkedPracticeName = null,
    string? TreatmentOptionCode = null,
    string? TreatmentOptionName = null,
    DateTime? TreatmentDecidedOn = null,
    string? TreatmentDecidedByName = null,
    long? TreatmentTaskId = null,
    long? AcceptedByEmployeeId = null,
    string? AcceptedByName = null,
    // 292. The acceptor's active organisation roles, comma separated,
    // so the UI can render "Vinod - Risk Owner". Separate from
    // AcceptedByName: the name is what is stored, and composing the two
    // in the UI keeps a role suffix out of any persisted value.
    string? AcceptedByRoleNames = null,
    DateTime? AcceptedOn = null,
    string? AcceptanceNote = null,
    DateTime? NextReviewDate = null,
    DateTime? LastReviewedOn = null,
    int ReviewCount = 0,
    string? WorkflowStageCode = null,
    int OpenTreatmentTaskCount = 0,
    int TreatmentTaskCount = 0,
    bool IsReviewDue = false,
    int MappedPracticeCount = 0,
    int MappedDependencyCount = 0,
    // 310. THE ONE COMMON RISK VERSION, and the only one any screen
    // should call a version. It starts at 1 and is incremented by
    // sp_risk_acceptance_save alone -- not by analysis, not by residual
    // analysis, not by review.
    //
    // Deliberately NOT AnalysisVersion or ResidualVersion, which are
    // still here and still mean what they always did: the BRD 20 history
    // sequence of risk_analysis and risk_residual_analysis, used by
    // those two history tables to tell one retained row from another.
    //
    // Defaults to 1, not 0: a database that has not had 310 applied
    // returns no RiskVersion column, and "version 0" is not a state a
    // risk can be in.
    int RiskVersion = 1,
    // 311. How many practices this risk is LINKED to, which is not the
    // same question as MappedPracticeCount above.
    //
    // MappedPracticeCount is rows in risk_practice_map. That map's
    // Primary row is derived by sp_risk_mapping_sync_primary, and the
    // only thing that calls it is the /mapping read -- so a risk whose
    // scope panel has never been opened has a linked practice and an
    // empty map, and the mapped count reports 0 for a risk that plainly
    // shows a practice.
    //
    // This one counts the map plus the risk's own linked practice when
    // that practice is not in the map yet. Defaults to 0, not 1: a risk
    // with no practice anywhere is a real state (Custom risks have
    // none), unlike a version.
    int LinkedPracticeCount = 0,
    // 376. Same additive STRING_AGG column as RiskRegisterRow above,
    // added to sp_risk_register_get so the Risk View detail page can
    // show every mapped category without a second round trip. Null on
    // a database not yet migrated to 376.
    string? RiskCategoryNames = null);

// =====================================================================
// Residual Risk Analysis — migration 258 (BRD §9.1, §17, §20, §22)
//
//   POST /register/{riskId}/residual           save a new version
//   GET  /register/{riskId}/residual           the current version
//   GET  /register/{riskId}/residual/history   §20, every version
//
// The rating is NOT in the request. It is resolved server-side from the
// organisation's matrix by the same procedure the inherent rating uses,
// so a client cannot supply a score the matrix disagrees with.
// =====================================================================
public sealed record RiskResidualSaveRequest(
    string ResidualLikelihoodCode,
    string ResidualImpactCode,
    string? TreatmentSummary,
    string? ResidualControls,
    string? AnalystRemarks,
    long? AssessedByEmployeeId,
    string? CallerDisplayName,
    // ---- migration 263 ----------------------------------------------
    // The residual analysis is a FULL analysis and may conclude with a
    // different treatment decision from the original: a risk treated
    // once and still too high may now be Transferred, or finally
    // Tolerated. Optional — omitting it leaves the existing decision
    // standing. Supplying it delegates to sp_risk_treatment_option_set,
    // which raises another treatment task if the option calls for one.
    string? TreatmentOptionCode = null);

public sealed record RiskResidualSaveResult(
    bool Success,
    long RiskRegisterId,
    long? RiskResidualAnalysisId,
    int? ResidualVersion,
    string? ResidualRatingCode,
    string? ResidualRatingName,
    int? ResidualRatingScore,
    // Echoed back so the screen can report the reduction ("Critical ->
    // Medium") without a second fetch.
    string? InherentRatingCode,
    int? InherentRatingScore,
    string? Error,
    // ---- migration 263 ----------------------------------------------
    string? TreatmentOptionCode = null,
    string? TreatmentOptionName = null);

public sealed record RiskResidualDetail(
    long RiskResidualAnalysisId,
    long OrganizationId,
    long RiskRegisterId,
    long? InherentAnalysisId,
    int ResidualVersion,
    bool IsCurrent,
    string? ResidualLikelihoodCode,
    string? ResidualLikelihoodName,
    int? ResidualLikelihoodValue,
    string? ResidualImpactCode,
    string? ResidualImpactName,
    int? ResidualImpactValue,
    string? ResidualRatingCode,
    string? ResidualRatingName,
    int? ResidualRatingScore,
    string? InherentRatingCode,
    string? InherentRatingName,
    int? InherentRatingScore,
    string? TreatmentSummary,
    string? ResidualControls,
    string? AnalystRemarks,
    DateTime AssessedOn,
    long? AssessedByEmployeeId,
    string? AssessedByName);

public sealed record RiskResidualVersionRow(
    long RiskResidualAnalysisId,
    int ResidualVersion,
    bool IsCurrent,
    string? ResidualLikelihoodName,
    string? ResidualImpactName,
    string? ResidualRatingCode,
    int? ResidualRatingScore,
    // The inherent rating AS IT STOOD at the time. Frozen on the row, so
    // a version reads correctly even after the inherent risk is
    // re-scored.
    string? InherentRatingCode,
    int? InherentRatingScore,
    string? TreatmentSummary,
    string? AnalystRemarks,
    DateTime AssessedOn,
    string? AssessedByName);

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

// =====================================================================
// Practice / Asset mapping — migrations 261, 262
//
//   GET    /register/{riskId}/mapping           practices + assets
//   GET    /register/{riskId}/mapping/options   what is still mappable
//   POST   /register/{riskId}/practices         map a practice
//   DELETE /register/{riskId}/practices/{pid}   unmap it
//   POST   /register/{riskId}/assets            map an asset directly
//   DELETE /register/{riskId}/assets/{aid}      remove the direct mapping
//
// THE SHAPE MIRRORS THE DATA MODEL, NOT THE SCREEN
// ------------------------------------------------
// There is ONE asset row per (risk, asset) however many practices reach
// it — 265's central invariant — so RiskMappedDependencyRow is one row
// per (category, object), and the provenance travels on it as flags plus
// a pre-computed SourceLabel. The client renders the label; it does not
// derive it, because deriving it in two places is how the grid and the
// export start to disagree.
// =====================================================================
public sealed record RiskMappedPracticeRow(
    long RiskPracticeMapId,
    long PracticeId,
    string? PracticeName,
    string? PracticeCode,
    // Primary = the practice the risk arrived with (linked_practice_id).
    // Additional = mapped by an analyst during Risk Analysis.
    string MapSourceCode,
    bool IsPrimary,
    DateTime MappedDt,
    long? MappedByEmployeeId,
    string? MappedByName,
    string? Remarks,
    // Dependencies on THIS RISK that this practice vouches for, across
    // every category — not the number the practice depends on. The
    // difference is what tells the user what unmapping would actually
    // drop.
    int DependencyCount);

public sealed record RiskMappedDependencyRow(
    long RiskDependencyMapId,
    // The category, from dependency_type_master -- the SAME master the
    // Operationalize screen reads. Never an enum here: an organisation
    // that adds a category gets it with no code change.
    int DependencyTypeId,
    string? DependencyTypeName,
    long DependencyObjectId,
    string? DependencyObjectName,
    DateTime FirstMappedDt,
    string? Remarks,
    bool IsDirect,
    bool IsInherited,
    bool FromPrimaryPractice,
    // Primary | Additional | Direct | DirectAndInherited — resolved by
    // sp_risk_mapping_get so there is one definition of the badge.
    string SourceLabel,
    int SourceCount,
    // "Why is this dependency here?", already joined and comma-separated.
    string? SourcePractices);

// One row per ACTIVE dependency_type_master category, including the ones
// with nothing mapped yet. Deriving the list from the mapped rows would
// hide every empty category, and "you can also map a Vendor here" would
// be invisible until somebody had already mapped a vendor.
public sealed record RiskDependencyCategoryRow(
    int DependencyTypeId,
    string? DependencyTypeCode,
    string DependencyTypeName,
    int DisplayOrder,
    // False when the category has no dependency_type_source_config row:
    // declarable in Operationalize but with nothing to pick, so the
    // screen must not offer an Add control that cannot work.
    bool IsSelectable,
    int MappedCount);

public sealed record RiskMappingDetail(
    long RiskRegisterId,
    IReadOnlyList<RiskMappedPracticeRow> Practices,
    IReadOnlyList<RiskDependencyCategoryRow> Categories,
    IReadOnlyList<RiskMappedDependencyRow> Dependencies);

public sealed record RiskPracticeOption(
    long PracticeId,
    string PracticeName,
    string? PracticeCode,
    // How many dependencies, across ALL categories, mapping this practice
    // would pull in. Shown in the picker so it is never a surprise.
    int DependenciesFromPractice);

// Practices only. The OBJECTS for a category come from the repository
// gateway's `dependency-options/query` — the same endpoint the
// Operationalize picker uses, which reads dependency_type_source_config
// and can query whichever of the nine source tables the category names.
// Reimplementing that here would be a second answer to "what objects
// exist", guaranteed to drift from the first.
public sealed record RiskMappingOptions(
    IReadOnlyList<RiskPracticeOption> Practices);

public sealed record RiskPracticeMapRequest(
    long PracticeId,
    string? Remarks,
    long? ActorEmployeeId,
    string? CallerDisplayName);

public sealed record RiskPracticeMapResult(
    bool Success,
    long RiskRegisterId,
    long PracticeId,
    string? PracticeName,
    bool Created,
    int DependenciesAdded,
    int ContributionsAdded,
    string? Error);

public sealed record RiskPracticeUnmapResult(
    bool Success,
    long RiskRegisterId,
    long PracticeId,
    bool Removed,
    // Dropped because nothing else vouched for them, and kept because
    // something did. Both reported: a user who removes a practice and
    // sees dependencies remain needs to be told why.
    int DependenciesRemoved,
    int DependenciesKept,
    string? Error);

public sealed record RiskDependencyMapRequest(
    int DependencyTypeId,
    long DependencyObjectId,
    // The label the user actually saw in the picker. Frozen on the
    // mapping because there is no single table to join back to — see
    // migration 265, decision 3.
    string? DependencyObjectName,
    string? Remarks,
    long? ActorEmployeeId,
    string? CallerDisplayName);

public sealed record RiskDependencyMapResult(
    bool Success,
    long RiskRegisterId,
    long? RiskDependencyMapId,
    int DependencyTypeId,
    string? DependencyTypeName,
    long DependencyObjectId,
    string? DependencyObjectName,
    bool Created,
    string? Error);

public sealed record RiskDependencyUnmapResult(
    bool Success,
    long RiskRegisterId,
    int DependencyTypeId,
    long DependencyObjectId,
    // False when the dependency stayed because a mapped practice still
    // reaches it. RemainingSources says how many.
    bool DependencyRemoved,
    int RemainingSources,
    string? Error);
// =====================================================================
// Treatment Option — migrations 261, 263
//
//   POST /register/{riskId}/treatment-option    choose, and dispatch
//   GET  /register/{riskId}/treatment-state     counts + the gate answer
//   POST /register/{riskId}/treatment-sync      all closed -> Monitoring
//
// Exactly four options, fixed by the flow:
//   Terminate  Terminate / Avoid   -> raises a treatment task
//   Treat      Treat / Reduce      -> raises a treatment task
//   Transfer   Transfer / Share    -> raises a treatment task
//   Tolerate   Tolerate / Accept   -> raises nothing, goes to acceptance
//
// The label is NOT sent by the client and not chosen by the API. The
// procedure maps code -> label, so every surface says the same words.
// =====================================================================
public sealed record RiskTreatmentOptionRequest(
    string TreatmentOptionCode,
    string? TaskTitle,
    string? TaskDescription,
    DateTime? TargetDate,
    string? Remark,
    long? ActorEmployeeId,
    string? CallerDisplayName);

public sealed record RiskTreatmentOptionResult(
    bool Success,
    long RiskRegisterId,
    string? TreatmentOptionCode,
    string? TreatmentOptionName,
    long? TreatmentTaskId,
    // False when a task was already open — the idempotency guarantee,
    // reported rather than hidden so the screen can say "already raised".
    bool TaskCreated,
    string? StatusCode,
    // 'Treatment' or 'Acceptance' — where the client should go next.
    // Computed server-side so the routing rule has one definition.
    string? NextStep,
    string? Error);

public sealed record RiskTreatmentTaskRow(
    long TaskId,
    string? TaskNumber,
    string? Title,
    string? StatusCode,
    string? StatusName,
    bool IsTerminal,
    long? OwnerEmployeeId,
    string? OwnerName,
    string? Priority,
    DateTime? DueAt,
    DateTime? ClosedAt,
    bool IsChild,
    long? ParentTaskId,
    int ChildCount,
    int MandatoryChildOpenCount,
    DateTime? RaisedDt);

public sealed record RiskTreatmentState(
    long RiskRegisterId,
    string? TreatmentOptionCode,
    string? StatusCode,
    int TreatmentTaskCount,
    int OpenTreatmentTaskCount,
    int ClosedTreatmentTaskCount,
    int OpenSubTaskCount,
    // The gate for Residual Risk Analysis. Reason explains a false, so
    // the screen can disable a button AND say why.
    bool ResidualAvailable,
    bool ResidualPending,
    string? Reason,
    IReadOnlyList<RiskTreatmentTaskRow> Tasks);

// =====================================================================
// Acceptance, Review and the Risk Calendar — migration 264
//
//   GET  /register/{riskId}/acceptance     current + can-accept guidance
//   POST /register/{riskId}/acceptance     accept (review date REQUIRED)
//   POST /register/{riskId}/review         reassess a due risk
//   GET  /review-due                       the Review Risk list
//   GET  /review-calendar                  the Risk Calendar feed
// =====================================================================
public sealed record RiskAcceptanceSaveRequest(
    // Required, and the procedure refuses without it. A risk accepted
    // with no review date never comes back — see 264's header.
    DateTime NextReviewDate,
    long? AcceptedByEmployeeId,
    DateTime? AcceptedDate,
    string? AcceptanceNote,
    long? ActorEmployeeId,
    string? CallerDisplayName,
    // 293. The cadence NextReviewDate was derived from — recorded, not
    // enforced: the date above remains the authority and the only thing
    // that brings the risk back. Optional and last on purpose, so every
    // pre-293 caller (which sends only a date) binds unchanged, and so a
    // Custom / Event-driven acceptance can legitimately send null.
    int? ReviewFrequencyId = null);

/// <summary>
/// One row of <c>sp_risk_review_frequency_list</c> — the Acceptance
/// screen's "Review Frequency" options.
///
/// <para><c>FrequencyValue</c> and <c>FrequencyUnit</c> travel with each
/// row so the client derives "Quarterly = today + 3 months" from DATA
/// rather than from a hard-coded switch that could disagree with
/// <c>frequency_master</c>. <c>IsCustom</c> marks the rows where no date
/// can be derived and the user types one; value and unit are null there,
/// and null on Event Driven / Continuous too.</para>
/// </summary>
public sealed record RiskReviewFrequencyRow(
    int     FrequencyId,
    string? FrequencyCode,
    string  FrequencyName,
    int?    FrequencyValue,
    string? FrequencyUnit,
    bool    IsCustom);

public sealed record RiskAcceptanceResult(
    bool Success,
    long RiskRegisterId,
    string? RiskNumber,
    long? AcceptedByEmployeeId,
    string? AcceptedByName,
    DateTime? AcceptedOn,
    DateTime? NextReviewDate,
    string? StatusCode,
    string? Error);

public sealed record RiskAcceptanceDetail(
    long RiskRegisterId,
    string? RiskNumber,
    string? RiskTitle,
    string? StatusCode,
    long? RiskOwnerEmployeeId,
    string? RiskOwnerName,
    string? TreatmentOptionCode,
    string? TreatmentOptionName,
    string? InherentRatingCode,
    string? ResidualRatingCode,
    bool ResidualPending,
    bool AnalysisPending,
    long? AcceptedByEmployeeId,
    string? AcceptedByName,
    // 291. The acceptor's active organisation roles, comma separated, so
    // the UI can show "Vinod - Risk Owner". SEPARATE from AcceptedByName
    // on purpose: the name is what is stored, and composing the two in
    // the UI keeps a role suffix out of any persisted value. Null when
    // the acceptor holds no active role.
    string? AcceptedByRoleNames,
    DateTime? AcceptedOn,
    string? AcceptanceNote,
    // 293. The cadence this risk's review date was derived from, plus
    // its display name so the select can preselect without a second
    // lookup round trip. Null on every acceptance recorded before 293,
    // and on a Custom / Event-driven one — both legitimate states, not
    // missing data.
    int? ReviewFrequencyId,
    string? ReviewFrequencyName,
    DateTime? NextReviewDate,
    DateTime? LastReviewedOn,
    int ReviewCount,
    string? WorkflowStageCode,
    int OpenTreatmentTaskCount,
    bool CanAccept,
    string? AcceptGuidance);

public sealed record RiskReviewDueRow(
    long RiskRegisterId,
    string RiskNumber,
    string RiskTitle,
    string? RiskStatement,
    string? RiskCategoryName,
    string StatusCode,
    long? RiskOwnerEmployeeId,
    string? RiskOwnerName,
    string? BusinessUnit,
    string? InherentRatingCode,
    string? InherentRatingName,
    string? ResidualRatingCode,
    string? ResidualRatingName,
    string? TreatmentOptionCode,
    string? TreatmentOptionName,
    DateTime? AcceptedOn,
    string? AcceptedByName,
    DateTime? NextReviewDate,
    DateTime? LastReviewedOn,
    int ReviewCount,
    // Signed, and computed from one "today" for the whole call, so a
    // risk due today reads 0 rather than drifting with the clock.
    int DaysOverdue,
    bool IsDue,
    string? WorkflowStageCode);

public sealed record RiskReviewDueListResult(
    long TotalRows, int Page, int PageSize,
    IReadOnlyList<RiskReviewDueRow> Rows);

public sealed record RiskCalendarEventRow(
    long RiskRegisterId,
    string RiskNumber,
    string RiskTitle,
    DateTime EventDate,
    string StatusCode,
    string? RiskCategoryName,
    long? RiskOwnerEmployeeId,
    string? RiskOwnerName,
    string? BusinessUnit,
    string? InherentRatingCode,
    string? ResidualRatingCode,
    // Residual where one exists, inherent otherwise — the risk as it
    // stands now. Same precedence the register grid uses.
    string? EffectiveRatingCode,
    string? TreatmentOptionCode,
    string? TreatmentOptionName,
    DateTime? AcceptedOn,
    string? AcceptedByName,
    int ReviewCount,
    bool IsOverdue,
    bool IsToday,
    string? WorkflowStageCode);

// A review IS a re-analysis, so this request carries the same analysis
// fields as RiskRegisterAssessRequest. It is a separate record rather
// than a reuse because it also carries the review-only fields, and
// because a future divergence should be a compile error, not a silent
// behaviour change on a shared type.
public sealed record RiskReviewPerformRequest(
    string RiskCategoryCode,
    string LikelihoodCode,
    string ImpactCode,
    string? RiskCause,
    string? PotentialConsequence,
    string? ExistingControls,
    string? RiskDescription,
    string? ProcessName,
    string? ReviewRemarks,
    string? TreatmentOptionCode,
    // Optional, and since 299 a PROPOSAL rather than a control: the date
    // the reviewer suggests for the next cycle. It is stored on the risk
    // and the Accept screen opens with it filled in, where whoever
    // accepts may change it. It no longer decides where the risk goes —
    // that is status_code, which a review always sets to Monitoring.
    DateTime? NextReviewDate,
    long? ReviewedByEmployeeId,
    string? CallerDisplayName,
    // 299. The cadence proposed alongside that date, carried the same
    // way and for the same reason.
    int? ReviewFrequencyId = null);

public sealed record RiskReviewPerformResult(
    bool Success,
    long RiskRegisterId,
    string? RiskNumber,
    string? StatusCode,
    DateTime? NextReviewDate,
    string? TreatmentOptionCode,
    string? Error);

// =====================================================================
// Risk acceptance approval authority — migration 271
//
// Organization -> Risk Acceptance Approval Authority. Who may approve
// accepting a risk, per rating level, separately for the inherent and
// residual score.
//
// THE LEVELS ARE NOT AN ENUM. They come from each organisation's own
// risk_matrix_cell, because rating_code is free text by design (204) and
// the matrix is per-organisation. A fixed five-value enum here would
// contradict sp_risk_config_save's 56222 ("not a rating this
// organisation's risk matrix produces") and would leave every risk rated
// with an unlisted code unmatched.
// =====================================================================

/// <summary>
/// One rating level's authority row.
///
/// <para>The <c>Effective*</c> values are what applies RIGHT NOW,
/// fallback included, so the page can show the answer rather than only
/// the override. <c>UsesFallback</c> says whether that answer came from
/// <c>org_risk_config.approver_role_id</c> (migration 212) rather than
/// from this configuration.</para>
///
/// <para><see cref="ResidualSameAsInherent"/> is a stored link, not a
/// copy: an organisation that says "residual follows inherent" means it
/// should keep following when the inherent role changes.</para>
/// </summary>
public sealed record RiskAcceptanceAuthorityRow(
    string RatingCode,
    string? RatingName,
    int? Severity,
    long? InherentRoleId,
    string? InherentRoleName,
    long? ResidualRoleId,
    string? ResidualRoleName,
    bool ResidualSameAsInherent,
    long? EffectiveInherentRoleId,
    string? EffectiveInherentRoleName,
    long? EffectiveResidualRoleId,
    string? EffectiveResidualRoleName,
    bool InherentUsesFallback,
    bool ResidualUsesFallback);

public sealed record RiskAuthorityRoleOption(long RoleId, string RoleName);

/// <summary>
/// The blanket settings from migration 212 that this page defers to.
/// Shown so an unconfigured level reads as "falls back to X" rather than
/// as "nobody approves this".
/// </summary>
public sealed record RiskAuthorityFallback(
    bool ApprovalRequired,
    string? ApprovalMinRatingCode,
    long? FallbackRoleId,
    string? FallbackRoleName);

public sealed record RiskAcceptanceAuthorityResult(
    IReadOnlyList<RiskAcceptanceAuthorityRow> Levels,
    IReadOnlyList<RiskAuthorityRoleOption> Roles,
    RiskAuthorityFallback? Fallback,
    bool Success = true,
    string? Error = null);

/// <summary>
/// One row of the save. <c>InherentRoleId = null</c> clears the override
/// and lets that level fall back; it does not mean "no approver".
/// </summary>
public sealed record RiskAcceptanceAuthorityRowInput(
    string RatingCode,
    long? InherentRoleId,
    long? ResidualRoleId,
    bool ResidualSameAsInherent);

/// <summary>
/// The whole grid in one save — all or nothing. Row-at-a-time would mean
/// a half-saved authority table if one row failed validation.
/// </summary>
public sealed record RiskAcceptanceAuthoritySaveRequest(
    long OrganizationId,
    IReadOnlyList<RiskAcceptanceAuthorityRowInput> Rows,
    long? ActorEmployeeId,
    string? CallerDisplayName);

/// <summary>
/// Who may approve accepting one risk (<c>sp_risk_acceptance_authority_resolve</c>).
///
/// <para><see cref="ResolvedFrom"/> is <c>Configured</c>,
/// <c>SameAsInherent</c>, <c>OrgFallback</c> or <c>NotConfigured</c> — so
/// the acceptance screen can say WHY a role applies instead of just
/// naming one.</para>
/// </summary>
public sealed record RiskAcceptanceAuthorityResolved(
    long RiskRegisterId,
    string? RiskNumber,
    long OrganizationId,
    string ScopeCode,
    string? RatingCode,
    long? ApproverRoleId,
    string? ApproverRoleName,
    string ResolvedFrom);

// =====================================================================
// Bulk review — migration 270
//
// THIS IS NOT RiskReviewPerformRequest OVER A LIST.
//
// The single-risk review is a RE-ASSESSMENT: RiskCategoryCode,
// LikelihoodCode and ImpactCode are REQUIRED above, and the procedure
// behind them produces a new rating through sp_risk_register_assess.
// Those are per-risk judgements; applying one likelihood/impact pair to
// thirty risks would fabricate an assessment nobody made. So bulk
// carries shared dispositions and no scores, and a risk needing a
// genuine re-score still goes through the single-risk path.
//
// 294 added a fourth, ReviewFrequencyId, on the same test: a cadence is
// a scheduling decision genuinely shared by a quarterly sweep, not an
// assessment of any one risk.
//
// Every field but the ids is optional and NULL means "leave alone", so
// the same contract serves "just move the review dates" and "review,
// note and accept with a cadence" without a second endpoint — which is
// why bulk ACCEPTANCE needs no endpoint of its own.
// =====================================================================

/// <summary>
/// Apply one review disposition across a selection of risks
/// (migration 270).
///
/// <para><b>Status is not written directly.</b> `sp_risk_bulk_review`
/// routes it through <c>sp_risk_acceptance_save</c> (for Accepted) or
/// <c>sp_risk_register_status_set</c>, so every §21 rule still applies —
/// a completed analysis, a chosen treatment option, an accepter in the
/// same organisation. Bulk changes the number of risks, not the rules.</para>
///
/// <para><b>Closing and retiring are refused</b> (56724): each needs its
/// own reason under §20, and a bulk form has one shared note.</para>
///
/// <para><see cref="NextReviewDate"/> must be in the future. It fails
/// identically for every risk, so it is rejected once up front (56722)
/// rather than producing N copies of the same message.</para>
/// </summary>
public sealed record RiskBulkReviewRequest(
    IReadOnlyList<long> RiskRegisterIds,
    // The reviewer's note. Written to the review's own remark and the
    // audit trail — NOT to each risk's risk_description, which is what
    // the risk IS and differs per risk.
    string? ReviewRemarks,
    string? StatusCode,
    DateTime? NextReviewDate,
    long? ReviewedByEmployeeId,
    string? CallerDisplayName,
    // 294. The cadence NextReviewDate was derived from, carried across
    // the whole selection. With StatusCode "Accepted" it reaches
    // sp_risk_acceptance_save, so bulk acceptance records a cadence
    // exactly as single acceptance has since 293; otherwise it is
    // COALESCEd into the review stamp. Null means "leave alone".
    //
    // Optional and last, so every pre-294 caller binds unchanged.
    int? ReviewFrequencyId = null);

/// <summary>
/// What happened to one risk. <c>Outcome</c> is <c>Applied</c>,
/// <c>Skipped</c> (with the reason the procedure gave) or
/// <c>Unchanged</c>.
///
/// <para>A skip is information, not a fault: "this risk has no treatment
/// option" is the answer, and the remaining risks still went through.</para>
/// </summary>
public sealed record RiskBulkReviewRow(
    long RiskRegisterId,
    string? RiskNumber,
    string? RiskTitle,
    string Outcome,
    string? Reason,
    string? FromStatus,
    string? ToStatus,
    DateTime? FromReviewDate,
    DateTime? ToReviewDate);

/// <summary>
/// <see cref="Success"/> means the batch ran, NOT that every risk was
/// updated — read <see cref="Rows"/>. A caller that reports "saved"
/// without checking <see cref="SkippedCount"/> is lying to the user.
/// </summary>
public sealed record RiskBulkReviewResult(
    bool Success,
    IReadOnlyList<RiskBulkReviewRow> Rows,
    string? Error = null)
{
    public int AppliedCount   => Rows.Count(r => r.Outcome == "Applied");
    public int SkippedCount   => Rows.Count(r => r.Outcome == "Skipped");
    public int UnchangedCount => Rows.Count(r => r.Outcome == "Unchanged");
}

// =====================================================================
// Bulk accept — migration 295
//
// THIS IS NOT RiskBulkReviewRequest WITH StatusCode "Accepted".
//
// That path stamps a REVIEW — last_reviewed_dt, review_count++, a
// BulkReview history row — which is correct when a risk comes back at
// its review date and is re-accepted, and WRONG for a risk being
// accepted for the first time: it records a review nobody performed.
//
// The two share the only thing that must not diverge: both call
// sp_risk_acceptance_save, so every §21 rule is enforced in one place.
// They differ exactly where they should — the review stamp.
// =====================================================================

/// <summary>
/// Accept a selection of risks in one operation (migration 295).
///
/// <para><b>200 does not mean every risk was accepted.</b> Each risk
/// comes back with <c>Applied</c> or <c>Skipped</c> and its reason; a
/// risk whose analysis is incomplete or which has no treatment option is
/// skipped while the rest proceed. Read <c>skippedCount</c>.</para>
///
/// <para>400 means the BATCH was rejected — nothing selected, no review
/// date, a date in the past, or an unknown cadence. Those fail
/// identically for every risk, so they are refused once (56750–56754)
/// rather than repeated per risk.</para>
/// </summary>
public sealed record RiskBulkAcceptRequest(
    IReadOnlyList<long> RiskRegisterIds,
    // Required, and the procedure refuses without it (56751/56752).
    DateTime NextReviewDate,
    // One accepter for the batch. Null falls through to
    // sp_risk_acceptance_save's COALESCE — each risk's own owner — which
    // is why the UI sends an explicit value rather than relying on it.
    long? AcceptedByEmployeeId,
    DateTime? AcceptedDate,
    string? AcceptanceNote,
    int? ReviewFrequencyId,
    long? ActorEmployeeId,
    string? CallerDisplayName);

/// <summary>
/// What happened to one risk. <c>Outcome</c> is <c>Applied</c> or
/// <c>Skipped</c> — there is no <c>Unchanged</c>, because re-accepting a
/// risk always writes something (at minimum a new review date).
///
/// <para><c>AcceptedOn</c> and <c>ToStatus</c> come back from
/// <c>sp_risk_acceptance_save</c> itself, so they report what was
/// written rather than what was asked for.</para>
/// </summary>
public sealed record RiskBulkAcceptRow(
    long RiskRegisterId,
    string? RiskNumber,
    string? RiskTitle,
    string Outcome,
    string? Reason,
    string? FromStatus,
    string? ToStatus,
    DateTime? AcceptedOn,
    DateTime? NextReviewDate);

/// <summary>
/// <see cref="Success"/> means the batch ran, NOT that every risk was
/// accepted — read <see cref="Rows"/> and <see cref="SkippedCount"/>.
/// </summary>
public sealed record RiskBulkAcceptResult(
    bool Success,
    IReadOnlyList<RiskBulkAcceptRow> Rows,
    string? Error = null)
{
    public int AppliedCount => Rows.Count(r => r.Outcome == "Applied");
    public int SkippedCount => Rows.Count(r => r.Outcome == "Skipped");
}

// ---- Risk scope: practice context + tasks (migration 284) -----------
// Backs the "Existing Controls" section of the risk analysis page. The
// scope panel used to list a mapped practice by name alone; these rows
// carry where it came from and what is being done about it.

/// <summary>One mapped practice with its provenance.</summary>
public sealed record RiskScopePracticeContext(
    long    PracticeId,
    string? PracticeCode,
    string? PracticeName,
    string? FrameworkName,
    string? StructureRootName,
    string? StatementReference,
    string? StatementTitle,
    int     TaskCount);

/// <summary>One task running under a mapped practice.</summary>
public sealed record RiskScopePracticeTask(
    long      TaskId,
    long?     PracticeId,
    string?   Title,
    string?   StatusName,
    string?   Priority,
    DateTime? DueAt,
    string?   AssignedTo);

/// <summary>Both result sets of sp_risk_scope_practice_context.</summary>
public sealed record RiskScopePracticeContextResult(
    IReadOnlyList<RiskScopePracticeContext> Practices,
    IReadOnlyList<RiskScopePracticeTask>    Tasks);
