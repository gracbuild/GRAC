// =====================================================================
// PermissionsController  (charter §12.1.6)
//
// Route: /api/practice/permissions/probe
// Charter §7 API convention: /api/practice/{feature}/{action}
//
// This controller is small on purpose — it is a thin transport layer
// over IPermissionService. New per-feature controllers follow the same
// pattern (see charter §5: do not extend PracticeRepositoryController).
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/permissions")]
public sealed class PermissionsController(
    IPermissionService permissionService,
    ILogger<PermissionsController> logger) : ControllerBase
{
    public sealed record ProbeBody(
        string EntityType,
        long EntityId,
        long? ActorEmployeeId,
        string OriginCode,
        string ActionCode,
        long? OrganizationId);

    /// <summary>
    /// Answers "would this actor be allowed to perform this action against
    /// this entity of that origin?". Used by the UI to enable / grey-out
    /// action buttons. Never mutates.
    /// </summary>
    [HttpPost("probe")]
    public async Task<IActionResult> Probe([FromBody] ProbeBody body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (string.IsNullOrWhiteSpace(body.EntityType))
            return BadRequest(new { error = "EntityType is required." });
        if (string.IsNullOrWhiteSpace(body.ActionCode))
            return BadRequest(new { error = "ActionCode is required." });

        try
        {
            var result = await permissionService.ProbeAsync(
                new PermissionProbeRequest(
                    EntityType:      body.EntityType,
                    EntityId:        body.EntityId,
                    ActorEmployeeId: body.ActorEmployeeId,
                    OriginCode:      string.IsNullOrWhiteSpace(body.OriginCode) ? "GRAC" : body.OriginCode,
                    ActionCode:      body.ActionCode,
                    OrganizationId:  body.OrganizationId),
                cancellationToken);

            if (result is null)
            {
                // Fail closed
                return Ok(new
                {
                    verdict          = "Denied",
                    resolvedRole     = "ANY",
                    resolvedScope    = "ANY",
                    origin           = body.OriginCode ?? "GRAC",
                    action           = body.ActionCode,
                    reason           = "Probe returned no rows; fail closed."
                });
            }

            return Ok(new
            {
                verdict          = result.Verdict,
                resolvedRole     = result.ResolvedRole,
                resolvedScope    = result.ResolvedScope,
                origin           = result.Origin,
                action           = result.Action,
                reason           = result.Reason
            });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Permission probe failed for {EntityType} / {Action}", body.EntityType, body.ActionCode);
            // Fail closed on error — safety over availability for permissions.
            return StatusCode(StatusCodes.Status500InternalServerError, new
            {
                verdict = "Denied",
                reason  = "Probe error; fail closed."
            });
        }
    }
}
