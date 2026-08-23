// =====================================================================
// TaskCandidateController  (Task Centre v2, Phase 2)
//
// Route: /api/practice/task-candidates/...
// Independent of TaskController per charter §5 — that one owns the task
// engine, this owns the validation gate in front of it.
//
// Endpoints:
//   GET  /api/practice/task-candidates                  -> list (paginated)
//   GET  /api/practice/task-candidates/counts           -> tab badges
//   GET  /api/practice/task-candidates/{id}             -> detail + history
//   GET  /api/practice/task-candidates/source-items     -> BRD §15 panel
//   GET  /api/practice/task-candidates/source-state     -> BRD §14 marker
//   POST /api/practice/task-candidates                  -> raise manually
//   POST /api/practice/task-candidates/{id}/validate    -> confirm owner + priority
//   POST /api/practice/task-candidates/{id}/approve     -> convert to a task
//   POST /api/practice/task-candidates/{id}/discard     -> will not be executed
//
// There is no update/delete: a candidate is either validated, approved or
// discarded. BRD §5 gives this stage exactly one job, and letting callers
// rewrite a candidate's origin or title would let Task Centre quietly
// redefine work the source identified.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/task-candidates")]
public sealed class TaskCandidateController(
    ITaskCandidateService candidateService,
    ILogger<TaskCandidateController> logger) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long? organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? sourceTypeCode,
        [FromQuery] long? sourceRecordId,
        [FromQuery] long? ownerEmployeeId,
        [FromQuery] string? priority,
        [FromQuery] string? search,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        var result = await candidateService.ListAsync(
            new TaskCandidateListQuery(organizationId, statusCode, sourceTypeCode,
                                       sourceRecordId, ownerEmployeeId, priority,
                                       search, page, pageSize),
            cancellationToken);
        return Ok(result);
    }

    [HttpGet("counts")]
    public async Task<IActionResult> Counts([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        try
        {
            var counts = await candidateService.CountsAsync(organizationId, cancellationToken);
            return Ok(counts);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskCandidateController.Counts failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("{id:long}")]
    public async Task<IActionResult> Detail(long id, CancellationToken cancellationToken)
    {
        var detail = await candidateService.GetAsync(id, cancellationToken);
        return detail is null
            ? NotFound(new { error = $"Task candidate {id} was not found." })
            : Ok(detail);
    }

    /// <summary>
    /// BRD §15 — the source's "Related Tasks" panel. Returns candidates
    /// AND tasks in one list so a gap owner can see work that is
    /// identified but not yet accountable, instead of an empty panel.
    /// </summary>
    [HttpGet("source-items")]
    public async Task<IActionResult> SourceItems(
        [FromQuery] string sourceTypeCode,
        [FromQuery] long sourceRecordId,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(sourceTypeCode))
            return BadRequest(new { error = "sourceTypeCode is required." });

        var rows = await candidateService.SourceItemsAsync(sourceTypeCode, sourceRecordId, organizationId, cancellationToken);
        return Ok(new { data = rows });
    }

    /// <summary>
    /// BRD §14 — "Task Action Completed" for a source. Reports only; the
    /// source module still decides whether its own item is resolved.
    /// 200 with a null payload means no task work has ever been raised,
    /// which is a normal state rather than a 404.
    /// </summary>
    [HttpGet("source-state")]
    public async Task<IActionResult> SourceState(
        [FromQuery] string sourceTypeCode,
        [FromQuery] long sourceRecordId,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(sourceTypeCode))
            return BadRequest(new { error = "sourceTypeCode is required." });

        var state = await candidateService.SourceActionStateAsync(sourceTypeCode, sourceRecordId, cancellationToken);
        return Ok(new { data = state });
    }

    [HttpPost]
    public async Task<IActionResult> Create([FromBody] TaskCandidateCreateRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await candidateService.CreateAsync(body, cancellationToken);
        if (!result.Success) return Respond(result);

        // An idempotent match is a 200, not a 201 — nothing was created.
        var payload = new { taskCandidateId = result.TaskCandidateId, statusCode = result.StatusCode, created = result.Created };
        return result.Created
            ? StatusCode(StatusCodes.Status201Created, payload)
            : Ok(payload);
    }

    [HttpPost("{id:long}/validate")]
    public async Task<IActionResult> Validate(long id, [FromBody] TaskCandidateValidateRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await candidateService.ValidateAsync(body with { TaskCandidateId = id }, cancellationToken);
        return Respond(result);
    }

    [HttpPost("{id:long}/approve")]
    public async Task<IActionResult> Approve(long id, [FromBody] TaskCandidateApproveRequest? body, CancellationToken cancellationToken)
    {
        var request = (body ?? new TaskCandidateApproveRequest(id, null, null)) with { TaskCandidateId = id };
        var result  = await candidateService.ApproveAsync(request, cancellationToken);

        return result.Success
            ? StatusCode(StatusCodes.Status201Created,
                new { taskCandidateId = id, approvedTaskId = result.ApprovedTaskId, statusCode = result.StatusCode })
            : Respond(result);
    }

    [HttpPost("{id:long}/discard")]
    public async Task<IActionResult> Discard(long id, [FromBody] TaskCandidateDiscardRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (string.IsNullOrWhiteSpace(body.DiscardReason))
            return BadRequest(new { error = "DiscardReason is required." });

        var result = await candidateService.DiscardAsync(body with { TaskCandidateId = id }, cancellationToken);
        return Respond(result);
    }

    private IActionResult Respond(TaskCandidateCommandResult result)
    {
        if (result.Success)
            return Ok(new
            {
                taskCandidateId = result.TaskCandidateId,
                statusCode      = result.StatusCode,
                approvedTaskId  = result.ApprovedTaskId
            });

        // Same convention as TaskController: a state the record is
        // already in, or a rule about what stage it has reached, is a
        // conflict; a malformed or incomplete ask is a 400.
        var status = result.ReasonCode switch
        {
            "ALREADY_APPROVED"  => StatusCodes.Status409Conflict,
            "ALREADY_DISCARDED" => StatusCodes.Status409Conflict,
            "DISCARDED"         => StatusCodes.Status409Conflict,
            "NOT_EDITABLE"      => StatusCodes.Status409Conflict,

            "OWNER_REQUIRED"    => StatusCodes.Status400BadRequest,
            "OWNER_NOT_IN_ORG"  => StatusCodes.Status400BadRequest,
            "REASON_REQUIRED"   => StatusCodes.Status400BadRequest,
            "VALIDATION_ERROR"  => StatusCodes.Status400BadRequest,

            _                   => StatusCodes.Status500InternalServerError
        };
        return StatusCode(status, new { error = result.Error, reasonCode = result.ReasonCode });
    }
}
