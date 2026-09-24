// =====================================================================
// ExceptionCentreModels  (charter §5)
// Request/response contracts for ExceptionCentreController.
// =====================================================================
using Microsoft.AspNetCore.Http;

namespace PracticeManagement.Api.Models;

public sealed record ExceptionTypeRow(
    int ExceptionTypeId,
    string ExceptionTypeCode,
    string ExceptionTypeName,
    string? Description,
    int SortOrder);

public sealed record ExceptionRequestRow(
    long ExceptionRequestId,
    long OrganizationId,
    // 327: nullable. sp_exception_request_list has LEFT JOINed custom_gap
    // since 193 (task-linked requests never had a gap); this record just
    // never admitted it. A CUSTOM exception is the same shape.
    long? CustomGapId,
    string? GapTitle,
    string RequestTitle,
    string? ExceptionTypeName,
    string StatusCode,          // Pending | Approved | Rejected | Withdrawn | Expired
    DateTime RequestedOn,
    string? RequestedByName,
    DateTime? ApprovedOn,
    string? ApprovedByName,
    DateTime? EffectiveFrom,
    DateTime? EffectiveUntil,
    DateTime? RejectedOn,
    string? RejectedByName,
    int AttachmentCount,
    // Migration 184 -- exception-centre tab filter + SLA-override payload.
    string RequestTypeCode = "GAP_CANDIDATE",
    int?   SlaDaysOriginal  = null,
    int?   SlaDaysRequested = null);

public sealed record ExceptionRequestListResult(
    long TotalRows, int Page, int PageSize,
    IReadOnlyList<ExceptionRequestRow> Rows);

public sealed record ExceptionRequestDetail(
    long ExceptionRequestId,
    long OrganizationId,
    // 327: nullable -- sp_exception_request_get now LEFT JOINs custom_gap
    // so a CUSTOM (or task-linked) exception, which has no gap, no longer
    // vanishes from this read entirely.
    long? CustomGapId,
    string? GapTitle,
    string RequestTitle,
    string? RequestReason,
    string? Justification,
    string? RiskImpact,
    string? ExceptionTypeCode,
    string? ExceptionTypeName,
    long? OwnerEmployeeId,
    string? OwnerName,
    long? LinkedPracticeId,
    string? LinkedRequirementRef,
    string StatusCode,
    // 327: how this request came into being -- GAP_CANDIDATE /
    // SLA_CANDIDATE / TASK_SLA_EXTENSION / TASK_PRIORITY_REDUCTION /
    // CUSTOM. Exception View reads this to show "Source: Custom
    // Exception"; everything else about a CUSTOM row is unmarked.
    string RequestTypeCode,
    long? RequestedByEmployeeId,
    string? RequestedByName,
    DateTime RequestedOn,
    // 260. The window the ANALYST proposed, kept apart from the approved
    // one below: a proposal is not a grant, and every reader of
    // EffectiveFrom/Until (the days-left badge, the expire sweep, the
    // gap extension) treats a value there as approved.
    DateTime? ProposedEffectiveFrom,
    DateTime? ProposedEffectiveUntil,
    long? ApprovedByEmployeeId,
    string? ApprovedByName,
    DateTime? ApprovedOn,
    DateTime? EffectiveFrom,
    DateTime? EffectiveUntil,
    string? ApprovalNote,
    string? CompensatingControl,
    int? ReviewFrequencyId,
    string? ReviewFrequencyName,
    long? RejectedByEmployeeId,
    string? RejectedByName,
    DateTime? RejectedOn,
    string? RejectionReason);

public sealed record ExceptionApproveRequest(
    DateTime EffectiveUntil,
    string ApprovalNote,
    long? ApprovedByEmployeeId,
    DateTime? EffectiveFrom,
    string? CompensatingControl,
    int? ReviewFrequencyId,
    // Optional request-level fields that the approver may fill/edit at
    // approve time if analyst did not capture them earlier.
    string? ExceptionTypeCode,
    string? Justification,
    string? RiskImpact,
    long? OwnerEmployeeId,
    long? LinkedPracticeId,
    string? LinkedRequirementRef,
    string? CallerDisplayName);

// Migration 184 -- SLA Candidate approve. No effective_until / note --
// the requested days already sit on the exception_request row.
public sealed record ExceptionApproveSlaRequest(
    long?   ApprovedByEmployeeId,
    string? CallerDisplayName);

// Fields the analyst / admin can set on Pending (before approval).
public sealed record ExceptionRequestUpdateFields(
    string? ExceptionTypeCode,
    string? Justification,
    string? RiskImpact,
    long? OwnerEmployeeId,
    long? LinkedPracticeId,
    string? LinkedRequirementRef);

public sealed record ExceptionRejectRequest(
    string RejectionReason,
    long? RejectedByEmployeeId,
    string? CallerDisplayName);

