// =====================================================================
// RepositoryChangeController (Web tier)  (statement subscription copy
// model, phase 3)
//
// Thin proxy to Api /api/practice/repository-changes, same contract as
// PracticeObligationController: session guard, organization isolation,
// caller employee id + admin flag stamped from the SESSION (X-PM-Caller-*),
// overwriting anything the browser sent. The Api's
// sp_repository_change_apply then decides whether the caller may approve
// (release owner or organization admin).
//
// The "me" routes take the recipient from the session, never the query
// string, so one user can never read or clear another's notices.
// =====================================================================
using System.Net.Http;
using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/repository-changes")]
public sealed class RepositoryChangeController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<RepositoryChangeController> logger) : ControllerBase
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

    [HttpGet]
    public async Task<IActionResult> List(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err, out _)) return err!;
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return await ForwardAsync(HttpMethod.Get, $"api/practice/repository-changes{qs}", null, ct);
    }

    [HttpGet("counts")]
    public async Task<IActionResult> Counts(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err, out _)) return err!;
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return await ForwardAsync(HttpMethod.Get, $"api/practice/repository-changes/counts{qs}", null, ct);
    }

    /// <summary>organizationId (query) scopes the org-isolation check; the
    /// change itself is looked up by id and re-checked by the procedure.</summary>
    [HttpPost("{id:long}/decision")]
    public async Task<IActionResult> Decide(long id, CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err, out _)) return err!;
        return await ForwardAsync(HttpMethod.Post, $"api/practice/repository-changes/{id}/decision", await ReadBodyAsync(ct), ct);
    }

    [HttpPost("decisions")]
    public async Task<IActionResult> DecideMany(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err, out _)) return err!;
        return await ForwardAsync(HttpMethod.Post, "api/practice/repository-changes/decisions", await ReadBodyAsync(ct), ct);
    }

    [HttpGet("me/notifications")]
    public async Task<IActionResult> MyNotifications([FromQuery] long? organizationId, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        // A badge must never break a page: an unmapped account simply has none.
        if (CallerEmployeeId is not { } employeeId) return Ok(new { data = Array.Empty<object>() });
        if (organizationId is > 0 && !HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller not authorised for this organization." });

        var qs = $"?recipientEmployeeId={employeeId}" + (organizationId is > 0 ? $"&organizationId={organizationId.Value}" : "");
        return await ForwardAsync(HttpMethod.Get, $"api/practice/repository-changes/notifications{qs}", null, ct);
    }

    [HttpPost("me/notifications/mark-read")]
    public async Task<IActionResult> MyMarkRead(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err, out var orgId)) return err!;
        if (CallerEmployeeId is not { } employeeId) return Ok(new { markedCount = 0 });
        return await ForwardAsync(HttpMethod.Post,
            $"api/practice/repository-changes/notifications/mark-read?recipientEmployeeId={employeeId}&organizationId={orgId}", "", ct);
    }

    // ------------------------------------------------------------------
    private bool TryGuardOrganization(out IActionResult? error, out long organizationId)
    {
        error = null;
        organizationId = 0;
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
        {
            error = Unauthorized(new { error = "Session expired." });
            return false;
        }
        if (!long.TryParse(Request.Query["organizationId"], out organizationId) || organizationId <= 0)
        {
            error = BadRequest(new { error = "organizationId is required." });
            return false;
        }
        if (!HttpContext.IsOrganizationAllowed(organizationId))
        {
            error = StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller not authorised for this organization." });
            return false;
        }
        return true;
    }

    private async Task<string> ReadBodyAsync(CancellationToken ct)
    {
        using var sr = new StreamReader(Request.Body);
        var body = await sr.ReadToEndAsync(ct);
        return string.IsNullOrWhiteSpace(body) ? "{}" : body;
    }

    private async Task<IActionResult> ForwardAsync(HttpMethod method, string relativeUrl, string? body, CancellationToken ct)
    {
        var client = BuildClient();
        try
        {
            using var msg = new HttpRequestMessage(method, relativeUrl);
            if (body is not null)
            {
                msg.Content = new StringContent(body);
                msg.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            }
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
            logger.LogError(ex, "RepositoryChange {Method} proxy failed: {Url}", method, relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // Set from the session, overwriting whatever the browser sent.
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
