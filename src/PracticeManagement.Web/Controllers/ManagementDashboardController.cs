// =====================================================================
// ManagementDashboardController (Web tier)  (migrations 413 / 414)
//
// Thin proxy to Api /api/practice/management-dashboard/{module}, same
// contract as RepositoryChangeController: session guard, organization
// isolation, and the caller (employee id + admin flag) stamped from the
// SESSION into X-PM-Caller-*, overwriting anything the browser sent.
//
// Access follows the page: VIEW on the dashboard's own "Dashboard" submenu
// (416) and on at least one child screen it summarises
// (ManagementDashboards.CanOpen).
// =====================================================================
using System.Net.Http;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Models;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/management-dashboard")]
public sealed class ManagementDashboardController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    PermissionPolicy permissionPolicy,
    ILogger<ManagementDashboardController> logger) : ControllerBase
{
    private const string ApiBaseKey           = "ApiBaseUrl";
    private const string CallerEmployeeHeader = "X-PM-Caller-Employee-Id";
    private const string CallerAdminHeader    = "X-PM-Caller-Is-Admin";

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

    private long? CallerEmployeeId =>
        long.TryParse(HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey), out var id) && id > 0
            ? id
            : null;

    private string[] Roles() =>
        (HttpContext.Session.GetString(PracticeSessionIdentity.RolesKey) ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries);

    [HttpGet("{module}")]
    public async Task<IActionResult> Get(string module, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        if (!long.TryParse(Request.Query["organizationId"], out var organizationId) || organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (!HttpContext.IsOrganizationAllowed(organizationId))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller not authorised for this organization." });

        var screenKey = $"{module}-dashboard";
        if (!ManagementDashboards.IsDashboard(screenKey))
            return NotFound(new { error = $"Unknown dashboard '{module}'." });
        var roles = Roles();
        if (!ManagementDashboards.CanOpen(screenKey,
                key => permissionPolicy.IsAllowed(roles, key, "VIEW"),
                child => permissionPolicy.IsAllowed(roles, PracticeController.ScreenPermissionArea(child), "VIEW")))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "You do not have access to this dashboard." });

        var client = BuildClient();
        var relativeUrl = $"api/practice/management-dashboard/{Uri.EscapeDataString(module)}?organizationId={organizationId}";
        try
        {
            using var msg = new HttpRequestMessage(HttpMethod.Get, relativeUrl);
            StampCaller(msg);
            var resp    = await client.SendAsync(msg, ct);
            var payload = await resp.Content.ReadAsStringAsync(ct);
            return new ContentResult
            {
                Content     = payload,
                ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
                StatusCode  = (int)resp.StatusCode
            };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "ManagementDashboard proxy failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // Set from the session, overwriting whatever the browser sent. Same
    // admin rule as RepositoryChangeController / WorkflowController.
    private void StampCaller(HttpRequestMessage request)
    {
        request.Headers.Remove(CallerEmployeeHeader);
        request.Headers.Remove(CallerAdminHeader);

        if (CallerEmployeeId is { } id)
            request.Headers.TryAddWithoutValidation(CallerEmployeeHeader, id.ToString());

        var dataScope = (HttpContext.Session.GetString(PracticeSessionIdentity.DataScopeKey) ?? "ORGANIZATION")
            .Trim().ToUpperInvariant();
        var isAdmin = dataScope is "GLOBAL" or "ORGANIZATION";
        request.Headers.TryAddWithoutValidation(CallerAdminHeader, isAdmin ? "1" : "0");
    }
}
