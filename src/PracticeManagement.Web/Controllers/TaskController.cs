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
//
// TASK CENTRE v2 (BRD 16 Aug 2026)
//   The v2 routes are grouped at the bottom. They follow the same
//   pattern as the originals: GETs that carry an organizationId are
//   guarded by session + IsOrganizationAllowed; everything else is a
//   straight body forward, because the Api tier owns the governance
//   rules and re-implementing them here would create two sources of
//   truth for the same BRD clause.
// =====================================================================
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
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

    // =================================================================
    // Task Centre v2  (migrations 192-196)
    // =================================================================

    /// <summary>
    /// Operational detail view (BRD §16). Session-guarded but NOT
    /// org-guarded on the querystring: the caller supplies only a task
    /// id, and the Api resolves the organisation from the row itself.
    /// Cross-org isolation for detail reads is enforced by the Api's own
    /// org scoping, exactly as it is for /{id}/close today.
    /// </summary>
    [HttpGet("{id:long}")]
    public Task<IActionResult> Detail(long id, CancellationToken cancellationToken)
        => ForwardGetAsync($"api/practice/tasks/{id}", cancellationToken);

    [HttpGet("{id:long}/eligibility")]
    public Task<IActionResult> Eligibility(long id, CancellationToken cancellationToken)
        => ForwardGetAsync($"api/practice/tasks/{id}/eligibility", cancellationToken);

    /// <summary>Source -> Tasks panel (BRD §15). Called by the Gap /
    /// Exception / Risk / Assurance detail screens.</summary>
    [HttpGet("by-source")]
    public async Task<IActionResult> BySource([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        if (organizationId.HasValue && organizationId.Value > 0
            && !HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });

        return await ForwardGetAsync("api/practice/tasks/by-source" + (Request.QueryString.Value ?? ""), cancellationToken);
    }

    /// <summary>Owner ladder preview (BRD §6). organizationId is required
    /// and org-guarded — the ladder reads that organisation's ownership
    /// master data.</summary>
    [HttpGet("owner-resolve")]
    public async Task<IActionResult> OwnerResolve([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        if (!organizationId.HasValue || organizationId.Value <= 0)
            return BadRequest(new { error = "organizationId is required." });

        if (!HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });

        return await ForwardGetAsync("api/practice/tasks/owner-resolve" + (Request.QueryString.Value ?? ""), cancellationToken);
    }

    [HttpPost("{id:long}/priority")]
    public Task<IActionResult> ChangePriority(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/priority", cancellationToken);

    [HttpPost("{id:long}/sla-extension")]
    public Task<IActionResult> RequestSlaExtension(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/sla-extension", cancellationToken);

    [HttpPost("{id:long}/children")]
    public Task<IActionResult> CreateChild(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/children", cancellationToken);

    [HttpPost("{id:long}/complete")]
    public Task<IActionResult> Complete(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/complete", cancellationToken);

    [HttpPost("{id:long}/activity")]
    public Task<IActionResult> AddActivity(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/activity", cancellationToken);

    [HttpPost("requests/{exceptionRequestId:long}/approve-sla-extension")]
    public Task<IActionResult> ApproveSlaExtension(long exceptionRequestId, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/requests/{exceptionRequestId}/approve-sla-extension", cancellationToken);

    [HttpPost("requests/{exceptionRequestId:long}/approve-priority-reduction")]
    public Task<IActionResult> ApprovePriorityReduction(long exceptionRequestId, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/requests/{exceptionRequestId}/approve-priority-reduction", cancellationToken);

    /// <summary>
    /// Evidence upload (BRD §16). Streams the multipart body straight
    /// through rather than re-parsing it: the Web tier has no business
    /// inspecting file content, and buffering a 50 MB upload twice is
    /// wasteful.
    /// </summary>
    [HttpPost("{id:long}/attachments")]
    [RequestSizeLimit(52_428_800)] // 50 MB — matches the Api-side limit
    public async Task<IActionResult> UploadAttachment(long id, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });

        try
        {
            using var content = new StreamContent(Request.Body);
            if (!string.IsNullOrWhiteSpace(Request.ContentType)
                && MediaTypeHeaderValue.TryParse(Request.ContentType, out var mediaType))
                content.Headers.ContentType = mediaType;

            using var req = new HttpRequestMessage(HttpMethod.Post, $"api/practice/tasks/{id}/attachments")
            {
                Content = content
            };

            var resp = await client.SendAsync(req, cancellationToken);
            return await ForwardAsync(resp, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController.UploadAttachment proxy failed for task {TaskId}", id);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    /// <summary>Evidence download (BRD §16). Binary, so it cannot go
    /// through ForwardAsync's string path.</summary>
    [HttpGet("attachments/{attachmentId:long}")]
    public async Task<IActionResult> DownloadAttachment(long attachmentId, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });

        try
        {
            var resp = await client.GetAsync($"api/practice/tasks/attachments/{attachmentId}", cancellationToken);
            if (!resp.IsSuccessStatusCode)
                return await ForwardAsync(resp, cancellationToken);

            var bytes       = await resp.Content.ReadAsByteArrayAsync(cancellationToken);
            var contentType = resp.Content.Headers.ContentType?.ToString() ?? "application/octet-stream";
            var fileName    = resp.Content.Headers.ContentDisposition?.FileNameStar
                           ?? resp.Content.Headers.ContentDisposition?.FileName?.Trim('"')
                           ?? $"attachment-{attachmentId}";

            return File(bytes, contentType, fileName);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController.DownloadAttachment proxy failed for attachment {AttachmentId}", attachmentId);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // =================================================================
    // Forwarding helpers
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
            logger.LogError(ex, "TaskController GET proxy failed for {Path}", upstreamPath);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

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
