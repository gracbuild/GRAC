// =====================================================================
// SubscriptionRequestController (Web tier)  (migration 511)
//
// Thin proxy to Api /api/practice/subscription-requests for Organization
// Management -> Subscription Requests: the platform-side approval of the
// requests organizations raise from Add Release -> Subscribe from
// Repository (406). The EvidenceCenterController pattern:
//   * session guard;
//   * menu permission on the "subscription-requests" screen:
//       GET  /                 VIEW
//       POST /{id}/decision    APPROVE (Approve and Reject alike)
//   * GLOBAL data scope. A request belongs to ANOTHER organization, and
//     approving it subscribes that organization -- a platform decision, not
//     an organization's own (an organization admin must not approve its own
//     request). GLOBAL is the scope that already means "every organization"
//     (OrganizationAccessContext.IsGlobalScope; the ReviewLogin bootstrap and
//     the 220 GRAC admins carry it), so it is the one test used here;
//   * the decider is the SESSION sign-in: the forwarded body is rebuilt with
//     actor set here, so the browser can never name someone else.
// Web tier never opens SQL.
// =====================================================================
using System.Net.Http.Headers;
using System.Text.Json;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
// TWO absolute routes, the same pair PracticeManagementGatewayController
// carries, and for the same reason (2026-11-02 fix: the grid answered
// "Request failed (HTTP 404)" on load).
//
// This screen lives in the Organization Management module, and the module
// is reached two different ways. On a hosted deployment
// /OrganizationManagement is a PathBase, so the path left for routing is
// /practice/api/subscription-requests -- the first route. On a plain host
// it is a conventional ROUTE instead (Program.cs,
// "OrganizationManagement/{areaKey?}") and ModuleRouteBase() still reports
// /OrganizationManagement, so the partial's own U() helper -- which
// prefixes window.appBasePath, correctly -- asks for
// /OrganizationManagement/practice/api/subscription-requests. Without the
// second route that matches nothing and 404s before the Api is ever
// called.
[Route("practice/api/subscription-requests")]
[Route("OrganizationManagement/practice/api/subscription-requests")]
public sealed class SubscriptionRequestController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    PermissionPolicy permissionPolicy,
    ILogger<SubscriptionRequestController> logger) : ControllerBase
{
    private const string ApiBaseKey = "ApiBaseUrl";
    private const string ApiBase    = "api/practice/subscription-requests";
    private const string Area       = "subscription-requests";

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

    private bool Can(string action) =>
        permissionPolicy.IsAllowed(Roles(), PermissionAreaMap.For(Area), action);

    [HttpGet]
    public async Task<IActionResult> List(CancellationToken ct)
    {
        if (Guard("VIEW") is { } denied) return denied;
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return await ForwardAsync(HttpMethod.Get, $"{ApiBase}{qs}", null, ct);
    }

    [HttpPost("{id:long}/decision")]
    public async Task<IActionResult> Decide(long id, CancellationToken ct)
    {
        if (Guard("APPROVE") is { } denied) return denied;

        string? decision = null, remark = null;
        using (var sr = new StreamReader(Request.Body))
        {
            var raw = await sr.ReadToEndAsync(ct);
            try
            {
                using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(raw) ? "{}" : raw);
                foreach (var p in doc.RootElement.EnumerateObject())
                {
                    if (p.Value.ValueKind != JsonValueKind.String) continue;
                    if (p.Name.Equals("decision", StringComparison.OrdinalIgnoreCase)) decision = p.Value.GetString();
                    else if (p.Name.Equals("remark", StringComparison.OrdinalIgnoreCase)) remark = p.Value.GetString();
                }
            }
            catch (JsonException)
            {
                return BadRequest(new { error = "The request body must be JSON." });
            }
        }

        // Rebuilt, not passed through: actor comes from the session only.
        var actor = HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) ?? "";
        var body = JsonSerializer.Serialize(new { decision, remark, actor });
        return await ForwardAsync(HttpMethod.Post, $"{ApiBase}/{id}/decision", body, ct);
    }

    // ------------------------------------------------------------------
    private IActionResult? Guard(string action)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        if (!Can(action))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "You do not have permission for this action." });
        if (!HttpContext.IsGlobalScope())
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Subscription requests are decided by a platform (GLOBAL scope) administrator." });
        return null;
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
            logger.LogError(ex, "SubscriptionRequest {Method} proxy failed: {Url}", method, relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }
}
