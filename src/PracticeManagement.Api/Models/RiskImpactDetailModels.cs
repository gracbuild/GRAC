// =====================================================================
// DEAD CODE. NOT WIRED UP. DO NOT BUILD ON THIS FILE.
//
// The narrative Impact Details feature these models served was
// withdrawn. "Impact Details" on the risk pages is now the
// by-Operationalize-category table of impacted assets, vendors and
// people -- the section riskMapping already renders, over
// risk_dependency_map, which this file never touched. See
// docs/risk-obligation-structure.md.
//
// Nothing references these types: the routes are gone from
// RiskCentreController, IRiskImpactDetailService is no longer
// registered in RiskCentreServiceRegistration, and migration 309's
// tables are meant to be rolled back. The file is kept only so the
// removal is one reviewable commit; delete it, RiskImpactDetailService,
// Views/Practice/Partials/_impact-detail-dialog.cshtml and
// wwwroot/js/Shared/impact-detail-form.js together.
// =====================================================================
// RiskImpactDetailModels
//
// Impact Details, and the attribution of a mapped dependency to an
// obligation -- migration 309. The reasoning is in
// docs/risk-obligation-structure.md; the parts that matter here:
//
//   * A risk has no obligation LIST. The obligations shown on the risk
//     pages are DERIVED from the practices in risk_practice_map, so
//     nothing in this file stores or returns an obligation collection --
//     ObligationId is only ever the one an impact or an attribution
//     points at.
//   * ObligationId is a SOFT reference and can be either side of the
//     product: a published obligation (GRAC_New) or an
//     organisation-defined one (practice_instance_obligation /
//     practice_obligation). ObligationOriginCode says which, because one
//     id column cannot reference both.
//   * Severity is risk_impact_master -- the same 1-10 levels the
//     inherent and residual scores use. Frozen onto the row as
//     Code/Name/Value the way migration 205 freezes likelihood_name, so
//     a later edit to the master cannot rewrite what was recorded.
// =====================================================================
namespace PracticeManagement.Api.Models;

// ---------- the risk's obligations, DERIVED ----------
/// <summary>
/// One row per (mapped practice, obligation). There is no risk-obligation
/// table and this does not create one: decision 1 in
/// docs/risk-obligation-structure.md is that the obligations shown on the
/// risk pages are the obligations of the practices in `risk_practice_map`.
///
/// The practice is carried alongside because two practices in one risk's
/// scope can publish the same obligation, and the panel groups
/// practice → obligation. Collapsing them would make one obligation look
/// like it belonged to neither.
/// </summary>
public sealed record RiskObligationRow(
    long    PracticeId,
    string? PracticeName,
    string? PracticeCode,
    /// <summary>Primary (the practice the risk arrived with) or Additional
    /// (mapped during Risk Analysis) — frozen on risk_practice_map.</summary>
    string? MapSourceCode,
    long    ObligationId,
    string? ObligationName,
    string? ObligationText,
    string? TypeCode,
    string? TypeName,
    string? FrameworkRelease);

public sealed record RiskObligationListResult(
    bool Success,
    long RiskRegisterId,
    IReadOnlyList<RiskObligationRow> Obligations,
    string? Error = null);

// ---------- grac_practice.sp_risk_impact_area_list ----------
public sealed record RiskImpactAreaRow(
    long    RiskImpactAreaId,
    string? AreaCode,
    string? AreaName,
    int     DisplayOrder);

// ---------- grac_practice.sp_risk_impact_detail_list ----------
public sealed record RiskImpactDetailRow(
    long    RiskImpactDetailId,
    long    RiskRegisterId,
    /// <summary>Null means the impact was recorded against the risk as a
    /// whole rather than one obligation. The pages group those under
    /// "not attributed to an obligation".</summary>
    long?   ObligationId,
    string? ObligationName,
    string? ObligationOriginCode,
    long    RiskImpactAreaId,
    string? AreaCode,
    string? AreaName,
    string? ImpactDescription,
    /// <summary>Severity, from risk_impact_master. Null while the impact
    /// has been recorded but not yet sized — a real state, so the
    /// procedure does not force a level.</summary>
    string? ImpactCode,
    string? ImpactName,
    int?    ImpactValue,
    string? AffectedParty,
    /// <summary>Free text on purpose: "2 days downtime", "~200 records".
    /// A typed currency column would be wrong for most impact areas.</summary>
    string? EstimatedValue,
    string? TimeHorizonCode,
    string? Remarks,
    /// <summary>Analysis | Residual | Review — which stage first recorded
    /// it. Never rewritten by an edit, so an Analysis impact corrected
    /// during Review still reads as Analysis.</summary>
    string? AddedStageCode,
    long?   AddedByEmployeeId,
    string? AddedByName,
    DateTime? AddedDt,
    string? Status);

public sealed record RiskImpactDetailListResult(
    bool Success,
    long RiskRegisterId,
    IReadOnlyList<RiskImpactDetailRow> Impacts,
    string? Error = null);

// ---------- grac_practice.sp_risk_impact_detail_save ----------
/// <summary>
/// RiskImpactDetailId = 0 adds; anything else edits that row, and only
/// if it belongs to this risk. ImpactDescription and RiskImpactAreaId are
/// the only required fields.
/// </summary>
public sealed record RiskImpactDetailSaveRequest(
    long    RiskImpactDetailId,
    long?   ObligationId,
    string? ObligationName,
    string? ObligationOriginCode,
    long    RiskImpactAreaId,
    string? ImpactDescription,
    string? ImpactCode,
    string? AffectedParty,
    string? EstimatedValue,
    string? TimeHorizonCode,
    string? Remarks,
    string? AddedStageCode,
    long?   ActorEmployeeId,
    string? CallerDisplayName);

public sealed record RiskImpactDetailSaveResult(
    bool    Success,
    long    RiskRegisterId,
    long?   RiskImpactDetailId,
    bool    Created,
    string? Message = null,
    string? Error = null);

// ---------- grac_practice.sp_risk_dependency_obligation_list / _set ----------
public sealed record RiskDependencyObligationRow(
    long    RiskDependencyObligationId,
    long    RiskDependencyMapId,
    long    ObligationId,
    string? ObligationName,
    string? ObligationOriginCode,
    int     DependencyTypeId,
    string? DependencyTypeName,
    long    DependencyObjectId,
    string? DependencyObjectName,
    DateTime? AttributedDt,
    string? AttributedByName);

public sealed record RiskDependencyObligationListResult(
    bool Success,
    long RiskRegisterId,
    IReadOnlyList<RiskDependencyObligationRow> Attributions,
    string? Error = null);

/// <summary>
/// Attach = false removes the attribution. It never removes the
/// dependency: that lives in risk_dependency_map, which 309 does not
/// touch, so un-attributing can only ever change which obligation a
/// dependency is filed under.
/// </summary>
public sealed record RiskDependencyObligationSetRequest(
    long    RiskDependencyMapId,
    long    ObligationId,
    string? ObligationName,
    string? ObligationOriginCode,
    bool    Attach,
    string? Remarks,
    long?   ActorEmployeeId,
    string? CallerDisplayName);

public sealed record RiskDependencyObligationSetResult(
    bool    Success,
    long    RiskRegisterId,
    long    RiskDependencyMapId,
    long    ObligationId,
    bool    Attached,
    /// <summary>False when the attribution was already in the state the
    /// caller asked for — a no-op, not a failure.</summary>
    bool    Changed,
    string? Error = null);
