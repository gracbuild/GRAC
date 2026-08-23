// =====================================================================
// PracticeConfigureController
//
// Route: /api/practice/workflow/practice-configure/...
//
// Nested under the workflow route on purpose. The Web tier's
// WorkflowController is a catch-all proxy for /practice/api/workflow/**
// that already enforces a live session and checks organizationId --
// on the querystring for GET, in the body for POST -- against the
// caller's allowed organizations. Hanging these endpoints there gets
// that guard for free and needs no Web-side controller at all.
//
// Sub-routes:
//   GET  /practice-configure/{practiceId}     Practice header for the page
//   GET  /practice-configure/teams            Team multi-select feed
//   POST /practice-configure/instances        Create one instance per team
//
// Obligations are deliberately absent: the page reads them through the
// existing evidence-obligations-typed gateway path (migration 122), which
// already returns the typed shape the View Obligations panel renders.
// A second obligation endpoint would be a second thing to keep correct.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/workflow/practice-configure")]
public sealed class PracticeConfigureController(
    IPracticeConfigureService practiceConfigureService,
    ILogger<PracticeConfigureController> logger) : ControllerBase
{
    [HttpGet("teams")]
    public async Task<IActionResult> ListTeams(
        [FromQuery] long  organizationId,
        [FromQuery] long? practiceId,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await practiceConfigureService.ListTeamOptionsAsync(
            organizationId, practiceId, cancellationToken);

        if (!result.Success)
        {
            logger.LogWarning("Team option list failed for organization {OrganizationId}: {Error}",
                organizationId, result.Error);
            return StatusCode(StatusCodes.Status500InternalServerError, new { error = result.Error });
        }
        return Ok(new { data = result.Teams });
    }

    [HttpPost("instances")]
    public async Task<IActionResult> ConfigureInstances(
        [FromBody] PracticeConfigureRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await practiceConfigureService.ConfigureInstancesAsync(body, cancellationToken);
        if (!result.Success)
            return BadRequest(new { error = result.Error });

        // Counts ride along so the UI does not have to recompute them, and so
        // "3 created, 2 already configured, 1 with no owner" can be said
        // plainly instead of a bare "Saved".
        return Ok(new
        {
            data                    = result.Outcomes,
            createdCount            = result.CreatedCount,
            alreadyConfiguredCount  = result.AlreadyConfiguredCount,
            withoutOwnerCount       = result.WithoutOwnerCount
        });
    }

    /// <summary>
    /// Practice header. Accepts either identifier: the Organization Practices
    /// grid is one row per organization_requirement and does not reliably
    /// carry a practice id, so the page sends whichever it has.
    ///
    /// A literal segment rather than a route parameter, so it cannot shadow
    /// "teams" or "instances" and so the two ids stay symmetrical.
    /// </summary>
    [HttpGet("detail")]
    public async Task<IActionResult> GetPractice(
        [FromQuery] long? practiceId,
        [FromQuery] long? organizationId,
        [FromQuery] long? organizationRequirementId,
        CancellationToken cancellationToken = default)
    {
        var result = await practiceConfigureService.GetPracticeDetailAsync(
            practiceId, organizationId, organizationRequirementId, cancellationToken);

        if (!result.Success)
            return NotFound(new { error = result.Error ?? "Practice not found." });

        return Ok(new { data = result.Practice });
    }
}
