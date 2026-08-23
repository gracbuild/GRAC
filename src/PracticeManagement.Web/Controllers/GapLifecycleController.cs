// =====================================================================
// GapLifecycleController (Web tier)  (charter §5 / §12.1.6)
//
// Thin HTTP proxy from Web -> Api for the Gap Centre v1.0 lifecycle
// surface. Session-gated. Caller identity always stamped from the
// session before proxying (never trusted from the browser).
// =====================================================================
using System.Net.Http;
using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/gap-lifecycle")]
public sealed class GapLifecycleController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<GapLifecycleController> logger) : ControllerBase
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

    // ---- header (bootstrap the Gap Detail page from the gap itself) ----
    [HttpGet("gaps/{customGapId:long}/header")]
    public Task<IActionResult> Header(long customGapId, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        return ForwardGetAsync($"api/practice/gap-lifecycle/gaps/{customGapId}/header", ct);
    }

    // ---- materialize (Implementation tab -> lifecycle) ----
    // The browser sends only the practice_instance id + orgId (already
    // scope-checked by the session's allowed orgs). Caller stamps come
    // from the session, never from the payload.
    [HttpPost("materialize-from-instance")]
    public Task<IActionResult> MaterializeFromInstance(CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post, "api/practice/gap-lifecycle/materialize-from-instance", ct);

    // ---- lookups ----
    [HttpGet("states")]
    public Task<IActionResult> States(CancellationToken ct) => ForwardGetAsync("api/practice/gap-lifecycle/states", ct);

    [HttpGet("actions")]
    public Task<IActionResult> Actions(CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/gap-lifecycle/actions{qs}", ct);
    }

    // ---- transition (POST with stamped caller) ----
    [HttpPost("gaps/{customGapId:long}/transition")]
    public Task<IActionResult> Transition(long customGapId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post, $"api/practice/gap-lifecycle/gaps/{customGapId}/transition", ct);

    // ---- analysis ----
    [HttpGet("gaps/{customGapId:long}/analysis")]
    public Task<IActionResult> GetAnalysis(long customGapId, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        return ForwardGetAsync($"api/practice/gap-lifecycle/gaps/{customGapId}/analysis", ct);
    }

    [HttpPut("gaps/{customGapId:long}/analysis")]
    public Task<IActionResult> SaveAnalysis(long customGapId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Put, $"api/practice/gap-lifecycle/gaps/{customGapId}/analysis", ct);

    // ---- linked artefacts (new; feeds the Analysis-tab chip strip) ----
    [HttpGet("gaps/{customGapId:long}/linked-artefacts")]
    public Task<IActionResult> ListLinkedArtefacts(long customGapId, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        return ForwardGetAsync($"api/practice/gap-lifecycle/gaps/{customGapId}/linked-artefacts", ct);
    }

    // ---- downstream (retained for backward compat) ----
    [HttpGet("gaps/{customGapId:long}/downstream")]
    public Task<IActionResult> ListDownstream(long customGapId, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/gap-lifecycle/gaps/{customGapId}/downstream{qs}", ct);
    }

    [HttpPost("gaps/{customGapId:long}/downstream")]
    public Task<IActionResult> AddDownstream(long customGapId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post, $"api/practice/gap-lifecycle/gaps/{customGapId}/downstream", ct);

    [HttpPost("downstream/{linkId:long}/cancel")]
    public Task<IActionResult> CancelDownstream(long linkId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post, $"api/practice/gap-lifecycle/downstream/{linkId}/cancel", ct);

    // ---- helpers ----

    private async Task<IActionResult> ForwardGetAsync(string relativeUrl, CancellationToken ct)
    {
        var client = BuildClient();
        try
        {
            var resp    = await client.GetAsync(relativeUrl, ct);
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
            logger.LogError(ex, "GapLifecycle GET proxy failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // Read the JSON body, rewrite callerEmployeeId / callerDisplayName
    // from the session, and forward. Prevents browser-supplied caller
    // spoofing on audit-sensitive endpoints (transition, cancel, etc.).
    private async Task<IActionResult> ForwardJsonWithCallerStampAsync(HttpMethod method, string relativeUrl, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var client = BuildClient();
        try
        {
            string body;
            using (var sr = new StreamReader(Request.Body)) body = await sr.ReadToEndAsync(ct);

            long? callerEmpId = null;
            if (long.TryParse(HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey), out var eid) && eid > 0)
                callerEmpId = eid;
            var callerNm = HttpContext.Session.GetString(PracticeSessionIdentity.UserKey);

            using var ms = new MemoryStream();
            using (var w = new System.Text.Json.Utf8JsonWriter(ms))
            {
                w.WriteStartObject();
                if (!string.IsNullOrWhiteSpace(body))
                {
                    using var doc = System.Text.Json.JsonDocument.Parse(body);
                    foreach (var p in doc.RootElement.EnumerateObject())
                    {
                        if (p.Name.Equals("callerEmployeeId",  StringComparison.OrdinalIgnoreCase)) continue;
                        if (p.Name.Equals("callerDisplayName", StringComparison.OrdinalIgnoreCase)) continue;
                        p.WriteTo(w);
                    }
                }
                if (callerEmpId.HasValue)                w.WriteNumber("callerEmployeeId", callerEmpId.Value);
                if (!string.IsNullOrWhiteSpace(callerNm)) w.WriteString("callerDisplayName", callerNm);
                w.WriteEndObject();
            }

            using var msg = new HttpRequestMessage(method, relativeUrl)
            {
                Content = new ByteArrayContent(ms.ToArray())
            };
            msg.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");

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
            logger.LogError(ex, "GapLifecycle {Method} proxy failed: {Url}", method, relativeUrl);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }
}
