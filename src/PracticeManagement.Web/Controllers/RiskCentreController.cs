// =====================================================================
// RiskCentreController (Web tier)  (charter §5 / §12.1.6)
// Session-gated proxy; org guarded; caller stamped from session.
// Mirrors ExceptionCentreController pattern with risk-appropriate routes.
// =====================================================================
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/risk-centre")]
public sealed class RiskCentreController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    ILogger<RiskCentreController> logger) : ControllerBase
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

    // ---- reads ----
    [HttpGet]
    public Task<IActionResult> List(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre{qs}", ct);
    }

    [HttpGet("{id:long}")]
    public Task<IActionResult> Get(long id, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/{id}", ct);
    }

    [HttpGet("{id:long}/attachments")]
    public Task<IActionResult> ListAttachments(long id, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/{id}/attachments", ct);
    }

    [HttpGet("attachments/{attachmentId:long}")]
    public async Task<IActionResult> DownloadAttachment(long attachmentId, [FromQuery] bool inline, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return err!;
        var client = BuildClient();
        try
        {
            var qs = inline ? "?inline=true" : "";
            var resp = await client.GetAsync($"api/practice/risk-centre/attachments/{attachmentId}{qs}",
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
            logger.LogError(ex, "RiskCentre.DownloadAttachment proxy failed for {Id}", attachmentId);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // ---- writes ----
    [HttpPost("{id:long}/accept")]
    public Task<IActionResult> Accept(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/{id}/accept",
            "acceptedByEmployeeId", ct);

    [HttpPost("{id:long}/reject")]
    public Task<IActionResult> Reject(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/{id}/reject",
            "rejectedByEmployeeId", ct);

    [HttpPost("{id:long}/withdraw")]
    public Task<IActionResult> Withdraw(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/{id}/withdraw",
            "actorEmployeeId", ct);

    // =================================================================
    // Risk Register (migrations 204-207)
    //
    // Same two guarantees as the rest of this proxy: the session must be
    // live, and the caller must be authorised for the organisation. The
    // second one is why the two body-scoped writes (custom risk create,
    // duplicate check) go through the guardBodyOrganization path — their
    // organizationId arrives in JSON, not the query string, and an
    // unchecked one would let a caller read or write another tenant's
    // register.
    // =================================================================

    [HttpGet("scoring-options")]
    public Task<IActionResult> ScoringOptions(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/scoring-options{qs}", ct);
    }

    [HttpGet("{id:long}/analysis")]
    public Task<IActionResult> GetAnalysis(long id, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/{id}/analysis", ct);
    }

    [HttpGet("{id:long}/analysis/history")]
    public Task<IActionResult> GetAnalysisHistory(long id, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/{id}/analysis/history", ct);
    }

    [HttpPost("{id:long}/analysis")]
    public Task<IActionResult> SaveAnalysis(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/{id}/analysis", "analysedByEmployeeId", ct);

    [HttpPost("{id:long}/assign")]
    public Task<IActionResult> Assign(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/{id}/assign", "actorEmployeeId", ct);

    [HttpPost("{id:long}/clarify")]
    public Task<IActionResult> Clarify(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/{id}/clarify", "actorEmployeeId", ct);

    [HttpPost("{id:long}/close-duplicate")]
    public Task<IActionResult> CloseDuplicate(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/{id}/close-duplicate", "actorEmployeeId", ct);

    [HttpPost("{id:long}/register")]
    public Task<IActionResult> Register(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/{id}/register", "registeredByEmployeeId", ct);

    [HttpPost("duplicate-check")]
    public Task<IActionResult> DuplicateCheck(CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            "api/practice/risk-centre/duplicate-check", "actorEmployeeId", ct,
            guardBodyOrganization: true);

    [HttpPost("custom")]
    public Task<IActionResult> CreateCustom(CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            "api/practice/risk-centre/custom", "createdByEmployeeId", ct,
            guardBodyOrganization: true);

    [HttpGet("register")]
    public Task<IActionResult> ListRegister(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/register{qs}", ct);
    }

    [HttpGet("register/{riskId:long}")]
    public Task<IActionResult> GetRegister(long riskId, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/register/{riskId}", ct);
    }

    [HttpPost("register/{riskId:long}/status")]
    public Task<IActionResult> SetRegisterStatus(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/status", "actorEmployeeId", ct);

    [HttpPost("register/{riskId:long}/owner")]
    public Task<IActionResult> SetRegisterOwner(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/owner", "actorEmployeeId", ct);

    // =================================================================
    // Phase B — migrations 208-211
    //
    // The org-scoped reads and writes go through TryGuardOrganization,
    // which reads organizationId from the query string. Config SAVE is a
    // POST but keeps its organizationId in the query string for exactly
    // that reason — putting it in the body would need the slower
    // guardBodyOrganization path for no benefit.
    // =================================================================

    // ---- §19 configuration ------------------------------------------
    [HttpGet("config")]
    public Task<IActionResult> GetConfig(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/config{qs}", ct);
    }

    [HttpPost("config")]
    public Task<IActionResult> SaveConfig(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/config{qs}", "actorEmployeeId", ct);
    }

    // ---- §19 approval workflow ---------------------------------------
    [HttpPost("{id:long}/submit-approval")]
    public Task<IActionResult> SubmitApproval(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/{id}/submit-approval", "actorEmployeeId", ct);

    [HttpPost("{id:long}/approve")]
    public Task<IActionResult> DecideApproval(long id, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/{id}/approve", "actorEmployeeId", ct);

    [HttpGet("approval-queue")]
    public Task<IActionResult> ApprovalQueue(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/approval-queue{qs}", ct);
    }

    // ---- §21 notifications -------------------------------------------
    [HttpPost("notifications/sweep")]
    public Task<IActionResult> SweepNotifications(CancellationToken ct)
    {
        // Org-scoped from the screen. The API also accepts an
        // organizationId-less sweep for a scheduled job, but this proxy
        // never offers it — a session-authenticated caller must not be
        // able to sweep tenants it cannot see.
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/notifications/sweep{qs}", "actorEmployeeId", ct);
    }

    [HttpGet("notifications")]
    public Task<IActionResult> ListNotifications(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/notifications{qs}", ct);
    }

    [HttpGet("notifications/counts")]
    public Task<IActionResult> NotificationCounts(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/notifications/counts{qs}", ct);
    }

    [HttpPost("notifications/{notificationId:long}/mark")]
    public Task<IActionResult> MarkNotification(long notificationId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/notifications/{notificationId}/mark", "actorEmployeeId", ct);

    // ---- §23 dashboard -----------------------------------------------
    [HttpGet("dashboard")]
    public Task<IActionResult> Dashboard(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/dashboard{qs}", ct);
    }

    [HttpGet("ageing")]
    public Task<IActionResult> Ageing(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/ageing{qs}", ct);
    }

    // ---- §22 treatment task, opt-in ----------------------------------
    [HttpPost("register/{riskId:long}/treatment-task")]
    public Task<IActionResult> RaiseTreatmentTask(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/treatment-task", "actorEmployeeId", ct);

    [HttpGet("register/{riskId:long}/treatment-tasks")]
    public Task<IActionResult> ListTreatmentTasks(long riskId, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/register/{riskId}/treatment-tasks", ct);
    }

    // ---- Two-stage assessment (migration 216) ------------------------
    [HttpGet("assessment-options")]
    public Task<IActionResult> AssessmentOptions(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/assessment-options{qs}", ct);
    }

    [HttpPost("register/{riskId:long}/assess")]
    public Task<IActionResult> AssessRegisteredRisk(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/assess", "analysedByEmployeeId", ct);

    [HttpPost("register/{riskId:long}/assess/approve")]
    public Task<IActionResult> DecideRegisterAnalysis(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/assess/approve", "actorEmployeeId", ct);

    // Multipart proxy for attachment upload -- same buffered-form pattern
    // as ExceptionCentre to avoid Kestrel/streaming races with [ApiController].
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

            using var msg = new HttpRequestMessage(HttpMethod.Post, $"api/practice/risk-centre/{id}/attachments") { Content = mp };
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
            logger.LogError(ex, "RiskCentre.UploadAttachment proxy failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    // ---- helpers (parallel to ExceptionCentreController) ----

    // The session-only half of TryGuardOrganization. The record-scoped
    // reads (a candidate, an analysis, one risk) have no organizationId
    // in the URL, so they can only check the session here — the API
    // resolves the record's organisation itself.
    private bool TryGuardSession(out IActionResult? error)
    {
        error = null;
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
        {
            error = Unauthorized(new { error = "Session expired." });
            return false;
        }
        return true;
    }

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
            logger.LogError(ex, "RiskCentre GET proxy failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    private async Task<IActionResult> ForwardJsonWithCallerStampAsync(HttpMethod method, string relativeUrl, string employeeIdField, CancellationToken ct,
        bool guardBodyOrganization = false)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });
        var client = BuildClient();
        try
        {
            string body;
            using (var sr = new StreamReader(Request.Body)) body = await sr.ReadToEndAsync(ct);

            // Body-scoped org guard. Custom risk creation and duplicate
            // detection carry organizationId in JSON rather than the
            // query string, so TryGuardOrganization cannot see it.
            if (guardBodyOrganization)
            {
                long bodyOrgId = 0;
                if (!string.IsNullOrWhiteSpace(body))
                {
                    using var probe = System.Text.Json.JsonDocument.Parse(body);
                    if (probe.RootElement.TryGetProperty("organizationId", out var orgEl)
                        && orgEl.ValueKind == System.Text.Json.JsonValueKind.Number)
                        bodyOrgId = orgEl.GetInt64();
                }
                if (bodyOrgId <= 0)
                    return BadRequest(new { success = false, error = "organizationId is required." });
                if (!HttpContext.IsOrganizationAllowed(bodyOrgId))
                    return StatusCode(StatusCodes.Status403Forbidden,
                        new { success = false, error = "Caller not authorised for this organization." });
            }

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
                        if (p.Name.Equals(employeeIdField,     StringComparison.OrdinalIgnoreCase)) continue;
                        if (p.Name.Equals("callerDisplayName", StringComparison.OrdinalIgnoreCase)) continue;
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
            logger.LogError(ex, "RiskCentre {Method} proxy failed: {Url}", method, relativeUrl);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }
}
