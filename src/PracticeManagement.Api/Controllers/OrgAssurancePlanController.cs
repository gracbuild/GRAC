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
}
