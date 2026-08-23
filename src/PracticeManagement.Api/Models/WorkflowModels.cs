// =====================================================================
// WorkflowModels
//
// Request / response contracts for WorkflowController (event-driven
// assurance engine per BRD "GRAC -- Workflow & Event-Driven Assurance
// Engine" v1.0).
//
// Follows the same convention as CustomGapModels.cs: one file per
// module, plain records, request records carry organizationId + actor,
// list results carry TotalCount/PageNumber/PageSize + rows.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------- Workflow (BRD Sec 6) ----------
public sealed record WorkflowListQuery(
    long?  OrganizationId,
    string? StatusCode,
    string? Search,
    int Page     = 1,
    int PageSize = 25);

public sealed record WorkflowListRow(
    long   WorkflowId,
    long   OrganizationId,
    string WorkflowCode,
    string WorkflowName,
    string? Description,
    string? ApplicableEntityType,
    string  Version,
    long?   OwnerEmployeeId,
    string  Status,
    bool    IsDefaultTemplate,
    DateTime EnteredDt,
    string  EnteredBy);

public sealed record WorkflowListResult(
    long TotalCount, int PageNumber, int PageSize,
    IReadOnlyList<WorkflowListRow> Rows);

public sealed record WorkflowSaveRequest(
    long?  WorkflowId,
    long   OrganizationId,
    string WorkflowCode,
    string WorkflowName,
    string? Description,
    string? ApplicableEntityType,
    string? Version,
    long?  OwnerEmployeeId,
    string? Status,
    bool?  IsDefaultTemplate,
    long?  ActorEmployeeId);

public sealed record WorkflowCommandResult(
    bool Success, long? WorkflowId, string? Error = null);

// ---------- Workflow Stage (BRD Sec 7) ----------
public sealed record WorkflowStageRow(
    long   WorkflowStageId,
    long   WorkflowId,
    string StageCode,
    string StageName,
    string? Description,
    int    StageSequence,
    long?  PreviousStageId,
    long?  NextStageId,
    string? AllowedTransitions,
    string  Status);

public sealed record WorkflowStageSaveRequest(
    long?  WorkflowStageId,
    long   WorkflowId,
    string StageCode,
    string StageName,
    string? Description,
    int?   StageSequence,
    long?  PreviousStageId,
    long?  NextStageId,
    string? AllowedTransitions,
    string? Status,
    long?  ActorEmployeeId);

public sealed record WorkflowStageCommandResult(
    bool Success, long? WorkflowStageId, string? Error = null);

// ---------- Entity Type (BRD Sec 9) ----------
public sealed record EntityTypeRow(
    long   EntityTypeId,
    long   OrganizationId,
    string EntityTypeCode,
    string EntityTypeName,
    string? Description,
    string? EntityCategory,
    string  Status);

public sealed record EntityTypeSaveRequest(
    long?  EntityTypeId,
    long   OrganizationId,
    string EntityTypeCode,
    string EntityTypeName,
    string? Description,
    string? EntityCategory,
    string? Status,
    long?  ActorEmployeeId);

public sealed record EntityTypeCommandResult(
    bool Success, long? EntityTypeId, string? Error = null);

// ---------- Event Definition (BRD Sec 8) ----------
public sealed record EventDefinitionListQuery(
    long?   OrganizationId,
    string? StatusCode,
    string? EntityCategory,
    string? Search,
    int Page     = 1,
    int PageSize = 25);

public sealed record EventDefinitionRow(
    long   EventDefinitionId,
    long   OrganizationId,
    string EventCode,
    string EventName,
    string? Description,
    string? EntityCategory,
    long?  WorkflowId,
    long?  WorkflowStageId,
    string? TriggerSource,
    string  Status,
    DateTime EnteredDt,
    string  EnteredBy);

public sealed record EventDefinitionListResult(
    long TotalCount, int PageNumber, int PageSize,
    IReadOnlyList<EventDefinitionRow> Rows);

public sealed record EventDefinitionSaveRequest(
    long?  EventDefinitionId,
    long   OrganizationId,
    string EventCode,
    string EventName,
    string? Description,
    string? EntityCategory,
    long?  WorkflowId,
    long?  WorkflowStageId,
    string? TriggerSource,
    string? Status,
    long?  ActorEmployeeId);

public sealed record EventDefinitionCommandResult(
    bool Success, long? EventDefinitionId, string? Error = null);

// ---------- Checklist (BRD Sec 11) ----------
public sealed record ChecklistListQuery(
    long?   OrganizationId,
    string? StatusCode,
    string? Search,
    int Page     = 1,
    int PageSize = 25);

public sealed record ChecklistRow(
    long   ChecklistId,
    long   OrganizationId,
    string ChecklistCode,
    string ChecklistName,
    string? Description,
    string  Version,
    string  Status,
    int     ItemCount,
    DateTime EnteredDt,
    string  EnteredBy);

public sealed record ChecklistListResult(
    long TotalCount, int PageNumber, int PageSize,
    IReadOnlyList<ChecklistRow> Rows);

public sealed record ChecklistSaveRequest(
    long?  ChecklistId,
    long   OrganizationId,
    string ChecklistCode,
    string ChecklistName,
    string? Description,
    string? Version,
    string? Status,
    long?  ActorEmployeeId);

public sealed record ChecklistCommandResult(
    bool Success, long? ChecklistId, string? Error = null);

public sealed record ChecklistItemRow(
    long   ChecklistItemId,
    long   ChecklistId,
    int    ItemSequence,
    string ItemText,
    string ItemType,
    bool   IsMandatory,
    bool   EvidenceRequired,
    bool   AttachmentRequired,
    bool   ApprovalRequired,
    string? ResponsibleRole,
    int?    DuePeriodDays,
    string? EscalationRules,
    string  Status);

