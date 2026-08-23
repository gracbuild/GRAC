// =====================================================================
// TaskNotificationController (Web tier)  (Task Centre v2, Phase 3)
//
// Thin HTTP proxy from Web -> Api for the SLA notification outbox,
// mirroring Web/Controllers/TaskController.cs: same named HttpClient,
// same session guard, same org-isolation check, same forwarding helpers.
//
// The Web tier never opens its own SQL connection for feature data.
//
// NOTE ON SWEEP
//   The sweep endpoint is proxied because operators need it after fixing
//   a notify-role configuration. It is idempotent, so repeated calls are
//   harmless — but it is a write, and it is org-guarded like every other
//   write here.
// =====================================================================
using System.Net.Http;
using System.Text;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/task-notifications")]
public sealed class TaskNotificationController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<TaskNotificationController> logger) : ControllerBase
{
    private const string ApiBaseKey = "ApiBaseUrl";

    private HttpClient BuildClient()
    {
        var client = httpClientFactory.CreateClient("PracticeManagementApi");
        if (client.BaseAddress is null)
        {
            var url = (configuration[ApiBaseKey] ?? "http://localhost:5045").Trim().TrimEnd('/') + "/";
            client.BaseAddress = new Uri(url);
        }
        return client;
    }

    [HttpGet]
    public async Task<IActionResult> List([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        if (!organizationId.HasValue || organizationId.Value <= 0)
            return BadRequest(new { error = "organizationId is required. Select an organization first." });

        if (!HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });

        return await ForwardGetAsync("api/practice/task-notifications" + (Request.QueryString.Value ?? ""), cancellationToken);
    }

    [HttpGet("counts")]
    public async Task<IActionResult> Counts([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId.HasValue && organizationId.Value > 0
            && !HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });

        return await ForwardGetAsync("api/practice/task-notifications/counts" + (Request.QueryString.Value ?? ""), cancellationToken);
    }

    [HttpPost("sweep")]
    public async Task<IActionResult> Sweep([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId.HasValue && organizationId.Value > 0
            && !HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });

        return await ForwardBodyAsync(HttpMethod.Post,
            "api/practice/task-notifications/sweep" + (Request.QueryString.Value ?? ""), cancellationToken);
    }

    [HttpPost("{id:long}/mark")]
    public Task<IActionResult> Mark(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/task-notifications/{id}/mark", cancellationToken);

    // =================================================================
    // "My Notifications" — session-scoped
    //
    // The recipient is taken from the SESSION, never from the
    // querystring. If the browser could name a recipient, any signed-in
    // user could read the SLA escalations addressed to somebody else —
    // and these messages name overdue work and the people accountable
    // for it. Same pattern as DocumentAcknowledgementController's
    // /my-* routes.
    // =================================================================

    private long? CallerEmployeeId =>
        long.TryParse(HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey), out var id) && id > 0
            ? id
            : null;

    [HttpGet("me")]
    public async Task<IActionResult> MyNotifications(
        [FromQuery] long? organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? notifyEventCode,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var employeeId = CallerEmployeeId;
        if (employeeId is null)
            return StatusCode(StatusCodes.Status403Forbidden, new
            {
                error = "Your account is not mapped to an employee record, so it cannot receive task notifications. Ask a GRAC Admin to link it."
            });

        var qs = $"?recipientEmployeeId={employeeId.Value}&page={Math.Max(1, page)}&pageSize={Math.Clamp(pageSize, 1, 200)}";
        if (organizationId is > 0)                        qs += "&organizationId=" + organizationId.Value;
        if (!string.IsNullOrWhiteSpace(statusCode))       qs += "&statusCode=" + Uri.EscapeDataString(statusCode);
        if (!string.IsNullOrWhiteSpace(notifyEventCode))  qs += "&notifyEventCode=" + Uri.EscapeDataString(notifyEventCode);

        return await ForwardGetAsync("api/practice/task-notifications" + qs, cancellationToken);
    }

    [HttpGet("me/counts")]
    public async Task<IActionResult> MyCounts([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var employeeId = CallerEmployeeId;
        // An unmapped account has no notifications rather than an error —
        // this feeds a badge, and a badge must never break a page.
        if (employeeId is null)
            return Ok(new { pendingCount = 0, sentCount = 0, failedCount = 0, suppressedCount = 0,
                            warningCount = 0, breachCount = 0, escalationCount = 0, unroutableCount = 0 });

        var qs = "?recipientEmployeeId=" + employeeId.Value
               + (organizationId is > 0 ? "&organizationId=" + organizationId.Value : "");

        return await ForwardGetAsync("api/practice/task-notifications/counts" + qs, cancellationToken);
    }

    /// <summary>
    /// Marks the caller's own notifications read. Scoped to the session's
    /// employee id, so one user can never clear another's unread state —
    /// that would destroy the only evidence they had not seen it.
    /// </summary>
    [HttpPost("me/mark-all")]
    public async Task<IActionResult> MyMarkAll(
        [FromQuery] long? organizationId,
        [FromQuery] string? notifyEventCode,
        CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var employeeId = CallerEmployeeId;
        if (employeeId is null)
            return StatusCode(StatusCodes.Status403Forbidden, new
            {
                error = "Your account is not mapped to an employee record."
            });

        var qs = "?recipientEmployeeId=" + employeeId.Value
               + (organizationId is > 0 ? "&organizationId=" + organizationId.Value : "")
               + (!string.IsNullOrWhiteSpace(notifyEventCode) ? "&notifyEventCode=" + Uri.EscapeDataString(notifyEventCode) : "");

        return await ForwardBodyAsync(HttpMethod.Post,
            "api/practice/task-notifications/mark-all" + qs, cancellationToken);
    }

    // =================================================================
    // Forwarding helpers  (identical contract to TaskController's)
    // =================================================================

    private async Task<IActionResult> ForwardGetAsync(string upstreamPath, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });

        try
        {
            var resp = await client.GetAsync(upstreamPath, cancellationToken);
            return await ForwardAsync(resp, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskNotificationController GET proxy failed for {Path}", upstreamPath);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    private async Task<IActionResult> ForwardBodyAsync(HttpMethod method, string upstreamPath, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });

        string bodyJson;
        using (var reader = new StreamReader(Request.Body, Encoding.UTF8))
            bodyJson = await reader.ReadToEndAsync(cancellationToken);
        if (string.IsNullOrWhiteSpace(bodyJson)) bodyJson = "{}";

        using var req = new HttpRequestMessage(method, upstreamPath)
        {
            Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
        };
        try
        {
            var resp = await client.SendAsync(req, cancellationToken);
            return await ForwardAsync(resp, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskNotificationController proxy failed for {Method} {Path}", method, upstreamPath);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    private async Task<IActionResult> ForwardAsync(HttpResponseMessage resp, CancellationToken cancellationToken)
    {
        var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
        return new ContentResult
        {
            Content     = payload,
            ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
            StatusCode  = (int)resp.StatusCode
        };
    }
}
