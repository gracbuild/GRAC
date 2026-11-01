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
    // 477: the caller the Web tier stamps from the session (X-PM-Caller-*),
    // for the Evidence Center visibility rule.
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";
    private const string CallerAdminHeader    = "X-PM-Caller-Is-Admin";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private bool CallerIsAdmin =>
        Request.Headers[CallerAdminHeader].ToString() is "1" or "true" or "True";

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

    // Migration 256: per-source counts for Task Centre's Source filter,
    // matching what Gap Centre's filter already showed. Non-fatal --
    // the service returns an empty list with an Error rather than
    // throwing, so a missing migration costs the counts, not the page.
    [HttpGet("source-counts")]
    public async Task<IActionResult> SourceCounts(
        [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        var result = await taskService.SourceCountsAsync(organizationId, cancellationToken);
        return Ok(new
        {
            sources        = result.Sources,
            totalCount     = result.TotalCount,
            unsourcedCount = result.UnsourcedCount,
            error          = result.Error
        });
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
        // Migration 414 -- management dashboard drill-down (?drillCode=,
        // statusText=, severityText=, minAgeDays=, maxAgeDays=, noOwner=).
        // Every value absent = the list exactly as before.
        [FromQuery] ListDrillQuery? drill = null,
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
            Priority:             priority,
            Drill:                drill?.ToFilter());

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

    // =================================================================
    // Task edit — migration 269
    //
    // ONE endpoint for every editable field. /transition, /assign and
    // /priority are NOT removed: they are still the right call for a
    // single governed act from elsewhere in the product (Risk Treatment
    // reassigns from its own row menu, Exception Centre approves a
    // priority reduction), and sp_task_update composes the very same
    // procedures. This is an additional door into the same rooms, not a
    // second set of rules.
    // =================================================================

    /// <summary>
    /// What the editor may offer for this task: which fields are
    /// editable, whether a governed request is already pending, and the
    /// status transitions that are legal right now.
    ///
    /// <para>The UI calls this before rendering the form so it cannot
    /// offer a control whose save the database would refuse.</para>
    /// </summary>
    [HttpGet("{id:long}/edit-options")]
    public async Task<IActionResult> EditOptions(long id, CancellationToken cancellationToken)
    {
        var options = await taskService.GetEditOptionsAsync(id, cancellationToken);
        return options is null
            ? NotFound(new { error = $"Task {id} was not found." })
            : Ok(options);
    }

    /// <summary>
    /// Save the edit form. PUT, not POST: this replaces the editable
    /// state of one identified task and is idempotent — sending the same
    /// body twice changes nothing the second time, because sp_task_update
    /// diffs against current values before writing.
    ///
    /// <para><b>200 does not mean every field was applied.</b> Priority
    /// reductions (§7) and due-date changes (§8) come back with
    /// <c>outcome: "PendingApproval"</c> and the task is unchanged until
    /// Exception Centre approves. The response carries a per-field list
    /// precisely so the client cannot report a blanket "saved".</para>
    ///
    /// <para>409 Conflict covers both an illegal status transition and a
    /// concurrent edit (someone else changed the task after this form was
    /// loaded), which is what Conflict means in each case.</para>
    /// </summary>
    [HttpPut("{id:long}")]
    public async Task<IActionResult> Update(long id, [FromBody] TaskUpdateRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        // Route id wins, as it does on every other command here.
        // 2026-10-26: the actor comes from the session the Web tier stamps
        // (X-PM-Caller-Employee-Id), as Reopen does -- the browser never
        // sent ActorEmployeeId, so an SLA extension (BRD 8) raised from the
        // edit form was refused with ACTOR_REQUIRED. The body value is only
        // a fallback for a direct API caller with no stamped header.
        var result = await taskService.UpdateAsync(
            body with { TaskId = id, ActorEmployeeId = CallerEmployeeId ?? body.ActorEmployeeId },
            cancellationToken);

        if (!result.Success)
        {
            var status = result.ReasonCode switch
            {
                "CONCURRENT_EDIT"         => StatusCodes.Status409Conflict,
                "ILLEGAL_TRANSITION"      => StatusCodes.Status409Conflict,
                "TASK_CLOSED"             => StatusCodes.Status409Conflict,
                "CLOSE_VIA_EDIT_REFUSED"  => StatusCodes.Status409Conflict,
                "PRIORITY_REQUEST_PENDING"=> StatusCodes.Status409Conflict,
                "EXTENSION_PENDING"       => StatusCodes.Status409Conflict,
                "CHILD_PRIORITY_LOCKED"   => StatusCodes.Status409Conflict,
                "CHILD_SLA_LOCKED"        => StatusCodes.Status409Conflict,
                "SQL_ERROR"               => StatusCodes.Status500InternalServerError,
                _                         => StatusCodes.Status400BadRequest
            };
            return StatusCode(status, new { error = result.Error, reasonCode = result.ReasonCode });
        }

        return Ok(new
        {
            taskId           = result.TaskId,
            changes          = result.Changes,
            anyApplied       = result.AnyApplied,
            pendingApproval  = result.AnyPendingApproval
        });
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

    [HttpPost("{id:long}/reopen")]
    public async Task<IActionResult> Reopen(long id, [FromBody] TaskReopenRequest? body, CancellationToken cancellationToken)
    {
        // Actor + admin come from the session the Web tier stamps
        // (X-PM-Caller-*); sp_task_reopen authorizes admin OR task owner.
        var request = (body ?? new TaskReopenRequest(id, null, null, false, null, null)) with
        {
            TaskId          = id,
            ActorEmployeeId = CallerEmployeeId,
            IsAdmin         = CallerIsAdmin,
            ActorRoleCode   = CallerIsAdmin ? "Admin" : null
        };
        var result = await taskService.ReopenAsync(request, cancellationToken);
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
        [FromForm] long? instanceEvidenceId,   // 482: the recurring evidence row it answers
        // 499: the Evidence Center fields the shared upload dialog captures.
        // All optional -- posting only the file behaves exactly as before.
        [FromForm] string?   evidenceTitle,
        [FromForm] int?      evidenceTypeId,
        [FromForm] string?   evidenceItemDescription,
        [FromForm] long?     ownerEmployeeId,
        [FromForm] DateTime? validFrom,
        [FromForm] DateTime? validTo,
        [FromForm] string?   classification,
        [FromForm] string?   tags,
        CancellationToken cancellationToken)
    {
        if (file is null || file.Length == 0)
            return BadRequest(new { error = "A non-empty file is required." });

        using var ms = new MemoryStream();
        await file.CopyToAsync(ms, cancellationToken);

        // evidenceDescription is the ATTACHMENT's note on this task;
        // evidenceItemDescription is the Evidence Center item's own
        // description. Two different fields, which is why the form names
        // them apart.
        var metadata = new EvidenceUploadMetadata(
            evidenceTitle, evidenceTypeId, evidenceItemDescription, ownerEmployeeId,
            validFrom, validTo, classification, tags);

        var result = await taskService.AddAttachmentAsync(
            id, file.FileName, file.ContentType, ms.ToArray(),
            evidenceDescription, uploadedByEmployeeId, CallerIsAdmin, instanceEvidenceId, cancellationToken,
            metadata.HasAny ? metadata : null);

        return result.Success
            ? StatusCode(StatusCodes.Status201Created, new { taskAttachmentId = result.TaskId, message = result.Message })
            : Respond(result);
    }

    // ---- 477: Select from Evidence Center on a task -------------------
    // organizationId is required and checked by the Web tier against the
    // session; the procedures check the task belongs to it.
    [HttpGet("{id:long}/evidence-center")]
    public async Task<IActionResult> EvidenceCandidates(
        long id,
        [FromQuery] long    organizationId,
        [FromQuery] string? search,
        [FromQuery] int?    evidenceTypeId,
        [FromQuery] int     pageNumber = 1,
        [FromQuery] int     pageSize   = 10,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var result = await taskService.ListEvidenceCandidatesAsync(
            id, organizationId, CallerEmployeeId, CallerIsAdmin, search, evidenceTypeId, pageNumber, pageSize, cancellationToken);
        return result.Success
            ? Ok(new { data = result.Rows, totalRows = result.TotalRows })
            : BadRequest(new { error = result.Error });
    }

    [HttpPost("{id:long}/evidence-links")]
    public async Task<IActionResult> LinkEvidence(long id, [FromBody] TaskEvidenceLinkRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var actor = CallerEmployeeId is { } eid ? $"employee:{eid}" : "system";
        var result = await taskService.LinkEvidenceAsync(id, body, CallerEmployeeId, CallerIsAdmin, actor, cancellationToken);
        return result.Success
            ? Ok(new { success = true, taskAttachmentId = result.TaskId, message = result.Message })
            : Respond(result);
    }

    // ---- 482: recurring evidence on Complete Task --------------------
    // The recurring evidence of a scheduled task's obligation, and the
    // option chosen per row (Direct Upload / Evidence Center Reference /
    // External Evidence Reference). organizationId is required and checked
    // by the Web tier against the session; the procedures check the task
    // belongs to it. Nothing here is mandatory.
    [HttpGet("{id:long}/recurring-evidence")]
    public async Task<IActionResult> RecurringEvidence(
        long id, [FromQuery] long organizationId, CancellationToken cancellationToken)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var result = await taskService.ListRecurringEvidenceAsync(id, organizationId, cancellationToken);
        return result.Success
            ? Ok(new { data = result.Rows, general = result.General })   // 483: general
            : BadRequest(new { error = result.Error });
    }

    [HttpPost("{id:long}/recurring-evidence")]
    public async Task<IActionResult> SaveRecurringEvidence(
        long id, [FromBody] TaskRecurringEvidenceSaveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        var actor = CallerEmployeeId is { } eid ? $"employee:{eid}" : "system";
        var result = await taskService.SaveRecurringEvidenceAsync(id, body, CallerEmployeeId, actor, cancellationToken);
        return result.Success
            ? Ok(new { success = true, message = result.Message })
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

        // Approver = the authenticated caller (see ApprovePriorityReduction).
        var approver = CallerEmployeeId ?? (body.ApprovedByEmployeeId > 0 ? body.ApprovedByEmployeeId : (long?)null);
        if (approver is null)
            return BadRequest(new { error = "Your account is not linked to an employee record, so you cannot approve this request." });

        var result = await taskService.ApproveSlaExtensionAsync(
            body with { ExceptionRequestId = exceptionRequestId, ApprovedByEmployeeId = approver.Value }, cancellationToken);

        return result.Success
            ? Ok(new { exceptionRequestId, taskId = result.TaskId, statusCode = result.StatusCode })
            : Respond(result);
    }

    [HttpPost("requests/{exceptionRequestId:long}/approve-priority-reduction")]
    public async Task<IActionResult> ApprovePriorityReduction(
        long exceptionRequestId, [FromBody] TaskGovernanceApproveRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        // The approver is the authenticated caller (X-PM-Caller-Employee-Id),
        // not a value the browser sends. Falls back to the body only if the
        // header is absent. sp_task_priority_reduction_approve requires a
        // non-null approver, so refuse cleanly when neither is available.
        var approver = CallerEmployeeId ?? (body.ApprovedByEmployeeId > 0 ? body.ApprovedByEmployeeId : (long?)null);
        if (approver is null)
            return BadRequest(new { error = "Your account is not linked to an employee record, so you cannot approve this request." });

        var result = await taskService.ApprovePriorityReductionAsync(
            body with { ExceptionRequestId = exceptionRequestId, ApprovedByEmployeeId = approver.Value }, cancellationToken);

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

            // task reopen (479)
            "TASK_NOT_CLOSED"           => StatusCodes.Status409Conflict,
            "REOPEN_FORBIDDEN"          => StatusCodes.Status403Forbidden,
            "TASK_NOT_FOUND"            => StatusCodes.Status404NotFound,

            "REASON_REQUIRED"           => StatusCodes.Status400BadRequest,
            "ACTOR_REQUIRED"            => StatusCodes.Status400BadRequest,
            "EXTENSION_NOT_LATER"       => StatusCodes.Status400BadRequest,
            "VALIDATION_ERROR"          => StatusCodes.Status400BadRequest,

            _                           => StatusCodes.Status500InternalServerError
        };
        return StatusCode(status, new { error = result.Error, reasonCode = result.ReasonCode });
    }
}
