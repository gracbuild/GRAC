// =====================================================================
// RiskCentreController  (charter §5)
// Route: /api/practice/risk-centre/...
// Mirrors ExceptionCentreController; risk terminology (Accept/Reject/
// Withdraw) instead of Approve/Reject/Withdraw.
// =====================================================================
using Microsoft.AspNetCore.Mvc;
using PracticeManagement.Api.Models;
using PracticeManagement.Api.Services;

namespace PracticeManagement.Api.Controllers;

[ApiController]
[Route("api/practice/risk-centre")]
public sealed class RiskCentreController(
    IRiskCentreService svc,
    ILogger<RiskCentreController> logger) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> List(
        [FromQuery] long organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListAsync(organizationId, statusCode, page, pageSize, ct));
    }

    [HttpGet("{id:long}")]
    public async Task<IActionResult> Get(long id, CancellationToken ct)
    {
        var r = await svc.GetAsync(id, ct);
        return r is null ? NotFound() : Ok(r);
    }

    [HttpPost("{id:long}/accept")]
    public async Task<IActionResult> Accept(long id, [FromBody] RiskAcceptRequest req, CancellationToken ct)
    {
        try
        {
            if (req is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await svc.AcceptAsync(id, req, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RiskCentre.Accept failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    [HttpPost("{id:long}/reject")]
    public async Task<IActionResult> Reject(long id, [FromBody] RiskRejectRequest req, CancellationToken ct)
    {
        try
        {
            if (req is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await svc.RejectAsync(id, req, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RiskCentre.Reject failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    [HttpPost("{id:long}/withdraw")]
    public async Task<IActionResult> Withdraw(long id, [FromBody] RiskWithdrawRequest req, CancellationToken ct)
    {
        try
        {
            if (req is null) return BadRequest(new { success = false, error = "request body is required." });
            var result = await svc.WithdrawAsync(id, req, ct);
            return result.Success ? Ok(result) : BadRequest(result);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RiskCentre.Withdraw failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    [HttpGet("{id:long}/attachments")]
    public async Task<IActionResult> ListAttachments(long id, CancellationToken ct)
        => Ok(await svc.ListAttachmentsAsync(id, ct));

    // Same evidence-style semantics as exception centre.
    [HttpPost("{id:long}/attachments")]
    [Consumes("multipart/form-data")]
    [RequestSizeLimit(52_428_800)]
    public async Task<IActionResult> UploadAttachment(long id,
        [FromForm] RiskAttachmentUploadForm form, CancellationToken ct)
    {
        try
        {
            if (form is null) return BadRequest(new { success = false, error = "form is required." });
            var method = string.IsNullOrWhiteSpace(form.CollectionMethodCode) ? "Manual" : form.CollectionMethodCode;

            if (method.Equals("Manual", StringComparison.OrdinalIgnoreCase))
            {
                if (form.File is null || form.File.Length == 0)
                    return BadRequest(new { success = false, error = "Manual attachment requires a file." });
            }
            else
            {
                if (string.IsNullOrWhiteSpace(form.EvidenceLocation) || string.IsNullOrWhiteSpace(form.EvidenceLocator))
                    return BadRequest(new { success = false, error = "Automated attachment requires evidenceLocation and evidenceLocator." });
            }

            byte[]? bytes = null;
            string? fileName = null;
            string? contentType = null;
            if (form.File is { Length: > 0 } f)
            {
                using var ms = new MemoryStream();
                await f.CopyToAsync(ms, ct);
                bytes = ms.ToArray();
                fileName = f.FileName;
                contentType = f.ContentType;
            }

            var attId = await svc.SaveAttachmentAsync(id, method, form.EvidenceTypeCode,
                fileName, contentType, bytes,
                form.EvidenceLocation, form.EvidenceLocator,
                form.UploadedByEmployeeId, form.CallerDisplayName, ct);
            return Ok(new { success = attId > 0, attachmentId = attId });
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "RiskCentre.UploadAttachment failed for {Id}", id);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    [HttpGet("attachments/{attachmentId:long}")]
    public async Task<IActionResult> DownloadAttachment(long attachmentId,
        [FromQuery] bool inline, CancellationToken ct)
    {
        var (bytes, fileName, contentType) = await svc.GetAttachmentAsync(attachmentId, ct);
        if (bytes is null) return NotFound();
        var ct2 = string.IsNullOrWhiteSpace(contentType) ? "application/octet-stream" : contentType;
        if (inline)
        {
            var cd = new System.Net.Http.Headers.ContentDispositionHeaderValue("inline") { FileName = fileName };
            Response.Headers["Content-Disposition"] = cd.ToString();
            return File(bytes, ct2);
        }
        return File(bytes, ct2, fileName);
    }

    // =================================================================
    // Risk Register (migrations 204-207)
    // BRD: "Risk Candidate Analysis and Risk Register"
    //
    // Validation lives in the stored procedures — see 206's header for
    // why. These actions therefore only guard what SQL cannot see (a
    // missing body, a non-positive id) and pass the proc's message
    // through unchanged, because those messages cite the BRD clause the
    // caller violated.
    // =================================================================

    // §7, §12, §13 — the organisation's own scale, categories and sources.
    [HttpGet("scoring-options")]
    public async Task<IActionResult> ScoringOptions([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.GetScoringOptionsAsync(organizationId, ct));
    }

    // §7.1 — current analysis for a candidate.
    [HttpGet("{id:long}/analysis")]
    public async Task<IActionResult> GetAnalysis(long id, CancellationToken ct)
    {
        var a = await svc.GetAnalysisAsync(id, null, ct);
        return a is null ? NotFound() : Ok(a);
    }

    // §20 — every retained version.
    [HttpGet("{id:long}/analysis/history")]
    public async Task<IActionResult> GetAnalysisHistory(long id, CancellationToken ct)
        => Ok(await svc.GetAnalysisHistoryAsync(id, ct));

    // §7 — save. Each call writes a NEW version; nothing is overwritten.
    [HttpPost("{id:long}/analysis")]
    public async Task<IActionResult> SaveAnalysis(long id, [FromBody] RiskAnalysisSaveRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.SaveAnalysisAsync(id, null, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §6.2, §18 — assign the Risk Analyst.
    [HttpPost("{id:long}/assign")]
    public async Task<IActionResult> Assign(long id, [FromBody] RiskCandidateAssignRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.AssignAsync(id, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §8C — return for clarification / re-analysis.
    [HttpPost("{id:long}/clarify")]
    public async Task<IActionResult> Clarify(long id, [FromBody] RiskCandidateClarifyRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.ClarifyAsync(id, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §15 — close the candidate against an existing register entry.
    [HttpPost("{id:long}/close-duplicate")]
    public async Task<IActionResult> CloseDuplicate(long id, [FromBody] RiskCandidateDuplicateRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.CloseDuplicateAsync(id, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §8A — Route A. Fails with a 560xx message if the analysis is
    // absent or incomplete; that failure IS BRD §24 rule 1.
    [HttpPost("{id:long}/register")]
    public async Task<IActionResult> Register(long id, [FromBody] RiskRegisterRequest? req, CancellationToken ct)
    {
        var result = await svc.RegisterAsync(id,
            req ?? new RiskRegisterRequest(null, null, null, null, null, null, null, null, null), ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §15 — advisory duplicate detection, used before either route
    // registers. Never blocks; the analyst decides.
    [HttpPost("duplicate-check")]
    public async Task<IActionResult> DuplicateCheck([FromBody] RiskDuplicateCheckRequest req, CancellationToken ct)
    {
        if (req is null || req.OrganizationId <= 0)
            return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.CheckDuplicatesAsync(req, ct));
    }

    // §4B, §11 — Route B. Creation and analysis in one call; no
    // candidate row is created.
    [HttpPost("custom")]
    public async Task<IActionResult> CreateCustom([FromBody] RiskCustomCreateRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.CreateCustomRiskAsync(req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §9, §23 — the register grid.
    [HttpGet("register")]
    public async Task<IActionResult> ListRegister(
        [FromQuery] long organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? sourceTypeCode,
        [FromQuery] string? categoryCode,
        [FromQuery] string? ratingCode,
        [FromQuery] long? ownerEmployeeId,
        [FromQuery] string? search,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListRegisterAsync(organizationId, statusCode, sourceTypeCode,
            categoryCode, ratingCode, ownerEmployeeId, search, page, pageSize, ct));
    }

    // §9.1 + §10 — the risk and its whole traceability chain.
    [HttpGet("register/{riskId:long}")]
    public async Task<IActionResult> GetRegister(long riskId, CancellationToken ct)
    {
        var r = await svc.GetRegisterAsync(riskId, ct);
        return r is null ? NotFound() : Ok(r);
    }

    // §17 — Active / UnderTreatment / Accepted / Monitoring / Closed / Retired.
    [HttpPost("register/{riskId:long}/status")]
    public async Task<IActionResult> SetRegisterStatus(long riskId, [FromBody] RiskRegisterStatusRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.SetRegisterStatusAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §18 — Risk Owner accepts ownership of the registered risk.
    [HttpPost("register/{riskId:long}/owner")]
    public async Task<IActionResult> SetRegisterOwner(long riskId, [FromBody] RiskRegisterOwnerRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.SetRegisterOwnerAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // =================================================================
    // Phase B — migrations 208-211
    // =================================================================

    // ---- §19 configuration ------------------------------------------
    [HttpGet("config")]
    public async Task<IActionResult> GetConfig([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        var c = await svc.GetConfigAsync(organizationId, ct);
        return c is null ? NotFound() : Ok(c);
    }

    [HttpPost("config")]
    public async Task<IActionResult> SaveConfig([FromQuery] long organizationId,
        [FromBody] RiskConfigSaveRequest req, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { success = false, error = "organizationId is required." });
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        try
        {
            var c = await svc.SaveConfigAsync(organizationId, req, ct);
            return c is null ? NotFound() : Ok(c);
        }
        catch (Microsoft.Data.SqlClient.SqlException ex)
        {
            // 56222 / 56223 carry the configuration mistake in plain
            // words — a rating the matrix does not produce, or an unknown
            // role. Passing them through is the whole value.
            logger.LogWarning(ex, "RiskCentre.SaveConfig failed for org {Org}", organizationId);
            return BadRequest(new { success = false, error = ex.Message });
        }
    }

    // ---- §19 approval workflow ---------------------------------------
    [HttpPost("{id:long}/submit-approval")]
    public async Task<IActionResult> SubmitApproval(long id, [FromBody] RiskApprovalRequest? req, CancellationToken ct)
    {
        var result = await svc.SubmitForApprovalAsync(id, req ?? new RiskApprovalRequest(null, null, null), ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    [HttpPost("{id:long}/approve")]
    public async Task<IActionResult> DecideApproval(long id, [FromBody] RiskApprovalDecisionRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.DecideApprovalAsync(id, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    [HttpGet("approval-queue")]
    public async Task<IActionResult> ApprovalQueue([FromQuery] long organizationId,
        [FromQuery] int page = 1, [FromQuery] int pageSize = 25, CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListApprovalQueueAsync(organizationId, page, pageSize, ct));
    }

    // ---- §21 notifications -------------------------------------------
    // This is an OUTBOX, not a sender. The sweep records who should have
    // been told; a dispatcher marks rows Sent.
    [HttpPost("notifications/sweep")]
    public async Task<IActionResult> SweepNotifications([FromQuery] long? organizationId,
        [FromQuery] int sinceHours = 168, [FromQuery] int maxEvents = 500, CancellationToken ct = default)
    {
        var result = await svc.SweepNotificationsAsync(organizationId, sinceHours, maxEvents, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    [HttpGet("notifications")]
    public async Task<IActionResult> ListNotifications(
        [FromQuery] long organizationId,
        [FromQuery] string? statusCode,
        [FromQuery] string? notifyEventCode,
        [FromQuery] string? subjectTypeCode,
        [FromQuery] long? subjectRecordId,
        [FromQuery] long? recipientEmployeeId,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListNotificationsAsync(organizationId, statusCode, notifyEventCode,
            subjectTypeCode, subjectRecordId, recipientEmployeeId, page, pageSize, ct));
    }

    [HttpGet("notifications/counts")]
    public async Task<IActionResult> NotificationCounts([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.GetNotificationCountsAsync(organizationId, ct));
    }

    [HttpPost("notifications/{notificationId:long}/mark")]
    public async Task<IActionResult> MarkNotification(long notificationId,
        [FromBody] RiskNotificationMarkRequest req, CancellationToken ct)
    {
        if (req is null || string.IsNullOrWhiteSpace(req.StatusCode))
            return BadRequest(new { success = false, error = "statusCode is required." });
        var ok = await svc.MarkNotificationAsync(notificationId, req, ct);
        return Ok(new { success = ok, notificationId, statusCode = req.StatusCode });
    }

    // ---- §23 dashboard -----------------------------------------------
    [HttpGet("dashboard")]
    public async Task<IActionResult> Dashboard([FromQuery] long organizationId,
        [FromQuery] int trendMonths = 12, CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.GetDashboardAsync(organizationId, trendMonths, ct));
    }

    [HttpGet("ageing")]
    public async Task<IActionResult> Ageing([FromQuery] long organizationId,
        [FromQuery] int minAgeDays = 0, [FromQuery] int page = 1,
        [FromQuery] int pageSize = 25, CancellationToken ct = default)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.ListAgeingAsync(organizationId, minAgeDays, page, pageSize, ct));
    }

    // ---- §22 treatment task, opt-in ----------------------------------
    // Deliberately a separate action on a REGISTERED risk, not a flag on
    // registration: §22 puts the decision after registration.
    [HttpPost("register/{riskId:long}/treatment-task")]
    public async Task<IActionResult> RaiseTreatmentTask(long riskId,
        [FromBody] RiskTreatmentTaskRequest? req, CancellationToken ct)
    {
        var result = await svc.RaiseTreatmentTaskAsync(riskId,
            req ?? new RiskTreatmentTaskRequest(null, null, null, null, null, null, null), ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    [HttpGet("register/{riskId:long}/treatment-tasks")]
    public async Task<IActionResult> ListTreatmentTasks(long riskId, CancellationToken ct)
        => Ok(await svc.ListTreatmentWorkAsync(riskId, ct));

    // =================================================================
    // Two-stage assessment — migration 216
    //
    //   Stage 1  the candidate assessment: statement, threat,
    //            vulnerability, owner, business function -> register
    //   Stage 2  the scored analysis on a registered risk: category,
    //            likelihood, impact -> rating, then the §19 approval
    // =================================================================

    // The threat / vulnerability / business-function picklists. Separate
    // from /scoring-options because that one is the org's SCALE, which
    // stage 1 does not use.
    [HttpGet("assessment-options")]
    public async Task<IActionResult> AssessmentOptions([FromQuery] long organizationId, CancellationToken ct)
    {
        if (organizationId <= 0) return BadRequest(new { error = "organizationId is required." });
        return Ok(await svc.GetAssessmentOptionsAsync(organizationId, ct));
    }

    // Stage 2. Succeeds whether or not approval is required — the result
    // says which happened, because "saved, and the rating is live" and
    // "saved, and the rating is waiting for an approver" are different
    // outcomes the caller must be able to tell apart.
    [HttpPost("register/{riskId:long}/assess")]
    public async Task<IActionResult> AssessRegisteredRisk(long riskId,
        [FromBody] RiskRegisterAssessRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.AssessRegisteredRiskAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }

    // §19 at stage 2 — approving is what lets a rating reach the
    // authoritative register.
    [HttpPost("register/{riskId:long}/assess/approve")]
    public async Task<IActionResult> DecideRegisterAnalysis(long riskId,
        [FromBody] RiskApprovalDecisionRequest req, CancellationToken ct)
    {
        if (req is null) return BadRequest(new { success = false, error = "request body is required." });
        var result = await svc.DecideRegisterAnalysisAsync(riskId, req, ct);
        return result.Success ? Ok(result) : BadRequest(result);
    }
}
