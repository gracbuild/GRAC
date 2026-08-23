// =====================================================================
// OrgAssuranceController (Web tier)
//
// Phase 2 Assurance Management -- Stage 1 thin HTTP proxy.
//
// Route: /practice/api/org-assurance/*  -> forwards to
//        /api/practice/org-assurance/*  on the API tier.
//
// Mirrors WorkflowController (Web) exactly:
//   * Session-guarded via GuardSession() (defined in
//     PracticeManagement.Web.Security).
//   * Same-origin-only browser calls.
//   * Cross-org access blocked via HttpContext.IsOrganizationAllowed
//     for any query parameter carrying an organizationId.
//
// Web tier NEVER opens its own SQL connection for feature data -- all
// state flows through the API tier.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/org-assurance")]
public sealed class OrgAssuranceController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<OrgAssuranceController> logger) : ControllerBase
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
    // Generic GET proxy. Catch-all path forwards to
    // /api/practice/org-assurance/<same-path>.
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
            var resp    = await client.GetAsync("api/practice/org-assurance/" + path + qs, cancellationToken);
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
            logger.LogError(ex, "OrgAssuranceController.ProxyGet failed for {Path}", path);
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

        // Buffer body so we can peek the organizationId while still forwarding it.
        Request.EnableBuffering();
        string bodyText;
        using (var reader = new StreamReader(Request.Body, leaveOpen: true))
        {
            bodyText = await reader.ReadToEndAsync(cancellationToken);
            Request.Body.Position = 0;
        }

        // Best-effort org enforcement -- reject a mismatched body organizationId.
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
            var resp    = await client.PostAsync("api/practice/org-assurance/" + path, content, cancellationToken);
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
            logger.LogError(ex, "OrgAssuranceController.ProxyPost failed for {Path}", path);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // -----------------------------------------------------------------
    // Generic DELETE proxy (soft-delete endpoints for Question Sets /
    // Questions land here). Same session + org-authorization pattern
    // as ProxyGet -- no request body expected.
    // -----------------------------------------------------------------
    [HttpDelete("{**path}")]
    public async Task<IActionResult> ProxyDelete(string path, CancellationToken cancellationToken)
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
            var resp    = await client.DeleteAsync("api/practice/org-assurance/" + path + qs, cancellationToken);
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
            logger.LogError(ex, "OrgAssuranceController.ProxyDelete failed for {Path}", path);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // -----------------------------------------------------------------
    // Session guard -- mirrors WorkflowController pattern.
    // -----------------------------------------------------------------
    private IActionResult? GuardSession()
    {
        var token = HttpContext.Session.GetString(PracticeSessionIdentity.TokenKey);
        return string.IsNullOrWhiteSpace(token)
            ? Unauthorized(new { error = "Session expired. Please sign in again." })
            : null;
    }
}
