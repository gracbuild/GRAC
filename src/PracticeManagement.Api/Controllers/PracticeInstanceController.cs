// =====================================================================
// PracticeInstanceController  (Q13/Q14/Q15)
//
// Route: /api/practice/instances/...
// Kept separate from PracticeRepositoryController per charter §5.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/instances")]
public sealed class PracticeInstanceController(
    IPracticeInstanceWorkflowService workflowService,
    IConfiguration configuration,
    ILogger<PracticeInstanceController> logger) : ControllerBase
{
    /// <summary>
    /// Lightweight read-only lookup used by the UI to pre-fill the
    /// "Add Implementation Task" and "Update Implementation Status" modals.
    /// Returns 404 when the instance is unknown.
    /// </summary>
    [HttpGet("{id:long}/context")]
    public async Task<IActionResult> GetContext(long id, CancellationToken cancellationToken)
    {
        var ctx = await workflowService.GetContextAsync(id, cancellationToken);
        return ctx is null ? NotFound(new { error = "Practice Instance not found." }) : Ok(ctx);
    }

    // GET /api/practice/instances/gaps?organizationId=&search=&page=&pageSize=
    // Task Center Gaps tab data source.
    [HttpGet("gaps")]
    public async Task<IActionResult> Gaps(
        [FromQuery] long? organizationId,
        [FromQuery] string? search,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
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
            cmd.CommandText = "grac_practice.sp_task_center_gaps_list";
            void Add(string n, System.Data.DbType t, object? v) { var p = cmd.CreateParameter(); p.ParameterName = n; p.DbType = t; p.Value = v ?? DBNull.Value; cmd.Parameters.Add(p); }
            Add("@organization_id", System.Data.DbType.Int64,  (object?)organizationId ?? DBNull.Value);
            Add("@search",          System.Data.DbType.String, (object?)search ?? DBNull.Value);
            Add("@page",            System.Data.DbType.Int32,  Math.Max(1, page));
            Add("@page_size",       System.Data.DbType.Int32,  Math.Clamp(pageSize, 1, 200));

            await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
            long total = 0; int pn = page, ps = pageSize;
            if (await reader.ReadAsync(cancellationToken))
            {
                total = Convert.ToInt64(reader["TotalCount"]);
                pn    = Convert.ToInt32(reader["PageNumber"]);
                ps    = Convert.ToInt32(reader["PageSize"]);
            }
            var rows = new List<object>();
            if (await reader.NextResultAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                    rows.Add(new
                    {
                        practiceInstanceId  = Convert.ToInt64(reader["PracticeInstanceId"]),
                        instanceCode        = reader["InstanceCode"]?.ToString() ?? "",
                        instanceName        = reader["InstanceName"]?.ToString() ?? "",
                        practiceId          = reader["PracticeId"] as long?,
                        practiceCode        = reader["PracticeCode"] as string,
                        practiceName        = reader["PracticeName"] as string,
                        organizationId      = reader["OrganizationId"] as long?,
                        organizationName    = reader["OrganizationName"] as string,
                        implementationStatus= reader["ImplementationStatus"]?.ToString() ?? "",
                        owner               = reader["Owner"] as string,
                        criticality         = reader["Criticality"] as string,
                        existingTaskCount   = Convert.ToInt32(reader["ExistingTaskCount"])
                    });
                }
            }
            return Ok(new { totalCount = total, pageNumber = pn, pageSize = ps, rows });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "PracticeInstanceController.Gaps failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    /// <summary>
    /// Active implementation-status options for populating the Add/Edit
    /// form dropdown and the "Update Implementation Status" popup.
    /// </summary>
    [HttpGet("implementation-status-options")]
    public async Task<IActionResult> GetImplementationStatusOptions(CancellationToken cancellationToken)
    {
        var options = await workflowService.GetImplementationStatusOptionsAsync(cancellationToken);
        return Ok(options);
    }

    /// <summary>
    /// Active employees of the practice-instance's organization. Used by
    /// the "Assigned To" dropdown in the Add/Edit Implementation Task
    /// modal. Guarantees the selected assignee belongs to the same org
    /// as the instance (front-end and backend both filter by org).
    /// </summary>
    [HttpGet("{id:long}/employees")]
    public async Task<IActionResult> GetEmployees(long id, CancellationToken cancellationToken)
    {
        var list = await workflowService.GetInstanceEmployeesAsync(id, cancellationToken);
        return Ok(list);
    }

    public sealed record UpdateImplementationStatusBody(
        string NewStatusCode,
        string? Remarks,
        DateTime? EffectiveDate,
        long? ActorEmployeeId);

    /// <summary>
    /// Dedicated status-change endpoint. Captures remarks + effective
    /// date + actor and writes an audit-trail row. Used by the
    /// "Update Implementation Status" popup on the Practice Instance row.
    /// </summary>
    [HttpPost("{id:long}/update-implementation-status")]
    public async Task<IActionResult> UpdateImplementationStatus(
        long id,
        [FromBody] UpdateImplementationStatusBody body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (string.IsNullOrWhiteSpace(body.NewStatusCode))
            return BadRequest(new { error = "NewStatusCode is required.", reasonCode = "BAD_REQUEST" });

        var result = await workflowService.UpdateImplementationStatusAsync(
            new UpdateImplementationStatusRequest(
                PracticeInstanceId: id,
                NewStatusCode:      body.NewStatusCode,
                Remarks:            body.Remarks,
                EffectiveDate:      body.EffectiveDate,
                ActorEmployeeId:    body.ActorEmployeeId),
            cancellationToken);

        if (result.Success)
            return Ok(new { newStatusCode = result.NewStatusCode, newStatusId = result.NewStatusId });

        var status = result.ReasonCode switch
        {
            "INSTANCE_NOT_FOUND" => StatusCodes.Status404NotFound,
            "UNKNOWN_STATUS"     => StatusCodes.Status400BadRequest,
            "BAD_REQUEST"        => StatusCodes.Status400BadRequest,
            _                    => StatusCodes.Status500InternalServerError
        };
        return StatusCode(status, new { error = result.Error, reasonCode = result.ReasonCode });
    }

    public sealed record OpenImplementationTaskBody(
        string SubjectTitle,
        string? SubjectDescription,
        long? AssignedToEmployeeId,
        DateTime? TargetDate,
        string? Priority,
        string? Remarks,
        long? ActorEmployeeId,
        string? ActorRoleCode,
        Guid? CorrelationId);

    /// <summary>
    /// Opens an Implementation task for a Practice Instance whose
    /// implementation status is 'Not Implemented'. Idempotent — if an
    /// open Implementation task already exists for this instance, its
    /// id is returned.
    /// </summary>
    [HttpPost("{id:long}/open-implementation-task")]
    public async Task<IActionResult> OpenImplementationTask(
        long id,
        [FromBody] OpenImplementationTaskBody body,
        CancellationToken cancellationToken)
    {
        if (body is null) return BadRequest(new { error = "Request body is required." });
        if (string.IsNullOrWhiteSpace(body.SubjectTitle))
            return BadRequest(new { error = "SubjectTitle is required.", reasonCode = "BAD_REQUEST" });

        var result = await workflowService.OpenImplementationTaskAsync(
            new OpenImplementationTaskRequest(
                PracticeInstanceId:   id,
                SubjectTitle:         body.SubjectTitle,
                SubjectDescription:   body.SubjectDescription,
                AssignedToEmployeeId: body.AssignedToEmployeeId,
                TargetDate:           body.TargetDate,
                Priority:             body.Priority,
                Remarks:              body.Remarks,
                ActorEmployeeId:      body.ActorEmployeeId,
                ActorRoleCode:        body.ActorRoleCode,
                CorrelationId:        body.CorrelationId),
            cancellationToken);

        if (result.Success) return Ok(new { taskId = result.TaskId });

        var status = result.ReasonCode switch
        {
            "INSTANCE_NOT_FOUND"  => StatusCodes.Status404NotFound,
            "STATE_NOT_ALLOWED"   => StatusCodes.Status409Conflict,
            "ILLEGAL_TRANSITION"  => StatusCodes.Status409Conflict,
            "BAD_REQUEST"         => StatusCodes.Status400BadRequest,
            "REASON_REQUIRED"     => StatusCodes.Status400BadRequest,
            _                     => StatusCodes.Status500InternalServerError
        };
        return StatusCode(status, new { error = result.Error, reasonCode = result.ReasonCode });
    }
}
