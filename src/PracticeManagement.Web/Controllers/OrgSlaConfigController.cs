// =====================================================================
// OrgSlaConfigController (Web tier)
//
// Organization SLA Configuration -- thin HTTP proxy.
//
// Route: /practice/api/org-sla/*  ->  /api/practice/org-sla/*  (API tier)
//
// Mirrors OrgAssuranceController exactly:
//   * Session-guarded via GuardSession()
//   * Cross-org access blocked via HttpContext.IsOrganizationAllowed
//     for any query parameter OR body organizationId
//   * Web tier NEVER opens its own SQL connection
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/org-sla")]
public sealed class OrgSlaConfigController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<OrgSlaConfigController> logger) : ControllerBase
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
    // Generic GET proxy.
    // -----------------------------------------------------------------
    [HttpGet("{**path}")]
    public async Task<IActionResult> ProxyGet(string path, CancellationToken cancellationToken)
    {
        var unauthorized = GuardSession();
        if (unauthorized is not null) return unauthorized;

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
            var resp    = await client.GetAsync("api/practice/org-sla/" + path + qs, cancellationToken);
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
            logger.LogError(ex, "OrgSlaConfigController.ProxyGet failed for {Path}", path);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // -----------------------------------------------------------------
    // Generic POST proxy.
    // -----------------------------------------------------------------
    [HttpPost("{**path}")]
    public async Task<IActionResult> ProxyPost(string path, CancellationToken cancellationToken)
    {
        var unauthorized = GuardSession();
        if (unauthorized is not null) return unauthorized;

        Request.EnableBuffering();
        string bodyText;
        using (var reader = new StreamReader(Request.Body, leaveOpen: true))
        {
            bodyText = await reader.ReadToEndAsync(cancellationToken);
            Request.Body.Position = 0;
        }

        if (!string.IsNullOrWhiteSpace(bodyText))
        {
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(bodyText);
                if (doc.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object &&
                    doc.RootElement.TryGetProperty("organizationId", out var orgProp) &&
                    orgProp.TryGetInt64(out var orgId) && orgId > 0)
                {
                    if (!HttpContext.IsOrganizationAllowed(orgId))
                        return StatusCode(StatusCodes.Status403Forbidden,
                            new { error = "Caller is not authorised for the requested organization." });
                }
            }
            catch (System.Text.Json.JsonException)
            {
                /* not JSON -- let the API tier handle it. */
            }
        }

        var client = BuildClient();
        try
        {
            using var content = new StringContent(bodyText,
                System.Text.Encoding.UTF8,
                Request.ContentType ?? "application/json");
            var resp    = await client.PostAsync("api/practice/org-sla/" + path, content, cancellationToken);
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
            logger.LogError(ex, "OrgSlaConfigController.ProxyPost failed for {Path}", path);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    private IActionResult? GuardSession()
    {
        var token = HttpContext.Session.GetString(PracticeSessionIdentity.TokenKey);
        return string.IsNullOrWhiteSpace(token)
            ? Unauthorized(new { error = "Session expired. Please sign in again." })
            : null;
    }
}
