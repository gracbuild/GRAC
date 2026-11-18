// =====================================================================
// OrgAssuranceUniverseModels (577, CR2 - AA Part A -- Audit Universe;
// 580, Part B -- Framework & Practice Mapping)
//
// Request bodies of OrgAssuranceUniverseController. Reads come back as the
// procedures' rows (OrgAssuranceUniverseService).
// =====================================================================
namespace PracticeManagement.Api.Models;

/// <summary>A Universe master value (Universe Configuration). Group:
/// CATEGORY / SUBCATEGORY / CLASSIFICATION / REG_SIGNIFICANCE / CRITICALITY /
/// STATUS / RELATIONSHIP. Code is fixed once saved.</summary>
public sealed record OrgAssuranceUniverseMasterSaveRequest(
    long    OrganizationId,
    long?   UniverseMasterId,
    string  MasterGroup,
    string  Code,
    string  Name,
    string? Description,
    long?   ParentMasterId,
    int?    RankValue,
    int     DisplayOrder,
    bool    IsActive,
    string? Actor = null);

/// <summary>An Organization Registry record: Kind = LEGAL_ENTITY / UNIT /
/// LOCATION / DEPARTMENT / FUNCTION / PROCESS, Id = the registry record's
/// own id.</summary>
public sealed record OrgAssuranceUniverseRecordRef(
    string Kind,
    long   Id,
    bool?  IsPrimary = null);

/// <summary>INCLUDE (Discovered subjects) / EXCLUDE (reason required) /
/// RELEASE on discovered registry records.</summary>
public sealed record OrgAssuranceUniverseDiscoverRequest(
    long    OrganizationId,
    string  Action,
    IReadOnlyList<OrgAssuranceUniverseRecordRef>? Records,
    string? Reason     = null,
    long?   CategoryId = null,
    string? Actor      = null);

/// <summary>Create (UniverseSubjectId null) or change a subject. Sources
/// replace the registry links when given (null = unchanged). VersionNo is
/// the version read (required to change).</summary>
public sealed record OrgAssuranceUniverseSaveRequest(
    long      OrganizationId,
    long?     UniverseSubjectId,
    int?      VersionNo,
    string    SubjectName,
    string?   Description,
    long?     CategoryId,
    long?     SubcategoryId,
    long?     ClassificationId,
    long?     RegSignificanceId,
    long?     CriticalityId,
    long?     ParentSubjectId,
    string?   SubjectSource,
    long?     OwnerEmployeeId,
    long?     DivisionId,
    long?     DepartmentId,
    DateTime? EffectiveFrom,
    string?   Remarks,
    IReadOnlyList<OrgAssuranceUniverseRecordRef>? Sources,
    string?   Actor = null);

/// <summary>SUBMIT / APPROVE / RETURN / REVIEW / DEACTIVATE / REACTIVATE /
/// RETIRE / DISCARD; Comment is required to RETURN, DEACTIVATE, REACTIVATE,
/// RETIRE and DISCARD.</summary>
public sealed record OrgAssuranceUniverseActionRequest(
    long    OrganizationId,
    string  Action,
    string? Comment   = null,
    int?    VersionNo = null,
    string? Actor     = null);

/// <summary>Add a relationship (UniverseRelationshipId null), or end one
/// (UniverseRelationshipId with IsActive false).</summary>
public sealed record OrgAssuranceUniverseRelationshipSaveRequest(
    long    OrganizationId,
    long?   UniverseRelationshipId,
    long?   FromSubjectId,
    long?   ToSubjectId,
    long?   RelationshipTypeId,
    string? Remarks,
    bool    IsActive = true,
    string? Actor    = null);

/// <summary>580: refresh a subject's suggested mappings.</summary>
public sealed record OrgAssuranceUniverseMappingSuggestRequest(
    long    OrganizationId,
    string? Actor = null);

/// <summary>580: map records of one level by hand (added Confirmed).
/// Level: FRAMEWORK / RELEASE / CONTROL / REQUIREMENT / OBLIGATION /
/// PRACTICE / PRACTICE_INSTANCE / RISK (581: an enterprise risk -- key =
/// risk_register_id); Keys: the records' keys from
/// universe-mapping-options (a requirement's key is its statement id).</summary>
public sealed record OrgAssuranceUniverseMappingAddRequest(
    long    OrganizationId,
    string  Level,
    IReadOnlyList<string>? Keys,
    string? Remarks = null,
    string? Actor   = null);

/// <summary>580: CONFIRM / REJECT / DEACTIVATE / REACTIVATE mappings;
/// Remarks (the reason) is required to REJECT and DEACTIVATE.</summary>
public sealed record OrgAssuranceUniverseMappingActionRequest(
    long    OrganizationId,
    string  Action,
    IReadOnlyList<long>? MappingIds,
    string? Remarks = null,
    string? Actor   = null);

public sealed record OrgAssuranceUniverseResult(
    bool    Success,
    long?   Id         = null,
    string? Error      = null,
    string? ReasonCode = null);
