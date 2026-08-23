// =====================================================================
// EventScopeModels
//
// Request / response contracts for EventScopeController -- role and
// asset-category scoped event assurance (migrations 123 / 124).
//
// Separate from WorkflowModels.cs on purpose: WorkflowModels covers the
// 066/067 engine as shipped, this file covers the scoping layer added on
// top. Reviewing them apart keeps the diff on the original engine small.
//
// Same conventions as WorkflowModels / CustomGapModels: plain records,
// request records carry OrganizationId + ActorEmployeeId, list results
// carry the rows.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------- Shared vocabulary ----------
public static class EventScopeDimensions
{
    public const string OrgRole       = "ORG_ROLE";
    public const string AssetCategory = "ASSET_CATEGORY";

    public static bool IsValid(string? value)
        => value is null or OrgRole or AssetCategory;
}

public static class EventSubjectEntities
{
    public const string Employee = "EMPLOYEE";
    public const string Asset    = "ASSET";

    public static bool IsValid(string? value)
        => value is Employee or Asset;
}

public static class EventLifecycleActions
{
    public const string Onboard      = "ONBOARD";
    public const string Offboard     = "OFFBOARD";
    public const string Commission   = "COMMISSION";
    public const string Decommission = "DECOMMISSION";
}

// ---------- Mapping workspace (sp_event_scope_mapping_list) ----------
public sealed record EventScopeMappingQuery(
    long    OrganizationId,
    long?   EventDefinitionId,
    string? ScopeDimension,
    long?   ScopeRoleId,
    int?    ScopeAssetCategoryId);

public sealed record EventScopeMappingRow(
    long    ChecklistId,
    string  ChecklistCode,
    string  ChecklistName,
    string  ChecklistVersion,
    long    EventDefinitionId,
    string  EventCode,
    string  EventName,
    long?   MappingId,
    long?   EntityTypeId,
    string? ScopeDimension,
    long?   ScopeRoleId,
    int?    ScopeAssetCategoryId,
    long?   ReleaseId,
    long?   DefaultOwnerRoleId,
    string? DefaultOwnerRoleName,
    int?    DefaultDuePeriodDays,
    string? MappingStatus,
    // Unmapped | AppliesToAll | Mapped | Inactive
    string  MappingState,
    int     ActiveItemCount);

public sealed record EventScopeMappingResult(
    IReadOnlyList<EventScopeMappingRow> Rows);

// ---------- Coverage (sp_event_scope_coverage_list) ----------
public sealed record EventScopeCoverageQuery(
    long    OrganizationId,
    string  ScopeDimension,
    long?   EventDefinitionId);

public sealed record EventScopeCoverageRow(
    string ScopeDimension,
    long   ScopeValueId,
    string ScopeValueName,
    int    TotalChecklists,
    int    MappedChecklists,
    int    UnmappedChecklists)
{
    public decimal CoveragePercent =>
        TotalChecklists == 0 ? 0 : Math.Round(MappedChecklists * 100m / TotalChecklists, 1);
}

public sealed record EventScopeCoverageResult(
    IReadOnlyList<EventScopeCoverageRow> Rows);

// ---------- Raise (sp_event_instance_raise_scoped) ----------
public sealed record EventScopedRaiseRequest(
    long      OrganizationId,
    long?     EventDefinitionId,
    string?   EventCode,
    string    SubjectEntity,
    long      SubjectRecordId,
    DateTime? EffectiveDate,
    string?   TriggerSource,
    string?   PayloadJson,
    long?     ActorEmployeeId);

public sealed record PeopleLifecycleRaiseRequest(
    long      OrganizationId,
    long      EmployeeId,
    string    LifecycleAction,          // ONBOARD | OFFBOARD
    DateTime? EffectiveDate,
    string?   EventCode,
    string?   TriggerSource,
    long?     ActorEmployeeId);

public sealed record AssetLifecycleRaiseRequest(
    long      OrganizationId,
    long      AssetId,
    string    LifecycleAction,          // COMMISSION | DECOMMISSION
    DateTime? EffectiveDate,
    string?   EventCode,
    string?   TriggerSource,
    long?     ActorEmployeeId);

// RaisedCount can legitimately be 0 with Success = true: nothing was
// mapped for that role or category. That is a configuration gap, not a
// failure, and the caller should surface it as such rather than as an
// error toast.
public sealed record EventScopedRaiseResult(
    bool    Success,
    int     RaisedCount,
    string? Error = null);

// ---------- Inbox (sp_event_checklist_inbox_list) ----------
public sealed record EventChecklistInboxQuery(
    long    OrganizationId,
    long?   OwnerEmployeeId,
    string? SubjectEntity,
    string? StatusFilter,
    bool    OverdueOnly = false);

