// =====================================================================
// EvidenceAutomationController (Web tier)  (migration 530)
//
// Thin proxy to Api /api/practice/evidence-automation, the
// EvidenceCenterController pattern:
//   * session guard and organisation isolation (organizationId in the
//     query string or body, checked against the session's organisations);
//   * menu permission on the "evidence-automation" screen:
//       GET  lookups, obligations, obligations/{id}/evidence, bindings,
//            bindings/{id}, events, events/{id}/targets          VIEW
//       POST bindings                                             ADD
//       POST bindings/{id}/save, bindings/{id}/token              EDIT
//       POST bindings/{id}/status   EDIT (Pause / Resume) / DELETE (Retire)
//       POST events/{id}/accept, events/{id}/reject               EDIT
//       GET  notices/me, POST notices/me/mark   session only -- the
//            caller's own "not received" notices (My Notifications)
//   * caller employee id + admin flag stamped from the SESSION
//     (X-PM-Caller-*), overwriting anything the browser sent.
// The procedures then decide which sources the caller manages
// (admin / source owner / obligation owner). Web tier never opens SQL.
//
// The intake itself (no session, token) is EvidenceIntakeController.
// =====================================================================
using System.Net.Http.Headers;
using System.Text.Json;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/evidence-automation")]
public sealed class EvidenceAutomationController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    PermissionPolicy permissionPolicy,
    ILogger<EvidenceAutomationController> logger) : ControllerBase
{
    private const string ApiBaseKey = "ApiBaseUrl";
    private const string ApiBase    = "api/practice/evidence-automation";
    private const string Area       = "evidence-automation";

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

    private long? CallerEmployeeId =>
        long.TryParse(HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey), out var id) && id > 0
            ? id
            : null;

    // ------------------------------------------------------------------ reads
    [HttpGet("lookups")]
    public Task<IActionResult> Lookups(CancellationToken ct) => ForwardGetAsync($"{ApiBase}/lookups", ct);

    [HttpGet("obligations")]
    public Task<IActionResult> Obligations(CancellationToken ct) => ForwardGetAsync($"{ApiBase}/obligations", ct);

    [HttpGet("obligations/{id:long}/evidence")]
    public Task<IActionResult> ObligationEvidence(long id, CancellationToken ct) => ForwardGetAsync($"{ApiBase}/obligations/{id}/evidence", ct);

    [HttpGet("bindings")]
    public Task<IActionResult> Bindings(CancellationToken ct) => ForwardGetAsync($"{ApiBase}/bindings", ct);

    [HttpGet("bindings/{id:long}")]
    public Task<IActionResult> Binding(long id, CancellationToken ct) => ForwardGetAsync($"{ApiBase}/bindings/{id}", ct);

    [HttpGet("events")]
    public Task<IActionResult> Events(CancellationToken ct) => ForwardGetAsync($"{ApiBase}/events", ct);

    [HttpGet("events/{id:long}/targets")]
    public Task<IActionResult> EventTargets(long id, CancellationToken ct) => ForwardGetAsync($"{ApiBase}/events/{id}/targets", ct);

    // ------------------------------------------------------------------ writes
    [HttpPost("bindings")]
    public Task<IActionResult> CreateBinding(CancellationToken ct) => GuardedPostAsync($"{ApiBase}/bindings", _ => "ADD", ct);

    [HttpPost("bindings/{id:long}/save")]
    public Task<IActionResult> SaveBinding(long id, CancellationToken ct) => GuardedPostAsync($"{ApiBase}/bindings/{id}/save", _ => "EDIT", ct);

    [HttpPost("bindings/{id:long}/token")]
    public Task<IActionResult> IssueToken(long id, CancellationToken ct) => GuardedPostAsync($"{ApiBase}/bindings/{id}/token", _ => "EDIT", ct);

    [HttpPost("bindings/{id:long}/status")]
    public Task<IActionResult> BindingStatus(long id, CancellationToken ct) =>
        GuardedPostAsync($"{ApiBase}/bindings/{id}/status",
            body => string.Equals(ReadString(body, "action"), "Retire", StringComparison.OrdinalIgnoreCase) ? "DELETE" : "EDIT", ct);

    [HttpPost("events/{id:long}/accept")]
    public Task<IActionResult> Accept(long id, CancellationToken ct) => GuardedPostAsync($"{ApiBase}/events/{id}/accept", _ => "EDIT", ct);

    [HttpPost("events/{id:long}/reject")]
    public Task<IActionResult> Reject(long id, CancellationToken ct) => GuardedPostAsync($"{ApiBase}/events/{id}/reject", _ => "EDIT", ct);

    // ---- the caller's own "not received" notices (My Notifications) ------
    // Session only, no screen permission: addressed to the person; the API
    // takes the recipient from the stamped caller, never the query string.
    [HttpGet("notices/me")]
    public async Task<IActionResult> MyNotices(CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        if (CallerEmployeeId is null)
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Your sign-in is not linked to an employee record." });
        if (long.TryParse(Request.Query["organizationId"], out var orgId) && orgId > 0
            && !HttpContext.IsOrganizationAllowed(orgId))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller not authorised for this organization." });
        return await SendAsync(HttpMethod.Get, $"{ApiBase}/notices/me{QueryString()}", null, ct);
    }

    [HttpPost("notices/me/mark")]
    public async Task<IActionResult> MarkMyNotices(CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        var body = await ReadBodyAsync(ct);
        if (long.TryParse(ReadString(body, "organizationId"), out var orgId) && orgId > 0
            && !HttpContext.IsOrganizationAllowed(orgId))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller not authorised for this organization." });
        return await SendAsync(HttpMethod.Post, $"{ApiBase}/notices/me/mark", body, ct);
    }

    // ------------------------------------------------------------------ guards
    private async Task<IActionResult> ForwardGetAsync(string relativeUrl, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (!HttpContext.IsOrganizationAllowed(orgId))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller not authorised for this organization." });
        if (!Can("VIEW"))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "You do not have permission for this action." });
        return await SendAsync(HttpMethod.Get, relativeUrl + QueryString(), null, ct);
    }

    private async Task<IActionResult> GuardedPostAsync(string relativeUrl, Func<string, string> action, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        var body = await ReadBodyAsync(ct);
        if (!long.TryParse(ReadString(body, "organizationId"), out var orgId) || orgId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (!HttpContext.IsOrganizationAllowed(orgId))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller not authorised for this organization." });
        if (!Can(action(body)))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "You do not have permission for this action." });
        return await SendAsync(HttpMethod.Post, relativeUrl, body, ct);
    }

    private static string? ReadString(string body, string property)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            foreach (var p in doc.RootElement.EnumerateObject())
                if (string.Equals(p.Name, property, StringComparison.OrdinalIgnoreCase))
                    return p.Value.ValueKind switch
                    {
                        JsonValueKind.String => p.Value.GetString(),
                        JsonValueKind.Number => p.Value.GetRawText(),
                        _ => null
                    };
        }
        catch (JsonException) { /* not JSON -- treated as missing */ }
        return null;
    }

    // ------------------------------------------------------------------ forwarding
    private string QueryString() => Request.QueryString.HasValue ? Request.QueryString.Value! : "";

    private async Task<IActionResult> SendAsync(HttpMethod method, string relativeUrl, string? body, CancellationToken ct)
    {
        try
        {
            using var req = new HttpRequestMessage(method, relativeUrl);
            if (body is not null)
            {
                req.Content = new StringContent(body);
                req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            }
            StampCaller(req);
            var resp = await BuildClient().SendAsync(req, ct);
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
            logger.LogError(ex, "EvidenceAutomation proxy failed: {Method} {Url}", method, relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    private async Task<string> ReadBodyAsync(CancellationToken ct)
    {
        using var sr = new StreamReader(Request.Body);
        var body = await sr.ReadToEndAsync(ct);
        return string.IsNullOrWhiteSpace(body) ? "{}" : body;
    }

    // Set from the session, overwriting whatever the browser sent (the
    // EvidenceCenterController rule; the admin flag is the one shared rule).
    private void StampCaller(HttpRequestMessage request)
    {
        request.Headers.Remove(CallerIdentityHandler.CallerEmployeeHeader);
        if (CallerEmployeeId is { } id)
            request.Headers.TryAddWithoutValidation(CallerIdentityHandler.CallerEmployeeHeader, id.ToString());
        CallerIdentityHandler.StampAdminFlag(HttpContext, request);
    }
}
