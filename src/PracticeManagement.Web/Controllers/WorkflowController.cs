// =====================================================================
// WorkflowController (Web tier)  (BRD "Workflow & Event-Driven
// Assurance Engine" v1.0)
//
// Thin HTTP proxy from Web -> Api for every /api/practice/workflow/*
// endpoint. Mirrors the TaskController / GapsController pattern so all
// browser calls stay same-origin under /practice/api/workflow/*.
//
// PROJECT-WIDE RULE preserved: Web tier NEVER opens its own SQL
// connection for feature data. All state comes through the Api tier.
// =====================================================================
using System.Net.Http;
using System.Text;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/workflow")]
public sealed class WorkflowController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<WorkflowController> logger) : ControllerBase
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

    // -----------------------------------------------------------------
    // Generic forwarders. All requests must have a session AND
    // (for org-scoped calls) an organizationId the caller can access.
    // Catch-all route captures everything after /practice/api/workflow/
    // and forwards it to /api/practice/workflow/<same-path>.
    // -----------------------------------------------------------------
    [HttpGet("{**path}")]
    public async Task<IActionResult> ProxyGet(string path, CancellationToken cancellationToken)
    {
        var unauthorized = GuardSession();
        if (unauthorized is not null) return unauthorized;

        // If the querystring names an organizationId, verify caller can see it.
        if (long.TryParse(Request.Query["organizationId"], out var orgId) && orgId > 0)
        {
            if (!HttpContext.IsOrganizationAllowed(orgId))
                return StatusCode(StatusCodes.Status403Forbidden,
                    new { error = "Caller is not authorised for the requested organization." });
        }

        var client = BuildClient();
        var qs     = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        try
        {
            using var getReq = new HttpRequestMessage(HttpMethod.Get, "api/practice/workflow/" + path + qs);
            StampCallerIdentity(getReq);
            var resp    = await client.SendAsync(getReq, cancellationToken);
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
            logger.LogError(ex, "WorkflowController.ProxyGet failed for {Path}", path);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    [HttpPost("{**path}")]
    public async Task<IActionResult> ProxyPost(string path, CancellationToken cancellationToken)
    {
        var unauthorized = GuardSession();
        if (unauthorized is not null) return unauthorized;

        var client = BuildClient();
        string bodyJson;
        using (var reader = new System.IO.StreamReader(Request.Body, Encoding.UTF8))
            bodyJson = await reader.ReadToEndAsync(cancellationToken);
        if (string.IsNullOrWhiteSpace(bodyJson)) bodyJson = "{}";

        // If the body carries organizationId, verify caller can see it.
        // Lightweight, string-based check to avoid deserialising twice.
        if (bodyJson.Contains("\"organizationId\"", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(bodyJson);
                if (doc.RootElement.TryGetProperty("organizationId", out var orgProp)
                    && orgProp.ValueKind == System.Text.Json.JsonValueKind.Number
                    && orgProp.TryGetInt64(out var orgId) && orgId > 0
                    && !HttpContext.IsOrganizationAllowed(orgId))
                {
                    return StatusCode(StatusCodes.Status403Forbidden,
                        new { error = "Caller is not authorised for the requested organization." });
                }
            }
            catch { /* body may not be JSON -- fall through and let Api validate */ }
        }

        using var req = new HttpRequestMessage(HttpMethod.Post, "api/practice/workflow/" + path)
        {
            Content = new System.Net.Http.StringContent(bodyJson, Encoding.UTF8, "application/json")
        };
        StampCallerIdentity(req);
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
            logger.LogError(ex, "WorkflowController.ProxyPost failed for {Path}", path);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // -----------------------------------------------------------------
    // Feature-flag probe: /practice/api/workflow/feature-status?featureCode=screen.workflows&organizationId=...
    // -----------------------------------------------------------------
    [HttpGet("~/practice/api/workflow-feature/status")]
    public async Task<IActionResult> FeatureStatus(
        [FromQuery] string  featureCode,
        [FromQuery] long?   organizationId,
        CancellationToken cancellationToken)
    {
        var unauthorized = GuardSession();
        if (unauthorized is not null) return unauthorized;

        if (string.IsNullOrWhiteSpace(featureCode))
            return BadRequest(new { enabled = false, reason = "featureCode is required." });
        if (!organizationId.HasValue || organizationId.Value <= 0)
            return BadRequest(new { enabled = false, reason = "organizationId is required." });
        if (!HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden, new { enabled = false, reason = "Caller is not authorised for the requested organization." });

        var client = BuildClient();
        var qs = "?featureCode=" + Uri.EscapeDataString(featureCode) + "&organizationId=" + organizationId.Value;
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
            logger.LogWarning(ex, "WorkflowController.FeatureStatus proxy failed; failing closed.");
            return Ok(new { enabled = false, organizationId, reason = "Probe error; fail closed." });
        }
    }

    private IActionResult? GuardSession()
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });
        return null;
    }

    /// <summary>
    /// Puts the caller's identity on the upstream request as headers, read
    /// from the session and nowhere else.
    ///
    /// The Resolve list shows "instances I own", which means the API has to
    /// know who is asking. Taking that from the request body or querystring
    /// would let anyone list somebody else's work by editing one number.
    /// These headers are set here, on the server, after the session check --
    /// whatever the browser sent under the same names is replaced, so a
    /// forged header is simply overwritten rather than trusted.
    ///
    /// Admin means an organization-wide or global data scope, matching the
    /// isEmployeeScope test the front end already uses to decide whether a
    /// user sees one release or all of them.
    /// </summary>
    private void StampCallerIdentity(HttpRequestMessage request)
    {
        request.Headers.Remove(CallerEmployeeHeader);
        request.Headers.Remove(CallerAdminHeader);

        var employeeId = HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey);
        if (long.TryParse(employeeId, out var id) && id > 0)
            request.Headers.TryAddWithoutValidation(CallerEmployeeHeader, id.ToString());

        var dataScope = (HttpContext.Session.GetString(PracticeSessionIdentity.DataScopeKey) ?? "ORGANIZATION")
            .Trim().ToUpperInvariant();
        var isAdmin = dataScope is "GLOBAL" or "ORGANIZATION";
        request.Headers.TryAddWithoutValidation(CallerAdminHeader, isAdmin ? "1" : "0");
    }

    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";
    private const string CallerAdminHeader    = "X-PM-Caller-Is-Admin";
}
