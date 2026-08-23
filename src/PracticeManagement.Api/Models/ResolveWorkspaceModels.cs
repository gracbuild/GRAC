// =====================================================================
// ResolveWorkspaceModels
//
// Shapes for the rebuilt Resolve screens (migrations 140/141): the
// owner-scoped instance list, and the per-instance workspace carrying
// obligations and dependencies.
//
// Property names match the procedures' result aliases exactly, so the
// readers stay a straight lookup with nothing to drift.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------- grac_practice.sp_resolve_instance_list ----------
public sealed record ResolveInstanceQuery(
    long    OrganizationId,
    long?   CallerEmployeeId,
    bool    IsAdmin,
    string? Search,
    int     PageNumber = 1,
    int     PageSize   = 25);

public sealed record ResolveInstanceRow(
    long    PracticeInstanceId,
    string  InstanceCode,
    string  InstanceName,
    long?   PracticeId,
    string? PracticeCode,
    string? PracticeName,
    long?   OwnerEmployeeId,
    string? OwnerName,
    string? Department,
    string? Criticality,
    string? ImplementationStatus,
    string? Status,
    int     TotalObligations,
    int     AdoptedObligations,
    int     TotalDependencies,
    int     ResolvedDependencies);

public sealed record ResolveInstanceResult(
    bool Success, IReadOnlyList<ResolveInstanceRow> Rows, string? Error = null);

// ---------- grac_practice.sp_resolve_instance_detail ----------
public sealed record ResolveInstanceDetail(
    long    PracticeInstanceId,
    long    OrganizationId,
    string? OrganizationName,
    string  InstanceCode,
    string  InstanceName,
    long?   PracticeId,
    string? PracticeCode,
    string? PracticeName,
    long?   OwnerEmployeeId,
    string? OwnerName,
    string? Department,
    string? ExecutionFrequency,
    string? AssuranceFrequency,
    string? AssuranceMode,
    string? Criticality,
    string? ImplementationStatus,
    string? Status);

public sealed record ResolveInstanceDetailResult(
    bool Success, ResolveInstanceDetail? Instance, string? Error = null);

// ---------- grac_practice.sp_resolve_obligation_list ----------
public sealed record ResolveObligationRow(
    long    ObligationId,
    string  ObligationName,
    string? ObligationText,
    string? TypeCode,
    string? TypeName,
    long?   ReleaseId,
    string? FrameworkRelease,
    bool    IsSubscribed,
    // As published by the authority.
    string? PublishedExecutionFrequency,
    string? PublishedResponsibility,
    string? PublishedApprovalAuthority,
    string? PublishedRetention,
    // As adopted here; null until the organization adopts it.
    long?   AdoptionId,
    bool    IsAdopted,
    bool    OrganizationModified,
    int?    ExecutionFrequencyId,
    string? ExecutionFrequency,
    int?    AssuranceFrequencyId,
    string? AssuranceFrequency,
    string? Responsibility,
    string? ApprovalAuthority,
    string? RetentionPeriod,
    string? Remarks,
    string? AdoptedBy,
    DateTime? AdoptedDt,
    int     PublishedEvidenceCount,
    int     ResolvedEvidenceCount);

public sealed record ResolveObligationResult(
    bool Success, IReadOnlyList<ResolveObligationRow> Obligations, string? Error = null);

// ---------- grac_practice.sp_resolve_obligation_adopt ----------
/// <summary>
/// One decision per obligation. Leave a parameter null to take the
/// published value; the procedure derives OrganizationModified from what
/// actually differs, so nothing here asserts it.
/// </summary>
public sealed record ResolveObligationDecision(
    long    ObligationId,
    bool    IsAdopted,
    int?    ExecutionFrequencyId,
    string? ExecutionFrequency,
    int?    AssuranceFrequencyId,
    string? AssuranceFrequency,
    string? Responsibility,
    string? ApprovalAuthority,
    string? RetentionPeriod,
    string? Remarks);

public sealed record ResolveObligationAdoptRequest(
    long PracticeInstanceId,
    long? OrganizationId,
    IReadOnlyList<ResolveObligationDecision> Obligations,
    string? Actor);

public sealed record ResolveObligationOutcome(
    long    ObligationId,
    string? ObligationName,
    string  Outcome,
    bool    OrganizationModified,
    bool    NotSubscribed,
    int     EvidenceRows,
    int     UnmappedEvidenceTypes);

