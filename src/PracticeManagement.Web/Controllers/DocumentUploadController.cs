// =====================================================================
// DocumentUploadController (Web tier)  (charter §5 / §12.1.6)
//
// Thin HTTP proxy from Web -> Api for the Document Upload module.
//
// Route convention (charter §7):
//   Api : /api/practice/document-uploads/...
//   Web : /practice/api/document-uploads/...    (browser hits this,
//                                                Api stays behind CORS)
//
// PROJECT-WIDE RULE: the Web tier NEVER opens SQL directly. Every
// endpoint below forwards to the Api and streams the response body
// back to the browser.
//
// Multipart proxying: the Create/Update endpoints forward the raw
// request stream (including the file part) rather than parsing +
// re-serialising it. That keeps the memory footprint constant on the
// Web tier regardless of upload size.
// =====================================================================
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/document-uploads")]
public sealed class DocumentUploadController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<DocumentUploadController> logger) : ControllerBase
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

    // ============================== Lookups ==========================
    // Session gate only -- lookups do not carry organization-scoped data
    // for stages/statuses/types (global catalogs). Departments/employees
    // DO carry org data and are additionally scope-checked below.

    [HttpGet("lookups/{name}")]
    public async Task<IActionResult> Lookup(string name, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { "types", "stages", "statuses", "source-types", "distribution-types", "departments", "employees" };
        if (!allowed.Contains(name))
            return NotFound();

        // Scope-check for org-carrying lookups
        if ((name.Equals("departments", StringComparison.OrdinalIgnoreCase) ||
             name.Equals("employees",   StringComparison.OrdinalIgnoreCase))
            && !TryGuardOrganization(out var orgError))
        {
            return orgError!;
        }

        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return await ForwardGetAsync($"api/practice/document-uploads/lookups/{name}{qs}", ct);
    }

    // ============================== Register (read) ==================

    [HttpGet]
    public async Task<IActionResult> List(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return err!;
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return await ForwardGetAsync($"api/practice/document-uploads{qs}", ct);
    }

    [HttpGet("{documentId:long}")]
    public async Task<IActionResult> Details(long documentId, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });
        return await ForwardGetAsync($"api/practice/document-uploads/{documentId}", ct);
    }

    [HttpGet("{documentId:long}/distribution/{kind}")]
    public async Task<IActionResult> Distribution(long documentId, string kind, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });
        var allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "departments", "employees" };
        if (!allowed.Contains(kind)) return NotFound();
        return await ForwardGetAsync($"api/practice/document-uploads/{documentId}/distribution/{kind}", ct);
    }

    [HttpGet("{documentId:long}/file")]
    public async Task<IActionResult> Download(long documentId, [FromQuery] bool inline, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var client = BuildClient();
        try
        {
            var qs   = inline ? "?inline=true" : "";
            var resp = await client.GetAsync($"api/practice/document-uploads/{documentId}/file{qs}",
                                             HttpCompletionOption.ResponseHeadersRead, ct);
            if (resp.StatusCode == HttpStatusCode.NotFound) return NotFound();

            var stream      = await resp.Content.ReadAsStreamAsync(ct);
            var contentType = resp.Content.Headers.ContentType?.ToString() ?? "application/octet-stream";
            var fileName    = resp.Content.Headers.ContentDisposition?.FileNameStar
                           ?? resp.Content.Headers.ContentDisposition?.FileName
                           ?? $"document-{documentId}";
            fileName = fileName.Trim('"');

            if (inline)
            {
                // Preserve the upstream inline disposition so the browser
                // renders the file (e.g. in an <iframe>) rather than saving
                // it. File(...) without a fileName would still work but the
                // Content-Disposition header would be absent; setting it
                // explicitly is safer for downstream file-name display.
                var cd = new System.Net.Http.Headers.ContentDispositionHeaderValue("inline")
                {
                    FileName = fileName
                };
                Response.Headers["Content-Disposition"] = cd.ToString();

                // Global Web middleware (Program.cs) sets X-Frame-Options=DENY
                // and CSP frame-ancestors='none' on every response, which
                // makes the browser show "localhost refused to connect" when
                // the iframe tries to load this URL. Loosen ONLY on this
                // endpoint to same-origin -- other pages remain locked down.
                Response.Headers["X-Frame-Options"]         = "SAMEORIGIN";
                Response.Headers["Content-Security-Policy"] = "frame-ancestors 'self'";
                return File(stream, contentType);
            }
            return File(stream, contentType, fileName);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "DocumentUpload.Download proxy failed for {DocumentId}", documentId);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // ============================== Register (write) =================
    // Multipart passthrough. We stream the request body into an
    // HttpRequestMessage that carries the original Content-Type header
    // (with its boundary=) so the Api sees the exact bytes the browser
    // sent.

    // Broad try/catch at the action so a startup-time / binding / size-limit
    // exception surfaces as 400 with a message instead of an opaque 500 from
    // the framework pipeline. RequestSizeLimit is generous (100 MB) plus a
    // matching RequestFormLimits so both Kestrel and the form reader agree.
    [HttpPost]
    [DisableRequestSizeLimit]
    [RequestFormLimits(MultipartBodyLengthLimit = long.MaxValue, ValueLengthLimit = int.MaxValue)]
    public async Task<IActionResult> Create(CancellationToken ct)
    {
        try { return await ForwardMultipartAsync(HttpMethod.Post, "api/practice/document-uploads", ct); }
        catch (Exception ex)
        {
            logger.LogError(ex, "DocumentUpload.Create (web) outer failure");
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }

    [HttpPut("{documentId:long}")]
    [DisableRequestSizeLimit]
    [RequestFormLimits(MultipartBodyLengthLimit = long.MaxValue, ValueLengthLimit = int.MaxValue)]
    public async Task<IActionResult> Update(long documentId, CancellationToken ct)
    {
        try { return await ForwardMultipartAsync(HttpMethod.Put, $"api/practice/document-uploads/{documentId}", ct); }
        catch (Exception ex)
        {
            logger.LogError(ex, "DocumentUpload.Update (web) outer failure for {DocumentId}", documentId);
            return BadRequest(new { success = false, error = ex.Message, inner = ex.InnerException?.Message });
        }
    }

    [HttpPost("{documentId:long}/toggle-status")]
    public Task<IActionResult> ToggleStatus(long documentId, CancellationToken ct)
    {
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardJsonBodyAsync(HttpMethod.Post, $"api/practice/document-uploads/{documentId}/toggle-status{qs}", ct);
    }

    [HttpPost("{documentId:long}/workflow")]
    public Task<IActionResult> Workflow(long documentId, CancellationToken ct)
        => ForwardJsonBodyAsync(HttpMethod.Post, $"api/practice/document-uploads/{documentId}/workflow", ct);

    // ============================== Helpers ==========================

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
            error = BadRequest(new { error = "organizationId is required. Select an organization first." });
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
            logger.LogError(ex, "DocumentUpload proxy GET failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    private async Task<IActionResult> ForwardJsonBodyAsync(HttpMethod method, string relativeUrl, CancellationToken ct)
    {
        var client = BuildClient();
        try
        {
            using var msg = new HttpRequestMessage(method, relativeUrl);
            if (Request.ContentLength.GetValueOrDefault() > 0)
            {
                Request.EnableBuffering();
                using var ms = new MemoryStream();
                await Request.Body.CopyToAsync(ms, ct);
                var bytes = ms.ToArray();
                msg.Content = new ByteArrayContent(bytes);
                msg.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(
                    Request.ContentType ?? "application/json");
            }
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
            logger.LogError(ex, "DocumentUpload proxy {Method} failed: {Url}", method, relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    private async Task<IActionResult> ForwardMultipartAsync(HttpMethod method, string relativeUrl, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        // Streaming Request.Body directly into StreamContent races with the
        // [ApiController] input-formatter probing and shows up as a 502 with
        // an ObjectDisposedException. Instead we parse the form here (Kestrel
        // knows how) and REBUILD a MultipartFormDataContent for the Api. This
        // also lets us stamp caller identity from the session, closing a
        // vector where the browser could otherwise spoof CallerEmployeeId.
        if (!Request.HasFormContentType)
            return BadRequest(new { error = "Request is not multipart/form-data." });

        var client = BuildClient();
        try
        {
            var form = await Request.ReadFormAsync(ct);

            using var mp = new MultipartFormDataContent("----pmboundary-" + Guid.NewGuid().ToString("N"));

            // Copy every text field the browser sent, except caller stamps --
            // those come from the trusted session below.
            foreach (var kv in form)
            {
                if (kv.Key.Equals("CallerEmployeeId",  StringComparison.OrdinalIgnoreCase)) continue;
                if (kv.Key.Equals("CallerDisplayName", StringComparison.OrdinalIgnoreCase)) continue;
                foreach (var v in kv.Value)
                    if (v is not null) mp.Add(new StringContent(v), kv.Key);
            }

            // Session-stamped caller identity (never trust the browser here).
            var callerEmpId  = HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey);
            var callerName   = HttpContext.Session.GetString(PracticeSessionIdentity.UserKey);
            if (!string.IsNullOrWhiteSpace(callerEmpId))
                mp.Add(new StringContent(callerEmpId), "CallerEmployeeId");
            if (!string.IsNullOrWhiteSpace(callerName))
                mp.Add(new StringContent(callerName),  "CallerDisplayName");

            // Files
            foreach (var file in form.Files)
            {
                if (file.Length == 0) continue;
                var streamContent = new StreamContent(file.OpenReadStream());
                if (!string.IsNullOrWhiteSpace(file.ContentType))
                    streamContent.Headers.ContentType = MediaTypeHeaderValue.Parse(file.ContentType);
                mp.Add(streamContent, file.Name, file.FileName);
            }

            using var msg = new HttpRequestMessage(method, relativeUrl) { Content = mp };
            var resp     = await client.SendAsync(msg, HttpCompletionOption.ResponseHeadersRead, ct);
            var payload  = await resp.Content.ReadAsStringAsync(ct);
            return new ContentResult
            {
                Content     = payload,
                ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
                StatusCode  = (int)resp.StatusCode
            };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "DocumentUpload multipart proxy {Method} failed: {Url}", method, relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new
            {
                error  = "Upstream API unreachable.",
                detail = ex.Message,
                inner  = ex.InnerException?.Message
            });
        }
    }
}
