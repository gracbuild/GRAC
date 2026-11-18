// =====================================================================
// OrgAssurancePlanRecommendationController (583, CR2 - AA Part E -- Audit
// Plan Recommendations)
//
// Approved RBIA results and each Audit Universe subject's assurance
// intelligence recommend engagements for an Annual Audit Plan; the Head of
// Internal Audit decides each one. Route: /api/practice/org-assurance (the
// Web's generic org-assurance proxy). The caller is the session employee
// the Web tier stamps (X-PM-Caller-Employee-Id, 555).
//
// Endpoints (rows are the procedures' columns):
//   GET  /plan-recommendation-settings?organizationId=   { settings: {
//        IncludeBandCodes, DueWindowMonths, AlwaysOpenHighFindings,
//        AlwaysHighRegSignificance, AlwaysNeverAudited, RankingOrder,
//        ChangedBy, ChangedDt, CanEdit }, bands: [{ BandCode, BandName,
//        MinScore, MaxScore, AuditPriority, FrequencyMonths }] (published RBIA) }
//   POST /plan-recommendation-settings  { organizationId, includeBandCodes,
//        dueWindowMonths, alwaysOpenHighFindings, alwaysHighRegSignificance,
//        alwaysNeverAudited, rankingOrder }
//   POST /plan-recommendations/generate  { organizationId, planId } -> { generatedCount }
//   GET  /plan-recommendations?organizationId=&planId=&kind=&status=&search=
//        { data: [{ PlanRecommendationId, RankNo, RecKind (RECOMMENDED /
//        OPTIONAL / NOT_ASSESSED), Reasons, UniverseSubjectId, UniverseRef,
//        SubjectName, RbiaRef, ResidualScore, BandCode, BandName,
//        AuditPriority, FrequencyMonths, RegSignificanceName, CriticalityName,
//        LastAuditDt, LastEngagementCode, LastResult, DueBy, NeverAudited,
//        LinkedRisks, AboveAppetite, OpenTreatmentActions, OpenGaps, Findings,
//        OpenFindings, OpenHighFindings, RelevantDefinitionId / Name,
//        Status (PROPOSED / ACCEPTED / DEFERRED / REJECTED), SuggestedFrom,
//        SuggestedTo, ProgrammeId / Code / Name, DefinitionId / Code / Name,
//        EngagementId, EngagementCode, EngagementStatus, EngagementRemoved,
//        DecisionReason, DecidedBy, DecidedDt, CanDecide }],
//        summary: { PlanStatus, PlanOpen, IsHeadOfInternalAudit,
//        LastGeneratedDt, Recommended, Optional, NotAssessed, Proposed,
//        Accepted, Deferred, Rejected } }
//   POST /plan-recommendations/{id}/update  { organizationId, suggestedFrom,
//        suggestedTo, programmeId, definitionId }
//   POST /plan-recommendations/{id}/action  { organizationId, action: DEFER /
//        REJECT / REOPEN, reason }
//   POST /plan-recommendations/{id}/link  { organizationId, planItemId, comment }
//        (Accept: the engagement was created by POST plan-items)
//   GET  /plan-recommendations/history?organizationId=&planId=&recommendationId=
// Errors: { error, reasonCode } -- PLAN_REC_* (MapReason), PLAN_REC_EMPLOYEE_REQUIRED.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance")]
public sealed class OrgAssurancePlanRecommendationController(
    IOrgAssurancePlanRecommendationService service,
    ILogger<OrgAssurancePlanRecommendationController> logger) : ControllerBase
{
    // 555: the signed-in employee, stamped by the Web tier (CallerIdentityHandler).
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private string CallerActor(string? actor) =>
        !string.IsNullOrWhiteSpace(actor) ? actor : CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    private static BadRequestObjectResult NoOrganization() => new(new { error = "organizationId is required." });
    private static BadRequestObjectResult NoEmployee() =>
        new(new { error = "Sign in as a person of the organization.", reasonCode = "PLAN_REC_EMPLOYEE_REQUIRED" });

    private IActionResult Result(OrgAssurancePlanRecResult result, string idName)
        => result.Success
            ? Ok(new Dictionary<string, object?> { [idName] = result.Id })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });

    private async Task<IActionResult> Read(Func<Task<object?>> read, string what)
    {
        try { return Ok(await read()); }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanRecommendationController {What} failed", what);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("plan-recommendation-settings")]
    public async Task<IActionResult> GetSettings([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        return await Read(async () => (object?)await service.GetSettingsAsync(organizationId.Value, CallerEmployeeId, cancellationToken), "GetSettings");
    }

    [HttpPost("plan-recommendation-settings")]
    public async Task<IActionResult> SaveSettings([FromBody] OrgAssurancePlanRecSettingRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.SaveSettingsAsync(body, emp, CallerActor(body.Actor), cancellationToken), "organizationId");
    }

    [HttpPost("plan-recommendations/generate")]
    public async Task<IActionResult> Generate([FromBody] OrgAssurancePlanRecGenerateRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (body.PlanId <= 0) return BadRequest(new { error = "Choose the plan." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.GenerateAsync(body, emp, CallerActor(body.Actor), cancellationToken), "generatedCount");
    }

    [HttpGet("plan-recommendations")]
    public async Task<IActionResult> List(
        [FromQuery] long? organizationId, [FromQuery] long? planId, [FromQuery] string? kind, [FromQuery] string? status,
        [FromQuery] string? search, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        if (planId is null or <= 0) return BadRequest(new { error = "planId is required." });
        return await Read(async () => (object?)await service.ListAsync(organizationId.Value, planId.Value, kind, status, search, CallerEmployeeId, cancellationToken), "List");
    }

    [HttpPost("plan-recommendations/{id:long}/update")]
    public async Task<IActionResult> Update(long id, [FromBody] OrgAssurancePlanRecUpdateRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.UpdateAsync(id, body, emp, CallerActor(body.Actor), cancellationToken), "planRecommendationId");
    }

    [HttpPost("plan-recommendations/{id:long}/action")]
    public async Task<IActionResult> RecommendationAction(long id, [FromBody] OrgAssurancePlanRecActionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (string.IsNullOrWhiteSpace(body.Action)) return BadRequest(new { error = "action is required." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.ActionAsync(id, body, emp, CallerActor(body.Actor), cancellationToken), "planRecommendationId");
    }

    [HttpPost("plan-recommendations/{id:long}/link")]
    public async Task<IActionResult> Link(long id, [FromBody] OrgAssurancePlanRecLinkRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return NoOrganization();
        if (body.PlanItemId <= 0) return BadRequest(new { error = "planItemId is required." });
        if (CallerEmployeeId is not { } emp) return NoEmployee();
        return Result(await service.LinkAsync(id, body, emp, CallerActor(body.Actor), cancellationToken), "planRecommendationId");
    }

    [HttpGet("plan-recommendations/history")]
    public async Task<IActionResult> History(
        [FromQuery] long? organizationId, [FromQuery] long? planId, [FromQuery] long? recommendationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return NoOrganization();
        if (planId is null or <= 0) return BadRequest(new { error = "planId is required." });
        return await Read(async () => (object?)new { data = await service.HistoryAsync(organizationId.Value, planId.Value, recommendationId, cancellationToken) }, "History");
    }
}
