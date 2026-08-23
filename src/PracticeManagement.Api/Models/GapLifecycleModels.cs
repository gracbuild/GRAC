// =====================================================================
// GapLifecycleModels  (charter §5)  -- Gap Centre v1.0
//
// Wire contracts for GapLifecycleController. All records; kept in a new
// file to avoid touching the existing CustomGapModels.cs.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---- Bootstrap header (server-derived context, no browser trust) ----
public sealed record GapHeader(
    long CustomGapId,
    long OrganizationId,
    string Title,
    string? Description,
    string? StatusCode,
    string? Priority,
    string? SeverityCode,
    string? SeverityName,
    string? OwnerName,
    long? OwnerEmployeeId,
    DateTime? DueDate,
    string? LifecycleStateCode,
    string? LifecycleStateName,
    // Terminal flags from gap_lifecycle_state_master (migration 173).
    // UI uses (IsTerminal && !IsValidTerminal) to lock the workspace --
    // same rule the server enforces in sp_custom_gap_analysis_save.
    bool LifecycleIsTerminal,
    bool LifecycleIsValidTerminal,
    string? SourceModuleCode,
    // Duplicate / Invalid detail (migration 177). Populated only when
    // the gap is in the matching terminal state.
    long? DuplicateOfGapId,
    string? DuplicateOfGapTitle,
    string? InvalidReason,
    // Migration 185 -- SLA snapshot + pending-override flag. Populated
    // only when sp_custom_gap_apply_sla has matched an Active
    // org_sla_config for the gap's severity_code. Default null so
    // pre-185 servers still return a valid GapHeader.
    long?   SlaMasterId          = null,
    string? SlaMasterName        = null,
    int?    SlaDaysEffective     = null,
    string? SlaSourceCode        = null,
    bool    SlaOverridePending   = false);

// ---- Lifecycle state master ----------------------------------------
public sealed record GapLifecycleStateRow(
    int LifecycleStateId,
    string StateCode,
    string StateName,
    string? Description,
    int SortOrder,
    bool IsTerminal,
    bool IsValidTerminal);

// ---- Lifecycle actions available from a given state ----------------
public sealed record GapLifecycleActionRow(
    string ActionCode,
    string ActionName,
    string? Description,
    bool RemarkRequired,
    string ToStateCode,
    string ToStateName);

// ---- Transition request ---------------------------------------------
public sealed record GapLifecycleTransitionRequest(
    string ActionCode,
    string? Remark,
    long? DuplicateOfGapId,       // required when action -> Duplicate
    string? InvalidReason,         // required when action -> Invalid
    long? CallerEmployeeId,
    string? CallerDisplayName);

public sealed record GapLifecycleTransitionResult(
    bool Success,
    long CustomGapId,
    string? FromStateCode,
    string? ToStateCode,
    string? StatusCode,
    string? Error);

// ---- Analysis record (1:1 with gap) ---------------------------------
public sealed record GapAnalysisModel(
    long CustomGapId,
    string? DetectionMethodCode,
    string? DetectionMethodName,
    string? SeverityCode,
    string? SeverityName,
    string? BusinessImpactCode,
    string? BusinessImpactSummary,
    string? RegulatoryImpactCode,
    string? RegulatoryImpactSummary,
    bool RcaRequired,
    string? RcaMethodCode,
    string? RcaSummary,
    string? RecommendedActionSummary,
    // Legacy flags (proc keeps them in sync with decisions below).
    bool RecommendTask,
    bool RecommendException,
    bool RecommendRisk,
    // Decision model (migration 168). "Y" / "N" -- always present after 168.
    string? RemediationPossible,
    string? BusinessRiskPresent,
    long? AnalysedByEmployeeId,
    DateTime? AnalysedOn,
    string? EnteredBy,
    DateTime? EnteredDt,
    string? UpdatedBy,
    DateTime? UpdatedDt);

public sealed record GapAnalysisSaveRequest(
    string? DetectionMethodCode,
    string? DetectionMethodName,
    string? SeverityCode,
    string? SeverityName,
    string? BusinessImpactCode,
    string? BusinessImpactSummary,
    string? RegulatoryImpactCode,
    string? RegulatoryImpactSummary,
    bool RcaRequired,
    string? RcaMethodCode,
    string? RcaSummary,
    string? RecommendedActionSummary,
    // Legacy fields (kept for backward compat; new UI uses the two
    // decision fields below). If both legacy and new are supplied, the
    // proc gives new priority and derives legacy from it. Migration 168.
    bool RecommendTask,
    bool RecommendException,
    bool RecommendRisk,
    // Sir's decision model (migration 168):
    //   remediation_possible='Y' -> Task Centre; ='N' -> Exception Centre
    //   business_risk_present='Y' -> Risk Centre
    string? RemediationPossible,   // "Y" | "N" | null (falls back to legacy)
    string? BusinessRiskPresent,   // "Y" | "N" | null (falls back to legacy)
    long? AnalysedByEmployeeId,
    string? CallerDisplayName);

public sealed record GapAnalysisSaveResult(bool Success, long CustomGapId, string? Error);

// ---- Materialize (on-demand custom_gap for a practice_instance) ----
public sealed record GapMaterializeFromInstanceRequest(
    long PracticeInstanceId,
    long OrganizationId,
    long? CallerEmployeeId,
    string? CallerDisplayName);

public sealed record GapMaterializeResult(
    bool Success,
    long? CustomGapId,
    bool Created,
    string? Error);

// ---- Linked artefacts (read-only summary for UI chip strip) --------
// One-shot summary of the Task / Exception / Risk artefacts that share
// the gap's custom_gap_id. Sourced directly from practice_task /
// exception_request / risk_candidate (not from downstream_link).
public sealed record GapLinkedArtefactRow(
    string ArtefactType,     // "Task" | "Exception" | "RiskCandidate"
    long ArtefactId,
    string? Title,
    string? StatusCode);

public sealed record GapLinkedArtefactsResult(
    GapLinkedArtefactRow? Task,
    GapLinkedArtefactRow? Exception,
    GapLinkedArtefactRow? Risk);

// ---- Downstream link (many:many gap -> Task/Exception/Risk) ---------
public sealed record GapDownstreamLinkRow(
    long LinkId,
    long CustomGapId,
    string ArtefactTypeCode,        // Task | Exception | RiskCandidate
    long? ArtefactId,
    string? ExternalRef,
    string? Title,
    string LinkStatusCode,          // Active | Cancelled
    long? InitiatedByEmployeeId,
    DateTime InitiatedOn,
    long? CancelledByEmployeeId,
    DateTime? CancelledOn,
    string? CancellationReason);

public sealed record GapDownstreamLinkAddRequest(
    string ArtefactTypeCode,
    long? ArtefactId,
    string? ExternalRef,
    string? Title,
    long? InitiatedByEmployeeId,
    string? CallerDisplayName);

public sealed record GapDownstreamLinkCancelRequest(
    string Reason,
    long? CancelledByEmployeeId,
    string? CallerDisplayName);
