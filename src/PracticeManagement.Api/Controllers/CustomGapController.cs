// =====================================================================
// CustomGapController (unified Gap Center)
//
// Route: /api/practice/gaps/custom
//
// Existing endpoints (from 055, preserved for the Custom tab):
//   GET  /                         List (with new optional filters)
//   POST /                         Open   (minimal create)
//   POST /{id}/close               Close  (minimal close)
//
// Stage 4b unified endpoints (Assurance-source flow etc.):
//   GET    /{id}                   Get detail
//   POST   /save                   Full unified upsert
//   DELETE /{id}                   Soft-delete (Open only)
//   POST   /generate               Generate from Assurance observation
//   POST   /{id}/start
//   POST   /{id}/submit-remediation
//   POST   /{id}/verify
//   POST   /{id}/close-lifecycle
//   POST   /{id}/reopen
//   GET    /{id}/observations?includeDetached=
//   POST   /{id}/attach-observation
//   POST   /{id}/detach-observation
//   POST   /{id}/merge             (route id = source; body carries target)
//   GET    /{id}/actions
//   POST   /{id}/actions
//   POST   /{id}/actions/{actionId}/complete
//   DELETE /{id}/actions/{actionId}
//   GET    /{id}/history
//   GET    /by-observation/{obsId}/gaps?includeDetached=
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/gaps/custom")]
public sealed class CustomGapController(
    ICustomGapService customGapService,
    ILogger<CustomGapController> logger) : ControllerBase
{
    // -----------------------------------------------------------
    // Legacy
    // -----------------------------------------------------------
    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long?   organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? priority,
        [FromQuery] long?   ownerEmployeeId,
        [FromQuery] string? search,
        [FromQuery] int page       = 1,
        [FromQuery] int pageSize   = 25,
        [FromQuery] string? gapSourceModuleCode = null,
        [FromQuery] string? severityCode        = null,
        [FromQuery] long?   observationId       = null,
        [FromQuery] long?   executionId         = null,
        CancellationToken cancellationToken = default)
    {
        var q = new CustomGapListQuery(
            OrganizationId:      organizationId,
            StatusCode:          statusCode,
            Priority:            priority,
            OwnerEmployeeId:     ownerEmployeeId,
            Search:              search,
            Page:                page,
            PageSize:            pageSize,
            GapSourceModuleCode: gapSourceModuleCode,
            SeverityCode:        severityCode,
            ObservationId:       observationId,
            ExecutionId:         executionId);
        var result = await customGapService.ListAsync(q, cancellationToken);
        return Ok(result);
    }

    [HttpPost]
    public async Task<IActionResult> Open([FromBody] CustomGapOpenRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await customGapService.OpenAsync(body, cancellationToken);
        return result.Success
            ? StatusCode(StatusCodes.Status201Created, new { customGapId = result.CustomGapId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpPost("{id:long}/close")]
    public async Task<IActionResult> Close(long id, [FromBody] CustomGapCloseRequest? body, CancellationToken cancellationToken)
    {
        var request = (body ?? new CustomGapCloseRequest(id, null, null)) with { CustomGapId = id };
        var result  = await customGapService.CloseAsync(request, cancellationToken);
        return result.Success
            ? Ok(new { customGapId = result.CustomGapId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // -----------------------------------------------------------
    // Unified: get / save / delete / generate
    // -----------------------------------------------------------
    [HttpGet("{id:long}")]
    public async Task<IActionResult> Get(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var detail = await customGapService.GetAsync(organizationId.Value, id, cancellationToken);
        return detail is null
            ? NotFound(new { error = "Gap not found." })
            : Ok(new { data = detail });
    }

    [HttpPost("save")]
    public async Task<IActionResult> Save(
        [FromBody] CustomGapSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await customGapService.SaveAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { customGapId = result.CustomGapId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpDelete("{id:long}")]
    public async Task<IActionResult> Delete(
        long id,
        [FromQuery] long?   organizationId,
        [FromQuery] string? actor,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await customGapService.DeleteAsync(
            new CustomGapCommandRequest(organizationId.Value, id, null, actor), cancellationToken);
        return result.Success
            ? Ok(new { customGapId = result.CustomGapId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpPost("generate")]
    public async Task<IActionResult> GenerateFromObservation(
        [FromBody] CustomGapGenerateRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await customGapService.GenerateFromAssuranceObservationAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { customGapId = result.CustomGapId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // -----------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------
    [HttpPost("{id:long}/start")]
    public Task<IActionResult> Start(long id, [FromBody] CustomGapCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.StartAsync(r, c));

    [HttpPost("{id:long}/submit-remediation")]
    public Task<IActionResult> SubmitRemediation(long id, [FromBody] CustomGapCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.SubmitRemediationAsync(r, c));

    [HttpPost("{id:long}/verify")]
    public Task<IActionResult> Verify(long id, [FromBody] CustomGapCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.VerifyAsync(r, c));

    [HttpPost("{id:long}/close-lifecycle")]
    public Task<IActionResult> CloseLifecycle(long id, [FromBody] CustomGapCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.CloseLifecycleAsync(r, c));

    [HttpPost("{id:long}/reopen")]
    public Task<IActionResult> Reopen(long id, [FromBody] CustomGapCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.ReopenAsync(r, c));

    private async Task<IActionResult> Invoke(
        long routeId,
        CustomGapCommandRequest? body,
        CancellationToken cancellationToken,
        Func<ICustomGapService, CustomGapCommandRequest, CancellationToken, Task<CustomGapCommandResult>> op)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var effective = body with { CustomGapId = routeId };
        var result    = await op(customGapService, effective, cancellationToken);
        return result.Success
            ? Ok(new { customGapId = result.CustomGapId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // -----------------------------------------------------------
    // Junction
    // -----------------------------------------------------------
    [HttpGet("{id:long}/observations")]
    public async Task<IActionResult> ListLinkedObservations(
        long id,
        [FromQuery] long? organizationId,
        [FromQuery] bool  includeDetached = false,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        var rows = await customGapService.ListLinkedObservationsAsync(
            organizationId.Value, id, includeDetached, cancellationToken);
        return Ok(new { data = rows });
    }

    [HttpGet("by-observation/{obsId:long}/gaps")]
    public async Task<IActionResult> ListLinkedGapsForObservation(
        long obsId,
        [FromQuery] long? organizationId,
        [FromQuery] bool  includeDetached = false,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        var rows = await customGapService.ListLinkedGapsForObservationAsync(
            organizationId.Value, obsId, includeDetached, cancellationToken);
        return Ok(new { data = rows });
    }

    [HttpPost("{id:long}/attach-observation")]
    public async Task<IActionResult> AttachObservation(
        long id,
        [FromBody] CustomGapAttachRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var effective = body with { CustomGapId = id };
        var result    = await customGapService.AttachObservationAsync(effective, cancellationToken);
        return result.Success
            ? Ok(new { junctionId = result.JunctionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpPost("{id:long}/detach-observation")]
    public async Task<IActionResult> DetachObservation(
        long id,
        [FromBody] CustomGapDetachRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var effective = body with { CustomGapId = id };
        var result    = await customGapService.DetachObservationAsync(effective, cancellationToken);
        return result.Success
            ? Ok(new { customGapId = result.CustomGapId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpPost("{id:long}/merge")]
    public async Task<IActionResult> Merge(
        long id,
        [FromBody] CustomGapMergeRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var effective = body with { SourceCustomGapId = id };
        var result    = await customGapService.MergeGapsAsync(effective, cancellationToken);
        return result.Success
            ? Ok(new { targetCustomGapId = result.TargetCustomGapId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // -----------------------------------------------------------
    // Actions
    // -----------------------------------------------------------
    [HttpGet("{id:long}/actions")]
    public async Task<IActionResult> ListActions(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        var rows = await customGapService.ListActionsAsync(organizationId.Value, id, cancellationToken);
        return Ok(new { data = rows });
    }

    [HttpPost("{id:long}/actions")]
    public async Task<IActionResult> SaveAction(
        long id,
        [FromBody] CustomGapActionSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var effective = body with { CustomGapId = id };
        var result    = await customGapService.SaveActionAsync(effective, cancellationToken);
        return result.Success
            ? Ok(new { actionId = result.ActionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpPost("{id:long}/actions/{actionId:long}/complete")]
    public async Task<IActionResult> CompleteAction(
        long id, long actionId,
        [FromBody] CustomGapCommandRequest? body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await customGapService.CompleteActionAsync(
            body.OrganizationId, id, actionId, body.Notes, body.Actor, cancellationToken);
        return result.Success
            ? Ok(new { actionId = result.CustomGapId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpDelete("{id:long}/actions/{actionId:long}")]
    public async Task<IActionResult> DeleteAction(
        long id, long actionId,
        [FromQuery] long?   organizationId,
        [FromQuery] string? actor,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        var result = await customGapService.DeleteActionAsync(
            organizationId.Value, id, actionId, actor, cancellationToken);
        return result.Success
            ? Ok(new { actionId = result.CustomGapId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // -----------------------------------------------------------
    // History
    // -----------------------------------------------------------
    [HttpGet("{id:long}/history")]
    public async Task<IActionResult> ListHistory(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        var rows = await customGapService.ListHistoryAsync(organizationId.Value, id, cancellationToken);
        return Ok(new { data = rows });
    }

    // -----------------------------------------------------------
    // SLA override (migration 184)
    //   POST /api/practice/custom-gaps/{id}/sla/override
    // Body: SlaOverrideRequestPayload -- customGapId is validated
    // to match the route id, so the URL cannot address a different gap.
    // -----------------------------------------------------------
    [HttpPost("{id:long}/sla/override")]
    public async Task<IActionResult> RequestSlaOverride(
        long id,
        [FromBody] SlaOverrideRequestPayload request,
        CancellationToken cancellationToken)
    {
        if (request is null)
            return BadRequest(new { error = "Request body is required." });
        if (request.CustomGapId != id)
            return BadRequest(new { error = "customGapId in body does not match route." });

        var result = await customGapService.RequestSlaOverrideAsync(request, cancellationToken);
        return result.Success
            ? Ok(new { success = true, exceptionRequestId = result.ExceptionRequestId })
            : BadRequest(new { error = result.Error });
    }
}
