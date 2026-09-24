// =====================================================================
// PracticeObligationController (Web tier)
//
// Route: /practice/api/practice-obligations
//
// Session-gated proxy in front of the Api tier's practice-obligation
// endpoints (migration 307). Organisation-guarded on the read, caller
// stamped from the session on every call.
//
// WHY IT DOES NOT RIDE THE WORKFLOW CATCH-ALL
// -------------------------------------------
// WorkflowController proxies /practice/api/workflow/** and applies an
// instance-owner check on the way through, which is the right question
// for everything scoped to one practice instance. A practice-level
// obligation is the PRACTICE's, not an instance's, so it gets its own
// route rather than borrowing a guard that would ask whether the caller
// owns an instance nobody named.
//
// CALLER IDENTITY IS STAMPED, NEVER FORWARDED
// -------------------------------------------
// The two X-PM-Caller-* headers are set here from the session and
// overwrite anything the browser sent, so what reaches the Api tier is
// the session's identity. Same discipline as WorkflowController.
// =====================================================================
using System.Net.Http;
using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/practice-obligations")]
public sealed class PracticeObligationController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<PracticeObligationController> logger) : ControllerBase
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

    /// <summary>
    /// The practice-level obligations of one practice. Organisation-scoped:
    /// the caller has to be authorised for the organizationId supplied,
    /// the same guard the other org-scoped reads apply.
    /// </summary>
    [HttpGet]
    public async Task<IActionResult> List(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return err!;

        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return await ForwardAsync(HttpMethod.Get, $"api/practice/practice-obligations{qs}", null, ct);
    }

    /// <summary>
    /// Adds, edits or retires one practice-level obligation. The Api tier
    /// fans the change out to every instance of the practice before it
    /// answers, so the counts that come back describe what happened.
    /// </summary>
    [HttpPost]
    public async Task<IActionResult> Save(CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });

        string body;
        using (var sr = new StreamReader(Request.Body)) body = await sr.ReadToEndAsync(ct);

        return await ForwardAsync(HttpMethod.Post, "api/practice/practice-obligations", body, ct);
    }

    /// <summary>
    /// Reconciles an instance, or a whole practice, against the practice's
    /// definitions. Idempotent — safe to call on load, which is how an
    /// instance created after a definition existed picks its copies up.
    /// </summary>
    [HttpPost("fan-out")]
    public async Task<IActionResult> FanOut(CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });

        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return await ForwardAsync(HttpMethod.Post, $"api/practice/practice-obligations/fan-out{qs}", "", ct);
    }

    // ------------------------------------------------------------------
    private bool TryGuardOrganization(out IActionResult? error)
    {
        error = null;
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
        {
            error = Unauthorized(new { error = "Session expired." });
            return false;
        }
        if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
        {
            error = BadRequest(new { error = "organizationId is required." });
            return false;
        }
        if (!HttpContext.IsOrganizationAllowed(orgId))
        {
            error = StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller not authorised for this organization." });
            return false;
        }
        return true;
    }

    private async Task<IActionResult> ForwardAsync(
        HttpMethod method, string relativeUrl, string? body, CancellationToken ct)
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
            logger.LogError(ex, "PracticeObligation {Method} proxy failed: {Url}", method, relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // Set from the session, overwriting whatever the browser sent.
    private void StampCaller(HttpRequestMessage request)
    {
        request.Headers.Remove(CallerEmployeeHeader);
        request.Headers.Remove(CallerAdminHeader);

        var employeeId = HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey);
        if (long.TryParse(employeeId, out var id) && id > 0)
            request.Headers.TryAddWithoutValidation(CallerEmployeeHeader, id.ToString());

        var dataScope = (HttpContext.Session.GetString(PracticeSessionIdentity.DataScopeKey) ?? "ORGANIZATION")
            .Trim().ToUpperInvariant();
        var isAdmin = dataScope is "GLOBAL" or "ORGANIZATION";
        request.Headers.TryAddWithoutValidation(CallerAdminHeader, isAdmin ? "1" : "0");
    }
}
