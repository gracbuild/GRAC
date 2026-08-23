// =====================================================================
// OrgAssuranceObservationController
//
// Phase 2 Assurance Management -- Stage 4 Observation API.
//
// Route: /api/practice/org-assurance (shared with other org-assurance
// controllers -- ASP.NET Core routes by specific action template).
//
// Endpoints:
//   GET    /observation-severities
//   GET    /observation-statuses
//   GET    /observation-types
//   GET    /observations?organizationId=&executionId=&entityId=&statusCode=&severityCode=&observationType=&search=&page=&pageSize=
//   GET    /observations/{id}?organizationId=
//   POST   /observations                            Create or update
//   DELETE /observations/{id}?organizationId=&actor=
//   POST   /observations/{id}/submit-review
//   POST   /observations/{id}/accept
//   POST   /observations/{id}/reject
//   POST   /observations/{id}/resolve
//   POST   /observations/{id}/close
//   GET    /observations/{id}/evidence?organizationId=
//   POST   /observation-evidence                    Create or update
//   DELETE /observations/{obsId}/evidence/{evidenceId}?organizationId=&actor=
//   GET    /observations/{id}/history?organizationId=
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance")]
public sealed class OrgAssuranceObservationController(
    IOrgAssuranceObservationService service,
    ILogger<OrgAssuranceObservationController> logger) : ControllerBase
{
    // ================================================================
    // Lookups
    // ================================================================
    [HttpGet("observation-severities")]
    public async Task<IActionResult> ListSeverities(CancellationToken cancellationToken)
    {
        try { return Ok(new { data = await service.ListSeveritiesAsync(cancellationToken) }); }
        catch (Exception ex) { logger.LogError(ex, "ListSeverities failed"); return StatusCode(500, new { error = ex.Message }); }
    }

    [HttpGet("observation-statuses")]
    public async Task<IActionResult> ListStatuses(CancellationToken cancellationToken)
    {
        try { return Ok(new { data = await service.ListStatusesAsync(cancellationToken) }); }
        catch (Exception ex) { logger.LogError(ex, "ListStatuses failed"); return StatusCode(500, new { error = ex.Message }); }
    }

    [HttpGet("observation-types")]
    public async Task<IActionResult> ListTypes(CancellationToken cancellationToken)
    {
        try { return Ok(new { data = await service.ListTypesAsync(cancellationToken) }); }
        catch (Exception ex) { logger.LogError(ex, "ListTypes failed"); return StatusCode(500, new { error = ex.Message }); }
    }

    // ================================================================
    // Observations
    // ================================================================
    [HttpGet("observations")]
    public async Task<IActionResult> List(
        [FromQuery] long?   organizationId,
        [FromQuery] long?   executionId,
        [FromQuery] long?   entityId,
        [FromQuery] string? statusCode,
        [FromQuery] string? severityCode,
        [FromQuery] string? observationType,
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
                new OrgAssuranceObservationListQuery(
                    organizationId.Value, executionId, entityId,
                    statusCode, severityCode, observationType, search,
                    page, pageSize),
                cancellationToken);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceObservationController.List failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("observations/{id:long}")]
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
                ? NotFound(new { error = "Observation not found." })
                : Ok(new { data = detail });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceObservationController.Get failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("observations")]
    public async Task<IActionResult> Save(
        [FromBody] OrgAssuranceObservationSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.SaveAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { observationId = result.ObservationId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpDelete("observations/{id:long}")]
    public async Task<IActionResult> Delete(
        long id,
        [FromQuery] long?   organizationId,
        [FromQuery] string? actor,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.DeleteAsync(
            new OrgAssuranceObservationCommandRequest(organizationId.Value, id, null, actor),
            cancellationToken);
        return result.Success
            ? Ok(new { observationId = result.ObservationId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Lifecycle
    // ================================================================
    [HttpPost("observations/{id:long}/submit-review")]
    public Task<IActionResult> SubmitReview(long id, [FromBody] OrgAssuranceObservationCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.SubmitReviewAsync(r, c));

    [HttpPost("observations/{id:long}/accept")]
    public Task<IActionResult> Accept(long id, [FromBody] OrgAssuranceObservationCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.AcceptAsync(r, c));

    [HttpPost("observations/{id:long}/reject")]
    public Task<IActionResult> Reject(long id, [FromBody] OrgAssuranceObservationCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.RejectAsync(r, c));

    [HttpPost("observations/{id:long}/resolve")]
    public Task<IActionResult> Resolve(long id, [FromBody] OrgAssuranceObservationCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.ResolveAsync(r, c));

    [HttpPost("observations/{id:long}/close")]
    public Task<IActionResult> Close(long id, [FromBody] OrgAssuranceObservationCommandRequest? body, CancellationToken ct) =>
        Invoke(id, body, ct, (svc, r, c) => svc.CloseAsync(r, c));

    private async Task<IActionResult> Invoke(
        long routeId,
        OrgAssuranceObservationCommandRequest? body,
        CancellationToken cancellationToken,
        Func<IOrgAssuranceObservationService, OrgAssuranceObservationCommandRequest, CancellationToken, Task<OrgAssuranceObservationCommandResult>> op)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var effective = body with { ObservationId = routeId };
        var result    = await op(service, effective, cancellationToken);
        return result.Success
            ? Ok(new { observationId = result.ObservationId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Evidence
    // ================================================================
    [HttpGet("observations/{id:long}/evidence")]
    public async Task<IActionResult> ListEvidence(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var rows = await service.ListEvidenceAsync(organizationId.Value, id, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceObservationController.ListEvidence failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("observation-evidence")]
    public async Task<IActionResult> SaveEvidence(
        [FromBody] OrgAssuranceObservationEvidenceSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.SaveEvidenceAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { evidenceId = result.EvidenceId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpDelete("observations/{obsId:long}/evidence/{evidenceId:long}")]
    public async Task<IActionResult> DeleteEvidence(
        long obsId, long evidenceId,
        [FromQuery] long?   organizationId,
        [FromQuery] string? actor,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.DeleteEvidenceAsync(organizationId.Value, obsId, evidenceId, actor, cancellationToken);
        return result.Success
            ? Ok(new { evidenceId = result.ObservationId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // History
    // ================================================================
    [HttpGet("observations/{id:long}/history")]
    public async Task<IActionResult> ListHistory(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var rows = await service.ListHistoryAsync(organizationId.Value, id, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceObservationController.ListHistory failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }
}
