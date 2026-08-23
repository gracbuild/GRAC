// =====================================================================
// TaskNotificationController  (Task Centre v2, Phase 3 — BRD §13)
//
// Route: /api/practice/task-notifications/...
//
// Endpoints:
//   GET  /api/practice/task-notifications           -> outbox / my inbox
//   GET  /api/practice/task-notifications/counts    -> badges
//   POST /api/practice/task-notifications/sweep     -> run one pass now
//   POST /api/practice/task-notifications/{id}/mark -> dispatcher feedback
//
// There is no "send" endpoint. Phase 3 records the obligation to notify;
// no delivery infrastructure exists to hand off to. `mark` is the seam a
// future dispatcher reports back through.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/task-notifications")]
public sealed class TaskNotificationController(
    ITaskNotificationService notificationService,
    ILogger<TaskNotificationController> logger) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long? organizationId,
        [FromQuery] long? recipientEmployeeId,
        [FromQuery] long? taskId,
        [FromQuery] string? statusCode,
        [FromQuery] string? notifyEventCode,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        var result = await notificationService.ListAsync(
            new TaskNotificationListQuery(organizationId, recipientEmployeeId, taskId,
                                          statusCode, notifyEventCode, page, pageSize),
            cancellationToken);
        return Ok(result);
    }

    [HttpGet("counts")]
    public async Task<IActionResult> Counts(
        [FromQuery] long? organizationId,
        [FromQuery] long? recipientEmployeeId,
        CancellationToken cancellationToken)
    {
        try
        {
            var counts = await notificationService.CountsAsync(organizationId, recipientEmployeeId, cancellationToken);
            return Ok(counts);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskNotificationController.Counts failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Runs one sweep pass immediately. The worker does this on a timer;
    /// this endpoint exists for operators who need it now (after fixing a
    /// notify-role configuration, say) and for environments running with
    /// the worker disabled.
    ///
    /// Idempotent: an already-recorded threshold is not recorded twice, so
    /// calling this repeatedly is harmless and returns enqueued = 0.
    /// </summary>
    [HttpPost("sweep")]
    public async Task<IActionResult> Sweep(
        [FromQuery] long? organizationId,
        [FromQuery] int batchSize = 200,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var result = await notificationService.SweepAsync(organizationId, batchSize, cancellationToken);
            return Ok(new { enqueued = result.Enqueued, tasksScanned = result.TasksScanned });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskNotificationController.Sweep failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Marks one recipient's Pending notifications read. The Web tier
    /// supplies recipientEmployeeId from the SESSION, never from the
    /// browser — see Web/Controllers/TaskNotificationController's /me
    /// routes. It is required here precisely so there is no "mark
    /// everyone's" path to call by accident.
    /// </summary>
    [HttpPost("mark-all")]
    public async Task<IActionResult> MarkAll(
        [FromQuery] long recipientEmployeeId,
        [FromQuery] long? organizationId,
        [FromQuery] string? notifyEventCode,
        CancellationToken cancellationToken)
    {
        if (recipientEmployeeId <= 0)
            return BadRequest(new { error = "recipientEmployeeId is required." });

        try
        {
            var marked = await notificationService.MarkAllAsync(
                recipientEmployeeId, organizationId, notifyEventCode, cancellationToken);
            return Ok(new { recipientEmployeeId, markedCount = marked });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskNotificationController.MarkAll failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("{id:long}/mark")]
    public async Task<IActionResult> Mark(long id, [FromBody] TaskNotificationMarkRequest body, CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });

        var result = await notificationService.MarkAsync(body with { TaskNotificationId = id }, cancellationToken);
        if (result.Success)
            return Ok(new { taskNotificationId = result.TaskNotificationId, statusCode = result.StatusCode });

        var status = result.ReasonCode switch
        {
            "NOT_FOUND"        => StatusCodes.Status404NotFound,
            "INVALID_STATUS"   => StatusCodes.Status400BadRequest,
            "VALIDATION_ERROR" => StatusCodes.Status400BadRequest,
            _                  => StatusCodes.Status500InternalServerError
        };
        return StatusCode(status, new { error = result.Error, reasonCode = result.ReasonCode });
    }
}
