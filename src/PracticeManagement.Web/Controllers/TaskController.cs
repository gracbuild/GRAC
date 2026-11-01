// =====================================================================
// TaskController (Web tier)  (charter §12.1.3 / §12.1.6)
//
// Thin HTTP proxy from Web -> Api for the Task Center. Kept independent
// of PracticeManagementGatewayController (which is scoped to secure
// query/manage envelopes for existing entities).
//
// Charter §7 API convention preserved: /api/practice/{feature}/{action}
// on the Api side; the Web tier exposes /practice/api/{feature}/{action}
// so the browser can call it without CORS or the Api being publicly
// reachable.
//
// PROJECT-WIDE RULE (enforced):
//   The Web tier NEVER opens its own SQL connection for feature/task
//   data. All DB access goes through the Api tier, which owns the single
//   shared connection string via
//   PracticeManagement.Api.Infrastructure.SqlConnectionStringResolver.
//   (The only Web-tier exception is PracticeLoginService, needed for
//   login itself, before an Api token exists.) The earlier direct SQL
//   call from FeatureStatus was a temporary shortcut that violated this
//   rule and is now removed — FeatureStatus proxies to
//   /api/practice/feature-flags/status.
//
// TASK CENTRE v2 (BRD 16 Aug 2026)
//   The v2 routes are grouped at the bottom. They follow the same
//   pattern as the originals: GETs that carry an organizationId are
//   guarded by session + IsOrganizationAllowed; everything else is a
//   straight body forward, because the Api tier owns the governance
//   rules and re-implementing them here would create two sources of
//   truth for the same BRD clause.
// =====================================================================
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Web.Security;
using ControlManagement.Security;

namespace PracticeManagement.Web.Controllers;

