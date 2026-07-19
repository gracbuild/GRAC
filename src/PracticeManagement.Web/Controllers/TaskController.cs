// =====================================================================
// TaskController (Web tier)  (charter §12.1.3 / §12.1.6)
//
// Thin HTTP proxy from Web -> Api for the Task Center. Kept independent
// of PracticeManagementGatewayController (which is scoped to secure
// query/manage envelopes for existing entities).
//
// Charter §7 API convention preserved: /api/practice/{feature}/{action}
// on the Api side; the Web tier exposes /practice/api/{feature}/{action}
// so the browser can call it without CORS or the Api being publicly
// reachable.
//
// PROJECT-WIDE RULE (enforced):
//   The Web tier NEVER opens its own SQL connection for feature/task
//   data. All DB access goes through the Api tier, which owns the single
//   shared connection string via
//   PracticeManagement.Api.Infrastructure.SqlConnectionStringResolver.
//   (The only Web-tier exception is PracticeLoginService, needed for
//   login itself, before an Api token exists.) The earlier direct SQL
//   call from FeatureStatus was a temporary shortcut that violated this
//   rule and is now removed — FeatureStatus proxies to
//   /api/practice/feature-flags/status.
// =====================================================================
using System.Net;
using System.Net.Http;
using System.Text;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/tasks")]
public sealed class TaskController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<TaskController> logger) : ControllerBase
{
    // Uses the same ApiBaseUrl config key SecurePracticeClient already reads
    // (default localhost:5045). Zero appsettings changes needed.
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

    /// <summary>
    /// UI probe — is Task Center enabled for the given organization?
    ///
    /// organizationId MUST be supplied by the caller (the browser picks it
    /// from the Organization filter). We validate that the caller is
    /// authorised to operate on that org (GLOBAL scope OR the id is in the
    /// user's AllowedOrganizationIds) before proxying to the Api. This
    /// prevents an org employee from probing feature state for another
    /// organisation by hand-crafting the querystring.
    /// </summary>
    [HttpGet("counts")]
    public async Task<IActionResult> Counts([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        var client = BuildClient();
        try
        {
            var qs = organizationId.HasValue ? "?organizationId=" + organizationId.Value : "";
            var resp    = await client.GetAsync("api/practice/tasks/counts" + qs, cancellationToken);
            var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
            return new ContentResult { Content = payload, ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json", StatusCode = (int)resp.StatusCode };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController.Counts proxy failed");
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    [HttpGet("feature-status")]
    public async Task<IActionResult> FeatureStatus(
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        if (!organizationId.HasValue || organizationId.Value <= 0)
            return BadRequest(new
            {
                enabled = false,
                organizationId = (long?)null,
                reason = "organizationId is required. Select an organization first."
            });

        if (!HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden, new
            {
                enabled = false,
                organizationId,
                reason  = "Caller is not authorised for the requested organization."
            });

        var client = BuildClient();
        if (client.BaseAddress is null)
            return Ok(new { enabled = false, organizationId, reason = "PracticeManagementApi:BaseUrl is not configured." });

        var qs = "?featureCode=screen.tasks&organizationId=" + organizationId.Value;
        try
        {
            var resp = await client.GetAsync("api/practice/feature-flags/status" + qs, cancellationToken);
            return await ForwardAsync(resp, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "TaskController.FeatureStatus proxy failed; failing closed.");
            return Ok(new { enabled = false, organizationId, reason = "Probe error; fail closed." });
        }
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

        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });

        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        try
        {
            var resp = await client.GetAsync("api/practice/tasks" + qs, cancellationToken);
            return await ForwardAsync(resp, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController.List proxy failed");
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> Create(CancellationToken cancellationToken)
    {
        return await ForwardBodyAsync(HttpMethod.Post, "api/practice/tasks", cancellationToken);
    }

    [HttpPost("{id:long}/assign")]
    public Task<IActionResult> Assign(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/assign", cancellationToken);

    [HttpPost("{id:long}/transition")]
    public Task<IActionResult> Transition(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/transition", cancellationToken);

    [HttpPost("{id:long}/close")]
    public Task<IActionResult> Close(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/close", cancellationToken);

    private async Task<IActionResult> ForwardBodyAsync(HttpMethod method, string upstreamPath, CancellationToken cancellationToken)
    {
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
            logger.LogError(ex, "TaskController proxy failed for {Method} {Path}", method, upstreamPath);
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
