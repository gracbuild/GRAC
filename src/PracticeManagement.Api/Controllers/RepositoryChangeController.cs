// =====================================================================
// RepositoryChangeController  (statement subscription copy model, phase 3)
//
// Route: /api/practice/repository-changes/...
//   GET  /                         pending (or any status) changes of an organization
//   GET  /counts                   pending count per release (badge)
//   POST /{id}/decision            approve / reject one change
//   POST /decisions                the same decision for several changes
//   GET  /notifications            one recipient's open notices (Home)
//   POST /notifications/mark-read  the recipient opened the review page
//
// No "detect now" endpoint: detection is scheduled only (decision 9) --
// RepositoryChangeDetectWorker, or SQL Agent.
//
// The caller (employee id, admin flag) comes from the headers the Web tier
// stamps from the SESSION (X-PM-Caller-*), never from the browser.
// sp_repository_change_apply enforces release owner / organization admin.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/repository-changes")]
public sealed class RepositoryChangeController(
    IRepositoryChangeService changeService,
    ILogger<RepositoryChangeController> logger) : ControllerBase
{
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";
    private const string CallerAdminHeader    = "X-PM-Caller-Is-Admin";

    private long? CallerEmployeeId =>
        long.TryParse(Request.Headers[CallerEmployeeHeader].ToString(), out var id) && id > 0 ? id : null;

    private bool CallerIsAdmin =>
        Request.Headers[CallerAdminHeader].ToString() is "1" or "true" or "True";

    private string Actor =>
        CallerEmployeeId is { } id ? $"employee:{id}" : "system";

    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long organizationId,
        [FromQuery] long? releaseId,
        [FromQuery] string? status = "Pending",
        [FromQuery] int pageNumber = 1,
        [FromQuery] int pageSize = 50,
        CancellationToken cancellationToken = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            var rows = await changeService.ListAsync(organizationId, releaseId, status, pageNumber, pageSize, cancellationToken);
            return Ok(new
            {
                data = rows,
                totalRows = rows.Count > 0 && rows[0].TryGetValue("TotalRows", out var t) ? Convert.ToInt32(t) : 0,
                isAdmin = CallerIsAdmin,
                callerEmployeeId = CallerEmployeeId
            });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RepositoryChangeController.List failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("counts")]
    public async Task<IActionResult> Counts([FromQuery] long organizationId, CancellationToken cancellationToken)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        try
        {
            return Ok(new { data = await changeService.CountsAsync(organizationId, cancellationToken) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RepositoryChangeController.Counts failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("{id:long}/decision")]
    public async Task<IActionResult> Decide(long id, [FromBody] RepositoryChangeDecisionRequest body, CancellationToken cancellationToken)
    {
        if (body is null || string.IsNullOrWhiteSpace(body.Decision))
            return BadRequest(new { error = "decision is required (Approve or Reject)." });

        var result = await changeService.DecideAsync(id, body.Decision.Trim(), body.Remark,
            CallerEmployeeId, CallerIsAdmin, Actor, cancellationToken);
        return result.Success ? Ok(result) : BadRequest(new { error = result.Message, changeId = id });
    }

    [HttpPost("decisions")]
    public async Task<IActionResult> DecideMany([FromBody] RepositoryChangeBulkDecisionRequest body, CancellationToken cancellationToken)
    {
        if (body?.ChangeIds is not { Length: > 0 } || string.IsNullOrWhiteSpace(body.Decision))
            return BadRequest(new { error = "changeIds and decision are required." });

        // Ids arrive in the order the review page lists them (repository
        // order), which is the order the copies depend on.
        var results = new List<RepositoryChangeDecisionResult>();
        foreach (var changeId in body.ChangeIds.Distinct())
            results.Add(await changeService.DecideAsync(changeId, body.Decision.Trim(), body.Remark,
                CallerEmployeeId, CallerIsAdmin, Actor, cancellationToken));

        return Ok(new
        {
            succeeded = results.Count(r => r.Success),
            failed = results.Count(r => !r.Success),
            results
        });
    }

    [HttpGet("notifications")]
    public async Task<IActionResult> Notifications([FromQuery] long recipientEmployeeId, [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (recipientEmployeeId <= 0) return BadRequest(new { error = "recipientEmployeeId is required." });
        try
        {
            return Ok(new { data = await changeService.NotificationsAsync(recipientEmployeeId, organizationId, cancellationToken) });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RepositoryChangeController.Notifications failed");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpPost("notifications/mark-read")]
    public async Task<IActionResult> MarkRead([FromQuery] long recipientEmployeeId, [FromQuery] long organizationId, CancellationToken cancellationToken)
    {
        if (recipientEmployeeId <= 0 || organizationId <= 0)
            return BadRequest(new { error = "recipientEmployeeId and organizationId are required." });
        var marked = await changeService.MarkNotificationsReadAsync(recipientEmployeeId, organizationId, cancellationToken);
        return Ok(new { markedCount = marked });
    }
}
