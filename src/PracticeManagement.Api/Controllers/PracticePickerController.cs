// =====================================================================
// PracticePickerController
//
// Cascading lookup API behind the reusable Practice Picker (282).
//
// Route: /api/practice/practice-picker
//   GET /frameworks?organizationId=
//   GET /structures?organizationId=&releaseId=
//   GET /controls?organizationId=&structureNodeId=[&releaseId=]
//   GET /practices?organizationId=&organizationControlId=[&search=][&excludePracticeIds=]
//   GET /resolve?organizationId=&practiceId=
//
// Every level takes the parent's id, so a caller can only ever fetch the
// rows under a selection the user has already made. Nothing here returns
// an unbounded practice list -- that is the point of the component.
//
// Read-only: all five are GETs over SELECT-only procedures.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/practice-picker")]
public sealed class PracticePickerController(
    IPracticePickerService service,
    ILogger<PracticePickerController> logger) : ControllerBase
{
    [HttpGet("frameworks")]
    public async Task<IActionResult> Frameworks(
        [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        try
        {
            return Ok(new { data = await service.ListFrameworksAsync(organizationId.Value, cancellationToken) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "PracticePicker.Frameworks failed for organization {OrganizationId}", organizationId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("structures")]
    public async Task<IActionResult> Structures(
        [FromQuery] long? organizationId, [FromQuery] long? releaseId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (releaseId is null or 0)
            return BadRequest(new { error = "releaseId is required." });
        try
        {
            return Ok(new { data = await service.ListStructuresAsync(organizationId.Value, releaseId.Value, cancellationToken) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "PracticePicker.Structures failed for release {ReleaseId}", releaseId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("controls")]
    public async Task<IActionResult> Controls(
        [FromQuery] long? organizationId, [FromQuery] long? structureNodeId,
        [FromQuery] long? releaseId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (structureNodeId is null or 0)
            return BadRequest(new { error = "structureNodeId is required." });
        try
        {
            return Ok(new { data = await service.ListControlsAsync(
                organizationId.Value, releaseId, structureNodeId.Value, cancellationToken) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "PracticePicker.Controls failed for node {StructureNodeId}", structureNodeId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("practices")]
    public async Task<IActionResult> Practices(
        [FromQuery] long? organizationId, [FromQuery] long? organizationControlId,
        [FromQuery] string? search, [FromQuery] string? excludePracticeIds,
        // 312. The risk whose scope decides what is already taken. The
        // exclusion is done in SQL on organization_id AND this id --
        // omit it and nothing is excluded on that basis, which is every
        // caller outside the Risk Centre.
        [FromQuery] long? riskRegisterId,
        // 312. true returns the practices this risk already has, flagged
        // AlreadyMappedToRisk, so the UI can show them disabled with the
        // reason instead of an empty dropdown.
        [FromQuery] bool includeAlreadyMapped = false,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (organizationControlId is null or 0)
            return BadRequest(new { error = "organizationControlId is required." });
        try
        {
            return Ok(new { data = await service.ListPracticesAsync(
                organizationId.Value, organizationControlId.Value, search, excludePracticeIds,
                riskRegisterId, includeAlreadyMapped, cancellationToken) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "PracticePicker.Practices failed for control {ControlId}", organizationControlId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // Edit mode: walk a stored practice back up to Framework / Structure /
    // Control so the picker can show the path the record was saved with.
    // Returns data: null (200, not 404) when the practice reaches no
    // control -- that is a normal shape for a manually added practice,
    // not a failure the caller should treat as an error.
    [HttpGet("resolve")]
    public async Task<IActionResult> Resolve(
        [FromQuery] long? organizationId, [FromQuery] long? practiceId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (practiceId is null or <= 0)
            return BadRequest(new { error = "practiceId is required." });
        try
        {
            return Ok(new { data = await service.ResolveAsync(organizationId.Value, practiceId.Value, cancellationToken) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "PracticePicker.Resolve failed for practice {PracticeId}", practiceId);
            return StatusCode(500, new { error = ex.Message });
        }
    }
}