public sealed record ResolveObligationAdoptResult(
    bool Success,
    IReadOnlyList<ResolveObligationOutcome> Outcomes,
    string? Error = null)
{
    public int AdoptedCount => Outcomes.Count(o => o.Outcome == "Adopted");
    public int RemovedCount => Outcomes.Count(o => o.Outcome == "Removed");
    /// <summary>
    /// Published evidence types with no practice-side equivalent. Those
    /// rows were not created, and the screen says so rather than letting
    /// the count quietly disagree with the obligation.
    /// </summary>
    public int UnmappedEvidenceTypes => Outcomes.Sum(o => o.UnmappedEvidenceTypes);
}

// ---------- grac_practice.sp_resolve_dependency_list ----------
public sealed record ResolveDependencyCategory(
    int     DependencyTypeId,
    string  DependencyCategory,
    long?   DependencyId,
    int     ResolvedCount,
    string? ResolvedNames,
    bool    IsResolved);

public sealed record ResolveDependencyItem(
    long    ResolutionId,
    int     DependencyTypeId,
    long    ResolvedDependencyId,
    string  ResolvedDependencyName,
    long?   ResolutionOwnerId,
    string? ResolutionOwnerName,
    string? Remarks,
    string? ResolutionStatus);

public sealed record ResolveDependencyResult(
    bool Success,
    IReadOnlyList<ResolveDependencyCategory> Categories,
    IReadOnlyList<ResolveDependencyItem> Resolutions,
    string? Error = null);

// ---------- grac_practice.sp_resolve_dependency_save ----------
public sealed record ResolveDependencyObject(long Id, string Name);

/// <summary>
/// Several objects per category, in one call. Nothing is deactivated
/// implicitly: sending A and B does not retire C. Removing is the
/// separate, explicit act below, because "one more" and "only these"
/// are different intentions a tick list cannot distinguish.
/// </summary>
public sealed record ResolveDependencySaveRequest(
    long    PracticeInstanceId,
    long?   OrganizationId,
    int     DependencyTypeId,
    IReadOnlyList<ResolveDependencyObject> Objects,
    long?   ResolutionOwnerId,
    string? Remarks,
    string? Actor);

public sealed record ResolveDependencyRemoveRequest(
    long    PracticeInstanceId,
    long    ResolutionId,
    string? Actor);

public sealed record ResolveCommandResult(
    bool Success, string? Message = null, string? Error = null);

// ---------- grac_practice.sp_resolve_instance_frequency_save ----------
/// <summary>
/// Configure defaults these from the practice's obligations; this is how
/// the owner changes them. Null clears a frequency rather than leaving it
/// alone -- both are sent together from one form, so there is no
/// "untouched" case to preserve.
/// </summary>
public sealed record ResolveFrequencySaveRequest(
    long  PracticeInstanceId,
    int?  ExecutionFrequencyId,
    int?  AssuranceFrequencyId,
    string? Actor);

// ---------- grac_practice.sp_resolve_evidence_list ----------
public sealed record ResolveEvidenceRow(
    long    EvidenceId,
    long?   SourceObligationId,
    int     EvidenceTypeId,
    string? EvidenceType,
    bool    IsMandatory,
    int?    CollectionMethodId,
    string? CollectionMethod,
    int?    CollectionFrequencyId,
    string? CollectionFrequency,
    int?    AssuranceTypeId,
    string? AssuranceType,
    string? RetentionPeriod,
    string? EvidenceOwner,
    string? EvidenceDescription,
    string? EvidenceLocation,
    string? EvidenceLocator,
    int?    AlignmentStatusId,
    string? AlignmentStatus,
    bool    InheritedFromRepository,
    bool    OrganizationModified,
    /// <summary>
    /// Location and locator both present -- the same test assurance
    /// eligibility applies, so this cannot say ready where assurance
    /// would then refuse.
    /// </summary>
    bool    IsResolved);

public sealed record ResolveEvidenceResult(
    bool Success, IReadOnlyList<ResolveEvidenceRow> Evidence, string? Error = null);

// ---------- grac_practice.sp_resolve_evidence_save ----------
/// <summary>
/// Null means "leave as it is", so a screen can save one field without
/// resending what it did not touch. ClearOwner is the explicit way to
/// blank an owner, since null cannot mean both "unchanged" and "remove".
/// </summary>
public sealed record ResolveEvidenceSaveRequest(
    long    PracticeInstanceId,
    long    EvidenceId,
    bool?   IsMandatory,
    int?    CollectionMethodId,
    int?    CollectionFrequencyId,
    int?    AssuranceTypeId,
    string? RetentionPeriod,
    long?   OwnerEmployeeId,
    bool    ClearOwner,
    string? EvidenceDescription,
    string? EvidenceLocation,
    string? EvidenceLocator,
    string? Actor);