public sealed record ChecklistItemSaveRequest(
    long?  ChecklistItemId,
    long   ChecklistId,
    int?   ItemSequence,
    string ItemText,
    string? ItemType,
    bool?  IsMandatory,
    bool?  EvidenceRequired,
    bool?  AttachmentRequired,
    bool?  ApprovalRequired,
    string? ResponsibleRole,
    int?    DuePeriodDays,
    string? EscalationRules,
    string? Status,
    long?  ActorEmployeeId);

public sealed record ChecklistItemCommandResult(
    bool Success, long? ChecklistItemId, string? Error = null);

// ---------- Event-Checklist Mapping (BRD Sec 10) ----------
public sealed record EventChecklistMappingListQuery(
    long?   OrganizationId,
    string? StatusCode,
    int Page     = 1,
    int PageSize = 25);

public sealed record EventChecklistMappingRow(
    long   MappingId,
    long   OrganizationId,
    long   EntityTypeId,
    string EntityTypeName,
    long   EventDefinitionId,
    string EventCode,
    string EventName,
    long   ChecklistId,
    string ChecklistName,
    string? DefaultOwnerRole,
    int?   DefaultDuePeriodDays,
    string Status);

public sealed record EventChecklistMappingListResult(
    long TotalCount, int PageNumber, int PageSize,
    IReadOnlyList<EventChecklistMappingRow> Rows);

// Scope parameters (migration 124) are appended and optional, so every
// existing caller keeps compiling and keeps producing an unscoped mapping
// exactly as before. See EventScopeDimensions for the allowed values.
public sealed record EventChecklistMappingSaveRequest(
    long?  MappingId,
    long   OrganizationId,
    long   EntityTypeId,
    long   EventDefinitionId,
    long   ChecklistId,
    string? DefaultOwnerRole,
    int?   DefaultDuePeriodDays,
    string? Status,
    long?  ActorEmployeeId,
    string? ScopeDimension       = null,
    long?  ScopeRoleId           = null,
    int?   ScopeAssetCategoryId  = null,
    long?  ReleaseId             = null,
    long?  DefaultOwnerRoleId    = null);

public sealed record EventChecklistMappingCommandResult(
    bool Success, long? MappingId, string? Error = null);

// ---------- Event Instance (BRD Sec 13/14) ----------
public sealed record EventInstanceListQuery(
    long?   OrganizationId,
    string? StatusCode,
    string? Search,
    int Page     = 1,
    int PageSize = 25);

public sealed record EventInstanceRow(
    long   EventInstanceId,
    long   OrganizationId,
    long   EventDefinitionId,
    string EventCode,
    string EventName,
    long?  EntityTypeId,
    string? EntityTypeName,
    string? EntityReference,
    string? EntityDisplayName,
    long?  ChecklistId,
    string? ChecklistName,
    string? TriggerSource,
    long?  OwnerEmployeeId,
    DateTime? DueDate,
    string  Status,
    DateTime? CompletedDt,
    DateTime EnteredDt,
    string  EnteredBy);

public sealed record EventInstanceListResult(
    long TotalCount, int PageNumber, int PageSize,
    IReadOnlyList<EventInstanceRow> Rows);

public sealed record EventInstanceTriggerRequest(
    long   OrganizationId,
    long?  EventDefinitionId,
    string? EventCode,
    long?  EntityTypeId,
    string? EntityReference,
    string? EntityDisplayName,
    string? TriggerSource,
    string? PayloadJson,
    long?  OwnerEmployeeId,
    long?  ActorEmployeeId);

public sealed record EventInstanceCommandResult(
    bool Success, long? EventInstanceId, string? Error = null);

public sealed record EventInstanceCompleteRequest(
    long   EventInstanceId,
    long?  ActorEmployeeId,
    string? Comments);

public sealed record EventInstanceItemSaveRequest(
    long   EventInstanceItemId,
    string ItemStatus,
    string? EvidenceUrl,
    string? Remarks,
    long?  ActorEmployeeId);

// ---------- Event Gap (BRD Sec 15) ----------
public sealed record EventGapListQuery(
    long?   OrganizationId,
    string? StatusCode,
    string? Severity,
    int Page     = 1,
    int PageSize = 25);

public sealed record EventGapRow(
    long   EventGapId,
    long   OrganizationId,
    long   EventInstanceId,
    long?  ChecklistItemId,
    string? EntityReference,
    string  Title,
    string? Description,
    string  Severity,
    long?   OwnerEmployeeId,
    DateTime? DueDate,
    string  Status,
    long?   LinkedTaskId,
    DateTime EnteredDt,
    string  EnteredBy);

public sealed record EventGapListResult(
    long TotalCount, int PageNumber, int PageSize,
    IReadOnlyList<EventGapRow> Rows);

public sealed record EventGapOpenRequest(
    long   OrganizationId,
    long   EventInstanceId,
    long?  ChecklistItemId,
    string? EntityReference,
    string Title,
    string? Description,
    string? Severity,
    long?  OwnerEmployeeId,
    DateTime? DueDate,
    long?  ActorEmployeeId);

public sealed record EventGapCloseRequest(
    long   EventGapId,
    long?  ActorEmployeeId,
    string? Remarks);

public sealed record EventGapCommandResult(
    bool Success, long? EventGapId, string? Error = null);

// ---------- Dashboard (BRD Sec 16) ----------
public sealed record WorkflowDashboardCounts(
    long EventsReceived,
    long AssuranceGenerated,
    long PendingAssurance,
    long OverdueAssurance,
    long FailedAssurance,
    long OpenGaps,
    long ActiveWorkflows,
    long ActiveEvents,
    long ActiveChecklists);
