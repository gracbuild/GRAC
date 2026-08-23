// =====================================================================
// WorkflowController
//
// Route: /api/practice/workflow/...
// Delegates to IWorkflowService for the Workflow & Event-Driven
// Assurance Engine (BRD v1.0).
//
// Sub-routes:
//   /workflows                      Workflow definitions (Sec 6)
//   /workflows/{id}/stages          Workflow stages     (Sec 7)
//   /entity-types                   Entity types        (Sec 9)
//   /events                         Event definitions   (Sec 8)
//   /checklists                     Checklists          (Sec 11)
//   /checklists/{id}/items          Checklist items     (Sec 11)
//   /event-checklist-mappings       Mappings            (Sec 10)
//   /event-instances                Event Assurance     (Sec 13/14)
//   /event-instances/trigger        Event trigger       (Sec 13)
//   /event-gaps                     Event gaps          (Sec 15)
//   /dashboard/counts               Dashboard KPIs      (Sec 16)
//
// Kept flat + REST-verb-driven so the Web tier's WorkflowController
// (proxy) can forward paths one-to-one.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/workflow")]
public sealed class WorkflowController(
    IWorkflowService workflowService,
    ILogger<WorkflowController> logger) : ControllerBase
{
    // ============================================================
    // Workflow
    // ============================================================
    [HttpGet("workflows")]
    public async Task<IActionResult> ListWorkflows(
        [FromQuery] long?   organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? search,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        var q = new WorkflowListQuery(organizationId, statusCode, search, page, pageSize);
        return Ok(await workflowService.ListWorkflowsAsync(q, cancellationToken));
    }

    [HttpPost("workflows")]
    public async Task<IActionResult> SaveWorkflow([FromBody] WorkflowSaveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await workflowService.SaveWorkflowAsync(body, cancellationToken);
        return result.Success ? Ok(new { workflowId = result.WorkflowId }) : BadRequest(new { error = result.Error });
    }

    // ============================================================
    // Workflow Stage
    // ============================================================
    [HttpGet("workflows/{workflowId:long}/stages")]
    public async Task<IActionResult> ListStages(long workflowId, CancellationToken cancellationToken)
        => Ok(await workflowService.ListWorkflowStagesAsync(workflowId, cancellationToken));

    [HttpPost("workflow-stages")]
    public async Task<IActionResult> SaveStage([FromBody] WorkflowStageSaveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await workflowService.SaveWorkflowStageAsync(body, cancellationToken);
        return result.Success ? Ok(new { workflowStageId = result.WorkflowStageId }) : BadRequest(new { error = result.Error });
    }

    // ============================================================
    // Entity Type
    // ============================================================
    [HttpGet("entity-types")]
    public async Task<IActionResult> ListEntityTypes(
        [FromQuery] long?   organizationId,
        [FromQuery] string? statusCode,
        CancellationToken cancellationToken)
        => Ok(await workflowService.ListEntityTypesAsync(organizationId, statusCode, cancellationToken));

    [HttpPost("entity-types")]
    public async Task<IActionResult> SaveEntityType([FromBody] EntityTypeSaveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await workflowService.SaveEntityTypeAsync(body, cancellationToken);
        return result.Success ? Ok(new { entityTypeId = result.EntityTypeId }) : BadRequest(new { error = result.Error });
    }

    // ============================================================
    // Event Definition
    // ============================================================
    [HttpGet("events")]
    public async Task<IActionResult> ListEvents(
        [FromQuery] long?   organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? entityCategory,
        [FromQuery] string? search,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        var q = new EventDefinitionListQuery(organizationId, statusCode, entityCategory, search, page, pageSize);
        return Ok(await workflowService.ListEventDefinitionsAsync(q, cancellationToken));
    }

    [HttpPost("events")]
    public async Task<IActionResult> SaveEvent([FromBody] EventDefinitionSaveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await workflowService.SaveEventDefinitionAsync(body, cancellationToken);
        return result.Success ? Ok(new { eventDefinitionId = result.EventDefinitionId }) : BadRequest(new { error = result.Error });
    }

    // ============================================================
    // Checklist
    // ============================================================
    [HttpGet("checklists")]
    public async Task<IActionResult> ListChecklists(
        [FromQuery] long?   organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? search,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        var q = new ChecklistListQuery(organizationId, statusCode, search, page, pageSize);
        return Ok(await workflowService.ListChecklistsAsync(q, cancellationToken));
    }

    [HttpPost("checklists")]
    public async Task<IActionResult> SaveChecklist([FromBody] ChecklistSaveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await workflowService.SaveChecklistAsync(body, cancellationToken);
        return result.Success ? Ok(new { checklistId = result.ChecklistId }) : BadRequest(new { error = result.Error });
    }

    [HttpGet("checklists/{checklistId:long}/items")]
    public async Task<IActionResult> ListChecklistItems(long checklistId, CancellationToken cancellationToken)
        => Ok(await workflowService.ListChecklistItemsAsync(checklistId, cancellationToken));

    [HttpPost("checklist-items")]
    public async Task<IActionResult> SaveChecklistItem([FromBody] ChecklistItemSaveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await workflowService.SaveChecklistItemAsync(body, cancellationToken);
        return result.Success ? Ok(new { checklistItemId = result.ChecklistItemId }) : BadRequest(new { error = result.Error });
    }

    // ============================================================
    // Event-Checklist Mapping
    // ============================================================
    [HttpGet("event-checklist-mappings")]
    public async Task<IActionResult> ListMappings(
        [FromQuery] long?   organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        var q = new EventChecklistMappingListQuery(organizationId, statusCode, page, pageSize);
        return Ok(await workflowService.ListEventChecklistMappingsAsync(q, cancellationToken));
    }

    [HttpPost("event-checklist-mappings")]
    public async Task<IActionResult> SaveMapping([FromBody] EventChecklistMappingSaveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await workflowService.SaveEventChecklistMappingAsync(body, cancellationToken);
        return result.Success ? Ok(new { mappingId = result.MappingId }) : BadRequest(new { error = result.Error });
    }

    // ============================================================
    // Event Instance (Trigger Engine)
    // ============================================================
    [HttpGet("event-instances")]
    public async Task<IActionResult> ListEventInstances(
        [FromQuery] long?   organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? search,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        var q = new EventInstanceListQuery(organizationId, statusCode, search, page, pageSize);
        return Ok(await workflowService.ListEventInstancesAsync(q, cancellationToken));
    }

    [HttpPost("event-instances/trigger")]
    public async Task<IActionResult> TriggerEvent([FromBody] EventInstanceTriggerRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await workflowService.TriggerEventAsync(body, cancellationToken);
        return result.Success
            ? StatusCode(StatusCodes.Status201Created, new { eventInstanceId = result.EventInstanceId })
            : BadRequest(new { error = result.Error });
    }

    [HttpPost("event-instances/{id:long}/complete")]
    public async Task<IActionResult> CompleteEventInstance(long id, [FromBody] EventInstanceCompleteRequest? body, CancellationToken cancellationToken)
    {
        var request = (body ?? new EventInstanceCompleteRequest(id, null, null)) with { EventInstanceId = id };
        var result  = await workflowService.CompleteEventInstanceAsync(request, cancellationToken);
        return result.Success ? Ok(new { eventInstanceId = result.EventInstanceId }) : BadRequest(new { error = result.Error });
    }

    [HttpPost("event-instance-items")]
    public async Task<IActionResult> SaveEventInstanceItem([FromBody] EventInstanceItemSaveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await workflowService.SaveEventInstanceItemAsync(body, cancellationToken);
        return result.Success ? Ok(new { eventInstanceItemId = result.EventInstanceId }) : BadRequest(new { error = result.Error });
    }

    // ============================================================
    // Event Gap
    // ============================================================
    [HttpGet("event-gaps")]
    public async Task<IActionResult> ListEventGaps(
        [FromQuery] long?   organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? severity,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        var q = new EventGapListQuery(organizationId, statusCode, severity, page, pageSize);
        return Ok(await workflowService.ListEventGapsAsync(q, cancellationToken));
    }

    [HttpPost("event-gaps")]
    public async Task<IActionResult> OpenEventGap([FromBody] EventGapOpenRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var result = await workflowService.OpenEventGapAsync(body, cancellationToken);
        return result.Success
            ? StatusCode(StatusCodes.Status201Created, new { eventGapId = result.EventGapId })
            : BadRequest(new { error = result.Error });
    }

    [HttpPost("event-gaps/{id:long}/close")]
    public async Task<IActionResult> CloseEventGap(long id, [FromBody] EventGapCloseRequest? body, CancellationToken cancellationToken)
    {
        var request = (body ?? new EventGapCloseRequest(id, null, null)) with { EventGapId = id };
        var result  = await workflowService.CloseEventGapAsync(request, cancellationToken);
        return result.Success ? Ok(new { eventGapId = result.EventGapId }) : BadRequest(new { error = result.Error });
    }

    // ============================================================
    // Dashboard
    // ============================================================
    [HttpGet("dashboard/counts")]
    public async Task<IActionResult> DashboardCounts(
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
        => Ok(await workflowService.GetDashboardCountsAsync(organizationId, cancellationToken));
}
