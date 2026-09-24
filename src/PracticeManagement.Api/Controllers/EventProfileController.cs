// =====================================================================
// EventProfileController
//
// Route: /api/practice/workflow/scope/profiles/...
//
// Nested under the existing workflow route for the same reason
// EventScopeController is: the Web tier's WorkflowController is a
// catch-all proxy over /practice/api/workflow/**, so every path below
// forwards one-to-one with NO Web-tier change, while the C# type stays a
// separate reviewable file.
//
// (That catch-all is why nothing has to be hand-registered here. The
// Exception Centre proxy enumerates its endpoints by hand and a missing
// [HttpPost] there produced a 405 that looked like a routing bug --
// worth knowing before adding an endpoint to a differently shaped
// proxy.)
//
// Sub-routes:
//   GET    /scope/profiles                    Grid (paged)
//   GET    /scope/profiles/dimensions         Criterion dimensions
//   GET    /scope/profiles/dimension-values   Values for one dimension
//   GET    /scope/profiles/preview            Who a profile matches
//   GET    /scope/profiles/{id}               One profile + criteria
//   POST   /scope/profiles                    Create or update
//   POST   /scope/profiles/{id}/status        Activate / Deactivate
//   POST   /scope/profiles/{id}/delete        Delete (refused once used)
//
// Obligation mapping for a profile is NOT here: it is the existing
// /scope/obligation-mappings with scopeDimension=PROFILE. One screen
// action, one endpoint -- a second write path to the same table is how
// two sources of truth start.
//
// Delete is POST .../delete rather than HTTP DELETE, matching this
// module's existing verb convention and the Web proxy, which forwards
// GET and POST only.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/workflow/scope/profiles")]
public sealed class EventProfileController(
    IEventProfileService eventProfileService,
    ILogger<EventProfileController> logger) : ControllerBase
{
    // ============================================================
    // Criterion dimensions -- what a profile can be scoped on.
    //
    // The screen renders its criteria rows from this, so a dimension
    // seeded into event_profile_dimension_master appears in the UI with
    // no code change. That is the whole extensibility contract.
    // ============================================================
    [HttpGet("dimensions")]
    public async Task<IActionResult> ListDimensions(
        [FromQuery] string? subjectEntity,
        CancellationToken cancellationToken = default)
    {
        if (subjectEntity is not null && !EventSubjectEntities.IsValid(subjectEntity))
            return BadRequest(new { error = "subjectEntity must be EMPLOYEE or ASSET." });

        return Ok(await eventProfileService.ListDimensionsAsync(subjectEntity, cancellationToken));
    }

    [HttpGet("dimension-values")]
    public async Task<IActionResult> ListDimensionValues(
        [FromQuery] long    organizationId,
        [FromQuery] string  dimensionCode,
        [FromQuery] string? search,
        [FromQuery] int     pageSize = 200,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(dimensionCode))
            return BadRequest(new { error = "dimensionCode is required." });

        try
        {
            return Ok(await eventProfileService.ListDimensionValuesAsync(
                organizationId, dimensionCode, search, pageSize, cancellationToken));
        }
        catch (Exception ex)
        {
            // An unknown or inactive dimension THROWs in the procedure.
            // Surfaced as 400 rather than 500: it is a bad request, and a
            // 500 would send someone reading server logs for a typo.
            logger.LogWarning(ex, "ListDimensionValues failed for {DimensionCode}", dimensionCode);
            return BadRequest(new { error = ex.Message });
        }
    }

    // ============================================================
    // Grid
    // ============================================================
    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long    organizationId,
        [FromQuery] string? subjectEntity,
        [FromQuery] string? status,
        [FromQuery] string? search,
        [FromQuery] int     pageNumber = 1,
        [FromQuery] int     pageSize   = 25,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (subjectEntity is not null && !EventSubjectEntities.IsValid(subjectEntity))
            return BadRequest(new { error = "subjectEntity must be EMPLOYEE or ASSET." });

        var q = new EventProfileListQuery(
            organizationId, subjectEntity, status, search, pageNumber, pageSize);
        return Ok(await eventProfileService.ListAsync(q, cancellationToken));
    }

    // ============================================================
    // Preview -- declared BEFORE {profileId:long} so "preview" is never
    // taken for a route value. It cannot be, being non-numeric, but
    // relying on that would make adding a non-numeric sub-route later a
    // silent 404.
    // ============================================================
    [HttpGet("preview")]
    public async Task<IActionResult> Preview(
        [FromQuery] long  organizationId,
        [FromQuery] long? profileId,
        [FromQuery] int   sampleSize = 10,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            return Ok(await eventProfileService.PreviewMembersAsync(
                organizationId, profileId, sampleSize, cancellationToken));
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Preview failed for profile {ProfileId}", profileId);
            return BadRequest(new { error = ex.Message });
        }
    }

    [HttpGet("{profileId:long}")]
    public async Task<IActionResult> Get(
        long profileId,
        [FromQuery] long organizationId,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var detail = await eventProfileService.GetAsync(organizationId, profileId, cancellationToken);
        return detail is null
            ? NotFound(new { error = "Profile not found in this organization." })
            : Ok(detail);
    }

    // ============================================================
    // Write
    // ============================================================
    [HttpPost]
    public async Task<IActionResult> Save(
        [FromBody] EventProfileSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await eventProfileService.SaveAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { profileId = result.ProfileId, profileCode = result.ProfileCode })
            : BadRequest(new { error = result.Error });
    }

    [HttpPost("{profileId:long}/status")]
    public async Task<IActionResult> SetStatus(
        long profileId,
        [FromBody] EventProfileStatusRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await eventProfileService.SetStatusAsync(
            body.OrganizationId, profileId, body.Status, body.ActorEmployeeId, cancellationToken);

        return result.Success
            ? Ok(new { profileId, status = body.Status })
            : BadRequest(new { error = result.Error });
    }

    [HttpPost("{profileId:long}/delete")]
    public async Task<IActionResult> Delete(
        long profileId,
        [FromBody] EventProfileDeleteRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await eventProfileService.DeleteAsync(
            body.OrganizationId, profileId, body.ActorEmployeeId, cancellationToken);

        // The procedure refuses when the profile has decisions or raised
        // instances behind it, and its message says to deactivate instead.
        // Passed through unchanged -- it is the better instruction.
        return result.Success
            ? Ok(new { profileId })
            : BadRequest(new { error = result.Error });
    }
}

public sealed record EventProfileStatusRequest(
    long    OrganizationId,
    string  Status,
    long?   ActorEmployeeId);

public sealed record EventProfileDeleteRequest(
    long    OrganizationId,
    long?   ActorEmployeeId);
