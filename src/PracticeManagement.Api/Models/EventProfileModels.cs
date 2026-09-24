// =====================================================================
// EventProfileModels (migrations 329-331)
//
// A Profile is a named, organisation-scoped population expressed as
// attribute criteria -- Location, Department, Role today, and whatever
// else is seeded into event_profile_dimension_master tomorrow. Event
// obligations are then mapped to the profile rather than to a single
// role:
//
//     Profile -> Event Type -> Obligation
//
// WHY THE CRITERIA ARE A LIST AND NOT NAMED PROPERTIES
// ----------------------------------------------------
// A record with LocationIds / DepartmentIds / RoleIds properties would
// have to change -- along with the controller signature, the service
// mapping and the screen -- the first time a fifth criterion is scoped.
// The dimension list is data (329), so the transport is a list of
// (dimensionCode, matchAll, values). Adding a criterion is then a seed
// row, not a release.
//
// Scope constants live in EventScopeModels.EventScopeDimensions, which
// gains Profile alongside OrgRole and AssetCategory -- one vocabulary,
// not two.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------------------------------------------------------------------
// Criterion dimensions -- read from event_profile_dimension_master.
// ---------------------------------------------------------------------
public sealed record EventProfileDimensionRow(
    int     DimensionId,
    string  DimensionCode,
    string  DimensionName,
    string  SubjectEntity,
    // "ID"   -- values are ids from a master table
    // "TEXT" -- values are free text (no master exists for this attribute)
    string  ValueKind,
    bool    IsMultiValued,
    /// <summary>False when the attribute has no master to pick from, so the
    /// screen offers the values already in use rather than a lookup.</summary>
    bool    HasValueSource,
    int     DisplayOrder);

public sealed record EventProfileDimensionResult(
    IReadOnlyList<EventProfileDimensionRow> Rows);

public sealed record EventProfileDimensionValueRow(
    long?   Id,
    string? TextValue,
    string? Name);

public sealed record EventProfileDimensionValueResult(
    IReadOnlyList<EventProfileDimensionValueRow> Rows);

// ---------------------------------------------------------------------
// The grid.
// ---------------------------------------------------------------------
public sealed record EventProfileListQuery(
    long    OrganizationId,
    string? SubjectEntity,
    string? Status,
    string? Search,
    int     PageNumber = 1,
    int     PageSize   = 25);

public sealed record EventProfileRow(
    long      ProfileId,
    long      OrganizationId,
    string    ProfileCode,
    string    ProfileName,
    string?   Description,
    string    SubjectEntity,
    string    Status,
    /// <summary>"Location: India, Kerala | Department: IT Operations | Role: All",
    /// built in the procedure so the grid does not have to fetch every
    /// profile's whole criteria tree to render one caption.</summary>
    string?   CriteriaSummary,
    // Two numbers, for migration 130's reason: how many decisions exist,
    // and how many of them actually apply. An undecided obligation is an
    // unknown; an excluded one is a documented judgement.
    int       MappedObligationCount,
    int       ApplicableObligationCount,
    int       CriteriaCount,
    string?   EnteredBy,
    DateTime? EnteredDate,
    string?   UpdatedBy,
    DateTime? UpdatedDate);

public sealed record EventProfileListResult(
    IReadOnlyList<EventProfileRow> Rows,
    int  TotalRows,
    int  Page,
    int  PageSize);

// ---------------------------------------------------------------------
// One profile, with its criteria tree.
// ---------------------------------------------------------------------
public sealed record EventProfileCriteriaValue(
    long?   CriteriaValueId,
    long?   ValueId,
    string? ValueText,
    string? ValueLabel);

public sealed record EventProfileCriteria(
    long?   CriteriaId,
    int     DimensionId,
    string  DimensionCode,
    string? DimensionName,
    string? ValueKind,
    int     DisplayOrder,
    /// <summary>True = this dimension places no constraint. Stored explicitly
    /// so the screen can show "All" as a choice the admin made rather than
    /// a field nobody filled in; the matcher treats it exactly like an
    /// absent criterion.</summary>
    bool    MatchAll,
    IReadOnlyList<EventProfileCriteriaValue> Values);

public sealed record EventProfileDetail(
    long      ProfileId,
    long      OrganizationId,
    string    ProfileCode,
    string    ProfileName,
    string?   Description,
    string    SubjectEntity,
    string    Status,
    string?   EnteredBy,
    DateTime? EnteredDate,
    string?   UpdatedBy,
    DateTime? UpdatedDate,
    IReadOnlyList<EventProfileCriteria> Criteria);

// ---------------------------------------------------------------------
// Save. ProfileId 0 or null creates.
// ---------------------------------------------------------------------
public sealed record EventProfileSaveRequest(
    long?   ProfileId,
    long    OrganizationId,
    string? ProfileCode,
    string  ProfileName,
    string? Description,
    string? SubjectEntity,
    string? Status,
    IReadOnlyList<EventProfileCriteriaSaveItem>? Criteria,
    long?   ActorEmployeeId);

public sealed record EventProfileCriteriaSaveItem(
    string  DimensionCode,
    bool    MatchAll,
    IReadOnlyList<EventProfileCriteriaValueSaveItem>? Values);

public sealed record EventProfileCriteriaValueSaveItem(
    long?   ValueId,
    string? ValueText,
    string? ValueLabel);

public sealed record EventProfileCommandResult(
    bool Success, long? ProfileId, string? ProfileCode, string? Error = null);

// ---------------------------------------------------------------------
// Preview -- who does this profile actually match?
//
// Without this an admin builds a population blind and finds out it was
// empty weeks later, when nobody's onboarding produced a checklist.
// ---------------------------------------------------------------------
public sealed record EventProfileMemberRow(
    long    EmployeeId,
    string? EmployeeCode,
    string? EmployeeName,
    string? Designation);

public sealed record EventProfilePreviewResult(
    int     MatchedCount,
    int     TotalActiveEmployees,
    IReadOnlyList<EventProfileMemberRow> Sample)
{
    /// <summary>A saved profile that matches nobody is configurable but inert;
    /// the screen says so rather than letting it look configured.</summary>
    public bool MatchesNobody => MatchedCount == 0;
}
