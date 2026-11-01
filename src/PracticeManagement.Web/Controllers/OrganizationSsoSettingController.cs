// =====================================================================
// OrganizationSsoSettingController (Web tier)  (migration 466)
//
// Thin proxy to Api /api/practice/org-sso for Organization Administration
// -> Organization tab -> "Single Sign-On" (moved from Organization Setup,
// 2026-10-13). Same guards as the screen it sits on
// (organization-administration): VIEW to read, ADD or EDIT to save; the
// organization must be one the session may act on. The caller is stamped
// by CallerIdentityHandler. Shape copied from RoleViewDataScopeController.
//
// Migration 467: POST approve-user { organizationId, employeeId } -- the
// Users tab "Approve" action for a user created by SSO that waits for
// approval. Same guard as Save (the Users tab sits under the same
// organization-administration area, PermissionAreaMap "users").
// =====================================================================
using System.Net.Http.Headers;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/org-sso")]
public sealed class OrganizationSsoSettingController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    PermissionPolicy permissionPolicy,
    ILogger<OrganizationSsoSettingController> logger) : ControllerBase
{
    private const string ApiBaseKey = "ApiBaseUrl";
    private static readonly string Area = PermissionAreaMap.For("organization-administration");

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
    public async Task<IActionResult> Get([FromQuery] long organizationId, CancellationToken ct)
    {
        if (Guard(organizationId, write: false) is { } error) return error;
        return await ForwardAsync(HttpMethod.Get, $"api/practice/org-sso?organizationId={organizationId}", null, ct);
    }

    [HttpPost]
    public async Task<IActionResult> Save(CancellationToken ct)
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
        return await ForwardAsync(HttpMethod.Post, "api/practice/org-sso", body, ct);
    }

    [HttpPost("approve-user")]
    public async Task<IActionResult> ApproveUser(CancellationToken ct)
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
        return await ForwardAsync(HttpMethod.Post, "api/practice/org-sso/approve-user", body, ct);
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
        return allowed ? null : StatusCode(StatusCodes.Status403Forbidden, new { error = "You do not have access to Organization Administration." });
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
            logger.LogError(ex, "Organization SSO setting proxy failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }
}
