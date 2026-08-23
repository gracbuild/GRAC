// =====================================================================
// DocumentAcknowledgementController (Web tier)  (charter §5 / §12.1.6)
//
// Thin HTTP proxy from Web -> Api for the Document Acknowledgement
// admin surface. Session-gated; org-scope checked before proxying.
// =====================================================================
using System.Net.Http;
using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/document-acknowledgements")]
public sealed class DocumentAcknowledgementController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<DocumentAcknowledgementController> logger) : ControllerBase
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

    // ---------------- Reads ------------------------------------------

    [HttpGet("pending")]
    public Task<IActionResult> Pending(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/document-acknowledgements/pending{qs}", ct);
    }

    [HttpGet]
    public Task<IActionResult> List(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/document-acknowledgements{qs}", ct);
    }

    [HttpGet("{acknowledgementId:long}/documents")]
    public Task<IActionResult> BatchDocuments(long acknowledgementId, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        return ForwardGetAsync($"api/practice/document-acknowledgements/{acknowledgementId}/documents", ct);
    }

    [HttpGet("{acknowledgementId:long}/documents/{documentId:long}/users")]
    public Task<IActionResult> DocumentUsers(long acknowledgementId, long documentId, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        return ForwardGetAsync($"api/practice/document-acknowledgements/{acknowledgementId}/documents/{documentId}/users", ct);
    }

    // ---------------- Write ------------------------------------------

    // Batch create -- accepts JSON. Caller identity is stamped from the
    // session (never trusted from the browser) before forwarding.
    [HttpPost]
    public async Task<IActionResult> Create(CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });

        var client = BuildClient();
        try
        {
            // Read the browser payload, then rewrite CallerEmployeeId /
            // CallerDisplayName with server-side session values.
            string body;
            using (var sr = new StreamReader(Request.Body))
                body = await sr.ReadToEndAsync(ct);

            if (string.IsNullOrWhiteSpace(body))
                return BadRequest(new { success = false, error = "request body is required." });

            using var doc = System.Text.Json.JsonDocument.Parse(body);
            var elem     = doc.RootElement;
            var callerId = HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey);
            var callerNm = HttpContext.Session.GetString(PracticeSessionIdentity.UserKey);

            // Rebuild the JSON with session-stamped caller fields. Preserves
            // every other property from the browser payload.
            using var ms = new MemoryStream();
            using (var w = new System.Text.Json.Utf8JsonWriter(ms))
            {
                w.WriteStartObject();
                foreach (var p in elem.EnumerateObject())
                {
                    if (p.Name.Equals("CallerEmployeeId",  StringComparison.OrdinalIgnoreCase)) continue;
                    if (p.Name.Equals("CallerDisplayName", StringComparison.OrdinalIgnoreCase)) continue;
                    if (p.Name.Equals("callerEmployeeId",  StringComparison.Ordinal)) continue;
                    if (p.Name.Equals("callerDisplayName", StringComparison.Ordinal)) continue;
                    p.WriteTo(w);
                }
                if (!string.IsNullOrWhiteSpace(callerId) && long.TryParse(callerId, out var cid))
                    w.WriteNumber("callerEmployeeId", cid);
                if (!string.IsNullOrWhiteSpace(callerNm))
                    w.WriteString("callerDisplayName", callerNm);
                w.WriteEndObject();
            }

            using var msg = new HttpRequestMessage(HttpMethod.Post, "api/practice/document-acknowledgements");
            msg.Content = new ByteArrayContent(ms.ToArray());
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
            logger.LogError(ex, "DocumentAcknowledgement.Create (web) failed");
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }

    // ---------------- Helpers ----------------------------------------

    // ==================== USER SIDE (Phase 3) ========================
    //
    // The employee id is ALWAYS read from the session before forwarding.
    // Browser-supplied employee ids are ignored (session identity is
    // the trusted source; the API layer takes whatever we send).

    [HttpGet("my/batches")]
    public Task<IActionResult> MyBatches(CancellationToken ct)
    {
        // Session presence is enough. An Admin without an employee-map is
        // still valid on this page (they browse the org-wide list).
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));

        var isAdmin = IsSessionAdmin();
        long.TryParse(HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey), out var empId);

        if (!isAdmin && empId <= 0)
            return Task.FromResult<IActionResult>(
                StatusCode(StatusCodes.Status403Forbidden, new { error = "Your session has no employee identity mapped." }));

        long.TryParse(Request.Query["organizationId"], out var qsOrgId);
        var orgId = qsOrgId > 0 ? qsOrgId : SessionFirstOrgId();
        if (isAdmin && orgId <= 0)
            return Task.FromResult<IActionResult>(
                BadRequest(new { error = "organizationId is required for admin view (session has no allowed orgs)." }));

        var extra  = $"employeeId={empId}&isAdmin={(isAdmin ? "true" : "false")}"
                   + (isAdmin && orgId > 0 ? $"&organizationId={orgId}" : "");
        var joiner = Request.QueryString.HasValue ? Request.QueryString.Value + "&" : "?";
        var url    = $"api/practice/document-acknowledgements/my/batches{joiner}{extra}";
        return ForwardGetAsync(url, ct);
    }

    [HttpGet("my/batches/{acknowledgementId:long}/documents")]
    public Task<IActionResult> MyBatchDocuments(long acknowledgementId, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));

        var isAdmin = IsSessionAdmin();
        long.TryParse(HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey), out var empId);
        if (!isAdmin && empId <= 0)
            return Task.FromResult<IActionResult>(
                StatusCode(StatusCodes.Status403Forbidden, new { error = "Your session has no employee identity mapped." }));

        var url = $"api/practice/document-acknowledgements/my/batches/{acknowledgementId}/documents"
                + $"?employeeId={empId}&isAdmin={(isAdmin ? "true" : "false")}";
        return ForwardGetAsync(url, ct);
    }

    private bool IsSessionAdmin()
    {
        var scope = HttpContext.Session.GetString(PracticeSessionIdentity.DataScopeKey);
        if (string.IsNullOrWhiteSpace(scope)) return false;
        scope = scope.ToUpperInvariant();
        return scope == "GLOBAL" || scope == "ORGANIZATION";
    }

    // First allowed org id from the session -- used as the scope when an
    // admin lands on the page without picking one explicitly.
    private long SessionFirstOrgId()
    {
        var raw = HttpContext.Session.GetString(PracticeSessionIdentity.AllowedOrganizationIdsKey);
        if (string.IsNullOrWhiteSpace(raw)) return 0;
        foreach (var s in raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            if (long.TryParse(s, out var v) && v > 0) return v;
        return 0;
    }

    [HttpPost("my/acknowledge")]
    public async Task<IActionResult> MyAcknowledge(CancellationToken ct)
    {
        if (!TryGetSessionEmployeeId(out var empId, out var err)) return err!;

        var client = BuildClient();
        try
        {
            string body;
            using (var sr = new StreamReader(Request.Body)) body = await sr.ReadToEndAsync(ct);
            if (string.IsNullOrWhiteSpace(body))
                return BadRequest(new { success = false, error = "request body is required." });

            // Rewrite caller stamps from session so browser cannot spoof.
            using var doc = System.Text.Json.JsonDocument.Parse(body);
            var callerNm  = HttpContext.Session.GetString(PracticeSessionIdentity.UserKey);
            using var ms  = new MemoryStream();
            using (var w  = new System.Text.Json.Utf8JsonWriter(ms))
            {
                w.WriteStartObject();
                foreach (var p in doc.RootElement.EnumerateObject())
                {
                    var k = p.Name;
                    if (k.Equals("callerEmployeeId",  StringComparison.OrdinalIgnoreCase)) continue;
                    if (k.Equals("callerDisplayName", StringComparison.OrdinalIgnoreCase)) continue;
                    p.WriteTo(w);
                }
                w.WriteNumber("callerEmployeeId", empId);
                if (!string.IsNullOrWhiteSpace(callerNm)) w.WriteString("callerDisplayName", callerNm);
                w.WriteEndObject();
            }

            using var msg = new HttpRequestMessage(HttpMethod.Post,
                $"api/practice/document-acknowledgements/my/acknowledge?employeeId={empId}");
            msg.Content = new ByteArrayContent(ms.ToArray());
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
            logger.LogError(ex, "DocumentAcknowledgement.MyAcknowledge (web) failed");
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }

    private bool TryGetSessionEmployeeId(out long employeeId, out IActionResult? error)
    {
        employeeId = 0;
        error     = null;
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
        {
            error = Unauthorized(new { error = "Session expired. Please sign in again." });
            return false;
        }
        var raw = HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey);
        if (!long.TryParse(raw, out employeeId) || employeeId <= 0)
        {
            error = StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Your session has no employee identity mapped." });
            return false;
        }
        return true;
    }

    private bool TryGuardOrganization(out IActionResult? error)
    {
        error = null;
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
        {
            error = Unauthorized(new { error = "Session expired. Please sign in again." });
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
                new { error = "Caller is not authorised for the requested organization." });
            return false;
        }
        return true;
    }

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
            logger.LogError(ex, "DocumentAcknowledgement GET proxy failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }
}
