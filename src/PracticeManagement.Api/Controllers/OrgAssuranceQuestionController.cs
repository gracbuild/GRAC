// =====================================================================
// OrgAssuranceQuestionController
//
// Phase 2 Assurance Management -- Stage 2 Question Builder API.
//
// Route: /api/practice/org-assurance
// Sub-routes:
//   GET    /admin-question-types
//   GET    /question-sets?organizationId=&search=&page=&pageSize=
//   POST   /question-sets                  Create / update
//   GET    /question-sets/{id}?organizationId=
//   DELETE /question-sets/{id}?organizationId=&actor=
//   GET    /question-sets/{id}/questions?organizationId=
//   POST   /questions                       Create / update
//   GET    /questions/{id}?organizationId=
//   DELETE /questions/{id}?organizationId=&actor=
//
// Shares the base route with OrgAssuranceDefinitionController.
// ASP.NET Core routes by the specific action template, so the split
// controllers coexist cleanly.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance")]
public sealed class OrgAssuranceQuestionController(
    IOrgAssuranceQuestionService service,
    ILogger<OrgAssuranceQuestionController> logger) : ControllerBase
{
    // ================================================================
    // Admin question types
    // ================================================================
    [HttpGet("admin-question-types")]
    public async Task<IActionResult> ListAdminQuestionTypes(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListAdminQuestionTypesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceQuestionController.ListAdminQuestionTypes failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Question Sets
    // ================================================================
    [HttpGet("question-sets")]
    public async Task<IActionResult> ListSets(
        [FromQuery] long?   organizationId,
        [FromQuery] string? search,
        [FromQuery] int page     = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.ListSetsAsync(
                new OrgAssuranceQuestionSetListQuery(organizationId.Value, search, page, pageSize),
                cancellationToken);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceQuestionController.ListSets failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("question-sets/{id:long}")]
    public async Task<IActionResult> GetSet(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var detail = await service.GetSetAsync(organizationId.Value, id, cancellationToken);
            return detail is null
                ? NotFound(new { error = "Question set not found." })
                : Ok(new { data = detail });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceQuestionController.GetSet failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("question-sets")]
    public async Task<IActionResult> SaveSet(
        [FromBody] OrgAssuranceQuestionSetSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var result = await service.SaveSetAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { questionSetId = result.QuestionSetId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpDelete("question-sets/{id:long}")]
    public async Task<IActionResult> DeleteSet(
        long id,
        [FromQuery] long?   organizationId,
        [FromQuery] string? actor,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.DeleteSetAsync(organizationId.Value, id, actor, cancellationToken);
        return result.Success
            ? Ok(new { questionSetId = result.Id })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Questions
    // ================================================================
    [HttpGet("question-sets/{id:long}/questions")]
    public async Task<IActionResult> ListQuestions(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var rows = await service.ListQuestionsAsync(organizationId.Value, id, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceQuestionController.ListQuestions failed for set {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("questions/{id:long}")]
    public async Task<IActionResult> GetQuestion(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var row = await service.GetQuestionAsync(organizationId.Value, id, cancellationToken);
            return row is null
                ? NotFound(new { error = "Question not found." })
                : Ok(new { data = row });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceQuestionController.GetQuestion failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("questions")]
    public async Task<IActionResult> SaveQuestion(
        [FromBody] OrgAssuranceQuestionSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        if (body.QuestionSetId  <= 0) return BadRequest(new { error = "questionSetId is required." });

        var result = await service.SaveQuestionAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { questionId = result.QuestionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpDelete("questions/{id:long}")]
    public async Task<IActionResult> DeleteQuestion(
        long id,
        [FromQuery] long?   organizationId,
        [FromQuery] string? actor,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.DeleteQuestionAsync(organizationId.Value, id, actor, cancellationToken);
        return result.Success
            ? Ok(new { questionId = result.Id })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }
}
