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

    // Review Frequency options for the Approve dialog (reuses
    // grac_practice.sp_risk_review_frequency_list, 293 -- see the Api-side
    // controller/service for why this is not a new frequency list).
    [HttpGet("lookups/review-frequencies")]
    public Task<IActionResult> ReviewFrequencies(CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        return ForwardGetAsync("api/practice/exception-centre/lookups/review-frequencies", ct);
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

    // Migration 260. The audit trail behind the analysis page and the
    // approver's form -- including who moved the effective window.
    [HttpGet("{id:long}/history")]
    public Task<IActionResult> ListHistory(long id, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        return ForwardGetAsync($"api/practice/exception-centre/{id}/history", ct);
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

    // Migration 327 -- "+ Add Custom Exception." Same bare collection
    // route as List (GET), but this Web-tier controller routes each verb
    // explicitly rather than via a catch-all (see approve-sla / analysis
    // comments above) -- so a POST here needed its own enumerated action.
    // Without it, routing still matches the route template (List's GET
    // proves the template resolves) but finds no action accepting POST,
    // which ASP.NET Core reports as 405 Method Not Allowed rather than
    // 404 -- exactly the symptom reported ("HTTP 405 on saving new
    // exception").
    //
    // Follow-up after ship: "Requested By" is now stamped server-side
    // from the caller's own session -- no dropdown, no client input --
    // the same way Approve/Reject stamp their own employee-id field via
    // ForwardJsonWithCallerStampAsync. Any requestedByEmployeeId the
    // client sends is discarded and overwritten here; it is never
    // trusted from the request body, same reasoning as every other
    // stamped field in this file.
    [HttpPost]
    public async Task<IActionResult> CreateCustom(CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });

        string body;
        using (var sr = new StreamReader(Request.Body)) body = await sr.ReadToEndAsync(ct);
        if (string.IsNullOrWhiteSpace(body))
            return BadRequest(new { error = "Request body is required." });

        long orgId;
        System.Text.Json.JsonDocument doc;
        try
        {
            doc = System.Text.Json.JsonDocument.Parse(body);
        }
        catch (System.Text.Json.JsonException)
        {
            return BadRequest(new { error = "Request body is not valid JSON." });
        }
        using (doc)
        {
            if (!doc.RootElement.TryGetProperty("organizationId", out var orgProp)
                || !orgProp.TryGetInt64(out orgId) || orgId <= 0)
                return BadRequest(new { error = "organizationId is required." });
            if (!HttpContext.IsOrganizationAllowed(orgId))
                return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller not authorised for this organization." });

            long.TryParse(HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey), out var callerId);
            var callerNm = HttpContext.Session.GetString(PracticeSessionIdentity.UserKey);
            var client = BuildClient();
            try
            {
                using var ms = new MemoryStream();
                using (var w = new System.Text.Json.Utf8JsonWriter(ms))
                {
                    w.WriteStartObject();
                    foreach (var p in doc.RootElement.EnumerateObject())
                    {
                        if (p.Name.Equals("requestedByEmployeeId", StringComparison.OrdinalIgnoreCase)) continue;
                        if (p.Name.Equals("callerDisplayName",     StringComparison.OrdinalIgnoreCase)) continue;
                        p.WriteTo(w);
                    }
                    if (callerId > 0) w.WriteNumber("requestedByEmployeeId", callerId);
                    if (!string.IsNullOrWhiteSpace(callerNm)) w.WriteString("callerDisplayName", callerNm);
                    w.WriteEndObject();
                }

                using var msg = new HttpRequestMessage(HttpMethod.Post, "api/practice/exception-centre") { Content = new ByteArrayContent(ms.ToArray()) };
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
                logger.LogError(ex, "ExceptionCentre.CreateCustom proxy failed");
                return BadRequest(new { success = false, error = ex.Message });
            }
        }
    }

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

    // =================================================================
    // Migration 257 -- Analysis stage proxies.
    //
    // Enumerated for the same reason approve-sla is: this Web controller
    // routes explicitly, with no catch-all, so an un-proxied endpoint 404s
    // in the Web tier before it ever reaches the Api.
    // =================================================================
    [HttpPost("{id:long}/analysis")]
    public Task<IActionResult> SaveAnalysis(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/exception-centre/{id}/analysis",
            "ownerEmployeeId", ct);

    [HttpPost("{id:long}/submit-for-approval")]
    public Task<IActionResult> SubmitForApproval(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/exception-centre/{id}/submit-for-approval",
            "actorEmployeeId", ct);

    [HttpGet("{id:long}/tasks")]
    public Task<IActionResult> ListTasks(long id, CancellationToken ct)
    {
        // Same session guard shape the other id-scoped GETs use. The Api
        // resolves the organisation from the row, so there is no
        // organizationId on the query string to check here.
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        return ForwardGetAsync($"api/practice/exception-centre/{id}/tasks", ct);
    }

    [HttpGet("{id:long}/task-candidates")]
    public Task<IActionResult> ListTaskCandidates(long id, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Task.FromResult<IActionResult>(Unauthorized(new { error = "Session expired." }));
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/exception-centre/{id}/task-candidates{qs}", ct);
    }

    [HttpPost("{id:long}/tasks")]
    public Task<IActionResult> LinkTask(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/exception-centre/{id}/tasks",
            "actorEmployeeId", ct);

    [HttpDelete("{id:long}/tasks/{taskId:long}")]
    public async Task<IActionResult> UnlinkTask(long id, long taskId, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        var client = BuildClient();
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        try
        {
            var resp    = await client.DeleteAsync(
                $"api/practice/exception-centre/{id}/tasks/{taskId}{qs}", ct);
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
            logger.LogError(ex, "ExceptionCentre DELETE task-link proxy failed for {Id}/{TaskId}", id, taskId);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

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