[ApiController]
[Route("practice/api/tasks")]
public sealed class TaskController(
    IHttpClientFactory httpClientFactory,
    IConfiguration configuration,
    PermissionPolicy permissionPolicy,
    ILogger<TaskController> logger) : ControllerBase
{
    // The task-governance approvals (priority reduction / SLA extension) are
    // decided from Exceptions & Waivers, so they require the APPROVE grant on
    // the exception-centre menu (Role Master -> Approve checkbox) -- the same
    // permission that gates the Approve button in the grid.
    private string[] Roles() =>
        (HttpContext.Session.GetString(PracticeSessionIdentity.RolesKey) ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries);

    private bool CanApprove() =>
        permissionPolicy.IsAllowed(Roles(), PermissionAreaMap.For("exception-centre"), "APPROVE");

    private IActionResult? ApprovePermissionGuard() =>
        HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null
            ? Unauthorized(new { error = "Session expired. Please sign in again." })
            : CanApprove() ? null
            : StatusCode(StatusCodes.Status403Forbidden,
                new { error = "You do not have Approve permission for Exceptions & Waivers." });

    // Uses the same ApiBaseUrl config key SecurePracticeClient already reads
    // (default localhost:5045). Zero appsettings changes needed.
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

    /// <summary>
    /// UI probe — is Task Center enabled for the given organization?
    ///
    /// organizationId MUST be supplied by the caller (the browser picks it
    /// from the Organization filter). We validate that the caller is
    /// authorised to operate on that org (GLOBAL scope OR the id is in the
    /// user's AllowedOrganizationIds) before proxying to the Api. This
    /// prevents an org employee from probing feature state for another
    /// organisation by hand-crafting the querystring.
    /// </summary>
    [HttpGet("counts")]
    public async Task<IActionResult> Counts([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        var client = BuildClient();
        try
        {
            var qs = organizationId.HasValue ? "?organizationId=" + organizationId.Value : "";
            var resp    = await client.GetAsync("api/practice/tasks/counts" + qs, cancellationToken);
            var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
            return new ContentResult { Content = payload, ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json", StatusCode = (int)resp.StatusCode };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController.Counts proxy failed");
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // Migration 256 -- proxy for the Source filter's per-source counts.
    // The Web TaskController has no catch-all route, so every API
    // endpoint needs an explicit method here; this mirrors Counts above.
    [HttpGet("source-counts")]
    public async Task<IActionResult> SourceCounts(
        [FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        if (organizationId.HasValue && !HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });

        var client = BuildClient();
        try
        {
            var qs = organizationId.HasValue ? "?organizationId=" + organizationId.Value : "";
            var resp    = await client.GetAsync("api/practice/tasks/source-counts" + qs, cancellationToken);
            var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
            return new ContentResult
            {
                Content     = payload,
                ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
                StatusCode  = (int)resp.StatusCode
            };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController.SourceCounts proxy failed");
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    [HttpGet("feature-status")]
    public async Task<IActionResult> FeatureStatus(
        [FromQuery] long? organizationId,
        CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        if (!organizationId.HasValue || organizationId.Value <= 0)
            return BadRequest(new
            {
                enabled = false,
                organizationId = (long?)null,
                reason = "organizationId is required. Select an organization first."
            });

        if (!HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden, new
            {
                enabled = false,
                organizationId,
                reason  = "Caller is not authorised for the requested organization."
            });

        var client = BuildClient();
        if (client.BaseAddress is null)
            return Ok(new { enabled = false, organizationId, reason = "PracticeManagementApi:BaseUrl is not configured." });

        var qs = "?featureCode=screen.tasks&organizationId=" + organizationId.Value;
        try
        {
            var resp = await client.GetAsync("api/practice/feature-flags/status" + qs, cancellationToken);
            return await ForwardAsync(resp, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "TaskController.FeatureStatus proxy failed; failing closed.");
            return Ok(new { enabled = false, organizationId, reason = "Probe error; fail closed." });
        }
    }

    [HttpGet]
    public async Task<IActionResult> List([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        if (!organizationId.HasValue || organizationId.Value <= 0)
            return BadRequest(new { error = "organizationId is required. Select an organization first." });

        if (!HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });

        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });

        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        try
        {
            var resp = await client.GetAsync("api/practice/tasks" + qs, cancellationToken);
            return await ForwardAsync(resp, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController.List proxy failed");
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    [HttpPost]
    public async Task<IActionResult> Create(CancellationToken cancellationToken)
    {
        return await ForwardBodyAsync(HttpMethod.Post, "api/practice/tasks", cancellationToken);
    }

    [HttpPost("{id:long}/assign")]
    public Task<IActionResult> Assign(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/assign", cancellationToken);

    [HttpPost("{id:long}/transition")]
    public Task<IActionResult> Transition(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/transition", cancellationToken);

    [HttpPost("{id:long}/close")]
    public Task<IActionResult> Close(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/close", cancellationToken);

    // Reopen (479). Unlike Close, the Api gate here is admin-OR-owner, so
    // the Api must learn whether the caller is an organisation admin. That
    // flag is opt-in (CallerIdentityHandler.StampAdminFlag), so this proxy
    // must ask ForwardBodyAsync to stamp it -- otherwise every caller,
    // admins included, reaches sp_task_reopen as a non-admin and only the
    // owner can reopen (403 REOPEN_FORBIDDEN for an admin who is not it).
    [HttpPost("{id:long}/reopen")]
    public Task<IActionResult> Reopen(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/reopen", cancellationToken, stampAdmin: true);

    // =================================================================
    // Task Centre v2  (migrations 192-196)
    // =================================================================

    /// <summary>
    /// Operational detail view (BRD §16). Session-guarded but NOT
    /// org-guarded on the querystring: the caller supplies only a task
    /// id, and the Api resolves the organisation from the row itself.
    /// Cross-org isolation for detail reads is enforced by the Api's own
    /// org scoping, exactly as it is for /{id}/close today.
    /// </summary>
    [HttpGet("{id:long}")]
    public Task<IActionResult> Detail(long id, CancellationToken cancellationToken)
        => ForwardGetAsync($"api/practice/tasks/{id}", cancellationToken);

    [HttpGet("{id:long}/eligibility")]
    public Task<IActionResult> Eligibility(long id, CancellationToken cancellationToken)
        => ForwardGetAsync($"api/practice/tasks/{id}/eligibility", cancellationToken);

    // ---- Task edit (migration 269) ----------------------------------
    // Thin proxies, like everything else in this tier: the Web project
    // holds no connection and makes no decision. The per-field outcome
    // list and every §7/§8 rule come back from the Api untouched.

    /// <summary>Which fields the editor may offer, and the status
    /// transitions that are legal right now.</summary>
    [HttpGet("{id:long}/edit-options")]
    public Task<IActionResult> EditOptions(long id, CancellationToken cancellationToken)
        => ForwardGetAsync($"api/practice/tasks/{id}/edit-options", cancellationToken);

    /// <summary>
    /// The single task edit save. PUT, matching the Api — a 200 here does
    /// not mean every field applied; the response's per-field outcomes say
    /// which were applied and which became Exception Centre requests.
    /// </summary>
    [HttpPut("{id:long}")]
    public Task<IActionResult> Update(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Put, $"api/practice/tasks/{id}", cancellationToken);

    /// <summary>Source -> Tasks panel (BRD §15). Called by the Gap /
    /// Exception / Risk / Assurance detail screens.</summary>
    [HttpGet("by-source")]
    public async Task<IActionResult> BySource([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        if (organizationId.HasValue && organizationId.Value > 0
            && !HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });

        return await ForwardGetAsync("api/practice/tasks/by-source" + (Request.QueryString.Value ?? ""), cancellationToken);
    }

    /// <summary>Owner ladder preview (BRD §6). organizationId is required
    /// and org-guarded — the ladder reads that organisation's ownership
    /// master data.</summary>
    [HttpGet("owner-resolve")]
    public async Task<IActionResult> OwnerResolve([FromQuery] long? organizationId, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        if (!organizationId.HasValue || organizationId.Value <= 0)
            return BadRequest(new { error = "organizationId is required." });

        if (!HttpContext.IsOrganizationAllowed(organizationId.Value))
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Caller is not authorised for the requested organization." });

        return await ForwardGetAsync("api/practice/tasks/owner-resolve" + (Request.QueryString.Value ?? ""), cancellationToken);
    }

    [HttpPost("{id:long}/priority")]
    public Task<IActionResult> ChangePriority(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/priority", cancellationToken);

    [HttpPost("{id:long}/sla-extension")]
    public Task<IActionResult> RequestSlaExtension(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/sla-extension", cancellationToken);

    [HttpPost("{id:long}/children")]
    public Task<IActionResult> CreateChild(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/children", cancellationToken);

    [HttpPost("{id:long}/complete")]
    public Task<IActionResult> Complete(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/complete", cancellationToken);

    [HttpPost("{id:long}/activity")]
    public Task<IActionResult> AddActivity(long id, CancellationToken cancellationToken)
        => ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/{id}/activity", cancellationToken);

    [HttpPost("requests/{exceptionRequestId:long}/approve-sla-extension")]
    public Task<IActionResult> ApproveSlaExtension(long exceptionRequestId, CancellationToken cancellationToken)
    {
        var guard = ApprovePermissionGuard();
        if (guard is not null) return Task.FromResult(guard);
        return ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/requests/{exceptionRequestId}/approve-sla-extension", cancellationToken);
    }

    [HttpPost("requests/{exceptionRequestId:long}/approve-priority-reduction")]
    public Task<IActionResult> ApprovePriorityReduction(long exceptionRequestId, CancellationToken cancellationToken)
    {
        var guard = ApprovePermissionGuard();
        if (guard is not null) return Task.FromResult(guard);
        return ForwardBodyAsync(HttpMethod.Post, $"api/practice/tasks/requests/{exceptionRequestId}/approve-priority-reduction", cancellationToken);
    }

    /// <summary>
    /// Evidence upload (BRD §16).
    ///
    /// 2026-10-10: ReadFormAsync + rebuild, the pattern Document Upload and
    /// Exception Centre already use. This used to stream Request.Body
    /// straight into a StreamContent, which races with [ApiController]'s
    /// input-formatter probing (see DocumentUploadController
    /// .ForwardMultipartAsync): the Api received a truncated/empty multipart
    /// body, its [FromForm] binding failed, and it answered 400 with a
    /// ProblemDetails body that has no "error" field -- so the browser could
    /// only say "Upload failed (HTTP 400)". Rebuilding also stamps the
    /// uploader from the session (uploadedByEmployeeId), which the browser
    /// never sent and must not be trusted to send.
    /// </summary>
    [HttpPost("{id:long}/attachments")]
    [RequestSizeLimit(52_428_800)] // 50 MB — matches the Api-side limit
    public async Task<IActionResult> UploadAttachment(long id, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });
        if (!Request.HasFormContentType)
            return BadRequest(new { error = "Request is not multipart/form-data." });

        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });

        try
        {
            var form = await Request.ReadFormAsync(cancellationToken);
            using var mp = new MultipartFormDataContent("----pmboundary-" + Guid.NewGuid().ToString("N"));

            // Text fields the browser sent (evidenceDescription), except the
            // uploader -- that comes from the session below.
            foreach (var kv in form)
            {
                if (kv.Key.Equals("uploadedByEmployeeId", StringComparison.OrdinalIgnoreCase)) continue;
                foreach (var v in kv.Value)
                    if (v is not null) mp.Add(new StringContent(v), kv.Key);
            }
            if (long.TryParse(HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey), out var callerId)
                && callerId > 0)
                mp.Add(new StringContent(callerId.ToString()), "uploadedByEmployeeId");

            foreach (var file in form.Files)
            {
                if (file.Length == 0) continue;
                var sc = new StreamContent(file.OpenReadStream());
                if (!string.IsNullOrWhiteSpace(file.ContentType))
                    sc.Headers.ContentType = MediaTypeHeaderValue.Parse(file.ContentType);
                mp.Add(sc, file.Name, file.FileName);
            }

            using var req = new HttpRequestMessage(HttpMethod.Post, $"api/practice/tasks/{id}/attachments")
            {
                Content = mp
            };
            // 477: the identical-file check honours the Evidence Center
            // visibility rule, which needs the admin flag.
            CallerIdentityHandler.StampAdminFlag(HttpContext, req);

            var resp = await client.SendAsync(req, cancellationToken);
            return await ForwardAsync(resp, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController.UploadAttachment proxy failed for task {TaskId}", id);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // ---- 477: Select from Evidence Center on a task ------------------
    // organizationId is REQUIRED and checked against the session (the
    // list is the organisation's evidence); the API checks the task
    // belongs to it. The admin flag feeds the visibility rule.
    [HttpGet("{id:long}/evidence-center")]
    public Task<IActionResult> EvidenceCandidates(long id, CancellationToken cancellationToken)
        => ForwardOrgScopedGetAsync(id, "evidence-center", nameof(EvidenceCandidates), cancellationToken);

    [HttpPost("{id:long}/evidence-links")]
    public Task<IActionResult> LinkEvidence(long id, CancellationToken cancellationToken)
        => ForwardOrgScopedPostAsync(id, "evidence-links", nameof(LinkEvidence), cancellationToken);

    // ---- 482: recurring evidence on Complete Task -------------------
    // Same organisation rule as the two 477 routes above.
    [HttpGet("{id:long}/recurring-evidence")]
    public Task<IActionResult> RecurringEvidence(long id, CancellationToken cancellationToken)
        => ForwardOrgScopedGetAsync(id, "recurring-evidence", nameof(RecurringEvidence), cancellationToken);

    [HttpPost("{id:long}/recurring-evidence")]
    public Task<IActionResult> SaveRecurringEvidence(long id, CancellationToken cancellationToken)
        => ForwardOrgScopedPostAsync(id, "recurring-evidence", nameof(SaveRecurringEvidence), cancellationToken);

    // 477 / 482: a task route whose organizationId (query string) is
    // REQUIRED and checked against the session. The admin flag feeds the
    // Evidence Center visibility rule.
    private async Task<IActionResult> ForwardOrgScopedGetAsync(
        long id, string route, string operation, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });
        if (!long.TryParse(Request.Query["organizationId"], out var orgId) || orgId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (!HttpContext.IsOrganizationAllowed(orgId))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller is not authorised for the requested organization." });

        var client = BuildClient();
        try
        {
            var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
            using var req = new HttpRequestMessage(HttpMethod.Get, $"api/practice/tasks/{id}/{route}{qs}");
            CallerIdentityHandler.StampAdminFlag(HttpContext, req);
            var resp = await client.SendAsync(req, cancellationToken);
            return await ForwardAsync(resp, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController.{Operation} proxy failed for task {TaskId}", operation, id);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // The JSON body's organizationId is REQUIRED and checked the same way.
    private async Task<IActionResult> ForwardOrgScopedPostAsync(
        long id, string route, string operation, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        string bodyJson;
        using (var reader = new StreamReader(Request.Body, Encoding.UTF8))
            bodyJson = await reader.ReadToEndAsync(cancellationToken);
        long orgId = 0;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(string.IsNullOrWhiteSpace(bodyJson) ? "{}" : bodyJson);
            if (doc.RootElement.TryGetProperty("organizationId", out var p) && p.ValueKind == System.Text.Json.JsonValueKind.Number)
                p.TryGetInt64(out orgId);
        }
        catch (System.Text.Json.JsonException) { /* treated as missing */ }
        if (orgId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        if (!HttpContext.IsOrganizationAllowed(orgId))
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller is not authorised for the requested organization." });

        var client = BuildClient();
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, $"api/practice/tasks/{id}/{route}")
            {
                Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
            };
            CallerIdentityHandler.StampAdminFlag(HttpContext, req);
            var resp = await client.SendAsync(req, cancellationToken);
            return await ForwardAsync(resp, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController.{Operation} proxy failed for task {TaskId}", operation, id);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    /// <summary>Evidence download (BRD §16). Binary, so it cannot go
    /// through ForwardAsync's string path.</summary>
    [HttpGet("attachments/{attachmentId:long}")]
    public async Task<IActionResult> DownloadAttachment(long attachmentId, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });

        try
        {
            var resp = await client.GetAsync($"api/practice/tasks/attachments/{attachmentId}", cancellationToken);
            if (!resp.IsSuccessStatusCode)
                return await ForwardAsync(resp, cancellationToken);

            var bytes       = await resp.Content.ReadAsByteArrayAsync(cancellationToken);
            var contentType = resp.Content.Headers.ContentType?.ToString() ?? "application/octet-stream";
            var fileName    = resp.Content.Headers.ContentDisposition?.FileNameStar
                           ?? resp.Content.Headers.ContentDisposition?.FileName?.Trim('"')
                           ?? $"attachment-{attachmentId}";

            return File(bytes, contentType, fileName);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController.DownloadAttachment proxy failed for attachment {AttachmentId}", attachmentId);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // =================================================================
    // Forwarding helpers
    // =================================================================

    private async Task<IActionResult> ForwardGetAsync(string upstreamPath, CancellationToken cancellationToken)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired. Please sign in again." });

        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });

        try
        {
            var resp = await client.GetAsync(upstreamPath, cancellationToken);
            return await ForwardAsync(resp, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController GET proxy failed for {Path}", upstreamPath);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    private async Task<IActionResult> ForwardBodyAsync(HttpMethod method, string upstreamPath, CancellationToken cancellationToken, bool stampAdmin = false)
    {
        var client = BuildClient();
        if (client.BaseAddress is null)
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "PracticeManagementApi:BaseUrl is not configured." });

        string bodyJson;
        using (var reader = new StreamReader(Request.Body, Encoding.UTF8))
            bodyJson = await reader.ReadToEndAsync(cancellationToken);
        if (string.IsNullOrWhiteSpace(bodyJson)) bodyJson = "{}";

        using var req = new HttpRequestMessage(method, upstreamPath)
        {
            Content = new StringContent(bodyJson, Encoding.UTF8, "application/json")
        };
        // The caller's employee id is stamped automatically on every call by
        // CallerIdentityHandler; the admin flag is opt-in and stamped only
        // when a route (e.g. reopen) needs the Api to authorize by it.
        if (stampAdmin) CallerIdentityHandler.StampAdminFlag(HttpContext, req);
        try
        {
            var resp = await client.SendAsync(req, cancellationToken);
            return await ForwardAsync(resp, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "TaskController proxy failed for {Method} {Path}", method, upstreamPath);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    private async Task<IActionResult> ForwardAsync(HttpResponseMessage resp, CancellationToken cancellationToken)
    {
        var payload = await resp.Content.ReadAsStringAsync(cancellationToken);
        return new ContentResult
        {
            Content     = payload,
            ContentType = resp.Content.Headers.ContentType?.ToString() ?? "application/json",
            StatusCode  = (int)resp.StatusCode
        };
    }
}
