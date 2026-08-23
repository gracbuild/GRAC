// =====================================================================
// OrgRoleLookupController (Web tier)
//
// Thin HTTP proxy for /api/practice/org-roles.
// Used by the Role -> Employee two-step picker across the Assurance
// and Gap Center partials.
//
// Same session + organization-authorization pattern as the other Web
// proxies in this codebase.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/org-roles")]
public sealed class OrgRoleLookupController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<OrgRoleLookupController> logger) : ControllerBase
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

    [HttpGet("{**path}")]
    public async Task<IActionResult> Proxy(string? path, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        if (long.TryParse(Request.Query["organizationId"], out var orgId) && orgId > 0)
        {
            if (!HttpContext.IsOrganizationAllowed(orgId))
                return StatusCode(StatusCodes.Status403Forbidden,
                    new { error = "Caller is not authorised for the requested organization." });
        }
        else
        {
            return BadRequest(new { error = "organizationId is required." });
        }

        var client = BuildClient();
        var qs     = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        var suffix = string.IsNullOrWhiteSpace(path) ? "" : "/" + path;
        try
        {
            var resp    = await client.GetAsync("api/practice/org-roles" + suffix + qs, cancellationToken);
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
            logger.LogError(ex, "OrgRoleLookupController proxy failed for {Path}", path);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }
}