public sealed record ExceptionActionResult(
    bool Success,
    long ExceptionRequestId,
    string? StatusCode,
    string? Error);

public sealed class ExceptionAttachmentUploadForm
{
    // Manual (default) requires File; Automated requires EvidenceLocation
    // + EvidenceLocator. Same vocabulary as practice_instance_evidence.
    public string? CollectionMethodCode { get; set; } = "Manual";
    public string? EvidenceTypeCode { get; set; }        // optional; from evidence_type_master
    public IFormFile? File { get; set; }
    public string? EvidenceLocation { get; set; }
    public string? EvidenceLocator { get; set; }
    public long? UploadedByEmployeeId { get; set; }
    public string? CallerDisplayName { get; set; }
}

public sealed record EvidenceTypeRow(
    int EvidenceTypeId,
    string EvidenceTypeCode,
    string EvidenceTypeName,
    int SortOrder);

public sealed record OrganizationPracticeRow(
    long PracticeId,
    string PracticeCode,
    string PracticeName,
    string? ApplicabilityStatus,
    string? PracticeOwner);

/// <summary>
/// One row of <c>grac_practice.sp_risk_review_frequency_list</c> — the
/// Approve Exception dialog's "Review frequency (if applicable)" select.
///
/// Reuses the SAME procedure (and the same <c>grac_practice.
/// frequency_master</c> table) migration 293 already exposes to Risk
/// Centre's Acceptance screen (<c>RiskReviewFrequencyRow</c> /
/// <c>/review-frequencies</c>) -- frequency_master is a shared master
/// table (293's own header: "organization_committee.review_frequency_id
/// is the same column against the same master"), not a Risk-owned one,
/// so Exception Centre reads it the same way rather than adding a second
/// frequency list or a hard-coded set of options. Not modified here.
///
/// FrequencyValue/FrequencyUnit/IsCustom travel through unused today
/// (the Approve dialog only needs Id/Name to populate the select and
/// save/display the choice) but are kept on the row rather than
/// projected away, matching the shape callers of this same procedure
/// already rely on elsewhere.
/// </summary>
public sealed record ExceptionReviewFrequencyRow(
    int     FrequencyId,
    string? FrequencyCode,
    string  FrequencyName,
    int?    FrequencyValue,
    string? FrequencyUnit,
    bool    IsCustom);

