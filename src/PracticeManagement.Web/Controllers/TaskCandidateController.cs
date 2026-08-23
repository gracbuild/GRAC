// =====================================================================
// TaskCandidateController (Web tier)  (Task Centre v2, Phase 2)
//
// Thin HTTP proxy from Web -> Api for the Task Candidate stage, mirroring
// Web/Controllers/TaskController.cs exactly: same named HttpClient, same
// session guard, same org-isolation check, same forwarding helpers.
//
// PROJECT-WIDE RULE (enforced): the Web tier never opens its own SQL
// connection for feature data. Everything goes through the Api tier.
//
// ORG ISOLATION
//   GETs that carry an organizationId are checked against the caller's
//   AllowedOrganizationIds before proxying, so an org employee cannot
//   enumerate another organisation's candidates by editing the
//   querystring. Routes keyed only by a candidate id rely on the Api's
//   own org scoping, exactly as /practice/api/tasks/{id} does.
// =====================================================================
using System.Net.Http;
using System.Text;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/task-candidates")]
public sealed class TaskCandidateController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<TaskCandidateController> logger) : ControllerBase
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

        return await ForwardGetAsync("api/practice/task-candidates" + (Request.QueryString.Value ?? ""), cancellationToken);
    }

    [HttpGet("counts")]
    public async Task<IActionResult> Counts([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId.HasValue && organizationId.Value > 0
            && !HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });

        var qs = organizationId.HasValue ? "?organizationId=" + organizationId.Value : "";
        return await ForwardGetAsync("api/practice/task-candidates/counts" + qs, cancellationToken);
    }

    [HttpGet("{id:long}")]
    public Task<IActionResult> Detail(long id, CancellationToken cancellationToken)
        => ForwardGetAsync($"api/practice/task-candidates/{id}", cancellationToken);

    [HttpGet("source-items")]
    public async Task<IActionResult> SourceItems([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (organizationId.HasValue && organizationId.Value > 0
            && !HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });

        return await ForwardGetAsync("api/practice/task-candidates/source-items" + (Request.QueryString.Value ?? ""), cancellationToken);
    }

    [HttpGet("source-state")]
    public Task<IActionResult> SourceState(CancellationToken cancellationToken)
        => ForwardGetAsync("api/practice/task-candidates/source-state" + (Request.QueryString.Value ?? ""), cancellationToken);

    [HttpPost]
    public Task<IActionResult> Create(CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, "api/practice/task-candidates", cancellationToken);

    [HttpPost("{id:long}/validate")]
    public Task<IActionResult> Validate(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/task-candidates/{id}/validate", cancellationToken);

    [HttpPost("{id:long}/approve")]
    public Task<IActionResult> Approve(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/task-candidates/{id}/approve", cancellationToken);

    [HttpPost("{id:long}/discard")]
    public Task<IActionResult> Discard(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/task-candidates/{id}/discard", cancellationToken);

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
            logger.LogError(ex, "TaskCandidateController GET proxy failed for {Path}", upstreamPath);
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
            logger.LogError(ex, "TaskCandidateController proxy failed for {Method} {Path}", method, upstreamPath);
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