public sealed record EventChecklistInboxRow(
    long      EventInstanceId,
    string    EventCode,
    string    EventName,
    string?   SubjectEntity,
    long?     SubjectRecordId,
    string?   SubjectLabel,
    long?     ScopeRoleId,
    string?   ScopeRoleName,
    int?      ScopeAssetCategoryId,
    string?   ScopeAssetCategoryName,
    long?     ChecklistId,
    string?   ChecklistName,
    long?     OwnerEmployeeId,
    string?   OwnerEmployeeName,
    DateTime? EffectiveDate,
    DateTime? DueDate,
    string    InstanceStatus,
    bool      IsOverdue,
    int?      DaysOverdue,
    int       ItemCount,
    int       ItemsDone);

public sealed record EventChecklistInboxResult(
    IReadOnlyList<EventChecklistInboxRow> Rows);

// ---------- Instance detail (sp_event_instance_detail_get) ----------
public sealed record EventInstanceDetailHeader(
    long      EventInstanceId,
    string    EventCode,
    string    EventName,
    string?   SubjectEntity,
    long?     SubjectRecordId,
    string?   SubjectLabel,
    long?     ScopeRoleId,
    string?   ScopeRoleName,
    int?      ScopeAssetCategoryId,
    string?   ScopeAssetCategoryName,
    long?     ReleaseId,
    long?     SourceMappingId,
    long?     ChecklistId,
    string?   ChecklistName,
    string?   ChecklistVersion,
    long?     OwnerEmployeeId,
    string?   OwnerEmployeeName,
    DateTime? EffectiveDate,
    DateTime? DueDate,
    string    InstanceStatus,
    DateTime? CompletedDt,
    string?   Comments);

public static class EventItemOrigins
{
    public const string Checklist  = "CHECKLIST";
    public const string Obligation = "OBLIGATION";

    public static bool IsValid(string? value) => value is Checklist or Obligation;
}

// ItemId is an identity from event_instance_item OR from
// event_instance_obligation depending on ItemOrigin -- the two sequences
// overlap, so the origin must travel with the id all the way back to the
// save call (migration 132).
public sealed record EventInstanceDetailItem(
    string    ItemOrigin,
    long      ItemId,
    long      SourceId,          // checklist_item_id or obligation_id
    int       ItemSequence,
    string    ItemText,
    string    ItemType,
    bool      IsMandatory,
    bool      EvidenceRequired,
    bool      AttachmentRequired,
    bool      ApprovalRequired,
    string?   ResponsibleRole,
    string    ItemStatus,
    string?   EvidenceUrl,
    string?   Remarks,
    string?   NaJustification,
    string?   CompletedBy,
    DateTime? CompletedDt);

public sealed record EventInstanceObligationSaveRequest(
    long    OrganizationId,
    long    EventInstanceObligationId,
    string  ItemStatus,
    string? EvidenceUrl,
    string? Remarks,
    string? NaJustification,
    long?   ActorEmployeeId);

public sealed record EventInstanceDetailResult(
    EventInstanceDetailHeader? Header,
    IReadOnlyList<EventInstanceDetailItem> Items)
{
    private static bool Resolved(string status)
        => status is "Passed" or "Failed" or "NotApplicable";

    // Mirrors the server-side submit gate exactly, including 132's rule that
    // an instance with no items at all cannot be completed.
    public bool CanSubmit =>
        Header is not null
        && Header.InstanceStatus is not ("Completed" or "Cancelled")
        && Items.Count > 0
        && Items.Where(i => i.IsMandatory).All(i => Resolved(i.ItemStatus));

    public IReadOnlyList<int> OutstandingMandatorySequences =>
        Items.Where(i => i.IsMandatory && !Resolved(i.ItemStatus))
             .Select(i => i.ItemSequence)
             .ToList();
}

// =====================================================================
// Obligation-based scoping (migrations 127 / 128)
//
// This is the substrate the business actually maps to a role: an
// obligation inherited from a subscribed release, not a hand-authored
// checklist. The checklist records above remain for organizations that
// author their own checklists; both paths coexist.
// =====================================================================

public sealed record EventObligationMappingQuery(
    long    OrganizationId,
    long?   EventTypeId,
    string? EventTypeCode,
    string  ScopeDimension,
    long?   ScopeRoleId,
    int?    ScopeAssetCategoryId,
    bool    IncludeUnsubscribed = false);

public sealed record EventObligationMappingRow(
    long    ObligationId,
    string? ObligationLabel,
    string? ObligationText,
    long?   PracticeId,
    string? PracticeCode,
    string? PracticeName,
    string? RequirementCode,
    string? RequirementName,
    long    EventTypeId,
    string? EventTypeCode,
    string? EventTypeName,
    string? SubjectEntity,
    long?   ReleaseId,
    bool    IsSubscribed,
    string? PracticeApplicability,
    string? RequirementApplicability,
    long?   ApplicabilityId,
    bool?   IsApplicable,
    string? Rationale,
    long?   OwnerRoleId,
    string? OwnerRoleName,
    int?    DueDays,
    string? MappingStatus,
    // Unmapped | Mapped | NotApplicable | Inactive
    string  MappingState);

public sealed record EventObligationMappingResult(
    IReadOnlyList<EventObligationMappingRow> Rows);

