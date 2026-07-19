// =====================================================================
// GapsController (Web tier)
//
// Thin HTTP proxy for the Gap Center feature-flag probe. The data grid
// itself is served by the pre-existing /practice/api/instances/gaps
// endpoint (PracticeInstanceWorkflowController.Gaps), which Gap Center
// reuses unchanged. This controller only exists so the Gap Center
// partial can probe `screen.gaps` on the same origin (no CORS, no
// direct Api exposure).
//
// PROJECT-WIDE RULE preserved (see comment on Web TaskController): the
// Web tier does NOT open its own SQL connection for feature data — all
// state comes through the Api tier.
// =====================================================================
using System.Net.Http;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/gaps")]
public sealed class GapsController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<GapsController> logger) : ControllerBase
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

    /// <summary>
    /// UI probe — is Gap Center enabled for the given organization?
    /// Mirrors TaskController.FeatureStatus so the two modules share
    /// the same authorization + fail-closed semantics.
    /// </summary>
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

        var qs = "?featureCode=screen.gaps&organizationId=" + organizationId.Value;
        try
        {
            var resp    = await client.GetAsync("api/practice/feature-flags/status" + qs, cancellationToken);
            var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
            return new ContentResult
            {
                Content     = payload,
                ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
                StatusCode  = (int)resp.StatusCode
            };
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "GapsController.FeatureStatus proxy failed; failing closed.");
            return Ok(new { enabled = false, organizationId, reason = "Probe error; fail closed." });
        }
    }

    // -----------------------------------------------------------------
    // Custom Gap endpoints -- proxies for /api/practice/gaps/custom/*.
    // The browser calls /practice/api/gaps/custom (list) and POSTs the
    // same path (open). Every request must carry organizationId and
    // must target an authorised org (same guard as tasks).
    // -----------------------------------------------------------------
    [HttpGet("custom")]
    public async Task<IActionResult> CustomList([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });
        if (!organizationId.HasValue || organizationId.Value <= 0)
            return BadRequest(new { error = "organizationId is required. Select an organization first." });
        if (!HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });

        var client = BuildClient();
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        try
        {
            var resp    = await client.GetAsync("api/practice/gaps/custom" + qs, cancellationToken);
            var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
            return new ContentResult
            {
                Content     = payload,
                ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
                StatusCode  = (int)resp.StatusCode
            };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "GapsController.CustomList proxy failed");
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    [HttpPost("custom")]
    public async Task<IActionResult> CustomOpen(CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });
        return await ForwardBodyAsync(HttpMethod.Post, "api/practice/gaps/custom", cancellationToken);
    }

    [HttpPost("custom/{id:long}/close")]
    public Task<IActionResult> CustomClose(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/gaps/custom/{id}/close", cancellationToken);

    private async Task<IActionResult> ForwardBodyAsync(HttpMethod method, string upstreamPath, CancellationToken cancellationToken)
    {
        var client = BuildClient();
        string bodyJson;
        using (var reader = new System.IO.StreamReader(Request.Body, System.Text.Encoding.UTF8))
            bodyJson = await reader.ReadToEndAsync(cancellationToken);
        if (string.IsNullOrWhiteSpace(bodyJson)) bodyJson = "{}";

        using var req = new HttpRequestMessage(method, upstreamPath)
        {
            Content = new System.Net.Http.StringContent(bodyJson, System.Text.Encoding.UTF8, "application/json")
        };
        try
        {
            var resp    = await client.SendAsync(req, cancellationToken);
            var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
            return new ContentResult
            {
                Content     = payload,
                ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
                StatusCode  = (int)resp.StatusCode
            };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "GapsController proxy failed for {Method} {Path}", method, upstreamPath);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }
}
