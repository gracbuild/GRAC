// =====================================================================
// TaskController  (charter §12.1.3)
//
// Route: /api/practice/tasks/...
// Fully independent of PracticeRepositoryController per charter §5.
//
// Endpoints:
//   GET  /api/practice/tasks                       -> list (paginated)
//   POST /api/practice/tasks                       -> open
//   POST /api/practice/tasks/{id}/assign           -> reassign
//   POST /api/practice/tasks/{id}/transition       -> state change
//   POST /api/practice/tasks/{id}/close            -> close (two-gate guarded)
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/tasks")]
public sealed class TaskController(
    ITaskService taskService,
    IConfiguration configuration,
    ILogger<TaskController> logger) : ControllerBase
{
    // GET /api/practice/tasks/counts?organizationId=
    // Returns the 4 tab count badges for the Task Center UI.
    [HttpGet("counts")]
    public async Task<IActionResult> Counts([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        var conn = Infrastructure.SqlConnectionStringResolver.Resolve(configuration);
        if (string.IsNullOrWhiteSpace(conn))
            return StatusCode(503, new { error = "Connection string not configured." });
        try
        {
            await using var connection = new Microsoft.Data.SqlClient.SqlConnection(conn);
            await connection.OpenAsync(cancellationToken);
            await using var cmd = connection.CreateCommand();
            cmd.CommandType = System.Data.CommandType.StoredProcedure;
            cmd.CommandText = "grac_practice.sp_task_center_counts";
            var p = cmd.CreateParameter();
            p.ParameterName = "@organization_id"; p.DbType = System.Data.DbType.Int64;
            p.Value = (object?)organizationId ?? DBNull.Value;
            cmd.Parameters.Add(p);
            await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                return Ok(new { gapsCount = 0, implementationCount = 0, assuranceCount = 0, customCount = 0 });
            return Ok(new
            {
                gapsCount           = Convert.ToInt64(reader["GapsCount"]),
                implementationCount = Convert.ToInt64(reader["ImplementationCount"]),
                assuranceCount      = Convert.ToInt64(reader["AssuranceCount"]),
                customCount         = Convert.ToInt64(reader["CustomCount"])
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
            PageSize:             pageSize);

        var result = await taskService.ListAsync(query, cancellationToken);
        return Ok(result);
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

    private IActionResult Respond(TaskCommandResult result)
    {
        if (result.Success) return Ok(new { taskId = result.TaskId });

        // Charter: illegal state transition returns 409 Conflict
        var status = result.ReasonCode switch
        {
            "ILLEGAL_TRANSITION"  => StatusCodes.Status409Conflict,
            "REASON_REQUIRED"     => StatusCodes.Status400BadRequest,
            "TWO_GATE_NOT_PASSED" => StatusCodes.Status409Conflict,
            _                     => StatusCodes.Status500InternalServerError
        };
        return StatusCode(status, new { error = result.Error, reasonCode = result.ReasonCode });
    }
}
