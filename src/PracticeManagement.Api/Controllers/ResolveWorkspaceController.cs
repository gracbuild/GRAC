// =====================================================================
// ResolveWorkspaceController
//
// Route: /api/practice/workflow/resolve/...
//
// Nested under the workflow route so the Web tier's WorkflowController
// catch-all proxy forwards these paths unchanged, with its session guard
// and its organizationId check already applied.
//
// Sub-routes:
//   GET  /resolve/instances                  owner-scoped instance list
//   GET  /resolve/instances/{id}             workspace header
//   GET  /resolve/instances/{id}/obligations subscribed obligations
//   POST /resolve/obligations                adopt / edit / un-adopt
//   GET  /resolve/instances/{id}/dependencies dependency cards
//   POST /resolve/dependencies               resolve one dependency
//
// CALLER IDENTITY
// ---------------
// Who is asking decides which instances come back, so it is read from
// headers the Web proxy stamps from the session -- never from the query
// string or the body. A browser can send these header names, but the
// proxy overwrites them before the request leaves the Web tier, so the
// values that arrive here are the session's.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/workflow/resolve")]
public sealed class ResolveWorkspaceController(
    IResolveWorkspaceService resolveService,
    ILogger<ResolveWorkspaceController> logger) : ControllerBase
{
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";
    private const string CallerAdminHeader    = "X-PM-Caller-Is-Admin";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private bool CallerIsAdmin =>
        Request.Headers[CallerAdminHeader].ToString() is "1" or "true" or "True";

    private string Actor =>
        CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    // ============================================================
    // Instance list
    // ============================================================
    [HttpGet("instances")]
    public async Task<IActionResult> ListInstances(
        [FromQuery] long    organizationId,
        [FromQuery] string? search,
        [FromQuery] int     pageNumber = 1,
        [FromQuery] int     pageSize   = 25,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await resolveService.ListInstancesAsync(new ResolveInstanceQuery(
            OrganizationId:   organizationId,
            CallerEmployeeId: CallerEmployeeId,
            IsAdmin:          CallerIsAdmin,
            Search:           search,
            PageNumber:       pageNumber,
            PageSize:         pageSize), cancellationToken);

        if (!result.Success)
        {
            logger.LogWarning("Resolve instance list failed for organization {OrganizationId}: {Error}",
                organizationId, result.Error);
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
        }

        // isAdmin rides along so the screen can say "showing all instances"
        // versus "showing yours" instead of leaving the user guessing why
        // a colleague's row is or is not there.
        return Ok(new { data = result.Rows, isAdmin = CallerIsAdmin });
    }

    // ============================================================
    // Workspace
    // ============================================================
    [HttpGet("instances/{practiceInstanceId:long}")]
    public async Task<IActionResult> GetInstance(
        long practiceInstanceId,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken = default)
    {
        var result = await resolveService.GetInstanceAsync(
            practiceInstanceId, organizationId, CallerEmployeeId, CallerIsAdmin, cancellationToken);

        // The workspace is reachable by URL, so this endpoint is the gate:
        // the obligation and dependency endpoints below are only ever
        // reached for an instance this one has already opened.
        return result.Success
            ? Ok(new { data = result.Instance })
            : NotFound(new { error = result.Error ?? "Practice instance not found." });
    }

    [HttpGet("instances/{practiceInstanceId:long}/obligations")]
    public async Task<IActionResult> ListObligations(
        long practiceInstanceId,
        [FromQuery] bool includeUnsubscribed = false,
        CancellationToken cancellationToken = default)
    {
        var result = await resolveService.ListObligationsAsync(
            practiceInstanceId, includeUnsubscribed, cancellationToken);

        return result.Success
            ? Ok(new { data = result.Obligations })
            : StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
    }

    [HttpPost("obligations")]
    public async Task<IActionResult> AdoptObligations(
        [FromBody] ResolveObligationAdoptRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.AdoptObligationsAsync(
            body with { Actor = Actor }, cancellationToken);

        if (!result.Success) return BadRequest(new { error = result.Error });

        return Ok(new
        {
            data                  = result.Outcomes,
            adoptedCount          = result.AdoptedCount,
            removedCount          = result.RemovedCount,
            unmappedEvidenceTypes = result.UnmappedEvidenceTypes
        });
    }

    [HttpGet("instances/{practiceInstanceId:long}/dependencies")]
    public async Task<IActionResult> ListDependencies(
        long practiceInstanceId,
        CancellationToken cancellationToken = default)
    {
        var result = await resolveService.ListDependenciesAsync(practiceInstanceId, cancellationToken);

        return result.Success
            ? Ok(new { data = result.Categories, resolutions = result.Resolutions })
            : StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
    }

    /// <summary>
    /// Resolves one or more objects against a dependency category. Adding
    /// does not remove: sending A and B leaves an existing C alone, because
    /// "one more" and "only these" are different intentions and the payload
    /// cannot tell them apart. Removal is the endpoint below.
    /// </summary>
    [HttpPost("dependencies")]
    public async Task<IActionResult> SaveDependency(
        [FromBody] ResolveDependencySaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.SaveDependencyAsync(
            body with { Actor = Actor }, cancellationToken);

        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }

    /// <summary>
    /// Changes what Configure defaulted from the practice's obligations.
    /// The procedure repeats the ownership test, so this cannot be used to
    /// edit another owner's instance.
    /// </summary>
    [HttpPost("frequency")]
    public async Task<IActionResult> SaveFrequency(
        [FromBody] ResolveFrequencySaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.SaveFrequencyAsync(
            body with { Actor = Actor }, CallerEmployeeId, CallerIsAdmin, cancellationToken);

        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }

    // ============================================================
    // Evidence
    // ============================================================
    [HttpGet("instances/{practiceInstanceId:long}/evidence")]
    public async Task<IActionResult> ListEvidence(
        long practiceInstanceId,
        [FromQuery] long? obligationId,
        CancellationToken cancellationToken = default)
    {
        var result = await resolveService.ListEvidenceAsync(practiceInstanceId, obligationId, cancellationToken);

        return result.Success
            ? Ok(new { data = result.Evidence })
            : StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
    }

    [HttpPost("evidence")]
    public async Task<IActionResult> SaveEvidence(
        [FromBody] ResolveEvidenceSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.SaveEvidenceAsync(
            body with { Actor = Actor }, cancellationToken);

        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }

    [HttpPost("dependencies/remove")]
    public async Task<IActionResult> RemoveDependency(
        [FromBody] ResolveDependencyRemoveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await resolveService.RemoveDependencyAsync(
            body with { Actor = Actor }, cancellationToken);

        return result.Success
            ? Ok(new { success = true, message = result.Message })
            : BadRequest(new { error = result.Error });
    }
}
