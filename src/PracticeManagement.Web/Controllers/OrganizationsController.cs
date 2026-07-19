// =====================================================================
// OrganizationsController (Web tier)  (charter §7 cross-cut)
//
// Route: /practice/api/organizations/...
//
// Thin HTTP proxy from Web -> Api for the Organization filter used by
// Task Center and every other organization-scoped Practice Management
// screen. Follows the project-wide rule: the Web tier does not open its
// own SQL connection — it just forwards to the Api which owns the
// single shared connection string.
//
// The identity (data scope, primary org, email) is read from the caller's
// session here and passed to the Api as query parameters. The Api then
// runs the correct query (GLOBAL → all Active orgs, otherwise
// user_organization_map ∪ primary org).
// =====================================================================
using System.Net.Http;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/organizations")]
public sealed class OrganizationsController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<OrganizationsController> logger) : ControllerBase
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
    /// GET /practice/api/organizations/allowed
    /// Returns the organizations the signed-in user is allowed to work with.
    /// GRAC Admin (DataScope=GLOBAL) → every Active organization.
    /// Everyone else → primary org + user_organization_map entries.
    /// </summary>
    [HttpGet("allowed")]
    public async Task<IActionResult> Allowed(CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var isGlobal = HttpContext.IsGlobalScope();
        var primary  = HttpContext.PrimaryOrganizationId();
        var email    = HttpContext.Email();
        var employee = HttpContext.EmployeeCode();

        var qs = "?isGlobalScope=" + (isGlobal ? "true" : "false");
        if (!string.IsNullOrWhiteSpace(email))    qs += "&email="        + Uri.EscapeDataString(email);
        if (!string.IsNullOrWhiteSpace(employee)) qs += "&employeeCode=" + Uri.EscapeDataString(employee);
        if (primary.HasValue)                     qs += "&primaryOrganizationId=" + primary.Value;

        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });

        try
        {
            var resp    = await client.GetAsync("api/practice/organizations/allowed" + qs, cancellationToken);
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
            logger.LogError(ex, "OrganizationsController.Allowed proxy failed");
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    /// <summary>
    /// GET /practice/api/organizations/{orgId}/employees
    /// Active employees of the given organization. Used by Task Center's
    /// "New Task" modal to populate the Assigned To dropdown.
    /// </summary>
    [HttpGet("{organizationId:long}/employees")]
    public async Task<IActionResult> Employees(long organizationId, CancellationToken cancellationToken)
    {
        var client = BuildClient();
        try
        {
            var resp    = await client.GetAsync($"api/practice/organizations/{organizationId}/employees", cancellationToken);
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
            logger.LogError(ex, "OrganizationsController.Employees proxy failed for org {OrgId}", organizationId);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }
}
