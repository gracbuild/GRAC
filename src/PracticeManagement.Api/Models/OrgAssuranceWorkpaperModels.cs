// =====================================================================
// OrgAssuranceWorkpaperModels (567, Audit Change spec 4.6 / 4.7)
//
// Request bodies of OrgAssuranceWorkpaperController. Reads come back as
// rows of the procedures (OrgAssuranceWorkpaperService, the
// EvidenceCenterService pattern), so only the writes are typed here.
// =====================================================================
namespace PracticeManagement.Api.Models;

/// <summary>A working paper's fields (create when WorkingPaperId is null).
/// TestResult: SATISFACTORY / PARTIAL / UNSATISFACTORY / NA.</summary>
public sealed record OrgAssuranceWorkingPaperSaveRequest(
    long    OrganizationId,
    long?   WorkingPaperId,
    string? TestingMethodCode,
    string? TestingGuidance,
    string? ProcedurePerformed,
    string? Population,
    string? SamplingMethod,
    int?    SampleSize,
    string? SampleDetails,
    string? EvidenceReferences,
    string? TestResult,
    string? Deviations,
    string? AuditorComments,
    string? Conclusion,
    string? Actor = null);

/// <summary>SUBMIT / REVIEW / RETURN / APPROVE / REOPEN / DELETE; Comment
/// is required to RETURN or REOPEN.</summary>
public sealed record OrgAssuranceWorkingPaperActionRequest(
    long    OrganizationId,
    string  Action,
    string? Comment = null,
    string? Actor   = null);

public sealed record OrgAssuranceQuestionAssignRequest(
    long    OrganizationId,
    long?   AssigneeEmployeeId,
    string? Actor = null);

public sealed record OrgAssuranceQuestionConcludeRequest(
    long    OrganizationId,
    string  ConclusionCode,
    string? Reason = null,
    string? Actor  = null);

public sealed record OrgAssuranceAuditConclusionRequest(
    long    OrganizationId,
    string? Conclusion,
    string? Actor = null);

/// <summary>Raise a finding from a Partially Satisfactory / Unsatisfactory
/// working paper with the spec 4.7 fields.</summary>
public sealed record OrgAssuranceRaiseFindingRequest(
    long      OrganizationId,
    string    Title,
    string?   Description,
    string?   SeverityCode,
    long?     OwnerEmployeeId,
    DateTime? DueDate,
    string?   AuditCriteria,
    string?   ConditionText,
    string?   RootCause,
    string?   RiskImpact,
    string?   Recommendation,
    string?   SupportingEvidence,
    string?   Actor = null);

/// <summary>An observation's spec 4.7 details (Observations -> Finding).</summary>
public sealed record OrgAssuranceObservationFindingRequest(
    long    OrganizationId,
    string? OriginCode,
    string? AuditCriteria,
    string? ConditionText,
    string? RootCause,
    string? RiskImpact,
    string? Recommendation,
    string? ManagementResponse,
    string? CorrectiveAction,
    string? SupportingEvidence,
    string? Actor = null);

/// <summary>The outcome of a write: Id is the working paper / observation
/// made, when one is.</summary>
public sealed record OrgAssuranceWorkpaperResult(
    bool    Success,
    long?   Id         = null,
    string? Error      = null,
    string? ReasonCode = null);
