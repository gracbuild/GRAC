// =====================================================================
// TaskController  (charter §12.1.3)
//
// Route: /api/practice/tasks/...
// Fully independent of PracticeRepositoryController per charter §5.
//
// Endpoints:
//   GET  /api/practice/tasks                          -> list (paginated)
//   GET  /api/practice/tasks/counts                   -> tab badges
//   GET  /api/practice/tasks/{id}                     -> detail (v2)
//   GET  /api/practice/tasks/{id}/eligibility         -> completion gate (v2)
//   GET  /api/practice/tasks/by-source                -> source -> tasks (v2)
//   GET  /api/practice/tasks/owner-resolve            -> owner ladder preview (v2)
//   GET  /api/practice/tasks/attachments/{id}         -> download evidence (v2)
//   POST /api/practice/tasks                          -> open
//   POST /api/practice/tasks/{id}/assign              -> reassign
//   POST /api/practice/tasks/{id}/transition          -> state change
//   POST /api/practice/tasks/{id}/close               -> close (two-gate guarded)
//   POST /api/practice/tasks/{id}/priority            -> governed priority change (v2)
//   POST /api/practice/tasks/{id}/sla-extension       -> raise extension request (v2)
//   POST /api/practice/tasks/{id}/children            -> decompose (v2)
//   POST /api/practice/tasks/{id}/complete            -> governed completion (v2)
//   POST /api/practice/tasks/{id}/activity            -> comment / update (v2)
//   POST /api/practice/tasks/{id}/attachments         -> upload evidence (v2)
//   POST /api/practice/tasks/requests/{rid}/approve-sla-extension       (v2)
//   POST /api/practice/tasks/requests/{rid}/approve-priority-reduction  (v2)
//
// The v2 endpoints are documented in docs/task-centre-v2.md and map 1:1
// onto migrations 192-196.
//
// NOTE: the Counts endpoint used to open its own SqlConnection inline.
// That duplicated the data-access concern TaskService already owns, so
// it now delegates to ITaskService.CountsAsync like every other action.
// IConfiguration is consequently no longer a dependency of this class.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/tasks")]
public sealed class TaskController(
    ITaskService taskService,
    ILogger<TaskController> logger) : ControllerBase
{
    // GET /api/practice/tasks/counts?organizationId=
    // Returns the tab count badges for the Task Center UI.
    [HttpGet("counts")]
    public async Task<IActionResult> Counts([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        try
        {
            var counts = await taskService.CountsAsync(organizationId, cancellationToken);
            return Ok(new
            {
                gapsCount            = counts.GapsCount,
                implementationCount  = counts.ImplementationCount,
                assuranceCount       = counts.AssuranceCount,
                customCount          = counts.CustomCount,
                // new in v2 (195) — safe to ignore for older UIs
                breachedCount        = counts.BreachedCount,
                pendingApprovalCount = counts.PendingApprovalCount
            });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController.Counts failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long? organizationId,
        [FromQuery] long? assignedToEmployeeId,
        [FromQuery] string? taskTypeCode,
        [FromQuery] string? statusCode,
        [FromQuery] bool? overdueOnly,
        [FromQuery] string? search,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        // ---- v2 filters (195) ----
        [FromQuery] long? parentTaskId = null,
        [FromQuery] bool? includeChildren = null,
        [FromQuery] string? slaStatusCode = null,
        [FromQuery] string? sourceTypeCode = null,
        [FromQuery] long? sourceRecordId = null,
        [FromQuery] string? priority = null,
        CancellationToken cancellationToken = default)
    {
        var query = new TaskListQuery(
            OrganizationId:       organizationId,
            AssignedToEmployeeId: assignedToEmployeeId,
            TaskTypeCode:         taskTypeCode,
            StatusCode:           statusCode,
            OverdueOnly:          overdueOnly,
            Search:               search,
            Page:                 page,
            PageSize:             pageSize,
            ParentTaskId:         parentTaskId,
            IncludeChildren:      includeChildren,
            SlaStatusCode:        slaStatusCode,
            SourceTypeCode:       sourceTypeCode,
            SourceRecordId:       sourceRecordId,
            Priority:             priority);

        var result = await taskService.ListAsync(query, cancellationToken);
        return Ok(result);
    }

    // ---- v2: operational detail view (BRD §16) ----------------------
    [HttpGet("{id:long}")]
    public async Task<IActionResult> Detail(long id, CancellationToken cancellationToken)
    {
        var detail = await taskService.GetAsync(id, cancellationToken);
        return detail is null
            ? NotFound(new { error = $"Task {id} was not found." })
            : Ok(detail);
    }

    // ---- v2: may this task be completed right now? (BRD §12) --------
    [HttpGet("{id:long}/eligibility")]
    public async Task<IActionResult> Eligibility(long id, CancellationToken cancellationToken)
    {
        var eligibility = await taskService.CompletionEligibilityAsync(id, cancellationToken);
        return eligibility is null
            ? NotFound(new { error = $"Task {id} was not found." })
            : Ok(eligibility);
    }

    // ---- v2: one source -> many tasks (BRD §15) ---------------------
    [HttpGet("by-source")]
    public async Task<IActionResult> BySource(
        [FromQuery] string sourceTypeCode,
        [FromQuery] long sourceRecordId,
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(sourceTypeCode))
            return BadRequest(new { error = "sourceTypeCode is required." });

        var rows = await taskService.SourceTasksAsync(sourceTypeCode, sourceRecordId, organizationId, cancellationToken);
        return Ok(new { data = rows });
    }

    // ---- v2: preview the owner ladder without committing (BRD §6) ---
    [HttpGet("owner-resolve")]
    public async Task<IActionResult> OwnerResolve(
        [FromQuery] long organizationId,
        [FromQuery] string? sourceTypeCode,
        [FromQuery] long? sourceRecordId,
        [FromQuery] long? linkedPracticeId,
        [FromQuery] long? linkedControlId,
        [FromQuery] long? linkedInstanceId,
        [FromQuery] long? explicitOwnerEmployeeId,
        CancellationToken cancellationToken)
    {
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });

        var result = await taskService.ResolveOwnerAsync(
            new TaskOwnerResolveQuery(organizationId, sourceTypeCode, sourceRecordId,
                                      linkedPracticeId, linkedControlId, linkedInstanceId,
                                      explicitOwnerEmployeeId),
            cancellationToken);

        return Ok(result);
    }

    // ---- v2: stream one piece of evidence (BRD §16) -----------------
    [HttpGet("attachments/{attachmentId:long}")]
    public async Task<IActionResult> DownloadAttachment(long attachmentId, CancellationToken cancellationToken)
    {
        var file = await taskService.GetAttachmentAsync(attachmentId, cancellationToken);
        return file is null
            ? NotFound(new { error = $"Attachment {attachmentId} was not found." })
            : File(file.FileData, file.ContentType ?? "application/octet-stream", file.FileName);
    }

    [HttpPost]
    public async Task<IActionResult> Open([FromBody] TaskOpenRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await taskService.OpenAsync(body, cancellationToken);
        return result.Success
            ? StatusCode(StatusCodes.Status201Created, new { taskId = result.TaskId })
            : StatusCode(StatusCodes.Status400BadRequest,
                new { error = result.Error, reasonCode = result.ReasonCode });
    }

    [HttpPost("{id:long}/assign")]
    public async Task<IActionResult> Assign(long id, [FromBody] TaskAssignRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        // Force route id
        var request = body with { TaskId = id };
        var result = await taskService.AssignAsync(request, cancellationToken);
        return Respond(result);
    }

    [HttpPost("{id:long}/transition")]
    public async Task<IActionResult> Transition(long id, [FromBody] TaskTransitionRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (string.IsNullOrWhiteSpace(body.ToStatusCode))
            return BadRequest(new { error = "ToStatusCode is required." });

        var request = body with { TaskId = id };
        var result = await taskService.TransitionAsync(request, cancellationToken);
        return Respond(result);
    }

    [HttpPost("{id:long}/close")]
    public async Task<IActionResult> Close(long id, [FromBody] TaskCloseRequest? body, CancellationToken cancellationToken)
    {
        var request = (body ?? new TaskCloseRequest(id, null, null, null, null, null)) with { TaskId = id };
        var result = await taskService.CloseAsync(request, cancellationToken);
        return Respond(result);
    }

    // =================================================================
    // Task Centre v2 commands
    // =================================================================

    /// <summary>
    /// BRD §7. An increase returns 200 with statusCode "Applied"; a
    /// reduction returns 202 Accepted with statusCode "PendingApproval"
    /// and the Exception Centre request id — nothing on the task has
    /// changed yet, and 202 says exactly that.
    /// </summary>
    [HttpPost("{id:long}/priority")]
    public async Task<IActionResult> ChangePriority(long id, [FromBody] TaskPriorityChangeRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (string.IsNullOrWhiteSpace(body.NewPriority))
            return BadRequest(new { error = "NewPriority is required." });

        var result = await taskService.ChangePriorityAsync(body with { TaskId = id }, cancellationToken);
        if (!result.Success) return Respond(result);

        var payload = new
        {
            taskId             = result.TaskId,
            statusCode         = result.StatusCode,
            exceptionRequestId = result.ExceptionRequestId
        };

        return result.StatusCode == "PendingApproval"
            ? Accepted(payload)
            : Ok(payload);
    }

    /// <summary>
    /// BRD §8. Always 202 Accepted on success: an extension request never
    /// changes the effective due date, it only asks Exception Centre.
    /// </summary>
    [HttpPost("{id:long}/sla-extension")]
    public async Task<IActionResult> RequestSlaExtension(long id, [FromBody] TaskSlaExtensionRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await taskService.RequestSlaExtensionAsync(body with { TaskId = id }, cancellationToken);
        return result.Success
            ? Accepted(new
              {
                  taskId             = result.TaskId,
                  statusCode         = result.StatusCode,
                  exceptionRequestId = result.ExceptionRequestId
              })
            : Respond(result);
    }

    /// <summary>BRD §11. Child inherits priority and SLA from the parent —
    /// neither is accepted in the body.</summary>
    [HttpPost("{id:long}/children")]
    public async Task<IActionResult> CreateChild(long id, [FromBody] TaskChildCreateRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (string.IsNullOrWhiteSpace(body.SubjectTitle))
            return BadRequest(new { error = "SubjectTitle is required." });

        var result = await taskService.CreateChildAsync(body with { ParentTaskId = id }, cancellationToken);
        return result.Success
            ? StatusCode(StatusCodes.Status201Created, new { childTaskId = result.TaskId, parentTaskId = id })
            : Respond(result);
    }

    /// <summary>BRD §10/§12. 409 Conflict when mandatory children are still
    /// open, or when the Implementation two-gate rule blocks closure.</summary>
    [HttpPost("{id:long}/complete")]
    public async Task<IActionResult> Complete(long id, [FromBody] TaskCompleteRequest? body, CancellationToken cancellationToken)
    {
        var request = (body ?? new TaskCompleteRequest(id, null, null, null)) with { TaskId = id };
        var result  = await taskService.CompleteAsync(request, cancellationToken);
        return result.Success
            ? Ok(new { taskId = result.TaskId, statusCode = result.StatusCode ?? "Completed" })
            : Respond(result);
    }

    /// <summary>BRD §16. Progress updates and comments on the task feed.</summary>
    [HttpPost("{id:long}/activity")]
    public async Task<IActionResult> AddActivity(long id, [FromBody] TaskActivityAddRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (string.IsNullOrWhiteSpace(body.ActivityTypeCode))
            return BadRequest(new { error = "ActivityTypeCode is required." });

        var result = await taskService.AddActivityAsync(body with { TaskId = id }, cancellationToken);
        return Respond(result);
    }

    /// <summary>BRD §16. Evidence upload. Multipart so the browser can post
    /// the file directly rather than base64-inflating it through JSON.</summary>
    [HttpPost("{id:long}/attachments")]
    [RequestSizeLimit(52_428_800)] // 50 MB — matches the document upload module
    public async Task<IActionResult> UploadAttachment(
        long id,
        [FromForm] IFormFile? file,
        [FromForm] string? evidenceDescription,
        [FromForm] long? uploadedByEmployeeId,
        CancellationToken cancellationToken)
    {
        if (file is null || file.Length == 0)
            return BadRequest(new { error = "A non-empty file is required." });

        using var ms = new MemoryStream();
        await file.CopyToAsync(ms, cancellationToken);

        var result = await taskService.AddAttachmentAsync(
            id, file.FileName, file.ContentType, ms.ToArray(),
            evidenceDescription, uploadedByEmployeeId, cancellationToken);

        return result.Success
            ? StatusCode(StatusCodes.Status201Created, new { taskAttachmentId = result.TaskId })
            : Respond(result);
    }

    // ---- v2: Exception Centre approvals -----------------------------
    // Rejection is NOT here: it stays on the Exception Centre's own
    // endpoint (sp_exception_request_reject), which 193 made task-aware.
    // Splitting reject across two controllers would create exactly the
    // parallel approval mechanism BRD §19 forbids.

    [HttpPost("requests/{exceptionRequestId:long}/approve-sla-extension")]
    public async Task<IActionResult> ApproveSlaExtension(
        long exceptionRequestId, [FromBody] TaskGovernanceApproveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await taskService.ApproveSlaExtensionAsync(
            body with { ExceptionRequestId = exceptionRequestId }, cancellationToken);

        return result.Success
            ? Ok(new { exceptionRequestId, taskId = result.TaskId, statusCode = result.StatusCode })
            : Respond(result);
    }

    [HttpPost("requests/{exceptionRequestId:long}/approve-priority-reduction")]
    public async Task<IActionResult> ApprovePriorityReduction(
        long exceptionRequestId, [FromBody] TaskGovernanceApproveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await taskService.ApprovePriorityReductionAsync(
            body with { ExceptionRequestId = exceptionRequestId }, cancellationToken);

        return result.Success
            ? Ok(new { exceptionRequestId, taskId = result.TaskId, statusCode = result.StatusCode })
            : Respond(result);
    }

    // =================================================================

    private IActionResult Respond(TaskCommandResult result)
    {
        if (result.Success)
            return Ok(new { taskId = result.TaskId, statusCode = result.StatusCode });

        // Charter: illegal state transition returns 409 Conflict.
        // Task Centre v2 keeps that convention: a governance rule that
        // says "not in this state / not from this role of the hierarchy"
        // is a conflict; a malformed ask is a 400.
        var status = result.ReasonCode switch
        {
            "ILLEGAL_TRANSITION"        => StatusCodes.Status409Conflict,
            "TWO_GATE_NOT_PASSED"       => StatusCodes.Status409Conflict,
            "COMPLETION_BLOCKED"        => StatusCodes.Status409Conflict,
            "ALREADY_COMPLETED"         => StatusCodes.Status409Conflict,
            "PARENT_COMPLETED"          => StatusCodes.Status409Conflict,
            "PRIORITY_REQUEST_PENDING"  => StatusCodes.Status409Conflict,
            "EXTENSION_PENDING"         => StatusCodes.Status409Conflict,
            "CHILD_PRIORITY_LOCKED"     => StatusCodes.Status409Conflict,
            "CHILD_SLA_LOCKED"          => StatusCodes.Status409Conflict,
            "CHILD_NESTING_NOT_ALLOWED" => StatusCodes.Status409Conflict,

            "REASON_REQUIRED"           => StatusCodes.Status400BadRequest,
            "ACTOR_REQUIRED"            => StatusCodes.Status400BadRequest,
            "EXTENSION_NOT_LATER"       => StatusCodes.Status400BadRequest,
            "VALIDATION_ERROR"          => StatusCodes.Status400BadRequest,

            _                           => StatusCodes.Status500InternalServerError
        };
        return StatusCode(status, new { error = result.Error, reasonCode = result.ReasonCode });
    }
}
