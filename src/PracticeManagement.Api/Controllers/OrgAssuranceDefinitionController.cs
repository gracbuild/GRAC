// =====================================================================
// OrgAssuranceDefinitionController
//
// Phase 2 Assurance Management -- Stage 1 API surface.
//
// Route: /api/practice/org-assurance/definitions[/{id}][/{action}]
// Sub-routes:
//   GET  /statuses                             Lifecycle status list
//   GET  /definitions?organizationId=&statusCode=&search=&page=&pageSize=
//   POST /definitions                          Create or update a draft
//   GET  /definitions/{id}?organizationId=     Detail
//   GET  /definitions/{id}/history?organizationId=
//   GET  /definitions/{id}/versions?organizationId=
//   POST /definitions/{id}/submit              Draft -> UnderReview
//   POST /definitions/{id}/approve             UnderReview -> Approved
//   POST /definitions/{id}/activate            Approved -> Active
//   POST /definitions/{id}/retire              Active -> Retired
//
// New, INDEPENDENT module. Follows the TaskController / WorkflowController
// style: thin, delegates to IOrgAssuranceDefinitionService, plain JSON
// results, no encrypted envelope (matches the Workflow layer -- envelope
// is reserved for legacy repository/manage endpoints per project rule).
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/org-assurance")]
public sealed class OrgAssuranceDefinitionController(
    IOrgAssuranceDefinitionService service,
    ILogger<OrgAssuranceDefinitionController> logger) : ControllerBase
{
    // ================================================================
    // Statuses (dropdown feed)
    // ================================================================
    [HttpGet("statuses")]
    public async Task<IActionResult> ListStatuses(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListStatusesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListStatuses failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Admin-published Assurance Categories (dropdown feed)
    // ================================================================
    [HttpGet("categories")]
    public async Task<IActionResult> ListAdminCategories(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListAdminCategoriesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListAdminCategories failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // List definitions
    // ================================================================
    [HttpGet("definitions")]
    public async Task<IActionResult> ListDefinitions(
        [FromQuery] long?    organizationId,
        [FromQuery] string?  statusCode,
        [FromQuery] string?  search,
        [FromQuery] int      page      = 1,
        [FromQuery] int      pageSize  = 25,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.ListAsync(
                new OrgAssuranceDefinitionListQuery(organizationId.Value, statusCode, search, page, pageSize),
                cancellationToken);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListDefinitions failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Get single definition
    // ================================================================
    [HttpGet("definitions/{id:long}")]
    public async Task<IActionResult> GetDefinition(
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
                ? NotFound(new { error = "Definition not found." })
                : Ok(new { data = detail });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.GetDefinition failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Save (create + update)
    // ================================================================
    [HttpPost("definitions")]
    public async Task<IActionResult> SaveDefinition(
        [FromBody] OrgAssuranceDefinitionSaveRequest body,
        CancellationToken cancellationToken)
    {
        if (body is null)
            return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.SaveAsync(body, cancellationToken);
        return result.Success
            ? Ok(new { definitionId = result.DefinitionId, definitionVersionId = result.DefinitionVersionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Lifecycle transitions
    // ================================================================
    [HttpPost("definitions/{id:long}/submit")]
    public Task<IActionResult> Submit(long id, [FromBody] OrgAssuranceDefinitionTransitionRequest? body, CancellationToken cancellationToken) =>
        InvokeTransition(id, body, cancellationToken, (svc, req, ct) => svc.SubmitAsync(req, ct));

    [HttpPost("definitions/{id:long}/approve")]
    public Task<IActionResult> Approve(long id, [FromBody] OrgAssuranceDefinitionTransitionRequest? body, CancellationToken cancellationToken) =>
        InvokeTransition(id, body, cancellationToken, (svc, req, ct) => svc.ApproveAsync(req, ct));

    [HttpPost("definitions/{id:long}/activate")]
    public Task<IActionResult> Activate(long id, [FromBody] OrgAssuranceDefinitionTransitionRequest? body, CancellationToken cancellationToken) =>
        InvokeTransition(id, body, cancellationToken, (svc, req, ct) => svc.ActivateAsync(req, ct));

    [HttpPost("definitions/{id:long}/retire")]
    public Task<IActionResult> Retire(long id, [FromBody] OrgAssuranceDefinitionTransitionRequest? body, CancellationToken cancellationToken) =>
        InvokeTransition(id, body, cancellationToken, (svc, req, ct) => svc.RetireAsync(req, ct));

    private async Task<IActionResult> InvokeTransition(
        long routeId,
        OrgAssuranceDefinitionTransitionRequest? body,
        CancellationToken cancellationToken,
        Func<IOrgAssuranceDefinitionService, OrgAssuranceDefinitionTransitionRequest, CancellationToken, Task<OrgAssuranceDefinitionTransitionResult>> op)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        // Prefer the id from the route so a mismatched body cannot escalate.
        var effective = body with { DefinitionId = routeId };
        var result    = await op(service, effective, cancellationToken);
        return result.Success
            ? Ok(new { definitionId = result.DefinitionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // History + Versions
    // ================================================================
    [HttpGet("definitions/{id:long}/history")]
    public async Task<IActionResult> GetHistory(
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
            logger.LogError(ex, "OrgAssuranceDefinitionController.GetHistory failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("definitions/{id:long}/versions")]
    public async Task<IActionResult> GetVersions(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var rows = await service.ListVersionsAsync(organizationId.Value, id, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.GetVersions failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    // ================================================================
    // Scope Builder (Stage 2 -- BRD Part 2 Sec 2)
    // ================================================================
    [HttpGet("scope-dimensions")]
    public async Task<IActionResult> ListScopeDimensions(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListScopeDimensionsAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListScopeDimensions failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("scope-dimensions/{code}/values")]
    public async Task<IActionResult> ListScopeDimensionValues(
        string code,
        [FromQuery] long? organizationId,
        [FromQuery] string? search,
        [FromQuery] int pageSize = 100,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (string.IsNullOrWhiteSpace(code))
            return BadRequest(new { error = "dimension code is required." });

        try
        {
            var rows = await service.ListScopeDimensionValuesAsync(organizationId.Value, code, search, pageSize, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListScopeDimensionValues failed for {Code}", code);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("definitions/{id:long}/scope")]
    public async Task<IActionResult> GetScope(
        long id,
        [FromQuery] long?  organizationId,
        [FromQuery] long?  versionId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var tree = await service.GetScopeAsync(organizationId.Value, id, versionId, cancellationToken);
            return tree is null
                ? NotFound(new { error = "Definition or version not found." })
                : Ok(tree);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.GetScope failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("definitions/{id:long}/scope")]
    public async Task<IActionResult> SaveScope(
        long id,
        [FromBody] OrgAssuranceScopeSaveRequest? body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        // Prefer the route id -- protects against a body/route mismatch.
        var effective = body with { DefinitionId = id };
        var result    = await service.SaveScopeAsync(effective, cancellationToken);
        return result.Success
            ? Ok(new { definitionId = result.DefinitionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Evidence Configuration (Stage 2 -- BRD Part 2 Sec 5)
    // ================================================================
    [HttpGet("evidence-types")]
    public async Task<IActionResult> ListEvidenceTypes(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListEvidenceTypesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListEvidenceTypes failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("collection-methods")]
    public async Task<IActionResult> ListCollectionMethods(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListCollectionMethodsAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListCollectionMethods failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("frequencies")]
    public async Task<IActionResult> ListFrequencies(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListFrequenciesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListFrequencies failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("definitions/{id:long}/evidence-config")]
    public async Task<IActionResult> GetEvidenceConfig(
        long id,
        [FromQuery] long? organizationId,
        [FromQuery] long? versionId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.GetEvidenceConfigAsync(organizationId.Value, id, versionId, cancellationToken);
            return result is null
                ? NotFound(new { error = "Definition or version not found." })
                : Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.GetEvidenceConfig failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("definitions/{id:long}/evidence-config")]
    public async Task<IActionResult> SaveEvidenceConfig(
        long id,
        [FromBody] OrgAssuranceEvidenceConfigSaveRequest? body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var effective = body with { DefinitionId = id };
        var result    = await service.SaveEvidenceConfigAsync(effective, cancellationToken);
        return result.Success
            ? Ok(new { definitionId = result.DefinitionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Workflow Configuration (Stage 2 -- BRD Part 2 Sec 6)
    // ================================================================
    [HttpGet("admin-workflow-templates")]
    public async Task<IActionResult> ListAdminWorkflowTemplates(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListAdminWorkflowTemplatesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListAdminWorkflowTemplates failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("workflow-stage-types")]
    public async Task<IActionResult> ListWorkflowStageTypes(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListWorkflowStageTypesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListWorkflowStageTypes failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("organization-roles")]
    public async Task<IActionResult> ListOrganizationRoles(
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var rows = await service.ListOrganizationRolesAsync(organizationId.Value, cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListOrganizationRoles failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("definitions/{id:long}/workflow-config")]
    public async Task<IActionResult> GetWorkflow(
        long id,
        [FromQuery] long? organizationId,
        [FromQuery] long? versionId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.GetWorkflowAsync(organizationId.Value, id, versionId, cancellationToken);
            return result is null
                ? NotFound(new { error = "Definition or version not found." })
                : Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.GetWorkflow failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("definitions/{id:long}/workflow-config")]
    public async Task<IActionResult> SaveWorkflow(
        long id,
        [FromBody] OrgAssuranceWorkflowSaveRequest? body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var effective = body with { DefinitionId = id };
        var result    = await service.SaveWorkflowAsync(effective, cancellationToken);
        return result.Success
            ? Ok(new { definitionId = result.DefinitionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Scoring Configuration (Stage 2 -- BRD Part 2 Sec 7)
    // ================================================================
    [HttpGet("admin-scoring-models")]
    public async Task<IActionResult> ListAdminScoringModels(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListAdminScoringModelsAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListAdminScoringModels failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("scoring-model-types")]
    public async Task<IActionResult> ListScoringModelTypes(CancellationToken cancellationToken)
    {
        try
        {
            var rows = await service.ListScoringModelTypesAsync(cancellationToken);
            return Ok(new { data = rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListScoringModelTypes failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("definitions/{id:long}/scoring-config")]
    public async Task<IActionResult> GetScoring(
        long id,
        [FromQuery] long? organizationId,
        [FromQuery] long? versionId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.GetScoringAsync(organizationId.Value, id, versionId, cancellationToken);
            return result is null
                ? NotFound(new { error = "Definition or version not found." })
                : Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.GetScoring failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("definitions/{id:long}/scoring-config")]
    public async Task<IActionResult> SaveScoring(
        long id,
        [FromBody] OrgAssuranceScoringSaveRequest? body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var effective = body with { DefinitionId = id };
        var result    = await service.SaveScoringAsync(effective, cancellationToken);
        return result.Success
            ? Ok(new { definitionId = result.DefinitionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Trigger Configuration (Stage 3 -- BRD Part 2 Sec 9)
    // ================================================================
    [HttpGet("trigger-types")]
    public async Task<IActionResult> ListTriggerTypes(CancellationToken cancellationToken)
    {
        try { var rows = await service.ListTriggerTypesAsync(cancellationToken); return Ok(new { data = rows }); }
        catch (Exception ex) { logger.LogError(ex, "ListTriggerTypes failed"); return StatusCode(500, new { error = ex.Message }); }
    }

    [HttpGet("schedule-frequencies")]
    public async Task<IActionResult> ListScheduleFrequencies(CancellationToken cancellationToken)
    {
        try { var rows = await service.ListScheduleFrequenciesAsync(cancellationToken); return Ok(new { data = rows }); }
        catch (Exception ex) { logger.LogError(ex, "ListScheduleFrequencies failed"); return StatusCode(500, new { error = ex.Message }); }
    }

    [HttpGet("event-codes")]
    public async Task<IActionResult> ListEventCodes(CancellationToken cancellationToken)
    {
        try { var rows = await service.ListEventCodesAsync(cancellationToken); return Ok(new { data = rows }); }
        catch (Exception ex) { logger.LogError(ex, "ListEventCodes failed"); return StatusCode(500, new { error = ex.Message }); }
    }

    [HttpGet("continuous-sources")]
    public async Task<IActionResult> ListContinuousSources(CancellationToken cancellationToken)
    {
        try { var rows = await service.ListContinuousSourcesAsync(cancellationToken); return Ok(new { data = rows }); }
        catch (Exception ex) { logger.LogError(ex, "ListContinuousSources failed"); return StatusCode(500, new { error = ex.Message }); }
    }

    [HttpGet("definitions/{id:long}/triggers")]
    public async Task<IActionResult> ListTriggers(
        long id,
        [FromQuery] long? organizationId,
        [FromQuery] long? versionId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.ListTriggersAsync(organizationId.Value, id, versionId, cancellationToken);
            return result is null
                ? NotFound(new { error = "Definition or version not found." })
                : Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListTriggers failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("definitions/{id:long}/triggers")]
    public async Task<IActionResult> SaveTrigger(
        long id,
        [FromBody] OrgAssuranceTriggerSaveRequest? body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var effective = body with { DefinitionId = id };
        var result    = await service.SaveTriggerAsync(effective, cancellationToken);
        return result.Success
            ? Ok(new { triggerId = result.TriggerId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpDelete("triggers/{id:long}")]
    public async Task<IActionResult> DeleteTrigger(
        long id,
        [FromQuery] long?   organizationId,
        [FromQuery] string? actor,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await service.DeleteTriggerAsync(organizationId.Value, id, actor, cancellationToken);
        return result.Success
            ? Ok(new { triggerId = result.TriggerId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    // ================================================================
    // Scope Resolution Engine (Stage 3 -- BRD Part 2 Sec 3)
    // ================================================================
    [HttpPost("definitions/{id:long}/scope-resolve")]
    public async Task<IActionResult> ResolveScope(
        long id,
        [FromBody] OrgAssuranceScopeResolveRequest? body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (body.OrganizationId <= 0) return BadRequest(new { error = "organizationId is required." });

        var effective = body with { DefinitionId = id };
        var result    = await service.ResolveScopeAsync(effective, cancellationToken);
        return result.Success
            ? Ok(new { resolutionId = result.ResolutionId })
            : BadRequest(new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpGet("definitions/{id:long}/scope-resolutions")]
    public async Task<IActionResult> ListScopeResolutions(
        long id,
        [FromQuery] long?  organizationId,
        [FromQuery] long?  versionId,
        [FromQuery] int    page     = 1,
        [FromQuery] int    pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.ListScopeResolutionsAsync(organizationId.Value, id, versionId, page, pageSize, cancellationToken);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListScopeResolutions failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("scope-resolutions/{id:long}")]
    public async Task<IActionResult> GetScopeResolution(
        long id,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.GetScopeResolutionAsync(organizationId.Value, id, cancellationToken);
            return result is null
                ? NotFound(new { error = "Resolution not found." })
                : Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.GetScopeResolution failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("scope-resolutions/{id:long}/entities")]
    public async Task<IActionResult> ListScopeResolutionEntities(
        long id,
        [FromQuery] long?   organizationId,
        [FromQuery] string? dimensionCode,
        [FromQuery] string? search,
        [FromQuery] int     page     = 1,
        [FromQuery] int     pageSize = 50,
        CancellationToken cancellationToken = default)
    {
        if (organizationId is null or <= 0)
            return BadRequest(new { error = "organizationId is required." });

        try
        {
            var result = await service.ListScopeResolutionEntitiesAsync(
                organizationId.Value, id, dimensionCode, search, page, pageSize, cancellationToken);
            return Ok(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "OrgAssuranceDefinitionController.ListScopeResolutionEntities failed for id {Id}", id);
            return StatusCode(500, new { error = ex.Message });
        }
    }
}
