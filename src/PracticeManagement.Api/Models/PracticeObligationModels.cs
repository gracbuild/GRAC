// =====================================================================
// PracticeObligationModels
//
// The practice-level obligation: authored once against a PRACTICE and
// fanned out to every Practice Instance of it (migration 307).
//
// Field names mirror ResolveLocalObligation* on purpose. The same form
// writes both -- Shared/obligation-form.js, scope "instance" or
// "practice" -- so a field that means the same thing is called the same
// thing on both sides, and the form does not have to translate.
//
// What is deliberately NOT here, and why:
//   ImplementationStatusId  status is a fact about DOING the work, and
//   ConnectionTypeId        the work happens on an instance. Two teams
//   ConnectionUrl           carrying out one practice are not at the
//                           same stage, and an automated check points at
//                           each team's own endpoint. The practice says
//                           WHAT is required; the instance answers HOW
//                           FAR and AGAINST WHAT. See migration 307.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------- grac_practice.sp_practice_obligation_list ----------
public sealed record PracticeObligationRow(
    long    PracticeObligationId,
    long    OrganizationId,
    long    PracticeId,
    string? ObligationName,
    string? ObligationDescription,
    string? ObligationTypeCode,
    string? TypeName,
    /// <summary>
    /// The same JSON array shape vw_pm_obligation_typed_detail emits, for
    /// the reason migration 227 gives: mirroring Control Management's six
    /// detail tables would mean copying a schema this module does not own.
    /// </summary>
    string? TypedDetailJson,
    int?    ExecutionFrequencyId,
    string? ExecutionFrequency,
    string? Responsibility,
    string? ApprovalAuthority,
    string? AssuranceType,
    string? Remarks,
    /// <summary>
    /// The declared evidence list, as the form sent it. Stored rather
    /// than only replayed at save time, because an instance created later
    /// has to be seeded from it.
    /// </summary>
    string? EvidenceJson,
    string? Status,
    string? EnteredBy,
    DateTime? EnteredDt,
    /// <summary>
    /// How many active instances currently carry a copy. The one fact the
    /// panel needs that the definition itself does not hold — it is what
    /// makes "this applies everywhere" visible rather than promised.
    /// </summary>
    int     InstanceCount);

public sealed record PracticeObligationListResult(
    bool Success,
    IReadOnlyList<PracticeObligationRow> Obligations,
    string? Error = null);

// ---------- grac_practice.sp_practice_obligation_save ----------
/// <summary>
/// PracticeObligationId = 0 adds; anything else edits that definition.
/// Retire = true removes it from the practice and, through the fan-out,
/// from every instance.
/// </summary>
public sealed record PracticeObligationSaveRequest(
    long    PracticeId,
    long?   OrganizationId,
    long    PracticeObligationId,
    string? ObligationName,
    string? ObligationDescription,
    string? ObligationTypeCode,
    string? TypedDetailJson,
    int?    ExecutionFrequencyId,
    string? ExecutionFrequency,
    string? Responsibility,
    string? ApprovalAuthority,
    string? AssuranceType,
    string? Remarks,
    /// <summary>
    /// Null means "leave the stored list alone" and an empty array means
    /// "no evidence" — the same contract migration 232 established for
    /// the instance-level form.
    /// </summary>
    IReadOnlyList<PracticeObligationEvidenceItem>? Evidence,
    bool    Retire,
    string? Actor);

public sealed record PracticeObligationEvidenceItem(
    int     EvidenceTypeId,
    bool    IsMandatory,
    string? RetentionPeriod,
    string? Remarks);

/// <summary>
/// The fan-out counts travel back on the same row as the outcome, which
/// is the shape migration 233 established: a procedure another procedure
/// EXECs must not SELECT, so its numbers ride out as columns instead.
/// </summary>
public sealed record PracticeObligationSaveResult(
    bool    Success,
    long?   PracticeObligationId,
    string? Message = null,
    string? Error = null,
    int     CopiesCreated = 0,
    int     CopiesUpdated = 0,
    int     CopiesRetired = 0,
    int     EvidenceSynced = 0);

// ---------- grac_practice.sp_practice_obligation_fan_out ----------
/// <summary>
/// Reconciliation, for instances created after a definition existed.
/// Every argument is optional in the procedure: naming only the practice
/// means "every definition, every active instance".
/// </summary>
public sealed record PracticeObligationFanOutResult(
    bool    Success,
    int     CopiesCreated = 0,
    int     CopiesUpdated = 0,
    int     CopiesRetired = 0,
    int     EvidenceSynced = 0,
    string? Error = null);
