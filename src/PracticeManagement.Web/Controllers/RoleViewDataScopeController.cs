// =====================================================================
// RoleViewDataScopeController (Web tier)  (migration 415)
//
// Thin proxy to Api /api/practice/roles/{roleId}/view-data-scope for the
// Role Menu Permission section's "Advanced Settings". Same guards as the
// permission matrix it sits under (the gateway's role-menu-permissions
// area): VIEW to read, ADD or EDIT to save; the organization must be one
// the session may act on. The caller is stamped by CallerIdentityHandler.
// =====================================================================
using System.Net.Http.Headers;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/roles/{roleId:long}/view-data-scope")]
public sealed class RoleViewDataScopeController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    PermissionPolicy permissionPolicy,
    ILogger<RoleViewDataScopeController> logger) : ControllerBase
{
    private const string ApiBaseKey = "ApiBaseUrl";
    private static readonly string Area = PermissionAreaMap.For("role-menu-permissions");

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

    private string[] Roles() =>
        (HttpContext.Session.GetString(PracticeSessionIdentity.RolesKey) ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries);

    [HttpGet]
    public async Task<IActionResult> Get(long roleId, [FromQuery] long organizationId, CancellationToken ct)
    {
        if (Guard(organizationId, write: false) is { } error) return error;
        return await ForwardAsync(HttpMethod.Get,
            $"api/practice/roles/{roleId}/view-data-scope?organizationId={organizationId}", null, ct);
    }

    [HttpPost]
    public async Task<IActionResult> Save(long roleId, CancellationToken ct)
    {
        using var reader = new StreamReader(Request.Body);
        var body = await reader.ReadToEndAsync(ct);
        long organizationId = 0;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(string.IsNullOrWhiteSpace(body) ? "{}" : body);
            if (doc.RootElement.TryGetProperty("organizationId", out var org)) org.TryGetInt64(out organizationId);
        }
        catch (System.Text.Json.JsonException) { return BadRequest(new { error = "Invalid request body." }); }
        if (Guard(organizationId, write: true) is { } error) return error;
        return await ForwardAsync(HttpMethod.Post, $"api/practice/roles/{roleId}/view-data-scope", body, ct);
    }

    private IActionResult? Guard(long organizationId, bool write)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        if (organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (!HttpContext.IsOrganizationAllowed(organizationId))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller not authorised for this organization." });
        var roles = Roles();
        var allowed = write
            ? permissionPolicy.IsAllowed(roles, Area, "ADD") || permissionPolicy.IsAllowed(roles, Area, "EDIT")
            : permissionPolicy.IsAllowed(roles, Area, "VIEW");
        return allowed ? null : StatusCode(StatusCodes.Status403Forbidden, new { error = "You do not have access to role permissions." });
    }

    private async Task<IActionResult> ForwardAsync(HttpMethod method, string relativeUrl, string? body, CancellationToken ct)
    {
        try
        {
            using var msg = new HttpRequestMessage(method, relativeUrl);
            if (body is not null)
            {
                msg.Content = new StringContent(body);
                msg.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            }
            var resp    = await BuildClient().SendAsync(msg, ct);
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
            logger.LogError(ex, "RoleViewDataScope proxy failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }
}