public sealed record ExceptionAttachmentRow(
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
// Migration 257 — the Analysis stage
//
// A Pending request is ANALYSED, then SUBMITTED for approval, and only
// then can be Approved or Rejected. The analysis owns the request-level
// detail that used to be captured inside the Approve modal, plus the
// remediation tasks attached to the exception.
// =====================================================================

/// <summary>
/// What the analysis page saves. Every field is optional and
/// COALESCE-preserved by the procedure, so a partial analysis can be
/// saved without blanking what is already recorded.
/// <para>
/// Deliberately absent: linked practice (displayed from the request, not
/// chosen), linked requirement ref, approval note and compensating
/// control. The approval note belongs to the approver's form.
/// </para>
/// </summary>
public sealed record ExceptionAnalysisSaveRequest(
    string? ExceptionTypeCode,
    string? Justification,
    string? RiskImpact,
    long?   OwnerEmployeeId,
    // 260. Optional on save so a draft can be parked; the procedure
    // refuses SUBMIT FOR APPROVAL until both are set, which is where the
    // requirement actually bites.
    DateTime? ProposedEffectiveFrom,
    DateTime? ProposedEffectiveUntil,
    string? CallerDisplayName);

/// <summary>
/// One row of exception_request_history (161). Written since 161 by
/// create / approve / reject / withdraw / submit, and — from 260 —
/// 'EffectiveDatesChanged' when an approver overrules the analyst's
/// proposed window. Read-only: the trail is appended by the procedures,
/// never edited.
/// </summary>
public sealed record ExceptionHistoryRow(
    long      HistoryId,
    long      ExceptionRequestId,
    string    ActionCode,
    string?   FromStatusCode,
    string?   ToStatusCode,
    string?   Remark,
    long?     ActorEmployeeId,
    string?   ActorName,
    DateTime  EnteredOn);

public sealed record ExceptionSubmitForApprovalRequest(
    long?   ActorEmployeeId,
    string? CallerDisplayName);

/// <summary>A remediation task attached to an exception.</summary>
public sealed record ExceptionTaskRow(
    long      ExceptionRequestTaskId,
    long      TaskId,
    string?   TaskNumber,
    string?   TaskTitle,
    string?   TaskTypeCode,
    string?   TaskTypeName,
    string?   TaskStatusCode,
    string?   TaskStatusName,
    string?   Priority,
    DateTime? DueAt,
    long?     AssignedToEmployeeId,
    string?   AssignedToName,
    /// <summary>Created from the analysis page, or Mapped to it. "We
    /// raised this to fix it" and "this already existed and also covers
    /// it" are different claims.</summary>
    string?   LinkSourceCode,
    string?   LinkedBy,
    DateTime? LinkedOn);

/// <summary>
/// A task offered by the "map an existing task" picker: everything under
/// the exception's linked practice. Already-linked tasks come back with
/// <see cref="IsLinked"/> set rather than being filtered out, so the
/// picker can show them ticked instead of appearing to have lost them.
/// </summary>
public sealed record ExceptionTaskCandidateRow(
    long      TaskId,
    string?   TaskNumber,
    string?   TaskTitle,
    string?   TaskTypeCode,
    string?   TaskTypeName,
    string?   TaskStatusCode,
    string?   TaskStatusName,
    string?   Priority,
    DateTime? DueAt,
    string?   AssignedToName,
    bool      IsLinked);

public sealed record ExceptionTaskLinkRequest(
    long    TaskId,
    /// <summary>"Created" or "Mapped"; anything else is treated as Mapped.</summary>
    string? LinkSourceCode,
    string? CallerDisplayName);

/// <summary>
/// The candidate list plus the practice it was scoped to (migration 258).
/// Carrying the scope means an empty grid can say WHICH practice had no
/// tasks, or that no practice could be resolved — rather than leaving the
/// operator to guess which of the two happened.
/// </summary>
public sealed record ExceptionTaskCandidatesResult(
    IReadOnlyList<ExceptionTaskCandidateRow> Rows,
    long?   PracticeId,
    string? PracticeCode,
    string? PracticeName,
    /// <summary>
    /// Migration 259. "Practice" — scoped to the exception's practice.
    /// "Organization" — no practice could be resolved (a Custom gap has
    /// no practice instance behind it), so every task in the org is
    /// offered. Tasks already attached to the exception are included
    /// under both, wherever they live.
    /// </summary>
    string? ScopeCode = null);

// =====================================================================
// Migration 327 — Custom Exception creation
//
// "Exception Management -> Add Custom Exception -> Enter Basic Details
// -> Save -> Exception Request Created -> Existing Exception Approval /
// Processing Flow." The fields below are exactly the ones
// sp_exception_request_create already accepted (organization/title/
// description/justification/owner/requested-by/linked practice/linked
// requirement/related gap/proposed dates) plus nothing else -- no new
// column exists for "Description" or "Justification" because the
// existing request_reason and justification columns already cover them,
// and there is no separate "Framework" concept anywhere in the Exception
// model to reuse (it is implicit in whichever Practice/Control is
// picked, same as every other exception).
//
// 328 follow-up: Related Control / Practice now accepts more than one,
// via LinkedPracticeIds below -- see that field's own comment.
// =====================================================================
public sealed record ExceptionCreateCustomRequest(
    long    OrganizationId,
    string  RequestTitle,
    /// <summary>Maps to request_reason -- the "Exception Description" field.</summary>
    string? RequestReason,
    /// <summary>Maps to justification -- the "Reason / Justification" field.
    /// Same column the Analysis stage later edits; capturing it here just
    /// gives the analyst a starting point instead of a blank box.</summary>
    string? Justification,
    string? ExceptionTypeCode,
    long?   OwnerEmployeeId,
    long?   RequestedByEmployeeId,
    /// <summary>"Related Control / Practice / Obligation, where applicable."
    /// Kept for any future caller that wants to set the single "primary"
    /// practice directly. The Add Custom Exception dialog (328) no longer
    /// sends this -- it sends <see cref="LinkedPracticeIds"/> instead, and
    /// the procedure derives this one from the first entry when it is not
    /// supplied explicitly.</summary>
    long?   LinkedPracticeId,
    string? LinkedRequirementRef,
    /// <summary>328. "Related Control / Practice(s), where applicable" --
    /// every practice picked via the reusable cascading Practice Picker
    /// (the same window.__practicePicker Risk Centre's Map Practice dialog
    /// uses), one Add per practice. Null or empty means none, same as
    /// every other optional field here. Serialized to JSON and passed to
    /// sp_exception_request_create's @practice_ids_json.</summary>
    IReadOnlyList<long>? LinkedPracticeIds,
    /// <summary>"Related Gap, where applicable." Optional on purpose -- a
    /// Custom Exception is precisely the one that does NOT require a gap;
    /// this only validates and links one if the analyst names it.</summary>
    long?   CustomGapId,
    /// <summary>"Valid From" / "Valid Until / Expiry Date." These are the
    /// analyst's PROPOSED window (260's proposed_effective_from/until),
    /// not the approved effective_from/until -- an un-approved exception
    /// must not look approved to the days-left badge or the expiry sweep.</summary>
    DateTime? ProposedEffectiveFrom,
    DateTime? ProposedEffectiveUntil,
    string? CallerDisplayName);
