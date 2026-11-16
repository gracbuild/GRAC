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
//   POST   /question-sets/{id}/questions/grid   520: save the set page's
//                                               whole questions grid
//   551 versions and approval (only a Draft version is changed):
//   GET    /question-sets/{id}/versions?organizationId=   every version, newest first
//   GET    /question-sets/{id}/impact?organizationId=     audit definitions affected
//                                                          by approving this version
//   POST   /question-sets/{id}/new-version     Active -> new Draft copy
//   POST   /question-sets/{id}/submit          Recommend: Draft -> UnderReview (note)
//   POST   /question-sets/{id}/return          UnderReview -> Draft (note = reason)
//   POST   /question-sets/{id}/approve         UnderReview -> Active; definitions
//                                              using older versions move to it
//   DELETE /question-sets/{id}                 a Draft v2+ is discarded; a whole
//                                              set only when no audit uses it
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
    // 551: Question set versions and approval
    // ================================================================
    [HttpGet("question-sets/{id:long}/versions")]
    public async Task<IActionResult> ListVersions(long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var rows = await service.ListVersionsAsync(organizationId.Value, id, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceQuestionController.ListVersions failed for set {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("question-sets/{id:long}/impact")]
    public async Task<IActionResult> GetImpact(long id, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var rows = await service.GetImpactAsync(organizationId.Value, id, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceQuestionController.GetImpact failed for set {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("question-sets/{id:long}/new-version")]
    public async Task<IActionResult> NewVersion(long id, [FromBody] OrgAssuranceQuestionSetActionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var result = await service.NewVersionAsync(id, body, cancellationToken);
        return result.Success
            ? Ok(new { questionSetId = result.Id })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpPost("question-sets/{id:long}/submit")]
    public async Task<IActionResult> Submit(long id, [FromBody] OrgAssuranceQuestionSetActionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var result = await service.SubmitAsync(id, body, cancellationToken);
        return result.Success
            ? Ok(new { questionSetId = id })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpPost("question-sets/{id:long}/return")]
    public async Task<IActionResult> Return(long id, [FromBody] OrgAssuranceQuestionSetActionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var result = await service.ReturnAsync(id, body, cancellationToken);
        return result.Success
            ? Ok(new { questionSetId = id })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpPost("question-sets/{id:long}/approve")]
    public async Task<IActionResult> Approve(long id, [FromBody] OrgAssuranceQuestionSetActionRequest? body, CancellationToken cancellationToken)
    {
        if (body is null || body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var result = await service.ApproveAsync(id, body, cancellationToken);
        return result.Success
            ? Ok(new { questionSetId = id, definitions = result.Definitions })
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

    // 520: the set page's questions grid in one call (all or nothing).
    [HttpPost("question-sets/{id:long}/questions/grid")]
    public async Task<IActionResult> SaveQuestionGrid(
        long id,
        [FromBody] OrgAssuranceQuestionGridSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var result = await service.SaveQuestionGridAsync(id, body, cancellationToken);
        return result.Success
            ? Ok(new { questionSetId = id, savedCount = result.Id })
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
