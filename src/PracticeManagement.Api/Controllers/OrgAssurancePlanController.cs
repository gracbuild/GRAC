// =====================================================================
// OrgAssurancePlanController
//
// Phase 2 Assurance Management -- Stage 3 Assurance Plans API.
//
// Route: /api/practice/org-assurance (shared with OrgAssuranceDefinition-
// Controller / OrgAssuranceQuestionController -- ASP.NET Core routes by
// specific action template, so all three coexist).
//
// Endpoints:
//   GET    /plan-statuses
//   GET    /plan-types
//   GET    /plans?organizationId=&statusCode=&planType=&search=&page=&pageSize=
//   POST   /plans                            Create or update
//   GET    /plans/{id}?organizationId=
//   DELETE /plans/{id}?organizationId=&actor=
//   POST   /plans/{id}/submit
//   POST   /plans/{id}/approve
//   POST   /plans/{id}/activate
//   POST   /plans/{id}/close
//   GET    /plans/{id}/items?organizationId=
//   POST   /plan-items                       Create or update
//   DELETE /plans/{planId}/items/{itemId}?organizationId=&actor=
//   POST   /plans/{planId}/items/{itemId}/start-execution   (546; 552: one
//          execution per audit of the engagement not yet started)
//   552 -- plan items are ENGAGEMENTS (one or more audit definitions):
//   POST   /plan-items                     + engagementName, definitionIds[] (in order)
//   GET    /plans/{planId}/items/{itemId}/definitions?organizationId=   the audits
//   POST   /engagements/scope-preview      View Scope, live, nothing saved:
//          { organizationId, planItemId? , definitionIds?, locationId? }
//          554: an engagement's Branch (a Location) narrows the scope --
//          practice instances linked to it in Operationalize, assets at it;
//          Start Execution narrows the same way (53942: an audit has
//          nothing at the branch). Branch list: GET
//          scope-dimensions/BRANCH/values?organizationId=
//          body { organizationId, planId, actor } -> { executionId,
//          executionCode, executionName, totalEntityCount }
//   565 -- Annual Audit Plan fields, Audit Programmes (Plan -> Programme
//   -> Engagement, mandatory), Planning Methodology, plan revisions:
//   POST   /plans                 + financialYear, objectives, plannedCoverage,
//          plannedBudget, budgetCurrency, plannedEffortDays, resourcesNote
//   GET    /plans, /plans/{id}    + programmeCount, methodologies, planned vs
//          actual (itemCount / engagementCount, engagementInProgressCount,
//          engagementCompletedCount); the detail also the annual fields
//   GET    /planning-methodologies              { data: [{ id, code, name, description }] }
//   GET    /plans/{id}/programmes?organizationId=   { data: [{ programmeId,
//          programmeCode, programmeName, objective, planningMethodologyId,
//          methodologyName, owner..., displayOrder, isDefault, engagementCount,
//          engagementInProgressCount, engagementCompletedCount }] }
//   POST   /plan-programmes        { organizationId, planId, programmeId?,
//          programmeName, objective, planningMethodologyId, owner..., displayOrder,
//          actor } -> { programmeId }   (plan Draft / Submitted)
//   DELETE /plans/{planId}/programmes/{programmeId}?organizationId=&actor=
//          (no engagement left in it)
//   POST   /plan-items             + programmeId (mandatory; may be left out
//          when the plan has exactly one programme); rows + programmeId /
//          programmeCode / programmeName
//   POST   /plans/{id}/revise      { organizationId, reason, actor } -- an
//          Approved / Active plan back to Draft, version + 1, the old values
//          in the revision history
//   GET    /plans/{id}/revisions?organizationId=   { data: [{ revisionId,
//          fromVersion, toVersion, fromStatusCode, reason, snapshotJson,
//          revisedBy, revisedDt }] }
//   566 -- Audit Engagements as a record (planned or independent):
//   GET    /engagement-initiation-sources       { data: [{ code, name }] }
//   GET    /engagements?organizationId=&status=&origin=&planId=&search=&page=&pageSize=
//          { totalCount, page, pageSize, data: [engagement rows] }
//          status: Draft / Planned / InProgress / Completed / Cancelled
//   GET    /engagements/{id}?organizationId=    { engagement, audits, team }
//   GET    /engagements/{id}/team?organizationId=&includeHistory=
//   POST   /engagements/{id}/team               { organizationId, team: [{ teamRole,
//          employeeId?, name?, organisation? }], teamRemarks, actor }
//   POST   /engagements/{id}/approve            { organizationId, approvalReference, actor } (independent)
//   POST   /engagements/{id}/cancel             { organizationId, reason, actor } (no live execution)
//   DELETE /engagements/{id}?organizationId=&actor=   (independent Draft, no execution)
//   POST   /engagements/{id}/start-execution    { organizationId, planId?, actor }
//   POST   /plan-items   planId optional for engagementOrigin INDEPENDENT; +
//          auditSubject, engagementObjective, scopeSummary, auditee..., team[],
//          teamRemarks, engagementInstructions, initiationSourceCode,
//          initiationReason, approvalReference (lead = assignedAuditor...)
//   546: items are saved / removed only while the plan is Draft or
//   Submitted, for Active audits, inside the plan period; item rows carry
//   definitionStatusCode / Name, executionId / Code / StatusCode / Name
//   and slotStatus (Planned / InProgress / Completed / NotExecuted).
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance")]
public sealed class OrgAssurancePlanController(
    IOrgAssurancePlanService service,
    ILogger<OrgAssurancePlanController> logger) : ControllerBase
{
    // ================================================================
    // Lookups
    // ================================================================
    [HttpGet("plan-statuses")]
    public async Task<IActionResult> ListStatuses(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListStatusesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListStatuses failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("plan-types")]
    public async Task<IActionResult> ListPlanTypes(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListPlanTypesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListPlanTypes failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Plans
    // ================================================================
    [HttpGet("plans")]
    public async Task<IActionResult> List(
        [FromQuery] long?   organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? planType,
        [FromQuery] string? search,
        [FromQuery] int page     = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.ListAsync(
                new OrgAssurancePlanListQuery(organizationId.Value, statusCode, planType, search, page, pageSize),
                cancellationToken);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.List failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("plans/{id:long}")]
    public async Task<IActionResult> Get(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var detail = await service.GetAsync(organizationId.Value, id, cancellationToken);
            return detail is null
                ? NotFound(new { error = "Plan not found." })
                : Ok(new { data = detail });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.Get failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("plans")]
    public async Task<IActionResult> Save(
        [FromBody] OrgAssurancePlanSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var result = await service.SaveAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { planId = result.PlanId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpDelete("plans/{id:long}")]
    public async Task<IActionResult> Delete(
        long id,
        [FromQuery] long?   organizationId,
        [FromQuery] string? actor,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.DeleteAsync(
            new OrgAssurancePlanCommandRequest(organizationId.Value, id, actor), cancellationToken);
        return result.Success
            ? Ok(new { planId = result.PlanId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Lifecycle
    // ================================================================
    [HttpPost("plans/{id:long}/submit")]
    public Task<IActionResult> Submit  (long id, [FromBody] OrgAssurancePlanCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.SubmitAsync(r, c));

    [HttpPost("plans/{id:long}/approve")]
    public Task<IActionResult> Approve (long id, [FromBody] OrgAssurancePlanCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.ApproveAsync(r, c));

    [HttpPost("plans/{id:long}/activate")]
    public Task<IActionResult> Activate(long id, [FromBody] OrgAssurancePlanCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.ActivateAsync(r, c));

    [HttpPost("plans/{id:long}/close")]
    public Task<IActionResult> Close   (long id, [FromBody] OrgAssurancePlanCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.CloseAsync(r, c));

    private async Task<IActionResult> Invoke(
        long routeId,
        OrgAssurancePlanCommandRequest? body,
        CancellationToken cancellationToken,
        Func<IOrgAssurancePlanService, OrgAssurancePlanCommandRequest, CancellationToken, Task<OrgAssurancePlanCommandResult>> op)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var effective = body with { PlanId = routeId };
        var result    = await op(service, effective, cancellationToken);
        return result.Success
            ? Ok(new { planId = result.PlanId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Plan items
    // ================================================================
    [HttpGet("plans/{id:long}/items")]
    public async Task<IActionResult> ListItems(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var rows = await service.ListItemsAsync(organizationId.Value, id, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListItems failed for plan {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("plan-items")]
    public async Task<IActionResult> SaveItem(
        [FromBody] OrgAssurancePlanItemSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var result = await service.SaveItemAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { planItemId = result.PlanItemId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpDelete("plans/{planId:long}/items/{itemId:long}")]
    public async Task<IActionResult> DeleteItem(
        long planId, long itemId,
        [FromQuery] long?   organizationId,
        [FromQuery] string? actor,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.DeleteItemAsync(organizationId.Value, planId, itemId, actor, cancellationToken);
        return result.Success
            ? Ok(new { planItemId = result.PlanId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // 565: Planning Methodology, Programmes, revisions
    // ================================================================
    [HttpGet("planning-methodologies")]
    public async Task<IActionResult> ListPlanningMethodologies(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListPlanningMethodologiesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListPlanningMethodologies failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("plans/{id:long}/programmes")]
    public async Task<IActionResult> ListProgrammes(
        long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var rows = await service.ListProgrammesAsync(organizationId.Value, id, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListProgrammes failed for plan {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("plan-programmes")]
    public async Task<IActionResult> SaveProgramme(
        [FromBody] OrgAssurancePlanProgrammeSaveRequest? body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0 || body.PlanId <= 0)
            return BadRequest(new { error = "organizationId and planId are required." });
        var result = await service.SaveProgrammeAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { programmeId = result.ProgrammeId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpDelete("plans/{planId:long}/programmes/{programmeId:long}")]
    public async Task<IActionResult> DeleteProgramme(
        long planId, long programmeId,
        [FromQuery] long?   organizationId,
        [FromQuery] string? actor,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        var result = await service.DeleteProgrammeAsync(organizationId.Value, planId, programmeId, actor, cancellationToken);
        return result.Success
            ? Ok(new { programmeId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpPost("plans/{id:long}/revise")]
    public async Task<IActionResult> Revise(
        long id, [FromBody] OrgAssurancePlanReviseRequest? body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var result = await service.ReviseAsync(body with { PlanId = id }, cancellationToken);
        return result.Success
            ? Ok(new { planId = result.PlanId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpGet("plans/{id:long}/revisions")]
    public async Task<IActionResult> ListRevisions(
        long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var rows = await service.ListRevisionsAsync(organizationId.Value, id, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListRevisions failed for plan {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // 552: the audits of an engagement.
    [HttpGet("plans/{planId:long}/items/{itemId:long}/definitions")]
    public async Task<IActionResult> ListEngagementDefinitions(
        long planId, long itemId, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var rows = await service.ListEngagementDefinitionsAsync(organizationId.Value, itemId, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListEngagementDefinitions failed for item {Id}", itemId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // 552: View Scope -- live preview of an engagement's scope; nothing saved.
    [HttpPost("engagements/scope-preview")]
    public async Task<IActionResult> PreviewEngagementScope(
        [FromBody] OrgAssuranceEngagementScopeRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if ((body.PlanItemId ?? 0) <= 0 && (body.DefinitionIds is null || body.DefinitionIds.Count == 0))
            return BadRequest(new { error = "Pick at least one audit." });
        try
        {
            var result = await service.PreviewEngagementScopeAsync(body, cancellationToken);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.PreviewEngagementScope failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // 546: Start Execution from a plan slot (origin PLAN).
    [HttpPost("plans/{planId:long}/items/{itemId:long}/start-execution")]
    public async Task<IActionResult> StartItemExecution(
        long planId, long itemId,
        [FromBody] OrgAssurancePlanCommandRequest? body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var result = await service.StartItemExecutionAsync(body.OrganizationId, planId, itemId, body.Actor, cancellationToken);
        return result.Success
            ? Ok(new
              {
                  executionId      = result.ExecutionId,
                  executionCode    = result.ExecutionCode,
                  executionName    = result.ExecutionName,
                  totalEntityCount = result.TotalEntityCount,
                  executions       = result.Executions   // 552: every execution started
              })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // 566: Audit Engagements -- planned (in a plan's programme) and
    // independent (initiation source, reason, approved by authority).
    // ================================================================
    [HttpGet("engagement-initiation-sources")]
    public async Task<IActionResult> ListInitiationSources(CancellationToken cancellationToken)
    {
        try { return Ok(new { data = await service.ListInitiationSourcesAsync(cancellationToken) }); }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListInitiationSources failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("engagements")]
    public async Task<IActionResult> ListEngagements(
        [FromQuery] long?   organizationId,
        [FromQuery] string? status,
        [FromQuery] string? origin,
        [FromQuery] long?   planId,
        [FromQuery] string? search,
        [FromQuery] int     page     = 1,
        [FromQuery] int     pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var result = await service.ListEngagementsAsync(
                new OrgAssuranceEngagementListQuery(organizationId.Value, status, origin, planId, search, page, pageSize),
                cancellationToken);
            return Ok(new { totalCount = result.TotalCount, page = result.Page, pageSize = result.PageSize, data = result.Rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListEngagements failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("engagements/{id:long}")]
    public async Task<IActionResult> GetEngagement(
        long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var detail = await service.GetEngagementAsync(organizationId.Value, id, cancellationToken);
            return detail is null ? NotFound(new { error = "Engagement not found." }) : Ok(detail);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.GetEngagement failed for {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // The team with its trail (removed members, who / when) when includeHistory.
    [HttpGet("engagements/{id:long}/team")]
    public async Task<IActionResult> ListEngagementTeam(
        long id, [FromQuery] long? organizationId, [FromQuery] bool includeHistory, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            var rows = await service.ListEngagementTeamAsync(organizationId.Value, id, includeHistory, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssurancePlanController.ListEngagementTeam failed for {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("engagements/{id:long}/team")]
    public async Task<IActionResult> SaveEngagementTeam(
        long id, [FromBody] OrgAssuranceEngagementTeamSaveRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return CommandResult(await service.SaveEngagementTeamAsync(id, body, cancellationToken));
    }

    [HttpPost("engagements/{id:long}/approve")]
    public async Task<IActionResult> ApproveEngagement(
        long id, [FromBody] OrgAssuranceEngagementCommandRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return CommandResult(await service.ApproveEngagementAsync(id, body, cancellationToken));
    }

    [HttpPost("engagements/{id:long}/cancel")]
    public async Task<IActionResult> CancelEngagement(
        long id, [FromBody] OrgAssuranceEngagementCommandRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return CommandResult(await service.CancelEngagementAsync(id, body, cancellationToken));
    }

    [HttpDelete("engagements/{id:long}")]
    public async Task<IActionResult> DeleteEngagement(
        long id, [FromQuery] long? organizationId, [FromQuery] string? actor, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        return CommandResult(await service.DeleteEngagementAsync(organizationId.Value, id, actor, cancellationToken));
    }

    // Start Execution of any engagement (planned: the plan Approved / Active;
    // independent: approved -- its executions are MANUAL with the engagement).
    [HttpPost("engagements/{id:long}/start-execution")]
    public async Task<IActionResult> StartEngagementExecution(
        long id, [FromBody] OrgAssurancePlanCommandRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var result = await service.StartItemExecutionAsync(body.OrganizationId, body.PlanId, id, body.Actor, cancellationToken);
        return result.Success
            ? Ok(new
              {
                  executionId      = result.ExecutionId,
                  executionCode    = result.ExecutionCode,
                  executionName    = result.ExecutionName,
                  totalEntityCount = result.TotalEntityCount,
                  executions       = result.Executions
              })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    private IActionResult CommandResult(OrgAssurancePlanCommandResult result)
        => result.Success
            ? Ok(new { engagementId = result.PlanId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
}
