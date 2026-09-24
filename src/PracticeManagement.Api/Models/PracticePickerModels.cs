// =====================================================================
// PracticePickerModels
//
// Contracts for the cascading Practice Picker (migration 282).
//
// One row type per level. They are deliberately flat and name-carrying:
// the picker renders a <select> per level and needs a label without a
// second lookup.
//
// PracticeId is grac_practice.practice.practice_id -- the id existing
// consumers already post (the Risk Centre sends { practiceId } to
// /register/{riskId}/practices), so the picker is a drop-in for them.
// =====================================================================
namespace PracticeManagement.Api.Models;

/// <summary>Level 1 -- a framework release the organisation subscribes to.</summary>
public sealed record PracticePickerFramework(
    long    SubscriptionId,
    long?   ReleaseId,
    long?   ArtifactId,
    string? AuthorityName,
    string? ArtifactName,
    string? ReleaseVersion,
    string? FrameworkName);

/// <summary>Level 2 -- a source structure node inside one release.</summary>
public sealed record PracticePickerStructure(
    long    StructureNodeId,
    long?   ParentNodeId,
    int?    NodeLevel,
    string? NodeReference,
    string? NodeTitle,
    string? StructureName,
    int     ControlCount);

/// <summary>Level 3 -- an organisation control under one structure node.</summary>
public sealed record PracticePickerControl(
    long    OrganizationControlId,
    string? ControlCode,
    string? ControlName,
    string? ApplicabilityStatus,
    int     PracticeCount);

/// <summary>Level 4 -- a practice under one control.</summary>
public sealed record PracticePickerPractice(
    long    PracticeId,
    string? PracticeCode,
    string? PracticeName,
    string? ApplicabilityStatus,
    long?   OrganizationRequirementId,
    long?   OrganizationControlId,
    string? ControlCode,
    // 312. Whether THIS risk already has this practice, decided in SQL
    // on organization_id AND risk_register_id. False whenever no risk
    // was named, which is every non-Risk-Centre caller.
    bool    AlreadyMappedToRisk = false,
    // 'Primary' when the row was derived from the risk's own
    // linked_practice_id by sp_risk_mapping_sync_primary, 'Additional'
    // when a person mapped it. The difference is the whole explanation
    // for "I never mapped that practice to this risk".
    string? MapSourceCode = null);

/// <summary>
/// Edit mode -- the full path back up from a practice, so a form opened
/// on an existing record can show Framework / Structure / Control / Practice
/// without the user re-walking the tree. Null when the practice is not
/// reachable through any control (a manually added practice, say).
/// </summary>
public sealed record PracticePickerPath(
    long    PracticeId,
    string? PracticeCode,
    string? PracticeName,
    long?   OrganizationControlId,
    string? ControlCode,
    string? ControlName,
    long?   StructureNodeId,
    string? NodeTitle,
    string? StructureName,
    long?   ReleaseId,
    string? FrameworkName);
