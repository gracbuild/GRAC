// =====================================================================
// ExceptionCentreController (Web tier)  (charter §5 / §12.1.6)
// Session-gated proxy; org guarded; caller stamped from session.
// =====================================================================
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/exception-centre")]
public sealed class ExceptionCentreController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<ExceptionCentreController> logger) : ControllerBase
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

    // Evidence-type lookup (from evidence_type_master; used by approve modal).
    [HttpGet("lookups/evidence-types")]
    public Task<IActionResult> EvidenceTypes(CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        return ForwardGetAsync("api/practice/exception-centre/lookups/evidence-types", ct);
    }

    // Exception-type lookup (Temporary / Business / etc. from exception_type_master).
    [HttpGet("lookups/exception-types")]
    public Task<IActionResult> ExceptionTypes(CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        return ForwardGetAsync("api/practice/exception-centre/lookups/exception-types", ct);
    }

    // Linked-practice combo lookup. Org-scoped -- caller must be authorised
    // for the organizationId supplied on the query string (same guard as
    // the main list endpoint).
    [HttpGet("lookups/practices")]
    public Task<IActionResult> Practices(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var orgId = Request.Query["organizationId"];
        return ForwardGetAsync($"api/practice/exception-centre/lookups/practices?organizationId={orgId}", ct);
    }

    // Ops-triggered expiry sweep (or a scheduled task can hit the Api directly).
    [HttpPost("expire-due")]
    public Task<IActionResult> ExpireDue(CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            "api/practice/exception-centre/expire-due", "callerEmployeeId", ct);

    // ---- reads ----
    [HttpGet]
    public Task<IActionResult> List(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/exception-centre{qs}", ct);
    }

    [HttpGet("{id:long}")]
    public Task<IActionResult> Get(long id, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        return ForwardGetAsync($"api/practice/exception-centre/{id}", ct);
    }

    [HttpGet("{id:long}/attachments")]
    public Task<IActionResult> ListAttachments(long id, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        return ForwardGetAsync($"api/practice/exception-centre/{id}/attachments", ct);
    }

    [HttpGet("attachments/{attachmentId:long}")]
    public async Task<IActionResult> DownloadAttachment(long attachmentId, [FromQuery] bool inline, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        var client = BuildClient();
        try
        {
            var qs = inline ? "?inline=true" : "";
            var resp = await client.GetAsync($"api/practice/exception-centre/attachments/{attachmentId}{qs}",
                HttpCompletionOption.ResponseHeadersRead, ct);
            if (resp.StatusCode == HttpStatusCode.NotFound) return NotFound();
            var stream = await resp.Content.ReadAsStreamAsync(ct);
            var contentType = resp.Content.Headers.ContentType?.ToString() ?? "application/octet-stream";
            var fileName = resp.Content.Headers.ContentDisposition?.FileNameStar
                        ?? resp.Content.Headers.ContentDisposition?.FileName
                        ?? $"attachment-{attachmentId}";
            fileName = fileName.Trim('"');
            if (inline)
            {
                Response.Headers["Content-Disposition"] =
                    new System.Net.Http.Headers.ContentDispositionHeaderValue("inline") { FileName = fileName }.ToString();
                Response.Headers["X-Frame-Options"]         = "SAMEORIGIN";
                Response.Headers["Content-Security-Policy"] = "frame-ancestors 'self'";
                return File(stream, contentType);
            }
            return File(stream, contentType, fileName);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "ExceptionCentre.DownloadAttachment proxy failed for {Id}", attachmentId);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // ---- writes ----
    [HttpPost("{id:long}/approve")]
    public Task<IActionResult> Approve(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/exception-centre/{id}/approve",
            "approvedByEmployeeId", ct);

    [HttpPost("{id:long}/reject")]
    public Task<IActionResult> Reject(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/exception-centre/{id}/reject",
            "rejectedByEmployeeId", ct);

    // Migration 184 -- SLA Candidate approve. Distinct endpoint from
    // the Gap Candidate approve (no effective_until / approval_note
    // dialog fields; the requested days already sit on the row).
    // Web-tier ExceptionCentre uses explicit route wiring, not a
    // catch-all, so this proxy must be enumerated -- otherwise the
    // browser gets 404 before the request ever leaves the Web tier.
    [HttpPost("{id:long}/approve-sla")]
    public Task<IActionResult> ApproveSla(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/exception-centre/{id}/approve-sla",
            "approvedByEmployeeId", ct);

    // Multipart proxy for attachment upload -- ReadFormAsync + rebuild
    // (same pattern as document-uploads to avoid Kestrel/streaming races).
    [HttpPost("{id:long}/attachments")]
    [RequestSizeLimit(52_428_800)]
    public async Task<IActionResult> UploadAttachment(long id, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        if (!Request.HasFormContentType)
            return BadRequest(new { success = false, error = "multipart/form-data required." });

        var client = BuildClient();
        try
        {
            var form = await Request.ReadFormAsync(ct);
            using var mp = new MultipartFormDataContent("----pmboundary-" + Guid.NewGuid().ToString("N"));

            foreach (var kv in form)
            {
                if (kv.Key.Equals("UploadedByEmployeeId", StringComparison.OrdinalIgnoreCase)) continue;
                if (kv.Key.Equals("CallerDisplayName",   StringComparison.OrdinalIgnoreCase)) continue;
                foreach (var v in kv.Value) if (v is not null) mp.Add(new StringContent(v), kv.Key);
            }
            long.TryParse(HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey), out var callerId);
            if (callerId > 0) mp.Add(new StringContent(callerId.ToString()), "UploadedByEmployeeId");
            var callerNm = HttpContext.Session.GetString(PracticeSessionIdentity.UserKey);
            if (!string.IsNullOrWhiteSpace(callerNm)) mp.Add(new StringContent(callerNm), "CallerDisplayName");

            foreach (var f in form.Files)
            {
                if (f.Length == 0) continue;
                var sc = new StreamContent(f.OpenReadStream());
                if (!string.IsNullOrWhiteSpace(f.ContentType))
                    sc.Headers.ContentType = MediaTypeHeaderValue.Parse(f.ContentType);
                mp.Add(sc, f.Name, f.FileName);
            }

            using var msg = new HttpRequestMessage(HttpMethod.Post, $"api/practice/exception-centre/{id}/attachments") { Content = mp };
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
            logger.LogError(ex, "ExceptionCentre.UploadAttachment proxy failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    // ---- helpers ----
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
            error = StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller not authorised for this organization." });
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
            logger.LogError(ex, "ExceptionCentre GET proxy failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    private async Task<IActionResult> ForwardJsonWithCallerStampAsync(HttpMethod method, string relativeUrl, string employeeIdField, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        var client = BuildClient();
        try
        {
            string body;
            using (var sr = new StreamReader(Request.Body)) body = await sr.ReadToEndAsync(ct);

            long.TryParse(HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey), out var callerId);
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
                        if (p.Name.Equals(employeeIdField,        StringComparison.OrdinalIgnoreCase)) continue;
                        if (p.Name.Equals("callerDisplayName",    StringComparison.OrdinalIgnoreCase)) continue;
                        p.WriteTo(w);
                    }
                }
                if (callerId > 0) w.WriteNumber(employeeIdField, callerId);
                if (!string.IsNullOrWhiteSpace(callerNm)) w.WriteString("callerDisplayName", callerNm);
                w.WriteEndObject();
            }

            using var msg = new HttpRequestMessage(method, relativeUrl) { Content = new ByteArrayContent(ms.ToArray()) };
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
            logger.LogError(ex, "ExceptionCentre {Method} proxy failed: {Url}", method, relativeUrl);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }
}
