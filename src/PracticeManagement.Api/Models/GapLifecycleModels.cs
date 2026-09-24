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
    bool    SlaOverridePending   = false,
    // Migration 250: detection method captured at Add-Gap time on
    // custom gaps. Optional and last -- absent on pre-250 headers,
    // legacy rows, and non-Custom gaps. The gap-detail form reads
    // this as a fallback when the analysis row has no value yet.
    string? DetectionMethodCode  = null,
    string? DetectionMethodName  = null,
    // Migration 321: the Practice Instance this gap materialized from
    // (source_reference_id/source_reference_type = 'PracticeInstance'),
    // if any. Null for Custom/Assurance gaps and for an un-materialized
    // Implementation row. The gap-detail screen's Practice Instance tab
    // shows itself only when PracticeInstanceId is present.
    long?   PracticeInstanceId   = null,
    string? PracticeInstanceCode = null,
    string? PracticeInstanceName = null,
    // Migration 325: when the gap was identified/raised (custom_gap.
    // entered_dt). Optional and last -- absent on a pre-325 header proc,
    // same tolerance pattern as every other field added here since 177.
    // Feeds the Gap View page's "Identified Date" fact.
    DateTime? IdentifiedDate     = null,
    // Migration 367: whether the related Practice Instance is currently
    // Operationalized (same live dependency-resolution computation as
    // the Repository/Register screens and the Practice page). Null when
    // there is no linked Practice Instance (Custom/Assurance gaps) or on
    // a pre-367 header proc. gap-detail.js uses this, together with the
    // linked-artefacts "failed obligations" list, to gate the Analyze
    // action for Implementation-sourced gaps.
    bool?   IsPracticeOperationalized = null);

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
    // Migration 249: separate free-text answer to "so this class of gap
    // does not recur". NULL when the operator has not offered one.
    string? PreventiveAction,
    // Migration 323: these are the three independent decisions again --
    // "Generate Task" / "Request Exception" / "Create Risk" on the
    // Analysis tab bind straight to these three (their original,
    // pre-168 meaning; 168-252 briefly derived them from the two Y/N
    // fields below instead). Any combination is valid.
    bool RecommendTask,
    bool RecommendException,
    bool RecommendRisk,
    // Migration 168, retired by 323: no longer driven by/driving the
    // three flags above. Returned only so a historical row's stored
    // value is still visible; the Analysis tab no longer reads these.
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
    // Migration 249: separate free-text answer to "so this class of gap
    // does not recur". NULL when the operator has not offered one.
    string? PreventiveAction,
    // Migration 323: three independent decisions, each with its own
    // auto-trigger, any combination valid -- replaces the 168 model
    // below. The Analysis tab's three checkboxes (Generate Task /
    // Request Exception / Create Risk) map straight onto these.
    bool RecommendTask,
    bool RecommendException,
    bool RecommendRisk,
    // Migration 168, retired by 323: the UI no longer populates these
    // (always sends null). Kept as accepted parameters only so an
    // older caller does not break; the proc no longer reads them to
    // drive anything and no longer derives them from the three flags
    // above -- a value already stored on the row is left untouched.
    string? RemediationPossible,
    string? BusinessRiskPresent,
    long? AnalysedByEmployeeId,
    string? CallerDisplayName);

// Migration 323: TaskCreated/ExceptionCreated/RiskCreated/*Error carry
// sp_custom_gap_analysis_save's second result set -- whether each
// requested (Generate Task / Request Exception / Create Risk)
// auto-trigger actually succeeded, and its error text if it did not.
// All default false/null so an older, pre-323 database (whose proc
// returns only the first result set) still binds -- GapLifecycleService
// leaves these at their defaults when the second result set is absent.
// Migration 324: LifecycleTransitioned/LifecycleError/LifecycleStateCode/
// LifecycleStateName carry the "Auto-transition to Delegated" step's own
// outcome, the same way TaskCreated/... already report the three
// auto-triggers. Before 324 this step was wrapped in a TRY/CATCH that
// only PRINTed on failure -- and, on a gap with no lifecycle_state_id
// yet (every Custom gap opened before 324), the transition was skipped
// entirely with no error at all, which is why the gap's status silently
// never reached "Analysed". LifecycleStateCode/LifecycleStateName are the
// gap's fresh post-save lifecycle state, read once the auto-transition
// attempt (successful or not) is done, so a caller has the true status
// directly from the save call. All four default to false/null so a
// database still on the pre-324 proc (single result set, or the pre-324
// shape of the second one) degrades to those defaults instead of
// throwing -- same HasColumn-guarded pattern as TaskCreated/... below.
public sealed record GapAnalysisSaveResult(
    bool Success,
    long CustomGapId,
    string? Error,
    bool TaskCreated = false,
    string? TaskError = null,
    bool ExceptionCreated = false,
    string? ExceptionError = null,
    bool RiskCreated = false,
    string? RiskError = null,
    bool LifecycleTransitioned = false,
    string? LifecycleError = null,
    string? LifecycleStateCode = null,
    string? LifecycleStateName = null);

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

// ---- Failed Obligation(s) behind an automatically generated gap ----
// Migration 317. Populated ONLY for a gap that IS an Implementation gap
// materialized from a Practice Instance (custom_gap.source_reference_type
// = 'PracticeInstance') -- sourced from practice_gap_obligation (245),
// the same snapshot the sync proc already keeps current on every
// obligation save. Empty for every manually created gap (Assurance,
// Custom, Exception, Risk, Audit source, or a hand-entered Custom gap),
// so a manual gap is never shown against an Obligation it has nothing
// to do with.
public sealed record GapFailedObligationRow(
    long ObligationId,          // practice_instance_obligation_id
    string? ObligationName,     // snapshotted at the moment it entered the gap
    string? ObligationTypeCode,
    string LoggedStatusCode,    // "Not Implemented" | "Partially Implemented" | "Not Started" -- snapshot, taken when this row was (re)inserted; does not track later status changes
    DateTime? AddedDt,
    // Migration 372: fresh, live-joined status (never stale, unlike LoggedStatusCode above).
    // Optional/nullable so a pre-372 database (column not yet present in the result set) degrades
    // gracefully -- see GapLifecycleService.ListLinkedArtefactsAsync's HasColumn() guard.
    string? CurrentStatusCode = null);

public sealed record GapLinkedArtefactsResult(
    GapLinkedArtefactRow? Task,
    GapLinkedArtefactRow? Exception,
    GapLinkedArtefactRow? Risk,
    IReadOnlyList<GapFailedObligationRow> FailedObligations);

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
