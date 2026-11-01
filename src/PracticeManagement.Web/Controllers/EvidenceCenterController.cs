// =====================================================================
// EvidenceCenterController (Web tier)  (migration 476, Phase 1)
//
// Thin proxy to Api /api/practice/evidence-center, the
// RepositoryChangeController / AssetConfigController pattern:
//   * session guard and organisation isolation (organizationId in the
//     query string, checked against the session's organisations);
//   * menu permission on the "evidence-center" screen:
//       GET  /, /lookups, /{id}, /files/{fileId}   VIEW
//       POST /upload        ADD (new item) / EDIT (new version)
//       POST /{id}/save     EDIT
//       POST /{id}/status   EDIT (Retire / Restore) / DELETE (Delete)
//       GET  /notices/me, POST /notices/me/mark   session only -- the
//            caller's own expiry notices (477)
//   * caller employee id + admin flag stamped from the SESSION
//     (X-PM-Caller-*), overwriting anything the browser sent.
// The procedures then decide which items the caller may see and change
// (owner / uploader / linked instance / admin; Restricted = owner + admin).
// Web tier never opens SQL.
// =====================================================================
using System.Net.Http.Headers;
using System.Text.Json;
using ControlManagement.Security;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;
using PracticeManagement.Web.Services;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/evidence-center")]
public sealed class EvidenceCenterController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    PermissionPolicy permissionPolicy,
    ILogger<EvidenceCenterController> logger) : ControllerBase
{
    private const string ApiBaseKey           = "ApiBaseUrl";
    private const string ApiBase              = "api/practice/evidence-center";
    private const string Area                 = "evidence-center";

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

    private bool Can(params string[] actions) =>
        actions.Any(a => permissionPolicy.IsAllowed(Roles(), PermissionAreaMap.For(Area), a));

    private long? CallerEmployeeId =>
        long.TryParse(HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey), out var id) && id > 0
            ? id
            : null;

    // ------------------------------------------------------------------
    [HttpGet]
    public Task<IActionResult> List(CancellationToken ct) =>
        ForwardGetAsync(ApiBase, ct);

    [HttpGet("lookups")]
    public Task<IActionResult> Lookups(CancellationToken ct) =>
        ForwardGetAsync($"{ApiBase}/lookups", ct);

    [HttpGet("{id:long}")]
    public Task<IActionResult> Get(long id, CancellationToken ct) =>
        ForwardGetAsync($"{ApiBase}/{id}", ct);

    [HttpGet("files/{fileId:long}")]
    public async Task<IActionResult> Download(long fileId, CancellationToken ct)
    {
        if (Guard(out var orgId, "VIEW") is { } denied) return denied;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"{ApiBase}/files/{fileId}?organizationId={orgId}");
            StampCaller(req);
            var resp = await BuildClient().SendAsync(req, ct);
            if (!resp.IsSuccessStatusCode) return await PassThroughAsync(resp, ct);
            return await ApiFileProxy.ToFileResultAsync(resp, $"evidence-file-{fileId}", ct);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EvidenceCenter download failed for file {FileId}", fileId);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    /// <summary>A new item needs ADD; a new version of an item needs EDIT.</summary>
    [HttpPost("upload")]
    [RequestSizeLimit(52_428_800)] // 50 MB -- matches the Api-side limit
    public async Task<IActionResult> Upload(CancellationToken ct)
    {
        if (!Request.HasFormContentType)
            return BadRequest(new { error = "Request is not multipart/form-data." });
        var form = await Request.ReadFormAsync(ct);
        var newVersion = long.TryParse(form["evidenceItemId"], out var itemId) && itemId > 0;
        if (Guard(out var orgId, newVersion ? "EDIT" : "ADD") is { } denied) return denied;

        try
        {
            // Identity comes from the session (StampCaller), never the form.
            using var content = await ApiFileProxy.BuildMultipartAsync(
                Request, ct, "callerEmployeeId", "callerIsAdmin", "actor");
            using var req = new HttpRequestMessage(HttpMethod.Post, $"{ApiBase}/upload?organizationId={orgId}")
            {
                Content = content
            };
            StampCaller(req);
            return await PassThroughAsync(await BuildClient().SendAsync(req, ct), ct);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EvidenceCenter upload failed");
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // ---- 477: the caller's own expiry notices (My Notifications) ----------
    // Session only, no screen permission: they are addressed to the person,
    // and the API takes the recipient from the stamped caller, never the
    // query string.
    [HttpGet("notices/me")]
    public async Task<IActionResult> MyNotices(CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        // Notices are addressed to an employee; a sign-in without one has
        // none (My Notifications then leaves the section hidden).
        if (CallerEmployeeId is null)
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Your sign-in is not linked to an employee record." });
        if (long.TryParse(Request.Query["organizationId"], out var orgId) && orgId > 0
            && !HttpContext.IsOrganizationAllowed(orgId))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller not authorised for this organization." });
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"{ApiBase}/notices/me{qs}");
            StampCaller(req);
            return await PassThroughAsync(await BuildClient().SendAsync(req, ct), ct);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EvidenceCenter notices proxy failed");
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
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
        return await ForwardPostAsync($"{ApiBase}/notices/me/mark", body, ct);
    }

    [HttpPost("{id:long}/save")]
    public async Task<IActionResult> Save(long id, CancellationToken ct)
    {
        var body = await ReadBodyAsync(ct);
        if (GuardBody(body, out var _, "EDIT") is { } denied) return denied;
        return await ForwardPostAsync($"{ApiBase}/{id}/save", body, ct);
    }

    [HttpPost("{id:long}/status")]
    public async Task<IActionResult> SetStatus(long id, CancellationToken ct)
    {
        var body = await ReadBodyAsync(ct);
        var action = ReadString(body, "action");
        var needed = string.Equals(action, "Delete", StringComparison.OrdinalIgnoreCase) ? "DELETE" : "EDIT";
        if (GuardBody(body, out var _, needed) is { } denied) return denied;
        return await ForwardPostAsync($"{ApiBase}/{id}/status", body, ct);
    }

    // ------------------------------------------------------------------
    // Guards
    // ------------------------------------------------------------------
    private IActionResult? Guard(out long organizationId, string action)
    {
        organizationId = 0;
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        if (!long.TryParse(Request.Query["organizationId"], out organizationId) || organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (!HttpContext.IsOrganizationAllowed(organizationId))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller not authorised for this organization." });
        if (!Can(action))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "You do not have permission for this action." });
        return null;
    }

    private IActionResult? GuardBody(string body, out long organizationId, string action)
    {
        organizationId = 0;
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        var raw = ReadString(body, "organizationId");
        if (!long.TryParse(raw, out organizationId) || organizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (!HttpContext.IsOrganizationAllowed(organizationId))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller not authorised for this organization." });
        if (!Can(action))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "You do not have permission for this action." });
        return null;
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

    // ------------------------------------------------------------------
    // Forwarding
    // ------------------------------------------------------------------
    private async Task<IActionResult> ForwardGetAsync(string relativeUrl, CancellationToken ct)
    {
        if (Guard(out _, "VIEW") is { } denied) return denied;
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, relativeUrl + qs);
            StampCaller(req);
            return await PassThroughAsync(await BuildClient().SendAsync(req, ct), ct);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EvidenceCenter GET proxy failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    private async Task<IActionResult> ForwardPostAsync(string relativeUrl, string body, CancellationToken ct)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, relativeUrl)
            {
                Content = new StringContent(body)
            };
            req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            StampCaller(req);
            return await PassThroughAsync(await BuildClient().SendAsync(req, ct), ct);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "EvidenceCenter POST proxy failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    private static async Task<IActionResult> PassThroughAsync(HttpResponseMessage resp, CancellationToken ct)
    {
        var payload = await resp.Content.ReadAsStringAsync(ct);
        return new ContentResult
        {
            Content     = payload,
            ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
            StatusCode  = (int)resp.StatusCode
        };
    }

    private async Task<string> ReadBodyAsync(CancellationToken ct)
    {
        using var sr = new StreamReader(Request.Body);
        var body = await sr.ReadToEndAsync(ct);
        return string.IsNullOrWhiteSpace(body) ? "{}" : body;
    }

    // Set from the session, overwriting whatever the browser sent. The
    // employee id is also stamped by CallerIdentityHandler on every call;
    // the admin flag comes from the one shared rule.
    private void StampCaller(HttpRequestMessage request)
    {
        request.Headers.Remove(CallerIdentityHandler.CallerEmployeeHeader);
        if (CallerEmployeeId is { } id)
            request.Headers.TryAddWithoutValidation(CallerIdentityHandler.CallerEmployeeHeader, id.ToString());
        CallerIdentityHandler.StampAdminFlag(HttpContext, request);
    }
}
