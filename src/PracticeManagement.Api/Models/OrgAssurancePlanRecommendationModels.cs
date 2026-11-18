// =====================================================================
// OrgAssurancePlanRecommendationModels (583, CR2 - AA Part E -- Audit Plan
// Recommendations)
//
// Request bodies of OrgAssurancePlanRecommendationController. Reads come
// back as the procedures' rows (OrgAssurancePlanRecommendationService).
// =====================================================================
namespace PracticeManagement.Api.Models;

/// <summary>The engine settings (Head of Internal Audit): IncludeBandCodes
/// "VERY_HIGH,HIGH,..." (the RBIA band codes to recommend), DueWindowMonths
/// 0-36, the always-include rules, RankingOrder "RESIDUAL_SCORE,PRIORITY,..."
/// (keys RESIDUAL_SCORE, PRIORITY, REG_SIGNIFICANCE, CRITICALITY, LAST_AUDIT,
/// OPEN_FINDINGS, OPEN_GAPS, ABOVE_APPETITE; missing ones are appended).</summary>
public sealed record OrgAssurancePlanRecSettingRequest(
    long    OrganizationId,
    string? IncludeBandCodes,
    int     DueWindowMonths,
    bool    AlwaysOpenHighFindings,
    bool    AlwaysHighRegSignificance,
    bool    AlwaysNeverAudited,
    string? RankingOrder,
    string? Actor = null);

/// <summary>Generate (or refresh) the recommendations of a plan.</summary>
public sealed record OrgAssurancePlanRecGenerateRequest(
    long    OrganizationId,
    long    PlanId,
    string? Actor = null);

/// <summary>Change a Proposed / Deferred recommendation: the audit period
/// (both or neither, inside the plan period), programme, audit definition.</summary>
public sealed record OrgAssurancePlanRecUpdateRequest(
    long      OrganizationId,
    DateTime? SuggestedFrom,
    DateTime? SuggestedTo,
    long?     ProgrammeId,
    long?     DefinitionId,
    string?   Actor = null);

/// <summary>DEFER (reason optional) / REJECT (reason required) / REOPEN.</summary>
public sealed record OrgAssurancePlanRecActionRequest(
    long    OrganizationId,
    string  Action,
    string? Reason = null,
    string? Actor  = null);

/// <summary>Accept: link the engagement the engagement form created.</summary>
public sealed record OrgAssurancePlanRecLinkRequest(
    long    OrganizationId,
    long    PlanItemId,
    string? Comment = null,
    string? Actor   = null);

public sealed record OrgAssurancePlanRecResult(
    bool    Success,
    long?   Id         = null,
    string? Error      = null,
    string? ReasonCode = null);
