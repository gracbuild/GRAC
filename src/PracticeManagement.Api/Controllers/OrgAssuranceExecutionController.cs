// =====================================================================
// OrgAssuranceExecutionController
//
// Phase 2 Assurance Management -- Stage 3 Execution API.
//
// Route: /api/practice/org-assurance (shared with other org-assurance
// controllers -- ASP.NET Core routes by specific action template).
//
// Endpoints:
//   GET    /execution-statuses
//   GET    /executions?organizationId=&definitionId=&statusCode=&originType=&search=&page=&pageSize=
//   GET    /executions/{id}?organizationId=
//   POST   /executions/materialize                Materialize an execution
//   DELETE /executions/{id}?organizationId=&actor=
//   POST   /executions/{id}/start
//   POST   /executions/{id}/submit
//   POST   /executions/{id}/review
//   POST   /executions/{id}/approve
//   POST   /executions/{id}/close
//   POST   /executions/{id}/cancel
//   GET    /executions/{id}/entities?organizationId=&dimensionCode=&statusCode=&search=&page=&pageSize=
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance")]
public sealed class OrgAssuranceExecutionController(
    IOrgAssuranceExecutionService service,
    ILogger<OrgAssuranceExecutionController> logger) : ControllerBase
{
    // ================================================================
    // Lookups
    // ================================================================
    [HttpGet("execution-statuses")]
    public async Task<IActionResult> ListStatuses(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListStatusesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.ListStatuses failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Executions
    // ================================================================
    [HttpGet("executions")]
    public async Task<IActionResult> List(
        [FromQuery] long?   organizationId,
        [FromQuery] long?   definitionId,
        [FromQuery] string? statusCode,
        [FromQuery] string? originType,
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
                new OrgAssuranceExecutionListQuery(
                    organizationId.Value, definitionId,
                    statusCode, originType, search, page, pageSize),
                cancellationToken);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.List failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("executions/{id:long}")]
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
                ? NotFound(new { error = "Execution not found." })
                : Ok(new { data = detail });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.Get failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("executions/materialize")]
    public async Task<IActionResult> Materialize(
        [FromBody] OrgAssuranceExecutionMaterializeRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.MaterializeAsync(body, cancellationToken);
        return result.Success
            ? Ok(new
              {
                  executionId      = result.ExecutionId,
                  executionCode    = result.ExecutionCode,
                  executionName    = result.ExecutionName,
                  totalEntityCount = result.TotalEntityCount
              })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpDelete("executions/{id:long}")]
    public async Task<IActionResult> Delete(
        long id,
        [FromQuery] long?   organizationId,
        [FromQuery] string? actor,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.DeleteAsync(
            new OrgAssuranceExecutionCommandRequest(organizationId.Value, id, actor),
            cancellationToken);
        return result.Success
            ? Ok(new { executionId = result.ExecutionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Lifecycle
    // ================================================================
    [HttpPost("executions/{id:long}/start")]
    public Task<IActionResult> Start   (long id, [FromBody] OrgAssuranceExecutionCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.StartAsync(r, c));

    [HttpPost("executions/{id:long}/submit")]
    public Task<IActionResult> Submit  (long id, [FromBody] OrgAssuranceExecutionCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.SubmitAsync(r, c));

    [HttpPost("executions/{id:long}/review")]
    public Task<IActionResult> Review  (long id, [FromBody] OrgAssuranceExecutionCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.ReviewAsync(r, c));

    [HttpPost("executions/{id:long}/approve")]
    public Task<IActionResult> Approve (long id, [FromBody] OrgAssuranceExecutionCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.ApproveAsync(r, c));

    [HttpPost("executions/{id:long}/close")]
    public Task<IActionResult> Close   (long id, [FromBody] OrgAssuranceExecutionCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.CloseAsync(r, c));

    [HttpPost("executions/{id:long}/cancel")]
    public Task<IActionResult> Cancel  (long id, [FromBody] OrgAssuranceExecutionCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.CancelAsync(r, c));

    private async Task<IActionResult> Invoke(
        long routeId,
        OrgAssuranceExecutionCommandRequest? body,
        CancellationToken cancellationToken,
        Func<IOrgAssuranceExecutionService, OrgAssuranceExecutionCommandRequest, CancellationToken, Task<OrgAssuranceExecutionCommandResult>> op)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var effective = body with { ExecutionId = routeId };
        var result    = await op(service, effective, cancellationToken);
        return result.Success
            ? Ok(new { executionId = result.ExecutionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Entities
    // ================================================================
    [HttpGet("executions/{id:long}/entities")]
    public async Task<IActionResult> ListEntities(
        long id,
        [FromQuery] long?   organizationId,
        [FromQuery] string? dimensionCode,
        [FromQuery] string? statusCode,
        [FromQuery] string? search,
        [FromQuery] int page     = 1,
        [FromQuery] int pageSize = 100,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.ListEntitiesAsync(
                organizationId.Value, id,
                dimensionCode, statusCode, search,
                page, pageSize, cancellationToken);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceExecutionController.ListEntities failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // 120 -- per-entity Auditor assignment (role+employee hybrid)
    // ================================================================
    [HttpPost("executions/{id:long}/entities/{entityId:long}/auditor")]
    public async Task<IActionResult> AssignEntityAuditor(
        long id, long entityId,
        [FromBody] OrgAssuranceExecutionAuditorAssignRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null)
            return BadRequest(new { error = "Request body is required." });

        // Honor the route ids over any body-supplied values (defense in depth).
        var effective = body with { ExecutionId = id, ExecutionEntityId = entityId };

        var result = await service.AssignEntityAuditorAsync(effective, cancellationToken);
        return result.Success
            ? Ok(result)
            : BadRequest(new
              {
                  error      = result.Error,
                  reasonCode = result.ReasonCode
              });
    }
}
