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

    // Migration 284 -- practice context + tasks for the scope panel.
    // Organisation-scoped read, so it uses the same query-string guard
    // the other org-scoped reads on this controller use.
    [HttpGet("register/{riskId:long}/practice-context")]
    public Task<IActionResult> GetPracticeContext(long riskId, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/register/{riskId}/practice-context{qs}", ct);
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

    // ---- Organisation-owned threats / vulnerabilities (285, 286) -----
    // Org-scoped reads, so they take the same organization guard
    // assessment-options above takes rather than the session-only one.
    [HttpGet("threats")]
    public Task<IActionResult> ListThreats(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/threats{qs}", ct);
    }

    [HttpGet("vulnerabilities")]
    public Task<IActionResult> ListVulnerabilities(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/vulnerabilities{qs}", ct);
    }

    // Caller-stamped like every other write on this controller, so the
    // master row records who added it.
    //
    // guardBodyOrganization: organizationId arrives in the JSON body,
    // not the query string, so TryGuardOrganization cannot see it --
    // the same reason /custom and /duplicate-check set this. Without it
    // a caller could create a threat under another tenant's id.
    [HttpPost("threats")]
    public Task<IActionResult> CreateThreat(CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
               "api/practice/risk-centre/threats", "actorEmployeeId", ct,
               guardBodyOrganization: true);

    [HttpPost("vulnerabilities")]
    public Task<IActionResult> CreateVulnerability(CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
               "api/practice/risk-centre/vulnerabilities", "actorEmployeeId", ct,
               guardBodyOrganization: true);

    [HttpGet("register/{riskId:long}/threats")]
    public Task<IActionResult> GetThreatSelection(long riskId, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/register/{riskId}/threats", ct);
    }

    [HttpPost("register/{riskId:long}/threats")]
    public Task<IActionResult> SetThreatSelection(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
               $"api/practice/risk-centre/register/{riskId}/threats", "actorEmployeeId", ct,
               guardBodyOrganization: true);

    [HttpPost("analysis/{analysisId:long}/threats")]
    public Task<IActionResult> SetAnalysisThreatSelection(long analysisId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
               $"api/practice/risk-centre/analysis/{analysisId}/threats", "actorEmployeeId", ct,
               guardBodyOrganization: true);

    // ---- Risk Type: Confidentiality / Integrity / Availability (313, 314) --
    // Same shape as the threats/vulnerabilities block above -- org-guarded
    // read for the option list, session-guarded read for one risk's
    // current selection, caller-stamped body-guarded write. "actorEmployeeId"
    // is the same placeholder field name threats uses below; RiskTypeSelectionRequest
    // has no employee-id column of its own, so the API model simply ignores it.
    [HttpGet("risk-types")]
    public Task<IActionResult> ListRiskTypes(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/risk-types{qs}", ct);
    }

    [HttpGet("register/{riskId:long}/risk-types")]
    public Task<IActionResult> GetRiskTypeSelection(long riskId, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/register/{riskId}/risk-types", ct);
    }

    [HttpPost("register/{riskId:long}/risk-types")]
    public Task<IActionResult> SetRiskTypeSelection(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
               $"api/practice/risk-centre/register/{riskId}/risk-types", "actorEmployeeId", ct,
               guardBodyOrganization: true);

    // ---- Risk Category, multi-select (375, 376) ------------------------
    // Same shape as Risk Type immediately above -- session-guarded read
    // for one risk's current selection, caller-stamped body-guarded
    // write. No list-all-categories proxy: the API tier has no such
    // route either (the options ride on /scoring-options's Categories).
    [HttpGet("register/{riskId:long}/risk-categories")]
    public Task<IActionResult> GetRiskCategorySelection(long riskId, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/register/{riskId}/risk-categories", ct);
    }

    [HttpPost("register/{riskId:long}/risk-categories")]
    public Task<IActionResult> SetRiskCategorySelection(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
               $"api/practice/risk-centre/register/{riskId}/risk-categories", "actorEmployeeId", ct,
               guardBodyOrganization: true);

    [HttpPost("register/{riskId:long}/assess")]
    public Task<IActionResult> AssessRegisteredRisk(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/assess", "analysedByEmployeeId", ct);

    [HttpPost("register/{riskId:long}/assess/approve")]
    public Task<IActionResult> DecideRegisterAnalysis(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/assess/approve", "actorEmployeeId", ct);

    // ---- Residual Risk Analysis (migration 258) ----------------------
    // Record-scoped, like every other register route: there is no
    // organizationId in the URL, so the session guard is all this tier
    // can check and the API resolves the risk's organisation itself.
    [HttpPost("register/{riskId:long}/residual")]
    public Task<IActionResult> SaveResidualAnalysis(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/residual", "assessedByEmployeeId", ct);

    [HttpGet("register/{riskId:long}/residual")]
    public Task<IActionResult> GetResidualAnalysis(long riskId, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/register/{riskId}/residual", ct);
    }

    [HttpGet("register/{riskId:long}/residual/history")]
    public Task<IActionResult> GetResidualHistory(long riskId, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/register/{riskId}/residual/history", ct);
    }

    // ---- Practice / Asset mapping (migrations 261, 262) --------------
    // Record-scoped like the residual routes: no organizationId in the
    // URL, so the session guard is all this tier can check and the API
    // resolves the risk's organisation itself.
    [HttpGet("register/{riskId:long}/mapping")]
    public Task<IActionResult> GetMapping(long riskId, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/register/{riskId}/mapping", ct);
    }

    [HttpGet("register/{riskId:long}/mapping/options")]
    public Task<IActionResult> GetMappingOptions(long riskId, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/register/{riskId}/mapping/options{qs}", ct);
    }

    [HttpPost("register/{riskId:long}/practices")]
    public Task<IActionResult> MapPractice(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/practices", "actorEmployeeId", ct);

    // DELETE carries no body, so the actor cannot be stamped into JSON.
    // ForwardDeleteWithCallerStampAsync appends it to the query string
    // instead — and appends the SESSION's identity, ignoring anything the
    // client sent, so a caller cannot attribute an unmapping to somebody
    // else.
    [HttpDelete("register/{riskId:long}/practices/{practiceId:long}")]
    public Task<IActionResult> UnmapPractice(long riskId, long practiceId, CancellationToken ct)
        => ForwardDeleteWithCallerStampAsync(
            $"api/practice/risk-centre/register/{riskId}/practices/{practiceId}", ct);

    [HttpPost("register/{riskId:long}/dependencies")]
    public Task<IActionResult> MapDependency(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/dependencies", "actorEmployeeId", ct);

    [HttpDelete("register/{riskId:long}/dependencies/{dependencyTypeId:int}/{dependencyObjectId:long}")]
    public Task<IActionResult> UnmapDependency(long riskId, int dependencyTypeId, long dependencyObjectId, CancellationToken ct)
        => ForwardDeleteWithCallerStampAsync(
            $"api/practice/risk-centre/register/{riskId}/dependencies/{dependencyTypeId}/{dependencyObjectId}", ct);

    // ---- Treatment Option (migrations 261, 263) ----------------------
    [HttpPost("register/{riskId:long}/treatment-option")]
    public Task<IActionResult> SetTreatmentOption(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/treatment-option", "actorEmployeeId", ct);

    [HttpGet("register/{riskId:long}/treatment-state")]
    public Task<IActionResult> GetTreatmentState(long riskId, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/register/{riskId}/treatment-state", ct);
    }

    // Two shapes, two guards. An org-wide sweep names an organizationId
    // and gets the full org guard; a single-risk sweep names only a
    // riskRegisterId and gets the session guard, because there is no
    // organizationId in the URL for the org guard to check -- the same
    // split every other record-scoped register route makes.
    //
    // TryGuardOrganization cannot be used unconditionally here: it 400s
    // when organizationId is absent, which would reject the single-risk
    // form that the register screen actually calls.
    [HttpPost("register/treatment-sync")]
    public Task<IActionResult> SyncTreatment(CancellationToken ct)
    {
        var hasOrg = Request.Query.ContainsKey("organizationId");
        if (hasOrg)
        {
            if (!TryGuardOrganization(out var orgErr)) return Task.FromResult(orgErr!);
        }
        else if (!TryGuardSession(out var sesErr)) return Task.FromResult(sesErr!);

        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardEmptyPostAsync($"api/practice/risk-centre/register/treatment-sync{qs}", ct);
    }

    // ---- Acceptance, Review, Calendar (migration 264) ----------------
    [HttpGet("register/{riskId:long}/acceptance")]
    public Task<IActionResult> GetAcceptance(long riskId, CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync($"api/practice/risk-centre/register/{riskId}/acceptance", ct);
    }

    [HttpPost("register/{riskId:long}/acceptance")]
    public Task<IActionResult> SaveAcceptance(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/acceptance", "actorEmployeeId", ct);

    // Review frequency options for the acceptance select (293). Session
    // guard, not the organization guard the threat / vulnerability reads
    // take: frequency_master is a master table with no tenant column, so
    // there is no organizationId in the query string to check and
    // TryGuardOrganization would 400 every call.
    [HttpGet("review-frequencies")]
    public Task<IActionResult> ListReviewFrequencies(CancellationToken ct)
    {
        if (!TryGuardSession(out var err)) return Task.FromResult(err!);
        return ForwardGetAsync("api/practice/risk-centre/review-frequencies", ct);
    }

    [HttpPost("register/{riskId:long}/review")]
    public Task<IActionResult> PerformReview(long riskId, CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            $"api/practice/risk-centre/register/{riskId}/review", "reviewedByEmployeeId", ct);

    /// <summary>
    /// Bulk review (270). The reviewer is stamped from the session, the
    /// same way the single review and acceptance are — the browser cannot
    /// nominate who performed a review.
    ///
    /// <para>Route is <c>register/bulk-review</c>, deliberately not
    /// <c>register/{id}/...</c>: it acts on a set carried in the body, and
    /// a route id would imply one risk.</para>
    /// </summary>
    [HttpPost("register/bulk-review")]
    public Task<IActionResult> BulkReview(CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            "api/practice/risk-centre/register/bulk-review", "reviewedByEmployeeId", ct);

    /// <summary>
    /// Bulk accept (295). Stamps <c>actorEmployeeId</c> from the session —
    /// WHO PERFORMED the acceptance — exactly as the single acceptance
    /// does.
    ///
    /// <para><c>acceptedByEmployeeId</c> is deliberately NOT stamped and
    /// travels from the browser: it is who the acceptance is recorded
    /// FOR, which may be a committee chair or the risk owner rather than
    /// the person clicking. The same distinction the single Accept modal
    /// already makes, and <c>sp_risk_acceptance_save</c> still refuses an
    /// accepter from another organisation (56608).</para>
    /// </summary>
    [HttpPost("register/bulk-accept")]
    public Task<IActionResult> BulkAccept(CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            "api/practice/risk-centre/register/bulk-accept", "actorEmployeeId", ct);

    // ---- Risk acceptance approval authority (271) -------------------
    // Organization -> Risk Acceptance Approval Authority.
    //
    // organizationId-scoped, so the FULL org guard applies -- this is
    // configuration that decides who may approve accepting a risk, and a
    // session-only check would let one organisation read or rewrite
    // another's approval authority.

    [HttpGet("acceptance-authority")]
    public Task<IActionResult> GetAcceptanceAuthority(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/acceptance-authority{qs}", ct);
    }

    /// <summary>
    /// The actor is stamped from the session, as it is on every other
    /// risk write — the browser does not get to nominate who changed the
    /// approval authority, which is the whole point of auditing it.
    /// </summary>
    [HttpPost("acceptance-authority")]
    public Task<IActionResult> SaveAcceptanceAuthority(CancellationToken ct)
        => ForwardJsonWithCallerStampAsync(HttpMethod.Post,
            "api/practice/risk-centre/acceptance-authority", "actorEmployeeId", ct);

    /// <summary>
    /// Who approves accepting one risk. Session-guarded only, like the
    /// other /register/{id}/... reads: the caller supplies a risk id and
    /// the Api resolves the organisation from the row itself.
    /// </summary>
    [HttpGet("register/{riskId:long}/acceptance-authority")]
    public Task<IActionResult> ResolveAcceptanceAuthority(long riskId, CancellationToken ct)
    {
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync(
            $"api/practice/risk-centre/register/{riskId}/acceptance-authority{qs}", ct);
    }

    // Both of these are organizationId-scoped in the query string, so the
    // full org guard applies rather than the session-only one.
    [HttpGet("review-due")]
    public Task<IActionResult> ListReviewDue(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/review-due{qs}", ct);
    }

    [HttpGet("review-calendar")]
    public Task<IActionResult> GetReviewCalendar(CancellationToken ct)
    {
        if (!TryGuardOrganization(out var err)) return Task.FromResult(err!);
        var qs = Request.QueryString.HasValue ? Request.QueryString.Value : "";
        return ForwardGetAsync($"api/practice/risk-centre/review-calendar{qs}", ct);
    }

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

    // DELETE has no body to stamp the caller into, so the actor goes on
    // the query string instead — taken from the SESSION and never from
    // the client, so an unmapping cannot be attributed to somebody else.
    // Any actorEmployeeId or caller the client sent is dropped.
    private async Task<IActionResult> ForwardDeleteWithCallerStampAsync(string relativeUrl, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });

        long.TryParse(HttpContext.Session.GetString(PracticeSessionIdentity.EmployeeIdKey), out var callerId);
        var callerNm = HttpContext.Session.GetString(PracticeSessionIdentity.UserKey);

        var sep = relativeUrl.Contains('?') ? "&" : "?";
        var url = relativeUrl;
        if (callerId > 0) { url += $"{sep}actorEmployeeId={callerId}"; sep = "&"; }
        if (!string.IsNullOrWhiteSpace(callerNm))
            url += $"{sep}caller={WebUtility.UrlEncode(callerNm)}";

        var client = BuildClient();
        try
        {
            var resp    = await client.DeleteAsync(url, ct);
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
            logger.LogError(ex, "RiskCentre DELETE proxy failed: {Url}", relativeUrl);
            return StatusCode(StatusCodes.Status502BadGateway, new { error = "Upstream API unreachable." });
        }
    }

    // A POST whose whole payload is in the query string. The treatment
    // sweep is the only one: it takes no body, and sending an empty JSON
    // object would be a lie about the contract rather than a courtesy.
    private async Task<IActionResult> ForwardEmptyPostAsync(string relativeUrl, CancellationToken ct)
    {
        if (HttpContext.Session.GetString(PracticeSessionIdentity.UserKey) is null)
            return Unauthorized(new { error = "Session expired." });

        var client = BuildClient();
        try
        {
            using var msg = new HttpRequestMessage(HttpMethod.Post, relativeUrl);
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
            logger.LogError(ex, "RiskCentre POST proxy failed: {Url}", relativeUrl);
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
