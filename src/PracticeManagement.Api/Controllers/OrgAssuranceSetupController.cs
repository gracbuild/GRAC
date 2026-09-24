// =====================================================================
// OrgAssuranceSetupController
//
// Phase 2 Audit Management API.
//
// Route: /api/practice/org-assurance
// Sub-routes:
//   GET  /definitions/{definitionId}/question-sets?organizationId=&versionId=
//   POST /definitions/{definitionId}/question-sets
//   GET  /definitions/{definitionId}/setup-status?organizationId=&versionId=
//
// Shares the base route with OrgAssuranceDefinitionController and
// OrgAssuranceQuestionController -- ASP.NET Core routes by the specific
// action template, so the split controllers coexist, exactly as the
// Question controller's header notes.
//
// The Web tier needs NO new proxy: OrgAssuranceController (Web) forwards
// /practice/api/org-assurance/{**path} to /api/practice/org-assurance/,
// so these land automatically with the existing session guard and
// cross-organization check.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance")]
public sealed class OrgAssuranceSetupController(
    IOrgAssuranceSetupService service,
    ILogger<OrgAssuranceSetupController> logger) : ControllerBase
{
    // ================================================================
    // Question sets adopted by an audit version
    // ================================================================
    [HttpGet("definitions/{definitionId:long}/question-sets")]
    public async Task<IActionResult> GetQuestionSets(
        long definitionId,
        [FromQuery] long? organizationId,
        [FromQuery] long? versionId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.GetQuestionSetsAsync(
                organizationId.Value, definitionId, versionId, cancellationToken);
            return Ok(new { header = result.Header, adopted = result.Adopted, available = result.Available });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceSetupController.GetQuestionSets failed for {DefinitionId}", definitionId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("definitions/{definitionId:long}/question-sets")]
    public async Task<IActionResult> SaveQuestionSets(
        long definitionId,
        [FromBody] OrgAssuranceDefinitionQuestionSetSaveRequest request,
        CancellationToken cancellationToken)
    {
        if (request is null)
            return BadRequest(new { error = "A request body is required." });
        if (request.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        // The route id wins over the body so a mismatched payload cannot
        // write to a different audit than the one addressed.
        var normalized = request with { DefinitionId = definitionId };

        try
        {
            var result = await service.SaveQuestionSetsAsync(normalized, cancellationToken);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceSetupController.SaveQuestionSets failed for {DefinitionId}", definitionId);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Setup status roll-up -- drives the flow tab chips
    // ================================================================
    [HttpGet("definitions/{definitionId:long}/setup-status")]
    public async Task<IActionResult> GetSetupStatus(
        long definitionId,
        [FromQuery] long? organizationId,
        [FromQuery] long? versionId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.GetSetupStatusAsync(
                organizationId.Value, definitionId, versionId, cancellationToken);
            return Ok(new { header = result.Header, steps = result.Steps });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceSetupController.GetSetupStatus failed for {DefinitionId}", definitionId);
            return StatusCode(500, new { error = ex.Message });
        }
    }
}
