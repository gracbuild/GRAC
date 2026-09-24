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
    int     ActiveInstanceCount,
    // Migration 301. A JSON array of { ReleaseId, FrameworkRelease } for the
    // framework releases this practice is mapped to, straight from the
    // procedure -- kept as the raw JSON string rather than a parsed list
    // because the Practice View already carries a jsonArray() parser for the
    // obligations procedure's detail columns and this is the same shape.
    //
    // Nullable, and null is not the same as "[]": null means the database is
    // still on the pre-301 procedure and the column was not returned at all,
    // where "[]" means it answered and nothing is mapped. Both render as no
    // Frameworks row, so the page does not have to tell them apart.
    string? MappedFrameworksJson = null,
    // Migration 303. The practice's implementation roll-up over its instances,
    // derived by sp_practice_detail_get with the same rule and the same four
    // labels the Organization Practices list uses. Named to match that list's
    // column, and for the same reason it is named that there: ImplementationStatus
    // is the value STORED on the requirement, and the two must not be confused.
    //
    // Null when the database is still on the pre-303 procedure; the Practice
    // View then omits the row rather than showing a wrong status.
    string? PracticeImplementationStatus = null,
    // Migration 316. A JSON array of { FrameworkStatementId, StatementReference,
    // StatementTitle, SourceStatement } for the Source Statement(s) this
    // practice is mapped to -- the same organization_statement_practice_mapping
    // rows MappedFrameworksJson reads, joined to GRAC_New.framework_statement
    // instead of GRAC_New.release. Same raw-JSON-string treatment as
    // MappedFrameworksJson, for the same reason.
    //
    // Null means the database is still on a pre-316 procedure and the column
    // was not returned; "[]" means it answered and nothing is mapped (for
    // instance, a practice reached through a Control rather than a
    // Statement). Both render as no Source Statement row.
    string? MappedSourceStatementsJson = null);

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
