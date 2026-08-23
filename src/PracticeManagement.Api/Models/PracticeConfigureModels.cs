// =====================================================================
// PracticeConfigureModels
//
// Shapes for the full-page Practice view and its Configure panel
// (migration 139). Kept separate from EventScopeModels: these belong to
// the practice lifecycle, not to event-driven assurance, and the two
// evolve independently.
//
// Property names match the procedures' result aliases exactly, so the
// readers stay a straight lookup with no translation table to drift.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------- grac_practice.sp_practice_detail_get ----------
public sealed record PracticeDetail(
    long    PracticeId,
    long    OrganizationId,
    string  OrganizationName,
    string  PracticeCode,
    string  PracticeName,
    string? Description,
    string? OriginType,
    string? PracticeOwner,
    long?   PracticeOwnerId,
    string? ApplicabilityStatus,
    string? ExclusionJustification,
    string  Status,
    long?   OrganizationRequirementId,
    string? RequirementCode,
    string? RequirementName,
    int     ActiveInstanceCount);

public sealed record PracticeDetailResult(
    bool Success, PracticeDetail? Practice, string? Error = null);

// ---------- grac_practice.sp_practice_team_option_list ----------
public sealed record PracticeTeamOption(
    long    TeamId,
    string  TeamName,
    long?   TeamManagerId,
    string? TeamManagerName,
    bool    HasManager,
    string? DepartmentName,
    long?   DepartmentId,
    bool    AlreadyConfigured,
    string? ExistingInstanceCode);

public sealed record PracticeTeamOptionResult(
    bool Success, IReadOnlyList<PracticeTeamOption> Teams, string? Error = null);

// ---------- grac_practice.sp_practice_instance_configure ----------
public sealed record PracticeConfigureRequest(
    long           OrganizationId,
    long           PracticeId,
    IReadOnlyList<long> TeamIds,
    string?        Actor);

/// <summary>
/// One row per requested team. Outcome is Created, AlreadyConfigured or
/// TeamNotFound -- the caller reports each rather than claiming a blanket
/// success, because a partially applied batch is the normal case once a
/// practice has been configured before.
/// </summary>
public sealed record PracticeConfigureOutcome(
    long    TeamId,
    string  TeamName,
    string  Outcome,
    long?   PracticeInstanceId,
    string? InstanceCode,
    string? InstanceName,
    string? OwnerName,
    bool    HasOwner);

public sealed record PracticeConfigureResult(
    bool Success,
    IReadOnlyList<PracticeConfigureOutcome> Outcomes,
    string? Error = null)
{
    public int CreatedCount           => Outcomes.Count(o => o.Outcome == PracticeConfigureOutcomes.Created);
    public int AlreadyConfiguredCount => Outcomes.Count(o => o.Outcome == PracticeConfigureOutcomes.AlreadyConfigured);
    public int WithoutOwnerCount      => Outcomes.Count(o => o.Outcome == PracticeConfigureOutcomes.Created && !o.HasOwner);
}

public static class PracticeConfigureOutcomes
{
    public const string Created           = "Created";
    public const string AlreadyConfigured = "AlreadyConfigured";
    public const string TeamNotFound      = "TeamNotFound";
}