public sealed record EventObligationApplicabilitySaveRequest(
    long    OrganizationId,
    long    ObligationId,
    long    EventTypeId,
    string  ScopeDimension,
    long?   ScopeRoleId,
    int?    ScopeAssetCategoryId,
    bool    IsApplicable,
    string? Rationale,
    long?   OwnerRoleId,
    int?    DueDays,
    string? Status,
    long?   ActorEmployeeId);

public sealed record EventObligationApplicabilityCommandResult(
    bool Success, long? ApplicabilityId, string? Error = null);

// Two questions, two numbers (migration 130).
//   Decided    -- has every obligation been triaged? The GAP metric.
//   Applicable -- how many actually apply here?      The WORKLOAD metric.
// An undecided obligation is an unknown; an excluded one is a documented
// judgement. Reporting them as the same thing is how a compliance hole
// gets signed off, so they stay separate all the way to the screen.
public sealed record EventObligationCoverageRow(
    string ScopeDimension,
    long   ScopeValueId,
    string ScopeValueName,
    int    TotalObligations,
    int    DecidedObligations,
    int    UndecidedObligations,
    int    ApplicableObligations,
    int    ExcludedObligations)
{
    public decimal DecidedPercent =>
        TotalObligations == 0 ? 0 : Math.Round(DecidedObligations * 100m / TotalObligations, 1);

    public decimal ApplicablePercent =>
        TotalObligations == 0 ? 0 : Math.Round(ApplicableObligations * 100m / TotalObligations, 1);

    /// <summary>Fully triaged, but nothing applies -- worth surfacing distinctly.</summary>
    public bool FullyExcluded =>
        TotalObligations > 0 && UndecidedObligations == 0 && ApplicableObligations == 0;
}

public sealed record EventObligationCoverageResult(
    IReadOnlyList<EventObligationCoverageRow> Rows);

// =====================================================================
// Custom checklist questions per scope + event (migration 136)
//
// These sit alongside the inherited obligations in the Role Master and
// Asset Category forms. The obligations come from
// EventObligationMappingRow above; these are the organization's own
// additions for the same scope and event.
// =====================================================================

public sealed record ScopeQuestionQuery(
    long    OrganizationId,
    string  ScopeDimension,
    long?   ScopeRoleId,
    int?    ScopeAssetCategoryId,
    string  EventTypeCode);

public sealed record ScopeQuestionRow(
    long    ChecklistItemId,
    long    ChecklistId,
    int     SortOrder,
    string  QuestionText,
    string  ItemType,
    bool    IsMandatory,
    bool    EvidenceRequired,
    string? ResponsibleRole,
    string  Status);

public sealed record ScopeQuestionResult(
    IReadOnlyList<ScopeQuestionRow> Rows);

public sealed record ScopeQuestionSaveRequest(
    long    OrganizationId,
    string  ScopeDimension,
    long?   ScopeRoleId,
    int?    ScopeAssetCategoryId,
    string  EventTypeCode,
    long?   ChecklistItemId,        // null = add
    string  QuestionText,
    bool    IsMandatory,
    bool    EvidenceRequired,
    string? ResponsibleRole,
    int?    SortOrder,
    long?   ActorEmployeeId);

public sealed record ScopeQuestionDeleteRequest(
    long OrganizationId,
    long ChecklistItemId,
    long? ActorEmployeeId);

public sealed record ScopeQuestionCommandResult(
    bool Success, long? ChecklistItemId, string? Error = null);

// ---------- Resolution trace (sp_event_resolution_trace_list) ----------
public sealed record EventResolutionTraceQuery(
    long    OrganizationId,
    string? SubjectEntity,
    long?   SubjectRecordId,
    long?   EventInstanceId,
    bool    GapsOnly = false);

public sealed record EventResolutionTraceRow(
    long      ResolutionId,
    long      EventDefinitionId,
    string    EventCode,
    string    EventName,
    string    SubjectEntity,
    long      SubjectRecordId,
    string?   SubjectLabel,
    DateTime? EffectiveDate,
    long?     MappingId,
    long?     ChecklistId,
    string?   ChecklistName,
    string?   ScopeDimension,
    long?     ScopeRoleId,
    string?   ScopeRoleName,
    int?      ScopeAssetCategoryId,
    string?   ScopeAssetCategoryName,
    long?     ReleaseId,
    string    Decision,
    string    ReasonCode,
    string?   ReasonDetail,
    long?     EventInstanceId,
    string    EnteredBy,
    DateTime  EnteredDt);

public sealed record EventResolutionGapRow(
    string    ReasonCode,
    long      EventDefinitionId,
    string    EventCode,
    string    SubjectEntity,
    long?     ScopeRoleId,
    string?   ScopeRoleName,
    int?      ScopeAssetCategoryId,
    string?   ScopeAssetCategoryName,
    int       OccurrenceCount,
    DateTime  FirstSeenDt,
    DateTime  LastSeenDt);

public sealed record EventResolutionTraceResult(
    IReadOnlyList<EventResolutionTraceRow> Rows,
    IReadOnlyList<EventResolutionGapRow>   Gaps);
